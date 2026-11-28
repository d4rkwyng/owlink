# The daily-use pass

`Scripts/daily-use.sh` drives what a person does with Owlink all day and
times it, so usability bugs and slowdowns are found by a process and not
by hand. It is not part of CI, `Scripts/test.sh` or `Scripts/verify.sh`.

    Scripts/daily-use.sh [--no-build] [--runs N] [--cold N] [--out DIR] [--write-budgets [--metrics LIST]] [--flows-only] [APP]

`--flows-only` runs the self-test and the flows, no timings (about 30 s).

It builds the check build (`Scripts/bundle-app.sh`, never `--release`),
then runs everything in process through the DevChecks framework
(`CEDRIC_CHECK=…`): real NSEvents through NSApp, window snapshots with
`cacheDisplay`, works with the screen locked. There is no XCUITest: the
app is SwiftPM only, and UI testing needs Automation Mode, which we do not
turn on.

## What it runs

- `CEDRIC_CHECK=dailyuseselftest`: proves the known-bug markers' strict
  flip (below), the isolation rule, and the preview timing's endpoint (a
  heading that comes 400 ms late is timed at least 400 ms; one that never
  comes is no sample).
- `CEDRIC_CHECK=dailyuse` (Sources/CedricApp/DailyUseCheck.swift): writes
  a fixture tree in its temp folder (folder A: 20+ mixed files, a 5 MB
  .log, a 5 MB one-line file, a .pcap, a .gpx, a binary file, a subfolder;
  folder B elsewhere)
  and runs eight flows, snapshotting the window after every step as
  `NN-flow-step.png`:
  1. a file from outside the sidebar's folder opened through
     `application(_:open:)` and File › Open's path: the sidebar follows;
  2. 20 files clicked in the sidebar: the tab, title, text, no second tab,
     the selected row, binary and capture files held;
  3. Markdown preview on and off, twice: widths, no overlap, rendered;
     then a local link clicked in the preview (the preview's history
     entry is the linked file, not a new tab), a two-finger swipe back,
     and the preview bar's Back button (the history entry is the document
     again);
  4. File › Open Recent lists and opens the fixture files;
  5. switching folders B → A: root, rows, selection, sidebar width, tabs;
     then File › Up One Folder from A/sub (the root becomes A) and
     File › Go to Folder… with B's path typed in its sheet (the root
     becomes B). Main has neither command yet: they are looked up in the
     menus at run time, by action and title;
  6. every Settings pane: at most 700 pt tall, no control outside the
     window, no truncated single-line text, no overlapping controls;
     Settings › Cedric once per AI engine (its height depends on it);
  7. a 5 MB one-line file in long-line mode: Wrap ON, no row past the
     view and each row of the spaceless line fills the width; Wrap OFF
     scrolls horizontally;
  8. an untitled tab, typing `**bold**` on line 1, switches to Markdown
     at the next typing pause.
