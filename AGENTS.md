# Repository Guidelines

## Project Overview

`tern-periscope` is a single [Tern](https://docs.stencil.so/tern/index.md) plugin written in Luau: a block that shows the
live subagents of an [omp](https://github.com/can1357/oh-my-pi) session and opens their transcripts. The repository root
**is** the plugin package (`plugin.toml` at the top), so `tern plugin install github.com/kenXengineering/tern-periscope`
installs it directly. Everything ships as **source**: no build step, no `package.json`, no automated tests, no CI.

## Architecture & Data Flow

Two Luau VMs, declared in `plugin.toml` (`schema = 1`, `id = "periscope"`):

- **Host half** (`host.luau`, in the session daemon): `tern.block.define(id, { init, view, key, event, save, title })`.
  Blocks are panes whose state and view are Lua. Every handler has a **2 s budget**. Defines `list` (opens in the
  split layout by default; saved `layout = "list"` is honoured) and `transcript` (palette-hidden; opened by the
  window half). The session picker popup is drawn by the host in the `layer` region (`with_popup`), not by Tern.
- **Window half** (`window.luau`, one per Tern window): the `ctrl+alt+p` command and the `tern.route.link` claim for
  `tern-periscope://transcript?path=…&label=…`. Only this half can place panes (`cx.layout:split`). The command also
  picks the tab's omp pane (private-use glyph in its title) and passes its cwd and title as block args; the host matches
  the title to a session (`agents.title_key`) while nothing is pinned.
- **Host → window** goes through `cx:open("tern-periscope://…")` (producer `open_below` in `host.luau`, consumer
  `window.luau`, query encoding in `lib/util.luau`).
- **Filesystem and process access**: Luau has no `stat`/seek. All reads go through `lib/util.luau` `scan()` →
  `tern.process.run({"sh", "scripts/scan.sh", …})`, which runs off the worker. Output is tab-separated text parsed in
  Luau.
- **Data flow**: omp's per-subagent transcripts (`~/.omp/agent/sessions/<cwd bucket>/<session>/<Agent>.jsonl`) →
  `scan.sh` + `agent.awk` digest only changed files → `lib/agents.luau` `classify()` → `host.luau` builds the rows →
  `lib/transcript.luau` tails and renders one transcript.
- **Views**: `list_view` (one line per agent), `transcript_view` (drill-down in the same block), `split_view` (picker
  over one transcript). Headers and the picker are drawn in the `layer` region; `main` carries an invisible `spacer`
  copy that reserves the same height (see Tern gotchas).

## Key Directories & Files

| Path | Purpose |
| --- | --- |
| `plugin.toml` | Manifest: `host`, `window`, `styles = ["periscope.css"]`, `[[blocks]]` (`list`, `transcript`) |
| `host.luau` | Block definitions, list/split/transcript views, key and event handlers, the refresh loop |
| `window.luau` | `ctrl+alt+p` command; `tern-periscope://` route that splits a pane |
| `lib/agents.luau` | Session discovery, digest parsing, status rules (`classify`, `STALE_MS`) |
| `lib/transcript.luau` | Transcript viewer: tailing, entries, folding, output modes, `reveal`, header buttons |
| `lib/util.luau` | `scan()`, URL encode/decode, durations, ISO time parsing |
| `scripts/scan.sh`, `scripts/agent.awk` | Read-only probes of omp's session store |
| `periscope.css` | Plugin stylesheet; selectors are scoped by `[data-surface^='plugin.periscope.']` |
| `dev/tern-test`, `dev/tern-test-ctl` | Launch and drive an isolated Tern instance for smoke tests |

## Development Commands

Only commands that exist and were observed.

```sh
# Use the checkout in place (reloads on save), inspect, force a reload
tern plugin link .
tern plugin list            # "ready" = loaded; without a daemon it only means the manifest parsed
tern plugin reload          # exit 1 on a failed plugin; a bad stylesheet is logged as a WARN, not a failure
tern plugin types /tmp/x    # writes tern.d.luau for luau-lsp (keep it OUTSIDE the repo)

# Static checks (luau-lsp is not installed by the repo; download a release binary)
luau-lsp analyze --platform=standard --definitions=@tern=/tmp/x/tern.d.luau \
  host.luau window.luau lib/*.luau
sh -n scripts/scan.sh
```

## Code Conventions & Common Patterns

### Luau
- Every file starts `--!strict`, then a header comment on the module's role. Section banners (`-----`) split `host.luau`.
- Model state as an `export type …State` with trailing field comments; mutate in handlers, return, let `view` re-render.
  `view` must be pure.
- **Keyed nodes**: give list items `key` (stable ids) so scroll and fold state survive reorders.
- **Background work** is a `tern.timer` loop guarded by `running(cx.pane)` (checked before launching, in callbacks, and
  before rescheduling); keep a `stopped` flag before `cx:exit`.
- **Untyped JSON**: `pcall(tern.json.decode, line)`, then `type(x) == "…"` checks. Filter by line prefix *before*
  decoding large lines.
- **Clocks**: `scan.sh` reports `now <epoch>`; `wall()` = scan time + `tern.now()` delta. Luau does not know wall time.
- Round-trip costs: chunk argv at 40 names; join parallel `scan` calls with a `pending` counter.
- Tunables are named constants (`TICK_MS`, `REFRESH_EVERY`, `TAIL_LINES`, `PREVIEW_LINES`, `STALE_MS`, …).
  `STALE_MS` (45 min) is also stated in the README's Limits: change both.
- `with()`, `safe()` and `has()` are duplicated in `host.luau` and `lib/transcript.luau`; move shared ones to
  `lib/util.luau` rather than copying again.
- Tabs for indentation, double quotes, trailing commas, as in the existing files. No formatter config exists.

### Shell / awk (`scripts/`)
- POSIX `sh` only; the header lists every subcommand and the tools used (keep it truthful: `sh awk grep head ls wc tail
  date cut tr`).
- Output is tab-separated records, `@@<TAB>name` frames per item. Read-only; never write files.
- In awk, a regex literal passed as a function argument means `$0 ~ /re/` (a 0/1). Pass strings, or use `index`/`substr`.

### Tern gotchas learned the hard way
- **`main` is virtualized**: rows scrolled out of view are unmounted, so `position: sticky` cannot pin a header. The
  header lives in the `layer` region and `main` starts with an invisible `periscope.spacer` copy of it. Both copies
  must be built from the same function (`header_block`/`framed` in `host.luau`) or the heights drift.
- **Tern's `agent` element ignores grid placement** (`grid-area`, `grid-row`, `grid-column` had no effect on its
  children), so the list draws its own nine cells per row (always all nine, blank when empty) and lets plain grid
  auto-placement keep the columns aligned.
- **The `tool` element's `preview = { lines = N }` clamp measures lazily** and left visible outputs unclamped, so
  `lib/transcript.luau` cuts tool output to `PREVIEW_LINES` itself and passes an oversized `preview` so Tern's clamp
  never applies.
- **Unknown CSS properties are dropped with a WARN** (`plugin style sheet has errors`), e.g. `scroll-margin-top`.
  After editing `periscope.css`, run `tern plugin reload` and read the daemon log.
- **Keyboard scrolling**: `cx:frame({ { "reveal", id, "nearest" | "start" | "end" } })` scrolls a node into view; ids
  are `main.entries.<key>` / `layer.picker.rows.a_<name>`. Reveal a beat after a render (`tern.timer(60, …)`) so the
  nodes exist. Luau cannot read the scroll offset, so the viewer remembers the cursor entry, not pixels.
- `ui.node("agent")`'s `stats.age`/`took` tick live in the client; our own rows only refresh with the list refresh.

## Testing & QA

No automated tests exist; do not add test scaffolding for wiring. Verification is a smoke run of the changed path plus
the static checks above. State in your PR or notes what you ran and what you could not run.

**Isolated smoke test** (never touches your real Tern config or plugins):

```sh
dev/tern-test ~/code/some-dir-with-omp-sessions &      # own config dir, daemon and control socket; links this checkout
dev/tern-test-ctl key ctrl+alt+p                       # open a list beside the shell pane
dev/tern-test-ctl click 800 125                        # click a row (X Y are screen px); add `cmd` to ⌘-click
dev/tern-test-ctl shot NAME                            # PNG under $TERN_TEST_DIR/run/target/shots/tern/live/
dev/tern-test-ctl tree "[data-role='periscope.row']"   # query nodes: rects, classes, text
dev/tern-test-ctl quit
```

- `tern serve` (headless) does **not** load window halves; use the real instance above to test routes and splits.
- `dev/tern-test` pre-answers Tern's "manage omp?" first-run offer with "no" so no popup appears.
- `tern ctl run` takes **one** argument (quote the command line or put it in a script).
- Needs real omp sessions for the directory you open (`~/.omp/agent/sessions/…`).

## CI & Releases

`.github/workflows/ci.yml` runs on pull requests, pushes to `main` and (as a reusable workflow) before every release:

| Job | Checks |
| --- | --- |
| `luau` | `luau-lsp analyze` (pinned release + SHA-256) against `.github/tern.d.luau`, a **pinned copy** of `tern plugin types DIR`: refresh it by hand when Tern updates |
| `manifest` | `.github/scripts/check-manifest.py`: `schema = 1`, semver `version`, referenced files exist, every `[[blocks]]` id is defined in `host.luau` |
| `shell` (Linux, macOS) | `sh -n` / `bash -n` / `dash -n`; ShellCheck (Linux, warnings and up) |
| `awk` (Linux, macOS) | `scripts/agent.awk` on `.github/fixtures/agent.jsonl` under `awk`, `gawk`, `mawk` must equal `agent.expected` (change both together) |
| `tests` (Linux, macOS) | `tests/run.sh`, once it exists (issue #1) |

Actions are pinned by commit SHA; Dependabot keeps them current. Run the same checks locally with the commands under
Development Commands, plus `python3 .github/scripts/check-manifest.py`.

**Cut a release** (semver; prereleases like `0.2.0-rc1` are fine):

1. Set `version` in `plugin.toml` (e.g. `0.2.0` or `0.2.0-rc1`) and push it to `main`.
2. `git tag v0.2.0 && git push origin v0.2.0`.

`.github/workflows/release.yml` then runs CI, checks that the tag is semver, equals `v` + the `plugin.toml` version and is
on `main`, and builds `tern-periscope-<version>.tar.gz` / `.zip` with `git archive` (`.gitattributes` leaves out `.github`,
`dev`, `AGENTS.md`) plus `SHA256SUMS`. It publishes a GitHub release with those files and a changelog of the commits
since the previous release (a final release compares with the last final release; a prerelease with the last tag).
A tag containing `-` is marked as a prerelease and never becomes "latest". A mismatched tag fails the workflow before
anything is published.

## Git Workflow

- Remote `origin` = `git@github.com:kenXengineering/tern-periscope.git`, default branch `main`. `main` is the live
  development version and may break; it accepts direct pushes from the owner. Larger features still go through a
  branch (`feat/<kebab>`, `fix/<kebab>`, `docs/<kebab>`) and a PR (`gh pr create --base main`). Stable installs use tags.
- Commit subjects: sentence-case imperative, no prefixes (`Add split view to the list block`).
- Keep the README (keys table, Limits) and this file in step with behaviour changes.
