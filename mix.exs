defmodule Assembler.MixProject do
  use Mix.Project

  def project do
    [
      app: :assembler,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        flags: [:error_handling, :extra_return, :missing_return, :unmatched_returns]
      ]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  # Every git operation is a system `git` process (System.cmd): crash-safe,
  # since a failing git cannot take the VM down the way a NIF can, and no
  # native dependency to build. The cost is a process per call and parsing
  # git's text output, which is small next to the merges themselves.
  defp deps do
    [
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