- Cold launches (`CEDRIC_LAUNCH_METRICS`'s `launch_ms`, out of process).
- `CEDRIC_CHECK=dailyuseperf` N times (default 5): `sidebar_md_ms`,
  `sidebar_log_ms`, `sidebar_switch_ms`, `preview_toggle_ms` (DailyUsePerf.swift).
  `preview_toggle_ms` runs from ⌥⌘P until the document's heading is in
  the page WebKit loaded, with a laid-out box, as read back from the page
  (asked every millisecond). Submitting the load is not the endpoint; a
  heading that has not come after 10 s fails the sample and the launch.
  Painting to the screen is not timed (a locked screen has no display
  refresh for WebKit to wait on).
- `CEDRIC_CHECK=dailyusebudget`: the metrics against
  `Scripts/daily-use-budgets.json`.

The app runs inactive (a background launch, often a locked screen), so
no window becomes key: after an open the check sends the front tab's
`windowDidBecomeKey` as the system would, and a sidebar click the
inactive outline drops is replayed as select-and-open (both noted in the
log). A divider drag is not taken by an inactive app's split view, so the
sidebar width is checked against its saved width, not after a drag.

Coverage gap, reported as a `SKIP` in every run: a live two-finger swipe
comes from the window server and is followed by AppKit's
`NSEvent.trackSwipeEvent`, which takes an active session and a trackpad.
The pass makes scroll-wheel events with gesture phases in process; such
events carry no window, so they are handed to the web view and pass by
the app's event monitors. The `preview-swipe-back` marker is therefore
only as good as that: when the swipe merges, drive its handler here as
`CEDRIC_CHECK=previewswipe` does, and swipe once by hand.

A main-thread watchdog fails the run (`check: FAIL hang in <step>`, a
`sample` of the process in `hang-sample.txt`) when the run loop has not
turned for 10 s.

## Known bugs

`knownBug(id:note:)` marks assertions that are expected to fail on main,
with `XCTExpectFailure(strict: true)` semantics: while they fail, the run
prints `check: KNOWN-BUG id (still open: …)` and passes; once everything
inside passes it prints `check: FAIL UNEXPECTED-PASS id` and fails until
the marker is removed. The rules are `DailyUseVerdict` in CedricCore,
unit-tested in `Tests/CedricCoreTests/DailyUseTests.swift`. Each marker's
comment names the branch that fixes it:

- `sidebar-follow`: fix/0.6.1-sidebar-speed
- `settings-cedric-tall`: fix/cedric-settings-compact (draft PR #26; stays known-bug on main)
- `longline-wrap`: fix/0.6.1-longline-wrap
- `md-detect`: fix/0.6.1-md-detect
- `open-folder-select`: File › Open Folder lists the folder that holds the
  selected tab's file but does not select that file (Open Enclosing Folder
  does, via `reveal:`). No fix branch yet.
- `folder-up`, `folder-goto`, `preview-swipe-back`: no Up One Folder, no
  Go to Folder…, no swipe back in the preview: feat/sidebar-folder-browsing

A marker holds only the assertion about the bug. What it depends on is
asserted plainly outside it, so a broken flow is a FAIL and not a "known
bug": the file opened, folder A listed immediately before each open from
outside it (each case sets that up itself, whatever the case before left),
the typed text arrived in the untitled tab, the long line was laid out,
the Settings pane was measured. `CEDRIC_DAILYUSE_FAULT=drop-typing` and
`=first-open-follows` break those inputs on purpose to prove it (the
first must end in a plain FAIL; the second must still pass its "folder A
is listed immediately before" assertion).

## Speed budgets

Each metric is the median of per-launch medians (the first sample of a
launch is a warm-up, printed but not counted). Its budget is the baseline
plus 30%, never under a floor and never over a cap (`DailyUseBudget`).
`--write-budgets` measures and writes new baselines; the file records the
date, host, per-run values and load. It replaces the file only with a
complete collection: every launch asked for (`--runs`, `--cold`), none
failed or skipped, none under heavy load; otherwise the file is left as
it was and the run fails. `--metrics preview_toggle_ms` (comma separated)
re-measures those metrics only and keeps the other entries; it does not
go with `--flows-only`.

Noise is not red. Under heavy load (1-minute load per core over 0.75) at
the start, the perf launch waits up to 3 minutes and then SKIPs. The
attribution rule for a metric over budget: the load counts only through
that metric's own samples. A perf launch's load (at its start or end)
marks the medians of that launch; a cold launch's load marks that launch.
Over budget is a SKIP when all of the metric's samples are from heavy
runs, or when its calm samples alone are within budget (the heavy runs
pushed the median over). Calm samples over budget on their own are a
FAIL, whatever the load was in other launches: a heavy cold launch does
not excuse a slow sidebar click measured on calm perf launches.

## Isolation

Every launch gets temporary session and undo folders (`cedric_isolate`),
no session restore or save, a temporary `CEDRIC_MODELS_DIR` (Settings ›
Cedric otherwise lists the real Application Support/Cedric/Models) and a
scratch `CEDRIC_AI_DEFAULTS` suite (the engine sweep writes the AI
settings), deleted at the end. The app runs as a copy of the check build
with the bundle id `net.mindtricks.cedric.dailyuse` (re-signed ad hoc), so
its defaults and recent-documents list are its own; both are removed at
the end. If the copy cannot be made, signed and read back, the runner
exits 1 and launches nothing: the check build itself (which has the
user's bundle id) is never run, and the checks refuse to run in it
(`check: FAIL isolation: …`). Each launch prints the bundle id, the app
path, the folders and the suite it runs with; the runner compares that
with what it set, and checks that `net.mindtricks.cedric`'s defaults and
recent-documents list did not change. It does not look inside
`~/Library/Application Support/Cedric`.

## Output

`~/Orchestrator/scratch/daily-use/YYYY-MM-DD/` (or `--out`): `summary.md`
(passes, known bugs, metrics against budgets, SKIPs, every FAIL line, the
runtime), the raw logs and `shots/`. Exit 1 on any FAIL. The summary and
the exit status are about that invocation's launches only: logs an
earlier run left in the same folder are not read.
