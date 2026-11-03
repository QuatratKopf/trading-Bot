"""Baut FVG-Trader.cmd: eine einzige Datei (Windows-Batch + Python), die alles enthält."""
import hashlib
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.join(HERE, "app")
OUT = os.path.join(HERE, "dist", "FVG-Trader.cmd")

HEADER = r"""0<0# : ^
r'''
@echo off
title FVG Trader
cd /d "%~dp0"
set "FVG_LAUNCHER=%~f0"
set "FVG_DATA=%~dp0FVG-Trader-Daten"
set "PYEXE="
set "PYARG="
for %%P in (py.exe) do if not "%%~$PATH:P"=="" set "PYEXE=%%~$PATH:P"
if defined PYEXE set "PYARG=-3"
if not defined PYEXE if exist "%LOCALAPPDATA%\Programs\Python\Launcher\py.exe" set "PYEXE=%LOCALAPPDATA%\Programs\Python\Launcher\py.exe"
if defined PYEXE if not defined PYARG set "PYARG=-3"
if not defined PYEXE for /d %%D in ("%LOCALAPPDATA%\Programs\Python\Python3*") do if exist "%%D\python.exe" set "PYEXE=%%D\python.exe"
if not defined PYEXE (
  echo.
  echo   FVG Trader braucht Python. Es wird jetzt einmalig installiert, das dauert 1-2 Minuten ...
  echo.
  winget install -e --id Python.Python.3.12 --scope user --silent --accept-package-agreements --accept-source-agreements
  if exist "%LOCALAPPDATA%\Programs\Python\Launcher\py.exe" set "PYEXE=%LOCALAPPDATA%\Programs\Python\Launcher\py.exe"
  if exist "%LOCALAPPDATA%\Programs\Python\Python312\python.exe" set "PYEXE=%LOCALAPPDATA%\Programs\Python\Python312\python.exe"
)
if not defined PYEXE (
  echo.
  echo   Python konnte nicht automatisch installiert werden.
  echo   Bitte installiere Python von python.org ^(Haken bei "Add Python to PATH"^)
  echo   und oeffne danach diese Datei erneut.
  start "" "https://www.python.org/downloads/"
  pause
  exit /b 1
)
rem Alte FVG-Trader-Instanzen beenden: wer den App-Port 8787 belegt, wird geschlossen
for /f "tokens=2,3,5" %%A in ('netstat -ano -p tcp ^| findstr /c:":8787 "') do if "%%B"=="0.0.0.0:0" if not "%%C"=="0" taskkill /F /T /PID %%C >nul 2>&1
set "PYW="
if /i "%PYEXE:~-6%"=="py.exe" for %%I in ("%PYEXE%") do if exist "%%~dpIpyw.exe" set "PYW=%%~dpIpyw.exe"
if /i "%PYEXE:~-10%"=="python.exe" for %%I in ("%PYEXE%") do if exist "%%~dpIpythonw.exe" set "PYW=%%~dpIpythonw.exe"
if defined PYW (
  start "" "%PYW%" %PYARG% "%~f0" %*
  exit /b 0
)
echo.
echo   FVG Trader startet ... dieses Fenster bitte offen lassen.
echo.
"%PYEXE%" %PYARG% "%~f0" %*
if errorlevel 1 pause
exit /b 0
'''
# ─────────────────────────────────────────────────────────────────────────────
#  FVG Trader – alles in einer Datei.
#  Windows: Doppelklick.   Mac/Linux: python3 FVG-Trader.cmd
#  Daten liegen im Ordner „FVG-Trader-Daten“ neben dieser Datei.
# ─────────────────────────────────────────────────────────────────────────────
"""

LOCAL_IMPORTS = re.compile(
    r"^(from (db|brokers|discovery|engine|tunnel|appshell) import .*|sys\.path\.insert\(0, os\.path\.dirname\(os\.path\.abspath\(__file__\)\)\))\s*$",
    re.M)


def module(name):
    with open(os.path.join(APP, name), encoding="utf-8") as f:
        src = f.read()
    src = LOCAL_IMPORTS.sub("", src)
    return f"\n# ═════════════════ {name} ═════════════════\n" + src


def main():
    with open(os.path.join(APP, "static", "index.html"), encoding="utf-8") as f:
        html = f.read()
    with open(os.path.join(HERE, "tradingview", "fvg_bot_multi.pine"), encoding="utf-8") as f:
        pine = f.read()
    body = "".join(module(m) for m in ("db.py", "brokers.py", "discovery.py", "engine.py", "tunnel.py", "appshell.py"))
    server = module("server.py")
    server = server.replace(
        'DATA = os.environ.get("FVG_DATA", os.path.join(ROOT, "data"))',
        'DATA = os.environ.get("FVG_DATA", os.path.join(os.path.dirname(os.path.abspath(__file__)), "FVG-Trader-Daten"))')
    assert "FVG-Trader-Daten" in server
    version = sys.argv[1] if len(sys.argv) > 1 else "0.0.0"
    notes = sys.argv[2] if len(sys.argv) > 2 else ""
    assert re.fullmatch(r"\d+\.\d+\.\d+", version), "Version wie 1.4.0 angeben"
    server = server.replace('APP_VERSION = "dev"', f'APP_VERSION = "{version}"', 1)
    assert f'APP_VERSION = "{version}"' in server
    consts = f"\nINDEX_HTML = {html!r}\n\nPINE_SOURCE = {pine!r}\n"
    out = HEADER + body + consts + server
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8", newline="\r\n") as f:
        f.write(out)
    with open(OUT, "rb") as f:
        sha = hashlib.sha256(f.read()).hexdigest()
    with open(os.path.join(os.path.dirname(OUT), "version.json"), "w", encoding="utf-8") as f:
        # eigene, nie wieder geänderte Datei je Version: GitHub kann keine veraltete Fassung ausliefern
        json.dump({"version": version, "file": f"releases/FVG-Trader-{version}.cmd", "sha256": sha, "notes": notes},
                  f, ensure_ascii=False, indent=2)
    print("gebaut:", OUT, os.path.getsize(OUT), "Bytes · Version", version)


if __name__ == "__main__":
    main()
