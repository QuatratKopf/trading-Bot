"""Damit FVG Trader sich wie eine App anfühlt: eigenes Fenster, Icon, Desktop-Verknüpfung, Handy-App."""
import os
import shutil
import struct
import subprocess
import sys
import webbrowser
import zlib

_PNG_CACHE = {}


def icon_png(size=512):
    """App-Icon ohne Bilddatei: blaues Quadrat mit drei Kerzen, als PNG erzeugt."""
    if size in _PNG_CACHE:
        return _PNG_CACHE[size]
    bg = (47, 91, 211)
    rad = size * 0.22
    # (x0, x1, y0, y1, Deckkraft) als Anteile der Kantenlänge
    bars = [(0.22, 0.36, 0.20, 0.58, 255), (0.43, 0.57, 0.34, 0.80, 140), (0.64, 0.78, 0.46, 0.80, 255)]
    wicks = [(0.285, 0.295, 0.12, 0.66), (0.495, 0.505, 0.26, 0.88), (0.705, 0.715, 0.38, 0.88)]
    raw = bytearray()
    for y in range(size):
        raw.append(0)
        fy = (y + 0.5) / size
        for x in range(size):
            fx = (x + 0.5) / size
            # abgerundete Ecken
            cx = min(max(x + 0.5, rad), size - rad)
            cy = min(max(y + 0.5, rad), size - rad)
            d = ((x + 0.5 - cx) ** 2 + (y + 0.5 - cy) ** 2) ** 0.5
            a = 255 if d <= rad - 0.5 else (0 if d >= rad + 0.5 else int((rad + 0.5 - d) * 255))
            r, g, b = bg
            for x0, x1, y0, y1 in wicks:
                if x0 <= fx <= x1 and y0 <= fy <= y1:
                    r, g, b = 235, 240, 255
            for x0, x1, y0, y1, op in bars:
                if x0 <= fx <= x1 and y0 <= fy <= y1:
                    t = op / 255
                    r, g, b = (int(bg[i] * (1 - t) + 255 * t) for i in range(3))
            raw += bytes((r, g, b, a))

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))
    _PNG_CACHE[size] = png
    return png


def write_ico(path):
    png = icon_png(256)
    header = struct.pack("<HHH", 0, 1, 1) + struct.pack("<BBBBHHII", 0, 0, 0, 0, 1, 32, len(png), 22)
    with open(path, "wb") as f:
        f.write(header + png)


