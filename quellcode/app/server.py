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
from appshell import MANIFEST, SERVICE_WORKER, autostart_enabled, ensure_desktop_shortcut, icon_png, open_app_window, service_install, service_installed, service_remove, set_autostart, windowless_python  # noqa: E402,E501

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.environ.get("FVG_DATA", os.path.join(ROOT, "data"))
STATIC = os.path.join(ROOT, "app", "static")
HOST = os.environ.get("FVG_HOST", "127.0.0.1")
PORT = int(os.environ.get("FVG_PORT", "8787"))
BACKGROUND = "--hintergrund" in sys.argv
SERVICE = "--dienst" in sys.argv   # läuft als Dienst (Windows-Aufgabenplanung, Start ohne Anmeldung)
_svc_cache = {"t": 0, "v": False}


REMOTE = {"month": "", "n": 0, "dirty": 0, "kinds": {}}


def _remote_file():
    return os.path.join(DATA, "anfragen.json")


def count_remote(h):
    """Zählt Anfragen, die über die Internet-Verbindung (ngrok/Cloudflare) kommen. ngrok kostenlos: 20.000 im Monat."""
    if not (h.headers.get("X-Forwarded-For") or h.headers.get("Cf-Connecting-Ip")):
        return
    m = time.strftime("%Y-%m")
    if not REMOTE["month"]:
        try:
            with open(_remote_file(), encoding="utf-8") as f:
                REMOTE.update(json.load(f))
        except (OSError, ValueError):
            pass
    if REMOTE["month"] != m:
        REMOTE.update(month=m, n=0, kinds={})
    REMOTE["n"] += 1
    h._remote = True
    if not h.path.startswith("/webhook/"):
        _remote_kind("app")
    REMOTE["dirty"] += 1
    if REMOTE["dirty"] >= 20:
        REMOTE["dirty"] = 0
        try:
            with open(_remote_file(), "w", encoding="utf-8") as f:
                json.dump({"month": REMOTE["month"], "n": REMOTE["n"], "kinds": REMOTE.get("kinds") or {}}, f)
        except OSError:
            pass


def _remote_kind(kind):
    k = REMOTE.setdefault("kinds", {})
    k[kind] = k.get(kind, 0) + 1


def remote_view(limit):
    """Verbrauch diesen Monat, aufgeteilt nach Art, und Hochrechnung bis Monatsende."""
    import calendar
    now = time.localtime()
    n = REMOTE["n"] if REMOTE["month"] == time.strftime("%Y-%m") else 0
    days = calendar.monthrange(now.tm_year, now.tm_mon)[1]
    elapsed = max(0.25, now.tm_mday - 1 + now.tm_hour / 24 + now.tm_min / 1440)
    kinds = (REMOTE.get("kinds") or {}) if REMOTE["month"] == time.strftime("%Y-%m") else {}
    return {"month": REMOTE["month"], "n": n, "limit": limit, "kinds": kinds,
            "projection": round(n / elapsed * days) if now.tm_mday > 1 or now.tm_hour >= 6 else None, "days": days}


