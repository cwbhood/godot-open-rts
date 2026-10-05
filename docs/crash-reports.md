# Crash reports

`source/crash/CrashReporter.gd` (an autoload) writes a report to `user://crash_reports/`
when the game crashes, freezes for 20 s or more, or logs 100 errors within 10 s. On Windows
that folder is `%APPDATA%\Ironbound\crash_reports`.

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

## Example

A crash forced 15 s into a match by the playthrough bot (log lines trimmed):

````markdown
### Ironbound crash report

**What happened:** The game crashed: Program crashed with signal 4 (illegal instruction).

- **Game:** Open RTS 0.9.0, commit 61e80e2d5a on claude/project-thread-n848m0, debug build, Godot 4.7.2-stable (official)
- **Match:** Plain & Simple, players human, AI raider, match time 0:15, weather clear, 30 units
- **Performance:** 7 fps, frame 166.5 ms, physics 3.0 ms, 2379 nodes, 70 MB RAM, 47 MB VRAM, played 0:16
- **System:** Linux 24.04, Intel(R) Xeon(R) Processor @ 2.10GHz (4 threads), Mesa llvmpipe (LLVM 20.1.2, 256 bits), driver unknown, gl_compatibility/opengl3, screen (1280, 720)

**Engine backtrace**
```text
Program crashed with signal 4 (illegal instruction)
Engine version: Godot Engine v4.7.2.stable.official (ed1daf0bf001b61586d9930840f2f1394092c079)
GDScript backtrace (most recent call first):
  [0] _run_crash_test (res://source/crash/CrashReporter.gd:623)
  [1] _process (res://source/crash/CrashReporter.gd:200)
(18 C++ frames without symbols left out)

Log before the crash:
   at: init_output_device (drivers/alsa/audio_driver_alsa.cpp:97)
WARNING: All audio drivers failed, falling back to the dummy driver.
   at: initialize (servers/audio/audio_server.cpp:258)
...
````
