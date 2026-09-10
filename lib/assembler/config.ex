defmodule Assembler.Config do
  @moduledoc """
  Parser for the `gitassembly` file.

  Directive semantics match git-assembler, which this replaces: `target`,
  `flags`, and the four branch rules `base` / `rebase` / `stage` / `merge`.
  A `#` is not a comment and never was here -- the parser rejects an unknown
  command rather than skipping the line, because a silently dropped rule and
  an applied one look identical afterwards.
  """

  defmodule Node do
    @moduledoc false
    defstruct name: nil,
              base: nil,
              # :branch | :base | :rebase | :stage
              type: :branch,
              merge: [],
              merge_flags: %{},
              rebase_flags: []
  end

  @rules ~w(base rebase stage merge)
  @base_rules ~w(base rebase stage)

  @doc """
  Parse `path`. `branches` is the list of branch names a pattern may expand
  against. Returns `{:ok, nodes, settings}` or `{:error, reason}` where reason
  names the file and line, so a bad rule says which one it is.
  """
  def parse(path, branches \\ []) do
    with {:ok, text} <- File.read(path) do
      text
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.reduce_while({%{}, %{target: []}, %{"merge" => [], "rebase" => []}}, fn
        {line, n}, acc -> step(String.split(line), n, path, branches, acc)
      end)
      |> case do
        {:error, _} = err -> err
        {nodes, settings, _global} -> {:ok, nodes, settings}
      end
    end
  end

  defp step([], _n, _path, _branches, acc), do: {:cont, acc}

  defp step(["target" | rest], n, path, _branches, {nodes, settings, global}) do
    cond do
      rest == [] -> halt_err(path, n, "invalid assembly line")
      settings.target != [] -> halt_err(path, n, "default target/s redefined")
      true -> {:cont, {nodes, %{settings | target: rest}, global}}
    end
  end

  defp step(["flags" | rest], n, path, _branches, {nodes, settings, global}) do
    case rest do
      [] -> halt_err(path, n, "invalid assembly line")
      [target | args] when is_map_key(global, target) ->
        {:cont, {nodes, settings, Map.put(global, target, args)}}
      _ -> halt_err(path, n, "invalid flags target")
    end
  end

  defp step([cmd | rest], n, path, branches, acc) when cmd in @rules do
    case rest do
      [_target] -> halt_err(path, n, "invalid assembly line")
      [] -> halt_err(path, n, "invalid assembly line")
      [target | args] -> rule(cmd, target, args, n, path, branches, acc)
    end
  end

  defp step([cmd | _], n, path, _branches, _acc),
    do: halt_err(path, n, "unknown command: #{cmd}")

  defp rule(cmd, target, args, n, path, branches, {nodes, settings, global}) do
    {args, flags} = split_flags(cmd, args, global)

    with {:ok, targets} <- expand_target(target, branches, n, path),
         {:ok, nodes} <- apply_rule(cmd, targets, args, flags, nodes, n, path, branches) do
      {:cont, {nodes, settings, global}}
    else
      {:error, _} = err -> {:halt, err}
    end
  end

  # For merge/rebase rules the first `-`-prefixed argument begins the flags.
  defp split_flags(cmd, args, global) when cmd in ["merge", "rebase"] do
    case Enum.find_index(args, &String.starts_with?(&1, "-")) do
      nil -> {args, Map.fetch!(global, cmd)}
      i -> {Enum.take(args, i), Map.fetch!(global, cmd) ++ Enum.drop(args, i)}
    end
  end

  defp split_flags(_cmd, args, _global), do: {args, []}

  defp expand_target(target, branches, n, path) do
    if pattern?(target) do
      case expand(target, branches) do
        [] -> {:error, err(path, n, "pattern #{target} in rule does not match any branch")}
        list -> {:ok, list}
      end
    else
      {:ok, [target]}
    end
  end

  defp apply_rule(cmd, targets, args, flags, nodes, n, path, branches) do
    Enum.reduce_while(targets, {:ok, nodes}, fn branch, {:ok, acc} ->
      node = Map.get(acc, branch, %Node{name: branch})

      case do_rule(cmd, node, args, flags, n, path, branches) do
        {:ok, node} -> {:cont, {:ok, Map.put(acc, branch, node)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp do_rule(cmd, %Node{} = node, args, flags, n, path, _branches) when cmd in @base_rules do
    cond do
      node.base != nil ->
        {:error, err(path, n, "branch base/type cannot be redefined")}

      length(args) != 1 ->
        {:error, err(path, n, "invalid base for branch #{node.name}")}

      pattern?(hd(args)) ->
        {:error, err(path, n, "base #{hd(args)} cannot be a pattern")}

      hd(args) == node.name ->
        {:error, err(path, n, "refusing to #{cmd} #{node.name} onto itself")}

      true ->
        type = %{"stage" => :stage, "rebase" => :rebase, "base" => :base}[cmd]
        node = %{node | base: hd(args), type: type}
        {:ok, if(cmd == "rebase", do: %{node | rebase_flags: flags}, else: node)}
    end
  end

  defp do_rule("merge", %Node{} = node, args, flags, n, path, branches) do
    with {:ok, deps} <- collect_deps(args, node, branches, n, path) do
      case Enum.find(deps, &(&1 == node.name)) do
        nil ->
          {:ok,
           %{
             node
             | merge: node.merge ++ deps,
               merge_flags: Enum.reduce(deps, node.merge_flags, &Map.put(&2, &1, flags))
           }}

        self ->
          {:error, err(path, n, "refusing merge of #{self} into itself")}
      end
    end
  end

  # An explicit duplicate is an error; a duplicate that a pattern happened to
  # produce is skipped, because the author did not name it twice.
  defp collect_deps(args, node, branches, n, path) do
    Enum.reduce_while(args, {:ok, []}, fn arg, {:ok, acc} ->
      cond do
        not pattern?(arg) and (arg in acc or arg in node.merge) ->
          {:halt, {:error, err(path, n, "duplicate merge of #{arg} into #{node.name}")}}

        not pattern?(arg) ->
          {:cont, {:ok, acc ++ [arg]}}

        true ->
          case expand(arg, branches) do
            [] -> {:halt, {:error, err(path, n, "pattern #{arg} in rule does not match any branch")}}
            list -> {:cont, {:ok, acc ++ Enum.reject(list, &(&1 in acc or &1 in node.merge))}}
          end
      end
    end)
  end

  @doc "A branch name is a pattern if it starts with `/` (regex) or contains `*` (glob)."
  def pattern?(name), do: String.starts_with?(name, "/") or String.contains?(name, "*")

  @doc """
  Expand a pattern over `branches`. A leading `/` is a regex; otherwise a glob
  where `**` crosses `/` and `*` does not.
  """
  def expand("/" <> regex, branches) do
    case Regex.compile(regex) do
      {:ok, re} -> Enum.filter(branches, &Regex.match?(re, &1))
      {:error, _} -> []
    end
  end

  def expand(glob, branches) do
    re =
      glob
      |> Regex.escape()
      |> String.replace("\\*\\*", ".*")
      |> String.replace("\\*", "[^/]*")

    case Regex.compile("^" <> re <> "$") do
      {:ok, re} -> Enum.filter(branches, &Regex.match?(re, &1))
      {:error, _} -> []
    end
  end

  defp halt_err(path, n, msg), do: {:halt, {:error, err(path, n, msg)}}
  defp err(path, n, msg), do: "#{path}:#{n}: #{msg}"
end