def service_state():
    if time.time() - _svc_cache["t"] > 60:
        _svc_cache.update(t=time.time(), v=service_installed())
    return {"installed": _svc_cache["v"], "running": SERVICE}
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
engine.news_source = lambda: NEWS["events"]
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
        if n > (250_000_000 if self.path.startswith("/api/disc/import") else 40_000_000 if self.path.startswith("/api/backtest/") else
                9_000_000 if self.path.startswith(("/api/update/", "/api/own/import", "/api/trade/")) else 100_000):
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
        count_remote(self)
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
    txt = raw.decode("utf-8", "replace") if isinstance(raw, (bytes, bytearray)) else str(raw)
    if "{{" in txt and "}}" in txt:
        # TradingView hat den Platzhalter nicht ersetzt: Der Alert hängt nicht an der Strategie (z. B. Kurs-Alarm)
        engine.alert_issue = {"ts": time.time(), "text": txt[:120]}
        engine.db.log("Alert falsch eingerichtet: TradingView schickt den Platzhalter statt der Daten. "
                      "Im Alert als Bedingung die Strategie „FVG Bot“ wählen (nicht NQ1!) und "
                      "„Orderausführungen und alert()-Aufrufe“.", "error")
        return h._send(400, {"error": "Platzhalter nicht ersetzt: Alert muss an der Strategie hängen"})
    try:
        payload = json.loads(raw)
    except ValueError:
        engine.db.log(f"Webhook ohne gültiges JSON empfangen: {raw[:80]!r}", "error")
        return h._send(400, {"error": "Kein gültiges JSON"})
    if isinstance(payload, dict) and payload.get("type") == "ping":
        return h._send(200, {"ok": True, "pong": True})   # Selbsttest der Internet-Verbindung, zählt nicht als TradingView
    try:
        res = engine.handle_webhook(payload)
    except ValueError as e:
        engine.db.log(f"Webhook abgelehnt: {e}", "error")
        return h._send(400, {"error": str(e)})
    engine.alert_issue = None
    if getattr(h, "_remote", False):
        _remote_kind({"bar": "kerzen", "tick": "live"}.get(str(payload.get("type")), "signale"))
    # Kommt hier etwas an, nutzt der TradingView-Alert die aktuelle Adresse: Erinnerung automatisch abhaken
    cur = hook_url()
    if cur and engine.cfg.get("hook_confirmed") != cur:
        try:
            engine.update_cfg({"hook_confirmed": cur})
            engine.db.log("TradingView sendet an die aktuelle Webhook-Adresse")
        except ValueError:
            pass
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
    h._send(200, {"version": APP_VERSION, "pid": os.getpid(), "service": SERVICE})


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
    s["service"] = service_state()
    if not REMOTE["month"]:
        try:
            with open(_remote_file(), encoding="utf-8") as f:
                REMOTE.update(json.load(f))
        except (OSError, ValueError):
            REMOTE["month"] = time.strftime("%Y-%m")
    s["remote"] = remote_view(20000 if (s.get("tunnel") or {}).get("provider") == "ngrok" else None)
    s["version"] = APP_VERSION
    s["launcher"] = LAUNCHER
    s["update"] = UPDATE.copy()
    s["alert_issue"] = getattr(engine, "alert_issue", None)
    s["health"] = server_health(s)
    h._send(200, s)


# ───────────────────────── Wirtschafts-News (Forex-Factory-Kalender) ─────────────────────────
NEWS_URL = "https://nfs.faireconomy.media/ff_calendar_thisweek.json"
NEWS = {"events": [], "fetched": 0, "error": None, "loading": False}
_news_lock = threading.Lock()


def _news_load_cache():
    try:
        with open(os.path.join(DATA, "news.json"), encoding="utf-8") as f:
            NEWS.update(json.load(f))
    except (OSError, ValueError):
        pass
    NEWS["loading"] = False


def _news_parse(raw):
    from datetime import datetime
    out = []
    for e in raw if isinstance(raw, list) else []:
        try:
            ts = int(datetime.fromisoformat(str(e.get("date", "")).replace("Z", "+00:00")).timestamp() * 1000)
        except ValueError:
            continue
        imp = str(e.get("impact", "")).strip().lower()
        out.append({"ts": ts, "title": str(e.get("title", ""))[:120], "country": str(e.get("country", ""))[:8],
                    "impact": {"high": "high", "medium": "medium", "low": "low", "holiday": "holiday"}.get(imp, "low"),
                    "forecast": str(e.get("forecast") or "")[:20], "previous": str(e.get("previous") or "")[:20],
                    "actual": str(e.get("actual") or "")[:20]})
    out.sort(key=lambda x: x["ts"])
    return out


def _news_fetch():
    try:
        req = urllib.request.Request(NEWS_URL, headers={"User-Agent": "FVG-Trader"})
        with urllib.request.urlopen(req, timeout=20) as r:
            events = _news_parse(json.loads(r.read().decode("utf-8", "replace")))
        NEWS.update(events=events, fetched=time.time(), error=None)
        with open(os.path.join(DATA, "news.json"), "w", encoding="utf-8") as f:
            json.dump({"events": events, "fetched": NEWS["fetched"]}, f)
    except Exception as e:  # noqa: BLE001
        NEWS["error"] = "News konnten nicht geladen werden" + (" (zu viele Abrufe, später erneut)" if "429" in str(e) else "")
        NEWS["fetched_try"] = time.time()
    finally:
        NEWS["loading"] = False


