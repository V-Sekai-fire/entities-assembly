#!/usr/bin/env elixir

argv = System.argv()

if Enum.any?(argv, &(&1 in ["-h", "--help"])) do
  IO.puts("""
  Usage: elixir #{__ENV__.file} [--help|-h] [--dry-run|--no-push|-n]

  --help, -h       Display help
  --dry-run, -n    Do not push.
  """)
  System.halt(0)
end

dry_run = Enum.any?(argv, &(&1 in ["-n", "--no-push", "--dry-run"]))

# HTTPS, not SSH. Everything else in this workspace authenticates to github.com
# with the v-sekai-fire-persona installation token through the git credential
# helper; the SSH path needs an agent holding a key, which CI runners do not have
# and which fails on a desk whose agent has dropped its keys. The failure mode was
# a 60-second stall then "Permission denied (publickey)" before any work started.
merge_remote = "v-sekai-fire"
# Named for where the engine actually lives. `v-sekai-multiplayer-fabric` is an archived org
# and `v-sekai-fabric` redirects; both resolved here, so every run was clone-through-redirect,
# which is somebody else's promise and not a name this repository should depend on.
merge_remote_url = "https://github.com/V-Sekai-fire/entities-godot.git"
# Feature branches come from merge_remote (entities-godot). The assembled tags go to
# publish_remote (entities-zone), which only has main until something publishes to it.
publish_remote = "entities-zone"
publish_remote_url = "https://github.com/V-Sekai-fire/entities-zone.git"
opentelemetry_remote = "opentelemetry-godot"
opentelemetry_remote_url = "https://github.com/V-Sekai-fire/opentelemetry-godot.git"
# Read from the assembly config's own stage line rather than duplicated here.
# The config was renamed multiplayer-fabric -> dev/fabric-0.1.0 and this constant
# was not, so cleanup deleted a branch that no longer existed and left the real
# assembled branch behind -- the exact stray-branch failure the comment further
# down warns about -- while the tag went out named after the old target.

# Absolute paths resolved before cd — the assembler and config live here, all git
# work happens in the disposable clone below.
#
# `GODOT_PATH` overrides, because a machine that keeps the tree elsewhere should
# not have to edit this file to say so.
script_dir = __ENV__.file |> Path.dirname() |> Path.expand()

# Assemble in a throwaway clone, never in a checkout somebody is working in.
# The steps below run `git stash --include-untracked`, `git checkout --force`
# and `git branch -D`; aiming those at the tree the goal manifest checks out is
# how uncommitted work disappears. This directory is gitignored.
work_root = Path.join(script_dir, ".assembly-work")

godot_path =
  case System.get_env("GODOT_PATH") do
    nil -> Path.join(work_root, "entities-godot")
    env -> Path.expand(env)
  end

assembler_config = Path.join(script_dir, "gitassembly")

# Every `stage` line is a release. A release whose base is another release is
# nested on it (`stage r1-see r0-base`), so releases are ordered base first --
# the same order `Assembler.Run.order/1` builds them in.
releases =
  case File.read(assembler_config) do
    {:ok, text} ->
      stages =
        text
        |> String.split("\n")
        |> Enum.flat_map(fn line ->
          case String.split(String.trim(line), ~r/\s+/) do
            ["stage", target, base | _] -> [{target, base}]
            _ -> []
          end
        end)

      if stages == [], do: raise("no `stage` line in #{assembler_config}; cannot tell which branch is assembled")

      names = MapSet.new(stages, &elem(&1, 0))

      Stream.unfold({stages, MapSet.new()}, fn
        {[], _done} ->
          nil

        {pending, done} ->
          case Enum.find(pending, fn {_t, base} -> not MapSet.member?(names, base) or MapSet.member?(done, base) end) do
            nil -> raise "stage cycle among #{inspect(Enum.map(pending, &elem(&1, 0)))}"
            {t, _} = ready -> {t, {List.delete(pending, ready), MapSet.put(done, t)}}
          end
      end)
      |> Enum.to_list()

    {:error, reason} ->
      raise "cannot read #{assembler_config}: #{inspect(reason)}"
  end

IO.puts("Releases, in build order: #{Enum.join(releases, " -> ")}")

unless File.dir?(Path.join(godot_path, ".git")) do
  File.mkdir_p!(Path.dirname(godot_path))
  IO.puts("Cloning #{merge_remote_url} into #{godot_path}")
  {output, code} = System.cmd("git", ["clone", merge_remote_url, godot_path], stderr_to_stdout: true)
  if output != "", do: IO.puts(output)
  if code != 0, do: raise("git clone failed (exit #{code}): #{output}")
end

# Windows git defaults core.autocrlf to true, which rewrites line endings under every
# merge and leaves an assembled tree that does not match the one assembled elsewhere.
System.cmd("git", ["-C", godot_path, "config", "core.autocrlf", "false"], stderr_to_stdout: true)

File.cd!(godot_path)

# Safety guard: abort if git thinks we are anywhere other than godot/.
{toplevel, 0} = System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: true)
if Path.expand(String.trim(toplevel)) != godot_path do
  IO.puts("Error: git root is #{String.trim(toplevel)}, expected #{godot_path}. Refusing to assemble outside godot/.")
  System.halt(1)
end

run! = fn cmd, args ->
  case System.cmd(cmd, args, stderr_to_stdout: true) do
    {output, 0} ->
      if output != "", do: IO.puts(output)
      output
    {output, code} ->
      IO.puts(output)
      raise "Command failed (exit #{code}): #{cmd} #{Enum.join(args, " ")}"
  end
end

add_remote = fn name, url ->
  System.cmd("git", ["remote", "add", name, url], stderr_to_stdout: true)
  System.cmd("git", ["remote", "set-url", name, url], stderr_to_stdout: true)
  run!.("git", ["fetch", name])
