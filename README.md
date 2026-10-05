# entities-assembly

The recipe and driver that assemble the multiplayer-fabric engine branch from feature branches and push it to `entities-godot`.

## What it is for

`gitassembly` names each feature branch and how it is merged. The Elixir driver runs this repository's own assembler over a disposable clone, then pushes the assembled branches and a tag. Keeping the merge order in a file makes it a decision that can be read and reviewed. [RFD 2243](https://github.com/V-Sekai-fire/manuals-weftspun/tree/main/rfd/2243-assembly-one-cycle-blockers) owns the assembly cycle.

## Build and run

```sh
pixi run mix deps.get
pixi run mix test
```

The tests assemble throwaway repositories. The driver, `update_godot_v_sekai.exs`, pushes to the engine repository; its `--help` names the dry run.

## Licence

MIT; see `LICENSE`.
