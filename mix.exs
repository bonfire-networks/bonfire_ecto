defmodule BonfireEcto.MixProject do
  use Mix.Project

  def project do
    [
      app: :bonfire_ecto,
      version: "0.1.0",
      elixir: "~> 1.12",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application, do: [ extra_applications: [:logger] ]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # {:bonfire_epics, "~> 0.1"},
      {:bonfire_common, git: "https://github.com/bonfire-networks/bonfire_common", branch: "main", optional: true},
      {:bonfire_epics, git: "https://github.com/bonfire-networks/bonfire_epics", branch: "main"},
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
    ]
  end
end