def _news_loop():
    """Wirtschaftskalender auch ohne offenes App-Fenster aktuell halten (für die News-Pause)."""
    _news_load_cache()
    while True:
        news_refresh()
        time.sleep(600)


def news_refresh(force=False):
    """Höchstens alle 60 Minuten abrufen (die Quelle sperrt bei zu vielen Anfragen), nach Fehler 10 Minuten warten."""
    with _news_lock:
        if NEWS["loading"]:
            return
        age = time.time() - NEWS.get("fetched", 0)
        retry = time.time() - NEWS.get("fetched_try", 0)
        if not force and age < 3600:
            return
        if retry < (60 if force else 600):
            return
        NEWS["loading"] = True
        NEWS["fetched_try"] = time.time()
    threading.Thread(target=_news_fetch, daemon=True).start()


@route("GET", r"/api/news")
def news(h):
    if not NEWS["fetched"] and not NEWS["loading"] and "fetched_try" not in NEWS:
        _news_load_cache()
    news_refresh()
    h._send(200, {"events": NEWS["events"], "fetched": NEWS["fetched"], "error": NEWS["error"], "loading": NEWS["loading"]})


@route("POST", r"/api/news/refresh")
def news_force(h):
    news_refresh(force=True)
    h._send(200, {"ok": True})


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
        info = None
        # Zuerst direkt über die GitHub-API lesen: raw.githubusercontent.com hält Dateien einige Minuten im Zwischenspeicher
        m = re.match(r"^https://raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/]+)/(.+)$", src)
        if m:
            api = f"https://api.github.com/repos/{m.group(1)}/{m.group(2)}/contents/{m.group(4)}?ref={m.group(3)}"
            try:
                req = urllib.request.Request(api, headers={"User-Agent": f"FVG-Trader/{APP_VERSION}", "Accept": "application/vnd.github.raw"})
                with urllib.request.urlopen(req, timeout=20) as r:
                    info = json.loads(r.read(100_000).decode("utf-8"))
            except Exception:  # noqa: BLE001
                info = None
        if info is None:
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
                        "rem Startet FVG Trader nach einem Update neu (unsichtbar, ohne Konsolenfenster)\r\n"
                        "ping -n 3 127.0.0.1 >nul\r\n"
                        + (f'start "" "{windowless_python()}" "{LAUNCHER}" --hintergrund --dienst\r\n' if SERVICE
                           else f'call "{LAUNCHER}" --hintergrund\r\n'))
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


def _download_install():
    """Neue Version laden und einspielen (mit Wiederholung, falls GitHub kurz eine alte Datei liefert)."""
    for attempt in range(3):
        data = _fetch(UPDATE["file"])
        try:
            return install_update(data, UPDATE.get("sha256"))
        except ValueError as e:
            if "Prüfsumme" not in str(e) or attempt == 2:
                raise
            engine.db.log("Update: Prüfsumme passt noch nicht, lade erneut …", "warn")
            time.sleep(4)
            check_update()


def _update_loop():
    time.sleep(20)
    last_check = 0
    while True:
        auto = bool(engine.cfg.get("auto_update"))
        # mit automatischen Updates öfter nachsehen (stündlich), sonst alle 6 Stunden
        if engine.cfg.get("update_url") and time.time() - last_check >= (3600 if auto else 6 * 3600):
            last_check = time.time()
            was = UPDATE.get("available")
            check_update()
            if UPDATE["available"] and not was:
                engine.db.log(f"Update verfügbar: Version {UPDATE['version']}")
        if auto and UPDATE.get("available") and not UPDATE.get("busy"):
            if engine.db.open_positions() or engine.db.pending():
                pass   # nie mitten im Trade oder bei offenem Vorschlag: später nochmal versuchen
            else:
                UPDATE["busy"] = True
                try:
                    engine.db.log(f"Automatisches Update auf Version {UPDATE['version']} …")
                    _download_install()
                except Exception as e:  # noqa: BLE001
                    engine.db.log(f"Automatisches Update fehlgeschlagen: {e}", "error")
                finally:
                    UPDATE["busy"] = False
        time.sleep(300)


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
        v = _download_install()
    finally:
        UPDATE["busy"] = False
    h._send(200, {"ok": True, "version": v})


