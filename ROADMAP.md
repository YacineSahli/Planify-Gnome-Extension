# Roadmap

Status: 2026-10-05, after a full code/packaging/tests/visual review.
**Direction decision (2026-10-05): the extension stops reading Planify's
SQLite database.** The primary track is now a proper D-Bus API provided
by the Planify app (see *Primary track* below). The SQLite backend stays
only as the temporary implementation until that API exists in a Planify
release; v0.2 hardening of it is deliberately minimal (fix what is wrong
today, invest nothing in its future).

Phases: **primary track** (D-Bus) runs in parallel with
**v0.2** correctness → **v0.3** polish → **v1.0** extensions.gnome.org.
Line references are to `src/extension.js` at the current HEAD.

## v0.2 — correctness & credibility (next)

1. **SQL bug: pinned CTE hygiene filters are dead** (`extension.js:109-113`).
   `… AND COALESCE(i.due,'') != '' OR (i.pinned = 1 AND i.checked = 0)` —
   `AND` binds tighter than `OR`, so the trailing OR lets **deleted,
   trashed, and archived-project pinned tasks** into the card. Rewrite the
   WHERE with explicit parentheses; consciously decide whether pinned
   tasks *without* a due date belong in the Pinned section (what the OR
   was reaching for) and comment it. Add a fixture-DB regression case.
   (Interim fix — the SQLite backend is being sunset; see Primary track.)
2. **Teardown: cancel undo timers.** `QuickViewMenu.destroy()`
   (`extension.js:1356-1363`) never drains `_pending` — an undo timer
   pending at disable time later fires a completion (D-Bus action or a
   fresh `flatpak run`) with no UI. Also cancel `_pending` when the
   `database-path` setting swaps stores (`extension.js:1432-1438`), or
   completions submit against the wrong database.
3. **Expand state after refresh.** `_clearRows()` never resets
   `_expandedRow` (`extension.js:1141-1146`); after a live refresh, the
   next row click can act on a destroyed actor. One line.
4. **Quick-add submit: keep one Enter path.** All four paths
   (`activate`, both `key-press-event` connects, the AddEntryItem vfunc)
   fire per press (`extension.js:1005-1031`) — that is why the 500 ms
   dedupe guard (`extension.js:974-977`) exists. Keep one canonical path,
   delete the other three, drop the guard and the stale "no reliable key
   signal" comment (introspection lies; connects work — see
   ROADMAP history / runtime verification).
5. **Failure diagnostics.** Missing `sqlite3`, schema drift, and a
   non-DB file at `database-path` all render as "Planify database not
   found" (`extension.js:260-267, 1122-1124`). Track a last-error string
   and surface it (card footer line + journal) so users can tell the
   causes apart.
6. **File monitor re-arm.** `rewatchIfStale()` only re-arms when the
   monitor is gone (`extension.js:223-237`); if Planify replaces
   `database.db` via rename, live updates silently degrade to the 120 s
   poll for the whole session.
7. **Post-disable safety.** An in-flight `requestComplete()` continues
   after `disable()` and takes the CLI branch
   (`extension.js:354-364, 381-388`). Bail out once disabled.
8. **Badge honesty above 100 tasks.** The badge shows `tasks.length`,
   capped by `MAX_QUERY_ROWS` (`extension.js:48, 1475`). Use a COUNT
   query or cap the label ("99+").
9. **Packaging metadata.** `metadata.json`: `url` must be this repo
   (EGO uses it as the extension homepage — it still points at the
   Planify app repo), and add `"version": 1` (EGO requires it).
10. **Docs & scripts.** README: app-closed click **completes via the
    Planify CLI**, it does not open the app (fix "How it works");
    completion goes through the app's D-Bus *action group* (not
    `ActivateAction`); list all 10 debug D-Bus methods (README, gschema
    description and prefs subtitle currently disagree); add python3/zip
    to Requirements. `install.sh`: check `python3`/`zip` before starting;
    uninstall should clean `enabled-extensions` and `dconf reset -f` the
    schema path; soften the "next login" message when the live shell
    already accepted the install.

## v0.3 — robustness, parity, polish

11. **Native-install parity.** Every app-closed write/launch path
    hardcodes `flatpak run` (`extension.js:381-388, 422-444, 456`) while
    reading supports native installs — complete/quick-add/Open are silent
    no-ops for .rpm/.deb/AUR users with the app closed. Reuse the
    `launchApp` DesktopAppInfo fallback pattern; add a `--` separator
    before quick-add content in the CLI argv.
12. **Capture hardening.** The `/tmp` guard is lexical only —
    `File.replace` follows symlinks and files are world-readable
    (`extension.js:1536-1543, 1624-1659`). Write into a private `0700`
    directory, `chmod 0600`, refuse symlinked targets. Document that
    `debug-dbus` is callable by any session-bus peer while enabled.
13. **Journal noise.** Quick-add logs raw task text per submit
    (`extension.js:978`) — drop or gate behind debug.
14. **Accessibility & keyboard.** Rows have no accessible names; Enter on
    a focused row can expand but never complete (no event coordinates,
    `extension.js:1187-1229`). Add a11y labels; decide on an explicit
    keyboard-complete affordance.
15. **Refresh efficiency.** Every refresh destroys and rebuilds all rows
    and resets scroll (`extension.js:1155-1184`). Compare a query hash
    and skip no-op rebuilds; preserve scroll position across rebuilds.
