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

  # egit is an Erlang NIF over libgit2, Apache-2.0. It replaces the GPLv3
  # git-assembler it replaced is deleted; nothing GPLv3 is vendored here. Only local
  # operations go through it -- branch, merge, rebase, rev-parse -- because the
  # assembler itself makes no network calls; clone and fetch stay on system git
  # in update_godot_v_sekai.exs.
  defp deps do
    [
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
