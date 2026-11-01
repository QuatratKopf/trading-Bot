0<0# : ^
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

# ═════════════════ db.py ═════════════════
"""SQLite-Speicher für Signale, Positionen und Ereignisse."""
import json
import sqlite3
import threading
import time

SCHEMA = """
CREATE TABLE IF NOT EXISTS signals (
    id TEXT PRIMARY KEY,
    ts REAL NOT NULL,
    ticker TEXT, root TEXT, contract TEXT, side TEXT, setup TEXT,
    entry REAL, sl REAL, tp REAL, qty INTEGER, risk_usd REAL,
    flags TEXT, status TEXT, reason TEXT, expires REAL,
    is_test INTEGER DEFAULT 0, raw TEXT, bar_time REAL
);
CREATE TABLE IF NOT EXISTS positions (
    id TEXT PRIMARY KEY,
    signal_id TEXT, broker TEXT, root TEXT, contract TEXT, side TEXT, setup TEXT,
    qty INTEGER, entry REAL, sl REAL, tp REAL, initial_sl REAL,
    opened REAL, closed REAL, exit REAL, pnl REAL,
    status TEXT, close_reason TEXT, broker_ref TEXT, is_test INTEGER DEFAULT 0, bar_time REAL,
    source TEXT, trade_day TEXT, note TEXT
);
CREATE TABLE IF NOT EXISTS shadow (
    id TEXT PRIMARY KEY,
    signal_id TEXT, setup TEXT, fam TEXT, side TEXT,
    entry REAL, sl REAL, tp REAL, opened REAL, closed REAL, exit REAL, r REAL,
    status TEXT, ny_hour INTEGER, ny_weekday INTEGER, bar_time REAL
);
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts REAL NOT NULL, level TEXT, text TEXT
);
"""


class DB:
    def __init__(self, path):
        self.lock = threading.RLock()
        self.con = sqlite3.connect(path, check_same_thread=False)
        self.con.row_factory = sqlite3.Row
        with self.lock:
            self.con.executescript(SCHEMA)
            self._migrate()
            self.con.commit()

    def _migrate(self):
        """Fehlende Spalten nach einem Update ergänzen, ohne Daten zu verlieren."""
        import re
        for table, body in re.findall(r"CREATE TABLE IF NOT EXISTS (\w+) \((.*?)\);", SCHEMA, re.S):
            have = {r[1] for r in self.con.execute(f"PRAGMA table_info({table})")}
            for col in body.split(","):
                parts = col.strip().split(None, 1)
                if len(parts) == 2 and parts[0] not in have and "PRIMARY KEY" not in parts[1]:
                    self.con.execute(f"ALTER TABLE {table} ADD COLUMN {parts[0]} {parts[1]}")

    def _exec(self, sql, args=()):
        with self.lock:
            cur = self.con.execute(sql, args)
            self.con.commit()
            return cur

    def rows(self, sql, args=()):
        with self.lock:
            return [dict(r) for r in self.con.execute(sql, args).fetchall()]

    def one(self, sql, args=()):
        r = self.rows(sql, args)
        return r[0] if r else None

    # --- Signale ---
    def add_signal(self, s):
        cols = list(s.keys())
        vals = [json.dumps(v) if isinstance(v, (list, dict)) else v for v in s.values()]
        self._exec(f"INSERT INTO signals ({','.join(cols)}) VALUES ({','.join('?' * len(cols))})", vals)

    def update_signal(self, sid, **kw):
        if not kw:
            return
        sets = ",".join(f"{k}=?" for k in kw)
        vals = [json.dumps(v) if isinstance(v, (list, dict)) else v for v in kw.values()]
        self._exec(f"UPDATE signals SET {sets} WHERE id=?", vals + [sid])

    def signal(self, sid):
        return self._decode_signal(self.one("SELECT * FROM signals WHERE id=?", (sid,)))

    def signals(self, limit=60):
        return [self._decode_signal(r) for r in self.rows("SELECT * FROM signals ORDER BY ts DESC LIMIT ?", (limit,))]

    def pending(self):
        return [self._decode_signal(r) for r in self.rows("SELECT * FROM signals WHERE status='offen' ORDER BY ts DESC")]

    @staticmethod
    def _decode_signal(r):
        if r and r.get("flags"):
            try:
                r["flags"] = json.loads(r["flags"])
            except ValueError:
                r["flags"] = []
        elif r:
            r["flags"] = []
        if r:
            r.pop("raw", None)
        return r

    # --- Positionen ---
    def add_position(self, p):
        cols = list(p.keys())
        vals = [json.dumps(v) if isinstance(v, dict) else v for v in p.values()]
        self._exec(f"INSERT INTO positions ({','.join(cols)}) VALUES ({','.join('?' * len(cols))})", vals)

    def update_position(self, pid, **kw):
        sets = ",".join(f"{k}=?" for k in kw)
        vals = [json.dumps(v) if isinstance(v, dict) else v for v in kw.values()]
        self._exec(f"UPDATE positions SET {sets} WHERE id=?", vals + [pid])

    def position(self, pid):
        return self._decode_pos(self.one("SELECT * FROM positions WHERE id=?", (pid,)))

    def open_positions(self):
        return [self._decode_pos(r) for r in self.rows("SELECT * FROM positions WHERE status='offen' ORDER BY opened")]

    def closed_positions(self, limit=5000):
        return [self._decode_pos(r) for r in self.rows(
            "SELECT * FROM positions WHERE status='geschlossen' ORDER BY closed LIMIT ?", (limit,))]

    @staticmethod
    def _decode_pos(r):
        if r:
            try:
                r["broker_ref"] = json.loads(r["broker_ref"]) if r.get("broker_ref") else {}
            except ValueError:
                r["broker_ref"] = {}
        return r

    def reset_trades(self, broker):
        self._exec("DELETE FROM positions WHERE broker=?", (broker,))

    # --- Schatten-Trades (jedes Signal wird simuliert, auch abgelehnte) ---
    def add_shadow(self, s):
        cols = list(s.keys())
        self._exec(f"INSERT INTO shadow ({','.join(cols)}) VALUES ({','.join('?' * len(cols))})", list(s.values()))

    def update_shadow(self, sid, **kw):
        sets = ",".join(f"{k}=?" for k in kw)
        self._exec(f"UPDATE shadow SET {sets} WHERE id=?", list(kw.values()) + [sid])

    def open_shadows(self):
        return self.rows("SELECT * FROM shadow WHERE status='offen'")

    def closed_shadows(self):
        return self.rows("SELECT * FROM shadow WHERE status='geschlossen' ORDER BY closed")

    # --- Ereignisse ---
    def log(self, text, level="info"):
        self._exec("INSERT INTO events (ts, level, text) VALUES (?,?,?)", (time.time(), level, text))
        self._exec("DELETE FROM events WHERE id NOT IN (SELECT id FROM events ORDER BY id DESC LIMIT 300)")

    def events(self, limit=40):
        return self.rows("SELECT ts, level, text FROM events ORDER BY id DESC LIMIT ?", (limit,))

# ═════════════════ brokers.py ═════════════════
"""Broker-Anbindungen: Paper-Trading (Simulation) und Tradovate (REST-API).

Jede Order wird als Bracket mit Stop-Loss geschickt. Ohne Stop verlässt keine Order die App.
"""
import datetime as dt
import json
import time
import urllib.error
import urllib.request
import uuid


class BrokerError(Exception):
    pass


# ───────────────────────── Kontrakt-Monate ─────────────────────────
MONTH_CODES = {3: "H", 6: "M", 9: "U", 12: "Z"}


def third_friday(year, month):
    d = dt.date(year, month, 15)
    while d.weekday() != 4:
        d += dt.timedelta(days=1)
    return d


def front_month(root, today=None):
    """Aktueller Quartalskontrakt, gerollt 8 Tage vor Verfall (z. B. NQZ6)."""
    today = today or dt.date.today()
    for year in (today.year, today.year + 1):
        for month in (3, 6, 9, 12):
            roll = third_friday(year, month) - dt.timedelta(days=8)
            if today < roll:
                return f"{root}{MONTH_CODES[month]}{year % 10}"
    raise BrokerError("Kein Kontraktmonat gefunden")


# ───────────────────────── Paper-Trading ─────────────────────────
class PaperBroker:
    """Simuliert Ausführung. Stop/Ziel werden von der Engine über die Bar-Daten aus TradingView geprüft."""
    name = "paper"
    label = "Paper-Trading"

    def __init__(self, cfg):
        self.cfg = cfg

    def connect(self):
        return "Paper-Konto bereit"

    def contract_name(self, root):
        return f"{root} (Paper)"

    def open(self, contract, side, qty, price, sl, tp, tick):
        slip = self.cfg["paper"]["slippage_ticks"] * tick
        fill = price + slip if side == "long" else price - slip
        return fill, {}

    def close(self, pos, price, tick):
        slip = self.cfg["paper"]["slippage_ticks"] * tick
        return price - slip if pos["side"] == "long" else price + slip

    def modify_stop(self, pos, new_sl):
        return True

    def sync(self, positions):
        return []

    def balance(self):
        return None


# ───────────────────────── Tradovate ─────────────────────────
class TradovateBroker:
    """Tradovate REST-API (Demo oder Live). Benötigt das API-Add-on und einen API-Key (cid/secret)."""
    name = "tradovate"
    label = "Tradovate"

    def __init__(self, cfg):
        self.cfg = cfg
        self.token = None
        self.token_exp = 0
        self.account_id = None
        self.account_name = None
        self._contracts = {}

    @property
    def tcfg(self):
        return self.cfg["tradovate"]

    @property
    def base(self):
        env = "live" if self.tcfg.get("env") == "live" else "demo"
        return f"https://{env}.tradovateapi.com/v1"

    def _req(self, method, path, body=None, auth=True):
        if auth:
            self._ensure_token()
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.base + path, data=data, method=method)
        req.add_header("Content-Type", "application/json")
        req.add_header("Accept", "application/json")
        if auth:
            req.add_header("Authorization", f"Bearer {self.token}")
        try:
            with urllib.request.urlopen(req, timeout=15) as r:
                raw = r.read().decode() or "null"
        except urllib.error.HTTPError as e:
            raise BrokerError(f"Tradovate {e.code}: {e.read().decode()[:200]}")
        except urllib.error.URLError as e:
            raise BrokerError(f"Tradovate nicht erreichbar: {e.reason}")
        res = json.loads(raw)
        if isinstance(res, dict) and (res.get("errorText") or res.get("failureReason")):
            raise BrokerError(f"Tradovate: {res.get('errorText') or res.get('failureReason')} {res.get('failureText', '')}".strip())
        return res

    def _ensure_token(self):
        if self.token and time.time() < self.token_exp - 120:
            return
        c = self.tcfg
        missing = [k for k in ("username", "password", "cid", "secret") if not str(c.get(k, "")).strip()]
        if missing:
            raise BrokerError("Tradovate-Zugangsdaten fehlen: " + ", ".join(missing))
        if not c.get("device_id"):
            c["device_id"] = str(uuid.uuid4())
        res = self._req("POST", "/auth/accesstokenrequest", {
            "name": c["username"], "password": c["password"],
            "appId": c.get("app_id") or "FVG Trader", "appVersion": "1.0",
            "cid": int(c["cid"]), "sec": c["secret"], "deviceId": c["device_id"],
        }, auth=False)
        if not res or "accessToken" not in res:
            raise BrokerError("Tradovate-Login fehlgeschlagen" + (f": {res.get('p-ticket')}" if isinstance(res, dict) and res.get("p-ticket") else ""))
        self.token = res["accessToken"]
        try:
            exp = dt.datetime.fromisoformat(res["expirationTime"].replace("Z", "+00:00"))
            self.token_exp = exp.timestamp()
        except (KeyError, ValueError):
            self.token_exp = time.time() + 60 * 60
        accounts = self._req("GET", "/account/list")
        if not accounts:
            raise BrokerError("Kein Tradovate-Konto gefunden")
        want = (c.get("account") or "").strip()
        acc = next((a for a in accounts if a.get("name") == want), accounts[0])
        self.account_id, self.account_name = acc["id"], acc["name"]

    def connect(self):
        self.token = None
        self._ensure_token()
        env = "LIVE" if self.tcfg.get("env") == "live" else "Demo"
        return f"Verbunden mit Tradovate {env}, Konto {self.account_name}"

    def contract_name(self, root):
        override = (self.cfg.get("contracts") or {}).get(root, "").strip()
        return override or front_month(root)

    def _contract_id(self, name):
        if name not in self._contracts:
            res = self._req("GET", f"/contract/find?name={name}")
            if not res or "id" not in res:
                raise BrokerError(f"Kontrakt {name} nicht gefunden")
            self._contracts[name] = res["id"]
        return self._contracts[name]

    def open(self, contract, side, qty, price, sl, tp, tick):
        action, opp = ("Buy", "Sell") if side == "long" else ("Sell", "Buy")
        body = {
            "accountSpec": self.account_name or "", "accountId": self.account_id,
            "action": action, "symbol": contract, "orderQty": int(qty),
            "orderType": "Market", "isAutomated": True,
            "bracket1": {"action": opp, "orderType": "Stop", "stopPrice": sl},
        }
        if tp:
            body["bracket2"] = {"action": opp, "orderType": "Limit", "price": tp}
        self._ensure_token()
        body["accountSpec"], body["accountId"] = self.account_name, self.account_id
        res = self._req("POST", "/order/placeoso", body)
        if not isinstance(res, dict) or not res.get("orderId"):
            raise BrokerError(f"Order abgelehnt: {res}")
        ref = {"orderId": res["orderId"], "stopId": res.get("oso1Id"), "tpId": res.get("oso2Id"),
               "contractId": self._contract_id(contract), "contract": contract}
        fill = self._fill_price(ref["orderId"]) or price
        return fill, ref

    def _fill_price(self, order_id, tries=5):
        for _ in range(tries):
            fills = [f for f in self._req("GET", "/fill/list") if f.get("orderId") == order_id]
            if fills:
                q = sum(f["qty"] for f in fills)
                return sum(f["price"] * f["qty"] for f in fills) / q
            time.sleep(0.4)
        return None

    def close(self, pos, price, tick):
        ref = pos["broker_ref"]
        self._req("POST", "/order/liquidateposition",
                  {"accountId": self.account_id, "contractId": ref["contractId"], "admin": False})
        time.sleep(0.8)
        return self._exit_price(pos) or price

    def modify_stop(self, pos, new_sl):
        ref = pos["broker_ref"]
        if not ref.get("stopId"):
            raise BrokerError("Stop-Order-ID unbekannt")
        self._req("POST", "/order/modifyorder", {"orderId": ref["stopId"], "orderQty": pos["qty"],
                                                  "orderType": "Stop", "stopPrice": new_sl, "isAutomated": True})
        return True

    def _exit_price(self, pos):
        ref = pos["broker_ref"]
        exit_action = "Sell" if pos["side"] == "long" else "Buy"
        fills = [f for f in self._req("GET", "/fill/list")
                 if f.get("contractId") == ref.get("contractId") and f.get("action") == exit_action
                 and f.get("orderId") != ref.get("orderId")]
        if not fills:
            return None
        fills.sort(key=lambda f: f.get("timestamp", ""))
        return fills[-1]["price"]

    def sync(self, positions):
        """Erkennt Positionen, die beim Broker durch Stop oder Ziel geschlossen wurden."""
        if not positions:
            return []
        net = {p["contractId"]: p.get("netPos", 0) for p in self._req("GET", "/position/list")}
        closed = []
        for pos in positions:
            cid = pos["broker_ref"].get("contractId")
            if cid is not None and net.get(cid, 0) == 0:
                closed.append((pos, self._exit_price(pos)))
        return closed

    def round_trips(self):
        """Abgeschlossene Trades (Fill-Paare) des Kontos: Kauf-Fill + Verkaufs-Fill."""
        self._ensure_token()
        pairs = self._req("GET", "/fillPair/list") or []
        if not pairs:
            return []

        def items(path, ids):
            ids, out = [i for i in ids if i is not None], []
            for k in range(0, len(ids), 100):
                out += self._req("GET", f"{path}?ids={','.join(str(i) for i in ids[k:k + 100])}") or []
            return {x["id"]: x for x in out if isinstance(x, dict) and "id" in x}

        fills = items("/fill/items", {p.get("buyFillId") for p in pairs} | {p.get("sellFillId") for p in pairs})
        positions = items("/position/items", {p.get("positionId") for p in pairs})
        contracts = items("/contract/items", {f.get("contractId") for f in fills.values()})
        trips = []
        for p in pairs:
            b, s_ = fills.get(p.get("buyFillId")), fills.get(p.get("sellFillId"))
            if not b or not s_:
                continue
            pos = positions.get(p.get("positionId"))
            if pos and self.account_id and pos.get("accountId") not in (None, self.account_id):
                continue
            trips.append({"id": p["id"], "contract": (contracts.get(b.get("contractId")) or {}).get("name", "?"),
                          "qty": p.get("qty") or b.get("qty") or 1, "buy": p.get("buyPrice", b.get("price")),
                          "sell": p.get("sellPrice", s_.get("price")), "buy_ts": b.get("timestamp"), "sell_ts": s_.get("timestamp"),
                          "order_ids": [b.get("orderId"), s_.get("orderId")], "trade_date": b.get("tradeDate")})
        return trips

    def balance(self):
        res = self._req("POST", "/cashBalance/getcashbalancesnapshot", {"accountId": self.account_id})
        return res.get("totalCashValue") if isinstance(res, dict) else None


BROKERS = {"paper": PaperBroker, "tradovate": TradovateBroker}

# ═════════════════ engine.py ═════════════════
"""Kern der App: Signale prüfen, Positionsgröße berechnen, Stop-Loss erzwingen, ausführen oder vorschlagen."""
import copy
import datetime as dt
import json
import math
import re
import os
import secrets
import threading
import time
import uuid



# Tickgröße und $ pro Punkt
INSTR = {
    "NQ":  {"tick": 0.25, "pv": 20.0, "micro": "MNQ", "name": "E-mini Nasdaq-100"},
    "MNQ": {"tick": 0.25, "pv": 2.0,  "mini": "NQ",   "name": "Micro E-mini Nasdaq-100"},
    "ES":  {"tick": 0.25, "pv": 50.0, "micro": "MES", "name": "E-mini S&P 500"},
    "MES": {"tick": 0.25, "pv": 5.0,  "mini": "ES",   "name": "Micro E-mini S&P 500"},
}

# Handels-Sessions in New Yorker Zeit (Start, Ende)
TRADING_SESSIONS = {
    "asia":     ("Asien", "20:00", "00:00"),
    "london":   ("London", "02:00", "05:00"),
    "ny_am":    ("New York Vormittag (Open)", "09:30", "11:30"),
    "ny_lunch": ("New York Mittag", "11:30", "13:30"),
    "ny_pm":    ("New York Nachmittag", "13:30", "15:50"),
}


def in_session(key, t):
    """Liegt die New-Yorker Zeit t in der Session? Abend-Sessions (Asien) gehören zum nächsten Handelstag."""
    _, start, end = TRADING_SESSIONS[key]
    hm, wd = t.strftime("%H:%M"), t.weekday()
    if start < end:
        return wd < 5 and start <= hm < end
    return (hm >= start and wd in (6, 0, 1, 2, 3)) or (hm < end and wd < 5)


DEFAULT_UPDATE_URL = "https://raw.githubusercontent.com/QuatratKopf/trading-Bot/main/version.json"

DEFAULT_CONFIG = {
    "auto_mode": False,
    "paused": False,
    "broker": "paper",
    "public_url": "",          # feste eigene Adresse (optional), sonst automatische Verbindung
    "hook_confirmed": "",
    "update_url": DEFAULT_UPDATE_URL,   # Adresse der version.json für Updates      # zuletzt in TradingView eingetragene Webhook-Adresse
    "webhook_token": "",
    "follow_tv_exits": True,
    "suggestion_timeout_sec": 120,
    "sizing": {
        "mode": "risk_usd",          # fixed | risk_usd | risk_pct
        "fixed_qty": 1,
        "risk_usd": 300.0,
        "risk_pct": 0.5,
        "contract_type": "auto",     # auto | mini | micro
        "max_qty": 5,
    },
    "safe_stop": {
        "NQ": {"default": 40.0, "min": 5.0, "max": 80.0},
        "ES": {"default": 10.0, "min": 1.5, "max": 20.0},
        "default_rr": 2.0,
    },
    "risk": {
        "max_daily_loss": 1000.0,
        "max_trades_day": 5,
        "max_open": 1,
        "enforce_session": True,
        "session_start": "09:30",   # alt, nicht mehr genutzt
        "session_end": "15:50",     # alt, nicht mehr genutzt
        "sessions": {"asia": False, "london": False, "ny_am": True, "ny_lunch": False, "ny_pm": True},
        "flat_at_session_end": True,
    },
    "paper": {"start_balance": 50000.0, "slippage_ticks": 1, "commission": 2.25},
    "tradovate": {"env": "demo", "username": "", "password": "", "cid": "", "secret": "",
                  "app_id": "", "account": "", "device_id": ""},
    "contracts": {"NQ": "", "MNQ": "", "ES": "", "MES": ""},
    "learning": {
        "enabled": True,
        "window": 30,          # letzte N Schatten-Trades je Strategie
        "min_trades": 12,      # vorher nur beobachten
        "pause_below_r": -0.10,
        "half_below_r": 0.10,
    },
    "setup_rules": {},         # Strategie -> auto | an | aus
    "own_sync": {"tradovate": False},   # eigene Trades automatisch aus Tradovate übernehmen
    "tunnel": {"ngrok_token": ""},      # mit Schlüssel: feste Adresse über ngrok
}

# $ pro Punkt für eigene Trades aus dem Broker-Import
POINT_VALUE = {"NQ": 20, "MNQ": 2, "ES": 50, "MES": 5, "YM": 5, "MYM": 0.5, "RTY": 50, "M2K": 5,
               "GC": 100, "MGC": 10, "CL": 1000, "MCL": 100, "SI": 5000, "SIL": 1000}
SECRET_FIELDS = ("password", "secret")
SECRET_PATHS = (("tradovate", "password"), ("tradovate", "secret"), ("tunnel", "ngrok_token"))
MASK = "••••••••"


def deep_merge(base, patch):
    out = copy.deepcopy(base)
    for k, v in (patch or {}).items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = deep_merge(out[k], v)
        else:
            out[k] = v
    return out


# ───────────────────────── New-York-Zeit ohne Zusatzpakete ─────────────────────────
def _nth_sunday(year, month, n):
    d = dt.date(year, month, 1)
    d += dt.timedelta(days=(6 - d.weekday()) % 7)
    return d + dt.timedelta(weeks=n - 1)


def ny_time(ts=None):
    """US-Ostküste: Sommerzeit vom 2. Sonntag im März bis 1. Sonntag im November."""
    utc = dt.datetime.fromtimestamp(ts if ts is not None else time.time(), dt.timezone.utc).replace(tzinfo=None)
    y = utc.year
    dst_start = dt.datetime.combine(_nth_sunday(y, 3, 2), dt.time(7))   # 2:00 EST = 7:00 UTC
    dst_end = dt.datetime.combine(_nth_sunday(y, 11, 1), dt.time(6))    # 2:00 EDT = 6:00 UTC
    off = -4 if dst_start <= utc < dst_end else -5
    return utc + dt.timedelta(hours=off)


def ny_date(ts=None):
    return ny_time(ts).date()


def family(root):
    return INSTR[root].get("mini", root)


def round_tick(price, tick):
    return round(round(price / tick) * tick, 4)


