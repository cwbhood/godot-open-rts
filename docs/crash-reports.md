# Crash reports

`source/crash/CrashReporter.gd` (an autoload) writes a report to `user://crash_reports/`
when the game crashes, freezes for 20 s or more, or logs 100 errors within 10 s. On Windows
that folder is `%APPDATA%\Godot\app_userdata\Open RTS\crash_reports`.

What a report holds: game version, commit and branch, Godot version, build type, map,
players and AI personalities, match time, weather, unit count, fps and frame times, memory,
OS, CPU and GPU, the most frequent errors with their GDScript call stacks, the engine's
crash backtrace and the last log lines. It holds no names, accounts or addresses, and
folder paths are shortened to `user://`, `res://` or `~`.

## How a report reaches us

On the next launch the main menu asks "Send last crash report?" and shows the exact text.
Nothing is sent unless the player presses Send.

- Default: Send opens a new issue on github.com/cwbhood/godot-open-rts in the browser with
  the report filled in, and the player presses Submit. Reports land as issues titled
  `Crash report: ...`.
- With the optional crash inbox (`tools/crash-inbox/`, a free Cloudflare Worker) set in
  `ironbound/crash_reports/endpoint`, the game posts the report and the worker files the
  issue, so players need no GitHub account.

"Don't send" moves the report to `dismissed/`, Send moves it to `sent/`.

## QA runs

Every run, including the playthrough bot and the PC QA batches, writes the same reports.
Runs given `--out=DIR` also get `crash_report.txt` and `crash_report.json` in that folder,
and the playthrough bot lists the report as a finding. The playthrough bot ends a match
frozen for 3 minutes (`--hang-exit=SECONDS` changes that) so a batch keeps going. A run that
crashed outright is turned into a report by the next Godot launch; after a batch run

    godot --headless --path . res://tools/crash/Collect.tscn

to collect and list them. Runs in parallel write over each other's godot.log, so give each
its own log to keep the engine backtrace: `godot --log-file /tmp/run1.log ... --
--crash-log=/tmp/run1.log`.

## Testing

`--crash-test=crash:30` (or `hang`, `freeze`, `storm`, `script`) makes the game crash,
freeze or flood errors 30 s into a match, or 30 s after start outside a match.

Runs started from the Godot editor skip the freeze check, because a debugger stopped at a
breakpoint looks the same as a freeze; pass `--hang-watch` to turn it on anyway. Stopping
the game from the editor isn't reported as a crash.
