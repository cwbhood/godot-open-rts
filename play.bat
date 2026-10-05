@echo off
rem One command to play-test Ironbound with the play harness on Windows.
rem Double-click it for the quick batch, or from a terminal in this folder:
rem
rem   play                      the quick batch: every scenario once
rem   play smoke                one scenario from tools\harness\scenarios\
rem   play batch maps-vs-ais    a batch from tools\harness\batches\
rem   play stress 60            60 against 60 units, with frame-time budgets
rem   play serve                an open match that takes orders on port 7777
rem   play watch smoke          a scenario in a window at normal speed, to watch it
rem
rem Matches run in a window on your graphics card with the harness's own mouse, so your
rem cursor stays yours. Extra options go after, e.g.  play smoke --speed=1 --seed=3
rem Godot is taken from the GODOT variable, then godot.exe on the PATH, then the newest
rem Godot_v4*.exe next to this folder or in Downloads. Reports land in harness-out\.
setlocal EnableDelayedExpansion
cd /d "%~dp0"

if not defined GODOT (
  for %%G in (godot.exe godot4.exe) do (
    if not defined GODOT for /f "delims=" %%P in ('where %%G 2^>nul') do if not defined GODOT set "GODOT=%%P"
  )
)
if not defined GODOT (
  for %%D in ("%~dp0.." "%USERPROFILE%\Downloads" "%USERPROFILE%\Desktop") do (
    for /f "delims=" %%P in ('dir /b /s /o-n "%%~D\Godot_v4*_win64.exe" 2^>nul ^| findstr /v /i console') do if not defined GODOT set "GODOT=%%P"
  )
)
if not defined GODOT (
  echo Godot not found. Set it once with:  setx GODOT "C:\path\to\Godot_v4.7.2-stable_win64.exe"
  pause
  exit /b 2
)

set "WHAT=%~1"
if "%WHAT%"=="" set "WHAT=batch"
shift
set "ARGS="
if /i "%WHAT%"=="batch" (
  set "NAME=%~1"
  if "!NAME!"=="" (set "NAME=quick") else shift
  set "ARGS=--batch=!NAME! --view=window"
) else if /i "%WHAT%"=="stress" (
  set "NAME=%~1"
  if "!NAME!"=="" (set "NAME=40") else shift
  set "ARGS=--stress=!NAME! --view=window"
) else if /i "%WHAT%"=="serve" (
  set "ARGS=--serve=7777 --scenario=sandbox"
) else if /i "%WHAT%"=="watch" (
  set "NAME=%~1"
  if "!NAME!"=="" (set "NAME=smoke") else shift
  set "ARGS=--scenario=!NAME! --view=window --speed=1"
) else (
  set "ARGS=--scenario=%WHAT% --view=window"
)

set "REST="
:collect
if "%~1"=="" goto run
set "REST=!REST! %1"
shift
goto collect

:run
echo Using "%GODOT%"
"%GODOT%" --path . res://tools/harness/Harness.tscn -- %ARGS% %REST%
set "CODE=%ERRORLEVEL%"
if "%CODE%"=="0" (echo All checks passed.) else (echo Some checks failed: see the report.md under harness-out\)
if "%~0"=="%~dpnx0" pause
exit /b %CODE%
