# Repository Guidelines

## Project Overview

`tern-periscope` is a single [Tern](https://docs.stencil.so/tern/index.md) plugin written in Luau: a block that shows the
live subagents of an [omp](https://github.com/can1357/oh-my-pi) session and opens their transcripts. The repository root
**is** the plugin package (`plugin.toml` at the top), so `tern plugin install github.com/kenXengineering/tern-periscope`
installs it directly. Everything ships as **source**: no build step, no `package.json`. Tests (`tests/`) and CI
(`.github/`) are left out of release archives.

## Architecture & Data Flow

Two Luau VMs, declared in `plugin.toml` (`schema = 1`, `id = "periscope"`):

- **Host half** (`host.luau`, in the session daemon): `tern.block.define(id, { init, view, key, event, save, title })`.
  Blocks are panes whose state and view are Lua. Every handler has a **2 s budget**. Defines `list` (opens in the
  split layout by default; saved `layout = "list"` is honoured) and `transcript` (palette-hidden; opened by the
  window half). The session picker is drawn by the host in the `layer` region (`popup_of` / `layer_col`), not by Tern.
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
| `tests/run.sh` | Runs every automated test (see Testing & QA) |
| `tests/tern_stub.luau`, `tests/check.luau` | Fake `tern` global and the assertion harness for `tests/*_test.luau` |
| `tests/fixtures/` | Hand-written omp transcripts and golden digests (no real user data) |

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

# Tests (needs luau, sh and awk; gawk/mawk are used when installed)
sh tests/run.sh
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
  `STALE_MS` (45 min) is also stated in the README's Limits and asserted in `tests/agents_test.luau`: change all three.
- `with()`, `safe()` and `has()` are duplicated in `host.luau` and `lib/transcript.luau`; move shared ones to
  `lib/util.luau` rather than copying again.
- Tabs for indentation, double quotes, trailing commas, as in the existing files. No formatter config exists.

### Shell / awk (`scripts/`)
- POSIX `sh` only; the header lists every subcommand and the tools used (keep it truthful: `sh awk grep head ls wc tail
  date cut tr find`).
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
- **Never wrap the `layer` root's children in an extra role-carrying `col`** (the old `with_popup` did): the extra box
  added spacing that moved the break bar and header. `layer_col(kids, popup)` builds the layer once and the picker is
  a plain sibling (`popup_of`).
- **Buttons that change label must keep their width** (`periscope.layout` is fixed at 70px, and no active-state rule
  may change `font-weight`): the header buttons are right-aligned, so any width change shifts the buttons beside them.
- **`scroll-padding-top` (96px / 324px) must stay above the layer's height**: measured 82px (transcript header),
  242px (split picker + header), both copies of `header_block` carry the 2px `periscope.rule`. `.sf-layer` is capped at
  `max-height: 100%` and scrolls, so an open session picker (548px) cannot cut the header off on a short pane.

## Testing & QA

`sh tests/run.sh` runs every automated test and exits non-zero on a failure. It needs `luau`, `sh` and `awk`; `gawk`
and `mawk` are used too when installed.

| File | Covers |
| --- | --- |
| `tests/agents_test.luau` | `classify` (the README status table), `shown` + `STALE_MS`, the `scan.sh` output parsers, `bucket`, `sessions_root` env precedence |
| `tests/util_test.luau` | `parse_iso`, `duration`, `oneline`, `unescape`, `encode`/`decode`, path helpers, `scan()` |
| `tests/transcript_test.luau` | Records to entries, tail polling, keys, folds, output modes and the `PREVIEW_LINES` cut |
| `tests/awk_test.sh` | `scripts/agent.awk` on each `tests/fixtures/awk/*.jsonl` under every awk found; must equal the `.expected` beside it |
| `tests/scan_test.sh` | Every `scripts/scan.sh` subcommand on a session store built in a temp dir |

- The stock `luau` CLI gives each required module its own globals, so a test cannot set `tern`. `run.sh` copies `lib/`
  to a temp dir with `local tern = require("../tests/tern_stub").tern` on line 1 (line numbers stay right) and runs
  the tests from there. `tests/tern_stub.luau` fakes env, clock, `process.run`, timers, a JSON decoder and `ui` builders
  that return plain `{ k, p, c }` nodes; `tests/check.luau` has `test`, `eq`, `ok` and `done`.
- A new test is `tests/<name>_test.luau` (require `../lib/<module>`, end with `check.done()`) or `tests/<name>_test.sh`
  (run with `sh` from the repository root, POSIX only, ShellCheck clean).
- `host.luau` cannot be loaded without `tern.block`; move a pure rule into `lib/` to test it (as `agents.shown`).
- Test behaviour a user would notice (statuses, counts, text shown, boundaries), not wiring. Changing `agent.awk`'s
  output means updating the `.expected` files with it.

Rendering, CSS and the host/window routing need a real Tern: after the tests and static checks, smoke-run the changed
path and state in your PR or notes what you ran and what you could not run.

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
- Launched from a script or agent, `dev/tern-test` exits at once unless it has a terminal: run it with a pty, not
  with `&`. `dev/tern-test-ctl key l`, `key enter` and `tree` drive and measure it.
- `quit` closes the window but the test daemon (and its tabs and blocks) survives and piles up across runs. After a
  run: `dev/tern-test-ctl quit`, then `pkill -f "tern daemon --socket $HOME/.cache/tern-periscope-test/daemon.sock"`,
  then `rm -f ~/.cache/tern-periscope-test/daemon.state* ~/.cache/tern-periscope-test/*.sock`.
- Local lint tools: `luau-lsp` has no Homebrew formula; download the pinned release (`luau-lsp-macos.zip`, version in
  `ci.yml`). `brew install gawk mawk` for the awk fixture check (CI runs `awk`, `gawk` and `mawk`).

## CI & Releases

`.github/workflows/ci.yml` runs on pull requests, pushes to `main` and (as a reusable workflow) before every release:

| Job | Checks |
| --- | --- |
| `luau` | `luau-lsp analyze` (pinned release + SHA-256) against `.github/tern.d.luau`, a **pinned copy** of `tern plugin types DIR`: refresh it by hand when Tern updates |
| `manifest` | `.github/scripts/check-manifest.py`: `schema = 1`, semver `version`, referenced files exist, every `[[blocks]]` id is defined in `host.luau` |
| `shell` (Linux) | `sh -n` (dash) / `bash -n` and ShellCheck (warnings and up) on `scripts/scan.sh`, `dev/*`, `tests/*.sh` |
| `tests` (Linux, macOS) | `sh tests/run.sh` with a pinned `luau` CLI (release + SHA-256 per OS), plus `gawk` and `mawk` (Linux) / `gawk` (macOS); macOS covers BSD awk, `find`, `ls`, `touch` and bash-as-`sh` |

Actions are pinned by commit SHA; Dependabot keeps them current. Run the same checks locally with the commands under
Development Commands, plus `python3 .github/scripts/check-manifest.py`.

**Cut a release** (semver; prereleases like `0.2.0-rc1` are fine):

1. Set `version` in `plugin.toml` (e.g. `0.2.0` or `0.2.0-rc1`) and push it to `main`.
2. `git tag v0.2.0 && git push origin v0.2.0`.

`.github/workflows/release.yml` then runs CI, checks that the tag is semver, equals `v` + the `plugin.toml` version and is
on `main`, and builds `tern-periscope-<version>.tar.gz` / `.zip` with `git archive` (`.gitattributes` leaves out `.github`,
`dev`, `tests`, `AGENTS.md`) plus `SHA256SUMS`. It publishes a GitHub release with those files and a changelog of the commits
since the previous release (a final release compares with the last final release; a prerelease with the last tag).
A tag containing `-` is marked as a prerelease and never becomes "latest". A mismatched tag fails the workflow before
anything is published.

## Git Workflow

- Remote `origin` = `git@github.com:kenXengineering/tern-periscope.git`, default branch `main`. `main` is the live
  development version and may break; it accepts direct pushes from the owner. Larger features still go through a
  branch (`feat/<kebab>`, `fix/<kebab>`, `docs/<kebab>`) and a PR (`gh pr create --base main`). Stable installs use tags.
- Commit subjects: sentence-case imperative, no prefixes (`Add split view to the list block`).
- Before every commit run the CI checks locally and commit only if all pass: `luau-lsp analyze --platform=standard
  --definitions=@tern=.github/tern.d.luau host.luau window.luau lib/*.luau`, `sh -n`/`bash -n`/`dash -n` and
  `shellcheck -s sh -S warning scripts/scan.sh tests/*.sh`, `python3 .github/scripts/check-manifest.py`, and
  `sh tests/run.sh`.
- Keep the README (keys table, Limits) and this file in step with behaviour changes.
