"""FVG Trader – lokaler Webserver ohne Zusatzpakete.

Start:  python app/server.py      →  http://localhost:8787
TradingView-Alerts gehen an:  <öffentliche URL>/webhook/<token>
"""
import hashlib
import hmac
import http.cookies
import json
import os
import re
import secrets
import sys
import threading
import time
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from engine import Engine  # noqa: E402
from tunnel import Tunnel  # noqa: E402
from appshell import MANIFEST, SERVICE_WORKER, autostart_enabled, ensure_desktop_shortcut, icon_png, open_app_window, set_autostart, windowless_python  # noqa: E402,E501

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.environ.get("FVG_DATA", os.path.join(ROOT, "data"))
STATIC = os.path.join(ROOT, "app", "static")
HOST = os.environ.get("FVG_HOST", "127.0.0.1")
PORT = int(os.environ.get("FVG_PORT", "8787"))
BACKGROUND = "--hintergrund" in sys.argv
APP_VERSION = "dev"   # wird beim Bauen der Ein-Datei-Version gesetzt

LOG_FILE = os.path.join(DATA, "app.log")


class _Tee:
    """Schreibt Ausgaben immer in app.log und, falls vorhanden, zusätzlich ins Konsolenfenster."""
    def __init__(self, *streams):
        self.streams = [x for x in streams if x is not None]

    def write(self, text):
        for st in self.streams:
            try:
                st.write(text)
            except Exception:  # noqa: BLE001
                pass
        return len(text)

    def flush(self):
        for st in self.streams:
            try:
                st.flush()
            except Exception:  # noqa: BLE001
                pass


os.makedirs(DATA, exist_ok=True)
try:
    if os.path.exists(LOG_FILE) and os.path.getsize(LOG_FILE) > 1_000_000:   # alte Logs aufheben, Datei klein halten
        os.replace(LOG_FILE, LOG_FILE + ".1")
except OSError:
    pass
_logf = open(LOG_FILE, "a", encoding="utf-8", buffering=1)
_logf.write(f"\n===== {time.strftime('%Y-%m-%d %H:%M:%S')} Start =====\n")
sys.stdout = _Tee(sys.stdout, _logf)
sys.stderr = _Tee(sys.stderr, _logf)

engine = Engine(DATA)
tunnel = Tunnel(DATA, PORT, engine.db.log, get_token=lambda: (engine.cfg.get("tunnel") or {}).get("ngrok_token", ""))
LAUNCHER = os.environ.get("FVG_LAUNCHER") or os.path.abspath(sys.argv[0])
AUTH_FILE = os.path.join(DATA, "auth.json")
SESSION_FILE = os.path.join(DATA, "sessions.json")
SESSION_TTL = 7 * 24 * 3600
try:   # Anmeldungen überleben Neustarts und Updates
    with open(SESSION_FILE) as _f:
        SESSIONS = {k: v for k, v in json.load(_f).items() if v > time.time()}
except (OSError, ValueError):
    SESSIONS = {}


def save_sessions():
    try:
        with open(SESSION_FILE, "w") as f:
            json.dump(SESSIONS, f)
    except OSError:
        pass
_fail_lock = threading.Lock()


def hook_url():
    base = (engine.cfg.get("public_url") or tunnel.url or "").rstrip("/")
    return f"{base}/webhook/{engine.cfg['webhook_token']}" if base else ""


def pine_source():
    if "PINE_SOURCE" in globals():
        return globals()["PINE_SOURCE"]
    with open(os.path.join(ROOT, "tradingview", "fvg_bot_multi.pine"), encoding="utf-8") as f:
        return f.read()


# ───────────────────────── Passwort ─────────────────────────
def _hash(pw, salt):
    return hashlib.pbkdf2_hmac("sha256", pw.encode(), bytes.fromhex(salt), 200_000).hex()


def has_password():
    return os.path.exists(AUTH_FILE)


def set_password(pw):
    salt = secrets.token_hex(16)
    with open(AUTH_FILE, "w") as f:
        json.dump({"salt": salt, "hash": _hash(pw, salt)}, f)


