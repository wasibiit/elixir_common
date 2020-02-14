defmodule Mix.Tasks.Vbt.Bootstrap do
  @shortdoc "Boostrap project (generate everything!!!)"
  @moduledoc "Boostrap project (generate everything!!!)"

  # credo:disable-for-this-file Credo.Check.Readability.Specs
  use Mix.Task
  alias Mix.Vbt
  alias Mix.Vbt.{ConfigFile, MixFile, SourceFile}

  def run(args) do
    if Mix.Project.umbrella?() do
      Mix.raise("mix vbt.bootstrap can only be run inside an application directory")
    end

    Enum.each(
      ~w/makefile docker circleci heroku github_pr_template credo dialyzer formatter_config
      tool_versions aws_mock operator_config/,
      &Mix.Task.run("vbt.gen.#{&1}", args)
    )

    adapt_code!()
  end

  # ------------------------------------------------------------------------
  # Code adaptation
  # ------------------------------------------------------------------------

  defp adapt_code! do
    source_files()
    |> adapt_gitignore()
    |> adapt_mix()
    |> configure_endpoint()
    |> configure_repo()
    |> adapt_app_module()
    |> drop_prod_secret()
    |> store_source_files!()

    File.rm(Path.join(~w/config prod.secret.exs/))
  end

  defp adapt_gitignore(source_files) do
    update_in(
      source_files.gitignore,
      &SourceFile.append(
        &1,
        """

        # Build folder inside devstack container
        /_builds/
        """
      )
    )
  end

  defp adapt_mix(source_files) do
    update_in(
      source_files.mix,
      fn mix_file ->
        mix_file
        |> MixFile.append_config(:aliases, ~s|credo: ["compile", "credo"]|)
        |> MixFile.append_config(
          :aliases,
          ~s|operator_template: ["compile", &operator_template/1]|
        )
        |> MixFile.append_config(:project, "preferred_cli_env: preferred_cli_env()")
        |> SourceFile.add_to_module("
            defp preferred_cli_env,
              do: [credo: :test, dialyzer: :test, operator_template: :prod]

        ")
        |> MixFile.append_config(:project, "dialyzer: dialyzer()")
        |> MixFile.append_config(:project, ~s|build_path: System.get_env("BUILD_PATH", "_build")|)
        |> SourceFile.add_to_module("""
            defp dialyzer do
              [
                plt_add_apps: [:ex_unit, :mix],
                ignore_warnings: "dialyzer.ignore-warnings"
              ]
            end

            defp operator_template(_),
              do: IO.puts(#{Mix.Vbt.context_module_name()}.OperatorConfig.template())

        """)
      end
    )
  end

  defp adapt_app_module(source_files) do
    update_in(
      source_files.app_module.content,
      &String.replace(
        &1,
        ~r/(\s*def start\(.*?do)/s,
        "\\1\n#{Mix.Vbt.context_module_name()}.OperatorConfig.validate!()\n"
      )
    )
  end

  defp drop_prod_secret(source_files) do
    update_in(
      source_files.prod_config.content,
      &String.replace(
        &1,
        ~s/import_config "prod.secret.exs"/,
        ""
      )
    )
  end

  # ------------------------------------------------------------------------
  # Endpoint configuration
  # ------------------------------------------------------------------------

  defp configure_endpoint(source_files) do
    source_files
    |> update_files(~w/config dev_config test_config prod_config/a, &remove_endpoint_settings/1)
    |> update_in([:endpoint], &setup_runtime_endpoint_config/1)
  end

  defp remove_endpoint_settings(file),
    do: ConfigFile.update_endpoint_config(file, &Keyword.drop(&1, ~w/url http secret_key_base/a))

  defp setup_runtime_endpoint_config(endpoint_file) do
    SourceFile.add_to_module(
      endpoint_file,
      """

      @impl Phoenix.Endpoint
      def init(_type, config) do
        config =
          config
          |> Keyword.put(:secret_key_base, #{Mix.Vbt.context_module_name()}.OperatorConfig.secret_key_base())
          |> Keyword.update(:url, url_config(), &Keyword.merge(&1, url_config()))
          |> Keyword.update(:http, http_config(), &(http_config() ++ (&1 || [])))

        {:ok, config}
      end

      defp url_config, do: [host: #{Mix.Vbt.context_module_name()}.OperatorConfig.host()]
      defp http_config, do: [:inet6, port: #{Mix.Vbt.context_module_name()}.OperatorConfig.port()]
      """
    )
  end

  # ------------------------------------------------------------------------
  # Repo configuration
  # ------------------------------------------------------------------------

  defp configure_repo(source_files) do
    source_files
    |> update_in([:config], &add_global_repo_config/1)
    |> update_files([:dev_config, :test_config], &remove_repo_settings/1)
    |> update_in([:repo], &setup_runtime_repo_config/1)
  end

  defp add_global_repo_config(config) do
    config
    |> ConfigFile.update_config(&Keyword.merge(&1, generators: [binary_id: true]))
    |> ConfigFile.add_new_config("""
        config #{inspect(Vbt.otp_app())}, #{inspect(Vbt.repo_module())},
          adapter: Ecto.Adapters.Postgres,
          migration_primary_key: [type: :binary_id],
          migration_timestamps: [type: :utc_datetime_usec],
          otp_app: #{inspect(Vbt.otp_app())}
    """)
  end

  defp remove_repo_settings(file) do
    ConfigFile.update_repo_config(
      file,
      &Keyword.drop(&1, ~w/username password database hostname pool_size/a)
    )
  end

  defp setup_runtime_repo_config(repo_file) do
    SourceFile.add_to_module(
      repo_file,
      """
      @impl Ecto.Repo
      def init(_type, config) do
        config =
          Keyword.merge(
            config,
            url: #{Mix.Vbt.context_module_name()}.OperatorConfig.db_url(),
            pool_size: #{Mix.Vbt.context_module_name()}.OperatorConfig.db_pool_size(),
            ssl: #{Mix.Vbt.context_module_name()}.OperatorConfig.db_ssl()
          )

        {:ok, config}
      end
      """
    )
  end

  # ------------------------------------------------------------------------
  # Common functions
  # ------------------------------------------------------------------------

  defp source_files do
    %{
      gitignore: SourceFile.load!(".gitignore", format?: false),
      mix: SourceFile.load!("mix.exs"),
      config: SourceFile.load!("config/config.exs"),
      dev_config: SourceFile.load!("config/dev.exs"),
      test_config: SourceFile.load!("config/test.exs"),
      prod_config: SourceFile.load!("config/prod.exs"),
      endpoint: load_web_file("endpoint.ex"),
      repo: load_context_file("repo.ex"),
      app_module: load_context_file("application.ex")
    }
  end

  defp update_files(source_files, files, updater),
    do: Enum.reduce(files, source_files, &update_in(&2[&1], updater))

  defp load_web_file(location),
    do: SourceFile.load!(Path.join(["lib", "#{Vbt.otp_app()}_web", location]))

  defp load_context_file(location),
    do: SourceFile.load!(Path.join(["lib", "#{Vbt.otp_app()}", location]))

  defp store_source_files!(source_files),
    do: source_files |> Map.values() |> Enum.each(&SourceFile.store!/1)
end
