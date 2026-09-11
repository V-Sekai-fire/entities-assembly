defmodule Assembler.Run do
  @moduledoc """
  Execute a parsed `gitassembly` against a checkout.

  The git commands match what `git-assembler` issued, because the bar RFD 2243
  sets for this replacement is a byte-identical tree rather than a similar one:
  bootstrap with `checkout --no-guess -b`, then `merge --rerere-autoupdate
  --no-edit` per dependency in declared order, and a dependency that is the
  node's own base is skipped rather than merged into itself.

  Only `stage` and `merge` are executed. `rebase` raises rather than falling
  through, so a config using it fails loudly instead of assembling something
  the caller did not ask for.
  """

  alias Assembler.Config

  def assemble(repo, config_path) do
    with {:ok, nodes, _settings} <- Config.parse(config_path) do
      nodes
      |> Map.values()
      |> Enum.reduce_while(:ok, fn node, :ok ->
        case build(repo, node) do
          :ok -> {:cont, :ok}
          err -> {:halt, err}
        end
      end)
    end
  end

  defp build(_repo, %{type: :rebase} = node),
    do: {:error, "#{node.name}: rebase is not implemented; only stage and merge are"}

  defp build(repo, %{type: :stage, base: base} = node) when is_binary(base) do
    # --recreate semantics: the branch may or may not exist, and either is fine.
    _ = git(repo, ["branch", "-D", node.name])

    with :ok <- git!(repo, ["checkout", "-q", "--no-guess", "-b", node.name, base]) do
      node.merge
      |> Enum.reject(&(&1 == base))
      |> Enum.reduce_while(:ok, fn dep, :ok ->
        case merge(repo, dep) do
          :ok -> {:cont, :ok}
          err -> {:halt, err}
        end
      end)
    end
  end

  defp build(_repo, node),
    do: {:error, "#{node.name}: only a stage node with a base can be assembled"}

  # rerere may resolve a conflict after `merge` has already exited non-zero, so
  # the commit is attempted before the merge is called a failure.
  defp merge(repo, dep) do
    case git(repo, ["merge", "-q", "--rerere-autoupdate", "--no-edit", dep]) do
      {_, 0} ->
        :ok

      {out, _} ->
        case git(repo, ["commit", "-q", "--no-edit"]) do
          {_, 0} -> :ok
          _ -> {:error, "merging #{dep} failed:\n#{out}"}
        end
    end
  end

  defp git!(repo, args) do
    case git(repo, args) do
      {_, 0} -> :ok
      {out, code} -> {:error, "git #{Enum.join(args, " ")} exited #{code}:\n#{out}"}
    end
  end

  defp git(repo, args),
    do: System.cmd("git", ["-C", repo] ++ args, stderr_to_stdout: true)
end
