# tern-periscope

Peek into your [omp](https://github.com/can1357/oh-my-pi) subagents from a [Tern](https://docs.stencil.so/tern/index.md) block.

Periscope lists the subagents of the omp session running in a directory, with live status, tool and request counts,
cost and running time, and opens any one's transcript as it is written: in the same block, in a block below, or in a
split view with a three-row picker over one transcript. Nothing needs to be installed on the omp side; it reads omp's
own session files.

## Install

```sh
tern plugin install github.com/kenXengineering/tern-periscope
```

> **`main` is the development version.** It is live: commits land on it directly and it may break from time to time.
> For a stable install, use a tagged release (see [Releases](https://github.com/kenXengineering/tern-periscope/releases)):
>
> ```sh
> git clone --branch <tag> --depth 1 https://github.com/kenXengineering/tern-periscope /tmp/tern-periscope
> tern plugin install /tmp/tern-periscope
> ```
>
> Each release carries `tern-periscope-<version>.tar.gz` / `.zip` and `SHA256SUMS`; versions are semver and prereleases
> look like `v0.2.0-rc1`.

Update with `tern plugin install github.com/kenXengineering/tern-periscope --force`; remove with
`tern plugin remove periscope`. To work on a checkout instead, use `tern plugin link /path/to/tern-periscope`
(Tern reloads it on save).

Then press `⌃⌥P`, or open the command palette and run **New Periscope block** (it opens in the split view)
from the pane where omp runs. The block takes that pane's directory. With `⌃⌥P`, when a pane in the same tab runs
omp, Periscope takes that pane's directory and shows that pane's omp session: it matches the session title omp puts in
the terminal title. The palette command has no tab context and shows the directory's newest session. If no pane matches,
the newest session shows too; `s` / `S` or the picker choose another.

Requires Tern with plugin support, omp, and on the machine running the Tern daemon a POSIX `sh` plus `awk`, `grep`,
`head`, `ls`, `wc`, `tail`, `date`, `cut`, `tr` and `find` (macOS, Linux).

## Use

| Input | In the list | In a transcript |
| --- | --- | --- |
| `⌃⌥P` (anywhere) | Open a Periscope list beside the focused pane, in its directory | — |
| Click a row, `Enter` | Open the transcript in place (in this block) | — |
| `⌘`-click (or `⌃`-click), `⌘Enter`, `o` | Open the transcript in a new block **below** this one | — |
| `↑` `↓` / `j` `k` | Move the selection (the first row is selected by default) | Scroll: move the cursor entry |
| `←` `→` | — | Previous / next agent (also in the split view) |
| Click a filter button, `f` | Filter: **All**, **Running**, **Error** (`failed`, `aborted`), **Finished** (`idle`, `parked`); `f` cycles | — |
| `Esc` | — | Back to the list |
| `Space` | Open the transcript | Fold or unfold the tool or long Response (over 12 lines) under the cursor; clicking its head does the same |
| `c` / `e` | — | Tool output **Collapsed** / **Expanded**; press again to return to Preview |
| `G` / `g` | — | Follow the newest entry (the view then tracks new output) / jump to the top. Following is off until you press `G`, or move down onto the last entry; moving up turns it off. A transcript lands on its newest entry when first shown, then stays put as it grows |
| `p`, `r` | — | Load earlier history / reload |
| `s` / `S` | Switch to the next / previous omp session of this directory (wraps around) | Same (leaves the transcript) |
| **Sessions** button | Open the session picker (see below) | — |
| `l` (or `v`) | Switch to the **split view** | Toggle back to the list (in the split view) |

A transcript opened below is a `periscope.transcript` block with the same keys (`Esc` does nothing there). The
filter is saved with the block.

Each list entry is one line at fixed columns: status glyph, name, mode (the agent definition, e.g. `task`), model,
tools, requests, tokens, cost and running time. The agent's short task description is in the transcript header.

Every transcript starts with a pinned header: `← Periscope` (back), the agent name, status, request count, cost and
running time, then three output buttons, with the task description on a line below. The buttons are **Preview**
(first 3 source lines of each tool output, the default; long lines still wrap), **Collapsed** (hidden) and
**Expanded** (full). They apply to bash/shell and every other tool result; folding a single tool with `Space` or a
click still overrides the mode for that tool.

Tool output is drawn with the richest Tern node that fits, in the Tern theme's colors: a unified diff as a diff, JSON
as a collapsible tree, a `read` of a known file type (`.go`, `.ts`, `.md`, …) as highlighted code with line numbers,
anything else (including bash) as ANSI text, so colors the command emitted show. Thoughts are Markdown, in italics.

Each agent's view is remembered while the block lives: switching to another agent and back keeps its output mode,
its folds and its cursor entry, and scrolls back to that entry. Only the cursor entry is restored, not the exact
scroll offset: Luau cannot read how far the pane is scrolled, so scrolling with the wheel alone is not remembered
(moving the cursor, `g`/`G`, page keys or clicking an entry is).

### Split view

`l` (or `v`, or the **Split view** button) shows a picker on top and one
transcript below, all in the same block, so you never switch back and forth or close blocks. The picker is three
rows tall and scrolls; an accent bar separates it from the transcript header. Click a row, or press `←` `→`, and the
transcript below follows; `↑` `↓` / `j` `k` scroll it. In the split view `f` filters, `o` / `⌘Enter` open the selected agent in
a block below, `c` `e` `Space` `g` `G` `p` `r` act on the transcript, and `l` / `v` / `Esc` / the **List view** button
return to the list. The layout is saved with the block.

### Session picker

The **Sessions N** button (list and split headers) opens a popup over the top of the block with a scrollable list of
the directory's omp sessions (newest first, up to 50): title, and how many subagents each has. Click one to show it;
**Close** or `Esc` dismisses the popup. **Hide sessions without subagents** removes sessions with no subagents from
the picker, from `s` / `S` and from the newest-session default. The option is saved with the block.

A session with running subagents shows `● N running` next to its agent count.

## How it works

- omp keeps one transcript per subagent at
  `~/.omp/agent/sessions/<cwd bucket>/<session>/<AgentName>.jsonl` (`PI_CODING_AGENT_SESSION_DIR`,
  `PI_CODING_AGENT_DIR` and `PI_CONFIG_DIR` are honoured). The block picks the newest session of its directory
  (`s` / `S` or the picker pin another).
- `scripts/scan.sh` + `scripts/agent.awk` (run through `tern.process.run`, off the Luau worker) report file sizes
  and digest only the changed transcripts: tool/request counts, cost, the last context size and the last few
  entries. Unchanged transcripts cost one `wc -c`.
- Status comes from the newest significant entry:

  | Last entry | Status |
  | --- | --- |
  | `tool_execution_start`, a tool result, a user message, or an assistant turn ending in `toolUse` | `running` (with the tool in flight) |
  | assistant turn ending `stop` | `idle` (finished its turn; may still be messaged) |
  | assistant turn ending `error` / `aborted` | `failed` / `aborted` |
  | `session_exit` (`normal` / `signal`) | `parked` / `aborted` |

- Tern plugins run as two Luau halves. `host.luau` (in the session daemon) defines the blocks; `window.luau` (per
  window) is the only half that can place panes. `⌘`-click, `o` and `⌘Enter` therefore go host → window: the host
  opens `tern-periscope://transcript?path=…`, and `window.luau` claims that URL in `tern.route.link` and splits the
  originating pane downward with a `periscope.transcript` block.
- The list header, the split-view picker and the transcript header are drawn in Tern's `layer` region so they stay
  put while the transcript scrolls; `main` starts with an invisible copy that reserves the same height.

## Limits

- A status is inferred from files. A hard-killed omp (no `session_exit`) keeps showing `running` until the
  transcript has been silent for 45 minutes (`STALE_MS` in `lib/agents.luau`), then reads as `idle`.
- Tool calls that wait quietly (`wait`, long builds) look the same as a hung agent until they finish.
- The picker's `● N running` count is cheaper and coarser than the list's status: it counts a session's subagent
  transcripts written in the last 45 minutes (`STALE_MS`) that do not end in `session_exit`. An agent that finished
  its turn but was not disposed still counts. Refreshes with the session list (every ~6 ticks).
- The block follows the directory of the pane it was opened from. Two omp sessions in one directory are both
  listed in the picker; the one written last is shown first.
- Running times in the list refresh about every 1.5 s with the list's own refresh; they do not tick live.
- The header of a standalone transcript block shows its label, path and the output buttons only; request count,
  cost and running time exist only in the list's drill-down and the split view.
- Untested: `cx:open` reaches every window showing the session, so opening below with two windows attached may
  open the transcript block twice.
- Transcripts are tailed (400 lines, `p` loads 400 more) and at most the newest 160 entries are drawn.
- Only the layout of the list is tuned for a pane about 600 px wide; in a much narrower pane the name and model
  columns are cut with an ellipsis.

## Development

See [AGENTS.md](AGENTS.md) for the layout, conventions and how to smoke-test in an isolated Tern instance
(`dev/tern-test`). There is no build step and no automated test suite.

## License

[MIT](LICENSE)
