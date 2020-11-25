defmodule Mix.Tasks.Vbt.Bootstrap do
  @shortdoc "Boostrap project (generate everything!!!)"
  @moduledoc "Boostrap project (generate everything!!!)"

  # credo:disable-for-this-file Credo.Check.Readability.Specs
  use Mix.Task
  import Mix.Vbt
  alias Mix.Vbt.{ConfigFile, MixFile, SourceFile}

  def run(args) do
    if Mix.Project.umbrella?() do
      Mix.raise("mix vbt.bootstrap can only be run inside an application directory")
    end

    # we'll generate our own app module
    File.rm!("lib/#{otp_app()}/application.ex")

    generate_files(args)
    adapt_code!()
    setup_git!()
  end

  # ------------------------------------------------------------------------
  # File generation
  # ------------------------------------------------------------------------

  # Collecting template files which have user's executable permission set.
  # This information is needed so we can make corresponding generated files executable. We need
  # to collect such files during compilation, because vbt.new is distributed as an Elixir archive
  # (https://hexdocs.pm/mix/Mix.Tasks.Archive.Build.html#content), and executable mode is not
  # preserved in an archive.
  local_templates_folder = Path.join(~w(priv templates))

  executable_templates =
    Path.join(~w(#{local_templates_folder} ** *.eex))
    |> Path.wildcard()
    |> Stream.filter(&match?(<<1::1, _rest::6>>, <<File.stat!(&1).mode::7>>))
    |> Enum.map(&Path.relative_to(&1, local_templates_folder))

  defp generate_files(args) do
    # This function will load all .eex which reside under priv/templates, and generate
    # corresponding files in the client project. The folder structure of the generated files will
    # match the folder structure inside priv/templates. Each generated file will have the same name
    # as the source template, minus the .eex suffix. If the template file is executable by the
    # owner, the generated file will also be executable (only by the owner user). Finally, files
    # in priv/template which don't have the .eex extension will be ignored.

    templates_path = Path.join(~w/#{Application.app_dir(:vbt_new)} priv templates/)

    {mix_generator_opts, [organization]} = OptionParser.parse!(args, switches: [force: :boolean])

    for template <- Path.wildcard(Path.join(templates_path, "**/*.eex"), match_dot: true) do
      relative_path = Path.relative_to(template, templates_path)

      target_file =
        relative_path
        |> String.replace(~r/\.eex$/, "")
        |> String.replace(
          ~r[^((?:lib)|(?:test/support))/otp_app(_|/|\.ex)],
          "\\1/#{otp_app()}\\2"
        )
        |> String.replace(~r[^((lib)|(test))/web/], "\\1/#{otp_app()}_web/")

      content = EEx.eval_file(template, app: otp_app(), docker: true, organization: organization)

      content =
        if Path.extname(target_file) in ~w/.ex .eex/,
          do: SourceFile.format_code(content),
          else: content

      if Mix.Generator.create_file(target_file, content, mix_generator_opts) do
        if Enum.member?(unquote(executable_templates), relative_path) do
          new_mode = Bitwise.bor(File.stat!(target_file).mode, 0b1_000_000)
          File.chmod!(target_file, new_mode)
        end
      end
    end
  end

  # ------------------------------------------------------------------------
  # Code adaptation
  # ------------------------------------------------------------------------

  defp adapt_code! do
    source_files()
    |> adapt_gitignore()
    |> adapt_mix()
    |> add_kubernetes_liveness_check()
    |> adapt_web_root_module()
    |> configure_endpoint()
    |> configure_repo()
    |> drop_prod_secret()
    |> setup_test_mocks()
    |> config_bcrypt()
    |> setup_sentry()
    |> setup_test_plug()
    |> adapt_test_support_modules()
    |> store_source_files!()

    adapt_test_references!()

    File.rm(Path.join(~w/config prod.secret.exs/))
    File.rm_rf("priv/repo/migrations/.formatter.exs")

    disable_credo_checks()
  end

  defp adapt_gitignore(source_files) do
    update_in(
      source_files.gitignore,
      &SourceFile.append(
        &1,
        """

        # Build folder inside devstack container
        /_builds/

        # Ignore ssh folder generated by docker
        .ssh
        """
      )
    )
  end

  defp adapt_mix(source_files) do
    update_in(
      source_files.mix,
      fn mix_file ->
        mix_file
        |> adapt_min_elixir_version()
        |> setup_aliases()
        |> setup_preferred_cli_env()
        |> setup_dialyzer()
        |> setup_release()
        |> setup_boundary()
        |> MixFile.append_config(:project, ~s|build_path: System.get_env("BUILD_PATH", "_build")|)
        |> adapt_deps()
        |> Map.update!(
          :content,
          &String.replace(
            &1,
            "#{context_module_name()}.Application",
            "#{app_module_name()}"
          )
        )
        |> Map.update!(
          :content,
          &String.replace(
            &1,
            "compilers: [:phoenix",
            "compilers: [:boundary, :phoenix"
          )
        )
      end
    )
  end

  defp adapt_deps(mix_file) do
    mix_file
    |> MixFile.append_config(:deps, ~s/\n{:boundary, "~> 0.6"}/)
    |> MixFile.append_config(:deps, ~s/\n{:mox, "~> 0.5", only: :test}/)
    |> sort_deps()
  end

  defp sort_deps(mix_file) do
    deps_regex = ~r/\n\s*defp deps do\s+\[(?<deps>.*?)\]\s+end/s

    deps =
      Regex.named_captures(deps_regex, mix_file.content)
      |> Map.fetch!("deps")
      |> String.split(~r/\n\s*/, trim: true)
      |> Enum.sort()
      |> Enum.map(&String.replace(&1, ~r/,\s*$/, ""))
      |> Enum.join(",\n")

    update_in(mix_file.content, &String.replace(&1, deps_regex, "\ndefp deps do [#{deps}] end"))
  end

  defp adapt_min_elixir_version(mix_file) do
    elixir = tool_versions().elixir

    Map.update!(
      mix_file,
      :content,
      &String.replace(&1, ~r/elixir: ".*"/, ~s/elixir: "~> #{elixir.major}.#{elixir.minor}"/)
    )
  end

  defp setup_aliases(mix_file) do
    mix_file
    |> MixFile.append_config(:aliases, ~s|credo: ["compile", "credo"]|)
    |> MixFile.append_config(
      :aliases,
      ~s|operator_template: ["compile", &operator_template/1]|
    )
  end

  defp setup_preferred_cli_env(mix_file) do
    mix_file
    |> MixFile.append_config(:project, "preferred_cli_env: preferred_cli_env()")
    |> SourceFile.add_to_module("""
    defp preferred_cli_env,
      do: [credo: :test, dialyzer: :test, release: :prod, operator_template: :prod]

    """)
  end

  defp setup_dialyzer(mix_file) do
    mix_file
    |> MixFile.append_config(:project, "dialyzer: dialyzer()")
    |> SourceFile.add_to_module("""
    defp dialyzer do
      [
        plt_add_apps: [:ex_unit, :mix],
        ignore_warnings: "dialyzer.ignore-warnings"
      ]
    end

    defp operator_template(_),
      do: IO.puts(#{config_module_name()}.template())

    """)
  end

  defp setup_release(mix_file) do
    mix_file
    |> MixFile.append_config(:project, "releases: releases()")
    |> SourceFile.add_to_module("""
    defp releases() do
      [
        #{otp_app()}: [
          include_executables_for: [:unix],
          steps: [:assemble, &copy_bin_files/1]
        ]
      ]
    end

    # solution from https://elixirforum.com/t/equivalent-to-distillerys-boot-hooks-in-mix-release-elixir-1-9/23431/2
    defp copy_bin_files(release) do
      File.cp_r("rel/bin", Path.join(release.path, "bin"))
      release
    end

    """)
    |> MixFile.append_config(:aliases, ~s|release: release_steps()|)
    |> SourceFile.add_to_module("""
      defp release_steps do
        if Mix.env != :prod or System.get_env("SKIP_ASSETS") == "true" or not File.dir?("assets") do
          []
        else
          [
            "cmd 'cd assets && npm install && npm run deploy'",
            "phx.digest"
          ]
        end
        |> Enum.concat(["release"])
      end
    """)
  end

  defp setup_boundary(mix_file) do
    mix_file
    |> MixFile.append_config(:project, "boundary: boundary()")
    |> SourceFile.add_to_module("""
    defp boundary do
      [
        default: [
          check: [
            apps: [{:mix, :runtime}]
          ]
        ]
      ]
    end
    """)
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

  defp disable_credo_checks do
    # We don't check for specs in views, controllers, channels, and resolvers, because specs aren't
    # useful there, and they add some noise.
    Enum.each(
      Path.wildcard("lib/#{otp_app()}_web/**/*.ex"),
      &disable_credo_checks(&1, ["Credo.Check.Readability.Specs"])
    )

    # Some helper files created by phx.new violate these checks, so we'll disable them. This is
    # not the code we'll edit, so disabling these checks is fine here.
    disable_credo_checks("lib/#{otp_app()}_web.ex", ~w/
      Credo.Check.Readability.AliasAs
      Credo.Check.Readability.Specs
      VBT.Credo.Check.Consistency.ModuleLayout
    /)

    disable_credo_checks(
      "lib/#{otp_app()}_web/telemetry.ex",
      ~w/VBT.Credo.Check.Consistency.ModuleLayout/
    )

    disable_credo_checks("test/support/#{otp_app()}_test/web/conn_case.ex", ~w/
      Credo.Check.Readability.AliasAs
      Credo.Check.Design.AliasUsage
    /)

    disable_credo_checks("test/support/#{otp_app()}_test/data_case.ex", ~w/
      Credo.Check.Design.AliasUsage
      Credo.Check.Readability.Specs
    /)

    disable_credo_checks(
      "test/support/#{otp_app()}_test/web/channel_case.ex",
      ~w/Credo.Check.Design.AliasUsage/
    )
  end

  defp disable_credo_checks(file, checks) do
    checks
    |> Enum.reduce(
      file |> SourceFile.load!() |> SourceFile.prepend("\n"),
      &SourceFile.prepend(&2, "# credo:disable-for-this-file #{&1}\n")
    )
    |> SourceFile.store!()
  end

  defp config_bcrypt(source_files) do
    update_in(
      source_files.test_config,
      &ConfigFile.prepend(&1, "config :bcrypt_elixir, :log_rounds, 1")
    )
  end

  defp setup_sentry(source_files) do
    source_files
    |> configure_sentry()
    |> add_sentry_to_endpoint()
  end

  defp configure_sentry(source_files) do
    source_files
    |> update_in(
      [:config],
      &ConfigFile.prepend(&1, """
      config :sentry,
        dsn: {:system, "SENTRY_DSN"},
        environment_name: {:system, "RELEASE_LEVEL"},
        enable_source_code_context: true,
        root_source_code_path: File.cwd!(),
        included_environments: ~w(prod stage develop preview),
        release: #{context_module_name()}.MixProject.project()[:version]
      """)
    )
    |> update_in(
      [:test_config],
      &ConfigFile.prepend(
        &1,
        "config :sentry, client: #{test_module_name()}.SentryClient"
      )
    )
  end

  defp add_sentry_to_endpoint(source_files) do
    update_in(
      source_files.endpoint.content,
      &String.replace(
        &1,
        ~r/(use Phoenix\.Endpoint.*?)\n/s,
        "\\1\nuse Sentry.Phoenix.Endpoint\n"
      )
    )
  end

  defp setup_test_plug(source_files) do
    update_in(
      source_files.endpoint.content,
      &String.replace(
        &1,
        ~r/(plug #{web_module_name()}\.Router)\n/,
        """
        if Mix.env() == :test do
          plug #{test_module_name()}.Web.TestPlug
        end

        \\1
        """
      )
    )
  end

  defp adapt_test_support_modules(source_files) do
    for file_name <- ~w/channel_case conn_case/ do
      source = Path.join(~w/test support #{file_name}.ex/)
      destination = Path.join(~w/test support #{otp_app()}_test web #{file_name}.ex/)
      File.mkdir_p!(Path.dirname(destination))
      File.rename!(source, destination)

      destination
      |> SourceFile.load!()
      |> update_in(
        [:content],
        &String.replace(
          &1,
          "defmodule #{web_module_name()}.",
          "defmodule #{test_module_name()}.Web."
        )
      )
      |> SourceFile.store!()
    end

    source = Path.join(~w/test support data_case.ex/)
    destination = Path.join(~w/test support #{otp_app()}_test data_case.ex/)
    File.mkdir_p!(Path.dirname(destination))
    File.rename!(source, destination)

    destination
    |> SourceFile.load!()
    |> update_in(
      [:content],
      &String.replace(
        &1,
        "defmodule #{context_module_name()}.",
        "defmodule #{test_module_name()}."
      )
    )
    |> SourceFile.store!()

    source_files
  end

  defp setup_test_mocks(source_files),
    do: update_in(source_files.test_helper, &SourceFile.append(&1, "VBT.Aws.Test.setup()"))

  defp adapt_test_references! do
    for file <- Path.wildcard(Path.join(~w/test **/)),
        not File.dir?(file),
        String.ends_with?(file, ".ex") or String.ends_with?(file, ".exs") do
      file
      |> SourceFile.load!()
      |> update_in(
        [:content],
        &String.replace(
          &1,
          ~r/#{web_module_name()}\.(ConnCase|ChannelCase)/,
          "#{test_module_name()}.Web.\\1"
        )
      )
      |> SourceFile.store!()
    end
  end

  # ------------------------------------------------------------------------
  # Endpoint configuration
  # ------------------------------------------------------------------------

  defp add_kubernetes_liveness_check(source_files) do
    update_in(
      source_files.endpoint.content,
      &String.replace(
        &1,
        "plug Plug.Head\n",
        """
        plug Plug.Head
        plug VBT.Kubernetes.Probe, "/healthz"
        """
      )
    )
  end

  defp adapt_web_root_module(source_files) do
    update_in(
      source_files.web.content,
      &String.replace(
        &1,
        ~r/@moduledoc """.*?"""/s,
        """
        \\0

        use Boundary,
          deps: [#{context_module_name()}, #{config_module_name()}, #{schemas_module_name()}],
          exports: [Endpoint]

        @spec start_link :: Supervisor.on_start()
        def start_link do
          Supervisor.start_link(
            [
              #{web_module_name()}.Telemetry,
              #{web_module_name()}.Endpoint
            ],
            strategy: :one_for_one,
            name: __MODULE__
          )
        end

        @spec child_spec(any) :: Supervisor.child_spec()
        def child_spec(_arg) do
          %{
            id: __MODULE__,
            type: :supervisor,
            start: {__MODULE__, :start_link, []}
          }
        end
        """
      )
    )
  end

  defp configure_endpoint(source_files) do
    source_files
    |> update_files(~w/config dev_config test_config prod_config/a, &remove_endpoint_settings/1)
    |> update_in(
      [:prod_config],
      &ConfigFile.update_endpoint_config(
        &1,
        fn config ->
          Keyword.merge(config,
            url: [scheme: "https", port: 443],
            force_ssl: [rewrite_on: [:x_forwarded_proto]],
            server: true
          )
        end
      )
    )
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
          |> Keyword.put(:secret_key_base, #{config_module_name()}.secret_key_base())
          |> Keyword.update(:url, url_config(), &Keyword.merge(&1, url_config()))
          |> Keyword.update(:http, http_config(), &(http_config() ++ (&1 || [])))

        {:ok, config}
      end

      defp url_config, do: [host: #{config_module_name()}.host()]
      defp http_config, do: [:inet6, port: #{config_module_name()}.port()]
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
    |> update_in([:repo, :content], &String.replace(&1, "use Ecto.Repo", "use VBT.Repo"))
  end

  defp add_global_repo_config(config) do
    config
    |> ConfigFile.update_config(&Keyword.merge(&1, generators: [binary_id: true]))
    |> ConfigFile.prepend("""
        config #{inspect(otp_app())}, #{inspect(repo_module())},
          adapter: Ecto.Adapters.Postgres,
          migration_primary_key: [type: :binary_id],
          migration_timestamps: [type: :utc_datetime_usec],
          otp_app: #{inspect(otp_app())}
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
            url: #{config_module_name()}.db_url(),
            pool_size: #{config_module_name()}.db_pool_size(),
            ssl: #{config_module_name()}.db_ssl()
          )

        {:ok, config}
      end
      """
    )
  end

  # ------------------------------------------------------------------------
  # GitHub configuration
  # ------------------------------------------------------------------------

  defp setup_git! do
    git!(~w/init/)
    git!(~w/add ./)
    git!(~w/commit -m "Kickoff"/)
    git!(~w/checkout -b develop/)
    git!(~w/branch -d master/)
    git!(~w/branch prod/)
  end

  defp git!(args) do
    {result, 0} = System.cmd("git", args, stderr_to_stdout: true)
    result
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
      test_helper: SourceFile.load!("test/test_helper.exs"),
      web: SourceFile.load!("lib/#{otp_app()}_web.ex")
    }
  end

  defp update_files(source_files, files, updater),
    do: Enum.reduce(files, source_files, &update_in(&2[&1], updater))

  defp load_web_file(location),
    do: SourceFile.load!(Path.join(["lib", "#{otp_app()}_web", location]))

  defp load_context_file(location, opts \\ []),
    do: SourceFile.load!(Path.join(["lib", "#{otp_app()}", location]), opts)

  defp store_source_files!(source_files),
    do: source_files |> Map.values() |> Enum.each(&SourceFile.store!/1)
end