class Engine:
    def __init__(self, data_dir):
        os.makedirs(data_dir, exist_ok=True)
        self.lock = threading.RLock()
        self.cfg_path = os.path.join(data_dir, "config.json")
        self.cfg = self._load_cfg()
        self.db = DB(os.path.join(data_dir, "trader.db"))
        self.learn_path = os.path.join(data_dir, "learning.json")
        self.learning = {}
        if os.path.exists(self.learn_path):
            with open(self.learn_path, encoding="utf-8") as f:
                self.learning = json.load(f)
        self.last_msg = None          # Zeitpunkt der letzten TradingView-Nachricht
        self.last_bar = {}            # Familie (NQ/ES) -> Bar
        self.broker_status = ""
        self.broker_ok = False
        self._balance_cache = (0, None)
        self._sync_client = None
        self.sync_state = {"last": None, "added": 0, "error": "", "next": 0}
        self.broker = BROKERS[self.cfg["broker"]](self.cfg)
        self._connect_broker()
        threading.Thread(target=self._loop, daemon=True).start()

    # ───────── Konfiguration ─────────
    def _load_cfg(self):
        cfg = copy.deepcopy(DEFAULT_CONFIG)
        if os.path.exists(self.cfg_path):
            with open(self.cfg_path, encoding="utf-8") as f:
                cfg = deep_merge(cfg, json.load(f))
        if cfg.get("public_url") and not re.match(r"^https?://", cfg["public_url"].strip()):
            cfg["public_url"] = ""
        if not cfg.get("update_url") or "QuatratKopf/trading-bot/" in cfg["update_url"]:
            cfg["update_url"] = DEFAULT_UPDATE_URL
        if not cfg["webhook_token"]:
            cfg["webhook_token"] = secrets.token_urlsafe(18)
        self._write_cfg(cfg)
        return cfg

    def _write_cfg(self, cfg):
        tmp = self.cfg_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(cfg, f, indent=2, ensure_ascii=False)
        os.replace(tmp, self.cfg_path)

    def public_cfg(self):
        c = copy.deepcopy(self.cfg)
        for sec, k in SECRET_PATHS:
            if c.get(sec, {}).get(k):
                c[sec][k] = MASK
        return c

    def update_cfg(self, patch):
        with self.lock:
            for sec, k in SECRET_PATHS:
                part = (patch or {}).get(sec) or {}
                if part.get(k) == MASK:
                    part.pop(k)
            new = deep_merge(self.cfg, patch)
            self._validate_cfg(new)
            broker_changed = new["broker"] != self.cfg["broker"] or new["tradovate"] != self.cfg["tradovate"]
            if new["broker"] != self.cfg["broker"] and self.db.open_positions():
                raise ValueError("Broker kann nur ohne offene Positionen gewechselt werden.")
            if new["auto_mode"] != self.cfg["auto_mode"]:
                self.db.log("Auto-Modus " + ("eingeschaltet" if new["auto_mode"] else "ausgeschaltet: Signale kommen als Vorschlag"))
            if new["paused"] != self.cfg["paused"]:
                self.db.log("Handel pausiert" if new["paused"] else "Handel fortgesetzt", "warn" if new["paused"] else "info")
            self.cfg.clear()
            self.cfg.update(new)
            self._write_cfg(self.cfg)
            if broker_changed:
                self.broker = BROKERS[self.cfg["broker"]](self.cfg)
                self._connect_broker()
                self._sync_client = None
                self.sync_state["next"] = 0
            return self.public_cfg()

    @staticmethod
    def _validate_cfg(c):
        s = c["sizing"]
        if s["mode"] not in ("fixed", "risk_usd", "risk_pct"):
            raise ValueError("Unbekannter Größen-Modus")
        if s["contract_type"] not in ("auto", "mini", "micro"):
            raise ValueError("Unbekannter Kontrakttyp")
        for k, lo in (("fixed_qty", 1), ("max_qty", 1)):
            s[k] = int(s[k])
            if s[k] < lo:
                raise ValueError("Kontraktanzahl muss mindestens 1 sein")
        s["risk_usd"] = float(s["risk_usd"])
        s["risk_pct"] = float(s["risk_pct"])
        if not (0 < s["risk_pct"] <= 5):
            raise ValueError("Risiko in % muss zwischen 0 und 5 liegen")
        for fam in ("NQ", "ES"):
            st = c["safe_stop"][fam]
            for k in ("default", "min", "max"):
                st[k] = float(st[k])
            if not (0 < st["min"] <= st["default"] <= st["max"]):
                raise ValueError(f"Safe-Stop {fam}: es muss gelten Min ≤ Standard ≤ Max")
        for k, v in c["setup_rules"].items():
            if v not in ("auto", "an", "aus"):
                raise ValueError(f"Regel für {k} muss auto, an oder aus sein")
        L = c["learning"]
        L["window"], L["min_trades"] = int(L["window"]), int(L["min_trades"])
        L["pause_below_r"], L["half_below_r"] = float(L["pause_below_r"]), float(L["half_below_r"])
        if not (5 <= L["window"] <= 500 and 3 <= L["min_trades"] <= L["window"] and L["pause_below_r"] < L["half_below_r"]):
            raise ValueError("Lernmodul: Fenster 5–500, Mindest-Trades ≤ Fenster, Pause-Schwelle < Halbe-Größe-Schwelle")
        pu = (c.get("public_url") or "").strip()
        if pu and not re.match(r"^https?://[^\s/]+\.[^\s]+$", pu):
            raise ValueError("„Eigene feste Adresse“ muss eine Internetadresse sein (https://…). "
                             "Einen ngrok-Schlüssel bitte oben im Bereich TradingView eintragen und dieses Feld leer lassen.")
        tok = ((c.get("tunnel") or {}).get("ngrok_token") or "").strip()
        if tok and tok != MASK:
            if tok.startswith("cr_"):
                raise ValueError("Das ist eine ngrok-Zugangs-ID (beginnt mit cr_), nicht der Authtoken. "
                                 "Den Authtoken findest du im ngrok-Dashboard unter „Your Authtoken“.")
            if len(tok) < 30 or " " in tok:
                raise ValueError("Der ngrok-Authtoken sieht unvollständig aus. Bitte im ngrok-Dashboard unter „Your Authtoken“ komplett kopieren.")
        if c["broker"] not in BROKERS:
            raise ValueError("Unbekannter Broker")
        ses = c["risk"].get("sessions") or {}
        c["risk"]["sessions"] = {k: bool(ses.get(k)) for k in TRADING_SESSIONS}
        if c["risk"]["enforce_session"] and not any(c["risk"]["sessions"].values()):
            raise ValueError("Bitte mindestens eine Session anhaken, in der der Bot handeln darf.")

    def regenerate_token(self):
        with self.lock:
            self.cfg["webhook_token"] = secrets.token_urlsafe(18)
            self._write_cfg(self.cfg)
            self.db.log("Neue Webhook-URL erzeugt: Alert in TradingView anpassen", "warn")

    def _connect_broker(self):
        try:
            self.broker_status = self.broker.connect()
            self.broker_ok = True
        except BrokerError as e:
            self.broker_status = str(e)
            self.broker_ok = False
            self.db.log(f"Broker-Verbindung: {e}", "error")

    def test_broker(self):
        with self.lock:
            self._connect_broker()
            return {"ok": self.broker_ok, "status": self.broker_status}

    # ───────── Webhook ─────────
    def handle_webhook(self, payload):
        with self.lock:
            self.last_msg = time.time()
            kind = (payload.get("type") or "").lower()
            action = (payload.get("action") or "").lower()
            if kind == "bar":
                return self._on_bar(payload)
            if kind == "exit" or action in ("exit", "close", "flat"):
                return self._on_exit(payload)
            if action in ("buy", "sell", "long", "short"):
                return self._on_entry(payload)
            raise ValueError("Unbekannte Nachricht: 'action' muss buy, sell oder exit sein")

    @staticmethod
    def _root(ticker):
        t = (ticker or "").upper().split(":")[-1]
        for r in ("MNQ", "MES", "NQ", "ES"):
            if t.startswith(r):
                return r
        raise ValueError(f"Symbol {ticker!r} wird nicht unterstützt (nur NQ, MNQ, ES, MES)")

    @staticmethod
    def _num(v):
        if isinstance(v, dict):
            v = v.get("stopPrice", v.get("limitPrice", v.get("price")))
        try:
            f = float(v)
            return f if math.isfinite(f) else None
        except (TypeError, ValueError):
            return None

    def _on_bar(self, p):
        fam = family(self._root(p.get("ticker")))
        bar = {k: self._num(p.get(k)) for k in ("open", "high", "low", "close")}
        if None in bar.values():
            raise ValueError("Bar-Nachricht unvollständig")
        bar["ts"] = time.time()
        bar["time"] = self._num(p.get("time"))
        self.last_bar[fam] = bar
        for sh in self.db.open_shadows():
            if sh["fam"] != fam or not self._bar_after(sh, bar):
                continue
            long_ = sh["side"] == "long"
            if (bar["low"] <= sh["sl"]) if long_ else (bar["high"] >= sh["sl"]):
                self._close_shadow(sh, sh["sl"])
            elif (bar["high"] >= sh["tp"]) if long_ else (bar["low"] <= sh["tp"]):
                self._close_shadow(sh, sh["tp"])
        if self.broker.name == "paper":
            for pos in self.db.open_positions():
                if family(pos["root"]) != fam or pos["broker"] != "paper" or not self._bar_after(pos, bar):
                    continue
                long_ = pos["side"] == "long"
                hit_sl = bar["low"] <= pos["sl"] if long_ else bar["high"] >= pos["sl"]
                hit_tp = pos["tp"] and (bar["high"] >= pos["tp"] if long_ else bar["low"] <= pos["tp"])
                if hit_sl:   # beide in einer Kerze: konservativ als Stop werten
                    self._finish(pos, pos["sl"], "Stop-Loss", slip=True)
                elif hit_tp:
                    self._finish(pos, pos["tp"], "Ziel erreicht", slip=False)
        return {"ok": True, "type": "bar"}

    @staticmethod
    def _bar_after(obj, bar):
        """Die Kerze, auf der das Signal entstand, darf den Trade nicht auslösen."""
        if bar.get("time") and obj.get("bar_time"):
            return bar["time"] > obj["bar_time"]
        return bar["ts"] - obj["opened"] > 20

    def _on_exit(self, p):
        root = self._root(p.get("ticker"))
        fam = family(root)
        if not self.cfg["follow_tv_exits"]:
            return {"ok": True, "ignored": "TradingView-Exits sind deaktiviert"}
        price = self._num(p.get("price")) or (self.last_bar.get(fam) or {}).get("close")
        setup = str(p.get("setup") or "")
        for sh in self.db.open_shadows():
            if sh["fam"] == fam and price and (not setup or sh["setup"] == setup):
                self._close_shadow(sh, price)
        n = 0
        for pos in self.db.open_positions():
            if family(pos["root"]) == fam and (not setup or pos["setup"] == setup):
                self._close(pos, price, "Exit-Signal TradingView")
                n += 1
        for s in self.db.pending():
            if family(s["root"]) == fam and (not setup or s["setup"] == setup):
                self.db.update_signal(s["id"], status="verfallen", reason="Strategie hat den Trade bereits beendet")
        return {"ok": True, "closed": n}

    # ───────── Einstieg ─────────
    def _on_entry(self, p, is_test=False):
        action = p["action"].lower()
        side = "long" if action in ("buy", "long") else "short"
        sig_root = self._root(p.get("ticker"))
        fam = family(sig_root)
        price = self._num(p.get("price")) or (self.last_bar.get(fam) or {}).get("close")
        sid = uuid.uuid4().hex[:10]
        base = {"id": sid, "ts": time.time(), "ticker": p.get("ticker", ""), "root": fam, "side": side,
                "setup": str(p.get("setup") or p.get("comment") or "Signal")[:40], "is_test": int(is_test),
                "raw": json.dumps(p)[:2000], "entry": price, "bar_time": self._num(p.get("time"))}
        if price is None:
            base.update(status="blockiert", reason="Kein Preis im Signal")
            self.db.add_signal(base)
            return {"ok": False, "status": "blockiert", "reason": base["reason"]}

        sl, tp, flags = self._safe_stop(fam, side, price, self._num(p.get("stopLoss") or p.get("sl")),
                                         self._num(p.get("takeProfit") or p.get("tp")))
        if not is_test:
            now_ny = ny_time()
            self.db.add_shadow({"id": uuid.uuid4().hex[:10], "signal_id": sid, "setup": base["setup"], "fam": fam,
                                "side": side, "entry": price, "sl": sl, "tp": tp, "opened": time.time(),
                                "status": "offen", "ny_hour": now_ny.hour, "ny_weekday": now_ny.weekday(),
                                "bar_time": base["bar_time"]})
        sized = self._size(fam, price, sl)
        base.update(sl=sl, tp=tp, flags=flags)
        if isinstance(sized, str):
            base.update(status="blockiert", reason=sized)
            self.db.add_signal(base)
            self.db.log(f"Signal {side.upper()} {fam} blockiert: {sized}", "warn")
            return {"ok": False, "status": "blockiert", "reason": sized}
        root, qty, risk_usd = sized
        rule = self.setup_rule(base["setup"])
        if rule == "halbe Größe" and qty > 1:
            qty = qty // 2
            risk_usd = round(qty * abs(price - sl) * INSTR[root]["pv"], 2)
            flags.append("Halbe Größe (Lernmodul)")
        base.update(root=root, qty=qty, risk_usd=risk_usd, contract=self.broker.contract_name(root), flags=flags)

        guard = None
        if rule == "aus":
            guard = f"Strategie {base['setup']} ist ausgeschaltet"
        elif rule == "pausiert":
            guard = f"Strategie {base['setup']} vom Lernmodul pausiert (läuft im Schatten weiter)"
        guard = guard or self._guards(fam)
        if guard:
            base.update(status="blockiert", reason=guard)
            self.db.add_signal(base)
            self.db.log(f"Signal {side.upper()} {root} blockiert: {guard}", "warn")
            return {"ok": False, "status": "blockiert", "reason": guard}

        for old in self.db.pending():   # ältere offene Vorschläge derselben Familie ersetzen
            if family(old["root"]) == fam:
                self.db.update_signal(old["id"], status="ersetzt", reason="Neueres Signal")

        if self.cfg["auto_mode"]:
            base.update(status="wird ausgeführt")
            self.db.add_signal(base)
            return self._execute(self.db.signal(sid))
        base.update(status="offen", expires=time.time() + int(self.cfg["suggestion_timeout_sec"]))
        self.db.add_signal(base)
        self.db.log(f"Vorschlag: {side.upper()} {qty}× {root} @ {price:.2f}, Stop {sl:.2f}")
        return {"ok": True, "status": "offen", "id": sid}

    def _safe_stop(self, fam, side, entry, sl, tp):
        """Jede Order bekommt einen Stop: fehlt er, liegt er falsch oder zu weit, wird er korrigiert."""
        ss = self.cfg["safe_stop"][fam]
        tick = INSTR[fam]["tick"]
        d = 1 if side == "long" else -1
        flags = []
        if sl is None:
            sl = entry - d * ss["default"]
            flags.append("Safe-Stop gesetzt (Signal ohne Stop)")
        elif (entry - sl) * d <= 0:
            sl = entry - d * ss["default"]
            flags.append("Stop lag auf der falschen Seite, Safe-Stop gesetzt")
        dist = abs(entry - sl)
        if dist > ss["max"]:
            sl = entry - d * ss["max"]
            flags.append(f"Stop auf Maximum {ss['max']:g} Pkt. begrenzt")
        elif dist < ss["min"]:
            sl = entry - d * ss["min"]
            flags.append(f"Stop auf Minimum {ss['min']:g} Pkt. erweitert")
        sl = round_tick(sl, tick)
        risk = abs(entry - sl)
        if tp is None or (tp - entry) * d <= 0:
            tp = entry + d * risk * float(self.cfg["safe_stop"]["default_rr"])
            flags.append(f"Ziel auf {self.cfg['safe_stop']['default_rr']:g}R gesetzt")
        return sl, round_tick(tp, tick), flags

    def balance(self):
        if self.broker.name == "paper":
            closed = sum(p["pnl"] or 0 for p in self.db.closed_positions() if p["broker"] == "paper")
            return float(self.cfg["paper"]["start_balance"]) + closed
        ts, val = self._balance_cache
        if time.time() - ts > 30 and self.broker_ok:
            try:
                val = self.broker.balance()
            except BrokerError:
                pass
            self._balance_cache = (time.time(), val)
        return val

    def size_preview(self, fam, stop_points):
        entry = 10000.0
        return self._size(fam, entry, entry - stop_points)

    def _size(self, fam, entry, sl):
        """Positionsgröße → (Kontrakt, Anzahl, Risiko $) oder Grund, warum nicht gehandelt wird."""
        s = self.cfg["sizing"]
        pts = abs(entry - sl)
        if pts <= 0:
            return "Stop-Abstand ist 0"
        mini, micro = fam, INSTR[fam]["micro"]
        if s["mode"] == "fixed":
            root = micro if s["contract_type"] == "micro" else mini
            qty = int(s["fixed_qty"])
        else:
            if s["mode"] == "risk_usd":
                budget = float(s["risk_usd"])
            else:
                bal = self.balance()
                if not bal:
                    return "Kontostand unbekannt, Risiko in % nicht berechenbar"
                budget = bal * float(s["risk_pct"]) / 100
            q_mini = math.floor(budget / (pts * INSTR[mini]["pv"]))
            q_micro = math.floor(budget / (pts * INSTR[micro]["pv"]))
            if s["contract_type"] == "mini":
                root, qty = mini, q_mini
            elif s["contract_type"] == "micro":
                root, qty = micro, q_micro
            else:   # auto: Mini, wenn mindestens einer ins Budget passt, sonst Micro
                root, qty = (mini, q_mini) if q_mini >= 1 else (micro, q_micro)
            if qty < 1:
                return f"Stop {pts:g} Pkt. zu weit für Risiko {budget:,.0f} $ (selbst 1 Micro wäre zu viel)"
        qty = min(qty, int(s["max_qty"]))
        return root, qty, round(qty * pts * INSTR[root]["pv"], 2)

    def _today_trades(self):
        today = ny_date()
        return [p for p in self.db.rows("SELECT opened, pnl, status, broker, is_test FROM positions")
                if ny_date(p["opened"]) == today and p["broker"] == self.broker.name]

    def today_pnl(self):
        today = ny_date()
        pnl = sum(p["pnl"] or 0 for p in self.db.closed_positions()
                  if p["broker"] == self.broker.name and ny_date(p["closed"]) == today)
        return pnl + sum(self._unrealized(p) for p in self.db.open_positions())

    def session_now(self, t=None):
        """Name der gerade laufenden, angehakten Session oder None."""
        t = t or ny_time()
        on = self.cfg["risk"].get("sessions") or {}
        return next((k for k in TRADING_SESSIONS if on.get(k) and in_session(k, t)), None)

    def _guards(self, fam):
        r = self.cfg["risk"]
        if self.cfg["paused"]:
            return "Handel pausiert"
        if r["enforce_session"] and not self.session_now():
            return "Außerhalb der gewählten Sessions"
        if len(self.db.open_positions()) >= int(r["max_open"]):
            return "Maximale Anzahl offener Positionen erreicht"
        if len(self._today_trades()) >= int(r["max_trades_day"]):
            return f"Max. {r['max_trades_day']} Trades pro Tag erreicht"
        if float(r["max_daily_loss"]) > 0 and self.today_pnl() <= -float(r["max_daily_loss"]):
            return "Tagesverlust-Limit erreicht"
        return None

    # ───────── Ausführen ─────────
    def _execute(self, sig):
        root, fam = sig["root"], family(sig["root"])
        tick = INSTR[root]["tick"]
        price = (self.last_bar.get(fam) or {}).get("close") if sig["status"] == "offen" else None
        price = price or sig["entry"]
        long_ = sig["side"] == "long"
        if (long_ and price <= sig["sl"]) or (not long_ and price >= sig["sl"]):
            self.db.update_signal(sig["id"], status="verfallen", reason="Kurs hat den Stop bereits erreicht")
            return {"ok": False, "status": "verfallen", "reason": "Kurs hat den Stop bereits erreicht"}
        try:
            fill, ref = self.broker.open(sig["contract"], sig["side"], sig["qty"], price, sig["sl"], sig["tp"], tick)
        except BrokerError as e:
            self.db.update_signal(sig["id"], status="fehler", reason=str(e))
            self.db.log(f"Order fehlgeschlagen: {e}", "error")
            return {"ok": False, "status": "fehler", "reason": str(e)}
        pid = uuid.uuid4().hex[:10]
        self.db.add_position({
            "id": pid, "signal_id": sig["id"], "broker": self.broker.name, "root": root, "contract": sig["contract"],
            "side": sig["side"], "setup": sig["setup"], "qty": sig["qty"], "entry": round_tick(fill, tick),
            "sl": sig["sl"], "tp": sig["tp"], "initial_sl": sig["sl"], "opened": time.time(),
            "status": "offen", "broker_ref": ref, "is_test": sig.get("is_test", 0),
            "bar_time": sig.get("bar_time")})
        self.db.update_signal(sig["id"], status="ausgeführt", reason="")
        self.db.log(f"{sig['side'].upper()} {sig['qty']}× {root} gefüllt @ {fill:.2f} · Stop {sig['sl']:.2f} · Ziel {sig['tp']:.2f}")
        return {"ok": True, "status": "ausgeführt", "position": pid}

    def accept(self, sid, overrides=None):
        with self.lock:
            sig = self.db.signal(sid)
            if not sig or sig["status"] != "offen":
                raise ValueError("Vorschlag ist nicht mehr offen")
            o = overrides or {}
            fam = family(sig["root"])
            upd = {}
            if o.get("qty") not in (None, ""):
                q = int(o["qty"])
                if not (1 <= q <= int(self.cfg["sizing"]["max_qty"])):
                    raise ValueError(f"Anzahl muss zwischen 1 und {self.cfg['sizing']['max_qty']} liegen")
                upd["qty"] = q
            if o.get("sl") not in (None, "") or o.get("tp") not in (None, ""):
                sl_in = self._num(o.get("sl")) if o.get("sl") not in (None, "") else sig["sl"]
                tp_in = self._num(o.get("tp")) if o.get("tp") not in (None, "") else sig["tp"]
                sl, tp, flags = self._safe_stop(fam, sig["side"], sig["entry"], sl_in, tp_in)
                upd.update(sl=sl, tp=tp, flags=sig["flags"] + [f for f in flags if f not in sig["flags"]])
            if upd:
                q = upd.get("qty", sig["qty"])
                upd["risk_usd"] = round(q * abs(sig["entry"] - upd.get("sl", sig["sl"])) * INSTR[sig["root"]]["pv"], 2)
                self.db.update_signal(sid, **upd)
                sig = self.db.signal(sid)
            guard = self._guards(fam)
            if guard:
                self.db.update_signal(sid, status="blockiert", reason=guard)
                raise ValueError(guard)
            return self._execute(sig)

    def reject(self, sid):
        with self.lock:
            sig = self.db.signal(sid)
            if not sig or sig["status"] != "offen":
                raise ValueError("Vorschlag ist nicht mehr offen")
            self.db.update_signal(sid, status="abgelehnt", reason="Von dir abgelehnt")
            self.db.log(f"Vorschlag {sig['side'].upper()} {sig['root']} abgelehnt")
            return {"ok": True}

    def _unrealized(self, pos):
        bar = self.last_bar.get(family(pos["root"]))
        if not bar:
            return 0.0
        d = 1 if pos["side"] == "long" else -1
        return (bar["close"] - pos["entry"]) * d * pos["qty"] * INSTR[pos["root"]]["pv"]

    def _finish(self, pos, exit_price, reason, slip=True):
        tick = INSTR[pos["root"]]["tick"]
        if pos["broker"] == "paper" and slip:
            exit_price = self.broker.close(pos, exit_price, tick) if self.broker.name == "paper" else exit_price
        d = 1 if pos["side"] == "long" else -1
        comm = float(self.cfg["paper"]["commission"]) * pos["qty"] * 2 if pos["broker"] == "paper" else 0.0
        pnl = (exit_price - pos["entry"]) * d * pos["qty"] * INSTR[pos["root"]]["pv"] - comm
        self.db.update_position(pos["id"], status="geschlossen", closed=time.time(), exit=round_tick(exit_price, tick),
                                pnl=round(pnl, 2), close_reason=reason)
        self.db.log(f"{pos['side'].upper()} {pos['qty']}× {pos['root']} geschlossen ({reason}) · {pnl:+,.0f} $",
                    "info" if pnl >= 0 else "warn")

    def _close(self, pos, price, reason):
        tick = INSTR[pos["root"]]["tick"]
        price = price or (self.last_bar.get(family(pos["root"])) or {}).get("close") or pos["entry"]
        try:
            exit_price = self.broker.close(pos, price, tick)
        except BrokerError as e:
            self.db.log(f"Schließen fehlgeschlagen: {e}", "error")
            raise ValueError(str(e))
        self._finish(pos, exit_price, reason, slip=False)

    def close_position(self, pid, reason="Manuell geschlossen"):
        with self.lock:
            pos = self.db.position(pid)
            if not pos or pos["status"] != "offen":
                raise ValueError("Position ist nicht mehr offen")
            self._close(pos, None, reason)
            return {"ok": True}

    def move_to_breakeven(self, pid):
        with self.lock:
            pos = self.db.position(pid)
            if not pos or pos["status"] != "offen":
                raise ValueError("Position ist nicht mehr offen")
            bar = self.last_bar.get(family(pos["root"]))
            d = 1 if pos["side"] == "long" else -1
            if bar and (bar["close"] - pos["entry"]) * d <= 0:
                raise ValueError("Position liegt nicht im Gewinn, Break-even würde sofort auslösen")
            try:
                self.broker.modify_stop(pos, pos["entry"])
            except BrokerError as e:
                raise ValueError(str(e))
            self.db.update_position(pid, sl=pos["entry"])
            self.db.log(f"Stop für {pos['root']} auf Break-even {pos['entry']:.2f} gezogen")
            return {"ok": True}

    def flatten_all(self):
        with self.lock:
            for s in self.db.pending():
                self.db.update_signal(s["id"], status="abgelehnt", reason="Notaus")
            errors = []
            for pos in self.db.open_positions():
                try:
                    self._close(pos, None, "Notaus")
                except ValueError as e:
                    errors.append(str(e))
            self.cfg["paused"] = True
            self._write_cfg(self.cfg)
            self.db.log("NOTAUS: alles geschlossen, Handel pausiert", "warn")
            if errors:
                raise ValueError("; ".join(errors))
            return {"ok": True}

    def test_signal(self, fam, side):
        with self.lock:
            last = (self.last_bar.get(fam) or {}).get("close")
            price = last or (21000.0 if fam == "NQ" else 6000.0)
            if not last:
                self.last_bar[fam] = {"open": price, "high": price, "low": price, "close": price, "ts": time.time()}
            ss = self.cfg["safe_stop"][fam]["default"] * 0.5
            d = 1 if side == "long" else -1
            return self._on_entry({"ticker": fam + "1!", "action": "buy" if side == "long" else "sell",
                                   "price": price, "stopLoss": price - d * ss, "setup": "Test-Signal"}, is_test=True)

    def reset_paper(self):
        with self.lock:
            if any(p["broker"] == "paper" for p in self.db.open_positions()):
                raise ValueError("Erst alle Paper-Positionen schließen")
            self.db.reset_trades("paper")
            self.db.log("Paper-Konto zurückgesetzt")

    # ───────── Lernmodul ─────────
    def _close_shadow(self, sh, exit_price):
        risk = abs(sh["entry"] - sh["sl"]) or 1e-9
        d = 1 if sh["side"] == "long" else -1
        self.db.update_shadow(sh["id"], status="geschlossen", closed=time.time(), exit=exit_price,
                              r=round((exit_price - sh["entry"]) * d / risk, 3))

    def setup_rule(self, setup):
        manual = self.cfg["setup_rules"].get(setup, "auto")
        if manual == "aus":
            return "aus"
        if manual == "an" or not self.cfg["learning"]["enabled"]:
            return "aktiv"
        return (self.learning.get("setups", {}).get(setup) or {}).get("status", "lernt")

    def learn(self):
        """Tägliche Auswertung aller Schatten-Trades je Strategie. Senkt Risiko automatisch, erhöht es nie über normal."""
        with self.lock:
            L = self.cfg["learning"]
            by = {}
            for s in self.db.closed_shadows():
                by.setdefault(s["setup"], []).append(s)
            prev = self.learning.get("setups", {})
            setups, insights = {}, []
            for name, lst in sorted(by.items()):
                recent = lst[-int(L["window"]):]
                rs = [x["r"] for x in recent]
                n = len(rs)
                avg = sum(rs) / n
                if n < int(L["min_trades"]):
                    status = "lernt"
                elif avg < float(L["pause_below_r"]):
                    status = "pausiert"
                elif avg < float(L["half_below_r"]):
                    status = "halbe Größe"
                else:
                    status = "aktiv"
                old = (prev.get(name) or {}).get("status")
                if old and old != status:
                    msg = f"{name}: {old} → {status} (Ø {avg:+.2f} R aus den letzten {n} Trades)"
                    insights.append({"kind": "change", "text": msg})
                    self.db.log("Lernmodul: " + msg, "warn" if status in ("pausiert", "halbe Größe") else "info")
                hours = {}
                for x in lst[-150:]:
                    hours.setdefault(x["ny_hour"], []).append(x["r"])
                for h, v in sorted(hours.items()):
                    if len(v) >= 6:
                        m = sum(v) / len(v)
                        if m <= -0.3:
                            insights.append({"kind": "bad", "text": f"{name} verliert um {h}:00 NY (Ø {m:+.2f} R aus {len(v)} Trades)"})
                        elif m >= 0.5:
                            insights.append({"kind": "good", "text": f"{name} läuft stark um {h}:00 NY (Ø {m:+.2f} R aus {len(v)} Trades)"})
                setups[name] = {"status": status, "n": n, "total": len(lst), "avg_r": round(avg, 3),
                                "winrate": round(sum(1 for r in rs if r > 0) / n * 100, 1), "sum_r": round(sum(rs), 2)}
            self.learning = {"last_run": time.time(), "last_day": str(ny_date()), "setups": setups, "insights": insights[:15]}
            with open(self.learn_path, "w", encoding="utf-8") as f:
                json.dump(self.learning, f, indent=2, ensure_ascii=False)
            return self.learning

    def learning_view(self):
        rows = []
        names = set(self.learning.get("setups", {})) | set(self.cfg["setup_rules"]) | \
            {s["setup"] for s in self.db.rows("SELECT DISTINCT setup FROM shadow")}
        for name in sorted(names):
            d = dict(self.learning.get("setups", {}).get(name) or {"status": "lernt", "n": 0, "total": 0})
            d["setup"] = name
            d["manual"] = self.cfg["setup_rules"].get(name, "auto")
            d["effective"] = self.setup_rule(name)
            d["open"] = len([s for s in self.db.open_shadows() if s["setup"] == name])
            rows.append(d)
        return {"last_run": self.learning.get("last_run"), "setups": rows,
                "insights": self.learning.get("insights", []), "params": self.cfg["learning"]}

    # ───────── Hintergrund ─────────
    def _loop(self):
        while True:
            time.sleep(2)
            try:
                self.tick()
            except Exception as e:   # Hintergrundschleife darf nie sterben
                self.db.log(f"Hintergrundfehler: {e}", "error")

    def tick(self):
        with self.lock:
            now = time.time()
            for s in self.db.pending():
                if s["expires"] and now > s["expires"]:
                    self.db.update_signal(s["id"], status="verfallen", reason="Zeit abgelaufen")
                    self.db.log(f"Vorschlag {s['side'].upper()} {s['root']} verfallen")
            r = self.cfg["risk"]
            t = ny_time()
            if t.weekday() < 5 and t.strftime("%H:%M") >= "16:00" and self.learning.get("last_day") != str(t.date()):
                for sh in self.db.open_shadows():
                    last = (self.last_bar.get(sh["fam"]) or {}).get("close")
                    if last:
                        self._close_shadow(sh, last)
                self.learn()
                self.db.log("Lernmodul: Tagesauswertung abgeschlossen")
            if r["flat_at_session_end"] and self.db.open_positions():
                for pos in self.db.open_positions():
                    o = ny_time(pos["opened"])
                    # schließen, sobald keine angehakte Session mehr läuft (wie in der TradingView-Strategie)
                    started_in = next((k for k in TRADING_SESSIONS if in_session(k, o)), None)
                    if started_in and (not self.session_now(t) or time.time() - pos["opened"] > 20 * 3600):
                        try:
                            self._close(pos, None, "Sessionende")
                        except ValueError:
                            pass
            if self.cfg["own_sync"].get("tradovate") and time.time() >= self.sync_state["next"]:
                self.sync_state["next"] = time.time() + 600
                threading.Thread(target=self.own_sync, daemon=True).start()
            if self.broker.name != "paper" and self.broker_ok:
                mine = [p for p in self.db.open_positions() if p["broker"] == self.broker.name]
                try:
                    for pos, exit_price in self.broker.sync(mine):
                        reason = "Stop-Loss" if exit_price and abs(exit_price - pos["sl"]) <= abs(exit_price - (pos["tp"] or 0)) else "Ziel erreicht"
                        self._finish(pos, exit_price or pos["sl"], reason + " (Broker)", slip=False)
                except BrokerError as e:
                    self.broker_status = str(e)

    # ───────── Statistik & Zustand ─────────
    def stats(self, include_tests=False):
        trades = [p for p in self.db.closed_positions()
                  if p["broker"] == self.broker.name and (include_tests or not p["is_test"])]
        wins = [t for t in trades if t["pnl"] > 0]
        losses = [t for t in trades if t["pnl"] <= 0]
        gp = sum(t["pnl"] for t in wins)
        gl = -sum(t["pnl"] for t in losses)
        eq, peak, mdd, curve = 0.0, 0.0, 0.0, []
        for t in trades:
            eq += t["pnl"]
            peak = max(peak, eq)
            mdd = min(mdd, eq - peak)
            curve.append({"t": t["closed"], "e": round(eq, 2)})
        by_setup = {}
        for t in trades:
            b = by_setup.setdefault(t["setup"] or "–", {"n": 0, "w": 0, "net": 0.0})
            b["n"] += 1
            b["w"] += t["pnl"] > 0
            b["net"] += t["pnl"]
        r_mult = [t["pnl"] / (abs(t["entry"] - t["initial_sl"]) * t["qty"] * INSTR[t["root"]]["pv"])
                  for t in trades if t["initial_sl"] and t["entry"] != t["initial_sl"]]
        return {
            "n": len(trades), "net": round(gp - gl, 2), "winrate": len(wins) / len(trades) * 100 if trades else None,
            "pf": gp / gl if gl > 0 else None, "avg_win": gp / len(wins) if wins else None,
            "avg_loss": -gl / len(losses) if losses else None, "max_dd": round(mdd, 2),
            "avg_r": sum(r_mult) / len(r_mult) if r_mult else None,
            "curve": curve[-500:], "by_setup": by_setup,
            "trades": list(reversed(trades))[:100],
        }

    # ───────── Kalender: Bot-Trades + eigene Trades ─────────
    def _calendar_trades(self):
        out = []
        for t in self.db.closed_positions():
            if t["broker"] == "eigen":
                t["source"] = "eigen"
            elif t["broker"] == self.broker.name and not t["is_test"]:
                t["source"] = "bot"
            else:
                continue
            t["day"] = t.get("trade_day") or str(ny_date(t["closed"]))
            out.append(t)
        return out

    def daily(self):
        """P&L je Handelstag, getrennt nach Bot und eigenen Trades."""
        days = {}
        for t in self._calendar_trades():
            d = days.setdefault(t["day"], {s: {"pnl": 0.0, "n": 0, "w": 0} for s in ("bot", "eigen")})
            b = d[t["source"]]
            b["pnl"] += t["pnl"] or 0
            b["n"] += 1
            b["w"] += (t["pnl"] or 0) > 0
        for d in days.values():
            for b in d.values():
                b["pnl"] = round(b["pnl"], 2)
        return days

    def day_trades(self, day):
        return sorted([t for t in self._calendar_trades() if t["day"] == day], key=lambda t: t["opened"] or t["closed"])

    def _own_insert(self, t):
        pid = uuid.uuid4().hex[:10]
        self.db.add_position({
            "id": pid, "signal_id": "", "broker": "eigen", "source": "eigen", "root": t["root"], "contract": t["root"],
            "side": t["side"], "setup": "Eigener Trade", "qty": t["qty"], "entry": t.get("entry"), "exit": t.get("exit"),
            "sl": None, "tp": None, "initial_sl": None, "opened": t["opened"], "closed": t["closed"],
            "pnl": round(t["pnl"], 2), "status": "geschlossen", "close_reason": t.get("note") or "Eigener Trade",
            "broker_ref": {"key": t.get("key", "")}, "is_test": 0, "trade_day": t["day"], "note": t.get("note", "")})
        return pid

    def own_add(self, b):
        """Eigenen Trade von Hand eintragen. P&L direkt oder aus Punkten × Punktwert × Anzahl − Gebühren."""
        with self.lock:
            day = str(b.get("day") or "")
            dt.date.fromisoformat(day)
            root = str(b.get("root") or "NQ").upper()
            side = "short" if str(b.get("side")).lower() == "short" else "long"
            qty = int(b.get("qty") or 1)
            if qty < 1:
                raise ValueError("Anzahl muss mindestens 1 sein")
            entry, exit_, fees = self._num(b.get("entry")), self._num(b.get("exit")), self._num(b.get("fees")) or 0.0
            pnl = self._num(b.get("pnl"))
            if pnl is None:
                if entry is None or exit_ is None or root not in INSTR:
                    raise ValueError("Bitte Ein- und Ausstieg angeben oder das P&L direkt eintragen")
                d = 1 if side == "long" else -1
                pnl = (exit_ - entry) * d * qty * INSTR[root]["pv"] - fees
            ts = self._num(b.get("ts")) or dt.datetime.combine(dt.date.fromisoformat(day), dt.time(16), dt.timezone.utc).timestamp()
            pid = self._own_insert({"root": root, "side": side, "qty": qty, "entry": entry, "exit": exit_, "pnl": pnl,
                                    "opened": self._num(b.get("ts_in")) or ts, "closed": ts, "day": day,
                                    "note": str(b.get("note") or "")[:120]})
            self.db.log(f"Eigener Trade eingetragen: {day} {side.upper()} {qty}× {root} · {pnl:+,.0f} $")
            return {"ok": True, "id": pid}

    # ───────── Eigene Trades automatisch aus Tradovate ─────────
    def test_tradovate(self):

        try:
            return {"ok": True, "status": BROKERS["tradovate"](self.cfg).connect()}
        except BrokerError as e:
            return {"ok": False, "status": str(e)}

    def own_sync(self):

        if not self.cfg["own_sync"].get("tradovate"):
            raise ValueError("Automatische Übernahme ist ausgeschaltet")
        st = self.sync_state
        st["next"] = time.time() + 600
        try:
            if self._sync_client is None:
                self._sync_client = BROKERS["tradovate"](self.cfg)
            trips = self._sync_client.round_trips()
        except BrokerError as e:
            st.update(error=str(e), last=time.time())
            self._sync_client = None
            return dict(st, ok=False)
        with self.lock:
            bot_orders = set()
            for p in self.db.rows("SELECT broker_ref FROM positions WHERE broker='tradovate'"):
                try:
                    ref = json.loads(p["broker_ref"] or "{}")
                except ValueError:
                    ref = {}
                bot_orders |= {ref.get(k) for k in ("orderId", "stopId", "tpId")} - {None}
            existing = {(p.get("broker_ref") or {}).get("key") for p in self.db.closed_positions() if p["broker"] == "eigen"}
            added = 0
            for t in trips:
                key = f"tradovate-pair-{t['id']}"
                if key in existing or any(o in bot_orders for o in t["order_ids"]):
                    continue
                try:
                    tb = dt.datetime.fromisoformat(str(t["buy_ts"]).replace("Z", "+00:00")).timestamp()
                    ts = dt.datetime.fromisoformat(str(t["sell_ts"]).replace("Z", "+00:00")).timestamp()
                except ValueError:
                    continue
                m = re.match(r"^(MNQ|MES|MYM|M2K|MGC|MCL|SIL|NQ|ES|YM|RTY|GC|CL|SI)", str(t["contract"]).upper())
                root = m.group(1) if m else str(t["contract"])[:8]
                pv = POINT_VALUE.get(root)
                if pv is None:
                    continue
                long_ = tb <= ts
                qty = int(t["qty"])
                td = t.get("trade_date") or {}
                day = f"{td['year']}-{td['month']:02d}-{td['day']:02d}" if td.get("year") else str(ny_date(max(tb, ts)))
                self._own_insert({"root": root, "side": "long" if long_ else "short", "qty": qty,
                                  "entry": t["buy"] if long_ else t["sell"], "exit": t["sell"] if long_ else t["buy"],
                                  "pnl": (t["sell"] - t["buy"]) * qty * pv, "opened": min(tb, ts), "closed": max(tb, ts),
                                  "day": day, "key": key, "note": "Tradovate (ohne Gebühren)"})
                existing.add(key)
                added += 1
            st.update(last=time.time(), added=added, error="")
            if added:
                self.db.log(f"Tradovate: {added} eigene Trades übernommen")
        return dict(st, ok=True)

    def own_delete(self, pid):
        with self.lock:
            p = self.db.position(pid)
            if not p or p["broker"] != "eigen":
                raise ValueError("Nur eigene Trades können gelöscht werden")
            self.db._exec("DELETE FROM positions WHERE id=?", (pid,))
            return {"ok": True}

    def own_import(self, text, subtract_fees=True):
        """CSV-Import eigener Trades (Topstep/ProjectX, Tradovate, NinjaTrader u. a.). Spalten werden automatisch erkannt."""
        import csv
        import hashlib
        import io
        text = text.lstrip("\ufeff")
        try:
            dialect = csv.Sniffer().sniff(text[:4000], delimiters=",;\t")
        except csv.Error:
            dialect = csv.excel
        rows = list(csv.reader(io.StringIO(text), dialect))
        if len(rows) < 2:
            raise ValueError("Die Datei enthält keine Trades")
        norm = lambda h: re.sub(r"[^a-z0-9&%]", "", h.lower())   # noqa: E731
        head = [norm(h) for h in rows[0]]

        def col(*names, avoid=("%", "cum", "kum", "total", "percent")):
            for n in names:
                for i, h in enumerate(head):
                    if n in h and not any(a in h for a in avoid):
                        return i
            return None

        c_pnl = col("netpnl", "netprofit", "pnl", "p&l", "profit", "gewinn", "realized")
        if c_pnl is None:
            raise ValueError("Keine P&L-Spalte gefunden (z. B. „PnL“, „Profit“, „P&L“)")
        c_exit = col("exitedat", "exittime", "soldtimestamp", "closetime", "closedat", "exitdate", "closed", "sold")
        c_entry = col("enteredat", "entrytime", "boughttimestamp", "opentime", "openedat", "entrydate", "bought")
        c_date = col("tradeday", "tradedate", "datetime", "date", "time", "datum")
        c_sym = col("contractname", "contract", "symbol", "instrument", "ticker", "product")
        c_qty = col("size", "qty", "quantity", "contracts", "menge")
        c_side = col("type", "side", "direction", "richtung")
        c_ein = col("entryprice", "buyprice", "openprice", "avgentry")
        c_aus = col("exitprice", "sellprice", "closeprice", "avgexit")
        c_fee = [i for i, h in enumerate(head) if any(k in h for k in ("fee", "commission", "gebuehr", "gebühr"))]
        if c_exit is None and c_date is None and c_entry is None:
            raise ValueError("Keine Datums-Spalte gefunden")

        def num(v):
            v = (v or "").strip().replace("$", "").replace("€", "").replace(" ", "").replace("−", "-")
            if v.startswith("(") and v.endswith(")"):
                v = "-" + v[1:-1]
            if v.count(",") and v.count("."):
                v = v.replace(",", "") if v.rfind(".") > v.rfind(",") else v.replace(".", "").replace(",", ".")
            elif v.count(",") == 1:
                v = v.replace(",", ".")
            try:
                return float(v)
            except ValueError:
                return None

        def when(v):
            v = (v or "").strip()
            if not v:
                return None
            iso = v.replace(" ", "T", 1) if re.match(r"\d{4}-\d{2}-\d{2} ", v) else v
            try:
                d = dt.datetime.fromisoformat(iso.replace("Z", "+00:00"))
                return d if d.tzinfo else d.astimezone()
            except ValueError:
                pass
            base = re.sub(r"\s*[+-]\d{2}:?\d{2}$", "", v)
            for f in ("%m/%d/%Y %H:%M:%S", "%m/%d/%Y %H:%M", "%m/%d/%Y %I:%M:%S %p", "%m/%d/%Y %I:%M %p", "%m/%d/%Y",
                      "%d.%m.%Y %H:%M:%S", "%d.%m.%Y %H:%M", "%d.%m.%Y", "%Y/%m/%d %H:%M:%S", "%Y-%m-%d"):
                try:
                    return dt.datetime.strptime(base, f).astimezone()
                except ValueError:
                    continue
            return None

        existing = {(p.get("broker_ref") or {}).get("key") for p in self.db.closed_positions() if p["broker"] == "eigen"}
        added, skipped, bad = 0, 0, 0
        with self.lock:
            for r in rows[1:]:
                if not any(x.strip() for x in r):
                    continue
                g = lambda i: r[i] if i is not None and i < len(r) else ""   # noqa: E731
                pnl = num(g(c_pnl))
                t_exit = when(g(c_exit)) or when(g(c_date)) or when(g(c_entry))
                if pnl is None or t_exit is None:
                    bad += 1
                    continue
                fees = sum(num(g(i)) or 0 for i in c_fee) if subtract_fees else 0.0
                t_entry = when(g(c_entry)) or t_exit
                day_raw = when(g(c_date)) if c_date is not None and "tradeday" in head[c_date] else None
                day = str(day_raw.date()) if day_raw else str(ny_date(t_exit.timestamp()))
                sym = g(c_sym).strip().upper()
                m = re.match(r"^/?(MNQ|MES|NQ|ES|MYM|YM|M2K|RTY|MGC|GC|MCL|CL)", sym.split(":")[-1])
                root = m.group(1) if m else (sym[:12] or "?")
                side_raw = g(c_side).lower()
                side = "short" if any(k in side_raw for k in ("short", "sell", "verkauf")) else "long"
                qty = abs(int(num(g(c_qty)) or 1)) or 1
                key = hashlib.sha1("|".join([day, sym, g(c_entry), g(c_exit), g(c_pnl), g(c_ein), g(c_aus)]).encode()).hexdigest()
                if key in existing:
                    skipped += 1
                    continue
                existing.add(key)
                self._own_insert({"root": root, "side": side, "qty": qty, "entry": num(g(c_ein)), "exit": num(g(c_aus)),
                                  "pnl": pnl - fees, "opened": t_entry.timestamp(), "closed": t_exit.timestamp(),
                                  "day": day, "key": key, "note": "Import"})
                added += 1
            self.db.log(f"Eigene Trades importiert: {added} neu, {skipped} schon vorhanden, {bad} nicht lesbar")
        return {"ok": True, "added": added, "skipped": skipped, "bad": bad, "fees": bool(c_fee) and subtract_fees}

    def state(self):
        with self.lock:
            opens = self.db.open_positions()
            for p in opens:
                p["upnl"] = round(self._unrealized(p), 2)
                p["last"] = (self.last_bar.get(family(p["root"])) or {}).get("close")
            r = self.cfg["risk"]
            now_ny = ny_time()
            return {
                "config": self.public_cfg(),
                "instruments": INSTR,
                "now_ny": now_ny.strftime("%H:%M"),
                "session_open": bool(self.session_now(now_ny)),
                "session_name": TRADING_SESSIONS[self.session_now(now_ny)][0] if self.session_now(now_ny) else "",
                "sessions": {k: {"name": v[0], "start": v[1], "end": v[2]} for k, v in TRADING_SESSIONS.items()},
                "tv": {"last_msg": self.last_msg,
                       "last_bar": {k: v for k, v in self.last_bar.items()}},
                "broker": {"name": self.broker.name, "label": self.broker.label, "ok": self.broker_ok,
                           "status": self.broker_status},
                "balance": self.balance(),
                "today": {"pnl": round(self.today_pnl(), 2), "trades": len(self._today_trades()),
                          "max_trades": r["max_trades_day"], "max_loss": r["max_daily_loss"]},
                "pending": self.db.pending(),
                "positions": opens,
                "signals": self.db.signals(40),
                "events": self.db.events(30),
                "stats": self.stats(),
                "learning": self.learning_view(),
                "daily": self.daily(),
                "own_sync": dict(self.sync_state, enabled=bool(self.cfg["own_sync"].get("tradovate"))),
                "sizing_preview": {fam: [self.size_preview(fam, pts) for pts in
                                         ((10, 20, 40, 60) if fam == "NQ" else (3, 5, 10, 15))]
                                   for fam in ("NQ", "ES")},
            }

