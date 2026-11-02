defmodule Assembler.Run do
  @moduledoc """
  Execute a parsed `gitassembly` against a checkout.

  The git commands match what `git-assembler` issued, because the bar RFD66606-2243
  sets for this replacement is a byte-identical tree rather than a similar one:
  bootstrap with `checkout --no-guess -b`, then `merge --no-ff --no-edit` per dependency in declared order, and a dependency that is the
  node's own base is skipped rather than merged into itself.

  Only `stage` and `merge` are executed. `rebase` raises rather than falling
  through, so a config using it fails loudly instead of assembling something
  the caller did not ask for.
  """

  alias Assembler.Config

  def assemble(repo, config_path) do
    with {:ok, nodes, _settings} <- Config.parse(config_path),
         {:ok, ordered} <- order(nodes) do
      ordered
      |> Enum.reduce_while(:ok, fn node, :ok ->
        case build(repo, node) do
          :ok -> {:cont, :ok}
          err -> {:halt, err}
        end
      end)
    end
  end

  @doc """
  Nodes in build order: a node whose base is another node comes after it, so a
  nested release (`stage r1-see r0-base`) is built on the branch its base just
  produced. Ties keep name order, so the order never depends on map layout.
  A cycle is an error naming the nodes in it.
  """
  def order(nodes) do
    nodes
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn name, {:ok, acc, done} ->
      case visit(nodes, name, [], acc, done) do
        {:ok, acc, done} -> {:cont, {:ok, acc, done}}
        err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc, _done} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  defp visit(nodes, name, path, acc, done) do
    cond do
      MapSet.member?(done, name) ->
        {:ok, acc, done}

      name in path ->
        cycle = Enum.reverse([name | path]) |> Enum.drop_while(&(&1 != name))
        {:error, "stage cycle: #{Enum.join(cycle, " -> ")}"}

      true ->
        node = Map.fetch!(nodes, name)

        with {:ok, acc, done} <- visit_base(nodes, node.base, [name | path], acc, done) do
          {:ok, [node | acc], MapSet.put(done, name)}
        end
    end
  end

  defp visit_base(nodes, base, path, acc, done) when is_map_key(nodes, base),
    do: visit(nodes, base, path, acc, done)

  defp visit_base(_nodes, _base, _path, acc, done), do: {:ok, acc, done}

  defp build(_repo, %{type: :rebase} = node),
    do: {:error, "#{node.name}: rebase is not implemented; only stage and merge are"}

  defp build(repo, %{type: :stage, base: base} = node) when is_binary(base) do
    # --recreate semantics: the branch may or may not exist, and either is fine.
    _ = git(repo, ["branch", "-D", node.name])

    deps = Enum.reject(node.merge, &(&1 == base))

    with :ok <- git!(repo, ["checkout", "-q", "--no-guess", "-b", node.name, base]),
         {:ok, env} <- deterministic_env(repo, [base | deps]) do
      deps
      |> Enum.reduce_while(:ok, fn dep, :ok ->
        case merge(repo, dep, env) do
          :ok -> {:cont, :ok}
          err -> {:halt, err}
        end
      end)
    end
  end

  defp build(_repo, node),
    do: {:error, "#{node.name}: only a stage node with a base can be assembled"}

  # rerere is banned: it replays resolutions from a local cache that is not in
  # the commit, so the same inputs would assemble differently per machine. It is
  # switched off explicitly (a user's rerere.enabled=true must not leak in), and
  # a conflict fails the assembly after the merge is aborted.
  #
  # Every merge is `--no-ff` so each input branch is recorded as a parent of the
  # result, even when it could fast-forward. Dates and identity come from `env`.
  defp merge(repo, dep, env) do
    case git(repo, ["-c", "rerere.enabled=false", "merge", "-q", "--no-ff", "--no-edit", dep], env) do
      {_, 0} ->
        :ok

      {out, _} ->
        _ = git(repo, ["merge", "--abort"])
        {:error, "merging #{dep} failed:\n#{out}"}
    end
  end

  # The merge commits' timestamps and identity must not depend on when or where
  # the assembly runs, or the same inputs hash differently. The time is the
  # newest committer time among the base and every merged tip, so it is the
  # time of the last commit in the chain; the identity is the v-sekai-fire-persona GitHub App bot (id 327205944).
  defp deterministic_env(repo, refs) do
    refs
    |> Enum.reduce_while({:ok, []}, fn ref, {:ok, acc} ->
      case git(repo, ["log", "-1", "--format=%ct", ref]) do
        {out, 0} -> {:cont, {:ok, [String.to_integer(String.trim(out)) | acc]}}
        {out, _} -> {:halt, {:error, "cannot read the commit time of #{ref}:\n#{out}"}}
      end
    end)
    |> case do
      {:ok, times} ->
        date = "#{Enum.max(times)} +0000"

        {:ok,
         [
           {"GIT_AUTHOR_DATE", date},
           {"GIT_COMMITTER_DATE", date},
           {"GIT_AUTHOR_NAME", "v-sekai-fire-persona[bot]"},
           {"GIT_AUTHOR_EMAIL", "327205944+v-sekai-fire-persona[bot]@users.noreply.github.com"},
           {"GIT_COMMITTER_NAME", "v-sekai-fire-persona[bot]"},
           {"GIT_COMMITTER_EMAIL", "327205944+v-sekai-fire-persona[bot]@users.noreply.github.com"}
         ]}

      err ->
        err
    end
  end

  defp git!(repo, args) do
    case git(repo, args) do
      {_, 0} -> :ok
      {out, code} -> {:error, "git #{Enum.join(args, " ")} exited #{code}:\n#{out}"}
    end
  end

  defp git(repo, args, env \\ []),
    do: System.cmd("git", ["-C", repo] ++ args, stderr_to_stdout: true, env: env)
end