def check_password(pw):
    with open(AUTH_FILE) as f:
        a = json.load(f)
    return hmac.compare_digest(_hash(pw, a["salt"]), a["hash"])


ROUTES = []


def route(method, pattern, auth=True):
    def deco(fn):
        ROUTES.append((method, re.compile("^" + pattern + "$"), auth, fn))
        return fn
    return deco


class Handler(BaseHTTPRequestHandler):
    server_version = "FVGTrader/1.0"

    def log_message(self, fmt, *args):   # leise, außer Fehler
        pass

    # ───────── Helfer ─────────
    def _send(self, code, body, ctype="application/json; charset=utf-8", headers=None):
        data = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False, default=str).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n > (5_000_000 if self.path.startswith(("/api/update/", "/api/own/import")) else 100_000):
            raise ValueError("Anfrage zu groß")
        raw = self.rfile.read(n).decode("utf-8", "replace") if n else ""
        return raw

    def _json(self):
        raw = self._body()
        return json.loads(raw) if raw.strip() else {}

    def _session(self):
        c = http.cookies.SimpleCookie(self.headers.get("Cookie", ""))
        sid = c["sid"].value if "sid" in c else None
        exp = SESSIONS.get(sid)
        return sid if exp and exp > time.time() else None

    def _dispatch(self, method):
        path = self.path.split("?")[0]
        if method == "GET" and (path == "/" or path.startswith("/static/")):
            return self._static(path)
        for m, rx, auth, fn in ROUTES:
            mt = rx.match(path)
            if m == method and mt:
                if auth:
                    if not self._session():
                        return self._send(401, {"error": "Bitte anmelden"})
                    if method == "POST" and self.headers.get("X-Requested-With") != "fvg":
                        return self._send(403, {"error": "Ungültige Anfrage"})
                try:
                    return fn(self, *mt.groups())
                except (ValueError, KeyError, TypeError) as e:
                    return self._send(400, {"error": str(e)})
                except Exception as e:   # noqa: BLE001
                    engine.db.log(f"Serverfehler: {e}", "error")
                    return self._send(500, {"error": "Interner Fehler: " + str(e)})
        self._send(404, {"error": "Nicht gefunden"})

    def _static(self, path):
        if path == "/" and "INDEX_HTML" in globals():
            return self._send(200, globals()["INDEX_HTML"].encode("utf-8"), "text/html; charset=utf-8")
        name = "index.html" if path == "/" else path[len("/static/"):]
        full = os.path.normpath(os.path.join(STATIC, name))
        if not full.startswith(STATIC) or not os.path.isfile(full):
            return self._send(404, {"error": "Nicht gefunden"})
        ctype = {"html": "text/html", "js": "text/javascript", "css": "text/css", "svg": "image/svg+xml",
                 "png": "image/png", "json": "application/json"}.get(name.rsplit(".", 1)[-1], "application/octet-stream")
        with open(full, "rb") as f:
            self._send(200, f.read(), ctype + "; charset=utf-8")

    def do_GET(self):
        self._dispatch("GET")

    def do_POST(self):
        self._dispatch("POST")


# ───────────────────────── Routen ─────────────────────────
@route("POST", r"/webhook/([A-Za-z0-9_\-]+)", auth=False)
def webhook(h, token):
    if not hmac.compare_digest(token, engine.cfg["webhook_token"]):
        time.sleep(0.5)
        return h._send(403, {"error": "Falscher Webhook-Token"})
    raw = h._body()
    try:
        payload = json.loads(raw)
    except ValueError:
        engine.db.log(f"Webhook ohne gültiges JSON empfangen: {raw[:80]!r}", "error")
        return h._send(400, {"error": "Kein gültiges JSON"})
    try:
        res = engine.handle_webhook(payload)
    except ValueError as e:
        engine.db.log(f"Webhook abgelehnt: {e}", "error")
        return h._send(400, {"error": str(e)})
    h._send(200, res)