@route("POST", r"/api/update/upload")
def update_upload(h):
    n = int(h.headers.get("Content-Length") or 0)
    data = h.rfile.read(n)
    v = install_update(data)
    h._send(200, {"ok": True, "version": v})


@route("POST", r"/api/shortcut")
def shortcut(h):
    if not sys.platform.startswith("win"):
        raise ValueError("Desktop-Symbole gibt es nur unter Windows")
    try:
        os.remove(os.path.join(DATA, "verknuepfung.txt"))
    except OSError:
        pass
    ensure_desktop_shortcut(LAUNCHER, DATA, engine.db.log)
    h._send(200, {"ok": True})


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


@route("GET", r"/api/levels/(NQ|ES|auto)")
def levels(h, fam):
    with engine.lock:
        h._send(200, engine.levels(None if fam == "auto" else fam))


@route("GET", r"/api/sessions/(NQ|ES|auto)")
def session_stats(h, fam):
    with engine.lock:
        h._send(200, engine.session_stats(None if fam == "auto" else fam))


@route("GET", r"/api/lab/variants")
def lab_variants(h):
    with engine.lock:
        h._send(200, engine.variant_view())


@route("GET", r"/api/lab/rules")
def lab_rules(h):
    with engine.lock:
        h._send(200, engine.rules_find())


@route("GET", r"/api/chart/(NQ|ES|auto)/(\d{1,2})/(1|5|15)")
def chart(h, fam, days, tf):
    with engine.lock:
        h._send(200, engine.chart_data(None if fam == "auto" else fam, max(1, min(10, int(days))), int(tf)))


@route("GET", r"/api/edge")
def edge(h):
    h._send(200, engine.edge_data())


@route("POST", r"/api/own/add")
def own_add(h):
    h._send(200, engine.own_add(h._json()))


# ───────────────────────── Backtest: Trade-Liste aus dem TradingView-Strategietester ─────────────────────────
def _bt_xlsx(data):
    """Minimaler Excel-Leser (ohne Zusatzpakete): Blattnamen und Zellwerte als Zeilen."""
    import io
    import zipfile
    import xml.etree.ElementTree as ET
    ns = {"m": "http://schemas.openxmlformats.org/spreadsheetml/2006/main",
          "r": "http://schemas.openxmlformats.org/officeDocument/2006/relationships",
          "p": "http://schemas.openxmlformats.org/package/2006/relationships"}
    z = zipfile.ZipFile(io.BytesIO(data))
    shared = []
    if "xl/sharedStrings.xml" in z.namelist():
        for si in ET.fromstring(z.read("xl/sharedStrings.xml")).findall("m:si", ns):
            shared.append("".join(t.text or "" for t in si.iter("{%s}t" % ns["m"])))
    rels = {r.get("Id"): r.get("Target") for r in ET.fromstring(z.read("xl/_rels/workbook.xml.rels")).findall("p:Relationship", ns)}
    out = []
    for sh in ET.fromstring(z.read("xl/workbook.xml")).find("m:sheets", ns).findall("m:sheet", ns):
        target = rels.get(sh.get("{%s}id" % ns["r"]), "")
        path = target.lstrip("/") if target.startswith("/") else "xl/" + target
        if path not in z.namelist():
            continue
        rows = []
        for row in ET.fromstring(z.read(path)).iter("{%s}row" % ns["m"]):
            vals = {}
            for c in row.findall("m:c", ns):
                ref, t = c.get("r", ""), c.get("t")
                col = 0
                for ch in ref:
                    if ch.isalpha():
                        col = col * 26 + (ord(ch.upper()) - 64)
                v = c.find("m:v", ns)
                if t == "s" and v is not None:
                    val = shared[int(v.text)]
                elif t == "inlineStr":
                    val = "".join(x.text or "" for x in c.iter("{%s}t" % ns["m"]))
                elif v is not None and v.text is not None:
                    try:
                        val = float(v.text) if t not in ("str", "e") else v.text
                    except ValueError:
                        val = v.text
                else:
                    val = ""
                vals[col - 1] = val
            if vals:
                rows.append([vals.get(i, "") for i in range(max(vals) + 1)])
            if len(rows) > 50000:
                break
        out.append({"name": sh.get("name"), "rows": rows})
    return out