end

IO.puts("Checkout remotes")

add_remote.(merge_remote, merge_remote_url)
add_remote.(publish_remote, publish_remote_url)
add_remote.(opentelemetry_remote, opentelemetry_remote_url)

# The branch the clone landed on is the repository's default; that is the base
# the assembly starts from and the branch cleanup returns to.
original_branch =
  case System.cmd("git", ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], stderr_to_stdout: true) do
    {ref, 0} -> ref |> String.trim() |> String.replace_prefix("origin/", "")
    _ -> String.trim(run!.("git", ["rev-parse", "--abbrev-ref", "HEAD"]))
  end

IO.puts("Base branch: #{original_branch}")

current_branch = String.trim(run!.("git", ["rev-parse", "--abbrev-ref", "HEAD"]))

if current_branch != original_branch do
  IO.puts("Failed to run merge script: on #{current_branch}, expected the default branch #{original_branch}.")
  System.halt(1)
end

IO.puts("*** Working on assembling #{assembler_config}")

has_changes =
  case System.cmd("git", ["diff", "--quiet", "HEAD"], stderr_to_stdout: true) do
    {_, 0} -> false
    _ -> true
  end

# Always return to the base branch and drop the local assembly branch — on
# success, on a dry run, AND on failure. Order matters: you cannot delete the
# branch you are on, so check out `original_branch` FIRST, then delete
# every release branch. Both steps are non-fatal (System.cmd, not run!) so a half-built
# assembly still leaves the checkout clean and back on `original_branch` with no
# stray release branch left behind — that leftover branch was the root of the
# branch-state problems.
cleanup = fn ->
  System.cmd("git", ["checkout", original_branch, "--force"], stderr_to_stdout: true)
  Enum.each(releases, &System.cmd("git", ["branch", "-D", &1], stderr_to_stdout: true))
end

run!.("git", ["stash", "--include-untracked"])

try do
  run!.("git", ["checkout", original_branch, "--force"])
  Enum.each(releases, &System.cmd("git", ["branch", "-D", &1], stderr_to_stdout: true))
  # The assembler is `Assembler.Run` in this project, invoked through mix so the
  # script and the library are one implementation. It replaced a vendored GPLv3
  # program; RFD66606-2243 set the bar at a byte-identical tree, and the swap was
  # verified against it before the original was removed.
  # `run!` runs in the assembly checkout; mix has to run where mix.exs is.
  # One line, no newlines: on Windows mix is a .bat file and cmd.exe truncates an
  # argument at the first newline, so a multi-line expression arrived unterminated.
  assemble_cmd = [
    "run",
    "-e",
    ~s|case Assembler.Run.assemble("#{godot_path}", "#{assembler_config}") do | <>
      ~s|:ok -> :ok; {:error, why} -> IO.puts(:stderr, why); System.halt(1) end|
  ]

  case System.cmd("mix", assemble_cmd, cd: script_dir, stderr_to_stdout: true) do
    {out, 0} -> if out != "", do: IO.puts(out)
    {out, code} -> raise "assembly failed (exit #{code}): #{out}"
  end

  if not dry_run do
    # Record which gitassembly produced these tags: the merge order is not in
    # the commits, so without this a tag cannot be rebuilt.
    {assembly_sha, 0} = System.cmd("git", ["-C", script_dir, "rev-parse", "HEAD"])
    assembly_sha = String.trim(assembly_sha)

    {dirty, 0} = System.cmd("git", ["-C", script_dir, "status", "--porcelain", "--", "gitassembly", "lib"])
    if String.trim(dirty) != "", do: raise("gitassembly or lib/ has uncommitted changes; commit them so the tag can name them")

    # RFD66606-2312, once per release: the tag is computed from that release's
    # last commit (its branch tip, no extra commit on top), with that commit's
    # committer time in UTC. Release branches are local work names and are
    # never pushed; the pseudo-version tag is the published artifact, and
    # `stage/<release>` is the moving tag that names the build the release
    # holds. The prefix keeps it from colliding with the local branch name.
    Enum.each(releases, fn release ->
      {stamp, 0} =
        System.cmd("git", ["log", "-1", "--format=%cd %H", "--date=format-local:%Y%m%d%H%M%S", "refs/heads/#{release}"],
          env: [{"TZ", "UTC"}]
        )

      [time, sha] = String.split(String.trim(stamp), " ")
      tag_name = "v0.0.0-#{time}-#{String.slice(sha, 0, 12)}"

      run!.("git", ["tag", "-a", tag_name, "-m", "#{release} #{tag_name}\n\nentities-assembly: #{assembly_sha}", sha])
      run!.("git", ["push", publish_remote, "refs/tags/#{tag_name}"])
      run!.("git", ["tag", "-f", "stage/#{release}", sha])
      run!.("git", ["push", "--force", publish_remote, "refs/tags/stage/#{release}"])
      IO.puts("Pushed #{tag_name} and moved stage/#{release} to it.")
    end)
  else
    IO.puts("Dry run: would tag each release (#{Enum.join(releases, ", ")}) with a pseudo-version and move its stage tag (no push).")
  end
rescue
  e ->
    IO.puts("Merge failed: #{Exception.message(e)}")
    cleanup.()
    System.halt(1)
end

# Success / dry-run: clean up unconditionally so every run ends back on the base
# branch with no release branch lingering.
cleanup.()

IO.puts("ALL DONE. Cleaned up #{Enum.join(releases, ", ")}; back on #{original_branch}. ------")

if has_changes do
  IO.puts("""
  Note that uncommitted changes may have been stashed. Run
      git stash apply
  to re-apply them.
  """)
  run!.("git", ["stash", "list"])
end