# ═════════════════ tunnel.py ═════════════════
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
    def _run(self):
        delay = 5
        while not self._stopped:
            token = (self.get_token() or "").strip()
            self.provider = "ngrok" if token else "cloudflare"
            try:
                flags = 0x08000000 if sys.platform.startswith("win") else 0   # kein extra Fenster unter Windows
                if token:
                    exe = self._ngrok()
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
                self.status = f"Fehler: {last_err}" if last_err else "getrennt, verbinde neu"
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

# ═════════════════ appshell.py ═════════════════
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
        with open(flag, encoding="utf-8") as f:
            if f.read().strip() == launcher:
                return
    except OSError:
        pass
    try:
        desktop, programs = _folders()[:2]
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

INDEX_HTML = '<!doctype html>\n<html lang="de">\n<head>\n<meta charset="utf-8">\n<meta name="viewport" content="width=device-width, initial-scale=1">\n<title>FVG Trader</title>\n<link rel="manifest" href="/manifest.webmanifest">\n<meta name="theme-color" content="#2f5bd3">\n<meta name="apple-mobile-web-app-capable" content="yes">\n<meta name="mobile-web-app-capable" content="yes">\n<meta name="apple-mobile-web-app-title" content="FVG Trader">\n<link rel="apple-touch-icon" href="/icon-192.png">\n<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns=\'http://www.w3.org/2000/svg\' viewBox=\'0 0 32 32\'%3E%3Crect width=\'32\' height=\'32\' rx=\'6\' fill=\'%232f5bd3\'/%3E%3Crect x=\'7\' y=\'6\' width=\'5\' height=\'12\' fill=\'white\'/%3E%3Crect x=\'14\' y=\'11\' width=\'5\' height=\'14\' fill=\'white\' opacity=\'.55\'/%3E%3Crect x=\'21\' y=\'15\' width=\'5\' height=\'11\' fill=\'white\'/%3E%3C/svg%3E">\n<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Archivo:wght@600;800&family=Public+Sans:wght@400;500;600&family=IBM+Plex+Mono:wght@400;500&display=swap">\n<style>\n/* Layout: feste Kopfzeile mit Modus-Schalter & Notaus → Reiter → Cockpit (Vorschläge zuerst, dann Positionen, dann Verlauf) */\n:root{\n  --bg:#f3f4f7; --surface:#fff; --sunk:#eceef3; --line:#d9dce5; --fg:#161a24; --muted:#5d6475;\n  --accent:#2f5bd3; --accent-fg:#fff; --pos:#0f8a72; --neg:#d2493f; --warn:#b86e00; --fill:rgba(47,91,211,.10);\n  --pos-bg:rgba(15,138,114,.10); --neg-bg:rgba(210,73,63,.10); --warn-bg:rgba(184,110,0,.12);\n  --f-display:"Archivo","Arial Narrow",system-ui,sans-serif;\n  --f-body:"Public Sans",system-ui,-apple-system,"Segoe UI",sans-serif;\n  --f-mono:"IBM Plex Mono",ui-monospace,Menlo,Consolas,monospace;\n  color-scheme:light;\n}\n@media (prefers-color-scheme:dark){:root{\n  --bg:#10131b; --surface:#171b26; --sunk:#12151e; --line:#2a3040; --fg:#e7e9ef; --muted:#9097a8;\n  --accent:#7b9cff; --accent-fg:#0d1020; --pos:#3cc4a4; --neg:#f2766b; --warn:#f0a43a; --fill:rgba(123,156,255,.14);\n  --pos-bg:rgba(60,196,164,.12); --neg-bg:rgba(242,118,107,.12); --warn-bg:rgba(240,164,58,.14); color-scheme:dark}}\n*{box-sizing:border-box}\n[hidden]{display:none!important}\nhtml,body{margin:0}\nbody{background:var(--bg);color:var(--fg);font:14px/1.5 var(--f-body);-webkit-font-smoothing:antialiased}\n.wrap{max-width:1200px;margin:0 auto;padding:0 max(16px,env(safe-area-inset-left,0px)) 60px max(16px,env(safe-area-inset-right,0px))}\nbutton{font:inherit;cursor:pointer}\nbutton:focus-visible,input:focus-visible,select:focus-visible{outline:2px solid var(--accent);outline-offset:2px}\ninput,select{font:inherit;color:var(--fg);background:var(--surface);border:1px solid var(--line);border-radius:6px;padding:7px 10px;min-width:0}\ninput[type=number]{font-family:var(--f-mono);font-variant-numeric:tabular-nums}\n.mono{font-family:var(--f-mono);font-variant-numeric:tabular-nums}\n.pos{color:var(--pos)} .neg{color:var(--neg)} .muted{color:var(--muted)}\n\n/* Kopfzeile */\n.top{position:sticky;top:0;z-index:5;background:var(--bg);border-bottom:1px solid var(--line)}\n.top .wrap{padding-bottom:0}\n.bar{display:flex;align-items:center;gap:14px;flex-wrap:wrap;padding:12px 0}\n.brand{font-family:var(--f-display);font-weight:800;font-size:20px;letter-spacing:-.01em;margin-right:auto;display:flex;align-items:center;gap:10px}\n.brand i{display:inline-block;width:22px;height:22px;border-radius:5px;background:var(--accent)}\n.pill{display:inline-flex;align-items:center;gap:6px;font-size:12px;padding:4px 10px;border-radius:999px;border:1px solid var(--line);color:var(--muted);white-space:nowrap}\n.dot{width:8px;height:8px;border-radius:50%;background:var(--muted)}\n.dot.ok{background:var(--pos)} .dot.bad{background:var(--neg)} .dot.warn{background:var(--warn)}\n.switch{display:flex;align-items:center;gap:10px;padding:5px 6px 5px 12px;border:1px solid var(--line);border-radius:999px;background:var(--surface)}\n.switch b{font-weight:600;font-size:13px}\n.tgl{position:relative;width:46px;height:26px;border-radius:999px;border:0;background:var(--line);transition:background .15s}\n.tgl::after{content:"";position:absolute;top:3px;left:3px;width:20px;height:20px;border-radius:50%;background:#fff;transition:transform .15s;box-shadow:0 1px 2px rgba(0,0,0,.25)}\n.tgl[aria-checked=true]{background:var(--pos)} .tgl[aria-checked=true]::after{transform:translateX(20px)}\n.btn{border:1px solid var(--line);background:var(--surface);color:var(--fg);border-radius:6px;padding:7px 12px;font-weight:500}\n.btn.primary{background:var(--accent);border-color:var(--accent);color:var(--accent-fg);font-weight:600}\n.btn.good{background:var(--pos);border-color:var(--pos);color:#fff;font-weight:600}\n.btn.danger{background:var(--neg);border-color:var(--neg);color:#fff;font-weight:600}\n.btn.ghost-danger{color:var(--neg);border-color:var(--neg)}\n.btn:disabled{opacity:.5;cursor:default}\n.tabs{display:flex;gap:4px;overflow-x:auto}\n@media (max-width:600px){\n  .top{position:static}\n  .bar{gap:8px;padding:10px 0}\n  .brand{font-size:18px;width:100%}\n  #pSess,#pBroker{display:none}\n  .switch{padding:3px 4px 3px 10px}\n  #kill{padding:6px 10px}\n  .tabs button{padding:9px 9px}\n}\n.tabs button{border:0;background:none;color:var(--muted);padding:10px 12px;border-bottom:2px solid transparent;font-weight:500;white-space:nowrap}\n.tabs button[aria-selected=true]{color:var(--fg);border-bottom-color:var(--accent)}\n.banner{margin:12px 0 0;padding:10px 14px;border-radius:6px;background:var(--warn-bg);color:var(--warn);font-weight:500}\n\nmain{display:flex;flex-direction:column;gap:20px;padding-top:20px}\nh2{font-family:var(--f-display);font-weight:600;font-size:16px;margin:0}\n.section{display:flex;flex-direction:column;gap:10px;min-width:0}\n.section-h{display:flex;align-items:baseline;justify-content:space-between;gap:10px;flex-wrap:wrap}\n.hint{color:var(--muted);font-size:12.5px;margin:0}\n.panel{background:var(--surface);border:1px solid var(--line);border-radius:8px;padding:16px;min-width:0}\n.empty{color:var(--muted);font-size:13px;padding:18px;border:1px dashed var(--line);border-radius:8px;text-align:center}\n\n/* Kennzahlen */\n.kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(118px,1fr));background:var(--surface);border:1px solid var(--line);border-radius:8px;overflow:hidden}\n.kpi{background:var(--surface);padding:12px 14px;display:flex;flex-direction:column;gap:2px;min-width:0;box-shadow:1px 0 0 var(--line),0 1px 0 var(--line)}\n.seg{display:inline-flex;border:1px solid var(--line);border-radius:6px;overflow:hidden;background:var(--surface)}\n.seg button{font:500 13px var(--f-body);background:transparent;color:var(--muted);border:0;border-right:1px solid var(--line);padding:7px 12px;cursor:pointer}\n.seg button:last-child{border-right:0}\n.seg button[aria-pressed="true"]{background:var(--fill);color:var(--accent);font-weight:600}\n.kpi .l{font-size:11px;text-transform:uppercase;letter-spacing:.08em;color:var(--muted)}\n.kpi .v{font-family:var(--f-mono);font-size:20px;font-weight:500;font-variant-numeric:tabular-nums;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\n.meter{height:4px;border-radius:2px;background:var(--sunk);overflow:hidden;margin-top:4px}\n.meter i{display:block;height:100%;background:var(--neg)}\n\n/* Vorschläge */\n.cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(320px,1fr));gap:14px}\n.sug{background:var(--surface);border:1px solid var(--line);border-left:4px solid var(--accent);border-radius:8px;padding:14px 16px;display:flex;flex-direction:column;gap:12px}\n.sug.long{border-left-color:var(--pos)} .sug.short{border-left-color:var(--neg)}\n.sug-h{display:flex;align-items:center;gap:10px;flex-wrap:wrap}\n.side{font-family:var(--f-display);font-weight:800;font-size:18px;letter-spacing:.02em}\n.side.long{color:var(--pos)} .side.short{color:var(--neg)}\n.chip{display:inline-block;font-size:11.5px;padding:2px 7px;border-radius:4px;background:var(--fill);color:var(--accent);font-weight:500;white-space:nowrap}\n.chip.warn{background:var(--warn-bg);color:var(--warn)}\n.chip.good{background:var(--pos-bg);color:var(--pos)}\n.chip.bad{background:var(--neg-bg);color:var(--neg)}\n.chip.mute{background:var(--sunk);color:var(--muted)}\n.timer{margin-left:auto;font-family:var(--f-mono);font-size:12px;color:var(--muted)}\n.lv{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:8px 12px}\n.lv div{display:flex;flex-direction:column;min-width:0}\n.lv span{font-size:11px;color:var(--muted);text-transform:uppercase;letter-spacing:.06em}\n.lv b{font-family:var(--f-mono);font-weight:500;font-size:15px;font-variant-numeric:tabular-nums}\n.edit{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:8px}\n.edit label{display:flex;flex-direction:column;gap:3px;font-size:11px;color:var(--muted);text-transform:uppercase;letter-spacing:.06em}\n.edit input{width:100%}\n.flags{display:flex;gap:6px;flex-wrap:wrap}\n.actions{display:flex;gap:8px}\n.actions .btn{flex:1;padding:9px 12px}\n\n/* Tabellen */\n.scroll{overflow-x:auto}\ntable{width:100%;border-collapse:collapse;font-variant-numeric:tabular-nums}\nth{font-size:11px;text-transform:uppercase;letter-spacing:.07em;color:var(--muted);font-weight:600;text-align:right;padding:7px 8px;border-bottom:1px solid var(--line);white-space:nowrap}\ntd{font-family:var(--f-mono);font-size:12.5px;text-align:right;padding:7px 8px;border-bottom:1px solid var(--line);white-space:nowrap}\ntd.t,th.t{text-align:left;font-family:var(--f-body)}\ntd.wrap{white-space:normal;min-width:260px;font-family:var(--f-body);font-size:12.5px;text-align:left;color:var(--muted)}\ntr:last-child td{border-bottom:0}\n.rowbtns{display:flex;gap:6px;justify-content:flex-end}\n.rowbtns .btn{padding:4px 9px;font-size:12px}\n\n.grid2{display:grid;grid-template-columns:minmax(0,1.4fr) minmax(0,1fr);gap:20px}\n@media (max-width:860px){.grid2{grid-template-columns:1fr}}\n.wizard{list-style:none;margin:12px 0 0;padding:0;display:grid;gap:14px}\n.wizard li{display:grid;grid-template-columns:28px minmax(0,1fr);gap:12px;align-items:start}\n.wizard .num{width:26px;height:26px;border-radius:50%;display:grid;place-items:center;font-weight:600;font-size:13px;background:var(--sunk);color:var(--muted)}\n.wizard li.done .num{background:var(--pos-bg);color:var(--pos)}\n.wizard li.now .num{background:var(--accent);color:var(--accent-fg)}\n.wizard li.done .hint{display:none}\n.feed{display:flex;flex-direction:column;gap:0;max-height:360px;overflow:auto}\n.feed div{display:grid;grid-template-columns:52px 1fr;gap:8px;padding:6px 0;border-bottom:1px solid var(--line);font-size:12.5px}\n.feed time{font-family:var(--f-mono);color:var(--muted);font-size:11.5px}\n.feed .warn{color:var(--warn)} .feed .error{color:var(--neg)}\nsvg{display:block;width:100%;height:auto}\nsvg text{fill:var(--muted);font-family:var(--f-mono);font-size:11px}\n.gl{stroke:var(--line)}\n\n/* Performance & Grafiken */\n.perf{display:flex;flex-direction:column;gap:14px}\n.perf-h{display:flex;justify-content:space-between;align-items:center;gap:10px;flex-wrap:wrap}\n.perf-ctl{display:flex;gap:8px;flex-wrap:wrap}\n.perf-b{display:grid;grid-template-columns:auto minmax(0,1fr);gap:24px;align-items:center}\n.ring{position:relative;width:170px;height:170px;flex:none}\n.ring svg{display:block}\n.ring-c{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center}\n.ring-v{font-family:var(--f-mono);font-size:22px;font-weight:600;font-variant-numeric:tabular-nums}\n.ring-l{font-size:12px;color:var(--muted)}\n.perf-side{display:flex;flex-direction:column;gap:12px;min-width:0}\n.perf-stats{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:10px}\n.perf-stats div{display:flex;flex-direction:column;gap:2px;padding:10px 12px;border-radius:8px;background:var(--sunk);min-width:0}\n.perf-stats span{font-size:11px;text-transform:uppercase;letter-spacing:.07em;color:var(--muted)}\n.perf-stats b{font-family:var(--f-mono);font-size:17px;font-weight:500;white-space:nowrap}\n.spark{border-radius:8px;background:var(--sunk);padding:6px}\n.spark svg{width:100%;display:block}\n.hbars{display:flex;flex-direction:column;gap:10px}\n.hbar{display:grid;grid-template-columns:minmax(0,1.2fr) minmax(0,1fr) auto;gap:12px;align-items:center}\n.hbar-l{display:flex;flex-direction:column;gap:2px;min-width:0}\n.hbar-l .hint{font-size:11.5px}\n.hbar-t{position:relative;height:10px;border-radius:5px;background:var(--sunk);overflow:hidden}\n.hbar-mid{position:absolute;left:50%;top:0;bottom:0;width:1px;background:var(--line)}\n.hbar-t i{position:absolute;top:0;bottom:0;border-radius:5px}\n.hbar-t i.p{left:50%;background:var(--pos)} .hbar-t i.n{right:50%;background:var(--neg)}\n.hbar b{font-size:13px;text-align:right;min-width:70px}\n.panel{box-shadow:0 1px 2px rgba(10,15,30,.04)}\n@media (max-width:720px){ .perf-b{grid-template-columns:1fr;justify-items:center} .perf-side{width:100%} .perf-stats{grid-template-columns:repeat(2,minmax(0,1fr))} }\n\n.sess-list{display:flex;flex-direction:column;gap:6px}\n.sess{display:grid;grid-template-columns:20px minmax(0,1fr) auto auto;gap:10px;align-items:center;padding:9px 12px;border:1px solid var(--line);border-radius:8px;cursor:pointer}\n.sess.on,.sess:has(input:checked){border-color:var(--accent);background:var(--fill)}\n.sess-n{font-size:13.5px;font-weight:500}\n.sess-t{font-size:12px}\n@media (max-width:560px){ .sess{grid-template-columns:20px minmax(0,1fr)} .sess-t{grid-column:2} }\n\n/* Kalender */\n.cal-h{display:flex;align-items:center;gap:10px;flex-wrap:wrap}\n.cal-h h2{font-size:20px;min-width:170px;text-align:center}\n.cal-nav{width:34px;height:34px;padding:0;font-size:18px;line-height:1}\n.cal{display:grid;grid-template-columns:repeat(5,minmax(0,1fr)) minmax(0,1.1fr);gap:6px}\n.cal .dow{font-size:11px;text-transform:uppercase;letter-spacing:.08em;color:var(--muted);font-weight:600;padding:0 4px 2px}\n.day{position:relative;min-height:92px;border:1px solid var(--line);border-radius:8px;background:var(--surface);padding:8px 10px;display:flex;flex-direction:column;justify-content:space-between;text-align:left;font:inherit;color:inherit;min-width:0}\n.day.win{background:var(--pos-bg);border-color:color-mix(in srgb,var(--pos) 35%,var(--line))}\n.day.loss{background:var(--neg-bg);border-color:color-mix(in srgb,var(--neg) 35%,var(--line))}\n.day.out{background:transparent;border-style:dashed;opacity:.45}\n.day.today{outline:2px solid var(--accent);outline-offset:-1px}\n.day.sel{box-shadow:0 0 0 2px var(--fg) inset}\nbutton.day{cursor:pointer}\n.day .dn{font-size:12px;color:var(--muted);font-variant-numeric:tabular-nums}\n.day .pl{font-family:var(--f-mono);font-size:17px;font-weight:500;font-variant-numeric:tabular-nums;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\n.day .pl .s{display:none}\n.day .meta{font-size:11.5px;color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\n.wk{border-radius:8px;border:1px solid var(--line);background:var(--sunk);padding:8px 10px;display:flex;flex-direction:column;justify-content:space-between;min-height:92px;min-width:0}\n.wk .dn{font-size:11px;text-transform:uppercase;letter-spacing:.06em;color:var(--muted)}\n.wk .pl{font-family:var(--f-mono);font-size:17px;font-weight:600;font-variant-numeric:tabular-nums;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\n.wk .pl .s,.wk .dn .s{display:none}\n@media (max-width:640px){\n  .cal{gap:3px}\n  .day,.wk{min-height:58px;padding:5px 5px;border-radius:6px}\n  .day .pl,.wk .pl{font-size:12px}\n  .day .pl .f,.wk .pl .f,.wk .dn .f{display:none} .day .pl .s,.wk .pl .s,.wk .dn .s{display:inline}\n  .day .meta,.wk .meta{display:none}\n  .cal .dow{font-size:10px;padding:0 2px}\n}\n\n.day .meta .s,.wk .meta .s{display:none}\n.modal-bg{position:fixed;inset:0;z-index:40;background:rgba(10,12,20,.55);display:grid;place-items:center;padding:16px;overflow:auto}\n.modal{max-width:460px;width:100%;display:flex;flex-direction:column;gap:12px;box-shadow:0 20px 50px rgba(0,0,0,.3)}\n.modal select{width:100%}\n.modal:has(.logbox){max-width:820px}\n.logbox{max-height:min(60vh,520px);overflow:auto;white-space:pre;word-break:normal;margin:0;font-size:11.5px;line-height:1.45}\n@media (max-width:640px){ .day .meta,.wk .meta{display:block;font-size:10px} .day .meta .f,.wk .meta .f{display:none} .day .meta .s,.wk .meta .s{display:inline} }\n\n/* Einstellungen */\n.settings-wrap{max-width:820px;margin:0 auto;display:flex;flex-direction:column;gap:14px;width:100%}\n.set-sec{background:var(--surface);border:1px solid var(--line);border-radius:10px;padding:16px 18px;display:flex;flex-direction:column;gap:12px;min-width:0}\n.set-h{display:flex;flex-direction:column;gap:2px}\n.set-h h2{font-size:16px}\n.set-b{display:flex;flex-direction:column;gap:10px;min-width:0}\n.sub{display:flex;flex-direction:column;gap:10px;padding-left:12px;border-left:2px solid var(--line)}\n.form{display:flex;flex-direction:column;gap:12px}\n.row{display:grid;grid-template-columns:minmax(0,1fr) minmax(170px,42%);gap:12px;align-items:center}\n.row[hidden]{display:none}\n.row label{font-size:13.5px}\n.row small{display:block;color:var(--muted);font-size:11.5px;margin-top:1px}\n.row input,.row select{width:100%}\n.row .tgl,.row > .btn,.row .chk{justify-self:end}\n.row input.chk,.chk{width:18px;height:18px;accent-color:var(--accent)}\n.inline{display:flex;gap:8px;align-items:center;justify-content:flex-end;flex-wrap:wrap}\n.inline input[type=time]{width:auto}\n.wrap-gap{justify-content:flex-start}\n.lbl{display:block;font-size:11px;text-transform:uppercase;letter-spacing:.07em;color:var(--muted);font-weight:600;margin:4px 0 4px}\n.preview{display:flex;flex-direction:column;gap:4px;background:var(--sunk);border-radius:8px;padding:10px 12px;font-size:12.5px}\n.preview div{display:flex;gap:6px 14px;flex-wrap:wrap;align-items:baseline}\n.pv{font-family:var(--f-mono);font-size:12px;color:var(--muted)}\n.pv b{color:var(--fg);font-weight:500}\ndetails.adv summary{cursor:pointer;list-style:none;display:flex;justify-content:space-between;align-items:center}\ndetails.adv summary::-webkit-details-marker{display:none}\ndetails.adv summary::after{content:"▾";color:var(--muted);transition:transform .15s}\ndetails.adv[open] summary::after{transform:rotate(180deg)}\n.savebar{position:sticky;bottom:max(12px,env(safe-area-inset-bottom,0px));margin:14px auto 0;max-width:820px;width:100%;display:flex;gap:10px;align-items:center;justify-content:flex-end;background:var(--surface);border:1px solid var(--accent);border-radius:10px;padding:10px 14px;box-shadow:0 8px 24px rgba(0,0,0,.18);z-index:6}\n.savebar .hint{margin-right:auto}\n@media (max-width:560px){ .row{grid-template-columns:1fr} .row .tgl,.row > .btn,.row .chk{justify-self:start} .inline{justify-content:flex-start} }\n.save{display:flex;gap:10px;align-items:center;justify-content:flex-end}\n.ok-msg{font-size:12.5px;color:var(--pos)} .err-msg{font-size:12.5px;color:var(--neg)}\n.code{font-family:var(--f-mono);font-size:12px;background:var(--sunk);border:1px solid var(--line);border-radius:6px;padding:10px;word-break:break-all;white-space:pre-wrap}\n.copyrow{display:flex;gap:8px;align-items:stretch}\n.copyrow .code{flex:1;min-width:0}\nol.steps{margin:0;padding-left:18px;display:grid;gap:6px;font-size:13px}\n\n/* Login */\n.login{min-height:100vh;display:grid;place-items:center;padding:16px}\n.login form{width:min(360px,100%);display:flex;flex-direction:column;gap:12px;background:var(--surface);border:1px solid var(--line);border-radius:10px;padding:24px}\n.login h1{font-family:var(--f-display);font-weight:800;font-size:24px;margin:0}\n\n.toast{position:fixed;left:50%;bottom:max(20px,env(safe-area-inset-bottom,0px));transform:translateX(-50%);background:var(--fg);color:var(--bg);padding:10px 16px;border-radius:8px;font-size:13px;z-index:20;max-width:calc(100% - 32px)}\n@media (prefers-reduced-motion:reduce){*{transition:none!important}}\n</style>\n</head>\n<body>\n<div id="app"></div>\n<div id="toast" class="toast" hidden></div>\n\n<script>\nconst $ = (s, el = document) => el.querySelector(s);\nconst esc = s => String(s ?? "").replace(/[&<>"\']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",\'"\':"&quot;","\'":"&#39;"}[c]));\nconst usd = v => v == null || !isFinite(v) ? "–" : (v < 0 ? "−$" : "$") + Math.abs(v).toLocaleString("de-DE", {maximumFractionDigits: 0});\nconst usd2 = v => v == null || !isFinite(v) ? "–" : (v < 0 ? "−$" : "$") + Math.abs(v).toLocaleString("de-DE", {minimumFractionDigits: 2, maximumFractionDigits: 2});\nconst px = v => v == null ? "–" : Number(v).toLocaleString("de-DE", {minimumFractionDigits: 2, maximumFractionDigits: 2});\nconst pct = v => v == null || !isFinite(v) ? "–" : v.toFixed(1).replace(".", ",") + " %";\nconst num2 = v => v == null || !isFinite(v) ? "–" : v.toFixed(2).replace(".", ",");\nconst cls = v => v > 0 ? "pos" : v < 0 ? "neg" : "";\nconst tm = ts => new Date(ts * 1000).toLocaleTimeString("de-DE", {hour: "2-digit", minute: "2-digit"});\nconst dtm = ts => new Date(ts * 1000).toLocaleString("de-DE", {day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit"});\n\n// Reiter in der Adresse merken, ohne neue Verlaufseinträge (sonst darf sich das App-Fenster nicht schließen)\nconst setHash = t => { try { history.replaceState(null, "", "#" + t); } catch (e) { location.hash = t; } };\nlet S = null, TAB = "cockpit", pendingKey = "", seenPending = new Set(), firstLoad = true, settingsDirty = false;\n\nasync function api(path, body) {\n  const opt = body === undefined ? {} : {method: "POST", headers: {"Content-Type": "application/json", "X-Requested-With": "fvg"}, body: JSON.stringify(body)};\n  const r = await fetch(path, opt);\n  const j = await r.json().catch(() => ({}));\n  if (r.status === 401 && !path.startsWith("/api/login")) { showLogin(); throw new Error("Bitte anmelden"); }\n  if (!r.ok) throw new Error(j.error || "Fehler " + r.status);\n  return j;\n}\nfunction toast(msg) {\n  const t = $("#toast"); t.textContent = msg; t.hidden = false;\n  clearTimeout(toast._t); toast._t = setTimeout(() => t.hidden = true, 3200);\n}\nasync function act(fn, okMsg) {\n  try { const r = await fn(); if (okMsg) toast(okMsg); await refresh(); return r; }\n  catch (e) { toast(e.message); }\n}\n\nfunction copyText(txt, label) {\n  const fallback = () => { const ta = document.createElement("textarea"); ta.value = txt; document.body.appendChild(ta); ta.select();\n    try { document.execCommand("copy"); toast((label || "Text") + " kopiert"); } catch (e) { toast("Bitte manuell kopieren"); } ta.remove(); };\n  if (navigator.clipboard) navigator.clipboard.writeText(txt).then(() => toast((label || "Text") + " kopiert"), fallback); else fallback();\n}\n\nasync function runUpdate(doIt) {\n  const before = S && S.version;\n  document.body.insertAdjacentHTML("beforeend", `<div id="updOv" style="position:fixed;inset:0;z-index:50;background:var(--bg);display:grid;place-items:center;padding:16px">\n    <div style="text-align:center;max-width:380px;display:flex;flex-direction:column;gap:10px;align-items:center">\n      <h2 style="font-size:20px" id="updT">Update wird geladen …</h2>\n      <p class="hint" id="updMsg" style="margin:0">Die neue Version wird heruntergeladen und geprüft.</p>\n      <div id="updAct"></div></div></div>`);\n  const msg = (t, m, act) => { $("#updT").textContent = t; $("#updMsg").innerHTML = m; $("#updAct").innerHTML = act || ""; };\n  let res;\n  try { res = await doIt(); } catch (e) {\n    msg("Update fehlgeschlagen", esc(e.message), \'<button class="btn" id="updClose">Schließen</button>\');\n    $("#updClose").onclick = () => $("#updOv").remove(); return;\n  }\n  const target = res && res.version;\n  msg("Neustart …", `Version <b>${esc(target || "neu")}</b> ist installiert. FVG Trader startet neu, das dauert ein paar Sekunden.`);\n  const t0 = Date.now();\n  let kills = 0;\n  const poll = async () => {\n    const secs = (Date.now() - t0) / 1000;\n    try {\n      const r = await fetch("/api/state", {cache: "no-store"});\n      if (r.status === 401) { location.reload(); return; }\n      if (r.ok) {\n        const j = await r.json();\n        if (j.version !== before) { location.reload(); return; }\n        if (secs > 12 && kills < 5) {   // eine alte Instanz antwortet noch: beenden, die neue übernimmt\n          kills++;\n          msg("Räume auf …", "Eine ältere FVG-Trader-Instanz läuft noch im Hintergrund und wird beendet.");\n          try { await fetch("/api/shutdown", {method: "POST", headers: {"X-Requested-With": "fvg", "Content-Type": "application/json"}, body: "{}"}); } catch (e) {}\n        }\n      }\n    } catch (e) {}\n    if (secs > 30) {\n      msg("Update installiert ✓", `Version <b>${esc(target || "neu")}</b> ist installiert.<br>Schließ dieses Fenster und starte FVG Trader über das <b>Desktop-Symbol</b>.`,\n        \'<button class="btn" id="updRetry">Erneut verbinden</button>\');\n      $("#updRetry").onclick = () => location.reload(); return;\n    }\n    setTimeout(poll, 1000);\n  };\n  setTimeout(poll, 2000);\n}\nasync function startupUpdatePrompt() {\n  if (!S.config.update_url) return;\n  let u;\n  try { u = await api("/api/update/check", {}); } catch (e) { return; }\n  if (!u.available) return;\n  try { if (sessionStorage.getItem("fvg-upd-asked") === u.version) return; sessionStorage.setItem("fvg-upd-asked", u.version); } catch (e) {}\n  document.body.insertAdjacentHTML("beforeend", `<div id="updAsk" role="dialog" aria-modal="true" aria-labelledby="updAskT"\n    style="position:fixed;inset:0;z-index:40;background:rgba(10,12,20,.55);display:grid;place-items:center;padding:16px">\n    <div class="panel" style="max-width:400px;width:100%;display:flex;flex-direction:column;gap:12px;box-shadow:0 20px 50px rgba(0,0,0,.3)">\n      <h2 id="updAskT" style="font-size:19px">Update verfügbar</h2>\n      <p style="margin:0">Version <b>${esc(u.version)}</b> ist da (installiert: ${esc(S.version)}).${u.notes ? `<br><span class="hint">${esc(u.notes)}</span>` : ""}</p>\n      <p class="hint" style="margin:0">Jetzt aktualisieren? Deine Einstellungen und Trades bleiben erhalten.</p>\n      <div class="actions"><button class="btn primary" id="updYes">Ja, jetzt aktualisieren</button><button class="btn" id="updNo">Nein</button></div>\n    </div></div>`);\n  $("#updYes").focus();\n  $("#updNo").onclick = () => $("#updAsk").remove();\n  $("#updYes").onclick = () => { $("#updAsk").remove(); runUpdate(() => api("/api/update/apply", {})); };\n}\n\n/* ───────── Login ───────── */\nasync function showLogin() {\n  const a = await fetch("/api/auth").then(r => r.json());\n  const setup = !a.has_password;\n  $("#app").innerHTML = `<div class="login"><form id="lf">\n    <h1>FVG Trader</h1>\n    <p class="hint">${setup ? "Lege ein Passwort fest. Es schützt die App, sobald sie über das Internet erreichbar ist." : "Melde dich an, um deinen Bot zu steuern."}</p>\n    <input id="pw" type="password" autocomplete="${setup ? "new-password" : "current-password"}" placeholder="Passwort${setup ? " (mind. 8 Zeichen)" : ""}" required>\n    <button class="btn primary" type="submit">${setup ? "Passwort festlegen" : "Anmelden"}</button>\n    <p id="lerr" class="err-msg" hidden></p></form></div>`;\n  $("#pw").focus();\n  $("#lf").onsubmit = async e => {\n    e.preventDefault();\n    try { await api(setup ? "/api/setup" : "/api/login", {password: $("#pw").value}); start(); }\n    catch (err) { $("#lerr").textContent = err.message; $("#lerr").hidden = false; }\n  };\n}\n\n/* ───────── Gerüst ───────── */\nfunction shell() {\n  $("#app").innerHTML = `\n  <div class="top"><div class="wrap">\n    <div class="bar">\n      <div class="brand"><i aria-hidden="true"></i>FVG Trader</div>\n      <span class="pill" id="pTv"></span>\n      <span class="pill" id="pBroker"></span>\n      <span class="pill" id="pSess"></span>\n      <div class="switch"><b id="autoLbl">Auto-Modus</b><button class="tgl" id="autoT" role="switch" aria-checked="false" aria-labelledby="autoLbl"></button></div>\n      <button class="btn danger" id="kill">Notaus</button>\n    </div>\n    <nav class="tabs" role="tablist">\n      ${[["cockpit","Cockpit"],["calendar","Kalender"],["stats","Statistik"],["learn","Lernmodul"],["settings","Einstellungen"]].map(([k,l]) =>\n        `<button role="tab" data-tab="${k}" aria-selected="${k===TAB}">${l}</button>`).join("")}\n    </nav>\n  </div></div>\n  <div class="wrap"><div id="banner"></div><main id="main"></main></div>`;\n  document.querySelectorAll(".tabs button").forEach(b => b.onclick = () => { TAB = b.dataset.tab; setHash(TAB); pendingKey = ""; settingsDirty = false;\n    document.querySelectorAll(".tabs button").forEach(x => x.setAttribute("aria-selected", x === b)); render(true); });\n  $("#autoT").onclick = () => act(() => api("/api/config", {auto_mode: !S.config.auto_mode}),\n    !S.config.auto_mode ? "Auto-Modus an: Signale werden direkt ausgeführt" : "Auto-Modus aus: Signale kommen als Vorschlag");\n  $("#kill").onclick = () => confirmBtn($("#kill"), "Wirklich alles schließen?", () =>\n    act(() => api("/api/flatten", {}), "Alles geschlossen, Handel pausiert"));\n}\nlet ARMED = {key: null, until: 0};\nconst armed = key => ARMED.key === key && Date.now() < ARMED.until;\nfunction confirmBtn(btn, question, fn) {\n  const key = btn.dataset.key || btn.id;\n  if (!btn.dataset.orig) btn.dataset.orig = btn.textContent;\n  if (armed(key)) { ARMED = {key: null, until: 0}; btn.textContent = btn.dataset.orig; fn(); return; }\n  ARMED = {key, until: Date.now() + 4000}; btn.textContent = question;\n  setTimeout(() => { if (ARMED.key === key && Date.now() >= ARMED.until) { ARMED = {key: null, until: 0}; } if (!armed(key) && document.body.contains(btn)) btn.textContent = btn.dataset.orig; }, 4100);\n}\n\nfunction header() {\n  const c = S.config, age = S.tv.last_msg ? (Date.now() / 1000 - S.tv.last_msg) : null;\n  const tvState = age == null ? ["bad", "TradingView: noch kein Signal"] : age < 900 ? ["ok", "TradingView verbunden · " + tm(S.tv.last_msg)] : ["warn", "TradingView: letzte Nachricht " + dtm(S.tv.last_msg)];\n  $("#pTv").innerHTML = `<span class="dot ${tvState[0]}"></span>${tvState[1]}`;\n  $("#pBroker").innerHTML = `<span class="dot ${S.broker.ok ? "ok" : "bad"}"></span>${esc(S.broker.label)}${S.broker.name === "tradovate" ? " " + (c.tradovate.env === "live" ? "LIVE" : "Demo") : ""}`;\n  $("#pBroker").title = S.broker.status;\n  $("#pSess").innerHTML = `<span class="dot ${S.session_open ? "ok" : ""}"></span>NY ${S.now_ny} · ${S.session_open ? esc(S.session_name) : "keine Session"}`;\n  $("#autoT").setAttribute("aria-checked", c.auto_mode);\n  $("#banner").innerHTML = c.paused ? `<div class="banner">Handel pausiert. Neue Signale werden blockiert. <button class="btn" id="resume" style="margin-left:8px">Fortsetzen</button></div>`\n    : (S.broker.name === "tradovate" && c.tradovate.env === "live" ? `<div class="banner">LIVE-Konto aktiv: Orders gehen mit echtem Geld an Tradovate.</div>` : "")\n    + (c.hook_confirmed && S.hook_url && !S.hook_confirmed ? `<div class="banner">Deine Webhook-Adresse hat sich nach dem Neustart geändert. Bitte im TradingView-Alert ersetzen:\n        <div class="copyrow" style="margin-top:8px"><div class="code" id="newHook">${esc(S.hook_url)}</div><button class="btn" id="cpNew">Kopieren</button><button class="btn primary" id="okNew">Erledigt</button></div></div>` : "");\n  if (S.update && S.update.available) {\n    $("#banner").innerHTML += `<div class="banner" style="background:var(--fill);color:var(--fg)">Update verfügbar: Version <b>${esc(S.update.version)}</b>${S.update.notes ? ` · ${esc(S.update.notes)}` : ""}\n      <button class="btn primary" id="updNow" style="margin-left:8px">Jetzt aktualisieren</button></div>`;\n    $("#updNow").onclick = () => runUpdate(() => api("/api/update/apply", {}));\n  }\n  const rs = $("#resume");\n  if ($("#cpNew")) { $("#cpNew").onclick = () => copyText(S.hook_url); $("#okNew").onclick = () => act(() => api("/api/hook-confirm", {}), "Gespeichert"); } if (rs) rs.onclick = () => act(() => api("/api/config", {paused: false}), "Handel fortgesetzt");\n}\n\n/* ───────── Cockpit ───────── */\nfunction cockpit(full) {\n  const m = $("#main"), t = S.today, lossUsed = t.max_loss > 0 ? Math.min(100, Math.max(0, -t.pnl / t.max_loss * 100)) : 0;\n  if (full || !$("#ck")) m.innerHTML = `<div id="ck" style="display:contents">\n    <div id="setup"></div>\n    <section class="kpis" id="todayK"></section>\n    <section class="panel perf" id="perf"></section>\n    <section class="section"><div class="section-h"><h2>Vorschläge</h2><p class="hint" id="sugHint"></p></div><div id="sugs"></div></section>\n    <section class="section"><div class="section-h"><h2>Offene Positionen</h2><p class="hint">Jede Position hat einen Stop-Loss beim Broker.</p></div><div id="posBox"></div></section>\n    <div class="grid2">\n      <section class="section"><h2>Signale</h2><div class="panel scroll" id="sigBox"></div></section>\n      <section class="section"><h2>Aktivität</h2><div class="panel feed" id="feed"></div></section>\n    </div></div>`;\n  setupPanel();\n  const perfKey = JSON.stringify([PERF, S.daily]);\n  if (perfKey !== cockpit._perfKey || full) { cockpit._perfKey = perfKey; $("#perf").innerHTML = perfCard(); bindPerf($("#perf"), () => { cockpit._perfKey = ""; cockpit(false); }); }\n  $("#todayK").innerHTML = [\n    ["Kontostand", S.balance == null ? "–" : usd2(S.balance), ""],\n    ["P&L heute", usd(t.pnl), cls(t.pnl)],\n    ["Trades heute", `${t.trades} / ${t.max_trades}`, ""],\n    ["Tageslimit genutzt", t.max_loss > 0 ? Math.round(lossUsed) + " %" : "aus", lossUsed >= 80 ? "neg" : "", lossUsed],\n    ["Modus", S.config.auto_mode ? "Automatisch" : "Vorschläge", S.config.auto_mode ? "pos" : ""],\n  ].map(([l, v, c, meter]) => `<div class="kpi"><span class="l">${l}</span><span class="v ${c}">${v}</span>${meter != null ? `<div class="meter"><i style="width:${meter}%"></i></div>` : ""}</div>`).join("");\n  $("#sugHint").textContent = S.config.auto_mode ? "Auto-Modus ist an: Signale werden ohne Rückfrage ausgeführt." : `Verfallen nach ${S.config.suggestion_timeout_sec} s ohne Antwort.`;\n\n  // Vorschläge nur neu aufbauen, wenn sich die Menge ändert (Eingaben bleiben erhalten)\n  const key = S.pending.map(p => p.id).join(",");\n  if (key !== pendingKey) {\n    pendingKey = key;\n    $("#sugs").innerHTML = S.pending.length ? `<div class="cards">${S.pending.map(sugCard).join("")}</div>`\n      : `<div class="empty">Keine offenen Vorschläge. ${S.config.auto_mode ? "Im Auto-Modus gehen Signale direkt in den Markt." : "Neue Signale aus TradingView erscheinen hier zum Annehmen oder Ablehnen."}</div>`;\n    S.pending.forEach(p => {\n      const card = $(`#s-${p.id}`), q = $(".q", card), sl = $(".sl", card), tp = $(".tp", card);\n      const upd = () => {\n        const inst = S.instruments[p.root], slv = parseFloat(sl.value), qv = parseInt(q.value) || 0;\n        const risk = isFinite(slv) ? Math.abs(p.entry - slv) * qv * inst.pv : NaN;\n        $(".risk", card).textContent = usd(risk);\n        const tpv = parseFloat(tp.value); $(".rr", card).textContent = isFinite(tpv) && isFinite(slv) ? num2(Math.abs(tpv - p.entry) / Math.abs(p.entry - slv)) + " R" : "–";\n      };\n      [q, sl, tp].forEach(i => i.oninput = upd); upd();\n      $(".acc", card).onclick = () => act(() => api(`/api/signal/${p.id}/accept`, {qty: q.value, sl: sl.value, tp: tp.value}), "Trade eröffnet");\n      $(".rej", card).onclick = () => act(() => api(`/api/signal/${p.id}/reject`, {}), "Vorschlag abgelehnt");\n    });\n  }\n  timers();\n\n  $("#posBox").innerHTML = S.positions.length ? `<div class="panel scroll"><table><thead><tr><th class="t">Kontrakt</th><th class="t">Strategie</th><th>Anz.</th><th>Einstieg</th><th>Kurs</th><th>Stop</th><th>Ziel</th><th>Offen</th><th></th></tr></thead><tbody>\n    ${S.positions.map(p => `<tr><td class="t"><span class="side ${p.side}" style="font-size:13px">${p.side === "long" ? "LONG" : "SHORT"}</span> ${esc(p.contract)}${p.is_test ? \' <span class="chip mute">Test</span>\' : ""}</td>\n      <td class="t"><span class="chip">${esc(p.setup)}</span></td><td>${p.qty}</td><td>${px(p.entry)}</td><td>${px(p.last)}</td>\n      <td class="neg">${px(p.sl)}${p.sl === p.entry ? \' <span class="chip good">BE</span>\' : ""}</td><td class="pos">${px(p.tp)}</td>\n      <td class="${cls(p.upnl)}">${usd(p.upnl)}</td>\n      <td><div class="rowbtns"><button class="btn be" data-id="${p.id}" ${p.sl === p.entry ? "disabled" : ""}>Break-even</button><button class="btn ghost-danger cl" data-id="${p.id}" data-key="cl-${p.id}" data-orig="Schließen">${armed("cl-" + p.id) ? "Sicher?" : "Schließen"}</button></div></td></tr>`).join("")}\n    </tbody></table></div>` : `<div class="empty">Keine offene Position.</div>`;\n  document.querySelectorAll("#posBox .be").forEach(b => b.onclick = () => act(() => api(`/api/position/${b.dataset.id}/breakeven`, {}), "Stop auf Break-even gezogen"));\n  document.querySelectorAll("#posBox .cl").forEach(b => b.onclick = () => confirmBtn(b, "Sicher?", () => act(() => api(`/api/position/${b.dataset.id}/close`, {}), "Position geschlossen")));\n\n  const stChip = s => ({"ausgeführt": "good", "offen": "", "abgelehnt": "mute", "verfallen": "mute", "ersetzt": "mute", "blockiert": "warn", "fehler": "bad"}[s] ?? "mute");\n  $("#sigBox").innerHTML = S.signals.length ? `<table><thead><tr><th class="t">Zeit</th><th class="t">Signal</th><th>Anz.</th><th>Stop</th><th class="t">Status</th><th class="t">Grund</th></tr></thead><tbody>\n    ${S.signals.slice(0, 15).map(s => `<tr><td class="t mono">${tm(s.ts)}</td><td class="t"><b class="side ${s.side}" style="font-size:12px">${s.side === "long" ? "L" : "S"}</b> ${esc(s.root)} <span class="chip">${esc(s.setup)}</span></td>\n      <td>${s.qty ?? "–"}</td><td>${px(s.sl)}</td><td class="t"><span class="chip ${stChip(s.status)}">${esc(s.status)}</span></td>\n      <td class="wrap">${esc(s.reason || (s.flags || []).join(" · "))}</td></tr>`).join("")}</tbody></table>`\n    : `<p class="hint">Noch keine Signale. Teste die Verbindung unter Einstellungen → TradingView.</p>`;\n  $("#feed").innerHTML = S.events.map(e => `<div><time>${tm(e.ts)}</time><span class="${e.level}">${esc(e.text)}</span></div>`).join("") || `<p class="hint">Noch keine Aktivität.</p>`;\n}\nlet setupKey = "";\nfunction setupPanel() {\n  let hidden = false; try { hidden = localStorage.getItem("fvg-setup-hidden") === "1"; } catch (e) {}\n  const hasSignal = S.signals.some(x => !x.is_test) || !!S.tv.last_msg;\n  let pineCopied = false; try { pineCopied = localStorage.getItem("fvg-pine-copied") === "1"; } catch (e) {}\n  const steps = [\n    {done: !!S.hook_url, title: "Internet-Verbindung", body: S.hook_url ? "Aktiv. TradingView kann deine App erreichen." : `Wird automatisch aufgebaut … (${esc(S.tunnel.status)})`},\n    {done: hasSignal || pineCopied, title: "Script in TradingView", body: `Kopiere das Script, öffne in TradingView unten den <b>Pine Editor</b>, lösche den Inhalt, füge es ein und klicke <b>Zum Chart hinzufügen</b>. Chart: <b>NQ1!</b> oder <b>ES1!</b>, 5 Minuten.\n      <div style="margin-top:8px"><button class="btn" id="cpPine">Script kopieren</button></div>`},\n    {done: S.hook_confirmed, title: "Alert anlegen", body: `In TradingView auf den Wecker klicken → Bedingung <b>FVG Bot</b> → <b>Orderausführungen und alert()-Aufrufe</b>. Unter Benachrichtigungen <b>Webhook-URL</b> anhaken und diese Adresse einfügen:\n      <div class="copyrow" style="margin:8px 0"><div class="code">${S.hook_url ? esc(S.hook_url) : "kommt gleich …"}</div><button class="btn" id="cpHook" ${S.hook_url ? "" : "disabled"}>Kopieren</button></div>\n      Bei Nachricht diesen Text einsetzen: <div class="copyrow" style="margin:8px 0"><div class="code">{{strategy.order.alert_message}}</div><button class="btn" id="cpMsg">Kopieren</button></div>\n      <button class="btn primary" id="hookOk" ${S.hook_url ? "" : "disabled"}>Alert ist angelegt</button>`},\n    {done: hasSignal, title: "Erstes Signal", body: hasSignal ? "Signale kommen an. Fertig!" : `Sobald die Strategie handelt, erscheint hier ein Vorschlag. Probier es jetzt aus: <button class="btn" id="tryIt">Test-Signal senden</button>`},\n  ];\n  const allDone = steps.every(x => x.done);\n  const key = JSON.stringify([hidden, steps.map(x => [x.done, x.body])]);\n  if (key === setupKey) return; setupKey = key;\n  const box = $("#setup");\n  if (hidden || allDone) { box.innerHTML = hidden && !allDone ? `<p class="hint">Einrichtung ausgeblendet · <button class="btn" id="showSetup" style="padding:3px 8px;font-size:12px">Anzeigen</button></p>` : ""; \n    const sh = $("#showSetup"); if (sh) sh.onclick = () => { try { localStorage.removeItem("fvg-setup-hidden"); } catch (e) {} setupKey = ""; setupPanel(); }; return; }\n  const next = steps.findIndex(x => !x.done);\n  box.innerHTML = `<section class="panel"><div class="section-h"><h2>Einrichtung · ${steps.filter(x => x.done).length} von ${steps.length}</h2><button class="btn" id="hideSetup" style="padding:4px 10px;font-size:12px">Ausblenden</button></div>\n    <ol class="wizard">${steps.map((x, i) => `<li class="${x.done ? "done" : i === next ? "now" : ""}"><span class="num">${x.done ? "✓" : i + 1}</span><div><b>${x.title}</b><div class="hint" style="font-size:13px;margin-top:2px">${x.body}</div></div></li>`).join("")}</ol></section>`;\n  $("#hideSetup").onclick = () => { try { localStorage.setItem("fvg-setup-hidden", "1"); } catch (e) {} setupKey = ""; setupPanel(); };\n  const b = id => $("#" + id);\n  if (b("cpPine")) b("cpPine").onclick = async () => { try { const r = await api("/api/pine"); copyText(r.source, "Script"); try { localStorage.setItem("fvg-pine-copied", "1"); } catch (e) {} setupKey = ""; setupPanel(); } catch (e) { toast(e.message); } };\n  if (b("cpHook")) b("cpHook").onclick = () => copyText(S.hook_url, "Adresse");\n  if (b("cpMsg")) b("cpMsg").onclick = () => copyText("{{strategy.order.alert_message}}", "Nachricht");\n  if (b("hookOk")) b("hookOk").onclick = () => act(() => api("/api/hook-confirm", {}), "Super, Alert ist verbunden");\n  if (b("tryIt")) b("tryIt").onclick = () => act(() => api("/api/test-signal", {fam: "NQ", side: "long"}), "Test-Signal gesendet");\n}\nfunction timers() {\n  (S.pending || []).forEach(p => { const el = $(`#s-${p.id} .timer`); if (el) { const s = Math.max(0, Math.round(p.expires - Date.now() / 1000)); el.textContent = `noch ${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`; } });\n}\nfunction sugCard(p) {\n  const inst = S.instruments[p.root];\n  return `<article class="sug ${p.side}" id="s-${p.id}">\n    <div class="sug-h"><span class="side ${p.side}">${p.side === "long" ? "LONG" : "SHORT"}</span><span class="mono">${esc(p.contract)}</span><span class="chip">${esc(p.setup)}</span>${p.is_test ? \'<span class="chip mute">Test</span>\' : ""}<span class="timer"></span></div>\n    <div class="lv"><div><span>Einstieg ca.</span><b>${px(p.entry)}</b></div><div><span>Risiko</span><b class="risk neg">–</b></div><div><span>Chance</span><b class="rr">–</b></div></div>\n    <div class="edit">\n      <label>Anzahl ${esc(p.root)}<input class="q" type="number" min="1" max="${S.config.sizing.max_qty}" step="1" value="${p.qty}"></label>\n      <label>Stop-Loss<input class="sl" type="number" step="${inst.tick}" value="${p.sl}"></label>\n      <label>Ziel<input class="tp" type="number" step="${inst.tick}" value="${p.tp}"></label>\n    </div>\n    ${p.flags && p.flags.length ? `<div class="flags">${p.flags.map(f => `<span class="chip warn">${esc(f)}</span>`).join("")}</div>` : ""}\n    <div class="actions"><button class="btn good acc">Annehmen</button><button class="btn rej">Ablehnen</button></div>\n  </article>`;\n}\n\n/* ───────── Statistik ───────── */\n/* ───────── Grafiken ───────── */\nlet PERF = {period: "monat", src: "alle"};\ntry { PERF = Object.assign(PERF, JSON.parse(localStorage.getItem("fvg-perf") || "{}")); } catch (e) {}\nconst savePerf = () => { try { localStorage.setItem("fvg-perf", JSON.stringify(PERF)); } catch (e) {} };\nconst isoDay = d => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;\nfunction perfData(period, src) {\n  const now = new Date(), today = isoDay(now);\n  let from = "0000";\n  if (period === "heute") from = today;\n  else if (period === "woche") { const d = new Date(now); d.setDate(d.getDate() - ((d.getDay() + 6) % 7)); from = isoDay(d); }\n  else if (period === "monat") from = today.slice(0, 8) + "01";\n  const days = Object.keys(S.daily || {}).filter(k => k >= from && k <= today).sort().map(k => {\n    const d = S.daily[k], b = d.bot || {pnl: 0, n: 0, w: 0}, o = d.eigen || {pnl: 0, n: 0, w: 0};\n    const r = src === "bot" ? b : src === "eigen" ? o : {pnl: b.pnl + o.pnl, n: b.n + o.n, w: b.w + o.w};\n    return {day: k, pnl: r.pnl, n: r.n, w: r.w};\n  }).filter(r => r.n);\n  const n = days.reduce((a, r) => a + r.n, 0), w = days.reduce((a, r) => a + r.w, 0), pnl = days.reduce((a, r) => a + r.pnl, 0);\n  let eq = 0; const curve = days.map(r => (eq += r.pnl));\n  return {days, n, w, l: n - w, pnl, curve, winDays: days.filter(r => r.pnl > 0).length,\n          best: days.reduce((a, r) => !a || r.pnl > a.pnl ? r : a, null), worst: days.reduce((a, r) => !a || r.pnl < a.pnl ? r : a, null)};\n}\nfunction donutSvg(w, l, size = 170) {\n  const r = 62, c = 2 * Math.PI * r, tot = w + l, fw = tot ? w / tot : 0;\n  const gap = tot && w && l ? 3 : 0, lw = Math.max(0, c * fw - gap), ll = Math.max(0, c * (1 - fw) - gap);\n  return `<svg viewBox="0 0 170 170" width="${size}" height="${size}" role="img" aria-label="Gewinn- und Verlust-Trades">\n    <circle cx="85" cy="85" r="${r}" fill="none" stroke="var(--sunk)" stroke-width="16"/>\n    ${tot ? `<circle cx="85" cy="85" r="${r}" fill="none" stroke="var(--pos)" stroke-width="16" stroke-linecap="round" stroke-dasharray="${lw} ${c}" transform="rotate(-90 85 85)"/>\n    <circle cx="85" cy="85" r="${r}" fill="none" stroke="var(--neg)" stroke-width="16" stroke-linecap="round" stroke-dasharray="${ll} ${c}" stroke-dashoffset="${-(c * fw)}" transform="rotate(-90 85 85)"/>` : ""}\n  </svg>`;\n}\nfunction sparkSvg(vals, W = 320, H = 70) {\n  if (vals.length < 2) return `<div class="hint" style="height:${H}px;display:grid;place-items:center">Kurve ab 2 Handelstagen</div>`;\n  const all = [0, ...vals], lo = Math.min(...all), hi = Math.max(...all), span = hi - lo || 1;\n  const x = i => 4 + (W - 8) * i / (all.length - 1), y = v => 6 + (H - 12) * (1 - (v - lo) / span);\n  const line = all.map((v, i) => `${i ? "L" : "M"}${x(i).toFixed(1)},${y(v).toFixed(1)}`).join("");\n  const col = vals[vals.length - 1] >= 0 ? "var(--pos)" : "var(--neg)";\n  return `<svg viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" style="height:${H}px" role="img" aria-label="Equity-Verlauf">\n    <line x1="4" x2="${W - 4}" y1="${y(0)}" y2="${y(0)}" class="gl" stroke-dasharray="3 3"/>\n    <path d="${line}L${x(all.length - 1)},${y(lo)}L${x(0)},${y(lo)}Z" fill="${col}" fill-opacity=".10"/>\n    <path d="${line}" fill="none" stroke="${col}" stroke-width="2" vector-effect="non-scaling-stroke"/></svg>`;\n}\nfunction dayBarsSvg(days) {\n  if (!days.length) return \'<p class="hint">Noch keine Handelstage im Zeitraum.</p>\';\n  const W = 900, H = 200, L = 56, R = 8, T = 10, B = 24, n = days.length;\n  const lo0 = Math.min(0, ...days.map(d => d.pnl)), hi0 = Math.max(0, ...days.map(d => d.pnl));\n  const span = hi0 - lo0 || 100, stepRaw = span / 4, mag = 10 ** Math.floor(Math.log10(stepRaw)), step = [1, 2, 2.5, 5, 10].find(m => m * mag >= stepRaw) * mag;\n  const lo = Math.floor(lo0 / step) * step, hi = Math.ceil(hi0 / step) * step || step;\n  const y = v => T + (H - T - B) * (1 - (v - lo) / (hi - lo)), bw = (W - L - R) / n;\n  let g = ""; for (let v = lo; v <= hi + 1e-9; v += step) g += `<line class="gl" x1="${L}" x2="${W - R}" y1="${y(v)}" y2="${y(v)}"/><text x="${L - 8}" y="${y(v) + 4}" text-anchor="end">${kUsd(v)}</text>`;\n  const every = Math.ceil(n / 10);\n  const bars = days.map((d, i) => { const x0 = L + i * bw + bw * .18, w = Math.max(2, bw * .64), y0 = y(Math.max(0, d.pnl)), h = Math.max(1, Math.abs(y(d.pnl) - y(0)));\n    return `<rect x="${x0}" y="${y0}" width="${w}" height="${h}" rx="2" fill="${d.pnl >= 0 ? "var(--pos)" : "var(--neg)"}"><title>${d.day}: ${sUsd(d.pnl)} · ${d.n} Trades</title></rect>` +\n      (i % every === 0 ? `<text x="${x0 + w / 2}" y="${H - 6}" text-anchor="middle">${d.day.slice(8)}.${d.day.slice(5, 7)}.</text>` : ""); }).join("");\n  return `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="P&L je Handelstag">${g}${bars}</svg>`;\n}\nconst PERIODS = [["heute", "Heute"], ["woche", "Woche"], ["monat", "Monat"], ["gesamt", "Gesamt"]];\nconst SOURCES = [["alle", "Alle"], ["bot", "Bot"], ["eigen", "Eigene"]];\nfunction perfCard(compact) {\n  const d = perfData(PERF.period, PERF.src), wr = d.n ? d.w / d.n * 100 : null;\n  const seg = (list, key) => `<div class="seg" role="group">${list.map(([k, l]) => `<button type="button" data-${key}="${k}" aria-pressed="${PERF[key] === k}">${l}</button>`).join("")}</div>`;\n  return `<div class="perf-h"><h2>Performance</h2><div class="perf-ctl">${seg(PERIODS, "period")}${seg(SOURCES, "src")}</div></div>\n    <div class="perf-b">\n      <div class="ring">${donutSvg(d.w, d.l)}<div class="ring-c"><span class="ring-v ${cls(d.pnl)}">${d.n ? sUsd(Math.round(d.pnl)) : "–"}</span><span class="ring-l">${wr == null ? "keine Trades" : `${Math.round(wr)} % Treffer`}</span></div></div>\n      <div class="perf-side">\n        <div class="perf-stats">\n          <div><span>Gewinner</span><b class="pos">${d.w}</b></div><div><span>Verlierer</span><b class="neg">${d.l}</b></div>\n          <div><span>Handelstage</span><b>${d.days.length}${d.days.length ? ` <small class="hint">(${d.winDays} grün)</small>` : ""}</b></div>\n          <div><span>Ø pro Tag</span><b class="${cls(d.days.length ? d.pnl / d.days.length : 0)}">${d.days.length ? sUsd(Math.round(d.pnl / d.days.length)) : "–"}</b></div>\n        </div>\n        ${compact ? "" : ""}<div class="spark">${sparkSvg(d.curve)}</div>\n      </div>\n    </div>`;\n}\nfunction bindPerf(root, rerender) {\n  root.querySelectorAll("[data-period]").forEach(b => b.onclick = () => { PERF.period = b.dataset.period; savePerf(); rerender(); });\n  root.querySelectorAll("[data-src]").forEach(b => b.onclick = () => { PERF.src = b.dataset.src; savePerf(); rerender(); });\n}\n\nfunction stats() {\n  const st = S.stats;\n  const all = perfData("gesamt", "alle"), last30 = all.days.slice(-30);\n  const setups = Object.entries(st.by_setup).sort((a, b) => b[1].net - a[1].net), maxAbs = Math.max(1, ...setups.map(([, v]) => Math.abs(v.net)));\n  $("#main").innerHTML = `\n    <section class="panel perf" id="perfS"></section>\n    <section class="panel"><div class="section-h"><h2>P&L je Handelstag</h2><p class="hint">Letzte ${last30.length} Handelstage, Bot und eigene Trades</p></div>${dayBarsSvg(last30)}</section>\n    <section class="kpis">${[\n      ["Netto-Gewinn", usd(st.net), cls(st.net)], ["Trades", st.n, ""], ["Trefferquote", pct(st.winrate), ""],\n      ["Profit-Faktor", num2(st.pf), st.pf >= 1 ? "pos" : st.pf != null ? "neg" : ""], ["Ø R pro Trade", num2(st.avg_r), cls(st.avg_r)],\n      ["Max. Drawdown", usd(st.max_dd), st.max_dd < 0 ? "neg" : ""], ["Ø Gewinn", usd(st.avg_win), "pos"], ["Ø Verlust", usd(st.avg_loss), "neg"],\n    ].map(([l, v, c]) => `<div class="kpi"><span class="l">${l}</span><span class="v ${c}">${v}</span></div>`).join("")}</section>\n    <section class="panel"><div class="section-h"><h2>Equity des Bots</h2><p class="hint">Kumulierter Gewinn je abgeschlossenem Trade (${esc(S.broker.label)}, ohne Test-Trades)</p></div><div id="eq"></div></section>\n    <div class="grid2">\n      <section class="section"><h2>Nach Strategie</h2><div class="panel">${st.n ? `<div class="hbars">\n        ${setups.map(([k, v]) => `<div class="hbar"><div class="hbar-l"><span class="chip">${esc(k)}</span><span class="hint">${v.n} Trades · ${pct(v.w / v.n * 100)}</span></div>\n          <div class="hbar-t"><div class="hbar-mid"></div><i class="${v.net >= 0 ? "p" : "n"}" style="width:${Math.abs(v.net) / maxAbs * 50}%"></i></div><b class="mono ${cls(v.net)}">${usd(v.net)}</b></div>`).join("")}\n        </div>` : \'<p class="hint">Noch keine abgeschlossenen Trades.</p>\'}</div></section>\n      <section class="section"><h2>Letzte Trades</h2><div class="panel scroll">${st.trades.length ? `<table><thead><tr><th class="t">Geschlossen</th><th class="t">Trade</th><th>Ein</th><th>Aus</th><th class="t">Grund</th><th>Netto</th></tr></thead><tbody>\n        ${st.trades.slice(0, 15).map(t => `<tr><td class="t mono">${dtm(t.closed)}</td><td class="t"><b class="side ${t.side}" style="font-size:12px">${t.side === "long" ? "L" : "S"}</b> ${t.qty}× ${esc(t.root)}</td><td>${px(t.entry)}</td><td>${px(t.exit)}</td><td class="t" style="font-family:var(--f-body);color:var(--muted)">${esc(t.close_reason)}</td><td class="${cls(t.pnl)}">${usd(t.pnl)}</td></tr>`).join("")}\n        </tbody></table>` : \'<p class="hint">Noch keine abgeschlossenen Trades.</p>\'}</div></section>\n    </div>`;\n  $("#eq").innerHTML = equitySvg(st.curve);\n  const pr = () => { $("#perfS").innerHTML = perfCard(); bindPerf($("#perfS"), pr); };\n  pr();\n}\nfunction equitySvg(curve) {\n  if (!curve.length) return \'<p class="hint">Die Kurve erscheint nach dem ersten abgeschlossenen Trade.</p>\';\n  const W = 900, H = 240, L = 60, R = 14, T = 14, B = 22, pts = [{e: 0}, ...curve];\n  const vals = pts.map(p => p.e), lo0 = Math.min(0, ...vals), hi0 = Math.max(0, ...vals);\n  const span = hi0 - lo0 || 100, stepRaw = span / 4, mag = 10 ** Math.floor(Math.log10(stepRaw)), step = [1, 2, 2.5, 5, 10].find(m => m * mag >= stepRaw) * mag;\n  const lo = Math.floor(lo0 / step) * step, hi = Math.ceil(hi0 / step) * step || step;\n  const x = i => L + (W - L - R) * i / Math.max(1, pts.length - 1), y = v => T + (H - T - B) * (1 - (v - lo) / (hi - lo));\n  let g = ""; for (let v = lo; v <= hi + 1e-9; v += step) g += `<line class="gl" x1="${L}" x2="${W - R}" y1="${y(v)}" y2="${y(v)}"/><text x="${L - 8}" y="${y(v) + 4}" text-anchor="end">${usd(v)}</text>`;\n  const line = pts.map((p, i) => `${i ? "L" : "M"}${x(i).toFixed(1)},${y(p.e).toFixed(1)}`).join("");\n  const last = pts[pts.length - 1], col = last.e >= 0 ? "var(--pos)" : "var(--neg)";\n  return `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="Equity-Kurve">\n    <defs><linearGradient id="eqg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="var(--accent)" stop-opacity=".28"/><stop offset="1" stop-color="var(--accent)" stop-opacity="0"/></linearGradient></defs>${g}\n    <path d="${line}L${x(pts.length - 1)},${y(Math.max(lo, 0))}L${x(0)},${y(Math.max(lo, 0))}Z" fill="url(#eqg)"/>\n    <path d="${line}" fill="none" stroke="var(--accent)" stroke-width="2"/><circle cx="${x(pts.length - 1)}" cy="${y(last.e)}" r="4" fill="${col}"/>\n    <text x="${L}" y="${H - 4}">Start</text><text x="${W - R}" y="${H - 4}" text-anchor="end">Trade ${pts.length - 1}</text></svg>`;\n}\n\n/* ───────── Kalender ───────── */\nconst CAL = {y: null, m: null, sel: null, detail: null, filter: "alle"};\ntry { CAL.filter = localStorage.getItem("fvg-cal-filter") || "alle"; } catch (e) {}\nconst MONTHS = ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember"];\nconst iso = d => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;\nconst kUsd = v => { const a = Math.abs(v); return (v < 0 ? "−" : v > 0 ? "+" : "") + "$" + (a >= 1000 ? (a / 1000).toFixed(a >= 10000 ? 0 : 1).replace(".", ",") + "k" : Math.round(a)); };\nconst sUsd = v => (v > 0 ? "+" : "") + usd(v);\n// Tageswerte passend zum Filter: {pnl, n, w, bot, own}\nfunction pick(d) {\n  if (!d) return null;\n  const b = d.bot || {pnl: 0, n: 0, w: 0}, o = d.eigen || {pnl: 0, n: 0, w: 0};\n  const r = CAL.filter === "bot" ? {...b} : CAL.filter === "eigen" ? {...o} : {pnl: b.pnl + o.pnl, n: b.n + o.n, w: b.w + o.w};\n  r.bot = CAL.filter === "eigen" ? 0 : b.n; r.own = CAL.filter === "bot" ? 0 : o.n;\n  return r.n ? r : null;\n}\nfunction countText(r, short) {\n  if (CAL.filter !== "alle") return short ? `${r.n}` : `${r.n} ${r.n === 1 ? "Trade" : "Trades"} · ${Math.round(r.w / r.n * 100)} %`;\n  const parts = [];\n  if (r.bot) parts.push(short ? `${r.bot}B` : `${r.bot} Bot`);\n  if (r.own) parts.push(short ? `${r.own}E` : `${r.own} ${r.own === 1 ? "eigener" : "eigene"}`);\n  return parts.join(short ? " " : " · ");\n}\nfunction calendar() {\n  const now = new Date();\n  if (CAL.y === null) { CAL.y = now.getFullYear(); CAL.m = now.getMonth(); }\n  const D = S.daily || {}, first = new Date(CAL.y, CAL.m, 1), last = new Date(CAL.y, CAL.m + 1, 0);\n  const start = new Date(first); start.setDate(1 - ((first.getDay() + 6) % 7));\n  const todayIso = iso(now), prefix = `${CAL.y}-${String(CAL.m + 1).padStart(2, "0")}`;\n  const mDays = Object.keys(D).filter(k => k.startsWith(prefix)).map(k => [k, pick(D[k])]).filter(([, r]) => r);\n  const mPnl = mDays.reduce((a, [, r]) => a + r.pnl, 0), wins = mDays.filter(([, r]) => r.pnl > 0), losses = mDays.filter(([, r]) => r.pnl < 0);\n  const mBot = Object.keys(D).filter(k => k.startsWith(prefix)).reduce((a, k) => a + (D[k].bot ? D[k].bot.pnl : 0), 0);\n  const mOwn = Object.keys(D).filter(k => k.startsWith(prefix)).reduce((a, k) => a + (D[k].eigen ? D[k].eigen.pnl : 0), 0);\n  const mTrades = mDays.reduce((a, [, r]) => a + r.n, 0);\n  const best = mDays.reduce((a, x) => !a || x[1].pnl > a[1].pnl ? x : a, null), worst = mDays.reduce((a, x) => !a || x[1].pnl < a[1].pnl ? x : a, null);\n  const dLabel = k => new Date(k + "T12:00:00").toLocaleDateString("de-DE", {day: "numeric", month: "short"});\n  let cells = ["Mo", "Di", "Mi", "Do", "Fr", "Woche"].map(d => `<div class="dow">${d}</div>`).join("");\n  let wkNo = 0;\n  for (let w = new Date(start); w <= last; w.setDate(w.getDate() + 7)) {\n    let wk = {pnl: 0, n: 0, bot: 0, own: 0, w: 0}, wkDays = 0;\n    for (let i = 0; i < 7; i++) {\n      const d = new Date(w); d.setDate(w.getDate() + i);\n      const inMonth = d.getMonth() === CAL.m, k = iso(d), r = inMonth ? pick(D[k]) : null;\n      if (r) { wk.pnl += r.pnl; wk.n += r.n; wk.bot += r.bot; wk.own += r.own; wk.w += r.w; wkDays++; }\n      if (i >= 5) continue;\n      if (!inMonth) { cells += `<div class="day out"><span class="dn">${d.getDate()}</span></div>`; continue; }\n      const cls = r ? (r.pnl > 0 ? "win" : r.pnl < 0 ? "loss" : "") : "";\n      cells += `<${r ? `button type="button" data-day="${k}"` : "div"} class="day ${cls} ${k === todayIso ? "today" : ""} ${CAL.sel === k ? "sel" : ""}" ${r ? `aria-label="${d.getDate()}. ${MONTHS[CAL.m]}: ${sUsd(r.pnl)}, ${countText(r)}"` : ""}>\n        <span class="dn">${d.getDate()}</span>\n        ${r ? `<span class="pl ${cls === "win" ? "pos" : cls === "loss" ? "neg" : ""}"><span class="f">${sUsd(r.pnl)}</span><span class="s">${kUsd(r.pnl)}</span></span>\n          <span class="meta"><span class="f">${countText(r)}</span><span class="s">${countText(r, true)}</span></span>` : `<span class="meta">&nbsp;</span>`}\n      </${r ? "button" : "div"}>`;\n    }\n    wkNo++;\n    cells += `<div class="wk"><span class="dn"><span class="f">Woche ${wkNo}</span><span class="s">W${wkNo}</span></span>\n      <span class="pl ${wk.pnl > 0 ? "pos" : wk.pnl < 0 ? "neg" : ""}">${wkDays ? `<span class="f">${sUsd(wk.pnl)}</span><span class="s">${kUsd(wk.pnl)}</span>` : "–"}</span>\n      <span class="meta"><span class="f">${wkDays ? `${wkDays} ${wkDays === 1 ? "Tag" : "Tage"} · ${countText(wk)}` : "kein Handel"}</span><span class="s">${wkDays ? countText(wk, true) : ""}</span></span></div>`;\n  }\n  const kpis = [\n    ["Monat", sUsd(mPnl), cls(mPnl)],\n    ...(CAL.filter === "alle" ? [["davon Bot", sUsd(mBot), cls(mBot)], ["davon eigene", sUsd(mOwn), cls(mOwn)]] : []),\n    ["Handelstage", mDays.length, ""],\n    ["Gewinntage", `${wins.length}${mDays.length ? ` · ${Math.round(wins.length / mDays.length * 100)} %` : ""}`, wins.length ? "pos" : ""],\n    ["Verlusttage", losses.length, losses.length ? "neg" : ""], ["Trades", mTrades, ""],\n    ["Bester Tag", best && best[1].pnl > 0 ? sUsd(best[1].pnl) : "–", "pos", best && best[1].pnl > 0 ? dLabel(best[0]) : ""],\n    ["Schlechtester Tag", worst && worst[1].pnl < 0 ? sUsd(worst[1].pnl) : "–", "neg", worst && worst[1].pnl < 0 ? dLabel(worst[0]) : ""],\n  ];\n  $("#main").innerHTML = `\n    <section class="section">\n      <div class="section-h">\n        <div class="cal-h"><button class="btn cal-nav" id="calPrev" aria-label="Vorheriger Monat">‹</button><h2>${MONTHS[CAL.m]} ${CAL.y}</h2><button class="btn cal-nav" id="calNext" aria-label="Nächster Monat">›</button>\n          <button class="btn" id="calToday" style="padding:6px 10px">Heute</button></div>\n        <div style="display:flex;gap:8px;flex-wrap:wrap;align-items:center">\n          <div class="seg" role="group" aria-label="Trades filtern">${[["alle", "Alle"], ["bot", "Bot"], ["eigen", "Eigene"]].map(([k, l]) => `<button type="button" data-f="${k}" aria-pressed="${CAL.filter === k}">${l}</button>`).join("")}</div>\n          <button class="btn" id="ownAdd">+ Eigener Trade</button>\n          <label class="btn" style="cursor:pointer">Importieren<input type="file" id="ownCsv" accept=".csv,.txt" hidden></label>\n        </div>\n      </div>\n      <section class="kpis">${kpis.map(([l, v, c, sub]) => `<div class="kpi"><span class="l">${l}</span><span class="v ${c}">${v}</span>${sub ? `<span class="hint" style="font-size:11.5px">${sub}</span>` : ""}</div>`).join("")}</section>\n      <div class="cal" role="grid" aria-label="Handelskalender">${cells}</div>\n      <p class="hint">Tage nach New-Yorker Handelsdatum. Bot-Trades ohne Test-Trades. Eigene Trades zählen nicht in die Bot-Statistik.</p>\n    </section>\n    <section class="section" id="dayBox">${CAL.detail && CAL.sel ? dayDetail() : (mDays.length ? \'<p class="hint">Tippe auf einen Tag, um seine Trades zu sehen.</p>\' : `<div class="empty">In diesem Monat gibt es ${CAL.filter === "eigen" ? "noch keine eigenen Trades. Trag sie mit „+ Eigener Trade“ ein oder importiere sie als CSV." : "noch keine abgeschlossenen Trades."}</div>`)}</section>`;\n  const go = dm => { CAL.m += dm; if (CAL.m < 0) { CAL.m = 11; CAL.y--; } if (CAL.m > 11) { CAL.m = 0; CAL.y++; } CAL.sel = null; CAL.detail = null; calendar(); };\n  $("#calPrev").onclick = () => go(-1); $("#calNext").onclick = () => go(1);\n  $("#calToday").onclick = () => { CAL.y = now.getFullYear(); CAL.m = now.getMonth(); CAL.sel = null; CAL.detail = null; calendar(); };\n  document.querySelectorAll(".seg [data-f]").forEach(b => b.onclick = () => { CAL.filter = b.dataset.f; try { localStorage.setItem("fvg-cal-filter", CAL.filter); } catch (e) {}\n    if (CAL.sel) openDay(CAL.sel); else calendar(); });\n  document.querySelectorAll(".cal button.day").forEach(b => b.onclick = () => openDay(b.dataset.day));\n  $("#ownAdd").onclick = () => ownTradeDialog(CAL.sel || todayIso);\n  document.querySelectorAll(".owndel").forEach(b => b.onclick = () => confirmBtn(b, "Sicher?", async () => {\n    try { await api(`/api/own/${b.dataset.id}/delete`, {}); toast("Eigener Trade gelöscht"); S = await api("/api/state"); openDay(CAL.sel); } catch (e) { toast(e.message); }\n  }));\n  $("#ownCsv").onchange = e => { const f = e.target.files[0]; if (f) importDialog(f); e.target.value = ""; };\n}\nasync function openDay(k) {\n  CAL.sel = k;\n  try { CAL.dayTrades = (await api("/api/day/" + k)).trades; CAL.dayErr = null; } catch (e) { CAL.dayErr = e.message; CAL.dayTrades = []; }\n  CAL.detail = true;\n  calendar();\n  $("#dayBox").scrollIntoView({behavior: "smooth", block: "nearest"});\n}\nfunction dayDetail() {\n  const k = CAL.sel;\n  if (CAL.dayErr) return `<p class="err-msg">${esc(CAL.dayErr)}</p>`;\n  const list = (CAL.dayTrades || []).filter(t => CAL.filter === "alle" || t.source === CAL.filter);\n  const sum = pick((S.daily || {})[k]) || {pnl: 0, n: 0, w: 0, bot: 0, own: 0};\n  const title = new Date(k + "T12:00:00").toLocaleDateString("de-DE", {weekday: "long", day: "numeric", month: "long", year: "numeric"});\n  return `<div class="section-h"><h2>${title}</h2><p class="hint"><span class="${cls(sum.pnl)}" style="font-weight:600">${sUsd(sum.pnl)}</span>${sum.n ? ` · ${countText(sum)} · ${sum.w} Gewinner` : ""}</p></div>\n    ${list.length ? `<div class="panel scroll"><table><thead><tr><th class="t">Zeit</th><th class="t">Quelle</th><th class="t">Trade</th><th class="t">Strategie / Notiz</th><th>Ein</th><th>Aus</th><th>Netto</th><th></th></tr></thead><tbody>\n    ${list.map(t => `<tr><td class="t mono">${t.source === "eigen" && t.opened === t.closed ? "–" : `${tm(t.opened)}–${tm(t.closed)}`}</td>\n      <td class="t"><span class="chip ${t.source === "eigen" ? "warn" : ""}">${t.source === "eigen" ? "Eigen" : "Bot"}</span></td>\n      <td class="t"><b class="side ${t.side}" style="font-size:12px">${t.side === "long" ? "L" : "S"}</b> ${t.qty}× ${esc(t.root)}</td>\n      <td class="wrap" style="min-width:140px">${esc(t.source === "eigen" ? (t.note || "–") : `${t.setup} · ${t.close_reason}`)}</td>\n      <td>${px(t.entry)}</td><td>${px(t.exit)}</td><td class="${cls(t.pnl)}">${usd(t.pnl)}</td>\n      <td>${t.source === "eigen" ? `<button class="btn ghost-danger owndel" data-id="${t.id}" data-key="del-${t.id}" data-orig="Löschen" style="padding:3px 8px;font-size:12px">${armed("del-" + t.id) ? "Sicher?" : "Löschen"}</button>` : ""}</td></tr>`).join("")}\n    </tbody></table></div>` : `<div class="empty">Keine ${CAL.filter === "bot" ? "Bot-" : CAL.filter === "eigen" ? "eigenen " : ""}Trades an diesem Tag.</div>`}`;\n}\nfunction modal(html) {\n  document.body.insertAdjacentHTML("beforeend", `<div class="modal-bg" id="mdl" role="dialog" aria-modal="true"><div class="panel modal">${html}</div></div>`);\n  const close = () => $("#mdl") && $("#mdl").remove();\n  $("#mdl").addEventListener("click", e => { if (e.target.id === "mdl") close(); });\n  document.addEventListener("keydown", function esc(e) { if (e.key === "Escape") { close(); document.removeEventListener("keydown", esc); } });\n  return close;\n}\nfunction ownTradeDialog(day) {\n  const close = modal(`<h2 style="font-size:18px">Eigenen Trade eintragen</h2>\n    <form id="ownF" class="form" style="gap:10px">\n      <div class="edit" style="grid-template-columns:repeat(2,minmax(0,1fr))">\n        <label>Handelstag<input id="oDay" type="date" value="${day}" required></label>\n        <label>Instrument<select id="oRoot">${["NQ", "MNQ", "ES", "MES"].map(r => `<option>${r}</option>`).join("")}</select></label>\n        <label>Richtung<select id="oSide"><option value="long">Long</option><option value="short">Short</option></select></label>\n        <label>Anzahl<input id="oQty" type="number" min="1" step="1" value="1"></label>\n        <label>Einstieg<input id="oIn" type="number" step="0.25" placeholder="z. B. 21010.25"></label>\n        <label>Ausstieg<input id="oOut" type="number" step="0.25" placeholder="z. B. 21030.50"></label>\n        <label>Gebühren ($)<input id="oFee" type="number" step="0.01" min="0" value="0"></label>\n        <label>oder P&L direkt ($)<input id="oPnl" type="number" step="0.01" placeholder="optional"></label>\n      </div>\n      <div class="edit" style="grid-template-columns:1fr"><label>Notiz<input id="oNote" type="text" maxlength="120" placeholder="z. B. Topstep-Konto, NY-Open"></label></div>\n      <p class="hint" style="margin:0">Ergebnis: <b id="oRes">–</b></p>\n      <p class="err-msg" id="oErr" hidden></p>\n      <div class="actions"><button class="btn primary" type="submit">Speichern</button><button class="btn" type="button" id="oCancel">Abbrechen</button></div>\n    </form>`);\n  const pv = {NQ: 20, MNQ: 2, ES: 50, MES: 5};\n  const calc = () => {\n    const direct = parseFloat($("#oPnl").value);\n    let r = NaN;\n    if (isFinite(direct)) r = direct;\n    else { const a = parseFloat($("#oIn").value), b = parseFloat($("#oOut").value), q = parseInt($("#oQty").value) || 0, f = parseFloat($("#oFee").value) || 0;\n      if (isFinite(a) && isFinite(b)) r = (b - a) * ($("#oSide").value === "long" ? 1 : -1) * q * pv[$("#oRoot").value] - f; }\n    $("#oRes").textContent = isFinite(r) ? sUsd(Math.round(r * 100) / 100) : "–"; $("#oRes").className = cls(r);\n  };\n  $("#ownF").addEventListener("input", calc);\n  $("#oCancel").onclick = close;\n  $("#ownF").onsubmit = async e => {\n    e.preventDefault();\n    const dayVal = $("#oDay").value;\n    try {\n      await api("/api/own/add", {day: dayVal, root: $("#oRoot").value, side: $("#oSide").value, qty: $("#oQty").value,\n        entry: $("#oIn").value, exit: $("#oOut").value, fees: $("#oFee").value, pnl: $("#oPnl").value, note: $("#oNote").value});\n      close(); toast("Eigener Trade gespeichert");\n      S = await api("/api/state");\n      CAL.y = +dayVal.slice(0, 4); CAL.m = +dayVal.slice(5, 7) - 1; openDay(dayVal);\n    } catch (err) { $("#oErr").textContent = err.message; $("#oErr").hidden = false; }\n  };\n  $("#oIn").focus();\n}\nasync function importDialog(file) {\n  const text = await file.text();\n  const close = modal(`<h2 style="font-size:18px">Eigene Trades importieren</h2>\n    <p style="margin:0"><b>${esc(file.name)}</b> · ${text.split(/\\r?\\n/).filter(x => x.trim()).length - 1} Zeilen</p>\n    <p class="hint" style="margin:0">Funktioniert mit CSV-Exporten aus Topstep, Tradovate, NinjaTrader und den meisten Plattformen. Spalten wie Datum, Symbol, Richtung und P&L werden automatisch erkannt. Schon importierte Trades werden übersprungen.</p>\n    <label style="display:flex;gap:8px;align-items:center;font-size:13px"><input type="checkbox" id="iFee" checked> Gebühren-Spalte vom P&L abziehen (falls vorhanden)</label>\n    <p class="err-msg" id="iErr" hidden></p>\n    <div class="actions"><button class="btn primary" id="iGo">Importieren</button><button class="btn" id="iCancel">Abbrechen</button></div>`);\n  $("#iCancel").onclick = close;\n  $("#iGo").onclick = async () => {\n    try {\n      const r = await api("/api/own/import", {csv: text, subtract_fees: $("#iFee").checked});\n      close(); toast(`${r.added} Trades importiert${r.skipped ? `, ${r.skipped} schon vorhanden` : ""}${r.bad ? `, ${r.bad} nicht lesbar` : ""}`);\n      CAL.filter = CAL.filter === "bot" ? "alle" : CAL.filter; await refresh(true);\n    } catch (e) { $("#iErr").textContent = e.message; $("#iErr").hidden = false; }\n  };\n}\n\n/* ───────── Lernmodul ───────── */\nfunction learn() {\n  const L = S.learning, p = L.params;\n  const stChip = s => ({"aktiv": "good", "halbe Größe": "warn", "pausiert": "bad", "aus": "bad", "lernt": "mute"}[s] || "mute");\n  $("#main").innerHTML = `\n    <section class="panel"><div class="section-h"><div><h2>So lernt der Bot</h2>\n      <p class="hint" style="max-width:75ch;margin-top:4px">Jedes Signal wird im Hintergrund als Schatten-Trade simuliert, auch abgelehnte und blockierte. Nach jeder Session wertet der Bot die letzten ${p.window} Schatten-Trades je Strategie aus.\n      Unter ${num2(p.half_below_r)} R im Schnitt gibt es halbe Größe, unter ${num2(p.pause_below_r)} R eine Pause. Erst ab ${p.min_trades} Trades greift die Bewertung.\n      Pausierte Strategien laufen im Schatten weiter und werden automatisch wieder freigegeben, wenn sie sich erholen. Das Risiko wird nie automatisch über deine Einstellung erhöht.</p></div>\n      <div style="display:flex;gap:10px;align-items:center"><span class="hint">Letzte Auswertung: ${L.last_run ? dtm(L.last_run) : "noch keine"}</span><button class="btn primary" id="runL">Jetzt auswerten</button></div></div></section>\n    <section class="section"><h2>Strategien</h2><div class="panel scroll">${L.setups.length ? `<table><thead><tr><th class="t">Strategie</th><th class="t">Status</th><th>Ausgewertet</th><th>Gesamt</th><th>Treffer</th><th>Ø R</th><th>Σ R</th><th>Laufend</th><th class="t">Steuerung</th></tr></thead><tbody>\n      ${L.setups.map(s => `<tr><td class="t"><span class="chip">${esc(s.setup)}</span></td>\n        <td class="t"><span class="chip ${stChip(s.effective)}">${esc(s.effective)}</span>${s.manual !== "auto" ? \' <span class="hint">(manuell)</span>\' : ""}</td>\n        <td>${s.n}</td><td>${s.total}</td><td>${pct(s.winrate)}</td><td class="${cls(s.avg_r)}">${num2(s.avg_r)}</td><td class="${cls(s.sum_r)}">${num2(s.sum_r)}</td><td>${s.open}</td>\n        <td class="t"><select data-setup="${esc(s.setup)}" class="rule" aria-label="Steuerung ${esc(s.setup)}">${[["auto", "Lernmodul entscheidet"], ["an", "Immer an"], ["aus", "Aus"]].map(([v, l]) => `<option value="${v}" ${s.manual === v ? "selected" : ""}>${l}</option>`).join("")}</select></td></tr>`).join("")}\n      </tbody></table>` : \'<p class="hint">Noch keine Daten. Sobald Signale aus TradingView eintreffen, erscheinen hier alle Strategien.</p>\'}</div></section>\n    <section class="section"><h2>Erkenntnisse</h2><div class="panel">${L.insights.length ? `<div class="flags" style="flex-direction:column;align-items:flex-start;gap:8px">${L.insights.map(i => `<span class="chip ${i.kind === "bad" ? "bad" : i.kind === "good" ? "good" : "warn"}">${esc(i.text)}</span>`).join("")}</div>` : \'<p class="hint">Noch keine Auffälligkeiten. Erkenntnisse zu Uhrzeiten erscheinen ab 6 Trades pro Stunde.</p>\'}</div></section>`;\n  $("#runL").onclick = () => act(() => api("/api/learn", {}), "Auswertung fertig");\n  document.querySelectorAll(".rule").forEach(sel => sel.onchange = () =>\n    act(() => api("/api/config", {setup_rules: {[sel.dataset.setup]: sel.value}}), "Gespeichert"));\n}\n\n/* ───────── Einstellungen ───────── */\nfunction field(id, label, value, opts = {}) {\n  const attrs = Object.entries(opts.attrs || {}).map(([k, v]) => `${k}="${v}"`).join(" ");\n  const inp = opts.select ? `<select id="${id}" data-cfg>${opts.select.map(([v, l]) => `<option value="${v}" ${String(v) === String(value) ? "selected" : ""}>${l}</option>`).join("")}</select>`\n    : opts.check ? `<input id="${id}" data-cfg type="checkbox" ${value ? "checked" : ""} class="chk">`\n    : `<input id="${id}" data-cfg type="${opts.type || "number"}" value="${esc(value ?? "")}" ${attrs} ${opts.type === "password" ? \'autocomplete="new-password"\' : ""}>`;\n  return `<div class="row ${opts.cls || ""}" ${opts.hidden ? "hidden" : ""} data-row="${id}"><label for="${id}">${label}${opts.help ? `<small>${opts.help}</small>` : ""}</label>${inp}</div>`;\n}\nconst v = id => { const el = $("#" + id); return !el ? undefined : el.type === "checkbox" ? el.checked : el.value; };\nconst num = id => { const x = parseFloat(v(id)); return isFinite(x) ? x : undefined; };\nconst sec = (title, hint, body, id = "") => `<section class="set-sec" ${id ? `id="${id}"` : ""}><div class="set-h"><h2>${title}</h2>${hint ? `<p class="hint">${hint}</p>` : ""}</div><div class="set-b">${body}</div></section>`;\n\nlet settingsKey = "";\n// New Yorker Uhrzeit in die Ortszeit des Nutzers umrechnen (aus aktueller NY-Zeit vom Server)\nfunction localTime(hm) {\n  const [nh, nm] = (S.now_ny || "00:00").split(":").map(Number), now = new Date();\n  const off = ((now.getHours() * 60 + now.getMinutes()) - (nh * 60 + nm) + 1440 * 2) % 1440;\n  const rounded = Math.round(off / 30) * 30, [h, m] = hm.split(":").map(Number), t = (h * 60 + m + rounded) % 1440;\n  return `${String(Math.floor(t / 60)).padStart(2, "0")}:${String(t % 60).padStart(2, "0")}`;\n}\nfunction settings() {\n  settingsKey = JSON.stringify([S.tunnel, S.hook_url, S.broker, S.update, S.own_sync && S.own_sync.last, S.own_sync && S.own_sync.error, S.autostart]);\n  const c = S.config, sz = c.sizing, ss = c.safe_stop, r = c.risk, t = c.tradovate, L = c.learning;\n  const phoneUrl = (c.public_url || S.tunnel.url || "").replace(/\\/+$/, "");\n  const prev = fam => S.sizing_preview[fam].map((p, i) => {\n    const pts = (fam === "NQ" ? [10, 20, 40, 60] : [3, 5, 10, 15])[i];\n    return `<span class="pv">${pts} Pkt. → ${typeof p === "string" ? "zu weit" : `<b>${p[1]}× ${p[0]}</b> <span class="neg">${usd(p[2])}</span>`}</span>`;\n  }).join("");\n  const updState = S.update.available ? `<span class="chip warn">Version ${esc(S.update.version)} verfügbar</span>`\n    : S.update.error && S.update.checked ? `<span class="chip bad">Prüfung fehlgeschlagen</span>`\n    : `<span class="chip good">aktuell</span>`;\n\n  $("#main").innerHTML = `<div class="settings-wrap">\n  ${sec("App & Updates", "", `\n    <div class="row"><label>Installierte Version<small>${S.update.checked ? "Zuletzt geprüft: " + dtm(S.update.checked) : "Die App prüft bei jedem Start und alle 6 Stunden."}</small></label>\n      <div class="inline"><b class="mono">${esc(S.version)}</b> ${updState}</div></div>\n    <div class="row"><label>Programmdatei<small>Diese Datei läuft gerade, auf sie zeigt auch das Desktop-Symbol. Andere Kopien (z. B. „FVG-Trader (1).cmd“ in Downloads) kannst du löschen.</small></label>\n      <div class="inline"><span class="mono" style="font-size:11.5px;word-break:break-all;text-align:right">${esc(S.launcher || "–")}</span></div></div>\n    <div class="row"><label>Nach Updates suchen und installieren<small>${S.update.available && S.update.notes ? esc(S.update.notes) : "Deine Einstellungen und Trades bleiben erhalten."}</small></label>\n      <button class="btn primary" id="updNowSet">Jetzt aktualisieren</button></div>\n    ${S.platform.startsWith("win") ? `<div class="row"><label>Mit Windows starten<small>Der Bot läuft nach dem Hochfahren still im Hintergrund.</small></label>\n      <button class="tgl" id="asT" role="switch" aria-checked="${S.autostart}" aria-label="Mit Windows starten"></button></div>` : ""}\n    <div class="row"><label>FVG Trader beenden<small>Ohne Beenden läuft der Bot im Hintergrund weiter, auch wenn das Fenster zu ist.</small></label>\n      <button class="btn ghost-danger" id="quit">App beenden</button></div>`)}\n\n  ${sec("Positionsgröße", "Wie viele Kontrakte der Bot pro Trade handelt.", `\n    <div class="row"><label>Methode</label><div class="seg" role="group" aria-label="Methode">${[["fixed", "Feste Anzahl"], ["risk_usd", "Risiko $"], ["risk_pct", "Risiko %"]].map(([k, l]) =>\n      `<button type="button" data-mode="${k}" aria-pressed="${sz.mode === k}">${l}</button>`).join("")}</div></div>\n    ${field("fq", "Kontrakte pro Trade", sz.fixed_qty, {attrs: {min: 1, step: 1}, hidden: sz.mode !== "fixed"})}\n    ${field("ru", "Risiko pro Trade ($)", sz.risk_usd, {attrs: {min: 10, step: 10}, hidden: sz.mode !== "risk_usd", help: "Größe wird aus dem Stop-Abstand berechnet"})}\n    ${field("rp", "Risiko pro Trade (% vom Konto)", sz.risk_pct, {attrs: {min: 0.05, max: 5, step: 0.05}, hidden: sz.mode !== "risk_pct"})}\n    ${field("ct", "Kontrakttyp", sz.contract_type, {select: [["auto", "Automatisch (Mini oder Micro)"], ["mini", "Nur Mini (NQ / ES)"], ["micro", "Nur Micro (MNQ / MES)"]]})}\n    ${field("mq", "Höchstens Kontrakte", sz.max_qty, {attrs: {min: 1, step: 1}})}\n    <div class="preview"><span class="hint">Beispiel mit gespeicherter Einstellung</span><div><b>NQ</b> ${prev("NQ")}</div><div><b>ES</b> ${prev("ES")}</div></div>`)}\n\n  ${sec("Risiko & Schutz", "Jede Order bekommt einen Stop-Loss. Fehlt er im Signal, nimmt der Bot den Standard-Stop.", `\n    ${field("nqd", "Standard-Stop NQ (Punkte)", ss.NQ.default, {attrs: {step: 0.25, min: 1}})}\n    ${field("esd", "Standard-Stop ES (Punkte)", ss.ES.default, {attrs: {step: 0.25, min: 0.25}})}\n    ${field("rr", "Standard-Ziel (R)", ss.default_rr, {attrs: {step: 0.25, min: 0.5}, help: "Wenn das Signal kein Ziel mitschickt"})}\n    ${field("mdl", "Tagesverlust-Limit ($)", r.max_daily_loss, {attrs: {min: 0, step: 50}, help: "Danach handelt der Bot heute nicht mehr. 0 = aus"})}\n    ${field("mtd", "Max. Trades pro Tag", r.max_trades_day, {attrs: {min: 1, step: 1}})}`)}\n\n  ${sec("Sessions & Vorschläge", "Hak an, in welchen Sessions der Bot handeln darf. Die gleichen Haken gibt es in den Einstellungen der TradingView-Strategie.", `\n    <div class="sess-list">${Object.entries(S.sessions).map(([k, x]) => `<label class="sess ${(r.sessions || {})[k] ? "on" : ""}">\n      <input type="checkbox" class="chk" data-cfg data-sess="${k}" ${(r.sessions || {})[k] ? "checked" : ""}>\n      <span class="sess-n">${esc(x.name)}</span><span class="sess-t mono">${x.start}–${x.end === "00:00" ? "24:00" : x.end} NY</span><span class="sess-t mono hint">${localTime(x.start)}–${localTime(x.end)} bei dir</span></label>`).join("")}</div>\n    ${field("es", "Nur in der Handelszeit handeln", r.enforce_session, {check: true})}\n    ${field("fe", "Zum Ende der Session schließen", r.flat_at_session_end, {check: true, help: "Offene Positionen werden geschlossen, wenn ihre Session endet"})}\n    ${field("to", "Vorschlag verfällt nach (Sekunden)", c.suggestion_timeout_sec, {attrs: {min: 15, step: 15}, help: "Gilt, wenn der Auto-Modus aus ist"})}\n    ${field("le", "Lernmodul aktiv", L.enabled, {check: true, help: "Schwache Strategien bekommen halbe Größe oder Pause"})}`)}\n\n  ${sec("TradingView", "Verbindung zwischen deiner Strategie und dem Bot.", `\n    <div class="row"><label>Internet-Verbindung<small>${c.public_url ? "Eigene Adresse aus „Erweitert“." : S.tunnel.fixed ? "Feste Adresse: bleibt nach Neustarts gleich, der Alert muss nie wieder angepasst werden." : "Die Adresse wechselt bei jedem Neustart. Mit einem ngrok-Schlüssel wird sie fest."}</small></label>\n      <div class="inline">${S.tunnel.ok || c.public_url ? \'<span class="chip good">aktiv</span>\' : `<span class="chip bad" style="white-space:normal;text-align:left;max-width:100%">${esc(S.tunnel.status)}</span>`}\n        <span class="chip ${S.tunnel.fixed || c.public_url ? "good" : "warn"}">${S.tunnel.fixed || c.public_url ? "feste Adresse" : "wechselnde Adresse"}</span></div></div>\n    ${field("ngt", "ngrok-Schlüssel für feste Adresse", (c.tunnel || {}).ngrok_token, {type: "password", help: "Kostenlos: ngrok.com → registrieren → im Dashboard „Your Authtoken“ kopieren und hier einfügen"})}\n    <div><span class="lbl">Webhook-Adresse für den Alert</span><div class="copyrow"><div class="code" id="hook">${esc(S.hook_url || "wird automatisch erzeugt …")}</div><button class="btn" id="cp" ${S.hook_url ? "" : "disabled"}>Kopieren</button></div></div>\n    <div><span class="lbl">Alert-Nachricht</span><div class="copyrow"><div class="code" id="msgTpl">{{strategy.order.alert_message}}</div><button class="btn" id="cp2">Kopieren</button></div></div>\n    <div class="inline wrap-gap"><button class="btn" id="cpPine2">Strategie-Script kopieren</button><button class="btn" id="tL">Test-Signal senden</button></div>`)}\n\n  ${sec("Konten verknüpfen", "Einmal verbinden: Deine eigenen Trades kommen dann automatisch in den Kalender.", `\n    <div class="row"><label>TradingView<small>TradingView hat keine Schnittstelle für deine Trades. Handelst du in TradingView über Tradovate, kommen die Trades über die Tradovate-Verknüpfung unten.</small></label>\n      <div class="inline"><span class="chip mute">über Tradovate</span></div></div>\n    <span class="lbl">Tradovate ${t.username && t.cid ? (S.own_sync.error ? \'<span class="chip bad">Fehler</span>\' : \'<span class="chip good">hinterlegt</span>\') : \'<span class="chip mute">nicht verbunden</span>\'}</span>\n    ${field("tenv", "Konto", t.env, {select: [["demo", "Demo"], ["live", "Live (echtes Konto)"]]})}\n    ${field("tu", "Benutzername", t.username, {type: "text", attrs: {autocomplete: "off"}})}\n    ${field("tpw", "Passwort", t.password, {type: "password"})}\n    ${field("tcid", "API cid", t.cid, {type: "text", help: "Tradovate → Einstellungen → API-Zugang (API-Add-on nötig)"})}\n    ${field("tsec", "API secret", t.secret, {type: "password"})}\n    ${field("osync", "Eigene Trades automatisch übernehmen", c.own_sync && c.own_sync.tradovate, {check: true, help: "Alle 10 Minuten. Trades des Bots werden erkannt und nicht doppelt gezählt."})}\n    ${S.own_sync.enabled ? `<div class="row"><label>Letzter Abruf<small>${S.own_sync.error ? `<span class="neg">${esc(S.own_sync.error)}</span>` : S.own_sync.last ? `${S.own_sync.added} neue Trades` : "läuft gleich"}</small></label>\n      <div class="inline"><span class="mono">${S.own_sync.last ? dtm(S.own_sync.last) : "–"}</span></div></div>` : ""}\n    <div class="inline wrap-gap"><button class="btn" id="tvTest">Verbindung testen</button>${S.own_sync.enabled ? \'<button class="btn" id="syncNow">Eigene Trades jetzt abrufen</button>\' : ""}</div>\n    <span class="lbl">Bot-Orders</span>\n    ${field("bk", "Der Bot handelt über", c.broker, {select: [["paper", "Paper-Trading (Simulation)"], ["tradovate", "Tradovate-Konto oben"]], help: c.broker === "tradovate" ? `Status: ${esc(S.broker.status || "–")}` : "Empfohlen, bis der Bot sich bewährt hat"})}\n    <div id="ppd" class="sub" ${c.broker === "paper" ? "" : "hidden"}>\n      ${field("pb", "Startkapital Paper ($)", c.paper.start_balance, {attrs: {min: 1000, step: 1000}})}\n      <div class="inline wrap-gap"><button class="btn ghost-danger" id="pr">Paper-Konto zurücksetzen</button></div>\n    </div>`)}\n\n  ${sec("Aufs Handy", "Adresse am Handy öffnen, anmelden und „Zum Startbildschirm“ wählen.", `\n    <div class="copyrow"><div class="code">${esc(phoneUrl || "kommt, sobald die Internet-Verbindung steht")}</div><button class="btn" id="cpPhone" ${phoneUrl ? "" : "disabled"}>Kopieren</button></div>\n    <p class="hint" style="margin:0">${S.tunnel.fixed || c.public_url ? "Feste Adresse: das Symbol am Handy funktioniert dauerhaft." : "Ändert sich bei jedem Neustart des PCs. Mit ngrok-Schlüssel (TradingView-Bereich) bleibt sie fest."}</p>`)}\n\n  ${sec("Protokoll", "Hilfreich, wenn etwas nicht klappt: Log anzeigen, kopieren und mir in den Chat schicken.", `\n    <div class="inline wrap-gap"><button class="btn" id="logShow">App-Log anzeigen</button><button class="btn" id="logFolder">Ordner öffnen</button></div>\n    <p class="hint" style="margin:0">Liegt im Ordner <b>FVG-Trader-Daten</b> neben deiner FVG-Trader.cmd, Datei <b>app.log</b>.</p>`)}\n\n  <details class="set-sec adv"><summary><span><b>Erweitert</b><span class="hint"> · nur bei Bedarf ändern</span></span></summary><div class="set-b">\n    <span class="lbl">Safe-Stop-Grenzen (Punkte)</span>\n    ${field("nqmin", "NQ Minimum", ss.NQ.min, {attrs: {step: 0.25, min: 0.25}})}\n    ${field("nqmax", "NQ Maximum", ss.NQ.max, {attrs: {step: 0.25, min: 1}})}\n    ${field("esmin", "ES Minimum", ss.ES.min, {attrs: {step: 0.25, min: 0.25}})}\n    ${field("esmax", "ES Maximum", ss.ES.max, {attrs: {step: 0.25, min: 0.5}})}\n    <span class="lbl">Bot-Verhalten</span>\n    ${field("mo", "Max. gleichzeitige Positionen", r.max_open, {attrs: {min: 1, step: 1}})}\n    ${field("fx", "Exit-Signalen aus TradingView folgen", c.follow_tv_exits, {check: true})}\n    <span class="lbl">Lernmodul</span>\n    ${field("lw", "Auswerten über letzte Trades", L.window, {attrs: {min: 5, max: 500, step: 1}})}\n    ${field("lm", "Mindest-Trades vor Bewertung", L.min_trades, {attrs: {min: 3, step: 1}})}\n    ${field("lh", "Halbe Größe unter Ø R", L.half_below_r, {attrs: {step: 0.05}})}\n    ${field("lp", "Pause unter Ø R", L.pause_below_r, {attrs: {step: 0.05}})}\n    <span class="lbl">Paper-Trading</span>\n    ${field("psl", "Slippage (Ticks)", c.paper.slippage_ticks, {attrs: {min: 0, step: 1}})}\n    ${field("pc", "Gebühr pro Kontrakt & Seite ($)", c.paper.commission, {attrs: {min: 0, step: 0.05}})}\n    <span class="lbl">Tradovate</span>\n    ${field("tacc", "Kontoname", t.account, {type: "text", help: "Leer = erstes Konto. Bei mehreren Konten (z. B. Topstep) den Namen eintragen."})}\n    ${field("cnq", "Kontrakt NQ / MNQ", c.contracts.NQ, {type: "text", attrs: {placeholder: "automatisch"}})}\n    ${field("ces", "Kontrakt ES / MES", c.contracts.ES, {type: "text", attrs: {placeholder: "automatisch"}})}\n    <span class="lbl">Verbindung & Updates</span>\n    ${field("pu", "Eigene feste Adresse", c.public_url, {type: "url", attrs: {placeholder: "leer = automatisch"}, help: "Nur mit ngrok o. Ä."})}\n    <div class="inline wrap-gap"><button class="btn ghost-danger" id="rt">Neue Webhook-Adresse erzeugen</button>\n      <label class="btn" style="cursor:pointer">Update aus Datei<input type="file" id="updFile" accept=".cmd" hidden></label></div>\n  </div></details>\n  </div>\n  <div class="savebar" id="savebar" hidden><span class="hint" id="saveMsg">Du hast Änderungen.</span><button class="btn" id="discard">Verwerfen</button><button class="btn primary" id="saveAll">Änderungen speichern</button></div>`;\n\n  // Änderungen sammeln, eine Speichern-Leiste\n  let mode = sz.mode;\n  const dirty = () => { settingsDirty = true; $("#savebar").hidden = false; };\n  $("#main").oninput = e => { if (e.target.matches("[data-cfg]")) dirty(); };\n  $("#main").onchange = e => { if (e.target.matches("[data-cfg]")) dirty(); };\n  document.querySelectorAll("[data-mode]").forEach(b => b.onclick = () => {\n    mode = b.dataset.mode; document.querySelectorAll("[data-mode]").forEach(x => x.setAttribute("aria-pressed", x === b));\n    $(\'[data-row="fq"]\').hidden = mode !== "fixed"; $(\'[data-row="ru"]\').hidden = mode !== "risk_usd"; $(\'[data-row="rp"]\').hidden = mode !== "risk_pct"; dirty(); });\n  $("#bk").addEventListener("change", () => { $("#ppd").hidden = v("bk") !== "paper"; });\n  $("#discard").onclick = () => { settingsDirty = false; render(true); };\n  const doSave = async () => {\n    const patch = {\n      sizing: {mode, fixed_qty: v("fq"), risk_usd: num("ru"), risk_pct: num("rp"), contract_type: v("ct"), max_qty: v("mq")},\n      safe_stop: {NQ: {default: num("nqd"), min: num("nqmin"), max: num("nqmax")}, ES: {default: num("esd"), min: num("esmin"), max: num("esmax")}, default_rr: num("rr")},\n      risk: {max_daily_loss: num("mdl"), max_trades_day: parseInt(v("mtd")), max_open: parseInt(v("mo")), enforce_session: v("es"), flat_at_session_end: v("fe"),\n        sessions: Object.fromEntries([...document.querySelectorAll("[data-sess]")].map(x => [x.dataset.sess, x.checked]))},\n      suggestion_timeout_sec: parseInt(v("to")), follow_tv_exits: v("fx"),\n      learning: {enabled: v("le"), window: v("lw"), min_trades: v("lm"), half_below_r: num("lh"), pause_below_r: num("lp")},\n      broker: v("bk"), public_url: v("pu").trim(),\n      tradovate: {env: v("tenv"), username: v("tu"), password: v("tpw"), cid: v("tcid"), secret: v("tsec"), account: v("tacc")},\n      contracts: {NQ: v("cnq"), MNQ: v("cnq") ? v("cnq").replace(/^NQ/i, "MNQ") : "", ES: v("ces"), MES: v("ces") ? v("ces").replace(/^ES/i, "MES") : ""},\n      paper: {start_balance: num("pb") ?? c.paper.start_balance, slippage_ticks: parseInt(v("psl")), commission: num("pc")},\n      own_sync: {tradovate: v("osync")},\n      tunnel: {ngrok_token: (v("ngt") || "").trim()},\n    };\n    await api("/api/config", patch); settingsDirty = false;\n  };\n  $("#saveAll").onclick = async () => {\n    try { await doSave(); toast("Gespeichert"); await refresh(true); }\n    catch (e) { $("#saveMsg").textContent = e.message; $("#saveMsg").className = "err-msg"; }\n  };\n  $("#tvTest").onclick = async () => {\n    try { if (settingsDirty) await doSave(); const r = await api("/api/tradovate/test", {}); toast(r.ok ? r.status : "Fehler: " + r.status); await refresh(true); }\n    catch (e) { toast(e.message); }\n  };\n  const sn = $("#syncNow"); if (sn) sn.onclick = async () => {\n    sn.disabled = true; sn.textContent = "Rufe ab …";\n    try { const r = await api("/api/own/sync", {}); toast(r.ok ? `${r.added} neue eigene Trades übernommen` : "Fehler: " + r.error); } catch (e) { toast(e.message); }\n    await refresh(true);\n  };\n\n  // Protokoll\n  $("#logShow").onclick = showLog;\n  $("#logFolder").onclick = async () => { try { const r = await api("/api/open-folder", {}); toast("Ordner geöffnet: " + r.folder); } catch (e) { toast(e.message); } };\n\n  // Sofort-Aktionen\n  $("#updNowSet").onclick = async () => {\n    const b = $("#updNowSet"); b.disabled = true; b.textContent = "Suche …";\n    try {\n      const u = await api("/api/update/check", {});\n      if (u.available) return runUpdate(() => api("/api/update/apply", {}));\n      toast(u.error && !u.version ? u.error : `Du hast die neueste Version (${S.version})`);\n    } catch (e) { toast(e.message); }\n    b.disabled = false; b.textContent = "Jetzt aktualisieren"; refresh(true);\n  };\n  const as = $("#asT"); if (as) as.onclick = () => act(() => api("/api/autostart", {on: !S.autostart}), !S.autostart ? "Startet ab jetzt mit Windows" : "Autostart aus").then(() => render(true));\n  $("#quit").onclick = () => confirmBtn($("#quit"), S.positions.length ? "Positionen offen. Trotzdem?" : "Wirklich beenden?", async () => {\n    try { await api("/api/shutdown", {}); } catch (e) {}\n    document.body.innerHTML = `<div class="login"><form><h1>FVG Trader ist beendet</h1><p class="hint">Signale aus TradingView werden jetzt nicht verarbeitet. Zum Starten auf das Desktop-Symbol <b>FVG Trader</b> klicken.</p><p class="hint">Du kannst dieses Fenster jetzt schließen.</p></form></div>`;\n    setTimeout(() => { try { window.close(); } catch (e) {} }, 600);\n  });\n  $("#cp").onclick = () => copyText(S.hook_url, "Adresse"); $("#cp2").onclick = () => copyText("{{strategy.order.alert_message}}", "Nachricht");\n  $("#cpPine2").onclick = async () => { try { const r = await api("/api/pine"); copyText(r.source, "Script"); } catch (e) { toast(e.message); } };\n  $("#tL").onclick = () => act(() => api("/api/test-signal", {fam: "NQ", side: "long"}).then(r => { TAB = "cockpit"; setHash("cockpit"); return r; }), "Test-Signal gesendet");\n  const pr = $("#pr"); if (pr) pr.onclick = () => confirmBtn(pr, "Alle Paper-Trades löschen?", () => act(() => api("/api/paper/reset", {}), "Paper-Konto zurückgesetzt").then(() => render(true)));\n  const cpPhone = $("#cpPhone"); if (cpPhone) cpPhone.onclick = () => copyText(phoneUrl, "Adresse");\n  $("#rt").onclick = () => confirmBtn($("#rt"), "Alte Adresse wird ungültig. Sicher?", () => act(() => api("/api/token", {}), "Neue Adresse erzeugt: im TradingView-Alert ersetzen").then(() => render(true)));\n  $("#updFile").onchange = e => { const f = e.target.files[0]; if (!f) return;\n    runUpdate(async () => { const r = await fetch("/api/update/upload", {method: "POST", headers: {"X-Requested-With": "fvg"}, body: f});\n      const j = await r.json().catch(() => ({})); if (!r.ok) throw new Error(j.error || "Update fehlgeschlagen"); return j; }); };\n}\n\nasync function showLog() {\n  let r;\n  try { r = await api("/api/log"); } catch (e) { toast(e.message); return; }\n  let view = "log";\n  const text = () => view === "log" ? (r.log.length ? r.log.join("\\n") : "(noch keine Einträge)") : (r.events.join("\\n") || "(keine Aktivität)");\n  const close = modal(`<div class="section-h"><h2 style="font-size:18px">Protokoll · Version ${esc(r.version)}</h2>\n      <div class="seg" role="group" aria-label="Ansicht"><button type="button" data-v="log" aria-pressed="true">App-Log</button><button type="button" data-v="ev" aria-pressed="false">Aktivität</button></div></div>\n    <pre class="code logbox" id="logTxt"></pre>\n    <p class="hint" style="margin:0;word-break:break-all">Datei: ${esc(r.path)}</p>\n    <div class="actions"><button class="btn primary" id="logCopy">Alles kopieren</button><button class="btn" id="logClose">Schließen</button></div>`);\n  const fill = () => { $("#logTxt").textContent = text(); $("#logTxt").scrollTop = $("#logTxt").scrollHeight; };\n  document.querySelectorAll("#mdl [data-v]").forEach(b => b.onclick = () => { view = b.dataset.v === "log" ? "log" : "ev";\n    document.querySelectorAll("#mdl [data-v]").forEach(x => x.setAttribute("aria-pressed", x === b)); fill(); });\n  fill();\n  $("#logCopy").onclick = () => copyText(`FVG Trader ${r.version}\\n--- App-Log ---\\n${r.log.slice(-120).join("\\n")}\\n--- Aktivität ---\\n${r.events.slice(-60).join("\\n")}`, "Protokoll");\n  $("#logClose").onclick = close;\n}\n\n/* ───────── Nur ein Fenster ───────── */\n// Wird FVG Trader ein zweites Mal geöffnet, übernimmt das neue Fenster; das alte schließt sich oder wird gesperrt.\nconst WIN_ID = Math.random().toString(36).slice(2);\nlet BLOCKED = false;\nconst BC = "BroadcastChannel" in window ? new BroadcastChannel("fvg-trader-fenster") : null;\nfunction claimWindow() { BLOCKED = false; const o = $("#winBlock"); if (o) o.remove(); if (BC) BC.postMessage({t: "claim", id: WIN_ID}); }\nfunction blockWindow() {\n  if (BLOCKED) return;\n  BLOCKED = true;\n  try { window.close(); } catch (e) {}\n  document.body.insertAdjacentHTML("beforeend", `<div id="winBlock" style="position:fixed;inset:0;z-index:60;background:var(--bg);display:grid;place-items:center;padding:16px">\n    <div class="panel" style="max-width:380px;display:flex;flex-direction:column;gap:12px;text-align:center">\n      <h2 style="font-size:19px">In einem anderen Fenster geöffnet</h2>\n      <p class="hint" style="margin:0">FVG Trader läuft schon in einem anderen Fenster. Du kannst dieses hier schließen.</p>\n      <button class="btn primary" id="winHere">Hier weiterverwenden</button></div></div>`);\n  $("#winHere").onclick = () => { claimWindow(); refresh(true); };\n}\nif (BC) BC.onmessage = e => { if (e.data && e.data.t === "claim" && e.data.id !== WIN_ID) blockWindow(); };\n\n/* ───────── Laufzeit ───────── */\nfunction render(full) {\n  if (!S) return;\n  if (full && TAB !== "settings" && $("#main")) { $("#main").oninput = null; $("#main").onchange = null; }\n  header();\n  document.querySelectorAll(".tabs button").forEach(x => x.setAttribute("aria-selected", x.dataset.tab === TAB));\n  if (TAB === "cockpit") cockpit(full);\n  else if (full) ({calendar, stats, learn, settings}[TAB])();\n  else if (TAB === "settings" && !settingsDirty && !document.activeElement.matches("input,select")) {\n    // Status-Anzeigen live nachziehen (Verbindung, Broker, Updates, Abruf), ohne Eingaben zu stören\n    const key = JSON.stringify([S.tunnel, S.hook_url, S.broker, S.update, S.own_sync && S.own_sync.last, S.own_sync && S.own_sync.error, S.autostart]);\n    if (key !== settingsKey) { const open = $("details.adv") && $("details.adv").open, y = scrollY; settings(); if (open) $("details.adv").open = true; scrollTo(0, y); }\n  }\n  else if (TAB === "stats" || TAB === "learn" || TAB === "calendar") ({calendar, stats, learn}[TAB])();\n}\nasync function refresh(full) {\n  S = await api("/api/state");\n  notifyNew();\n  render(full);\n}\nfunction notifyNew() {\n  const ids = S.pending.map(p => p.id), fresh = ids.filter(id => !seenPending.has(id));\n  ids.forEach(id => seenPending.add(id));\n  if (firstLoad) { firstLoad = false; return; }\n  if (!fresh.length) return;\n  const p = S.pending.find(x => x.id === fresh[0]);\n  document.title = "● Neuer Vorschlag · FVG Trader";\n  setTimeout(() => document.title = "FVG Trader", 8000);\n  try { const a = new AudioContext(), o = a.createOscillator(), g = a.createGain(); o.frequency.value = 880; g.gain.value = .08; o.connect(g).connect(a.destination); o.start(); o.stop(a.currentTime + .18); } catch (e) {}\n  if ("Notification" in window && Notification.permission === "granted")\n    new Notification("Neuer Trade-Vorschlag", {body: `${p.side === "long" ? "LONG" : "SHORT"} ${p.qty}× ${p.root} · ${p.setup} · Stop ${px(p.sl)}`});\n}\nasync function start() {\n  TAB = ["cockpit", "calendar", "stats", "learn", "settings"].includes(location.hash.slice(1)) ? location.hash.slice(1) : "cockpit";\n  shell();\n  if ("Notification" in window && Notification.permission === "default") document.addEventListener("click", () => Notification.requestPermission(), {once: true});\n  try { await refresh(true); } catch (e) { return; }\n  startupUpdatePrompt();\n  claimWindow();\n  setInterval(async () => {\n    if (BLOCKED) return;\n    if (TAB === "settings" && settingsDirty) return;\n    try { await refresh(false); } catch (e) {}\n  }, 2000);\n  setInterval(() => !BLOCKED && S && TAB === "cockpit" && timers(), 1000);\n}\nfetch("/api/auth").then(r => r.json()).then(a => a.logged_in ? start() : showLogin());\nif ("serviceWorker" in navigator) navigator.serviceWorker.register("/sw.js").catch(() => {});\n</script>\n</body>\n</html>\n'