def _bt_csv(data):
    import csv
    import io
    for enc in ("utf-8-sig", "cp1252", "latin-1"):
        try:
            text = data.decode(enc)
            break
        except UnicodeDecodeError:
            continue
    first = text.split("\n", 1)[0]
    delim = max((";", ",", "\t"), key=first.count)
    return [{"name": "CSV", "rows": [r for r in csv.reader(io.StringIO(text), delimiter=delim)][:50000]}]


@route("POST", r"/api/backtest/read")
def backtest_read(h):
    import base64
    b = h._json()
    data = base64.b64decode(b.get("data") or "")
    name = str(b.get("name") or "")
    try:
        sheets = _bt_xlsx(data) if data[:2] == b"PK" else _bt_csv(data)
    except Exception as e:  # noqa: BLE001
        raise ValueError(f"Datei konnte nicht gelesen werden ({e}). Bitte als CSV oder Excel aus TradingView exportieren.")
    h._send(200, {"name": name, "sheets": sheets})


@route("POST", r"/api/backtest/save")
def backtest_save(h):
    b = h._json()
    trades = b.get("trades") or []
    if not isinstance(trades, list) or len(trades) > 50000:
        raise ValueError("Ungültige Trade-Liste")
    with open(os.path.join(DATA, "backtest.json"), "w", encoding="utf-8") as f:
        json.dump({"name": str(b.get("name") or "")[:200], "saved": time.time(), "trades": trades}, f)
    h._send(200, {"ok": True})


@route("GET", r"/api/backtest/live")
def backtest_live(h):
    with engine.lock:
        h._send(200, engine.live_backtest())


@route("GET", r"/api/backtest")
def backtest_get(h):
    try:
        with open(os.path.join(DATA, "backtest.json"), encoding="utf-8") as f:
            h._send(200, json.load(f))
    except (OSError, ValueError):
        h._send(200, {"trades": []})


@route("POST", r"/api/own/import")
def own_import(h):
    b = h._json()
    h._send(200, engine.own_import(str(b.get("csv") or ""), bool(b.get("subtract_fees", True))))


@route("POST", r"/api/own/sync")
def own_sync(h):
    h._send(200, engine.own_sync())


@route("POST", r"/api/topstep/test")
def topstep_test(h):
    h._send(200, engine.test_topstep())


@route("POST", r"/api/tradovate/test")
def tradovate_test(h):
    h._send(200, engine.test_tradovate())


@route("POST", r"/api/tests/delete")
def tests_delete(h):
    h._send(200, engine.delete_tests())


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


@route("POST", r"/api/service")
def service(h):
    on = bool(h._json().get("on"))
    if on:
        if autostart_enabled():
            set_autostart(False, LAUNCHER, DATA)   # sonst startet nach der Anmeldung eine zweite Kopie
        service_install(LAUNCHER, DATA)
        engine.db.log("Dienst eingerichtet: FVG Trader startet ab jetzt beim Hochfahren, auch ohne Anmeldung")
    else:
        service_remove(DATA)
        engine.db.log("Dienst entfernt: FVG Trader startet nicht mehr automatisch beim Hochfahren")
    _svc_cache["t"] = 0
    h._send(200, {"ok": True, "service": service_state()})


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


@route("POST", r"/api/position/([a-f0-9]+)/modify")
def pos_modify(h, pid):
    b = h._json()
    h._send(200, engine.modify_position(pid, sl=b.get("sl"), tp=b.get("tp"), clear_tp=bool(b.get("clear_tp"))))


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


# ───────────────────────── Discord, Gesundheit, Berichte, Journal ─────────────────────────
DISCORD_COLORS = {"good": 0x22C55E, "bad": 0xEF4444, "warn": 0xF59E0B, "info": 0x3B82F6}