@route("GET", r"/manifest.webmanifest", auth=False)
def manifest(h):
    h._send(200, json.dumps(MANIFEST).encode(), "application/manifest+json")


@route("GET", r"/icon-(192|512)\.png", auth=False)
def icon(h, size):
    h._send(200, icon_png(int(size)), "image/png", headers={"Cache-Control": "max-age=86400"})


@route("GET", r"/sw\.js", auth=False)
def sw(h):
    h._send(200, SERVICE_WORKER.encode(), "text/javascript; charset=utf-8")


@route("GET", r"/api/version", auth=False)
def version(h):
    h._send(200, {"version": APP_VERSION, "pid": os.getpid()})


@route("GET", r"/api/auth", auth=False)
def auth_status(h):
    h._send(200, {"has_password": has_password(), "logged_in": bool(h._session())})


@route("POST", r"/api/setup", auth=False)
def setup(h):
    if has_password():
        return h._send(400, {"error": "Passwort ist bereits gesetzt"})
    pw = h._json().get("password", "")
    if len(pw) < 8:
        return h._send(400, {"error": "Passwort braucht mindestens 8 Zeichen"})
    set_password(pw)
    return login_ok(h)


@route("POST", r"/api/login", auth=False)
def login(h):
    if not has_password():
        return h._send(400, {"error": "Erst ein Passwort festlegen"})
    with _fail_lock:
        ok = check_password(h._json().get("password", ""))
        if not ok:
            time.sleep(1.0)
            return h._send(401, {"error": "Passwort falsch"})
    return login_ok(h)


def login_ok(h):
    sid = secrets.token_urlsafe(32)
    SESSIONS[sid] = time.time() + SESSION_TTL
    save_sessions()
    secure = "; Secure" if h.headers.get("X-Forwarded-Proto") == "https" else ""
    h._send(200, {"ok": True}, headers={
        "Set-Cookie": f"sid={sid}; HttpOnly; SameSite=Strict; Path=/; Max-Age={SESSION_TTL}{secure}"})


@route("POST", r"/api/logout")
def logout(h):
    SESSIONS.pop(h._session(), None)
    save_sessions()
    h._send(200, {"ok": True}, headers={"Set-Cookie": "sid=; Path=/; Max-Age=0"})


@route("GET", r"/api/state")
def state(h):
    s = engine.state()
    s["tunnel"] = tunnel.info() if not os.environ.get("FVG_NO_TUNNEL") else {"url": None, "status": "aus", "ok": False}
    s["hook_url"] = hook_url()
    s["hook_confirmed"] = bool(s["hook_url"]) and engine.cfg.get("hook_confirmed") == s["hook_url"]
    s["platform"] = sys.platform
    s["autostart"] = autostart_enabled()
    s["version"] = APP_VERSION
    s["launcher"] = LAUNCHER
    s["update"] = UPDATE.copy()
    h._send(200, s)


# ───────────────────────── Updates ─────────────────────────
import hashlib as _hl  # noqa: E402
import urllib.parse  # noqa: E402
import urllib.request  # noqa: E402

UPDATE = {"available": False, "version": None, "notes": "", "checked": None, "error": "", "busy": False}
SRV = None


def _vtuple(v):
    try:
        return tuple(int(x) for x in str(v).split("."))
    except ValueError:
        return (0,)


def _fetch(url, limit=5_000_000):
    url += ("&" if "?" in url else "?") + f"t={int(time.time())}"   # GitHub-Zwischenspeicher umgehen
    req = urllib.request.Request(url, headers={"User-Agent": f"FVG-Trader/{APP_VERSION}", "Cache-Control": "no-cache"})
    try:
        with urllib.request.urlopen(req, timeout=25) as r:
            return r.read(limit + 1)[:limit]
    except Exception:
        import shutil
        import subprocess
        if shutil.which("curl"):   # z. B. fehlende Zertifikate bei Python auf dem Mac
            return subprocess.run(["curl", "-fsSL", "-H", "Cache-Control: no-cache", url], capture_output=True,
                                  check=True, timeout=90).stdout[:limit]
        raise


