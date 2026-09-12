defmodule Assembler.RunTest do
  use ExUnit.Case, async: false

  alias Assembler.Run

  setup do
    dir = Path.join(System.tmp_dir!(), "run-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    git(dir, ["init", "-q", "-b", "base"])
    git(dir, ["config", "user.email", "t@example.com"])
    # Windows desks default to core.autocrlf=true, which would have the fixture read
    # back what checkout rewrote rather than what the merge produced.
    git(dir, ["config", "core.autocrlf", "false"])
    git(dir, ["config", "user.name", "t"])
    commit(dir, "shared", "0\n", "root")
    for b <- ~w(topic-a topic-b) do
      git(dir, ["checkout", "-q", "-b", b, "base"])
      commit(dir, b, "#{b}\n", "on #{b}")
    end

    git(dir, ["checkout", "-q", "base"])
    {:ok, dir: dir}
  end

  defp git(dir, args), do: {_, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)

  defp commit(dir, file, body, msg) do
    File.write!(Path.join(dir, file), body)
    git(dir, ["add", file])
    git(dir, ["commit", "-qm", msg])
  end

  defp config(body) do
    p = Path.join(System.tmp_dir!(), "cfg-#{System.unique_integer([:positive])}")
    File.write!(p, body)
    on_exit(fn -> File.rm(p) end)
    p
  end

  defp tree(dir, ref), do: elem(System.cmd("git", ["-C", dir, "rev-parse", ref <> "^{tree}"]), 0) |> String.trim()
  defp merges(dir, range),
    do: System.cmd("git", ["-C", dir, "rev-list", "--count", "--merges", range]) |> elem(0) |> String.trim()

  # git-assembler passes no --ff flag, so the first dependency fast-forwards a
  # freshly staged branch and only the second needs a merge commit. Asserting two
  # here would assert --no-ff, which is a different assembler.
  test "a stage with two merges carries both", %{dir: dir} do
    assert :ok = Run.assemble(dir, config("stage out base\nmerge out topic-a topic-b\n"))

    assert File.read!(Path.join(dir, "topic-a")) == "topic-a\n"
    assert File.read!(Path.join(dir, "topic-b")) == "topic-b\n"
    assert merges(dir, "base..out") == "1"
  end

  test "assembling twice from the same refs gives the same tree", %{dir: dir} do
    cfg = config("stage out base\nmerge out topic-a topic-b\n")
    assert :ok = Run.assemble(dir, cfg)
    first = tree(dir, "out")

    git(dir, ["checkout", "-q", "base"])
    assert :ok = Run.assemble(dir, cfg)
    assert tree(dir, "out") == first
  end

  test "declared order is the order merged", %{dir: dir} do
    assert :ok = Run.assemble(dir, config("stage out base\nmerge out topic-a topic-b\n"))

    {log, 0} = System.cmd("git", ["-C", dir, "log", "--merges", "--format=%s", "base..out"])
    # newest first, so the last declared merge heads the log
    assert log |> String.split("\n", trim: true) |> hd() =~ "topic-b"
  end

  test "a dependency that is the base is not merged into itself", %{dir: dir} do
    assert :ok = Run.assemble(dir, config("stage out base\nmerge out base topic-a\n"))
    # topic-a fast-forwards, and base was skipped rather than merged into itself.
    assert merges(dir, "base..out") == "0"
    assert File.read!(Path.join(dir, "topic-a")) == "topic-a\n"
  end

  test "a conflicting merge fails rather than committing a marker", %{dir: dir} do
    git(dir, ["checkout", "-q", "-b", "clash-a", "base"])
    commit(dir, "shared", "a\n", "a")
    git(dir, ["checkout", "-q", "-b", "clash-b", "base"])
    commit(dir, "shared", "b\n", "b")
    git(dir, ["checkout", "-q", "base"])

    assert {:error, why} = Run.assemble(dir, config("stage out base\nmerge out clash-a clash-b\n"))
    assert why =~ "clash-b"
    # The conflict is left in the tree for a human, as git-assembler left it. What
    # must not happen is the caller being told the assembly succeeded.
    assert File.read!(Path.join(dir, "shared")) =~ "<<<<<<<"
    assert {_, 0} = System.cmd("git", ["-C", dir, "rev-parse", "--verify", "MERGE_HEAD"],
                               stderr_to_stdout: true)
  end

  test "rebase is refused rather than silently skipped", %{dir: dir} do
    assert {:error, why} = Run.assemble(dir, config("rebase topic-a base\n"))
    assert why =~ "rebase"
  end

  test "a missing ref fails and names the git error", %{dir: dir} do
    assert {:error, why} = Run.assemble(dir, config("stage out nosuchref\n"))
    assert why =~ "nosuchref"
  end
end
