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
    is_test INTEGER DEFAULT 0, raw TEXT, bar_time REAL, mgmt TEXT
);
CREATE TABLE IF NOT EXISTS positions (
    id TEXT PRIMARY KEY,
    signal_id TEXT, broker TEXT, root TEXT, contract TEXT, side TEXT, setup TEXT,
    qty INTEGER, entry REAL, sl REAL, tp REAL, initial_sl REAL,
    opened REAL, closed REAL, exit REAL, pnl REAL,
    status TEXT, close_reason TEXT, broker_ref TEXT, is_test INTEGER DEFAULT 0, bar_time REAL,
    source TEXT, trade_day TEXT, note TEXT, mgmt TEXT, best REAL, exit_bar REAL
);
CREATE TABLE IF NOT EXISTS shadow (
    id TEXT PRIMARY KEY,
    signal_id TEXT, setup TEXT, fam TEXT, side TEXT,
    entry REAL, sl REAL, tp REAL, opened REAL, closed REAL, exit REAL, r REAL,
    status TEXT, ny_hour INTEGER, ny_weekday INTEGER, bar_time REAL, ctx TEXT
);
CREATE TABLE IF NOT EXISTS variants (
    id TEXT PRIMARY KEY,
    shadow_id TEXT, setup TEXT, fam TEXT, side TEXT, var TEXT,
    entry REAL, stop REAL, risk REAL, tp REAL, best REAL,
    opened REAL, closed REAL, exit REAL, r REAL, status TEXT, bar_time REAL
);
CREATE TABLE IF NOT EXISTS bars (
    id TEXT PRIMARY KEY,
    fam TEXT, t REAL, o REAL, h REAL, l REAL, c REAL
);
CREATE TABLE IF NOT EXISTS bars1 (
    id TEXT PRIMARY KEY,
    fam TEXT, t REAL, o REAL, h REAL, l REAL, c REAL
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
            self.con.execute("CREATE INDEX IF NOT EXISTS bars_ft ON bars (fam, t)")
            self.con.execute("CREATE INDEX IF NOT EXISTS bars1_ft ON bars1 (fam, t)")
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

    # --- Varianten-Labor ---
    def add_variants(self, rows):
        if not rows:
            return
        cols = list(rows[0].keys())
        with self.lock:
            self.con.executemany(f"INSERT INTO variants ({','.join(cols)}) VALUES ({','.join('?' * len(cols))})",
                                 [list(r.values()) for r in rows])
            self.con.commit()

    def open_variants(self):
        return self.rows("SELECT * FROM variants WHERE status='offen'")

    def update_variant(self, vid, **kw):
        self._exec(f"UPDATE variants SET {','.join(k + '=?' for k in kw)} WHERE id=?", list(kw.values()) + [vid])

    def closed_variants(self):
        return self.rows("SELECT setup, var, side, r, opened, closed FROM variants WHERE status='geschlossen' ORDER BY opened")

    # --- Kerzen (für Key Levels und Session-Muster) ---
    def add_bar(self, fam, t, o, h, l, c):
        self._exec("INSERT OR REPLACE INTO bars (id, fam, t, o, h, l, c) VALUES (?,?,?,?,?,?,?)",
                   (f"{fam}{int(t)}", fam, t, o, h, l, c))

    def bars(self, fam, since_ms):
        return self.rows("SELECT t, o, h, l, c FROM bars WHERE fam=? AND t>=? ORDER BY t", (fam, since_ms))

    def bar_fams(self):
        return [r["fam"] for r in self.rows("SELECT fam, COUNT(*) n FROM bars GROUP BY fam ORDER BY n DESC")]

    def prune_bars(self, before_ms):
        self._exec("DELETE FROM bars WHERE t < ?", (before_ms,))

    # 1-Minuten-Kerzen (kommen gebündelt mit jeder Chart-Kerze, für Live-Chart und genaue Stop/Ziel-Prüfung)
    def add_bars1(self, fam, rows):
        with self.lock:
            self.con.executemany("INSERT OR REPLACE INTO bars1 (id, fam, t, o, h, l, c) VALUES (?,?,?,?,?,?,?)",
                                 [(f"{fam}{int(r[0])}", fam, *r) for r in rows])
            self.con.commit()

    def bars1(self, fam, since_ms):
        return self.rows("SELECT t, o, h, l, c FROM bars1 WHERE fam=? AND t>=? ORDER BY t", (fam, since_ms))

    def prune_bars1(self, before_ms):
        self._exec("DELETE FROM bars1 WHERE t < ?", (before_ms,))

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

    def modify_target(self, pos, new_tp):
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

    def modify_target(self, pos, new_tp):
        ref = pos["broker_ref"]
        if not ref.get("tpId"):
            raise BrokerError("Diese Position hat beim Broker keine Ziel-Order, das Ziel kann nicht nachträglich gesetzt werden")
        if new_tp is None:
            raise BrokerError("Das Ziel kann beim Broker nicht entfernt werden, nur verschoben")
        self._req("POST", "/order/modifyorder", {"orderId": ref["tpId"], "orderQty": pos["qty"],
                                                  "orderType": "Limit", "price": new_tp, "isAutomated": True})
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
import bisect
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


SESSION_NAMES = {k: v[0] for k, v in TRADING_SESSIONS.items()} | {"aus": "außerhalb der Sessions", "ganztags": "Ganztägig"}


def market_open(t):
    """CME-Futures: So 18:00 bis Fr 17:00 New York, täglich Pause 17–18 Uhr."""
    wd, hm = t.weekday(), t.strftime("%H:%M")
    if wd == 5 or (wd == 6 and hm < "18:00") or (wd == 4 and hm >= "17:00"):
        return False
    return not ("17:00" <= hm < "18:00")


def session_of(t):
    """Benannte Session zu einer New-Yorker Uhrzeit (unabhängig von den Haken), sonst „aus“."""
    return next((k for k in TRADING_SESSIONS if in_session(k, t)), "aus")


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
    "auto_update": False,      # neue Versionen selbst installieren (nur ohne offenen Trade)
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
        "all_day": False,          # ganztägig handeln (außer Marktpause)
        "flat_at_session_end": True,
    },
    "news": {                  # News-Pause aus dem Wirtschaftskalender
        "enabled": True, "before_min": 10, "after_min": 10, "impact": "high", "usd_only": True, "close_before": True,
    },
    "exit_rules": {},          # Strategie -> übernommene Ausstiegs-Variante (Varianten-Labor)
    "rule_filters": [],        # übernommene Regeln aus dem Regel-Finder
    "challenge": {             # Fremdkapital / Prop-Firm-Challenge
        "enabled": False, "name": "", "phase": "Challenge", "start_balance": 50000.0, "start_day": "",
        "profit_target": 3000.0, "max_dd": 2000.0, "dd_type": "eod", "lock_at_start": True,
        "daily_loss": 1000.0, "consistency_pct": 0.0, "min_days": 0, "source": "alle",
        "guard": True, "guard_buffer": 250.0,
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


# ───────────────────────── Key Levels & Session-Muster (aus gesammelten Kerzen) ─────────────────────────
def _ny_dt(ms):
    return ny_time(ms / 1000)


def _win(bars, a, b):
    """Kerzen, deren Beginn in [a, b) liegt (NY-Zeit)."""
    return [x for x in bars if a <= x["ny"] < b]


def _range_hl(bs):
    return (max(x["h"] for x in bs), min(x["l"] for x in bs)) if bs else (None, None)


def _first_break(bs, hi, lo):
    """Welche Seite wird zuerst gebrochen? ('oben'|'unten'|None, Uhrzeit, beide Seiten?)"""
    first, when, up, dn = None, None, False, False
    for x in bs:
        u, d = hi is not None and x["h"] > hi, lo is not None and x["l"] < lo
        if (u or d) and first is None:
            first = "oben" if u and not d else "unten" if d and not u else ("oben" if x["c"] >= x["o"] else "unten")
            when = x["ny"].strftime("%H:%M")
        up, dn = up or u, dn or d
    return first, when, up and dn


def summarize_day(bars, day):
    """Alle Levels und Ereignisse eines New-Yorker Handelstags. bars: Kerzen mit Feld 'ny' (datetime)."""
    D = dt.datetime.combine(day, dt.time(0))
    t = lambda h, m=0, d=0: D + dt.timedelta(days=d, hours=h, minutes=m)  # noqa: E731
    prev_days = sorted({x["ny"].date() for x in bars if x["ny"] < D and x["ny"].weekday() < 5
                        and dt.time(9, 30) <= x["ny"].time() < dt.time(16)})
    out = {"day": str(day), "levels": [], "events": {}}
    pd = prev_days[-1] if prev_days else None
    if pd:
        P = dt.datetime.combine(pd, dt.time(0))
        prth = _win(bars, P + dt.timedelta(hours=9, minutes=30), P + dt.timedelta(hours=16))
        if prth:
            h, l = _range_hl(prth)
            out["pdh"], out["pdl"], out["pdc"] = h, l, prth[-1]["c"]
    on = _win(bars, t(18, d=-1), t(9, 30))
    asia = _win(bars, t(20, d=-1), t(0))
    london = _win(bars, t(2), t(5))
    rth = _win(bars, t(9, 30), t(16))
    ib = _win(bars, t(9, 30), t(10, 30))
    mid = _win(bars, t(0), t(0, 30))
    out["onh"], out["onl"] = _range_hl(on)
    out["asia_h"], out["asia_l"] = _range_hl(asia)
    out["lon_h"], out["lon_l"] = _range_hl(london)
    out["ib_h"], out["ib_l"] = _range_hl(ib)
    out["mid_open"] = mid[0]["o"] if mid else None
    out["rth_open"] = rth[0]["o"] if rth else None
    out["rth_bars"] = len(rth)
    out["rth_done"] = bool(rth) and rth[-1]["ny"] >= t(15, 30)
    out["ib_done"] = bool(ib) and ib[-1]["ny"] >= t(10, 15)
    out["lon_done"] = bool(london) and london[-1]["ny"] >= t(4, 45)
    out["asia_done"] = bool(asia) and asia[-1]["ny"] >= t(23, 45, d=-1)
    ev = out["events"]
    # Gap: RTH-Eröffnung gegen Vortagesschluss
    if out.get("pdc") is not None and out["rth_open"] is not None:
        g = out["rth_open"] - out["pdc"]
        ev["gap"] = {"size": round(g, 2), "dir": "hoch" if g > 0 else "runter" if g < 0 else "keins", "filled": False, "when": None}
        for x in rth:
            if (g > 0 and x["l"] <= out["pdc"]) or (g < 0 and x["h"] >= out["pdc"]):
                ev["gap"].update(filled=True, when=x["ny"].strftime("%H:%M"))
                break
    if out["asia_done"]:
        f, w, both = _first_break(_win(bars, t(0), t(16)), out["asia_h"], out["asia_l"])
        ev["asia"] = {"first": f, "when": w, "both": both}
    if out["lon_done"]:
        f, w, both = _first_break(_win(bars, t(5), t(16)), out["lon_h"], out["lon_l"])
        ev["london"] = {"first": f, "when": w, "both": both}
    if out["ib_done"]:
        f, w, both = _first_break(_win(bars, t(10, 30), t(16)), out["ib_h"], out["ib_l"])
        ev["ib"] = {"first": f, "when": w, "both": both}
    if rth and out.get("pdh") is not None:
        ev["pdh"] = next((x["ny"].strftime("%H:%M") for x in rth if x["h"] > out["pdh"]), None)
        ev["pdl"] = next((x["ny"].strftime("%H:%M") for x in rth if x["l"] < out["pdl"]), None)
    if rth and out["mid_open"] is not None:
        ev["mid"] = next((x["ny"].strftime("%H:%M") for x in rth if x["l"] <= out["mid_open"] <= x["h"]), None)
    if rth:
        h, l = _range_hl(rth)
        hi_t = next(x["ny"] for x in rth if x["h"] == h)
        lo_t = next(x["ny"] for x in rth if x["l"] == l)
        ev["hod"], ev["lod"] = hi_t.strftime("%H:%M"), lo_t.strftime("%H:%M")
        ev["rth_close"] = rth[-1]["c"]
    return out


# ───────────────────────── Varianten-Labor: Ausstiegs-Varianten je Signal ─────────────────────────
VARIANTS = {
    "1R": {"tp": 1.0}, "1,5R": {"tp": 1.5}, "2R": {"tp": 2.0}, "3R": {"tp": 3.0},
    "2R + BE": {"tp": 2.0, "be": 1.0}, "3R + BE": {"tp": 3.0, "be": 1.0},
    "Trailing 1R": {"trail": 1.0}, "Bis Session-Ende": {},
}
PAPER_ONLY_VARIANTS = ("Trailing 1R", "Bis Session-Ende")   # brauchen eine Order ohne festes Ziel


def manage_stop(side, entry, risk, stop, best, rule):
    """Neuer Stop nach Break-even-/Trailing-Regel (oder unverändert)."""
    d = 1 if side == "long" else -1
    gain = (best - entry) * d
    new = stop
    if rule.get("be") and gain >= rule["be"] * risk:
        new = max(new, entry) if d > 0 else min(new, entry)
    if rule.get("trail") and gain >= rule["trail"] * risk:
        t = best - d * rule["trail"] * risk
        new = max(new, t) if d > 0 else min(new, t)
    return new


# ───────────────────────── Regel-Finder: Marktlage beim Signal ─────────────────────────
FEATURES = {
    "side": "Richtung", "hour": "Uhrzeit (NY)", "weekday": "Wochentag", "session": "Session",
    "gap": "Opening-Gap", "london": "London-Range", "ib": "Initial Balance", "asia": "Asien-Range",
    "pd": "Lage zum Vortag", "on": "Lage zum Overnight", "mo": "Midnight Open", "ro": "RTH-Open",
}
WD = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]


def describe_cond(f, v):
    if f == "side":
        return "Long" if v == "long" else "Short"
    if f == "hour":
        return f"{v}–{int(v) + 1} Uhr NY"
    if f == "weekday":
        return WD[int(v)] if str(v).isdigit() else v
    if f == "session":
        return TRADING_SESSIONS[v][0] if v in TRADING_SESSIONS else "außerhalb der Sessions"
    if f == "gap":
        return {"hoch": "Gap hoch", "runter": "Gap runter", "keins": "kein Gap"}.get(v, v)
    if f in ("london", "ib", "asia"):
        name = {"london": "London", "ib": "IB", "asia": "Asien"}[f]
        return f"{name} noch nicht gebrochen" if v == "keiner" else f"{name} {v} zuerst gebrochen"
    if f == "pd":
        return {"ueber": "über Vortageshoch", "unter": "unter Vortagestief", "innen": "innerhalb Vortagesrange"}.get(v, v)
    if f == "on":
        return {"ueber": "über Overnight-Hoch", "unter": "unter Overnight-Tief", "innen": "in der Overnight-Range"}.get(v, v)
    if f == "mo":
        return "über Midnight Open" if v == "ueber" else "unter Midnight Open"
    if f == "ro":
        return "über RTH-Open" if v == "ueber" else "unter RTH-Open"
    return f"{f}={v}"


def _mean(x):
    return sum(x) / len(x) if x else 0.0


def _welch_t(a, b):
    """t-Wert für den Unterschied zweier Gruppen. Nutzt die Streuung aller Signale, damit kleine Gruppen
    mit lauter gleichen Ergebnissen (z. B. 8 Verluste in Folge) nicht künstlich sicher wirken."""
    if len(a) < 2 or len(b) < 2:
        return 0.0
    allv = a + b
    m = _mean(allv)
    sd = math.sqrt(sum((x - m) ** 2 for x in allv) / (len(allv) - 1))
    se = sd * math.sqrt(1 / len(a) + 1 / len(b))
    return (_mean(a) - _mean(b)) / se if se > 1e-9 else 0.0


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
        self.chart_tf = {}            # Familie -> Kerzenlänge des TradingView-Charts in ms
        self.news_source = lambda: []  # liefert die Termine des Wirtschaftskalenders (setzt der Server)
        self._news_closed = set()
        self.last_tick = {}           # Familie -> {"price", "ts"}: Live-Kurs, solange ein Trade offen ist
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
        nw = c["news"]
        nw["enabled"], nw["usd_only"], nw["close_before"] = bool(nw["enabled"]), bool(nw["usd_only"]), bool(nw["close_before"])
        nw["before_min"], nw["after_min"] = int(nw["before_min"] or 0), int(nw["after_min"] or 0)
        if not (0 <= nw["before_min"] <= 240 and 0 <= nw["after_min"] <= 240):
            raise ValueError("News-Pause: Minuten vorher/nachher zwischen 0 und 240")
        if nw["impact"] not in ("high", "medium"):
            raise ValueError("News-Pause: Wichtigkeit muss hoch oder mittel sein")
        er = c.get("exit_rules") or {}
        c["exit_rules"] = {str(k)[:40]: v for k, v in er.items() if v in VARIANTS}
        rf = c.get("rule_filters") or []
        if not isinstance(rf, list) or len(rf) > 50:
            raise ValueError("Regel-Finder: höchstens 50 Regeln")
        clean = []
        for r in rf:
            if r.get("action") not in ("avoid", "only") or not r.get("conds"):
                raise ValueError("Regel-Finder: ungültige Regel")
            conds = [[str(f), str(v)] for f, v in r["conds"] if f in FEATURES][:3]
            clean.append({"setup": str(r.get("setup", ""))[:40], "conds": conds, "action": r["action"],
                          "label": str(r.get("label", ""))[:160], "added": float(r.get("added") or time.time()),
                          "active": bool(r.get("active", True))})
        c["rule_filters"] = clean
        ch = c["challenge"]
        for k in ("start_balance", "profit_target", "max_dd", "daily_loss", "consistency_pct", "guard_buffer"):
            ch[k] = float(ch[k] or 0)
            if ch[k] < 0:
                raise ValueError("Fremdkapital: Werte dürfen nicht negativ sein")
        ch["min_days"] = int(ch["min_days"] or 0)
        if ch["dd_type"] not in ("eod", "intraday", "static"):
            raise ValueError("Fremdkapital: unbekannte Drawdown-Art")
        if ch["source"] not in ("alle", "bot", "eigen"):
            raise ValueError("Fremdkapital: unbekannte Trade-Quelle")
        if ch["start_day"] and not re.match(r"^\d{4}-\d{2}-\d{2}$", ch["start_day"]):
            raise ValueError("Fremdkapital: Startdatum als JJJJ-MM-TT")
        if ch["enabled"] and (ch["start_balance"] <= 0 or ch["max_dd"] <= 0):
            raise ValueError("Fremdkapital: Kontogröße und maximaler Drawdown müssen größer als 0 sein")
        if ch["consistency_pct"] > 100:
            raise ValueError("Fremdkapital: Konsistenzregel in % (0–100)")
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
        c["risk"]["all_day"] = bool(c["risk"].get("all_day"))
        if c["risk"]["enforce_session"] and not any(c["risk"]["sessions"].values()) and not c["risk"]["all_day"]:
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
            if kind == "tick":
                return self._on_tick(payload)
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
        tf = self._num(p.get("tf"))
        if tf and tf > 0:
            self.chart_tf[fam] = tf
        self.last_bar[fam] = bar
        if bar["time"]:
            try:
                self.db.add_bar(fam, bar["time"], bar["open"], bar["high"], bar["low"], bar["close"])
            except Exception as e:  # noqa: BLE001
                self.db.log(f"Kerze nicht gespeichert: {e}", "warn")
        subs = []
        for r in (p.get("m1") or [])[:240] if isinstance(p.get("m1"), list) else []:
            if isinstance(r, list) and len(r) >= 5:
                vals = [self._num(x) for x in r[:5]]
                if None not in vals:
                    subs.append(vals)
        subs.sort(key=lambda r: r[0])
        if subs:
            try:
                self.db.add_bars1(fam, subs)
            except Exception as e:  # noqa: BLE001
                self.db.log(f"1-Minuten-Kerzen nicht gespeichert: {e}", "warn")
            # Stop/Ziel minutengenau prüfen statt nur mit der großen Kerze
            for t_, o_, h_, l_, c_ in subs:
                self._process_bar(fam, {"time": t_, "open": o_, "high": h_, "low": l_, "close": c_, "ts": bar["ts"]})
        else:
            self._process_bar(fam, bar)
        return {"ok": True, "type": "bar", "m1": len(subs)}

    def _on_tick(self, p):
        """Live-Kurs aus TradingView (alle ~20 s, solange die Strategie im Trade ist)."""
        fam = family(self._root(p.get("ticker")))
        price = self._num(p.get("price"))
        if price is None:
            raise ValueError("Kurs fehlt")
        self.last_tick[fam] = {"price": price, "ts": time.time(), "time": self._num(p.get("time"))}
        if self.broker.name == "paper":   # Stop/Ziel sofort prüfen statt erst zum Kerzenschluss
            for pos in self.db.open_positions():
                if family(pos["root"]) != fam or pos["broker"] != "paper" or time.time() - pos["opened"] < 5:
                    continue
                long_ = pos["side"] == "long"
                if (price <= pos["sl"]) if long_ else (price >= pos["sl"]):
                    self.db.update_position(pos["id"], exit_bar=(p.get("time") or time.time() * 1000))
                    self._finish(pos, pos["sl"], "Stop-Loss", slip=True)
                elif pos["tp"] and ((price >= pos["tp"]) if long_ else (price <= pos["tp"])):
                    self.db.update_position(pos["id"], exit_bar=(p.get("time") or time.time() * 1000))
                    self._finish(pos, pos["tp"], "Ziel erreicht", slip=False)
        return {"ok": True, "type": "tick"}

    def _process_bar(self, fam, bar):
        for sh in self.db.open_shadows():
            if sh["fam"] != fam or not self._bar_after(sh, bar):
                continue
            long_ = sh["side"] == "long"
            if (bar["low"] <= sh["sl"]) if long_ else (bar["high"] >= sh["sl"]):
                self._close_shadow(sh, sh["sl"])
            elif (bar["high"] >= sh["tp"]) if long_ else (bar["low"] <= sh["tp"]):
                self._close_shadow(sh, sh["tp"])
        bar_ny = ny_time(bar["time"] / 1000) if bar.get("time") else None
        if bar_ny:
            for sh in self.db.open_shadows():
                if sh["fam"] == fam and bar_ny >= self._session_end(sh):
                    self._close_shadow(sh, bar["open"])
        for v in self.db.open_variants():
            if v["fam"] != fam or not self._bar_after(v, bar):
                continue
            if bar_ny and bar_ny >= self._session_end(v):
                self._close_variant(v, bar["open"])   # alles, was noch offen ist, endet mit der New-York-Session
                continue
            long_ = v["side"] == "long"
            if (bar["low"] <= v["stop"]) if long_ else (bar["high"] >= v["stop"]):
                self._close_variant(v, v["stop"])
                continue
            if v["tp"] is not None and ((bar["high"] >= v["tp"]) if long_ else (bar["low"] <= v["tp"])):
                self._close_variant(v, v["tp"])
                continue
            best = max(v["best"], bar["high"]) if long_ else min(v["best"], bar["low"])
            stop = manage_stop(v["side"], v["entry"], v["risk"], v["stop"], best, VARIANTS.get(v["var"], {}))
            if best != v["best"] or stop != v["stop"]:
                self.db.update_variant(v["id"], best=best, stop=stop)
        # Break-even/Trailing für Bot-Positionen mit übernommenem Ausstieg (wirkt ab der nächsten Kerze)
        for pos in self.db.open_positions():
            rule = VARIANTS.get(pos.get("mgmt") or "")
            if not rule or not (rule.get("be") or rule.get("trail")) or family(pos["root"]) != fam or not self._bar_after(pos, bar):
                continue
            long_ = pos["side"] == "long"
            if (bar["low"] <= pos["sl"]) if long_ else (bar["high"] >= pos["sl"]):
                continue   # Stop wird gleich ausgelöst bzw. vom Broker ausgeführt
            risk = abs(pos["entry"] - (pos["initial_sl"] or pos["sl"]))
            prev = pos.get("best") or pos["entry"]
            best = max(prev, bar["high"]) if long_ else min(prev, bar["low"])
            new = round_tick(manage_stop(pos["side"], pos["entry"], risk, pos["sl"], best, rule), INSTR[pos["root"]]["tick"])
            if new != pos["sl"]:
                try:
                    self.broker.modify_stop(pos, new)
                    self.db.update_position(pos["id"], sl=new, best=best)
                    self.db.log(f"Stop {pos['root']} nachgezogen auf {new:.2f} ({pos['mgmt']})")
                except BrokerError as e:
                    self.db.log(f"Stop nachziehen fehlgeschlagen: {e}", "error")
            elif best != prev:
                self.db.update_position(pos["id"], best=best)
        if self.broker.name == "paper":
            for pos in self.db.open_positions():
                if family(pos["root"]) != fam or pos["broker"] != "paper" or not self._bar_after(pos, bar):
                    continue
                long_ = pos["side"] == "long"
                hit_sl = bar["low"] <= pos["sl"] if long_ else bar["high"] >= pos["sl"]
                hit_tp = pos["tp"] and (bar["high"] >= pos["tp"] if long_ else bar["low"] <= pos["tp"])
                if (hit_sl or hit_tp) and bar.get("time"):
                    self.db.update_position(pos["id"], exit_bar=bar["time"])   # für den Chart: Ausstieg an der richtigen Kerze
                if hit_sl:   # beide in einer Kerze: konservativ als Stop werten
                    self._finish(pos, pos["sl"], "Stop-Loss", slip=True)
                elif hit_tp:
                    self._finish(pos, pos["tp"], "Ziel erreicht", slip=False)

    def _bar_after(self, obj, bar):
        """Die Kerze, auf der das Signal entstand, darf den Trade nicht auslösen.
        Bei 1-Minuten-Kerzen zählen erst die Minuten nach dem Schluss der Signal-Kerze."""
        if bar.get("time") and obj.get("bar_time"):
            fam = obj.get("fam") or family(obj["root"])
            tf = self.chart_tf.get(fam)
            return bar["time"] >= obj["bar_time"] + tf if tf else bar["time"] > obj["bar_time"]
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
        sig_ts = base["bar_time"] / 1000 if base["bar_time"] and abs(base["bar_time"] / 1000 - time.time()) < 400 * 86400 else None
        try:
            ctx = self.context(fam, side, price, sig_ts)
        except Exception as e:  # noqa: BLE001
            ctx = {"side": side}
            self.db.log(f"Marktlage nicht bestimmbar: {e}", "warn")
        if not is_test:
            now_ny = ny_time(sig_ts)
            shid = uuid.uuid4().hex[:10]
            self.db.add_shadow({"id": shid, "signal_id": sid, "setup": base["setup"], "fam": fam,
                                "side": side, "entry": price, "sl": sl, "tp": tp, "opened": time.time(),
                                "status": "offen", "ny_hour": now_ny.hour, "ny_weekday": now_ny.weekday(),
                                "bar_time": base["bar_time"], "ctx": json.dumps(ctx)})
            risk = abs(price - sl)
            if risk > 0:
                d = 1 if side == "long" else -1
                self.db.add_variants([{
                    "id": uuid.uuid4().hex[:12], "shadow_id": shid, "setup": base["setup"], "fam": fam, "side": side,
                    "var": k, "entry": price, "stop": sl, "risk": risk,
                    "tp": price + d * v["tp"] * risk if v.get("tp") else None, "best": price,
                    "opened": time.time(), "status": "offen", "bar_time": base["bar_time"]} for k, v in VARIANTS.items()])
        # Vom Varianten-Labor übernommener Ausstieg für diese Strategie
        mgmt = (self.cfg.get("exit_rules") or {}).get(base["setup"])
        if mgmt in VARIANTS and not (mgmt in PAPER_ONLY_VARIANTS and self.broker.name != "paper"):
            v = VARIANTS[mgmt]
            d = 1 if side == "long" else -1
            tick = INSTR[fam]["tick"]
            tp = round_tick(price + d * v["tp"] * abs(price - sl), tick) if v.get("tp") else None
            base["mgmt"] = mgmt
            flags.append(f"Ausstieg {mgmt} (Varianten-Labor)")
        sized = self._size(fam, price, sl)
        base.update(sl=sl, tp=tp, flags=flags)
        if isinstance(sized, str):
            base.update(status="blockiert", reason=sized)
            self.db.add_signal(base)
            self.db.log(f"Signal {side.upper()} {fam} blockiert: {sized}", "warn")
            return {"ok": False, "status": "blockiert", "reason": sized}
        root, qty, risk_usd = sized
        sess_now = session_of(ny_time(sig_ts))
        rule = self.setup_rule(base["setup"], sess_now)
        if rule == "halbe Größe" and qty > 1:
            qty = qty // 2
            risk_usd = round(qty * abs(price - sl) * INSTR[root]["pv"], 2)
            flags.append("Halbe Größe (Lernmodul)")
        base.update(root=root, qty=qty, risk_usd=risk_usd, contract=self.broker.contract_name(root), flags=flags)

        guard = None
        if rule == "aus":
            guard = f"Strategie {base['setup']} ist ausgeschaltet"
        elif rule == "pausiert":
            ses_p = ((self.learning.get("setups", {}).get(base["setup"]) or {}).get("sessions") or {}).get(sess_now, {}).get("status") == "pausiert"
            guard = (f"Strategie {base['setup']} vom Lernmodul in {SESSION_NAMES.get(sess_now, sess_now)} pausiert (läuft im Schatten weiter)"
                     if ses_p else f"Strategie {base['setup']} vom Lernmodul pausiert (läuft im Schatten weiter)")
        if not guard and not is_test:
            guard = self.rule_block(base["setup"], ctx)
        guard = guard or self._guards(fam, base.get("risk_usd"))
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
        """Schlüssel der gerade laufenden, angehakten Session (bei „ganztägig“: „ganztags“) oder None."""
        t = t or ny_time()
        on = self.cfg["risk"].get("sessions") or {}
        k = next((k for k in TRADING_SESSIONS if on.get(k) and in_session(k, t)), None)
        if not k and self.cfg["risk"].get("all_day") and market_open(t):
            return "ganztags"
        return k

    def news_window(self, now=None):
        """Wichtige Termine, deren Sperrzeit gerade läuft oder in den nächsten 3 Stunden beginnt."""
        nw = self.cfg["news"]
        if not nw["enabled"]:
            return []
        now = now or time.time()
        out = []
        for e in self.news_source() or []:
            if nw["usd_only"] and e.get("country") != "USD":
                continue
            if e.get("impact") not in (("high",) if nw["impact"] == "high" else ("high", "medium")):
                continue
            t = e["ts"] / 1000
            start, end = t - nw["before_min"] * 60, t + nw["after_min"] * 60
            if end >= now and start <= now + 3 * 3600:
                out.append(dict(e, start=start, end=end, active=start <= now <= end))
        return sorted(out, key=lambda x: x["start"])

    def news_block(self):
        act = [e for e in self.news_window() if e["active"]]
        if not act:
            return None
        e = act[0]
        return f"News-Pause: {e['title']} um {ny_time(e['ts'] / 1000).strftime('%H:%M')} NY (bis {ny_time(e['end']).strftime('%H:%M')})"

    def _guards(self, fam, risk=None):
        r = self.cfg["risk"]
        if self.cfg["paused"]:
            return "Handel pausiert"
        nb = self.news_block()
        if nb:
            return nb
        ch = self.cfg["challenge"]
        if ch["enabled"] and ch["guard"] and ch["source"] != "eigen":
            c = self.challenge()
            if c["breached"]:
                return "Fremdkapital: Verlustgrenze erreicht, Konto ist verletzt"
            if c["daily_left"] is not None and c["daily_left"] <= ch["guard_buffer"]:
                return f"Fremdkapital: Tageslimit fast erreicht (noch ${c['daily_left']:.0f})"
            if c["can_lose"] <= ch["guard_buffer"]:
                return f"Fremdkapital-Schutz: nur noch ${c['can_lose']:.0f} bis zur Verlustgrenze"
            if risk and risk > c["can_lose"] - ch["guard_buffer"]:
                return f"Fremdkapital-Schutz: Risiko ${risk:.0f} größer als erlaubter Spielraum (${c['can_lose'] - ch['guard_buffer']:.0f})"
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
            "bar_time": sig.get("bar_time"), "mgmt": sig.get("mgmt"), "best": round_tick(fill, tick)})
        self.db.update_signal(sig["id"], status="ausgeführt", reason="")
        self.db.log(f"{sig['side'].upper()} {sig['qty']}× {root} gefüllt @ {fill:.2f} · Stop {sig['sl']:.2f} · "
                    + (f"Ziel {sig['tp']:.2f}" if sig["tp"] else f"ohne festes Ziel ({sig.get('mgmt')})"))
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
            guard = self._guards(fam, sig.get("risk_usd"))
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

    def last_price(self, fam):
        """Aktuellster Kurs: Live-Kurs aus TradingView, sonst Schluss der letzten Kerze."""
        bar, tick = self.last_bar.get(fam), self.last_tick.get(fam)
        if tick and (not bar or tick["ts"] >= bar["ts"]):
            return tick["price"], tick["ts"]
        return (bar["close"], bar["ts"]) if bar else (None, None)

    def _unrealized(self, pos):
        price, _ = self.last_price(family(pos["root"]))
        if price is None:
            return 0.0
        d = 1 if pos["side"] == "long" else -1
        return (price - pos["entry"]) * d * pos["qty"] * INSTR[pos["root"]]["pv"]

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

    def modify_position(self, pid, sl=None, tp=None, clear_tp=False):
        """Stop und/oder Ziel einer offenen Position verschieben. Der Stop bleibt immer bestehen."""
        with self.lock:
            pos = self.db.position(pid)
            if not pos or pos["status"] != "offen":
                raise ValueError("Position ist nicht mehr offen")
            tick = INSTR[pos["root"]]["tick"]
            long_ = pos["side"] == "long"
            last = self.last_price(family(pos["root"]))[0] or pos["entry"]
            upd, msgs = {}, []
            if sl is not None:
                sl = round_tick(float(sl), tick)
                if (long_ and sl >= last) or (not long_ and sl <= last):
                    raise ValueError(f"Stop muss {'unter' if long_ else 'über'} dem aktuellen Kurs ({last:.2f}) liegen, sonst würde er sofort auslösen")
                mx = float(self.cfg["safe_stop"][family(pos["root"])]["max"])
                if (pos["entry"] - sl if long_ else sl - pos["entry"]) > mx:
                    raise ValueError(f"Safe-Stop: höchstens {mx:g} Punkte vom Einstieg entfernt")
                if sl != pos["sl"]:
                    try:
                        self.broker.modify_stop(pos, sl)
                    except BrokerError as e:
                        raise ValueError(str(e))
                    upd["sl"] = sl
                    msgs.append(f"Stop {pos['sl']:.2f} → {sl:.2f}")
            if clear_tp:
                if self.broker.name != "paper" and pos["broker"] != "paper":
                    raise ValueError("Das Ziel kann beim Broker nicht entfernt werden, nur verschoben")
                upd["tp"] = None
                msgs.append("Ziel entfernt")
            elif tp is not None:
                tp = round_tick(float(tp), tick)
                if (long_ and tp <= last) or (not long_ and tp >= last):
                    raise ValueError(f"Ziel muss {'über' if long_ else 'unter'} dem aktuellen Kurs ({last:.2f}) liegen")
                if tp != pos["tp"]:
                    try:
                        self.broker.modify_target(pos, tp)
                    except BrokerError as e:
                        raise ValueError(str(e))
                    upd["tp"] = tp
                    msgs.append(f"Ziel {(pos['tp'] or 0):.2f} → {tp:.2f}" if pos["tp"] else f"Ziel gesetzt {tp:.2f}")
            if upd:
                self.db.update_position(pid, **upd)
                self.db.log(f"{pos['side'].upper()} {pos['qty']}× {pos['root']}: " + " · ".join(msgs))
            return {"ok": True, "changed": msgs}

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

    @staticmethod
    def _session_end(obj):
        """16:00 NY des Handelstags, an dem das Signal kam (Abend-Signale gehören zum nächsten Tag)."""
        t = ny_time(obj["bar_time"] / 1000) if obj.get("bar_time") else ny_time(obj["opened"])
        day = t.date() if t.time() < dt.time(16) else t.date() + dt.timedelta(days=1)
        while day.weekday() >= 5:
            day += dt.timedelta(days=1)
        return dt.datetime.combine(day, dt.time(16))

    @staticmethod
    def _shadow_session(x):
        try:
            c = json.loads(x.get("ctx") or "{}")
        except ValueError:
            c = {}
        if c.get("session") and c["session"] != "keine":
            return c["session"] if c["session"] in TRADING_SESSIONS else "aus"
        t = ny_time(x["bar_time"] / 1000) if x.get("bar_time") else ny_time(x["opened"])
        return session_of(t)

    def _close_variant(self, v, exit_price):
        d = 1 if v["side"] == "long" else -1
        self.db.update_variant(v["id"], status="geschlossen", closed=time.time(), exit=exit_price,
                               r=round((exit_price - v["entry"]) * d / (v["risk"] or 1e-9), 3))

    def setup_rule(self, setup, sess=None):
        """Status einer Strategie; mit Session: das Schlechtere aus Gesamtbewertung und Bewertung in dieser Session."""
        manual = self.cfg["setup_rules"].get(setup, "auto")
        if manual == "aus":
            return "aus"
        if manual == "an" or not self.cfg["learning"]["enabled"]:
            return "aktiv"
        d = self.learning.get("setups", {}).get(setup) or {}
        st = d.get("status", "lernt")
        if sess:
            ss = ((d.get("sessions") or {}).get(sess) or {}).get("status")
            rank = {"pausiert": 3, "halbe Größe": 2, "aktiv": 1, "lernt": 0}
            if ss and rank.get(ss, 0) > rank.get(st, 0):
                return ss
        return st

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
                # Je Session getrennt bewerten: schwache Sessions werden nur dort gebremst
                sess_rows = {}
                for x in lst[-max(150, int(L["window"]) * 5):]:
                    sess_rows.setdefault(self._shadow_session(x), []).append(x["r"])
                old_ss = (prev.get(name) or {}).get("sessions") or {}
                sessions = {}
                for sk, srs in sess_rows.items():
                    srs = srs[-int(L["window"]):]
                    sn, savg = len(srs), sum(srs) / len(srs)
                    sst = ("lernt" if sn < int(L["min_trades"]) else "pausiert" if savg < float(L["pause_below_r"])
                           else "halbe Größe" if savg < float(L["half_below_r"]) else "aktiv")
                    sessions[sk] = {"n": sn, "avg_r": round(savg, 3), "status": sst,
                                    "winrate": round(sum(1 for r in srs if r > 0) / sn * 100, 1)}
                    o_ss = (old_ss.get(sk) or {}).get("status")
                    if o_ss and o_ss != sst and sst != "lernt":
                        msg = f"{name} in {SESSION_NAMES.get(sk, sk)}: {o_ss} → {sst} (Ø {savg:+.2f} R aus {sn} Trades)"
                        insights.append({"kind": "change", "text": msg})
                        self.db.log("Lernmodul: " + msg, "warn" if sst in ("pausiert", "halbe Größe") else "info")
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
                setups[name] = {"sessions": sessions, "status": status, "n": n, "total": len(lst), "avg_r": round(avg, 3),
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
                for v in self.db.open_variants():
                    last = (self.last_bar.get(v["fam"]) or {}).get("close")
                    if last:
                        self._close_variant(v, last)
                self.learn()
                self.db.log("Lernmodul: Tagesauswertung abgeschlossen")
                self.db.prune_bars((now - 420 * 86400) * 1000)   # Kerzen älter als ~14 Monate löschen
                self.db.prune_bars1((now - 20 * 86400) * 1000)   # 1-Minuten-Kerzen: 20 Tage reichen für den Chart
            nw = self.cfg["news"]
            if nw["enabled"] and nw["close_before"] and self.db.open_positions():
                for e in self.news_window():
                    t = e["ts"] / 1000
                    key = f"{e['title']}{e['ts']}"
                    # 1 Minute vor dem Termin (bzw. sofort, wenn die Pause schon läuft) offene Positionen schließen
                    if key not in self._news_closed and time.time() >= min(t - 60, e["start"]) and time.time() <= e["end"]:
                        self._news_closed.add(key)
                        for pos in self.db.open_positions():
                            try:
                                self._close(pos, None, f"News: {e['title']}")
                            except ValueError:
                                pass
                        self.db.log(f"Vor News geschlossen: {e['title']} um {ny_time(t).strftime('%H:%M')} NY", "warn")
            if r["flat_at_session_end"] and self.db.open_positions():
                for pos in self.db.open_positions():
                    o = ny_time(pos["opened"])
                    # schließen, sobald keine angehakte Session mehr läuft (wie in der TradingView-Strategie)
                    started_in = next((k for k in TRADING_SESSIONS if in_session(k, o)), None) or \
                        ("ganztags" if r.get("all_day") else None)
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

    # ───────── Key Levels & Session-Muster ─────────
    def _bars_ny(self, fam, days):
        rows = self.db.bars(fam, (time.time() - days * 86400) * 1000)
        for x in rows:
            x["ny"] = _ny_dt(x["t"])
        return rows

    def levels(self, fam=None):
        fams = self.db.bar_fams()
        fam = fam if fam in fams else (fams[0] if fams else None)
        if not fam:
            return {"fams": [], "fam": None, "today": None, "price": None}
        bars = self._bars_ny(fam, 6)
        now = ny_time()
        day = now.date()
        if now.weekday() >= 5 or now.time() >= dt.time(18):   # ab 18 Uhr NY gehört alles zum nächsten Handelstag
            day = day + dt.timedelta(days=1)
            while day.weekday() >= 5:
                day += dt.timedelta(days=1)
        lb = self.last_bar.get(fam)
        price = lb["close"] if lb else (bars[-1]["c"] if bars else None)
        return {"fams": fams, "fam": fam, "today": summarize_day(bars, day), "price": price,
                "bars": len(bars), "now_ny": now.strftime("%H:%M")}

    def session_stats(self, fam=None, days=400):
        fams = self.db.bar_fams()
        fam = fam if fam in fams else (fams[0] if fams else None)
        if not fam:
            return {"fams": [], "fam": None, "days": []}
        bars = self._bars_ny(fam, days)
        cache = getattr(self, "_sum_cache", {})
        today = ny_date()
        days_ = sorted({x["ny"].date() for x in bars if x["ny"].weekday() < 5 and x["ny"].date() < today
                        and dt.time(9, 30) <= x["ny"].time() < dt.time(16)})
        out, ts = [], [x["t"] for x in bars]
        for d in days_:
            key = (fam, d)
            if key not in cache:
                mid = dt.datetime(d.year, d.month, d.day, tzinfo=dt.timezone.utc).timestamp() * 1000
                part = bars[bisect.bisect_left(ts, mid - 6 * 864e5):bisect.bisect_right(ts, mid + 2 * 864e5)]
                cache[key] = summarize_day(part, d)
            if cache[key]["rth_done"]:
                out.append({"day": str(d), "events": cache[key]["events"]})
        self._sum_cache = cache
        return {"fams": fams, "fam": fam, "days": out}

    @staticmethod
    def _agg(rows, tf_ms):
        out = []
        for t, o, h, l, c in rows:
            b = t - t % tf_ms
            if out and out[-1][0] == b:
                x = out[-1]
                x[2], x[3], x[4] = max(x[2], h), min(x[3], l), c
            else:
                out.append([b, o, h, l, c])
        return out

    @staticmethod
    def _tf_of(rows):
        diffs = sorted(b[0] - a[0] for a, b in zip(rows, rows[1:]) if b[0] > a[0])
        return diffs[len(diffs) // 4] if diffs else None   # unteres Quartil: Lücken (Nacht, Wochenende) verfälschen nicht

    def chart_data(self, fam=None, days=2, tf_min=5):
        """Kerzen + Trades für den Live-Chart im Cockpit."""
        fams = self.db.bar_fams()
        fam = fam if fam in fams else (fams[0] if fams else None)
        if not fam:
            return {"fams": [], "fam": None, "bars": []}
        last = self.db.one("SELECT MAX(t) t FROM bars WHERE fam=?", (fam,))
        anchor = min(time.time(), (last["t"] or 0) / 1000 + 3600) if last and last["t"] else time.time()
        since = anchor - days * 86400   # am Wochenende/abends: ab der letzten Kerze zurückrechnen, damit der Chart nicht leer ist
        raw = [[x["t"], x["o"], x["h"], x["l"], x["c"]] for x in self.db.bars(fam, since * 1000)]
        src_tf = self.chart_tf.get(fam) or self._tf_of(raw) or 300000
        want = int(tf_min) * 60000
        note = None
        if want >= src_tf * 0.9 or not raw:
            bars = self._agg(raw, want) if want > src_tf * 1.1 else raw
        else:
            m1 = [[x["t"], x["o"], x["h"], x["l"], x["c"]] for x in self.db.bars1(fam, since * 1000)]
            if m1:
                bars = self._agg(m1, want)
            else:
                bars = raw
                note = f"TradingView schickt {round(src_tf / 60000)}-Minuten-Kerzen. 1-Minuten-Kerzen kommen mit dem neuen Script (Einstellungen → TradingView → Strategie-Script kopieren)."
        tf = want if not note else src_tf
        trades = []
        for p in self.db.rows("SELECT * FROM positions WHERE (closed IS NULL OR closed >= ?) OR status='offen'", (since,)):
            if family(p["root"]) != fam or p["broker"] not in (self.broker.name, "eigen"):
                continue
            if p["broker"] == "eigen" and (not p["opened"] or p["opened"] == p["closed"] or not p["entry"]):
                continue   # eigene Trades ohne Uhrzeit/Preis lassen sich nicht einzeichnen
            t_in, t_out = p["opened"], p["closed"]
            ctf = (self.chart_tf.get(fam) or 0) / 1000
            if p.get("bar_time") and abs(p["bar_time"] / 1000 + ctf - p["opened"]) < 86400:
                t_in = p["bar_time"] / 1000 + ctf          # Einstieg zum Schluss der Signal-Kerze
            if p.get("exit_bar"):
                t_out = p["exit_bar"] / 1000
            trades.append({k: p.get(k) for k in ("id", "side", "qty", "root", "entry", "exit", "sl", "tp", "initial_sl",
                                                 "opened", "closed", "pnl", "status", "setup", "is_test", "mgmt")}
                          | {"source": "eigen" if p["broker"] == "eigen" else "bot", "t_in": t_in, "t_out": t_out})
        px_now = (self.last_bar.get(fam) or {}).get("close") or (bars[-1][4] if bars else None)
        for t in trades:
            if t["status"] == "offen" and px_now is not None and t["entry"] is not None:
                d = 1 if t["side"] == "long" else -1
                t["upnl"] = round((px_now - t["entry"]) * d * t["qty"] * INSTR[t["root"]]["pv"], 2)
        pending = [{k: s_.get(k) for k in ("id", "side", "entry", "sl", "tp", "qty", "root", "setup", "ts")}
                   for s_ in self.db.pending() if family(s_["root"]) == fam]
        lv = self.levels(fam).get("today") or {}
        keys = (("pdh", "PDH"), ("pdl", "PDL"), ("pdc", "PDC"), ("onh", "ONH"), ("onl", "ONL"), ("asia_h", "AH"), ("asia_l", "AL"),
                ("lon_h", "LH"), ("lon_l", "LL"), ("mid_open", "MO"), ("ib_h", "IBH"), ("ib_l", "IBL"))
        levels = [{"k": lab, "v": lv[k]} for k, lab in keys if lv.get(k) is not None]
        return {"fams": fams, "fam": fam, "bars": bars, "tf": tf, "src_tf": src_tf, "note": note, "trades": trades,
                "pending": pending, "levels": levels, "last": (self.last_bar.get(fam) or {}).get("close"),
                "has_m1": bool(self.db.one("SELECT 1 x FROM bars1 WHERE fam=? LIMIT 1", (fam,)))}

    def live_backtest(self):
        """Alle abgeschlossenen Strategie-Signale (Schatten-Trades) als Trade-Liste in $ für 1 Micro-Kontrakt."""
        com = float(self.cfg["paper"]["commission"]) * 2
        out = []
        for x in self.db.rows("SELECT setup, side, fam, entry, exit, opened, bar_time FROM shadow "
                              "WHERE status='geschlossen' AND exit IS NOT NULL ORDER BY opened"):
            micro = INSTR.get(x["fam"], {}).get("micro") or x["fam"]
            pv = INSTR.get(micro, INSTR.get(x["fam"], {"pv": 1}))["pv"]
            d = 1 if x["side"] == "long" else -1
            t = x["bar_time"] if x.get("bar_time") and abs(x["bar_time"] / 1000 - x["opened"]) < 86400 * 400 else x["opened"] * 1000
            out.append({"time": t, "setup": x["setup"], "dir": "Long" if d > 0 else "Short",
                        "pnl": round((x["exit"] - x["entry"]) * d * pv - com, 2)})
        return {"trades": out[-20000:], "micro_note": True}

    def edge_data(self):
        rows = self.db.rows("SELECT setup, side, r, ny_hour, ny_weekday, opened, closed FROM shadow "
                            "WHERE status='geschlossen' AND r IS NOT NULL ORDER BY closed")
        return {"trades": rows[-5000:]}

    # ───────── Lernlabor: Marktlage, Varianten, Regeln ─────────
    def context(self, fam, side, price, now=None):
        """Marktlage beim Signal (für den Regel-Finder). Nur Dinge, die zu diesem Zeitpunkt schon feststehen."""
        t = ny_time(now)
        ctx = {"side": side, "hour": t.hour, "weekday": t.weekday(),
               "session": next((k for k in TRADING_SESSIONS if in_session(k, t)), "keine")}
        bars = [x for x in self._bars_ny(fam, 6) if x["ny"] <= t]
        if not bars or price is None:
            return ctx
        day = t.date() if t.time() < dt.time(18) else t.date() + dt.timedelta(days=1)
        while day.weekday() >= 5:
            day += dt.timedelta(days=1)
        T = summarize_day(bars, day)
        ev, hm = T["events"], t.time()
        if T.get("pdh") is not None:
            ctx["pd"] = "ueber" if price > T["pdh"] else "unter" if price < T["pdl"] else "innen"
        if T.get("onh") is not None and hm >= dt.time(9, 30):
            ctx["on"] = "ueber" if price > T["onh"] else "unter" if price < T["onl"] else "innen"
        if T.get("mid_open") is not None and dt.time(0, 30) <= hm < dt.time(18):
            ctx["mo"] = "ueber" if price >= T["mid_open"] else "unter"
        if T.get("rth_open") is not None and dt.time(9, 35) <= hm < dt.time(18):
            ctx["ro"] = "ueber" if price >= T["rth_open"] else "unter"
            if "gap" in ev:
                ctx["gap"] = ev["gap"]["dir"]
        for k, start in (("asia", dt.time(0)), ("london", dt.time(5)), ("ib", dt.time(10, 30))):
            if start <= hm < dt.time(18) and T.get(f"{k}_done"):
                e = ev.get(k) or {}
                ctx[k] = e.get("first") or "keiner"
        return ctx

    def rule_block(self, setup, ctx):
        for r in self.cfg.get("rule_filters") or []:
            if not r.get("active", True) or r["setup"] not in (setup, "*"):
                continue
            match = all(str(ctx.get(f)) == str(v) for f, v in r["conds"])
            if r["action"] == "avoid" and match:
                return f"Regel-Finder: {setup} meiden, wenn {r['label']}"
            if r["action"] == "only" and not match:
                return f"Regel-Finder: {setup} nur, wenn {r['label']}"
        return None

    def _lab_shadows(self):
        rows = self.db.rows("SELECT id, setup, side, r, ny_hour, ny_weekday, opened, ctx FROM shadow "
                            "WHERE status='geschlossen' AND r IS NOT NULL ORDER BY opened")
        for x in rows:
            try:
                c = json.loads(x["ctx"]) if x["ctx"] else {}
            except ValueError:
                c = {}
            c.setdefault("side", x["side"])
            c.setdefault("hour", x["ny_hour"])
            c.setdefault("weekday", x["ny_weekday"])
            x["c"] = {k: str(v) for k, v in c.items() if v is not None}
        return rows

    def variant_view(self, min_n=20):
        base, by = {}, {}
        for s in self._lab_shadows():
            base.setdefault(s["setup"], []).append((s["opened"], s["r"]))
        for v in self.db.closed_variants():
            by.setdefault(v["setup"], {}).setdefault(v["var"], []).append((v["opened"], v["r"]))
        applied = self.cfg.get("exit_rules") or {}
        out = []
        for setup in sorted(set(base) | set(by)):
            def summ(lst):
                lst = sorted(lst)
                rs = [r for _, r in lst]
                k = int(len(rs) * 0.6)
                return {"n": len(rs), "avg": round(_mean(rs), 3), "wr": round(sum(1 for r in rs if r > 0) / len(rs) * 100, 1) if rs else None,
                        "sum": round(sum(rs), 2), "a1": round(_mean(rs[:k]), 3) if k else None, "a2": round(_mean(rs[k:]), 3) if rs[k:] else None}
            cols = {"Signal-Ziel": summ(base.get(setup, []))}
            for k in VARIANTS:
                cols[k] = summ(by.get(setup, {}).get(k, []))
            cur_key = applied.get(setup) if applied.get(setup) in VARIANTS else "Signal-Ziel"
            cur = cols[cur_key]
            rec = None
            for k, c in cols.items():
                if k == cur_key or c["n"] < min_n or c["a1"] is None or c["a2"] is None or cur["n"] == 0:
                    continue
                if c["avg"] >= cur["avg"] + 0.15 and c["a1"] > (cur["a1"] or 0) and c["a2"] > (cur["a2"] or 0) and c["avg"] > 0:
                    if not rec or c["avg"] > cols[rec]["avg"]:
                        rec = k
            out.append({"setup": setup, "cols": cols, "applied": cur_key, "rec": rec,
                        "paper_only": list(PAPER_ONLY_VARIANTS)})
        return {"setups": out, "variants": ["Signal-Ziel"] + list(VARIANTS), "min_n": min_n,
                "broker": self.broker.name}

    def rules_find(self, min_scope=20, min_n=12):
        rows = self._lab_shadows()
        by = {}
        for x in rows:
            by.setdefault(x["setup"], []).append(x)
        found, watch, tests = [], [], 0
        for setup, lst in sorted(by.items()):
            n = len(lst)
            if n < min_scope:
                continue
            k = int(n * 0.6)
            vals = {}
            for x in lst:
                for f, v in x["c"].items():
                    if f in FEATURES:
                        vals.setdefault((f, v), 0)
                        vals[(f, v)] += 1
            singles = [fv for fv, c in vals.items() if c >= min_n and c <= n - min_n // 2]
            conds = [(a,) for a in singles]
            for i, a in enumerate(singles):
                for b in singles[i + 1:]:
                    if a[0] != b[0]:
                        conds.append((a, b))
            single_eff = {}
            for cond in conds:
                m = [x for x in lst if all(x["c"].get(f) == v for f, v in cond)]
                if len(m) < min_n:
                    continue
                tests += 1
                ids = {x["id"] for x in m}
                rest = [x for x in lst if x["id"] not in ids]
                mi, ri = [x["r"] for x in lst[:k] if x["id"] in ids], [x["r"] for x in lst[:k] if x["id"] not in ids]
                mo, ro = [x["r"] for x in lst[k:] if x["id"] in ids], [x["r"] for x in lst[k:] if x["id"] not in ids]
                ma, ra = [x["r"] for x in m], [x["r"] for x in rest]
                t = _welch_t(ma, ra)
                d_all = _mean(ma) - _mean(ra)
                if len(cond) == 1:
                    single_eff[cond[0]] = d_all
                elif abs(d_all) < max(abs(single_eff.get(c, 0)) for c in cond) + 0.1:
                    continue   # Kombination bringt nichts über die Einzelbedingung hinaus
                d1 = _mean(mi) - _mean(ri) if mi and ri else None
                d2 = _mean(mo) - _mean(ro) if mo and ro else None
                action = "avoid" if d_all < 0 else "only"
                item = {"setup": setup, "conds": [list(c) for c in cond], "action": action,
                        "label": " und ".join(describe_cond(f, v) for f, v in cond),
                        "n": len(m), "n_all": n, "avg_match": round(_mean(ma), 3), "avg_rest": round(_mean(ra), 3),
                        "wr_match": round(sum(1 for r in ma if r > 0) / len(ma) * 100, 1),
                        "d1": round(d1, 3) if d1 is not None else None, "d2": round(d2, 3) if d2 is not None else None,
                        "n_oos": len(mo), "t": round(t, 2),
                        "effect": round(-sum(ma) if action == "avoid" else -sum(ra), 2)}
                ok_oos = d1 is not None and d2 is not None and len(mo) >= 4 and (
                    (action == "avoid" and d1 <= -0.25 and d2 <= -0.15 and _mean(ma) < 0) or
                    (action == "only" and d1 >= 0.25 and d2 >= 0.15 and _mean(ma) > 0.1))
                if ok_oos and abs(t) >= 2.5 and item["effect"] > 0:
                    found.append(item)
                elif abs(t) >= 1.6 and abs(d_all) >= 0.3 and item["effect"] > 0:
                    watch.append(item)
        key = lambda x: -abs(x["t"])  # noqa: E731
        found.sort(key=key)
        watch.sort(key=key)
        seen = {json.dumps([r["setup"], r["conds"], r["action"]]) for r in self.cfg.get("rule_filters") or []}
        for x in found + watch:
            x["applied"] = json.dumps([x["setup"], x["conds"], x["action"]]) in seen
        # Bilanz der übernommenen Regeln seit Übernahme (was sie geblockt hätten)
        active = []
        for r in self.cfg.get("rule_filters") or []:
            lst = [x for x in by.get(r["setup"], []) if x["opened"] >= r.get("added", 0)]
            hit = [x for x in lst if all(x["c"].get(f) == str(v) for f, v in r["conds"])]
            blocked = hit if r["action"] == "avoid" else [x for x in lst if x not in hit]
            active.append(dict(r, since_n=len(lst), blocked_n=len(blocked), blocked_r=round(sum(x["r"] for x in blocked), 2)))
        return {"found": found[:20], "watch": watch[:6], "tests": tests, "signals": len(rows),
                "setups": {s: len(v) for s, v in by.items()}, "min_scope": min_scope, "active": active}

    # ───────── Kalender: Bot-Trades + eigene Trades ─────────
    def _calendar_trades(self, include_tests=False):
        out = []
        for t in self.db.closed_positions():
            if t["broker"] == "eigen":
                t["source"] = "eigen"
            elif t["broker"] == self.broker.name and (include_tests or not t["is_test"]):
                t["source"] = "bot"
            else:
                continue
            t["day"] = t.get("trade_day") or str(ny_date(t["closed"]))
            out.append(t)
        return out

    def challenge(self):
        """Live-Stand der Fremdkapital-Challenge: Verlustgrenze (EOD/Intraday/statisch), Ziel, Tageslimit, Konsistenz."""
        ch = self.cfg["challenge"]
        start, dd = float(ch["start_balance"]), float(ch["max_dd"])
        today = str(ny_date())
        trades = [t for t in self._calendar_trades()
                  if (ch["source"] == "alle" or t["source"] == ch["source"]) and (not ch["start_day"] or t["day"] >= ch["start_day"])]
        trades.sort(key=lambda t: (t["day"], t["closed"] or 0))
        upnl = 0.0
        if ch["source"] != "eigen":
            upnl = sum(self._unrealized(p) for p in self.db.open_positions()
                       if p["broker"] == self.broker.name and not p["is_test"])

        def thr(hwm):
            if ch["dd_type"] == "static":
                return start - dd
            v = hwm - dd
            return min(v, start) if ch["lock_at_start"] else v

        bal, hwm, days, by_day = start, start, [], {}
        for t in trades:
            by_day.setdefault(t["day"], []).append(t)
        for d in sorted(by_day):
            pnl = 0.0
            for t in by_day[d]:
                pnl += t["pnl"]
                bal += t["pnl"]
                if ch["dd_type"] == "intraday":
                    hwm = max(hwm, bal)
            if ch["dd_type"] == "eod" and d < today:
                hwm = max(hwm, bal)
            days.append({"day": d, "pnl": round(pnl, 2), "n": len(by_day[d]), "balance": round(bal, 2),
                         "threshold": round(thr(hwm), 2)})
        equity = bal + upnl
        if ch["dd_type"] == "intraday":
            hwm = max(hwm, equity)
        threshold = thr(hwm)
        buffer = equity - threshold
        today_pnl = sum(t["pnl"] for t in by_day.get(today, [])) + upnl
        daily_left = (float(ch["daily_loss"]) + today_pnl) if float(ch["daily_loss"]) > 0 else None
        can_lose = min(buffer, daily_left) if daily_left is not None else buffer
        profit = bal - start
        to_target = max(0.0, float(ch["profit_target"]) - profit)
        win_days = [x["pnl"] for x in days if x["pnl"] > 0]
        best = max(win_days) if win_days else 0.0
        cons = None
        if float(ch["consistency_pct"]) > 0:
            need = best / (float(ch["consistency_pct"]) / 100) if best else 0.0
            share = best / profit * 100 if profit > 0 else None
            cons = {"pct": ch["consistency_pct"], "best": round(best, 2), "share": round(share, 1) if share is not None else None,
                    "ok": profit > 0 and best <= profit * float(ch["consistency_pct"]) / 100 + 1e-9,
                    "need_total": round(need, 2), "extra": round(max(0.0, need - profit), 2)}
        n_days = len(days)
        breached = buffer <= 0
        passed = (not breached and to_target <= 0 and (cons is None or cons["ok"]) and n_days >= int(ch["min_days"] or 0))
        return {
            "enabled": ch["enabled"], "cfg": ch, "start": start, "balance": round(bal, 2), "equity": round(equity, 2),
            "upnl": round(upnl, 2), "profit": round(profit, 2), "threshold": round(threshold, 2), "hwm": round(hwm, 2),
            "locked": ch["dd_type"] != "static" and ch["lock_at_start"] and hwm - dd >= start,
            "buffer": round(buffer, 2), "today_pnl": round(today_pnl, 2),
            "daily_left": round(daily_left, 2) if daily_left is not None else None, "can_lose": round(can_lose, 2),
            "to_target": round(to_target, 2), "consistency": cons, "days_traded": n_days,
            "best_day": round(best, 2), "breached": breached, "passed": passed,
            "daily_hit": daily_left is not None and daily_left <= 0, "days": days[-120:], "n_trades": len(trades),
        }

    def daily(self):
        """P&L je Handelstag, getrennt nach Bot und eigenen Trades."""
        days = {}
        for t in self._calendar_trades(include_tests=True):
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
        return sorted([t for t in self._calendar_trades(include_tests=True) if t["day"] == day], key=lambda t: t["opened"] or t["closed"])

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
        """Löscht einen eigenen Trade oder einen Test-Trade (samt Test-Signal). Echte Bot-Trades bleiben."""
        with self.lock:
            p = self.db.position(pid)
            if not p or not (p["broker"] == "eigen" or p["is_test"]):
                raise ValueError("Nur eigene Trades und Test-Trades können gelöscht werden")
            if p["status"] == "offen" and p["broker"] not in ("paper", "eigen"):
                raise ValueError("Test-Position ist beim Broker noch offen. Bitte zuerst schließen.")
            self.db._exec("DELETE FROM positions WHERE id=?", (pid,))
            if p["is_test"] and p.get("signal_id"):
                self.db._exec("DELETE FROM signals WHERE id=?", (p["signal_id"],))
            return {"ok": True}

    def delete_tests(self):
        """Alle Test-Signale und Test-Trades entfernen (offene Test-Positionen beim Broker bleiben bestehen)."""
        with self.lock:
            keep = [p["id"] for p in self.db.open_positions() if p["is_test"] and p["broker"] != "paper"]
            q = "DELETE FROM positions WHERE is_test=1" + (f" AND id NOT IN ({','.join('?' * len(keep))})" if keep else "")
            n = self.db._exec(q, keep).rowcount
            m = self.db._exec("DELETE FROM signals WHERE is_test=1 AND status != 'ausgeführt'" if keep else
                              "DELETE FROM signals WHERE is_test=1").rowcount
            self.db.log(f"Test-Daten gelöscht: {n} Trades, {m} Signale" + (f" ({len(keep)} offene Broker-Position bleibt)" if keep else ""))
            return {"ok": True, "trades": n, "signals": m, "kept": len(keep)}

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
                p["last"], p["last_ts"] = self.last_price(family(p["root"]))
            r = self.cfg["risk"]
            now_ny = ny_time()
            return {
                "config": self.public_cfg(),
                "instruments": INSTR,
                "now_ny": now_ny.strftime("%H:%M"),
                "session_open": bool(self.session_now(now_ny)),
                "session_name": SESSION_NAMES.get(self.session_now(now_ny), "") if self.session_now(now_ny) else "",
                "session_names": SESSION_NAMES,
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
                "has_tests": bool(self.db.one("SELECT 1 x FROM positions WHERE is_test=1 LIMIT 1")),
                "challenge": self.challenge() if self.cfg["challenge"]["enabled"] else None,
                "news_pause": self.news_block(),
                "news_next": next(({"title": e["title"], "ts": e["ts"], "start": e["start"], "end": e["end"]}
                                   for e in self.news_window() if not e["active"]), None),
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

INDEX_HTML = '<!doctype html>\n<html lang="de">\n<head>\n<meta charset="utf-8">\n<meta name="viewport" content="width=device-width, initial-scale=1">\n<title>FVG Trader</title>\n<link rel="manifest" href="/manifest.webmanifest">\n<meta name="theme-color" content="#070b14">\n<meta name="apple-mobile-web-app-capable" content="yes">\n<meta name="mobile-web-app-capable" content="yes">\n<meta name="apple-mobile-web-app-title" content="FVG Trader">\n<link rel="apple-touch-icon" href="/icon-192.png">\n<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns=\'http://www.w3.org/2000/svg\' viewBox=\'0 0 32 32\'%3E%3Crect width=\'32\' height=\'32\' rx=\'6\' fill=\'%232f5bd3\'/%3E%3Crect x=\'7\' y=\'6\' width=\'5\' height=\'12\' fill=\'white\'/%3E%3Crect x=\'14\' y=\'11\' width=\'5\' height=\'14\' fill=\'white\' opacity=\'.55\'/%3E%3Crect x=\'21\' y=\'15\' width=\'5\' height=\'11\' fill=\'white\'/%3E%3C/svg%3E">\n<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500;600&display=swap">\n<style>\n/* Layout: feste Kopfzeile mit Modus-Schalter & Notaus → Reiter → Cockpit (Vorschläge zuerst, dann Positionen, dann Verlauf) */\n:root{\n  --bg:#070b14; --surface:#0d1424; --raise:#111a2e; --sunk:#0a101d; --line:#1a2540; --line2:#24314f; --fg:#e4e9f2; --muted:#7d8aa5;\n  --accent:#4c8dff; --accent-fg:#fff; --pos:#2fd39a; --neg:#ff5d6c; --warn:#f2b441; --fill:rgba(76,141,255,.13);\n  --pos-bg:rgba(47,211,154,.09); --neg-bg:rgba(255,93,108,.09); --warn-bg:rgba(242,180,65,.12);\n  --f-display:"Inter",system-ui,-apple-system,"Segoe UI",sans-serif;\n  --f-body:"Inter",system-ui,-apple-system,"Segoe UI",sans-serif;\n  --f-mono:"JetBrains Mono","IBM Plex Mono",ui-monospace,Menlo,Consolas,monospace;\n  color-scheme:dark;\n}\nbody{background:radial-gradient(1200px 500px at 50% -200px,rgba(76,141,255,.08),transparent 70%) var(--bg) fixed}\n*{box-sizing:border-box}\n[hidden]{display:none!important}\nhtml,body{margin:0}\nbody{color:var(--fg);font:14px/1.5 var(--f-body);-webkit-font-smoothing:antialiased;font-feature-settings:"cv11","ss01"}\n.wrap{max-width:1200px;margin:0 auto;padding:0 max(16px,env(safe-area-inset-left,0px)) 60px max(16px,env(safe-area-inset-right,0px))}\nbutton{font:inherit;cursor:pointer}\nbutton:focus-visible,input:focus-visible,select:focus-visible{outline:2px solid var(--accent);outline-offset:2px}\ninput,select{font:inherit;color:var(--fg);background:var(--surface);border:1px solid var(--line);border-radius:6px;padding:7px 10px;min-width:0}\ninput[type=number]{font-family:var(--f-mono);font-variant-numeric:tabular-nums}\n.mono{font-family:var(--f-mono);font-variant-numeric:tabular-nums}\n.pos{color:var(--pos)} .neg{color:var(--neg)} .muted{color:var(--muted)}\n\n/* Kopfzeile mit Auswahlleiste oben */\n.top{position:sticky;top:0;z-index:5;background:color-mix(in srgb,var(--surface) 92%,transparent);backdrop-filter:blur(10px);border-bottom:1px solid var(--line)}\n.bar{display:flex;align-items:center;gap:14px;padding-block:10px}\n.brand{font-family:var(--f-display);font-weight:800;font-size:18px;letter-spacing:-.01em;display:flex;align-items:center;gap:9px;flex:none}\n.brand i{display:inline-block;width:24px;height:24px;border-radius:7px;background:linear-gradient(135deg,var(--accent),color-mix(in srgb,var(--accent) 60%,var(--pos)))}\n.nav{display:flex;gap:2px;margin:0 auto;padding:3px;background:var(--sunk);border-radius:12px}\n.nav button{display:flex;align-items:center;gap:8px;padding:8px 14px;border:0;border-radius:9px;background:transparent;color:var(--muted);font:500 14px var(--f-body);white-space:nowrap;transition:background .12s,color .12s}\n.nav button:hover{color:var(--fg)}\n.nav svg{width:18px;height:18px;flex:none;display:block}\n.nav button[aria-current=true]{background:var(--surface);color:var(--accent);font-weight:600;box-shadow:0 1px 2px rgba(0,0,0,.12)}\n.bar-r{display:flex;align-items:center;gap:10px;flex:none}\n.status{display:flex;gap:6px;flex-wrap:wrap;align-items:center;padding-top:14px}\n.status .hint{font-size:11.5px;margin-left:auto}\n.content{min-width:0}\n.nav button em{display:none}\n@media (max-width:1060px){ .nav button span{display:none} .nav button{padding:8px 12px} .nav button[aria-current=true] span{display:inline} }\n@media (max-width:820px){\n  .bar{flex-wrap:wrap;gap:10px 12px}\n  .brand{font-size:16px;margin-right:auto}\n  .nav{order:3;width:100%;display:grid;grid-template-columns:repeat(6,1fr);margin:0}\n  .nav button{flex-direction:column;gap:3px;padding:6px 0;font-size:10.5px}\n  .nav button span,.nav button[aria-current=true] span{display:none}\n  .nav button em{display:inline;font-style:normal;white-space:nowrap}\n  .status .hint{display:none}\n  .kpis{grid-template-columns:repeat(2,minmax(0,1fr))}\n  .kpi .v{font-size:18px}\n  .switch b{display:none}\n}\n.pill{display:inline-flex;align-items:center;gap:6px;font-size:12px;padding:4px 10px;border-radius:999px;border:1px solid var(--line);color:var(--muted);white-space:nowrap}\n.dot{width:8px;height:8px;border-radius:50%;background:var(--muted)}\n.dot.ok{background:var(--pos)} .dot.bad{background:var(--neg)} .dot.warn{background:var(--warn)}\n.switch{display:flex;align-items:center;gap:10px;padding:5px 6px 5px 12px;border:1px solid var(--line);border-radius:999px;background:var(--surface)}\n.switch b{font-weight:600;font-size:13px}\n.tgl{position:relative;width:46px;height:26px;border-radius:999px;border:0;background:var(--line);transition:background .15s}\n.tgl::after{content:"";position:absolute;top:3px;left:3px;width:20px;height:20px;border-radius:50%;background:#fff;transition:transform .15s;box-shadow:0 1px 2px rgba(0,0,0,.25)}\n.tgl[aria-checked=true]{background:var(--pos)} .tgl[aria-checked=true]::after{transform:translateX(20px)}\n.btn{border:1px solid var(--line);background:var(--surface);color:var(--fg);border-radius:6px;padding:7px 12px;font-weight:500}\n.btn.primary{background:var(--accent);border-color:var(--accent);color:var(--accent-fg);font-weight:600}\n.btn.good{background:var(--pos);border-color:var(--pos);color:#fff;font-weight:600}\n.btn.danger{background:var(--neg);border-color:var(--neg);color:#fff;font-weight:600}\n.btn.ghost-danger{color:var(--neg);border-color:var(--neg)}\n.btn:disabled{opacity:.5;cursor:default}\n.banner{margin:12px 0 0;padding:10px 14px;border-radius:6px;background:var(--warn-bg);color:var(--warn);font-weight:500}\n\nmain{display:flex;flex-direction:column;gap:22px;padding-top:22px;padding-bottom:40px}\nh2{font-family:var(--f-display);font-weight:600;font-size:16px;margin:0}\n.section{display:flex;flex-direction:column;gap:10px;min-width:0}\n.section-h{display:flex;align-items:baseline;justify-content:space-between;gap:10px;flex-wrap:wrap}\n.hint{color:var(--muted);font-size:12.5px;margin:0}\n.panel{background:var(--surface);border:1px solid var(--line);border-radius:12px;padding:18px;min-width:0}\n.empty{color:var(--muted);font-size:13px;padding:18px;border:1px dashed var(--line);border-radius:8px;text-align:center}\n\n/* Kennzahlen */\n.kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(118px,1fr));background:var(--surface);border:1px solid var(--line);border-radius:12px;overflow:hidden}\n.kpi{background:var(--surface);padding:12px 14px;display:flex;flex-direction:column;gap:2px;min-width:0;box-shadow:1px 0 0 var(--line),0 1px 0 var(--line)}\n.seg{display:inline-flex;border:1px solid var(--line);border-radius:6px;overflow:hidden;background:var(--surface)}\n.seg button{font:500 13px var(--f-body);background:transparent;color:var(--muted);border:0;border-right:1px solid var(--line);padding:7px 12px;cursor:pointer}\n.seg button:last-child{border-right:0}\n.seg button[aria-pressed="true"]{background:var(--fill);color:var(--accent);font-weight:600}\n.kpi .l{font-size:11px;text-transform:uppercase;letter-spacing:.08em;color:var(--muted)}\n.kpi .v{font-family:var(--f-mono);font-size:20px;font-weight:500;font-variant-numeric:tabular-nums;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\n.meter{height:4px;border-radius:2px;background:var(--sunk);overflow:hidden;margin-top:4px}\n.meter i{display:block;height:100%;background:var(--neg)}\n\n/* Vorschläge */\n.cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(320px,1fr));gap:14px}\n.sug{background:var(--surface);border:1px solid var(--line);border-left:4px solid var(--accent);border-radius:8px;padding:14px 16px;display:flex;flex-direction:column;gap:12px}\n.sug.long{border-left-color:var(--pos)} .sug.short{border-left-color:var(--neg)}\n.sug-h{display:flex;align-items:center;gap:10px;flex-wrap:wrap}\n.side{font-family:var(--f-display);font-weight:800;font-size:18px;letter-spacing:.02em}\n.side.long{color:var(--pos)} .side.short{color:var(--neg)}\n.chip{display:inline-block;font-size:11.5px;padding:2px 7px;border-radius:4px;background:var(--fill);color:var(--accent);font-weight:500;white-space:nowrap}\n.chip.warn{background:var(--warn-bg);color:var(--warn)}\n.chip.good{background:var(--pos-bg);color:var(--pos)}\n.chip.bad{background:var(--neg-bg);color:var(--neg)}\n.chip.mute{background:var(--sunk);color:var(--muted)}\n.timer{margin-left:auto;font-family:var(--f-mono);font-size:12px;color:var(--muted)}\n.lv{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:8px 12px}\n.lv div{display:flex;flex-direction:column;min-width:0}\n.lv span{font-size:11px;color:var(--muted);text-transform:uppercase;letter-spacing:.06em}\n.lv b{font-family:var(--f-mono);font-weight:500;font-size:15px;font-variant-numeric:tabular-nums}\n.edit{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:8px}\n.edit label{display:flex;flex-direction:column;gap:3px;font-size:11px;color:var(--muted);text-transform:uppercase;letter-spacing:.06em}\n.edit input{width:100%}\n.flags{display:flex;gap:6px;flex-wrap:wrap}\n.actions{display:flex;gap:8px}\n.actions .btn{flex:1;padding:9px 12px}\n\n/* Tabellen */\n.scroll{overflow-x:auto}\ntable{width:100%;border-collapse:collapse;font-variant-numeric:tabular-nums}\nth{font-size:11px;text-transform:uppercase;letter-spacing:.07em;color:var(--muted);font-weight:600;text-align:right;padding:7px 8px;border-bottom:1px solid var(--line);white-space:nowrap}\ntd{font-family:var(--f-mono);font-size:12.5px;text-align:right;padding:7px 8px;border-bottom:1px solid var(--line);white-space:nowrap}\ntd.t,th.t{text-align:left;font-family:var(--f-body)}\ntd.wrap{white-space:normal;min-width:260px;font-family:var(--f-body);font-size:12.5px;text-align:left;color:var(--muted)}\ntr:last-child td{border-bottom:0}\n.rowbtns{display:flex;gap:6px;justify-content:flex-end}\n.rowbtns .btn{padding:4px 9px;font-size:12px}\n\n.grid2{display:grid;grid-template-columns:minmax(0,1.4fr) minmax(0,1fr);gap:20px}\n@media (max-width:860px){.grid2{grid-template-columns:1fr}}\n.wizard{list-style:none;margin:12px 0 0;padding:0;display:grid;gap:14px}\n.wizard li{display:grid;grid-template-columns:28px minmax(0,1fr);gap:12px;align-items:start}\n.wizard .num{width:26px;height:26px;border-radius:50%;display:grid;place-items:center;font-weight:600;font-size:13px;background:var(--sunk);color:var(--muted)}\n.wizard li.done .num{background:var(--pos-bg);color:var(--pos)}\n.wizard li.now .num{background:var(--accent);color:var(--accent-fg)}\n.wizard li.done .hint{display:none}\n.feed{display:flex;flex-direction:column;gap:0;max-height:360px;overflow:auto}\n.feed div{display:grid;grid-template-columns:52px 1fr;gap:8px;padding:6px 0;border-bottom:1px solid var(--line);font-size:12.5px}\n.feed time{font-family:var(--f-mono);color:var(--muted);font-size:11.5px}\n.feed .warn{color:var(--warn)} .feed .error{color:var(--neg)}\nsvg{display:block;width:100%;height:auto}\nsvg text{fill:var(--muted);font-family:var(--f-mono);font-size:11px}\n.gl{stroke:var(--line)}\n\n/* Performance & Grafiken */\n.perf{display:flex;flex-direction:column;gap:14px}\n.perf-h{display:flex;justify-content:space-between;align-items:center;gap:10px;flex-wrap:wrap}\n.perf-ctl{display:flex;gap:8px;flex-wrap:wrap}\n.perf-b{display:grid;grid-template-columns:auto minmax(0,1fr);gap:24px;align-items:center}\n.ring{position:relative;width:170px;height:170px;flex:none}\n.ring svg{display:block}\n.ring-c{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center}\n.ring-v{font-family:var(--f-mono);font-size:22px;font-weight:600;font-variant-numeric:tabular-nums}\n.ring-l{font-size:12px;color:var(--muted)}\n.perf-side{display:flex;flex-direction:column;gap:12px;min-width:0}\n.perf-stats{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:10px}\n.perf-stats div{display:flex;flex-direction:column;gap:2px;padding:10px 12px;border-radius:8px;background:var(--sunk);min-width:0}\n.perf-stats span{font-size:11px;text-transform:uppercase;letter-spacing:.07em;color:var(--muted)}\n.perf-stats b{font-family:var(--f-mono);font-size:17px;font-weight:500;white-space:nowrap}\n.spark{border-radius:8px;background:var(--sunk);padding:6px}\n.spark svg{width:100%;display:block}\n.hbars{display:flex;flex-direction:column;gap:10px}\n.hbar{display:grid;grid-template-columns:minmax(0,1.2fr) minmax(0,1fr) auto;gap:12px;align-items:center}\n.hbar-l{display:flex;flex-direction:column;gap:2px;min-width:0}\n.hbar-l .hint{font-size:11.5px}\n.hbar-t{position:relative;height:10px;border-radius:5px;background:var(--sunk);overflow:hidden}\n.hbar-mid{position:absolute;left:50%;top:0;bottom:0;width:1px;background:var(--line)}\n.hbar-t i{position:absolute;top:0;bottom:0;border-radius:5px}\n.hbar-t i.p{left:50%;background:var(--pos)} .hbar-t i.n{right:50%;background:var(--neg)}\n.hbar b{font-size:13px;text-align:right;min-width:70px}\n.panel{box-shadow:0 1px 2px rgba(10,15,30,.04)}\n@media (max-width:720px){ .perf-b{grid-template-columns:1fr;justify-items:center} .perf-side{width:100%} .perf-stats{grid-template-columns:repeat(2,minmax(0,1fr))} }\n\n.sess-list{display:flex;flex-direction:column;gap:6px}\n.sess{display:grid;grid-template-columns:20px minmax(0,1fr) auto auto;gap:10px;align-items:center;padding:9px 12px;border:1px solid var(--line);border-radius:8px;cursor:pointer}\n.sess.on,.sess:has(input:checked){border-color:var(--accent);background:var(--fill)}\n.sess-n{font-size:13.5px;font-weight:500}\n.sess-t{font-size:12px}\n@media (max-width:560px){ .sess{grid-template-columns:20px minmax(0,1fr)} .sess-t{grid-column:2} }\n\n/* Kalender */\n.cal-top{display:flex;align-items:center;justify-content:space-between;gap:12px;flex-wrap:wrap}\n.cal-mon{display:flex;align-items:center;gap:6px}\n.cal-mon h2{font-size:22px;font-weight:600;letter-spacing:-.01em;margin:0 8px 0 2px;min-width:0;text-transform:none;color:var(--fg)}\n.cal-mon h2 small{font-weight:400;color:var(--muted);margin-left:6px}\n.ibtn{width:32px;height:32px;display:grid;place-items:center;border:1px solid var(--line);border-radius:8px;background:var(--surface);color:var(--muted);padding:0}\n.ibtn:hover{color:var(--fg);border-color:var(--line2)}\n.ibtn svg{width:16px;height:16px}\n.cal-act{display:flex;gap:8px;align-items:center;flex-wrap:wrap}\n.strip{display:grid;grid-template-columns:1.4fr repeat(4,minmax(0,1fr));background:var(--surface);border:1px solid var(--line);border-radius:12px}\n.strip > div{padding:14px 18px;display:flex;flex-direction:column;gap:4px;min-width:0;border-left:1px solid var(--line)}\n.strip > div:first-child{border-left:0}\n.strip .l{font-size:10.5px;text-transform:uppercase;letter-spacing:.1em;color:var(--muted);font-weight:600}\n.strip .v{font-family:var(--f-mono);font-size:19px;font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\n.strip .big{font-size:28px;font-weight:600;letter-spacing:-.02em}\n.strip .s{font-size:11.5px;color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\n.wl{display:flex;height:5px;border-radius:3px;overflow:hidden;background:var(--sunk);margin-top:3px}\n.wl i{display:block;height:100%}\n@media (max-width:820px){ .strip{grid-template-columns:repeat(2,minmax(0,1fr))} .strip > div{border-left:0;border-top:1px solid var(--line)} .strip > div:first-child{grid-column:1/-1;border-top:0} .strip > div:nth-child(odd):not(:first-child){border-left:1px solid var(--line)} }\n.calbox{background:var(--surface);border:1px solid var(--line);border-radius:12px;padding:6px;overflow:hidden}\n.cal{display:grid;grid-template-columns:repeat(5,minmax(0,1fr)) minmax(0,1.05fr);gap:6px}\n.cal .dow{font-size:10.5px;text-transform:uppercase;letter-spacing:.1em;color:var(--muted);font-weight:600;padding:8px 10px 2px}\n.day{position:relative;min-height:96px;border:1px solid var(--line);border-radius:9px;background:var(--raise);padding:9px 11px;display:flex;flex-direction:column;gap:2px;text-align:left;font:inherit;color:inherit;min-width:0;cursor:pointer;transition:border-color .12s,background .12s,transform .12s}\n.day:hover{border-color:var(--line2);background:color-mix(in srgb,var(--raise) 80%,var(--accent) 6%)}\n.day.win{background:linear-gradient(180deg,rgba(47,211,154,.13),rgba(47,211,154,.04));border-color:rgba(47,211,154,.28)}\n.day.loss{background:linear-gradient(180deg,rgba(255,93,108,.13),rgba(255,93,108,.04));border-color:rgba(255,93,108,.28)}\n.day.win:hover{border-color:rgba(47,211,154,.6)} .day.loss:hover{border-color:rgba(255,93,108,.6)}\n.day.empty{background:transparent}\n.day.out{background:transparent;border-color:transparent;opacity:.35;cursor:default}\n.day.sel{border-color:var(--accent)!important;box-shadow:0 0 0 1px var(--accent),0 6px 20px rgba(76,141,255,.18)}\n.day .dn{font-size:12px;color:var(--muted);font-variant-numeric:tabular-nums;font-weight:500;display:flex;align-items:center;gap:6px}\n.day.today .dn b{background:var(--accent);color:#fff;border-radius:6px;padding:0 6px;font-weight:600}\n.day .dn b{font-weight:500}\n.day .pl{font-family:var(--f-mono);font-size:17px;font-weight:600;font-variant-numeric:tabular-nums;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-top:auto}\n.day .pl .s{display:none}\n.day .meta{font-size:11px;color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;display:flex;gap:4px;align-items:center}\n.dots{display:flex;gap:3px;flex-wrap:wrap;max-width:100%}\n.dots i{width:6px;height:6px;border-radius:2px;background:var(--line2)}\n.dots i.w{background:var(--pos)} .dots i.l{background:var(--neg)}\n.wk{border-radius:9px;border:1px dashed var(--line2);background:transparent;padding:9px 11px;display:flex;flex-direction:column;gap:2px;min-height:96px;min-width:0}\n.wk .dn{font-size:10.5px;text-transform:uppercase;letter-spacing:.1em;color:var(--muted);font-weight:600}\n.wk .pl{font-family:var(--f-mono);font-size:17px;font-weight:600;font-variant-numeric:tabular-nums;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-top:auto}\n.wk .meta{font-size:11px;color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\n.wk .pl .s,.wk .dn .s,.day .meta .s,.wk .meta .s{display:none}\n.daybox{background:var(--surface);border:1px solid var(--line);border-radius:12px;overflow:hidden}\n.daybox-h{display:flex;align-items:center;gap:14px;padding:14px 18px;border-bottom:1px solid var(--line);flex-wrap:wrap}\n.daybox-h h2{font-size:15px;font-weight:600;text-transform:none;letter-spacing:0;color:var(--fg)}\n.daybox-h .v{font-family:var(--f-mono);font-size:18px;font-weight:600}\n.daybox-h .sp{margin-left:auto;display:flex;gap:8px;align-items:center}\n.daybox table{margin:0}\n.daybox .empty{margin:16px;border-color:var(--line2)}\n.legend{display:flex;gap:14px;flex-wrap:wrap;align-items:center;font-size:11.5px;color:var(--muted)}\n.legend span{display:inline-flex;gap:6px;align-items:center}\n.legend i{width:10px;height:10px;border-radius:3px;display:inline-block}\n@media (max-width:640px){\n  .calbox{padding:4px}\n  .cal{gap:3px}\n  .day,.wk{min-height:60px;padding:5px 6px;border-radius:7px}\n  .day .pl,.wk .pl{font-size:10.5px;letter-spacing:-.03em;text-overflow:clip}\n  .day,.wk{padding:5px 4px}\n  .day .pl .f,.wk .pl .f,.wk .dn .f{display:none} .day .pl .s,.wk .pl .s,.wk .dn .s{display:inline}\n  .day .meta,.wk .meta,.dots{display:none}\n  .cal .dow{font-size:9.5px;padding:4px 4px 0}\n  .cal-mon h2{font-size:18px}\n}\n.drw-bg{position:fixed;inset:0;z-index:30;background:rgba(3,6,12,.55);backdrop-filter:blur(2px);display:flex;justify-content:flex-end;animation:fade .15s}\n.drw{width:min(460px,100%);height:100%;background:var(--surface);border-left:1px solid var(--line2);display:flex;flex-direction:column;box-shadow:-20px 0 50px rgba(0,0,0,.4);animation:slide .18s ease-out}\n@keyframes fade{from{opacity:0}} @keyframes slide{from{transform:translateX(30px);opacity:0}}\n.drw .l{font-size:10.5px;text-transform:uppercase;letter-spacing:.1em;color:var(--muted);font-weight:600}\n.drw-h{display:flex;align-items:center;gap:8px;padding:14px 16px;border-bottom:1px solid var(--line)}\n.drw-t{flex:1;min-width:0;text-align:center}\n.drw-t h2{font-size:15px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\n.drw-b{flex:1;overflow:auto;padding:18px;display:flex;flex-direction:column;gap:18px}\n.drw-pl{display:flex;flex-direction:column;gap:2px}\n.drw-pl > b{font-family:var(--f-mono);font-size:34px;font-weight:600;letter-spacing:-.02em}\n.drw-b > *{flex-shrink:0}\n.drw-st{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));border:1px solid var(--line);border-radius:10px;overflow:hidden}\n.drw-st > div{padding:10px 12px;display:flex;flex-direction:column;gap:2px;box-shadow:1px 0 0 var(--line),0 1px 0 var(--line);min-width:0}\n.drw-st b{font-family:var(--f-mono);font-size:15px;font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\n.drw-cv{display:flex;flex-direction:column;gap:6px} .drw-cv svg{width:100%}\n.drw-list{display:flex;flex-direction:column;gap:8px}\n.tr{border:1px solid var(--line);border-left:3px solid var(--line2);border-radius:9px;background:var(--raise);padding:10px 12px;display:flex;flex-direction:column;gap:6px}\n.tr.w{border-left-color:var(--pos)} .tr.lo{border-left-color:var(--neg)}\n.tr-a{display:flex;align-items:center;gap:8px;flex-wrap:wrap}\n.tr-p{margin-left:auto;font-weight:600;font-size:15px}\n.tr-b{display:flex;gap:6px 12px;flex-wrap:wrap;align-items:center;font-size:12px;color:var(--muted)}\n.tr-n{flex:1;min-width:120px}\n.lnk{border:0;background:none;color:var(--neg);font-size:12px;padding:0;margin-left:auto}\n.lnk:hover{text-decoration:underline}\n.drw-f{padding:14px 16px;border-top:1px solid var(--line)} .drw-f .btn{width:100%;padding:10px}\n@media (max-width:640px){ .drw-bg{align-items:flex-end} .drw{height:88vh;border-left:0;border-top:1px solid var(--line2);border-radius:16px 16px 0 0;animation:up .2s ease-out} @keyframes up{from{transform:translateY(40px);opacity:0}} }\n.nw-ctl{display:flex;gap:6px;flex-wrap:wrap}\n.nw-box{padding:6px 0;display:flex;flex-direction:column}\n.nw{display:grid;grid-template-columns:52px 26px minmax(0,1fr) auto;grid-template-areas:"t i n c" ". . v v";gap:2px 10px;align-items:center;padding:9px 16px;border-top:1px solid var(--line)}\n.nw-t{grid-area:t} .nw .imp{grid-area:i} .nw-n{grid-area:n} .nw-c{grid-area:c} .nw-v{grid-area:v;white-space:normal!important}\n.nw-box > .nw:first-child,.nw-day + .nw,.nw-alert + .nw{border-top:0}\n.nw.past{opacity:.45}\n.nw.next{background:var(--fill)}\n.nw.live{background:var(--neg-bg)}\n.nw-t{font-size:13px;color:var(--muted)}\n.nw-n{min-width:0;font-size:13.5px}\n.nw-n b{font-weight:500}\n.nw-v{font-size:12px;color:var(--muted);white-space:nowrap}\n.nw-c{text-align:right}\n.nw-day{font-size:10.5px;text-transform:uppercase;letter-spacing:.1em;color:var(--muted);font-weight:600;padding:12px 18px 6px;border-top:1px solid var(--line)}\n.nw-box > .nw-day:first-child{border-top:0}\n.imp{display:inline-flex;gap:2px} .imp i{width:5px;height:12px;border-radius:2px;background:var(--line2)}\n.imp.low i:first-child{background:var(--warn)}\n.imp.medium i:nth-child(-n+2){background:#f2913a}\n.imp.high i,.imp.holiday i{background:var(--neg)} .imp.holiday i{background:var(--muted)}\n.nw-alert{margin:6px 12px 8px;padding:10px 12px;border-radius:9px;background:var(--neg-bg);border:1px solid rgba(255,93,108,.3);font-size:13px;display:flex;gap:8px;align-items:center;flex-wrap:wrap}\n.nw-f{display:flex;justify-content:space-between;gap:10px;align-items:center;padding:10px 18px 6px;border-top:1px solid var(--line);flex-wrap:wrap}\n.news-pill{color:var(--neg)!important;border-color:rgba(255,93,108,.4)!important}\n@media (max-width:700px){ .nw{grid-template-columns:46px 22px minmax(0,1fr) auto;padding:9px 12px} .nw-t{font-size:12px} }\n.subtabs{display:flex;gap:4px;border-bottom:1px solid var(--line);margin-bottom:-6px}\n.subtabs button{border:0;background:none;color:var(--muted);font:500 14px var(--f-body);padding:10px 14px;border-bottom:2px solid transparent;margin-bottom:-1px}\n.subtabs button:hover{color:var(--fg)}\n.subtabs button[aria-selected=true]{color:var(--fg);border-bottom-color:var(--accent);font-weight:600}\n.ed-top{display:flex;justify-content:space-between;align-items:flex-start;gap:14px;flex-wrap:wrap}\n.ed-k{display:grid;grid-template-columns:repeat(4,minmax(120px,auto));gap:0;border:1px solid var(--line);border-radius:10px;overflow:hidden;flex:1;max-width:900px}\n.ed-k > div{padding:12px 16px;display:flex;flex-direction:column;gap:2px;border-left:1px solid var(--line);min-width:0}\n.ed-k > div:first-child{border-left:0}\n.ed-k .l,.ed-x .l,.mu .l{font-size:10.5px;text-transform:uppercase;letter-spacing:.1em;color:var(--muted);font-weight:600}\n.ed-k b{font-family:var(--f-mono);font-size:21px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\n.ed-k small{font-size:11.5px;color:var(--muted)}\n.ed-help{margin:12px 0 4px;line-height:1.6}\n.edge,.muster{display:flex;flex-direction:column;gap:6px}\n.ed-t td,.ed-t th{vertical-align:middle}\n.ed-t td small{display:block;font-size:11px}\n.ed-r{cursor:pointer} .ed-r:hover td{background:var(--raise)} .ed-r.open td{background:var(--raise)}\n.ed-r .chev{color:var(--muted);display:inline-block;transition:transform .15s} .ed-r.open .chev{transform:rotate(180deg)}\n.ci-w{display:grid;grid-template-columns:52px 110px auto;gap:8px;align-items:center}\n.ci{position:relative;height:8px;border-radius:4px;background:var(--sunk)}\n.ci-r{position:absolute;top:0;bottom:0;background:color-mix(in srgb,var(--accent) 35%,transparent);border-radius:4px}\n.ci-b{position:absolute;top:-3px;bottom:-3px;width:2px;background:var(--muted);border-radius:1px}\n.ci-p{position:absolute;top:-2px;width:3px;height:12px;background:var(--fg);border-radius:1px;transform:translateX(-1px)}\n.grade{display:inline-grid;place-items:center;width:22px;height:22px;border-radius:6px;font:700 12px var(--f-body)}\n.gA{background:var(--fill);color:var(--accent)} .gB{background:rgba(76,141,255,.08);color:#8fb6ff} .gC{background:var(--warn-bg);color:var(--warn)} .gD{background:var(--neg-bg);color:var(--neg)} .g–{color:var(--muted)}\n.spk{width:80px;height:24px;display:block}\n.trust{font-family:var(--f-mono);font-size:15px}\n.ed-d td{padding:0!important;background:var(--sunk)}\n.ed-x{display:grid;grid-template-columns:minmax(0,1.1fr) minmax(0,1fr);gap:12px;padding:14px;white-space:normal;text-align:left;font-family:var(--f-body)}\n.ed-card{border:1px solid var(--line);border-radius:10px;background:var(--surface);padding:12px 14px;display:flex;flex-direction:column;gap:8px;min-width:0}\n.ed-wide{grid-column:1/-1}\n.grid-wl{display:grid;grid-template-columns:repeat(auto-fill,11px);gap:3px}\n.grid-wl i{width:11px;height:11px;border-radius:2px;background:var(--neg)} .grid-wl i.w{background:var(--pos)}\n.ed-mini{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:6px}\n.ed-mini div{display:flex;flex-direction:column;gap:1px} .ed-mini b{font-family:var(--f-mono);font-size:14px}\n.dirrow{display:grid;grid-template-columns:48px minmax(0,1fr) 60px 36px;gap:8px;align-items:center;font-size:12.5px}\n.dirrow .dbar{position:relative;height:8px;border-radius:4px;background:var(--sunk)} .dirrow .dbar i{display:block;height:100%;border-radius:4px;background:var(--accent)}\n.dirrow .dbar b{position:absolute;top:-3px;bottom:-3px;width:2px;background:var(--muted)}\n.wd,.hrs{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:4px}\n.hrs{grid-template-columns:repeat(auto-fill,minmax(44px,1fr))}\n.wd div,.hrs div{border-radius:7px;padding:6px 4px;text-align:center;background:var(--raise);border:1px solid var(--line);display:flex;flex-direction:column;gap:1px;font-size:11px;color:var(--muted)}\n.wd div.ok{background:var(--fill);color:#8fb6ff} .wd div.bad{background:var(--neg-bg)}\n.wd b,.hrs b{font-family:var(--f-mono);font-size:12.5px;color:var(--fg)} .wd small{font-size:10px}\n.recent{display:flex;gap:6px;flex-wrap:wrap}\n.recent span{font-size:11.5px;padding:3px 8px;border-radius:6px;border:1px solid var(--line);background:var(--raise);color:var(--muted)}\n.recent span.w{border-color:rgba(47,211,154,.35)} .recent span.w b{color:var(--pos)} .recent span.x{border-color:rgba(255,93,108,.35)} .recent span.x b{color:var(--neg)}\n.mu{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px;margin-top:8px}\n.mu-c{border:1px solid var(--line);border-radius:10px;background:var(--raise);padding:14px 16px;display:flex;flex-direction:column;gap:10px;min-width:0}\n.mu-w{grid-column:1/-1}\n.mu-h{display:flex;flex-direction:column;gap:1px}\n.mu-g{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px 14px}\n.mu-g > div{display:flex;flex-direction:column;gap:1px} .mu-g b{font-size:18px} .mu-g small{font-size:11px}\n.pbar{display:flex;height:8px;border-radius:4px;overflow:hidden;background:var(--sunk)} .pbar i{display:block;height:100%}\n.hist{display:grid;grid-template-columns:repeat(7,minmax(0,1fr));gap:8px;align-items:end}\n.hist > div{display:flex;flex-direction:column;align-items:center;gap:4px;font-size:11px;color:var(--muted)}\n.hb{height:90px;width:100%;display:flex;gap:3px;align-items:flex-end;justify-content:center}\n.hb i{width:40%;max-width:22px;border-radius:3px 3px 0 0;min-height:2px} .hb i.p{background:var(--pos)} .hb i.n{background:var(--neg)}\n.ck-2{align-items:start}\n@media (max-width:820px){ .ed-top{flex-direction:column;align-items:stretch} .ed-k{max-width:none} .ed-top .seg{align-self:flex-start} }\n@media (max-width:700px){\n  .ed-t tr > :nth-child(4),.ed-t tr > :nth-child(6),.ed-t tr > :nth-child(7),.ed-t tr > :nth-child(8),.ed-t tr > :nth-child(10){display:none}\n  .edge .scroll{overflow:visible}\n  .ed-t{table-layout:fixed;width:100%}\n  .ed-t th:nth-child(2){width:66px} .ed-t th:nth-child(3){width:40px} .ed-t th:nth-child(5){width:58px} .ed-t th:nth-child(9){width:40px}\n  .ed-t th{font-size:9.5px!important;letter-spacing:.04em!important;overflow:hidden;text-overflow:ellipsis}\n  .ed-t .ci{display:none}\n  .ed-t td:first-child b{display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\n  .ed-d td{width:auto} .ed-x{min-width:0} .ed-mini{grid-template-columns:repeat(2,minmax(0,1fr))}\n  .ed-t .ci-w{display:block} .ed-t .ci-w small{display:none}\n  .ed-t td,.ed-t th{padding-left:6px;padding-right:6px}\n  .ed-t td small{display:none}\n  .ed-d td{display:table-cell!important}\n  .ed-x{padding:10px 6px}\n  .wd{grid-template-columns:repeat(5,minmax(0,1fr))}\n}\n.lv-box{padding:6px 0}\n.lv-tags{display:flex;gap:6px;flex-wrap:wrap;padding:8px 16px 10px}\n.lv-row{display:grid;grid-template-columns:44px minmax(0,1fr) 92px 78px minmax(0,auto);gap:10px;align-items:center;padding:7px 16px;border-top:1px solid var(--line);font-size:13px}\n.lv-list > .lv-row:first-child{border-top:0}\n.lv-k{font:700 11px var(--f-body);letter-spacing:.06em;color:var(--accent)}\n.lv-row.pd .lv-k{color:var(--warn)}\n.lv-n{color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\n.lv-p{text-align:right} .lv-d{text-align:right;font-size:12px}\n.lv-row.now{background:var(--fill);border-top:1px solid color-mix(in srgb,var(--accent) 50%,transparent);border-bottom:1px solid color-mix(in srgb,var(--accent) 50%,transparent)}\n.lv-row.now .lv-k,.lv-row.now .lv-n,.lv-row.now .lv-p{color:var(--accent);font-weight:600}\n.lv-row.now + .lv-row{border-top:0}\n@media (max-width:1060px){ .ck-2{grid-template-columns:1fr} }\n@media (max-width:820px){ .ed-k{grid-template-columns:repeat(2,minmax(0,1fr))} .ed-k > div:nth-child(3){border-left:0} .ed-k > div:nth-child(n+3){border-top:1px solid var(--line)} .ed-x,.mu{grid-template-columns:1fr} .ed-mini{grid-template-columns:repeat(3,minmax(0,1fr))} .mu-w,.ed-wide{grid-column:auto} }\n@media (max-width:560px){ .lv-row{grid-template-columns:38px minmax(0,1fr) 76px 64px;padding:7px 12px} .lv-row > span:last-child{grid-column:2/-1} .lv-row > span:last-child:empty{display:none} }\n.chc{width:100%;text-align:left;font:inherit;color:inherit;background:var(--surface);border:1px solid var(--line);border-radius:12px;padding:14px 18px;display:flex;flex-direction:column;gap:10px;cursor:pointer;transition:border-color .12s}\n.chc:hover{border-color:color-mix(in srgb,var(--accent) 45%,var(--line))}\n.chc-h{display:flex;justify-content:space-between;align-items:center;gap:10px}\n.chc .l,.ch-big .l,.ch-head .l{font-size:10.5px;text-transform:uppercase;letter-spacing:.1em;color:var(--muted);font-weight:600}\n.chc-g{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px}\n.chc-g > div{display:flex;flex-direction:column;gap:1px;min-width:0}\n.chc-g b{font-family:var(--f-mono);font-size:20px;font-weight:600;white-space:nowrap}\n.chc-g small{font-size:11.5px;color:var(--muted)}\n.trk{display:flex;flex-direction:column;gap:6px}\n.trk-b{position:relative;height:10px;border-radius:5px;background:linear-gradient(90deg,rgba(255,93,108,.35),var(--sunk) 30%,var(--sunk) 70%,rgba(47,211,154,.35))}\n.trk.sm .trk-b{height:6px}\n.trk-f{position:absolute;left:0;top:0;bottom:0;border-radius:5px;background:color-mix(in srgb,var(--accent) 45%,transparent)}\n.trk-s{position:absolute;top:-4px;bottom:-4px;width:2px;background:var(--muted)}\n.trk-e{position:absolute;top:50%;width:14px;height:14px;border-radius:50%;background:var(--accent);border:2px solid var(--bg);transform:translate(-50%,-50%);box-shadow:0 0 0 3px rgba(76,141,255,.25)}\n.trk.sm .trk-e{width:11px;height:11px}\n.trk-l{position:relative;display:flex;justify-content:space-between;font-size:11.5px;font-family:var(--f-mono);height:16px}\n.trk-l span:nth-child(2){position:absolute;transform:translateX(-50%);color:var(--muted)}\n.ch-head{display:flex;justify-content:space-between;align-items:flex-end;gap:12px;flex-wrap:wrap}\n.ch-head h2{font-size:24px;font-weight:600;text-transform:none;letter-spacing:-.01em;color:var(--fg)}\n.ch-head h2 small{font-size:15px;color:var(--muted);font-weight:400;margin-left:6px;font-family:var(--f-mono)}\n.ch-hr{display:flex;flex-direction:column;align-items:flex-end;gap:4px}\n.ch-big{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));background:var(--surface);border:1px solid var(--line);border-radius:12px}\n.ch-big > div{padding:16px 18px;display:flex;flex-direction:column;gap:4px;border-left:1px solid var(--line);min-width:0}\n.ch-big > div:first-child{border-left:0}\n.ch-big > div.warn{background:var(--warn-bg);border-radius:12px 0 0 12px}\n.ch-big b{font-family:var(--f-mono);font-size:26px;font-weight:600;letter-spacing:-.02em;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\n.ch-big small{font-size:11.5px;color:var(--muted);line-height:1.4}\n.prog{height:5px;border-radius:3px;background:var(--sunk);overflow:hidden} .prog i{display:block;height:100%;background:var(--pos)}\n.rules{display:flex;flex-direction:column;padding:4px 0}\n.rl{display:grid;grid-template-columns:26px minmax(0,1fr) auto;gap:10px;align-items:center;padding:10px 18px;border-top:1px solid var(--line)}\n.rl:first-child{border-top:0}\n.rl b{font-size:13.5px;font-weight:600;display:block} .rl small{font-size:11.5px;color:var(--muted);display:block;line-height:1.4}\n.rl-i{width:22px;height:22px;border-radius:6px;display:grid;place-items:center;font-size:12px;font-weight:700;background:var(--sunk);color:var(--muted)}\n.rl.ok .rl-i{background:var(--pos-bg);color:var(--pos)} .rl.no .rl-i{background:var(--neg-bg);color:var(--neg)}\n.rl .mono{font-size:14px}\n.ch-form{max-width:none}\n.ch-empty{display:flex;flex-direction:column;gap:8px}\nsvg.chart{width:100%;height:auto}\n@media (max-width:820px){ .ch-big{grid-template-columns:repeat(2,minmax(0,1fr))} .ch-big > div:nth-child(3){border-left:0} .ch-big > div:nth-child(n+3){border-top:1px solid var(--line)} .ch-big b{font-size:21px} .ch-hr{align-items:flex-start} }\n@media (max-width:560px){ .chc-g{grid-template-columns:repeat(2,minmax(0,1fr))} .chc-g > div:last-child{display:none} .chc-g b{font-size:17px} }\n.vt th small{font-size:9.5px;letter-spacing:.04em;text-transform:none;font-weight:400}\n.vt td.vc{text-align:center}\n.vt td.vc b{display:block;font-size:14px}\n.vt td.vc small{display:block;font-size:10.5px;color:var(--muted)}\n.vt td.best{box-shadow:inset 0 0 0 1.5px rgba(47,211,154,.55);border-radius:6px}\n.vt td.cur{background:var(--fill)}\n.vt td.t small{display:block;font-size:11px}\n.vrec{display:flex;flex-direction:column;gap:6px;align-items:flex-start;white-space:normal;min-width:190px;font-family:var(--f-body);font-size:12.5px}\n.lab-h{font-size:10.5px;text-transform:uppercase;letter-spacing:.1em;color:var(--muted);font-weight:600;margin:14px 0 4px}\n.rf-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(330px,1fr));gap:10px}\n.rf{border:1px solid var(--line);border-left:3px solid var(--pos);border-radius:10px;background:var(--raise);padding:12px 14px;display:flex;flex-direction:column;gap:8px}\n.rf.avoid{border-left-color:var(--neg)} .rf.weak{opacity:.75;border-left-color:var(--line2)}\n.rf-h{display:flex;gap:8px;align-items:center;flex-wrap:wrap}\n.rf-l{font-size:15px;font-weight:600}\n.rf-g{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px 14px}\n.rf-g div{display:flex;flex-direction:column;gap:1px;min-width:0} .rf-g .l{font-size:10px;text-transform:uppercase;letter-spacing:.08em;color:var(--muted);font-weight:600}\n.rf-g b{font-family:var(--f-mono);font-size:14px} .rf-g small{font-size:10.5px;color:var(--muted)}\n.rf-act{display:flex;flex-direction:column;gap:6px}\n.rfa{display:grid;grid-template-columns:auto minmax(0,1fr) auto auto;gap:10px;align-items:center;border:1px solid var(--line);border-radius:9px;padding:10px 12px;background:var(--raise);font-size:13px}\n.rfa small{display:block} .rfa.off{opacity:.55}\n@media (max-width:560px){ .rf-g{grid-template-columns:repeat(2,minmax(0,1fr))} .rfa{grid-template-columns:auto minmax(0,1fr)} .rfa .btn{grid-column:auto} .rf-grid{grid-template-columns:1fr} }\n.pcs{display:flex;flex-direction:column;gap:12px}\n.pc{background:var(--surface);border:1px solid var(--line);border-left:4px solid var(--pos);border-radius:12px;padding:14px 18px;display:flex;flex-direction:column;gap:14px}\n.pc.short{border-left-color:var(--neg)}\n.pc-h{display:flex;align-items:center;gap:10px;flex-wrap:wrap}\n.pc-h .side{font-size:15px}\n.pc-pl{margin-left:auto;display:flex;flex-direction:column;align-items:flex-end;gap:1px}\n.pc-pl b{font-size:24px;font-weight:600;letter-spacing:-.02em} .pc-pl small{font-size:12px;color:var(--muted);font-family:var(--f-mono)}\n.pc-bar{display:flex;flex-direction:column;gap:4px}\n.pc-track{position:relative;height:8px;border-radius:4px;background:var(--sunk)}\n.pc-risk{position:absolute;left:0;top:0;bottom:0;background:linear-gradient(90deg,rgba(255,93,108,.55),rgba(255,93,108,.12));border-radius:4px 0 0 4px}\n.pc-rew{position:absolute;top:0;bottom:0;background:linear-gradient(90deg,rgba(47,211,154,.12),rgba(47,211,154,.55));border-radius:0 4px 4px 0}\n.pc-mk{position:absolute;top:50%;transform:translate(-50%,-50%);border-radius:50%}\n.pc-mk.e{width:4px;height:16px;border-radius:2px;background:var(--fg)}\n.pc-mk.n{width:14px;height:14px;background:var(--accent);border:2px solid var(--bg);box-shadow:0 0 0 3px rgba(76,141,255,.3);transition:left .4s}\n.pc-bl{position:relative;display:flex;justify-content:space-between;font-size:11px;color:var(--muted);height:15px}\n.pc-le{position:absolute;transform:translateX(-50%)}\n.pc-g{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));border:1px solid var(--line);border-radius:10px;overflow:hidden}\n.pc-c{padding:10px 14px;display:flex;flex-direction:column;gap:2px;border-left:1px solid var(--line);min-width:0}\n.pc-c:first-child{border-left:0}\n.pc-c.sl{background:rgba(255,93,108,.05)} .pc-c.tp{background:rgba(47,211,154,.05)}\n.pc-c .l{font-size:10.5px;text-transform:uppercase;letter-spacing:.1em;color:var(--muted);font-weight:600}\n.pc-c > b{font-size:18px;font-weight:600}\n.pc-c small{font-size:11.5px;color:var(--muted);line-height:1.45}\n.pc-c small.pos{color:var(--pos)} .pc-c small.neg{color:var(--neg)}\n.pc-a{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr) auto;gap:12px 16px;align-items:start}\n.pc-e{display:flex;flex-direction:column;gap:4px;min-width:0}\n.pc-e label{font-size:10.5px;text-transform:uppercase;letter-spacing:.1em;color:var(--muted);font-weight:600}\n.pc-in{display:flex;gap:4px;flex-wrap:wrap}\n.pc-in input{width:110px;flex:1;min-width:90px}\n.pc-in .btn{padding:6px 10px}\n.pc-q{display:flex;flex-direction:column;gap:6px;align-self:end}\n@media (max-width:1000px){ .pc-a{grid-template-columns:1fr} .pc-q{flex-direction:row;flex-wrap:wrap} }\n@media (max-width:760px){ .pc-g{grid-template-columns:repeat(2,minmax(0,1fr))} .pc-c:nth-child(3){border-left:0} .pc-c:nth-child(n+3){border-top:1px solid var(--line)} .pc{padding:12px} .pc-pl{margin-left:0;width:100%;flex-direction:row;align-items:baseline;gap:8px} }\n.live-dot{display:inline-block;width:7px;height:7px;border-radius:50%;background:var(--pos);margin-right:4px;vertical-align:1px;animation:pulse 1.6s infinite}\n@keyframes pulse{0%{box-shadow:0 0 0 0 rgba(47,211,154,.6)}70%{box-shadow:0 0 0 6px rgba(47,211,154,0)}100%{box-shadow:0 0 0 0 rgba(47,211,154,0)}}\n.ssn{display:flex;gap:4px;flex-wrap:wrap}\n.ssn .chip b{font-weight:600;margin-left:2px}\n.td-g{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:8px 12px;padding:8px 0 2px;border-top:1px solid var(--line)}\n.td-g div{display:flex;flex-direction:column;gap:1px;min-width:0}\n.td-g .l{font-size:10px;text-transform:uppercase;letter-spacing:.08em;color:var(--muted);font-weight:600}\n.td-g b{font-size:13.5px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\n.td-g small{font-size:11px;color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\n.bt{display:flex;flex-direction:column;gap:10px}\n.bt-drop{border:1.5px dashed var(--line2);border-radius:10px;padding:16px;text-align:center;color:var(--muted);font-size:13px;transition:all .12s}\n.bt-drop.over{border-color:var(--accent);background:var(--fill);color:var(--fg)}\n.bt-seg{flex-wrap:wrap;align-self:flex-start}\n.modal-bg{position:fixed;inset:0;z-index:40;background:rgba(10,12,20,.55);display:grid;place-items:center;padding:16px;overflow:auto}\n.modal{max-width:460px;width:100%;display:flex;flex-direction:column;gap:12px;box-shadow:0 20px 50px rgba(0,0,0,.3)}\n.modal select{width:100%}\n.modal:has(.logbox){max-width:820px}\n.logbox{max-height:min(60vh,520px);overflow:auto;white-space:pre;word-break:normal;margin:0;font-size:11.5px;line-height:1.45}\n\n/* Einstellungen */\n.settings-wrap{max-width:820px;margin:0 auto;display:flex;flex-direction:column;gap:10px;width:100%;padding-top:4px}\n.set-sec{background:var(--surface);border:1px solid var(--line);border-radius:12px;padding:18px 20px;scroll-margin-top:130px;display:flex;flex-direction:column;gap:12px;min-width:0}\n.set-h{display:flex;flex-direction:column;gap:2px}\n.set-h h2{font-size:16px}\n.set-b{display:flex;flex-direction:column;gap:10px;min-width:0}\n.sub{display:flex;flex-direction:column;gap:10px;padding-left:12px;border-left:2px solid var(--line)}\n.form{display:flex;flex-direction:column;gap:12px}\n.row{display:grid;grid-template-columns:minmax(0,1fr) minmax(170px,42%);gap:12px;align-items:center}\n.row[hidden]{display:none}\n.row label{font-size:13.5px}\n.row small{display:block;color:var(--muted);font-size:11.5px;margin-top:1px}\n.row input,.row select{width:100%}\n.row .tgl,.row > .btn,.row .chk{justify-self:end}\n.row input.chk,.chk{width:18px;height:18px;accent-color:var(--accent)}\n.inline{display:flex;gap:8px;align-items:center;justify-content:flex-end;flex-wrap:wrap}\n.inline input[type=time]{width:auto}\n.wrap-gap{justify-content:flex-start}\n.lbl{display:block;font-size:11px;text-transform:uppercase;letter-spacing:.07em;color:var(--muted);font-weight:600;margin:4px 0 4px}\n.preview{display:flex;flex-direction:column;gap:4px;background:var(--sunk);border-radius:8px;padding:10px 12px;font-size:12.5px}\n.preview div{display:flex;gap:6px 14px;flex-wrap:wrap;align-items:baseline}\n.pv{font-family:var(--f-mono);font-size:12px;color:var(--muted)}\n.pv b{color:var(--fg);font-weight:500}\ndetails.set-sec{padding:0;display:block}\ndetails.set-sec > summary{cursor:pointer;list-style:none;display:grid;grid-template-columns:36px minmax(0,1fr) auto 16px;gap:12px;align-items:center;padding:14px 18px;border-radius:12px}\ndetails.set-sec > summary:hover{background:var(--sunk)}\ndetails.set-sec > summary::-webkit-details-marker{display:none}\ndetails.set-sec > summary::after{content:"▾";color:var(--muted);transition:transform .15s;text-align:center}\ndetails.set-sec[open] > summary::after{transform:rotate(180deg)}\ndetails.set-sec[open] > summary{border-bottom:1px solid var(--line);border-radius:12px 12px 0 0}\n.s-ic{width:36px;height:36px;border-radius:10px;background:var(--fill);color:var(--accent);display:grid;place-items:center}\n.s-ic svg{width:19px;height:19px;display:block}\n.s-t{display:flex;flex-direction:column;gap:1px;min-width:0}\n.s-t b{font-size:15px;font-family:var(--f-display)}\n.s-t .hint{font-size:12.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\n.s-chip{display:flex;gap:6px}\ndetails.set-sec > .set-b{padding:16px 20px 20px}\ndetails.set-sec > .set-b > .hint:first-child{margin:0 0 2px}\n@media (max-width:640px){ details.set-sec > summary{grid-template-columns:32px minmax(0,1fr) 16px;padding:12px 14px} .s-chip{display:none} .s-ic{width:32px;height:32px} }\n.savebar{position:sticky;bottom:max(12px,env(safe-area-inset-bottom,0px));margin:14px auto 0;max-width:820px;width:100%;display:flex;gap:10px;align-items:center;justify-content:flex-end;background:var(--surface);border:1px solid var(--accent);border-radius:10px;padding:10px 14px;box-shadow:0 8px 24px rgba(0,0,0,.18);z-index:6}\n.savebar .hint{margin-right:auto}\n@media (max-width:560px){ .row{grid-template-columns:1fr} .row .tgl,.row > .btn,.row .chk{justify-self:start} .inline{justify-content:flex-start} }\n.save{display:flex;gap:10px;align-items:center;justify-content:flex-end}\n.ok-msg{font-size:12.5px;color:var(--pos)} .err-msg{font-size:12.5px;color:var(--neg)}\n.code{font-family:var(--f-mono);font-size:12px;background:var(--sunk);border:1px solid var(--line);border-radius:6px;padding:10px;word-break:break-all;white-space:pre-wrap}\n.copyrow{display:flex;gap:8px;align-items:stretch}\n.copyrow .code{flex:1;min-width:0}\nol.steps{margin:0;padding-left:18px;display:grid;gap:6px;font-size:13px}\n\n/* Login */\n.login{min-height:100vh;display:grid;place-items:center;padding:16px}\n.login form{width:min(360px,100%);display:flex;flex-direction:column;gap:12px;background:var(--surface);border:1px solid var(--line);border-radius:10px;padding:24px}\n.login h1{font-family:var(--f-display);font-weight:800;font-size:24px;margin:0}\n\n.toast{position:fixed;left:50%;bottom:max(20px,env(safe-area-inset-bottom,0px));transform:translateX(-50%);background:var(--fg);color:var(--bg);padding:10px 16px;border-radius:8px;font-size:13px;z-index:20;max-width:calc(100% - 32px)}\n@media (prefers-reduced-motion:reduce){*{transition:none!important}}\n/* Look wie ein Trading-Terminal: Navy, feine Linien, kleine Großbuchstaben-Labels */\n.btn{border-radius:8px;background:var(--raise);border-color:var(--line2);font-size:13px;transition:border-color .12s,background .12s}\n.btn:hover:not(:disabled){border-color:color-mix(in srgb,var(--accent) 45%,var(--line2))}\n.btn.primary{box-shadow:0 4px 14px rgba(76,141,255,.25)}\n.btn.primary:hover:not(:disabled){filter:brightness(1.1)}\n.btn.danger{background:transparent;color:var(--neg);border-color:rgba(255,93,108,.5)}\n.btn.danger:hover{background:var(--neg-bg)!important}\n.btn.ghost-danger{background:transparent;border-color:rgba(255,93,108,.45)}\ninput,select{background:var(--sunk);border-color:var(--line2);border-radius:8px}\n.panel,.kpis,.set-sec{background:var(--surface);border-color:var(--line);border-radius:12px}\n.kpi{background:transparent}\n.kpi .l,.lbl,th{font-size:10.5px!important;letter-spacing:.1em!important;font-weight:600}\n.section > .section-h h2,.section > h2{font-size:11.5px;text-transform:uppercase;letter-spacing:.12em;color:var(--muted);font-weight:600}\n.seg{background:var(--sunk);border-color:var(--line);border-radius:9px;padding:2px}\n.seg button{border-right:0;border-radius:7px;padding:6px 12px;font-size:12.5px}\n.seg button[aria-pressed="true"]{background:var(--raise);color:var(--fg);box-shadow:inset 0 0 0 1px var(--line2)}\n.chip{border-radius:5px;font-size:11px;font-weight:600;letter-spacing:.01em}\n.pill{background:var(--surface)!important;border:1px solid var(--line)!important}\n.switch{background:var(--raise);border-color:var(--line2)}\n.tgl{background:var(--line2)}\n.code{background:var(--sunk)!important;border-color:var(--line)!important}\n.sess{background:var(--raise)}\n::-webkit-scrollbar{width:10px;height:10px} ::-webkit-scrollbar-thumb{background:var(--line2);border-radius:6px;border:2px solid var(--bg)} ::-webkit-scrollbar-track{background:transparent}\n</style>\n</head>\n<body>\n<div id="app"></div>\n<div id="toast" class="toast" hidden></div>\n\n<script>\nconst $ = (s, el = document) => el.querySelector(s);\nconst esc = s => String(s ?? "").replace(/[&<>"\']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",\'"\':"&quot;","\'":"&#39;"}[c]));\nconst usd = v => v == null || !isFinite(v) ? "–" : (v < 0 ? "−$" : "$") + Math.abs(v).toLocaleString("de-DE", {maximumFractionDigits: 0});\nconst usd2 = v => v == null || !isFinite(v) ? "–" : (v < 0 ? "−$" : "$") + Math.abs(v).toLocaleString("de-DE", {minimumFractionDigits: 2, maximumFractionDigits: 2});\nconst px = v => v == null ? "–" : Number(v).toLocaleString("de-DE", {minimumFractionDigits: 2, maximumFractionDigits: 2});\nconst pct = v => v == null || !isFinite(v) ? "–" : v.toFixed(1).replace(".", ",") + " %";\nconst num2 = v => v == null || !isFinite(v) ? "–" : v.toFixed(2).replace(".", ",");\nconst cls = v => v > 0 ? "pos" : v < 0 ? "neg" : "";\nconst tm = ts => new Date(ts * 1000).toLocaleTimeString("de-DE", {hour: "2-digit", minute: "2-digit"});\nconst dtm = ts => new Date(ts * 1000).toLocaleString("de-DE", {day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit"});\n\n// Reiter in der Adresse merken, ohne neue Verlaufseinträge (sonst darf sich das App-Fenster nicht schließen)\nconst setHash = t => { try { history.replaceState(null, "", "#" + t); } catch (e) { location.hash = t; } };\nlet S = null, TAB = "cockpit", pendingKey = "", seenPending = new Set(), firstLoad = true, settingsDirty = false;\n\nasync function api(path, body) {\n  const opt = body === undefined ? {} : {method: "POST", headers: {"Content-Type": "application/json", "X-Requested-With": "fvg"}, body: JSON.stringify(body)};\n  const r = await fetch(path, opt);\n  const j = await r.json().catch(() => ({}));\n  if (r.status === 401 && !path.startsWith("/api/login")) { showLogin(); throw new Error("Bitte anmelden"); }\n  if (!r.ok) throw new Error(j.error || "Fehler " + r.status);\n  return j;\n}\nfunction toast(msg) {\n  const t = $("#toast"); t.textContent = msg; t.hidden = false;\n  clearTimeout(toast._t); toast._t = setTimeout(() => t.hidden = true, 3200);\n}\nasync function act(fn, okMsg) {\n  try { const r = await fn(); if (okMsg) toast(okMsg); await refresh(); return r; }\n  catch (e) { toast(e.message); }\n}\n\nfunction copyText(txt, label) {\n  const fallback = () => { const ta = document.createElement("textarea"); ta.value = txt; document.body.appendChild(ta); ta.select();\n    try { document.execCommand("copy"); toast((label || "Text") + " kopiert"); } catch (e) { toast("Bitte manuell kopieren"); } ta.remove(); };\n  if (navigator.clipboard) navigator.clipboard.writeText(txt).then(() => toast((label || "Text") + " kopiert"), fallback); else fallback();\n}\n\n\nasync function serviceSet(on) {\n  document.body.insertAdjacentHTML("beforeend", `<div id="svcOv" style="position:fixed;inset:0;z-index:50;background:var(--bg);display:grid;place-items:center;padding:16px">\n    <div style="text-align:center;max-width:420px;display:flex;flex-direction:column;gap:10px;align-items:center">\n      <h2 style="font-size:20px" id="svcT2">${on ? "Dienst wird eingerichtet …" : "Dienst wird entfernt …"}</h2>\n      <p class="hint" id="svcMsg" style="margin:0">Bitte die Windows-Rückfrage nach Administratorrechten mit „Ja“ bestätigen.</p><div id="svcAct"></div></div></div>`);\n  const msg = (t, m, close) => { $("#svcT2").textContent = t; $("#svcMsg").innerHTML = m;\n    $("#svcAct").innerHTML = close ? \'<button class="btn" id="svcClose">Schließen</button>\' : ""; if (close) $("#svcClose").onclick = () => { $("#svcOv").remove(); render(true); }; };\n  try { await api("/api/service", {on}); }\n  catch (e) { return msg(on ? "Einrichten fehlgeschlagen" : "Entfernen fehlgeschlagen", esc(e.message), true); }\n  if (!on) { S = await api("/api/state"); return msg("Dienst entfernt", "FVG Trader startet nicht mehr automatisch beim Hochfahren. Die App läuft weiter, bis du sie beendest oder der PC neu startet. Für den Start nach der Anmeldung kannst du „Mit Windows starten“ wieder einschalten.", true); }\n  msg("Dienst eingerichtet", "Der Dienst startet jetzt und übernimmt. Das dauert ein paar Sekunden …");\n  const t0 = Date.now();\n  while (Date.now() - t0 < 90000) {\n    await new Promise(r => setTimeout(r, 2000));\n    try { const v = await fetch("/api/version", {cache: "no-store"}).then(r => r.json()); if (v.service) { location.reload(); return; } } catch (e) { /* Übergabe läuft */ }\n  }\n  msg("Dienst eingerichtet", "Er startet spätestens beim nächsten Hochfahren. Falls die App gerade nicht reagiert: Seite neu laden.", true);\n}\nasync function runUpdate(doIt) {\n  const before = S && S.version;\n  document.body.insertAdjacentHTML("beforeend", `<div id="updOv" style="position:fixed;inset:0;z-index:50;background:var(--bg);display:grid;place-items:center;padding:16px">\n    <div style="text-align:center;max-width:380px;display:flex;flex-direction:column;gap:10px;align-items:center">\n      <h2 style="font-size:20px" id="updT">Update wird geladen …</h2>\n      <p class="hint" id="updMsg" style="margin:0">Die neue Version wird heruntergeladen und geprüft.</p>\n      <div id="updAct"></div></div></div>`);\n  const msg = (t, m, act) => { $("#updT").textContent = t; $("#updMsg").innerHTML = m; $("#updAct").innerHTML = act || ""; };\n  let res;\n  try { res = await doIt(); } catch (e) {\n    msg("Update fehlgeschlagen", esc(e.message), \'<button class="btn" id="updClose">Schließen</button>\');\n    $("#updClose").onclick = () => $("#updOv").remove(); return;\n  }\n  const target = res && res.version;\n  msg("Neustart …", `Version <b>${esc(target || "neu")}</b> ist installiert. FVG Trader startet neu, das dauert ein paar Sekunden.`);\n  const t0 = Date.now();\n  let kills = 0;\n  const poll = async () => {\n    const secs = (Date.now() - t0) / 1000;\n    try {\n      const r = await fetch("/api/state", {cache: "no-store"});\n      if (r.status === 401) { location.reload(); return; }\n      if (r.ok) {\n        const j = await r.json();\n        if (j.version !== before) { location.reload(); return; }\n        if (secs > 12 && kills < 5) {   // eine alte Instanz antwortet noch: beenden, die neue übernimmt\n          kills++;\n          msg("Räume auf …", "Eine ältere FVG-Trader-Instanz läuft noch im Hintergrund und wird beendet.");\n          try { await fetch("/api/shutdown", {method: "POST", headers: {"X-Requested-With": "fvg", "Content-Type": "application/json"}, body: "{}"}); } catch (e) {}\n        }\n      }\n    } catch (e) {}\n    if (secs > 30) {\n      msg("Update installiert ✓", `Version <b>${esc(target || "neu")}</b> ist installiert.<br>Schließ dieses Fenster und starte FVG Trader über das <b>Desktop-Symbol</b>.`,\n        \'<button class="btn" id="updRetry">Erneut verbinden</button>\');\n      $("#updRetry").onclick = () => location.reload(); return;\n    }\n    setTimeout(poll, 1000);\n  };\n  setTimeout(poll, 2000);\n}\nasync function startupUpdatePrompt() {\n  if (!S.config.update_url) return;\n  let u;\n  try { u = await api("/api/update/check", {}); } catch (e) { return; }\n  if (!u.available) return;\n  try { if (sessionStorage.getItem("fvg-upd-asked") === u.version) return; sessionStorage.setItem("fvg-upd-asked", u.version); } catch (e) {}\n  document.body.insertAdjacentHTML("beforeend", `<div id="updAsk" role="dialog" aria-modal="true" aria-labelledby="updAskT"\n    style="position:fixed;inset:0;z-index:40;background:rgba(10,12,20,.55);display:grid;place-items:center;padding:16px">\n    <div class="panel" style="max-width:400px;width:100%;display:flex;flex-direction:column;gap:12px;box-shadow:0 20px 50px rgba(0,0,0,.3)">\n      <h2 id="updAskT" style="font-size:19px">Update verfügbar</h2>\n      <p style="margin:0">Version <b>${esc(u.version)}</b> ist da (installiert: ${esc(S.version)}).${u.notes ? `<br><span class="hint">${esc(u.notes)}</span>` : ""}</p>\n      <p class="hint" style="margin:0">Jetzt aktualisieren? Deine Einstellungen und Trades bleiben erhalten.</p>\n      <div class="actions"><button class="btn primary" id="updYes">Ja, jetzt aktualisieren</button><button class="btn" id="updNo">Nein</button></div>\n    </div></div>`);\n  $("#updYes").focus();\n  $("#updNo").onclick = () => $("#updAsk").remove();\n  $("#updYes").onclick = () => { $("#updAsk").remove(); runUpdate(() => api("/api/update/apply", {})); };\n}\n\n/* ───────── Login ───────── */\nasync function showLogin() {\n  const a = await fetch("/api/auth").then(r => r.json());\n  const setup = !a.has_password;\n  $("#app").innerHTML = `<div class="login"><form id="lf">\n    <h1>FVG Trader</h1>\n    <p class="hint">${setup ? "Lege ein Passwort fest. Es schützt die App, sobald sie über das Internet erreichbar ist." : "Melde dich an, um deinen Bot zu steuern."}</p>\n    <input id="pw" type="password" autocomplete="${setup ? "new-password" : "current-password"}" placeholder="Passwort${setup ? " (mind. 8 Zeichen)" : ""}" required>\n    <button class="btn primary" type="submit">${setup ? "Passwort festlegen" : "Anmelden"}</button>\n    <p id="lerr" class="err-msg" hidden></p></form></div>`;\n  $("#pw").focus();\n  $("#lf").onsubmit = async e => {\n    e.preventDefault();\n    try { await api(setup ? "/api/setup" : "/api/login", {password: $("#pw").value}); start(); }\n    catch (err) { $("#lerr").textContent = err.message; $("#lerr").hidden = false; }\n  };\n}\n\n/* ───────── Gerüst ───────── */\nconst NAV = [\n  ["cockpit", "Cockpit", \'<path d="M4 15a8 8 0 1 1 16 0"/><path d="M12 15l4.5-4.5"/><circle cx="12" cy="15" r="1.2"/>\'],\n  ["calendar", "Kalender", \'<rect x="4" y="5" width="16" height="15" rx="2.5"/><path d="M4 10h16M9 3v4M15 3v4"/>\'],\n  ["stats", "Statistik", \'<path d="M5 19v-7M12 19V5M19 19v-10"/>\'],\n  ["challenge", "Fremdkapital", \'<path d="M3 8.5 12 4l9 4.5"/><path d="M5 10v7M9.5 10v7M14.5 10v7M19 10v7M3.5 20h17"/>\'],\n  ["learn", "Lernmodul", \'<path d="M12 3.5l2.3 4.8 5.2.7-3.8 3.7.9 5.2L12 15.4 7.4 17.9l.9-5.2-3.8-3.7 5.2-.7z"/>\'],\n  ["settings", "Einstellungen", \'<circle cx="12" cy="12" r="3"/><path d="M12 3v2.5M12 18.5V21M3 12h2.5M18.5 12H21M5.6 5.6l1.8 1.8M16.6 16.6l1.8 1.8M5.6 18.4l1.8-1.8M16.6 7.4l1.8-1.8"/>\'],\n];\nconst icon = d => `<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${d}</svg>`;\nfunction shell() {\n  $("#app").innerHTML = `\n  <header class="top"><div class="wrap bar">\n    <div class="brand"><i aria-hidden="true"></i>FVG Trader</div>\n    <nav class="nav" aria-label="Bereiche">${NAV.map(([k, l, d]) => `<button type="button" data-tab="${k}" aria-current="${k === TAB}" title="${l}">${icon(d)}<span>${l}</span><em>${{challenge: "Kapital", learn: "Lernen", settings: "Mehr"}[k] || l}</em></button>`).join("")}</nav>\n    <div class="bar-r">\n      <span class="dot" id="pDot" title="TradingView-Verbindung" hidden></span>\n      <div class="switch"><b id="autoLbl">Auto</b><button class="tgl" id="autoT" role="switch" aria-checked="false" aria-labelledby="autoLbl"></button></div>\n      <button class="btn danger" id="kill">Notaus</button>\n    </div>\n  </div></header>\n  <div class="content wrap">\n    <div class="status"><span class="pill" id="pTv"></span><span class="pill" id="pBroker"></span><span class="pill" id="pSess"></span><span class="pill news-pill" id="pNews" hidden></span><span class="hint" id="pVer"></span></div>\n    <div id="banner"></div><main id="main"></main>\n  </div>`;\n  document.querySelectorAll("[data-tab]").forEach(b => b.onclick = () => { if ($("#dayDrw")) closeDay(); TAB = b.dataset.tab; setHash(TAB); pendingKey = ""; settingsDirty = false;\n    window.scrollTo(0, 0); render(true); });\n  $("#autoT").onclick = () => act(() => api("/api/config", {auto_mode: !S.config.auto_mode}),\n    !S.config.auto_mode ? "Auto-Modus an: Signale werden direkt ausgeführt" : "Auto-Modus aus: Signale kommen als Vorschlag");\n  $("#kill").onclick = () => confirmBtn($("#kill"), "Wirklich alles schließen?", () =>\n    act(() => api("/api/flatten", {}), "Alles geschlossen, Handel pausiert"));\n}\nlet ARMED = {key: null, until: 0};\nconst armed = key => ARMED.key === key && Date.now() < ARMED.until;\nfunction confirmBtn(btn, question, fn) {\n  const key = btn.dataset.key || btn.id;\n  if (!btn.dataset.orig) btn.dataset.orig = btn.textContent;\n  if (armed(key)) { ARMED = {key: null, until: 0}; btn.textContent = btn.dataset.orig; fn(); return; }\n  ARMED = {key, until: Date.now() + 4000}; btn.textContent = question;\n  setTimeout(() => { if (ARMED.key === key && Date.now() >= ARMED.until) { ARMED = {key: null, until: 0}; } if (!armed(key) && document.body.contains(btn)) btn.textContent = btn.dataset.orig; }, 4100);\n}\n\nfunction header() {\n  const c = S.config, age = S.tv.last_msg ? (Date.now() / 1000 - S.tv.last_msg) : null;\n  const tvState = age == null ? ["bad", "TradingView: noch kein Signal"] : age < 900 ? ["ok", "TradingView verbunden · " + tm(S.tv.last_msg)] : ["warn", "TradingView: letzte Nachricht " + dtm(S.tv.last_msg)];\n  $("#pTv").innerHTML = `<span class="dot ${tvState[0]}"></span>${tvState[1]}`;\n  $("#pDot").className = "dot " + tvState[0]; $("#pDot").title = tvState[1];\n  $("#pVer").textContent = "Version " + S.version;\n  $("#pBroker").innerHTML = `<span class="dot ${S.broker.ok ? "ok" : "bad"}"></span>${esc(S.broker.label)}${S.broker.name === "tradovate" ? " " + (c.tradovate.env === "live" ? "LIVE" : "Demo") : ""}`;\n  $("#pBroker").title = S.broker.status;\n  $("#pSess").innerHTML = `<span class="dot ${S.session_open ? "ok" : ""}"></span>NY ${S.now_ny} · ${S.session_open ? esc(S.session_name) : "keine Session"}`;\n  $("#autoT").setAttribute("aria-checked", c.auto_mode);\n  $("#banner").innerHTML = c.paused ? `<div class="banner">Handel pausiert. Neue Signale werden blockiert. <button class="btn" id="resume" style="margin-left:8px">Fortsetzen</button></div>`\n    : (S.broker.name === "tradovate" && c.tradovate.env === "live" ? `<div class="banner">LIVE-Konto aktiv: Orders gehen mit echtem Geld an Tradovate.</div>` : "")\n    + (c.hook_confirmed && S.hook_url && !S.hook_confirmed ? `<div class="banner">Deine Webhook-Adresse hat sich nach dem Neustart geändert. Bitte im TradingView-Alert ersetzen:\n        <div class="copyrow" style="margin-top:8px"><div class="code" id="newHook">${esc(S.hook_url)}</div><button class="btn" id="cpNew">Kopieren</button><button class="btn primary" id="okNew">Erledigt</button></div></div>` : "")\n    + (S.remote && S.remote.limit && S.remote.n > S.remote.limit * 0.8 ? `<div class="banner">ngrok-Kontingent fast aufgebraucht: ${S.remote.n.toLocaleString("de-DE")} von ${S.remote.limit.toLocaleString("de-DE")} Anfragen diesen Monat. Ist es leer, kommen keine Signale mehr an. App am Handy seltener offen lassen; mehr dazu unter Einstellungen → TradingView.</div>` : "")\n    + (S.news_pause ? `<div class="banner" style="background:var(--warn-bg);color:var(--fg)"><b style="color:var(--warn)">${esc(S.news_pause)}</b> · In dieser Zeit nimmt der Bot keine neuen Trades.</div>` : "")\n    + (S.alert_issue ? `<div class="banner" style="background:var(--neg-bg);color:var(--fg);border:1px solid rgba(255,93,108,.35)"><b style="color:var(--neg)">TradingView-Alert falsch eingerichtet.</b>\n        Angekommen ist nur der Platzhalter <span class="mono">{{strategy.order.alert_message}}</span> statt der Daten (zuletzt ${tm(S.alert_issue.ts)}). Der Alert hängt am Kurs statt an der Strategie.\n        <ol style="margin:8px 0 0;padding-left:20px;line-height:1.7"><li>Alle bisherigen Alarme für NQ1! löschen.</li><li>Neuen Alarm: bei <b>Bedingung</b> die Strategie <b>„FVG Bot“</b> wählen (nicht „NQ1!“), darunter <b>„Orderausführungen und alert()-Aufrufe“</b>.</li>\n        <li>Nachricht: nur <span class="mono">{{strategy.order.alert_message}}</span>, kein anderer Text.</li><li>Benachrichtigungen → Webhook-URL aus den Einstellungen, Ablauf: unbegrenzt.</li></ol>\n        Richtig eingerichtet zeigt oben „TradingView verbunden“ nach spätestens 5 Minuten (jede Kerze wird geschickt), und dieser Hinweis verschwindet.</div>` : "");\n  if (S.update && S.update.available) {\n    $("#banner").innerHTML += `<div class="banner" style="background:var(--fill);color:var(--fg)">Update verfügbar: Version <b>${esc(S.update.version)}</b>${S.update.notes ? ` · ${esc(S.update.notes)}` : ""}\n      <button class="btn primary" id="updNow" style="margin-left:8px">Jetzt aktualisieren</button></div>`;\n    $("#updNow").onclick = () => runUpdate(() => api("/api/update/apply", {}));\n  }\n  const rs = $("#resume");\n  if ($("#cpNew")) { $("#cpNew").onclick = () => copyText(S.hook_url); $("#okNew").onclick = () => act(() => api("/api/hook-confirm", {}), "Gespeichert"); } if (rs) rs.onclick = () => act(() => api("/api/config", {paused: false}), "Handel fortgesetzt");\n}\n\n/* ───────── Cockpit ───────── */\n\n/* ───────── Wirtschafts-News ───────── */\nconst NEWSD = {events: [], fetched: 0, error: null, loading: false, at: 0};\nconst NV = {range: "heute", imp: "wichtig", usd: true};\ntry { Object.assign(NV, JSON.parse(localStorage.getItem("fvg-news") || "{}")); } catch (e) {}\nasync function loadNews(force) {\n  try {\n    if (force) await api("/api/news/refresh", {});\n    Object.assign(NEWSD, await api("/api/news"), {at: Date.now()});\n  } catch (e) { NEWSD.error = e.message; }\n  if (TAB === "cockpit") newsPanel();\n  newsPill();\n}\nfunction newsFiltered() {\n  const now = new Date(), d0 = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();\n  return NEWSD.events.filter(e => (!NV.usd || e.country === "USD")\n    && (NV.imp === "hoch" ? e.impact === "high" || e.impact === "holiday" : e.impact !== "low")\n    && (NV.range === "heute" ? e.ts >= d0 && e.ts < d0 + 864e5 : true));\n}\nconst inMin = ms => { const m = Math.round(ms / 60000); if (Math.abs(m) < 60) return m >= 0 ? `in ${m} Min` : `vor ${-m} Min`; const h = Math.round(m / 6) / 10; return m >= 0 ? `in ${String(h).replace(".", ",")} Std` : ""; };\nfunction newsPauseChip(e) {\n  const nw = (S && S.config && S.config.news) || {};\n  if (!nw.enabled || (nw.usd_only && e.country !== "USD") || !(e.impact === "high" || (nw.impact === "medium" && e.impact === "medium"))) return "";\n  const f = ms => new Date(ms).toLocaleTimeString("de-DE", {hour: "2-digit", minute: "2-digit"});\n  return ` <span class="chip" title="In dieser Zeit nimmt der Bot keine neuen Trades${nw.close_before ? " und schließt offene Positionen 1 Min vorher" : ""}">Bot-Pause ${f(e.ts - nw.before_min * 60000)}–${f(e.ts + nw.after_min * 60000)}</span>`;\n}\nfunction newsPill() {\n  const el = $("#pNews"); if (!el) return;\n  const now = Date.now(), next = NEWSD.events.find(e => e.country === "USD" && e.impact === "high" && e.ts > now - 5 * 60000 && e.ts < now + 45 * 60000);\n  el.hidden = !next;\n  if (next) el.innerHTML = `<span class="dot bad"></span>${esc(next.title)} ${next.ts > now ? inMin(next.ts - now) : "gerade"}`;\n}\nfunction newsPanel() {\n  const box = $("#newsSec"); if (!box) return;\n  if (!NEWSD.at && !newsPanel._req) { newsPanel._req = true; loadNews(); }\n  const list = newsFiltered(), now = Date.now();\n  const next = list.find(e => e.ts > now);\n  const hm = ts => new Date(ts).toLocaleTimeString("de-DE", {hour: "2-digit", minute: "2-digit"});\n  const dayH = ts => new Date(ts).toLocaleDateString("de-DE", {weekday: "long", day: "numeric", month: "short"});\n  let lastDay = "", rows = "";\n  for (const e of list) {\n    const dk = new Date(e.ts).toDateString();\n    if (NV.range === "woche" && dk !== lastDay) { rows += `<div class="nw-day">${dayH(e.ts)}${dk === new Date().toDateString() ? " · heute" : ""}</div>`; lastDay = dk; }\n    const past = e.ts < now - 5 * 60000, live = Math.abs(e.ts - now) <= 15 * 60000;\n    rows += `<div class="nw ${past ? "past" : ""} ${live ? "live" : ""} ${e === next ? "next" : ""}">\n      <span class="nw-t mono">${e.impact === "holiday" ? "ganztägig" : hm(e.ts)}</span>\n      <span class="imp ${e.impact}" title="${{high: "Hohe", medium: "Mittlere", low: "Geringe", holiday: "Feiertag:"}[e.impact]} Wirkung"><i></i><i></i><i></i></span>\n      <span class="nw-n"><b>${esc(e.title)}</b>${NV.usd ? "" : ` <span class="chip mute">${esc(e.country)}</span>`}${e.impact === "holiday" ? \' <span class="chip warn">Feiertag</span>\' : ""}${newsPauseChip(e)}</span>\n      <span class="nw-v mono">${e.actual ? `<b>${esc(e.actual)}</b> · ` : ""}${e.forecast ? `Prog. ${esc(e.forecast)}` : ""}${e.previous ? `${e.forecast ? " · " : ""}vorher ${esc(e.previous)}` : ""}</span>\n      <span class="nw-c">${live ? \'<span class="chip bad">jetzt</span>\' : past ? "" : e === next ? `<span class="chip">${inMin(e.ts - now)}</span>` : ""}</span>\n    </div>`;\n  }\n  const empty = NEWSD.loading && !NEWSD.events.length ? "News werden geladen …"\n    : NEWSD.error && !NEWSD.events.length ? esc(NEWSD.error)\n    : NV.range === "heute" ? "Heute keine wichtigen Termine. Normaler Handelstag ohne geplante Datenveröffentlichungen." : "Keine Termine in dieser Woche.";\n  box.innerHTML = `<div class="section-h"><h2>Wirtschafts-News</h2>\n      <div class="nw-ctl">\n        <div class="seg" role="group" aria-label="Zeitraum">${[["heute", "Heute"], ["woche", "Woche"]].map(([k, l]) => `<button type="button" data-nr="${k}" aria-pressed="${NV.range === k}">${l}</button>`).join("")}</div>\n        <div class="seg" role="group" aria-label="Wichtigkeit">${[["hoch", "Hoch"], ["wichtig", "Hoch + Mittel"]].map(([k, l]) => `<button type="button" data-ni="${k}" aria-pressed="${NV.imp === k}">${l}</button>`).join("")}</div>\n        <div class="seg" role="group" aria-label="Länder">${[[true, "USD"], [false, "Alle"]].map(([k, l]) => `<button type="button" data-nu="${k}" aria-pressed="${NV.usd === k}">${l}</button>`).join("")}</div>\n      </div></div>\n    <div class="panel nw-box">\n      ${next && next.impact === "high" && next.ts - now < 3 * 3600e3 ? `<div class="nw-alert"><span class="dot bad"></span><b>${esc(next.title)}</b> ${inMin(next.ts - now)} · ${hm(next.ts)} Uhr. Rund um wichtige US-Daten springen NQ und ES oft stark, Stops können durchrutschen.</div>` : ""}\n      ${rows || `<div class="empty" style="border:0">${empty}</div>`}\n      <div class="nw-f"><span class="hint">Uhrzeiten in deiner Ortszeit · Quelle: Forex-Factory-Kalender${NEWSD.fetched ? ` · Stand ${new Date(NEWSD.fetched * 1000).toLocaleTimeString("de-DE", {hour: "2-digit", minute: "2-digit"})}` : ""}${NEWSD.error && NEWSD.events.length ? ` · <span class="neg">${esc(NEWSD.error)}</span>` : ""}</span>\n        <button class="lnk" id="nwRef" style="color:var(--accent)">Neu laden</button></div>\n    </div>`;\n  const save = () => { try { localStorage.setItem("fvg-news", JSON.stringify(NV)); } catch (e) {} newsPanel(); };\n  box.querySelectorAll("[data-nr]").forEach(b => b.onclick = () => { NV.range = b.dataset.nr; save(); });\n  box.querySelectorAll("[data-ni]").forEach(b => b.onclick = () => { NV.imp = b.dataset.ni; save(); });\n  box.querySelectorAll("[data-nu]").forEach(b => b.onclick = () => { NV.usd = b.dataset.nu === "true"; save(); });\n  $("#nwRef").onclick = () => { toast("News werden neu geladen"); loadNews(true); };\n}\nsetInterval(() => loadNews(), 5 * 60000);\n\n/* ───────── Edge-Check: wie gut ist jede Strategie wirklich? ───────── */\nconst EDGE = {data: null, at: 0, open: null, period: "alle"};\ntry { EDGE.period = localStorage.getItem("fvg-edge-p") || "alle"; } catch (e) {}\nfunction wilson(k, n) {   // 95-%-Vertrauensbereich einer Quote\n  if (!n) return [0, 0];\n  const z = 1.96, p = k / n, d = 1 + z * z / n, c = (p + z * z / (2 * n)) / d, h = z * Math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d;\n  return [Math.max(0, c - h) * 100, Math.min(1, c + h) * 100];\n}\nconst DOW = ["Mo", "Di", "Mi", "Do", "Fr"];\nfunction edgeCalc(list) {\n  const n = list.length, w = list.filter(t => t.r > 0), l = list.filter(t => t.r <= 0);\n  const aw = w.length ? w.reduce((a, t) => a + t.r, 0) / w.length : 0, al = l.length ? -l.reduce((a, t) => a + t.r, 0) / l.length : 0;\n  const wr = n ? w.length / n * 100 : 0, base = aw > 0 && al > 0 ? al / (aw + al) * 100 : 100 / 3;\n  const [lo, hi] = wilson(w.length, n), exp = n ? list.reduce((a, t) => a + t.r, 0) / n : 0;\n  const gw = w.reduce((a, t) => a + t.r, 0), gl = -l.reduce((a, t) => a + t.r, 0);\n  const edge = wr - base;\n  const grade = !n ? "–" : lo > base + 5 ? "A" : lo > base ? "B" : wr > base ? "C" : "D";\n  const trust = Math.round(Math.max(0, Math.min(100, 50 + 2 * (lo - base) + (edge > 0 ? edge : 0))) * (0.35 + 0.65 * Math.min(1, n / 40)));\n  return {n, w: w.length, wr, base, lo, hi, exp, pf: gl ? gw / gl : null, edge, grade, trust, aw, al};\n}\nfunction streaks(list) {\n  let cur = 0, curW = null, bw = 0, bl = 0, run = 0, last = null;\n  for (const t of list) { const win = t.r > 0; run = win === last ? run + 1 : 1; last = win; if (win) bw = Math.max(bw, run); else bl = Math.max(bl, run); }\n  cur = run; curW = last;\n  return {cur, curW, bw, bl};\n}\nasync function edgeLoad(force) {\n  if (!force && EDGE.data && Date.now() - EDGE.at < 60000) return;\n  try { EDGE.data = await api("/api/edge"); EDGE.at = Date.now(); } catch (e) { EDGE.err = e.message; }\n}\nasync function edgeView() {\n  const body = $("#stBody");\n  if (!EDGE.data) body.innerHTML = \'<div class="empty">Edge-Check wird berechnet …</div>\';\n  const fresh = !EDGE.data || Date.now() - EDGE.at > 60000;\n  if (fresh) { await edgeLoad(); }\n  else if (body.querySelector(".edge")) return;   // nicht bei jedem Refresh neu aufbauen (aufgeklappte Zeile bleibt)\n  if (STAB !== "edge" || TAB !== "stats") return;\n  const days = {"1m": 31, "3m": 92, "6m": 183, alle: 1e5}[EDGE.period];\n  const since = Date.now() / 1000 - days * 86400;\n  const all = (EDGE.data ? EDGE.data.trades : []).filter(t => (t.closed || t.opened) >= since);\n  const by = {}; all.forEach(t => (by[t.setup] = by[t.setup] || []).push(t));\n  const rows = Object.entries(by).map(([k, l]) => ({k, l, c: edgeCalc(l)})).sort((a, b) => b.c.trust - a.c.trust);\n  const tot = edgeCalc(all), bestRow = rows[0];\n  const spark = l => { let s = 0; const v = l.slice(-60).map(t => (s += t.r)); if (v.length < 2) return ""; const lo = Math.min(0, ...v), hi = Math.max(0, ...v), sp = hi - lo || 1;\n    const pts = v.map((y, i) => `${(i / (v.length - 1) * 80).toFixed(1)},${(22 - (y - lo) / sp * 20).toFixed(1)}`).join(" ");\n    return `<svg viewBox="0 0 80 24" class="spk"><polyline points="${pts}" fill="none" stroke="${v[v.length - 1] >= 0 ? "var(--accent)" : "var(--neg)"}" stroke-width="1.6" vector-effect="non-scaling-stroke"/></svg>`; };\n  const ciBar = c => `<div class="ci"><span class="ci-r" style="left:${c.lo}%;width:${Math.max(1, c.hi - c.lo)}%"></span><span class="ci-b" style="left:${c.base}%"></span><span class="ci-p" style="left:${c.wr}%"></span></div>`;\n  const detail = r => {\n    const l = r.l, st = streaks(l), last20 = edgeCalc(l.slice(-20));\n    const dir = ["long", "short"].map(sd => [sd, edgeCalc(l.filter(t => t.side === sd))]);\n    const wd = DOW.map((d, i) => [d, edgeCalc(l.filter(t => t.ny_weekday === i))]);\n    const hrs = {}; l.forEach(t => (hrs[t.ny_hour] = hrs[t.ny_hour] || []).push(t));\n    const hk = Object.keys(hrs).map(Number).sort((a, b) => a - b);\n    return `<div class="ed-x">\n      <div class="ed-card"><span class="l">Bilanz · Gewinn / Verlust</span>\n        <div class="grid-wl">${l.slice(-200).map(t => `<i class="${t.r > 0 ? "w" : "x"}" title="${dtm(t.closed)} · ${t.r > 0 ? "+" : ""}${num2(t.r)} R"></i>`).join("")}</div>\n        <div class="ed-mini">${[["Aktuell", st.cur ? `${st.cur}${st.curW ? "G" : "V"}` : "–", st.curW ? "pos" : "neg"], ["Längste Gewinnserie", st.bw, "pos"], ["Längste Verlustserie", st.bl, "neg"],\n          ["Letzte 20", pct(last20.wr), last20.wr >= r.c.base ? "pos" : "neg"], ["Gesamt", pct(r.c.wr), ""]].map(([a, b, c]) => `<div><span class="l">${a}</span><b class="${c}">${b}</b></div>`).join("")}</div>\n        <span class="hint">${l.length} Signale${l.length > 200 ? " · neueste 200 gezeigt" : ""} · älteste links</span></div>\n      <div class="ed-card"><span class="l">Wo es funktioniert</span>\n        ${dir.map(([sd, c]) => `<div class="dirrow"><span>${sd === "long" ? "Long" : "Short"}</span><div class="dbar"><i style="width:${c.wr}%"></i><b style="left:${c.base}%"></b></div><span class="mono">${c.n ? pct(c.wr) : "–"}</span><span class="hint">(${c.n})</span></div>`).join("")}\n        <span class="l" style="margin-top:8px">Trefferquote je Wochentag</span>\n        <div class="wd">${wd.map(([d, c]) => `<div class="${!c.n ? "" : c.wr >= c.base ? "ok" : "bad"}"><span>${d}</span><b>${c.n ? Math.round(c.wr) + " %" : "–"}</b><small>${c.n}</small></div>`).join("")}</div>\n        <span class="l" style="margin-top:8px">Stunden (NY) · Ø R</span>\n        <div class="hrs">${hk.length ? hk.map(h => { const c = edgeCalc(hrs[h]); const a = Math.max(-1, Math.min(1, c.exp));\n          return `<div title="${h}:00 NY · ${c.n} Signale · ${pct(c.wr)}" style="background:${a >= 0 ? `rgba(47,211,154,${0.12 + a * 0.55})` : `rgba(255,93,108,${0.12 - a * 0.55})`}"><span>${h}</span><b>${c.exp > 0 ? "+" : ""}${num2(c.exp)}</b></div>`; }).join("") : \'<span class="hint">–</span>\'}</div></div>\n      <div class="ed-card ed-wide"><span class="l">Letzte Signale · neueste zuerst</span>\n        <div class="recent">${l.slice(-14).reverse().map(t => `<span class="${t.r > 0 ? "w" : "x"}">${new Date(t.closed * 1000).toLocaleDateString("de-DE", {weekday: "short", day: "numeric", month: "short"})} <b>${t.r > 0 ? "+" : ""}${num2(t.r)} R</b> ${t.r > 0 ? "✓" : "✗"}</span>`).join("")}</div></div>\n    </div>`;\n  };\n  body.innerHTML = `\n    <section class="panel edge">\n      <div class="ed-top">\n        <div class="ed-k">${[["Trefferquote", tot.n ? pct(tot.wr) : "–", `${tot.n ? (tot.edge >= 0 ? "+" : "") + num2(tot.edge) + " Pkt. über Breakeven" : ""}`],\n          ["Ausgewertete Signale", tot.n, `${rows.length} Strategien`], ["Ø R pro Signal", tot.n ? (tot.exp > 0 ? "+" : "") + num2(tot.exp) : "–", tot.pf ? `Profit-Faktor ${num2(tot.pf)}` : ""],\n          ["Beste Strategie", bestRow ? esc(bestRow.k) : "–", bestRow ? `Vertrauen ${bestRow.c.trust} · Note ${bestRow.c.grade}` : ""]].map(([l, v, sub]) => `<div><span class="l">${l}</span><b>${v}</b><small>${sub}</small></div>`).join("")}</div>\n        <div class="seg" role="group" aria-label="Zeitraum">${[["1m", "1M"], ["3m", "3M"], ["6m", "6M"], ["alle", "Alle"]].map(([k, l]) => `<button type="button" data-ep="${k}" aria-pressed="${EDGE.period === k}">${l}</button>`).join("")}</div>\n      </div>\n      <p class="hint ed-help"><b>So liest du es:</b> Trefferquote = wie oft das Signal ins Ziel lief · <b>Breakeven</b> = Quote, ab der die Strategie bei ihrem Chance-Risiko-Verhältnis Geld verdient · <b>Edge</b> = Abstand dazu · <b>Note A–D</b> = liegt auch der vorsichtige Wert (untere Grenze des 95-%-Bereichs) über Breakeven? · <b>Vertrauen</b> = Gesamtwert aus Edge und Stichprobe (danach sortiert). Gezählt werden alle Signale aus TradingView, auch die du nicht genommen hast.</p>\n      ${rows.length ? `<div class="scroll"><table class="ed-t"><thead><tr><th class="t">Strategie</th><th class="t">Trefferquote · 95 %</th><th>Note</th><th>Breakeven</th><th>Edge</th><th>Ø R</th><th>Signale</th><th class="t">Verlauf</th><th>Vertrauen</th><th></th></tr></thead><tbody>\n        ${rows.map(r => `<tr class="ed-r ${EDGE.open === r.k ? "open" : ""}" data-ek="${esc(r.k)}" tabindex="0">\n          <td class="t"><b>${esc(r.k)}</b><small class="hint">${r.c.aw ? `Ø Gewinn +${num2(r.c.aw)} R · Ø Verlust −${num2(r.c.al)} R` : ""}</small></td>\n          <td class="t"><div class="ci-w"><span class="mono">${pct(r.c.wr)}</span>${ciBar(r.c)}<small class="hint">±${num2((r.c.hi - r.c.lo) / 2)}</small></div></td>\n          <td><span class="grade g${r.c.grade}">${r.c.grade}</span></td>\n          <td class="muted">${pct(r.c.base)}</td>\n          <td class="${cls(r.c.edge)}">${r.c.edge > 0 ? "+" : ""}${num2(r.c.edge)}</td>\n          <td class="${cls(r.c.exp)}">${r.c.exp > 0 ? "+" : ""}${num2(r.c.exp)}</td>\n          <td>${r.c.n}</td>\n          <td class="t">${spark(r.l)}</td>\n          <td><b class="trust" style="color:${r.c.trust >= 70 ? "var(--accent)" : r.c.trust >= 50 ? "var(--fg)" : "var(--muted)"}">${r.c.trust}</b></td>\n          <td><span class="chev">▾</span></td></tr>\n          ${EDGE.open === r.k ? `<tr class="ed-d"><td colspan="${window.innerWidth <= 700 ? 5 : 10}">${detail(r)}</td></tr>` : ""}`).join("")}\n      </tbody></table></div>` : `<div class="empty">Noch keine abgeschlossenen Signale${EDGE.period !== "alle" ? " in diesem Zeitraum" : ""}. Sobald TradingView Signale und Kerzen schickt, füllt sich der Edge-Check von selbst.</div>`}\n    </section>`;\n  body.querySelectorAll("[data-ep]").forEach(b => b.onclick = () => { EDGE.period = b.dataset.ep; try { localStorage.setItem("fvg-edge-p", EDGE.period); } catch (e) {} body.innerHTML = ""; edgeView(); });\n  body.querySelectorAll(".ed-r").forEach(tr => { const t = () => { EDGE.open = EDGE.open === tr.dataset.ek ? null : tr.dataset.ek; body.innerHTML = ""; edgeView(); };\n    tr.onclick = t; tr.onkeydown = e => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); t(); } }; });\n}\n\n/* ───────── Session-Muster aus den gesammelten Kerzen ───────── */\nconst MU = {fam: "auto", data: null, at: 0};\nasync function musterView() {\n  const body = $("#stBody");\n  if (MU.data && Date.now() - MU.at < 120000 && body.querySelector(".muster")) return;\n  if (!MU.data) body.innerHTML = \'<div class="empty">Session-Muster werden berechnet …</div>\';\n  try { MU.data = await api("/api/sessions/" + MU.fam); MU.at = Date.now(); } catch (e) { body.innerHTML = `<div class="empty">${esc(e.message)}</div>`; return; }\n  if (STAB !== "muster" || TAB !== "stats") return;\n  const D = MU.data.days || [], n = D.length;\n  const prob = (k, m) => { const [lo, hi] = wilson(k, m); return {p: m ? k / m * 100 : null, lo, hi, k, m}; };\n  const pr = x => x.m ? `<b class="mono">${Math.round(x.p)} %</b><small class="hint">${x.k} von ${x.m} · 95 %: ${Math.round(x.lo)}–${Math.round(x.hi)} %</small>` : \'<b class="mono muted">–</b><small class="hint">noch keine Daten</small>\';\n  const bar = (parts) => `<div class="pbar">${parts.map(([v, c, l]) => v ? `<i style="width:${v}%;background:${c}" title="${l}: ${Math.round(v)} %"></i>` : "").join("")}</div>`;\n  const brk = key => { const ev = D.map(d => d.events[key]).filter(Boolean); const m = ev.length;\n    const up = ev.filter(e => e.first === "oben").length, dn = ev.filter(e => e.first === "unten").length, none = m - up - dn, both = ev.filter(e => e.both).length;\n    return {m, up: prob(up, m), dn: prob(dn, m), none: prob(none, m), both: prob(both, m),\n      times: ev.filter(e => e.when).map(e => e.when)}; };\n  const card = (title, sub, b) => `<div class="mu-c"><div class="mu-h"><b>${title}</b><small class="hint">${sub}</small></div>\n    ${bar([[b.up.p, "var(--pos)", "oben zuerst"], [b.dn.p, "var(--neg)", "unten zuerst"], [b.none.p, "var(--line2)", "kein Bruch"]])}\n    <div class="mu-g"><div><span class="l">Oben zuerst</span>${pr(b.up)}</div><div><span class="l">Unten zuerst</span>${pr(b.dn)}</div>\n      <div><span class="l">Beide Seiten (Sweep)</span>${pr(b.both)}</div><div><span class="l">Kein Bruch</span>${pr(b.none)}</div></div></div>`;\n  const gaps = D.map(d => d.events.gap).filter(g => g && g.dir !== "keins"), gu = gaps.filter(g => g.dir === "hoch"), gd = gaps.filter(g => g.dir === "runter");\n  const fillMin = gaps.filter(g => g.filled && g.when).map(g => { const [h, m] = g.when.split(":").map(Number); return h * 60 + m - 570; }).sort((a, b) => a - b);\n  const med = fillMin.length ? fillMin[Math.floor(fillMin.length / 2)] : null;\n  const pdh = prob(D.filter(d => d.events.pdh).length, D.filter(d => "pdh" in d.events).length), pdl = prob(D.filter(d => d.events.pdl).length, D.filter(d => "pdl" in d.events).length);\n  const mid = prob(D.filter(d => d.events.mid).length, D.filter(d => "mid" in d.events).length);\n  const hist = key => { const b = Array(7).fill(0); D.forEach(d => { const t = d.events[key]; if (!t) return; const [h, m] = t.split(":").map(Number); b[Math.min(6, Math.max(0, h - 9 - (m < 30 ? 1 : 0)))]++; }); return b; };\n  const hod = hist("hod"), lod = hist("lod"), hmax = Math.max(1, ...hod, ...lod);\n  const HL = ["9:30", "10:30", "11:30", "12:30", "13:30", "14:30", "15:30"];\n  body.innerHTML = `<section class="panel muster">\n    <div class="ed-top"><div class="ed-k">${[["Gesammelte Handelstage", n, MU.data.fam ? MU.data.fam + "-Kerzen aus TradingView" : ""],\n      ["Gap gefüllt", gaps.length ? Math.round(gaps.filter(g => g.filled).length / gaps.length * 100) + " %" : "–", gaps.length ? `${gaps.length} Gaps · Median ${med != null ? med + " Min nach Open" : "–"}` : ""],\n      ["PDH genommen", pdh.m ? Math.round(pdh.p) + " %" : "–", "in der New-York-Session"], ["PDL genommen", pdl.m ? Math.round(pdl.p) + " %" : "–", "in der New-York-Session"]]\n      .map(([l, v, sub]) => `<div><span class="l">${l}</span><b>${v}</b><small>${sub}</small></div>`).join("")}</div>\n      ${(MU.data.fams || []).length > 1 ? `<div class="seg">${MU.data.fams.map(f => `<button type="button" data-mf="${f}" aria-pressed="${MU.data.fam === f}">${f}</button>`).join("")}</div>` : ""}</div>\n    ${n < 20 ? `<p class="hint ed-help">Die App sammelt die Kerzen, die TradingView schickt, und wertet jeden fertigen Handelstag aus. Mit ${n} ${n === 1 ? "Tag" : "Tagen"} sind die Zahlen noch wackelig (siehe 95-%-Bereich). Ab etwa 40 Tagen werden sie belastbar. Dafür muss der Alert der Strategie in TradingView laufen und „Kerzen-Daten an die App senden“ an sein (Standard).</p>` : ""}\n    <div class="mu">\n      ${card("London-Range (02:00–05:00 NY)", "Welche Seite bricht danach zuerst?", brk("london"))}\n      ${card("Initial Balance (09:30–10:30)", "Welche Seite der ersten Stunde bricht zuerst?", brk("ib"))}\n      ${card("Asien-Range (20:00–00:00)", "Welche Seite bricht ab Mitternacht zuerst?", brk("asia"))}\n      <div class="mu-c"><div class="mu-h"><b>Opening-Gap</b><small class="hint">RTH-Open gegen Vortagesschluss · gefüllt bis 16:00</small></div>\n        <div class="mu-g"><div><span class="l">Gap hoch gefüllt</span>${pr(prob(gu.filter(g => g.filled).length, gu.length))}</div>\n          <div><span class="l">Gap runter gefüllt</span>${pr(prob(gd.filter(g => g.filled).length, gd.length))}</div>\n          <div><span class="l">Midnight Open getestet</span>${pr(mid)}</div>\n          <div><span class="l">Median bis Fill</span><b class="mono">${med != null ? med + " Min" : "–"}</b><small class="hint">nach 09:30</small></div></div></div>\n      <div class="mu-c mu-w"><div class="mu-h"><b>Wann entsteht Hoch und Tief des Tages?</b><small class="hint">New-York-Session je Stunde</small></div>\n        <div class="hist">${HL.map((h, i) => `<div><div class="hb"><i class="p" style="height:${hod[i] / hmax * 100}%" title="Tageshoch ${h}: ${hod[i]}"></i><i class="n" style="height:${lod[i] / hmax * 100}%" title="Tagestief ${h}: ${lod[i]}"></i></div><span>${h}</span></div>`).join("")}</div>\n        <div class="legend"><span><i style="background:var(--pos)"></i>Tageshoch</span><span><i style="background:var(--neg)"></i>Tagestief</span></div></div>\n    </div></section>`;\n  body.querySelectorAll("[data-mf]").forEach(b => b.onclick = () => { MU.fam = b.dataset.mf; MU.data = null; body.innerHTML = ""; musterView(); });\n}\n\n/* ───────── Key Levels heute (Cockpit) ───────── */\nconst LV = {fam: "auto", data: null, at: 0};\nasync function levelsLoad() {\n  try { LV.data = await api("/api/levels/" + LV.fam); LV.at = Date.now(); } catch (e) { LV.err = e.message; }\n  if (TAB === "cockpit") levelsPanel();\n}\nfunction levelsPanel() {\n  const box = $("#lvSec"); if (!box) return;\n  if (!LV.data || Date.now() - LV.at > 30000) { if (!levelsPanel._busy) { levelsPanel._busy = true; levelsLoad().finally(() => levelsPanel._busy = false); } if (!LV.data) return; }\n  const d = LV.data, T = d.today;\n  if (!d.fam || !T) { box.innerHTML = `<div class="section-h"><h2>Key Levels heute</h2></div><div class="empty">Erscheinen, sobald TradingView Kerzen schickt (Alert der Strategie läuft, „Kerzen-Daten an die App senden“ an). Ab dem zweiten Tag gibt es auch Vortages-Levels.</div>`; return; }\n  const ev = T.events || {}, price = d.price;\n  const L = [["PDH", "Vortageshoch", T.pdh, ev.pdh], ["PDL", "Vortagestief", T.pdl, ev.pdl], ["PDC", "Vortagesschluss", T.pdc, ev.gap && ev.gap.filled ? ev.gap.when : null],\n    ["ONH", "Overnight-Hoch", T.onh], ["ONL", "Overnight-Tief", T.onl],\n    ["AH", "Asien-Hoch", T.asia_h, ev.asia && ev.asia.first === "oben" ? ev.asia.when : null], ["AL", "Asien-Tief", T.asia_l, ev.asia && ev.asia.first === "unten" ? ev.asia.when : null],\n    ["LH", "London-Hoch", T.lon_h, ev.london && ev.london.first === "oben" ? ev.london.when : null], ["LL", "London-Tief", T.lon_l, ev.london && ev.london.first === "unten" ? ev.london.when : null],\n    ["MO", "Midnight Open", T.mid_open, ev.mid], ["RO", "RTH-Open 09:30", T.rth_open],\n    ["IBH", "IB-Hoch", T.ib_h, ev.ib && ev.ib.first === "oben" ? ev.ib.when : null], ["IBL", "IB-Tief", T.ib_l, ev.ib && ev.ib.first === "unten" ? ev.ib.when : null]]\n    .filter(x => x[2] != null).sort((a, b) => b[2] - a[2]);\n  let rows = "", placed = false;\n  for (const [k, name, v, hit] of L) {\n    if (!placed && price != null && price > v) { rows += `<div class="lv-row now"><span class="lv-k">Kurs</span><span class="lv-n">${esc(d.fam)} jetzt</span><span class="lv-p mono">${px(price)}</span><span></span><span></span></div>`; placed = true; }\n    const dist = price != null ? v - price : null;\n    rows += `<div class="lv-row ${k.startsWith("PD") ? "pd" : ""}"><span class="lv-k">${k}</span><span class="lv-n">${name}</span><span class="lv-p mono">${px(v)}</span>\n      <span class="lv-d mono ${dist == null ? "" : dist > 0 ? "pos" : "neg"}">${dist == null ? "" : (dist > 0 ? "+" : "−") + Math.abs(dist).toFixed(2).replace(".", ",")}</span>\n      <span>${hit ? `<span class="chip ${k === "MO" || k === "PDC" ? "" : "warn"}">${k === "MO" ? "getestet" : k === "PDC" ? "Gap gefüllt" : "gebrochen"} ${hit}</span>` : ""}</span></div>`;\n  }\n  if (!placed && price != null) rows += `<div class="lv-row now"><span class="lv-k">Kurs</span><span class="lv-n">${esc(d.fam)} jetzt</span><span class="lv-p mono">${px(price)}</span><span></span><span></span></div>`;\n  const tags = [];\n  if (ev.gap && ev.gap.dir !== "keins") tags.push(`Gap ${ev.gap.dir} ${Math.abs(ev.gap.size).toFixed(2).replace(".", ",")} Pkt. · ${ev.gap.filled ? "gefüllt " + ev.gap.when : "offen"}`);\n  if (ev.asia) tags.push(`Asien: ${ev.asia.first ? ev.asia.first + " zuerst " + ev.asia.when : "kein Bruch"}`);\n  if (ev.london) tags.push(`London: ${ev.london.first ? ev.london.first + " zuerst " + ev.london.when : "kein Bruch"}${ev.london.both ? " · beide Seiten" : ""}`);\n  if (ev.ib) tags.push(`IB: ${ev.ib.first ? ev.ib.first + " zuerst " + ev.ib.when : "kein Bruch"}`);\n  box.innerHTML = `<div class="section-h"><h2>Key Levels heute</h2>\n      ${(d.fams || []).length > 1 ? `<div class="seg">${d.fams.map(f => `<button type="button" data-lf="${f}" aria-pressed="${d.fam === f}">${f}</button>`).join("")}</div>` : `<p class="hint">${esc(d.fam)} · Handelstag ${esc(T.day.split("-").reverse().join("."))}</p>`}</div>\n    <div class="panel lv-box">${tags.length ? `<div class="lv-tags">${tags.map(t => `<span class="chip mute">${t}</span>`).join("")}</div>` : ""}\n      <div class="lv-list">${rows || \'<div class="empty" style="border:0">Noch keine Levels für heute.</div>\'}</div>\n      <div class="nw-f"><span class="hint">Abstand in Punkten vom aktuellen Kurs · Zeiten in NY · Levels aus den Kerzen, die TradingView schickt</span></div></div>`;\n  box.querySelectorAll("[data-lf]").forEach(b => b.onclick = () => { LV.fam = b.dataset.lf; LV.data = null; levelsLoad(); });\n}\n\n/* ───────── Fremdkapital (Prop-Firm-Challenge) ───────── */\nconst DDT = {eod: "EOD-Trailing (Tagesende)", intraday: "Intraday-Trailing (Echtzeit)", static: "Statisch (fest)"};\nconst mUsd = v => v == null ? "–" : (v < 0 ? "−$" : "$") + Math.abs(v).toLocaleString("de-DE", {maximumFractionDigits: 0});\nfunction chStatus(c) {\n  if (c.breached) return ["bad", "Verlustgrenze erreicht"];\n  if (c.passed) return ["good", "Ziel erreicht"];\n  if (c.daily_hit) return ["bad", "Tageslimit erreicht"];\n  if (c.can_lose < Math.max(250, c.cfg.max_dd * 0.15)) return ["warn", "Wenig Puffer"];\n  return ["", "Läuft"];\n}\nfunction chCard() {\n  const box = $("#chCard"); if (!box) return;\n  const c = S.challenge; box.hidden = !c;\n  if (!c) return;\n  const [st, txt] = chStatus(c), tgt = c.cfg.profit_target, prog = tgt > 0 ? Math.max(0, Math.min(100, c.profit / tgt * 100)) : 0;\n  box.innerHTML = `<button type="button" class="chc" id="chGo">\n    <div class="chc-h"><span class="l">Fremdkapital${c.cfg.name ? " · " + esc(c.cfg.name) : ""}</span><span class="chip ${st}">${txt}</span></div>\n    <div class="chc-g">\n      <div><span class="l">Darfst noch verlieren</span><b class="${c.can_lose <= 0 ? "neg" : ""}">${mUsd(c.can_lose)}</b><small>${c.daily_left != null && c.daily_left < c.buffer ? "Tageslimit" : "bis zur Verlustgrenze"}</small></div>\n      <div><span class="l">Noch bis zum Ziel</span><b class="${c.to_target <= 0 ? "pos" : ""}">${c.to_target <= 0 ? "erreicht" : mUsd(c.to_target)}</b><small>${Math.round(prog)} % von ${mUsd(tgt)}</small></div>\n      <div><span class="l">Konto</span><b>${mUsd(c.equity)}</b><small>Grenze ${mUsd(c.threshold)}</small></div>\n    </div>\n    ${chTrack(c, true)}</button>`;\n  $("#chGo").onclick = () => { TAB = "challenge"; setHash(TAB); window.scrollTo(0, 0); render(true); };\n}\nfunction chTrack(c, small) {   // Weg von der Verlustgrenze bis zum Ziel\n  const lo = c.threshold, hi = c.start + c.cfg.profit_target, span = Math.max(1, hi - lo);\n  const at = v => Math.max(0, Math.min(100, (v - lo) / span * 100));\n  return `<div class="trk ${small ? "sm" : ""}">\n    <div class="trk-b"><i class="trk-f" style="width:${at(c.equity)}%"></i><span class="trk-s" style="left:${at(c.start)}%"></span><span class="trk-e" style="left:${at(c.equity)}%"></span></div>\n    ${small ? "" : `<div class="trk-l"><span class="neg">Grenze ${mUsd(lo)}</span>${at(c.start) > 18 && at(c.start) < 82 ? `<span style="left:${at(c.start)}%">Start ${mUsd(c.start)}</span>` : "<span></span>"}<span class="pos">Ziel ${mUsd(hi)}</span></div>`}</div>`;\n}\nfunction chChart(c) {\n  const d = c.days; if (d.length < 1) return \'<p class="hint">Die Kurve erscheint nach dem ersten Handelstag.</p>\';\n  const W = 900, H = 230, L = 64, R = 14, T = 12, B = 24;\n  const pts = [{balance: c.start, threshold: d.length ? (c.cfg.dd_type === "static" ? c.start - c.cfg.max_dd : c.start - c.cfg.max_dd) : c.threshold, day: ""}, ...d];\n  const tgt = c.start + c.cfg.profit_target;\n  const vals = pts.flatMap(p => [p.balance, p.threshold]).concat([tgt, c.equity]);\n  const lo = Math.min(...vals), hi = Math.max(...vals), pad = (hi - lo) * 0.08 || 100;\n  const y0 = lo - pad, y1 = hi + pad;\n  const x = i => L + (W - L - R) * i / Math.max(1, pts.length - 1), y = v => T + (H - T - B) * (1 - (v - y0) / (y1 - y0));\n  const line = k => pts.map((p, i) => `${i ? "L" : "M"}${x(i).toFixed(1)},${y(p[k]).toFixed(1)}`).join("");\n  const step = pts.map((p, i) => i ? `L${x(i).toFixed(1)},${y(pts[i - 1].threshold).toFixed(1)}L${x(i).toFixed(1)},${y(p.threshold).toFixed(1)}` : `M${x(0)},${y(p.threshold)}`).join("");\n  let g = ""; for (let k = 0; k <= 4; k++) { const v = y0 + (y1 - y0) * k / 4; g += `<line class="gl" x1="${L}" x2="${W - R}" y1="${y(v)}" y2="${y(v)}"/><text x="${L - 8}" y="${y(v) + 4}" text-anchor="end">${mUsd(v)}</text>`; }\n  const every = Math.ceil(pts.length / 8);\n  const xl = pts.map((p, i) => i && (i % every === 0 || i === pts.length - 1) ? `<text x="${x(i)}" y="${H - 6}" text-anchor="middle">${p.day.slice(8)}.${p.day.slice(5, 7)}.</text>` : "").join("");\n  return `<svg viewBox="0 0 ${W} ${H}" class="chart" role="img" aria-label="Kontoverlauf mit Verlustgrenze">${g}${xl}\n    <line x1="${L}" x2="${W - R}" y1="${y(tgt)}" y2="${y(tgt)}" stroke="var(--pos)" stroke-dasharray="5 4" stroke-width="1.2"/><text x="${W - R}" y="${y(tgt) - 6}" text-anchor="end" style="fill:var(--pos)">Ziel</text>\n    <path d="${step}" fill="none" stroke="var(--neg)" stroke-width="1.6" stroke-dasharray="1 0" vector-effect="non-scaling-stroke"/><text x="${W - R}" y="${y(pts[pts.length - 1].threshold) + 14}" text-anchor="end" style="fill:var(--neg)">Verlustgrenze</text>\n    <path d="${line("balance")}" fill="none" stroke="var(--accent)" stroke-width="2.2" vector-effect="non-scaling-stroke"/>\n    ${pts.map((p, i) => `<circle cx="${x(i)}" cy="${y(p.balance)}" r="3" fill="var(--accent)"><title>${p.day || "Start"}: ${mUsd(p.balance)} · Grenze ${mUsd(p.threshold)}</title></circle>`).join("")}</svg>`;\n}\nfunction challenge(full) {\n  const c = S.challenge, cfg = (S.config.challenge || {});\n  if (full !== false || !$("#chWrap")) {\n    $("#main").innerHTML = `<div id="chWrap" style="display:contents"><div id="chLive" style="display:contents"></div>\n      <details class="set-sec ch-form" id="chForm" ${c ? "" : "open"}><summary><span class="s-ic">${icon(\'<path d="M4 7h10M18 7h2M4 17h4M12 17h8"/><circle cx="16" cy="7" r="2"/><circle cx="10" cy="17" r="2"/>\')}</span>\n        <span class="s-t"><b>Regeln deiner Challenge</b><span class="hint">${c ? `${esc(cfg.name || "Konto")} · ${mUsd(cfg.start_balance)} · Ziel ${mUsd(cfg.profit_target)} · Drawdown ${mUsd(cfg.max_dd)} ${DDT[cfg.dd_type].split(" ")[0]}` : "Einmal eintragen, dann rechnet die App live mit"}</span></span><span></span></summary>\n        <div class="set-b" id="chFormB"></div></details></div>`;\n    chForm();\n  }\n  const live = $("#chLive");\n  if (!c) { live.innerHTML = `<section class="panel ch-empty"><h2 style="font-size:18px;text-transform:none;letter-spacing:0;color:var(--fg)">Fremdkapital-Challenge</h2>\n    <p class="hint" style="font-size:13.5px;line-height:1.6">Trag unten die Regeln deiner Prop-Firm ein (Kontogröße, Profitziel, maximaler Drawdown, Tageslimit …). Danach siehst du hier live, <b>wie viel du noch verlieren darfst</b> und <b>wie viel bis zum Ziel fehlt</b>. Im Cockpit erscheint eine kleine Übersicht. Auf Wunsch stoppt die App den Bot, bevor die Grenze erreicht ist.</p></section>`; return; }\n  const [st, txt] = chStatus(c), tgt = c.cfg.profit_target, prog = tgt > 0 ? Math.max(0, Math.min(100, c.profit / tgt * 100)) : 0;\n  const md = c.cfg.min_days || 0, cons = c.consistency;\n  const rule = (ok, title, val, sub) => `<div class="rl ${ok === true ? "ok" : ok === false ? "no" : ""}"><span class="rl-i">${ok === true ? "✓" : ok === false ? "!" : "·"}</span><div><b>${title}</b><small>${sub}</small></div><span class="mono">${val}</span></div>`;\n  live.innerHTML = `\n    <section class="ch-head"><div><span class="l">${esc(c.cfg.phase || "Challenge")}</span><h2>${esc(c.cfg.name || "Fremdkapital-Konto")} <small>${mUsd(c.start)}</small></h2></div>\n      <div class="ch-hr"><span class="chip ${st}" style="font-size:12.5px;padding:4px 10px">${txt}</span><span class="hint">${c.n_trades} Trades · ${c.cfg.source === "alle" ? "Bot + eigene" : c.cfg.source === "bot" ? "nur Bot" : "nur eigene"}${c.cfg.start_day ? " · seit " + c.cfg.start_day.split("-").reverse().join(".") : ""}</span></div></section>\n    <section class="ch-big">\n      <div class="${c.can_lose <= c.cfg.guard_buffer ? "warn" : ""}"><span class="l">Darfst du noch verlieren</span><b class="${c.can_lose <= 0 ? "neg" : ""}">${mUsd(Math.max(0, c.can_lose))}</b>\n        <small>${c.daily_left != null && c.daily_left < c.buffer ? `Heute begrenzt durchs Tageslimit · bis zur Verlustgrenze ${mUsd(c.buffer)}` : `bis zur Verlustgrenze${c.daily_left != null ? ` · Tageslimit noch ${mUsd(c.daily_left)}` : ""}`}</small></div>\n      <div><span class="l">Noch zu gewinnen</span><b class="${c.to_target <= 0 ? "pos" : ""}">${c.to_target <= 0 ? "Ziel erreicht" : mUsd(c.to_target)}</b>\n        <div class="prog"><i style="width:${prog}%"></i></div><small>${mUsd(c.profit)} von ${mUsd(tgt)} · ${Math.round(prog)} %${cons && !cons.ok && cons.extra > 0 ? ` · für Konsistenz mind. ${mUsd(cons.extra)} mehr` : ""}</small></div>\n      <div><span class="l">Kontostand</span><b>${mUsd(c.equity)}</b><small>${c.upnl ? `davon offen ${sUsd(c.upnl)} · ` : ""}heute ${sUsd(c.today_pnl)}</small></div>\n      <div><span class="l">Verlustgrenze</span><b class="neg">${mUsd(c.threshold)}</b><small>${DDT[c.cfg.dd_type]}${c.locked ? " · fest auf Startkapital" : c.cfg.dd_type !== "static" ? ` · Höchststand ${mUsd(c.hwm)}` : ""}</small></div>\n    </section>\n    <section class="panel">${chTrack(c, false)}</section>\n    <div class="grid2">\n      <section class="section"><h2>Kontoverlauf</h2><div class="panel">${chChart(c)}<div class="legend" style="margin-top:6px"><span><i style="background:var(--accent)"></i>Kontostand (Tagesende)</span><span><i style="background:var(--neg)"></i>Verlustgrenze</span><span><i style="background:var(--pos)"></i>Profitziel</span></div></div></section>\n      <section class="section"><h2>Regeln</h2><div class="panel rules">\n        ${rule(c.to_target <= 0, "Profitziel", c.to_target <= 0 ? "✓" : mUsd(c.to_target), `${mUsd(tgt)} Gewinn · fehlt noch`)}\n        ${rule(!c.breached, "Max. Drawdown", mUsd(c.buffer), `${mUsd(c.cfg.max_dd)} ${DDT[c.cfg.dd_type]} · Puffer`)}\n        ${c.daily_left != null ? rule(!c.daily_hit, "Tageslimit heute", mUsd(Math.max(0, c.daily_left)), `${mUsd(c.cfg.daily_loss)} pro Tag · noch übrig`) : rule(null, "Tageslimit", "aus", "keine Tagesgrenze eingetragen")}\n        ${cons ? rule(cons.ok, `Konsistenz ${cons.pct} %`, cons.share != null ? cons.share.toFixed(0) + " %" : "–", `bester Tag ${mUsd(cons.best)} · darf höchstens ${cons.pct} % des Gewinns sein${!cons.ok && cons.need_total ? ` · Gewinn nötig: ${mUsd(cons.need_total)}` : ""}`) : rule(null, "Konsistenz", "aus", "keine Konsistenzregel eingetragen")}\n        ${md ? rule(c.days_traded >= md, "Mindest-Handelstage", `${c.days_traded} / ${md}`, md > c.days_traded ? `noch ${md - c.days_traded} ${md - c.days_traded === 1 ? "Tag" : "Tage"}` : "erfüllt") : rule(null, "Mindest-Handelstage", c.days_traded, "keine Mindestzahl eingetragen")}\n        ${rule(c.cfg.guard ? true : null, "Bot-Schutz", c.cfg.guard ? "an" : "aus", c.cfg.guard ? `Bot stoppt bei weniger als ${mUsd(c.cfg.guard_buffer)} Spielraum und nimmt keine Trades, deren Risiko größer ist` : "Bot handelt ohne Rücksicht auf die Challenge")}\n      </div></section>\n    </div>\n    <section class="section"><h2>Tage</h2><div class="panel scroll">${c.days.length ? `<table><thead><tr><th class="t">Tag</th><th>Trades</th><th>P&L</th><th>Kontostand</th><th>Grenze danach</th><th>Puffer</th></tr></thead><tbody>\n      ${c.days.slice().reverse().map(d => `<tr><td class="t">${new Date(d.day + "T12:00:00").toLocaleDateString("de-DE", {weekday: "short", day: "2-digit", month: "2-digit"})}</td><td>${d.n}</td><td class="${cls(d.pnl)}">${sUsd(d.pnl)}</td><td>${mUsd(d.balance)}</td><td class="neg">${mUsd(d.threshold)}</td><td>${mUsd(d.balance - d.threshold)}</td></tr>`).join("")}\n      </tbody></table>` : \'<p class="hint">Noch keine Trades seit dem Start der Challenge.</p>\'}</div></section>`;\n}\nfunction chForm() {\n  const cf = S.config.challenge || {};\n  const f = (id, label, val, help, attrs = "", type = "number") => `<div class="row"><label for="${id}">${label}${help ? `<small>${help}</small>` : ""}</label><input id="${id}" type="${type}" value="${esc(val ?? "")}" ${attrs}></div>`;\n  $("#chFormB").innerHTML = `\n    ${f("cName", "Name", cf.name, "z. B. Topstep 50K oder Apex 100K", \'maxlength="40" placeholder="Meine Challenge"\', "text")}\n    <div class="row"><label for="cPhase">Phase</label><select id="cPhase">${["Challenge", "Phase 2", "Funded", "Live"].map(x => `<option ${cf.phase === x ? "selected" : ""}>${x}</option>`).join("")}</select></div>\n    ${f("cSize", "Kontogröße / Startkapital ($)", cf.start_balance, "", \'min="1000" step="500"\')}\n    ${f("cStart", "Start der Challenge", cf.start_day, "Nur Trades ab diesem Tag zählen. Leer = alle Trades", "", "date")}\n    <span class="lbl">Regeln der Firma</span>\n    ${f("cTarget", "Profitziel ($)", cf.profit_target, "0 = kein Ziel (z. B. Funded-Konto)", \'min="0" step="100"\')}\n    ${f("cDd", "Maximaler Drawdown ($)", cf.max_dd, "Abstand der Verlustgrenze zum Höchststand bzw. Start", \'min="100" step="100"\')}\n    <div class="row"><label for="cType">Art des Drawdowns<small>EOD: zieht nur zum Tagesende nach · Intraday: zieht sofort mit offenen Gewinnen nach · Statisch: feste Grenze</small></label>\n      <select id="cType">${Object.entries(DDT).map(([k, l]) => `<option value="${k}" ${cf.dd_type === k ? "selected" : ""}>${l}</option>`).join("")}</select></div>\n    <div class="row"><label for="cLock">Grenze stoppt beim Startkapital<small>Bei den meisten Firmen wandert die Grenze höchstens bis zum Startkapital</small></label><input id="cLock" type="checkbox" class="chk" ${cf.lock_at_start ? "checked" : ""}></div>\n    ${f("cDaily", "Tagesverlust-Limit ($)", cf.daily_loss, "0 = keins", \'min="0" step="50"\')}\n    ${f("cCons", "Konsistenzregel (%)", cf.consistency_pct, "Bester Tag darf höchstens so viel % des Gesamtgewinns sein. 0 = keine", \'min="0" max="100" step="5"\')}\n    ${f("cDays", "Mindest-Handelstage", cf.min_days, "0 = keine", \'min="0" step="1"\')}\n    <span class="lbl">Was zählt & Schutz</span>\n    <div class="row"><label>Welche Trades zählen</label><div class="seg" role="group">${[["alle", "Bot + eigene"], ["bot", "Nur Bot"], ["eigen", "Nur eigene"]].map(([k, l]) => `<button type="button" data-cs="${k}" aria-pressed="${cf.source === k}">${l}</button>`).join("")}</div></div>\n    <div class="row"><label for="cGuard">Bot-Schutz<small>Der Bot nimmt keine neuen Trades mehr, wenn der Spielraum unter den Puffer fällt oder das Risiko eines Trades größer ist</small></label><input id="cGuard" type="checkbox" class="chk" ${cf.guard ? "checked" : ""}></div>\n    ${f("cBuf", "Sicherheits-Puffer ($)", cf.guard_buffer, "Abstand, den der Bot zur Grenze immer frei lässt", \'min="0" step="50"\')}\n    <p class="hint" style="margin:0">Trag die Werte genau so ein, wie sie in den Regeln deiner Firma stehen. Die App rechnet mit abgeschlossenen Trades (eigene und Bot) und den offenen Bot-Positionen. Kommissionen und die Uhrzeit des Tageswechsels können bei deiner Firma leicht abweichen. Lass deshalb etwas Puffer.</p>\n    <div class="inline wrap-gap"><button class="btn primary" id="cSave">${cf.enabled ? "Speichern" : "Challenge starten"}</button>${cf.enabled ? \'<button class="btn ghost-danger" id="cOff">Challenge beenden</button>\' : ""}</div>`;\n  let src = cf.source || "alle";\n  document.querySelectorAll("[data-cs]").forEach(b => b.onclick = () => { src = b.dataset.cs; document.querySelectorAll("[data-cs]").forEach(x => x.setAttribute("aria-pressed", x === b)); });\n  const save = async enabled => {\n    const n = id => parseFloat($("#" + id).value) || 0;\n    try {\n      await api("/api/config", {challenge: {enabled, name: $("#cName").value.trim(), phase: $("#cPhase").value, start_balance: n("cSize"), start_day: $("#cStart").value,\n        profit_target: n("cTarget"), max_dd: n("cDd"), dd_type: $("#cType").value, lock_at_start: $("#cLock").checked, daily_loss: n("cDaily"),\n        consistency_pct: n("cCons"), min_days: Math.round(n("cDays")), source: src, guard: $("#cGuard").checked, guard_buffer: n("cBuf")}});\n      S = await api("/api/state"); toast(enabled ? "Challenge gespeichert" : "Challenge beendet"); challenge(true);\n    } catch (e) { toast(e.message); }\n  };\n  $("#cSave").onclick = () => save(true);\n  if ($("#cOff")) $("#cOff").onclick = () => confirmBtn($("#cOff"), "Wirklich beenden?", () => save(false));\n}\n\n\n\n/* ───────── Offene Positionen: Details, Abstände in Ticks und Geld, Stop/Ziel verschieben ───────── */\nlet posKey = "";\nfunction posMath(p, price) {\n  const I = (S.instruments || {})[p.root] || {tick: 0.25, pv: 2}, d = p.side === "long" ? 1 : -1;\n  const pts = (a, b) => (b - a) * d;               // Punkte in Gewinnrichtung\n  const usdOf = pt => pt * I.pv * p.qty;\n  return {I, d, pts, usdOf, ticks: pt => Math.round(pt / I.tick)};\n}\nconst fPts = v => (v > 0 ? "+" : v < 0 ? "−" : "") + Math.abs(v).toLocaleString("de-DE", {minimumFractionDigits: 2, maximumFractionDigits: 2});\nconst fTicks = v => (v > 0 ? "+" : v < 0 ? "−" : "") + Math.abs(v).toLocaleString("de-DE") + " Ticks";\nfunction posPanel() {\n  const box = $("#posBox"); if (!box) return;\n  const key = JSON.stringify(S.positions.map(p => [p.id, p.sl, p.tp, p.qty, p.status]));\n  if (key !== posKey || !box.querySelector(".pcs, .empty")) {\n    posKey = key;\n    box.innerHTML = S.positions.length ? `<div class="pcs">${S.positions.map(posCard).join("")}</div>` : `<div class="empty">Keine offene Position.</div>`;\n    posBind();\n  }\n  S.positions.forEach(posLive);\n}\nfunction posCard(p) {\n  const m = posMath(p, p.last), risk = m.pts(p.entry, p.sl), rew = p.tp != null ? m.pts(p.entry, p.tp) : null;\n  const rr = rew != null && risk < 0 ? rew / -risk : null, paper = p.broker === "paper";\n  const step = m.I.tick, pt = 1;\n  return `<article class="pc ${p.side}" id="pc-${p.id}">\n    <div class="pc-h">\n      <span class="side ${p.side}">${p.side === "long" ? "LONG" : "SHORT"}</span><b class="mono">${p.qty}× ${esc(p.contract)}</b>\n      <span class="chip">${esc(p.setup)}</span>${p.is_test ? \'<span class="chip mute">Test</span>\' : ""}${p.mgmt ? `<span class="chip">${esc(p.mgmt)}</span>` : ""}\n      <span class="hint" id="pcAge-${p.id}"></span>\n      <div class="pc-pl"><b id="pcPl-${p.id}">–</b><small id="pcPl2-${p.id}"></small></div>\n    </div>\n    <div class="pc-bar"><div class="pc-track"><i class="pc-risk"></i><i class="pc-rew"></i><span class="pc-mk e" id="pcMe-${p.id}"></span><span class="pc-mk n" id="pcMn-${p.id}"></span></div>\n      <div class="pc-bl"><span class="neg">Stop</span><span class="pc-le" id="pcLe-${p.id}">Einstieg</span><span class="pos">${p.tp != null ? "Ziel" : "kein Ziel"}</span></div></div>\n    <div class="pc-g">\n      <div class="pc-c sl"><span class="l">Stop-Loss</span><b class="mono">${px(p.sl)}</b>\n        <small>${fPts(risk)} Pkt · ${fTicks(m.ticks(risk))}</small><small class="${risk >= 0 ? "pos" : "neg"}">${risk >= 0 ? "gesichert" : "Risiko"} ${sUsd(m.usdOf(risk))} ab Einstieg</small>\n        <small id="pcSlNow-${p.id}"></small></div>\n      <div class="pc-c"><span class="l">Einstieg</span><b class="mono">${px(p.entry)}</b>\n        <small>Kurs jetzt <b class="mono" id="pcNow-${p.id}">–</b> <span id="pcLive-${p.id}"></span></small><small id="pcNowD-${p.id}"></small><small>seit ${dtm(p.opened)}</small></div>\n      <div class="pc-c tp"><span class="l">Take-Profit</span><b class="mono">${p.tp != null ? px(p.tp) : "–"}</b>\n        ${rew != null ? `<small>${fPts(rew)} Pkt · ${fTicks(m.ticks(rew))}</small><small class="pos">Chance ${sUsd(m.usdOf(rew))} ab Einstieg</small><small id="pcTpNow-${p.id}"></small>` : "<small>kein festes Ziel</small>"}</div>\n      <div class="pc-c"><span class="l">Chance / Risiko</span><b class="mono">${rr != null ? "1 : " + rr.toFixed(2).replace(".", ",") : risk >= 0 ? "risikofrei" : "–"}</b>\n        <small>1 Tick = ${m.I.tick.toString().replace(".", ",")} Pkt = ${usd2(m.I.tick * m.I.pv)} je Kontrakt</small><small>1 Pkt = ${usd2(m.I.pv * p.qty)} bei ${p.qty} Kontrakt${p.qty === 1 ? "" : "en"}</small></div>\n    </div>\n    <div class="pc-a">\n      <div class="pc-e"><label for="sl-${p.id}">Stop verschieben</label>\n        <div class="pc-in"><button class="btn" data-adj="sl" data-id="${p.id}" data-d="-${pt}" title="1 Punkt runter">−1</button>\n          <input id="sl-${p.id}" type="number" step="${step}" value="${p.sl}" data-orig="${p.sl}">\n          <button class="btn" data-adj="sl" data-id="${p.id}" data-d="${pt}" title="1 Punkt hoch">+1</button>\n          <button class="btn primary" data-set="sl" data-id="${p.id}">Setzen</button></div>\n        <small class="hint" id="slPrev-${p.id}">&nbsp;</small></div>\n      <div class="pc-e"><label for="tp-${p.id}">Ziel verschieben</label>\n        <div class="pc-in"><button class="btn" data-adj="tp" data-id="${p.id}" data-d="-${pt}" title="1 Punkt runter">−1</button>\n          <input id="tp-${p.id}" type="number" step="${step}" value="${p.tp ?? ""}" data-orig="${p.tp ?? ""}" placeholder="kein Ziel">\n          <button class="btn" data-adj="tp" data-id="${p.id}" data-d="${pt}" title="1 Punkt hoch">+1</button>\n          <button class="btn primary" data-set="tp" data-id="${p.id}">Setzen</button>\n          ${paper && p.tp != null ? `<button class="btn" data-cleartp="${p.id}" title="Ziel entfernen, Trade läuft bis Stop oder manuell">Kein Ziel</button>` : ""}</div>\n        <small class="hint" id="tpPrev-${p.id}">&nbsp;</small></div>\n      <div class="pc-q">\n        <button class="btn be" data-id="${p.id}" ${p.sl === p.entry ? "disabled" : ""}>Stop auf Einstieg (BE)</button>\n        <button class="btn ghost-danger cl" data-id="${p.id}" data-key="cl-${p.id}" data-orig="Position schließen">${armed("cl-" + p.id) ? "Sicher?" : "Position schließen"}</button>\n      </div>\n    </div></article>`;\n}\nfunction posLive(p) {\n  const el = $("#pc-" + p.id); if (!el) return;\n  const m = posMath(p), now = p.last ?? p.entry, inPts = m.pts(p.entry, now);\n  const risk = -m.pts(p.entry, p.sl) || 1e-9, r = inPts / risk;\n  const pl = $("#pcPl-" + p.id); pl.textContent = sUsd(p.upnl ?? m.usdOf(inPts)); pl.className = "mono " + cls(p.upnl ?? inPts);\n  $("#pcPl2-" + p.id).textContent = `${fPts(inPts)} Pkt · ${fTicks(m.ticks(inPts))}${m.pts(p.entry, p.sl) < 0 ? ` · ${r >= 0 ? "+" : "−"}${Math.abs(r).toFixed(2).replace(".", ",")} R` : ""}`;\n  $("#pcNow-" + p.id).textContent = px(now);\n  const lv = $("#pcLive-" + p.id), pAge = p.last_ts ? Math.max(0, Math.round(Date.now() / 1000 - p.last_ts)) : null;\n  if (lv) lv.innerHTML = pAge == null ? "" : pAge <= 45 ? `<span class="live-dot"></span>live · vor ${pAge} s` : `<span class="muted">Stand vor ${pAge < 3600 ? Math.round(pAge / 60) + " Min" : "über 1 Std"}</span>`;\n  const nd = $("#pcNowD-" + p.id); nd.textContent = `${fPts(inPts)} Pkt · ${fTicks(m.ticks(inPts))}`; nd.className = cls(inPts);\n  const toSl = m.pts(now, p.sl);\n  $("#pcSlNow-" + p.id).textContent = `ab jetzt bis Stop: ${fTicks(m.ticks(toSl))} · ${sUsd(m.usdOf(toSl))}`;\n  if (p.tp != null) { const toTp = m.pts(now, p.tp); $("#pcTpNow-" + p.id).textContent = `ab jetzt bis Ziel: ${fTicks(m.ticks(toTp))} · ${sUsd(m.usdOf(toTp))}`; }\n  const age = $("#pcAge-" + p.id); const mins = Math.max(0, Math.round((Date.now() / 1000 - p.opened) / 60)); age.textContent = mins < 60 ? `${mins} Min offen` : `${Math.floor(mins / 60)} Std ${mins % 60} Min offen`;\n  // Leiste: links Stop, Mitte Einstieg, rechts Ziel (ohne Ziel: 2R)\n  const lo = p.sl, hi = p.tp ?? (p.entry + (p.entry - p.sl) * 2);\n  const at = v => Math.max(0, Math.min(100, ((v - lo) / (hi - lo || 1)) * 100));\n  const e = at(p.entry), n = at(now);\n  el.querySelector(".pc-risk").style.width = e + "%"; el.querySelector(".pc-rew").style.left = e + "%"; el.querySelector(".pc-rew").style.width = (100 - e) + "%";\n  $("#pcMe-" + p.id).style.left = e + "%"; $("#pcMn-" + p.id).style.left = n + "%";\n  const le = $("#pcLe-" + p.id); if (le) le.style.left = Math.max(12, Math.min(88, e)) + "%";\n}\nfunction posPreview(p, which) {\n  const inp = $(`#${which}-${p.id}`), out = $(`#${which}Prev-${p.id}`); if (!inp || !out) return;\n  const v = parseFloat(inp.value), m = posMath(p);\n  if (!isFinite(v) || String(v) === String(inp.dataset.orig)) { out.innerHTML = "&nbsp;"; return; }\n  const d = m.pts(p.entry, v);\n  out.innerHTML = `Neu: ${fPts(d)} Pkt · ${fTicks(m.ticks(d))} ab Einstieg = <b class="${cls(d)}">${sUsd(m.usdOf(d))}</b>`;\n}\nfunction posBind() {\n  const byId = id => S.positions.find(x => x.id === id);\n  document.querySelectorAll("#posBox [data-adj]").forEach(b => b.onclick = () => {\n    const p = byId(b.dataset.id), inp = $(`#${b.dataset.adj}-${p.id}`), I = posMath(p).I;\n    const base = parseFloat(inp.value) || (b.dataset.adj === "tp" ? p.last ?? p.entry : p.sl);\n    inp.value = (Math.round((base + parseFloat(b.dataset.d)) / I.tick) * I.tick).toFixed(2); posPreview(p, b.dataset.adj); });\n  document.querySelectorAll("#posBox .pc-in input").forEach(inp => inp.oninput = () => { const [w, id] = inp.id.split(/-(.+)/); posPreview(byId(id), w); });\n  document.querySelectorAll("#posBox [data-set]").forEach(b => b.onclick = () => {\n    const w = b.dataset.set, v = parseFloat($(`#${w}-${b.dataset.id}`).value);\n    if (!isFinite(v)) return toast(w === "sl" ? "Bitte einen Stop-Preis eintragen" : "Bitte einen Ziel-Preis eintragen");\n    act(() => api(`/api/position/${b.dataset.id}/modify`, {[w]: v}), w === "sl" ? "Stop verschoben" : "Ziel verschoben");\n  });\n  document.querySelectorAll("#posBox [data-cleartp]").forEach(b => b.onclick = () => act(() => api(`/api/position/${b.dataset.cleartp}/modify`, {clear_tp: true}), "Ziel entfernt"));\n  document.querySelectorAll("#posBox .be").forEach(b => b.onclick = () => act(() => api(`/api/position/${b.dataset.id}/breakeven`, {}), "Stop auf Break-even gezogen"));\n  document.querySelectorAll("#posBox .cl").forEach(b => b.onclick = () => confirmBtn(b, "Sicher?", () => act(() => api(`/api/position/${b.dataset.id}/close`, {}), "Position geschlossen")));\n}\nfunction cockpit(full) {\n  const m = $("#main"), t = S.today, lossUsed = t.max_loss > 0 ? Math.min(100, Math.max(0, -t.pnl / t.max_loss * 100)) : 0;\n  if (full || !$("#ck")) m.innerHTML = `<div id="ck" style="display:contents">\n    <div id="setup"></div>\n    <section class="kpis" id="todayK"></section>\n    <section id="chCard" hidden></section>\n    <section class="panel perf" id="perf"></section>\n    <section class="section"><div class="section-h"><h2>Offene Positionen</h2><p class="hint">Jede Position hat einen Stop-Loss beim Broker.</p></div><div id="posBox"></div></section>\n    <div class="grid2 ck-2"><section class="section" id="lvSec"></section><section class="section" id="newsSec"></section></div>\n    <section class="section"><div class="section-h"><h2>Vorschläge</h2><p class="hint" id="sugHint"></p></div><div id="sugs"></div></section>\n    <div class="grid2">\n      <section class="section"><div class="section-h"><h2>Signale</h2><button class="btn ghost-danger" id="delTests" data-key="deltests" hidden style="padding:4px 10px;font-size:12px">Test-Daten löschen</button></div><div class="panel scroll" id="sigBox"></div></section>\n      <section class="section"><h2>Aktivität</h2><div class="panel feed" id="feed"></div></section>\n    </div></div>`;\n  setupPanel();\n  newsPanel();\n  levelsPanel();\n  chCard();\n  const perfKey = JSON.stringify([PERF, S.daily]);\n  if (perfKey !== cockpit._perfKey || full) { cockpit._perfKey = perfKey; $("#perf").innerHTML = perfCard(); bindPerf($("#perf"), () => { cockpit._perfKey = ""; cockpit(false); }); }\n  $("#todayK").innerHTML = [\n    ["Kontostand", S.balance == null ? "–" : usd2(S.balance), ""],\n    ["P&L heute", usd(t.pnl), cls(t.pnl)],\n    ["Trades heute", `${t.trades} / ${t.max_trades}`, ""],\n    ["Tageslimit genutzt", t.max_loss > 0 ? Math.round(lossUsed) + " %" : "aus", lossUsed >= 80 ? "neg" : "", lossUsed],\n    ["Modus", S.config.auto_mode ? "Automatisch" : "Vorschläge", S.config.auto_mode ? "pos" : ""],\n  ].map(([l, v, c, meter]) => `<div class="kpi"><span class="l">${l}</span><span class="v ${c}">${v}</span>${meter != null ? `<div class="meter"><i style="width:${meter}%"></i></div>` : ""}</div>`).join("");\n  $("#sugHint").textContent = S.config.auto_mode ? "Auto-Modus ist an: Signale werden ohne Rückfrage ausgeführt." : `Verfallen nach ${S.config.suggestion_timeout_sec} s ohne Antwort.`;\n\n  // Vorschläge nur neu aufbauen, wenn sich die Menge ändert (Eingaben bleiben erhalten)\n  const key = S.pending.map(p => p.id).join(",");\n  if (key !== pendingKey) {\n    pendingKey = key;\n    $("#sugs").innerHTML = S.pending.length ? `<div class="cards">${S.pending.map(sugCard).join("")}</div>`\n      : `<div class="empty">Keine offenen Vorschläge. ${S.config.auto_mode ? "Im Auto-Modus gehen Signale direkt in den Markt." : "Neue Signale aus TradingView erscheinen hier zum Annehmen oder Ablehnen."}</div>`;\n    S.pending.forEach(p => {\n      const card = $(`#s-${p.id}`), q = $(".q", card), sl = $(".sl", card), tp = $(".tp", card);\n      const upd = () => {\n        const inst = S.instruments[p.root], slv = parseFloat(sl.value), qv = parseInt(q.value) || 0;\n        const risk = isFinite(slv) ? Math.abs(p.entry - slv) * qv * inst.pv : NaN;\n        $(".risk", card).textContent = usd(risk);\n        const tpv = parseFloat(tp.value); $(".rr", card).textContent = isFinite(tpv) && isFinite(slv) ? num2(Math.abs(tpv - p.entry) / Math.abs(p.entry - slv)) + " R" : "–";\n      };\n      [q, sl, tp].forEach(i => i.oninput = upd); upd();\n      $(".acc", card).onclick = () => act(() => api(`/api/signal/${p.id}/accept`, {qty: q.value, sl: sl.value, tp: tp.value}), "Trade eröffnet");\n      $(".rej", card).onclick = () => act(() => api(`/api/signal/${p.id}/reject`, {}), "Vorschlag abgelehnt");\n    });\n  }\n  timers();\n\n  posPanel();\n\n  const stChip = s => ({"ausgeführt": "good", "offen": "", "abgelehnt": "mute", "verfallen": "mute", "ersetzt": "mute", "blockiert": "warn", "fehler": "bad"}[s] ?? "mute");\n  $("#sigBox").innerHTML = S.signals.length ? `<table><thead><tr><th class="t">Zeit</th><th class="t">Signal</th><th>Anz.</th><th>Stop</th><th class="t">Status</th><th class="t">Grund</th></tr></thead><tbody>\n    ${S.signals.slice(0, 15).map(s => `<tr><td class="t mono">${tm(s.ts)}</td><td class="t"><b class="side ${s.side}" style="font-size:12px">${s.side === "long" ? "L" : "S"}</b> ${esc(s.root)} <span class="chip">${esc(s.setup)}</span>${s.is_test ? \' <span class="chip mute">Test</span>\' : ""}</td>\n      <td>${s.qty ?? "–"}</td><td>${px(s.sl)}</td><td class="t"><span class="chip ${stChip(s.status)}">${esc(s.status)}</span></td>\n      <td class="wrap">${esc(s.reason || (s.flags || []).join(" · "))}</td></tr>`).join("")}</tbody></table>`\n    : `<p class="hint">Noch keine Signale. Teste die Verbindung unter Einstellungen → TradingView.</p>`;\n  const dt = $("#delTests");\n  if (dt) {\n    dt.hidden = !(S.signals.some(x => x.is_test) || S.positions.some(x => x.is_test) || S.has_tests);\n    if (!armed("deltests")) dt.textContent = "Test-Daten löschen";\n    dt.onclick = () => confirmBtn(dt, "Alle Tests löschen?", async () => {\n      try { const r = await api("/api/tests/delete", {}); toast(`Gelöscht: ${r.trades} Test-Trades, ${r.signals} Test-Signale`); S = await api("/api/state"); render(true); } catch (e) { toast(e.message); }\n    });\n  }\n  $("#feed").innerHTML = S.events.map(e => `<div><time>${tm(e.ts)}</time><span class="${e.level}">${esc(e.text)}</span></div>`).join("") || `<p class="hint">Noch keine Aktivität.</p>`;\n}\nlet setupKey = "";\nfunction setupPanel() {\n  let hidden = false; try { hidden = localStorage.getItem("fvg-setup-hidden") === "1"; } catch (e) {}\n  const hasSignal = S.signals.some(x => !x.is_test) || !!S.tv.last_msg;\n  let pineCopied = false; try { pineCopied = localStorage.getItem("fvg-pine-copied") === "1"; } catch (e) {}\n  const steps = [\n    {done: !!S.hook_url, title: "Internet-Verbindung", body: S.hook_url ? "Aktiv. TradingView kann deine App erreichen." : `Wird automatisch aufgebaut … (${esc(S.tunnel.status)})`},\n    {done: hasSignal || pineCopied, title: "Script in TradingView", body: `Kopiere das Script, öffne in TradingView unten den <b>Pine Editor</b>, lösche den Inhalt, füge es ein und klicke <b>Zum Chart hinzufügen</b>. Chart: <b>NQ1!</b> oder <b>ES1!</b>, 5 Minuten.\n      <div style="margin-top:8px"><button class="btn" id="cpPine">Script kopieren</button></div>`},\n    {done: S.hook_confirmed, title: "Alert anlegen", body: `In TradingView auf den Wecker klicken → Bedingung <b>FVG Bot</b> → <b>Orderausführungen und alert()-Aufrufe</b>. Unter Benachrichtigungen <b>Webhook-URL</b> anhaken und diese Adresse einfügen:\n      <div class="copyrow" style="margin:8px 0"><div class="code">${S.hook_url ? esc(S.hook_url) : "kommt gleich …"}</div><button class="btn" id="cpHook" ${S.hook_url ? "" : "disabled"}>Kopieren</button></div>\n      Bei Nachricht diesen Text einsetzen: <div class="copyrow" style="margin:8px 0"><div class="code">{{strategy.order.alert_message}}</div><button class="btn" id="cpMsg">Kopieren</button></div>\n      <button class="btn primary" id="hookOk" ${S.hook_url ? "" : "disabled"}>Alert ist angelegt</button>`},\n    {done: hasSignal, title: "Erstes Signal", body: hasSignal ? "Signale kommen an. Fertig!" : `Sobald die Strategie handelt, erscheint hier ein Vorschlag. Probier es jetzt aus: <button class="btn" id="tryIt">Test-Signal senden</button>`},\n  ];\n  const allDone = steps.every(x => x.done);\n  const key = JSON.stringify([hidden, steps.map(x => [x.done, x.body])]);\n  if (key === setupKey) return; setupKey = key;\n  const box = $("#setup");\n  if (hidden || allDone) { box.innerHTML = hidden && !allDone ? `<p class="hint">Einrichtung ausgeblendet · <button class="btn" id="showSetup" style="padding:3px 8px;font-size:12px">Anzeigen</button></p>` : ""; \n    const sh = $("#showSetup"); if (sh) sh.onclick = () => { try { localStorage.removeItem("fvg-setup-hidden"); } catch (e) {} setupKey = ""; setupPanel(); }; return; }\n  const next = steps.findIndex(x => !x.done);\n  box.innerHTML = `<section class="panel"><div class="section-h"><h2>Einrichtung · ${steps.filter(x => x.done).length} von ${steps.length}</h2><button class="btn" id="hideSetup" style="padding:4px 10px;font-size:12px">Ausblenden</button></div>\n    <ol class="wizard">${steps.map((x, i) => `<li class="${x.done ? "done" : i === next ? "now" : ""}"><span class="num">${x.done ? "✓" : i + 1}</span><div><b>${x.title}</b><div class="hint" style="font-size:13px;margin-top:2px">${x.body}</div></div></li>`).join("")}</ol></section>`;\n  $("#hideSetup").onclick = () => { try { localStorage.setItem("fvg-setup-hidden", "1"); } catch (e) {} setupKey = ""; setupPanel(); };\n  const b = id => $("#" + id);\n  if (b("cpPine")) b("cpPine").onclick = async () => { try { const r = await api("/api/pine"); copyText(r.source, "Script"); try { localStorage.setItem("fvg-pine-copied", "1"); } catch (e) {} setupKey = ""; setupPanel(); } catch (e) { toast(e.message); } };\n  if (b("cpHook")) b("cpHook").onclick = () => copyText(S.hook_url, "Adresse");\n  if (b("cpMsg")) b("cpMsg").onclick = () => copyText("{{strategy.order.alert_message}}", "Nachricht");\n  if (b("hookOk")) b("hookOk").onclick = () => act(() => api("/api/hook-confirm", {}), "Super, Alert ist verbunden");\n  if (b("tryIt")) b("tryIt").onclick = () => act(() => api("/api/test-signal", {fam: "NQ", side: "long"}), "Test-Signal gesendet");\n}\nfunction timers() {\n  (S.pending || []).forEach(p => { const el = $(`#s-${p.id} .timer`); if (el) { const s = Math.max(0, Math.round(p.expires - Date.now() / 1000)); el.textContent = `noch ${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`; } });\n}\nfunction sugCard(p) {\n  const inst = S.instruments[p.root];\n  return `<article class="sug ${p.side}" id="s-${p.id}">\n    <div class="sug-h"><span class="side ${p.side}">${p.side === "long" ? "LONG" : "SHORT"}</span><span class="mono">${esc(p.contract)}</span><span class="chip">${esc(p.setup)}</span>${p.is_test ? \'<span class="chip mute">Test</span>\' : ""}<span class="timer"></span></div>\n    <div class="lv"><div><span>Einstieg ca.</span><b>${px(p.entry)}</b></div><div><span>Risiko</span><b class="risk neg">–</b></div><div><span>Chance</span><b class="rr">–</b></div></div>\n    <div class="edit">\n      <label>Anzahl ${esc(p.root)}<input class="q" type="number" min="1" max="${S.config.sizing.max_qty}" step="1" value="${p.qty}"></label>\n      <label>Stop-Loss<input class="sl" type="number" step="${inst.tick}" value="${p.sl}"></label>\n      <label>Ziel<input class="tp" type="number" step="${inst.tick}" value="${p.tp}"></label>\n    </div>\n    ${p.flags && p.flags.length ? `<div class="flags">${p.flags.map(f => `<span class="chip warn">${esc(f)}</span>`).join("")}</div>` : ""}\n    <div class="actions"><button class="btn good acc">Annehmen</button><button class="btn rej">Ablehnen</button></div>\n  </article>`;\n}\n\n/* ───────── Statistik ───────── */\n/* ───────── Grafiken ───────── */\nlet PERF = {period: "monat", src: "alle"};\ntry { PERF = Object.assign(PERF, JSON.parse(localStorage.getItem("fvg-perf") || "{}")); } catch (e) {}\nconst savePerf = () => { try { localStorage.setItem("fvg-perf", JSON.stringify(PERF)); } catch (e) {} };\nconst isoDay = d => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;\nfunction perfData(period, src) {\n  const now = new Date(), today = isoDay(now);\n  let from = "0000";\n  if (period === "heute") from = today;\n  else if (period === "woche") { const d = new Date(now); d.setDate(d.getDate() - ((d.getDay() + 6) % 7)); from = isoDay(d); }\n  else if (period === "monat") from = today.slice(0, 8) + "01";\n  const days = Object.keys(S.daily || {}).filter(k => k >= from && k <= today).sort().map(k => {\n    const d = S.daily[k], b = d.bot || {pnl: 0, n: 0, w: 0}, o = d.eigen || {pnl: 0, n: 0, w: 0};\n    const r = src === "bot" ? b : src === "eigen" ? o : {pnl: b.pnl + o.pnl, n: b.n + o.n, w: b.w + o.w};\n    return {day: k, pnl: r.pnl, n: r.n, w: r.w};\n  }).filter(r => r.n);\n  const n = days.reduce((a, r) => a + r.n, 0), w = days.reduce((a, r) => a + r.w, 0), pnl = days.reduce((a, r) => a + r.pnl, 0);\n  let eq = 0; const curve = days.map(r => (eq += r.pnl));\n  return {days, n, w, l: n - w, pnl, curve, winDays: days.filter(r => r.pnl > 0).length,\n          best: days.reduce((a, r) => !a || r.pnl > a.pnl ? r : a, null), worst: days.reduce((a, r) => !a || r.pnl < a.pnl ? r : a, null)};\n}\nfunction donutSvg(w, l, size = 170) {\n  const r = 62, c = 2 * Math.PI * r, tot = w + l, fw = tot ? w / tot : 0;\n  const gap = tot && w && l ? 3 : 0, lw = Math.max(0, c * fw - gap), ll = Math.max(0, c * (1 - fw) - gap);\n  return `<svg viewBox="0 0 170 170" width="${size}" height="${size}" role="img" aria-label="Gewinn- und Verlust-Trades">\n    <circle cx="85" cy="85" r="${r}" fill="none" stroke="var(--sunk)" stroke-width="16"/>\n    ${tot ? `<circle cx="85" cy="85" r="${r}" fill="none" stroke="var(--pos)" stroke-width="16" stroke-linecap="round" stroke-dasharray="${lw} ${c}" transform="rotate(-90 85 85)"/>\n    <circle cx="85" cy="85" r="${r}" fill="none" stroke="var(--neg)" stroke-width="16" stroke-linecap="round" stroke-dasharray="${ll} ${c}" stroke-dashoffset="${-(c * fw)}" transform="rotate(-90 85 85)"/>` : ""}\n  </svg>`;\n}\nfunction sparkSvg(vals, W = 320, H = 70) {\n  if (vals.length < 2) return `<div class="hint" style="height:${H}px;display:grid;place-items:center">Kurve ab 2 Handelstagen</div>`;\n  const all = [0, ...vals], lo = Math.min(...all), hi = Math.max(...all), span = hi - lo || 1;\n  const x = i => 4 + (W - 8) * i / (all.length - 1), y = v => 6 + (H - 12) * (1 - (v - lo) / span);\n  const line = all.map((v, i) => `${i ? "L" : "M"}${x(i).toFixed(1)},${y(v).toFixed(1)}`).join("");\n  const col = vals[vals.length - 1] >= 0 ? "var(--pos)" : "var(--neg)";\n  return `<svg viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" style="height:${H}px" role="img" aria-label="Equity-Verlauf">\n    <line x1="4" x2="${W - 4}" y1="${y(0)}" y2="${y(0)}" class="gl" stroke-dasharray="3 3"/>\n    <path d="${line}L${x(all.length - 1)},${y(lo)}L${x(0)},${y(lo)}Z" fill="${col}" fill-opacity=".10"/>\n    <path d="${line}" fill="none" stroke="${col}" stroke-width="2" vector-effect="non-scaling-stroke"/></svg>`;\n}\nfunction dayBarsSvg(days) {\n  if (!days.length) return \'<p class="hint">Noch keine Handelstage im Zeitraum.</p>\';\n  const W = 900, H = 200, L = 56, R = 8, T = 10, B = 24, n = days.length;\n  const lo0 = Math.min(0, ...days.map(d => d.pnl)), hi0 = Math.max(0, ...days.map(d => d.pnl));\n  const span = hi0 - lo0 || 100, stepRaw = span / 4, mag = 10 ** Math.floor(Math.log10(stepRaw)), step = [1, 2, 2.5, 5, 10].find(m => m * mag >= stepRaw) * mag;\n  const lo = Math.floor(lo0 / step) * step, hi = Math.ceil(hi0 / step) * step || step;\n  const y = v => T + (H - T - B) * (1 - (v - lo) / (hi - lo)), bw = (W - L - R) / n;\n  let g = ""; for (let v = lo; v <= hi + 1e-9; v += step) g += `<line class="gl" x1="${L}" x2="${W - R}" y1="${y(v)}" y2="${y(v)}"/><text x="${L - 8}" y="${y(v) + 4}" text-anchor="end">${kUsd(v)}</text>`;\n  const every = Math.ceil(n / 10);\n  const bars = days.map((d, i) => { const x0 = L + i * bw + bw * .18, w = Math.max(2, bw * .64), y0 = y(Math.max(0, d.pnl)), h = Math.max(1, Math.abs(y(d.pnl) - y(0)));\n    return `<rect x="${x0}" y="${y0}" width="${w}" height="${h}" rx="2" fill="${d.pnl >= 0 ? "var(--pos)" : "var(--neg)"}"><title>${d.day}: ${sUsd(d.pnl)} · ${d.n} Trades</title></rect>` +\n      (i % every === 0 ? `<text x="${x0 + w / 2}" y="${H - 6}" text-anchor="middle">${d.day.slice(8)}.${d.day.slice(5, 7)}.</text>` : ""); }).join("");\n  return `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="P&L je Handelstag">${g}${bars}</svg>`;\n}\nconst PERIODS = [["heute", "Heute"], ["woche", "Woche"], ["monat", "Monat"], ["gesamt", "Gesamt"]];\nconst SOURCES = [["alle", "Alle"], ["bot", "Bot"], ["eigen", "Eigene"]];\nfunction perfCard(compact) {\n  const d = perfData(PERF.period, PERF.src), wr = d.n ? d.w / d.n * 100 : null;\n  const seg = (list, key) => `<div class="seg" role="group">${list.map(([k, l]) => `<button type="button" data-${key}="${k}" aria-pressed="${PERF[key] === k}">${l}</button>`).join("")}</div>`;\n  return `<div class="perf-h"><h2>Performance</h2><div class="perf-ctl">${seg(PERIODS, "period")}${seg(SOURCES, "src")}</div></div>\n    <div class="perf-b">\n      <div class="ring">${donutSvg(d.w, d.l)}<div class="ring-c"><span class="ring-v ${cls(d.pnl)}">${d.n ? sUsd(d.pnl) : "–"}</span><span class="ring-l">${wr == null ? "keine Trades" : `${Math.round(wr)} % Treffer`}</span></div></div>\n      <div class="perf-side">\n        <div class="perf-stats">\n          <div><span>Gewinner</span><b class="pos">${d.w}</b></div><div><span>Verlierer</span><b class="neg">${d.l}</b></div>\n          <div><span>Handelstage</span><b>${d.days.length}${d.days.length ? ` <small class="hint">(${d.winDays} grün)</small>` : ""}</b></div>\n          <div><span>Ø pro Tag</span><b class="${cls(d.days.length ? d.pnl / d.days.length : 0)}">${d.days.length ? sUsd(d.pnl / d.days.length) : "–"}</b></div>\n        </div>\n        ${compact ? "" : ""}<div class="spark">${sparkSvg(d.curve)}</div>\n      </div>\n    </div>`;\n}\nfunction bindPerf(root, rerender) {\n  root.querySelectorAll("[data-period]").forEach(b => b.onclick = () => { PERF.period = b.dataset.period; savePerf(); rerender(); });\n  root.querySelectorAll("[data-src]").forEach(b => b.onclick = () => { PERF.src = b.dataset.src; savePerf(); rerender(); });\n}\n\nlet STAB = "uebersicht";\ntry { STAB = localStorage.getItem("fvg-stab") || "uebersicht"; } catch (e) {}\nfunction stats() {\n  if (!$("#stWrap")) {\n    $("#main").innerHTML = `<div id="stWrap" style="display:contents">\n      <div class="subtabs" role="tablist">${[["uebersicht", "Übersicht"], ["edge", "Edge-Check"], ["muster", "Session-Muster"]].map(([k, l]) =>\n        `<button type="button" role="tab" data-st="${k}" aria-selected="${STAB === k}">${l}</button>`).join("")}</div>\n      <div id="stBody" style="display:contents"></div></div>`;\n    document.querySelectorAll("[data-st]").forEach(b => b.onclick = () => { STAB = b.dataset.st; try { localStorage.setItem("fvg-stab", STAB); } catch (e) {}\n      document.querySelectorAll("[data-st]").forEach(x => x.setAttribute("aria-selected", x === b)); $("#stBody").innerHTML = ""; stats(); });\n  }\n  if (STAB === "edge") return edgeView();\n  if (STAB === "muster") return musterView();\n  statsOverview();\n}\nfunction statsOverview() {\n  const st = S.stats;\n  const all = perfData("gesamt", "alle"), last30 = all.days.slice(-30);\n  const setups = Object.entries(st.by_setup).sort((a, b) => b[1].net - a[1].net), maxAbs = Math.max(1, ...setups.map(([, v]) => Math.abs(v.net)));\n  $("#stBody").innerHTML = `\n    <section class="panel perf" id="perfS"></section>\n    <section class="panel"><div class="section-h"><h2>P&L je Handelstag</h2><p class="hint">Letzte ${last30.length} Handelstage, Bot und eigene Trades</p></div>${dayBarsSvg(last30)}</section>\n    <section class="kpis">${[\n      ["Netto-Gewinn", usd(st.net), cls(st.net)], ["Trades", st.n, ""], ["Trefferquote", pct(st.winrate), ""],\n      ["Profit-Faktor", num2(st.pf), st.pf >= 1 ? "pos" : st.pf != null ? "neg" : ""], ["Ø R pro Trade", num2(st.avg_r), cls(st.avg_r)],\n      ["Max. Drawdown", usd(st.max_dd), st.max_dd < 0 ? "neg" : ""], ["Ø Gewinn", usd(st.avg_win), "pos"], ["Ø Verlust", usd(st.avg_loss), "neg"],\n    ].map(([l, v, c]) => `<div class="kpi"><span class="l">${l}</span><span class="v ${c}">${v}</span></div>`).join("")}</section>\n    <section class="panel"><div class="section-h"><h2>Equity des Bots</h2><p class="hint">Kumulierter Gewinn je abgeschlossenem Trade (${esc(S.broker.label)}, ohne Test-Trades)</p></div><div id="eq"></div></section>\n    <div class="grid2">\n      <section class="section"><h2>Nach Strategie</h2><div class="panel">${st.n ? `<div class="hbars">\n        ${setups.map(([k, v]) => `<div class="hbar"><div class="hbar-l"><span class="chip">${esc(k)}</span><span class="hint">${v.n} Trades · ${pct(v.w / v.n * 100)}</span></div>\n          <div class="hbar-t"><div class="hbar-mid"></div><i class="${v.net >= 0 ? "p" : "n"}" style="width:${Math.abs(v.net) / maxAbs * 50}%"></i></div><b class="mono ${cls(v.net)}">${usd(v.net)}</b></div>`).join("")}\n        </div>` : \'<p class="hint">Noch keine abgeschlossenen Trades.</p>\'}</div></section>\n      <section class="section"><h2>Letzte Trades</h2><div class="panel scroll">${st.trades.length ? `<table><thead><tr><th class="t">Geschlossen</th><th class="t">Trade</th><th>Ein</th><th>Aus</th><th class="t">Grund</th><th>Netto</th></tr></thead><tbody>\n        ${st.trades.slice(0, 15).map(t => `<tr><td class="t mono">${dtm(t.closed)}</td><td class="t"><b class="side ${t.side}" style="font-size:12px">${t.side === "long" ? "L" : "S"}</b> ${t.qty}× ${esc(t.root)}</td><td>${px(t.entry)}</td><td>${px(t.exit)}</td><td class="t" style="font-family:var(--f-body);color:var(--muted)">${esc(t.close_reason)}</td><td class="${cls(t.pnl)}">${usd(t.pnl)}</td></tr>`).join("")}\n        </tbody></table>` : \'<p class="hint">Noch keine abgeschlossenen Trades.</p>\'}</div></section>\n    </div>`;\n  $("#eq").innerHTML = equitySvg(st.curve);\n  const pr = () => { $("#perfS").innerHTML = perfCard(); bindPerf($("#perfS"), pr); };\n  pr();\n}\nfunction equitySvg(curve) {\n  if (!curve.length) return \'<p class="hint">Die Kurve erscheint nach dem ersten abgeschlossenen Trade.</p>\';\n  const W = 900, H = 240, L = 60, R = 14, T = 14, B = 22, pts = [{e: 0}, ...curve];\n  const vals = pts.map(p => p.e), lo0 = Math.min(0, ...vals), hi0 = Math.max(0, ...vals);\n  const span = hi0 - lo0 || 100, stepRaw = span / 4, mag = 10 ** Math.floor(Math.log10(stepRaw)), step = [1, 2, 2.5, 5, 10].find(m => m * mag >= stepRaw) * mag;\n  const lo = Math.floor(lo0 / step) * step, hi = Math.ceil(hi0 / step) * step || step;\n  const x = i => L + (W - L - R) * i / Math.max(1, pts.length - 1), y = v => T + (H - T - B) * (1 - (v - lo) / (hi - lo));\n  let g = ""; for (let v = lo; v <= hi + 1e-9; v += step) g += `<line class="gl" x1="${L}" x2="${W - R}" y1="${y(v)}" y2="${y(v)}"/><text x="${L - 8}" y="${y(v) + 4}" text-anchor="end">${usd(v)}</text>`;\n  const line = pts.map((p, i) => `${i ? "L" : "M"}${x(i).toFixed(1)},${y(p.e).toFixed(1)}`).join("");\n  const last = pts[pts.length - 1], col = last.e >= 0 ? "var(--pos)" : "var(--neg)";\n  return `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="Equity-Kurve">\n    <defs><linearGradient id="eqg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="var(--accent)" stop-opacity=".28"/><stop offset="1" stop-color="var(--accent)" stop-opacity="0"/></linearGradient></defs>${g}\n    <path d="${line}L${x(pts.length - 1)},${y(Math.max(lo, 0))}L${x(0)},${y(Math.max(lo, 0))}Z" fill="url(#eqg)"/>\n    <path d="${line}" fill="none" stroke="var(--accent)" stroke-width="2"/><circle cx="${x(pts.length - 1)}" cy="${y(last.e)}" r="4" fill="${col}"/>\n    <text x="${L}" y="${H - 4}">Start</text><text x="${W - R}" y="${H - 4}" text-anchor="end">Trade ${pts.length - 1}</text></svg>`;\n}\n\n/* ───────── Kalender ───────── */\nconst CAL = {y: null, m: null, sel: null, detail: null, filter: "alle"};\ntry { CAL.filter = localStorage.getItem("fvg-cal-filter") || "alle"; } catch (e) {}\nconst MONTHS = ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember"];\nconst iso = d => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;\nconst kUsd = v => { const a = Math.abs(v); return (v < 0 ? "−" : v > 0 ? "+" : "") + "$" + (a >= 1000 ? (a / 1000).toFixed(a >= 10000 ? 0 : 1).replace(".", ",") + "k" : Math.round(a)); };\nconst sUsd = v => (v > 0 ? "+" : "") + usd(v);\n// Tageswerte passend zum Filter: {pnl, n, w, bot, own}\nfunction pick(d) {\n  if (!d) return null;\n  const b = d.bot || {pnl: 0, n: 0, w: 0}, o = d.eigen || {pnl: 0, n: 0, w: 0};\n  const r = CAL.filter === "bot" ? {...b} : CAL.filter === "eigen" ? {...o} : {pnl: b.pnl + o.pnl, n: b.n + o.n, w: b.w + o.w};\n  r.bot = CAL.filter === "eigen" ? 0 : b.n; r.own = CAL.filter === "bot" ? 0 : o.n;\n  return r.n ? r : null;\n}\nfunction countText(r, short) {\n  if (CAL.filter !== "alle") return short ? `${r.n}` : `${r.n} ${r.n === 1 ? "Trade" : "Trades"} · ${Math.round(r.w / r.n * 100)} %`;\n  const parts = [];\n  if (r.bot) parts.push(short ? `${r.bot}B` : `${r.bot} Bot`);\n  if (r.own) parts.push(short ? `${r.own}E` : `${r.own} ${r.own === 1 ? "eigener" : "eigene"}`);\n  return parts.join(short ? " " : " · ");\n}\nconst IC_L = \'<path d="M15 6l-6 6 6 6"/>\', IC_R = \'<path d="M9 6l6 6-6 6"/>\', IC_X = \'<path d="M6 6l12 12M18 6 6 18"/>\';\nfunction calendar() {\n  const now = new Date();\n  if (CAL.y === null) { CAL.y = now.getFullYear(); CAL.m = now.getMonth(); }\n  const D = S.daily || {}, first = new Date(CAL.y, CAL.m, 1), last = new Date(CAL.y, CAL.m + 1, 0);\n  const start = new Date(first); start.setDate(1 - ((first.getDay() + 6) % 7));\n  const todayIso = iso(now), prefix = `${CAL.y}-${String(CAL.m + 1).padStart(2, "0")}`;\n  const mKeys = Object.keys(D).filter(k => k.startsWith(prefix));\n  const mDays = mKeys.map(k => [k, pick(D[k])]).filter(([, r]) => r);\n  const mPnl = mDays.reduce((a, [, r]) => a + r.pnl, 0), wins = mDays.filter(([, r]) => r.pnl > 0), losses = mDays.filter(([, r]) => r.pnl < 0);\n  const mBot = mKeys.reduce((a, k) => a + (D[k].bot ? D[k].bot.pnl : 0), 0), mOwn = mKeys.reduce((a, k) => a + (D[k].eigen ? D[k].eigen.pnl : 0), 0);\n  const mTrades = mDays.reduce((a, [, r]) => a + r.n, 0), mW = mDays.reduce((a, [, r]) => a + r.w, 0);\n  const best = mDays.reduce((a, x) => !a || x[1].pnl > a[1].pnl ? x : a, null), worst = mDays.reduce((a, x) => !a || x[1].pnl < a[1].pnl ? x : a, null);\n  const dLabel = k => new Date(k + "T12:00:00").toLocaleDateString("de-DE", {weekday: "short", day: "numeric", month: "short"});\n  let cells = ["Mo", "Di", "Mi", "Do", "Fr", "Woche"].map(d => `<div class="dow">${d}</div>`).join("");\n  let wkNo = 0;\n  for (let w = new Date(start); w <= last; w.setDate(w.getDate() + 7)) {\n    let wk = {pnl: 0, n: 0, bot: 0, own: 0, w: 0}, wkDays = 0;\n    for (let i = 0; i < 7; i++) {\n      const d = new Date(w); d.setDate(w.getDate() + i);\n      const inMonth = d.getMonth() === CAL.m, k = iso(d), r = inMonth ? pick(D[k]) : null;\n      if (r) { wk.pnl += r.pnl; wk.n += r.n; wk.bot += r.bot; wk.own += r.own; wk.w += r.w; wkDays++; }\n      if (i >= 5) continue;\n      if (!inMonth) { cells += `<div class="day out"><span class="dn">${d.getDate()}</span></div>`; continue; }\n      const c = r ? (r.pnl > 0 ? "win" : r.pnl < 0 ? "loss" : "") : "empty";\n      const dots = r ? Array.from({length: Math.min(r.n, 10)}, (_, j) => `<i class="${j < r.w ? "w" : "l"}"></i>`).join("") : "";\n      cells += `<button type="button" data-day="${k}" class="day ${c} ${k === todayIso ? "today" : ""} ${CAL.sel === k ? "sel" : ""}"\n        aria-label="${d.getDate()}. ${MONTHS[CAL.m]}${r ? `: ${sUsd(r.pnl)}, ${countText(r)}` : ", kein Handel"}">\n        <span class="dn"><b>${d.getDate()}</b></span>\n        ${r ? `<span class="pl ${c === "win" ? "pos" : c === "loss" ? "neg" : ""}"><span class="f">${sUsd(r.pnl)}</span><span class="s">${kUsd(r.pnl)}</span></span>\n          <span class="meta"><span class="dots">${dots}</span><span class="f">${countText(r)}</span></span>` : ""}\n      </button>`;\n    }\n    wkNo++;\n    cells += `<div class="wk"><span class="dn"><span class="f">Woche ${wkNo}</span><span class="s">W${wkNo}</span></span>\n      <span class="pl ${wk.pnl > 0 ? "pos" : wk.pnl < 0 ? "neg" : ""}">${wkDays ? `<span class="f">${sUsd(wk.pnl)}</span><span class="s">${kUsd(wk.pnl)}</span>` : \'<span class="muted">–</span>\'}</span>\n      <span class="meta">${wkDays ? `${wkDays} ${wkDays === 1 ? "Tag" : "Tage"} · ${wk.n} Trades` : "kein Handel"}</span></div>`;\n  }\n  const wr = mDays.length ? wins.length / mDays.length : 0;\n  $("#main").innerHTML = `\n    <section class="section">\n      <div class="cal-top">\n        <div class="cal-mon"><h2>${MONTHS[CAL.m]}<small>${CAL.y}</small></h2>\n          <button class="ibtn" id="calPrev" aria-label="Vorheriger Monat">${icon(IC_L)}</button><button class="ibtn" id="calNext" aria-label="Nächster Monat">${icon(IC_R)}</button>\n          <button class="btn" id="calToday" style="padding:6px 12px">Heute</button></div>\n        <div class="cal-act">\n          <div class="seg" role="group" aria-label="Trades filtern">${[["alle", "Alle"], ["bot", "Bot"], ["eigen", "Eigene"]].map(([k, l]) => `<button type="button" data-f="${k}" aria-pressed="${CAL.filter === k}">${l}</button>`).join("")}</div>\n          <label class="btn" style="cursor:pointer">Importieren<input type="file" id="ownCsv" accept=".csv,.txt" hidden></label>\n          <button class="btn primary" id="ownAdd">+ Trade eintragen</button>\n        </div>\n      </div>\n      <div class="strip">\n        <div><span class="l">Monat</span><span class="v big ${cls(mPnl)}">${sUsd(mPnl)}</span>\n          <span class="s">${CAL.filter === "alle" ? `Bot <b class="${cls(mBot)}">${sUsd(mBot)}</b> · Eigene <b class="${cls(mOwn)}">${sUsd(mOwn)}</b>` : CAL.filter === "bot" ? "nur Bot-Trades" : "nur eigene Trades"}</span></div>\n        <div><span class="l">Gewinntage</span><span class="v">${mDays.length ? Math.round(wr * 100) + " %" : "–"}</span>\n          <div class="wl"><i style="width:${wr * 100}%;background:var(--pos)"></i><i style="width:${mDays.length ? losses.length / mDays.length * 100 : 0}%;background:var(--neg)"></i></div>\n          <span class="s">${wins.length} grün · ${losses.length} rot</span></div>\n        <div><span class="l">Trades</span><span class="v">${mTrades}</span><span class="s">${mTrades ? Math.round(mW / mTrades * 100) + " % Trefferquote" : "&nbsp;"}</span></div>\n        <div><span class="l">Bester Tag</span><span class="v pos">${best && best[1].pnl > 0 ? sUsd(best[1].pnl) : "–"}</span><span class="s">${best && best[1].pnl > 0 ? dLabel(best[0]) : "&nbsp;"}</span></div>\n        <div><span class="l">Schlechtester Tag</span><span class="v neg">${worst && worst[1].pnl < 0 ? sUsd(worst[1].pnl) : "–"}</span><span class="s">${worst && worst[1].pnl < 0 ? dLabel(worst[0]) : "&nbsp;"}</span></div>\n      </div>\n      <div class="calbox"><div class="cal" role="grid" aria-label="Handelskalender">${cells}</div></div>\n      <div class="legend"><span><i style="background:var(--pos)"></i>Gewinntag</span><span><i style="background:var(--neg)"></i>Verlusttag</span>\n        <span>Auf einen Tag klicken: Tages-Stats und Trade eintragen</span><span style="margin-left:auto">Tage nach New-Yorker Handelsdatum</span></div>\n    </section>`;\n  const go = dm => { CAL.m += dm; if (CAL.m < 0) { CAL.m = 11; CAL.y--; } if (CAL.m > 11) { CAL.m = 0; CAL.y++; } calendar(); };\n  $("#calPrev").onclick = () => go(-1); $("#calNext").onclick = () => go(1);\n  $("#calToday").onclick = () => { CAL.y = now.getFullYear(); CAL.m = now.getMonth(); calendar(); };\n  document.querySelectorAll(".seg [data-f]").forEach(b => b.onclick = () => { CAL.filter = b.dataset.f; try { localStorage.setItem("fvg-cal-filter", CAL.filter); } catch (e) {}\n    calendar(); if (CAL.sel && $("#dayDrw")) drawDay(); });\n  document.querySelectorAll(".cal button.day").forEach(b => b.onclick = () => openDay(b.dataset.day));\n  $("#ownAdd").onclick = () => ownTradeDialog(CAL.sel || todayIso);\n  $("#ownCsv").onchange = e => { const f = e.target.files[0]; if (f) importDialog(f); e.target.value = ""; };\n}\n// Tagesansicht als Seitenfenster: Stats des Tages, Trades, direkt eintragen\nasync function openDay(k) {\n  CAL.sel = k;\n  const d = new Date(k + "T12:00:00");\n  if (d.getFullYear() !== CAL.y || d.getMonth() !== CAL.m) { CAL.y = d.getFullYear(); CAL.m = d.getMonth(); }\n  try { CAL.dayTrades = (await api("/api/day/" + k)).trades; CAL.dayErr = null; } catch (e) { CAL.dayErr = e.message; CAL.dayTrades = []; }\n  if (TAB === "calendar") calendar();\n  drawDay();\n}\nfunction closeDay() {\n  const el = $("#dayDrw"); if (el) el.remove();\n  CAL.sel = null; document.querySelectorAll(".cal .day.sel").forEach(b => b.classList.remove("sel"));\n}\nfunction shiftDay(k, dir) {\n  const d = new Date(k + "T12:00:00");\n  do { d.setDate(d.getDate() + dir); } while (d.getDay() === 0 || d.getDay() === 6);\n  return iso(d);\n}\nfunction drawDay() {\n  const k = CAL.sel; if (!k) return;\n  const list = (CAL.dayTrades || []).filter(t => CAL.filter === "alle" || t.source === CAL.filter)\n    .slice().sort((a, b) => String(a.closed).localeCompare(String(b.closed)));\n  const pnl = list.reduce((a, t) => a + t.pnl, 0), w = list.filter(t => t.pnl > 0), l = list.filter(t => t.pnl < 0);\n  const gw = w.reduce((a, t) => a + t.pnl, 0), gl = -l.reduce((a, t) => a + t.pnl, 0);\n  const bot = list.filter(t => t.source !== "eigen"), own = list.filter(t => t.source === "eigen");\n  const best = list.reduce((a, t) => !a || t.pnl > a.pnl ? t : a, null), worst = list.reduce((a, t) => !a || t.pnl < a.pnl ? t : a, null);\n  let run = 0; const curve = list.map(t => (run += t.pnl));\n  const title = new Date(k + "T12:00:00").toLocaleDateString("de-DE", {weekday: "long", day: "numeric", month: "long", year: "numeric"});\n  const st = (lb, v, c = "") => `<div><span class="l">${lb}</span><b class="${c}">${v}</b></div>`;\n  const html = `\n    <div class="drw-h">\n      <button class="ibtn" id="dPrev" aria-label="Vorheriger Handelstag">${icon(IC_L)}</button>\n      <div class="drw-t"><span class="l">Tagesansicht</span><h2>${title}</h2></div>\n      <button class="ibtn" id="dNext" aria-label="Nächster Handelstag">${icon(IC_R)}</button>\n      <button class="ibtn" id="dClose" aria-label="Schließen">${icon(IC_X)}</button>\n    </div>\n    <div class="drw-b">\n      ${CAL.dayErr ? `<p class="err-msg">${esc(CAL.dayErr)}</p>` : ""}\n      <div class="drw-pl"><span class="l">Netto${CAL.filter !== "alle" ? (CAL.filter === "bot" ? " · Bot" : " · Eigene") : ""}</span>\n        <b class="${cls(pnl)}">${list.length ? sUsd(pnl) : "–"}</b>\n        ${list.length && CAL.filter === "alle" ? `<span class="hint">Bot <b class="${cls(bot.reduce((a, t) => a + t.pnl, 0))}">${sUsd(bot.reduce((a, t) => a + t.pnl, 0))}</b> · Eigene <b class="${cls(own.reduce((a, t) => a + t.pnl, 0))}">${sUsd(own.reduce((a, t) => a + t.pnl, 0))}</b></span>` : ""}</div>\n      ${list.length ? `<div class="drw-st">\n        ${st("Trades", `${list.length}`)}\n        ${st("Trefferquote", Math.round(w.length / list.length * 100) + " %", w.length >= l.length ? "pos" : "neg")}\n        ${st("Profit-Faktor", gl ? (gw / gl).toFixed(2).replace(".", ",") : (gw ? "∞" : "–"))}\n        ${st("Ø Trade", sUsd(pnl / list.length), cls(pnl))}\n        ${st("Bester", best ? sUsd(best.pnl) : "–", best && best.pnl > 0 ? "pos" : "")}\n        ${st("Schlechtester", worst ? sUsd(worst.pnl) : "–", worst && worst.pnl < 0 ? "neg" : "")}\n      </div>\n      ${list.length > 1 ? `<div class="drw-cv"><span class="l">Verlauf über den Tag</span>${sparkSvg(curve, 400, 64)}</div>` : ""}\n      <div class="drw-list"><span class="l">Trades</span>\n        ${list.map(t => `<div class="tr ${t.pnl > 0 ? "w" : t.pnl < 0 ? "lo" : ""}">\n          <div class="tr-a"><span class="chip ${t.side === "long" ? "good" : "bad"}">${t.side === "long" ? "Long" : "Short"}</span>\n            <b>${t.qty}× ${esc(t.root)}</b><span class="chip ${t.source === "eigen" ? "warn" : ""}">${t.source === "eigen" ? "Eigen" : "Bot"}</span>${t.is_test ? \'<span class="chip mute">Test</span>\' : ""}\n            <span class="tr-p mono ${cls(t.pnl)}">${sUsd(t.pnl)}</span></div>\n          ${tradeDetail(t)}\n          <div class="tr-b"><span class="tr-n">${esc(t.source === "eigen" ? (t.note || "") : `${t.setup} · ${t.close_reason}`)}</span>\n            ${t.source === "eigen" || t.is_test ? `<button class="lnk owndel" data-id="${t.id}" data-key="del-${t.id}" data-orig="Löschen">${armed("del-" + t.id) ? "Sicher?" : "Löschen"}</button>` : ""}</div>\n        </div>`).join("")}\n      </div>` : `<div class="empty">Keine ${CAL.filter === "bot" ? "Bot-" : CAL.filter === "eigen" ? "eigenen " : ""}Trades an diesem Tag.</div>`}\n    </div>\n    <div class="drw-f"><button class="btn primary" id="dAdd">+ Trade für diesen Tag eintragen</button></div>`;\n  let el = $("#dayDrw");\n  if (!el) {\n    document.body.insertAdjacentHTML("beforeend", `<div id="dayDrw" class="drw-bg"><aside class="drw" role="dialog" aria-modal="true" aria-label="Tagesansicht"></aside></div>`);\n    el = $("#dayDrw");\n    el.addEventListener("click", e => { if (e.target === el) closeDay(); });\n  }\n  el.querySelector(".drw").innerHTML = html;\n  $("#dClose").onclick = closeDay;\n  $("#dPrev").onclick = () => openDay(shiftDay(k, -1));\n  $("#dNext").onclick = () => openDay(shiftDay(k, 1));\n  $("#dAdd").onclick = () => ownTradeDialog(k);\n  el.querySelectorAll(".owndel").forEach(b => b.onclick = () => confirmBtn(b, "Sicher?", async () => {\n    try { await api(`/api/own/${b.dataset.id}/delete`, {}); toast("Trade gelöscht"); S = await api("/api/state"); openDay(k); } catch (e) { toast(e.message); }\n  }));\n}\ndocument.addEventListener("keydown", e => { if (e.key === "Escape" && $("#dayDrw") && !$("#mdl")) closeDay(); });\n\n/* Details eines abgeschlossenen Trades: Preise, Punkte, Ticks, CRV und erreichtes R */\nfunction tradeDetail(t) {\n  const I = (S.instruments || {})[t.root], hasPx = t.entry && t.exit != null;\n  const times = t.source === "eigen" && t.opened === t.closed ? "" : `${tm(t.opened)} → ${tm(t.closed)}`;\n  if (!I || !hasPx) return `<div class="tr-b"><span class="mono">${times}</span>${t.entry ? `<span class="mono">${px(t.entry)} → ${px(t.exit)}</span>` : ""}</div>`;\n  const d = t.side === "long" ? 1 : -1, tk = v => Math.round(v / I.tick);\n  const move = (t.exit - t.entry) * d, sl0 = t.initial_sl ?? t.sl;\n  const risk = sl0 != null ? (t.entry - sl0) * d : null, rew = t.tp != null ? (t.tp - t.entry) * d : null;\n  const crv = risk > 0 && rew != null ? rew / risk : null, rr = risk > 0 ? move / risk : null;\n  const mins = t.closed && t.opened && t.closed > t.opened ? Math.round((t.closed - t.opened) / 60) : null;\n  const cell = (l, v, sub, c = "") => `<div><span class="l">${l}</span><b class="mono ${c}">${v}</b>${sub ? `<small>${sub}</small>` : ""}</div>`;\n  return `<div class="td-g">\n    ${cell("Einstieg", px(t.entry), times ? tm(t.opened) : "")}\n    ${cell("Ausstieg", px(t.exit), times ? `${tm(t.closed)}${mins != null ? ` · ${mins < 60 ? mins + " Min" : Math.floor(mins / 60) + " Std " + (mins % 60) + " Min"}` : ""}` : "")}\n    ${cell("Bewegung", `${fPts(move)} Pkt`, fTicks(tk(move)), cls(move))}\n    ${cell("Stop", sl0 != null ? px(sl0) : "–", risk != null ? `${fPts(-risk)} Pkt · ${fTicks(-tk(risk))}` : "", "neg")}\n    ${cell("Ziel", t.tp != null ? px(t.tp) : "–", rew != null ? `${fPts(rew)} Pkt · ${fTicks(tk(rew))}` : "kein Ziel", "pos")}\n    ${cell("CRV geplant", crv != null ? "1 : " + crv.toFixed(2).replace(".", ",") : "–", rr != null ? `erreicht ${rr >= 0 ? "+" : "−"}${Math.abs(rr).toFixed(2).replace(".", ",")} R` : "", rr != null ? cls(rr) : "")}\n  </div>`;\n}\nfunction modal(html) {\n  document.body.insertAdjacentHTML("beforeend", `<div class="modal-bg" id="mdl" role="dialog" aria-modal="true"><div class="panel modal">${html}</div></div>`);\n  const close = () => $("#mdl") && $("#mdl").remove();\n  $("#mdl").addEventListener("click", e => { if (e.target.id === "mdl") close(); });\n  document.addEventListener("keydown", function esc(e) { if (e.key === "Escape") { close(); document.removeEventListener("keydown", esc); } });\n  return close;\n}\nfunction ownTradeDialog(day) {\n  const close = modal(`<h2 style="font-size:18px">Eigenen Trade eintragen</h2>\n    <form id="ownF" class="form" style="gap:10px">\n      <div class="edit" style="grid-template-columns:repeat(2,minmax(0,1fr))">\n        <label>Handelstag<input id="oDay" type="date" value="${day}" required></label>\n        <label>Instrument<select id="oRoot">${["NQ", "MNQ", "ES", "MES"].map(r => `<option>${r}</option>`).join("")}</select></label>\n        <label>Richtung<select id="oSide"><option value="long">Long</option><option value="short">Short</option></select></label>\n        <label>Anzahl<input id="oQty" type="number" min="1" step="1" value="1"></label>\n        <label>Einstieg<input id="oIn" type="number" step="0.25" placeholder="z. B. 21010.25"></label>\n        <label>Ausstieg<input id="oOut" type="number" step="0.25" placeholder="z. B. 21030.50"></label>\n        <label>Gebühren ($)<input id="oFee" type="number" step="0.01" min="0" value="0"></label>\n        <label>oder P&L direkt ($)<input id="oPnl" type="number" step="0.01" placeholder="optional"></label>\n      </div>\n      <div class="edit" style="grid-template-columns:1fr"><label>Notiz<input id="oNote" type="text" maxlength="120" placeholder="z. B. Topstep-Konto, NY-Open"></label></div>\n      <p class="hint" style="margin:0">Ergebnis: <b id="oRes">–</b></p>\n      <p class="err-msg" id="oErr" hidden></p>\n      <div class="actions"><button class="btn primary" type="submit">Speichern</button><button class="btn" type="button" id="oCancel">Abbrechen</button></div>\n    </form>`);\n  const pv = {NQ: 20, MNQ: 2, ES: 50, MES: 5};\n  const calc = () => {\n    const direct = parseFloat($("#oPnl").value);\n    let r = NaN;\n    if (isFinite(direct)) r = direct;\n    else { const a = parseFloat($("#oIn").value), b = parseFloat($("#oOut").value), q = parseInt($("#oQty").value) || 0, f = parseFloat($("#oFee").value) || 0;\n      if (isFinite(a) && isFinite(b)) r = (b - a) * ($("#oSide").value === "long" ? 1 : -1) * q * pv[$("#oRoot").value] - f; }\n    $("#oRes").textContent = isFinite(r) ? sUsd(Math.round(r * 100) / 100) : "–"; $("#oRes").className = cls(r);\n  };\n  $("#ownF").addEventListener("input", calc);\n  $("#oCancel").onclick = close;\n  $("#ownF").onsubmit = async e => {\n    e.preventDefault();\n    const dayVal = $("#oDay").value;\n    try {\n      await api("/api/own/add", {day: dayVal, root: $("#oRoot").value, side: $("#oSide").value, qty: $("#oQty").value,\n        entry: $("#oIn").value, exit: $("#oOut").value, fees: $("#oFee").value, pnl: $("#oPnl").value, note: $("#oNote").value});\n      close(); toast("Eigener Trade gespeichert");\n      S = await api("/api/state");\n      CAL.y = +dayVal.slice(0, 4); CAL.m = +dayVal.slice(5, 7) - 1; openDay(dayVal);\n    } catch (err) { $("#oErr").textContent = err.message; $("#oErr").hidden = false; }\n  };\n  $("#oIn").focus();\n}\nasync function importDialog(file) {\n  const text = await file.text();\n  const close = modal(`<h2 style="font-size:18px">Eigene Trades importieren</h2>\n    <p style="margin:0"><b>${esc(file.name)}</b> · ${text.split(/\\r?\\n/).filter(x => x.trim()).length - 1} Zeilen</p>\n    <p class="hint" style="margin:0">Funktioniert mit CSV-Exporten aus Topstep, Tradovate, NinjaTrader und den meisten Plattformen. Spalten wie Datum, Symbol, Richtung und P&L werden automatisch erkannt. Schon importierte Trades werden übersprungen.</p>\n    <label style="display:flex;gap:8px;align-items:center;font-size:13px"><input type="checkbox" id="iFee" checked> Gebühren-Spalte vom P&L abziehen (falls vorhanden)</label>\n    <p class="err-msg" id="iErr" hidden></p>\n    <div class="actions"><button class="btn primary" id="iGo">Importieren</button><button class="btn" id="iCancel">Abbrechen</button></div>`);\n  $("#iCancel").onclick = close;\n  $("#iGo").onclick = async () => {\n    try {\n      const r = await api("/api/own/import", {csv: text, subtract_fees: $("#iFee").checked});\n      close(); toast(`${r.added} Trades importiert${r.skipped ? `, ${r.skipped} schon vorhanden` : ""}${r.bad ? `, ${r.bad} nicht lesbar` : ""}`);\n      CAL.filter = CAL.filter === "bot" ? "alle" : CAL.filter; await refresh(true);\n    } catch (e) { $("#iErr").textContent = e.message; $("#iErr").hidden = false; }\n  };\n}\n\n/* ───────── Lernmodul ───────── */\nlet LTAB = "strategien";\ntry { LTAB = localStorage.getItem("fvg-ltab") || "strategien"; } catch (e) {}\nfunction learn() {\n  if (!$("#lnWrap")) {\n    $("#main").innerHTML = `<div id="lnWrap" style="display:contents">\n      <div class="subtabs" role="tablist">${[["strategien", "Strategien"], ["varianten", "Varianten-Labor"], ["regeln", "Regel-Finder"], ["backtest", "Backtest"]].map(([k, l]) =>\n        `<button type="button" role="tab" data-lt="${k}" aria-selected="${LTAB === k}">${l}</button>`).join("")}</div>\n      <div id="lnBody" style="display:contents"></div></div>`;\n    document.querySelectorAll("[data-lt]").forEach(b => b.onclick = () => { LTAB = b.dataset.lt; try { localStorage.setItem("fvg-ltab", LTAB); } catch (e) {}\n      document.querySelectorAll("[data-lt]").forEach(x => x.setAttribute("aria-selected", x === b)); $("#lnBody").innerHTML = ""; learn(); });\n  }\n  if (LTAB === "varianten") return labVariants();\n  if (LTAB === "regeln") return labRules();\n  if (LTAB === "backtest") return backtestView();\n  learnStrategies();\n}\nfunction learnStrategies() {\n  const L = S.learning, p = L.params;\n  const stChip = s => ({"aktiv": "good", "halbe Größe": "warn", "pausiert": "bad", "aus": "bad", "lernt": "mute"}[s] || "mute");\n  $("#lnBody").innerHTML = `\n    <section class="panel"><div class="section-h"><div><h2>So lernt der Bot</h2>\n      <p class="hint" style="max-width:75ch;margin-top:4px">Jedes Signal wird im Hintergrund als Schatten-Trade simuliert, auch abgelehnte und blockierte. Nach jeder Session wertet der Bot die letzten ${p.window} Schatten-Trades je Strategie aus.\n      Unter ${num2(p.half_below_r)} R im Schnitt gibt es halbe Größe, unter ${num2(p.pause_below_r)} R eine Pause. Erst ab ${p.min_trades} Trades greift die Bewertung.\n      Pausierte Strategien laufen im Schatten weiter und werden automatisch wieder freigegeben, wenn sie sich erholen. Das Risiko wird nie automatisch über deine Einstellung erhöht.\n      <b>Zusätzlich je Session:</b> Läuft eine Strategie z. B. in Asien schlecht, in New York aber gut, wird sie nur in Asien gebremst (Spalte „Je Session“: ✓ aktiv, ½ halbe Größe, ⏸ pausiert, … lernt noch).</p></div>\n      <div style="display:flex;gap:10px;align-items:center"><span class="hint">Letzte Auswertung: ${L.last_run ? dtm(L.last_run) : "noch keine"}</span><button class="btn primary" id="runL">Jetzt auswerten</button></div></div></section>\n    <section class="section"><h2>Strategien</h2><div class="panel scroll">${L.setups.length ? `<table><thead><tr><th class="t">Strategie</th><th class="t">Status</th><th>Ausgewertet</th><th>Gesamt</th><th>Treffer</th><th>Ø R</th><th>Σ R</th><th>Laufend</th><th class="t">Je Session</th><th class="t">Steuerung</th></tr></thead><tbody>\n      ${L.setups.map(s => `<tr><td class="t"><span class="chip">${esc(s.setup)}</span></td>\n        <td class="t"><span class="chip ${stChip(s.effective)}">${esc(s.effective)}</span>${s.manual !== "auto" ? \' <span class="hint">(manuell)</span>\' : ""}</td>\n        <td>${s.n}</td><td>${s.total}</td><td>${pct(s.winrate)}</td><td class="${cls(s.avg_r)}">${num2(s.avg_r)}</td><td class="${cls(s.sum_r)}">${num2(s.sum_r)}</td><td>${s.open}</td>\n        <td class="t wrap" style="min-width:220px">${Object.keys(s.sessions || {}).length ? `<div class="ssn">${["asia", "london", "ny_am", "ny_lunch", "ny_pm", "aus"].filter(k => (s.sessions || {})[k]).map(k => { const x = s.sessions[k];\n          return `<span class="chip ${stChip(x.status)}" title="${esc((S.session_names || {})[k] || k)}: ${x.n} Trades · ${pct(x.winrate)} · Ø ${num2(x.avg_r)} R · ${esc(x.status)}">${{asia: "Asien", london: "London", ny_am: "NY Vorm.", ny_lunch: "NY Mittag", ny_pm: "NY Nachm.", aus: "Sonst"}[k]} ${x.status === "pausiert" ? "⏸" : x.status === "halbe Größe" ? "½" : x.status === "aktiv" ? "✓" : "…"} <b class="mono">${x.avg_r > 0 ? "+" : ""}${num2(x.avg_r)}</b></span>`; }).join("")}</div>` : \'<span class="hint">noch keine Daten</span>\'}</td>\n        <td class="t"><select data-setup="${esc(s.setup)}" class="rule" aria-label="Steuerung ${esc(s.setup)}">${[["auto", "Lernmodul entscheidet"], ["an", "Immer an"], ["aus", "Aus"]].map(([v, l]) => `<option value="${v}" ${s.manual === v ? "selected" : ""}>${l}</option>`).join("")}</select></td></tr>`).join("")}\n      </tbody></table>` : \'<p class="hint">Noch keine Daten. Sobald Signale aus TradingView eintreffen, erscheinen hier alle Strategien.</p>\'}</div></section>\n    <section class="section"><h2>Erkenntnisse</h2><div class="panel">${L.insights.length ? `<div class="flags" style="flex-direction:column;align-items:flex-start;gap:8px">${L.insights.map(i => `<span class="chip ${i.kind === "bad" ? "bad" : i.kind === "good" ? "good" : "warn"}">${esc(i.text)}</span>`).join("")}</div>` : \'<p class="hint">Noch keine Auffälligkeiten. Erkenntnisse zu Uhrzeiten erscheinen ab 6 Trades pro Stunde.</p>\'}</div></section>`;\n  $("#runL").onclick = () => act(() => api("/api/learn", {}), "Auswertung fertig");\n  document.querySelectorAll(".rule").forEach(sel => sel.onchange = () =>\n    act(() => api("/api/config", {setup_rules: {[sel.dataset.setup]: sel.value}}), "Gespeichert"));\n}\n\n\n/* ───────── Lernlabor Stufe 1: Varianten-Labor ───────── */\nconst LAB = {v: null, vat: 0, r: null, rat: 0};\nasync function labVariants(force) {\n  const body = $("#lnBody");\n  if (!force && LAB.v && Date.now() - LAB.vat < 60000 && body.querySelector(".lab-v")) return;\n  if (!LAB.v) body.innerHTML = \'<div class="empty">Varianten werden ausgewertet …</div>\';\n  try { LAB.v = await api("/api/lab/variants"); LAB.vat = Date.now(); } catch (e) { body.innerHTML = `<div class="empty">${esc(e.message)}</div>`; return; }\n  if (TAB !== "learn" || LTAB !== "varianten") return;\n  const V = LAB.v, cols = V.variants;\n  const cell = (c, best, isCur, isRec) => !c.n ? \'<td class="muted">–</td>\'\n    : `<td class="vc ${best ? "best" : ""} ${isCur ? "cur" : ""} ${isRec ? "rec" : ""}" title="${c.n} Signale · Trefferquote ${pct(c.wr)} · Σ ${num2(c.sum)} R · 1. Teil ${num2(c.a1)} / 2. Teil ${num2(c.a2)}">\n        <b class="${cls(c.avg)}">${c.avg > 0 ? "+" : ""}${num2(c.avg)}</b><small>${Math.round(c.wr)} % · ${c.n}</small></td>`;\n  body.innerHTML = `<section class="panel lab-v">\n    <div class="section-h"><div><h2 style="font-size:16px;text-transform:none;letter-spacing:0;color:var(--fg)">Varianten-Labor</h2>\n      <p class="hint" style="max-width:85ch;margin-top:4px;line-height:1.6">Für jedes Signal rechnet die App im Hintergrund ${cols.length - 1} Ausstiegs-Varianten mit: feste Ziele von 1R bis 3R, Stop auf Break-even ab +1R, Trailing-Stop und Halten bis Session-Ende. Die Zahl ist das <b>Ø R pro Signal</b> (darunter Trefferquote und Anzahl). <b>Grün umrandet</b> = beste Variante, <b>blau</b> = aktuell genutzt.\n      Eine Empfehlung gibt es erst ab ${V.min_n} Signalen, wenn die Variante im Schnitt mindestens 0,15 R besser ist <b>und</b> in beiden Zeit-Hälften vorne liegt, damit es kein Zufall ist.</p></div>\n      <button class="btn" id="labVRef">Neu berechnen</button></div>\n    ${V.setups.length ? `<div class="scroll"><table class="vt"><thead><tr><th class="t">Strategie</th>${cols.map(k => `<th>${k === "Signal-Ziel" ? "Signal-Ziel<br><small>aus TradingView</small>" : esc(k)}</th>`).join("")}<th class="t">Empfehlung</th></tr></thead><tbody>\n      ${V.setups.map(r => { const bestK = cols.filter(k => r.cols[k].n >= 5).sort((a, b) => r.cols[b].avg - r.cols[a].avg)[0];\n        return `<tr><td class="t"><b>${esc(r.setup)}</b><small class="hint">${r.cols["Signal-Ziel"].n} Signale</small></td>\n          ${cols.map(k => cell(r.cols[k], k === bestK, k === r.applied, k === r.rec)).join("")}\n          <td class="t">${r.rec ? `<div class="vrec"><span>Wechsel auf <b>${esc(r.rec)}</b>: ${r.cols[r.rec].avg > 0 ? "+" : ""}${num2(r.cols[r.rec].avg)} R statt ${num2(r.cols[r.applied].avg)} R</span>\n              ${V.broker !== "paper" && r.paper_only.includes(r.rec) ? \'<small class="hint">nur mit Paper-Trading möglich</small>\' : `<button class="btn primary vapply" data-s="${esc(r.setup)}" data-v="${esc(r.rec)}">Übernehmen</button>`}</div>`\n            : r.applied !== "Signal-Ziel" ? `<div class="vrec"><span>Nutzt <b>${esc(r.applied)}</b></span><button class="btn vapply" data-s="${esc(r.setup)}" data-v="Signal-Ziel">Zurück auf Signal-Ziel</button></div>`\n            : `<span class="hint">${r.cols["Signal-Ziel"].n < V.min_n ? `sammelt noch (${r.cols["Signal-Ziel"].n}/${V.min_n})` : "Signal-Ziel ist gut so"}</span>`}</td></tr>`; }).join("")}\n    </tbody></table></div>` : \'<div class="empty">Noch keine Signale. Sobald TradingView Signale und Kerzen schickt, laufen die Varianten automatisch mit.</div>\'}\n    <p class="hint">„Übernehmen“ ändert, wie der Bot bei dieser Strategie aussteigt: Ziel, Break-even oder Trailing. Der Einstieg bleibt gleich. Trailing und „Bis Session-Ende“ gehen nur mit Paper-Trading, weil Tradovate dafür eine Order ohne festes Ziel bräuchte.</p>\n  </section>`;\n  $("#labVRef").onclick = () => labVariants(true);\n  body.querySelectorAll(".vapply").forEach(b => b.onclick = async () => {\n    try { await api("/api/config", {exit_rules: {[b.dataset.s]: b.dataset.v}}); toast(b.dataset.v === "Signal-Ziel" ? "Zurück auf das Signal-Ziel" : `${b.dataset.s}: Ausstieg ${b.dataset.v} übernommen`); S = await api("/api/state"); labVariants(true); }\n    catch (e) { toast(e.message); }\n  });\n}\n\n/* ───────── Lernlabor Stufe 2: Regel-Finder ───────── */\nasync function labRules(force) {\n  const body = $("#lnBody");\n  if (!force && LAB.r && Date.now() - LAB.rat < 60000 && body.querySelector(".lab-r")) return;\n  if (!LAB.r) body.innerHTML = \'<div class="empty">Regel-Finder sucht …</div>\';\n  try { LAB.r = await api("/api/lab/rules"); LAB.rat = Date.now(); } catch (e) { body.innerHTML = `<div class="empty">${esc(e.message)}</div>`; return; }\n  if (TAB !== "learn" || LTAB !== "regeln") return;\n  const R = LAB.r;\n  const card = (x, strong) => `<div class="rf ${x.action} ${strong ? "" : "weak"}">\n    <div class="rf-h"><span class="chip ${x.action === "avoid" ? "bad" : "good"}">${x.action === "avoid" ? "Meiden" : "Nur dann handeln"}</span><b>${esc(x.setup)}</b><span class="hint">${x.action === "avoid" ? "meiden, wenn" : "nur, wenn"}</span></div>\n    <div class="rf-l">${esc(x.label)}</div>\n    <div class="rf-g">\n      <div><span class="l">Wenn zutrifft</span><b class="${cls(x.avg_match)}">${x.avg_match > 0 ? "+" : ""}${num2(x.avg_match)} R</b><small>${x.n} Signale · ${Math.round(x.wr_match)} %</small></div>\n      <div><span class="l">Sonst</span><b class="${cls(x.avg_rest)}">${x.avg_rest > 0 ? "+" : ""}${num2(x.avg_rest)} R</b><small>${x.n_all - x.n} Signale</small></div>\n      <div><span class="l">Gegenprobe</span><b class="${x.d2 != null && Math.sign(x.d2) === Math.sign(x.avg_match - x.avg_rest) ? "pos" : "neg"}">${x.d2 == null ? "–" : (x.d2 > 0 ? "+" : "") + num2(x.d2) + " R"}</b><small>neueste ${x.n_oos} Signale</small></div>\n      <div><span class="l">Hätte gebracht</span><b class="pos">+${num2(x.effect)} R</b><small>Sicherheit t = ${num2(Math.abs(x.t))}</small></div>\n    </div>\n    ${strong ? (x.applied ? \'<span class="chip good" style="align-self:flex-start">übernommen ✓</span>\' : `<button class="btn primary rfapply" data-i="${R.found.indexOf(x)}" style="align-self:flex-start">Regel übernehmen</button>`) : \'<span class="hint">Beobachten: noch nicht genug Belege, um sie zu übernehmen.</span>\'}\n  </div>`;\n  const cnt = Object.entries(R.setups);\n  body.innerHTML = `<section class="panel lab-r">\n    <div class="section-h"><div><h2 style="font-size:16px;text-transform:none;letter-spacing:0;color:var(--fg)">Regel-Finder</h2>\n      <p class="hint" style="max-width:85ch;margin-top:4px;line-height:1.6">Bei jedem Signal merkt sich die App die Marktlage: Richtung, Uhrzeit, Wochentag, Session, Gap, ob Asien/London/IB schon gebrochen sind, Lage zu Vortageshoch/-tief, Overnight-Range, Midnight Open und RTH-Open.\n      Der Regel-Finder sucht Bedingungen (einzeln und als Paar), unter denen eine Strategie klar besser oder schlechter läuft. <b>Vorgeschlagen</b> wird eine Regel nur, wenn sie in den älteren 60 % der Signale gefunden wurde <b>und</b> in den neuesten 40 % (Gegenprobe) genauso hält, mit hoher Sicherheit (t ≥ 2,5). Getestet wurden ${R.tests} Bedingungen aus ${R.signals} Signalen.</p></div>\n      <button class="btn" id="labRRef">Neu suchen</button></div>\n    ${cnt.length ? `<div class="flags">${cnt.map(([k, n]) => `<span class="chip ${n >= R.min_scope ? "" : "mute"}">${esc(k)}: ${n}${n < R.min_scope ? ` / ${R.min_scope}` : ""}</span>`).join("")}</div>` : ""}\n    ${R.active.length ? `<h3 class="lab-h">Übernommene Regeln</h3><div class="rf-act">${R.active.map((r, i) => `<div class="rfa ${r.active ? "" : "off"}">\n        <span class="chip ${r.action === "avoid" ? "bad" : "good"}">${r.action === "avoid" ? "Meiden" : "Nur dann"}</span>\n        <div><b>${esc(r.setup)}</b> ${r.action === "avoid" ? "meiden, wenn" : "nur, wenn"} ${esc(r.label)}<small class="hint">seit ${new Date(r.added * 1000).toLocaleDateString("de-DE")} · ${r.blocked_n} von ${r.since_n} Signalen geblockt${r.blocked_n ? ` · die hätten ${r.blocked_r > 0 ? "+" : ""}${num2(r.blocked_r)} R gebracht` : ""}</small></div>\n        <button class="btn" data-ra="${i}">${r.active ? "Pausieren" : "Aktivieren"}</button><button class="btn ghost-danger" data-rd="${i}" data-key="rd-${i}">Entfernen</button></div>`).join("")}</div>\n      <p class="hint">Gute Regel: Die geblockten Signale hätten zusammen <b>negativ</b> abgeschnitten. Hätten sie viel Plus gebracht, die Regel lieber pausieren.</p>` : ""}\n    <h3 class="lab-h">Gefundene Regeln</h3>\n    ${R.found.length ? `<div class="rf-grid">${R.found.map(x => card(x, true)).join("")}</div>` : `<div class="empty">${R.signals < 40 ? `Noch zu wenig Signale. Der Regel-Finder braucht mindestens ${R.min_scope} abgeschlossene Signale je Strategie, richtig aussagekräftig wird es ab etwa 60–100.` : "Aktuell keine Regel, die die Gegenprobe sicher besteht. Das ist gut: lieber keine Regel als eine zufällige."}</div>`}\n    ${R.watch.length ? `<h3 class="lab-h">Zum Beobachten</h3><div class="rf-grid">${R.watch.map(x => card(x, false)).join("")}</div>` : ""}\n  </section>`;\n  $("#labRRef").onclick = () => labRules(true);\n  const saveRules = async (list, msg) => { try { await api("/api/config", {rule_filters: list}); toast(msg); S = await api("/api/state"); labRules(true); } catch (e) { toast(e.message); } };\n  const cur = () => (S.config.rule_filters || []).map(r => ({...r}));\n  body.querySelectorAll(".rfapply").forEach(b => b.onclick = () => { const x = R.found[+b.dataset.i];\n    saveRules([...cur(), {setup: x.setup, conds: x.conds, action: x.action, label: x.label, added: Date.now() / 1000, active: true}], "Regel übernommen: der Bot filtert ab jetzt"); });\n  body.querySelectorAll("[data-ra]").forEach(b => b.onclick = () => { const l = cur(); l[+b.dataset.ra].active = !l[+b.dataset.ra].active; saveRules(l, l[+b.dataset.ra].active ? "Regel aktiv" : "Regel pausiert"); });\n  body.querySelectorAll("[data-rd]").forEach(b => b.onclick = () => confirmBtn(b, "Sicher?", () => { const l = cur(); l.splice(+b.dataset.rd, 1); saveRules(l, "Regel entfernt"); }));\n}\n\n\n/* ───────── Backtest: Trade-Liste aus dem TradingView-Strategietester auswerten ───────── */\nconst BT = {trades: null, name: "", loaded: false, filter: "Alle", err: null, src: "export", live: null, liveAt: 0};\ntry { BT.src = localStorage.getItem("fvg-bt-src") || "export"; } catch (e) {}\nconst BT_NEWS = {\n  FOMC: [20240131,20240320,20240501,20240612,20240731,20240918,20241107,20241218,20250129,20250319,20250507,20250618,20250730,20250917,20251029,20251210,\n         20260128,20260318,20260429,20260617,20260729,20260916,20261028,20261209,20270127,20270317,20270428,20270609,20270728,20270915,20271027,20271208],\n  CPI: [20240111,20240213,20240312,20240410,20240515,20240612,20240711,20240814,20240911,20241010,20241113,20241211,20250115,20250212,20250312,20250410,20250513,\n        20250611,20250715,20250812,20250911,20251024,20251218,20260113,20260213,20260311,20260410,20260512,20260610,20260714,20260812,20260911,20261014,20261110,20261210],\n  NFP_EXTRA: [20251120,20251216,20260109], NFP_SKIP: [20251003,20251107]};\nconst btKey = d => d.getFullYear() * 10000 + (d.getMonth() + 1) * 100 + d.getDate();\nfunction btNews(d) {\n  const k = btKey(d), t = [];\n  if (BT_NEWS.FOMC.includes(k)) t.push("FOMC");\n  if (BT_NEWS.CPI.includes(k)) t.push("CPI");\n  if ((d.getDay() === 5 && d.getDate() <= 7 && !BT_NEWS.NFP_SKIP.includes(k)) || BT_NEWS.NFP_EXTRA.includes(k)) t.push("NFP");\n  return t;\n}\nconst btNum = v => { if (typeof v === "number") return v; if (v == null) return NaN;\n  let x = String(v).replace(/[−–]/g, "-").replace(/[^0-9.,\\-]/g, "");\n  if (x.includes(",") && x.includes(".")) x = x.lastIndexOf(",") > x.lastIndexOf(".") ? x.replace(/\\./g, "").replace(",", ".") : x.replace(/,/g, "");\n  else if (x.includes(",")) x = /^-?\\d{1,3}(,\\d{3})+$/.test(x) ? x.replace(/,/g, "") : x.replace(",", ".");\n  return parseFloat(x); };\nfunction btDate(v) {\n  if (v instanceof Date) return v;\n  if (typeof v === "number") return new Date(Math.round((v - 25569) * 864e5) + new Date().getTimezoneOffset() * 60000);\n  const s = String(v).trim(), m = s.match(/^(\\d{1,2})\\.(\\d{1,2})\\.(\\d{2,4})[ ,T]+(\\d{1,2}):(\\d{2})/);\n  if (m) return new Date(+(m[3].length === 2 ? "20" + m[3] : m[3]), +m[2] - 1, +m[1], +m[4], +m[5]);\n  const d = new Date(s.replace(" ", "T")); return isNaN(d) ? new Date(s) : d;\n}\nconst BT_ID = /^(trade[\\s-]*(#|nr\\.?|nummer|no\\.?|number)|#|nr\\.?)$/i, BT_ID2 = /trade[\\s-]*(#|nr|nummer|no|number)/i;\nfunction btParse(rows) {\n  let hi = -1;\n  for (let i = 0; i < Math.min(rows.length, 40); i++) { const r = rows[i].map(c => String(c ?? "").trim());\n    if (r.some(c => BT_ID.test(c) || BT_ID2.test(c)) && r.some(c => /^(type|typ)\\b/i.test(c) || /date|datum|zeit/i.test(c))) { hi = i; break; } }\n  if (hi < 0) throw new Error("NOHEADER");\n  const h = rows[hi].map(c => String(c ?? "").trim()), ix = re => h.findIndex(c => re.test(c));\n  let cT = ix(BT_ID); if (cT < 0) cT = ix(BT_ID2);\n  const cType = ix(/^(type|typ)\\b/i), cD = ix(/date|datum/i), cS = ix(/^signal/i);\n  const cP = h.findIndex(c => /(net\\s*p&?l|netto[\\s-]*(g&?v|gewinn|p&?l)|^g&v|^p&l|profit|gewinn)/i.test(c) && !/%|cum|kum|run|lauf|draw|max/i.test(c));\n  const miss = [[cT, "Trade-Nummer"], [cType, "Typ"], [cD, "Datum/Uhrzeit"], [cP, "Netto-G&V"]].filter(x => x[0] < 0).map(x => x[1]);\n  if (miss.length) throw new Error("Spalten nicht erkannt: " + miss.join(", ") + ". Gefunden: " + h.filter(Boolean).join(" · "));\n  const by = new Map();\n  for (const r of rows.slice(hi + 1)) {\n    if (r[cT] == null || r[cT] === "") continue;\n    const id = String(r[cT]), t = String(r[cType] || "").toLowerCase(), o = by.get(id) || {};\n    if (/entry|einstieg|eintritt/.test(t)) { o.time = btDate(r[cD]); o.setup = String(cS >= 0 ? r[cS] || "" : ""); o.dir = /short|verkauf/.test(t) ? "Short" : "Long"; }\n    else { if (/offen|open/i.test(String(r[cD]))) o.open = true; else o.exit = btDate(r[cD]); if (!o.dir) o.dir = /short|verkauf/.test(t) ? "Short" : "Long"; }\n    const p = btNum(r[cP]); if (!isNaN(p)) o.pnl = p;\n    by.set(id, o);\n  }\n  const out = [...by.values()].filter(o => !o.open && o.time && !isNaN(o.time) && typeof o.pnl === "number");   // noch offene Trades zählen nicht\n  out.forEach(o => { o.setup = (o.setup || "").trim(); if (!/(long|short)$/i.test(o.setup)) o.setup = ((o.setup || "Trade") + " " + o.dir); });\n  if (!out.length) throw new Error("Keine abgeschlossenen Trades in der Datei gefunden.");\n  return out.sort((a, b) => a.time - b.time);\n}\nasync function btLoadFile(f) {\n  BT.err = null;\n  try {\n    const buf = new Uint8Array(await f.arrayBuffer());\n    let bin = ""; for (let i = 0; i < buf.length; i += 0x8000) bin += String.fromCharCode.apply(null, buf.subarray(i, i + 0x8000));\n    const res = await api("/api/backtest/read", {name: f.name, data: btoa(bin)});\n    let trades = null, lastErr = null;\n    const order = [...res.sheets].sort((a, b) => (/liste|list/i.test(b.name) ? 1 : 0) - (/liste|list/i.test(a.name) ? 1 : 0));\n    for (const sh of order) { try { trades = btParse(sh.rows); break; } catch (e) { if (e.message !== "NOHEADER") lastErr = e; } }\n    if (!trades) {\n      const first = res.sheets.map(x => (x.rows.find(r => r.some(c => String(c).trim())) || []).slice(0, 12).map(c => String(c).trim()).filter(Boolean).join(" | ")).filter(Boolean)[0] || "leer";\n      throw lastErr || new Error(`Keine Trade-Liste gefunden. Erste Zeile der Datei: „${first.slice(0, 300)}“. Bitte im Strategietester die „Liste der Trades“ exportieren, nicht die Chartdaten.`);\n    }\n    BT.trades = trades; BT.name = f.name; BT.filter = "Alle";\n    await api("/api/backtest/save", {name: f.name, trades: trades.map(t => ({time: t.time.getTime(), setup: t.setup, dir: t.dir, pnl: t.pnl}))});\n    toast(`${trades.length} Trades eingelesen`);\n  } catch (e) { BT.err = e.message; }\n  backtestView(true);\n}\nconst btStats = ts => {\n  const n = ts.length, w = ts.filter(t => t.pnl > 0), l = ts.filter(t => t.pnl <= 0);\n  const gp = w.reduce((a, t) => a + t.pnl, 0), gl = -l.reduce((a, t) => a + t.pnl, 0);\n  let eq = 0, pk = 0, dd = 0; for (const t of ts) { eq += t.pnl; pk = Math.max(pk, eq); dd = Math.min(dd, eq - pk); }\n  return {n, net: gp - gl, wr: n ? w.length / n * 100 : null, pf: gl ? gp / gl : (gp ? Infinity : null), dd, avg: n ? (gp - gl) / n : null,\n    aw: w.length ? gp / w.length : null, al: l.length ? -gl / l.length : null};\n};\nfunction btBars(data) {\n  if (!data.length) return \'<p class="hint">Keine Daten.</p>\';\n  const W = 440, H = 190, L = 52, R = 8, T = 10, B = 24, vals = data.map(d => d.v);\n  const lo = Math.min(0, ...vals), hi = Math.max(0, ...vals), span = hi - lo || 1;\n  const y = v => T + (H - T - B) * (1 - (v - lo) / span), bw = (W - L - R) / data.length, every = Math.ceil(data.length / 12);\n  return `<svg viewBox="0 0 ${W} ${H}" role="img"><line class="gl" x1="${L}" x2="${W - R}" y1="${y(0)}" y2="${y(0)}"/>\n    <text x="${L - 6}" y="${y(hi) + 4}" text-anchor="end">${kUsd(hi)}</text><text x="${L - 6}" y="${y(lo) + 4}" text-anchor="end">${kUsd(lo)}</text>\n    ${data.map((d, i) => { const x0 = L + i * bw + bw * .15, w = bw * .7, y0 = y(Math.max(0, d.v)), h = Math.abs(y(d.v) - y(0));\n      return `<rect x="${x0}" y="${y0}" width="${w}" height="${Math.max(1, h)}" rx="1.5" fill="${d.v >= 0 ? "var(--pos)" : "var(--neg)"}"><title>${d.l}: ${sUsd(d.v)}</title></rect>` +\n        (i % every === 0 ? `<text x="${x0 + w / 2}" y="${H - 6}" text-anchor="middle">${d.l}</text>` : ""); }).join("")}</svg>`;\n}\nasync function backtestView(force) {\n  const body = $("#lnBody");\n  if (!BT.loaded) { BT.loaded = true; try { const r = await api("/api/backtest"); if (r.trades && r.trades.length) { BT.trades = r.trades.map(t => ({...t, time: new Date(t.time)})); BT.name = r.name; } } catch (e) {} }\n  if (BT.src === "live" && (!BT.live || Date.now() - BT.liveAt > 60000)) {\n    try { BT.live = (await api("/api/backtest/live")).trades.map(t => ({...t, time: new Date(t.time)})); BT.liveAt = Date.now(); force = true; } catch (e) { BT.err = e.message; }\n  }\n  if (!force && body.querySelector(".bt")) return;\n  if (TAB !== "learn" || LTAB !== "backtest") return;\n  const all = (BT.src === "live" ? BT.live : BT.trades) || [], setups = [...new Set(all.map(t => t.setup))].sort();\n  const ts = BT.filter === "Alle" ? all : all.filter(t => t.setup === BT.filter), st = btStats(ts);\n  const row = (label, x) => `<tr><td class="t">${label}</td><td>${x.n}</td><td>${pct(x.wr)}</td><td>${x.pf == null ? "–" : isFinite(x.pf) ? num2(x.pf) : "∞"}</td><td class="${cls(x.net)}">${usd(x.net)}</td><td class="${cls(x.avg)}">${x.n ? usd(x.avg) : "–"}</td></tr>`;\n  const tbl = (head, rows) => `<div class="scroll"><table><thead><tr>${head.map((h, i) => `<th class="${i ? "" : "t"}">${h}</th>`).join("")}</tr></thead><tbody>${rows.join("")}</tbody></table></div>`;\n  const H6 = ["", "Trades", "Treffer", "PF", "Netto", "Ø Trade"];\n  let curve = [], e = 0; ts.forEach(t => { e += t.pnl; curve.push({t: t.time.getTime() / 1000, e}); });\n  const months = new Map(); ts.forEach(t => { const k = t.time.getFullYear() + "-" + String(t.time.getMonth() + 1).padStart(2, "0"); months.set(k, (months.get(k) || 0) + t.pnl); });\n  const hours = new Map(); ts.forEach(t => { const h = t.time.getHours(); hours.set(h, (hours.get(h) || 0) + t.pnl); });\n  const DN = ["So", "Mo", "Di", "Mi", "Do", "Fr", "Sa"];\n  const news = ts.filter(t => btNews(t.time).length), calm = ts.filter(t => !btNews(t.time).length);\n  body.innerHTML = `<section class="panel bt">\n    <div class="seg" role="group" aria-label="Quelle" style="align-self:flex-start">${[["export", "TradingView-Export"], ["live", "Live-Signale (automatisch)"]].map(([k, l]) => `<button type="button" data-bsrc="${k}" aria-pressed="${BT.src === k}">${l}</button>`).join("")}</div>\n    ${BT.src === "live" ? `<p class="hint" style="margin:0;line-height:1.6;max-width:85ch">Alle Signale, die die Strategie seit dem Start an die App geschickt hat, auch nicht ausgeführte oder blockierte, mit ihrem echten Ausgang (Stop, Ziel oder Ausstieg). Gerechnet für <b>1 Micro-Kontrakt</b> inklusive Gebühren, damit es mit dem TradingView-Backtest vergleichbar ist. Füllt sich von selbst, kein Export nötig.</p>` : `\n    <div class="section-h"><div><h2 style="font-size:16px;text-transform:none;letter-spacing:0;color:var(--fg)">Backtest aus TradingView</h2>\n      <p class="hint" style="max-width:85ch;margin-top:4px;line-height:1.6">Im TradingView-Strategietester „Liste der Trades“ exportieren (CSV oder Excel, deutsch oder englisch) und hier einlesen. Die App wertet aus: Equity, Drawdown, Setups, Monate, Uhrzeiten, Wochentage und News-Tage (FOMC, CPI, NFP). Der letzte Import bleibt gespeichert.</p></div>\n      <div class="inline"><label class="btn primary" style="cursor:pointer">Export einlesen<input type="file" id="btFile" accept=".csv,.xlsx,.xls,.txt" hidden></label></div></div>\n    <div class="bt-drop" id="btDrop">${BT.name ? `Aktuell: <b>${esc(BT.name)}</b> · ${all.length} Trades · neue Datei hierher ziehen zum Ersetzen` : "Datei hierher ziehen"}</div>\n    ${BT.err ? `<p class="err-msg">${esc(BT.err)}</p>` : ""}`}\n  </section>\n  ${all.length ? `\n  <div class="seg bt-seg" role="group" aria-label="Setup">${["Alle", ...setups].map(k => `<button type="button" data-bf="${esc(k)}" aria-pressed="${BT.filter === k}">${esc(k)}</button>`).join("")}</div>\n  <section class="kpis">${[["Netto-Gewinn", usd(st.net), cls(st.net)], ["Trades", st.n, ""], ["Trefferquote", pct(st.wr), ""],\n    ["Profit-Faktor", st.pf == null ? "–" : isFinite(st.pf) ? num2(st.pf) : "∞", st.pf >= 1 ? "pos" : "neg"], ["Max. Drawdown", usd(st.dd), "neg"],\n    ["Ø Gewinn / Verlust", `${usd(st.aw)} / ${usd(st.al)}`, ""], ["Zeitraum", ts.length ? `${ts[0].time.toLocaleDateString("de-DE")} – ${ts[ts.length - 1].time.toLocaleDateString("de-DE")}` : "–", ""]]\n    .map(([l, v, c]) => `<div class="kpi"><span class="l">${l}</span><span class="v ${c}" style="${/Zeitraum|Ø/.test(l) ? "font-size:14px" : ""}">${v}</span></div>`).join("")}</section>\n  <section class="panel"><div class="section-h"><h2>Equity</h2><p class="hint">Kumulierter Netto-Gewinn je Trade</p></div>${equitySvg(curve)}</section>\n  <div class="grid2">\n    <section class="section"><h2>Nach Setup</h2><div class="panel">${tbl(["Setup", ...H6.slice(1)], setups.map(k => row(`<span class="chip">${esc(k)}</span>`, btStats(all.filter(t => t.setup === k)))))}</div></section>\n    <section class="section"><h2>News-Tage</h2><div class="panel">${tbl(["Tag", ...H6.slice(1)], [row("Normale Tage", btStats(calm)), row("Alle News-Tage", btStats(news)),\n      ...["FOMC", "CPI", "NFP"].map(k => row(`<span class="chip warn">${k}</span>`, btStats(ts.filter(t => btNews(t.time).includes(k)))))])}</div></section>\n  </div>\n  <div class="grid2">\n    <section class="section"><h2>Monatlich</h2><div class="panel">${btBars([...months.entries()].map(([k, v]) => ({l: k.slice(2).replace("-", "/"), v})))}</div></section>\n    <section class="section"><h2>Nach Uhrzeit (deine Ortszeit)</h2><div class="panel">${btBars([...hours.entries()].sort((a, b) => a[0] - b[0]).map(([h, v]) => ({l: h + "h", v})))}</div></section>\n  </div>\n  <section class="section"><h2>Nach Wochentag</h2><div class="panel">${tbl(["Tag", ...H6.slice(1)], [1, 2, 3, 4, 5].map(d => row(DN[d], btStats(ts.filter(t => t.time.getDay() === d)))))}</div></section>\n  <section class="section"><h2>Letzte 40 Trades</h2><div class="panel">${tbl(["Einstieg", "Setup", "News", "Netto"], ts.slice(-40).reverse().map(t =>\n    `<tr><td class="t mono">${t.time.toLocaleString("de-DE", {day: "2-digit", month: "2-digit", year: "2-digit", hour: "2-digit", minute: "2-digit"})}</td><td class="t"><span class="chip">${esc(t.setup)}</span></td><td class="t">${btNews(t.time).map(x => `<span class="chip warn">${x}</span>`).join(" ") || "–"}</td><td class="${cls(t.pnl)}">${usd(t.pnl)}</td></tr>`))}</div></section>`\n  : BT.src === "live" ? `<div class="empty">Noch keine abgeschlossenen Signale. Sobald die Strategie in TradingView Trades macht, erscheinen sie hier automatisch.</div>`\n  : `<div class="empty">Noch kein Backtest eingelesen. So geht\'s: TradingView → unten „Strategietester“ → Tabellen-Ansicht → „Liste der Trades“ → Export (CSV oder Excel) → hier „Export einlesen“.</div>`}`;\n  body.querySelectorAll("[data-bsrc]").forEach(b => b.onclick = () => { BT.src = b.dataset.bsrc; BT.filter = "Alle"; try { localStorage.setItem("fvg-bt-src", BT.src); } catch (e) {} backtestView(true); });\n  if (BT.src === "live") { body.querySelectorAll("[data-bf]").forEach(b => b.onclick = () => { BT.filter = b.dataset.bf; backtestView(true); }); return; }\n  $("#btFile").onchange = e => { const f = e.target.files[0]; if (f) btLoadFile(f); e.target.value = ""; };\n  const dz = $("#btDrop");\n  ["dragenter", "dragover"].forEach(ev => dz.addEventListener(ev, e => { e.preventDefault(); dz.classList.add("over"); }));\n  ["dragleave", "drop"].forEach(ev => dz.addEventListener(ev, e => { e.preventDefault(); dz.classList.remove("over"); }));\n  dz.addEventListener("drop", e => { const f = e.dataTransfer.files[0]; if (f) btLoadFile(f); });\n  body.querySelectorAll("[data-bf]").forEach(b => b.onclick = () => { BT.filter = b.dataset.bf; backtestView(true); });\n}\n\n/* ───────── Einstellungen ───────── */\nfunction field(id, label, value, opts = {}) {\n  const attrs = Object.entries(opts.attrs || {}).map(([k, v]) => `${k}="${v}"`).join(" ");\n  const inp = opts.select ? `<select id="${id}" data-cfg>${opts.select.map(([v, l]) => `<option value="${v}" ${String(v) === String(value) ? "selected" : ""}>${l}</option>`).join("")}</select>`\n    : opts.check ? `<input id="${id}" data-cfg type="checkbox" ${value ? "checked" : ""} class="chk">`\n    : `<input id="${id}" data-cfg type="${opts.type || "number"}" value="${esc(value ?? "")}" ${attrs} ${opts.type === "password" ? \'autocomplete="new-password"\' : ""}>`;\n  return `<div class="row ${opts.cls || ""}" ${opts.hidden ? "hidden" : ""} data-row="${id}"><label for="${id}">${label}${opts.help ? `<small>${opts.help}</small>` : ""}</label>${inp}</div>`;\n}\nconst v = id => { const el = $("#" + id); return !el ? undefined : el.type === "checkbox" ? el.checked : el.value; };\nconst num = id => { const x = parseFloat(v(id)); return isFinite(x) ? x : undefined; };\n// Einstellungs-Bereiche zum Aufklappen. Welche offen sind, merkt sich die App.\nlet OPEN = new Set();\ntry { OPEN = new Set(JSON.parse(localStorage.getItem("fvg-open") || "[]")); } catch (e) { /* ohne Speicher alles zu */ }\nconst SIC = {\n  app: \'<rect x="4" y="4" width="16" height="16" rx="4"/><path d="M12 8v5M9.5 10.5 12 13l2.5-2.5M8.5 16h7"/>\',\n  size: \'<path d="M4 18h16M7 18V9M12 18V5M17 18v-6"/>\',\n  risk: \'<path d="M12 3 5 6v5c0 4.4 3 8.3 7 9.5 4-1.2 7-5.1 7-9.5V6z"/><path d="m9 12 2 2 4-4"/>\',\n  sess: \'<circle cx="12" cy="12" r="8.5"/><path d="M12 7.5V12l3 2"/>\',\n  tv: \'<path d="M4 16 9 10l4 3 7-8"/><path d="M15 5h5v5"/>\',\n  acc: \'<path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1"/><path d="M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1"/>\',\n  adv: \'<path d="M4 7h10M18 7h2M4 17h4M12 17h8"/><circle cx="16" cy="7" r="2"/><circle cx="10" cy="17" r="2"/>\',\n};\nconst intro = t => `<p class="hint" style="margin:0">${t}</p>`;\nconst sec = (key, title, sum, chip, body) => `<details class="set-sec" data-sec="${key}" ${OPEN.has(key) ? "open" : ""}>\n  <summary><span class="s-ic">${icon(SIC[key])}</span><span class="s-t"><b>${title}</b><span class="hint">${sum}</span></span><span class="s-chip">${chip || ""}</span></summary>\n  <div class="set-b">${body}</div></details>`;\n\nlet settingsKey = "";\n// New Yorker Uhrzeit in die Ortszeit des Nutzers umrechnen (aus aktueller NY-Zeit vom Server)\nfunction localTime(hm) {\n  const [nh, nm] = (S.now_ny || "00:00").split(":").map(Number), now = new Date();\n  const off = ((now.getHours() * 60 + now.getMinutes()) - (nh * 60 + nm) + 1440 * 2) % 1440;\n  const rounded = Math.round(off / 30) * 30, [h, m] = hm.split(":").map(Number), t = (h * 60 + m + rounded) % 1440;\n  return `${String(Math.floor(t / 60)).padStart(2, "0")}:${String(t % 60).padStart(2, "0")}`;\n}\nfunction settings() {\n  settingsKey = JSON.stringify([S.tunnel, S.hook_url, S.broker, S.update, S.own_sync && S.own_sync.last, S.own_sync && S.own_sync.error, S.autostart, S.service]);\n  const c = S.config, sz = c.sizing, ss = c.safe_stop, r = c.risk, t = c.tradovate, L = c.learning;\n  const phoneUrl = (c.public_url || S.tunnel.url || "").replace(/\\/+$/, "");\n  const prev = fam => S.sizing_preview[fam].map((p, i) => {\n    const pts = (fam === "NQ" ? [10, 20, 40, 60] : [3, 5, 10, 15])[i];\n    return `<span class="pv">${pts} Pkt. → ${typeof p === "string" ? "zu weit" : `<b>${p[1]}× ${p[0]}</b> <span class="neg">${usd(p[2])}</span>`}</span>`;\n  }).join("");\n  const updState = S.update.available ? `<span class="chip warn">Version ${esc(S.update.version)} verfügbar</span>`\n    : S.update.error && S.update.checked ? `<span class="chip bad">Prüfung fehlgeschlagen</span>`\n    : `<span class="chip good">aktuell</span>`;\n\n  const sessOn = Object.entries(S.sessions).filter(([k]) => (r.sessions || {})[k]).map(([, x]) => x.name);\n  const sizeSum = (sz.mode === "fixed" ? `${sz.fixed_qty} Kontrakt${sz.fixed_qty == 1 ? "" : "e"} pro Trade` : sz.mode === "risk_usd" ? `${usd(sz.risk_usd)} Risiko pro Trade` : `${sz.risk_pct} % Risiko pro Trade`)\n    + ` · ${{auto: "Mini oder Micro", mini: "nur Mini", micro: "nur Micro"}[sz.contract_type] || ""} · max. ${sz.max_qty}`;\n  const riskSum = `Stop NQ ${ss.NQ.default} / ES ${ss.ES.default} Pkt. · Ziel ${ss.default_rr} R · ${r.max_daily_loss > 0 ? "Tageslimit " + usd(r.max_daily_loss) : "kein Tageslimit"} · ${(c.news || {}).enabled ? `News-Pause ±${c.news.before_min}/${c.news.after_min} Min` : "keine News-Pause"}`;\n  const tunChip = S.tunnel.ok || c.public_url ? `<span class="chip ${S.tunnel.fixed || c.public_url ? "good" : "warn"}">${S.tunnel.fixed || c.public_url ? "feste Adresse" : "wechselnde Adresse"}</span>` : \'<span class="chip bad">getrennt</span>\';\n  const accChip = t.username && t.cid ? (S.own_sync.error ? \'<span class="chip bad">Fehler</span>\' : \'<span class="chip good">Tradovate</span>\') : \'<span class="chip mute">nicht verbunden</span>\';\n  $("#main").innerHTML = `<div class="settings-wrap">\n  ${sec("app", "App & Updates", `Version ${esc(S.version)}${S.autostart ? " · startet mit Windows" : ""} · Handy · Protokoll`, updState, `\n    <div class="row"><label>Installierte Version<small>${S.update.checked ? "Zuletzt geprüft: " + dtm(S.update.checked) : "Die App prüft bei jedem Start und alle 6 Stunden."}</small></label>\n      <div class="inline"><b class="mono">${esc(S.version)}</b> ${updState}</div></div>\n    <div class="row"><label>Programmdatei<small>Diese Datei läuft gerade, auf sie zeigt auch das Desktop-Symbol. Andere Kopien (z. B. „FVG-Trader (1).cmd“ in Downloads) kannst du löschen.</small></label>\n      <div class="inline"><span class="mono" style="font-size:11.5px;word-break:break-all;text-align:right">${esc(S.launcher || "–")}</span></div></div>\n    <div class="row"><label>Nach Updates suchen und installieren<small>${S.update.available && S.update.notes ? esc(S.update.notes) : "Deine Einstellungen und Trades bleiben erhalten."}</small></label>\n      <button class="btn primary" id="updNowSet">Jetzt aktualisieren</button></div>\n    ${field("au", "Updates automatisch installieren", c.auto_update, {check: true, help: "Sucht stündlich nach neuen Versionen und installiert sie selbst, aber nie während ein Trade oder Vorschlag offen ist. Danach startet die App kurz neu."})}\n    ${S.platform.startsWith("win") ? `<div class="row"><label>Desktop-Symbol<small>Legt „FVG Trader“ auf dem Desktop und im Startmenü neu an.</small></label>\n      <button class="btn" id="mkIcon">Desktop-Symbol anlegen</button></div>` : ""}\n    ${S.platform.startsWith("win") ? `<div class="row"><label>Als Dienst starten (ohne Anmeldung)<small>${(S.service || {}).installed\n        ? `Eingerichtet: FVG Trader startet beim Hochfahren des PCs/Servers von selbst, auch ohne dass sich jemand anmeldet.${(S.service || {}).running ? " Läuft gerade als Dienst." : " Läuft gerade noch normal, ab dem nächsten Hochfahren als Dienst."}`\n        : "Ideal für einen Windows-Server: startet beim Hochfahren, ohne Anmeldung. Windows fragt einmal nach Administratorrechten."}</small></label>\n      <button class="tgl" id="svcT" role="switch" aria-checked="${!!(S.service || {}).installed}" aria-label="Als Dienst starten"></button></div>` : ""}\n    ${S.platform.startsWith("win") && !(S.service || {}).installed ? `<div class="row"><label>Mit Windows starten<small>Startet nach deiner Anmeldung still im Hintergrund.</small></label>\n      <button class="tgl" id="asT" role="switch" aria-checked="${S.autostart}" aria-label="Mit Windows starten"></button></div>` : ""}\n    <div class="row"><label>FVG Trader beenden<small>Ohne Beenden läuft der Bot im Hintergrund weiter, auch wenn das Fenster zu ist.</small></label>\n      <button class="btn ghost-danger" id="quit">App beenden</button></div>\n    <span class="lbl">Aufs Handy</span>\n    <div class="copyrow"><div class="code">${esc(phoneUrl || "kommt, sobald die Internet-Verbindung steht")}</div><button class="btn" id="cpPhone" ${phoneUrl ? "" : "disabled"}>Kopieren</button></div>\n    ${intro(`Am Handy öffnen, anmelden und „Zum Startbildschirm“ wählen. ${S.tunnel.fixed || c.public_url ? "Die Adresse bleibt fest." : "Die Adresse ändert sich bei jedem Neustart, mit ngrok-Schlüssel (TradingView) bleibt sie fest."}`)}\n    <span class="lbl">Protokoll</span>\n    <div class="inline wrap-gap"><button class="btn" id="logShow">App-Log anzeigen</button><button class="btn" id="logFolder">Ordner öffnen</button></div>\n    ${intro("Hilfreich, wenn etwas nicht klappt: Log anzeigen, kopieren und in den Chat schicken.")}`)}\n\n  ${sec("size", "Positionsgröße", sizeSum, "", `\n    <div class="row"><label>Methode</label><div class="seg" role="group" aria-label="Methode">${[["fixed", "Feste Anzahl"], ["risk_usd", "Risiko $"], ["risk_pct", "Risiko %"]].map(([k, l]) =>\n      `<button type="button" data-mode="${k}" aria-pressed="${sz.mode === k}">${l}</button>`).join("")}</div></div>\n    ${field("fq", "Kontrakte pro Trade", sz.fixed_qty, {attrs: {min: 1, step: 1}, hidden: sz.mode !== "fixed"})}\n    ${field("ru", "Risiko pro Trade ($)", sz.risk_usd, {attrs: {min: 10, step: 10}, hidden: sz.mode !== "risk_usd", help: "Größe wird aus dem Stop-Abstand berechnet"})}\n    ${field("rp", "Risiko pro Trade (% vom Konto)", sz.risk_pct, {attrs: {min: 0.05, max: 5, step: 0.05}, hidden: sz.mode !== "risk_pct"})}\n    ${field("ct", "Kontrakttyp", sz.contract_type, {select: [["auto", "Automatisch (Mini oder Micro)"], ["mini", "Nur Mini (NQ / ES)"], ["micro", "Nur Micro (MNQ / MES)"]]})}\n    ${field("mq", "Höchstens Kontrakte", sz.max_qty, {attrs: {min: 1, step: 1}})}\n    <div class="preview"><span class="hint">Beispiel mit gespeicherter Einstellung</span><div><b>NQ</b> ${prev("NQ")}</div><div><b>ES</b> ${prev("ES")}</div></div>`)}\n\n  ${sec("risk", "Risiko & Schutz", riskSum, \'<span class="chip good">Safe-Stop an</span>\', `\n    ${intro("Jede Order bekommt einen Stop-Loss. Fehlt er im Signal, nimmt der Bot den Standard-Stop.")}\n    ${field("nqd", "Standard-Stop NQ (Punkte)", ss.NQ.default, {attrs: {step: 0.25, min: 1}})}\n    ${field("esd", "Standard-Stop ES (Punkte)", ss.ES.default, {attrs: {step: 0.25, min: 0.25}})}\n    ${field("rr", "Standard-Ziel (R)", ss.default_rr, {attrs: {step: 0.25, min: 0.5}, help: "Wenn das Signal kein Ziel mitschickt"})}\n    ${field("mdl", "Tagesverlust-Limit ($)", r.max_daily_loss, {attrs: {min: 0, step: 50}, help: "Danach handelt der Bot heute nicht mehr. 0 = aus"})}\n    ${field("mtd", "Max. Trades pro Tag", r.max_trades_day, {attrs: {min: 1, step: 1}})}\n    <span class="lbl">News-Pause</span>\n    ${field("nwE", "Rund um wichtige News nicht handeln", (c.news || {}).enabled, {check: true, help: "Nutzt den Wirtschaftskalender (Cockpit → Wirtschafts-News). Gilt zusätzlich zum News-Filter im TradingView-Script."})}\n    ${field("nwB", "Minuten vorher sperren", (c.news || {}).before_min, {attrs: {min: 0, max: 240, step: 1}})}\n    ${field("nwA", "Minuten danach sperren", (c.news || {}).after_min, {attrs: {min: 0, max: 240, step: 1}})}\n    ${field("nwI", "Welche News", (c.news || {}).impact, {select: [["high", "Nur hohe Wichtigkeit (rot)"], ["medium", "Hohe und mittlere (rot + orange)"]]})}\n    ${field("nwU", "Nur US-News", (c.news || {}).usd_only, {check: true, help: "NQ und ES reagieren vor allem auf US-Daten"})}\n    ${field("nwC", "Offene Positionen vorher schließen", (c.news || {}).close_before, {check: true, help: "1 Minute vor dem Termin, damit kein Trade in die Veröffentlichung läuft"})}`)}\n\n  ${sec("sess", "Sessions & Vorschläge", r.all_day ? "Ganztägig" + (sessOn.length ? " · " + sessOn.join(" · ") : "") : sessOn.length ? sessOn.join(" · ") : "keine Session angehakt", `<span class="chip ${S.session_open ? "good" : "mute"}">${S.session_open ? "jetzt offen" : "gerade zu"}</span>`, `\n    ${intro("Hak an, in welchen Sessions der Bot handeln darf. Die gleichen Haken gibt es in den Einstellungen der TradingView-Strategie.")}\n    <div class="sess-list">${Object.entries(S.sessions).map(([k, x]) => `<label class="sess ${(r.sessions || {})[k] ? "on" : ""}">\n      <input type="checkbox" class="chk" data-cfg data-sess="${k}" ${(r.sessions || {})[k] ? "checked" : ""}>\n      <span class="sess-n">${esc(x.name)}</span><span class="sess-t mono">${x.start}–${x.end === "00:00" ? "24:00" : x.end} NY</span><span class="sess-t mono hint">${localTime(x.start)}–${localTime(x.end)} bei dir</span></label>`).join("")}</div>\n    ${field("ad", "Ganztägig handeln", r.all_day, {check: true, help: "Handelt zu jeder Uhrzeit, außer in der Marktpause 17–18 Uhr NY und am Wochenende. In TradingView dafür ebenfalls „Ganztägig handeln“ anhaken."})}\n    ${field("es", "Nur in der Handelszeit handeln", r.enforce_session, {check: true})}\n    ${field("fe", "Zum Ende der Session schließen", r.flat_at_session_end, {check: true, help: "Offene Positionen werden geschlossen, wenn ihre Session endet"})}\n    ${field("to", "Vorschlag verfällt nach (Sekunden)", c.suggestion_timeout_sec, {attrs: {min: 15, step: 15}, help: "Gilt, wenn der Auto-Modus aus ist"})}\n    ${field("le", "Lernmodul aktiv", L.enabled, {check: true, help: "Schwache Strategien bekommen halbe Größe oder Pause"})}`)}\n\n  ${sec("tv", "TradingView", "Webhook-Adresse, Alert-Nachricht, Strategie-Script", tunChip, `\n    ${S.remote && S.remote.limit ? `<div class="row"><label>Anfragen über ngrok diesen Monat<small>Kostenlos sind ${S.remote.limit.toLocaleString("de-DE")} im Monat. Die meisten braucht TradingView (Kerzen alle 5 Min, Live-Kurs nur im Trade). Am Handy fragt die App deshalb nur alle 10–30 s nach.</small></label>\n      <div class="inline"><b class="mono ${S.remote.n > S.remote.limit * 0.8 ? "neg" : ""}">${S.remote.n.toLocaleString("de-DE")}</b><span class="hint">/ ${S.remote.limit.toLocaleString("de-DE")}</span></div></div>` : ""}\n    <div class="row"><label>Internet-Verbindung<small>${c.public_url ? "Eigene Adresse aus „Erweitert“." : S.tunnel.fixed ? "Feste Adresse: bleibt nach Neustarts gleich, der Alert muss nie wieder angepasst werden." : "Die Adresse wechselt bei jedem Neustart. Mit einem ngrok-Schlüssel wird sie fest."}</small></label>\n      <div class="inline">${S.tunnel.ok || c.public_url ? \'<span class="chip good">aktiv</span>\' : `<span class="chip bad" style="white-space:normal;text-align:left;max-width:100%">${esc(S.tunnel.status)}</span>`}\n        <span class="chip ${S.tunnel.fixed || c.public_url ? "good" : "warn"}">${S.tunnel.fixed || c.public_url ? "feste Adresse" : "wechselnde Adresse"}</span></div></div>\n    ${field("ngt", "ngrok-Schlüssel für feste Adresse", (c.tunnel || {}).ngrok_token, {type: "password", help: "Kostenlos: ngrok.com → registrieren → im Dashboard „Your Authtoken“ kopieren und hier einfügen"})}\n    <div><span class="lbl">Webhook-Adresse für den Alert</span><div class="copyrow"><div class="code" id="hook">${esc(S.hook_url || "wird automatisch erzeugt …")}</div><button class="btn" id="cp" ${S.hook_url ? "" : "disabled"}>Kopieren</button></div></div>\n    <div><span class="lbl">Alert-Nachricht</span><div class="copyrow"><div class="code" id="msgTpl">{{strategy.order.alert_message}}</div><button class="btn" id="cp2">Kopieren</button></div></div>\n    <div class="inline wrap-gap"><button class="btn" id="cpPine2">Strategie-Script kopieren</button><button class="btn" id="tL">Test-Signal senden</button></div>`)}\n\n  ${sec("acc", "Konten & Broker", `Bot handelt über ${c.broker === "tradovate" ? "Tradovate" : "Paper-Trading"}${c.own_sync && c.own_sync.tradovate ? " · eigene Trades werden übernommen" : ""}`, accChip, `\n    ${intro("Einmal verbinden: Deine eigenen Trades kommen dann automatisch in den Kalender.")}\n    <div class="row"><label>TradingView<small>TradingView hat keine Schnittstelle für deine Trades. Handelst du in TradingView über Tradovate, kommen die Trades über die Tradovate-Verknüpfung unten.</small></label>\n      <div class="inline"><span class="chip mute">über Tradovate</span></div></div>\n    <span class="lbl">Tradovate ${t.username && t.cid ? (S.own_sync.error ? \'<span class="chip bad">Fehler</span>\' : \'<span class="chip good">hinterlegt</span>\') : \'<span class="chip mute">nicht verbunden</span>\'}</span>\n    ${field("tenv", "Konto", t.env, {select: [["demo", "Demo"], ["live", "Live (echtes Konto)"]]})}\n    ${field("tu", "Benutzername", t.username, {type: "text", attrs: {autocomplete: "off"}})}\n    ${field("tpw", "Passwort", t.password, {type: "password"})}\n    ${field("tcid", "API cid", t.cid, {type: "text", help: "Tradovate → Einstellungen → API-Zugang (API-Add-on nötig)"})}\n    ${field("tsec", "API secret", t.secret, {type: "password"})}\n    ${field("osync", "Eigene Trades automatisch übernehmen", c.own_sync && c.own_sync.tradovate, {check: true, help: "Alle 10 Minuten. Trades des Bots werden erkannt und nicht doppelt gezählt."})}\n    ${S.own_sync.enabled ? `<div class="row"><label>Letzter Abruf<small>${S.own_sync.error ? `<span class="neg">${esc(S.own_sync.error)}</span>` : S.own_sync.last ? `${S.own_sync.added} neue Trades` : "läuft gleich"}</small></label>\n      <div class="inline"><span class="mono">${S.own_sync.last ? dtm(S.own_sync.last) : "–"}</span></div></div>` : ""}\n    <div class="inline wrap-gap"><button class="btn" id="tvTest">Verbindung testen</button>${S.own_sync.enabled ? \'<button class="btn" id="syncNow">Eigene Trades jetzt abrufen</button>\' : ""}</div>\n    <span class="lbl">Bot-Orders</span>\n    ${field("bk", "Der Bot handelt über", c.broker, {select: [["paper", "Paper-Trading (Simulation)"], ["tradovate", "Tradovate-Konto oben"]], help: c.broker === "tradovate" ? `Status: ${esc(S.broker.status || "–")}` : "Empfohlen, bis der Bot sich bewährt hat"})}\n    <div id="ppd" class="sub" ${c.broker === "paper" ? "" : "hidden"}>\n      ${field("pb", "Startkapital Paper ($)", c.paper.start_balance, {attrs: {min: 1000, step: 1000}})}\n      <div class="inline wrap-gap"><button class="btn ghost-danger" id="pr">Paper-Konto zurücksetzen</button></div>\n    </div>`)}\n\n  ${sec("adv", "Erweitert", "Safe-Stop-Grenzen, Lernmodul, Paper, Kontrakte, eigene Adresse", \'<span class="chip mute">nur bei Bedarf</span>\', `\n    <span class="lbl">Safe-Stop-Grenzen (Punkte)</span>\n    ${field("nqmin", "NQ Minimum", ss.NQ.min, {attrs: {step: 0.25, min: 0.25}})}\n    ${field("nqmax", "NQ Maximum", ss.NQ.max, {attrs: {step: 0.25, min: 1}})}\n    ${field("esmin", "ES Minimum", ss.ES.min, {attrs: {step: 0.25, min: 0.25}})}\n    ${field("esmax", "ES Maximum", ss.ES.max, {attrs: {step: 0.25, min: 0.5}})}\n    <span class="lbl">Bot-Verhalten</span>\n    ${field("mo", "Max. gleichzeitige Positionen", r.max_open, {attrs: {min: 1, step: 1}})}\n    ${field("fx", "Exit-Signalen aus TradingView folgen", c.follow_tv_exits, {check: true})}\n    <span class="lbl">Lernmodul</span>\n    ${field("lw", "Auswerten über letzte Trades", L.window, {attrs: {min: 5, max: 500, step: 1}})}\n    ${field("lm", "Mindest-Trades vor Bewertung", L.min_trades, {attrs: {min: 3, step: 1}})}\n    ${field("lh", "Halbe Größe unter Ø R", L.half_below_r, {attrs: {step: 0.05}})}\n    ${field("lp", "Pause unter Ø R", L.pause_below_r, {attrs: {step: 0.05}})}\n    <span class="lbl">Paper-Trading</span>\n    ${field("psl", "Slippage (Ticks)", c.paper.slippage_ticks, {attrs: {min: 0, step: 1}})}\n    ${field("pc", "Gebühr pro Kontrakt & Seite ($)", c.paper.commission, {attrs: {min: 0, step: 0.05}})}\n    <span class="lbl">Tradovate</span>\n    ${field("tacc", "Kontoname", t.account, {type: "text", help: "Leer = erstes Konto. Bei mehreren Konten (z. B. Topstep) den Namen eintragen."})}\n    ${field("cnq", "Kontrakt NQ / MNQ", c.contracts.NQ, {type: "text", attrs: {placeholder: "automatisch"}})}\n    ${field("ces", "Kontrakt ES / MES", c.contracts.ES, {type: "text", attrs: {placeholder: "automatisch"}})}\n    <span class="lbl">Verbindung & Updates</span>\n    ${field("pu", "Eigene feste Adresse", c.public_url, {type: "url", attrs: {placeholder: "leer = automatisch"}, help: "Nur mit ngrok o. Ä."})}\n    <div class="inline wrap-gap"><button class="btn ghost-danger" id="rt">Neue Webhook-Adresse erzeugen</button>\n      <label class="btn" style="cursor:pointer">Update aus Datei<input type="file" id="updFile" accept=".cmd" hidden></label></div>`)}\n  </div>\n  <div class="savebar" id="savebar" hidden><span class="hint" id="saveMsg">Du hast Änderungen.</span><button class="btn" id="discard">Verwerfen</button><button class="btn primary" id="saveAll">Änderungen speichern</button></div>`;\n\n  document.querySelectorAll("details.set-sec").forEach(d => d.ontoggle = () => {\n    d.open ? OPEN.add(d.dataset.sec) : OPEN.delete(d.dataset.sec);\n    try { localStorage.setItem("fvg-open", JSON.stringify([...OPEN])); } catch (e) { /* egal */ }\n  });\n\n  // Änderungen sammeln, eine Speichern-Leiste\n  let mode = sz.mode;\n  const dirty = () => { settingsDirty = true; $("#savebar").hidden = false; };\n  $("#main").oninput = e => { if (e.target.matches("[data-cfg]")) dirty(); };\n  $("#main").onchange = e => { if (e.target.matches("[data-cfg]")) dirty(); };\n  document.querySelectorAll("[data-mode]").forEach(b => b.onclick = () => {\n    mode = b.dataset.mode; document.querySelectorAll("[data-mode]").forEach(x => x.setAttribute("aria-pressed", x === b));\n    $(\'[data-row="fq"]\').hidden = mode !== "fixed"; $(\'[data-row="ru"]\').hidden = mode !== "risk_usd"; $(\'[data-row="rp"]\').hidden = mode !== "risk_pct"; dirty(); });\n  $("#bk").addEventListener("change", () => { $("#ppd").hidden = v("bk") !== "paper"; });\n  $("#discard").onclick = () => { settingsDirty = false; render(true); };\n  const doSave = async () => {\n    const patch = {\n      sizing: {mode, fixed_qty: v("fq"), risk_usd: num("ru"), risk_pct: num("rp"), contract_type: v("ct"), max_qty: v("mq")},\n      safe_stop: {NQ: {default: num("nqd"), min: num("nqmin"), max: num("nqmax")}, ES: {default: num("esd"), min: num("esmin"), max: num("esmax")}, default_rr: num("rr")},\n      risk: {max_daily_loss: num("mdl"), max_trades_day: parseInt(v("mtd")), max_open: parseInt(v("mo")), enforce_session: v("es"), all_day: v("ad"), flat_at_session_end: v("fe"),\n        sessions: Object.fromEntries([...document.querySelectorAll("[data-sess]")].map(x => [x.dataset.sess, x.checked]))},\n      auto_update: v("au"),\n      news: {enabled: v("nwE"), before_min: parseInt(v("nwB")), after_min: parseInt(v("nwA")), impact: v("nwI"), usd_only: v("nwU"), close_before: v("nwC")},\n      suggestion_timeout_sec: parseInt(v("to")), follow_tv_exits: v("fx"),\n      learning: {enabled: v("le"), window: v("lw"), min_trades: v("lm"), half_below_r: num("lh"), pause_below_r: num("lp")},\n      broker: v("bk"), public_url: v("pu").trim(),\n      tradovate: {env: v("tenv"), username: v("tu"), password: v("tpw"), cid: v("tcid"), secret: v("tsec"), account: v("tacc")},\n      contracts: {NQ: v("cnq"), MNQ: v("cnq") ? v("cnq").replace(/^NQ/i, "MNQ") : "", ES: v("ces"), MES: v("ces") ? v("ces").replace(/^ES/i, "MES") : ""},\n      paper: {start_balance: num("pb") ?? c.paper.start_balance, slippage_ticks: parseInt(v("psl")), commission: num("pc")},\n      own_sync: {tradovate: v("osync")},\n      tunnel: {ngrok_token: (v("ngt") || "").trim()},\n    };\n    await api("/api/config", patch); settingsDirty = false;\n  };\n  $("#saveAll").onclick = async () => {\n    try { await doSave(); toast("Gespeichert"); await refresh(true); }\n    catch (e) { $("#saveMsg").textContent = e.message; $("#saveMsg").className = "err-msg"; }\n  };\n  $("#tvTest").onclick = async () => {\n    try { if (settingsDirty) await doSave(); const r = await api("/api/tradovate/test", {}); toast(r.ok ? r.status : "Fehler: " + r.status); await refresh(true); }\n    catch (e) { toast(e.message); }\n  };\n  const sn = $("#syncNow"); if (sn) sn.onclick = async () => {\n    sn.disabled = true; sn.textContent = "Rufe ab …";\n    try { const r = await api("/api/own/sync", {}); toast(r.ok ? `${r.added} neue eigene Trades übernommen` : "Fehler: " + r.error); } catch (e) { toast(e.message); }\n    await refresh(true);\n  };\n\n  // Protokoll\n  $("#logShow").onclick = showLog;\n  $("#logFolder").onclick = async () => { try { const r = await api("/api/open-folder", {}); toast("Ordner geöffnet: " + r.folder); } catch (e) { toast(e.message); } };\n\n  // Sofort-Aktionen\n  $("#updNowSet").onclick = async () => {\n    const b = $("#updNowSet"); b.disabled = true; b.textContent = "Suche …";\n    try {\n      const u = await api("/api/update/check", {});\n      if (u.available) return runUpdate(() => api("/api/update/apply", {}));\n      toast(u.error && !u.version ? u.error : `Du hast die neueste Version (${S.version})`);\n    } catch (e) { toast(e.message); }\n    b.disabled = false; b.textContent = "Jetzt aktualisieren"; refresh(true);\n  };\n  const mk = $("#mkIcon"); if (mk) mk.onclick = () => act(() => api("/api/shortcut", {}), "Desktop-Symbol angelegt");\n  const sv = $("#svcT");\n  if (sv) sv.onclick = () => {\n    const on = !(S.service || {}).installed;\n    serviceSet(on);\n  };\n  const as = $("#asT"); if (as) as.onclick = () => act(() => api("/api/autostart", {on: !S.autostart}), !S.autostart ? "Startet ab jetzt mit Windows" : "Autostart aus").then(() => render(true));\n  $("#quit").onclick = () => confirmBtn($("#quit"), S.positions.length ? "Positionen offen. Trotzdem?" : "Wirklich beenden?", async () => {\n    try { await api("/api/shutdown", {}); } catch (e) {}\n    document.body.innerHTML = `<div class="login"><form><h1>FVG Trader ist beendet</h1><p class="hint">Signale aus TradingView werden jetzt nicht verarbeitet. Zum Starten auf das Desktop-Symbol <b>FVG Trader</b> klicken.</p><p class="hint">Du kannst dieses Fenster jetzt schließen.</p></form></div>`;\n    setTimeout(() => { try { window.close(); } catch (e) {} }, 600);\n  });\n  $("#cp").onclick = () => copyText(S.hook_url, "Adresse"); $("#cp2").onclick = () => copyText("{{strategy.order.alert_message}}", "Nachricht");\n  $("#cpPine2").onclick = async () => { try { const r = await api("/api/pine"); copyText(r.source, "Script"); } catch (e) { toast(e.message); } };\n  $("#tL").onclick = () => act(() => api("/api/test-signal", {fam: "NQ", side: "long"}).then(r => { TAB = "cockpit"; setHash("cockpit"); return r; }), "Test-Signal gesendet");\n  const pr = $("#pr"); if (pr) pr.onclick = () => confirmBtn(pr, "Alle Paper-Trades löschen?", () => act(() => api("/api/paper/reset", {}), "Paper-Konto zurückgesetzt").then(() => render(true)));\n  const cpPhone = $("#cpPhone"); if (cpPhone) cpPhone.onclick = () => copyText(phoneUrl, "Adresse");\n  $("#rt").onclick = () => confirmBtn($("#rt"), "Alte Adresse wird ungültig. Sicher?", () => act(() => api("/api/token", {}), "Neue Adresse erzeugt: im TradingView-Alert ersetzen").then(() => render(true)));\n  $("#updFile").onchange = e => { const f = e.target.files[0]; if (!f) return;\n    runUpdate(async () => { const r = await fetch("/api/update/upload", {method: "POST", headers: {"X-Requested-With": "fvg"}, body: f});\n      const j = await r.json().catch(() => ({})); if (!r.ok) throw new Error(j.error || "Update fehlgeschlagen"); return j; }); };\n}\n\nasync function showLog() {\n  let r;\n  try { r = await api("/api/log"); } catch (e) { toast(e.message); return; }\n  let view = "log";\n  const text = () => view === "log" ? (r.log.length ? r.log.join("\\n") : "(noch keine Einträge)") : (r.events.join("\\n") || "(keine Aktivität)");\n  const close = modal(`<div class="section-h"><h2 style="font-size:18px">Protokoll · Version ${esc(r.version)}</h2>\n      <div class="seg" role="group" aria-label="Ansicht"><button type="button" data-v="log" aria-pressed="true">App-Log</button><button type="button" data-v="ev" aria-pressed="false">Aktivität</button></div></div>\n    <pre class="code logbox" id="logTxt"></pre>\n    <p class="hint" style="margin:0;word-break:break-all">Datei: ${esc(r.path)}</p>\n    <div class="actions"><button class="btn primary" id="logCopy">Alles kopieren</button><button class="btn" id="logClose">Schließen</button></div>`);\n  const fill = () => { $("#logTxt").textContent = text(); $("#logTxt").scrollTop = $("#logTxt").scrollHeight; };\n  document.querySelectorAll("#mdl [data-v]").forEach(b => b.onclick = () => { view = b.dataset.v === "log" ? "log" : "ev";\n    document.querySelectorAll("#mdl [data-v]").forEach(x => x.setAttribute("aria-pressed", x === b)); fill(); });\n  fill();\n  $("#logCopy").onclick = () => copyText(`FVG Trader ${r.version}\\n--- App-Log ---\\n${r.log.slice(-120).join("\\n")}\\n--- Aktivität ---\\n${r.events.slice(-60).join("\\n")}`, "Protokoll");\n  $("#logClose").onclick = close;\n}\n\n/* ───────── Nur ein Fenster ───────── */\n// Wird FVG Trader ein zweites Mal geöffnet, übernimmt das neue Fenster; das alte schließt sich oder wird gesperrt.\nconst WIN_ID = Math.random().toString(36).slice(2);\nlet BLOCKED = false;\nconst BC = "BroadcastChannel" in window ? new BroadcastChannel("fvg-trader-fenster") : null;\nfunction claimWindow() { BLOCKED = false; const o = $("#winBlock"); if (o) o.remove(); if (BC) BC.postMessage({t: "claim", id: WIN_ID}); }\nfunction blockWindow() {\n  if (BLOCKED) return;\n  BLOCKED = true;\n  try { window.close(); } catch (e) {}\n  document.body.insertAdjacentHTML("beforeend", `<div id="winBlock" style="position:fixed;inset:0;z-index:60;background:var(--bg);display:grid;place-items:center;padding:16px">\n    <div class="panel" style="max-width:380px;display:flex;flex-direction:column;gap:12px;text-align:center">\n      <h2 style="font-size:19px">In einem anderen Fenster geöffnet</h2>\n      <p class="hint" style="margin:0">FVG Trader läuft schon in einem anderen Fenster. Du kannst dieses hier schließen.</p>\n      <button class="btn primary" id="winHere">Hier weiterverwenden</button></div></div>`);\n  $("#winHere").onclick = () => { claimWindow(); refresh(true); };\n}\nif (BC) BC.onmessage = e => { if (e.data && e.data.t === "claim" && e.data.id !== WIN_ID) blockWindow(); };\n\n/* ───────── Laufzeit ───────── */\nfunction render(full) {\n  if (!S) return;\n  if (full && TAB !== "settings" && $("#main")) { $("#main").oninput = null; $("#main").onchange = null; }\n  header();\n  document.querySelectorAll("[data-tab]").forEach(x => x.setAttribute("aria-current", x.dataset.tab === TAB));\n  document.title = "FVG Trader · " + (NAV.find(n => n[0] === TAB) || NAV[0])[1];\n  if (TAB === "cockpit") cockpit(full);\n  else if (full) ({calendar, stats, learn, settings, challenge}[TAB])();\n  else if (TAB === "challenge") challenge(false);\n  else if (TAB === "settings" && !settingsDirty && !document.activeElement.matches("input,select")) {\n    // Status-Anzeigen live nachziehen (Verbindung, Broker, Updates, Abruf), ohne Eingaben zu stören\n    const key = JSON.stringify([S.tunnel, S.hook_url, S.broker, S.update, S.own_sync && S.own_sync.last, S.own_sync && S.own_sync.error, S.autostart, S.service]);\n    if (key !== settingsKey) { const y = scrollY; settings(); scrollTo(0, y); }\n  }\n  else if (TAB === "stats" || TAB === "learn" || TAB === "calendar") ({calendar, stats, learn}[TAB])();\n}\nasync function refresh(full) {\n  S = await api("/api/state");\n  notifyNew();\n  render(full);\n}\nfunction notifyNew() {\n  const ids = S.pending.map(p => p.id), fresh = ids.filter(id => !seenPending.has(id));\n  ids.forEach(id => seenPending.add(id));\n  if (firstLoad) { firstLoad = false; return; }\n  if (!fresh.length) return;\n  const p = S.pending.find(x => x.id === fresh[0]);\n  document.title = "● Neuer Vorschlag · FVG Trader";\n  setTimeout(() => document.title = "FVG Trader", 8000);\n  try { const a = new AudioContext(), o = a.createOscillator(), g = a.createGain(); o.frequency.value = 880; g.gain.value = .08; o.connect(g).connect(a.destination); o.start(); o.stop(a.currentTime + .18); } catch (e) {}\n  if ("Notification" in window && Notification.permission === "granted")\n    new Notification("Neuer Trade-Vorschlag", {body: `${p.side === "long" ? "LONG" : "SHORT"} ${p.qty}× ${p.root} · ${p.setup} · Stop ${px(p.sl)}`});\n}\nasync function start() {\n  TAB = ["cockpit", "calendar", "stats", "challenge", "learn", "settings"].includes(location.hash.slice(1)) ? location.hash.slice(1) : "cockpit";\n  shell();\n  if ("Notification" in window && Notification.permission === "default") document.addEventListener("click", () => Notification.requestPermission(), {once: true});\n  try { await refresh(true); } catch (e) { return; }\n  startupUpdatePrompt();\n  claimWindow();\n  // Über die Internet-Adresse (Handy) seltener abfragen: ngrok kostenlos erlaubt 20.000 Anfragen im Monat,\n  // und die braucht vor allem TradingView. Im Hintergrund (Tab nicht sichtbar) gar nicht abfragen.\n  const REMOTE_UI = !["localhost", "127.0.0.1", "[::1]"].includes(location.hostname);\n  let lastPoll = Date.now();\n  const poll = async force => {\n    if (BLOCKED || document.hidden) return;\n    if (TAB === "settings" && settingsDirty) return;\n    const every = REMOTE_UI ? (S && S.positions && S.positions.length ? 10000 : 30000) : 2000;\n    if (!force && Date.now() - lastPoll < every) return;\n    lastPoll = Date.now();\n    try { await refresh(false); } catch (e) {}\n  };\n  setInterval(() => poll(false), 1000);\n  document.addEventListener("visibilitychange", () => { if (!document.hidden) poll(true); });\n  setInterval(() => !BLOCKED && S && TAB === "cockpit" && timers(), 1000);\n}\nfetch("/api/auth").then(r => r.json()).then(a => a.logged_in ? start() : showLogin());\nif ("serviceWorker" in navigator) navigator.serviceWorker.register("/sw.js").catch(() => {});\n</script>\n</body>\n</html>\n'

PINE_SOURCE = '// This Pine Script® code is subject to the terms of the Mozilla Public License 2.0\n// Multi-Strategie Futures-Bot für NQ & ES (auch MNQ / MES)\n// Strategien: FVG, inverse FVG, Silver Bullet (FVG 10–11 NY), Opening Range Breakout, Liquidity Sweep (Vortag), VWAP-Reclaim\n// Verbindung zur FVG-Trader-App: Alert mit „Orderausführungen und alert()-Aufrufe“, Webhook = App-URL\n// Chart: NQ1! oder ES1!, Timeframe 5m (empfohlen) oder 1m/3m\n// Auto-Trading: Alert auf diese Strategie, Nachricht = {{strategy.order.alert_message}}, Webhook-URL deines Brokers/Connectors\n//@version=6\nstrategy("FVG Bot · Multi-Strategie [NQ·ES]", shorttitle = "FVG Bot", overlay = true,\n     initial_capital = 50000, default_qty_type = strategy.fixed, default_qty_value = 1,\n     commission_type = strategy.commission.cash_per_contract, commission_value = 2.25,\n     slippage = 1, pyramiding = 0, max_boxes_count = 400, max_labels_count = 100,\n     calc_on_every_tick = true, process_orders_on_close = false, margin_long = 0, margin_short = 0)\n// margin_long/short = 0: Futures brauchen nur eine kleine Sicherheitsleistung. Mit TradingViews Standard (100 % des Kontraktwerts)\n// würde z. B. 1 MNQ bei 28.000 Punkten (56.000 $) bei 50.000 $ Startkapital abgelehnt und es gäbe weder Trades noch Signale.\n// calc_on_every_tick: nur für den Live-Kurs an die App. Alle Handelsentscheidungen fallen weiter erst zum Kerzenschluss (barstate.isconfirmed).\n\n// ───────────────────────── Inputs ─────────────────────────\ngrpSetup = "① Setup"\nuseFVG      = input.bool(true,  "FVG-Retest handeln",                     group = grpSetup)\nuseIFVG     = input.bool(true,  "Inverse FVG (iFVG) handeln",             group = grpSetup)\nminGapAtr   = input.float(0.15, "Min. Gap-Größe (× ATR)", minval = 0, step = 0.05, group = grpSetup)\natrLen      = input.int(14,     "ATR-Länge", minval = 1,                  group = grpSetup)\nmaxAge      = input.int(60,     "Max. Alter einer Zone (Bars)", minval = 5, group = grpSetup)\nmaxZones    = input.int(20,     "Max. aktive Zonen", minval = 2, maxval = 100, group = grpSetup)\nneedConfirm = input.bool(true,  "Bestätigungskerze (Close über/unter Zonenmitte)", group = grpSetup)\n\ngrpStrat = "① b Weitere Strategien"\nuseSB       = input.bool(true,  "Silver Bullet (FVG im Fenster 10–11 NY)", group = grpStrat)\nsbWin       = input.session("1000-1100", "Silver-Bullet-Fenster",          group = grpStrat)\nuseORB      = input.bool(true,  "Opening Range Breakout",                  group = grpStrat)\norWin       = input.session("0930-0945", "Opening Range",                  group = grpStrat)\norbLastMin  = input.int(11 * 60, "ORB nur bis (Minute NY, 660 = 11:00)", minval = 0, maxval = 1439, group = grpStrat)\nuseSweep    = input.bool(true,  "Liquidity Sweep Vortageshoch/-tief",      group = grpStrat)\nuseVWAP     = input.bool(true,  "VWAP-Reclaim",                            group = grpStrat)\nvwapLook    = input.int(6,      "VWAP: Kerzen vorher auf der anderen Seite", minval = 2, group = grpStrat)\n\ngrpRisk = "② Risiko"\nrr          = input.float(2.0,  "Ziel (R-Vielfaches)", minval = 0.5, step = 0.25, group = grpRisk)\nslBufTicks  = input.int(4,      "Stop-Puffer (Ticks)", minval = 0,        group = grpRisk)\nminRiskTk   = input.int(8,      "Min. Stop-Abstand (Ticks)", minval = 1,  group = grpRisk)\nmaxRiskAtr  = input.float(3.0,  "Max. Stop-Abstand (× ATR)", minval = 0.5, step = 0.25, group = grpRisk)\nsizing      = input.string("Feste Kontrakte", "Positionsgröße", options = ["Feste Kontrakte", "Risiko in $"], group = grpRisk)\nfixedQty    = input.int(1,      "Kontrakte (fest)", minval = 1,           group = grpRisk)\nriskUsd     = input.float(500,  "Risiko pro Trade ($)", minval = 10,      group = grpRisk)\nmaxQty      = input.int(5,      "Max. Kontrakte", minval = 1,             group = grpRisk)\nuseBE       = input.bool(false, "Stop auf Break-even ab 1R",              group = grpRisk)\nmaxTradesDay= input.int(10,     "Max. Trades pro Tag", minval = 1,        group = grpRisk)\nmaxDayLoss  = input.float(1000, "Tagesverlust-Limit ($, 0 = aus)", minval = 0, group = grpRisk)\n\ngrpTime = "③ Sessions (New Yorker Zeit)"\nuseAllDay   = input.bool(false, "Ganztägig handeln (immer, außer Marktpause 17–18 Uhr)", group = grpTime)\nuseAsia     = input.bool(false, "Asien 20:00–24:00",                      group = grpTime)\nuseLondon   = input.bool(false, "London 02:00–05:00",                     group = grpTime)\nuseNyAm     = input.bool(true,  "New York Vormittag 09:30–11:30",         group = grpTime)\nuseNyLunch  = input.bool(false, "New York Mittag 11:30–13:30",            group = grpTime)\nuseNyPm     = input.bool(true,  "New York Nachmittag 13:30–15:50",        group = grpTime)\nflatEnd     = input.bool(true,  "Außerhalb der Sessions alles schließen", group = grpTime)\n\ngrpBias = "④ Trendfilter"\nuseBias     = input.bool(true,  "Nur mit HTF-Trend handeln",              group = grpBias)\nbiasTf      = input.timeframe("60", "Bias-Timeframe",                     group = grpBias)\nbiasLen     = input.int(50,     "Bias-EMA-Länge", minval = 2,             group = grpBias)\n\ngrpNews = "⑤ News-Filter"\nblockFomc   = input.string("Ab 13:45 NY", "FOMC-Tage",  options = ["Ganzer Tag", "Ab 13:45 NY", "Ignorieren"], group = grpNews)\nblockCpi    = input.string("Bis 10:00 NY", "CPI-Tage",  options = ["Ganzer Tag", "Bis 10:00 NY", "Ignorieren"], group = grpNews)\nblockNfp    = input.string("Bis 10:00 NY", "NFP-Tage",  options = ["Ganzer Tag", "Bis 10:00 NY", "Ignorieren"], group = grpNews)\nblock10     = input.bool(true,  "10:00-Daten sperren (09:50–10:10 NY)",   group = grpNews)\ncustomDates = input.string("",  "Eigene Sperrtage (JJJJMMTT, kommagetrennt)", group = grpNews)\n\ngrpVis = "⑥ Anzeige & Alerts"\nshowZones   = input.bool(true,  "Zonen zeichnen",                         group = grpVis)\nshowEma     = input.bool(true,  "Bias-EMA zeichnen",                      group = grpVis)\nshowDash    = input.bool(true,  "Dashboard anzeigen",                     group = grpVis)\ndashPosStr  = input.string("Oben rechts", "Dashboard-Position", options = ["Oben rechts", "Oben links", "Unten rechts", "Unten links"], group = grpVis)\nwhSymbol    = input.string("",  "Webhook-Symbol (leer = Chart-Symbol)",   group = grpVis)\nsendBars    = input.bool(true,  "Kerzen-Daten an die App senden (Paper-Trading & Lernmodul)", group = grpVis)\nsendTicks   = input.bool(true,  "Live-Kurs an die App, solange ein Trade offen ist", group = grpVis)\ntickSec     = input.int(20,     "Live-Kurs alle … Sekunden (TradingView erlaubt max. 15 Alarme in 3 Min)", minval = 15, maxval = 120, group = grpVis)\n\n// ───────────────────────── Farben ─────────────────────────\ncBull  = #26a69a\ncBear  = #ef5350\ncIBull = #2962ff\ncIBear = #ff9800\ncMuted = #9598a1\n\n// ───────────────────────── Zeit & Kalender ─────────────────────────\nTZ    = "America/New_York"\nnyMin = hour(time, TZ) * 60 + minute(time, TZ)\ndKey  = year(time, TZ) * 10000 + month(time, TZ) * 100 + dayofmonth(time, TZ)\nnewDay = ta.change(dKey) != 0\n\nvar array<int> FOMC = array.from(\n     20240131, 20240320, 20240501, 20240612, 20240731, 20240918, 20241107, 20241218,\n     20250129, 20250319, 20250507, 20250618, 20250730, 20250917, 20251029, 20251210,\n     20260128, 20260318, 20260429, 20260617, 20260729, 20260916, 20261028, 20261209,\n     20270127, 20270317, 20270428, 20270609, 20270728, 20270915, 20271027, 20271208)\n\nvar array<int> CPI = array.from(\n     20240111, 20240213, 20240312, 20240410, 20240515, 20240612, 20240711, 20240814, 20240911, 20241010, 20241113, 20241211,\n     20250115, 20250212, 20250312, 20250410, 20250513, 20250611, 20250715, 20250812, 20250911, 20251024, 20251218,\n     20260113, 20260213, 20260311, 20260410, 20260512, 20260610, 20260714, 20260812, 20260911, 20261014, 20261110, 20261210,\n     20270113, 20270211, 20270310, 20270413, 20270512, 20270610, 20270714, 20270811, 20270914, 20271014, 20271110, 20271210)\n\n// Arbeitsmarktbericht: Regel = 1. Freitag im Monat; Sondertermine (Shutdown 2025 etc.) hier\nvar array<int> NFP_EXTRA = array.from(20251120, 20251216, 20260109)\nvar array<int> NFP_SKIP  = array.from(20251003, 20251107)\n\nvar array<int> CUSTOM = array.new<int>()\nif barstate.isfirst and str.length(customDates) > 0\n    for p in str.split(customDates, ",")\n        float v = str.tonumber(str.replace_all(p, " ", ""))\n        if not na(v)\n            CUSTOM.push(int(v))\n\nisFomc   = FOMC.includes(dKey)\nisCpi    = CPI.includes(dKey)\nisNfp    = (dayofweek(time, TZ) == dayofweek.friday and dayofmonth(time, TZ) <= 7 and not NFP_SKIP.includes(dKey)) or NFP_EXTRA.includes(dKey)\nisCustom = CUSTOM.includes(dKey)\n\nvar string newsReason = "frei"\nnewsBlock = false\nnewsReason := "frei"\nif isCustom\n    newsBlock := true\n    newsReason := "Eigener Sperrtag"\nif isFomc and blockFomc != "Ignorieren" and (blockFomc == "Ganzer Tag" or nyMin >= 13 * 60 + 45)\n    newsBlock := true\n    newsReason := "FOMC"\nif isCpi and blockCpi != "Ignorieren" and (blockCpi == "Ganzer Tag" or nyMin < 10 * 60)\n    newsBlock := true\n    newsReason := "CPI"\nif isNfp and blockNfp != "Ignorieren" and (blockNfp == "Ganzer Tag" or nyMin < 10 * 60)\n    newsBlock := true\n    newsReason := "NFP"\nif block10 and nyMin >= 9 * 60 + 50 and nyMin < 10 * 60 + 10\n    newsBlock := true\n    newsReason := "10:00-Daten"\n\ninAsia   = useAsia    and not na(time(timeframe.period, "2000-2359", TZ))\ninLondon = useLondon  and not na(time(timeframe.period, "0200-0500", TZ))\ninNyAm   = useNyAm    and not na(time(timeframe.period, "0930-1130", TZ))\ninNyLun  = useNyLunch and not na(time(timeframe.period, "1130-1330", TZ))\ninNyPm   = useNyPm    and not na(time(timeframe.period, "1330-1550", TZ))\ninAllDay = useAllDay and na(time(timeframe.period, "1700-1800", TZ))\ninSess   = inAllDay or inAsia or inLondon or inNyAm or inNyLun or inNyPm\n\n// ───────────────────────── Indikatoren ─────────────────────────\natr    = ta.atr(atrLen)\nhtfEma = request.security(syminfo.tickerid, biasTf, ta.ema(close, biasLen)[1], lookahead = barmerge.lookahead_on)\nbiasL  = not useBias or close > htfEma\nbiasS  = not useBias or close < htfEma\nplot(showEma and useBias ? htfEma : na, "Bias-EMA", color = color.new(cMuted, 20), linewidth = 2)\n\n[pdh, pdl] = request.security(syminfo.tickerid, "D", [high[1], low[1]], lookahead = barmerge.lookahead_on)\nvw   = ta.vwap(hlc3)\ninSB = not na(time(timeframe.period, sbWin, TZ))\ninOR = not na(time(timeframe.period, orWin, TZ))\nvar float orH = na\nvar float orL = na\nif inOR and not inOR[1]\n    orH := high\n    orL := low\nelse if inOR\n    orH := math.max(orH, high)\n    orL := math.min(orL, low)\norReady = not inOR and not na(orH) and dayofmonth(time, TZ) == dayofmonth(time[1], TZ)\nplot(useVWAP ? vw : na, "VWAP", color = color.new(cIBull, 40))\nplot(useSweep ? pdh : na, "Vortageshoch", color = color.new(cBear, 50), style = plot.style_stepline)\nplot(useSweep ? pdl : na, "Vortagestief", color = color.new(cBull, 50), style = plot.style_stepline)\nplot(useORB and orReady ? orH : na, "OR-Hoch", color = color.new(cIBear, 30), style = plot.style_linebr)\nplot(useORB and orReady ? orL : na, "OR-Tief", color = color.new(cIBear, 30), style = plot.style_linebr)\n\n// ───────────────────────── Zonen ─────────────────────────\ntype Zone\n    float top\n    float bottom\n    int   dir\n    bool  inverse = false\n    int   born\n    bool  used = false\n    box   bx\n\nvar array<Zone> zones = array.new<Zone>()\n\nzoneColor(Zone z) =>\n    z.inverse ? (z.dir == 1 ? cIBull : cIBear) : (z.dir == 1 ? cBull : cBear)\n\ncloseBox(Zone z) =>\n    if not na(z.bx)\n        z.bx.set_right(bar_index)\n        z.bx.set_bgcolor(color.new(zoneColor(z), 94))\n        z.bx.set_border_color(color.new(zoneColor(z), 85))\n\naddZone(float t, float b, int d) =>\n    Zone z = Zone.new(top = t, bottom = b, dir = d, born = bar_index)\n    if showZones\n        c = zoneColor(z)\n        z.bx := box.new(bar_index - 2, t, bar_index + 1, b, border_color = color.new(c, 55), bgcolor = color.new(c, 82))\n    zones.push(z)\n    if zones.size() > maxZones\n        closeBox(zones.shift())\n\n// Neue Gaps erkennen (Kerzen [2] und [0] überlappen nicht)\nminGap = math.max(minGapAtr * atr, syminfo.mintick * 2)\nif bar_index > 2\n    if low > high[2] and low - high[2] >= minGap\n        addZone(low, high[2], 1)\n    if high < low[2] and low[2] - high >= minGap\n        addZone(low[2], high, -1)\n\n// Zonen pflegen: Invalidierung → Flip zu iFVG, Alter, Ausdehnung\nif zones.size() > 0\n    for i = zones.size() - 1 to 0\n        Zone z = zones.get(i)\n        bool remove = false\n        if z.born < bar_index\n            if bar_index - z.born > maxAge\n                remove := true\n            else if not z.inverse\n                if (z.dir == 1 and close < z.bottom) or (z.dir == -1 and close > z.top)\n                    if useIFVG\n                        closeBox(z)\n                        z.dir     := -z.dir\n                        z.inverse := true\n                        z.born    := bar_index\n                        z.used    := false\n                        if showZones\n                            c = zoneColor(z)\n                            z.bx := box.new(bar_index, z.top, bar_index + 1, z.bottom, border_color = color.new(c, 55), bgcolor = color.new(c, 82))\n                    else\n                        remove := true\n            else\n                if (z.dir == 1 and close < z.bottom) or (z.dir == -1 and close > z.top)\n                    remove := true\n        if remove\n            closeBox(z)\n            zones.remove(i)\n        else if not na(z.bx)\n            z.bx.set_right(bar_index + 1)\n\n// ───────────────────────── Tages-Risiko ─────────────────────────\nvar float dayStart    = 0.0\nvar int   tradesToday = 0\nvar bool  doneOrbL = false\nvar bool  doneOrbS = false\nvar bool  doneSwL  = false\nvar bool  doneSwS  = false\nif newDay\n    dayStart    := strategy.netprofit\n    tradesToday := 0\n    doneOrbL    := false\n    doneOrbS    := false\n    doneSwL     := false\n    doneSwS     := false\ndayPnl  = strategy.netprofit + strategy.openprofit - dayStart\nlossHit = maxDayLoss > 0 and dayPnl <= -maxDayLoss\n\n// ───────────────────────── Webhook-JSON ─────────────────────────\nsym = whSymbol == "" ? syminfo.ticker : whSymbol\njsonEntry(string action, int qty, float sl, float tp, string setup) =>\n    \'{"type":"entry","ticker":"\' + sym + \'","action":"\' + action + \'","setup":"\' + setup + \'","time":\' + str.tostring(time) +\n     \',"quantity":\' + str.tostring(qty) +\n     \',"price":\' + str.tostring(close, format.mintick) +\n     \',"stopLoss":{"type":"stop","stopPrice":\' + str.tostring(sl, format.mintick) + \'}\' +\n     \',"takeProfit":{"limitPrice":\' + str.tostring(tp, format.mintick) + \'}}\'\njsonExit(string setup) =>\n    \'{"type":"exit","ticker":"\' + sym + \'","action":"exit","setup":"\' + setup + \'","price":\' + str.tostring(close, format.mintick) + \'}\'\n\n// ───────────────────────── Einstieg ─────────────────────────\nvar float tSL   = na\nvar float tTP   = na\nvar float tRisk = na\nvar string tId  = ""\nvar bool  beDone = false\n\ncanTrade = inSess and not newsBlock and not lossHit and tradesToday < maxTradesDay and strategy.position_size == 0\n\n// ta-Funktionen global berechnen (nicht in if-Blöcken)\nbool  wasBelow = ta.highest(close - vw, vwapLook)[1] < 0\nbool  wasAbove = ta.lowest(close - vw, vwapLook)[1] > 0\nfloat swingLo  = ta.lowest(low, 5)\nfloat swingHi  = ta.highest(high, 5)\n\n// Kandidaten in fester Reihenfolge prüfen, der erste gültige wird gehandelt\nbool   sigOn   = false\nbool   sigLong = false\nfloat  sigSL   = na\nstring sigName = ""\nfloat  maxRisk = maxRiskAtr * atr\nfloat  minRisk = minRiskTk * syminfo.mintick\nfloat  buf     = slBufTicks * syminfo.mintick\n\nif canTrade and zones.size() > 0\n    for i = zones.size() - 1 to 0\n        Zone z = zones.get(i)\n        bool allowed = z.inverse ? useIFVG : (useFVG or (useSB and inSB))\n        if not sigOn and allowed and not z.used and z.born < bar_index\n            float mid = math.avg(z.top, z.bottom)\n            bool longSig  = z.dir == 1  and biasL and low  <= z.top    and close > z.bottom and (not needConfirm or (close > open and close >= mid))\n            bool shortSig = z.dir == -1 and biasS and high >= z.bottom and close < z.top    and (not needConfirm or (close < open and close <= mid))\n            if longSig or shortSig\n                float sl = longSig ? math.min(z.bottom, low) - buf : math.max(z.top, high) + buf\n                float risk = math.abs(close - sl)\n                if risk >= minRisk and risk <= maxRisk\n                    sigOn   := true\n                    sigLong := longSig\n                    sigSL   := sl\n                    sigName := z.inverse ? "iFVG" : (useSB and inSB) ? "Silver Bullet" : "FVG"\n                    z.used  := true\n\nif canTrade and not sigOn and useSweep and not na(pdh)\n    if not doneSwL and biasL and low < pdl and close > pdl and close > open\n        sigOn   := true\n        sigLong := true\n        sigSL   := low - buf\n        sigName := "Sweep"\n        doneSwL := true\n    else if not doneSwS and biasS and high > pdh and close < pdh and close < open\n        sigOn   := true\n        sigLong := false\n        sigSL   := high + buf\n        sigName := "Sweep"\n        doneSwS := true\n\nif canTrade and not sigOn and useORB and orReady and nyMin < orbLastMin\n    float orMid = math.avg(orH, orL)\n    if not doneOrbL and biasL and close > orH and close[1] <= orH\n        sigOn    := true\n        sigLong  := true\n        sigSL    := math.max(orMid, close - maxRisk) - buf\n        sigName  := "ORB"\n        doneOrbL := true\n    else if not doneOrbS and biasS and close < orL and close[1] >= orL\n        sigOn    := true\n        sigLong  := false\n        sigSL    := math.min(orMid, close + maxRisk) + buf\n        sigName  := "ORB"\n        doneOrbS := true\n\nif canTrade and not sigOn and useVWAP\n    if biasL and wasBelow and close > vw and close > open\n        sigOn   := true\n        sigLong := true\n        sigSL   := swingLo - buf\n        sigName := "VWAP"\n    else if biasS and wasAbove and close < vw and close < open\n        sigOn   := true\n        sigLong := false\n        sigSL   := swingHi + buf\n        sigName := "VWAP"\n\nif sigOn and barstate.isconfirmed\n    float risk = math.abs(close - sigSL)\n    if risk >= minRisk and risk <= maxRisk\n        float tp  = sigLong ? close + rr * risk : close - rr * risk\n        int qty   = sizing == "Feste Kontrakte" ? fixedQty : math.max(1, math.min(maxQty, int(math.floor(riskUsd / (risk * syminfo.pointvalue)))))\n        string id = sigName + (sigLong ? " Long" : " Short")\n        strategy.entry(id, sigLong ? strategy.long : strategy.short, qty = qty, alert_message = jsonEntry(sigLong ? "buy" : "sell", qty, sigSL, tp, id))\n        strategy.exit("Exit " + id, from_entry = id, stop = sigSL, limit = tp, alert_message = jsonExit(id))\n        tSL         := sigSL\n        tTP         := tp\n        tRisk       := risk\n        tId         := id\n        beDone      := false\n        tradesToday += 1\n\n// Break-even\nif useBE and not beDone and strategy.position_size != 0 and barstate.isconfirmed\n    float ep = strategy.position_avg_price\n    if (strategy.position_size > 0 and high >= ep + tRisk) or (strategy.position_size < 0 and low <= ep - tRisk)\n        tSL    := ep\n        beDone := true\n        strategy.exit("Exit " + tId, from_entry = tId, stop = tSL, limit = tTP, alert_message = jsonExit(tId))\n\n// Flat zum Sessionende, vor FOMC und bei Tageslimit\nif strategy.position_size != 0 and barstate.isconfirmed\n    if flatEnd and not inSess\n        strategy.close_all(comment = "Sessionende", alert_message = jsonExit(""))\n    else if isFomc and blockFomc != "Ignorieren" and nyMin >= 13 * 60 + 50\n        strategy.close_all(comment = "FOMC", alert_message = jsonExit(""))\n    else if lossHit\n        strategy.close_all(comment = "Tageslimit", alert_message = jsonExit(""))\n\nplot(strategy.position_size != 0 ? tSL : na, "Stop",   color = cBear, style = plot.style_linebr)\nplot(strategy.position_size != 0 ? tTP : na, "Target", color = cBull, style = plot.style_linebr)\nbgcolor(inSess and newsBlock ? color.new(cIBear, 88) : na, title = "News-Sperre")\n\n// Kerzen-Daten für die App (Paper-Trading prüft damit Stop/Ziel, das Lernmodul die Schatten-Trades,\n// der Live-Chart zeigt sie). Zusätzlich gehen die 1-Minuten-Kerzen innerhalb der Chart-Kerze mit.\nltf1 = timeframe.in_seconds() >= 60 ? "1" : timeframe.period   // nie höher als der Chart, sonst Laufzeitfehler\n[m1t, m1o, m1h, m1l, m1c] = request.security_lower_tf(syminfo.tickerid, ltf1, [time, open, high, low, close])\nif sendBars and barstate.isrealtime and barstate.isconfirmed\n    string m1s = ""\n    int m1n = math.min(array.size(m1t), 120)\n    if timeframe.in_seconds() >= 60 and m1n > 0\n        for i = 0 to m1n - 1\n            m1s += (i > 0 ? "," : "") + "[" + str.tostring(array.get(m1t, i)) + "," + str.tostring(array.get(m1o, i), format.mintick) + "," +\n                 str.tostring(array.get(m1h, i), format.mintick) + "," + str.tostring(array.get(m1l, i), format.mintick) + "," +\n                 str.tostring(array.get(m1c, i), format.mintick) + "]"\n    alert(\'{"type":"bar","ticker":"\' + sym + \'","time":\' + str.tostring(time) + \',"tf":\' + str.tostring(timeframe.in_seconds() * 1000) +\n         \',"open":\' + str.tostring(open, format.mintick) + \',"high":\' + str.tostring(high, format.mintick) +\n         \',"low":\' + str.tostring(low, format.mintick) + \',"close":\' + str.tostring(close, format.mintick) +\n         \',"m1":[\' + m1s + \']}\', alert.freq_once_per_bar_close)\n\n// Live-Kurs, solange die Strategie im Trade ist (gedrosselt, damit TradingView den Alarm nicht stoppt)\nvarip int lastTick = 0\nif sendTicks and barstate.isrealtime and not barstate.isconfirmed and strategy.position_size != 0 and timenow - lastTick >= tickSec * 1000\n    lastTick := timenow\n    alert(\'{"type":"tick","ticker":"\' + sym + \'","price":\' + str.tostring(close, format.mintick) + \',"time":\' + str.tostring(timenow) + \'}\', alert.freq_all)\n\n// ───────────────────────── Statistik je Setup ─────────────────────────\nvar array<string> stName = array.from("FVG", "iFVG", "Silver Bullet", "ORB", "Sweep", "VWAP")\nvar array<int>   stCnt  = array.new<int>(6, 0)\nvar array<int>   stWin  = array.new<int>(6, 0)\nvar array<float> stPnl  = array.new<float>(6, 0.0)\nvar int seen = 0\nif strategy.closedtrades > seen\n    for i = seen to strategy.closedtrades - 1\n        string eid = strategy.closedtrades.entry_id(i)\n        int   k = 0\n        for j = 0 to 5\n            if str.startswith(eid, stName.get(j) + " ")\n                k := j\n        float p = strategy.closedtrades.profit(i)\n        stCnt.set(k, stCnt.get(k) + 1)\n        stPnl.set(k, stPnl.get(k) + p)\n        if p > 0\n            stWin.set(k, stWin.get(k) + 1)\n    seen := strategy.closedtrades\n\n// ───────────────────────── Dashboard ─────────────────────────\ndashPos = switch dashPosStr\n    "Oben links"   => position.top_left\n    "Unten rechts" => position.bottom_right\n    "Unten links"  => position.bottom_left\n    => position.top_right\n\nvar table dash = table.new(dashPos, 2, 21, bgcolor = color.new(#131722, 8), border_color = color.new(#363a45, 0), border_width = 1, frame_color = color.new(#363a45, 0), frame_width = 1)\n\nmoney(float v) =>\n    (v < 0 ? "-$" : "$") + str.tostring(math.abs(v), "#,##0")\npct(float v) =>\n    na(v) ? "–" : str.tostring(v, "0.0") + "%"\nrow(int r, string k, string v, color vc) =>\n    table.cell(dash, 0, r, k, text_color = cMuted, text_size = size.small, text_halign = text.align_left)\n    table.cell(dash, 1, r, v, text_color = vc, text_size = size.small, text_halign = text.align_right)\n\nif showDash and barstate.islast\n    int ct      = strategy.closedtrades\n    float wr    = ct > 0 ? float(strategy.wintrades) / ct * 100 : na\n    float pf    = strategy.grossloss > 0 ? strategy.grossprofit / strategy.grossloss : na\n    float avgT  = ct > 0 ? strategy.netprofit / ct : na\n    int nF = 0\n    int nI = 0\n    for z in zones\n        if z.inverse\n            nI += 1\n        else\n            nF += 1\n    string pos  = strategy.position_size > 0 ? "LONG " + str.tostring(strategy.position_size) : strategy.position_size < 0 ? "SHORT " + str.tostring(math.abs(strategy.position_size)) : "Flat"\n    color posC  = strategy.position_size > 0 ? cBull : strategy.position_size < 0 ? cBear : color.white\n\n    table.cell(dash, 0, 0, "FVG Bot · " + syminfo.ticker + " · " + timeframe.period, text_color = color.white, text_size = size.normal, text_halign = text.align_left)\n    table.merge_cells(dash, 0, 0, 1, 0)\n    row(1,  "Position",          pos, posC)\n    string sName = inAsia ? "Asien" : inLondon ? "London" : inNyAm ? "NY Vormittag" : inNyLun ? "NY Mittag" : inNyPm ? "NY Nachmittag" : inAllDay ? "ganztägig" : "keine"\n    row(2,  "Session",           sName, inSess ? cBull : cMuted)\n    row(3,  "News-Filter",       newsBlock ? "gesperrt · " + newsReason : "frei", newsBlock ? cIBear : cBull)\n    row(4,  "HTF-Bias",          not useBias ? "aus" : close > htfEma ? "bullisch" : "bärisch", not useBias ? cMuted : close > htfEma ? cBull : cBear)\n    row(5,  "Aktive Zonen",      str.tostring(nF) + " FVG · " + str.tostring(nI) + " iFVG", color.white)\n    row(6,  "Trades heute",      str.tostring(tradesToday) + " / " + str.tostring(maxTradesDay), color.white)\n    row(7,  "P&L heute",         money(dayPnl), dayPnl >= 0 ? cBull : cBear)\n    row(8,  "─────",             "", cMuted)\n    row(9,  "Netto-Gewinn",      money(strategy.netprofit), strategy.netprofit >= 0 ? cBull : cBear)\n    row(10, "Trades gesamt",     str.tostring(ct), color.white)\n    row(11, "Trefferquote",      pct(wr), color.white)\n    row(12, "Profit-Faktor",     na(pf) ? "–" : str.tostring(pf, "0.00"), not na(pf) and pf >= 1 ? cBull : cBear)\n    row(13, "Ø Trade",           na(avgT) ? "–" : money(avgT), not na(avgT) and avgT >= 0 ? cBull : cBear)\n    row(14, "Max. Drawdown",     money(-strategy.max_drawdown), cBear)\n    for j = 0 to 5\n        int   n = stCnt.get(j)\n        float w = n > 0 ? float(stWin.get(j)) / n * 100 : na\n        row(15 + j, stName.get(j), n == 0 ? "–" : str.tostring(n) + " · " + pct(w) + " · " + money(stPnl.get(j)), n == 0 ? cMuted : stPnl.get(j) >= 0 ? cBull : cBear)\n'

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
SERVICE = "--dienst" in sys.argv   # läuft als Dienst (Windows-Aufgabenplanung, Start ohne Anmeldung)
_svc_cache = {"t": 0, "v": False}


REMOTE = {"month": "", "n": 0, "dirty": 0}


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
        REMOTE.update(month=m, n=0)
    REMOTE["n"] += 1
    REMOTE["dirty"] += 1
    if REMOTE["dirty"] >= 20:
        REMOTE["dirty"] = 0
        try:
            with open(_remote_file(), "w", encoding="utf-8") as f:
                json.dump({"month": REMOTE["month"], "n": REMOTE["n"]}, f)
        except OSError:
            pass


def service_state():
    if time.time() - _svc_cache["t"] > 60:
        _svc_cache.update(t=time.time(), v=service_installed())
    return {"installed": _svc_cache["v"], "running": SERVICE}
APP_VERSION = "2.12.1"   # wird beim Bauen der Ein-Datei-Version gesetzt

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
        if n > (20_000_000 if self.path.startswith("/api/backtest/") else
                5_000_000 if self.path.startswith(("/api/update/", "/api/own/import")) else 100_000):
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
    try:
        res = engine.handle_webhook(payload)
    except ValueError as e:
        engine.db.log(f"Webhook abgelehnt: {e}", "error")
        return h._send(400, {"error": str(e)})
    engine.alert_issue = None
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
    s["remote"] = {"month": REMOTE["month"], "n": REMOTE["n"] if REMOTE["month"] == time.strftime("%Y-%m") else 0,
                   "limit": 20000 if (s.get("tunnel") or {}).get("provider") == "ngrok" else None}
    s["version"] = APP_VERSION
    s["launcher"] = LAUNCHER
    s["update"] = UPDATE.copy()
    s["alert_issue"] = getattr(engine, "alert_issue", None)
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
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\n  Beendet.")
    finally:
        tunnel.stop()


if __name__ == "__main__":
    main()