def check_update():
    src = (engine.cfg.get("update_url") or "").strip()
    if not src:
        UPDATE.update(available=False, error="Keine Update-Quelle eingetragen", checked=time.time())
        return UPDATE
    try:
        info = json.loads(_fetch(src, 100_000).decode("utf-8"))
        newer = APP_VERSION != "dev" and _vtuple(info["version"]) > _vtuple(APP_VERSION)
        UPDATE.update(available=newer, version=info["version"], notes=info.get("notes", ""), error="",
                      checked=time.time(), file=urllib.parse.urljoin(src, info["file"]), sha256=info["sha256"])
    except Exception as e:  # noqa: BLE001
        engine.db.log(f"Update-Prüfung: {e}", "warn")
        msg = "Keine Update-Info gefunden. Ist das GitHub-Repository öffentlich?" if "404" in str(e) or "22" in str(e) \
            else "Update-Server nicht erreichbar. Besteht eine Internetverbindung?"
        UPDATE.update(error=msg, checked=time.time())
    return UPDATE


def _validate_build(data, sha=None):
    if sha and _hl.sha256(data).hexdigest() != sha.lower():
        raise ValueError("Prüfsumme stimmt nicht. Das Update wurde nicht installiert.")
    text = data.decode("utf-8")
    m = re.search(r'^APP_VERSION = "([0-9.]+)"', text, re.M)
    if not m or "PINE_SOURCE" not in text or not text.startswith("0<0# : ^"):
        raise ValueError("Das ist keine gültige FVG-Trader-Datei.")
    compile(text, "FVG-Trader.cmd", "exec")   # Syntax prüfen, bevor etwas ersetzt wird
    return m.group(1)


def install_update(data, sha=None):
    if not LAUNCHER.lower().endswith(".cmd") or not os.path.exists(LAUNCHER):
        raise ValueError("Updates funktionieren nur mit der Ein-Datei-Version (FVG-Trader.cmd).")
    new_version = _validate_build(data, sha)
    backup_dir = os.path.join(DATA, "backup")
    os.makedirs(backup_dir, exist_ok=True)
    with open(LAUNCHER, "rb") as f:
        old = f.read()
    with open(os.path.join(backup_dir, f"FVG-Trader-{APP_VERSION}.cmd"), "wb") as f:
        f.write(old)
    tmp = LAUNCHER + ".neu"
    with open(tmp, "wb") as f:
        f.write(data)
    try:
        os.replace(tmp, LAUNCHER)
    except OSError as e:
        os.remove(tmp)
        engine.db.log(f"Update: Datei konnte nicht ersetzt werden: {e}", "error")
        raise ValueError(f"Die App-Datei konnte nicht ersetzt werden ({e.strerror or e}). "
                         "Liegt sie in einem geschützten Ordner? Verschieb FVG-Trader.cmd z. B. nach Dokumente und versuch es erneut.")
    engine.db.log(f"Update installiert: Version {APP_VERSION} → {new_version}. App startet neu.")
    print(f"Update {APP_VERSION} -> {new_version}: Datei ersetzt, Neustart folgt", flush=True)
    threading.Timer(0.8, restart).start()
    return new_version


