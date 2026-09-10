# Vendored third-party code

| file | upstream | licence |
| --- | --- | --- |
| `git-assembler` | [git-assembler](https://gitlab.com/wavexx/git-assembler) by wave++ "Yuri D'Elia" | GNU GPLv3+, text in `git-assembler.LICENSE` |

**`git-assembler` is not MIT.** The repository's `LICENSE` is MIT and does not
reach this directory. The file has been modified here, so GPLv3 section 5(a)
applies: the modifications and their dates are stated in its header, and section
4 requires the licence text to travel with it, which is why
`git-assembler.LICENSE` sits beside it.

What this constrains: distributing a binary or a bundle that contains this file
carries GPLv3 obligations for that distribution. `update_godot_v_sekai.exs`
invokes it as a separate program rather than importing it, which is the
arrangement that keeps the obligation on this directory instead of on the
assembler's Elixir code.

RFD 2243 records the replacement work that would retire it.
