# Contributing

This repo assembles the multiplayer-fabric Godot fork from upstream
feature branches and pushes the result back to
`v-sekai-multiplayer-fabric/godot`. Three files do the work:

- `update_godot_v_sekai.exs` is the Elixir driver. It must be run
  from `main`, sets up the `v-sekai-multiplayer-fabric` and
  `opentelemetry-godot` remotes, invokes the assembler, and (unless
  `--dry-run` is passed) force-pushes the assembled
  `multiplayer-fabric-base` and `multiplayer-fabric` branches plus a
  CalVer tag.
- `lib/assembler/` is this repository's own assembler. It replaced a vendored
  copy of git-assembler 1.5, which was GPLv3 and is gone; RFD 2243 set the bar
  at a byte-identical tree and the swap was verified against it.
  a single Python 3 file (GPLv3). It reads `gitassembly` and performs
  the actual branch stage/merge operations.
- `gitassembly` is the configuration. It lists upstream refs to
  assemble, one operation per line.

## Workflow

Iterate with `--dry-run` so the script doesn't push:

```
elixir update_godot_v_sekai.exs --dry-run
```

Publish a release (force-push plus tag) by dropping the flag:

```
elixir update_godot_v_sekai.exs
```

You can also invoke the assembler directly. This skips the Elixir
wrapper's remote setup, stash, and push, so both remotes must already
be fetched:

```
mix run -e 'Assembler.Run.assemble(System.get_env("GODOT_PATH"), "gitassembly")'
```

Uncommitted changes are stashed at the start of the run and reported
at the end.

## Windows

The egit NIF links libgit2, and `pixi.toml` declares what that needs:
libgit2 itself, pkg-config, and `vs2022_win-64`, which points the build at
an installed Visual Studio 2022. So every command above runs under `pixi run` on Windows:

```
pixi run mix test
pixi run elixir update_godot_v_sekai.exs --dry-run
```

Outside the pixi environment the NIF's Makefile finds no libgit2 and says
so rather than linking something else. Nothing here is Windows-only at
runtime; the same `pixi run` prefix works on Linux and macOS.

Set `core.autocrlf=false` in the assembly checkout. With the Windows git
default of `true`, checkout rewrites line endings under the merges and the
assembled tree stops matching the tree assembled anywhere else.

## How the assembler behaves

Running the assembler twice with the same inputs produces the same
tree; the only thing that changes between runs is the timestamped tag.
If a step turns out to be non-deterministic, fix it before merging
rather than working around it.

Branch lists belong in `gitassembly`, not in the Elixir or Python
source. Adding a new upstream means adding a `merge` line, not
editing the wrapper.

`--dry-run` only suppresses the push and tag steps. The wrapper still
stashes, force-checks out `main`, deletes the local
`multiplayer-fabric-base` and `multiplayer-fabric` branches, and
recreates them via `--recreate`. Do not pass `--dry-run` expecting
nothing to happen locally.

Conflict resolution is plain `git merge`. `gitassembly` declares no
`ours`/`theirs`/custom merge drivers, and the assembler does not
support cherry-picking, so a conflict fails the run and the fix
belongs on the source branch.

Neither script should exit non-zero silently. In the Elixir wrapper
the `run!` helper raises with the failing command and exit code; in
the assembler, errors go through `logging.error`.

## Updating the vendored assembler

`lib/assembler/` is ours, MIT like the rest of this repository. Nothing
a directory. Its version lives in `APP_VER` inside the script
(currently `1.5`). To update: replace the file with a newer upstream
copy, adjust `APP_VER` to match, and verify the CLI flags the Elixir
wrapper depends on (`-av`, `--recreate`, `--config`) still exist.

## Tag format

The release tag is built from the current UTC time and the current
stage label:

```
v<YYYY.MM.DD.HHMM>-main-fabric-<X.Y.Z>
```

The `X.Y.Z` half is hand-maintained on the `stage` line of
`gitassembly` — the assembler reads it there, prepends the UTC
timestamp, and pushes both the branch and the tag. There is no
automated bump rule; a coordinator advances the label when they cut
a new assembled generation, and the previous label's branch and tag
stay live for rollback.

There is no Godot version string read from `.env` or the command
line. The assembled tree's Godot version is whatever the first
`stage` line in `gitassembly` points at as its base (currently
`feat/ci-ar-response-file`). To pin a different upstream version,
change that ref.