PINE_SOURCE = '// This Pine Script® code is subject to the terms of the Mozilla Public License 2.0\n// Multi-Strategie Futures-Bot für NQ & ES (auch MNQ / MES)\n// Strategien: FVG, inverse FVG, Silver Bullet (FVG 10–11 NY), Opening Range Breakout, Liquidity Sweep (Vortag), VWAP-Reclaim\n// Verbindung zur FVG-Trader-App: Alert mit „Orderausführungen und alert()-Aufrufe“, Webhook = App-URL\n// Chart: NQ1! oder ES1!, Timeframe 5m (empfohlen) oder 1m/3m\n// Auto-Trading: Alert auf diese Strategie, Nachricht = {{strategy.order.alert_message}}, Webhook-URL deines Brokers/Connectors\n//@version=6\nstrategy("FVG Bot · Multi-Strategie [NQ·ES]", shorttitle = "FVG Bot", overlay = true,\n     initial_capital = 50000, default_qty_type = strategy.fixed, default_qty_value = 1,\n     commission_type = strategy.commission.cash_per_contract, commission_value = 2.25,\n     slippage = 1, pyramiding = 0, max_boxes_count = 400, max_labels_count = 100,\n     calc_on_every_tick = false, process_orders_on_close = false)\n\n// ───────────────────────── Inputs ─────────────────────────\ngrpSetup = "① Setup"\nuseFVG      = input.bool(true,  "FVG-Retest handeln",                     group = grpSetup)\nuseIFVG     = input.bool(true,  "Inverse FVG (iFVG) handeln",             group = grpSetup)\nminGapAtr   = input.float(0.15, "Min. Gap-Größe (× ATR)", minval = 0, step = 0.05, group = grpSetup)\natrLen      = input.int(14,     "ATR-Länge", minval = 1,                  group = grpSetup)\nmaxAge      = input.int(60,     "Max. Alter einer Zone (Bars)", minval = 5, group = grpSetup)\nmaxZones    = input.int(20,     "Max. aktive Zonen", minval = 2, maxval = 100, group = grpSetup)\nneedConfirm = input.bool(true,  "Bestätigungskerze (Close über/unter Zonenmitte)", group = grpSetup)\n\ngrpStrat = "① b Weitere Strategien"\nuseSB       = input.bool(true,  "Silver Bullet (FVG im Fenster 10–11 NY)", group = grpStrat)\nsbWin       = input.session("1000-1100", "Silver-Bullet-Fenster",          group = grpStrat)\nuseORB      = input.bool(true,  "Opening Range Breakout",                  group = grpStrat)\norWin       = input.session("0930-0945", "Opening Range",                  group = grpStrat)\norbLastMin  = input.int(11 * 60, "ORB nur bis (Minute NY, 660 = 11:00)", minval = 0, maxval = 1439, group = grpStrat)\nuseSweep    = input.bool(true,  "Liquidity Sweep Vortageshoch/-tief",      group = grpStrat)\nuseVWAP     = input.bool(true,  "VWAP-Reclaim",                            group = grpStrat)\nvwapLook    = input.int(6,      "VWAP: Kerzen vorher auf der anderen Seite", minval = 2, group = grpStrat)\n\ngrpRisk = "② Risiko"\nrr          = input.float(2.0,  "Ziel (R-Vielfaches)", minval = 0.5, step = 0.25, group = grpRisk)\nslBufTicks  = input.int(4,      "Stop-Puffer (Ticks)", minval = 0,        group = grpRisk)\nminRiskTk   = input.int(8,      "Min. Stop-Abstand (Ticks)", minval = 1,  group = grpRisk)\nmaxRiskAtr  = input.float(3.0,  "Max. Stop-Abstand (× ATR)", minval = 0.5, step = 0.25, group = grpRisk)\nsizing      = input.string("Feste Kontrakte", "Positionsgröße", options = ["Feste Kontrakte", "Risiko in $"], group = grpRisk)\nfixedQty    = input.int(1,      "Kontrakte (fest)", minval = 1,           group = grpRisk)\nriskUsd     = input.float(500,  "Risiko pro Trade ($)", minval = 10,      group = grpRisk)\nmaxQty      = input.int(5,      "Max. Kontrakte", minval = 1,             group = grpRisk)\nuseBE       = input.bool(false, "Stop auf Break-even ab 1R",              group = grpRisk)\nmaxTradesDay= input.int(3,      "Max. Trades pro Tag", minval = 1,        group = grpRisk)\nmaxDayLoss  = input.float(1000, "Tagesverlust-Limit ($, 0 = aus)", minval = 0, group = grpRisk)\n\ngrpTime = "③ Sessions (New Yorker Zeit)"\nuseAsia     = input.bool(false, "Asien 20:00–24:00",                      group = grpTime)\nuseLondon   = input.bool(false, "London 02:00–05:00",                     group = grpTime)\nuseNyAm     = input.bool(true,  "New York Vormittag 09:30–11:30",         group = grpTime)\nuseNyLunch  = input.bool(false, "New York Mittag 11:30–13:30",            group = grpTime)\nuseNyPm     = input.bool(true,  "New York Nachmittag 13:30–15:50",        group = grpTime)\nflatEnd     = input.bool(true,  "Außerhalb der Sessions alles schließen", group = grpTime)\n\ngrpBias = "④ Trendfilter"\nuseBias     = input.bool(true,  "Nur mit HTF-Trend handeln",              group = grpBias)\nbiasTf      = input.timeframe("60", "Bias-Timeframe",                     group = grpBias)\nbiasLen     = input.int(50,     "Bias-EMA-Länge", minval = 2,             group = grpBias)\n\ngrpNews = "⑤ News-Filter"\nblockFomc   = input.string("Ab 13:45 NY", "FOMC-Tage",  options = ["Ganzer Tag", "Ab 13:45 NY", "Ignorieren"], group = grpNews)\nblockCpi    = input.string("Bis 10:00 NY", "CPI-Tage",  options = ["Ganzer Tag", "Bis 10:00 NY", "Ignorieren"], group = grpNews)\nblockNfp    = input.string("Bis 10:00 NY", "NFP-Tage",  options = ["Ganzer Tag", "Bis 10:00 NY", "Ignorieren"], group = grpNews)\nblock10     = input.bool(true,  "10:00-Daten sperren (09:50–10:10 NY)",   group = grpNews)\ncustomDates = input.string("",  "Eigene Sperrtage (JJJJMMTT, kommagetrennt)", group = grpNews)\n\ngrpVis = "⑥ Anzeige & Alerts"\nshowZones   = input.bool(true,  "Zonen zeichnen",                         group = grpVis)\nshowEma     = input.bool(true,  "Bias-EMA zeichnen",                      group = grpVis)\nshowDash    = input.bool(true,  "Dashboard anzeigen",                     group = grpVis)\ndashPosStr  = input.string("Oben rechts", "Dashboard-Position", options = ["Oben rechts", "Oben links", "Unten rechts", "Unten links"], group = grpVis)\nwhSymbol    = input.string("",  "Webhook-Symbol (leer = Chart-Symbol)",   group = grpVis)\nsendBars    = input.bool(true,  "Kerzen-Daten an die App senden (Paper-Trading & Lernmodul)", group = grpVis)\n\n// ───────────────────────── Farben ─────────────────────────\ncBull  = #26a69a\ncBear  = #ef5350\ncIBull = #2962ff\ncIBear = #ff9800\ncMuted = #9598a1\n\n// ───────────────────────── Zeit & Kalender ─────────────────────────\nTZ    = "America/New_York"\nnyMin = hour(time, TZ) * 60 + minute(time, TZ)\ndKey  = year(time, TZ) * 10000 + month(time, TZ) * 100 + dayofmonth(time, TZ)\nnewDay = ta.change(dKey) != 0\n\nvar array<int> FOMC = array.from(\n     20240131, 20240320, 20240501, 20240612, 20240731, 20240918, 20241107, 20241218,\n     20250129, 20250319, 20250507, 20250618, 20250730, 20250917, 20251029, 20251210,\n     20260128, 20260318, 20260429, 20260617, 20260729, 20260916, 20261028, 20261209,\n     20270127, 20270317, 20270428, 20270609, 20270728, 20270915, 20271027, 20271208)\n\nvar array<int> CPI = array.from(\n     20240111, 20240213, 20240312, 20240410, 20240515, 20240612, 20240711, 20240814, 20240911, 20241010, 20241113, 20241211,\n     20250115, 20250212, 20250312, 20250410, 20250513, 20250611, 20250715, 20250812, 20250911, 20251024, 20251218,\n     20260113, 20260213, 20260311, 20260410, 20260512, 20260610, 20260714, 20260812, 20260911, 20261014, 20261110, 20261210,\n     20270113, 20270211, 20270310, 20270413, 20270512, 20270610, 20270714, 20270811, 20270914, 20271014, 20271110, 20271210)\n\n// Arbeitsmarktbericht: Regel = 1. Freitag im Monat; Sondertermine (Shutdown 2025 etc.) hier\nvar array<int> NFP_EXTRA = array.from(20251120, 20251216, 20260109)\nvar array<int> NFP_SKIP  = array.from(20251003, 20251107)\n\nvar array<int> CUSTOM = array.new<int>()\nif barstate.isfirst and str.length(customDates) > 0\n    for p in str.split(customDates, ",")\n        float v = str.tonumber(str.replace_all(p, " ", ""))\n        if not na(v)\n            CUSTOM.push(int(v))\n\nisFomc   = FOMC.includes(dKey)\nisCpi    = CPI.includes(dKey)\nisNfp    = (dayofweek(time, TZ) == dayofweek.friday and dayofmonth(time, TZ) <= 7 and not NFP_SKIP.includes(dKey)) or NFP_EXTRA.includes(dKey)\nisCustom = CUSTOM.includes(dKey)\n\nvar string newsReason = "frei"\nnewsBlock = false\nnewsReason := "frei"\nif isCustom\n    newsBlock := true\n    newsReason := "Eigener Sperrtag"\nif isFomc and blockFomc != "Ignorieren" and (blockFomc == "Ganzer Tag" or nyMin >= 13 * 60 + 45)\n    newsBlock := true\n    newsReason := "FOMC"\nif isCpi and blockCpi != "Ignorieren" and (blockCpi == "Ganzer Tag" or nyMin < 10 * 60)\n    newsBlock := true\n    newsReason := "CPI"\nif isNfp and blockNfp != "Ignorieren" and (blockNfp == "Ganzer Tag" or nyMin < 10 * 60)\n    newsBlock := true\n    newsReason := "NFP"\nif block10 and nyMin >= 9 * 60 + 50 and nyMin < 10 * 60 + 10\n    newsBlock := true\n    newsReason := "10:00-Daten"\n\ninAsia   = useAsia    and not na(time(timeframe.period, "2000-2359", TZ))\ninLondon = useLondon  and not na(time(timeframe.period, "0200-0500", TZ))\ninNyAm   = useNyAm    and not na(time(timeframe.period, "0930-1130", TZ))\ninNyLun  = useNyLunch and not na(time(timeframe.period, "1130-1330", TZ))\ninNyPm   = useNyPm    and not na(time(timeframe.period, "1330-1550", TZ))\ninSess   = inAsia or inLondon or inNyAm or inNyLun or inNyPm\n\n// ───────────────────────── Indikatoren ─────────────────────────\natr    = ta.atr(atrLen)\nhtfEma = request.security(syminfo.tickerid, biasTf, ta.ema(close, biasLen)[1], lookahead = barmerge.lookahead_on)\nbiasL  = not useBias or close > htfEma\nbiasS  = not useBias or close < htfEma\nplot(showEma and useBias ? htfEma : na, "Bias-EMA", color = color.new(cMuted, 20), linewidth = 2)\n\n[pdh, pdl] = request.security(syminfo.tickerid, "D", [high[1], low[1]], lookahead = barmerge.lookahead_on)\nvw   = ta.vwap(hlc3)\ninSB = not na(time(timeframe.period, sbWin, TZ))\ninOR = not na(time(timeframe.period, orWin, TZ))\nvar float orH = na\nvar float orL = na\nif inOR and not inOR[1]\n    orH := high\n    orL := low\nelse if inOR\n    orH := math.max(orH, high)\n    orL := math.min(orL, low)\norReady = not inOR and not na(orH) and dayofmonth(time, TZ) == dayofmonth(time[1], TZ)\nplot(useVWAP ? vw : na, "VWAP", color = color.new(cIBull, 40))\nplot(useSweep ? pdh : na, "Vortageshoch", color = color.new(cBear, 50), style = plot.style_stepline)\nplot(useSweep ? pdl : na, "Vortagestief", color = color.new(cBull, 50), style = plot.style_stepline)\nplot(useORB and orReady ? orH : na, "OR-Hoch", color = color.new(cIBear, 30), style = plot.style_linebr)\nplot(useORB and orReady ? orL : na, "OR-Tief", color = color.new(cIBear, 30), style = plot.style_linebr)\n\n// ───────────────────────── Zonen ─────────────────────────\ntype Zone\n    float top\n    float bottom\n    int   dir\n    bool  inverse = false\n    int   born\n    bool  used = false\n    box   bx\n\nvar array<Zone> zones = array.new<Zone>()\n\nzoneColor(Zone z) =>\n    z.inverse ? (z.dir == 1 ? cIBull : cIBear) : (z.dir == 1 ? cBull : cBear)\n\ncloseBox(Zone z) =>\n    if not na(z.bx)\n        z.bx.set_right(bar_index)\n        z.bx.set_bgcolor(color.new(zoneColor(z), 94))\n        z.bx.set_border_color(color.new(zoneColor(z), 85))\n\naddZone(float t, float b, int d) =>\n    Zone z = Zone.new(top = t, bottom = b, dir = d, born = bar_index)\n    if showZones\n        c = zoneColor(z)\n        z.bx := box.new(bar_index - 2, t, bar_index + 1, b, border_color = color.new(c, 55), bgcolor = color.new(c, 82))\n    zones.push(z)\n    if zones.size() > maxZones\n        closeBox(zones.shift())\n\n// Neue Gaps erkennen (Kerzen [2] und [0] überlappen nicht)\nminGap = math.max(minGapAtr * atr, syminfo.mintick * 2)\nif bar_index > 2\n    if low > high[2] and low - high[2] >= minGap\n        addZone(low, high[2], 1)\n    if high < low[2] and low[2] - high >= minGap\n        addZone(low[2], high, -1)\n\n// Zonen pflegen: Invalidierung → Flip zu iFVG, Alter, Ausdehnung\nif zones.size() > 0\n    for i = zones.size() - 1 to 0\n        Zone z = zones.get(i)\n        bool remove = false\n        if z.born < bar_index\n            if bar_index - z.born > maxAge\n                remove := true\n            else if not z.inverse\n                if (z.dir == 1 and close < z.bottom) or (z.dir == -1 and close > z.top)\n                    if useIFVG\n                        closeBox(z)\n                        z.dir     := -z.dir\n                        z.inverse := true\n                        z.born    := bar_index\n                        z.used    := false\n                        if showZones\n                            c = zoneColor(z)\n                            z.bx := box.new(bar_index, z.top, bar_index + 1, z.bottom, border_color = color.new(c, 55), bgcolor = color.new(c, 82))\n                    else\n                        remove := true\n            else\n                if (z.dir == 1 and close < z.bottom) or (z.dir == -1 and close > z.top)\n                    remove := true\n        if remove\n            closeBox(z)\n            zones.remove(i)\n        else if not na(z.bx)\n            z.bx.set_right(bar_index + 1)\n\n// ───────────────────────── Tages-Risiko ─────────────────────────\nvar float dayStart    = 0.0\nvar int   tradesToday = 0\nvar bool  doneOrbL = false\nvar bool  doneOrbS = false\nvar bool  doneSwL  = false\nvar bool  doneSwS  = false\nif newDay\n    dayStart    := strategy.netprofit\n    tradesToday := 0\n    doneOrbL    := false\n    doneOrbS    := false\n    doneSwL     := false\n    doneSwS     := false\ndayPnl  = strategy.netprofit + strategy.openprofit - dayStart\nlossHit = maxDayLoss > 0 and dayPnl <= -maxDayLoss\n\n// ───────────────────────── Webhook-JSON ─────────────────────────\nsym = whSymbol == "" ? syminfo.ticker : whSymbol\njsonEntry(string action, int qty, float sl, float tp, string setup) =>\n    \'{"type":"entry","ticker":"\' + sym + \'","action":"\' + action + \'","setup":"\' + setup + \'","time":\' + str.tostring(time) +\n     \',"quantity":\' + str.tostring(qty) +\n     \',"price":\' + str.tostring(close, format.mintick) +\n     \',"stopLoss":{"type":"stop","stopPrice":\' + str.tostring(sl, format.mintick) + \'}\' +\n     \',"takeProfit":{"limitPrice":\' + str.tostring(tp, format.mintick) + \'}}\'\njsonExit(string setup) =>\n    \'{"type":"exit","ticker":"\' + sym + \'","action":"exit","setup":"\' + setup + \'","price":\' + str.tostring(close, format.mintick) + \'}\'\n\n// ───────────────────────── Einstieg ─────────────────────────\nvar float tSL   = na\nvar float tTP   = na\nvar float tRisk = na\nvar string tId  = ""\nvar bool  beDone = false\n\ncanTrade = inSess and not newsBlock and not lossHit and tradesToday < maxTradesDay and strategy.position_size == 0\n\n// ta-Funktionen global berechnen (nicht in if-Blöcken)\nbool  wasBelow = ta.highest(close - vw, vwapLook)[1] < 0\nbool  wasAbove = ta.lowest(close - vw, vwapLook)[1] > 0\nfloat swingLo  = ta.lowest(low, 5)\nfloat swingHi  = ta.highest(high, 5)\n\n// Kandidaten in fester Reihenfolge prüfen, der erste gültige wird gehandelt\nbool   sigOn   = false\nbool   sigLong = false\nfloat  sigSL   = na\nstring sigName = ""\nfloat  maxRisk = maxRiskAtr * atr\nfloat  minRisk = minRiskTk * syminfo.mintick\nfloat  buf     = slBufTicks * syminfo.mintick\n\nif canTrade and zones.size() > 0\n    for i = zones.size() - 1 to 0\n        Zone z = zones.get(i)\n        bool allowed = z.inverse ? useIFVG : (useFVG or (useSB and inSB))\n        if not sigOn and allowed and not z.used and z.born < bar_index\n            float mid = math.avg(z.top, z.bottom)\n            bool longSig  = z.dir == 1  and biasL and low  <= z.top    and close > z.bottom and (not needConfirm or (close > open and close >= mid))\n            bool shortSig = z.dir == -1 and biasS and high >= z.bottom and close < z.top    and (not needConfirm or (close < open and close <= mid))\n            if longSig or shortSig\n                float sl = longSig ? math.min(z.bottom, low) - buf : math.max(z.top, high) + buf\n                float risk = math.abs(close - sl)\n                if risk >= minRisk and risk <= maxRisk\n                    sigOn   := true\n                    sigLong := longSig\n                    sigSL   := sl\n                    sigName := z.inverse ? "iFVG" : (useSB and inSB) ? "Silver Bullet" : "FVG"\n                    z.used  := true\n\nif canTrade and not sigOn and useSweep and not na(pdh)\n    if not doneSwL and biasL and low < pdl and close > pdl and close > open\n        sigOn   := true\n        sigLong := true\n        sigSL   := low - buf\n        sigName := "Sweep"\n        doneSwL := true\n    else if not doneSwS and biasS and high > pdh and close < pdh and close < open\n        sigOn   := true\n        sigLong := false\n        sigSL   := high + buf\n        sigName := "Sweep"\n        doneSwS := true\n\nif canTrade and not sigOn and useORB and orReady and nyMin < orbLastMin\n    float orMid = math.avg(orH, orL)\n    if not doneOrbL and biasL and close > orH and close[1] <= orH\n        sigOn    := true\n        sigLong  := true\n        sigSL    := math.max(orMid, close - maxRisk) - buf\n        sigName  := "ORB"\n        doneOrbL := true\n    else if not doneOrbS and biasS and close < orL and close[1] >= orL\n        sigOn    := true\n        sigLong  := false\n        sigSL    := math.min(orMid, close + maxRisk) + buf\n        sigName  := "ORB"\n        doneOrbS := true\n\nif canTrade and not sigOn and useVWAP\n    if biasL and wasBelow and close > vw and close > open\n        sigOn   := true\n        sigLong := true\n        sigSL   := swingLo - buf\n        sigName := "VWAP"\n    else if biasS and wasAbove and close < vw and close < open\n        sigOn   := true\n        sigLong := false\n        sigSL   := swingHi + buf\n        sigName := "VWAP"\n\nif sigOn\n    float risk = math.abs(close - sigSL)\n    if risk >= minRisk and risk <= maxRisk\n        float tp  = sigLong ? close + rr * risk : close - rr * risk\n        int qty   = sizing == "Feste Kontrakte" ? fixedQty : math.max(1, math.min(maxQty, int(math.floor(riskUsd / (risk * syminfo.pointvalue)))))\n        string id = sigName + (sigLong ? " Long" : " Short")\n        strategy.entry(id, sigLong ? strategy.long : strategy.short, qty = qty, alert_message = jsonEntry(sigLong ? "buy" : "sell", qty, sigSL, tp, id))\n        strategy.exit("Exit " + id, from_entry = id, stop = sigSL, limit = tp, alert_message = jsonExit(id))\n        tSL         := sigSL\n        tTP         := tp\n        tRisk       := risk\n        tId         := id\n        beDone      := false\n        tradesToday += 1\n\n// Break-even\nif useBE and not beDone and strategy.position_size != 0\n    float ep = strategy.position_avg_price\n    if (strategy.position_size > 0 and high >= ep + tRisk) or (strategy.position_size < 0 and low <= ep - tRisk)\n        tSL    := ep\n        beDone := true\n        strategy.exit("Exit " + tId, from_entry = tId, stop = tSL, limit = tTP, alert_message = jsonExit(tId))\n\n// Flat zum Sessionende, vor FOMC und bei Tageslimit\nif strategy.position_size != 0\n    if flatEnd and not inSess\n        strategy.close_all(comment = "Sessionende", alert_message = jsonExit(""))\n    else if isFomc and blockFomc != "Ignorieren" and nyMin >= 13 * 60 + 50\n        strategy.close_all(comment = "FOMC", alert_message = jsonExit(""))\n    else if lossHit\n        strategy.close_all(comment = "Tageslimit", alert_message = jsonExit(""))\n\nplot(strategy.position_size != 0 ? tSL : na, "Stop",   color = cBear, style = plot.style_linebr)\nplot(strategy.position_size != 0 ? tTP : na, "Target", color = cBull, style = plot.style_linebr)\nbgcolor(inSess and newsBlock ? color.new(cIBear, 88) : na, title = "News-Sperre")\n\n// Kerzen-Daten für die App (Paper-Trading prüft damit Stop/Ziel, das Lernmodul die Schatten-Trades)\nif sendBars and barstate.isrealtime and barstate.isconfirmed\n    alert(\'{"type":"bar","ticker":"\' + sym + \'","time":\' + str.tostring(time) +\n         \',"open":\' + str.tostring(open, format.mintick) + \',"high":\' + str.tostring(high, format.mintick) +\n         \',"low":\' + str.tostring(low, format.mintick) + \',"close":\' + str.tostring(close, format.mintick) + \'}\', alert.freq_once_per_bar_close)\n\n// ───────────────────────── Statistik je Setup ─────────────────────────\nvar array<string> stName = array.from("FVG", "iFVG", "Silver Bullet", "ORB", "Sweep", "VWAP")\nvar array<int>   stCnt  = array.new<int>(6, 0)\nvar array<int>   stWin  = array.new<int>(6, 0)\nvar array<float> stPnl  = array.new<float>(6, 0.0)\nvar int seen = 0\nif strategy.closedtrades > seen\n    for i = seen to strategy.closedtrades - 1\n        string eid = strategy.closedtrades.entry_id(i)\n        int   k = 0\n        for j = 0 to 5\n            if str.startswith(eid, stName.get(j) + " ")\n                k := j\n        float p = strategy.closedtrades.profit(i)\n        stCnt.set(k, stCnt.get(k) + 1)\n        stPnl.set(k, stPnl.get(k) + p)\n        if p > 0\n            stWin.set(k, stWin.get(k) + 1)\n    seen := strategy.closedtrades\n\n// ───────────────────────── Dashboard ─────────────────────────\ndashPos = switch dashPosStr\n    "Oben links"   => position.top_left\n    "Unten rechts" => position.bottom_right\n    "Unten links"  => position.bottom_left\n    => position.top_right\n\nvar table dash = table.new(dashPos, 2, 21, bgcolor = color.new(#131722, 8), border_color = color.new(#363a45, 0), border_width = 1, frame_color = color.new(#363a45, 0), frame_width = 1)\n\nmoney(float v) =>\n    (v < 0 ? "-$" : "$") + str.tostring(math.abs(v), "#,##0")\npct(float v) =>\n    na(v) ? "–" : str.tostring(v, "0.0") + "%"\nrow(int r, string k, string v, color vc) =>\n    table.cell(dash, 0, r, k, text_color = cMuted, text_size = size.small, text_halign = text.align_left)\n    table.cell(dash, 1, r, v, text_color = vc, text_size = size.small, text_halign = text.align_right)\n\nif showDash and barstate.islast\n    int ct      = strategy.closedtrades\n    float wr    = ct > 0 ? float(strategy.wintrades) / ct * 100 : na\n    float pf    = strategy.grossloss > 0 ? strategy.grossprofit / strategy.grossloss : na\n    float avgT  = ct > 0 ? strategy.netprofit / ct : na\n    int nF = 0\n    int nI = 0\n    for z in zones\n        if z.inverse\n            nI += 1\n        else\n            nF += 1\n    string pos  = strategy.position_size > 0 ? "LONG " + str.tostring(strategy.position_size) : strategy.position_size < 0 ? "SHORT " + str.tostring(math.abs(strategy.position_size)) : "Flat"\n    color posC  = strategy.position_size > 0 ? cBull : strategy.position_size < 0 ? cBear : color.white\n\n    table.cell(dash, 0, 0, "FVG Bot · " + syminfo.ticker + " · " + timeframe.period, text_color = color.white, text_size = size.normal, text_halign = text.align_left)\n    table.merge_cells(dash, 0, 0, 1, 0)\n    row(1,  "Position",          pos, posC)\n    string sName = inAsia ? "Asien" : inLondon ? "London" : inNyAm ? "NY Vormittag" : inNyLun ? "NY Mittag" : inNyPm ? "NY Nachmittag" : "keine"\n    row(2,  "Session",           sName, inSess ? cBull : cMuted)\n    row(3,  "News-Filter",       newsBlock ? "gesperrt · " + newsReason : "frei", newsBlock ? cIBear : cBull)\n    row(4,  "HTF-Bias",          not useBias ? "aus" : close > htfEma ? "bullisch" : "bärisch", not useBias ? cMuted : close > htfEma ? cBull : cBear)\n    row(5,  "Aktive Zonen",      str.tostring(nF) + " FVG · " + str.tostring(nI) + " iFVG", color.white)\n    row(6,  "Trades heute",      str.tostring(tradesToday) + " / " + str.tostring(maxTradesDay), color.white)\n    row(7,  "P&L heute",         money(dayPnl), dayPnl >= 0 ? cBull : cBear)\n    row(8,  "─────",             "", cMuted)\n    row(9,  "Netto-Gewinn",      money(strategy.netprofit), strategy.netprofit >= 0 ? cBull : cBear)\n    row(10, "Trades gesamt",     str.tostring(ct), color.white)\n    row(11, "Trefferquote",      pct(wr), color.white)\n    row(12, "Profit-Faktor",     na(pf) ? "–" : str.tostring(pf, "0.00"), not na(pf) and pf >= 1 ? cBull : cBear)\n    row(13, "Ø Trade",           na(avgT) ? "–" : money(avgT), not na(avgT) and avgT >= 0 ? cBull : cBear)\n    row(14, "Max. Drawdown",     money(-strategy.max_drawdown), cBear)\n    for j = 0 to 5\n        int   n = stCnt.get(j)\n        float w = n > 0 ? float(stWin.get(j)) / n * 100 : na\n        row(15 + j, stName.get(j), n == 0 ? "–" : str.tostring(n) + " · " + pct(w) + " · " + money(stPnl.get(j)), n == 0 ? cMuted : stPnl.get(j) >= 0 ? cBull : cBear)\n'