def restart():
    """Startet FVG Trader neu. Unter Windows über ein kleines Hilfsskript, das unabhängig von diesem Prozess läuft."""
    import subprocess
    try:
        tunnel.stop()
        if SRV:
            SRV.server_close()
        if sys.platform.startswith("win"):
            helper = os.path.join(DATA, "neustart.cmd")
            with open(helper, "w", encoding="ascii", errors="replace") as f:
                f.write("@echo off\r\n"
                        "rem Startet FVG Trader nach einem Update neu\r\n"
                        "ping -n 3 127.0.0.1 >nul\r\n"
                        f'start "" /min "{LAUNCHER}" --hintergrund\r\n')
            flags = 0x08000000 | 0x00000200   # kein Fenster, eigene Prozessgruppe
            try:
                subprocess.Popen(["cmd.exe", "/c", helper], creationflags=flags | 0x01000000,   # aus dem Job lösen
                                 cwd=os.path.dirname(LAUNCHER), close_fds=True)
            except OSError:
                subprocess.Popen(["cmd.exe", "/c", helper], creationflags=flags, cwd=os.path.dirname(LAUNCHER), close_fds=True)
        else:
            subprocess.Popen([sys.executable, LAUNCHER, "--hintergrund"], cwd=os.path.dirname(LAUNCHER),
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True,
                             env=dict(os.environ, FVG_NO_BROWSER="1"))
        print("Neustart angestoßen", flush=True)
    except Exception as e:  # noqa: BLE001
        print(f"Neustart fehlgeschlagen: {e}", flush=True)
    finally:
        os._exit(0)


def _update_loop():
    time.sleep(20)
    while True:
        if engine.cfg.get("update_url"):
            was = UPDATE.get("available")
            check_update()
            if UPDATE["available"] and not was:
                engine.db.log(f"Update verfügbar: Version {UPDATE['version']}")
        time.sleep(6 * 3600)


@route("POST", r"/api/update/check")
def update_check(h):
    h._send(200, check_update())


@route("POST", r"/api/update/apply")
def update_apply(h):
    if not UPDATE.get("available"):
        check_update()
    if not UPDATE.get("available"):
        raise ValueError(UPDATE.get("error") or "Du hast bereits die neueste Version.")
    UPDATE["busy"] = True
    try:
        data = _fetch(UPDATE["file"])
        v = install_update(data, UPDATE.get("sha256"))
    finally:
        UPDATE["busy"] = False
    h._send(200, {"ok": True, "version": v})


@route("POST", r"/api/update/upload")
def update_upload(h):
    n = int(h.headers.get("Content-Length") or 0)
    data = h.rfile.read(n)
    v = install_update(data)
    h._send(200, {"ok": True, "version": v})


@route("POST", r"/api/shutdown")
def shutdown(h):
    engine.db.log("App beendet")
    h._send(200, {"ok": True})

    def bye():
        tunnel.stop()
        os._exit(0)
    threading.Timer(0.6, bye).start()


@route("GET", r"/api/day/(\d{4}-\d{2}-\d{2})")
def day(h, d):
    h._send(200, {"day": d, "trades": engine.day_trades(d)})


@route("POST", r"/api/own/add")
def own_add(h):
    h._send(200, engine.own_add(h._json()))


@route("POST", r"/api/own/import")
def own_import(h):
    b = h._json()
    h._send(200, engine.own_import(str(b.get("csv") or ""), bool(b.get("subtract_fees", True))))


@route("POST", r"/api/own/sync")
def own_sync(h):
    h._send(200, engine.own_sync())


@route("POST", r"/api/tradovate/test")
def tradovate_test(h):
    h._send(200, engine.test_tradovate())


@route("POST", r"/api/own/([a-f0-9]+)/delete")
def own_delete(h, pid):
    h._send(200, engine.own_delete(pid))


@route("GET", r"/api/log")
def app_log(h):
    lines = []
    for f in (LOG_FILE + ".1", LOG_FILE):
        try:
            with open(f, encoding="utf-8", errors="replace") as fh:
                lines += fh.read().splitlines()
        except OSError:
            pass
    events = [f"{time.strftime('%d.%m. %H:%M:%S', time.localtime(e['ts']))}  {e['level'].upper():5}  {e['text']}"
              for e in reversed(engine.db.events(150))]
    h._send(200, {"path": LOG_FILE, "folder": DATA, "version": APP_VERSION, "log": lines[-300:], "events": events})