MANIFEST = {
    "name": "FVG Trader",
    "short_name": "FVG Trader",
    "start_url": "/",
    "scope": "/",
    "display": "standalone",
    "background_color": "#10131b",
    "theme_color": "#2f5bd3",
    "icons": [
        {"src": "/icon-192.png", "sizes": "192x192", "type": "image/png"},
        {"src": "/icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "any maskable"},
    ],
}

SERVICE_WORKER = """// Macht FVG Trader installierbar. Es wird nichts zwischengespeichert: Kurse und Trades sind immer live.
self.addEventListener('install', e => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', e => e.respondWith(fetch(e.request)));
"""


# ───────────────────────── App-Fenster öffnen ─────────────────────────
def _app_browser():
    if sys.platform.startswith("win"):
        for base in (os.environ.get("ProgramFiles(x86)"), os.environ.get("ProgramFiles"), os.environ.get("LOCALAPPDATA")):
            for rel in (r"Microsoft\Edge\Application\msedge.exe", r"Google\Chrome\Application\chrome.exe"):
                if base and os.path.exists(os.path.join(base, rel)):
                    return os.path.join(base, rel)
    elif sys.platform == "darwin":
        for p in ("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                  "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
                  "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"):
            if os.path.exists(p):
                return p
    else:
        for name in ("google-chrome", "chromium", "chromium-browser", "microsoft-edge"):
            if shutil.which(name):
                return shutil.which(name)
    return None


def open_app_window(url):
    exe = _app_browser()
    if exe:
        try:
            subprocess.Popen([exe, f"--app={url}", "--window-size=1280,860"],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return
        except OSError:
            pass
    webbrowser.open(url)


# ───────────────────────── Verknüpfungen (Windows) ─────────────────────────
def windowless_python():
    """pythonw.exe startet Python ohne Konsolenfenster."""
    exe = sys.executable
    cand = os.path.join(os.path.dirname(exe), "pythonw.exe")
    return cand if os.path.exists(cand) else exe


def make_shortcuts(paths, launcher, icon, args=""):
    ps = (
        "$w = New-Object -ComObject WScript.Shell;"
        "foreach ($p in ($env:FVG_SC_PATHS -split '\\|')) {"
        "  $s = $w.CreateShortcut($p);"
        "  $s.TargetPath = $env:FVG_SC_TARGET; $s.Arguments = $env:FVG_SC_ARGS;"
        "  $s.WorkingDirectory = $env:FVG_SC_DIR; $s.IconLocation = $env:FVG_SC_ICON;"
        "  $s.Description = 'FVG Trader'; $s.Save() }"
    )
    env = dict(os.environ, FVG_SC_PATHS="|".join(paths), FVG_SC_TARGET=windowless_python(),
               FVG_SC_ARGS=f'"{launcher}" {args}'.strip(), FVG_SC_DIR=os.path.dirname(launcher), FVG_SC_ICON=icon)
    subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", ps],
                   env=env, check=True, timeout=30, creationflags=0x08000000,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def _folders():
    ps = "[Environment]::GetFolderPath('Desktop'); [Environment]::GetFolderPath('Programs'); [Environment]::GetFolderPath('Startup')"
    out = subprocess.run(["powershell", "-NoProfile", "-Command", ps], capture_output=True, text=True,
                         timeout=30, creationflags=0x08000000).stdout.split("\n")
    return [o.strip() for o in out if o.strip()]


def icon_file(data_dir):
    ico = os.path.join(data_dir, "FVG-Trader.ico")
    if not os.path.exists(ico):
        write_ico(ico)
    return ico


def ensure_desktop_shortcut(launcher, data_dir, log):
    """Legt „FVG Trader“ auf Desktop und im Startmenü an und richtet es neu aus, sobald eine andere Datei läuft.
    So zeigt das Symbol nie auf eine alte Kopie (z. B. „FVG-Trader (1).cmd“ in Downloads)."""
    if not sys.platform.startswith("win"):
        return
    flag = os.path.join(data_dir, "verknuepfung.txt")
    try:
        desktop, programs = _folders()[:2]
        try:
            with open(flag, encoding="utf-8") as f:
                same = f.read().strip() == launcher
        except OSError:
            same = False
        if same and os.path.exists(os.path.join(desktop, "FVG Trader.lnk")):
            return   # Symbol vorhanden und zeigt auf diese Datei
        make_shortcuts([os.path.join(desktop, "FVG Trader.lnk"), os.path.join(programs, "FVG Trader.lnk")],
                       launcher, icon_file(data_dir))
        if autostart_enabled():   # Autostart startet still im Hintergrund
            make_shortcuts([autostart_path()], launcher, icon_file(data_dir), "--hintergrund")
        with open(flag, "w", encoding="utf-8") as f:
            f.write(launcher)
        log(f"Desktop-Symbol zeigt auf: {launcher}")
    except Exception as e:  # noqa: BLE001
        log(f"Desktop-Symbol konnte nicht angelegt werden: {e}", "warn")


def autostart_path():
    if not sys.platform.startswith("win"):
        return None
    appdata = os.environ.get("APPDATA", "")
    return os.path.join(appdata, "Microsoft", "Windows", "Start Menu", "Programs", "Startup", "FVG Trader.lnk")


def set_autostart(on, launcher, data_dir):
    lnk = autostart_path()
    if not lnk:
        raise ValueError("Autostart gibt es nur unter Windows")
    old = os.path.join(os.path.dirname(lnk), "FVG-Trader-Autostart.cmd")
    if os.path.exists(old):
        os.remove(old)
    if on:
        make_shortcuts([lnk], launcher, icon_file(data_dir), "--hintergrund")
    elif os.path.exists(lnk):
        os.remove(lnk)


def autostart_enabled():
    lnk = autostart_path()
    return bool(lnk and os.path.exists(lnk))


# ───────────────────────── Dienst: Start beim Hochfahren ohne Anmeldung (Windows-Aufgabenplanung) ─────────────────────────
SERVICE_TASK = "FVG Trader Dienst"


def service_installed():
    if not sys.platform.startswith("win"):
        return False
    try:
        r = subprocess.run(["schtasks", "/Query", "/TN", SERVICE_TASK], capture_output=True, timeout=20,
                           creationflags=0x08000000)
        return r.returncode == 0
    except Exception:  # noqa: BLE001
        return False


def _ps_quote(s):
    return "'" + str(s).replace("'", "''") + "'"


def _run_elevated(script, data_dir, name, timeout=150):
    """PowerShell-Skript mit Administratorrechten ausführen (Windows fragt per UAC nach). Ergebnis kommt über eine Datei."""
    import time
    res = os.path.join(data_dir, name + ".ergebnis.txt")
    ps1 = os.path.join(data_dir, name + ".ps1")
    if os.path.exists(res):
        os.remove(res)
    with open(ps1, "w", encoding="utf-8-sig") as f:
        f.write(script.replace("__RESULT__", _ps_quote(res)))
    cmd = ("Start-Process powershell -Verb RunAs -WindowStyle Hidden -ArgumentList "
           f"'-NoProfile','-ExecutionPolicy','Bypass','-File',{_ps_quote(chr(34) + ps1 + chr(34))}")
    r = subprocess.run(["powershell", "-NoProfile", "-Command", cmd], capture_output=True, text=True,
                       timeout=60, creationflags=0x08000000)
    if r.returncode != 0:
        raise ValueError("Windows hat die Administratorrechte nicht erteilt (Rückfrage abgelehnt?).")
    end = time.time() + timeout
    while time.time() < end:
        if os.path.exists(res):
            time.sleep(0.3)
            with open(res, encoding="utf-8-sig", errors="replace") as f:
                txt = f.read().strip()
            if txt == "ok":
                return True
            raise ValueError(txt.replace("fehler: ", "Windows meldet: ", 1))
        time.sleep(0.5)
    raise ValueError("Keine Antwort von Windows. Wurde die Rückfrage nach Administratorrechten bestätigt?")


def service_install(launcher, data_dir):
    if not sys.platform.startswith("win"):
        raise ValueError("Den Dienst gibt es nur unter Windows. Unter Linux z. B. per systemd starten.")
    pyw = windowless_python()
    args = f'"{launcher}" --hintergrund --dienst'
    script = f"""$ErrorActionPreference = 'Stop'
$out = __RESULT__
try {{
  $act = New-ScheduledTaskAction -Execute {_ps_quote(pyw)} -Argument {_ps_quote(args)} -WorkingDirectory {_ps_quote(os.path.dirname(launcher))}
  $trg = New-ScheduledTaskTrigger -AtStartup
  $set = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew
  $pri = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  Register-ScheduledTask -TaskName {_ps_quote(SERVICE_TASK)} -Action $act -Trigger $trg -Settings $set -Principal $pri -Description 'Startet FVG Trader beim Hochfahren, auch ohne Anmeldung' -Force | Out-Null
  Set-Content -Path $out -Value 'ok' -Encoding ascii
  Start-Sleep -Seconds 4
  Start-ScheduledTask -TaskName {_ps_quote(SERVICE_TASK)}
}} catch {{ Set-Content -Path $out -Value ('fehler: ' + $_.Exception.Message) -Encoding utf8 }}
"""
    return _run_elevated(script, data_dir, "dienst-einrichten")


def service_remove(data_dir):
    if not sys.platform.startswith("win"):
        raise ValueError("Den Dienst gibt es nur unter Windows.")
    script = f"""$ErrorActionPreference = 'Stop'
$out = __RESULT__
try {{
  Unregister-ScheduledTask -TaskName {_ps_quote(SERVICE_TASK)} -Confirm:$false
  Set-Content -Path $out -Value 'ok' -Encoding ascii
}} catch {{ Set-Content -Path $out -Value ('fehler: ' + $_.Exception.Message) -Encoding utf8 }}
"""
    return _run_elevated(script, data_dir, "dienst-entfernen")