# ═════════════════ server.py ═════════════════
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





ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.environ.get("FVG_DATA", os.path.join(os.path.dirname(os.path.abspath(__file__)), "FVG-Trader-Daten"))
STATIC = os.path.join(ROOT, "app", "static")
HOST = os.environ.get("FVG_HOST", "127.0.0.1")
PORT = int(os.environ.get("FVG_PORT", "8787"))
BACKGROUND = "--hintergrund" in sys.argv
APP_VERSION = "2.0.0"   # wird beim Bauen der Ein-Datei-Version gesetzt

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
                        "rem Startet FVG Trader nach einem Update neu (unsichtbar, ohne Konsolenfenster)\r\n"
                        "ping -n 3 127.0.0.1 >nul\r\n"
                        f'call "{LAUNCHER}" --hintergrund\r\n')
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
        v = None
        for attempt in range(3):   # GitHub speichert kurz zwischen: bei falscher Prüfsumme neu laden
            data = _fetch(UPDATE["file"])
            try:
                v = install_update(data, UPDATE.get("sha256"))
                break
            except ValueError as e:
                if "Prüfsumme" not in str(e) or attempt == 2:
                    raise
                engine.db.log("Update: Prüfsumme passt noch nicht, lade erneut …", "warn")
                time.sleep(4)
                check_update()
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
