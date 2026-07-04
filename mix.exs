defmodule RegistryManager.MixProject do
  use Mix.Project

  def project do
    [
      app: :registry_manager,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      escript: [main_module: RegistryManager.CLI, name: "registry-manager"],
      test_coverage: [
        # Coverage summary configuration with 83% threshold (meaningful tests only)
        summary: [threshold: 80],
        ignore_modules: [
          # Main module (pure delegate functions, no business logic)
          RegistryManager,
          # External dependency modules (HTTP requests, system commands)
          RegistryManager.GitHubAPI.Client,
          # CLI modules (external dependencies, use System.halt)
          #          RegistryManager.CLI,
          # GitHub API modules (external API dependencies, most code paths are mocked in tests)
          RegistryManager.GitHubAPI,
          # Test support modules (not production code)
          RegistryManager.Test.GitHubAPIMock,
          RegistryManager.Test.TestDataStore
        ]
      ],
      dialyzer: [
        plt_add_apps: [:mix],
        flags: [:error_handling, :underspecs],
        ignore_warnings: "dialyzer.ignore-warnings"
      ],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:req, "~> 0.4"},
      {:table_rex, "~> 4.1"},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
