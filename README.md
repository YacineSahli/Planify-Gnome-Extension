# Planify Quick View — GNOME Shell panel extension

An unofficial GNOME Shell extension that puts [Planify](https://github.com/alainm23/planify)
in your top bar. Clicking the panel button opens a quick-view card — due-today
and overdue tasks, live from Planify — styled like a native GNOME
quick-settings card. Click a task to complete it, click outside or press
`Escape` to dismiss it (it animates back into its panel icon).

```
┌──────────────────────────────┐
│ Today                    [+] │
│ 5 open · 2 done today        │
│ ○ Restart learning Chinese…  │
│   ● Inbox          Overdue   │
│ ○ Help Cathy find job        │
│   ● Inbox             14:00  │
│ …                            │
│ ⬒ Open Planify               │
└──────────────────────────────┘
```

## Screenshots

Popup with Pinned / Overdue / Today sections (fixture data):

![Popup](docs/screenshots/screenshot-popup.png)

Fold-out description with copy button:

![Expanded](docs/screenshots/screenshot-expanded.png)

Settings window:

![Settings](docs/screenshots/screenshot-settings.png)

## Features

- Due-today and overdue tasks in the top bar, with a live open-task badge
  (`count`, `dot`, or hidden).
- Complete a task from the popup; an undo window (default 3 s) catches
  misclicks. Recurring tasks advance correctly because completion is
  delegated to the Planify app.
- Click a task title to fold out its description — selectable text with a
  copy button; click again to fold it back.
- Inline quick-add: type a title, press `Enter`, the task lands in Today.
- Global keybinding (off by default) to toggle the popup.

## How it works

- The extension runs inside `gnome-shell` (GJS) and renders the card with
  native `St` widgets — a GTK4 app window cannot be embedded in the shell,
  so data moves, not pixels.
- Tasks are read **directly and read-only** from Planify's SQLite database
  (`~/.var/app/io.github.alainm23.planify/data/.../database.db` for the
  Flatpak, `~/.local/share/io.github.alainm23.planify/` for native
  installs) via the `sqlite3` CLI in read-only mode. The extension never
  writes to the database.
- Completing a task is delegated to the Planify app over D-Bus
  (`org.freedesktop.Application.ActivateAction("complete", …)`), so
  recurring tasks advance and Todoist sync stays consistent. If Planify is
  not running, clicking a task opens it in the app instead.
- Live updates via a file monitor on the database plus a low-frequency
  poll (midnight rollover, missed events).

> **Roadmap:** talk to Planify over an in-app D-Bus API instead of reading
> the database file directly (see the discussion in
> [alainm23/planify#2718](https://github.com/alainm23/planify/pull/2718)).

## Install

```bash
git clone https://github.com/YacineSahli/Planify-Gnome-Extension.git
cd Planify-Gnome-Extension
./install.sh --enable     # install + enable; live on the next session start
./install.sh --uninstall  # fully remove
./build.sh                # build dist/planify-quick-view.zip for EGO upload
```

`install.sh` uses `gnome-extensions install` so a *running* shell registers
the files; the shell scans new extension directories only at session start,
so the panel button appears after your next login (this is standard GNOME
behavior for local zip installs — extensions.gnome.org installs are the
only ones that load instantly).

Requirements: GNOME Shell 50 (uses the 45+ ESM API; see
`src/metadata.json`), the `sqlite3` CLI, and Planify (Flatpak or native)
for data.

## Settings

Everything is configurable in the **Settings window** — click the panel
icon, then the gear row at the bottom of the popup (or `gnome-extensions
prefs planify-quick-view@yacinesahli.github.io`).

### Settings reference (gsettings)

Schema `org.gnome.shell.extensions.planify-quick-view`:

| Key | Default | Purpose |
|---|---|---|
| `database-path` | `""` | Override the Planify database path (testing) |
| `max-rows` | `12` | Rows shown before the list scrolls |
| `complete-delay-seconds` | `3` | Undo window after clicking a checkbox; click again to cancel. 0 = complete instantly |
| `animation-duration` | `0` | 0 = built-in (220 ms open / 160 ms close) |
| `debug-dbus` | `false` | Expose test D-Bus interface (see below) |
| `toggle-quick-view` | `[]` | Global keybinding to toggle the popup |
| `badge-mode` | `"count"` | Panel badge: `count`, `dot`, or `hidden` |

```bash
gsettings set org.gnome.shell.extensions.planify-quick-view \
  toggle-quick-view "['<Super><Shift>p']"
```

## Testing

```bash
./tests/e2e-nested.sh    # functional suite in an isolated headless shell
./tests/e2e-real.sh      # interactive suite for a graphical session
                         # (real clicks via ydotool, Escape, outside click)
```

The nested suite runs the extension in its own GNOME Shell with its own
D-Bus session and dconf, reads the real Planify database, and verifies the
full state machine and clean teardown. The real-session suite exercises
actual mouse/keyboard input on the real panel button.

`debug-dbus` exposes `io.github.yacinesahli.PlanifyQuickView` on the
session bus (`Toggle`, `Open`, `Close`, `Status`, `Capture`, `Repaint`) —
a test hook, off by default.

## Scope, known limitations

- **Read-only quick view**: completing tasks works through the app;
  editing/creating happens in Planify (the header **[+]** button opens
  Planify's quick-add window).
- Keyboard navigation between task rows (arrow keys) is not implemented
  yet; `Escape` and outside-click dismissal are handled by the shell.
- "Today" semantics replicate Planify's local-date comparison in SQL;
  recurring tasks are marked (↻) and completing them advances via the app.
- If Planify has never run, the card shows an empty state with an
  **Open Planify** shortcut.

## Credits & license

[Planify](https://github.com/alainm23/planify) is a to-do app by
[Alain M.](https://github.com/alainm23) — this extension is an independent
companion project and is not affiliated with or endorsed by Planify.

GPL-3.0-or-later, same as Planify. © 2026 Yacine Sahli.
