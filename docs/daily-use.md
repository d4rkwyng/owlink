# The daily-use pass

`Scripts/daily-use.sh` drives what a person does with Owlink all day and
times it, so usability bugs and slowdowns are found by a process and not
by hand. It is not part of CI, `Scripts/test.sh` or `Scripts/verify.sh`.

    Scripts/daily-use.sh [--no-build] [--runs N] [--cold N] [--out DIR] [--write-budgets] [APP]

It builds the check build (`Scripts/bundle-app.sh`, never `--release`),
then runs everything in process through the DevChecks framework
(`CEDRIC_CHECK=…`): real NSEvents through NSApp, window snapshots with
`cacheDisplay`, works with the screen locked. There is no XCUITest: the
app is SwiftPM only, and UI testing needs Automation Mode, which we do not
turn on.

## What it runs

- `CEDRIC_CHECK=dailyuseselftest`: proves the known-bug markers' strict
  flip (below).
- `CEDRIC_CHECK=dailyuse` (Sources/CedricApp/DailyUseCheck.swift): writes
  a fixture tree in its temp folder (folder A: 20+ mixed files, a 5 MB
  .log, a .pcap, a .gpx, a binary file, a subfolder; folder B elsewhere)
  and runs six flows, snapshotting the window after every step as
  `NN-flow-step.png`:
  1. a file from outside the sidebar's folder opened through
     `application(_:open:)` and File › Open's path: the sidebar follows;
  2. 20 files clicked in the sidebar: the tab, title, text, no second tab,
     the selected row, binary and capture files held;
  3. Markdown preview on and off, twice: widths, no overlap, rendered;
  4. File › Open Recent lists and opens the fixture files;
  5. switching folders B → A: root, rows, selection, sidebar width, tabs;
  6. every Settings pane: at most 700 pt tall, no control outside the
     window, no truncated single-line text, no overlapping controls.
- Cold launches (`CEDRIC_LAUNCH_METRICS`'s `launch_ms`, out of process).
- `CEDRIC_CHECK=dailyuseperf` N times (default 5): `sidebar_md_ms`,
  `sidebar_log_ms`, `sidebar_switch_ms`, `preview_toggle_ms` (DailyUsePerf.swift).
- `CEDRIC_CHECK=dailyusebudget`: the metrics against
  `Scripts/daily-use-budgets.json`.

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
- `settings-cedric-tall`: fix/cedric-settings-compact

## Speed budgets

Each metric is the median of per-launch medians (the first sample of a
launch is a warm-up, printed but not counted). Its budget is the baseline
plus 30%, never under a floor and never over a cap (`DailyUseBudget`).
`--write-budgets` measures and writes new baselines; the file records the
date, host, per-run values and load. Noise is not red: under heavy load
(1-minute load per core over 0.75) at the start, the perf launch waits up
to 3 minutes and then SKIPs; a metric over budget with heavy load at the
end is a SKIP, not a FAIL.

## Isolation

Every launch gets temporary session and undo folders (`cedric_isolate`)
and no session restore or save. The app runs as a copy of the check build
with the bundle id `net.mindtricks.cedric.dailyuse` (re-signed ad hoc), so
its defaults and recent-documents list are its own; both are removed at
the end. The runner checks that `net.mindtricks.cedric`'s defaults and
`~/Library/Application Support/Cedric` did not change.

## Output

`~/Orchestrator/scratch/daily-use/YYYY-MM-DD/` (or `--out`): `summary.md`
(passes, known bugs, metrics against budgets, SKIPs, every FAIL line, the
runtime), the raw logs and `shots/`. Exit 1 on any FAIL.
