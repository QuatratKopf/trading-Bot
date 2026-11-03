"""Öffentliche Adresse für TradingView.

- Mit ngrok-Schlüssel: feste Adresse (kostenlose ngrok-Dev-Domain, bleibt nach Neustarts gleich).
- Ohne Schlüssel: Cloudflare Quick Tunnel ohne Account (Adresse wechselt bei jedem Neustart).

Die benötigten Programme lädt die App beim ersten Bedarf selbst herunter.
"""
import io
import os
import platform
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import threading
import time
import urllib.request
import zipfile

CLOUDFLARED = "https://github.com/cloudflare/cloudflared/releases/latest/download/"
NGROK = "https://bin.equinox.io/c/bNyj1mQVY4c/"


class Tunnel:
    def __init__(self, data_dir, port, log, get_token=lambda: ""):
        self.dir = os.path.join(data_dir, "bin")
        self.port = port
        self.log = log
        self.get_token = get_token
        self.url = None
        self.status = "wird vorbereitet"
        self.ok = False
        self.proc = None
        self.provider = None
        self._stopped = False
        self._fast = False
        self._wake = threading.Event()

    def info(self):
        return {"url": self.url, "status": self.status, "ok": self.ok, "provider": self.provider,
                "fixed": self.provider == "ngrok"}

    def start(self):
        threading.Thread(target=self._run, daemon=True).start()

    def restart(self):
        """Nach Änderung des ngrok-Schlüssels: laufende Verbindung beenden, die Schleife baut neu auf."""
        self.url, self.ok, self.status = None, False, "verbindet neu"
        self._fast = True
        self._wake.set()
        proc = self.proc
        if proc and proc.poll() is None:
            proc.terminate()

            def _ensure_dead():
                try:
                    proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    proc.kill()
                try:
                    proc.stdout.close()
                except Exception:  # noqa: BLE001
                    pass
            threading.Thread(target=_ensure_dead, daemon=True).start()

    # ───────── Programme besorgen ─────────
    @staticmethod
    def _arch():
        return "arm64" if platform.machine().lower() in ("arm64", "aarch64") else "amd64"

    def _download(self, url):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "FVG-Trader"})
            with urllib.request.urlopen(req, timeout=120) as r:
                return r.read()
        except Exception as e:  # z. B. fehlende Zertifikate bei Python auf dem Mac
            if shutil.which("curl"):
                return subprocess.run(["curl", "-fsSL", url], check=True, timeout=180, capture_output=True).stdout
            raise e

    def _install(self, name, url, member_suffix=None, archive=None, size=""):
        found = shutil.which(name)
        if found:
            return found
        os.makedirs(self.dir, exist_ok=True)
        path = os.path.join(self.dir, name + (".exe" if sys.platform.startswith("win") else ""))
        if os.path.exists(path):
            return path
        self.status = f"lädt Verbindungsprogramm (einmalig{size})"
        data = self._download(url)
        if archive == "zip":
            with zipfile.ZipFile(io.BytesIO(data)) as z:
                member = next(m for m in z.namelist() if m.rstrip("/").endswith(member_suffix))
                data = z.read(member)
        elif archive == "tgz":
            with tarfile.open(fileobj=io.BytesIO(data)) as t:
                member = next(m for m in t.getmembers() if m.name.endswith(member_suffix))
                data = t.extractfile(member).read()
        tmp = path + ".download"
        with open(tmp, "wb") as f:
            f.write(data)
        os.replace(tmp, path)
        if not sys.platform.startswith("win"):
            os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
        return path

    def _cloudflared(self):
        a = self._arch()
        if sys.platform.startswith("win"):
            return self._install("cloudflared", CLOUDFLARED + "cloudflared-windows-amd64.exe", size=", ca. 30 MB")
        if sys.platform == "darwin":
            return self._install("cloudflared", CLOUDFLARED + f"cloudflared-darwin-{a}.tgz", "cloudflared", "tgz", ", ca. 30 MB")
        return self._install("cloudflared", CLOUDFLARED + f"cloudflared-linux-{a}", size=", ca. 30 MB")

    def _ngrok(self):
        a = self._arch()
        if sys.platform.startswith("win"):
            return self._install("ngrok", NGROK + "ngrok-v3-stable-windows-amd64.zip", "ngrok.exe", "zip", ", ca. 10 MB")
        if sys.platform == "darwin":
            return self._install("ngrok", NGROK + f"ngrok-v3-stable-darwin-{a}.zip", "ngrok", "zip", ", ca. 10 MB")
        return self._install("ngrok", NGROK + f"ngrok-v3-stable-linux-{a}.tgz", "ngrok", "tgz", ", ca. 10 MB")

    # ───────── Tunnel betreiben (startet bei Abbruch neu) ─────────
    @staticmethod
    def _kill_stray_ngrok():
        """Ein altes ngrok (z. B. nach Update oder Absturz) hält die feste Adresse besetzt → beenden."""
        if sys.platform.startswith("win"):
            subprocess.run(["taskkill", "/F", "/IM", "ngrok.exe"], capture_output=True, creationflags=0x08000000)
        else:
            subprocess.run(["pkill", "-x", "ngrok"], capture_output=True)

    def _run(self):
        delay = 5
        first = True
        while not self._stopped:
            token = (self.get_token() or "").strip()
            self.provider = "ngrok" if token else "cloudflare"
            try:
                flags = 0x08000000 if sys.platform.startswith("win") else 0   # kein extra Fenster unter Windows
                if token:
                    exe = self._ngrok()
                    if first:
                        self._kill_stray_ngrok()
                        time.sleep(1)
                    cmd = [exe, "http", str(self.port), "--log", "stdout", "--log-format", "logfmt"]
                    env = dict(os.environ, NGROK_AUTHTOKEN=token)
                    pattern = r"url=(https://[^\s\"]+)"
                else:
                    exe = self._cloudflared()
                    cmd = [exe, "tunnel", "--no-autoupdate", "--url", f"http://localhost:{self.port}"]
                    env = None
                    pattern = r"(https://[a-z0-9]+(?:-[a-z0-9]+)+\.trycloudflare\.com)"
                self.status = "verbindet"
                self.proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                             errors="replace", creationflags=flags, env=env)
                last_err = ""
                for line in iter(self.proc.stdout.readline, ""):
                    if "ERR_NGROK" in line or "lvl=eror" in line or "lvl=crit" in line:
                        m = re.search(r'err="?([^"]+)', line)
                        last_err = (m.group(1) if m else line.strip())[:200]
                        if "ERR_NGROK_105" in line or "authtoken" in line.lower():
                            last_err = "ngrok-Schlüssel ist ungültig. Bitte im ngrok-Dashboard neu kopieren."
                    m = re.search(pattern, line)
                    if m:
                        url = m.group(1).rstrip("/")
                        self._last_logged = None
                        if url != self.url:
                            self.url = url
                            self.log(f"Internet-Verbindung aktiv ({'feste Adresse' if token else 'wechselnde Adresse'}): {url}")
                        self.ok, self.status, delay = True, "aktiv", 5
                self.ok = False
                first = False
                if token and re.search(r"ERR_NGROK_(108|334)|already online|simultaneous", last_err or ""):
                    # Adresse noch von einem alten ngrok belegt: das alte beenden und sofort neu verbinden
                    self.log("Internet-Verbindung: altes ngrok blockiert die Adresse, wird beendet und neu verbunden", "warn")
                    self._kill_stray_ngrok()
                    time.sleep(3)
                    delay = 5
                    continue
                if last_err and last_err != getattr(self, "_last_logged", None):
                    self._last_logged = last_err
                    self.log(f"Internet-Verbindung: {last_err}", "error")
            except Exception as e:  # noqa: BLE001
                self.ok = False
                if not self._fast:   # beim gewollten Neustart ist ein Lesefehler normal
                    txt = str(e)
                    if "225" in txt or "Virus" in txt or "unerwünschte Software" in txt or "virus" in txt:
                        txt = ("Windows Defender hat ngrok blockiert. In Windows-Sicherheit → Viren- & Bedrohungsschutz → "
                               "Schutzverlauf den ngrok-Eintrag zulassen, oder den ngrok-Schlüssel entfernen.")
                    self.status = f"Fehler: {txt}"
                    if txt != getattr(self, "_last_logged", None):
                        self._last_logged = txt
                        self.log(f"Internet-Verbindung: {txt}", "error")
            if self._fast:   # nach Schlüssel-Änderung sofort neu verbinden
                self._fast, delay = False, 5
                self._wake.clear()
                time.sleep(1)
                continue
            self._wake.wait(delay)
            if self._wake.is_set():
                self._wake.clear()
                self._fast, delay = False, 5
                continue
            delay = min(delay * 2, 120)

    def stop(self):
        self._stopped = True
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