def _discord_post(url, msg):
    payload = {"username": "FVG Trader", "embeds": [{
        "title": msg["title"][:250], "description": msg["text"][:3900],
        "color": DISCORD_COLORS.get(msg.get("tone"), 0x3B82F6),
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(msg.get("ts") or time.time()))}]}
    req = urllib.request.Request(url, data=json.dumps(payload).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "User-Agent": f"FVG-Trader/{APP_VERSION}"})
    with urllib.request.urlopen(req, timeout=15) as r:
        r.read()


def _discord_loop():
    while True:
        time.sleep(1.5)
        if not engine.outbox:
            continue
        url = (engine.cfg.get("discord") or {}).get("url")
        if not url:
            engine.outbox.clear()
            continue
        msg = engine.outbox[0]
        try:
            _discord_post(url, msg)
            engine.outbox.pop(0)
            engine.discord_state.update(last=time.time(), error="")
        except urllib.error.HTTPError as e:
            if e.code == 429:
                time.sleep(5)
                continue
            engine.outbox.pop(0)
            engine.discord_state["error"] = f"Discord lehnt ab (HTTP {e.code}) – Webhook-URL prüfen"
        except Exception as e:  # noqa: BLE001
            msg["tries"] = msg.get("tries", 0) + 1
            if msg["tries"] >= 5:
                engine.outbox.pop(0)
            engine.discord_state["error"] = f"Discord nicht erreichbar ({e.__class__.__name__})"
            time.sleep(10)


@route("POST", r"/api/discord/test")
def discord_test(h):
    b = h._json()
    url = (b.get("url") or "").strip()
    if not url or url == "••••••••":
        url = (engine.cfg.get("discord") or {}).get("url")
    if not url:
        raise ValueError("Bitte zuerst die Discord-Webhook-URL eintragen")
    if not re.match(r"^https://(discord\.com|discordapp\.com|ptb\.discord\.com|canary\.discord\.com)/api/webhooks/\d+/[\w-]+$", url):
        raise ValueError("Das ist keine Discord-Webhook-URL (https://discord.com/api/webhooks/…)")
    try:
        _discord_post(url, {"title": "✅ FVG Trader ist verbunden", "tone": "good",
                            "text": "Ab jetzt bekommst du hier Nachrichten zu Trades, Fehlern, Tages-Stopp und den Berichten."})
    except urllib.error.HTTPError as e:
        raise ValueError(f"Discord lehnt ab (HTTP {e.code}). Ist die Webhook-URL vollständig und noch gültig?")
    except Exception as e:  # noqa: BLE001
        raise ValueError(f"Discord nicht erreichbar: {e}")
    engine.discord_state.update(last=time.time(), error="")
    h._send(200, {"ok": True})


def server_health(s):
    """Ergänzt den Gesundheits-Check der Engine um Verbindung, ngrok-Kontingent, News und Updates."""
    items = list(s.get("health") or [])
    tn = s.get("tunnel") or {}
    if os.environ.get("FVG_NO_TUNNEL"):
        pass
    elif engine.cfg.get("public_url"):
        items.insert(1, {"key": "tunnel", "label": "Webhook-Adresse", "status": "ok", "text": "eigene feste Adresse"})
    else:
        items.insert(1, {"key": "tunnel", "label": "Webhook-Adresse", "status": "ok" if tn.get("ok") else "bad",
                         "text": (tn.get("provider") or "Tunnel") + (" verbunden" if tn.get("ok") else ": " + str(tn.get("status") or "getrennt"))})
    rm = s.get("remote") or {}
    if rm.get("limit"):
        used = rm["n"] / rm["limit"] * 100
        day = int(time.strftime("%d"))
        pj = rm.get("projection")
        st = "ok" if used < 75 and (not pj or pj < rm["limit"] * 0.9) else "warn" if used < 95 else "bad"
        items.append({"key": "quota", "label": "ngrok-Kontingent", "status": st,
                      "text": f"{rm['n']:,} von {rm['limit']:,} Anfragen ({used:.0f} %, Tag {day})".replace(",", ".")
                      + (f" · Hochrechnung {pj:,} bis Monatsende".replace(",", ".") if pj else "")})
    if NEWS.get("error"):
        items.append({"key": "news", "label": "News-Kalender", "status": "warn", "text": NEWS["error"]})
    elif NEWS.get("fetched"):
        age = time.time() - NEWS["fetched"]
        items.append({"key": "news", "label": "News-Kalender", "status": "ok" if age < 6 * 3600 else "warn",
                      "text": f"{len(NEWS['events'])} Termine, aktualisiert vor {max(1, int(age // 60))} Min"})
    up = s.get("update") or {}
    if up.get("available"):
        items.append({"key": "update", "label": "Update", "status": "warn", "text": f"Version {up.get('version')} verfügbar"})
    return items