@route("POST", r"/api/open-folder")
def open_folder(h):
    import subprocess
    if sys.platform.startswith("win"):
        os.startfile(DATA)   # noqa: S606
    elif sys.platform == "darwin":
        subprocess.Popen(["open", DATA])
    else:
        subprocess.Popen(["xdg-open", DATA], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    h._send(200, {"ok": True, "folder": DATA})


@route("GET", r"/api/pine")
def pine(h):
    h._send(200, {"source": pine_source()})


@route("POST", r"/api/hook-confirm")
def hook_confirm(h):
    engine.update_cfg({"hook_confirmed": hook_url()})
    h._send(200, {"ok": True})


@route("POST", r"/api/autostart")
def autostart(h):
    set_autostart(bool(h._json().get("on")), LAUNCHER, DATA)
    h._send(200, {"ok": True, "autostart": autostart_enabled()})


@route("POST", r"/api/config")
def config(h):
    before = (engine.cfg.get("tunnel") or {}).get("ngrok_token", "")
    res = engine.update_cfg(h._json())
    if (engine.cfg.get("tunnel") or {}).get("ngrok_token", "") != before and not os.environ.get("FVG_NO_TUNNEL"):
        tunnel.restart()
        engine.db.log("Internet-Verbindung wird mit " + ("fester Adresse (ngrok)" if engine.cfg["tunnel"]["ngrok_token"] else "wechselnder Adresse") + " neu aufgebaut")
    h._send(200, res)


@route("POST", r"/api/token")
def token(h):
    engine.regenerate_token()
    h._send(200, {"ok": True})


@route("POST", r"/api/signal/([a-f0-9]+)/accept")
def accept(h, sid):
    h._send(200, engine.accept(sid, h._json()))


@route("POST", r"/api/signal/([a-f0-9]+)/reject")
def reject(h, sid):
    h._send(200, engine.reject(sid))


@route("POST", r"/api/position/([a-f0-9]+)/close")
def close(h, pid):
    h._send(200, engine.close_position(pid))


@route("POST", r"/api/position/([a-f0-9]+)/breakeven")
def breakeven(h, pid):
    h._send(200, engine.move_to_breakeven(pid))


@route("POST", r"/api/flatten")
def flatten(h):
    h._send(200, engine.flatten_all())


@route("POST", r"/api/test-signal")
def test_signal(h):
    b = h._json()
    h._send(200, engine.test_signal(b.get("fam", "NQ"), b.get("side", "long")))


@route("POST", r"/api/broker/test")
def broker_test(h):
    h._send(200, engine.test_broker())


@route("POST", r"/api/learn")
def learn(h):
    engine.learn()
    h._send(200, engine.learning_view())


@route("POST", r"/api/paper/reset")
def paper_reset(h):
    engine.reset_paper()
    h._send(200, {"ok": True})


class AppServer(ThreadingHTTPServer):
    """Belegt den Port exklusiv. Unter Windows erlaubt Python sonst, dass mehrere Instanzen denselben Port teilen –
    dann laufen unbemerkt alte Versionen weiter."""
    daemon_threads = True
    allow_reuse_address = not sys.platform.startswith("win")

    def server_bind(self):
        import socket
        if sys.platform.startswith("win") and hasattr(socket, "SO_EXCLUSIVEADDRUSE"):
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        super().server_bind()


def _running_version():
    """Fragt eine eventuell laufende Instanz nach ihrer Version. None = nichts läuft, "alt" = ältere Version ohne Abfrage."""
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(f"http://127.0.0.1:{PORT}/api/version", timeout=2) as r:
            return json.loads(r.read()).get("version") or "alt"
    except urllib.error.HTTPError:
        return "alt"
    except Exception:  # noqa: BLE001
        return None


def _port_owners():
    """Windows: Prozess-IDs, die den App-Port belegen (netstat, unabhängig von der Systemsprache)."""
    import subprocess
    try:
        out = subprocess.run(["netstat", "-ano", "-p", "tcp"], capture_output=True, text=True, errors="replace",
                             timeout=20, creationflags=0x08000000).stdout
    except Exception:  # noqa: BLE001
        return set()
    pids = set()
    for line in out.splitlines():
        t = line.split()
        if len(t) >= 5 and t[1].endswith(f":{PORT}") and t[2] in ("0.0.0.0:0", "[::]:0") and t[-1].isdigit():
            if int(t[-1]) not in (0, os.getpid()):
                pids.add(int(t[-1]))
    return pids


def _kill_port_owners():
    import subprocess
    killed = []
    for _ in range(5):
        pids = _port_owners()
        if not pids:
            break
        for pid in pids:
            subprocess.run(["taskkill", "/F", "/T", "/PID", str(pid)], capture_output=True, timeout=20, creationflags=0x08000000)
            killed.append(str(pid))
        time.sleep(1)
    return killed


def _kill_other_instances():
    """Windows: alle anderen FVG-Trader-Prozesse beenden (alte Versionen, andere Kopien der Datei)."""
    import subprocess
    if not sys.platform.startswith("win"):
        return []
    ps = ("Get-CimInstance Win32_Process | Where-Object { $_.Name -match '^(python|pythonw|py|pyw)\\.exe$' -and "
          "$_.CommandLine -like '*FVG-Trader*' -and $_.ProcessId -ne %d -and $_.ProcessId -ne %d } | "
          "ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; $_.ProcessId }") % (os.getpid(), os.getppid())
    try:
        out = subprocess.run(["powershell", "-NoProfile", "-Command", ps], capture_output=True, text=True,
                             timeout=40, creationflags=0x08000000).stdout
        return [x for x in out.split() if x.isdigit()]
    except Exception as e:  # noqa: BLE001
        print(f"Aufräumen alter Instanzen fehlgeschlagen: {e}", flush=True)
        return []


def main():
    global SRV
    srv = None
    if sys.platform.startswith("win"):
        rv = _running_version()
        if rv and rv != "alt" and _vtuple(rv) >= _vtuple(APP_VERSION) and not BACKGROUND:
            print(f"FVG Trader {rv} läuft bereits, das Fenster wird geöffnet.", flush=True)
            open_app_window(f"http://localhost:{PORT}")
            return
        print(f"Start: laufende Instanz = {rv or 'keine'}", flush=True)
        killed = _kill_port_owners() + _kill_other_instances()   # ältere oder hängende Instanzen ablösen
        if killed:
            print(f"Ältere FVG-Trader-Prozesse beendet: {', '.join(sorted(set(killed)))}", flush=True)
            time.sleep(1.5)
        still = _port_owners()
        if still:
            print(f"Port {PORT} noch belegt von: {', '.join(map(str, still))}", flush=True)
    for attempt in range(60):   # nach einem Update kann der Port noch kurz von der alten Version belegt sein
        try:
            srv = AppServer((HOST, PORT), Handler)
            break
        except OSError:
            if ("--hintergrund" in sys.argv or (sys.platform.startswith("win") and attempt < 15)) and attempt < 59:
                time.sleep(1)
                continue
            srv = None
            break
    SRV = srv
    if srv is None:
        print(f"\n  FVG Trader läuft bereits, das Fenster wird geöffnet.\n")
        open_app_window(f"http://localhost:{PORT}")
        return
    engine.db.log(f"FVG Trader {APP_VERSION} gestartet ({LAUNCHER})")
    print(f"FVG Trader {APP_VERSION} gestartet", flush=True)
    if not os.environ.get("FVG_NO_TUNNEL"):
        tunnel.start()
    url = f"http://localhost:{PORT}"
    print(f"\n  FVG Trader läuft:  {url}")
    print("  Webhook bereit (Adresse in der App unter Einstellungen → TradingView)")
    print("  Dieses Fenster offen lassen (darf minimiert sein). Beenden mit Strg+C.\n")
    if os.environ.get("FVG_NO_BROWSER") != "1" and not BACKGROUND:
        threading.Timer(1.0, lambda: open_app_window(url)).start()
    threading.Thread(target=ensure_desktop_shortcut, args=(LAUNCHER, DATA, engine.db.log), daemon=True).start()
    threading.Thread(target=_update_loop, daemon=True).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\n  Beendet.")
    finally:
        tunnel.stop()


if __name__ == "__main__":
    main()
