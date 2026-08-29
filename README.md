# artemisa81.gtasks

A TUI-style Google Tasks panel for the Omarchy shell. Native Quickshell
rendering, so it follows every Omarchy theme, font, and spacing token
automatically.

## What you get

- Bar widget with your open-task count; click to open the panel.
- Fully keyboard-driven:
  - `j` / `k` or arrows — move the cursor, `g` / `G` — jump to top / bottom
  - `Enter` / `Space` — complete / reopen the selected task
  - `a` — add a task (title, notes, due date)
  - `e` — edit the selected task's title, notes and due date
  - `d` — delete the selected task (with confirmation)
  - `J` / `K` — move the task down / up within its list
  - `h` / `l` or `Left` / `Right` — switch task list
  - `/` — filter tasks by substring, `Esc` clears it
  - `r` — refresh from Google, `c` — clear completed, `?` — toggle hints
  - `q` / `Esc` — close the panel
- Fast: renders instantly from a local cache, syncs in the background,
  and applies edits optimistically (reverts on failure).
- Due dates carry a time of day, kept in the task's notes. The Google Tasks web
  UI and phone apps can put a real time on a task — that is what produces
  Google's notification — but they use Google's internal API. The public Tasks
  API (discovery revision 20260818) still says of `due`: "Only date information
  is recorded; the time portion of the timestamp is discarded when setting this
  field. It isn't possible to read or write the time that a task is scheduled
  for using the API." Tasks are not exposed through the Calendar API either, so
  there is no public route to it.

  So the panel carries the time itself, as a trailing `⏰ HH:MM` line in the
  task's notes. That round-trips through Google untouched, which means the time
  is legible on the web and on your phone, and it is split back out here so the
  editor shows a proper time field and the notes stay clean. Type it any way
  that reads as a clock — `0930`, `9:30`, `09:30`.

  **The alert is local.** Google will not notify you for a time it never
  received, so the plugin does it: a desktop notification when a timed, still
  open task comes due, clicking through to the panel. It only fires on this
  machine, and only for alerts less than an hour old — anything older is a
  moment the machine was not running for, and is recorded silently rather than
  arriving as a backlog of toasts at login. For a phone alert, set the time in
  the Google Tasks app instead; the panel will not disturb it.

- Every write is a `patch`, never an `update`. `tasks.update` is a PUT and
  clears any field left out of the body, including state this API cannot see —
  so completing a task with an update would destroy a reminder time set on the
  web. The one exception is clearing a due date, which patch cannot express
  (`due: null` is ignored), so that single case uses update deliberately.

## One-time setup

Google Tasks requires OAuth authorization. Run:

```
omarchy-launch-tui --app-id=org.omarchy.gtasks-setup bash ~/.config/omarchy/plugins/artemisa81.gtasks/setup.sh
```

or click "Sign in with Google" in the panel. The script creates a dedicated
`gws` CLI profile at `~/.config/gws-omarchy-tasks` with the
`https://www.googleapis.com/auth/tasks` scope, reusing an existing OAuth
client secret from the calendar plugin profile when present.

If your GCP project has never used Tasks, enable the API when prompted:
https://console.cloud.google.com/apis/library/tasks.googleapis.com

The panel also opens via IPC, e.g. bound to a key in Hyprland:

```
omarchy-shell artemisa81.gtasks toggle
```

Other methods on the same target: `open`, `close`, `refresh`, and `state`
(dumps the panel's internal state to `~/.cache/omarchy-gtasks/state.json`).

## Settings

Per-widget settings live in `~/.config/omarchy/shell.json` under the bar
layout entry (`panelWidth`, `showCompleted`, `autoRefreshSec`, `showHints`),
editable from the widget settings UI.

## Files

| Path | Purpose |
| --- | --- |
| `~/.config/gws-omarchy-tasks/` | OAuth credentials (created by setup) |
| `~/.cache/omarchy-gtasks/cache.json` | Last synced lists + tasks |
| `~/.cache/omarchy-gtasks/state.json` | Panel state, written by the `state` IPC call |

## Development

The panel is a `KeyboardPanel` (layer-shell), not a `PopupCard` (xdg-popup):
an xdg-popup only receives keys once a click has routed focus through its
parent surface, so a keyboard-driven panel summoned from IPC or a keybind
opens without focus and its focus grab clears immediately, closing it again.
`KeyboardPanel` primes layer-shell keyboard focus on every open.

Edits under `~/.config/omarchy/plugins/` are meant to hot-reload, but changes
here did not always take effect until `omarchy restart shell`. If a change
appears to do nothing, restart the shell before believing the code is wrong.

## Requirements

- `gws` on PATH (same CLI the tmn73.calendar plugin uses)
- A Google account; up to ~300 tasks per list are fetched per refresh