16. **Test suite portability & CI.** The nested suite requires the
    author's real Planify DB (`dbFound` fails anywhere else) — build the
    fixture-DB path via the existing `database-path` setting, assert
    pinned/overdue/priority/empty permutations. Replace fixed sleeps with
    poll-waits; `mktemp -d` workdirs (fixed `/tmp/pqv-*` collide);
    isolate `XDG_DATA_HOME` in the nested run (it currently installs into
    the real session); exercise undo, fold-out, badge modes and row click
    routing via the unused `RowDebug`/`ToggleExpand`/`DebugSubmit` hooks;
    label `visual-headless.sh` as a capture tool (it always exits 0).
    GitHub Actions is feasible without xvfb (headless shell + software GL
    + fixture DB).
17. **Visual polish pass** (from the design review of the three
    screenshots):
    - Kill the two-tone background banding in the card (nested
      translucent surfaces with mismatched shades) — one uniform surface.
    - Copy button: ~2.2:1 contrast and flush against the card edge —
      raise contrast, add padding, hover pill background.
    - Pin the checkbox to the title line; it drifts to block-center when
      expanded.
    - One leading color bar per row (priority/project) instead of two
      ambiguous 4 px slivers.
    - Resolve dead space: content-width card or full-width rows.
    - Anchor the popup consistently (right edge / centered under button).
    - Neutral section headers (keep red only for Overdue); caption
      contrast ≥ 4.5:1; footer divider; fix the panel-indicator icon
      sliver; decide symbolic vs full-color footer icons.
    - Settings window: size to content (huge empty area), recognizable
      tab icons, retake screenshots without focus rings / text selection /
      the puzzle-piece compositing artifact.

## Primary track — D-Bus API (the decision)

The extension must not be a database client. Planify owns the semantics
(schema, `due` JSON shape, today-view rules); exposing them over D-Bus
fixes the fragility, the maintainer's objection, and — via a headless
service mode — the stale-when-app-closed problem.

A. **Upstream ask (implemented — PR-ready).** `GetTasks() → JSON`
   (versioned document; due-date side of the Today view + `done_today`)
   and `TasksChanged` (debounced, incl. day rollover) on the app's
   existing `io.github.alainm23.planify` interface
   (`Services.DBusServer.vala`). Survived TWO adversarial review rounds
   (8 subagents total). Round 2: style conformance (DBusTasks casing,
   named debounce const, comment trims — density verdict: fits the
   codebase's 2026 layer), a second live bug — `Store.set_item_trash`
   emitted NO signal so trash never reached clients (fixed: emits
   `item_updated`), and the PR body now carries the full client-facing
   contract (ordering unspecified/client-side sort, due.date grammar,
   opaque project.color, priority encoding, evolution policy,
   TasksChanged semantics, NameOwnerChanged/offline note, session-bus
   privacy note). Platform deep-dive: no leaks, exact wire marshalling,
   JSON-string choice validated, GJS consumer verified live.
   THIRD round: CI-reproducibility green (fresh from-scratch build,
   mergeable, lint clean; CI never RUNS the core suite), blast-radius GO
   (all 21 item_updated listeners traced; one cosmetic P2 disclosed),
   maintainer simulation predicts approve; body cut ~40%.
   Fork branch `feat/dbus-api` (commit `60e6a70dd`): unit suite 20/20,
   live integration 19/19 (`tests/dbus-api-live.sh`). PR body:
   `docs/UPSTREAM_DBUS_PR.md` (gitignored); user opens the PR with
   `gh pr create --repo alainm23/planify --base main --head
   YacineSahli:feat/dbus-api --body-file docs/UPSTREAM_DBUS_PR.md`.
B. **Extension-side seam (while waiting).** Isolate all SQLite access
   behind one narrow backend object with the client-facing surface
   (`listTasks()`, `completeTask(id)`, `addTask(text)`, `changed`
   signal). The UI never touches the backend; the future D-Bus backend
   becomes a drop-in. No behavior change.
C. **D-Bus backend.** Once the API lands in a Planify release: swap the
   backend to a `Gio.DBusProxy`, keep SQLite only as an opt-in legacy
   fallback for older Planify versions, then remove it.
D. **Background service (the staleness fix).** Fold in the app's
   existing `--background` flag via a pref: spawn it at session start so
   the app (and its sync + reminders) stays alive, and the D-Bus API is
   always there. The uninstalled
   `data/io.github.alainm23.planify.service.in` upstream would make the
   app D-Bus-activatable — worth proposing as the follow-up upstream.
E. **Upstream bug reports to file** (independent of the extension):
   CLI-created tasks are never uploaded to Todoist (no offline-queue
   entry); `Services.DBusServer` declares `update_item` client-side but
   never implements it; Planify's SQLite layer sets neither WAL nor
   `busy_timeout` (concurrent writers can clobber sync cursors).

## v0.2 — correctness & credibility (next)

## Later / feature ideas (from earlier discussions, unprioritized)

- Overdue-only badge accent; "Tomorrow" preview section; project
  grouping/filter tabs; opt-in end-of-day recap notification; task
  editing from the popup (needs the Primary-track D-Bus API); systray/
  panel-menu variant experiment branch.

## Release track (v1.0)

23. **extensions.gnome.org submission**: version field, correct homepage
    URL, retaken screenshots, description disclosing the sqlite3 read,
    clipboard button and debug hook; review notes prepared.
24. **Shell-version scope**: keep `["50"]` until 46–49 are actually
    tested (ESM APIs are 45+, GioUnix fallback exists in code).
25. **i18n**: strings are `_()`-wrapped and `gettext-domain` is declared,
    but no po/ exists — either wire a po/ + POTFILES.in or drop the
    decorative domain.
26. Tag releases + `CHANGELOG.md`.

## Explicitly declined (user decisions — do not resurrect)

Keyboard navigation between rows · labels-as-chips · middle-click snooze ·
hover tooltip (fold-out descriptions cover it).
