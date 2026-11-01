"""Öffentliche Adresse für TradingView ohne Account: Cloudflare Quick Tunnel (cloudflared).

Lädt cloudflared beim ersten Start automatisch herunter und startet es im Hintergrund.
"""
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

BASE = "https://github.com/cloudflare/cloudflared/releases/latest/download/"


class Tunnel:
    def __init__(self, data_dir, port, log):
        self.dir = os.path.join(data_dir, "bin")
        self.port = port
        self.log = log
        self.url = None
        self.status = "wird vorbereitet"
        self.ok = False
        self.proc = None

    def info(self):
        return {"url": self.url, "status": self.status, "ok": self.ok}

    def start(self):
        threading.Thread(target=self._run, daemon=True).start()

    # ───────── cloudflared besorgen ─────────
    def _asset(self):
        mach = platform.machine().lower()
        arm = mach in ("arm64", "aarch64")
        if sys.platform.startswith("win"):
            return "cloudflared-windows-amd64.exe", "cloudflared.exe", False
        if sys.platform == "darwin":
            return ("cloudflared-darwin-arm64.tgz" if arm else "cloudflared-darwin-amd64.tgz"), "cloudflared", True
        return ("cloudflared-linux-arm64" if arm else "cloudflared-linux-amd64"), "cloudflared", False

    def _download(self, url, dest):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "FVG-Trader"})
            with urllib.request.urlopen(req, timeout=120) as r, open(dest, "wb") as f:
                shutil.copyfileobj(r, f)
            return
        except Exception as e:  # z. B. fehlende Zertifikate bei Python auf dem Mac
            if shutil.which("curl"):
                subprocess.run(["curl", "-fsSL", "-o", dest, url], check=True, timeout=180)
                return
            raise e

    def _binary(self):
        found = shutil.which("cloudflared")
        if found:
            return found
        asset, name, is_tgz = self._asset()
        os.makedirs(self.dir, exist_ok=True)
        path = os.path.join(self.dir, name)
        if os.path.exists(path):
            return path
        self.status = "lädt Verbindungsprogramm (einmalig, ca. 30 MB)"
        tmp = path + ".download"
        self._download(BASE + asset, tmp)
        if is_tgz:
            with tarfile.open(tmp) as t:
                member = next(m for m in t.getmembers() if m.name.endswith("cloudflared"))
                with t.extractfile(member) as src, open(path, "wb") as dst:
                    shutil.copyfileobj(src, dst)
            os.remove(tmp)
        else:
            os.replace(tmp, path)
        if not sys.platform.startswith("win"):
            os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
        return path

    # ───────── Tunnel betreiben (startet bei Abbruch neu) ─────────
    def _run(self):
        delay = 5
        while True:
            try:
                exe = self._binary()
                self.status = "verbindet"
                flags = 0x08000000 if sys.platform.startswith("win") else 0   # kein extra Fenster unter Windows
                self.proc = subprocess.Popen(
                    [exe, "tunnel", "--no-autoupdate", "--url", f"http://localhost:{self.port}"],
                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace",
                    creationflags=flags)
                for line in self.proc.stdout:
                    m = re.search(r"https://[a-z0-9]+(?:-[a-z0-9]+)+\.trycloudflare\.com", line)
                    if m and m.group(0) != self.url:
                        self.url = m.group(0)
                        self.ok = True
                        self.status = "aktiv"
                        self.log(f"Internet-Verbindung aktiv: {self.url}")
                        delay = 5
                    elif m:
                        self.ok = True
                        self.status = "aktiv"
                self.ok = False
                self.status = "getrennt, verbinde neu"
            except Exception as e:  # noqa: BLE001
                self.ok = False
                self.status = f"Fehler: {e}"
                self.log(f"Internet-Verbindung: {e}", "error")
            time.sleep(delay)
            delay = min(delay * 2, 120)

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