@route("GET", r"/api/timeline/(\d{4}-\d{2}-\d{2})")
def timeline_day(h, day):
    with engine.lock:
        h._send(200, engine.timeline(day))


@route("GET", r"/api/report/week/(\d{1,3})")
def report_week(h, off):
    with engine.lock:
        h._send(200, engine.weekly_report(int(off)))


@route("POST", r"/api/report/week/(\d{1,3})/discord")
def report_week_discord(h, off):
    with engine.lock:
        rep = engine.weekly_report(int(off))
        if not (engine.cfg.get("discord") or {}).get("url"):
            raise ValueError("Discord ist noch nicht eingerichtet (Einstellungen → Benachrichtigungen)")
        engine.outbox.append({"title": f"Wochenbericht {rep['monday'][8:10]}.{rep['monday'][5:7]}.–{rep['friday'][8:10]}.{rep['friday'][5:7]}.",
                              "text": engine.weekly_text(rep), "tone": "good" if rep["net"] > 0 else "bad" if rep["net"] < 0 else "info",
                              "ts": time.time()})
    h._send(200, {"ok": True})


def _bt_saved():
    try:
        with open(os.path.join(DATA, "backtest.json"), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {"trades": []}


@route("GET", r"/api/compare/(gleich|alles)")
def compare(h, mode):
    bt = _bt_saved()
    with engine.lock:
        res = engine.compare_backtest(bt.get("trades") or [], same_period=mode == "gleich")
    res["bt_name"] = bt.get("name")
    h._send(200, res)


@route("GET", r"/api/montecarlo/(auto|bot|eigen|alle|signale|backtest)/(jetzt|neu)")
def montecarlo(h, src, mode):
    bt = _bt_saved().get("trades") or []
    with engine.lock:
        h._send(200, engine.monte_carlo(src, bt=bt, fresh=mode == "neu"))


@route("POST", r"/api/trade/([a-f0-9]{6,16})/journal")
def trade_journal(h, pid):
    h._send(200, engine.journal_set(pid, h._json().get("text")))


@route("POST", r"/api/trade/([a-f0-9]{6,16})/shot")
def trade_shot(h, pid):
    import base64
    data = str(h._json().get("data") or "")
    if "," in data[:100]:
        data = data.split(",", 1)[1]
    h._send(200, engine.shot_add(pid, base64.b64decode(data)))


@route("POST", r"/api/trade/([a-f0-9]{6,16})/shot/delete")
def trade_shot_delete(h, pid):
    h._send(200, engine.shot_delete(pid, str(h._json().get("name") or "")))


@route("GET", r"/api/shot/([a-f0-9]{6,16}_[a-f0-9]{8}\.(png|jpg|webp))")
def shot_get(h, name, ext):
    full = os.path.join(engine.shots_dir(), name)
    if not os.path.isfile(full):
        return h._send(404, {"error": "Bild nicht gefunden"})
    with open(full, "rb") as f:
        h._send(200, f.read(), {"png": "image/png", "jpg": "image/jpeg", "webp": "image/webp"}[ext],
                headers={"Cache-Control": "private, max-age=86400"})


@route("GET", r"/api/lab/sessions")
def lab_sessions(h):
    h._send(200, engine.session_targets_view())


@route("POST", r"/api/lab/sessions/refresh")
def lab_sessions_refresh(h):
    engine.learn_paths_async(adopt=False)
    h._send(200, {"ok": True})


@route("POST", r"/api/lab/sessions/apply")
def lab_sessions_apply(h):
    b = h._json()
    key = str(b.get("key") or "")[:60]
    if not key:
        raise ValueError("Session fehlt")
    val = None if b.get("remove") else {"f": float(b.get("f")), "g": float(b.get("g")), "added": time.time(), "auto": False}
    engine.update_cfg({"session_scale": {key: val}})
    if engine.sfit:
        engine.sfit = engine.session_fit()
    h._send(200, {"ok": True})


@route("GET", r"/api/disc")
def disc_get(h):
    h._send(200, engine.disc_view())


@route("POST", r"/api/balance")
def balance_set(h):
    h._send(200, engine.set_balance((h._json() or {}).get("value")))


@route("POST", r"/api/calendar/clear")
def calendar_clear(h):
    h._send(200, engine.calendar_clear(restore=bool((h._json() or {}).get("restore"))))


@route("GET", r"/api/confluence")
def confluence_get(h):
    h._send(200, engine.confluence_view())


@route("POST", r"/api/learn/reset")
def learn_reset(h):
    h._send(200, engine.reset_learning("von Hand"))


@route("POST", r"/api/disc/run")
def disc_run(h):
    engine.disc_async()
    h._send(200, {"ok": True})


@route("POST", r"/api/disc/item")
def disc_item(h):
    b = h._json()
    h._send(200, engine.disc_action(str(b.get("id") or ""), str(b.get("action") or "")))


@route("POST", r"/api/disc/import")
def disc_import(h):
    b = h._json()
    text = str(b.pop("csv", "") or "")
    fam = str(b.get("fam") or "")
    b.clear()
    res = engine.import_ohlc(fam, text)   # ohne die Engine zu sperren: Signale laufen währenddessen weiter
    h._send(200, res)


@route("POST", r"/api/hook/selftest")
def hook_selftest(h):
    """Schickt eine Test-Nachricht über das Internet (ngrok) an die eigene Webhook-Adresse – genau wie TradingView."""
    url = hook_url()
    if not url:
        raise ValueError("Noch keine Webhook-Adresse – die Internet-Verbindung steht noch nicht")
    t0 = time.time()
    try:
        req = urllib.request.Request(url, data=b'{"type":"ping"}', method="POST",
                                     headers={"Content-Type": "application/json", "User-Agent": "FVG-Trader-Selbsttest"})
        with urllib.request.urlopen(req, timeout=20) as r:
            ok = json.loads(r.read() or b"{}").get("pong")
    except urllib.error.HTTPError as e:
        raise ValueError(f"Über das Internet nicht erreichbar (HTTP {e.code}). "
                         + ("ngrok-Kontingent aufgebraucht oder Adresse belegt." if e.code in (402, 429, 502, 503, 504) else ""))
    except Exception as e:  # noqa: BLE001
        raise ValueError(f"Über das Internet nicht erreichbar: {e}")
    if not ok:
        raise ValueError("Unter der Adresse antwortet nicht diese App – Webhook-Adresse in TradingView prüfen")
    h._send(200, {"ok": True, "ms": round((time.time() - t0) * 1000), "url": url})


@route("GET", r"/api/exits")
def exits(h):
    with engine.lock:
        h._send(200, engine.exit_review())


@route("GET", r"/api/chartview/(NQ|ES|auto)/(\d{4}-\d{2}-\d{2}|last)/(1|2|3|5|15|30|60|240)")
def chartview(h, fam, day, tf):
    with engine.lock:
        h._send(200, engine.chart_view(None if fam == "auto" else fam, None if day == "last" else day, int(tf)))


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
    if not SERVICE:   # der Dienst läuft als SYSTEM und hat keinen eigenen Desktop
        threading.Thread(target=ensure_desktop_shortcut, args=(LAUNCHER, DATA, engine.db.log), daemon=True).start()
    threading.Thread(target=_update_loop, daemon=True).start()
    threading.Thread(target=_news_loop, daemon=True).start()
    threading.Thread(target=_discord_loop, daemon=True).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\n  Beendet.")
    finally:
        tunnel.stop()


if __name__ == "__main__":
    main()
