defmodule Assembler.ConfigTest do
  use ExUnit.Case, async: true

  alias Assembler.Config

  @branches ~w(main topic-a topic-b topic-c feat/one feat/two)

  defp fixture(kind, name), do: Path.join(["test/fixtures", kind, name])

  defp valid_names, do: File.ls!("test/fixtures/valid") |> Enum.sort()
  defp invalid_names, do: File.ls!("test/fixtures/invalid") |> Enum.sort()

  # The corpus is fixed and small, so it is enumerated rather than sampled:
  # a fixture nobody parses is a fixture that has stopped saying anything.
  test "every valid fixture parses" do
    assert valid_names() != [], "no valid fixtures; an empty corpus is not a pass"

    for name <- valid_names() do
      assert {:ok, nodes, _settings} = Config.parse(fixture("valid", name), @branches),
             "#{name} should parse"

      assert map_size(nodes) > 0, "#{name} parsed to no nodes"
    end
  end

  test "every invalid fixture is rejected, and says which line" do
    assert invalid_names() != [], "no invalid fixtures; the negative control is missing"

    for name <- invalid_names() do
      assert {:error, reason} = Config.parse(fixture("invalid", name), @branches),
             "#{name} should be rejected"

      assert reason =~ name, "#{name}: the error should name the file, got: #{reason}"
    end
  end

  test "a glob expands against the branch list" do
    {:ok, nodes, _} = Config.parse(fixture("valid", "02-wildcard-doublestar"), @branches)
    merges = nodes["main"].merge
    assert "feat/one" in merges and "feat/two" in merges
    refute "topic-b" in merges
  end

  test "a regex expands against the branch list" do
    {:ok, nodes, _} = Config.parse(fixture("valid", "03-regex"), @branches)
    assert Enum.sort(nodes["main"].merge) == ["topic-b", "topic-c"]
  end

  # Read against the file rather than a copy of it: the target name and the branch
  # list move every release, and a restated pair fails on the move rather than on a bug.
  test "the real gitassembly parses to one stage node" do
    lines = File.read!("gitassembly") |> String.split("
", trim: true)
    ["stage", target, base] = lines |> Enum.find(&String.starts_with?(&1, "stage ")) |> String.split()
    merged = Enum.count(lines, &String.starts_with?(&1, "merge "))

    assert {:ok, nodes, _} = Config.parse("gitassembly")
    assert [{name, node}] = Map.to_list(nodes)
    assert name == target
    assert node.type == :stage
    assert node.base == base
    assert length(node.merge) == merged
  end

  test "a comment character is data, not a comment" do
    path = Path.join(System.tmp_dir!(), "cfg-#{System.unique_integer([:positive])}")
    File.write!(path, "stage main#x topic-a\n")
    on_exit(fn -> File.rm(path) end)

    assert {:ok, nodes, _} = Config.parse(path, @branches)
    assert Map.has_key?(nodes, "main#x")
  end
end
