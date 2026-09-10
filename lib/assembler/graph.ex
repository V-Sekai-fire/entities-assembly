defmodule Assembler.Graph do
  @moduledoc """
  Turns parsed rules into a dependency graph and orders it for execution.

  Two behaviours here are easy to miss and both come from git-assembler, which
  this replaces:

    * merging a node's own base into it is a no-op and is discarded, unless the
      node is a plain `base` type. Base switching is allowed for
      experimentation, so this warns rather than failing.

    * a branch named as a base or a merge dependency but never given a rule of
      its own still becomes a node, with no dependencies of its own.
  """

  alias Assembler.Config.Node

  @doc """
  Resolve names to nodes and compute each node's ordered dependencies: base
  first, then merges in the order written.

  Returns `{nodes, warnings}`; a discarded no-op merge produces a warning
  rather than being dropped silently, because a rule that vanished and a rule
  that applied look the same in the result.
  """
  def build(nodes) do
    nodes = Enum.reduce(nodes, nodes, &ensure_referenced/2)

    Enum.reduce(nodes, {%{}, []}, fn {name, node}, {acc, warns} ->
      {merge, warns} = filter_useless(node, warns)
      deps = if(node.base, do: [node.base], else: []) ++ merge
      {Map.put(acc, name, %{node | merge: merge}) |> put_deps(name, deps), warns}
    end)
    |> then(fn {acc, warns} -> {acc, Enum.reverse(warns)} end)
  end

  # a name used as a base or dep, but never defined by a rule, is still a node
  defp ensure_referenced({_name, node}, acc) do
    ([node.base] ++ node.merge)
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(acc, fn ref, a ->
      Map.put_new(a, ref, %Node{name: ref})
    end)
  end

  defp filter_useless(%Node{} = node, warns) do
    Enum.reduce(node.merge, {[], warns}, fn dep, {keep, w} ->
      if dep == node.base and node.type != :base do
        {keep, ["discarding useless merge of branch #{dep} into #{node.name}" | w]}
      else
        {keep ++ [dep], w}
      end
    end)
  end

  defp put_deps(acc, name, deps), do: Map.update!(acc, name, &Map.put(&1, :deps, deps))

  @doc """
  Depth-first post-order over `targets`, so every dependency precedes the node
  that needs it. `seen` makes a diamond appear once, and a cycle terminates
  instead of recursing forever.
  """
  def topo_sort(nodes, targets) do
    {order, _seen} =
      Enum.reduce(targets, {[], MapSet.new()}, fn name, {acc, seen} ->
        visit(name, nodes, acc, seen)
      end)

    Enum.reverse(order)
  end

  defp visit(name, nodes, acc, seen) do
    if MapSet.member?(seen, name) do
      {acc, seen}
    else
      seen = MapSet.put(seen, name)
      node = Map.get(nodes, name)
      deps = (node && Map.get(node, :deps, [])) || []

      {acc, seen} =
        Enum.reduce(deps, {acc, seen}, fn dep, {a, s} -> visit(dep, nodes, a, s) end)

      {[name | acc], seen}
    end
  end

  @doc "Targets to assemble: the CLI's, else the config's `target`, else every node."
  def targets(nodes, cli_targets, settings) do
    cond do
      cli_targets != [] -> cli_targets
      settings.target != [] -> settings.target
      true -> Map.keys(nodes)
    end
  end
end
