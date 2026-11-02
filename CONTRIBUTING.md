# Contributing

This repo assembles the multiplayer-fabric Godot fork from upstream
feature branches and pushes the result back to
`v-sekai-multiplayer-fabric/godot`. Three files do the work:

- `update_godot_v_sekai.exs` is the Elixir driver. It must be run
  from `main`, sets up the `v-sekai-multiplayer-fabric` and
  `opentelemetry-godot` remotes, invokes the assembler, and (unless
  `--dry-run` is passed) force-pushes the assembled
  `multiplayer-fabric-base` and `multiplayer-fabric` branches plus a
  release tag computed from the assembled commit (RFD66606-2312).
- `lib/assembler/` is this repository's own assembler. It replaced a vendored
  copy of git-assembler 1.5, which was GPLv3 and is gone; RFD66606-2243 set the bar
  at a byte-identical tree and the swap was verified against it.
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

## Dependencies

Elixir and a system `git` on the path, on Windows, Linux and macOS
alike. Every git operation, in the assembler and the driver, is a `git`
process (`System.cmd`): a failing git returns an exit code instead of
crashing the VM, and there is no native library to build. The cost is a
process spawn per call and parsing git's text output.

Set `core.autocrlf=false` in the assembly checkout. With the Windows git
default of `true`, checkout rewrites line endings under the merges and the
assembled tree stops matching the tree assembled anywhere else.

## How the assembler behaves

Running the assembler twice with the same inputs produces the same
tree; the only thing that changes between runs is the tag, because the
assembled commit carries the time it was made.
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

## Releases and tags

`gitassembly` holds five nested releases, one `stage` block each, in
the order RFD66606-2360 lists the beta's features:

```
r0-base   the monolithic engine and every branch not tied to a feature
r1-see    + see each other           (stage r1-see r0-base)
r2-hear   + hear each other          (stage r2-hear r1-see)
r3-wear   + draw and wear            (stage r3-wear r2-hear)
r4-party  + party and shopkeeper     (stage r4-party r3-wear)
```

A release whose base is another release is built on it, whatever the
file order (`Assembler.Run.order/1`); a cycle is refused. A conflict
fails the run and names the release it happened in.

No version is kept by hand. Release branches are local work names and
are never pushed. Each release is tagged from its own last commit, in
the form RFD66606-2312 sets for every release tag, with that commit's
committer time:

```
v0.0.0-<UTC committer time YYYYMMDDhhmmss>-<first 12 hex of the commit>
```

The tag message names the release and the `entities-assembly` commit
that produced it. `stage/<release>` is a moving tag pointing at the
release's latest build; promotion moves it, nothing is rebuilt. Every
earlier pseudo-version tag stays live for rollback.

Merges take the newest committer time among the release's base and
merged tips and the v-sekai-fire-persona bot identity, use `--no-ff`,
and run with rerere disabled, so the same inputs give the same hashes
on any machine.

The engine's Godot version is whatever `r0-base` stages on (currently
`main`). To pin a different upstream version, change that ref.
