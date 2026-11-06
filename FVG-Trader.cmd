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
    source TEXT, trade_day TEXT, note TEXT, mgmt TEXT, best REAL, exit_bar REAL, journal TEXT, shots TEXT, ghost_status TEXT, ghost_sl REAL, ghost_tp REAL, ghost_exit REAL, ghost_r REAL, ghost_how TEXT, exit_cat TEXT
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
        self.on_log = None
        self.path = path
        self.con = sqlite3.connect(path, check_same_thread=False, timeout=30)
        self.con.row_factory = sqlite3.Row
        try:   # WAL: Lesen und Schreiben blockieren sich nicht gegenseitig
            self.con.execute("PRAGMA journal_mode=WAL")
        except sqlite3.DatabaseError:
            pass
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

    def read(self, sql, args=()):
        """Große Lese-Abfragen (Kerzen) über eine eigene Verbindung als einfache Tupel –
        sperrt nichts, damit Webhooks und die Oberfläche währenddessen weiterlaufen."""
        con = sqlite3.connect(self.path, timeout=30)
        try:
            return con.execute(sql, args).fetchall()
        finally:
            con.close()

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
        return self.rows("SELECT shadow_id, setup, var, side, r, opened, closed FROM variants WHERE status='geschlossen' ORDER BY opened")

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
        if self.on_log:
            try:
                self.on_log(text, level)
            except Exception:   # noqa: BLE001  Benachrichtigung darf das Loggen nie stören
                pass
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

# ═════════════════ discovery.py ═════════════════
"""Strategie-Finder: sucht in den gespeicherten Kursdaten nach neuen Einstiegs-Mustern
(Orderblöcke, Breaker, FVG-Retests, Liquiditäts-Sweeps, BOS-Pullbacks/OTE, Range-Ausbrüche, Rückkehr zum Mittel
und bekannte Scalping-Konzepte: Judas Swing / Asia-Range-Sweep, Vortages-Hoch/Tief-Sweep, Candle Range Theory, Opening Range Breakout)
und bewertet sie ehrlich: nach Gebühren, mit Prüfung in einer späteren Zeit-Hälfte und danach im Probelauf."""
import math

DC_DETECTORS = {
    "ob":    {"name": "Orderblock-Retest", "short": "Orderblock", "N": (5, 10, 20), "K": (1.0, 1.5, 2.0)},
    "brk":   {"name": "Breaker-Block", "short": "Breaker", "N": (5, 10, 20), "K": (1.0, 1.5, 2.0)},
    "fvg":   {"name": "FVG-Retest", "short": "FVG-Retest", "N": (30,), "K": (0.3, 0.5, 0.8)},
    "sweep": {"name": "Liquiditäts-Sweep", "short": "Sweep", "N": (10, 20, 40), "K": (0.0, 0.15, 0.3)},
    "bos":   {"name": "BOS-Pullback / OTE", "short": "BOS-Pullback", "N": (10, 20, 40), "K": (0.5, 0.618, 0.705, 0.79)},
    "rng":   {"name": "Range-Ausbruch", "short": "Range-Ausbruch", "N": (10, 20, 40), "K": (2.0, 3.0, 4.0)},
    "mr":    {"name": "Rückkehr zum Mittel", "short": "Mittel-Rückkehr", "N": (20, 50), "K": (1.5, 2.0, 2.5)},
    # bekannte Konzepte bekannter Scalper (ICT/Smart Money, Opening-Range-Trader)
    "judas": {"name": "Judas Swing (Asia-Range-Sweep)", "short": "Judas", "N": (1,), "K": (0.0, 0.1, 0.25)},
    "pdhl":  {"name": "Vortages-Hoch/Tief-Sweep", "short": "PDH/PDL-Sweep", "N": (1,), "K": (0.0, 0.1, 0.25)},
    "crt":   {"name": "Candle Range Theory", "short": "CRT", "N": (15, 60, 240), "K": (0.0, 0.15)},
    "orb":   {"name": "Opening Range Breakout", "short": "ORB", "N": (5, 15, 30), "K": (0.5, 1.0)},
}
DC_TPS = (1.0, 1.5, 2.0, 3.0)
DC_SESS_SHORT = {"asia": "Asien", "london": "London", "ny_am": "NY-Vorm.", "ny_lunch": "NY-Mittag", "ny_pm": "NY-Nachm.",
              "aus": "Randzeiten", "alle": "ganztags"}


def _dc_num(v):
    return (f"{v:g}").replace(".", ",")


def dc_describe(det, n, k, tf, d, tp):
    """Die Strategie in einfachen Worten."""
    side = "Long" if d > 0 else "Short"
    up, hi, lo = ("über", "Hoch", "Tief") if d > 0 else ("unter", "Tief", "Hoch")
    t = {
        "ob": f"Nach einem kräftigen Ausbruch {up} das {n}-Kerzen-{hi} (Kerze mind. {_dc_num(k)}× so groß wie normal) wird die letzte "
              f"Gegenkerze davor zur Orderblock-Zone. Kommt der Kurs in die Zone zurück und schließt wieder außerhalb: {side}. "
              f"Stop hinter der Zone.",
        "brk": f"Ein Orderblock (nach Ausbruch über/unter das {n}-Kerzen-Extrem, mind. {_dc_num(k)}× normale Kerze) wird durchbrochen "
               f"und dadurch zum Breaker. Beim Test von der anderen Seite: {side}. Stop hinter dem Block.",
        "fvg": f"Eine Fair-Value-Gap von mind. {_dc_num(k)}× der normalen Kerzen-Spanne entsteht. Läuft der Kurs innerhalb von "
               f"{n} Kerzen zurück in die Lücke und schließt über der Mitte (Short: darunter): {side}. Stop hinter der Lücke.",
        "sweep": f"Der Kurs sticht {'unter' if d > 0 else 'über'} das {n}-Kerzen-{lo} "
                 f"(Liquidität){' um mind. ' + _dc_num(k) + '× Kerzen-Spanne' if k else ''} und schließt wieder zurück in der Range "
                 f"mit {'grüner' if d > 0 else 'roter'} Kerze: {side}. Stop hinter dem Docht.",
        "bos": f"Struktur-Bruch: Schluss {up} dem {n}-Kerzen-{hi}. Danach Rücklauf auf {_dc_num(round(k * 100, 1))} % der Bewegung "
               f"und eine {'grüne' if d > 0 else 'rote'} Kerze: {side}. Stop hinter dem Start der Bewegung.",
        "rng": f"Enge Range: Die letzten {n} Kerzen liegen innerhalb von {_dc_num(k)}× der normalen Kerzen-Spanne. "
               f"Schluss {up} der Range: {side}. Stop auf der anderen Seite der Range.",
        "mr": f"Der Kurs liegt mehr als {_dc_num(k)}× Kerzen-Spanne {'unter' if d > 0 else 'über'} dem {n}-Kerzen-Durchschnitt und "
              f"dreht mit einer {'grünen' if d > 0 else 'roten'} Kerze: {side} zurück Richtung Mittel. Stop hinter den letzten 3 Kerzen.",
        "judas": f"Judas Swing: Zwischen 2 und 11 Uhr New York sticht der Kurs {'unter das Tief' if d > 0 else 'über das Hoch'} der "
                 f"Asien-Session (20–24 Uhr){' um mind. ' + _dc_num(k) + '× Kerzen-Spanne' if k else ''} und schließt wieder in der Range "
                 f"mit {'grüner' if d > 0 else 'roter'} Kerze – der falsche Ausbruch wird gehandelt: {side}. Stop hinter dem Docht, einmal pro Tag.",
        "pdhl": f"Der Kurs sticht {'unter das Tief' if d > 0 else 'über das Hoch'} des Vortags{' um mind. ' + _dc_num(k) + '× Kerzen-Spanne' if k else ''} "
                f"und schließt wieder zurück (Turtle Soup): {side}. Stop hinter dem Docht, einmal pro Tag.",
        "crt": f"Candle Range Theory: Die aktuelle {n}-Minuten-Kerze sticht {'unter das Tief' if d > 0 else 'über das Hoch'} der vorherigen "
               f"{n}-Minuten-Kerze{' um mind. ' + _dc_num(k) + '× Kerzen-Spanne' if k else ''} und schließt auf der kleinen Zeiteinheit wieder "
               f"in deren Range: {side} Richtung andere Seite. Stop hinter dem Docht.",
        "orb": f"Opening Range: Hoch und Tief der ersten {n} Minuten ab 9:30 New York. Schließt eine Kerze bis 11:30 {up} der Range: {side}. "
               f"Stop {'in der Mitte' if k < 1 else 'auf der anderen Seite'} der Range, einmal pro Tag.",
    }[det]
    return f"{t} Ziel {_dc_num(tp)}R. Zeiteinheit {tf} Min."


def dc_name_of(det, tf, d, sess):
    return f"Neu: {DC_DETECTORS[det]['short']} {tf}m {'Long' if d > 0 else 'Short'} {DC_SESS_SHORT.get(sess, sess)}"[:40]


def _dc_atr(h, l, c, n=14):
    out, s, q = [None] * len(c), 0.0, []
    for i in range(len(c)):
        tr = h[i] - l[i] if i == 0 else max(h[i] - l[i], abs(h[i] - c[i - 1]), abs(l[i] - c[i - 1]))
        q.append(tr)
        s += tr
        if len(q) > n:
            s -= q.pop(0)
        if len(q) == n:
            out[i] = s / n
    return out


def _dc_roll(arr, n, fn):
    """fn(arr[i-n:i]) ohne die aktuelle Kerze, per monotoner Schlange in O(n)."""
    from collections import deque
    out, dq = [None] * len(arr), deque()
    worse = (lambda a, b: a <= b) if fn is max else (lambda a, b: a >= b)
    for i in range(len(arr)):
        while dq and dq[0] < i - n:
            dq.popleft()
        if i >= n and dq:
            out[i] = arr[dq[0]]
        while dq and worse(arr[dq[-1]], arr[i]):
            dq.pop()
        dq.append(i)
    return out


def dc_prepare(o, h, l, c, t=None, nyf=None):
    """nyf(ms) liefert die New-Yorker Uhrzeit (datetime) – für zeitbasierte Muster (Asien-Range, Vortag, Opening Range)."""
    P = {"atr": _dc_atr(h, l, c), "cache": {}, "t": t}
    if t and nyf:
        hm, day = [], []
        for x in t:
            ny = nyf(x)
            hm.append(ny.hour * 60 + ny.minute)
            sh = ny.toordinal() + (1 if ny.hour >= 18 else 0)   # Handelstag beginnt um 18 Uhr New York
            day.append(sh)
        P["hm"], P["day"] = hm, day
    return P


def _dc_rmax(P, h, n):
    key = ("max", n)
    if key not in P["cache"]:
        P["cache"][key] = _dc_roll(h, n, max)
    return P["cache"][key]


def _dc_rmin(P, l, n):
    key = ("min", n)
    if key not in P["cache"]:
        P["cache"][key] = _dc_roll(l, n, min)
    return P["cache"][key]


def dc_detect(det, n, k, o, h, l, c, P, tick, start=0):
    """Liefert Signale (Index, Richtung +1/-1, Stop-Kurs). Einstieg ist der Schluss der Signal-Kerze."""
    atr = P["atr"]
    hiN, loN = _dc_rmax(P, h, n), _dc_rmin(P, l, n)
    out = []
    N = len(c)
    if det in ("ob", "brk"):
        zones = []   # [richtung, oben, unten, verfällt, art]  art: ob / breaker
        for i in range(max(n + 2, start), N):
            a = atr[i]
            keep = []
            for z in zones:
                d, top, bot, exp, kind = z
                if i > exp:
                    continue
                if kind == "ob":
                    if d > 0 and c[i] < bot or d < 0 and c[i] > top:
                        if det == "brk":   # Orderblock gebrochen → Breaker in Gegenrichtung
                            keep.append([-d, top, bot, i + 60, "breaker"])
                        continue
                    if det == "ob" and d > 0 and l[i] <= top and c[i] > top:
                        out.append((i, 1, min(bot, l[i]) - tick))
                        continue
                    if det == "ob" and d < 0 and h[i] >= bot and c[i] < bot:
                        out.append((i, -1, max(top, h[i]) + tick))
                        continue
                    keep.append(z)
                else:   # Breaker: Test von der anderen Seite
                    if d < 0 and h[i] >= bot and c[i] < bot:
                        out.append((i, -1, max(top, h[i]) + tick))
                        continue
                    if d > 0 and l[i] <= top and c[i] > top:
                        out.append((i, 1, min(bot, l[i]) - tick))
                        continue
                    if d < 0 and c[i] > top or d > 0 and c[i] < bot:
                        continue
                    keep.append(z)
            zones = keep[-10:]
            if not a or hiN[i] is None:
                continue
            if c[i] > hiN[i] and c[i] - o[i] >= k * a:
                for j in range(i - 1, max(i - 6, 0), -1):
                    if c[j] < o[j]:
                        zones.append([1, h[j], l[j], i + 60, "ob"])
                        break
            elif c[i] < loN[i] and o[i] - c[i] >= k * a:
                for j in range(i - 1, max(i - 6, 0), -1):
                    if c[j] > o[j]:
                        zones.append([-1, h[j], l[j], i + 60, "ob"])
                        break
    elif det == "fvg":
        zones = []
        for i in range(max(3, start), N):
            a = atr[i]
            keep = []
            for z in zones:
                d, top, bot, exp = z
                if i > exp or (d > 0 and c[i] < bot) or (d < 0 and c[i] > top):
                    continue
                mid = (top + bot) / 2
                if d > 0 and l[i] <= top and c[i] > mid:
                    out.append((i, 1, min(bot, l[i]) - tick))
                    continue
                if d < 0 and h[i] >= bot and c[i] < mid:
                    out.append((i, -1, max(top, h[i]) + tick))
                    continue
                keep.append(z)
            zones = keep[-10:]
            if not a:
                continue
            if l[i] > h[i - 2] and l[i] - h[i - 2] >= k * a:
                zones.append([1, l[i], h[i - 2], i + n])
            elif h[i] < l[i - 2] and l[i - 2] - h[i] >= k * a:
                zones.append([-1, l[i - 2], h[i], i + n])
    elif det == "sweep":
        for i in range(max(n + 1, start), N):
            a = atr[i]
            if not a or loN[i] is None:
                continue
            if l[i] < loN[i] - k * a and c[i] > loN[i] and c[i] > o[i]:
                out.append((i, 1, l[i] - tick))
            elif h[i] > hiN[i] + k * a and c[i] < hiN[i] and c[i] < o[i]:
                out.append((i, -1, h[i] + tick))
    elif det == "bos":
        act = None   # [richtung, extrem, start, verfällt]
        for i in range(max(n + 1, start), N):
            if hiN[i] is None:
                continue
            if act:
                d, ext, st, exp = act
                if i > exp or (d > 0 and c[i] < st) or (d < 0 and c[i] > st):
                    act = None
                else:
                    ext = max(ext, h[i]) if d > 0 else min(ext, l[i])
                    act[1] = ext
                    lvl = ext - k * (ext - st) if d > 0 else ext + k * (st - ext)
                    if d > 0 and l[i] <= lvl and c[i] > o[i] and l[i] > st:
                        out.append((i, 1, st - tick))
                        act = None
                        continue
                    if d < 0 and h[i] >= lvl and c[i] < o[i] and h[i] < st:
                        out.append((i, -1, st + tick))
                        act = None
                        continue
            if c[i] > hiN[i]:
                act = [1, h[i], loN[i], i + 30]
            elif c[i] < loN[i]:
                act = [-1, l[i], hiN[i], i + 30]
    elif det == "rng":
        cool = -1
        for i in range(max(n + 1, start), N):
            a = atr[i]
            if not a or hiN[i] is None or i < cool:
                continue
            rh, rl = hiN[i], loN[i]
            if rh - rl <= k * a:
                if c[i] > rh:
                    out.append((i, 1, rl - tick))
                    cool = i + n
                elif c[i] < rl:
                    out.append((i, -1, rh + tick))
                    cool = i + n
    elif det == "mr":
        s, q = 0.0, []
        for i in range(N):
            q.append(c[i])
            s += c[i]
            if len(q) > n:
                s -= q.pop(0)
            if i < max(n, start, 3) or not atr[i]:
                continue
            m = s / n
            if c[i] < m - k * atr[i] and c[i] > o[i] and c[i - 1] < o[i - 1]:
                out.append((i, 1, min(l[i - 2:i + 1]) - tick))
            elif c[i] > m + k * atr[i] and c[i] < o[i] and c[i - 1] > o[i - 1]:
                out.append((i, -1, max(h[i - 2:i + 1]) + tick))
    elif det in ("judas", "pdhl") and "day" in P:
        day, hm = P["day"], P["hm"]
        cur, ref, used = None, None, set()
        dh = dl = ah = al = None
        for i in range(N):
            if day[i] != cur:   # neuer Handelstag
                ref = (dh, dl) if det == "pdhl" else None
                cur, dh, dl, ah, al = day[i], h[i], l[i], None, None
            dh, dl = max(dh, h[i]), min(dl, l[i])
            if det == "judas":
                if 1200 <= hm[i] < 1440:
                    ah = h[i] if ah is None else max(ah, h[i])
                    al = l[i] if al is None else min(al, l[i])
                    continue
                ref = (ah, al) if ah is not None else None
                if not (120 <= hm[i] < 660):
                    continue
            if i < start or not ref or ref[0] is None or not atr[i]:
                continue
            rh, rl = ref
            a = atr[i]
            if (cur, -1) not in used and h[i] > rh + k * a and c[i] < rh and c[i] < o[i]:
                out.append((i, -1, h[i] + tick))
                used.add((cur, -1))
            elif (cur, 1) not in used and l[i] < rl - k * a and c[i] > rl and c[i] > o[i]:
                out.append((i, 1, l[i] - tick))
                used.add((cur, 1))
    elif det == "crt" and P.get("t"):
        t = P["t"]
        span = n * 60000
        cur, prev, hh, ll, used = None, None, None, None, set()
        for i in range(N):
            b = t[i] - t[i] % span
            if b != cur:
                prev = (hh, ll) if cur is not None and b - cur == span else None
                cur, hh, ll = b, h[i], l[i]
            else:
                hh, ll = max(hh, h[i]), min(ll, l[i])
            if i < start or not prev or not atr[i]:
                continue
            a = atr[i]
            if (cur, -1) not in used and hh > prev[0] + k * a and c[i] < prev[0] and c[i] < o[i]:
                out.append((i, -1, hh + tick))
                used.add((cur, -1))
            elif (cur, 1) not in used and ll < prev[1] - k * a and c[i] > prev[1] and c[i] > o[i]:
                out.append((i, 1, ll - tick))
                used.add((cur, 1))
    elif det == "orb" and "day" in P:
        day, hm = P["day"], P["hm"]
        cur, oh, ol, used = None, None, None, set()
        for i in range(N):
            if day[i] != cur:
                cur, oh, ol = day[i], None, None
            if 570 <= hm[i] < 570 + n:
                oh = h[i] if oh is None else max(oh, h[i])
                ol = l[i] if ol is None else min(ol, l[i])
                continue
            if i < start or oh is None or not (570 + n <= hm[i] < 690):
                continue
            stop_dist = (oh - ol) * k
            if (cur, 1) not in used and c[i] > oh:
                out.append((i, 1, oh - stop_dist - tick))
                used.add((cur, 1))
            elif (cur, -1) not in used and c[i] < ol:
                out.append((i, -1, ol + stop_dist + tick))
                used.add((cur, -1))
    return out


def dc_simulate(sigs, o, h, l, c, t, tf_ms, entry_idx, cost_fn, min_stop, max_hold):
    """Spielt jedes Signal durch: Stop vor Ziel, wenn beides in derselben Kerze liegt (vorsichtig).
    entry_idx(i) gibt die Kerze zurück, zu deren Schluss der Bot live wirklich einsteigen könnte (Verzögerung)."""
    trades = []
    N = len(c)
    for i, d, stop in sigs:
        e = entry_idx(i)
        if e is None or e >= N - 1:
            continue
        entry = c[e]
        risk = (entry - stop) * d
        if risk < min_stop:
            continue
        rs, ex = [None] * len(DC_TPS), [None] * len(DC_TPS)
        last = e
        for j in range(e + 1, min(N, e + 1 + max_hold)):
            if t[j] - t[j - 1] > 3 * tf_ms:   # Lücke (Marktpause/Wochenende): Trade vorher schließen
                break
            last = j
            fav = ((h[j] - entry) if d > 0 else (entry - l[j])) / risk
            adv = ((l[j] - entry) if d > 0 else (entry - h[j])) / risk
            done = True
            for x, tp in enumerate(DC_TPS):
                if rs[x] is not None:
                    continue
                if adv <= -1:
                    rs[x], ex[x] = -1.0, j
                elif fav >= tp:
                    rs[x], ex[x] = tp, j
                else:
                    done = False
            if done:
                break
        rc = (c[last] - entry) * d / risk
        for x in range(len(DC_TPS)):
            if rs[x] is None:
                rs[x], ex[x] = rc, last
        trades.append({"i": i, "e": e, "d": d, "risk": risk, "rs": rs, "ex": ex, "cost": cost_fn(entry, risk), "t": t[e]})
    return trades


def dc_stats(rs):
    n = len(rs)
    if not n:
        return None
    m = sum(rs) / n
    sd = (sum((x - m) ** 2 for x in rs) / (n - 1)) ** 0.5 if n > 1 else 0.0
    gw = sum(x for x in rs if x > 0)
    gl = -sum(x for x in rs if x <= 0)
    return {"n": n, "avg": m, "sd": sd, "t": m / sd * n ** 0.5 if sd > 0 else 0.0,
            "wr": sum(1 for x in rs if x > 0) / n * 100, "pf": gw / gl if gl > 0 else None}


def dc_evaluate(trades, sess_of, tp_idx, d, sess):
    """Trades einer Kandidaten-Strategie (Richtung, Session, Ziel) ohne Überschneidung, nach Gebühren."""
    out, busy = [], -1
    for tr in trades:
        if tr["d"] != d or tr["e"] <= busy:
            continue
        if sess != "alle" and sess_of(tr["t"]) != sess:
            continue
        busy = tr["ex"][tp_idx]
        out.append((tr["t"], tr["rs"][tp_idx] - tr["cost"]))
    return out

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
        "daily_profit_stop": 0.0,  # Tagesziel in $: danach keine neuen Trades (0 = aus)
        "daily_stop_close": False, # beim Tages-Stopp offene Positionen schließen
    },
    "discord": {               # Benachrichtigungen über einen Discord-Webhook
        "enabled": False, "url": "", "trades": True, "errors": True, "silence": True, "silence_min": 30,
        "daystop": True, "daily": True, "weekly": True, "learn": True,
    },
    "news": {                  # News-Pause aus dem Wirtschaftskalender
        "enabled": True, "before_min": 10, "after_min": 10, "impact": "high", "usd_only": True, "close_before": True,
    },
    "exit_rules": {},          # Strategie -> übernommene Ausstiegs-Variante (Varianten-Labor)
    "session_scale": {},       # Session (oder Strategie|Session) -> {"f": Ziel-Faktor, "g": Stop-Faktor} (Session-Ziele)
    "rule_filters": [],        # übernommene Regeln aus dem Regel-Finder
    "challenge": {             # Fremdkapital / Prop-Firm-Challenge
        "enabled": False, "name": "", "phase": "Challenge", "start_balance": 50000.0, "start_day": "",
        "profit_target": 3000.0, "max_dd": 2000.0, "dd_type": "eod", "lock_at_start": True,
        "daily_loss": 1000.0, "consistency_pct": 0.0, "min_days": 0, "source": "alle",
        "guard": True, "guard_buffer": 250.0,
    },
    "paper": {"start_balance": 50000.0, "slippage_ticks": 1, "commission": 2.25, "commission_micro": 0.75},
    "tradovate": {"env": "demo", "username": "", "password": "", "cid": "", "secret": "",
                  "app_id": "", "account": "", "device_id": ""},
    "contracts": {"NQ": "", "MNQ": "", "ES": "", "MES": ""},
    "learning": {
        "enabled": True,
        "window": 30,          # letzte N Schatten-Trades je Strategie
        "min_trades": 12,      # vorher nur beobachten
        "pause_below_r": -0.10,
        "half_below_r": 0.10,
        "auto_adopt": True,    # Varianten-Labor + Regel-Finder: Ergebnisse selbst übernehmen und wieder verwerfen
    },
    "setup_rules": {},         # Strategie -> auto | an | aus
    "own_sync": {"tradovate": False},   # eigene Trades automatisch aus Tradovate übernehmen
    "tunnel": {"ngrok_token": ""},      # mit Schlüssel: feste Adresse über ngrok
}

# $ pro Punkt für eigene Trades aus dem Broker-Import
POINT_VALUE = {"NQ": 20, "MNQ": 2, "ES": 50, "MES": 5, "YM": 5, "MYM": 0.5, "RTY": 50, "M2K": 5,
               "GC": 100, "MGC": 10, "CL": 1000, "MCL": 100, "SI": 5000, "SIL": 1000}
SECRET_FIELDS = ("password", "secret")
SECRET_PATHS = (("tradovate", "password"), ("tradovate", "secret"), ("tunnel", "ngrok_token"), ("discord", "url"))
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
    # Ohne feste Regel: wägt nach jeder Kerze anhand ähnlicher früherer Trades ab, ob sich Halten noch lohnt
    "Signal-Ziel + Smart-Ausstieg": {"signal_tp": True, "smart": True},
    # Wägt ab, ob der Stop auf Einstieg (Break-even) gehört, z. B. wenn der Trade zäh wird
    "Signal-Ziel + Smart-BE": {"signal_tp": True, "smart_be": True},
    "Signal-Ziel + Smart-BE + Ausstieg": {"signal_tp": True, "smart": True, "smart_be": True},
}
SMART_EXIT = "Signal-Ziel + Smart-Ausstieg"
SMART_VARS = [k for k, v in VARIANTS.items() if v.get("smart") or v.get("smart_be")]
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


def _ago(sec):
    sec = max(0, int(sec))
    if sec < 90:
        return f"{sec} s"
    if sec < 5400:
        return f"{sec // 60} Min"
    if sec < 172800:
        return f"{sec // 3600} Std"
    return f"{sec // 86400} Tagen"


def _fmt(v, f):
    """Zahl im deutschen Format: 1.234,50 statt 1,234.50."""
    return format(v, f).translate(str.maketrans(",.", ".,"))


def _wd(day):
    return ("Mo", "Di", "Mi", "Do", "Fr", "Sa", "So")[dt.date.fromisoformat(day).weekday()]


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


# Alle Strategien des TradingView-Scripts (Name wie im Signal), damit man sie schon vor dem ersten Signal steuern kann
KNOWN_SETUPS = [f"{b} {d}" for b in ("FVG", "iFVG", "Silver Bullet", "ORB", "Sweep", "VWAP") for d in ("Long", "Short")]


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
        self.old_script = None
        self.ticks = {}
        self.data_dir = data_dir
        self.outbox = []              # wartende Discord-Nachrichten (sendet der Server)
        self.discord_state = {"last": None, "error": ""}
        self._notified = {}
        self._silent = False
        self._daystop_day = None   # wird nach dem Laden des Lernstands gesetzt
        self._last_loop = time.time()
        self.paths, self.pm_index, self.pm_info, self.sfit = {}, {}, {}, None
        self._pm_busy = False
        self._ratr_cache, self._smart_pos_cache = {}, {}
        self.disc, self.disc_state, self._disc_sent, self.last_bundle = None, {"busy": False}, set(), 1
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
        self.db.on_log = self._on_log
        self._disc_load()
        self._daystop_day = self.learning.get("daystop_day")
        self.broker = BROKERS[self.cfg["broker"]](self.cfg)
        self._connect_broker()
        threading.Thread(target=self._loop, daemon=True).start()
        _t = threading.Timer(180, lambda: self.learn_paths_async(adopt=self.cfg["learning"].get("auto_adopt", True))); _t.daemon = True; _t.start()
        if time.time() - (self.disc.get("last_run") or 0) > 20 * 3600:
            _t = threading.Timer(1200, self.disc_async); _t.daemon = True; _t.start()   # erst 20 Min nach dem Start (schwere Rechnung)

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
        sc = c.get("session_scale") or {}
        clean_sc = {}
        for k, v in sc.items():
            if v is None:
                continue
            f_, g_ = float(v.get("f", 1)), float(v.get("g", 1))
            if not (0.3 <= f_ <= 1.0 and 0.3 <= g_ <= 1.0):
                raise ValueError("Session-Ziele: Faktoren zwischen 0,3 und 1,0")
            if f_ < 1.0 or g_ < 1.0:
                clean_sc[str(k)[:60]] = {"f": f_, "g": g_, "added": float(v.get("added") or time.time()), "auto": bool(v.get("auto")),
                                         "gain": float(v.get("gain") or 0)}
        c["session_scale"] = clean_sc
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
                          "active": bool(r.get("active", True)), "auto": bool(r.get("auto"))})
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
        dc = c["discord"]
        dc["url"] = str(dc.get("url") or "").strip()
        if dc["url"] and not re.match(r"^https://(discord\.com|discordapp\.com|ptb\.discord\.com|canary\.discord\.com)/api/webhooks/\d+/[\w-]+$", dc["url"]):
            raise ValueError("Discord: bitte die komplette Webhook-URL einfügen (https://discord.com/api/webhooks/…)")
        if dc["enabled"] and not dc["url"]:
            raise ValueError("Discord: zuerst die Webhook-URL eintragen")
        dc["silence_min"] = max(0, min(600, int(float(dc.get("silence_min") or 0))))
        rk = c["risk"]
        rk["daily_profit_stop"] = float(rk.get("daily_profit_stop") or 0)
        if rk["daily_profit_stop"] < 0 or float(rk["max_daily_loss"] or 0) < 0:
            raise ValueError("Tages-Stopp: Beträge dürfen nicht negativ sein")
        rk["daily_stop_close"] = bool(rk.get("daily_stop_close"))
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
        self.old_script = None if "bars" in p else time.time()   # altes Script schickt jede Kerze einzeln
        # Gebündelte Kerzen (TradingView schickt ohne offenen Trade mehrere Kerzen in einer Nachricht, spart Anfragen)
        extra = []
        for r in (p.get("bars") or [])[:12] if isinstance(p.get("bars"), list) else []:
            if isinstance(r, list) and len(r) >= 5:
                vals = [self._num(x) for x in r[:5]]
                if None not in vals and vals[0] != bar["time"]:
                    extra.append(vals)
        for t_, o_, h_, l_, c_ in sorted(extra):
            try:
                self.db.add_bar(fam, t_, o_, h_, l_, c_)
            except Exception:  # noqa: BLE001
                pass
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
                self._process_bar(fam, {"time": t_, "open": o_, "high": h_, "low": l_, "close": c_, "ts": bar["ts"], "len": 60000})
        else:
            tf_ = self.chart_tf.get(fam) or 300000
            for t_, o_, h_, l_, c_ in sorted(extra):
                self._process_bar(fam, {"time": t_, "open": o_, "high": h_, "low": l_, "close": c_, "ts": bar["ts"], "len": tf_})
            bar["len"] = tf_
            self._process_bar(fam, bar)
        self.last_bundle = len(extra) + 1
        try:
            self._disc_live(fam)
        except Exception as e:  # noqa: BLE001  ein Fehler im Strategie-Finder darf den Handel nie stören
            self.db.log(f"Strategie-Finder: Live-Prüfung fehlgeschlagen ({e})", "warn")
        return {"ok": True, "type": "bar", "m1": len(subs), "bars": len(extra) + 1}

    def _on_tick(self, p):
        """Live-Kurs aus TradingView (alle ~20 s, solange die Strategie im Trade ist)."""
        fam = family(self._root(p.get("ticker")))
        price = self._num(p.get("price"))
        if price is None:
            raise ValueError("Kurs fehlt")
        self.last_tick[fam] = {"price": price, "ts": time.time(), "time": self._num(p.get("time"))}
        tl = self.ticks.setdefault(fam, [])   # für die laufende Kerze im Chart
        tl.append((time.time() * 1000, price))
        while tl and tl[0][0] < (time.time() - 6 * 3600) * 1000:
            tl.pop(0)
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
        try:
            self._ghost_bar(fam, bar)
        except Exception as e:  # noqa: BLE001  Nachverfolgung darf den Handel nie stören
            self.db.log(f"Nachverfolgung fehlgeschlagen: {e}", "warn")
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
            vr = VARIANTS.get(v["var"], {})
            stop = v["stop"]
            if (vr.get("smart") or vr.get("smart_be")) and self._chart_close(fam, bar):
                dec = self._smart_for(v, bar, v["entry"], v["risk"], v["stop"], v["tp"], best, v["setup"], fam, v["side"], v["shadow_id"],
                                      want_be=bool(vr.get("smart_be")))
                if dec and dec["exit"] and vr.get("smart"):
                    self._close_variant(v, bar["close"])
                    continue
                if dec and dec["be"] and vr.get("smart_be"):
                    stop = v["entry"]
            stop = manage_stop(v["side"], v["entry"], v["risk"], stop, best, vr)
            if best != v["best"] or stop != v["stop"]:
                self.db.update_variant(v["id"], best=best, stop=stop)
        # Break-even/Trailing für Bot-Positionen mit übernommenem Ausstieg (wirkt ab der nächsten Kerze)
        for pos in self.db.open_positions():
            rule = VARIANTS.get(pos.get("mgmt") or "")
            if not rule or not (rule.get("be") or rule.get("trail") or rule.get("smart") or rule.get("smart_be")) \
                    or family(pos["root"]) != fam or not self._bar_after(pos, bar):
                continue
            long_ = pos["side"] == "long"
            if (bar["low"] <= pos["sl"]) if long_ else (bar["high"] >= pos["sl"]):
                continue   # Stop wird gleich ausgelöst bzw. vom Broker ausgeführt
            if pos["tp"] and ((bar["high"] >= pos["tp"]) if long_ else (bar["low"] <= pos["tp"])):
                continue   # Ziel wird gleich ausgelöst
            risk = abs(pos["entry"] - (pos["initial_sl"] or pos["sl"]))
            prev = pos.get("best") or pos["entry"]
            best = max(prev, bar["high"]) if long_ else min(prev, bar["low"])
            dec = None
            if (rule.get("smart") or rule.get("smart_be")) and self._chart_close(fam, bar):
                dec = self._smart_for(pos, bar, pos["entry"], risk, pos["sl"], pos["tp"], best, pos["setup"], fam, pos["side"],
                                      want_be=bool(rule.get("smart_be")))
            why = "Smart-Ausstieg: " + dec["text"] if dec and dec["exit"] and rule.get("smart") else None
            if why:
                try:
                    if bar.get("time"):
                        self.db.update_position(pos["id"], exit_bar=bar["time"])
                    self._close(pos, bar["close"], why)
                    self.db.log(f"{pos['side'].upper()} {pos['qty']}× {pos['root']} vorzeitig geschlossen · {why}")
                except ValueError as e:
                    self.db.log(f"Smart-Ausstieg fehlgeschlagen: {e}", "error")
                continue
            base_sl = pos["entry"] if dec and dec["be"] and rule.get("smart_be") else pos["sl"]
            new = round_tick(manage_stop(pos["side"], pos["entry"], risk, base_sl, best, rule), INSTR[pos["root"]]["tick"])
            if new != pos["sl"]:
                try:
                    self.broker.modify_stop(pos, new)
                    self.db.update_position(pos["id"], sl=new, best=best)
                    self.db.log(f"Stop {pos['root']} nachgezogen auf {new:.2f} · " + (dec["be_text"] if dec and dec["be"] and base_sl != pos["sl"] else pos["mgmt"]))
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
                    "tp": tp if v.get("signal_tp") else price + d * v["tp"] * risk if v.get("tp") else None, "best": price,
                    "opened": time.time(), "status": "offen", "bar_time": base["bar_time"]} for k, v in VARIANTS.items()])
        # Session-Ziele: Stop/Ziel an die übliche Bewegung der Session anpassen (gelernt, nur wenn bewährt)
        sc = self._session_scale_for(base["setup"], session_of(ny_time(sig_ts)))
        if sc and not is_test:
            d_ = 1 if side == "long" else -1
            tick_ = INSTR[fam]["tick"]
            sl0, tp0 = sl, tp
            sl = round_tick(price - d_ * max(abs(price - sl0) * sc["g"], self.cfg["safe_stop"][fam]["min"]), tick_)
            tp = round_tick(price + d_ * abs(tp0 - price) * sc["f"], tick_)
            flags.append(f"Session-Ziele: Stop {abs(price - sl) / tick_:.0f} statt {abs(price - sl0) / tick_:.0f} Ticks, "
                         f"Ziel {abs(tp - price) / tick_:.0f} statt {abs(tp0 - price) / tick_:.0f} Ticks")
        # Vom Varianten-Labor übernommener Ausstieg für diese Strategie
        mgmt = (self.cfg.get("exit_rules") or {}).get(base["setup"])
        if mgmt in VARIANTS and not (mgmt in PAPER_ONLY_VARIANTS and self.broker.name != "paper"):
            v = VARIANTS[mgmt]
            d = 1 if side == "long" else -1
            tick = INSTR[fam]["tick"]
            tp = tp if v.get("signal_tp") else round_tick(price + d * v["tp"] * abs(price - sl), tick) if v.get("tp") else None
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
        if float(r.get("daily_profit_stop") or 0) > 0 and self.today_pnl() >= float(r["daily_profit_stop"]):
            return f"Tagesziel von {_fmt(float(r['daily_profit_stop']), ',.0f')} $ erreicht – heute keine neuen Trades"
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
        if True:
            pv = INSTR[root]["pv"]
            risk_usd = abs(fill - sig["sl"]) * sig["qty"] * pv
            self.notify("trades", f"{'🟢 LONG' if sig['side'] == 'long' else '🔴 SHORT'} {sig['qty']}× {root} · {sig['setup']}" + (" (Test)" if sig.get("is_test") else ""),
                        f"Einstieg **{_fmt(fill, '.2f')}** · Stop {_fmt(sig['sl'], '.2f')} ({_fmt(-risk_usd, ',.0f')} $)"
                        + (f" · Ziel {_fmt(sig['tp'], '.2f')} (+{_fmt(abs(sig['tp'] - fill) * sig['qty'] * pv, ',.0f')} $)" if sig["tp"] else f" · {sig.get('mgmt')}"),
                        "info")
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
        comm = self._comm(pos["root"]) * pos["qty"] * 2 if pos["broker"] == "paper" else 0.0
        pnl = (exit_price - pos["entry"]) * d * pos["qty"] * INSTR[pos["root"]]["pv"] - comm
        # Nachverfolgung: Bei frühem Ausstieg (oder nachgezogenem Stop) weiter beobachten, was ohne ihn passiert wäre
        cat, gsl, gtp = self._exit_cat(pos, reason)
        self.db.update_position(pos["id"], status="geschlossen", closed=time.time(), exit=round_tick(exit_price, tick),
                                pnl=round(pnl, 2), close_reason=reason, exit_cat=cat,
                                ghost_status="offen" if cat else None, ghost_sl=gsl, ghost_tp=gtp)
        self.db.log(f"{pos['side'].upper()} {pos['qty']}× {pos['root']} geschlossen ({reason}) · {_fmt(pnl, '+,.0f')} $",
                    "info" if pnl >= 0 else "warn")
        if pos["broker"] != "eigen":
            r_ = self._r_of(dict(pos, pnl=pnl))
            self.notify("trades", f"{'✅' if pnl > 0 else '❌'} {pos['side'].upper()} {pos['qty']}× {pos['root']} geschlossen · {pos['setup']}" + (" (Test)" if pos.get("is_test") else ""),
                        f"{reason} · {_fmt(pos['entry'], '.2f')} → {_fmt(exit_price, '.2f')} · **{_fmt(pnl, '+,.0f')} $**" + (f" ({_fmt(r_, '+.2f')} R)" if r_ is not None else "")
                        + f"\nHeute: {_fmt(self.today_pnl(), '+,.0f')} $", "good" if pnl > 0 else "bad")

    @staticmethod
    def _exit_cat(pos, reason):
        """Art des Ausstiegs → (Kategorie, Stop, Ziel für die Nachverfolgung) oder (None, …), wenn es nichts zu verfolgen gibt."""
        if pos["broker"] == "eigen" or not pos.get("initial_sl"):
            return None, None, None
        r = reason or ""
        tick = INSTR[pos["root"]]["tick"]
        if r.startswith("Ziel"):
            return None, None, None
        if r.startswith("Stop-Loss"):
            if abs(pos["sl"] - pos["initial_sl"]) > tick / 2:   # Stop war nachgezogen (BE/Trailing): Was hätte der alte Stop gebracht?
                return "Stop nachgezogen", pos["initial_sl"], pos["tp"]
            return None, None, None
        for key, cat in (("Smart-Ausstieg", "Smart-Ausstieg"), ("Exit-Signal", "TradingView-Exit"), ("News", "News"),
                         ("Sessionende", "Sessionende"), ("Tages-Stopp", "Tages-Stopp"), ("Manuell", "Manuell")):
            if key in r:
                return cat, pos["sl"], pos["tp"]
        return "Sonstiges", pos["sl"], pos["tp"]

    def _ghost_bar(self, fam, bar):
        """Frühzeitig geschlossene Trades weiter verfolgen: Ziel, Stop oder Sessionende?"""
        if not bar.get("time"):
            return
        for p in self.db.rows("SELECT * FROM positions WHERE ghost_status='offen'"):
            if family(p["root"]) != fam or bar["time"] < (p["closed"] or 0) * 1000 - 1000:
                continue
            d = 1 if p["side"] == "long" else -1
            how, px = None, None
            if p["ghost_sl"] is not None and ((bar["low"] <= p["ghost_sl"]) if d > 0 else (bar["high"] >= p["ghost_sl"])):
                how, px = "Stop", p["ghost_sl"]
            elif p["ghost_tp"] is not None and ((bar["high"] >= p["ghost_tp"]) if d > 0 else (bar["low"] <= p["ghost_tp"])):
                how, px = "Ziel", p["ghost_tp"]
            elif ny_time(bar["time"] / 1000) >= self._session_end(p) or bar["time"] / 1000 - p["closed"] > 24 * 3600:
                how, px = "Sessionende", bar["open"]
            if not how:
                continue
            r0 = abs(p["entry"] - p["initial_sl"]) or 1e-9
            gr = (px - p["entry"]) * d / r0
            ar = (p["exit"] - p["entry"]) * d / r0
            self.db.update_position(p["id"], ghost_status="fertig", ghost_exit=px, ghost_r=round(gr, 3), ghost_how=how)
            if not p["is_test"]:
                diff = ar - gr
                verdict = "gerettet" if diff > 0.05 else "verpasst" if diff < -0.05 else "kein Unterschied"
                self.db.log(f"Nachverfolgung {p['side'].upper()} {p['root']} ({p['exit_cat']}): ohne frühen Ausstieg {how} bei "
                            f"{_fmt(gr, '+.2f')} R statt {_fmt(ar, '+.2f')} R – {verdict} {_fmt(abs(diff), '.2f')} R")
                self.notify("trades", f"🔍 Nachverfolgung · {p['setup']} ({p['exit_cat']})",
                            f"Ohne frühen Ausstieg: {how} bei **{_fmt(gr, '+.2f')} R** · tatsächlich {_fmt(ar, '+.2f')} R → "
                            f"**{verdict}{'' if verdict == 'kein Unterschied' else ' ' + _fmt(abs(diff), '.2f') + ' R'}**",
                            "good" if diff > 0.05 else "bad" if diff < -0.05 else "info")

    def exit_review(self):
        """Lohnen sich die frühen Ausstiege? Je Art und Strategie: tatsächlich gegen „hätte ich gehalten“."""
        rows = [p for p in self.db.rows("SELECT * FROM positions WHERE ghost_status IS NOT NULL ORDER BY closed")
                if p["broker"] == self.broker.name and not p["is_test"] and p.get("initial_sl")]
        groups, open_n = {}, 0
        for p in rows:
            if p["ghost_status"] != "fertig":
                open_n += 1
                continue
            d = 1 if p["side"] == "long" else -1
            r0 = abs(p["entry"] - p["initial_sl"]) or 1e-9
            ar = (p["exit"] - p["entry"]) * d / r0
            for key in (p["exit_cat"], p["exit_cat"] + "|" + (p["setup"] or "")):
                groups.setdefault(key, []).append((ar, p["ghost_r"], p["ghost_how"], p["closed"]))
        out = {}
        for key, lst in groups.items():
            diffs = [a - g for a, g, _, _ in lst]
            k = int(len(diffs) * 0.6)
            out[key] = {"n": len(lst), "actual": round(_mean([a for a, *_ in lst]), 3), "held": round(_mean([g for _, g, *_ in lst]), 3),
                        "diff": round(_mean(diffs), 3), "d1": round(_mean(diffs[:k]), 3) if k else None,
                        "d2": round(_mean(diffs[k:]), 3) if diffs[k:] else None, "sum": round(sum(diffs), 2),
                        "target": sum(1 for *_, how, _ in lst if how == "Ziel"), "stop": sum(1 for *_, how, _ in lst if how == "Stop")}
        recent = []
        for p in reversed(rows[-30:]):
            d = 1 if p["side"] == "long" else -1
            r0 = abs(p["entry"] - p["initial_sl"]) or 1e-9
            recent.append({"id": p["id"], "closed": p["closed"], "setup": p["setup"], "side": p["side"], "cat": p["exit_cat"],
                           "actual": round((p["exit"] - p["entry"]) * d / r0, 2), "held": p["ghost_r"], "how": p["ghost_how"],
                           "status": p["ghost_status"]})
        return {"groups": out, "open": open_n, "recent": recent, "follow_tv": bool(self.cfg["follow_tv_exits"]),
                "auto": self.learning.get("exit_auto") or []}

    def _exit_learn(self, er):
        """Aus den Nachverfolgungen lernen: Ausstiege, die nachweislich Geld kosten, selbst abschalten."""
        done, rv = [], self.exit_review()["groups"]
        g = rv.get("TradingView-Exit")
        if g and self.cfg["follow_tv_exits"] and g["n"] >= 15 and g["diff"] <= -0.1 and (g["d1"] or 0) < 0 and (g["d2"] or 0) < 0:
            self.cfg["follow_tv_exits"] = False
            self._write_cfg(self.cfg)
            done.append(f"TradingView-Exits werden nicht mehr befolgt: Gehalten wären es im Schnitt {_fmt(-g['diff'], '.2f')} R mehr gewesen "
                        f"({g['n']} Trades). Stop und Ziel bleiben aktiv.")
        for key, g in rv.items():
            if "|" not in key:
                continue
            cat, setup = key.split("|", 1)
            if cat not in ("Smart-Ausstieg", "Stop nachgezogen") or setup not in er:
                continue
            if g["n"] >= 12 and g["diff"] <= -0.1 and (g["d1"] or 0) < 0 and (g["d2"] or 0) < 0:
                old = er.pop(setup)
                self.learning.setdefault("exit_blocked", {})[setup] = {"var": old, "until": time.time() + 30 * 86400}
                done.append(f"{setup}: Ausstieg „{old}“ zurück auf das Signal-Ziel – in echten Trades hätte Halten im Schnitt "
                            f"{_fmt(-g['diff'], '.2f')} R mehr gebracht ({g['n']} Trades)")
        return done

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

    def _minutes_in(self, obj, bar):
        """Minuten seit dem Einstieg (Schluss der Signal-Kerze) bis zum Schluss dieser Kerze."""
        fam = obj.get("fam") or family(obj["root"])
        if obj.get("bar_time") and bar.get("time"):
            start = obj["bar_time"] + (self.chart_tf.get(fam) or 0)
            return (bar["time"] + (bar.get("len") or 60000) - start) / 60000
        return (time.time() - obj["opened"]) / 60

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
            self.learning = {"last_run": time.time(), "last_day": str(ny_date()), "setups": setups, "insights": insights[:15],
                             "rejected_rules": self.learning.get("rejected_rules") or [], "auto_log": self.learning.get("auto_log") or [],
                             "daystop_day": self.learning.get("daystop_day"), "exit_blocked": self.learning.get("exit_blocked") or {}}
            with open(self.learn_path, "w", encoding="utf-8") as f:
                json.dump(self.learning, f, indent=2, ensure_ascii=False)
            return self.learning

    def auto_adopt(self):
        """Setzt Ergebnisse aus Varianten-Labor und Regel-Finder selbst um – und nimmt sie zurück, wenn sie sich nicht bewähren."""
        if not self.cfg["learning"].get("auto_adopt", True):
            return []
        with self.lock:
            done = []
            # 1) Ausstiege: empfohlene Variante übernehmen (oder zurück aufs Signal-Ziel, wenn das wieder besser ist)
            er = dict(self.cfg.get("exit_rules") or {})
            blocked = self.learning.get("exit_blocked") or {}
            for row in self.variant_view()["setups"]:
                rec = row["rec"]
                if not rec or rec == row["applied"]:
                    continue
                b_ = blocked.get(row["setup"]) or {}
                if b_.get("var") == rec and b_.get("until", 0) > time.time():
                    continue   # in echten Trades gerade erst als schlechter erkannt: 30 Tage nicht wieder übernehmen
                if rec == "Signal-Ziel":
                    er.pop(row["setup"], None)
                else:
                    er[row["setup"]] = rec
                c = row["cols"][rec]
                done.append(f"{row['setup']}: Ausstieg {row['applied']} → {rec} (Ø {_fmt(c['avg'], '+.2f')} R aus {c['n']} Signalen)")
            # 1b) Echte Trades: frühe Ausstiege, die nachweislich kosten, zurücknehmen
            done += self._exit_learn(er)
            # 2) Regeln: bewährte übernehmen, schlecht laufende Auto-Regeln wieder entfernen
            rf = self.rules_find()
            rejected = set(self.learning.get("rejected_rules") or [])
            rules = []
            for r in rf["active"]:
                key = json.dumps([r["setup"], r["conds"], r["action"]])
                if r.get("auto") and r["blocked_n"] >= 15 and r["blocked_r"] > 0:
                    rejected.add(key)
                    done.append(f"Regel verworfen – {r['setup']} {'meiden' if r['action'] == 'avoid' else 'nur'}, wenn {r['label']}: "
                                f"die geblockten {r['blocked_n']} Signale hätten {_fmt(r['blocked_r'], '+.1f')} R gebracht")
                    continue
                rules.append({k: r[k] for k in ("setup", "conds", "action", "label", "added", "active", "auto") if k in r})
            have = {json.dumps([r["setup"], r["conds"], r["action"]]) for r in rules}
            for f in rf["found"]:
                key = json.dumps([f["setup"], f["conds"], f["action"]])
                mine = [r for r in rules if r["setup"] == f["setup"] and r.get("auto")]
                if key in have or key in rejected or len(mine) >= 3 or len(rules) >= 50:
                    continue
                if f["action"] == "only" and any(r["action"] == "only" for r in mine):
                    continue   # höchstens eine „nur wenn“-Regel je Strategie, sonst wird es zu eng
                rules.append({"setup": f["setup"], "conds": f["conds"], "action": f["action"], "label": f["label"],
                              "added": time.time(), "active": True, "auto": True})
                have.add(key)
                done.append(f"Regel übernommen – {f['setup']} {'meiden' if f['action'] == 'avoid' else 'nur'}, wenn {f['label']} "
                            f"(Ø {_fmt(f['avg_match'], '+.2f')} R gegenüber {_fmt(f['avg_rest'], '+.2f')} R, {f['n']} Signale)")
            # 3) Session-Ziele: realistische Stop-/Ziel-Abstände je Session
            sc = {k: dict(v) for k, v in (self.cfg.get("session_scale") or {}).items()}
            fit = (self.sfit or {}).get("groups") or {}
            for key, g in sorted(fit.items()):
                if not g["rec"] or ("|" in key and g["n"] < 60):
                    continue
                name = key if "|" not in key else key.split("|")[0] + " in " + SESSION_NAMES.get(key.split("|")[1], key.split("|")[1])
                name = SESSION_NAMES.get(name, name)
                if g["rec"]["f"] >= 1.0 and g["rec"]["g"] >= 1.0:
                    sc[key] = None
                    done.append(f"Session-Ziele {name}: zurück auf die Abstände aus dem Signal")
                else:
                    sc[key] = {"f": g["rec"]["f"], "g": g["rec"]["g"], "added": time.time(), "auto": True,
                               "gain": round(g["best"]["avg"] - g["cur"]["avg"], 3)}
                    done.append(f"Session-Ziele {name}: Ziel {g['rec']['f'] * 100:.0f} %, Stop {g['rec']['g'] * 100:.0f} % der Signal-Abstände "
                                f"(Ø {_fmt(g['cur']['avg'], '+.2f')} → {_fmt(g['best']['avg'], '+.2f')} R aus {g['n']} Signalen)")
            if done:
                self.cfg["session_scale"] = {k: v for k, v in sc.items() if v}
                self.update_cfg({"exit_rules": er, "rule_filters": rules})
                if any(k not in er for k in (self.cfg.get("exit_rules") or {})):
                    self.cfg["exit_rules"] = er
                    self._write_cfg(self.cfg)
                for d in done:
                    self.db.log("Lernmodul (automatisch): " + d)
            self.learning["rejected_rules"] = sorted(rejected)
            self.learning["auto_log"] = ([{"t": time.time(), "text": d} for d in done] + (self.learning.get("auto_log") or []))[:30]
            with open(self.learn_path, "w", encoding="utf-8") as fh:
                json.dump(self.learning, fh, indent=2, ensure_ascii=False)
            return done

    def learning_view(self):
        rows = []
        names = set(self.learning.get("setups", {})) | set(self.cfg["setup_rules"]) | \
            {s["setup"] for s in self.db.rows("SELECT DISTINCT setup FROM shadow")} | set(KNOWN_SETUPS)
        order = {n: i for i, n in enumerate(KNOWN_SETUPS)}
        for name in sorted(names, key=lambda n: (order.get(n, 99), n)):
            d = dict(self.learning.get("setups", {}).get(name) or {"status": "lernt", "n": 0, "total": 0})
            d["setup"] = name
            d["manual"] = self.cfg["setup_rules"].get(name, "auto")
            d["effective"] = self.setup_rule(name)
            d["open"] = len([s for s in self.db.open_shadows() if s["setup"] == name])
            rows.append(d)
        return {"last_run": self.learning.get("last_run"), "setups": rows,
                "insights": self.learning.get("insights", []), "params": self.cfg["learning"],
                "auto_log": self.learning.get("auto_log", [])}

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
            self._last_loop = now
            self._check_daystop()
            self._check_silence()
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
                self.learn_paths_async(adopt=True)   # Kursverläufe, Smart-Ausstieg, Session-Ziele, dann selbst übernehmen
                self.db.log("Lernmodul: Tagesauswertung abgeschlossen")
                self.notify("daily", f"Tagesabschluss {t.strftime('%d.%m.')}", self.day_report_text(), "info")
                if t.weekday() == 4:
                    rep = self.weekly_report()
                    self.notify("weekly", f"Wochenbericht {rep['monday'][8:10]}.{rep['monday'][5:7]}.–{rep['friday'][8:10]}.{rep['friday'][5:7]}.",
                                self.weekly_text(rep), "good" if rep["net"] > 0 else "bad" if rep["net"] < 0 else "info")
                self.db.prune_bars((now - 1100 * 86400) * 1000)  # Kerzen älter als ~3 Jahre löschen
                self.db.prune_bars1((now - 1100 * 86400) * 1000)  # 1-Minuten-Kerzen ~3 Jahre (Strategie-Finder, auch importierte)
                _t = threading.Timer(120, self.disc_async); _t.daemon = True; _t.start()     # nach der Tagesauswertung neue Strategien suchen
            nw = self.cfg["news"]
            if nw["enabled"] and nw["close_before"] and self.db.open_positions():
                for e in self.news_window():
                    news_ts = e["ts"] / 1000
                    key = f"{e['title']}{e['ts']}"
                    # 1 Minute vor dem Termin (bzw. sofort, wenn die Pause schon läuft) offene Positionen schließen
                    if key not in self._news_closed and time.time() >= min(news_ts - 60, e["start"]) and time.time() <= e["end"]:
                        self._news_closed.add(key)
                        for pos in self.db.open_positions():
                            try:
                                self._close(pos, None, f"News: {e['title']}")
                            except ValueError:
                                pass
                        self.db.log(f"Vor News geschlossen: {e['title']} um {ny_time(news_ts).strftime('%H:%M')} NY", "warn")
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
        com = self._comm("MNQ") * 2
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
        ids = {}
        for v in self.db.closed_variants():
            by.setdefault(v["setup"], {}).setdefault(v["var"], []).append((v["opened"], v["r"]))
            ids.setdefault((v["setup"], v["var"]), {})[v["shadow_id"]] = v["r"]
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
            base_r = {x["id"]: x["r"] for x in self._lab_shadows() if x["setup"] == setup}
            for k, c in cols.items():
                if k == cur_key or c["n"] < min_n or c["a1"] is None or c["a2"] is None or cur["n"] == 0:
                    continue
                # Auf denselben Signalen vergleichen (neue Varianten gibt es erst ab ihrem Einbau)
                mine = base_r if k == "Signal-Ziel" else ids.get((setup, k), {})
                other = base_r if cur_key == "Signal-Ziel" else ids.get((setup, cur_key), {})
                common = [sid for sid in mine if sid in other]
                if len(common) < min_n:
                    continue
                k1 = int(len(common) * 0.6)
                dm = [mine[x] - other[x] for x in common]
                d_all, d1, d2 = _mean(dm), _mean(dm[:k1]), _mean(dm[k1:])
                if k in PAPER_ONLY_VARIANTS and self.broker.name != "paper":
                    continue
                if d_all >= 0.15 and d1 > 0 and d2 > 0 and c["avg"] > 0:
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
            self.db.log(f"Eigener Trade eingetragen: {day} {side.upper()} {qty}× {root} · {_fmt(pnl, '+,.0f')} $")
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

    # ───────── Gelerntes Abwägen: Kursverläufe vergangener Signale ─────────
    # Für jedes abgeschlossene Signal wird der Kursverlauf nach dem Einstieg (bis 16:00 NY) in R gespeichert.
    # Daraus lernt der Bot (1) ob sich ein laufender Trade noch lohnt (Smart-Ausstieg, ohne feste Regel)
    # und (2) welche Stop-/Ziel-Abstände in welcher Session realistisch sind (Session-Ziele).

    def _ny_epoch(self, naive):
        guess = (naive - dt.datetime(1970, 1, 1)).total_seconds() + 5 * 3600
        off = (ny_time(guess) - dt.datetime.fromtimestamp(guess, dt.timezone.utc).replace(tzinfo=None)).total_seconds()
        return (naive - dt.datetime(1970, 1, 1)).total_seconds() - off

    def _entry_ms(self, obj, tf):
        bt = obj.get("bar_time")
        if bt and abs(bt / 1000 - obj["opened"]) < 400 * 86400:
            return bt + tf
        return obj["opened"] * 1000

    def _ratr(self, fam, entry_ms, r0, tf=None):
        """Stop-Abstand im Verhältnis zur normalen Kerzen-Spanne vor dem Einstieg."""
        key = (fam, int(entry_ms // 60000), round(r0, 2))
        if key in self._ratr_cache:
            return self._ratr_cache[key]
        tf = tf or self.chart_tf.get(fam) or 300000
        rows = self.db.rows("SELECT h, l FROM bars WHERE fam=? AND t<? AND t>=? ORDER BY t DESC LIMIT 12",
                            (fam, entry_ms, entry_ms - 40 * tf))
        rng = [x["h"] - x["l"] for x in rows if x["h"] > x["l"]]
        val = r0 / (sum(rng) / len(rng)) if len(rng) >= 4 else None
        if len(self._ratr_cache) > 5000:
            self._ratr_cache.clear()
        self._ratr_cache[key] = val
        return val

    @staticmethod
    def _pm_keys(setup, mins, r_now, best, ratr):
        mb = 0 if mins < 10 else 1 if mins < 20 else 2 if mins < 40 else 3 if mins < 80 else 4 if mins < 160 else 5
        rb = max(-4, min(8, math.floor(r_now / 0.25)))
        bb = max(0, min(4, math.floor(max(0.0, best) / 0.5)))
        ab = 9 if ratr is None else 0 if ratr < 1.5 else 1 if ratr < 3 else 2 if ratr < 6 else 3
        return [(setup, mb, rb, bb, ab), ("*", mb, rb, bb, ab), ("*", mb, rb, bb), ("*", mb, rb)]

    def paths_build(self):
        """Kursverläufe aller fertigen Signale aufbauen (läuft im Hintergrund, ändert nichts am Handel)."""
        now = time.time()
        paths = dict(self.paths)
        for sh in self.db.rows("SELECT id, setup, fam, side, entry, sl, tp, opened, closed, r, bar_time, ctx FROM shadow "
                               "WHERE status='geschlossen' AND r IS NOT NULL ORDER BY opened"):
            if sh["id"] in paths:
                continue
            end = self._ny_epoch(self._session_end(sh))
            if end > now - 300:
                continue   # Verlauf bis Sessionende noch nicht komplett
            r0 = abs(sh["entry"] - sh["sl"])
            if r0 <= 0:
                paths[sh["id"]] = None
                continue
            probe = self.db.rows("SELECT t FROM bars WHERE fam=? AND t>=? ORDER BY t LIMIT 40",
                                 (sh["fam"], (sh["bar_time"] or sh["opened"] * 1000) - 40 * 3600 * 1000))
            tf = self._tf_of([[x["t"]] for x in probe]) or self.chart_tf.get(sh["fam"]) or 300000
            e_ms = self._entry_ms(sh, tf)
            bars = self.db.rows("SELECT t, h, l, c FROM bars WHERE fam=? AND t>=? AND t<? ORDER BY t LIMIT 300",
                                (sh["fam"], e_ms, end * 1000))
            if not bars:
                paths[sh["id"]] = None
                continue
            d = 1 if sh["side"] == "long" else -1
            e = sh["entry"]
            fav = [((x["h"] if d > 0 else x["l"]) - e) * d / r0 for x in bars]
            adv = [((x["l"] if d > 0 else x["h"]) - e) * d / r0 for x in bars]
            cl = [(x["c"] - e) * d / r0 for x in bars]
            paths[sh["id"]] = {"id": sh["id"], "setup": sh["setup"], "fam": sh["fam"], "side": sh["side"], "entry": e, "r0": r0,
                               "t_r0": abs(sh["tp"] - e) / r0 if sh["tp"] else 2.0, "tf_min": tf / 60000, "entry_ms": e_ms,
                               "end_ms": end * 1000, "opened": sh["opened"], "closed": sh["closed"], "r": sh["r"],
                               "sess": self._shadow_session(sh), "ratr": self._ratr(sh["fam"], e_ms, r0, tf),
                               "fav": fav, "adv": adv, "cl": cl, "bar_time": sh["bar_time"], "sl": sh["sl"], "tp": sh["tp"]}
        index = {}
        for p in paths.values():
            if not p:
                continue
            best = -9.0
            for k in range(min(len(p["cl"]), 96)):
                best = max(best, p["fav"][k])
                for key in self._pm_keys(p["setup"], (k + 1) * p["tf_min"], p["cl"][k], best, p["ratr"]):
                    index.setdefault(key, []).append((p["id"], k))
        self.paths, self.pm_index = paths, index
        self.pm_info = {"built": time.time(), "trades": sum(1 for p in paths.values() if p),
                        "snapshots": sum(len(v) for k, v in index.items() if len(k) == 5 and k[0] != "*")}
        return self.pm_info

    def smart_check(self, setup, mins, r_now, best, ratr, s_r, t_r, max_bars, before_ms, exclude=None, want_be=True):
        """Wägt ab: Was bringt Halten im Schnitt, wenn ähnliche Trades in der Vergangenheit so standen?
        Keine feste Regel – entschieden wird nach Erfahrung und nur, wenn der Unterschied deutlich ist."""
        idx = self.pm_index
        if not idx:
            return None
        cand = None
        for key in self._pm_keys(setup, mins, r_now, best, ratr):
            seen = {}
            for sid, k in idx.get(key, ()):
                if sid == exclude or sid in seen:
                    continue
                p = self.paths.get(sid)
                if not p or p["end_ms"] >= before_ms or k + 1 >= len(p["cl"]):
                    continue
                seen[sid] = k
            if len(seen) >= 25:
                cand = seen
                break
        if not cand:
            return None
        picks = sorted(cand.items(), key=lambda kv: -self.paths[kv[0]]["opened"])[:40]
        # Break-even nur prüfen, wenn der Stop noch unter dem Einstieg liegt und der Kurs darüber
        be_ok = want_be and s_r < -0.02 and r_now > 0.05

        def run(stop_r):
            res = []
            for sid, k in picks:
                p = self.paths[sid]
                base = p["cl"][k]
                r = None
                last = min(len(p["cl"]), k + 1 + max(1, int(max_bars)))
                for j in range(k + 1, last):
                    if r_now + p["adv"][j] - base <= stop_r:
                        r = stop_r
                        break
                    if t_r is not None and r_now + p["fav"][j] - base >= t_r:
                        r = t_r
                        break
                res.append(r if r is not None else r_now + p["cl"][last - 1] - base)
            return res

        def mse(v):
            m = sum(v) / len(v)
            sd = (sum((x - m) ** 2 for x in v) / (len(v) - 1)) ** 0.5 if len(v) > 1 else 1.0
            return m, sd / len(v) ** 0.5

        out = run(s_r)
        n = len(out)
        hold, se = mse(out)
        res = {"exit": r_now - hold > 0.05 + se, "be": False, "hold": round(hold, 3), "now": round(r_now, 3), "n": n,
               "se": round(se, 3), "p_win": round(sum(1 for x in out if x > r_now) / n * 100), "be_val": None,
               "text": f"Halten bringt bei {n} ähnlichen Trades im Schnitt {_fmt(hold, '+.2f')} R, jetzt raus {_fmt(r_now, '+.2f')} R"}
        if be_ok:
            be = run(0.0)
            # gepaarter Vergleich auf denselben Verläufen: Stop auf Einstieg gegen Stop lassen
            dm, dse = mse([b - h for b, h in zip(be, out)])
            bm, bse = mse(be)
            res["be_val"] = round(bm, 3)
            res["be"] = dm > 0.03 + dse
            if res["exit"] and r_now - bm <= 0.05 + bse:
                res["exit"] = False   # Break-even ist mindestens so gut wie Aussteigen: drin bleiben, Stop hoch
                res["be"] = res["be"] or dm > 0
            if res["be"]:
                res["be_text"] = (f"Stop auf Einstieg: bei {n} ähnlichen Trades {_fmt(bm, '+.2f')} R statt {_fmt(hold, '+.2f')} R "
                                  f"mit altem Stop (jetzt {_fmt(r_now, '+.2f')} R)")
        return res

    def _smart_for(self, obj, bar, entry, r0, stop, tp, best_px, setup, fam, side, exclude=None, want_be=True):
        tf = self.chart_tf.get(fam) or 300000
        d = 1 if side == "long" else -1
        e_ms = self._entry_ms(obj, tf)
        end_ms = self._ny_epoch(self._session_end(obj)) * 1000
        bar_end = bar["time"] + (bar.get("len") or tf) if bar.get("time") else time.time() * 1000
        return self.smart_check(setup, (bar_end - e_ms) / 60000, (bar["close"] - entry) * d / r0, (best_px - entry) * d / r0,
                                self._ratr(fam, e_ms, r0, tf), (stop - entry) * d / r0, (tp - entry) * d / r0 if tp else None,
                                max(1, (end_ms - bar_end) / tf), time.time() * 1000, exclude, want_be)

    def _chart_close(self, fam, bar):
        tf = self.chart_tf.get(fam) or 300000
        if (bar.get("len") or tf) >= tf:
            return True
        return bool(bar.get("time")) and (bar["time"] + bar["len"]) % tf == 0

    def smart_backfill(self):
        """Smart-Varianten rückwirkend für alle fertigen Signale durchrechnen – jeweils nur mit dem Wissen,
        das zum Zeitpunkt des Signals schon da war (kein Blick in die Zukunft)."""
        total = 0
        for var in SMART_VARS:
            vr = VARIANTS[var]
            have = {x["shadow_id"] for x in self.db.rows("SELECT shadow_id FROM variants WHERE var=?", (var,))}
            rows = []
            for p in sorted((p for p in self.paths.values() if p and p["id"] not in have), key=lambda p: p["opened"]):
                r, best, stop, acted = None, -9.0, -1.0, False
                for k in range(len(p["cl"])):
                    if p["adv"][k] <= stop:
                        r = stop
                        break
                    if p["fav"][k] >= p["t_r0"]:
                        r = p["t_r0"]
                        break
                    best = max(best, p["fav"][k])
                    if k >= 96:
                        break
                    dec = self.smart_check(p["setup"], (k + 1) * p["tf_min"], p["cl"][k], best, p["ratr"], stop, p["t_r0"],
                                           len(p["cl"]) - k - 1, p["entry_ms"], p["id"], bool(vr.get("smart_be")))
                    if dec and dec["exit"] and vr.get("smart"):
                        r = p["cl"][k]
                        acted = True
                        break
                    if dec and dec["be"] and vr.get("smart_be") and stop < 0:
                        stop = 0.0
                        acted = True
                if not acted:
                    r = p["r"]   # nicht eingegriffen: genau wie das Signal-Ziel
                elif r is None:
                    if stop >= 0 and len(p["cl"]) > 96:   # nach BE weiter bis Sessionende verfolgen
                        for k in range(97, len(p["cl"])):
                            if p["adv"][k] <= stop:
                                r = stop
                                break
                            if p["fav"][k] >= p["t_r0"]:
                                r = p["t_r0"]
                                break
                    if r is None:
                        r = p["cl"][-1]
                d = 1 if p["side"] == "long" else -1
                rows.append({"id": uuid.uuid4().hex[:12], "shadow_id": p["id"], "setup": p["setup"], "fam": p["fam"], "side": p["side"],
                             "var": var, "entry": p["entry"], "stop": p["sl"], "risk": p["r0"], "tp": p["tp"],
                             "best": p["entry"], "opened": p["opened"], "closed": p["closed"], "exit": p["entry"] + d * r * p["r0"],
                             "r": round(r, 3), "status": "geschlossen", "bar_time": p["bar_time"]})
            self.db.add_variants(rows)
            total += len(rows)
        return total

    def learn_paths_async(self, adopt=False):
        def run():
            if self._pm_busy:
                return
            self._pm_busy = True
            try:
                self.paths_build()
                n = self.smart_backfill()
                self.sfit = self.session_fit()
                if n:
                    self.db.log(f"Lernmodul: Smart-Ausstieg für {n} vergangene Signale durchgerechnet")
                if adopt:
                    self.auto_adopt()
            except Exception as e:  # noqa: BLE001
                self.db.log(f"Lernmodul: Kursverläufe konnten nicht ausgewertet werden ({e})", "warn")
            finally:
                self._pm_busy = False
        threading.Thread(target=run, daemon=True).start()

    def smart_view_pos(self, pos):
        """Aktuelle Einschätzung für eine offene Position (für das Cockpit)."""
        key = (pos["id"], int(time.time() // 20))
        if self._smart_pos_cache.get(pos["id"], (None,))[0] == key:
            return self._smart_pos_cache[pos["id"]][1]
        price, _ = self.last_price(family(pos["root"]))
        res = None
        if price is not None and pos.get("initial_sl") and pos["entry"] != pos["initial_sl"]:
            long_ = pos["side"] == "long"
            best = pos.get("best") or pos["entry"]
            best = max(best, price) if long_ else min(best, price)
            fam = family(pos["root"])
            res = self._smart_for(pos, {"close": price, "time": None, "len": None}, pos["entry"], abs(pos["entry"] - pos["initial_sl"]),
                                  pos["sl"], pos["tp"], best, pos["setup"], fam, pos["side"])
        self._smart_pos_cache[pos["id"]] = (key, res)
        return res

    # ───────── Session-Ziele: realistische Abstände je Session ─────────
    def _comm(self, root):
        """Gebühr pro Kontrakt und Seite: Micros (MNQ/MES) kosten deutlich weniger als Minis."""
        p = self.cfg["paper"]
        if root in ("MNQ", "MES"):
            return float(p.get("commission_micro", 0.75) if p.get("commission_micro") is not None else 0.75)
        return float(p["commission"])

    def _cost_r(self, fam, entry, stop_pts):
        """Gebühr + Slippage in R. Bei engerem Stop handelt der Bot mehr Kontrakte, dadurch wiegen Kosten schwerer."""
        sz = self._size(fam, entry, entry - stop_pts)
        root = sz[0] if not isinstance(sz, str) else INSTR[fam]["micro"]
        pv, tick = INSTR[root]["pv"], INSTR[root]["tick"]
        per = 2 * self._comm(root) + float(self.cfg["paper"]["slippage_ticks"]) * tick * pv
        return per / (stop_pts * pv)

    def session_fit(self):
        F = (0.4, 0.5, 0.6, 0.75, 0.9, 1.0)
        G = (0.5, 0.6, 0.75, 0.9, 1.0)
        groups = {}
        for p in self.paths.values():
            if p:
                groups.setdefault(p["sess"], []).append(p)
                groups.setdefault(p["setup"] + "|" + p["sess"], []).append(p)
        cur = self.cfg.get("session_scale") or {}
        out = {}
        cost_cache = {}
        for key, lst in groups.items():
            lst = sorted(lst, key=lambda p: p["opened"])
            n = len(lst)
            tick = INSTR[lst[0]["fam"]]["tick"]
            res = {}
            for f in F:
                for g in G:
                    rs = []
                    for p in lst:
                        t, s = p["t_r0"] * f, -g
                        r = None
                        for a, b in zip(p["adv"], p["fav"]):
                            if a <= s:
                                r = s
                                break
                            if b >= t:
                                r = t
                                break
                        if r is None:
                            r = p["cl"][-1]
                        ck = (p["id"], g)
                        if ck not in cost_cache:
                            cost_cache[ck] = self._cost_r(p["fam"], p["entry"], p["r0"] * g)
                        rs.append(r / g - cost_cache[ck])
                    res[(f, g)] = rs
            k = int(n * 0.6)
            summ = {fg: (_mean(rs), _mean(rs[:k]) if k else 0.0, _mean(rs[k:]) if rs[k:] else 0.0) for fg, rs in res.items()}
            c = cur.get(key) or {}
            cur_fg = (c.get("f", 1.0), c.get("g", 1.0)) if c else (1.0, 1.0)
            if cur_fg not in summ:
                cur_fg = (1.0, 1.0)
            best_fg = max(summ, key=lambda fg: summ[fg][0])
            b, cu = summ[best_fg], summ[cur_fg]
            rec = None
            if n >= 30 and best_fg != cur_fg and b[0] - cu[0] >= 0.1 and b[1] - cu[1] > 0.03 and b[2] - cu[2] > 0.03 and b[0] > 0:
                rec = {"f": best_fg[0], "g": best_fg[1]}
            base_hits = sum(1 for p in lst if any(x >= p["t_r0"] for x in p["fav"]) and
                            next((i for i, x in enumerate(p["fav"]) if x >= p["t_r0"]), 1e9) <
                            next((i for i, x in enumerate(p["adv"]) if x <= -1), 1e9))
            mfe2h = sorted(max(p["fav"][:max(1, int(120 / p["tf_min"]))]) * p["r0"] / tick for p in lst)
            out[key] = {"n": n, "sl_ticks": round(_mean([p["r0"] / tick for p in lst])), "tp_ticks": round(_mean([p["t_r0"] * p["r0"] / tick for p in lst])),
                        "mfe_ticks": round(mfe2h[len(mfe2h) // 2]) if mfe2h else None, "tp_hit": round(base_hits / n * 100, 1),
                        "base": round(summ[(1.0, 1.0)][0], 3), "cur": {"f": cur_fg[0], "g": cur_fg[1], "avg": round(cu[0], 3)},
                        "best": {"f": best_fg[0], "g": best_fg[1], "avg": round(b[0], 3), "a1": round(b[1], 3), "a2": round(b[2], 3)},
                        "rec": rec, "applied": key in cur}
        return {"groups": out, "built": time.time(), "trades": sum(1 for p in self.paths.values() if p)}

    def session_vol(self, days=20):
        """Ø Kerzen-Spanne je Session in Ticks (letzte 20 Tage)."""
        out = {}
        for fam in self.db.bar_fams():
            rows = self.db.bars(fam, (time.time() - days * 86400) * 1000)
            tick = INSTR[fam]["tick"]
            tf = self._tf_of([[x["t"]] for x in rows]) or 300000
            for x in rows:
                k = session_of(ny_time(x["t"] / 1000))
                o = out.setdefault(fam, {}).setdefault(k, [0.0, 0])
                o[0] += (x["h"] - x["l"]) / tick
                o[1] += 1
            out[fam] = {k: round(v[0] / v[1], 1) for k, v in out.get(fam, {}).items() if v[1]}
            out[fam]["_tf_min"] = round(tf / 60000)
        return out

    def session_targets_view(self):
        if not self.sfit:
            self.sfit = self.session_fit()
        return {"fit": self.sfit, "vol": self.session_vol(), "applied": self.cfg.get("session_scale") or {},
                "smart": dict(self.pm_info or {}, busy=self._pm_busy), "names": SESSION_NAMES}

    def _session_scale_for(self, setup, sess):
        sc = self.cfg.get("session_scale") or {}
        return sc.get(f"{setup}|{sess}") or sc.get(sess)

    # ───────── Chart: Kerzen + alles, was der Bot sieht (Struktur, Liquidität, Zonen, Trades, Signale) ─────────
    def _trading_day_bounds(self, day):
        """Handelstag = 18:00 New York am Vortag bis 17:00 New York."""
        prev = day - dt.timedelta(days=1)
        a = self._ny_epoch(dt.datetime(prev.year, prev.month, prev.day, 18, 0))
        b = self._ny_epoch(dt.datetime(day.year, day.month, day.day, 17, 0))
        return a, b

    def chart_days(self, fam):
        """Handelstage mit Kerzen (für die Tagesauswahl)."""
        rows = self.db.rows("SELECT MIN(t) a, MAX(t) b FROM bars WHERE fam=?", (fam,))
        r1 = self.db.rows("SELECT MIN(t) a, MAX(t) b FROM bars1 WHERE fam=?", (fam,))
        lo = min(x for x in (rows[0]["a"], r1[0]["a"]) if x) if (rows[0]["a"] or r1[0]["a"]) else None
        hi = max(x for x in (rows[0]["b"], r1[0]["b"]) if x) if (rows[0]["b"] or r1[0]["b"]) else None
        if not hi:
            return None, None
        def tday(ms):
            t = ny_time(ms / 1000)
            d = t.date() + dt.timedelta(days=1 if t.hour >= 18 else 0)
            while d.weekday() >= 5:
                d += dt.timedelta(days=1)
            return d
        return tday(lo), tday(hi)

    def chart_view(self, fam=None, day=None, tf_min=5):
        fams = sorted(set(self.db.bar_fams()) | {r["fam"] for r in self.db.rows("SELECT DISTINCT fam FROM bars1")})
        fam = fam if fam in fams else (fams[0] if fams else None)
        if not fam:
            return {"fams": [], "fam": None, "candles": []}
        first, last = self.chart_days(fam)
        d = dt.date.fromisoformat(day) if day else last
        if d.weekday() >= 5:
            d -= dt.timedelta(days=d.weekday() - 4)
        span = {30: 3, 60: 5, 240: 20}.get(int(tf_min), 1)   # große Zeiteinheiten zeigen mehrere Tage
        d0 = d
        for _ in range(span - 1):
            d0 -= dt.timedelta(days=1)
            while d0.weekday() >= 5:
                d0 -= dt.timedelta(days=1)
        a, _ = self._trading_day_bounds(d0)
        _, b = self._trading_day_bounds(d)
        tf = int(tf_min) * 60000
        ctx_a = a - 3 * 86400   # Vorlauf für Vortag, Struktur und Zonen
        m1 = [list(x) for x in self.db.read("SELECT t, o, h, l, c FROM bars1 WHERE fam=? AND t>=? AND t<? ORDER BY t", (fam, ctx_a * 1000, b * 1000))]
        ch = [list(x) for x in self.db.read("SELECT t, o, h, l, c FROM bars WHERE fam=? AND t>=? AND t<? ORDER BY t", (fam, ctx_a * 1000, b * 1000))]
        src = self._tf_of(ch) or 300000
        note = None
        if m1 and (tf < src or len(m1) * 60000 >= len(ch) * src * 0.8):
            allb = self._agg(m1, tf)
            # Lücken in den 1-Minuten-Kerzen mit Chart-Kerzen füllen
            if ch and tf >= src:
                have = {x[0] for x in allb}
                allb = sorted(allb + [x for x in self._agg(ch, tf) if x[0] not in have])
        elif ch:
            if tf < src:
                note = f"Für {tf_min} Minuten fehlen 1-Minuten-Kerzen in diesem Zeitraum – angezeigt wird {round(src / 60000)} Min."
                tf = src
            allb = self._agg(ch, tf) if tf > src else ch
        else:
            allb = []
        # nur fertige Kerzen bis „jetzt“
        allb = [x for x in allb if x[0] < b * 1000]
        k0 = next((i for i, x in enumerate(allb) if x[0] >= a * 1000), len(allb))
        candles = allb[k0:]
        tick = INSTR[fam]["tick"]
        L = self._chart_layers(fam, allb, k0, tf, tick, a, b)
        L["trades"], L["seen"] = self._chart_trades(fam, a, b, tf)
        L["sessions"] = self._chart_sessions(a, b)
        counts = {k: len(v) for k, v in L.items()}
        # Laufende Kerze(n) aus dem Live-Kurs (TradingView schickt ihn, solange ein Trade offen ist)
        forming, live_px = [], None
        lp, lts = self.last_price(fam)
        if candles and time.time() < b + 600:
            start = candles[-1][0] + tf
            prev_c = candles[-1][4]
            for ts, px_ in self.ticks.get(fam, []):
                if ts < start:
                    continue
                bkt = ts - ts % tf
                if forming and forming[-1][0] == bkt:
                    f = forming[-1]
                    f[2], f[3], f[4] = max(f[2], px_), min(f[3], px_), px_
                else:
                    o_ = forming[-1][4] if forming else prev_c
                    forming.append([bkt, o_, max(o_, px_), min(o_, px_), px_])
            if lp is not None and lts and lts * 1000 >= start - tf:
                live_px = {"price": lp, "ts": lts * 1000}
        return {"fams": fams, "fam": fam, "day": str(d), "first": str(first) if first else None, "last": str(last) if last else None,
                "tf": tf // 60000, "candles": candles, "forming": forming, "live_px": live_px, "layers": L, "counts": counts, "note": note, "tick": tick,
                "from": a * 1000, "to": b * 1000, "live": d == last and time.time() < b + 600}

    def _chart_sessions(self, a, b):
        out = []
        day = ny_time(a).date()
        end = ny_time(b).date()
        while day <= end:
            for k, (name, s, e) in TRADING_SESSIONS.items():
                hs, ms = map(int, s.split(":"))
                he, me = map(int, e.split(":"))
                t0 = dt.datetime(day.year, day.month, day.day, hs, ms)
                t1 = dt.datetime(day.year, day.month, day.day, he, me) + (dt.timedelta(days=1) if e <= s else dt.timedelta())
                x0, x1 = self._ny_epoch(t0), self._ny_epoch(t1)
                if x1 > a and x0 < b and t0.weekday() < 5 or (k == "asia" and t0.weekday() == 6 and x1 > a and x0 < b):
                    out.append({"id": f"s-{k}-{day}", "key": k, "name": name, "t0": max(x0, a) * 1000, "t1": min(x1, b) * 1000,
                                "open_t": x0 * 1000})
            day += dt.timedelta(days=1)
        return out

    def _chart_layers(self, fam, bars, k0, tf, tick, a, b):
        """Struktur, Liquidität, Sweeps, Orderblöcke und FVGs – so wie der Bot den Markt liest."""
        n = len(bars)
        out = {"structure": [], "zigzag": [], "breaks": [], "pools": [], "sweeps": [], "ob": [], "fvg": []}
        if n < 10:
            return out
        t = [x[0] for x in bars]
        o = [x[1] for x in bars]
        h = [x[2] for x in bars]
        l = [x[3] for x in bars]
        c = [x[4] for x in bars]
        atr = dc_prepare(o, h, l, c)["atr"]
        start_ms = a * 1000
        end_t = t[-1] + tf
        K = 3 if tf <= 300000 else 2
        # 1) Swings (Pivot links/rechts K Kerzen) → HH/HL/LH/LL und Zickzack
        piv = []
        for i in range(K, n - K):
            if h[i] == max(h[i - K:i + K + 1]) and h[i] > max(h[i - K:i]):
                piv.append([i, "H", h[i]])
            if l[i] == min(l[i - K:i + K + 1]) and l[i] < min(l[i - K:i]):
                piv.append([i, "L", l[i]])
        zz = []
        for p in piv:   # aufeinanderfolgende gleiche Art → nur das Extrem behalten
            if zz and zz[-1][1] == p[1]:
                if (p[1] == "H" and p[2] >= zz[-1][2]) or (p[1] == "L" and p[2] <= zz[-1][2]):
                    zz[-1] = p
            else:
                zz.append(p)
        lastH = lastL = None
        for i, kind, price in zz:
            if kind == "H":
                lab = "HH" if lastH is None or price > lastH else "LH"
                lastH = price
            else:
                lab = "HL" if lastL is None or price > lastL else "LL"
                lastL = price
            if t[i] >= start_ms:
                out["structure"].append({"id": f"sw{t[i]}{kind}", "t": t[i], "p": price, "kind": kind, "label": lab})
        out["zigzag"] = [{"t": t[i], "p": p} for i, _, p in zz if t[i] >= start_ms - 6 * tf]
        # 2) Struktur-Brüche (BOS = mit dem Trend, MSS = Richtungswechsel) und Orderblöcke
        trend = 0
        hs = [(i, p) for i, k, p in zz if k == "H"]
        ls = [(i, p) for i, k, p in zz if k == "L"]
        used_h, used_l = set(), set()
        for j in range(n):
            ch_ = [x for x in hs if x[0] + K < j and x[0] not in used_h]
            cl_ = [x for x in ls if x[0] + K < j and x[0] not in used_l]
            if ch_:
                i, p = ch_[-1]
                if c[j] > p:
                    used_h.update(x[0] for x in ch_)
                    kind = "BOS" if trend >= 0 else "MSS"
                    trend = 1
                    if t[j] >= start_ms:
                        out["breaks"].append({"id": f"br{t[j]}u", "t0": t[i], "t": t[j], "p": p, "dir": 1, "kind": kind})
                    # Orderblock: letzte rote Kerze vor dem Anstieg
                    for q in range(j - 1, max(i - 1, j - 15), -1):
                        if c[q] < o[q]:
                            out["ob"].append(self._zone_life({"id": f"ob{t[q]}u", "t0": t[q], "top": h[q], "bot": l[q], "dir": 1,
                                                              "from_break": kind}, t, h, l, c, q + 1, end_t, tf, "ob"))
                            break
            if cl_:
                i, p = cl_[-1]
                if c[j] < p:
                    used_l.update(x[0] for x in cl_)
                    kind = "BOS" if trend <= 0 else "MSS"
                    trend = -1
                    if t[j] >= start_ms:
                        out["breaks"].append({"id": f"br{t[j]}d", "t0": t[i], "t": t[j], "p": p, "dir": -1, "kind": kind})
                    for q in range(j - 1, max(i - 1, j - 15), -1):
                        if c[q] > o[q]:
                            out["ob"].append(self._zone_life({"id": f"ob{t[q]}d", "t0": t[q], "top": h[q], "bot": l[q], "dir": -1,
                                                              "from_break": kind}, t, h, l, c, q + 1, end_t, tf, "ob"))
                            break
        out["ob"] = [z for z in out["ob"] if z["t1"] >= start_ms]
        # 3) FVGs (3-Kerzen-Lücken ab ¼ der normalen Kerzen-Spanne)
        for i in range(2, n):
            if not atr[i]:
                continue
            if l[i] > h[i - 2] and l[i] - h[i - 2] >= 0.25 * atr[i]:
                out["fvg"].append(self._zone_life({"id": f"fvg{t[i - 1]}u", "t0": t[i - 1], "top": l[i], "bot": h[i - 2], "dir": 1},
                                                  t, h, l, c, i + 1, end_t, tf, "fvg"))
            elif h[i] < l[i - 2] and l[i - 2] - h[i] >= 0.25 * atr[i]:
                out["fvg"].append(self._zone_life({"id": f"fvg{t[i - 1]}d", "t0": t[i - 1], "top": l[i - 2], "bot": h[i], "dir": -1},
                                                  t, h, l, c, i + 1, end_t, tf, "fvg"))
        out["fvg"] = [z for z in out["fvg"] if z["t1"] >= start_ms][-150:]
        # 4) Liquidität: Vortag, Asien, London, Mitternachts-Eröffnung, gleiche Hochs/Tiefs
        def rng(t0, t1):
            idx = [i for i in range(n) if t0 <= t[i] < t1]
            return (max(h[i] for i in idx), min(l[i] for i in idx)) if idx else (None, None)
        day = ny_time(b).date()
        days = sorted({ny_time(x / 1000).date() + dt.timedelta(days=1 if ny_time(x / 1000).hour >= 18 else 0) for x in t if x >= start_ms})
        for dd in days:
            da, db_ = self._trading_day_bounds(dd)
            prev = dd - dt.timedelta(days=1)
            while prev.weekday() >= 5:
                prev -= dt.timedelta(days=1)
            pa, pb = self._trading_day_bounds(prev)
            lv = []
            ph, pl = rng(pa * 1000, pb * 1000)
            lv += [("PDH", ph, 1), ("PDL", pl, -1)]
            pd_ = dd - dt.timedelta(days=1)
            ah, al = rng(self._ny_epoch(dt.datetime(pd_.year, pd_.month, pd_.day, 20)) * 1000, self._ny_epoch(dt.datetime(dd.year, dd.month, dd.day, 0)) * 1000)
            lv += [("Asien-Hoch", ah, 1), ("Asien-Tief", al, -1)]
            lh, ll = rng(self._ny_epoch(dt.datetime(dd.year, dd.month, dd.day, 2)) * 1000, self._ny_epoch(dt.datetime(dd.year, dd.month, dd.day, 5)) * 1000)
            lv += [("London-Hoch", lh, 1), ("London-Tief", ll, -1)]
            for name, price, side in lv:
                if price is None:
                    continue
                if name.startswith("Asien"):
                    t0 = self._ny_epoch(dt.datetime(dd.year, dd.month, dd.day, 0)) * 1000
                elif name.startswith("London"):
                    t0 = self._ny_epoch(dt.datetime(dd.year, dd.month, dd.day, 5)) * 1000
                else:
                    t0 = da * 1000
                if t0 >= db_ * 1000:
                    continue
                out["pools"].append(self._pool_life({"id": f"pl{name}{dd}", "name": name, "p": price, "side": side, "t0": t0,
                                                     "kind": "BSL" if side > 0 else "SSL"}, t, h, l, c, o, db_ * 1000, out["sweeps"]))
            mo = self._ny_epoch(dt.datetime(dd.year, dd.month, dd.day, 0)) * 1000
            k = next((i for i in range(n) if t[i] >= mo), None)
            if k is not None and t[k] < db_ * 1000:
                out["pools"].append({"id": f"mo{dd}", "name": "Mitternachts-Eröffnung", "p": o[k], "side": 0, "t0": t[k],
                                     "t1": min(db_ * 1000, end_t), "kind": "Eröffnung", "swept": None})
        # gleiche Hochs/Tiefs (EQH/EQL): zwei Swings innerhalb von 0,1 × Kerzen-Spanne
        for kind, lst, side in (("EQH", hs, 1), ("EQL", ls, -1)):
            for (i1, p1), (i2, p2) in zip(lst, lst[1:]):
                if t[i2] < start_ms or not atr[i2]:
                    continue
                if abs(p1 - p2) <= max(2 * tick, 0.1 * atr[i2]):
                    p = max(p1, p2) if side > 0 else min(p1, p2)
                    out["pools"].append(self._pool_life({"id": f"eq{t[i2]}{kind}", "name": kind, "p": p, "side": side, "t0": t[i1],
                                                         "kind": kind}, t, h, l, c, o, end_t, out["sweeps"], start=i2 + 1))
        return out

    @staticmethod
    def _zone_life(z, t, h, l, c, start, end_t, tf, kind):
        """Wie lange eine Zone gilt: berührt (mitigiert), durchbrochen (ungültig / bei FVG: invertiert) oder noch offen."""
        z["t1"], z["state"], z["touched"] = end_t, "offen", None
        for j in range(start, len(t)):
            if z["dir"] > 0:
                if z["touched"] is None and l[j] <= z["top"]:
                    z["touched"] = t[j]
                if c[j] < z["bot"]:
                    z["t1"], z["state"] = t[j] + tf, ("invertiert" if kind == "fvg" else "ungültig")
                    break
            else:
                if z["touched"] is None and h[j] >= z["bot"]:
                    z["touched"] = t[j]
                if c[j] > z["top"]:
                    z["t1"], z["state"] = t[j] + tf, ("invertiert" if kind == "fvg" else "ungültig")
                    break
            if kind == "fvg" and z["touched"] is not None and ((z["dir"] > 0 and l[j] <= z["bot"]) or (z["dir"] < 0 and h[j] >= z["top"])):
                z["t1"], z["state"] = t[j] + tf, "gefüllt"
                break
            if t[j] - z["t0"] > 2 * 86400000:
                z["t1"], z["state"] = t[j], "abgelaufen"
                break
        if z["state"] == "offen" and z["touched"]:
            z["state"] = "berührt"
        return z

    @staticmethod
    def _pool_life(pl, t, h, l, c, o, end, sweeps, start=0):
        """Liquiditäts-Level bis zum Sweep (Docht drüber, Schluss zurück) oder Durchbruch."""
        pl["t1"], pl["swept"] = end, None
        for j in range(start, len(t)):
            if t[j] < pl["t0"]:
                continue
            if t[j] >= end:
                break
            if pl["side"] > 0 and h[j] > pl["p"]:
                pl["t1"] = t[j]
                if c[j] < pl["p"]:
                    pl["swept"] = t[j]
                    sweeps.append({"id": f"sw{t[j]}{pl['id']}", "t": t[j], "p": h[j], "level": pl["p"], "name": pl["name"], "dir": -1})
                else:
                    pl["broken"] = t[j]
                break
            if pl["side"] < 0 and l[j] < pl["p"]:
                pl["t1"] = t[j]
                if c[j] > pl["p"]:
                    pl["swept"] = t[j]
                    sweeps.append({"id": f"sw{t[j]}{pl['id']}", "t": t[j], "p": l[j], "level": pl["p"], "name": pl["name"], "dir": 1})
                else:
                    pl["broken"] = t[j]
                break
        return pl

    def _chart_trades(self, fam, a, b, tf):
        trades, seen = [], []
        for p in self.db.rows("SELECT * FROM positions WHERE (opened < ? AND (closed IS NULL OR closed >= ?))", (b, a)):
            if family(p["root"]) != fam or p["broker"] not in (self.broker.name, "eigen") or not p.get("entry"):
                continue
            if p["broker"] == "eigen" and (not p["opened"] or p["opened"] == p["closed"]):
                continue
            t0 = p["opened"] * 1000
            if p.get("bar_time") and abs(p["bar_time"] / 1000 - p["opened"]) < 86400:
                t0 = p["bar_time"] + (self.chart_tf.get(fam) or 300000)
            t1 = (p["closed"] or time.time()) * 1000
            r_ = self._r_of(p) if p["status"] == "geschlossen" else None
            trades.append({"id": p["id"], "t0": t0, "t1": t1, "side": p["side"], "setup": p["setup"], "qty": p["qty"], "root": p["root"],
                           "entry": p["entry"], "exit": p["exit"], "sl0": p.get("initial_sl") or p["sl"], "sl": p["sl"], "tp": p["tp"],
                           "pnl": p["pnl"], "r": round(r_, 2) if r_ is not None else None, "reason": p["close_reason"],
                           "status": p["status"], "broker": p["broker"], "test": bool(p["is_test"]), "mgmt": p.get("mgmt"),
                           "ghost": {"how": p.get("ghost_how"), "r": p.get("ghost_r"), "status": p.get("ghost_status")} if p.get("ghost_status") else None})
        sh = {x["signal_id"]: x for x in self.db.rows("SELECT signal_id, status, r, exit, closed FROM shadow WHERE opened>=? AND opened<?", (a - 3600, b))}
        for s in self.db.rows("SELECT * FROM signals WHERE ts>=? AND ts<? ORDER BY ts", (a, b)):
            if family(s["root"] or fam) != fam or s["status"] == "ausgeführt":
                continue
            x = sh.get(s["id"])
            seen.append({"id": s["id"], "t": (s.get("bar_time") + (self.chart_tf.get(fam) or 300000)) if s.get("bar_time") and abs(s["bar_time"] / 1000 - s["ts"]) < 86400 else s["ts"] * 1000,
                         "side": s["side"], "setup": s["setup"], "entry": s["entry"], "sl": s["sl"], "tp": s["tp"], "status": s["status"],
                         "reason": s["reason"], "test": bool(s["is_test"]),
                         "shadow": {"status": x["status"], "r": x["r"], "exit": x["exit"], "t1": x["closed"] * 1000 if x["closed"] else None} if x else None})
        return trades, seen

    # ───────── Strategie-Finder: neue Einstiege selbst suchen ─────────
    def _disc_path(self):
        return os.path.join(self.data_dir, "strategien.json")

    def _disc_load(self):
        if self.disc is None:
            try:
                with open(self._disc_path(), encoding="utf-8") as f:
                    self.disc = json.load(f)
            except (OSError, ValueError):
                self.disc = {"items": {}, "last_run": None, "tested": 0, "data": {}}
        return self.disc

    def _disc_save(self):
        tmp = self._disc_path() + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(self.disc, f, ensure_ascii=False)
        os.replace(tmp, self._disc_path())

    def _disc_series(self, fam, tf_min, since_ms=0, limit=None):
        """Kerzen einer Zeiteinheit: aus den 1-Minuten-Kerzen gebaut, ergänzt um die Chart-Kerzen."""
        tf_ms = tf_min * 60000
        if limit:
            rows = self.db.read("SELECT t, o, h, l, c FROM bars1 WHERE fam=? AND t>=? ORDER BY t DESC LIMIT ?",
                                (fam, since_ms, limit * tf_min + tf_min))[::-1]
        else:
            rows = self.db.read("SELECT t, o, h, l, c FROM bars1 WHERE fam=? AND t>=? ORDER BY t", (fam, since_ms))
        if tf_min == 1:
            bars = rows
        else:
            # nur vollständige Blöcke (sonst ist die letzte Kerze noch nicht fertig)
            agg = {}
            for t_, o_, h_, l_, c_ in rows:
                b = t_ - t_ % tf_ms
                x = agg.get(b)
                if x is None:
                    agg[b] = [b, o_, h_, l_, c_, 1, t_]
                else:
                    x[2], x[3], x[4], x[5], x[6] = max(x[2], h_), min(x[3], l_), c_, x[5] + 1, t_
            merged = {b: x[:5] for b, x in agg.items() if x[6] >= b + tf_ms - 60000}
            if not limit:
                chart = self.db.read("SELECT t, o, h, l, c FROM bars WHERE fam=? AND t>=? ORDER BY t", (fam, since_ms))
                if chart and (self._tf_of([[x[0]] for x in chart[:200]]) or 0) == tf_ms:
                    for x in chart:
                        merged.setdefault(x[0], list(x))
            bars = [merged[k] for k in sorted(merged)]
            if limit:
                bars = bars[-limit:]
        return [list(col) for col in zip(*bars)] if bars else [[], [], [], [], []]

    @staticmethod
    def _disc_entry_fn(t, tf_ms, chart_ms):
        """Live kommen Kerzen erst zum Schluss der Chart-Kerze an: Einstieg erst dann (wie im echten Betrieb)."""
        if tf_ms >= chart_ms:
            return lambda i: i
        nxt = [None] * len(t)
        for i in range(len(t) - 1, -1, -1):
            if (t[i] + tf_ms) % chart_ms == 0:
                nxt[i] = i
            elif i + 1 < len(t) and nxt[i + 1] is not None and t[nxt[i + 1]] - t[i] < chart_ms:
                nxt[i] = nxt[i + 1]
        return lambda i: nxt[i]

    def _disc_ctx(self, fam, tf_min, series):
        t, o, h, l, c = series
        chart_ms = self.chart_tf.get(fam) or 300000
        sess_cache = {}

        def sess_of(ts):
            k = ts // 60000
            if k not in sess_cache:
                sess_cache[k] = session_of(ny_time(ts / 1000))
            return sess_cache[k]
        return {"P": dc_prepare(o, h, l, c, t, lambda ms: ny_time(ms / 1000)), "entry": self._disc_entry_fn(t, tf_min * 60000, chart_ms), "sess_of": sess_of,
                "cost": lambda entry, risk: self._cost_r(fam, entry, risk), "min_stop": float(self.cfg["safe_stop"][fam]["min"]),
                "tick": INSTR[fam]["tick"], "hold": 60 if tf_min == 1 else 36}

    def _disc_trades(self, it, series, ctx):
        t, o, h, l, c = series
        sigs = dc_detect(it["det"], it["n"], it["k"], o, h, l, c, ctx["P"], ctx["tick"])
        tr = dc_simulate(sigs, o, h, l, c, t, it["tf"] * 60000, ctx["entry"], ctx["cost"], ctx["min_stop"], ctx["hold"])
        return dc_evaluate(tr, ctx["sess_of"], DC_TPS.index(it["tp"]), it["d"], it["sess"])

    def disc_run(self):
        """Durchsucht alle gespeicherten Kerzen nach neuen Strategien (läuft im Hintergrund, 1–3 Minuten)."""
        if self.disc_state.get("busy"):
            return
        self.disc_state.update(busy=True, step="Lade Kursdaten", done=0, total=0, error="")
        try:
            D = self._disc_load()
            items = D.setdefault("items", {})
            found, tested, data = [], 0, {}
            fams = self.db.bar_fams() or [r["fam"] for r in self.db.rows("SELECT DISTINCT fam FROM bars1")]
            plan = [(fam, tf) for fam in fams for tf in (1, 5)]
            combos = sum(len(v["N"]) * len(v["K"]) for v in DC_DETECTORS.values())
            self.disc_state["total"] = len(plan) * combos
            since = (time.time() - 400 * 86400) * 1000   # gut 1 Jahr: genug Trades, aber Rechenzeit und Speicher im Rahmen
            for fam, tf in plan:
                series = self._disc_series(fam, tf, since_ms=since)
                t = series[0]
                days = len({str(ny_date(x / 1000)) for x in t[::max(1, 60 // tf)]})
                data[f"{fam} {tf}m"] = {"bars": len(t), "days": days,
                                         "from": t[0] if t else None, "to": t[-1] if t else None}
                need = 3000 if tf == 1 else 1500
                if len(t) < need:
                    self.disc_state["done"] += combos
                    continue
                ctx = self._disc_ctx(fam, tf, series)
                _, o, h, l, c = series
                for det, spec in DC_DETECTORS.items():
                    for n in spec["N"]:
                        for k in spec["K"]:
                            self.disc_state.update(step=f"{fam} {tf} Min · {spec['name']}", done=self.disc_state["done"] + 1)
                            sigs = dc_detect(det, n, k, o, h, l, c, ctx["P"], ctx["tick"])
                            trs = dc_simulate(sigs, o, h, l, c, t, tf * 60000, ctx["entry"], ctx["cost"], ctx["min_stop"], ctx["hold"])
                            if len(trs) < 40:
                                continue
                            for x, tp in enumerate(DC_TPS):
                                for d in (1, -1):
                                    for sess in ("alle", "asia", "london", "ny_am", "ny_lunch", "ny_pm"):
                                        ev = dc_evaluate(trs, ctx["sess_of"], x, d, sess)
                                        if len(ev) < 40:
                                            continue
                                        tested += 1
                                        rs = [r for _, r in ev]
                                        st = dc_stats(rs)
                                        k6 = int(len(rs) * 0.6)
                                        s1, s2 = dc_stats(rs[:k6]), dc_stats(rs[k6:])
                                        if st["avg"] >= 0.08 and st["t"] >= 2.0 and s1["avg"] > 0 and s2["avg"] > 0.03 and s2["n"] >= 15:
                                            weeks = max(1.0, (ev[-1][0] - ev[0][0]) / 86400000 / 7)
                                            cum, curve = 0.0, []
                                            step = max(1, len(rs) // 60)
                                            for idx, r in enumerate(rs):
                                                cum += r
                                                if idx % step == 0 or idx == len(rs) - 1:
                                                    curve.append(round(cum, 2))
                                            found.append({
                                                "id": f"{fam}-{det}-{tf}-{n}-{k}-{d}-{sess}-{tp}", "fam": fam, "det": det, "tf": tf, "n": n, "k": k,
                                                "d": d, "sess": sess, "tp": tp, "name": dc_name_of(det, tf, d, sess),
                                                "desc": dc_describe(det, n, k, tf, d, tp),
                                                "stats": {"n": st["n"], "avg": round(st["avg"], 3), "wr": round(st["wr"], 1),
                                                          "pf": round(st["pf"], 2) if st["pf"] else None, "t": round(st["t"], 2),
                                                          "avg1": round(s1["avg"], 3), "avg2": round(s2["avg"], 3), "n2": s2["n"],
                                                          "per_week": round(st["n"] / weeks, 1)},
                                                "curve": curve})
            # beste je Muster/Zeiteinheit/Richtung/Session, höchstens 3 je Muster-Art, insgesamt 25
            found.sort(key=lambda x: -x["stats"]["t"])
            seen, per_det, top = set(), {}, []
            for f in found:
                key = (f["fam"], f["det"], f["tf"], f["d"], f["sess"])
                same_tr = (f["fam"], f["det"], f["tf"], f["d"], f["stats"]["n"], f["stats"]["avg"])   # z. B. ORB „ganztags“ = „NY-Vorm.“
                if key in seen or same_tr in seen or per_det.get(f["det"], 0) >= 3:
                    continue
                seen.add(key)
                seen.add(same_tr)
                per_det[f["det"]] = per_det.get(f["det"], 0) + 1
                top.append(f)
                if len(top) >= 25:
                    break
            now = time.time()
            # Mitlernen: Gibt es für eine laufende Strategie inzwischen eine klar bessere Einstellung desselben Musters?
            for it in list(items.values()):
                if it["status"] not in ("aktiv", "probe") or it.get("succ"):
                    continue
                same = [f for f in found if (f["fam"], f["det"], f["tf"], f["d"], f["sess"]) == (it["fam"], it["det"], it["tf"], it["d"], it["sess"])
                        and f["id"] != it["id"] and f["id"] not in items]
                if not same:
                    continue
                b = max(same, key=lambda f: f["stats"]["t"])
                if b["stats"]["t"] >= it["stats"]["t"] + 0.5 and b["stats"]["avg"] >= it["stats"]["avg"] + 0.08:
                    ver = it.get("ver", 1) + 1
                    items[b["id"]] = dict(b, name=f"{it['name'][:35]} v{ver}", ver=ver, parent=it["id"], status="probe",
                                          found_at=now, promoted_at=now, auto=True)
                    it["succ"] = b["id"]
                    self.db.log(f"Lernmodul (automatisch): Strategie-Finder – verbesserte Einstellung für {it['name']} gefunden, startet als "
                                f"„{items[b['id']]['name']}“ den Probelauf (Ø {_fmt(b['stats']['avg'], '+.2f')} statt {_fmt(it['stats']['avg'], '+.2f')} R)")
            for f in top:
                old = items.get(f["id"])
                if old and old["status"] != "gefunden":
                    old.update(stats=f["stats"], curve=f["curve"], desc=f["desc"])
                else:
                    items[f["id"]] = dict(f, status="gefunden", found_at=(old or {}).get("found_at") or now)
            fresh = {f["id"] for f in top}
            for iid in [i for i, v in items.items() if v["status"] == "gefunden" and i not in fresh]:
                del items[iid]   # nicht mehr unter den besten: aus der Liste nehmen
            self.disc_state["step"] = "Probelauf auswerten"
            self._disc_forward(items)
            D.update(last_run=now, tested=tested, data=data, combos=len(plan) * combos)
            if self.cfg["learning"].get("auto_adopt", True):
                with self.lock:
                    self._disc_auto(items)
            self._disc_save()
            self.db.log(f"Strategie-Finder: {tested:,} Varianten geprüft, {len(top)} vielversprechend".replace(",", "."))
        except Exception as e:  # noqa: BLE001
            self.disc_state["error"] = str(e)
            self.db.log(f"Strategie-Finder fehlgeschlagen: {e}", "warn")
        finally:
            self.disc_state.update(busy=False, step="")

    def _disc_forward(self, items):
        """Probelauf: Ergebnis nur auf Kerzen NACH dem Fund – der ehrliche Test gegen Zufallstreffer."""
        cache = {}
        for it in items.values():
            if it["status"] not in ("probe", "aktiv", "bereit"):
                continue
            key = (it["fam"], it["tf"])
            if key not in cache:
                ser = self._disc_series(it["fam"], it["tf"])
                cache[key] = (ser, self._disc_ctx(it["fam"], it["tf"], ser))
            ser, ctx = cache[key]
            ev = [r for ts, r in self._disc_trades(it, ser, ctx) if ts >= (it.get("promoted_at") or it["found_at"]) * 1000]
            st = dc_stats(ev)
            it["fwd"] = {"n": len(ev), "avg": round(st["avg"], 3) if st else None, "wr": round(st["wr"], 1) if st else None,
                         "t": round(st["t"], 2) if st else None, "sum": round(sum(ev), 2)}

    def _disc_auto(self, items):
        probe = [i for i in items.values() if i["status"] == "probe"]
        for it in sorted((i for i in items.values() if i["status"] == "gefunden" and i["stats"]["t"] >= 2.5),
                         key=lambda i: -i["stats"]["t"]):
            if len(probe) >= 6:
                break
            it.update(status="probe", promoted_at=time.time(), auto=True)
            probe.append(it)
            self.db.log(f"Lernmodul (automatisch): Strategie-Finder – {it['name']} startet den Probelauf")
        for it in items.values():
            f = it.get("fwd") or {}
            if it["status"] in ("probe", "aktiv", "bereit") and f.get("n", 0) >= 20 and (f.get("avg") or 0) <= 0:
                was = it["status"]
                it.update(status="verworfen", dropped_at=time.time())
                if was == "aktiv":
                    self.cfg["setup_rules"][it["name"]] = "aus"
                    self._write_cfg(self.cfg)
                self.db.log(f"Lernmodul (automatisch): Strategie-Finder – {it['name']} verworfen "
                            f"(Probelauf {f['n']} Trades, Ø {_fmt(f['avg'] or 0, '+.2f')} R)")
            elif it["status"] == "probe" and f.get("n", 0) >= 20 and f["avg"] >= 0.1 and (f.get("t") or 0) >= 1.0:
                if self.broker.name == "paper":
                    self._disc_activate(it)
                    self.db.log(f"Lernmodul (automatisch): Strategie-Finder – {it['name']} handelt ab jetzt mit "
                                f"(Probelauf {f['n']} Trades, Ø {_fmt(f['avg'], '+.2f')} R)")
                else:
                    it["status"] = "bereit"
                    self.db.log(f"Strategie-Finder: {it['name']} hat den Probelauf bestanden – Freigabe für den Echtgeld-Broker im Lernmodul")

    def _disc_activate(self, it):
        it.update(status="aktiv", activated_at=time.time())
        self.cfg["setup_rules"][it["name"]] = "auto"
        par = (self.disc or {}).get("items", {}).get(it.get("parent") or "")
        if par and par["status"] in ("aktiv", "probe", "bereit"):   # die verbesserte Version löst die alte ab
            if par["status"] == "aktiv":
                self.cfg["setup_rules"][par["name"]] = "aus"
            par.update(status="verworfen", dropped_at=time.time(), replaced_by=it["id"])
            self.db.log(f"Strategie-Finder: {it['name']} löst {par['name']} ab")
        self._write_cfg(self.cfg)

    def disc_action(self, iid, action):
        with self.lock:
            D = self._disc_load()
            it = D["items"].get(iid)
            if not it:
                raise ValueError("Strategie nicht gefunden")
            if action == "probe":
                it.update(status="probe", promoted_at=time.time(), auto=False, fwd=None)
            elif action == "activate":
                self._disc_activate(it)
            elif action == "deactivate":
                it["status"] = "probe"
                self.cfg["setup_rules"][it["name"]] = "aus"
                self._write_cfg(self.cfg)
            elif action == "discard":
                if it["status"] == "aktiv":
                    self.cfg["setup_rules"][it["name"]] = "aus"
                    self._write_cfg(self.cfg)
                it.update(status="verworfen", dropped_at=time.time())
            else:
                raise ValueError("Unbekannte Aktion")
            self._disc_save()
            return {"ok": True}

    def disc_view(self):
        D = self._disc_load()
        bundle = getattr(self, "last_bundle", 1)
        return {"items": list(D.get("items", {}).values()), "last_run": D.get("last_run"), "tested": D.get("tested", 0),
                "data": D.get("data", {}), "state": dict(self.disc_state), "detectors": {k: v["name"] for k, v in DC_DETECTORS.items()},
                "bundle": bundle, "chart_tf": {k: v / 60000 for k, v in self.chart_tf.items()}, "broker": self.broker.name}

    def disc_async(self):
        if not self.disc_state.get("busy"):
            threading.Thread(target=self.disc_run, daemon=True).start()

    def _disc_live(self, fam):
        """Aktive gefundene Strategien: Signal prüfen, sobald frische Kerzen da sind, und wie ein TradingView-Signal behandeln."""
        D = self.disc
        if not D:
            return
        act = [i for i in D.get("items", {}).values() if i["status"] == "aktiv" and i["fam"] == fam]
        if not act:
            return
        now_ms = time.time() * 1000
        chart_ms = self.chart_tf.get(fam) or 300000
        for tf in sorted({i["tf"] for i in act}):
            ser = self._disc_series(fam, tf, since_ms=now_ms - 4 * 86400000, limit=2000 if tf == 1 else 600)
            t, o, h, l, c = ser
            if len(t) < 100 or t[-1] + tf * 60000 < now_ms - 150000:
                continue   # keine frischen Kerzen (z. B. gebündelt): lieber kein Signal als ein veraltetes
            ctx = self._disc_ctx(fam, tf, ser)
            last = len(t) - 1
            for it in (i for i in act if i["tf"] == tf):
                for i, d, stop in dc_detect(it["det"], it["n"], it["k"], o, h, l, c, ctx["P"], ctx["tick"], start=max(0, last - 120)):
                    if d != it["d"] or ctx["entry"](i) != last:
                        continue
                    if it["sess"] != "alle" and ctx["sess_of"](t[last]) != it["sess"]:
                        continue
                    key = (it["id"], t[i])
                    if key in self._disc_sent:
                        continue
                    self._disc_sent.add(key)
                    entry = c[last]
                    risk = (entry - stop) * d
                    if risk < ctx["min_stop"]:
                        continue
                    self.db.log(f"Strategie-Finder: Signal {it['name']}")
                    self._on_entry({"action": "buy" if d > 0 else "sell", "ticker": fam, "price": entry, "stopLoss": stop,
                                    "takeProfit": entry + d * it["tp"] * risk, "setup": it["name"],
                                    "time": t[last] + tf * 60000 - chart_ms})

    def import_ohlc(self, fam, text):
        """Kursdaten einlesen: TradingView-Export, Databento-CSV oder NinjaTrader-Export, 1- oder 5-Minuten-Kerzen."""
        import csv
        import io
        if fam not in ("NQ", "ES"):
            raise ValueError("Bitte NQ oder ES wählen")
        sample = text[:5000]
        delim = ";" if sample.count(";") > sample.count(",") else "\t" if sample.count("\t") > sample.count(",") else ","
        def reader():   # Zeile für Zeile, damit große Dateien wenig Speicher brauchen
            return csv.reader(io.StringIO(text), delimiter=delim)
        first = next(reader(), None)
        if not first:
            raise ValueError("Datei ist leer")
        head = [x.strip().lower() for x in first]
        out = []

        def fnum(v):
            v = v.strip()
            if delim == ";" and "," in v:
                v = v.replace(".", "").replace(",", ".")
            f = float(v)
            return f / 1e9 if f > 1e7 else f   # Databento ohne „pretty prices“: Festkomma ×1e9

        def berlin_to_utc(x):
            # NinjaTrader exportiert in PC-Zeit (hier Deutschland): MEZ/MESZ ohne Zeitzonen-Datenbank umrechnen
            y = x.year
            last_sun = lambda m: max(dt.date(y, m, d) for d in range(25, 32) if dt.date(y, m, d).weekday() == 6)  # noqa: E731
            dst = dt.datetime.combine(last_sun(3), dt.time(2)) <= x < dt.datetime.combine(last_sun(10), dt.time(3))
            return x - dt.timedelta(hours=2 if dst else 1)

        def parse_ts(ts):
            ts = ts.strip()
            if ts[:1].isdigit() and ts.replace(".", "", 1).isdigit():
                v = float(ts)
                return v / 1e6 if v > 1e17 else v if v > 1e11 else v * 1000   # Nanosekunden / ms / s
            if len(ts) >= 19 and ts[10] in "T " and ts.endswith("Z"):   # schneller Weg für Databento/UTC
                return dt.datetime(int(ts[0:4]), int(ts[5:7]), int(ts[8:10]), int(ts[11:13]), int(ts[14:16]), int(ts[17:19]),
                                   tzinfo=dt.timezone.utc).timestamp() * 1000
            x = dt.datetime.fromisoformat(re.sub(r"\.\d+", "", ts.replace("Z", "+00:00")).replace(" ", "T", 1))
            if x.tzinfo is None:
                x = x.replace(tzinfo=dt.timezone.utc)
            return x.timestamp() * 1000

        tcol = next((head.index(x) for x in ("ts_event", "time", "datetime", "date", "timestamp") if x in head), None)
        if tcol is not None and all(x in head for x in ("open", "high", "low", "close")):
            io_, ih, il, ic = (head.index(x) for x in ("open", "high", "low", "close"))
            sym = head.index("symbol") if "symbol" in head else None
            main = None
            if sym is not None:
                # 1. Durchgang: je Tag den Kontrakt mit den meisten Kerzen bestimmen (Spreads auslassen)
                cnt = {}
                it_ = reader()
                next(it_, None)
                for r in it_:
                    if len(r) <= sym or "-" in r[sym]:
                        continue
                    k = (r[tcol][:10], r[sym])
                    cnt[k] = cnt.get(k, 0) + 1
                main = {}
                for (d_, sname), n_ in cnt.items():
                    if n_ > main.get(d_, ("", 0))[1]:
                        main[d_] = (sname, n_)
                main = {d_: v[0] for d_, v in main.items()}
            it_ = reader()
            next(it_, None)
            for r in it_:
                try:
                    if main is not None and main.get(r[tcol][:10]) != r[sym]:
                        continue
                    out.append([parse_ts(r[tcol]), fnum(r[io_]), fnum(r[ih]), fnum(r[il]), fnum(r[ic])])
                except (ValueError, IndexError):
                    continue
        else:
            # NinjaTrader-Export ohne Kopfzeile: yyyyMMdd HHmmss;open;high;low;close;volume (Zeit = Ende der Kerze)
            for r in reader():
                try:
                    x = dt.datetime.strptime(r[0].strip(), "%Y%m%d %H%M%S")
                    utc = berlin_to_utc(x)
                    ms = utc.replace(tzinfo=dt.timezone.utc).timestamp() * 1000
                    out.append([ms, fnum(r[1]), fnum(r[2]), fnum(r[3]), fnum(r[4])])
                except (ValueError, IndexError):
                    continue
            if not out:
                raise ValueError("Format nicht erkannt. Unterstützt: TradingView-Export, Databento-CSV (OHLCV-1m) und NinjaTrader-Export.")
            tf_ = self._tf_of(sorted(out)) or 60000
            out = [[r[0] - tf_] + r[1:] for r in out]   # NinjaTrader stempelt das Kerzen-Ende
        out.sort()
        if len(out) < 50:
            raise ValueError("Keine Kerzen erkannt")
        tf = self._tf_of(out)
        if tf == 60000:
            for i in range(0, len(out), 2000):
                self.db.add_bars1(fam, out[i:i + 2000])
            kind = "1-Minuten-Kerzen"
        elif tf == 300000:
            for x in out:
                self.db.add_bar(fam, *x)
            kind = "5-Minuten-Kerzen"
        else:
            raise ValueError(f"Die Datei hat {round((tf or 0) / 60000)}-Minuten-Kerzen. Bitte den Chart auf 1 oder 5 Minuten stellen und neu exportieren.")
        days = len({str(ny_date(x[0] / 1000)) for x in out})
        self.db.log(f"Kursdaten importiert: {len(out):,} {kind} ({days} Handelstage) für {fam}".replace(",", "."))
        return {"ok": True, "bars": len(out), "kind": kind, "days": days,
                "from": out[0][0], "to": out[-1][0]}

    # ───────── Tageszusammenfassung, Timeline, Tages-Stopp ─────────
    @staticmethod
    def _r_of(p):
        if not p.get("initial_sl") or p.get("pnl") is None or p["entry"] == p["initial_sl"]:
            return None
        pv = INSTR.get(p["root"], {"pv": 1})["pv"]
        return p["pnl"] / (abs(p["entry"] - p["initial_sl"]) * (p["qty"] or 1) * pv)

    @staticmethod
    def _reason_cat(reason):
        r = reason or ""
        for key, label in (("News", "News-Pause"), ("Lernmodul", "Lernmodul-Pause"), ("ausgeschaltet", "Strategie aus"),
                           ("Regel-Finder", "Regel-Finder"), ("Fremdkapital", "Fremdkapital-Schutz"),
                           ("Session", "Außerhalb Session"), ("Tagesziel", "Tages-Stopp"), ("Tagesverlust", "Tages-Stopp"),
                           ("Trades pro Tag", "Max. Trades"), ("offener Positionen", "Max. Positionen"),
                           ("pausiert", "Handel pausiert"), ("zu weit", "Stop zu weit")):
            if key in r:
                return label
        return "Sonstiges"

    def _bot_closed(self, since=0, until=None):
        until = until or time.time() + 1
        return [p for p in self.db.closed_positions()
                if p["broker"] == self.broker.name and not p["is_test"] and since <= (p["closed"] or 0) < until]

    def daystop(self):
        """Tages-Stopp: Tagesziel oder Tagesverlust erreicht → heute keine neuen Trades."""
        r = self.cfg["risk"]
        pnl = self.today_pnl()
        goal, loss = float(r.get("daily_profit_stop") or 0), float(r.get("max_daily_loss") or 0)
        if goal > 0 and pnl >= goal:
            return {"hit": "ziel", "text": f"Tagesziel erreicht ({_fmt(pnl, '+,.0f')} $) – heute keine neuen Trades", "pnl": pnl}
        if loss > 0 and pnl <= -loss:
            return {"hit": "verlust", "text": f"Tagesverlust-Limit erreicht ({_fmt(pnl, '+,.0f')} $) – heute keine neuen Trades", "pnl": pnl}
        return {"hit": None, "pnl": pnl, "goal": goal, "loss": loss}

    def _check_daystop(self):
        ds = self.daystop()
        today = str(ny_date())
        if not ds["hit"] or self._daystop_day == today:
            return
        self._daystop_day = today
        self.learning["daystop_day"] = today   # merkt sich den Stopp über einen Neustart hinweg
        try:
            with open(self.learn_path, "w", encoding="utf-8") as fh:
                json.dump(self.learning, fh, indent=2, ensure_ascii=False)
        except OSError:
            pass
        self.db.log(ds["text"], "warn")
        closed = 0
        if self.cfg["risk"].get("daily_stop_close"):
            for pos in self.db.open_positions():
                if pos["broker"] == self.broker.name:
                    try:
                        self._close(pos, None, "Tages-Stopp")
                        closed += 1
                    except ValueError:
                        pass
        self.notify("daystop", "Tages-Stopp", ds["text"] + (f"\n{closed} offene Position(en) geschlossen." if closed else ""),
                    "good" if ds["hit"] == "ziel" else "bad")

    def summary(self):
        start = self._ny_day_start()
        closed = self._bot_closed(start)
        rs = [x for x in (self._r_of(p) for p in closed) if x is not None]
        opens = [p for p in self.db.open_positions() if p["broker"] == self.broker.name]
        sigs = [s for s in self.db.rows("SELECT status, reason, is_test FROM signals WHERE ts>=?", (start,)) if not s["is_test"]]
        blocked = {}
        for s in sigs:
            if s["status"] == "blockiert":
                k = self._reason_cat(s["reason"])
                blocked[k] = blocked.get(k, 0) + 1
        ds = self.daystop()
        own = [t for t in self._calendar_trades() if t["source"] == "eigen" and t["day"] == str(ny_date())]
        return {"n": len(closed), "wins": sum(1 for p in closed if p["pnl"] > 0), "losses": sum(1 for p in closed if p["pnl"] <= 0),
                "realized": round(sum(p["pnl"] for p in closed), 2), "upnl": round(sum(self._unrealized(p) for p in opens), 2),
                "r": round(sum(rs), 2) if rs else 0.0, "open": len(opens), "signals": len(sigs),
                "executed": sum(1 for s in sigs if s["status"] == "ausgeführt"), "blocked": blocked,
                "own_n": len(own), "own_pnl": round(sum(t["pnl"] or 0 for t in own), 2),
                "daystop": ds, "daystop_close": bool(self.cfg["risk"].get("daily_stop_close"))}

    def _ny_day_start(self, day=None):
        """Unix-Zeit von 00:00 New York an einem Datum (Standard: heute)."""
        import calendar
        d = day or ny_date()
        t = calendar.timegm((d.year, d.month, d.day, 4, 0, 0)) - 3600   # 03:00 UTC, dann vorwärts bis NY-Mitternacht
        while ny_date(t) < d:
            t += 900
        return t

    def timeline(self, day=None):
        """Alle Signale eines Tages mit Entscheidung, Grund und Ergebnis (auch, was geblockte gebracht hätten)."""
        d = dt.date.fromisoformat(day) if day else ny_date()
        a = self._ny_day_start(d)
        b = a + 86400 + 3600
        sigs = self.db.rows("SELECT id, ts, root, side, setup, entry, sl, tp, qty, risk_usd, flags, status, reason, is_test, mgmt "
                            "FROM signals WHERE ts>=? AND ts<? ORDER BY ts", (a, b))
        sigs = [s for s in sigs if ny_date(s["ts"]) == d]
        pos = {p["signal_id"]: p for p in self.db.rows(
            "SELECT signal_id, status, exit, pnl, close_reason, entry, initial_sl, qty, root, closed FROM positions WHERE opened>=? AND opened<?", (a, b))}
        sh = {x["signal_id"]: x for x in self.db.rows("SELECT signal_id, status, r FROM shadow WHERE opened>=? AND opened<?", (a, b))}
        out = []
        for s in sigs:
            try:
                s["flags"] = json.loads(s["flags"]) if s["flags"] else []
            except ValueError:
                s["flags"] = []
            p = pos.get(s["id"])
            if p:
                s["pos"] = {"status": p["status"], "exit": p["exit"], "pnl": p["pnl"], "reason": p["close_reason"],
                            "r": round(self._r_of(p), 2) if self._r_of(p) is not None else None}
            x = sh.get(s["id"])
            if x:
                s["shadow"] = {"status": x["status"], "r": x["r"]}
            if s["status"] == "blockiert":
                s["cat"] = self._reason_cat(s["reason"])
            out.append(s)
        return {"day": str(d), "items": out}

    # ───────── Discord ─────────
    def notify(self, kind, title, text, tone="info"):
        dc = self.cfg.get("discord") or {}
        if not dc.get("enabled") or not dc.get("url") or (kind != "test" and not dc.get(kind, True)):
            return
        key = (kind, title, text)
        now = time.time()
        if kind == "errors" and now - self._notified.get(key, 0) < 1800:
            return   # gleiche Fehlermeldung höchstens alle 30 Minuten
        self._notified[key] = now
        if len(self.outbox) < 200:
            self.outbox.append({"title": title, "text": text, "tone": tone, "ts": now})

    def _on_log(self, text, level):
        if level == "error":
            self.notify("errors", "Fehler", text, "bad")
        elif text.startswith("Lernmodul (automatisch)") or (text.startswith("Lernmodul:") and "→" in text):
            self.notify("learn", "Lernmodul", text.split(": ", 1)[-1], "info")

    def _check_silence(self):
        dc = self.cfg.get("discord") or {}
        mins = float(dc.get("silence_min") or 0)
        if mins <= 0 or not self.last_msg:
            return
        now = time.time()
        quiet = now - self.last_msg > mins * 60
        if quiet and not self._silent and market_open(ny_time()) and market_open(ny_time(now - mins * 60)):
            self._silent = True
            self.notify("silence", "TradingView schweigt",
                        f"Seit {round((now - self.last_msg) / 60)} Minuten kam keine Nachricht von TradingView, obwohl der Markt offen ist. "
                        "Prüfe den Alert in TradingView (abgelaufen, gelöscht oder pausiert?).", "bad")
        elif not quiet and self._silent:
            self._silent = False
            self.notify("silence", "TradingView wieder da", "Es kommen wieder Nachrichten von TradingView an.", "good")

    def day_report_text(self):
        s = self.summary()
        lines = [f"**{s['n']} Trades** · {s['wins']} Gewinner / {s['losses']} Verlierer",
                 f"Ergebnis: **{_fmt(s['realized'], '+,.0f')} $** ({_fmt(s['r'], '+.2f')} R)"]
        if s["signals"]:
            lines.append(f"Signale: {s['signals']} · ausgeführt {s['executed']}" +
                         (" · geblockt: " + ", ".join(f"{k} {v}" for k, v in s["blocked"].items()) if s["blocked"] else ""))
        if s["open"]:
            lines.append(f"Noch offen: {s['open']} Position(en), {_fmt(s['upnl'], '+,.0f')} $")
        if self.cfg["challenge"]["enabled"]:
            c = self.challenge()
            lines.append(f"Fremdkapital: {_fmt(c['buffer'], ',.0f')} $ Puffer bis zur Verlustgrenze · noch {_fmt(c['to_target'], ',.0f')} $ bis zum Ziel")
        return "\n".join(lines)

    # ───────── Gesundheits-Check ─────────
    def health(self):
        now = time.time()
        items = []
        t = ny_time()
        mo = market_open(t)
        tf = max(self.chart_tf.values() or [300000]) / 1000
        if not self.last_msg:
            items.append(("tv", "TradingView", "bad" if market_open(t) else "off", "Seit dem Start der App noch keine Nachricht"))
        else:
            age = now - self.last_msg
            txt = f"Letzte Nachricht vor {_ago(age)}"
            st = "ok" if age < tf * 3 + 300 else ("off" if not mo else "warn" if age < 2400 else "bad")   # Kerzen kommen ggf. gebündelt (alle 15 Min)
            if not mo and st != "ok":
                txt += " · Markt geschlossen"
            items.append(("tv", "TradingView", st, txt))
        ai = getattr(self, "alert_issue", None)
        if ai:
            items.append(("alert", "Alert-Einstellung", "bad", str(ai.get("text") if isinstance(ai, dict) else ai)[:140]))
        if self.broker.name == "paper":
            items.append(("broker", "Broker", "ok", "Paper-Trading (simuliert)"))
        else:
            items.append(("broker", self.broker.label, "ok" if self.broker_ok else "bad", "verbunden" if self.broker_ok else (self.broker_status or "nicht verbunden")))
        lt = now - self._last_loop
        items.append(("loop", "Hintergrund", "ok" if lt < 20 else "bad", "läuft" if lt < 20 else f"hängt seit {_ago(lt)}"))
        try:
            import shutil
            free = shutil.disk_usage(self.data_dir).free / 1e9
            size = os.path.getsize(os.path.join(self.data_dir, "trader.db")) / 1e6
            items.append(("disk", "Speicher", "ok" if free > 2 else "warn" if free > 0.5 else "bad",
                          f"{_fmt(free, ',.1f')} GB frei · Datenbank {_fmt(size, ',.0f')} MB"))
        except OSError:
            pass
        dc = self.cfg.get("discord") or {}
        if dc.get("enabled") and dc.get("url"):
            ds = self.discord_state
            st = "bad" if ds.get("error") else "ok"
            items.append(("discord", "Discord", st, ds.get("error") or (f"zuletzt gesendet vor {_ago(now - ds['last'])}" if ds.get("last") else "bereit")))
        ds = self.daystop()
        if ds["hit"]:
            items.append(("daystop", "Tages-Stopp", "warn", ds["text"]))
        return [{"key": k, "label": l, "status": s, "text": x} for k, l, s, x in items]

    # ───────── Wochenbericht ─────────
    def weekly_report(self, offset=0):
        today = ny_date()
        monday = today - dt.timedelta(days=today.weekday()) - dt.timedelta(weeks=int(offset))
        a = self._ny_day_start(monday)
        b = a + 7 * 86400
        pa = a - 7 * 86400
        trades = [p for p in self._bot_closed(a, b)]
        prev = self._bot_closed(pa, a)
        rs = [self._r_of(p) for p in trades]
        wins = [p for p in trades if p["pnl"] > 0]
        gp, gl = sum(p["pnl"] for p in wins), -sum(p["pnl"] for p in trades if p["pnl"] <= 0)
        days = {}
        for p in trades:
            d = str(ny_date(p["closed"]))
            x = days.setdefault(d, {"day": d, "n": 0, "pnl": 0.0})
            x["n"] += 1
            x["pnl"] = round(x["pnl"] + p["pnl"], 2)
        by_setup, by_sess = {}, {}
        for p, r in zip(trades, rs):
            for key, bucket in ((p["setup"] or "–", by_setup), (SESSION_NAMES.get(session_of(ny_time(p["opened"])), "außerhalb"), by_sess)):
                x = bucket.setdefault(key, {"n": 0, "w": 0, "pnl": 0.0, "r": 0.0})
                x["n"] += 1
                x["w"] += p["pnl"] > 0
                x["pnl"] = round(x["pnl"] + p["pnl"], 2)
                x["r"] = round(x["r"] + (r or 0), 2)
        sigs = [s for s in self.db.rows("SELECT id, status, reason, setup, is_test FROM signals WHERE ts>=? AND ts<?", (a, b)) if not s["is_test"]]
        shr = {x["signal_id"]: x["r"] for x in self.db.rows("SELECT signal_id, r FROM shadow WHERE opened>=? AND opened<? AND r IS NOT NULL", (a, b))}
        blocked = {}
        for s in sigs:
            if s["status"] == "blockiert":
                k = self._reason_cat(s["reason"])
                x = blocked.setdefault(k, {"n": 0, "r": 0.0, "known": 0})
                x["n"] += 1
                if s["id"] in shr:
                    x["r"] = round(x["r"] + shr[s["id"]], 2)
                    x["known"] += 1
        all_r = [shr[s["id"]] for s in sigs if s["id"] in shr]
        learn = [x for x in (self.learning.get("auto_log") or []) if a <= x["t"] < b]
        own = [t for t in self._calendar_trades() if t["source"] == "eigen" and str(monday) <= t["day"] < str(monday + dt.timedelta(days=7))]
        net, pnet = gp - gl, sum(p["pnl"] for p in prev)
        hl = []
        if trades:
            hl.append(f"{len(trades)} Trades, {len(wins)} Gewinner ({_fmt(len(wins) / len(trades) * 100, '.0f')} %), netto {_fmt(net, '+,.0f')} $"
                      + (f" – {'besser' if net > pnet else 'schwächer'} als letzte Woche ({_fmt(pnet, '+,.0f')} $)" if prev else ""))
            best = max(trades, key=lambda p: p["pnl"])
            worst = min(trades, key=lambda p: p["pnl"])
            hl.append(f"Bester Trade: {best['setup']} {_fmt(best['pnl'], '+,.0f')} $ · schlechtester: {worst['setup']} {_fmt(worst['pnl'], '+,.0f')} $")
            if len(days) > 1:
                bd = max(days.values(), key=lambda x: x["pnl"])
                wd = min(days.values(), key=lambda x: x["pnl"])
                hl.append(f"Bester Tag {_wd(bd['day'])} ({_fmt(bd['pnl'], '+,.0f')} $), schwächster {_wd(wd['day'])} ({_fmt(wd['pnl'], '+,.0f')} $)")
            if len(by_setup) > 1:
                top = max(by_setup.items(), key=lambda kv: kv[1]["pnl"])
                low = min(by_setup.items(), key=lambda kv: kv[1]["pnl"])
                hl.append(f"Stärkste Strategie: {top[0]} ({_fmt(top[1]['pnl'], '+,.0f')} $), schwächste: {low[0]} ({_fmt(low[1]['pnl'], '+,.0f')} $)")
        else:
            hl.append("Keine Bot-Trades in dieser Woche.")
        for k, x in sorted(blocked.items(), key=lambda kv: -kv[1]["n"]):
            if x["known"]:
                hl.append(f"{k}: {x['n']} Signale geblockt – die hätten zusammen {_fmt(x['r'], '+.1f')} R gebracht "
                          + ("(Filter hat geholfen)" if x["r"] < 0 else "(Filter hat Gewinn gekostet)" if x["r"] > 0 else ""))
        for x in learn:
            hl.append("Selbst umgestellt: " + x["text"])
        return {"monday": str(monday), "friday": str(monday + dt.timedelta(days=4)), "offset": int(offset),
                "n": len(trades), "wins": len(wins), "net": round(net, 2), "prev_net": round(pnet, 2), "prev_n": len(prev),
                "winrate": round(len(wins) / len(trades) * 100, 1) if trades else None, "pf": round(gp / gl, 2) if gl > 0 else None,
                "r": round(sum(r for r in rs if r is not None), 2), "days": sorted(days.values(), key=lambda x: x["day"]),
                "by_setup": by_setup, "by_session": by_sess, "signals": len(sigs), "executed": sum(1 for s in sigs if s["status"] == "ausgeführt"),
                "blocked": blocked, "signals_r": round(sum(all_r), 2), "signals_known": len(all_r),
                "learn": learn, "own_n": len(own), "own_pnl": round(sum(t["pnl"] or 0 for t in own), 2),
                "statuses": {k: {"status": v.get("status"), "avg_r": v.get("avg_r")} for k, v in (self.learning.get("setups") or {}).items()},
                "highlights": hl}

    def weekly_text(self, rep):
        return "\n".join(["• " + h for h in rep["highlights"][:10]])

    # ───────── Bot gegen Backtest ─────────
    def compare_backtest(self, bt, same_period=True):
        """Kennzahlen TradingView-Backtest ↔ alle Signale (live) ↔ echte Bot-Trades, plus Abgleich einzelner Trades."""
        bt = [dict(t) for t in (bt or []) if t.get("time") and t.get("pnl") is not None]
        live = self.live_backtest()["trades"]
        bot = []
        for p in self._bot_closed():
            t = p["bar_time"] if p.get("bar_time") and abs(p["bar_time"] / 1000 - p["opened"]) < 86400 * 400 else p["opened"] * 1000
            bot.append({"time": t, "setup": p["setup"], "dir": "Long" if p["side"] == "long" else "Short", "pnl": p["pnl"],
                        "r": self._r_of(p), "slip": None})
        period = None
        firsts = [x[0]["time"] for x in (live, bot) if x]
        if same_period and bt and firsts:
            a = min(firsts)
            b = max(t["time"] for t in bt)
            if b > a:
                period = (a, b + 86400000)
                bt = [t for t in bt if period[0] <= t["time"] <= period[1]]
                live = [t for t in live if period[0] <= t["time"] <= period[1]]
                bot = [t for t in bot if period[0] <= t["time"] <= period[1]]

        def kpis(lst):
            if not lst:
                return {"n": 0}
            w = [t["pnl"] for t in lst if t["pnl"] > 0]
            lo = [-t["pnl"] for t in lst if t["pnl"] <= 0]
            days = {str(ny_date(t["time"] / 1000)) for t in lst}
            setups = {}
            for t in lst:
                x = setups.setdefault(t.get("setup") or "–", {"n": 0, "w": 0})
                x["n"] += 1
                x["w"] += t["pnl"] > 0
            return {"n": len(lst), "winrate": round(len(w) / len(lst) * 100, 1), "pf": round(sum(w) / sum(lo), 2) if sum(lo) > 0 else None,
                    "payoff": round((sum(w) / len(w)) / (sum(lo) / len(lo)), 2) if w and lo and sum(lo) > 0 else None,
                    "per_day": round(len(lst) / max(1, len(days)), 2), "days": len(days),
                    "long_share": round(sum(1 for t in lst if t["dir"] == "Long") / len(lst) * 100, 1),
                    "setups": {k: {"n": v["n"], "wr": round(v["w"] / v["n"] * 100, 1)} for k, v in setups.items()}}

        def match(a_list, b_list, tol=15 * 60000):
            used, pairs = set(), []
            bs = sorted(range(len(b_list)), key=lambda i: b_list[i]["time"])
            for x in a_list:
                best = None
                for i in bs:
                    if i in used or b_list[i]["dir"] != x["dir"]:
                        continue
                    d = abs(b_list[i]["time"] - x["time"])
                    if d <= tol and (best is None or d < best[0]):
                        best = (d, i)
                if best:
                    used.add(best[1])
                    pairs.append((x, b_list[best[1]]))
            same = sum(1 for x, y in pairs if (x["pnl"] > 0) == (y["pnl"] > 0))
            return {"matched": len(pairs), "only_a": len(a_list) - len(pairs), "only_b": len(b_list) - len(used),
                    "same_outcome": round(same / len(pairs) * 100, 1) if pairs else None}

        res = {"backtest": kpis(bt), "signals": kpis(live), "bot": kpis(bot),
               "period": [period[0], period[1]] if period else None,
               "match_bt_signals": match(bt, live) if bt and live else None,
               "match_signals_bot": match(live, bot) if live and bot else None}
        notes = []
        B, L, R = res["backtest"], res["signals"], res["bot"]
        if B.get("n") and L.get("n"):
            d = L["winrate"] - B["winrate"]
            if abs(d) >= 10 and L["n"] >= 20:
                notes.append(("warn", f"Trefferquote live {_fmt(L['winrate'], '.0f')} % gegenüber {_fmt(B['winrate'], '.0f')} % im Backtest ({_fmt(d, '+.0f')} Prozentpunkte)."))
            else:
                notes.append(("ok", f"Trefferquote live und im Backtest ähnlich ({_fmt(L['winrate'], '.0f')} % zu {_fmt(B['winrate'], '.0f')} %)."))
            if L["per_day"] < B["per_day"] * 0.6 and L["days"] >= 5:
                notes.append(("warn", f"Live kommen deutlich weniger Signale an ({L['per_day']} statt {B['per_day']} pro Tag). Läuft der Alert durchgehend?"))
            m = res["match_bt_signals"]
            if m and m["matched"] + m["only_a"] >= 10 and m["only_a"] > (m["matched"] + m["only_a"]) * 0.25:
                notes.append(("warn", f"{m['only_a']} Backtest-Trades kamen live nie als Signal an – Alert war evtl. aus, oder das Script im Alert ist veraltet."))
            if m and m["same_outcome"] is not None and m["matched"] >= 10 and m["same_outcome"] < 75:
                notes.append(("warn", f"Nur {_fmt(m['same_outcome'], '.0f')} % der gleichen Trades endeten gleich – Hinweis auf Repainting oder andere Einstellungen."))
        if L.get("n") and R.get("n"):
            m = res["match_signals_bot"]
            if m and m["only_a"] > 0:
                notes.append(("info", f"{m['only_a']} Signale hat der Bot bewusst nicht genommen (Filter, Lernmodul, News, Limits)."))
        if not B.get("n"):
            notes.append(("info", "Noch kein TradingView-Backtest geladen – unter Lernmodul → Backtest eine Export-Datei einlesen."))
        res["notes"] = [{"tone": a, "text": b} for a, b in notes]
        return res

    # ───────── Monte-Carlo für die Fremdkapital-Challenge ─────────
    def monte_carlo(self, pool_src="auto", runs=3000, max_days=60, bt=None, fresh=False):
        import random
        ch = self.cfg["challenge"]
        c = self.challenge()
        start, dd = float(ch["start_balance"]), float(ch["max_dd"])
        target = start + float(ch["profit_target"])
        dloss = float(ch["daily_loss"] or 0)
        pools = {}
        cal = self._calendar_trades()
        for key, rows in (("bot", [t for t in cal if t["source"] == "bot"]), ("eigen", [t for t in cal if t["source"] == "eigen"]),
                          ("alle", cal)):
            days = {}
            for t in sorted(rows, key=lambda t: t["closed"] or 0):
                days.setdefault(t["day"], []).append(t["pnl"] or 0)
            pools[key] = list(days.values())
        for key, rows in (("signale", self.live_backtest()["trades"]), ("backtest", bt or [])):
            days = {}
            for t in sorted(rows, key=lambda t: t["time"]):
                days.setdefault(str(ny_date(t["time"] / 1000)), []).append(t["pnl"])
            pools[key] = list(days.values())
        if pool_src == "auto":
            pool_src = next((k for k in (ch["source"], "bot", "backtest", "signale") if len(pools.get(k, [])) >= 10), ch["source"])
        days_pool = pools.get(pool_src) or []
        info = {"source": pool_src, "pool_days": len(days_pool), "pool_trades": sum(len(d) for d in days_pool),
                "sizes": {k: len(v) for k, v in pools.items()}}
        if len(days_pool) < 5:
            return dict(info, ok=False, error="Zu wenig Handelstage für eine Simulation (mindestens 5).")
        use_now = not fresh and c["n_trades"] > 0 and not c["breached"] and not c["passed"]
        bal0 = c["balance"] if use_now else start
        hwm0 = c["hwm"] if use_now else start

        def thr(h):
            if ch["dd_type"] == "static":
                return start - dd
            v = h - dd
            return min(v, start) if ch["lock_at_start"] else v

        rnd = random.Random(42)
        passed = failed = 0
        t_pass, t_fail = [], []
        curves = [[] for _ in range(max_days + 1)]
        for _ in range(runs):
            bal, hwm, done = bal0, hwm0, None
            curves[0].append(bal)
            for day in range(1, max_days + 1):
                if done is None:
                    dp = 0.0
                    for p in rnd.choice(days_pool):
                        bal += p
                        dp += p
                        if ch["dd_type"] == "intraday":
                            hwm = max(hwm, bal)
                        if bal <= thr(hwm):
                            done = "fail"
                            break
                        if dloss > 0 and dp <= -dloss:
                            break   # Tageslimit: für heute Schluss (der Bot stoppt dann selbst)
                    if done is None and ch["dd_type"] == "eod":
                        hwm = max(hwm, bal)
                    if done is None and bal >= target:
                        done = "pass"
                    if done == "pass":
                        passed += 1
                        t_pass.append(day)
                    elif done == "fail":
                        failed += 1
                        t_fail.append(day)
                curves[day].append(bal)
        def q(v, p):
            v = sorted(v)
            return v[min(len(v) - 1, int(p * len(v)))] if v else None
        fan = [{"d": d, "p10": round(q(v, .1), 0), "p50": round(q(v, .5), 0), "p90": round(q(v, .9), 0)} for d, v in enumerate(curves)]
        avg_day = sum(sum(d) for d in days_pool) / len(days_pool)
        return dict(info, ok=True, runs=runs, max_days=max_days, from_now=use_now, start=bal0,
                    target=target, threshold=round(thr(hwm0), 2),
                    p_pass=round(passed / runs * 100, 1), p_fail=round(failed / runs * 100, 1),
                    p_open=round((runs - passed - failed) / runs * 100, 1),
                    med_pass=q(t_pass, .5), med_fail=q(t_fail, .5), avg_day=round(avg_day, 2), fan=fan)

    # ───────── Journal: Notizen und Screenshots je Trade ─────────
    def journal_set(self, pid, text):
        p = self.db.position(pid)
        if not p:
            raise ValueError("Trade nicht gefunden")
        self.db.update_position(pid, journal=str(text or "")[:4000])
        return {"ok": True}

    def shots_dir(self):
        d = os.path.join(self.data_dir, "screenshots")
        os.makedirs(d, exist_ok=True)
        return d

    def shot_add(self, pid, data):
        p = self.db.position(pid)
        if not p:
            raise ValueError("Trade nicht gefunden")
        shots = json.loads(p.get("shots") or "[]")
        if len(shots) >= 6:
            raise ValueError("Höchstens 6 Bilder pro Trade")
        if data[:8] == b"\x89PNG\r\n\x1a\n":
            ext = "png"
        elif data[:3] == b"\xff\xd8\xff":
            ext = "jpg"
        elif data[:4] == b"RIFF" and data[8:12] == b"WEBP":
            ext = "webp"
        else:
            raise ValueError("Nur PNG-, JPG- oder WEBP-Bilder")
        if len(data) > 6_000_000:
            raise ValueError("Bild ist größer als 6 MB")
        name = f"{pid}_{uuid.uuid4().hex[:8]}.{ext}"
        with open(os.path.join(self.shots_dir(), name), "wb") as f:
            f.write(data)
        shots.append(name)
        self.db.update_position(pid, shots=json.dumps(shots))
        return {"ok": True, "name": name, "shots": shots}

    def shot_delete(self, pid, name):
        p = self.db.position(pid)
        if not p:
            raise ValueError("Trade nicht gefunden")
        shots = [s for s in json.loads(p.get("shots") or "[]") if s != name]
        self.db.update_position(pid, shots=json.dumps(shots))
        try:
            os.remove(os.path.join(self.shots_dir(), os.path.basename(name)))
        except OSError:
            pass
        return {"ok": True, "shots": shots}

    def state(self):
        with self.lock:
            opens = self.db.open_positions()
            for p in opens:
                p["upnl"] = round(self._unrealized(p), 2)
                try:
                    p["smart"] = self.smart_view_pos(p)
                except Exception:   # noqa: BLE001  Einschätzung ist nur Anzeige
                    p["smart"] = None
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
                "old_script": self.old_script,
                "summary": self.summary(),
                "timeline": self.timeline(),
                "health": self.health(),
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

INDEX_HTML = '<!doctype html>\n<html lang="de">\n<head>\n<meta charset="utf-8">\n<meta name="viewport" content="width=device-width, initial-scale=1">\n<title>FVG Trader</title>\n<link rel="manifest" href="/manifest.webmanifest">\n<meta name="theme-color" content="#efeef2">\n<script>try{var t=localStorage.getItem("fvg-theme");if(t==="dark")document.documentElement.dataset.theme="dark";}catch(e){}</script>\n<meta name="apple-mobile-web-app-capable" content="yes">\n<meta name="mobile-web-app-capable" content="yes">\n<meta name="apple-mobile-web-app-title" content="FVG Trader">\n<link rel="apple-touch-icon" href="/icon-192.png">\n<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns=\'http://www.w3.org/2000/svg\' viewBox=\'0 0 32 32\'%3E%3Crect width=\'32\' height=\'32\' rx=\'6\' fill=\'%232f5bd3\'/%3E%3Crect x=\'7\' y=\'6\' width=\'5\' height=\'12\' fill=\'white\'/%3E%3Crect x=\'14\' y=\'11\' width=\'5\' height=\'14\' fill=\'white\' opacity=\'.55\'/%3E%3Crect x=\'21\' y=\'15\' width=\'5\' height=\'11\' fill=\'white\'/%3E%3C/svg%3E">\n<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500;600&display=swap">\n<style>\n/* Layout: feste Kopfzeile mit Modus-Schalter & Notaus → Reiter → Cockpit (Vorschläge zuerst, dann Positionen, dann Verlauf) */\n:root{\n  --bg:#070b14; --surface:#0d1424; --raise:#111a2e; --sunk:#0a101d; --line:#1a2540; --line2:#24314f; --fg:#e4e9f2; --muted:#7d8aa5;\n  --accent:#4c8dff; --accent-fg:#fff; --pos:#2fd39a; --neg:#ff5d6c; --warn:#f2b441; --fill:rgba(76,141,255,.13);\n  --pos-bg:rgba(47,211,154,.09); --neg-bg:rgba(255,93,108,.09); --warn-bg:rgba(242,180,65,.12);\n  --f-display:"Inter",system-ui,-apple-system,"Segoe UI",sans-serif;\n  --f-body:"Inter",system-ui,-apple-system,"Segoe UI",sans-serif;\n  --f-mono:"JetBrains Mono","IBM Plex Mono",ui-monospace,Menlo,Consolas,monospace;\n  color-scheme:dark;\n}\nbody{background:radial-gradient(1200px 500px at 50% -200px,rgba(76,141,255,.08),transparent 70%) var(--bg) fixed}\n*{box-sizing:border-box}\n[hidden]{display:none!important}\nhtml,body{margin:0}\nbody{color:var(--fg);font:14px/1.5 var(--f-body);-webkit-font-smoothing:antialiased;font-feature-settings:"cv11","ss01"}\n.wrap{max-width:1200px;margin:0 auto;padding:0 max(16px,env(safe-area-inset-left,0px)) 60px max(16px,env(safe-area-inset-right,0px))}\nbutton{font:inherit;cursor:pointer}\nbutton:focus-visible,input:focus-visible,select:focus-visible{outline:2px solid var(--accent);outline-offset:2px}\ninput,select{font:inherit;color:var(--fg);background:var(--surface);border:1px solid var(--line);border-radius:6px;padding:7px 10px;min-width:0}\ninput[type=number]{font-family:var(--f-mono);font-variant-numeric:tabular-nums}\n.mono{font-family:var(--f-mono);font-variant-numeric:tabular-nums}\n.pos{color:var(--pos)} .neg{color:var(--neg)} .muted{color:var(--muted)}\n\n/* Kopfzeile mit Auswahlleiste oben */\n.top{position:sticky;top:0;z-index:5;background:color-mix(in srgb,var(--surface) 92%,transparent);backdrop-filter:blur(10px);border-bottom:1px solid var(--line)}\n.bar{display:flex;align-items:center;gap:14px;padding-block:10px}\n.brand{font-family:var(--f-display);font-weight:800;font-size:18px;letter-spacing:-.01em;display:flex;align-items:center;gap:9px;flex:none}\n.brand i{display:inline-block;width:24px;height:24px;border-radius:7px;background:linear-gradient(135deg,var(--accent),color-mix(in srgb,var(--accent) 60%,var(--pos)))}\n.nav{display:flex;gap:2px;margin:0 auto;padding:3px;background:var(--sunk);border-radius:12px}\n.nav button{display:flex;align-items:center;gap:8px;padding:8px 14px;border:0;border-radius:9px;background:transparent;color:var(--muted);font:500 14px var(--f-body);white-space:nowrap;transition:background .12s,color .12s}\n.nav button:hover{color:var(--fg)}\n.nav svg{width:18px;height:18px;flex:none;display:block}\n.nav button[aria-current=true]{background:var(--surface);color:var(--accent);font-weight:600;box-shadow:0 1px 2px rgba(0,0,0,.12)}\n.bar-r{display:flex;align-items:center;gap:10px;flex:none}\n.status{display:flex;gap:6px;flex-wrap:wrap;align-items:center;padding-top:14px}\n.status .hint{font-size:11.5px;margin-left:auto}\n.content{min-width:0}\n.nav button em{display:none}\n@media (max-width:1060px){ .nav button span{display:none} .nav button{padding:8px 12px} .nav button[aria-current=true] span{display:inline} }\n@media (max-width:820px){\n  .bar{flex-wrap:wrap;gap:10px 12px}\n  .brand{font-size:16px;margin-right:auto}\n  .nav{order:3;width:100%;display:grid;grid-template-columns:repeat(7,1fr);margin:0}\n  .nav button{flex-direction:column;gap:3px;padding:6px 0;font-size:10.5px}\n  .nav button span,.nav button[aria-current=true] span{display:none}\n  .nav button em{display:inline;font-style:normal;white-space:nowrap}\n  .status .hint{display:none}\n  .kpis{grid-template-columns:repeat(2,minmax(0,1fr))}\n  .kpi .v{font-size:18px}\n  .switch b{display:none}\n}\n.pill{display:inline-flex;align-items:center;gap:6px;font-size:12px;padding:4px 10px;border-radius:999px;border:1px solid var(--line);color:var(--muted);white-space:nowrap}\n.dot{width:8px;height:8px;border-radius:50%;background:var(--muted)}\n.dot.ok{background:var(--pos)} .dot.bad{background:var(--neg)} .dot.warn{background:var(--warn)}\n.switch{display:flex;align-items:center;gap:10px;padding:5px 6px 5px 12px;border:1px solid var(--line);border-radius:999px;background:var(--surface)}\n.switch b{font-weight:600;font-size:13px}\n.tgl{position:relative;width:46px;height:26px;border-radius:999px;border:0;background:var(--line);transition:background .15s}\n.tgl::after{content:"";position:absolute;top:3px;left:3px;width:20px;height:20px;border-radius:50%;background:#fff;transition:transform .15s;box-shadow:0 1px 2px rgba(0,0,0,.25)}\n.tgl[aria-checked=true]{background:var(--pos)} .tgl[aria-checked=true]::after{transform:translateX(20px)}\n.btn{border:1px solid var(--line);background:var(--surface);color:var(--fg);border-radius:6px;padding:7px 12px;font-weight:500}\n.btn.primary{background:var(--accent);border-color:var(--accent);color:var(--accent-fg);font-weight:600}\n.btn.good{background:var(--pos);border-color:var(--pos);color:#fff;font-weight:600}\n.btn.danger{background:var(--neg);border-color:var(--neg);color:#fff;font-weight:600}\n.btn.ghost-danger{color:var(--neg);border-color:var(--neg)}\n.btn:disabled{opacity:.5;cursor:default}\n.banner{margin:12px 0 0;padding:10px 14px;border-radius:6px;background:var(--warn-bg);color:var(--warn);font-weight:500}\n\nmain{display:flex;flex-direction:column;gap:22px;padding-top:22px;padding-bottom:40px}\nh2{font-family:var(--f-display);font-weight:600;font-size:16px;margin:0}\n.section{display:flex;flex-direction:column;gap:10px;min-width:0}\n.section-h{display:flex;align-items:baseline;justify-content:space-between;gap:10px;flex-wrap:wrap}\n.hint{color:var(--muted);font-size:12.5px;margin:0}\n.panel{background:var(--surface);border:1px solid var(--line);border-radius:12px;padding:18px;min-width:0}\n.empty{color:var(--muted);font-size:13px;padding:18px;border:1px dashed var(--line);border-radius:8px;text-align:center}\n\n/* Kennzahlen */\n.kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(118px,1fr));background:var(--surface);border:1px solid var(--line);border-radius:12px;overflow:hidden}\n.kpi{background:var(--surface);padding:12px 14px;display:flex;flex-direction:column;gap:2px;min-width:0;box-shadow:1px 0 0 var(--line),0 1px 0 var(--line)}\n.seg{display:inline-flex;border:1px solid var(--line);border-radius:6px;overflow:hidden;background:var(--surface)}\n.seg button{font:500 13px var(--f-body);background:transparent;color:var(--muted);border:0;border-right:1px solid var(--line);padding:7px 12px;cursor:pointer}\n.seg button:last-child{border-right:0}\n.seg button[aria-pressed="true"]{background:var(--fill);color:var(--accent);font-weight:600}\n.kpi .l{font-size:11px;text-transform:uppercase;letter-spacing:.08em;color:var(--muted)}\n.kpi .v{font-family:var(--f-mono);font-size:20px;font-weight:500;font-variant-numeric:tabular-nums;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\n.meter{height:4px;border-radius:2px;background:var(--sunk);overflow:hidden;margin-top:4px}\n.meter i{display:block;height:100%;background:var(--neg)}\n\n/* Vorschläge */\n.cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(320px,1fr));gap:14px}\n.sug{background:var(--surface);border:1px solid var(--line);border-left:4px solid var(--accent);border-radius:8px;padding:14px 16px;display:flex;flex-direction:column;gap:12px}\n.sug.long{border-left-color:var(--pos)} .sug.short{border-left-color:var(--neg)}\n.sug-h{display:flex;align-items:center;gap:10px;flex-wrap:wrap}\n.side{font-family:var(--f-display);font-weight:800;font-size:18px;letter-spacing:.02em}\n.side.long{color:var(--pos)} .side.short{color:var(--neg)}\n.chip{display:inline-block;font-size:11.5px;padding:2px 7px;border-radius:4px;background:var(--fill);color:var(--accent);font-weight:500;white-space:nowrap}\n.chip.warn{background:var(--warn-bg);color:var(--warn)}\n.chip.good{background:var(--pos-bg);color:var(--pos)}\n.chip.bad{background:var(--neg-bg);color:var(--neg)}\n.chip.mute{background:var(--sunk);color:var(--muted)}\n.timer{margin-left:auto;font-family:var(--f-mono);font-size:12px;color:var(--muted)}\n.lv{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:8px 12px}\n.lv div{display:flex;flex-direction:column;min-width:0}\n.lv span{font-size:11px;color:var(--muted);text-transform:uppercase;letter-spacing:.06em}\n.lv b{font-family:var(--f-mono);font-weight:500;font-size:15px;font-variant-numeric:tabular-nums}\n.edit{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:8px}\n.edit label{display:flex;flex-direction:column;gap:3px;font-size:11px;color:var(--muted);text-transform:uppercase;letter-spacing:.06em}\n.edit input{width:100%}\n.flags{display:flex;gap:6px;flex-wrap:wrap}\n.actions{display:flex;gap:8px}\n.actions .btn{flex:1;padding:9px 12px}\n\n/* Tabellen */\n.scroll{overflow-x:auto}\ntable{width:100%;border-collapse:collapse;font-variant-numeric:tabular-nums}\nth{font-size:11px;text-transform:uppercase;letter-spacing:.07em;color:var(--muted);font-weight:600;text-align:right;padding:7px 8px;border-bottom:1px solid var(--line);white-space:nowrap}\ntd{font-family:var(--f-mono);font-size:12.5px;text-align:right;padding:7px 8px;border-bottom:1px solid var(--line);white-space:nowrap}\ntd.t,th.t{text-align:left;font-family:var(--f-body)}\ntd.wrap{white-space:normal;min-width:260px;font-family:var(--f-body);font-size:12.5px;text-align:left;color:var(--muted)}\ntr:last-child td{border-bottom:0}\n.rowbtns{display:flex;gap:6px;justify-content:flex-end}\n.rowbtns .btn{padding:4px 9px;font-size:12px}\n\n.grid2{display:grid;grid-template-columns:minmax(0,1.4fr) minmax(0,1fr);gap:20px}\n@media (max-width:860px){.grid2{grid-template-columns:1fr}}\n.wizard{list-style:none;margin:12px 0 0;padding:0;display:grid;gap:14px}\n.wizard li{display:grid;grid-template-columns:28px minmax(0,1fr);gap:12px;align-items:start}\n.wizard .num{width:26px;height:26px;border-radius:50%;display:grid;place-items:center;font-weight:600;font-size:13px;background:var(--sunk);color:var(--muted)}\n.wizard li.done .num{background:var(--pos-bg);color:var(--pos)}\n.wizard li.now .num{background:var(--accent);color:var(--accent-fg)}\n.wizard li.done .hint{display:none}\n.feed{display:flex;flex-direction:column;gap:0;max-height:360px;overflow:auto}\n.feed div{display:grid;grid-template-columns:52px 1fr;gap:8px;padding:6px 0;border-bottom:1px solid var(--line);font-size:12.5px}\n.feed time{font-family:var(--f-mono);color:var(--muted);font-size:11.5px}\n.feed .warn{color:var(--warn)} .feed .error{color:var(--neg)}\nsvg{display:block;width:100%;height:auto}\nsvg text{fill:var(--muted);font-family:var(--f-mono);font-size:11px}\n.gl{stroke:var(--line)}\n\n/* Performance & Grafiken */\n.perf{display:flex;flex-direction:column;gap:14px}\n.perf-h{display:flex;justify-content:space-between;align-items:center;gap:10px;flex-wrap:wrap}\n.perf-ctl{display:flex;gap:8px;flex-wrap:wrap}\n.perf-b{display:grid;grid-template-columns:auto minmax(0,1fr);gap:24px;align-items:center}\n.ring{position:relative;width:170px;height:170px;flex:none}\n.ring svg{display:block}\n.ring-c{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center}\n.ring-v{font-family:var(--f-mono);font-size:22px;font-weight:600;font-variant-numeric:tabular-nums}\n.ring-l{font-size:12px;color:var(--muted)}\n.perf-side{display:flex;flex-direction:column;gap:12px;min-width:0}\n.perf-stats{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:10px}\n.perf-stats div{display:flex;flex-direction:column;gap:2px;padding:10px 12px;border-radius:8px;background:var(--sunk);min-width:0}\n.perf-stats span{font-size:11px;text-transform:uppercase;letter-spacing:.07em;color:var(--muted)}\n.perf-stats b{font-family:var(--f-mono);font-size:17px;font-weight:500;white-space:nowrap}\n.spark{border-radius:8px;background:var(--sunk);padding:6px}\n.spark svg{width:100%;display:block}\n.hbars{display:flex;flex-direction:column;gap:10px}\n.hbar{display:grid;grid-template-columns:minmax(0,1.2fr) minmax(0,1fr) auto;gap:12px;align-items:center}\n.hbar-l{display:flex;flex-direction:column;gap:2px;min-width:0}\n.hbar-l .hint{font-size:11.5px}\n.hbar-t{position:relative;height:10px;border-radius:5px;background:var(--sunk);overflow:hidden}\n.hbar-mid{position:absolute;left:50%;top:0;bottom:0;width:1px;background:var(--line)}\n.hbar-t i{position:absolute;top:0;bottom:0;border-radius:5px}\n.hbar-t i.p{left:50%;background:var(--pos)} .hbar-t i.n{right:50%;background:var(--neg)}\n.hbar b{font-size:13px;text-align:right;min-width:70px}\n.panel{box-shadow:0 1px 2px rgba(10,15,30,.04)}\n@media (max-width:720px){ .perf-b{grid-template-columns:1fr;justify-items:center} .perf-side{width:100%} .perf-stats{grid-template-columns:repeat(2,minmax(0,1fr))} }\n\n.sess-list{display:flex;flex-direction:column;gap:6px}\n.sess{display:grid;grid-template-columns:20px minmax(0,1fr) auto auto;gap:10px;align-items:center;padding:9px 12px;border:1px solid var(--line);border-radius:8px;cursor:pointer}\n.sess.on,.sess:has(input:checked){border-color:var(--accent);background:var(--fill)}\n.sess-n{font-size:13.5px;font-weight:500}\n.sess-t{font-size:12px}\n@media (max-width:560px){ .sess{grid-template-columns:20px minmax(0,1fr)} .sess-t{grid-column:2} }\n\n/* Kalender */\n.cal-top{display:flex;align-items:center;justify-content:space-between;gap:12px;flex-wrap:wrap}\n.cal-mon{display:flex;align-items:center;gap:6px}\n.cal-mon h2{font-size:22px;font-weight:600;letter-spacing:-.01em;margin:0 8px 0 2px;min-width:0;text-transform:none;color:var(--fg)}\n.cal-mon h2 small{font-weight:400;color:var(--muted);margin-left:6px}\n.ibtn{width:32px;height:32px;display:grid;place-items:center;border:1px solid var(--line);border-radius:8px;background:var(--surface);color:var(--muted);padding:0}\n.ibtn:hover{color:var(--fg);border-color:var(--line2)}\n.ibtn svg{width:16px;height:16px}\n.cal-act{display:flex;gap:8px;align-items:center;flex-wrap:wrap}\n.strip{display:grid;grid-template-columns:1.4fr repeat(4,minmax(0,1fr));background:var(--surface);border:1px solid var(--line);border-radius:12px}\n.strip > div{padding:14px 18px;display:flex;flex-direction:column;gap:4px;min-width:0;border-left:1px solid var(--line)}\n.strip > div:first-child{border-left:0}\n.strip .l{font-size:10.5px;text-transform:uppercase;letter-spacing:.1em;color:var(--muted);font-weight:600}\n.strip .v{font-family:var(--f-mono);font-size:19px;font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\n.strip .big{font-size:28px;font-weight:600;letter-spacing:-.02em}\n.strip .s{font-size:11.5px;color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\n.wl{display:flex;height:5px;border-radius:3px;overflow:hidden;background:var(--sunk);margin-top:3px}\n.wl i{display:block;height:100%}\n@media (max-width:820px){ .strip{grid-template-columns:repeat(2,minmax(0,1fr))} .strip > div{border-left:0;border-top:1px solid var(--line)} .strip > div:first-child{grid-column:1/-1;border-top:0} .strip > div:nth-child(odd):not(:first-child){border-left:1px solid var(--line)} }\n.calbox{background:var(--surface);border:1px solid var(--line);border-radius:12px;padding:6px;overflow:hidden}\n.cal{display:grid;grid-template-columns:repeat(5,minmax(0,1fr)) minmax(0,1.05fr);gap:6px}\n.cal .dow{font-size:10.5px;text-transform:uppercase;letter-spacing:.1em;color:var(--muted);font-weight:600;padding:8px 10px 2px}\n.day{position:relative;min-height:96px;border:1px solid var(--line);border-radius:9px;background:var(--raise);padding:9px 11px;display:flex;flex-direction:column;gap:2px;text-align:left;font:inherit;color:inherit;min-width:0;cursor:pointer;transition:border-color .12s,background .12s,transform .12s}\n.day:hover{border-color:var(--line2);background:color-mix(in srgb,var(--raise) 80%,var(--accent) 6%)}\n.day.win{background:linear-gradient(180deg,rgba(47,211,154,.13),rgba(47,211,154,.04));border-color:rgba(47,211,154,.28)}\n.day.loss{background:linear-gradient(180deg,rgba(255,93,108,.13),rgba(255,93,108,.04));border-color:rgba(255,93,108,.28)}\n.day.win:hover{border-color:rgba(47,211,154,.6)} .day.loss:hover{border-color:rgba(255,93,108,.6)}\n.day.empty{background:transparent}\n.day.out{background:transparent;border-color:transparent;opacity:.35;cursor:default}\n.day.sel{border-color:var(--accent)!important;box-shadow:0 0 0 1px var(--accent),0 6px 20px rgba(76,141,255,.18)}\n.day .dn{font-size:12px;color:var(--muted);font-variant-numeric:tabular-nums;font-weight:500;display:flex;align-items:center;gap:6px}\n.day.today .dn b{background:var(--accent);color:#fff;border-radius:6px;padding:0 6px;font-weight:600}\n.day .dn b{font-weight:500}\n.day .pl{font-family:var(--f-mono);font-size:17px;font-weight:600;font-variant-numeric:tabular-nums;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-top:auto}\n.day .pl .s{display:none}\n.day .meta{font-size:11px;color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;display:flex;gap:4px;align-items:center}\n.dots{display:flex;gap:3px;flex-wrap:wrap;max-width:100%}\n.dots i{width:6px;height:6px;border-radius:2px;background:var(--line2)}\n.dots i.w{background:var(--pos)} .dots i.l{background:var(--neg)}\n.wk{border-radius:9px;border:1px dashed var(--line2);background:transparent;padding:9px 11px;display:flex;flex-direction:column;gap:2px;min-height:96px;min-width:0}\n.wk .dn{font-size:10.5px;text-transform:uppercase;letter-spacing:.1em;color:var(--muted);font-weight:600}\n.wk .pl{font-family:var(--f-mono);font-size:17px;font-weight:600;font-variant-numeric:tabular-nums;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-top:auto}\n.wk .meta{font-size:11px;color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\n.wk .pl .s,.wk .dn .s,.day .meta .s,.wk .meta .s{display:none}\n.daybox{background:var(--surface);border:1px solid var(--line);border-radius:12px;overflow:hidden}\n.daybox-h{display:flex;align-items:center;gap:14px;padding:14px 18px;border-bottom:1px solid var(--line);flex-wrap:wrap}\n.daybox-h h2{font-size:15px;font-weight:600;text-transform:none;letter-spacing:0;color:var(--fg)}\n.daybox-h .v{font-family:var(--f-mono);font-size:18px;font-weight:600}\n.daybox-h .sp{margin-left:auto;display:flex;gap:8px;align-items:center}\n.daybox table{margin:0}\n.daybox .empty{margin:16px;border-color:var(--line2)}\n.legend{display:flex;gap:14px;flex-wrap:wrap;align-items:center;font-size:11.5px;color:var(--muted)}\n.legend span{display:inline-flex;gap:6px;align-items:center}\n.legend i{width:10px;height:10px;border-radius:3px;display:inline-block}\n@media (max-width:640px){\n  .calbox{padding:4px}\n  .cal{gap:3px}\n  .day,.wk{min-height:60px;padding:5px 6px;border-radius:7px}\n  .day .pl,.wk .pl{font-size:10.5px;letter-spacing:-.03em;text-overflow:clip}\n  .day,.wk{padding:5px 4px}\n  .day .pl .f,.wk .pl .f,.wk .dn .f{display:none} .day .pl .s,.wk .pl .s,.wk .dn .s{display:inline}\n  .day .meta,.wk .meta,.dots{display:none}\n  .cal .dow{font-size:9.5px;padding:4px 4px 0}\n  .cal-mon h2{font-size:18px}\n}\n.drw-bg{position:fixed;inset:0;z-index:30;background:rgba(3,6,12,.55);backdrop-filter:blur(2px);display:flex;justify-content:flex-end;animation:fade .15s}\n.drw{width:min(460px,100%);height:100%;background:var(--surface);border-left:1px solid var(--line2);display:flex;flex-direction:column;box-shadow:-20px 0 50px rgba(0,0,0,.4);animation:slide .18s ease-out}\n@keyframes fade{from{opacity:0}} @keyframes slide{from{transform:translateX(30px);opacity:0}}\n.drw .l{font-size:10.5px;text-transform:uppercase;letter-spacing:.1em;color:var(--muted);font-weight:600}\n.drw-h{display:flex;align-items:center;gap:8px;padding:14px 16px;border-bottom:1px solid var(--line)}\n.drw-t{flex:1;min-width:0;text-align:center}\n.drw-t h2{font-size:15px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\n.drw-b{flex:1;overflow:auto;padding:18px;display:flex;flex-direction:column;gap:18px}\n.drw-pl{display:flex;flex-direction:column;gap:2px}\n.drw-pl > b{font-family:var(--f-mono);font-size:34px;font-weight:600;letter-spacing:-.02em}\n.drw-b > *{flex-shrink:0}\n.drw-st{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));border:1px solid var(--line);border-radius:10px;overflow:hidden}\n.drw-st > div{padding:10px 12px;display:flex;flex-direction:column;gap:2px;box-shadow:1px 0 0 var(--line),0 1px 0 var(--line);min-width:0}\n.drw-st b{font-family:var(--f-mono);font-size:15px;font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\n.drw-cv{display:flex;flex-direction:column;gap:6px} .drw-cv svg{width:100%}\n.drw-list{display:flex;flex-direction:column;gap:8px}\n.tr{border:1px solid var(--line);border-left:3px solid var(--line2);border-radius:9px;background:var(--raise);padding:10px 12px;display:flex;flex-direction:column;gap:6px}\n.tr.w{border-left-color:var(--pos)} .tr.lo{border-left-color:var(--neg)}\n.tr-a{display:flex;align-items:center;gap:8px;flex-wrap:wrap}\n.tr-p{margin-left:auto;font-weight:600;font-size:15px}\n.tr-b{display:flex;gap:6px 12px;flex-wrap:wrap;align-items:center;font-size:12px;color:var(--muted)}\n.tr-n{flex:1;min-width:120px}\n.lnk{border:0;background:none;color:var(--neg);font-size:12px;padding:0;margin-left:auto}\n.lnk:hover{text-decoration:underline}\n.drw-f{padding:14px 16px;border-top:1px solid var(--line)} .drw-f .btn{width:100%;padding:10px}\n@media (max-width:640px){ .drw-bg{align-items:flex-end} .drw{height:88vh;border-left:0;border-top:1px solid var(--line2);border-radius:16px 16px 0 0;animation:up .2s ease-out} @keyframes up{from{transform:translateY(40px);opacity:0}} }\n.nw-ctl{display:flex;gap:6px;flex-wrap:wrap}\n.nw-box{padding:6px 0;display:flex;flex-direction:column}\n.nw{display:grid;grid-template-columns:52px 26px minmax(0,1fr) auto;grid-template-areas:"t i n c" ". . v v";gap:2px 10px;align-items:center;padding:9px 16px;border-top:1px solid var(--line)}\n.nw-t{grid-area:t} .nw .imp{grid-area:i} .nw-n{grid-area:n} .nw-c{grid-area:c} .nw-v{grid-area:v;white-space:normal!important}\n.nw-box > .nw:first-child,.nw-day + .nw,.nw-alert + .nw{border-top:0}\n.nw.past{opacity:.45}\n.nw.next{background:var(--fill)}\n.nw.live{background:var(--neg-bg)}\n.nw-t{font-size:13px;color:var(--muted)}\n.nw-n{min-width:0;font-size:13.5px}\n.nw-n b{font-weight:500}\n.nw-v{font-size:12px;color:var(--muted);white-space:nowrap}\n.nw-c{text-align:right}\n.nw-day{font-size:10.5px;text-transform:uppercase;letter-spacing:.1em;color:var(--muted);font-weight:600;padding:12px 18px 6px;border-top:1px solid var(--line)}\n.nw-box > .nw-day:first-child{border-top:0}\n.imp{display:inline-flex;gap:2px} .imp i{width:5px;height:12px;border-radius:2px;background:var(--line2)}\n.imp.low i:first-child{background:var(--warn)}\n.imp.medium i:nth-child(-n+2){background:#f2913a}\n.imp.high i,.imp.holiday i{background:var(--neg)} .imp.holiday i{background:var(--muted)}\n.nw-alert{margin:6px 12px 8px;padding:10px 12px;border-radius:9px;background:var(--neg-bg);border:1px solid rgba(255,93,108,.3);font-size:13px;display:flex;gap:8px;align-items:center;flex-wrap:wrap}\n.nw-f{display:flex;justify-content:space-between;gap:10px;align-items:center;padding:10px 18px 6px;border-top:1px solid var(--line);flex-wrap:wrap}\n.news-pill{color:var(--neg)!important;border-color:rgba(255,93,108,.4)!important}\n@media (max-width:700px){ .nw{grid-template-columns:46px 22px minmax(0,1fr) auto;padding:9px 12px} .nw-t{font-size:12px} }\n.subtabs{display:flex;gap:4px;border-bottom:1px solid var(--line);margin-bottom:-6px}\n.subtabs button{border:0;background:none;color:var(--muted);font:500 14px var(--f-body);padding:10px 14px;border-bottom:2px solid transparent;margin-bottom:-1px}\n.subtabs button:hover{color:var(--fg)}\n.subtabs button[aria-selected=true]{color:var(--fg);border-bottom-color:var(--accent);font-weight:600}\n.ed-top{display:flex;justify-content:space-between;align-items:flex-start;gap:14px;flex-wrap:wrap}\n.ed-k{display:grid;grid-template-columns:repeat(4,minmax(120px,auto));gap:0;border:1px solid var(--line);border-radius:10px;overflow:hidden;flex:1;max-width:900px}\n.ed-k > div{padding:12px 16px;display:flex;flex-direction:column;gap:2px;border-left:1px solid var(--line);min-width:0}\n.ed-k > div:first-child{border-left:0}\n.ed-k .l,.ed-x .l,.mu .l{font-size:10.5px;text-transform:uppercase;letter-spacing:.1em;color:var(--muted);font-weight:600}\n.ed-k b{font-family:var(--f-mono);font-size:21px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\n.ed-k small{font-size:11.5px;color:var(--muted)}\n.ed-help{margin:12px 0 4px;line-height:1.6}\n.edge,.muster{display:flex;flex-direction:column;gap:6px}\n.ed-t td,.ed-t th{vertical-align:middle}\n.ed-t td small{display:block;font-size:11px}\n.ed-r{cursor:pointer} .ed-r:hover td{background:var(--raise)} .ed-r.open td{background:var(--raise)}\n.ed-r .chev{color:var(--muted);display:inline-block;transition:transform .15s} .ed-r.open .chev{transform:rotate(180deg)}\n.ci-w{display:grid;grid-template-columns:52px 110px auto;gap:8px;align-items:center}\n.ci{position:relative;height:8px;border-radius:4px;background:var(--sunk)}\n.ci-r{position:absolute;top:0;bottom:0;background:color-mix(in srgb,var(--accent) 35%,transparent);border-radius:4px}\n.ci-b{position:absolute;top:-3px;bottom:-3px;width:2px;background:var(--muted);border-radius:1px}\n.ci-p{position:absolute;top:-2px;width:3px;height:12px;background:var(--fg);border-radius:1px;transform:translateX(-1px)}\n.grade{display:inline-grid;place-items:center;width:22px;height:22px;border-radius:6px;font:700 12px var(--f-body)}\n.gA{background:var(--fill);color:var(--accent)} .gB{background:rgba(76,141,255,.08);color:#8fb6ff} .gC{background:var(--warn-bg);color:var(--warn)} .gD{background:var(--neg-bg);color:var(--neg)} .g–{color:var(--muted)}\n.spk{width:80px;height:24px;display:block}\n.trust{font-family:var(--f-mono);font-size:15px}\n.ed-d td{padding:0!important;background:var(--sunk)}\n.ed-x{display:grid;grid-template-columns:minmax(0,1.1fr) minmax(0,1fr);gap:12px;padding:14px;white-space:normal;text-align:left;font-family:var(--f-body)}\n.ed-card{border:1px solid var(--line);border-radius:10px;background:var(--surface);padding:12px 14px;display:flex;flex-direction:column;gap:8px;min-width:0}\n.ed-wide{grid-column:1/-1}\n.grid-wl{display:grid;grid-template-columns:repeat(auto-fill,11px);gap:3px}\n.grid-wl i{width:11px;height:11px;border-radius:2px;background:var(--neg)} .grid-wl i.w{background:var(--pos)}\n.ed-mini{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:6px}\n.ed-mini div{display:flex;flex-direction:column;gap:1px} .ed-mini b{font-family:var(--f-mono);font-size:14px}\n.dirrow{display:grid;grid-template-columns:48px minmax(0,1fr) 60px 36px;gap:8px;align-items:center;font-size:12.5px}\n.dirrow .dbar{position:relative;height:8px;border-radius:4px;background:var(--sunk)} .dirrow .dbar i{display:block;height:100%;border-radius:4px;background:var(--accent)}\n.dirrow .dbar b{position:absolute;top:-3px;bottom:-3px;width:2px;background:var(--muted)}\n.wd,.hrs{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:4px}\n.hrs{grid-template-columns:repeat(auto-fill,minmax(44px,1fr))}\n.wd div,.hrs div{border-radius:7px;padding:6px 4px;text-align:center;background:var(--raise);border:1px solid var(--line);display:flex;flex-direction:column;gap:1px;font-size:11px;color:var(--muted)}\n.wd div.ok{background:var(--fill);color:#8fb6ff} .wd div.bad{background:var(--neg-bg)}\n.wd b,.hrs b{font-family:var(--f-mono);font-size:12.5px;color:var(--fg)} .wd small{font-size:10px}\n.recent{display:flex;gap:6px;flex-wrap:wrap}\n.recent span{font-size:11.5px;padding:3px 8px;border-radius:6px;border:1px solid var(--line);background:var(--raise);color:var(--muted)}\n.recent span.w{border-color:rgba(47,211,154,.35)} .recent span.w b{color:var(--pos)} .recent span.x{border-color:rgba(255,93,108,.35)} .recent span.x b{color:var(--neg)}\n.mu{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px;margin-top:8px}\n.mu-c{border:1px solid var(--line);border-radius:10px;background:var(--raise);padding:14px 16px;display:flex;flex-direction:column;gap:10px;min-width:0}\n.mu-w{grid-column:1/-1}\n.mu-h{display:flex;flex-direction:column;gap:1px}\n.mu-g{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px 14px}\n.mu-g > div{display:flex;flex-direction:column;gap:1px} .mu-g b{font-size:18px} .mu-g small{font-size:11px}\n.pbar{display:flex;height:8px;border-radius:4px;overflow:hidden;background:var(--sunk)} .pbar i{display:block;height:100%}\n.hist{display:grid;grid-template-columns:repeat(7,minmax(0,1fr));gap:8px;align-items:end}\n.hist > div{display:flex;flex-direction:column;align-items:center;gap:4px;font-size:11px;color:var(--muted)}\n.hb{height:90px;width:100%;display:flex;gap:3px;align-items:flex-end;justify-content:center}\n.hb i{width:40%;max-width:22px;border-radius:3px 3px 0 0;min-height:2px} .hb i.p{background:var(--pos)} .hb i.n{background:var(--neg)}\n.ck-2{align-items:start}\n@media (max-width:820px){ .ed-top{flex-direction:column;align-items:stretch} .ed-k{max-width:none} .ed-top .seg{align-self:flex-start} }\n@media (max-width:700px){\n  .ed-t tr > :nth-child(4),.ed-t tr > :nth-child(6),.ed-t tr > :nth-child(7),.ed-t tr > :nth-child(8),.ed-t tr > :nth-child(10){display:none}\n  .edge .scroll{overflow:visible}\n  .ed-t{table-layout:fixed;width:100%}\n  .ed-t th:nth-child(2){width:66px} .ed-t th:nth-child(3){width:40px} .ed-t th:nth-child(5){width:58px} .ed-t th:nth-child(9){width:40px}\n  .ed-t th{font-size:9.5px!important;letter-spacing:.04em!important;overflow:hidden;text-overflow:ellipsis}\n  .ed-t .ci{display:none}\n  .ed-t td:first-child b{display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\n  .ed-d td{width:auto} .ed-x{min-width:0} .ed-mini{grid-template-columns:repeat(2,minmax(0,1fr))}\n  .ed-t .ci-w{display:block} .ed-t .ci-w small{display:none}\n  .ed-t td,.ed-t th{padding-left:6px;padding-right:6px}\n  .ed-t td small{display:none}\n  .ed-d td{display:table-cell!important}\n  .ed-x{padding:10px 6px}\n  .wd{grid-template-columns:repeat(5,minmax(0,1fr))}\n}\n.lv-box{padding:6px 0}\n.lv-tags{display:flex;gap:6px;flex-wrap:wrap;padding:8px 16px 10px}\n.lv-row{display:grid;grid-template-columns:44px minmax(0,1fr) 92px 78px minmax(0,auto);gap:10px;align-items:center;padding:7px 16px;border-top:1px solid var(--line);font-size:13px}\n.lv-list > .lv-row:first-child{border-top:0}\n.lv-k{font:700 11px var(--f-body);letter-spacing:.06em;color:var(--accent)}\n.lv-row.pd .lv-k{color:var(--warn)}\n.lv-n{color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\n.lv-p{text-align:right} .lv-d{text-align:right;font-size:12px}\n.lv-row.now{background:var(--fill);border-top:1px solid color-mix(in srgb,var(--accent) 50%,transparent);border-bottom:1px solid color-mix(in srgb,var(--accent) 50%,transparent)}\n.lv-row.now .lv-k,.lv-row.now .lv-n,.lv-row.now .lv-p{color:var(--accent);font-weight:600}\n.lv-row.now + .lv-row{border-top:0}\n@media (max-width:1060px){ .ck-2{grid-template-columns:1fr} }\n@media (max-width:820px){ .ed-k{grid-template-columns:repeat(2,minmax(0,1fr))} .ed-k > div:nth-child(3){border-left:0} .ed-k > div:nth-child(n+3){border-top:1px solid var(--line)} .ed-x,.mu{grid-template-columns:1fr} .ed-mini{grid-template-columns:repeat(3,minmax(0,1fr))} .mu-w,.ed-wide{grid-column:auto} }\n@media (max-width:560px){ .lv-row{grid-template-columns:38px minmax(0,1fr) 76px 64px;padding:7px 12px} .lv-row > span:last-child{grid-column:2/-1} .lv-row > span:last-child:empty{display:none} }\n.chc{width:100%;text-align:left;font:inherit;color:inherit;background:var(--surface);border:1px solid var(--line);border-radius:12px;padding:14px 18px;display:flex;flex-direction:column;gap:10px;cursor:pointer;transition:border-color .12s}\n.chc:hover{border-color:color-mix(in srgb,var(--accent) 45%,var(--line))}\n.chc-h{display:flex;justify-content:space-between;align-items:center;gap:10px}\n.chc .l,.ch-big .l,.ch-head .l{font-size:10.5px;text-transform:uppercase;letter-spacing:.1em;color:var(--muted);font-weight:600}\n.chc-g{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px}\n.chc-g > div{display:flex;flex-direction:column;gap:1px;min-width:0}\n.chc-g b{font-family:var(--f-mono);font-size:20px;font-weight:600;white-space:nowrap}\n.chc-g small{font-size:11.5px;color:var(--muted)}\n.trk{display:flex;flex-direction:column;gap:6px}\n.trk-b{position:relative;height:10px;border-radius:5px;background:linear-gradient(90deg,rgba(255,93,108,.35),var(--sunk) 30%,var(--sunk) 70%,rgba(47,211,154,.35))}\n.trk.sm .trk-b{height:6px}\n.trk-f{position:absolute;left:0;top:0;bottom:0;border-radius:5px;background:color-mix(in srgb,var(--accent) 45%,transparent)}\n.trk-s{position:absolute;top:-4px;bottom:-4px;width:2px;background:var(--muted)}\n.trk-e{position:absolute;top:50%;width:14px;height:14px;border-radius:50%;background:var(--accent);border:2px solid var(--bg);transform:translate(-50%,-50%);box-shadow:0 0 0 3px rgba(76,141,255,.25)}\n.trk.sm .trk-e{width:11px;height:11px}\n.trk-l{position:relative;display:flex;justify-content:space-between;font-size:11.5px;font-family:var(--f-mono);height:16px}\n.trk-l span:nth-child(2){position:absolute;transform:translateX(-50%);color:var(--muted)}\n.ch-head{display:flex;justify-content:space-between;align-items:flex-end;gap:12px;flex-wrap:wrap}\n.ch-head h2{font-size:24px;font-weight:600;text-transform:none;letter-spacing:-.01em;color:var(--fg)}\n.ch-head h2 small{font-size:15px;color:var(--muted);font-weight:400;margin-left:6px;font-family:var(--f-mono)}\n.ch-hr{display:flex;flex-direction:column;align-items:flex-end;gap:4px}\n.ch-big{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));background:var(--surface);border:1px solid var(--line);border-radius:12px}\n.ch-big > div{padding:16px 18px;display:flex;flex-direction:column;gap:4px;border-left:1px solid var(--line);min-width:0}\n.ch-big > div:first-child{border-left:0}\n.ch-big > div.warn{background:var(--warn-bg);border-radius:12px 0 0 12px}\n.ch-big b{font-family:var(--f-mono);font-size:26px;font-weight:600;letter-spacing:-.02em;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\n.ch-big small{font-size:11.5px;color:var(--muted);line-height:1.4}\n.prog{height:5px;border-radius:3px;background:var(--sunk);overflow:hidden} .prog i{display:block;height:100%;background:var(--pos)}\n.rules{display:flex;flex-direction:column;padding:4px 0}\n.rl{display:grid;grid-template-columns:26px minmax(0,1fr) auto;gap:10px;align-items:center;padding:10px 18px;border-top:1px solid var(--line)}\n.rl:first-child{border-top:0}\n.rl b{font-size:13.5px;font-weight:600;display:block} .rl small{font-size:11.5px;color:var(--muted);display:block;line-height:1.4}\n.rl-i{width:22px;height:22px;border-radius:6px;display:grid;place-items:center;font-size:12px;font-weight:700;background:var(--sunk);color:var(--muted)}\n.rl.ok .rl-i{background:var(--pos-bg);color:var(--pos)} .rl.no .rl-i{background:var(--neg-bg);color:var(--neg)}\n.rl .mono{font-size:14px}\n.ch-form{max-width:none}\n.ch-empty{display:flex;flex-direction:column;gap:8px}\nsvg.chart{width:100%;height:auto}\n@media (max-width:820px){ .ch-big{grid-template-columns:repeat(2,minmax(0,1fr))} .ch-big > div:nth-child(3){border-left:0} .ch-big > div:nth-child(n+3){border-top:1px solid var(--line)} .ch-big b{font-size:21px} .ch-hr{align-items:flex-start} }\n@media (max-width:560px){ .chc-g{grid-template-columns:repeat(2,minmax(0,1fr))} .chc-g > div:last-child{display:none} .chc-g b{font-size:17px} }\n.vt th small{font-size:9.5px;letter-spacing:.04em;text-transform:none;font-weight:400}\n.vt td.vc{text-align:center}\n.vt td.vc b{display:block;font-size:14px}\n.vt td.vc small{display:block;font-size:10.5px;color:var(--muted)}\n.vt td.best{box-shadow:inset 0 0 0 1.5px rgba(47,211,154,.55);border-radius:6px}\n.vt td.cur{background:var(--fill)}\n.vt td.t small{display:block;font-size:11px}\n.vrec{display:flex;flex-direction:column;gap:6px;align-items:flex-start;white-space:normal;min-width:190px;font-family:var(--f-body);font-size:12.5px}\n.lab-h{font-size:10.5px;text-transform:uppercase;letter-spacing:.1em;color:var(--muted);font-weight:600;margin:14px 0 4px}\n.rf-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(330px,1fr));gap:10px}\n.rf{border:1px solid var(--line);border-left:3px solid var(--pos);border-radius:10px;background:var(--raise);padding:12px 14px;display:flex;flex-direction:column;gap:8px}\n.rf.avoid{border-left-color:var(--neg)} .rf.weak{opacity:.75;border-left-color:var(--line2)}\n.rf-h{display:flex;gap:8px;align-items:center;flex-wrap:wrap}\n.rf-l{font-size:15px;font-weight:600}\n.rf-g{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px 14px}\n.rf-g div{display:flex;flex-direction:column;gap:1px;min-width:0} .rf-g .l{font-size:10px;text-transform:uppercase;letter-spacing:.08em;color:var(--muted);font-weight:600}\n.rf-g b{font-family:var(--f-mono);font-size:14px} .rf-g small{font-size:10.5px;color:var(--muted)}\n.rf-act{display:flex;flex-direction:column;gap:6px}\n.rfa{display:grid;grid-template-columns:auto minmax(0,1fr) auto auto;gap:10px;align-items:center;border:1px solid var(--line);border-radius:9px;padding:10px 12px;background:var(--raise);font-size:13px}\n.rfa small{display:block} .rfa.off{opacity:.55}\n@media (max-width:560px){ .rf-g{grid-template-columns:repeat(2,minmax(0,1fr))} .rfa{grid-template-columns:auto minmax(0,1fr)} .rfa .btn{grid-column:auto} .rf-grid{grid-template-columns:1fr} }\n.pcs{display:flex;flex-direction:column;gap:12px}\n.pc{background:var(--surface);border:1px solid var(--line);border-left:4px solid var(--pos);border-radius:12px;padding:14px 18px;display:flex;flex-direction:column;gap:14px}\n.pc.short{border-left-color:var(--neg)}\n.pc-h{display:flex;align-items:center;gap:10px;flex-wrap:wrap}\n.pc-h .side{font-size:15px}\n.pc-pl{margin-left:auto;display:flex;flex-direction:column;align-items:flex-end;gap:1px}\n.pc-pl b{font-size:24px;font-weight:600;letter-spacing:-.02em} .pc-pl small{font-size:12px;color:var(--muted);font-family:var(--f-mono)}\n.pc-bar{display:flex;flex-direction:column;gap:4px}\n.pc-track{position:relative;height:8px;border-radius:4px;background:var(--sunk)}\n.pc-risk{position:absolute;left:0;top:0;bottom:0;background:linear-gradient(90deg,rgba(255,93,108,.55),rgba(255,93,108,.12));border-radius:4px 0 0 4px}\n.pc-rew{position:absolute;top:0;bottom:0;background:linear-gradient(90deg,rgba(47,211,154,.12),rgba(47,211,154,.55));border-radius:0 4px 4px 0}\n.pc-mk{position:absolute;top:50%;transform:translate(-50%,-50%);border-radius:50%}\n.pc-mk.e{width:4px;height:16px;border-radius:2px;background:var(--fg)}\n.pc-mk.n{width:14px;height:14px;background:var(--accent);border:2px solid var(--bg);box-shadow:0 0 0 3px rgba(76,141,255,.3);transition:left .4s}\n.pc-bl{position:relative;display:flex;justify-content:space-between;font-size:11px;color:var(--muted);height:15px}\n.pc-le{position:absolute;transform:translateX(-50%)}\n.pc-g{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));border:1px solid var(--line);border-radius:10px;overflow:hidden}\n.pc-c{padding:10px 14px;display:flex;flex-direction:column;gap:2px;border-left:1px solid var(--line);min-width:0}\n.pc-c:first-child{border-left:0}\n.pc-c.sl{background:rgba(255,93,108,.05)} .pc-c.tp{background:rgba(47,211,154,.05)}\n.pc-c .l{font-size:10.5px;text-transform:uppercase;letter-spacing:.1em;color:var(--muted);font-weight:600}\n.pc-c > b{font-size:18px;font-weight:600}\n.pc-c small{font-size:11.5px;color:var(--muted);line-height:1.45}\n.pc-c small.pos{color:var(--pos)} .pc-c small.neg{color:var(--neg)}\n.pc-a{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr) auto;gap:12px 16px;align-items:start}\n.pc-e{display:flex;flex-direction:column;gap:4px;min-width:0}\n.pc-e label{font-size:10.5px;text-transform:uppercase;letter-spacing:.1em;color:var(--muted);font-weight:600}\n.pc-in{display:flex;gap:4px;flex-wrap:wrap}\n.pc-in input{width:110px;flex:1;min-width:90px}\n.pc-in .btn{padding:6px 10px}\n.pc-q{display:flex;flex-direction:column;gap:6px;align-self:end}\n@media (max-width:1000px){ .pc-a{grid-template-columns:1fr} .pc-q{flex-direction:row;flex-wrap:wrap} }\n@media (max-width:760px){ .pc-g{grid-template-columns:repeat(2,minmax(0,1fr))} .pc-c:nth-child(3){border-left:0} .pc-c:nth-child(n+3){border-top:1px solid var(--line)} .pc{padding:12px} .pc-pl{margin-left:0;width:100%;flex-direction:row;align-items:baseline;gap:8px} }\n.live-dot{display:inline-block;width:7px;height:7px;border-radius:50%;background:var(--pos);margin-right:4px;vertical-align:1px;animation:pulse 1.6s infinite}\n@keyframes pulse{0%{box-shadow:0 0 0 0 rgba(47,211,154,.6)}70%{box-shadow:0 0 0 6px rgba(47,211,154,0)}100%{box-shadow:0 0 0 0 rgba(47,211,154,0)}}\n.ssn{display:flex;gap:4px;flex-wrap:wrap}\n.ssn .chip b{font-weight:600;margin-left:2px}\n.td-g{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:8px 12px;padding:8px 0 2px;border-top:1px solid var(--line)}\n.td-g div{display:flex;flex-direction:column;gap:1px;min-width:0}\n.td-g .l{font-size:10px;text-transform:uppercase;letter-spacing:.08em;color:var(--muted);font-weight:600}\n.td-g b{font-size:13.5px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\n.td-g small{font-size:11px;color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\n.bt{display:flex;flex-direction:column;gap:10px}\n.bt-drop{border:1.5px dashed var(--line2);border-radius:10px;padding:16px;text-align:center;color:var(--muted);font-size:13px;transition:all .12s}\n.bt-drop.over{border-color:var(--accent);background:var(--fill);color:var(--fg)}\n.bt-seg{flex-wrap:wrap;align-self:flex-start}\n.modal-bg{position:fixed;inset:0;z-index:40;background:rgba(10,12,20,.55);display:grid;place-items:center;padding:16px;overflow:auto}\n.modal{max-width:460px;width:100%;display:flex;flex-direction:column;gap:12px;box-shadow:0 20px 50px rgba(0,0,0,.3)}\n.modal select{width:100%}\n.modal:has(.logbox){max-width:820px}\n.logbox{max-height:min(60vh,520px);overflow:auto;white-space:pre;word-break:normal;margin:0;font-size:11.5px;line-height:1.45}\n\n/* Einstellungen */\n.settings-wrap{max-width:820px;margin:0 auto;display:flex;flex-direction:column;gap:10px;width:100%;padding-top:4px}\n.set-sec{background:var(--surface);border:1px solid var(--line);border-radius:12px;padding:18px 20px;scroll-margin-top:130px;display:flex;flex-direction:column;gap:12px;min-width:0}\n.set-h{display:flex;flex-direction:column;gap:2px}\n.set-h h2{font-size:16px}\n.set-b{display:flex;flex-direction:column;gap:10px;min-width:0}\n.sub{display:flex;flex-direction:column;gap:10px;padding-left:12px;border-left:2px solid var(--line)}\n.form{display:flex;flex-direction:column;gap:12px}\n.row{display:grid;grid-template-columns:minmax(0,1fr) minmax(170px,42%);gap:12px;align-items:center}\n.row[hidden]{display:none}\n.row label{font-size:13.5px}\n.row small{display:block;color:var(--muted);font-size:11.5px;margin-top:1px}\n.row input,.row select{width:100%}\n.row .tgl,.row > .btn,.row .chk{justify-self:end}\n.row input.chk,.chk{width:18px;height:18px;accent-color:var(--accent)}\n.inline{display:flex;gap:8px;align-items:center;justify-content:flex-end;flex-wrap:wrap}\n.inline input[type=time]{width:auto}\n.wrap-gap{justify-content:flex-start}\n.lbl{display:block;font-size:11px;text-transform:uppercase;letter-spacing:.07em;color:var(--muted);font-weight:600;margin:4px 0 4px}\n.preview{display:flex;flex-direction:column;gap:4px;background:var(--sunk);border-radius:8px;padding:10px 12px;font-size:12.5px}\n.preview div{display:flex;gap:6px 14px;flex-wrap:wrap;align-items:baseline}\n.pv{font-family:var(--f-mono);font-size:12px;color:var(--muted)}\n.pv b{color:var(--fg);font-weight:500}\ndetails.set-sec{padding:0;display:block}\ndetails.set-sec > summary{cursor:pointer;list-style:none;display:grid;grid-template-columns:36px minmax(0,1fr) auto 16px;gap:12px;align-items:center;padding:14px 18px;border-radius:12px}\ndetails.set-sec > summary:hover{background:var(--sunk)}\ndetails.set-sec > summary::-webkit-details-marker{display:none}\ndetails.set-sec > summary::after{content:"▾";color:var(--muted);transition:transform .15s;text-align:center}\ndetails.set-sec[open] > summary::after{transform:rotate(180deg)}\ndetails.set-sec[open] > summary{border-bottom:1px solid var(--line);border-radius:12px 12px 0 0}\n.s-ic{width:36px;height:36px;border-radius:10px;background:var(--fill);color:var(--accent);display:grid;place-items:center}\n.s-ic svg{width:19px;height:19px;display:block}\n.s-t{display:flex;flex-direction:column;gap:1px;min-width:0}\n.s-t b{font-size:15px;font-family:var(--f-display)}\n.s-t .hint{font-size:12.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\n.s-chip{display:flex;gap:6px}\ndetails.set-sec > .set-b{padding:16px 20px 20px}\ndetails.set-sec > .set-b > .hint:first-child{margin:0 0 2px}\n@media (max-width:640px){ details.set-sec > summary{grid-template-columns:32px minmax(0,1fr) 16px;padding:12px 14px} .s-chip{display:none} .s-ic{width:32px;height:32px} }\n.savebar{position:sticky;bottom:max(12px,env(safe-area-inset-bottom,0px));margin:14px auto 0;max-width:820px;width:100%;display:flex;gap:10px;align-items:center;justify-content:flex-end;background:var(--surface);border:1px solid var(--accent);border-radius:10px;padding:10px 14px;box-shadow:0 8px 24px rgba(0,0,0,.18);z-index:6}\n.savebar .hint{margin-right:auto}\n@media (max-width:560px){ .row{grid-template-columns:1fr} .row .tgl,.row > .btn,.row .chk{justify-self:start} .inline{justify-content:flex-start} }\n.save{display:flex;gap:10px;align-items:center;justify-content:flex-end}\n.ok-msg{font-size:12.5px;color:var(--pos)} .err-msg{font-size:12.5px;color:var(--neg)}\n.code{font-family:var(--f-mono);font-size:12px;background:var(--sunk);border:1px solid var(--line);border-radius:6px;padding:10px;word-break:break-all;white-space:pre-wrap}\n.copyrow{display:flex;gap:8px;align-items:stretch}\n.copyrow .code{flex:1;min-width:0}\nol.steps{margin:0;padding-left:18px;display:grid;gap:6px;font-size:13px}\n\n/* Login */\n.login{min-height:100vh;display:grid;place-items:center;padding:16px}\n.login form{width:min(360px,100%);display:flex;flex-direction:column;gap:12px;background:var(--surface);border:1px solid var(--line);border-radius:10px;padding:24px}\n.login h1{font-family:var(--f-display);font-weight:800;font-size:24px;margin:0}\n\n.toast{position:fixed;left:50%;bottom:max(20px,env(safe-area-inset-bottom,0px));transform:translateX(-50%);background:var(--fg);color:var(--bg);padding:10px 16px;border-radius:8px;font-size:13px;z-index:20;max-width:calc(100% - 32px)}\n@media (prefers-reduced-motion:reduce){*{transition:none!important}}\n/* Look wie ein Trading-Terminal: Navy, feine Linien, kleine Großbuchstaben-Labels */\n.btn{border-radius:8px;background:var(--raise);border-color:var(--line2);font-size:13px;transition:border-color .12s,background .12s}\n.btn:hover:not(:disabled){border-color:color-mix(in srgb,var(--accent) 45%,var(--line2))}\n.btn.primary{box-shadow:0 4px 14px rgba(76,141,255,.25)}\n.btn.primary:hover:not(:disabled){filter:brightness(1.1)}\n.btn.danger{background:transparent;color:var(--neg);border-color:rgba(255,93,108,.5)}\n.btn.danger:hover{background:var(--neg-bg)!important}\n.btn.ghost-danger{background:transparent;border-color:rgba(255,93,108,.45)}\ninput,select{background:var(--sunk);border-color:var(--line2);border-radius:8px}\n.panel,.kpis,.set-sec{background:var(--surface);border-color:var(--line);border-radius:12px}\n.kpi{background:transparent}\n.kpi .l,.lbl,th{font-size:10.5px!important;letter-spacing:.1em!important;font-weight:600}\n.section > .section-h h2,.section > h2{font-size:11.5px;text-transform:uppercase;letter-spacing:.12em;color:var(--muted);font-weight:600}\n.seg{background:var(--sunk);border-color:var(--line);border-radius:9px;padding:2px}\n.seg button{border-right:0;border-radius:7px;padding:6px 12px;font-size:12.5px}\n.seg button[aria-pressed="true"]{background:var(--raise);color:var(--fg);box-shadow:inset 0 0 0 1px var(--line2)}\n.chip{border-radius:5px;font-size:11px;font-weight:600;letter-spacing:.01em}\n.pill{background:var(--surface)!important;border:1px solid var(--line)!important}\n.switch{background:var(--raise);border-color:var(--line2)}\n.tgl{background:var(--line2)}\n.code{background:var(--sunk)!important;border-color:var(--line)!important}\n.sess{background:var(--raise)}\n::-webkit-scrollbar{width:10px;height:10px} ::-webkit-scrollbar-thumb{background:var(--line2);border-radius:6px;border:2px solid var(--bg)} ::-webkit-scrollbar-track{background:transparent}\n\n/* Tageszusammenfassung */\n.td{display:flex;flex-direction:column;gap:14px}\n.td-l{font-size:10.5px;text-transform:uppercase;letter-spacing:.1em;color:var(--muted);font-weight:600}\n.td-top{display:grid;grid-template-columns:minmax(200px,1.1fr) 3fr;gap:18px;align-items:center}\n.td-pl{display:flex;flex-direction:column;gap:2px}\n.td-pl b{font-family:var(--f-mono);font-size:34px;font-weight:600;letter-spacing:-.02em;font-variant-numeric:tabular-nums;line-height:1.15}\n.td-pl small,.td-c small{color:var(--muted);font-size:12px}\n.td-cs{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:0}\n.td-c{display:flex;flex-direction:column;gap:2px;padding:4px 14px;border-left:1px solid var(--line);min-width:0}\n.td-c b{font-size:19px;font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\n.td-m{display:flex;flex-direction:column;gap:4px}\n.td-mt{position:relative;height:8px;border-radius:99px;background:var(--sunk);overflow:hidden}\n.td-mt i{position:absolute;top:0;bottom:0;border-radius:99px}\n.td-mt i.p{background:var(--pos)} .td-mt i.n{background:var(--neg)}\n.td-mt b{position:absolute;top:-2px;bottom:-2px;width:2px;background:var(--muted);transform:translateX(-1px)}\n.td-ml{display:flex;justify-content:space-between;font-size:11px;color:var(--muted)}\n.td-chips{display:flex;flex-wrap:wrap;gap:6px}\n.td-chips .chip{display:inline-flex;align-items:center;gap:6px;font-size:12px;padding:3px 9px;max-width:100%;white-space:normal;line-height:1.4}\n.hc{border-top:1px solid var(--line);padding-top:10px}\n.hc-sum{display:flex;align-items:center;gap:12px;width:100%;background:transparent;border:0;color:var(--fg);font:500 13px var(--f-body);cursor:pointer;padding:2px 0;text-align:left}\n.hc-dots{display:inline-flex;gap:5px}\n.hc-ch{margin-left:auto;color:var(--accent);font-size:12.5px}\n.hc-list{display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:6px 18px;margin-top:10px}\n.hc-i{display:grid;grid-template-columns:10px auto 1fr;gap:8px;align-items:center;font-size:12.5px;padding:4px 0}\n.hc-i span:last-child{color:var(--muted);overflow:hidden;text-overflow:ellipsis}\n@media (max-width:820px){.td-top{grid-template-columns:1fr}.td-cs{grid-template-columns:repeat(2,minmax(0,1fr));row-gap:10px}.td-c:nth-child(odd){border-left:0;padding-left:0}}\n/* Timeline */\n.tl{display:flex;flex-direction:column}\n.tl-i{display:grid;grid-template-columns:44px 14px 1fr auto;gap:10px;align-items:start;padding:9px 0;border-bottom:1px solid var(--line)}\n.tl-i:last-child{border-bottom:0}\n.tl-i time{font-size:11.5px;color:var(--muted);padding-top:3px}\n.tl-d{width:10px;height:10px;border-radius:50%;margin-top:5px;background:var(--muted)}\n.tl-i.in .tl-d{background:var(--accent)} .tl-i.bl .tl-d{background:var(--warn)}\n.tl-c{min-width:0;display:flex;flex-direction:column;gap:3px}\n.tl-h{display:flex;flex-wrap:wrap;gap:6px;align-items:center;font-size:13px}\n.tl-w{font-size:12.5px;color:var(--muted);line-height:1.45}\n.tl-o{display:flex;flex-direction:column;align-items:flex-end;gap:1px;text-align:right;white-space:nowrap}\n.tl-o small{font-size:11px;color:var(--muted)}\n.tl-old summary{cursor:pointer;margin:4px 0}\n#sigBox{max-height:560px;overflow:auto}\n.flags .chip.wrapc{white-space:normal;text-align:left;line-height:1.45}\n/* Journal */\n.jr{display:flex;flex-direction:column;gap:6px;margin-top:6px}\n.jr-t{width:100%;resize:vertical;min-height:38px;background:var(--sunk);border:1px solid var(--line);border-radius:8px;color:var(--fg);font:13px/1.45 var(--f-body);padding:7px 9px}\n.jr-t:focus{outline:2px solid var(--accent);outline-offset:-1px}\n.jr-s{display:flex;flex-wrap:wrap;gap:6px;align-items:center}\n.jr-img{position:relative;width:74px;height:50px;border-radius:6px;overflow:hidden;border:1px solid var(--line)}\n.jr-img img{width:100%;height:100%;object-fit:cover;cursor:zoom-in;display:block}\n.jr-x{position:absolute;top:2px;right:2px;width:18px;height:18px;border-radius:50%;border:0;background:rgba(0,0,0,.65);color:#fff;font-size:13px;line-height:18px;padding:0;cursor:pointer}\n.jr-add{font-size:12px;color:var(--accent);border:1px dashed var(--line);border-radius:6px;padding:6px 10px;cursor:pointer}\n/* Wochenbericht, Vergleich, Monte-Carlo */\n.wk-head{display:flex;align-items:center;gap:12px;flex-wrap:wrap}\n.wk-head h2{font-size:19px;text-transform:none;letter-spacing:0;color:var(--fg);margin:2px 0 0}\n.wk-hl{margin:0;padding-left:18px;display:flex;flex-direction:column;gap:6px;font-size:13.5px;line-height:1.5}\n.cmp-notes{display:flex;flex-direction:column;gap:6px;margin-top:12px}\n.cmp-n{display:flex;gap:8px;align-items:center;font-size:13px}\ntable.cmp td,table.cmp th{white-space:normal}\n.cmp-m{display:grid;grid-template-columns:repeat(auto-fit,minmax(110px,1fr));gap:10px}\n.cmp-m > div{display:flex;flex-direction:column;gap:2px}\n.cmp-m b{font-size:22px} .cmp-m small{font-size:12px;color:var(--muted)}\n.mc-ctl{display:flex;gap:12px;flex-wrap:wrap;align-items:center;margin:12px 0}\n.mc-ctl label{display:flex;gap:8px;align-items:center;font-size:13px;color:var(--muted)}\n.mc-ctl select{background:var(--sunk);color:var(--fg);border:1px solid var(--line);border-radius:6px;padding:6px 8px;font:13px var(--f-body)}\n.mc-big{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:0;margin-bottom:10px}\n.mc-big > div{display:flex;flex-direction:column;gap:2px;padding:4px 14px;border-left:1px solid var(--line)}\n.mc-big > div:first-child{border-left:0;padding-left:0}\n.mc-big b{font-family:var(--f-mono);font-size:26px;font-weight:600}\n.mc-big small{font-size:12px;color:var(--muted)}\n.mc-bar{display:flex;height:8px;border-radius:99px;overflow:hidden;background:var(--sunk);margin-bottom:12px}\n.mc-bar i.p{background:var(--pos)} .mc-bar i.o{background:var(--muted);opacity:.5} .mc-bar i.n{background:var(--neg)}\n@media (max-width:820px){.mc-big{grid-template-columns:repeat(2,minmax(0,1fr));row-gap:12px}.mc-big > div:nth-child(odd){border-left:0;padding-left:0}}\n.pc-sm{display:flex;gap:8px;align-items:flex-start;font-size:12.5px;line-height:1.5;padding:8px 10px;margin:8px 0 2px;border-radius:8px;background:var(--sunk)}\n.pc-sm .dot{margin-top:6px;flex-shrink:0}\n.df-list{display:flex;flex-direction:column;gap:10px}\n.df-c{background:var(--surface);border:1px solid var(--line);border-radius:12px;padding:14px 16px}\n.df-h{display:flex;gap:8px;align-items:center;flex-wrap:wrap}\n.df-s{display:flex;flex-wrap:wrap;gap:6px 22px}\n.df-s span{display:flex;flex-direction:column;gap:1px}\n.df-s small{font-size:10.5px;text-transform:uppercase;letter-spacing:.08em;color:var(--muted)}\n.df-s .df-f{padding-left:18px;border-left:1px solid var(--line)}\n.df-a{display:flex;gap:8px;align-items:center;justify-content:flex-end;flex-wrap:wrap;margin-top:10px}\n.df-a .hint{margin-right:auto}\n.df-d{display:flex;gap:6px;flex-wrap:wrap;align-items:center;margin-top:10px}\n.df-imp{margin-top:10px}\n.df-imp select{background:var(--sunk);color:var(--fg);border:1px solid var(--line);border-radius:6px;padding:6px 8px}\n.gh{display:flex;gap:8px;align-items:flex-start;font-size:12.5px;line-height:1.5;padding:7px 10px;margin-top:6px;border-radius:8px;background:var(--sunk)}\n.gh .dot{margin-top:6px;flex-shrink:0}\n\n/* ═════════ Stil 3.0: hell & minimal (Pill-Navigation, weiche Karten, Verlauf-Akzent) ═════════ */\n:root{\n  --bg:#efeef2; --surface:#ffffff; --raise:#f7f7f9; --sunk:#f2f1f5; --line:#e8e7ed; --line2:#dad9e1; --fg:#121215; --muted:#86858f;\n  --ink:#121215; --ink-fg:#ffffff;\n  --accent:#f0562b; --accent2:#ff8a4c; --accent-fg:#fff; --pos:#13a052; --neg:#e5484d; --warn:#d97a06; --fill:rgba(240,86,43,.10);\n  --pos-bg:rgba(19,160,82,.09); --neg-bg:rgba(229,72,77,.09); --warn-bg:rgba(217,122,6,.11);\n  --grad:linear-gradient(135deg,#ff8a4c 0%,#f0562b 55%,#e1401f 100%);\n  --shadow:0 1px 2px rgba(18,18,21,.04),0 10px 30px -14px rgba(18,18,21,.12);\n  --shadow-h:0 2px 4px rgba(18,18,21,.05),0 22px 44px -18px rgba(18,18,21,.22);\n  --glass:rgba(255,255,255,.86);\n  --r:22px; --r-s:14px;\n  --ease:cubic-bezier(.22,.8,.24,1);\n  --f-display:"Inter",system-ui,-apple-system,"Segoe UI",sans-serif;\n  --f-body:"Inter",system-ui,-apple-system,"Segoe UI",sans-serif;\n  --f-mono:"Inter",system-ui,-apple-system,"Segoe UI",sans-serif;\n  --f-code:"JetBrains Mono",ui-monospace,Menlo,Consolas,monospace;\n  color-scheme:light;\n}\n:root[data-theme=dark]{\n  --bg:#0b0b0d; --surface:#161618; --raise:#1c1c1f; --sunk:#121214; --line:#242428; --line2:#323238; --fg:#f2f2f4; --muted:#8c8c95;\n  --ink:#f2f2f4; --ink-fg:#111113;\n  --accent:#ff6a3d; --accent2:#ff9a5c; --pos:#3cc97f; --neg:#ff6369; --warn:#f5a524; --fill:rgba(255,106,61,.13);\n  --pos-bg:rgba(60,201,127,.11); --neg-bg:rgba(255,99,105,.11); --warn-bg:rgba(245,165,36,.12);\n  --shadow:0 1px 2px rgba(0,0,0,.3),0 12px 30px -16px rgba(0,0,0,.6);\n  --shadow-h:0 2px 4px rgba(0,0,0,.35),0 24px 48px -18px rgba(0,0,0,.75);\n  --glass:rgba(22,22,24,.88);\n  color-scheme:dark;\n}\nhtml{background:var(--bg)}\nbody{background:var(--bg);color:var(--fg);font:14px/1.5 var(--f-body);letter-spacing:-.006em;transition:background-color .4s var(--ease)}\n.mono,td,input[type=number]{font-family:var(--f-mono);font-variant-numeric:tabular-nums}\n.code,.logbox,.cv-raw pre,code{font-family:var(--f-code)!important}\n::selection{background:color-mix(in srgb,var(--accent) 25%,transparent)}\n::-webkit-scrollbar{width:10px;height:10px} ::-webkit-scrollbar-thumb{background:var(--line2);border-radius:6px;border:2px solid var(--bg)} ::-webkit-scrollbar-track{background:transparent}\n\n/* ── Kopfzeile ── */\n.top{position:sticky;top:0;z-index:20;background:color-mix(in srgb,var(--bg) 78%,transparent);backdrop-filter:saturate(1.4) blur(16px);-webkit-backdrop-filter:saturate(1.4) blur(16px);border-bottom:0}\n.wrap{max-width:1320px}\n.bar{display:grid;grid-template-columns:1fr auto 1fr;align-items:center;gap:16px;padding-block:14px}\n.brand{display:flex;align-items:center;gap:10px;font:700 15.5px var(--f-display);letter-spacing:-.02em;text-transform:none;color:var(--fg)}\n.brand i{width:34px;height:34px;border-radius:50%;background:var(--grad);display:grid;place-items:center;color:#fff;font:800 16px var(--f-display);font-style:normal;box-shadow:0 6px 16px -6px rgba(240,86,43,.7)}\n.brand i::before{content:"F"}\n.nav{position:relative;display:flex;gap:2px;margin:0;padding:5px;background:var(--surface);border-radius:999px;box-shadow:var(--shadow);border:1px solid var(--line)}\n.nav-ind{position:absolute;top:5px;bottom:5px;left:0;width:0;border-radius:999px;background:var(--ink);transition:left .45s var(--ease),width .45s var(--ease),opacity .2s;pointer-events:none;z-index:0;opacity:0}\n.nav button{position:relative;z-index:1;display:flex;align-items:center;gap:7px;padding:8px 15px;border:0;border-radius:999px;background:transparent;color:var(--muted);font:500 13.5px var(--f-body);letter-spacing:-.01em;text-transform:none;white-space:nowrap;transition:color .3s var(--ease)}\n.nav button svg{display:none;width:18px;height:18px}\n.nav button:hover{color:var(--fg)}\n.nav button[aria-current=true]{background:transparent;color:var(--ink-fg);box-shadow:none;font-weight:600}\n.nav.noind button[aria-current=true]{background:var(--ink)}\n.nav button em{display:none}\n.bar-r{display:flex;align-items:center;gap:10px;justify-content:flex-end}\n.icgrp{display:flex;align-items:center;gap:2px;padding:5px;background:var(--surface);border:1px solid var(--line);border-radius:999px;box-shadow:var(--shadow)}\n.ib{width:34px;height:34px;border-radius:50%;border:0;background:transparent;color:var(--fg);display:grid;place-items:center;padding:0;position:relative;transition:background .2s,transform .2s var(--ease)}\n.ib:hover{background:var(--sunk)} .ib:active{transform:scale(.92)}\n.ib svg{width:18px;height:18px}\n.ib .dot{position:absolute;top:7px;right:7px;width:7px;height:7px;box-shadow:0 0 0 2px var(--surface)}\n.prof{display:flex;align-items:center;gap:8px;padding:5px 5px 5px 14px;background:var(--surface);border:1px solid var(--line);border-radius:999px;box-shadow:var(--shadow)}\n.prof .switch{border:0;background:transparent;padding:0;gap:8px}\n.prof .switch b{font-size:13px;font-weight:600}\n#kill{border-radius:999px;padding:8px 14px;font-weight:600;background:var(--neg-bg);color:var(--neg);border:0}\n#kill:hover{background:var(--neg)!important;color:#fff}\n.tgl{width:42px;height:24px;background:var(--line2)}\n.tgl::after{top:3px;left:3px;width:18px;height:18px;transition:transform .35s var(--ease)}\n.tgl[aria-checked=true]{background:var(--pos)} .tgl[aria-checked=true]::after{transform:translateX(18px)}\n\n/* ── Seitenleiste ── */\n.rail{position:fixed;left:18px;top:50%;transform:translateY(-50%);z-index:15;display:none;flex-direction:column;gap:12px}\n.rail .icgrp{flex-direction:column;padding:5px}\n.rail .ib.on{background:var(--ink);color:var(--ink-fg)}\n@media (min-width:1240px){ .rail{display:flex} body{padding-left:64px} }\n\n/* ── Seitenkopf ── */\n.content{padding-top:6px}\n.phead{display:flex;justify-content:space-between;align-items:flex-end;gap:16px;flex-wrap:wrap;padding:18px 0 4px}\n.phead h1{margin:0;font:600 clamp(26px,3.4vw,40px)/1.1 var(--f-display);letter-spacing:-.035em;color:var(--fg)}\n.phead h1 .w{display:inline-block;white-space:pre}\n.phead p{margin:6px 0 0;color:var(--muted);font-size:14px}\n.status{padding-top:0;gap:6px;justify-content:flex-end}\n.status .hint{display:none}\n.pill{background:var(--surface)!important;border:1px solid var(--line)!important;border-radius:999px;font-size:12px;padding:5px 11px;color:var(--fg);box-shadow:var(--shadow)}\n.pill .dot{width:7px;height:7px}\n.dot{background:var(--line2)}\n.dot.ok{background:var(--pos);box-shadow:0 0 0 3px var(--pos-bg)} .dot.bad{background:var(--neg);box-shadow:0 0 0 3px var(--neg-bg)} .dot.warn{background:var(--warn);box-shadow:0 0 0 3px var(--warn-bg)}\n.banner{border-radius:var(--r-s);padding:12px 16px;background:var(--warn-bg);color:var(--fg);border:1px solid color-mix(in srgb,var(--warn) 25%,transparent);margin:12px 0 0}\nmain{gap:20px;padding-top:20px;padding-bottom:60px}\n\n/* ── Typo & Grundbausteine ── */\nh2,.section h2,.section-h h2,.section > .section-h h2,.section > h2{font:600 16.5px/1.3 var(--f-display);letter-spacing:-.02em;text-transform:none;color:var(--fg)}\nh3{letter-spacing:-.01em}\n.hint{color:var(--muted)}\n.panel,.kpis,.set-sec,.calbox,.daybox,.strip,.ch-big,.df-c,.chc,.pc,.cv-sec,.lo-c,.sug{background:var(--surface);border:1px solid var(--line);border-radius:var(--r);box-shadow:var(--shadow)}\n.panel{padding:20px 22px}\n.panel,.lo-c,.chc,.df-c,.hero-card{transition:transform .5s var(--ease),box-shadow .5s var(--ease)}\n.lift:hover,.lo-c:hover,.chc:hover,.df-c:hover{transform:translateY(-4px);box-shadow:var(--shadow-h)}\n.empty{border:1.5px dashed var(--line2);border-radius:var(--r-s);background:transparent}\n.btn{border-radius:999px;padding:8px 16px;font:500 13px var(--f-body);background:var(--surface);color:var(--fg);border:1px solid var(--line2);transition:transform .2s var(--ease),background .2s,border-color .2s,box-shadow .2s}\n.btn:hover:not(:disabled){border-color:var(--fg)}\n.btn:active:not(:disabled){transform:scale(.96)}\n.btn.primary{background:var(--ink);border-color:var(--ink);color:var(--ink-fg);box-shadow:none;font-weight:600}\n.btn.primary:hover:not(:disabled){filter:none;box-shadow:0 8px 20px -8px color-mix(in srgb,var(--ink) 60%,transparent)}\n.btn.good{background:var(--pos);border-color:var(--pos);color:#fff}\n.btn.danger{background:var(--neg-bg);color:var(--neg);border-color:transparent}\n.btn.danger:hover{background:var(--neg)!important;color:#fff;border-color:var(--neg)!important}\n.btn.ghost-danger{background:transparent;color:var(--neg);border-color:color-mix(in srgb,var(--neg) 40%,transparent)}\n.btn.accent{background:var(--grad);border:0;color:#fff;font-weight:600;box-shadow:0 8px 20px -10px rgba(240,86,43,.8)}\ninput,select,textarea{background:var(--raise);border:1px solid var(--line2);border-radius:12px;color:var(--fg);transition:border-color .2s,box-shadow .2s}\ninput:focus,select:focus,textarea:focus{outline:0;border-color:var(--fg);box-shadow:0 0 0 4px color-mix(in srgb,var(--fg) 8%,transparent)}\nbutton:focus-visible{outline:2px solid var(--accent);outline-offset:2px}\n.chip{border-radius:999px;padding:3px 9px;font-size:11.5px;font-weight:600;letter-spacing:0;background:var(--sunk);color:var(--fg)}\n.chip.good{background:var(--pos-bg);color:var(--pos)} .chip.bad{background:var(--neg-bg);color:var(--neg)} .chip.warn{background:var(--warn-bg);color:var(--warn)} .chip.mute{background:var(--sunk);color:var(--muted)}\n.seg{background:var(--sunk);border:0;border-radius:999px;padding:3px;gap:2px}\n.seg button{border:0;border-radius:999px;padding:6px 13px;font:500 12.5px var(--f-body);color:var(--muted);transition:background .3s var(--ease),color .3s}\n.seg button[aria-pressed="true"]{background:var(--surface);color:var(--fg);box-shadow:0 1px 3px rgba(0,0,0,.08);font-weight:600}\n.kpi .l,.lbl,th,.td-l,.strip .l,.ed-k .l,.mu .l,.chc .l,.ch-big .l,.pc-c .l,.drw .l,.rf-g .l,.td-g .l,.df-s small{font-size:11px!important;letter-spacing:.02em!important;text-transform:none!important;font-weight:500!important;color:var(--muted)}\nth{border-bottom-color:var(--line)} td{border-bottom-color:var(--line);font-size:13px}\ntbody tr{transition:background .2s} tbody tr:hover td{background:var(--raise)}\n.subtabs,.ln-tabs{display:flex;flex-wrap:wrap;align-items:center;gap:2px;border:1px solid var(--line);border-bottom:1px solid var(--line);background:var(--surface);border-radius:999px;padding:5px;margin:0;align-self:flex-start;box-shadow:var(--shadow);max-width:100%}\n.subtabs button,.ln-tabs button.sm{border:0;border-radius:999px;padding:7px 14px;margin:0;font:500 13px var(--f-body);color:var(--muted);transition:background .35s var(--ease),color .35s}\n.subtabs button:hover{color:var(--fg)}\n.subtabs button[aria-selected=true]{background:var(--ink);color:var(--ink-fg);border:0;font-weight:600}\n.ln-det{font-size:11px;letter-spacing:.02em;text-transform:none;color:var(--muted);margin:0 2px 0 6px;padding-left:10px;border-left:1px solid var(--line)}\n.toast{border-radius:999px;background:var(--ink);color:var(--ink-fg);padding:11px 20px;font-weight:500;box-shadow:var(--shadow-h);animation:toastIn .45s var(--ease)}\n@keyframes toastIn{from{opacity:0;transform:translate(-50%,16px) scale(.96)}}\n.modal-bg,.drw-bg{background:color-mix(in srgb,#0b0b0d 40%,transparent);backdrop-filter:blur(6px);animation:fade .3s}\n.modal{border-radius:var(--r);animation:pop .4s var(--ease)}\n@keyframes pop{from{opacity:0;transform:translateY(12px) scale(.97)}}\n.drw{border-radius:var(--r) 0 0 var(--r);border-left:1px solid var(--line);background:var(--surface);animation:slide .45s var(--ease)}\n.tr{background:var(--raise);border-radius:var(--r-s)}\n.feed div{border-bottom-color:var(--line)}\nsvg text{fill:var(--muted);font-family:var(--f-body);font-size:11px}\n.live-dot{background:var(--pos)}\n\n/* ── Cockpit-Hero ── */\n.hero{display:grid;grid-template-columns:minmax(0,1.05fr) minmax(0,1.1fr) minmax(0,1.15fr);gap:18px}\n.hero-card{background:var(--surface);border:1px solid var(--line);border-radius:var(--r);box-shadow:var(--shadow);padding:20px 22px;display:flex;flex-direction:column;gap:14px;min-width:0}\n.hero-card:hover{transform:translateY(-4px);box-shadow:var(--shadow-h)}\n.hc-top{display:flex;justify-content:space-between;align-items:center;gap:10px}\n.hc-top span{font-size:13.5px;color:var(--fg);font-weight:500}\n.hc-top small{font-size:12px;color:var(--muted)}\n.bal{font:600 clamp(30px,3.2vw,40px)/1.05 var(--f-display);letter-spacing:-.04em;font-variant-numeric:tabular-nums;white-space:nowrap}\n.delta{display:inline-flex;align-items:center;gap:6px;font-size:12px;color:var(--muted)}\n.delta b{font-size:11.5px;padding:2px 8px;border-radius:999px;font-weight:600}\n.delta b.pos{background:var(--pos-bg)} .delta b.neg{background:var(--neg-bg)} .delta b.zero{background:var(--sunk);color:var(--muted)}\n.hb-act{display:grid;grid-template-columns:1fr 1fr;gap:10px}\n.hb-act .btn{padding:12px 14px;display:flex;align-items:center;justify-content:center;gap:8px;font-weight:600}\n.hb-act .btn svg{width:16px;height:16px}\n.wal{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:8px;background:var(--raise);border-radius:var(--r-s);padding:8px;border:1px solid var(--line)}\n.wal>div{background:var(--surface);border-radius:11px;padding:9px 11px;display:flex;flex-direction:column;gap:2px;min-width:0;box-shadow:0 1px 2px rgba(0,0,0,.04)}\n.wal span{font-size:11.5px;color:var(--muted);display:flex;align-items:center;gap:6px}\n.wal span i{width:8px;height:8px;border-radius:50%;background:var(--line2)}\n.wal b{font-size:15px;font-weight:600;letter-spacing:-.02em;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-variant-numeric:tabular-nums}\n.tiles{display:grid;grid-template-columns:1fr 1fr;gap:12px;background:transparent;border:0;box-shadow:none;padding:0}\n.tiles:hover{transform:none;box-shadow:none}\n.tile{background:var(--surface);border:1px solid var(--line);border-radius:var(--r);box-shadow:var(--shadow);padding:16px 18px;display:flex;flex-direction:column;gap:6px;min-width:0;transition:transform .5s var(--ease),box-shadow .5s var(--ease)}\n.tile:hover{transform:translateY(-4px);box-shadow:var(--shadow-h)}\n.tile-h{display:flex;justify-content:space-between;align-items:center;font-size:12.5px;color:var(--muted)}\n.tile-h i{width:28px;height:28px;border-radius:50%;display:grid;place-items:center;background:var(--sunk);color:var(--fg)}\n.tile-h i svg{width:14px;height:14px}\n.tile b{font:600 clamp(24px,2.4vw,30px)/1.1 var(--f-display);letter-spacing:-.035em;font-variant-numeric:tabular-nums;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-top:auto}\n.tile small{font-size:11.5px;color:var(--muted);display:flex;align-items:center;gap:6px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\n.tile small em{font-style:normal;font-weight:600;font-size:11px;padding:1px 7px;border-radius:999px;background:var(--sunk);color:var(--fg)}\n.tile.hot{background:var(--grad);border:0;color:#fff;box-shadow:0 18px 36px -18px rgba(240,86,43,.85);position:relative;overflow:hidden}\n.tile.hot::after{content:"";position:absolute;inset:0;background:radial-gradient(120% 80% at 100% 0%,rgba(255,255,255,.28),transparent 55%);pointer-events:none}\n.tile.hot .tile-h,.tile.hot small{color:rgba(255,255,255,.85)}\n.tile.hot .tile-h i{background:rgba(255,255,255,.2);color:#fff}\n.tile.hot small em{background:rgba(255,255,255,.22);color:#fff}\n.tile.hot b{color:#fff!important}\n.tile.hot.neg{background:linear-gradient(135deg,#3a3a40,#17171a)} .tile.hot.neg{box-shadow:0 18px 36px -18px rgba(0,0,0,.6)}\n:root[data-theme=dark] .tile.hot.neg{background:linear-gradient(135deg,#2b2b30,#1d1d21);border:1px solid var(--line)}\n.hbars{display:flex;flex-direction:column;gap:10px}\n.bars-box{flex:1;display:flex;flex-direction:column;gap:8px;background:var(--raise);border:1px solid var(--line);border-radius:var(--r-s);padding:12px 12px 8px;min-height:180px}\n.bars-h{display:flex;justify-content:space-between;align-items:center;font-size:12px;color:var(--muted)}\n.bars-h b{color:var(--fg);font-weight:600;font-size:13px}\n.bars{flex:1;display:grid;grid-auto-flow:column;grid-auto-columns:minmax(0,1fr);gap:6px;align-items:stretch;min-height:130px;position:relative}\n.bars .col{position:relative;display:flex;flex-direction:column;justify-content:flex-end;align-items:center;gap:5px;min-width:0;cursor:default}\n.bars .stk{position:relative;width:min(100%,26px);flex:1;display:flex;flex-direction:column}\n.bars .up,.bars .dn{position:absolute;left:0;right:0;border-radius:7px;transform-origin:bottom;transition:filter .2s}\n.bars .up{background:var(--ink)}\n.bars .dn{transform-origin:top;background:repeating-linear-gradient(-45deg,var(--accent) 0 3px,color-mix(in srgb,var(--accent) 55%,transparent) 3px 6px)}\n.bars .col:hover .up,.bars .col:hover .dn{filter:brightness(1.25)}\n.bars .col.ph .stk{border-radius:7px;background:repeating-linear-gradient(0deg,transparent 0 6px,var(--line) 6px 7px);opacity:.6}\n.bars .zl{position:absolute;left:0;right:0;height:1px;background:var(--line2)}\n.bars .col small{font-size:10px;color:var(--muted);white-space:nowrap}\n.bars .tip{position:absolute;bottom:calc(100% + 4px);left:50%;transform:translate(-50%,4px);background:var(--ink);color:var(--ink-fg);font-size:11px;padding:4px 8px;border-radius:8px;white-space:nowrap;opacity:0;pointer-events:none;transition:opacity .2s,transform .25s var(--ease);z-index:3}\n.bars .col:hover .tip{opacity:1;transform:translate(-50%,0)}\n.bars .col:nth-last-child(-n+3) .tip{left:auto;right:0;transform:translate(0,4px)} .bars .col:nth-last-child(-n+3):hover .tip{transform:translate(0,0)}\n.bars .col:nth-child(-n+3) .tip{left:0;transform:translate(0,4px)} .bars .col:nth-child(-n+3):hover .tip{transform:translate(0,0)}\n.fresh .bars .up{animation:growUp .9s var(--ease) both;animation-delay:calc(var(--k,0)*45ms + .15s)}\n.fresh .bars .dn{animation:growDn .9s var(--ease) both;animation-delay:calc(var(--k,0)*45ms + .15s)}\n@keyframes growUp{from{transform:scaleY(0)}} @keyframes growDn{from{transform:scaleY(0)}}\n.bars-empty{flex:1;display:grid;place-items:center;text-align:center;color:var(--muted);font-size:12.5px}\n@media (max-width:1180px){ .hero{grid-template-columns:1fr 1fr} .hero .hero-card:last-child{grid-column:1/-1} }\n@media (max-width:720px){ .hero{grid-template-columns:1fr} .hero .hero-card:last-child{grid-column:auto} }\n\n/* Status-Karte (Tages-Stopp, Hinweise, Gesundheits-Check) */\n.stc{display:flex;flex-direction:column;gap:12px}\n.stc-row{display:flex;flex-wrap:wrap;gap:8px;align-items:center}\n.td-mt{height:10px;background:var(--sunk)}\n.td-mt i.p{background:var(--pos)} .td-mt i.n{background:repeating-linear-gradient(-45deg,var(--neg) 0 3px,color-mix(in srgb,var(--neg) 60%,transparent) 3px 6px)}\n.hc{border-top:1px solid var(--line);padding-top:12px}\n.hc-ch{color:var(--fg);font-weight:600}\n.hc-list{animation:fadeUp .45s var(--ease)}\n\n/* ── Einblenden & Übergänge ── */\n.in{animation:rise .75s var(--ease) both;animation-delay:calc(var(--i,0)*70ms)}\n@keyframes rise{from{opacity:0;transform:translateY(18px) scale(.985);filter:blur(8px)}}\n@keyframes fadeUp{from{opacity:0;transform:translateY(6px)}}\n.phead h1 .w{animation:word .8s var(--ease) both;animation-delay:calc(var(--w,0)*80ms)}\n.phead p.in2{animation:word .8s var(--ease) both;animation-delay:.25s}\n@keyframes word{from{opacity:0;filter:blur(10px);transform:translateY(8px)}}\ndetails>*:not(summary){animation:fadeUp .4s var(--ease)}\n::view-transition-old(root),::view-transition-new(root){animation:none;mix-blend-mode:normal}\n::view-transition-new(root){z-index:2} ::view-transition-old(root){z-index:1}\n@media (prefers-reduced-motion:reduce){ *,*::before,*::after{animation:none!important;transition:none!important} }\n\n/* ── Bereiche im Cockpit ── */\n.ck-more{margin-top:4px}\n.ck-more>summary{cursor:pointer;list-style:none;display:flex;align-items:center;justify-content:center;gap:8px;color:var(--muted);font-size:13px;letter-spacing:0;text-transform:none;padding:12px;border:1px dashed var(--line2);border-radius:999px;transition:color .2s,border-color .2s,background .2s}\n.ck-more>summary:hover{color:var(--fg);border-color:var(--fg)}\n.ck-more>summary::before{content:"+";font-weight:600;color:var(--accent);transition:transform .3s var(--ease);display:inline-block}\n.ck-more[open]>summary::before{content:"+";transform:rotate(45deg)}\n.ck-more[open]>summary{margin-bottom:16px}\n.sug{border-left:0;position:relative;overflow:hidden}\n.sug::before{content:"";position:absolute;left:0;top:0;bottom:0;width:4px;background:var(--accent)}\n.sug.long::before{background:var(--pos)} .sug.short::before{background:var(--neg)}\n.pc{border-left:0;position:relative;overflow:hidden} .pc::before{content:"";position:absolute;left:0;top:0;bottom:0;width:4px;background:var(--pos)} .pc.short::before{background:var(--neg)}\n.pc-g,.drw-st,.ed-k{border-radius:var(--r-s)}\n.chc{padding:18px 22px}\n.strip,.ch-big{overflow:hidden}\n.day{border-radius:14px;background:var(--raise);transition:transform .35s var(--ease),box-shadow .35s var(--ease),border-color .2s}\n.day:hover{transform:translateY(-3px);box-shadow:var(--shadow-h)}\n.day.win{background:linear-gradient(180deg,var(--pos-bg),transparent);border-color:color-mix(in srgb,var(--pos) 30%,transparent)}\n.day.loss{background:linear-gradient(180deg,var(--neg-bg),transparent);border-color:color-mix(in srgb,var(--neg) 30%,transparent)}\n.day.today .dn b{background:var(--ink);color:var(--ink-fg);border-radius:999px;padding:0 7px}\n.day.sel{border-color:var(--ink)!important;box-shadow:0 0 0 1px var(--ink),var(--shadow-h)}\n.wk{border-radius:14px}\n.calbox{padding:10px}\ndetails.set-sec > summary{border-radius:var(--r)}\ndetails.set-sec[open] > summary{border-radius:var(--r) var(--r) 0 0}\n.s-ic{border-radius:12px;background:var(--sunk);color:var(--fg)}\ndetails.set-sec[open] .s-ic{background:var(--ink);color:var(--ink-fg)}\n.savebar{border-radius:999px;border:0;background:var(--ink);color:var(--ink-fg);box-shadow:var(--shadow-h);animation:pop .4s var(--ease)}\n.savebar .hint{color:color-mix(in srgb,var(--ink-fg) 70%,transparent)}\n.savebar .btn{border-color:transparent}\n.savebar .btn.primary{background:var(--grad);color:#fff}\n.code{background:var(--raise)!important;border:1px solid var(--line)!important;border-radius:12px}\n.preview{border-radius:12px}\n.perf-stats div,.spark{border-radius:14px;background:var(--raise)}\n.perf-stats span{font-size:11.5px;letter-spacing:0;text-transform:none;color:var(--muted)} .perf-stats b{font-size:19px;font-weight:600;letter-spacing:-.02em}\n.ring svg circle:first-child{stroke:var(--sunk)}\n.hbar-t,.meter,.prog,.pbar,.wl,.mc-bar,.td-mt,.ci,.trk-b{border-radius:999px}\n.content.wide{max-width:none}\n.login form{border-radius:var(--r);box-shadow:var(--shadow-h);padding:30px}\n.login h1{font-weight:700;letter-spacing:-.03em}\n.login h1::before{content:"F";display:inline-grid;place-items:center;width:38px;height:38px;border-radius:50%;background:var(--grad);color:#fff;font-size:18px;margin-right:10px;vertical-align:middle}\n\n/* ── Chart ── */\n.cv{padding-top:0}\n.cv-bar{display:flex;flex-wrap:wrap;align-items:center;gap:10px 14px;padding:10px 14px;border:1px solid var(--line);border-radius:999px;background:var(--surface);box-shadow:var(--shadow);margin-bottom:14px}\n.cv-f{display:flex;align-items:center;gap:6px}\n.cv-f>span{font-size:12px;color:var(--muted)}\n.cv-f select,.cv-f input{padding:5px 10px;font:500 12.5px var(--f-body);border-radius:999px}\n.cv-f .ibtn{width:28px;height:28px;border-radius:50%;border:1px solid var(--line2);background:var(--surface);color:var(--fg);font-size:15px;line-height:1}\n.cv-tf{display:flex;gap:2px;background:var(--sunk);padding:3px;border-radius:999px}\n.cv-tf button{border:0;background:transparent;color:var(--muted);font:600 12px var(--f-body);padding:4px 9px;border-radius:999px;transition:background .3s var(--ease),color .3s}\n.cv-tf button[aria-pressed=true]{background:var(--ink);color:var(--ink-fg)}\n.cv-info{font-size:12.5px;color:var(--muted)} .cv-info b{color:var(--fg)} .cv-info b.acc,.cv-info .live{color:var(--accent)}\n.cv-hint{margin-left:auto;font-size:11.5px;color:var(--muted)}\n.cv-main{display:grid;grid-template-columns:minmax(0,1fr) 300px;gap:14px}\n.cv-wrap{position:relative;height:calc(100vh - 250px);min-height:440px;border:1px solid var(--line);background:var(--surface);border-radius:var(--r);overflow:hidden;box-shadow:var(--shadow)}\n.cv-wrap canvas{display:block;cursor:crosshair;touch-action:none;outline:none}\n.cv-ohlc{position:absolute;left:12px;top:10px;font-size:11.5px;color:var(--muted);pointer-events:none;background:var(--glass);backdrop-filter:blur(6px);padding:3px 9px;border-radius:999px}\n.cv-ohlc b{color:var(--fg);margin-right:6px} .cv-ohlc .acc{color:var(--accent)} .cv-ohlc span{color:var(--fg)}\n.cv-msg{position:absolute;left:50%;top:40%;transform:translate(-50%,-50%);background:var(--surface);border:1px solid var(--line);padding:14px 18px;border-radius:var(--r-s);color:var(--muted);max-width:70%;text-align:center;box-shadow:var(--shadow)}\n.cv-side{display:flex;flex-direction:column;gap:14px;max-height:calc(100vh - 250px);overflow:auto}\n.cv-sec{padding:14px 16px}\n.cv-sec h3{margin:0 0 10px;font:600 13.5px var(--f-display);letter-spacing:-.01em;text-transform:none;color:var(--fg)}\n.cv-lay{display:flex;flex-direction:column;gap:2px}\n.cv-li{display:grid;grid-template-columns:16px 8px 1fr auto;gap:8px;align-items:center;font-size:12.5px;padding:4px 0;cursor:pointer}\n.cv-li input{accent-color:var(--ink);margin:0}\n.cv-li i{width:8px;height:8px;border-radius:50%}\n.cv-li b{font-size:11px;color:var(--muted);font-weight:500}\n.cv-lb{display:flex;gap:6px;margin-top:8px} .cv-lb .btn{padding:4px 10px;font-size:11.5px}\n.cv-ik{font-weight:600;color:var(--accent);margin-bottom:8px;font-size:13px}\n.cv-kv{display:grid;grid-template-columns:auto 1fr;gap:5px 12px;margin:0;font-size:12.5px}\n.cv-kv dt{color:var(--muted)} .cv-kv dd{margin:0;text-align:right;word-break:break-word}\n.cv-raw pre{font-size:10.5px;white-space:pre-wrap;color:var(--muted);max-height:220px;overflow:auto;margin:6px 0 0}\n@media (max-width:980px){ .cv-main{grid-template-columns:1fr} .cv-side{max-height:none} .cv-hint{display:none} .cv-wrap{height:62vh} .cv-bar{border-radius:var(--r)} }\n\n/* ── Lernmodul-Übersicht ── */\n.lo-top{display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap}\n.lo-st{display:flex;gap:10px;align-items:center;flex-wrap:wrap}\n.lo-g{display:grid;grid-template-columns:repeat(auto-fill,minmax(320px,1fr));gap:16px}\n.lo-c{padding:18px 20px}\n.lo-h{display:flex;justify-content:space-between;align-items:center;margin-bottom:12px}\n.lo-h h3{margin:0;font:600 15px var(--f-display);letter-spacing:-.015em;text-transform:none;color:var(--fg)}\n.lnk{background:none;border:0;color:var(--muted);font:500 12.5px var(--f-body);padding:4px 10px;border-radius:999px;transition:background .2s,color .2s}\n.lnk:hover{color:var(--ink-fg);background:var(--ink);text-decoration:none}\n.lo-l{display:flex;flex-direction:column;gap:8px}\n.lo-r{display:flex;gap:6px;align-items:center;flex-wrap:wrap;font-size:13px} .lo-r>span:first-child{margin-right:auto}\n.lo-log{display:flex;flex-direction:column;gap:8px;font-size:13px;line-height:1.5}\n\n/* ── Feinschliff einzelner Bausteine ── */\n.hbar-l .chip{align-self:flex-start}\n.wd div.ok{background:var(--pos-bg);color:var(--pos)} .gB{background:var(--sunk);color:var(--fg)} .gA{background:var(--ink);color:var(--ink-fg)}\n.wd div,.hrs div{border-radius:10px}\n.nw.next{background:var(--fill)} .nw-box{padding:4px 0}\n.cv-bar{border-radius:var(--r)}\n.cv-hint{display:none}\n.td-ml{margin-bottom:4px}\n.stc .chip .dot{width:7px;height:7px;vertical-align:0}\n\n/* ── Handy ── */\n@media (max-width:1060px){ .nav button{padding:8px 11px;font-size:13px} .prof .switch b{display:none} }\n@media (max-width:900px){\n  .top{backdrop-filter:none;-webkit-backdrop-filter:none;background:var(--bg)}\n  .bar{grid-template-columns:1fr auto;padding-block:10px}\n  .brand span{display:none}\n  .nav{position:fixed;left:50%;transform:translateX(-50%);bottom:max(12px,env(safe-area-inset-bottom,0px));top:auto;z-index:30;order:initial;width:auto;max-width:calc(100% - 20px);margin:0;display:flex;grid-template-columns:none;overflow:visible;background:var(--glass);backdrop-filter:saturate(1.5) blur(18px);-webkit-backdrop-filter:saturate(1.5) blur(18px);box-shadow:0 12px 40px -12px rgba(0,0,0,.35);padding:6px}\n  .nav button{flex-direction:column;gap:2px;padding:7px 10px;font-size:10px;min-width:0}\n  .nav button svg{display:block;width:20px;height:20px}\n  .nav button span{display:none!important}\n  .nav button em{display:inline;font-style:normal;font-size:10px;white-space:nowrap}\n  main{padding-bottom:110px}\n  .phead{padding-top:8px}\n  .status{justify-content:flex-start}\n  .toast{bottom:calc(max(12px,env(safe-area-inset-bottom,0px)) + 76px)}\n  .savebar{bottom:calc(max(12px,env(safe-area-inset-bottom,0px)) + 76px)}\n}\n@media (max-width:640px){\n  .phead>div:first-child{width:100%}\n  .status{flex-wrap:nowrap;overflow-x:auto;width:calc(100% + 32px);margin:0 -16px;padding:2px 16px 8px;scrollbar-width:none}\n  .status::-webkit-scrollbar{display:none}\n  .pill{flex:none}\n  .subtabs,.ln-tabs{flex-wrap:nowrap;overflow-x:auto;scrollbar-width:none;align-self:stretch}\n  .subtabs::-webkit-scrollbar{display:none}\n  .subtabs button,.ln-tabs button.sm{flex:none}\n  .ln-det{display:none}\n}\n@media (max-width:480px){\n  .nav button{padding:7px 7px} .nav button em{font-size:9.5px}\n  .prof{padding-left:10px} #kill{padding:7px 11px}\n  .panel{padding:16px} .hero-card{padding:16px}\n  .wal b{font-size:13.5px}\n}\n</style>\n</head>\n<body>\n<div id="app"></div>\n<div id="toast" class="toast" hidden></div>\n\n<script>\nconst $ = (s, el = document) => el.querySelector(s);\nconst esc = s => String(s ?? "").replace(/[&<>"\']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",\'"\':"&quot;","\'":"&#39;"}[c]));\nconst usd = v => v == null || !isFinite(v) ? "–" : (v < 0 ? "−$" : "$") + Math.abs(v).toLocaleString("de-DE", {maximumFractionDigits: 0});\nconst usd2 = v => v == null || !isFinite(v) ? "–" : (v < 0 ? "−$" : "$") + Math.abs(v).toLocaleString("de-DE", {minimumFractionDigits: 2, maximumFractionDigits: 2});\nconst px = v => v == null ? "–" : Number(v).toLocaleString("de-DE", {minimumFractionDigits: 2, maximumFractionDigits: 2});\nconst pct = v => v == null || !isFinite(v) ? "–" : v.toFixed(1).replace(".", ",") + " %";\nconst num2 = v => v == null || !isFinite(v) ? "–" : v.toFixed(2).replace(".", ",");\nconst cls = v => v > 0 ? "pos" : v < 0 ? "neg" : "";\nconst tm = ts => new Date(ts * 1000).toLocaleTimeString("de-DE", {hour: "2-digit", minute: "2-digit"});\nconst dtm = ts => new Date(ts * 1000).toLocaleString("de-DE", {day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit"});\n\n// Reiter in der Adresse merken, ohne neue Verlaufseinträge (sonst darf sich das App-Fenster nicht schließen)\nconst setHash = t => { try { history.replaceState(null, "", "#" + t); } catch (e) { location.hash = t; } };\nlet S = null, TAB = "cockpit", pendingKey = null, seenPending = new Set(), firstLoad = true, settingsDirty = false;\n\nasync function api(path, body) {\n  const opt = body === undefined ? {} : {method: "POST", headers: {"Content-Type": "application/json", "X-Requested-With": "fvg"}, body: JSON.stringify(body)};\n  const r = await fetch(path, opt);\n  const j = await r.json().catch(() => ({}));\n  if (r.status === 401 && !path.startsWith("/api/login")) { showLogin(); throw new Error("Bitte anmelden"); }\n  if (!r.ok) throw new Error(j.error || "Fehler " + r.status);\n  return j;\n}\nfunction toast(msg) {\n  const t = $("#toast"); t.textContent = msg; t.hidden = false;\n  clearTimeout(toast._t); toast._t = setTimeout(() => t.hidden = true, 3200);\n}\nasync function act(fn, okMsg) {\n  try { const r = await fn(); if (okMsg) toast(okMsg); await refresh(); return r; }\n  catch (e) { toast(e.message); }\n}\n\nfunction copyText(txt, label) {\n  const fallback = () => { const ta = document.createElement("textarea"); ta.value = txt; document.body.appendChild(ta); ta.select();\n    try { document.execCommand("copy"); toast((label || "Text") + " kopiert"); } catch (e) { toast("Bitte manuell kopieren"); } ta.remove(); };\n  if (navigator.clipboard) navigator.clipboard.writeText(txt).then(() => toast((label || "Text") + " kopiert"), fallback); else fallback();\n}\n\n\nasync function serviceSet(on) {\n  document.body.insertAdjacentHTML("beforeend", `<div id="svcOv" style="position:fixed;inset:0;z-index:50;background:var(--bg);display:grid;place-items:center;padding:16px">\n    <div style="text-align:center;max-width:420px;display:flex;flex-direction:column;gap:10px;align-items:center">\n      <h2 style="font-size:20px" id="svcT2">${on ? "Dienst wird eingerichtet …" : "Dienst wird entfernt …"}</h2>\n      <p class="hint" id="svcMsg" style="margin:0">Bitte die Windows-Rückfrage nach Administratorrechten mit „Ja“ bestätigen.</p><div id="svcAct"></div></div></div>`);\n  const msg = (t, m, close) => { $("#svcT2").textContent = t; $("#svcMsg").innerHTML = m;\n    $("#svcAct").innerHTML = close ? \'<button class="btn" id="svcClose">Schließen</button>\' : ""; if (close) $("#svcClose").onclick = () => { $("#svcOv").remove(); render(true); }; };\n  try { await api("/api/service", {on}); }\n  catch (e) { return msg(on ? "Einrichten fehlgeschlagen" : "Entfernen fehlgeschlagen", esc(e.message), true); }\n  if (!on) { S = await api("/api/state"); return msg("Dienst entfernt", "FVG Trader startet nicht mehr automatisch beim Hochfahren. Die App läuft weiter, bis du sie beendest oder der PC neu startet. Für den Start nach der Anmeldung kannst du „Mit Windows starten“ wieder einschalten.", true); }\n  msg("Dienst eingerichtet", "Der Dienst startet jetzt und übernimmt. Das dauert ein paar Sekunden …");\n  const t0 = Date.now();\n  while (Date.now() - t0 < 90000) {\n    await new Promise(r => setTimeout(r, 2000));\n    try { const v = await fetch("/api/version", {cache: "no-store"}).then(r => r.json()); if (v.service) { location.reload(); return; } } catch (e) { /* Übergabe läuft */ }\n  }\n  msg("Dienst eingerichtet", "Er startet spätestens beim nächsten Hochfahren. Falls die App gerade nicht reagiert: Seite neu laden.", true);\n}\nasync function runUpdate(doIt) {\n  const before = S && S.version;\n  document.body.insertAdjacentHTML("beforeend", `<div id="updOv" style="position:fixed;inset:0;z-index:50;background:var(--bg);display:grid;place-items:center;padding:16px">\n    <div style="text-align:center;max-width:380px;display:flex;flex-direction:column;gap:10px;align-items:center">\n      <h2 style="font-size:20px" id="updT">Update wird geladen …</h2>\n      <p class="hint" id="updMsg" style="margin:0">Die neue Version wird heruntergeladen und geprüft.</p>\n      <div id="updAct"></div></div></div>`);\n  const msg = (t, m, act) => { $("#updT").textContent = t; $("#updMsg").innerHTML = m; $("#updAct").innerHTML = act || ""; };\n  let res;\n  try { res = await doIt(); } catch (e) {\n    msg("Update fehlgeschlagen", esc(e.message), \'<button class="btn" id="updClose">Schließen</button>\');\n    $("#updClose").onclick = () => $("#updOv").remove(); return;\n  }\n  const target = res && res.version;\n  msg("Neustart …", `Version <b>${esc(target || "neu")}</b> ist installiert. FVG Trader startet neu, das dauert ein paar Sekunden.`);\n  const t0 = Date.now();\n  let kills = 0;\n  const poll = async () => {\n    const secs = (Date.now() - t0) / 1000;\n    try {\n      const r = await fetch("/api/state", {cache: "no-store"});\n      if (r.status === 401) { location.reload(); return; }\n      if (r.ok) {\n        const j = await r.json();\n        if (j.version !== before) { location.reload(); return; }\n        if (secs > 12 && kills < 5) {   // eine alte Instanz antwortet noch: beenden, die neue übernimmt\n          kills++;\n          msg("Räume auf …", "Eine ältere FVG-Trader-Instanz läuft noch im Hintergrund und wird beendet.");\n          try { await fetch("/api/shutdown", {method: "POST", headers: {"X-Requested-With": "fvg", "Content-Type": "application/json"}, body: "{}"}); } catch (e) {}\n        }\n      }\n    } catch (e) {}\n    if (secs > 30) {\n      msg("Update installiert ✓", `Version <b>${esc(target || "neu")}</b> ist installiert.<br>Schließ dieses Fenster und starte FVG Trader über das <b>Desktop-Symbol</b>.`,\n        \'<button class="btn" id="updRetry">Erneut verbinden</button>\');\n      $("#updRetry").onclick = () => location.reload(); return;\n    }\n    setTimeout(poll, 1000);\n  };\n  setTimeout(poll, 2000);\n}\nasync function startupUpdatePrompt() {\n  if (!S.config.update_url) return;\n  let u;\n  try { u = await api("/api/update/check", {}); } catch (e) { return; }\n  if (!u.available) return;\n  try { if (sessionStorage.getItem("fvg-upd-asked") === u.version) return; sessionStorage.setItem("fvg-upd-asked", u.version); } catch (e) {}\n  document.body.insertAdjacentHTML("beforeend", `<div id="updAsk" role="dialog" aria-modal="true" aria-labelledby="updAskT"\n    style="position:fixed;inset:0;z-index:40;background:rgba(10,12,20,.55);display:grid;place-items:center;padding:16px">\n    <div class="panel" style="max-width:400px;width:100%;display:flex;flex-direction:column;gap:12px;box-shadow:0 20px 50px rgba(0,0,0,.3)">\n      <h2 id="updAskT" style="font-size:19px">Update verfügbar</h2>\n      <p style="margin:0">Version <b>${esc(u.version)}</b> ist da (installiert: ${esc(S.version)}).${u.notes ? `<br><span class="hint">${esc(u.notes)}</span>` : ""}</p>\n      <p class="hint" style="margin:0">Jetzt aktualisieren? Deine Einstellungen und Trades bleiben erhalten.</p>\n      <div class="actions"><button class="btn primary" id="updYes">Ja, jetzt aktualisieren</button><button class="btn" id="updNo">Nein</button></div>\n    </div></div>`);\n  $("#updYes").focus();\n  $("#updNo").onclick = () => $("#updAsk").remove();\n  $("#updYes").onclick = () => { $("#updAsk").remove(); runUpdate(() => api("/api/update/apply", {})); };\n}\n\n/* ───────── Login ───────── */\nasync function showLogin() {\n  const a = await fetch("/api/auth").then(r => r.json());\n  const setup = !a.has_password;\n  $("#app").innerHTML = `<div class="login"><form id="lf">\n    <h1>FVG Trader</h1>\n    <p class="hint">${setup ? "Lege ein Passwort fest. Es schützt die App, sobald sie über das Internet erreichbar ist." : "Melde dich an, um deinen Bot zu steuern."}</p>\n    <input id="pw" type="password" autocomplete="${setup ? "new-password" : "current-password"}" placeholder="Passwort${setup ? " (mind. 8 Zeichen)" : ""}" required>\n    <button class="btn primary" type="submit">${setup ? "Passwort festlegen" : "Anmelden"}</button>\n    <p id="lerr" class="err-msg" hidden></p></form></div>`;\n  $("#pw").focus();\n  $("#lf").onsubmit = async e => {\n    e.preventDefault();\n    try { await api(setup ? "/api/setup" : "/api/login", {password: $("#pw").value}); start(); }\n    catch (err) { $("#lerr").textContent = err.message; $("#lerr").hidden = false; }\n  };\n}\n\n/* ───────── Gerüst ───────── */\nconst NAV = [\n  ["cockpit", "Cockpit", \'<path d="M4 15a8 8 0 1 1 16 0"/><path d="M12 15l4.5-4.5"/><circle cx="12" cy="15" r="1.2"/>\'],\n  ["chart", "Chart", \'<path d="M4 19h16"/><path d="M7 15V9M7 9V7M12 13V6M12 6V4M17 16v-5M17 11V9"/><rect x="5.5" y="9" width="3" height="5" rx=".5"/><rect x="10.5" y="6" width="3" height="6" rx=".5"/><rect x="15.5" y="11" width="3" height="4" rx=".5"/>\'],\n  ["calendar", "Kalender", \'<rect x="4" y="5" width="16" height="15" rx="2.5"/><path d="M4 10h16M9 3v4M15 3v4"/>\'],\n  ["stats", "Statistik", \'<path d="M5 19v-7M12 19V5M19 19v-10"/>\'],\n  ["challenge", "Fremdkapital", \'<path d="M3 8.5 12 4l9 4.5"/><path d="M5 10v7M9.5 10v7M14.5 10v7M19 10v7M3.5 20h17"/>\'],\n  ["learn", "Lernmodul", \'<path d="M12 3.5l2.3 4.8 5.2.7-3.8 3.7.9 5.2L12 15.4 7.4 17.9l.9-5.2-3.8-3.7 5.2-.7z"/>\'],\n  ["settings", "Einstellungen", \'<circle cx="12" cy="12" r="3"/><path d="M12 3v2.5M12 18.5V21M3 12h2.5M18.5 12H21M5.6 5.6l1.8 1.8M16.6 16.6l1.8 1.8M5.6 18.4l1.8-1.8M16.6 7.4l1.8-1.8"/>\'],\n];\nconst icon = d => `<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${d}</svg>`;\nconst PAGES = {\n  chart: ["Chart", "Kerzen mit allen Signalen, Trades, Zonen und Liquidität"],\n  calendar: ["Kalender", "Jeder Handelstag auf einen Blick, mit Trades und Journal"],\n  stats: ["Statistik", "Wie gut der Bot wirklich ist, über Tage, Wochen und Sessions"],\n  challenge: ["Fremdkapital", "Wie viel Puffer du noch hast und wie viel bis zum Ziel fehlt"],\n  learn: ["Lernmodul", "Was der Bot selbst gelernt und umgesetzt hat"],\n  settings: ["Einstellungen", "Verbindung, Risiko, Broker und alles Weitere"],\n};\nconst I = {\n  sun: \'<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>\',\n  moon: \'<path d="M20 14.5A8 8 0 0 1 9.5 4a8 8 0 1 0 10.5 10.5z"/>\',\n  log: \'<path d="M6 4h9l4 4v12H6z"/><path d="M15 4v4h4M9 12h7M9 16h5"/>\',\n  reload: \'<path d="M20 11a8 8 0 1 0-2.3 5.7"/><path d="M20 5v6h-6"/>\',\n  pause: \'<rect x="7" y="5" width="3.5" height="14" rx="1"/><rect x="13.5" y="5" width="3.5" height="14" rx="1"/>\',\n  play: \'<path d="M8 5l11 7-11 7z"/>\',\n  candle: \'<path d="M7 4v16M17 4v16"/><rect x="5" y="8" width="4" height="7" rx="1"/><rect x="15" y="6" width="4" height="9" rx="1"/>\',\n  bolt: \'<path d="M13 3 5 14h6l-1 7 8-11h-6z"/>\',\n  target: \'<circle cx="12" cy="12" r="8"/><circle cx="12" cy="12" r="4"/><circle cx="12" cy="12" r=".8"/>\',\n  signal: \'<path d="M4 18c3-8 5-8 8 0s5 8 8 0" transform="translate(0 -6)"/>\',\n  trend: \'<path d="M4 16l5-5 4 4 7-7"/><path d="M15 8h5v5"/>\',\n};\nconst theme = () => document.documentElement.dataset.theme === "dark" ? "dark" : "light";\nfunction setTheme(t, ev) {\n  if (t === theme()) return;\n  try { localStorage.setItem("fvg-theme", t); } catch (e) {}\n  const apply = () => { if (t === "dark") document.documentElement.dataset.theme = "dark"; else delete document.documentElement.dataset.theme;\n    const m = document.querySelector(\'meta[name="theme-color"]\'); if (m) m.content = t === "dark" ? "#0b0b0d" : "#efeef2";\n    themeButtons(); if (TAB === "chart" && typeof cvDraw === "function") try { cvDraw(); } catch (e) {} };\n  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;\n  if (!document.startViewTransition || reduce) { apply(); return; }\n  const x = ev && ev.clientX != null ? ev.clientX : innerWidth - 40, y = ev && ev.clientY != null ? ev.clientY : 40;\n  const r = Math.hypot(Math.max(x, innerWidth - x), Math.max(y, innerHeight - y));\n  const vt = document.startViewTransition(apply);\n  vt.ready.then(() => document.documentElement.animate({clipPath: [`circle(0px at ${x}px ${y}px)`, `circle(${r}px at ${x}px ${y}px)`]},\n    {duration: 750, easing: "cubic-bezier(.65,0,.35,1)", pseudoElement: "::view-transition-new(root)"})).catch(() => {});\n}\nfunction themeButtons() {\n  const t = theme();\n  document.querySelectorAll("[data-theme-set]").forEach(b => { b.classList.toggle("on", b.dataset.themeSet === t); b.setAttribute("aria-pressed", b.dataset.themeSet === t); });\n  const tb = $("#thT"); if (tb) { tb.innerHTML = icon(t === "dark" ? I.sun : I.moon); tb.title = t === "dark" ? "Hell" : "Dunkel"; }\n}\nfunction navInd() {\n  const nav = $(".nav"), ind = $(".nav-ind"), cur = nav && nav.querySelector(\'[aria-current="true"]\');\n  if (!nav || !ind || !cur) return;\n  if (getComputedStyle(nav).position === "fixed") {   // Handy: Leiste unten, Pille hinter dem aktiven Symbol\n    ind.style.top = "6px"; ind.style.bottom = "6px";\n  } else { ind.style.top = ""; ind.style.bottom = ""; }\n  ind.style.left = cur.offsetLeft + "px"; ind.style.width = cur.offsetWidth + "px"; ind.style.opacity = 1;\n}\nfunction greet() {\n  const h = new Date().getHours();\n  return h < 5 ? "Gute Nacht" : h < 11 ? "Guten Morgen" : h < 18 ? "Guten Tag" : "Guten Abend";\n}\nfunction pageHead(animate) {\n  const ph = $("#phead"); if (!ph) return;\n  const [title, sub] = TAB === "cockpit" ? [greet() + ".", ""] : PAGES[TAB] || ["", ""];\n  const key = TAB + "|" + title;\n  if (pageHead._k !== key || animate) {\n    pageHead._k = key;\n    $("#pTitle").innerHTML = title.split(/(\\s+)/).map((w, i) => /^\\s+$/.test(w) ? w : `<span class="w" style="--w:${i / 2}">${esc(w)}</span>`).join("");\n    if (!animate) $("#pTitle").querySelectorAll(".w").forEach(w => w.style.animation = "none");\n  }\n  const p = $("#pSub");\n  const txt = TAB === "cockpit" ? cockpitLine() : sub;\n  if (p.textContent !== txt) { p.textContent = txt; }\n  if (animate) { p.classList.remove("in2"); void p.offsetWidth; p.classList.add("in2"); }\n}\nfunction cockpitLine() {\n  const c = S.config, ds = (S.summary && S.summary.daystop) || {};\n  const st = c.paused ? "Der Handel ist pausiert" : ds.hit ? (ds.hit === "ziel" ? "Tagesziel erreicht, für heute ist Schluss" : "Tages-Stopp erreicht, für heute ist Schluss")\n    : S.news_pause ? "News-Pause, gerade keine neuen Trades" : !S.session_open ? "Gerade läuft keine Session, der Bot wartet"\n    : c.auto_mode ? `Der Bot handelt automatisch in ${S.session_name}` : `Der Bot schickt Vorschläge in ${S.session_name}`;\n  return st + ".";\n}\nfunction shell() {\n  $("#app").innerHTML = `\n  <header class="top"><div class="wrap bar">\n    <div class="brand"><i aria-hidden="true"></i><span>FVG Trader</span></div>\n    <nav class="nav" aria-label="Bereiche"><span class="nav-ind" aria-hidden="true"></span>${NAV.map(([k, l, d]) => `<button type="button" data-tab="${k}" aria-current="${k === TAB}" title="${l}">${icon(d)}<span>${l}</span><em>${{challenge: "Kapital", learn: "Lernen", settings: "Mehr", calendar: "Kalender", stats: "Statistik"}[k] || l}</em></button>`).join("")}</nav>\n    <div class="bar-r">\n      <div class="icgrp"><button class="ib" id="tvB" type="button" title="TradingView-Verbindung">${icon(I.signal)}<span class="dot" id="pDot"></span></button><button class="ib" id="thT" type="button"></button></div>\n      <div class="prof"><div class="switch"><b id="autoLbl">Auto</b><button class="tgl" id="autoT" role="switch" aria-checked="false" aria-labelledby="autoLbl"></button></div>\n      <button class="btn danger" id="kill">Notaus</button></div>\n    </div>\n  </div></header>\n  <aside class="rail" aria-label="Werkzeuge">\n    <div class="icgrp"><button class="ib" type="button" data-theme-set="light" title="Hell">${icon(I.sun)}</button><button class="ib" type="button" data-theme-set="dark" title="Dunkel">${icon(I.moon)}</button></div>\n    <div class="icgrp"><button class="ib" type="button" id="rLog" title="App-Protokoll">${icon(I.log)}</button><button class="ib" type="button" id="rReload" title="Neu laden">${icon(I.reload)}</button></div>\n  </aside>\n  <div class="content wrap">\n    <div class="phead" id="phead"><div><h1 id="pTitle"></h1><p id="pSub"></p></div>\n      <div class="status"><span class="pill" id="pTv"></span><span class="pill" id="pBroker"></span><span class="pill" id="pSess"></span><span class="pill news-pill" id="pNews" hidden></span><span class="hint" id="pVer"></span></div></div>\n    <div id="banner"></div><main id="main"></main>\n  </div>`;\n  document.querySelectorAll("[data-tab]").forEach(b => b.onclick = () => { if (b.dataset.tab === TAB) return; if ($("#dayDrw")) closeDay(); TAB = b.dataset.tab; setHash(TAB); pendingKey = null; settingsDirty = false;\n    window.scrollTo({top: 0}); render(true); });\n  $("#autoT").onclick = () => act(() => api("/api/config", {auto_mode: !S.config.auto_mode}),\n    !S.config.auto_mode ? "Auto-Modus an: Signale werden direkt ausgeführt" : "Auto-Modus aus: Signale kommen als Vorschlag");\n  $("#kill").onclick = () => confirmBtn($("#kill"), "Wirklich alles schließen?", () =>\n    act(() => api("/api/flatten", {}), "Alles geschlossen, Handel pausiert"));\n  document.querySelectorAll("[data-theme-set]").forEach(b => b.onclick = e => setTheme(b.dataset.themeSet, e));\n  $("#thT").onclick = e => setTheme(theme() === "dark" ? "light" : "dark", e);\n  $("#tvB").onclick = () => { TAB = "settings"; OPEN.add("tv"); setHash(TAB); window.scrollTo({top: 0}); render(true); };\n  $("#rLog").onclick = () => showLog();\n  $("#rReload").onclick = () => location.reload();\n  themeButtons();\n  addEventListener("resize", () => { clearTimeout(navInd._t); navInd._t = setTimeout(navInd, 80); });\n  if (document.fonts && document.fonts.ready) document.fonts.ready.then(navInd);\n}\nlet ARMED = {key: null, until: 0};\nconst armed = key => ARMED.key === key && Date.now() < ARMED.until;\nfunction confirmBtn(btn, question, fn) {\n  const key = btn.dataset.key || btn.id;\n  if (!btn.dataset.orig) btn.dataset.orig = btn.textContent;\n  if (armed(key)) { ARMED = {key: null, until: 0}; btn.textContent = btn.dataset.orig; fn(); return; }\n  ARMED = {key, until: Date.now() + 4000}; btn.textContent = question;\n  setTimeout(() => { if (ARMED.key === key && Date.now() >= ARMED.until) { ARMED = {key: null, until: 0}; } if (!armed(key) && document.body.contains(btn)) btn.textContent = btn.dataset.orig; }, 4100);\n}\n\nfunction header() {\n  const c = S.config, age = S.tv.last_msg ? (Date.now() / 1000 - S.tv.last_msg) : null;\n  const tvState = age == null ? ["bad", "TradingView: noch kein Signal"] : age < 1260 ? ["ok", "TradingView verbunden · " + tm(S.tv.last_msg)] : ["warn", "TradingView: letzte Nachricht " + dtm(S.tv.last_msg)];\n  $("#pTv").innerHTML = `<span class="dot ${tvState[0]}"></span>${tvState[1]}`;\n  $("#pDot").className = "dot " + tvState[0]; $("#pDot").title = tvState[1];\n  $("#pVer").textContent = "Version " + S.version;\n  $("#pBroker").innerHTML = `<span class="dot ${S.broker.ok ? "ok" : "bad"}"></span>${esc(S.broker.label)}${S.broker.name === "tradovate" ? " " + (c.tradovate.env === "live" ? "LIVE" : "Demo") : ""}`;\n  $("#pBroker").title = S.broker.status;\n  $("#pSess").innerHTML = `<span class="dot ${S.session_open ? "ok" : ""}"></span>NY ${S.now_ny} · ${S.session_open ? esc(S.session_name) : "keine Session"}`;\n  $("#autoT").setAttribute("aria-checked", c.auto_mode);\n  $("#banner").innerHTML = c.paused ? `<div class="banner">Handel pausiert. Neue Signale werden blockiert. <button class="btn" id="resume" style="margin-left:8px">Fortsetzen</button></div>`\n    : (S.broker.name === "tradovate" && c.tradovate.env === "live" ? `<div class="banner">LIVE-Konto aktiv: Orders gehen mit echtem Geld an Tradovate.</div>` : "")\n    + (c.hook_confirmed && S.hook_url && !S.hook_confirmed ? `<div class="banner">Deine Webhook-Adresse hat sich nach dem Neustart geändert. Bitte im TradingView-Alert ersetzen:\n        <div class="copyrow" style="margin-top:8px"><div class="code" id="newHook">${esc(S.hook_url)}</div><button class="btn" id="cpNew">Kopieren</button><button class="btn primary" id="okNew">Erledigt</button></div></div>` : "")\n    + (S.remote && S.remote.limit && S.remote.n > S.remote.limit * 0.8 ? `<div class="banner">ngrok-Kontingent fast aufgebraucht: ${S.remote.n.toLocaleString("de-DE")} von ${S.remote.limit.toLocaleString("de-DE")} Anfragen diesen Monat. Ist es leer, kommen keine Signale mehr an. App am Handy seltener offen lassen; mehr dazu unter Einstellungen → TradingView.</div>` : "")\n    + (S.old_script && S.remote && S.remote.limit ? `<div class="banner" style="background:var(--fill);color:var(--fg)"><b>Neues TradingView-Script spart ngrok-Anfragen</b> (Kerzen gebündelt, Live-Kurs sparsam – etwa ein Drittel bis die Hälfte weniger). Einstellungen → TradingView → <b>Strategie-Script kopieren</b>, in TradingView im Pine-Editor ersetzen und speichern, danach den Alert <b>löschen und neu anlegen</b> (alte Alerts behalten das alte Script).</div>` : "")\n    + (S.news_pause ? `<div class="banner" style="background:var(--warn-bg);color:var(--fg)"><b style="color:var(--warn)">${esc(S.news_pause)}</b> · In dieser Zeit nimmt der Bot keine neuen Trades.</div>` : "")\n    + (S.alert_issue ? `<div class="banner" style="background:var(--neg-bg);color:var(--fg);border:1px solid rgba(255,93,108,.35)"><b style="color:var(--neg)">TradingView-Alert falsch eingerichtet.</b>\n        Angekommen ist nur der Platzhalter <span class="mono">{{strategy.order.alert_message}}</span> statt der Daten (zuletzt ${tm(S.alert_issue.ts)}). Der Alert hängt am Kurs statt an der Strategie.\n        <ol style="margin:8px 0 0;padding-left:20px;line-height:1.7"><li>Alle bisherigen Alarme für NQ1! löschen.</li><li>Neuen Alarm: bei <b>Bedingung</b> die Strategie <b>„FVG Bot“</b> wählen (nicht „NQ1!“), darunter <b>„Orderausführungen und alert()-Aufrufe“</b>.</li>\n        <li>Nachricht: nur <span class="mono">{{strategy.order.alert_message}}</span>, kein anderer Text.</li><li>Benachrichtigungen → Webhook-URL aus den Einstellungen, Ablauf: unbegrenzt.</li></ol>\n        Richtig eingerichtet zeigt oben „TradingView verbunden“ nach spätestens 5 Minuten (jede Kerze wird geschickt), und dieser Hinweis verschwindet.</div>` : "");\n  if (S.update && S.update.available) {\n    $("#banner").innerHTML += `<div class="banner" style="background:var(--fill);color:var(--fg)">Update verfügbar: Version <b>${esc(S.update.version)}</b>${S.update.notes ? ` · ${esc(S.update.notes)}` : ""}\n      <button class="btn primary" id="updNow" style="margin-left:8px">Jetzt aktualisieren</button></div>`;\n    $("#updNow").onclick = () => runUpdate(() => api("/api/update/apply", {}));\n  }\n  const rs = $("#resume");\n  if ($("#cpNew")) { $("#cpNew").onclick = () => copyText(S.hook_url); $("#okNew").onclick = () => act(() => api("/api/hook-confirm", {}), "Gespeichert"); } if (rs) rs.onclick = () => act(() => api("/api/config", {paused: false}), "Handel fortgesetzt");\n}\n\n/* ───────── Cockpit ───────── */\n/* ───────── Tageszusammenfassung + Gesundheits-Check ───────── */\nlet HC_OPEN = false;\nfunction todayCard() {   // Status-Karte: Zustand, News, Tages-Stopp-Balken, Gesundheits-Check (Zahlen stehen oben im Hero)\n  const s = S.summary, ds = s.daystop || {}, total = s.realized + s.upnl;\n  const goal = ds.goal || S.config.risk.daily_profit_stop || 0, loss = ds.loss || S.config.risk.max_daily_loss || 0;\n  let meter = "";\n  if (goal > 0 || loss > 0) {\n    const lo = loss > 0 ? -loss : Math.min(0, total), hi = goal > 0 ? goal : Math.max(1, total), span = hi - lo || 1;\n    const p0 = Math.max(0, Math.min(100, -lo / span * 100)), pv = Math.max(0, Math.min(100, (total - lo) / span * 100));\n    meter = `<div class="td-m" title="Tages-Stopp: ${loss > 0 ? "Verlust " + usd(-loss) : "kein Verlust-Stopp"} · ${goal > 0 ? "Ziel " + usd(goal) : "kein Tagesziel"}">\n      <div class="td-ml"><span>${loss > 0 ? "Stopp bei " + usd(-loss) : ""}</span><span>Heute ${sUsd(total)}</span><span>${goal > 0 ? "Tagesziel " + usd(goal) : ""}</span></div>\n      <div class="td-mt"><i class="${total >= 0 ? "p" : "n"}" style="left:${Math.min(p0, pv)}%;width:${Math.abs(pv - p0)}%"></i><b style="left:${p0}%"></b></div></div>`;\n  }\n  const st = S.config.paused ? ["bad", "Pausiert"] : ds.hit ? ["warn", ds.hit === "ziel" ? "Tagesziel erreicht" : "Tages-Stopp"] : S.news_pause ? ["warn", "News-Pause"]\n    : !S.session_open ? ["mute", "Wartet auf Session"] : S.config.auto_mode ? ["good", "Handelt automatisch"] : ["", "Schickt Vorschläge"];\n  const nn = S.news_next;\n  const blocked = Object.entries(s.blocked || {}).sort((a, b) => b[1] - a[1]);\n  const H = S.health || [], nBad = H.filter(x => x.status === "bad").length, nWarn = H.filter(x => x.status === "warn").length;\n  return `<div class="stc-row">\n      <span class="chip ${st[0]}"><span class="dot ${st[0] === "good" ? "ok" : st[0] === "mute" ? "" : st[0]}" style="display:inline-block;margin-right:2px"></span>${st[1]}</span>\n      ${nn ? `<span class="chip" title="${esc(nn.title)}">Nächste News ${tm(nn.ts / 1000)} · ${esc(nn.title.length > 28 ? nn.title.slice(0, 27) + "…" : nn.title)}</span>` : ""}\n      ${blocked.length ? `<span class="chip mute">Nicht genommen: ${blocked.map(([k, v]) => `${esc(k)} ${v}`).join(" · ")}</span>` : ""}\n      ${s.own_n ? `<span class="chip mute">Eigene Trades heute ${sUsd(s.own_pnl)}</span>` : ""}\n    </div>\n    ${meter}\n    <div class="hc">\n      <button type="button" class="hc-sum" id="hcT" aria-expanded="${HC_OPEN}">\n        <span class="hc-dots">${H.map(x => `<span class="dot ${x.status === "off" ? "" : x.status}" title="${esc(x.label)}: ${esc(x.text)}"></span>`).join("")}</span>\n        <span>${nBad ? `<b class="neg">${nBad} Problem${nBad > 1 ? "e" : ""}</b>` : nWarn ? `<b style="color:var(--warn)">${nWarn} Hinweis${nWarn > 1 ? "e" : ""}</b>` : `<b class="pos">Alles in Ordnung</b>`} · Gesundheits-Check</span>\n        <span class="hc-ch">${HC_OPEN ? "weniger" : "Details"}</span></button>\n      ${HC_OPEN ? `<div class="hc-list">${H.map(x => `<div class="hc-i"><span class="dot ${x.status === "off" ? "" : x.status}"></span><b>${esc(x.label)}</b><span>${esc(x.text)}</span></div>`).join("")}</div>` : ""}\n    </div>`;\n}\n\n/* ───────── Hero oben im Cockpit: Konto · Heute · Tagesbalken ───────── */\nconst cu = (v, f) => `data-cu="${v}" data-f="${f}"`;\nconst FMT = {usd: v => usd(v), usd2: v => usd2(v), susd: v => sUsd(v), int: v => String(Math.round(v)), r: v => (v > 0 ? "+" : "") + num2(v) + " R"};\nfunction heroBars() {\n  const days = perfData("gesamt", "alle").days.slice(-12);\n  if (!days.length) return `<div class="bars-box"><div class="bars-h"><span>P&L je Handelstag</span></div><div class="bars-empty">Noch keine Handelstage.<br>Hier wächst gleich dein Verlauf.</div></div>`;\n  const hi = Math.max(1, ...days.map(d => d.pnl)), lo = Math.min(0, ...days.map(d => d.pnl)), span = hi - lo || 1, z = hi / span * 100;\n  const tot = days.reduce((a, d) => a + d.pnl, 0), green = days.filter(d => d.pnl > 0).length;\n  return `<div class="bars-box"><div class="bars-h"><span>Letzte ${days.length} Handelstage · ${green} grün</span><b class="${cls(tot)}">${sUsd(tot)}</b></div>\n    <div class="bars">${Array.from({length: 12 - days.length}, () => \'<div class="col ph"><div class="stk"></div><small>&nbsp;</small></div>\').join("")}${days.map((d, k) => { const h = Math.abs(d.pnl) / span * 100;\n      return `<div class="col" style="--k:${k}"><div class="stk"><span class="zl" style="top:${z}%"></span>${d.pnl >= 0 ? `<i class="up" style="bottom:${100 - z}%;height:${Math.max(1.5, h)}%"></i>` : `<i class="dn" style="top:${z}%;height:${Math.max(1.5, h)}%"></i>`}\n        <span class="tip">${new Date(d.day + "T12:00:00").toLocaleDateString("de-DE", {weekday: "short", day: "2-digit", month: "2-digit"})} · ${sUsd(d.pnl)} · ${d.n} Trade${d.n === 1 ? "" : "s"}</span></div><small>${d.day.slice(8)}.</small></div>`; }).join("")}</div></div>`;\n}\nfunction heroHtml() {\n  const s = S.summary, total = s.realized + s.upnl, bal = S.balance, c = S.config;\n  const base = bal != null ? bal - total : null, dp = base ? total / base * 100 : 0;\n  const tile = (cl, label, ic, val, f, sub) => `<div class="tile ${cl}"><div class="tile-h"><span>${label}</span><i>${icon(ic)}</i></div><b ${cu(val, f)}>${FMT[f](val)}</b><small>${sub}</small></div>`;\n  const wr = s.n ? Math.round(s.wins / s.n * 100) : null;\n  return `\n  <div class="hero-card">\n    <div class="hc-top"><span>Kontostand</span><small>${esc(S.broker.label)}</small></div>\n    <div><div class="bal mono" ${bal == null ? "" : cu(bal, "usd2")}>${bal == null ? "–" : usd2(bal)}</div>\n      <div class="delta"><b class="${total > 0 ? "pos" : total < 0 ? "neg" : "zero"}">${total > 0 ? "↗" : total < 0 ? "↘" : "→"} ${base ? (dp >= 0 ? "+" : "") + dp.toFixed(2).replace(".", ",") + " %" : "0 %"}</b>heute</div></div>\n    <div class="hb-act">\n      <button class="btn primary" id="hPause" type="button">${icon(c.paused ? I.play : I.pause)}${c.paused ? "Fortsetzen" : "Pausieren"}</button>\n      <button class="btn" id="hChart" type="button">${icon(I.candle)}Zum Chart</button>\n    </div>\n    <div class="wal">\n      <div><span><i style="background:var(--ink)"></i>Realisiert</span><b class="${cls(s.realized)}">${sUsd(s.realized)}</b></div>\n      <div><span><i style="background:var(--accent)"></i>Offen</span><b class="${cls(s.upnl)}">${s.open ? sUsd(s.upnl) : "–"}</b></div>\n      <div><span><i style="background:var(--pos)"></i>Trefferquote</span><b>${wr == null ? "–" : wr + " %"}</b></div>\n    </div>\n  </div>\n  <div class="hero-card tiles">\n    ${tile("hot" + (total < 0 ? " neg" : ""), "Heute", I.bolt, total, "susd", `<em>${(s.r > 0 ? "+" : "") + num2(s.r)} R</em>${s.n ? "realisiert " + sUsd(s.realized) : "noch nichts geschlossen"}`)}\n    ${tile("", "Trades", I.target, s.n + s.open, "int", s.n ? `<em class="${s.wins >= s.losses ? "pos" : "neg"}">${s.wins}:${s.losses}</em>Gewinner : Verlierer` : `<em>${s.open} offen</em>max. ${c.risk.max_trades_day} pro Tag`)}\n    ${tile("", "Signale", I.signal, s.signals, "int", s.signals ? `<em>${s.executed}</em>genommen · ${s.signals - s.executed} nicht` : "heute noch keins")}\n    ${tile("", "Ergebnis in R", I.trend, s.r, "r", s.n ? `<em>Ø ${num2(s.r / s.n)} R</em>pro Trade` : "Risiko-Einheiten")}\n  </div>\n  <div class="hero-card">\n    <div class="hc-top"><span>Tagesergebnisse</span><small>Bot + eigene Trades</small></div>\n    ${heroBars()}\n  </div>`;\n}\nfunction heroRender(full) {\n  const box = $("#hero"); if (!box) return;\n  const key = JSON.stringify([S.summary, S.balance, S.config.paused, S.config.risk.max_trades_day, S.broker.label, perfData("gesamt", "alle").days.slice(-12)]);\n  if (key === heroRender._k && !full) return;\n  heroRender._k = key;\n  box.innerHTML = heroHtml();\n  if (full) { box.classList.add("fresh"); clearTimeout(heroRender._t); heroRender._t = setTimeout(() => box.classList.remove("fresh"), 2200); countUp(box); }\n  $("#hPause").onclick = () => act(() => api("/api/config", {paused: !S.config.paused}), S.config.paused ? "Handel fortgesetzt" : "Handel pausiert: keine neuen Trades");\n  $("#hChart").onclick = () => { TAB = "chart"; setHash(TAB); window.scrollTo({top: 0}); render(true); };\n}\nfunction countUp(root) {\n  if (matchMedia("(prefers-reduced-motion: reduce)").matches) return;\n  root.querySelectorAll("[data-cu]").forEach(el => {\n    const to = parseFloat(el.dataset.cu), f = FMT[el.dataset.f] || FMT.int; if (!isFinite(to)) return;\n    const from = /^usd/.test(el.dataset.f) && Math.abs(to) > 1000 ? to * 0.96 : 0, t0 = performance.now(), dur = 1100;\n    const step = now => { const k = Math.min(1, (now - t0) / dur), e = 1 - Math.pow(1 - k, 4), v = from + (to - from) * e;\n      el.textContent = f(el.dataset.f === "int" ? Math.round(v) : v); if (k < 1 && el.isConnected) requestAnimationFrame(step); };\n    requestAnimationFrame(step);\n  });\n}\n\n/* ───────── Timeline: was der Bot heute entschieden hat ───────── */\nfunction tlItems(items, withDate) {\n  const chip = {"ausgeführt": "good", "offen": "", "abgelehnt": "mute", "verfallen": "mute", "ersetzt": "mute", "blockiert": "warn", "fehler": "bad"};\n  return items.slice().reverse().map(s => {\n    const p = s.pos, sh = s.shadow;\n    let what = "", out = "", kind = s.status === "ausgeführt" ? "in" : s.status === "blockiert" ? "bl" : "mu";\n    if (s.status === "ausgeführt") {\n      what = `Eingestiegen ${s.qty}× @ ${px(s.entry)} · Stop ${px(s.sl)}${s.tp ? " · Ziel " + px(s.tp) : ""}${s.mgmt ? ` · Ausstieg ${esc(s.mgmt)}` : ""}`;\n      if (p && p.status === "geschlossen") out = `<b class="mono ${cls(p.pnl)}">${sUsd(p.pnl)}</b><small>${p.r != null ? (p.r > 0 ? "+" : "") + num2(p.r) + " R · " : ""}${esc(p.reason || "")}</small>`;\n      else if (p) out = `<span class="chip">läuft</span>`;\n    } else {\n      what = esc(s.reason || s.status);\n      if (sh && sh.status === "geschlossen" && sh.r != null) {\n        const helped = sh.r < 0;\n        out = `<b class="mono ${helped ? "pos" : "neg"}" title="${helped ? "Der Filter hat einen Verlust verhindert" : "Der Filter hat einen Gewinn verhindert"}">hätte ${(sh.r > 0 ? "+" : "") + num2(sh.r)} R</b><small>${helped ? "gut, dass nicht" : "verpasst"}</small>`;\n      } else if (sh) out = `<small class="hint">Schatten läuft</small>`;\n    }\n    const flags = (s.flags || []).filter(f => !/^Ausstieg /.test(f));\n    return `<div class="tl-i ${kind}"><time class="mono">${withDate ? dtm(s.ts) : tm(s.ts)}</time><span class="tl-d"></span>\n      <div class="tl-c"><div class="tl-h"><b class="side ${s.side}" style="font-size:12px">${s.side === "long" ? "L" : "S"}</b> ${esc(s.root)} <span class="chip">${esc(s.setup)}</span>\n        <span class="chip ${chip[s.status] ?? "mute"}">${s.status === "blockiert" && s.cat ? "nicht genommen · " + esc(s.cat) : esc(s.status)}</span>${s.is_test ? \' <span class="chip mute">Test</span>\' : ""}</div>\n        <div class="tl-w">${what}${flags.length ? `<span class="hint"> · ${esc(flags.join(" · "))}</span>` : ""}</div></div>\n      <div class="tl-o">${out}</div></div>`;\n  }).join("");\n}\nfunction timelinePanel() {\n  const tl = S.timeline || {items: []};\n  if (tl.items.length) return `<div class="tl">${tlItems(tl.items)}</div>`;\n  const old = (S.signals || []).slice(0, 8);\n  return `<p class="hint" style="margin:0 0 8px">Heute noch keine Signale. ${S.session_open ? "Der Bot wartet auf das nächste Setup." : "Gerade läuft keine Session."}</p>\n    ${old.length ? `<details class="tl-old"><summary class="hint">Letzte Signale der Vortage</summary><div class="tl">${tlItems(old.slice().reverse(), true)}</div></details>` : ""}`;\n}\n\n/* ───────── Journal je Trade (Kalender) ───────── */\nfunction journalBox(t) {\n  const shots = (() => { try { return JSON.parse(t.shots || "[]"); } catch (e) { return []; } })();\n  return `<div class="jr" data-jr="${t.id}">\n    <textarea class="jr-t" data-id="${t.id}" rows="2" placeholder="Notiz zum Trade: Warum rein? Was lief gut, was nicht? (speichert automatisch)">${esc(t.journal || "")}</textarea>\n    <div class="jr-s">${shots.map(n => `<span class="jr-img"><img src="/api/shot/${n}" alt="Screenshot" loading="lazy" data-full="/api/shot/${n}"><button type="button" class="jr-x" data-id="${t.id}" data-n="${n}" aria-label="Bild löschen">×</button></span>`).join("")}\n      ${shots.length < 6 ? `<label class="jr-add" title="Bild hinzufügen (oder Screenshot mit Strg+V ins Notizfeld einfügen)">+ Bild<input type="file" accept="image/png,image/jpeg,image/webp" data-id="${t.id}" hidden></label>` : ""}</div>\n  </div>`;\n}\nasync function jrUpload(id, file) {\n  if (!file || !/^image\\/(png|jpeg|webp)$/.test(file.type)) return toast("Nur PNG-, JPG- oder WEBP-Bilder");\n  if (file.size > 6e6) return toast("Bild ist größer als 6 MB");\n  const data = await new Promise((res, rej) => { const r = new FileReader(); r.onload = () => res(r.result); r.onerror = rej; r.readAsDataURL(file); });\n  try { await api(`/api/trade/${id}/shot`, {data}); toast("Bild gespeichert"); openDay(CAL.sel); } catch (e) { toast(e.message); }\n}\nfunction jrBind(root) {\n  root.querySelectorAll(".jr-t").forEach(ta => {\n    let last = ta.value;\n    const save = async () => { if (ta.value === last) return; last = ta.value; try { await api(`/api/trade/${ta.dataset.id}/journal`, {text: ta.value});\n      const t = (CAL.dayTrades || []).find(x => x.id === ta.dataset.id); if (t) t.journal = ta.value; toast("Notiz gespeichert"); } catch (e) { toast(e.message); } };\n    ta.addEventListener("blur", save);\n    ta.addEventListener("paste", e => { const f = [...(e.clipboardData || {}).files || []].find(x => x.type.startsWith("image/")); if (f) { e.preventDefault(); save(); jrUpload(ta.dataset.id, f); } });\n  });\n  root.querySelectorAll(".jr-add input").forEach(inp => inp.onchange = () => jrUpload(inp.dataset.id, inp.files[0]));\n  root.querySelectorAll(".jr-x").forEach(b => b.onclick = async () => { try { await api(`/api/trade/${b.dataset.id}/shot/delete`, {name: b.dataset.n}); openDay(CAL.sel); } catch (e) { toast(e.message); } });\n  root.querySelectorAll(".jr-img img").forEach(img => img.onclick = () => { const c = modal(`<img src="${img.dataset.full}" alt="Screenshot" style="max-width:100%;max-height:78vh;display:block;margin:0 auto;border-radius:8px">\n    <div class="inline" style="justify-content:flex-end;margin-top:10px"><button class="btn" data-close>Schließen</button></div>`); $("#mdl [data-close]").onclick = c; });\n}\n\n/* ───────── Nachverfolgung früher Ausstiege ───────── */\nfunction ghostLine(t) {\n  if (!t.ghost_status || !t.initial_sl) return "";\n  const d = t.side === "long" ? 1 : -1, r0 = Math.abs(t.entry - t.initial_sl) || 1e-9, ar = (t.exit - t.entry) * d / r0;\n  if (t.ghost_status !== "fertig") return `<div class="gh"><span class="dot"></span><span>${esc(t.exit_cat)} · wird weiter verfolgt: Was wäre ohne den frühen Ausstieg passiert?</span></div>`;\n  const diff = ar - t.ghost_r, good = diff > 0.05, bad = diff < -0.05;\n  return `<div class="gh ${good ? "g" : bad ? "b" : ""}"><span class="dot ${good ? "ok" : bad ? "bad" : ""}"></span><span><b>${esc(t.exit_cat)}:</b> gehalten hätte er ${t.ghost_how === "Ziel" ? "das <b>Ziel</b> erreicht" : t.ghost_how === "Stop" ? "den <b>Stop</b> erreicht" : "bis Sessionende"} bei <b class="mono ${cls(t.ghost_r)}">${t.ghost_r > 0 ? "+" : ""}${num2(t.ghost_r)} R</b> statt ${ar > 0 ? "+" : ""}${num2(ar)} R → <b>${good ? "gerettet" : bad ? "verpasst" : "kein Unterschied"}${good || bad ? " " + num2(Math.abs(diff)) + " R" : ""}</b></span></div>`;\n}\nconst EX = {data: null, at: 0};\nasync function exitPanel() {\n  const el = $("#exPanel"); if (!el) return;\n  if (!EX.data || Date.now() - EX.at > 60000) { try { EX.data = await api("/api/exits"); EX.at = Date.now(); } catch (e) { return; } }\n  const d = EX.data, G = Object.entries(d.groups).filter(([k]) => !k.includes("|")).sort((a, b) => b[1].n - a[1].n);\n  el.innerHTML = `<div class="section-h"><h2>Frühe Ausstiege: gut oder schlecht?</h2><p class="hint">Jeder Trade, der nicht über Stop oder Ziel endet (oder mit nachgezogenem Stop), wird weiter verfolgt${d.open ? ` · ${d.open} laufen gerade` : ""}</p></div>\n    ${G.length ? `<table><thead><tr><th class="t">Ausstieg</th><th>Trades</th><th>Ø tatsächlich</th><th>Ø gehalten</th><th>Unterschied</th><th class="t">Gehalten wäre …</th><th class="t">Fazit</th></tr></thead><tbody>${G.map(([k, g]) =>\n      `<tr><td class="t">${esc(k)}</td><td>${g.n}</td><td class="${cls(g.actual)}">${num2(g.actual)} R</td><td class="${cls(g.held)}">${num2(g.held)} R</td><td class="${cls(g.diff)}"><b>${g.diff > 0 ? "+" : ""}${num2(g.diff)} R</b></td>\n        <td class="t hint">${g.target}× Ziel · ${g.stop}× Stop · ${g.n - g.target - g.stop}× Sessionende</td><td class="t">${g.n < 10 ? \'<span class="chip mute">sammelt</span>\' : g.diff > 0.05 ? \'<span class="chip good">hilft</span>\' : g.diff < -0.05 ? \'<span class="chip bad">kostet</span>\' : \'<span class="chip mute">neutral</span>\'}</td></tr>`).join("")}</tbody></table>\n      <p class="hint" style="margin:8px 0 0">Positiv = der frühe Ausstieg hat Geld gespart. Kosten Smart-Ausstieg/Smart-BE oder TradingView-Exits über viele Trades nachweislich Geld (in beiden Zeit-Hälften), schaltet der Bot sie selbst ab. ${d.follow_tv ? "" : "<b>TradingView-Exits werden zurzeit nicht befolgt.</b>"}</p>`\n      : \'<p class="hint">Noch keine frühen Ausstiege verfolgt. Sobald ein Trade über ein Exit-Signal, Smart-Ausstieg, News, Sessionende oder von Hand endet, verfolgt die App weiter, ob er Ziel oder Stop erreicht hätte.</p>\'}`;\n}\n/* ───────── Chart: Kerzen mit allem, was der Bot sieht ───────── */\nconst CV_LAYERS = [\n  ["trades", "★ Trades (genommen)", "#e3b341"],\n  ["seen", "Setups gesehen (nicht genommen)", "#8a857a"],\n  ["pools", "Liquidität (PDH/PDL, Asien, London, EQH/EQL)", "#4f8cff"],\n  ["sweeps", "Liquiditäts-Sweeps", "#ff8a3d"],\n  ["structure", "Struktur HH / HL / LH / LL", "#d9d2c3"],\n  ["zigzag", "Zickzack", "#e3b341"],\n  ["breaks", "Struktur-Brüche BOS / MSS", "#2dd4bf"],\n  ["ob", "Orderblöcke", "#a78bfa"],\n  ["fvg", "FVGs / Inversionen", "#38bdf8"],\n  ["sessions", "Sessions & Eröffnungen", "#6b7280"],\n];\nconst CV = {fam: "auto", day: "last", tf: 5, data: null, v: null, sel: null, hover: null, err: null, busy: false, timer: null,\n  layers: (() => { try { return JSON.parse(localStorage.getItem("cvLayers")) || null; } catch (e) { return null; } })()\n    || {trades: true, seen: true, pools: true, sweeps: true, structure: true, zigzag: true, breaks: true, ob: false, fvg: false, sessions: true}};\nconst cvSaveLayers = () => { try { localStorage.setItem("cvLayers", JSON.stringify(CV.layers)); } catch (e) {} };\n\nfunction chartPage() {\n  const d = CV.data;\n  $("#main").innerHTML = `\n  <section class="cv">\n    <div class="cv-bar">\n      <label class="cv-f"><span>Inst</span><select id="cvFam">${(d ? d.fams : ["NQ"]).map(f => `<option ${d && d.fam === f ? "selected" : ""}>${f}</option>`).join("")}</select></label>\n      <div class="cv-f"><span>Tag</span><button class="ibtn" id="cvPrev" aria-label="Vortag">‹</button><input type="date" id="cvDay" value="${d ? d.day : ""}" ${d && d.first ? `min="${d.first}" max="${d.last}"` : ""}><button class="ibtn" id="cvNext" aria-label="Nächster Tag">›</button></div>\n      <div class="cv-f"><span>TF</span><div class="cv-tf">${[1, 2, 3, 5, 15, 30, 60, 240].map(t => `<button type="button" data-tf="${t}" aria-pressed="${CV.tf === t}">${t < 60 ? t + "m" : t / 60 + "h"}</button>`).join("")}</div></div>\n      <span class="cv-info mono" id="cvInfo"></span>\n      <span class="cv-hint">Mausrad Zoom · Ziehen verschieben · Preisachse ziehen = Höhe · ←/→ Tage · Doppelklick zurück · Klick = Details</span>\n    </div>\n    <div class="cv-main">\n      <div class="cv-wrap" id="cvWrap"><canvas id="cvC" tabindex="0" aria-label="Kerzen-Chart"></canvas><div class="cv-ohlc mono" id="cvO"></div><div class="cv-msg" id="cvMsg" hidden></div></div>\n      <aside class="cv-side">\n        <div class="cv-sec"><h3>Inspector</h3><div id="cvI" class="cv-insp"><p class="hint">Etwas im Chart anklicken: Trade, Signal, Zone, Level, Sweep oder Struktur – hier stehen dann alle Details.</p></div></div>\n        <div class="cv-sec"><h3>Ebenen</h3><div class="cv-lay" id="cvL"></div></div>\n        <div class="cv-sec"><h3>Legende</h3><p class="hint" style="margin:0 0 8px;line-height:1.6">Mausrad = Zoom · Ziehen = verschieben · Preisachse ziehen = Höhe · ←/→ = Tage · Doppelklick = zurück · Klick = Details</p><p class="hint" style="margin:0;line-height:1.6">Grün/Rot hinter einem Trade = Ziel- und Stop-Bereich. ○ = Signal gesehen, nicht genommen (Farbe: hätte gewonnen/verloren). × = Sweep. Gestrichelt = Liquidität, endet beim Sweep. BOS = Bruch mit dem Trend, MSS = Richtungswechsel.</p></div>\n      </aside>\n    </div>\n  </section>`;\n  cvLayersPanel();\n  cvBind();\n  if (!CV.data || CV.err) cvLoad(true); else { cvResize(); cvDraw(); }\n}\n\nfunction cvLayersPanel() {\n  const c = (CV.data && CV.data.counts) || {};\n  $("#cvL").innerHTML = CV_LAYERS.map(([k, l, col]) => `<label class="cv-li"><input type="checkbox" data-ly="${k}" ${CV.layers[k] ? "checked" : ""}><i style="background:${col}"></i><span>${l}</span><b class="mono">${c[k] ?? ""}</b></label>`).join("")\n    + `<div class="cv-lb"><button class="btn" id="cvAll">alles</button><button class="btn" id="cvClean">aufgeräumt</button></div>`;\n  $("#cvL").querySelectorAll("[data-ly]").forEach(x => x.onchange = () => { CV.layers[x.dataset.ly] = x.checked; cvSaveLayers(); cvDraw(); });\n  $("#cvAll").onclick = () => { CV_LAYERS.forEach(([k]) => CV.layers[k] = true); cvSaveLayers(); cvLayersPanel(); cvDraw(); };\n  $("#cvClean").onclick = () => { CV.layers = {trades: true, seen: true, pools: true, sweeps: true, structure: false, zigzag: true, breaks: true, ob: false, fvg: false, sessions: true}; cvSaveLayers(); cvLayersPanel(); cvDraw(); };\n}\n\nasync function cvLoad(reset) {\n  if (CV.busy) return;\n  CV.busy = true;\n  const keepRight = CV.v && CV.data && CV.v.i1 >= CV.data.candles.length - 0.5;\n  try {\n    const d = await api(`/api/chartview/${CV.fam}/${CV.day}/${CV.tf}`);\n    d.real = d.candles.length;\n    d.candles = d.candles.concat(d.forming || []);   // laufende Kerze(n) aus dem Live-Kurs hinten anhängen\n    const same = CV.data && CV.data.day === d.day && CV.data.tf === d.tf && CV.data.fam === d.fam;\n    CV.data = d; CV.err = null;\n    if (CV.day === "last") CV.day = d.day;\n    if (!same || reset || !CV.v) cvResetView();\n    else if (keepRight) { const w = CV.v.i1 - CV.v.i0; CV.v.i1 = d.candles.length + 2; CV.v.i0 = CV.v.i1 - w; }\n  } catch (e) { CV.err = e.message; }\n  CV.busy = false;\n  if (TAB !== "chart" || !$("#cvC")) return;\n  const d = CV.data;\n  if (d) {\n    $("#cvDay").value = d.day; if (d.first) { $("#cvDay").min = d.first; $("#cvDay").max = d.last; }\n    $("#cvFam").innerHTML = d.fams.map(f => `<option ${d.fam === f ? "selected" : ""}>${f}</option>`).join("");\n    const ev = Object.entries(d.counts).filter(([k]) => !["zigzag", "sessions"].includes(k)).reduce((a, [, v]) => a + v, 0);\n    $("#cvInfo").innerHTML = `<b>${d.real}</b> ${d.tf < 60 ? d.tf + "m" : d.tf / 60 + "h"}-Kerzen · <b>${ev}</b> Ereignisse · <b class="${d.counts.trades ? "acc" : ""}">${d.counts.trades}</b> Trades${d.live ? ` · <span class="live">● live${d.live_px ? " · Kurs vor " + Math.max(1, Math.round((Date.now() - d.live_px.ts) / 1000)) + " s" : ""}</span>` : ""}`;\n    document.querySelectorAll("[data-tf]").forEach(b => b.setAttribute("aria-pressed", +b.dataset.tf === d.tf));\n  }\n  const msg = $("#cvMsg");\n  msg.hidden = !(CV.err || (d && (!d.candles.length || d.note)));\n  msg.textContent = CV.err || (d && !d.candles.length ? "Für diesen Tag sind keine Kerzen gespeichert." : d && d.note ? d.note : "");\n  cvLayersPanel();\n  cvResize(); cvDraw();\n  clearTimeout(CV.timer);\n  const inTrade = d && (S.positions || []).some(p => p.root && (p.root === d.fam || p.root === "M" + d.fam));\n  if (d && d.live) CV.timer = setTimeout(() => { if (TAB === "chart" && !document.hidden) cvLoad(false); },\n    ["localhost", "127.0.0.1"].includes(location.hostname) ? (inTrade ? 8000 : 20000) : 60000);\n}\n\nfunction cvResetView() {\n  const n = CV.data ? CV.data.candles.length : 0;\n  const narrow = innerWidth < 700;\n  const show = Math.min(n, narrow ? 70 : CV.data && CV.data.tf === 1 ? 300 : CV.data && CV.data.tf >= 60 ? 160 : n);\n  CV.v = {i1: n + 2, i0: n + 2 - Math.max(20, show + 2), y: null};\n}\n\nfunction cvBind() {\n  $("#cvFam").onchange = e => { CV.fam = e.target.value; CV.day = "last"; CV.sel = null; cvLoad(true); };\n  $("#cvDay").onchange = e => { if (e.target.value) { CV.day = e.target.value; CV.sel = null; cvLoad(true); } };\n  $("#cvPrev").onclick = () => cvShiftDay(-1);\n  $("#cvNext").onclick = () => cvShiftDay(1);\n  document.querySelectorAll("[data-tf]").forEach(b => b.onclick = () => { CV.tf = +b.dataset.tf; CV.sel = null; cvLoad(true); });\n  const cv = $("#cvC");\n  const pos = e => { const r = cv.getBoundingClientRect(); return [e.clientX - r.left, e.clientY - r.top]; };\n  let drag = null;\n  cv.addEventListener("wheel", e => {\n    e.preventDefault();\n    if (!CV.v || !CV.g) return;\n    const [x] = pos(e);\n    const f = Math.pow(1.0015, e.deltaY);   // gleichmäßig, auch bei Touchpads\n    const at = CV.v.i0 + Math.min(x, CV.g.pw) / CV.g.pw * (CV.v.i1 - CV.v.i0);\n    let w = (CV.v.i1 - CV.v.i0) * f;\n    const n = CV.data.candles.length;\n    w = Math.max(12, Math.min(Math.max(40, n * 1.5), w));\n    const k = (at - CV.v.i0) / (CV.v.i1 - CV.v.i0);\n    CV.v.i0 = at - k * w; CV.v.i1 = CV.v.i0 + w;\n    cvClamp(); cvDraw();\n  }, {passive: false});\n  cv.addEventListener("pointerdown", e => {\n    if (!CV.v || !CV.g) return;\n    const [x, y] = pos(e);\n    cv.setPointerCapture(e.pointerId);\n    drag = {x, y, i0: CV.v.i0, i1: CV.v.i1, axis: x > CV.g.pw, moved: false, yr: CV.g.yr.slice()};\n  });\n  cv.addEventListener("pointermove", e => {\n    const [x, y] = pos(e);\n    if (drag && CV.g) {\n      const dx = x - drag.x, dy = y - drag.y;\n      if (Math.abs(dx) + Math.abs(dy) > 3) drag.moved = true;\n      if (drag.axis) {   // Preisachse ziehen = Höhe skalieren\n        const mid = (drag.yr[0] + drag.yr[1]) / 2, half = (drag.yr[1] - drag.yr[0]) / 2 * Math.exp(dy / 150);\n        CV.v.y = [mid - half, mid + half];\n      } else {\n        const per = (drag.i1 - drag.i0) / CV.g.pw;\n        CV.v.i0 = drag.i0 - dx * per; CV.v.i1 = drag.i1 - dx * per;\n        if (CV.v.y) { const ppx = (drag.yr[1] - drag.yr[0]) / CV.g.ph; CV.v.y = [drag.yr[0] + dy * ppx, drag.yr[1] + dy * ppx]; }\n        cvClamp();\n      }\n      CV.hover = null; cvDraw(); return;\n    }\n    CV.hover = [x, y]; cvDraw();\n  });\n  cv.addEventListener("pointerup", e => {\n    const [x, y] = pos(e);\n    if (drag && !drag.moved && !drag.axis) cvPick(x, y);\n    drag = null;\n  });\n  cv.addEventListener("pointerleave", () => { CV.hover = null; cvDraw(); });\n  cv.addEventListener("dblclick", () => { cvResetView(); cvDraw(); });\n  cv.addEventListener("keydown", e => {\n    if (e.key === "ArrowLeft") { e.preventDefault(); cvShiftDay(-1); }\n    else if (e.key === "ArrowRight") { e.preventDefault(); cvShiftDay(1); }\n    else if (e.key === "0") { cvResetView(); cvDraw(); }\n  });\n  if (!CV.ro) { CV.ro = new ResizeObserver(() => { if (TAB === "chart" && $("#cvC")) { cvResize(); cvDraw(); } }); }\n  CV.ro.disconnect(); CV.ro.observe($("#cvWrap"));\n}\n\nfunction cvShiftDay(dir) {\n  if (!CV.data) return;\n  const d = new Date(CV.data.day + "T12:00:00Z");\n  do { d.setUTCDate(d.getUTCDate() + dir); } while (d.getUTCDay() === 0 || d.getUTCDay() === 6);\n  const k = d.toISOString().slice(0, 10);\n  if ((CV.data.first && k < CV.data.first) || (CV.data.last && k > CV.data.last)) return toast(dir < 0 ? "Älter sind keine Kerzen gespeichert" : "Das ist der neueste Tag");\n  CV.day = k; CV.sel = null; cvLoad(true);\n}\n\nfunction cvClamp() {\n  const n = CV.data.candles.length, w = CV.v.i1 - CV.v.i0;\n  if (CV.v.i1 < Math.min(n, 8)) { CV.v.i1 = Math.min(n, 8); CV.v.i0 = CV.v.i1 - w; }\n  if (CV.v.i0 > n - 8) { CV.v.i0 = n - 8; CV.v.i1 = CV.v.i0 + w; }\n}\n\nfunction cvResize() {\n  const cv = $("#cvC"), wrap = $("#cvWrap"); if (!cv || !wrap) return;\n  const r = wrap.getBoundingClientRect(), dpr = window.devicePixelRatio || 1;\n  cv.width = Math.round(r.width * dpr); cv.height = Math.round(r.height * dpr);\n  cv.style.width = r.width + "px"; cv.style.height = r.height + "px";\n}\n\n/* Zeit (ms) → Kerzen-Index (mit Bruchteil), damit Zonen und Trades genau zwischen Kerzen liegen */\nfunction cvIdx(ms) {\n  const c = CV.data.candles, tf = CV.data.tf * 60000;\n  if (!c.length) return 0;\n  if (ms <= c[0][0]) return (ms - c[0][0]) / tf;\n  let lo = 0, hi = c.length - 1;\n  while (lo < hi) { const m = (lo + hi + 1) >> 1; if (c[m][0] <= ms) lo = m; else hi = m - 1; }\n  return lo + Math.min(1, (ms - c[lo][0]) / tf);\n}\n\nfunction cvColors() {\n  const s = getComputedStyle(document.documentElement), g = k => s.getPropertyValue(k).trim();\n  const dk = theme() === "dark";\n  return {bg: g("--surface"), line: g("--line"), fg: g("--fg"), muted: g("--muted"), acc: g("--accent"), pos: g("--pos"), neg: g("--neg"), mono: g("--f-mono"), dk,\n    tip: dk ? "#2a2a2e" : "#121215", tipFg: "#fff", trade: dk ? "rgba(255,106,61,.9)" : "rgba(240,86,43,.95)", zz: dk ? "rgba(255,154,92,.7)" : "rgba(240,86,43,.6)",\n    mid: dk ? "rgba(217,210,195,.55)" : "rgba(90,90,100,.55)", cross: dk ? "rgba(217,210,195,.35)" : "rgba(18,18,21,.3)", sessLine: dk ? "rgba(160,160,160,.25)" : "rgba(18,18,21,.14)",\n    hh: dk ? "#7fd9a8" : "#13a052", ll: dk ? "#f2918a" : "#e5484d", pool: dk ? "#7aa7ff" : "#3366e0", accA: dk ? "rgba(255,106,61,.5)" : "rgba(240,86,43,.5)"};\n}\n\nfunction cvDraw() {\n  const cv = $("#cvC"); if (!cv || !CV.data || !CV.v) return;\n  const dpr = window.devicePixelRatio || 1, W = cv.width / dpr, H = cv.height / dpr;\n  const ctx = cv.getContext("2d"); ctx.setTransform(dpr, 0, 0, dpr, 0, 0);\n  const C = cvColors(), d = CV.data, cs = d.candles, L = d.layers, tf = d.tf * 60000;\n  const AX = 72, TX = 22, pw = W - AX, ph = H - TX;\n  ctx.fillStyle = C.bg; ctx.fillRect(0, 0, W, H);\n  ctx.font = `11px ${C.mono}`;\n  if (!cs.length) return;\n  const i0 = CV.v.i0, i1 = CV.v.i1, bw = pw / (i1 - i0);\n  const X = i => (i - i0) * bw;           // linke Kante von Kerze i\n  const XT = ms => X(cvIdx(ms));\n  // Preisbereich: automatisch aus den sichtbaren Kerzen, oder von Hand (Preisachse gezogen)\n  let lo = Infinity, hi = -Infinity;\n  for (let i = Math.max(0, Math.floor(i0)); i < Math.min(cs.length, Math.ceil(i1)); i++) { lo = Math.min(lo, cs[i][3]); hi = Math.max(hi, cs[i][2]); }\n  if (!isFinite(lo)) { lo = cs[cs.length - 1][3]; hi = cs[cs.length - 1][2]; }\n  const pad = (hi - lo) * 0.08 || 5;\n  let yr = CV.v.y || [lo - pad, hi + pad];\n  const Y = p => ph - (p - yr[0]) / (yr[1] - yr[0]) * ph;\n  CV.g = {pw, ph, yr, X, XT, Y, bw, W, H};\n  const tick = d.tick || 0.25, pfmt = p => (Math.round(p / tick) * tick).toLocaleString("de-DE", {minimumFractionDigits: 2, maximumFractionDigits: 2});\n  ctx.save(); ctx.beginPath(); ctx.rect(0, 0, pw, ph); ctx.clip();\n  // Raster\n  const step = cvNice((yr[1] - yr[0]) / 8);\n  ctx.strokeStyle = C.line; ctx.lineWidth = 1;\n  for (let p = Math.ceil(yr[0] / step) * step; p < yr[1]; p += step) { const y = Math.round(Y(p)) + .5; ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(pw, y); ctx.stroke(); }\n  const vis = (a, b) => b >= i0 - 1 && a <= i1 + 1;\n  const on = k => CV.layers[k];\n  const sel = CV.sel && CV.sel.o;\n  const hl = o => sel && o === sel;\n  // Sessions\n  if (on("sessions")) for (const s of L.sessions) {\n    const a = XT(s.t0), b = XT(s.t1); if (b < 0 || a > pw) continue;\n    ctx.fillStyle = {asia: "rgba(99,102,241,.06)", london: "rgba(56,189,248,.05)", ny_am: "rgba(240,86,43,.05)", ny_lunch: "rgba(160,160,160,.035)", ny_pm: "rgba(45,212,191,.05)"}[s.key] || "rgba(255,255,255,.03)";\n    ctx.fillRect(a, 0, b - a, ph);\n    ctx.strokeStyle = hl(s) ? C.acc : C.sessLine; ctx.setLineDash([2, 4]); ctx.beginPath(); ctx.moveTo(Math.round(a) + .5, 0); ctx.lineTo(Math.round(a) + .5, ph); ctx.stroke(); ctx.setLineDash([]);\n    const sn = {asia: "Asien", london: "London", ny_am: "NY AM", ny_lunch: "NY Mittag", ny_pm: "NY PM"}[s.key] || s.name;\n    if (b - a > ctx.measureText(sn).width + 10) { ctx.fillStyle = C.muted; ctx.fillText(sn, a + 4, 13); }\n  }\n  // Zonen: Orderblöcke, FVGs\n  const zone = (z, col, label) => {\n    const a = XT(z.t0), b = XT(z.t1); if (b < 0 || a > pw) return;\n    const y1 = Y(z.top), y2 = Y(z.bot), done = ["ungültig", "gefüllt", "abgelaufen", "invertiert"].includes(z.state);\n    ctx.fillStyle = col.replace("A", done ? ".06" : ".15"); ctx.fillRect(a, y1, b - a, y2 - y1);\n    ctx.strokeStyle = hl(z) ? C.acc : col.replace("A", done ? ".25" : ".55"); ctx.lineWidth = hl(z) ? 2 : 1; ctx.strokeRect(a + .5, y1 + .5, b - a, y2 - y1); ctx.lineWidth = 1;\n    if (b - a > 40 && y2 - y1 > 9) { ctx.fillStyle = col.replace("A", ".9"); ctx.fillText(label, a + 4, y1 + 11); }\n  };\n  if (on("fvg")) for (const z of L.fvg) zone(z, z.dir > 0 ? "rgba(56,189,248,A)" : "rgba(244,114,182,A)", (z.dir > 0 ? "FVG ↑" : "FVG ↓") + (z.state === "invertiert" ? " inv." : ""));\n  if (on("ob")) for (const z of L.ob) zone(z, "rgba(167,139,250,A)", (z.dir > 0 ? "OB ↑" : "OB ↓") + (z.state === "ungültig" ? " ✕" : ""));\n  // Liquidität\n  if (on("pools")) for (const p of L.pools) {\n    const a = Math.max(0, XT(p.t0)), b = Math.min(pw, XT(p.t1)); if (b < 0 || a > pw) continue;\n    const y = Math.round(Y(p.p)) + .5;\n    ctx.strokeStyle = hl(p) ? C.acc : p.side === 0 ? C.mid : C.pool; ctx.lineWidth = hl(p) ? 2 : 1;\n    ctx.setLineDash(p.side === 0 ? [1, 3] : [5, 4]); ctx.beginPath(); ctx.moveTo(a, y); ctx.lineTo(b, y); ctx.stroke(); ctx.setLineDash([]); ctx.lineWidth = 1;\n    ctx.fillStyle = p.side === 0 ? C.muted : C.pool; const txt = (p.side === 0 ? "Mitternacht" : p.name) + (p.swept ? " ✓" : "");\n    if (b - a > ctx.measureText(txt).width + 8) ctx.fillText(txt, b - ctx.measureText(txt).width - 4, y - 4);\n  }\n  // Trades (genommen): Ziel- und Stop-Bereich\n  if (on("trades")) for (const t of L.trades) {\n    const a = XT(t.t0), b = Math.max(a + 3, XT(t.t1)); if (b < 0 || a > pw) continue;\n    const ye = Y(t.entry);\n    if (t.tp) { const yt = Y(t.tp); ctx.fillStyle = "rgba(63,191,127,.16)"; ctx.fillRect(a, Math.min(ye, yt), b - a, Math.abs(yt - ye)); }\n    if (t.sl0) { const ys = Y(t.sl0); ctx.fillStyle = "rgba(229,83,75,.16)"; ctx.fillRect(a, Math.min(ye, ys), b - a, Math.abs(ys - ye)); }\n    ctx.strokeStyle = hl(t) ? C.acc : C.trade; ctx.lineWidth = hl(t) ? 2 : 1.2;\n    ctx.beginPath(); ctx.moveTo(a, ye); ctx.lineTo(b, ye); ctx.stroke();\n    if (t.sl !== t.sl0 && t.sl) { ctx.setLineDash([3, 3]); ctx.strokeStyle = "rgba(229,83,75,.8)"; const y = Y(t.sl); ctx.beginPath(); ctx.moveTo(a, y); ctx.lineTo(b, y); ctx.stroke(); ctx.setLineDash([]); }\n    ctx.lineWidth = 1;\n    if (t.exit != null && t.status === "geschlossen") { const yx = Y(t.exit); ctx.fillStyle = t.pnl > 0 ? C.pos : C.neg; ctx.beginPath(); ctx.arc(b, yx, 4, 0, 7); ctx.fill(); }\n    const up = t.side === "long";\n    ctx.fillStyle = C.acc; ctx.beginPath(); ctx.moveTo(a, ye); ctx.lineTo(a - 6, ye + (up ? 9 : -9)); ctx.lineTo(a + 6, ye + (up ? 9 : -9)); ctx.closePath(); ctx.fill();\n    const lab = `★ ${up ? "LONG" : "SHORT"} ${t.setup || ""}${t.r != null ? " " + (t.r > 0 ? "+" : "") + num2(t.r) + "R" : t.status === "offen" ? " · läuft" : ""}`;\n    ctx.fillStyle = C.acc; ctx.fillText(lab, a + 4, up ? Math.max(12, Y(t.tp || t.entry) - 4) : Math.min(ph - 4, Y(t.tp || t.entry) + 13));\n  }\n  // Kerzen\n  const cw = Math.max(1, Math.min(14, bw * 0.68));\n  for (let i = Math.max(0, Math.floor(i0) - 1); i < Math.min(cs.length, Math.ceil(i1) + 1); i++) {\n    const [, o, h, l, c] = cs[i], x = X(i) + bw / 2, up = c >= o, live = i >= (d.real ?? cs.length);\n    ctx.strokeStyle = ctx.fillStyle = up ? C.pos : C.neg;\n    ctx.globalAlpha = live ? 0.6 : 1;\n    ctx.beginPath(); ctx.moveTo(Math.round(x) + .5, Y(h)); ctx.lineTo(Math.round(x) + .5, Y(l)); ctx.stroke();\n    const yo = Y(o), yc = Y(c);\n    if (live) { ctx.setLineDash([2, 2]); ctx.strokeRect(Math.round(x - cw / 2) + .5, Math.min(yo, yc) + .5, Math.max(1, Math.round(cw)), Math.max(1, Math.abs(yc - yo))); ctx.setLineDash([]); }\n    else ctx.fillRect(Math.round(x - cw / 2), Math.min(yo, yc), Math.max(1, Math.round(cw)), Math.max(1, Math.abs(yc - yo)));\n    ctx.globalAlpha = 1;\n  }\n  // Zickzack + Struktur\n  if (on("zigzag") && L.zigzag.length > 1) {\n    ctx.strokeStyle = C.zz; ctx.lineWidth = 1.2; ctx.beginPath();\n    L.zigzag.forEach((p, k) => { const x = XT(p.t) + bw / 2, y = Y(p.p); k ? ctx.lineTo(x, y) : ctx.moveTo(x, y); }); ctx.stroke(); ctx.lineWidth = 1;\n  }\n  if (on("structure")) for (const s of L.structure) {\n    const x = XT(s.t) + bw / 2; if (x < -20 || x > pw + 20) continue;\n    ctx.fillStyle = hl(s) ? C.acc : s.label === "HH" || s.label === "HL" ? C.hh : C.ll;\n    ctx.textAlign = "center"; ctx.fillText(s.label, x, s.kind === "H" ? Y(s.p) - 6 : Y(s.p) + 14); ctx.textAlign = "left";\n  }\n  if (on("breaks")) for (const b of L.breaks) {\n    const a = XT(b.t0) + bw / 2, e = XT(b.t) + bw / 2; if (e < 0 || a > pw) continue;\n    const y = Math.round(Y(b.p)) + .5, col = b.kind === "MSS" ? "#f59e0b" : "#2dd4bf";\n    ctx.strokeStyle = hl(b) ? C.acc : col; ctx.setLineDash([4, 3]); ctx.beginPath(); ctx.moveTo(a, y); ctx.lineTo(e, y); ctx.stroke(); ctx.setLineDash([]);\n    ctx.fillStyle = col; ctx.textAlign = "center"; ctx.fillText(b.kind, (a + e) / 2, b.dir > 0 ? y - 4 : y + 12); ctx.textAlign = "left";\n  }\n  if (on("sweeps")) for (const s of L.sweeps) {\n    const x = XT(s.t) + bw / 2, y = Y(s.p) + (s.dir > 0 ? 8 : -8); if (x < -10 || x > pw + 10) continue;\n    ctx.strokeStyle = hl(s) ? C.acc : "#ff8a3d"; ctx.lineWidth = 2; ctx.beginPath(); ctx.moveTo(x - 4, y - 4); ctx.lineTo(x + 4, y + 4); ctx.moveTo(x + 4, y - 4); ctx.lineTo(x - 4, y + 4); ctx.stroke(); ctx.lineWidth = 1;\n  }\n  if (on("seen")) for (const s of L.seen) {\n    const x = XT(s.t), y = Y(s.entry); if (x < -10 || x > pw + 10) continue;\n    const r = s.shadow && s.shadow.r != null ? s.shadow.r : null;\n    ctx.strokeStyle = hl(s) ? C.acc : r == null ? C.muted : r > 0 ? C.pos : C.neg; ctx.lineWidth = hl(s) ? 2.5 : 1.6;\n    ctx.beginPath(); ctx.arc(x, y, 5, 0, 7); ctx.stroke(); ctx.lineWidth = 1;\n    ctx.fillStyle = C.muted; ctx.fillText(s.side === "long" ? "↑" : "↓", x + 7, y + 4);\n  }\n  ctx.restore();\n  // Achsen\n  ctx.fillStyle = C.bg; ctx.fillRect(pw, 0, AX, H); ctx.fillRect(0, ph, W, TX);\n  ctx.strokeStyle = C.line; ctx.beginPath(); ctx.moveTo(pw + .5, 0); ctx.lineTo(pw + .5, ph); ctx.moveTo(0, ph + .5); ctx.lineTo(W, ph + .5); ctx.stroke();\n  ctx.fillStyle = C.muted;\n  for (let p = Math.ceil(yr[0] / step) * step; p < yr[1]; p += step) ctx.fillText(pfmt(p), pw + 6, Y(p) + 4);\n  // Zeitachse: Abstand nach Zoom\n  const minPx = 70, every = [1, 2, 3, 5, 6, 10, 12, 15, 20, 30, 60, 120, 240].find(k => k * bw >= minPx) || 480;\n  const fmt = ms => new Date(ms).toLocaleTimeString("de-DE", {hour: "2-digit", minute: "2-digit"});\n  let lastLab = -1e9;\n  for (let i = Math.max(0, Math.ceil(i0)); i < Math.min(cs.length, i1); i++) {\n    const m = new Date(cs[i][0]); const mins = m.getHours() * 60 + m.getMinutes();\n    const per = every * d.tf;\n    if (per >= 1440 ? (i % every) : (mins % Math.min(per, 1440)) !== 0) continue;\n    const x = X(i) + bw / 2; if (x - lastLab < minPx) continue; lastLab = x;\n    const txt = per >= 360 || mins === 0 ? new Date(cs[i][0]).toLocaleDateString("de-DE", {day: "2-digit", month: "2-digit"}) + (mins ? " " + fmt(cs[i][0]) : "") : fmt(cs[i][0]);\n    ctx.textAlign = "center"; ctx.fillText(txt, x, ph + 15); ctx.textAlign = "left";\n  }\n  // letzter Kurs\n  const lc = d.live_px ? d.live_px.price : cs[cs.length - 1][4], yl = Y(lc);\n  if (yl > 0 && yl < ph) { ctx.fillStyle = C.acc; ctx.fillRect(pw, yl - 8, AX, 16); ctx.fillStyle = "#fff"; ctx.fillText(pfmt(lc), pw + 6, yl + 4); ctx.strokeStyle = C.accA; ctx.setLineDash([2, 3]); ctx.beginPath(); ctx.moveTo(0, Math.round(yl) + .5); ctx.lineTo(pw, Math.round(yl) + .5); ctx.stroke(); ctx.setLineDash([]); }\n  // Fadenkreuz + OHLC\n  let k = cs.length - 1;\n  if (CV.hover && CV.hover[0] < pw && CV.hover[1] < ph) {\n    const [hx, hy] = CV.hover;\n    k = Math.max(0, Math.min(cs.length - 1, Math.floor(i0 + hx / bw)));\n    ctx.strokeStyle = C.cross; ctx.setLineDash([3, 3]); ctx.beginPath();\n    ctx.moveTo(Math.round(hx) + .5, 0); ctx.lineTo(Math.round(hx) + .5, ph); ctx.moveTo(0, Math.round(hy) + .5); ctx.lineTo(pw, Math.round(hy) + .5); ctx.stroke(); ctx.setLineDash([]);\n    const p = yr[0] + (ph - hy) / ph * (yr[1] - yr[0]);\n    ctx.fillStyle = C.tip; ctx.fillRect(pw, hy - 8, AX, 16); ctx.fillStyle = C.tipFg; ctx.fillText(pfmt(p), pw + 6, hy + 4);\n    const tl = new Date(cs[k][0]).toLocaleString("de-DE", {weekday: "short", hour: "2-digit", minute: "2-digit"});\n    ctx.fillStyle = C.tip; const tw = ctx.measureText(tl).width + 12; ctx.fillRect(hx - tw / 2, ph + 2, tw, 18); ctx.fillStyle = C.tipFg; ctx.textAlign = "center"; ctx.fillText(tl, hx, ph + 15); ctx.textAlign = "left";\n  }\n  const [t, o, h, l, c] = cs[k];\n  $("#cvO").innerHTML = `<b>${esc(d.fam)} ${d.tf < 60 ? d.tf + "m" : d.tf / 60 + "h"}</b> ${new Date(t).toLocaleString("de-DE", {day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit"})}\n    &nbsp; O <span>${pfmt(o)}</span> H <span>${pfmt(h)}</span> L <span>${pfmt(l)}</span> C <span class="${c >= o ? "pos" : "neg"}">${pfmt(c)}</span>${k >= (d.real ?? cs.length) ? \' <span class="acc">läuft (Live-Kurs)</span>\' : ""}`;\n}\n\nfunction cvNice(x) {\n  const e = Math.pow(10, Math.floor(Math.log10(x))), f = x / e;\n  return (f <= 1 ? 1 : f <= 2 ? 2 : f <= 2.5 ? 2.5 : f <= 5 ? 5 : 10) * e;\n}\n\n/* Anklicken: das oberste Objekt unter dem Mauszeiger finden */\nfunction cvPick(x, y) {\n  const g = CV.g, L = CV.data.layers, on = k => CV.layers[k], bw = g.bw;\n  const hits = [];\n  const near = (px, py, r = 8) => Math.hypot(px - x, py - y) <= r;\n  const inRect = (a, b, y1, y2) => x >= Math.min(a, b) && x <= Math.max(a, b) && y >= Math.min(y1, y2) - 2 && y <= Math.max(y1, y2) + 2;\n  if (on("seen")) L.seen.forEach(s => near(g.XT(s.t), g.Y(s.entry)) && hits.push(["Setup gesehen (nicht genommen)", s, 1]));\n  if (on("sweeps")) L.sweeps.forEach(s => near(g.XT(s.t) + bw / 2, g.Y(s.p) + (s.dir > 0 ? 8 : -8)) && hits.push(["Liquiditäts-Sweep", s, 2]));\n  if (on("trades")) L.trades.forEach(t => inRect(g.XT(t.t0), Math.max(g.XT(t.t0) + 3, g.XT(t.t1)), g.Y(t.tp || t.entry), g.Y(t.sl0 || t.entry)) && hits.push(["★ Trade", t, 5]));\n  if (on("structure")) L.structure.forEach(s => near(g.XT(s.t) + bw / 2, s.kind === "H" ? g.Y(s.p) - 10 : g.Y(s.p) + 10, 10) && hits.push(["Struktur " + s.label, s, 3]));\n  if (on("breaks")) L.breaks.forEach(b => x >= g.XT(b.t0) && x <= g.XT(b.t) + bw && Math.abs(g.Y(b.p) - y) <= 5 && hits.push([b.kind === "MSS" ? "Struktur-Bruch MSS (Richtungswechsel)" : "Struktur-Bruch BOS", b, 4]));\n  if (on("pools")) L.pools.forEach(p => x >= g.XT(p.t0) && x <= g.XT(p.t1) && Math.abs(g.Y(p.p) - y) <= 5 && hits.push(["Liquidität " + p.name, p, 6]));\n  if (on("ob")) L.ob.forEach(z => inRect(g.XT(z.t0), g.XT(z.t1), g.Y(z.top), g.Y(z.bot)) && hits.push(["Orderblock", z, 7]));\n  if (on("fvg")) L.fvg.forEach(z => inRect(g.XT(z.t0), g.XT(z.t1), g.Y(z.top), g.Y(z.bot)) && hits.push(["FVG", z, 8]));\n  if (on("sessions")) L.sessions.forEach(s => x >= g.XT(s.t0) && x <= g.XT(s.t1) && y < 18 && hits.push(["Session " + s.name, s, 9]));\n  hits.sort((a, b) => a[2] - b[2]);\n  CV.sel = hits.length ? {kind: hits[0][0], o: hits[0][1], more: hits.length - 1} : null;\n  cvInspector(); cvDraw();\n}\n\nfunction cvInspector() {\n  const el = $("#cvI"); if (!el) return;\n  if (!CV.sel) { el.innerHTML = \'<p class="hint">Nichts getroffen. Etwas im Chart anklicken: Trade, Signal, Zone, Level, Sweep oder Struktur.</p>\'; return; }\n  const o = CV.sel.o, P = v => v == null ? "–" : px(v), T = v => v ? new Date(v).toLocaleString("de-DE", {day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit"}) : "–";\n  const R = v => v == null ? "–" : (v > 0 ? "+" : "") + num2(v) + " R";\n  let rows = [];\n  if (CV.sel.kind.startsWith("★")) rows = [["Richtung", o.side === "long" ? "LONG" : "SHORT"], ["Strategie", o.setup], ["Menge", `${o.qty}× ${o.root}`], ["Einstieg", P(o.entry) + " · " + T(o.t0)],\n    ["Stop", P(o.sl0) + (o.sl !== o.sl0 ? ` → ${P(o.sl)}` : "")], ["Ziel", P(o.tp)], ["Ausstieg", o.exit != null ? P(o.exit) + " · " + T(o.t1) : "läuft"],\n    ["Grund", o.reason || "–"], ["Ergebnis", o.pnl != null ? sUsd(o.pnl) + " · " + R(o.r) : "–"], ["Verwaltung", o.mgmt || "Signal-Ziel"],\n    ...(o.ghost ? [["Ohne frühen Ausstieg", o.ghost.status === "fertig" ? `${o.ghost.how} bei ${R(o.ghost.r)}` : "wird noch verfolgt"]] : []), ["Konto", o.broker + (o.test ? " · Test" : "")]];\n  else if (CV.sel.kind.startsWith("Setup")) rows = [["Richtung", o.side === "long" ? "LONG" : "SHORT"], ["Strategie", o.setup], ["Zeit", T(o.t)], ["Einstieg", P(o.entry)], ["Stop / Ziel", `${P(o.sl)} / ${P(o.tp)}`],\n    ["Status", o.status], ["Warum nicht", o.reason || "–"], ["Hätte gebracht", o.shadow ? (o.shadow.r != null ? R(o.shadow.r) : "läuft noch") : "–"]];\n  else if (CV.sel.kind.startsWith("Liquiditäts-Sweep")) rows = [["Level", o.name], ["Level-Preis", P(o.level)], ["Docht bis", P(o.p)], ["Zeit", T(o.t)], ["Richtung danach", o.dir > 0 ? "aufwärts (Tief geholt)" : "abwärts (Hoch geholt)"]];\n  else if (CV.sel.kind.startsWith("Liquidität")) rows = [["Art", o.kind], ["Preis", P(o.p)], ["Ab", T(o.t0)], ["Bis", T(o.t1)], ["Ergebnis", o.swept ? "gesweept " + T(o.swept) : o.broken ? "durchbrochen " + T(o.broken) : "noch offen"]];\n  else if (CV.sel.kind.startsWith("Orderblock") || CV.sel.kind === "FVG") rows = [["Richtung", o.dir > 0 ? "bullisch" : "bärisch"], ["Zone", `${P(o.bot)} – ${P(o.top)}`], ["Entstanden", T(o.t0)], ["Zuerst berührt", T(o.touched)], ["Zustand", o.state], ["Bis", T(o.t1)], ...(o.from_break ? [["nach", o.from_break]] : [])];\n  else if (CV.sel.kind.startsWith("Struktur-Bruch")) rows = [["Art", o.kind === "MSS" ? "MSS – Richtungswechsel" : "BOS – mit dem Trend"], ["Richtung", o.dir > 0 ? "aufwärts" : "abwärts"], ["Level", P(o.p)], ["Swing", T(o.t0)], ["Bruch", T(o.t)]];\n  else if (CV.sel.kind.startsWith("Struktur")) rows = [["Punkt", o.label], ["Preis", P(o.p)], ["Zeit", T(o.t)]];\n  else if (CV.sel.kind.startsWith("Session")) rows = [["Session", o.name], ["Von", T(o.t0)], ["Bis", T(o.t1)]];\n  el.innerHTML = `<div class="cv-ik">${esc(CV.sel.kind)}${CV.sel.more ? ` <span class="hint">+${CV.sel.more} darunter</span>` : ""}</div>\n    <dl class="cv-kv">${rows.map(([k, v]) => `<dt>${esc(k)}</dt><dd class="mono">${esc(String(v))}</dd>`).join("")}</dl>\n    <details class="cv-raw"><summary class="hint">Rohdaten</summary><pre class="mono">${esc(JSON.stringify(o, null, 1))}</pre></details>`;\n}\n\n/* ───────── Lernmodul: Übersicht (das Wichtigste auf einen Blick) ───────── */\nconst LO = {disc: null, at: 0};\nasync function learnOverview() {\n  const body = $("#lnBody");\n  if (!LO.disc || Date.now() - LO.at > 60000) { try { LO.disc = await api("/api/disc"); LO.at = Date.now(); } catch (e) {} }\n  if (TAB !== "learn" || LTAB !== "uebersicht") return;\n  const L = S.learning, c = S.config, sn = {asia: "Asien", london: "London", ny_am: "NY AM", ny_lunch: "NY Mittag", ny_pm: "NY PM", aus: "Sonst"};\n  const stChip = s => ({"aktiv": "good", "halbe Größe": "warn", "pausiert": "bad", "aus": "bad", "lernt": "mute"}[s] || "mute");\n  const strat = L.setups.filter(s => s.total || s.manual !== "auto" || s.effective !== "lernt");\n  const er = Object.entries(c.exit_rules || {}), sc = Object.entries(c.session_scale || {}), rules = (c.rule_filters || []).filter(r => r.active !== false);\n  const items = (LO.disc && LO.disc.items) || [], dAct = items.filter(i => i.status === "aktiv"), dProbe = items.filter(i => i.status === "probe" || i.status === "bereit");\n  const card = (title, tab, inner) => `<div class="lo-c"><div class="lo-h"><h3>${title}</h3><button class="lnk" data-go="${tab}">Details →</button></div>${inner}</div>`;\n  const none = t => `<p class="hint" style="margin:0">${t}</p>`;\n  body.innerHTML = `\n    <section class="panel lo-top"><div><h2>Was der Bot gelernt hat</h2><p class="hint" style="margin:4px 0 0">Nur das, was gerade anders läuft als ohne Lernen. Alles Weitere steht unter „Details“.</p></div>\n      <div class="lo-st"><span class="chip ${L.params.auto_adopt === false ? "mute" : "good"}">Selbst umsetzen: ${L.params.auto_adopt === false ? "aus" : "an"}</span><span class="hint">Letzte Auswertung ${L.last_run ? dtm(L.last_run) : "–"}</span></div></section>\n    <div class="lo-g">\n      ${card("Strategien", "strategien", strat.length ? (() => { const dev = strat.filter(s => s.effective !== "aktiv" || Object.values(s.sessions || {}).some(x => x.status === "pausiert" || x.status === "halbe Größe")); const ok = strat.length - dev.length;\n        return (dev.length ? "" : `<p class="hint" style="margin:0 0 6px">Alle ${strat.length} Strategien laufen normal.</p>`) + `<div class="lo-l">${dev.map(s => { const bad = Object.entries(s.sessions || {}).filter(([, x]) => x.status === "pausiert" || x.status === "halbe Größe");\n        return `<div class="lo-r"><span>${esc(s.setup)}</span>${s.effective !== "aktiv" ? `<span class="chip ${stChip(s.effective)}">${esc(s.effective)}</span>` : ""}${bad.map(([k, x]) => `<span class="chip ${stChip(x.status)}" title="${x.n} Trades · Ø ${num2(x.avg_r)} R">${sn[k] || k} ${x.status === "pausiert" ? "⏸ pausiert" : "½ Größe"}</span>`).join("")}</div>`; }).join("")}</div>` + (dev.length && ok ? `<p class="hint" style="margin:6px 0 0">${ok} weitere laufen normal.</p>` : ""); })() : none("Noch keine Daten – kommen mit den ersten Signalen."))}\n      ${card("Ausstiege", "varianten", (er.length ? `<div class="lo-l">${er.map(([k, v]) => `<div class="lo-r"><span>${esc(k)}</span><span class="chip good">${esc(v)}</span></div>`).join("")}</div>` : none("Überall das Ziel aus dem Signal."))\n        + (c.follow_tv_exits ? "" : `<p class="hint" style="margin:6px 0 0">TradingView-Exits werden nicht befolgt (haben Geld gekostet).</p>`))}\n      ${card("Session-Ziele", "sessionziele", sc.length ? `<div class="lo-l">${sc.map(([k, v]) => { const [a, b] = k.includes("|") ? k.split("|") : [null, k];\n        return `<div class="lo-r"><span>${a ? esc(a) + " · " : ""}${sn[b] || esc(b)}</span><span class="chip">Ziel ${Math.round(v.f * 100)} % · Stop ${Math.round(v.g * 100)} %</span></div>`; }).join("")}</div>` : none("Stop und Ziel wie im Signal."))}\n      ${card("Regeln", "regeln", rules.length ? `<div class="lo-l">${rules.map(r => `<div class="lo-r"><span>${esc(r.setup)}</span><span class="chip ${r.action === "avoid" ? "bad" : "good"}">${r.action === "avoid" ? "meiden" : "nur"}: ${esc(r.label)}</span></div>`).join("")}</div>` : none("Keine Filter aktiv."))}\n      ${card("Neue Strategien", "finder", dAct.length || dProbe.length ? `<div class="lo-l">${dAct.map(i => `<div class="lo-r"><span>${esc(i.name.replace("Neu: ", ""))}</span><span class="chip good">handelt mit</span></div>`).join("")}${dProbe.map(i => `<div class="lo-r"><span>${esc(i.name.replace("Neu: ", ""))}</span><span class="chip">Probelauf ${i.fwd ? i.fwd.n : 0}/20</span></div>`).join("")}</div>` : none("Keine im Probelauf."))}\n      ${card("Frühe Ausstiege", "ausstiege", `<p class="hint" style="margin:0">Ob Smart-Ausstieg, TradingView-Exit, News- oder Sessionende-Ausstiege Geld sparen oder kosten.</p>`)}\n    </div>\n    <section class="section"><h2>Zuletzt selbst geändert</h2><div class="panel">${(L.auto_log || []).length ? `<div class="lo-log">${L.auto_log.slice(0, 8).map(i => `<div><span class="mono hint">${new Date(i.t * 1000).toLocaleDateString("de-DE", {day: "2-digit", month: "2-digit"})}</span> ${esc(i.text)}</div>`).join("")}</div>` : none("Noch nichts. Jeden Abend nach Börsenschluss prüft der Bot, was sich bewährt hat.")}</div></section>\n    ${L.insights.length ? `<details class="ck-more"><summary>Erkenntnisse (${L.insights.length})</summary><div class="panel" style="margin-top:8px"><div class="flags" style="flex-direction:column;align-items:flex-start;gap:8px">${L.insights.map(i => `<span class="chip wrapc ${i.kind === "bad" ? "bad" : i.kind === "good" ? "good" : "warn"}">${esc(i.text)}</span>`).join("")}</div></div></details>` : ""}`;\n  body.querySelectorAll("[data-go]").forEach(b => b.onclick = () => { const t = document.querySelector(`[data-lt="${b.dataset.go}"]`); if (t) t.click(); });\n}\n/* ───────── Wochenbericht ───────── */\nconst WK = {off: 0, data: null, at: 0, err: null};\nasync function weekView(force) {\n  const body = $("#stBody");\n  if (force || !WK.data || WK.data.offset !== WK.off || Date.now() - WK.at > 60000) {\n    if (!WK.data) body.innerHTML = \'<p class="hint">Bericht wird erstellt …</p>\';\n    try { WK.data = await api("/api/report/week/" + WK.off); WK.at = Date.now(); WK.err = null; } catch (e) { WK.err = e.message; }\n  }\n  if (TAB !== "stats" || STAB !== "woche") return;\n  const r = WK.data;\n  if (!r) { body.innerHTML = `<p class="err-msg">${esc(WK.err || "")}</p>`; return; }\n  const dfmt = d => new Date(d + "T12:00:00").toLocaleDateString("de-DE", {day: "2-digit", month: "2-digit"});\n  const tbl = (obj, label) => { const e = Object.entries(obj).sort((a, b) => b[1].pnl - a[1].pnl);\n    return e.length ? `<table><thead><tr><th class="t">${label}</th><th>Trades</th><th>Treffer</th><th>R</th><th>Netto</th></tr></thead><tbody>${e.map(([k, v]) =>\n      `<tr><td class="t">${esc(k)}</td><td>${v.n}</td><td>${pct(v.w / v.n * 100)}</td><td class="${cls(v.r)}">${num2(v.r)}</td><td class="${cls(v.pnl)}">${sUsd(v.pnl)}</td></tr>`).join("")}</tbody></table>` : \'<p class="hint">Keine Trades.</p>\'; };\n  const bl = Object.entries(r.blocked).sort((a, b) => b[1].n - a[1].n);\n  const allDays = []; for (let i = 0; i < 5; i++) { const d = new Date(r.monday + "T12:00:00"); d.setDate(d.getDate() + i); const k = iso(d); const x = r.days.find(y => y.day === k); allDays.push({day: k, pnl: x ? x.pnl : 0, n: x ? x.n : 0}); }\n  body.innerHTML = `\n    <section class="wk-head panel"><button class="ibtn" id="wkPrev" aria-label="Vorwoche">${icon(IC_L)}</button>\n      <div><span class="td-l">Wochenbericht</span><h2>${dfmt(r.monday)} – ${dfmt(r.friday)}${r.offset === 0 ? \' <span class="chip">diese Woche</span>\' : ""}</h2></div>\n      <button class="ibtn" id="wkNext" aria-label="Nächste Woche" ${r.offset === 0 ? "disabled" : ""}>${icon(IC_R)}</button>\n      <span style="flex:1"></span><button class="btn" id="wkDc">An Discord senden</button></section>\n    <section class="kpis">${[\n      ["Netto (Bot)", sUsd(r.net), cls(r.net)], ["Trades", r.n, ""], ["Trefferquote", pct(r.winrate), ""], ["Profit-Faktor", num2(r.pf), r.pf >= 1 ? "pos" : r.pf != null ? "neg" : ""],\n      ["Summe R", (r.r > 0 ? "+" : "") + num2(r.r), cls(r.r)], ["Vorwoche", r.prev_n ? sUsd(r.prev_net) : "–", cls(r.prev_net)], ["Eigene Trades", r.own_n ? `${r.own_n} · ${sUsd(r.own_pnl)}` : "–", cls(r.own_pnl)],\n    ].map(([l, v, c]) => `<div class="kpi"><span class="l">${l}</span><span class="v ${c}">${v}</span></div>`).join("")}</section>\n    <section class="panel"><div class="section-h"><h2>Das Wichtigste</h2><p class="hint">Automatisch zusammengefasst – kommt freitags nach Börsenschluss auch per Discord</p></div>\n      <ul class="wk-hl">${r.highlights.map(h => `<li>${esc(h)}</li>`).join("")}</ul></section>\n    <section class="panel"><div class="section-h"><h2>Tage</h2></div>${dayBarsSvg(allDays)}</section>\n    <div class="grid2">\n      <section class="section"><h2>Nach Strategie</h2><div class="panel scroll">${tbl(r.by_setup, "Strategie")}</div></section>\n      <section class="section"><h2>Nach Session</h2><div class="panel scroll">${tbl(r.by_session, "Session")}</div></section>\n    </div>\n    <div class="grid2">\n      <section class="section"><h2>Nicht genommene Signale</h2><div class="panel">${bl.length ? `<table><thead><tr><th class="t">Grund</th><th>Signale</th><th>Hätten gebracht</th><th class="t">Fazit</th></tr></thead><tbody>${bl.map(([k, v]) =>\n        `<tr><td class="t">${esc(k)}</td><td>${v.n}</td><td class="${v.known ? (v.r < 0 ? "pos" : v.r > 0 ? "neg" : "") : ""}">${v.known ? (v.r > 0 ? "+" : "") + num2(v.r) + " R" : "–"}</td><td class="t hint">${!v.known ? "noch offen" : v.r < 0 ? "Filter hat geholfen" : v.r > 0 ? "Filter hat Gewinn gekostet" : "neutral"}</td></tr>`).join("")}</tbody></table>`\n        : \'<p class="hint">Alle Signale wurden genommen.</p>\'}\n        <p class="hint" style="margin:8px 0 0">${r.signals} Signale insgesamt, ${r.executed} genommen. Alle Signale zusammen (Schatten-Trades): ${(r.signals_r > 0 ? "+" : "") + num2(r.signals_r)} R aus ${r.signals_known} abgeschlossenen.</p></div></section>\n      <section class="section"><h2>Lernmodul</h2><div class="panel">${r.learn.length ? `<div class="flags" style="flex-direction:column;align-items:flex-start;gap:8px">${r.learn.map(x => `<span class="chip wrapc ${/verworfen/.test(x.text) ? "warn" : "good"}">${esc(x.text)}</span>`).join("")}</div>` : \'<p class="hint">Diese Woche nichts selbst umgestellt.</p>\'}\n        ${Object.keys(r.statuses).length ? `<div class="flags" style="margin-top:10px">${Object.entries(r.statuses).map(([k, v]) => `<span class="chip ${v.status === "aktiv" ? "good" : v.status === "pausiert" ? "bad" : v.status === "halbe Größe" ? "warn" : "mute"}">${esc(k)}: ${esc(v.status)}</span>`).join("")}</div>` : ""}</div></section>\n    </div>`;\n  $("#wkPrev").onclick = () => { WK.off++; weekView(true); };\n  $("#wkNext").onclick = () => { if (WK.off > 0) { WK.off--; weekView(true); } };\n  $("#wkDc").onclick = () => act(() => api(`/api/report/week/${WK.off}/discord`, {}), "An Discord geschickt");\n}\n\n/* ───────── Bot gegen Backtest ───────── */\nconst CMP = {mode: "gleich", data: null, at: 0, err: null};\nasync function compareView(force) {\n  const body = $("#stBody");\n  if (force || !CMP.data || Date.now() - CMP.at > 60000) {\n    if (!CMP.data) body.innerHTML = \'<p class="hint">Vergleiche …</p>\';\n    try { CMP.data = await api("/api/compare/" + CMP.mode); CMP.at = Date.now(); CMP.err = null; } catch (e) { CMP.err = e.message; }\n  }\n  if (TAB !== "stats" || STAB !== "vergleich") return;\n  const r = CMP.data; if (!r) { body.innerHTML = `<p class="err-msg">${esc(CMP.err || "")}</p>`; return; }\n  const B = r.backtest, L = r.signals, R = r.bot, cols = [B, L, R];\n  const row = (label, f, help) => `<tr><td class="t">${label}${help ? `<small class="hint" style="display:block">${help}</small>` : ""}</td>${cols.map(c => `<td>${c.n ? f(c) : "–"}</td>`).join("")}</tr>`;\n  const setups = [...new Set(cols.flatMap(c => Object.keys(c.setups || {})))].sort();\n  const m1 = r.match_bt_signals, m2 = r.match_signals_bot;\n  const per = r.period ? `${new Date(r.period[0]).toLocaleDateString("de-DE")} – ${new Date(r.period[1]).toLocaleDateString("de-DE")}` : "alle Daten";\n  body.innerHTML = `\n    <section class="panel"><div class="section-h"><div><h2>Bot gegen Backtest</h2><p class="hint" style="margin:4px 0 0">Läuft der Bot live so wie die Strategie im TradingView-Backtest? Verglichen wird im Zeitraum ${per}.${r.bt_name ? ` Backtest: ${esc(r.bt_name)}` : ""}</p></div>\n      <div class="seg" role="group" aria-label="Zeitraum">${[["gleich", "Gleicher Zeitraum"], ["alles", "Alles"]].map(([k, l]) => `<button type="button" data-cmp="${k}" aria-pressed="${CMP.mode === k}">${l}</button>`).join("")}</div></div>\n      <div class="cmp-notes">${r.notes.map(n => `<div class="cmp-n ${n.tone}"><span class="dot ${n.tone === "ok" ? "ok" : n.tone === "warn" ? "warn" : ""}"></span>${esc(n.text)}</div>`).join("")}</div></section>\n    <section class="panel scroll"><table class="cmp"><thead><tr><th class="t"></th><th>TradingView-Backtest</th><th>Alle Signale live<small class="hint" style="display:block;font-weight:400">jedes Signal simuliert</small></th><th>Bot-Trades<small class="hint" style="display:block;font-weight:400">wirklich genommen</small></th></tr></thead><tbody>\n      ${row("Trades", c => c.n)}\n      ${row("Trades pro Handelstag", c => num2(c.per_day), "deutlich weniger live → Alert prüfen")}\n      ${row("Trefferquote", c => pct(c.winrate))}\n      ${row("Profit-Faktor", c => num2(c.pf))}\n      ${row("Ø Gewinn ÷ Ø Verlust", c => num2(c.payoff), "Verhältnis der Durchschnitte")}\n      ${row("Anteil Long", c => pct(c.long_share))}\n      ${setups.map(k => row(`<span class="chip">${esc(k)}</span>`, c => c.setups && c.setups[k] ? `${c.setups[k].n} · ${pct(c.setups[k].wr)}` : "–")).join("")}\n    </tbody></table></section>\n    <div class="grid2">\n      <section class="section"><h2>Backtest ↔ live angekommene Signale</h2><div class="panel">${m1 ? `<div class="cmp-m">\n        <div><b class="mono">${m1.matched}</b><small>gleiche Trades gefunden</small></div><div><b class="mono ${m1.only_a ? "neg" : ""}">${m1.only_a}</b><small>nur im Backtest</small></div>\n        <div><b class="mono">${m1.only_b}</b><small>nur live</small></div><div><b class="mono">${m1.same_outcome != null ? pct(m1.same_outcome) : "–"}</b><small>gleich ausgegangen</small></div></div>\n        <p class="hint" style="margin:8px 0 0">Ein Trade gilt als gleich, wenn Richtung stimmt und er höchstens 15 Minuten auseinander liegt.</p>` : \'<p class="hint">Dafür braucht es einen geladenen Backtest und live angekommene Signale im selben Zeitraum.</p>\'}</div></section>\n      <section class="section"><h2>Signale ↔ Bot-Trades</h2><div class="panel">${m2 ? `<div class="cmp-m">\n        <div><b class="mono">${m2.matched}</b><small>Signale genommen</small></div><div><b class="mono">${m2.only_a}</b><small>bewusst nicht genommen</small></div>\n        <div><b class="mono">${m2.same_outcome != null ? pct(m2.same_outcome) : "–"}</b><small>Ergebnis wie simuliert</small></div></div>\n        <p class="hint" style="margin:8px 0 0">Weicht das Ergebnis oft ab, liegt es meist an Slippage, übernommenen Ausstiegs-Varianten oder geänderten Stops.</p>` : \'<p class="hint">Noch keine Bot-Trades im Zeitraum.</p>\'}</div></section>\n    </div>`;\n  body.querySelectorAll("[data-cmp]").forEach(b => b.onclick = () => { CMP.mode = b.dataset.cmp; compareView(true); });\n}\n\n/* ───────── Monte-Carlo (Fremdkapital) ───────── */\nconst MC = {src: "auto", mode: "jetzt", data: null, busy: false, err: null, key: ""};\nasync function mcRun() {\n  MC.busy = true; mcPanel();\n  try { MC.data = await api(`/api/montecarlo/${MC.src}/${MC.mode}`); MC.err = null; MC.key = JSON.stringify(S.challenge && S.challenge.cfg); } catch (e) { MC.err = e.message; }\n  MC.busy = false; mcPanel();\n}\nfunction mcFan(r) {\n  const W = 900, H = 230, L = 64, Rr = 14, T = 12, B = 24, f = r.fan;\n  const vals = f.flatMap(p => [p.p10, p.p90]).concat([r.target, r.threshold]);\n  const lo = Math.min(...vals), hi = Math.max(...vals), pad = (hi - lo) * .06 || 100, y0 = lo - pad, y1 = hi + pad;\n  const x = d => L + (W - L - Rr) * d / r.max_days, y = v => T + (H - T - B) * (1 - (v - y0) / (y1 - y0));\n  const band = f.map((p, i) => `${i ? "L" : "M"}${x(p.d).toFixed(1)},${y(p.p90).toFixed(1)}`).join("") + f.slice().reverse().map(p => `L${x(p.d).toFixed(1)},${y(p.p10).toFixed(1)}`).join("") + "Z";\n  const med = f.map((p, i) => `${i ? "L" : "M"}${x(p.d).toFixed(1)},${y(p.p50).toFixed(1)}`).join("");\n  let g = ""; for (let k = 0; k <= 4; k++) { const v = y0 + (y1 - y0) * k / 4; g += `<line class="gl" x1="${L}" x2="${W - Rr}" y1="${y(v)}" y2="${y(v)}"/><text x="${L - 8}" y="${y(v) + 4}" text-anchor="end">${mUsd(v)}</text>`; }\n  for (let d = 0; d <= r.max_days; d += 10) g += `<text x="${x(d)}" y="${H - 6}" text-anchor="${d === 0 ? "start" : d >= r.max_days ? "end" : "middle"}">${d ? "Tag " + d : "jetzt"}</text>`;\n  return `<svg viewBox="0 0 ${W} ${H}" class="chart" role="img" aria-label="Spannbreite des Kontostands">${g}\n    <path d="${band}" fill="var(--accent)" fill-opacity=".14"/>\n    <line x1="${L}" x2="${W - Rr}" y1="${y(r.target)}" y2="${y(r.target)}" stroke="var(--pos)" stroke-dasharray="5 4" stroke-width="1.2"/><text x="${W - Rr}" y="${y(r.target) - 6}" text-anchor="end" style="fill:var(--pos)">Ziel</text>\n    <line x1="${L}" x2="${W - Rr}" y1="${y(r.threshold)}" y2="${y(r.threshold)}" stroke="var(--neg)" stroke-dasharray="5 4" stroke-width="1.2"/><text x="${W - Rr}" y="${y(r.threshold) + 14}" text-anchor="end" style="fill:var(--neg)">Verlustgrenze ${S.challenge && S.challenge.cfg.dd_type !== "static" ? "(Start, wandert mit)" : ""}</text>\n    <path d="${med}" fill="none" stroke="var(--accent)" stroke-width="2.2" vector-effect="non-scaling-stroke"/></svg>`;\n}\nfunction mcPanel() {\n  const el = $("#mcBox"); if (!el) return;\n  const r = MC.data, srcs = [["auto", "Automatisch"], ["bot", "Bot-Trades"], ["eigen", "Eigene Trades"], ["alle", "Bot + eigene"], ["signale", "Alle Signale"], ["backtest", "TradingView-Backtest"]];\n  const sz = r && r.sizes ? r.sizes : {};\n  el.innerHTML = `<div class="section-h"><div><h2>Wie wahrscheinlich bestehst du?</h2><p class="hint" style="margin:4px 0 0">Monte-Carlo: Die App spielt ${r && r.runs ? r.runs.toLocaleString("de-DE") : "3.000"} mögliche Zukünfte durch, indem sie zufällig echte Handelstage aus deiner Historie aneinanderreiht – mit deinen Challenge-Regeln.</p></div>\n      <button class="btn" id="mcGo" ${MC.busy ? "disabled" : ""}>${MC.busy ? "Rechnet …" : "Neu berechnen"}</button></div>\n    <div class="mc-ctl"><label>Datenbasis <select id="mcSrc">${srcs.map(([k, l]) => `<option value="${k}" ${MC.src === k ? "selected" : ""}>${l}${sz[k] != null ? ` (${sz[k]} Tage)` : ""}</option>`).join("")}</select></label>\n      <div class="seg" role="group" aria-label="Start">${[["jetzt", "Ab heutigem Stand"], ["neu", "Challenge neu starten"]].map(([k, l]) => `<button type="button" data-mcm="${k}" aria-pressed="${MC.mode === k}">${l}</button>`).join("")}</div></div>\n    ${MC.err ? `<p class="err-msg">${esc(MC.err)}</p>` : !r ? \'<p class="hint">Wird berechnet …</p>\' : !r.ok ? `<p class="hint">${esc(r.error)} Datenbasis „${esc(srcs.find(s => s[0] === r.source)?.[1] || r.source)}“ hat ${r.pool_days} Handelstage.</p>` : `\n    <div class="mc-big">\n      <div><span class="td-l">Ziel erreicht</span><b class="pos">${pct(r.p_pass)}</b><small>${r.med_pass ? `meist nach ${r.med_pass} Handelstagen` : "–"}</small></div>\n      <div><span class="td-l">Verlustgrenze gerissen</span><b class="neg">${pct(r.p_fail)}</b><small>${r.med_fail ? `meist nach ${r.med_fail} Handelstagen` : "–"}</small></div>\n      <div><span class="td-l">Nach ${r.max_days} Tagen offen</span><b>${pct(r.p_open)}</b><small>weder Ziel noch Grenze</small></div>\n      <div><span class="td-l">Ø pro Handelstag</span><b class="${cls(r.avg_day)}">${sUsd(r.avg_day)}</b><small>${r.pool_days} Tage · ${r.pool_trades} Trades als Basis</small></div>\n    </div>\n    <div class="mc-bar"><i class="p" style="width:${r.p_pass}%"></i><i class="o" style="width:${r.p_open}%"></i><i class="n" style="width:${r.p_fail}%"></i></div>\n    ${mcFan(r)}\n    <div class="legend" style="margin-top:6px"><span><i style="background:var(--accent)"></i>mittlerer Verlauf</span><span><i style="background:var(--accent);opacity:.3"></i>80 % der Verläufe liegen in diesem Band</span></div>\n    <p class="hint" style="margin:8px 0 0">${r.from_now ? "Startet beim heutigen Kontostand." : "Startet bei frischem Konto."} Basis: ${esc(srcs.find(s => s[0] === r.source)?.[1] || r.source)}. ${r.pool_days < 20 ? "<b>Wenig Daten</b> – die Zahlen sind noch grob. " : ""}Die Vergangenheit garantiert nichts; die Rechnung zeigt, wie gut Größe und Regeln zu deinen bisherigen Ergebnissen passen.${S.challenge && S.challenge.cfg.consistency_pct ? " Die Konsistenzregel ist nicht eingerechnet." : ""}</p>`}`;\n  $("#mcGo").onclick = mcRun;\n  $("#mcSrc").onchange = e => { MC.src = e.target.value; mcRun(); };\n  el.querySelectorAll("[data-mcm]").forEach(b => b.onclick = () => { MC.mode = b.dataset.mcm; mcRun(); });\n}\n\n\n/* ───────── Wirtschafts-News ───────── */\nconst NEWSD = {events: [], fetched: 0, error: null, loading: false, at: 0};\nconst NV = {range: "heute", imp: "wichtig", usd: true};\ntry { Object.assign(NV, JSON.parse(localStorage.getItem("fvg-news") || "{}")); } catch (e) {}\nasync function loadNews(force) {\n  try {\n    if (force) await api("/api/news/refresh", {});\n    Object.assign(NEWSD, await api("/api/news"), {at: Date.now()});\n  } catch (e) { NEWSD.error = e.message; }\n  if (TAB === "cockpit") newsPanel();\n  newsPill();\n}\nfunction newsFiltered() {\n  const now = new Date(), d0 = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();\n  return NEWSD.events.filter(e => (!NV.usd || e.country === "USD")\n    && (NV.imp === "hoch" ? e.impact === "high" || e.impact === "holiday" : e.impact !== "low")\n    && (NV.range === "heute" ? e.ts >= d0 && e.ts < d0 + 864e5 : true));\n}\nconst inMin = ms => { const m = Math.round(ms / 60000); if (Math.abs(m) < 60) return m >= 0 ? `in ${m} Min` : `vor ${-m} Min`; const h = Math.round(m / 6) / 10; return m >= 0 ? `in ${String(h).replace(".", ",")} Std` : ""; };\nfunction newsPauseChip(e) {\n  const nw = (S && S.config && S.config.news) || {};\n  if (!nw.enabled || (nw.usd_only && e.country !== "USD") || !(e.impact === "high" || (nw.impact === "medium" && e.impact === "medium"))) return "";\n  const f = ms => new Date(ms).toLocaleTimeString("de-DE", {hour: "2-digit", minute: "2-digit"});\n  return ` <span class="chip" title="In dieser Zeit nimmt der Bot keine neuen Trades${nw.close_before ? " und schließt offene Positionen 1 Min vorher" : ""}">Bot-Pause ${f(e.ts - nw.before_min * 60000)}–${f(e.ts + nw.after_min * 60000)}</span>`;\n}\nfunction newsPill() {\n  const el = $("#pNews"); if (!el) return;\n  const now = Date.now(), next = NEWSD.events.find(e => e.country === "USD" && e.impact === "high" && e.ts > now - 5 * 60000 && e.ts < now + 45 * 60000);\n  el.hidden = !next;\n  if (next) el.innerHTML = `<span class="dot bad"></span>${esc(next.title)} ${next.ts > now ? inMin(next.ts - now) : "gerade"}`;\n}\nfunction newsPanel() {\n  const box = $("#newsSec"); if (!box) return;\n  if (!NEWSD.at && !newsPanel._req) { newsPanel._req = true; loadNews(); }\n  const list = newsFiltered(), now = Date.now();\n  const next = list.find(e => e.ts > now);\n  const hm = ts => new Date(ts).toLocaleTimeString("de-DE", {hour: "2-digit", minute: "2-digit"});\n  const dayH = ts => new Date(ts).toLocaleDateString("de-DE", {weekday: "long", day: "numeric", month: "short"});\n  let lastDay = "", rows = "";\n  for (const e of list) {\n    const dk = new Date(e.ts).toDateString();\n    if (NV.range === "woche" && dk !== lastDay) { rows += `<div class="nw-day">${dayH(e.ts)}${dk === new Date().toDateString() ? " · heute" : ""}</div>`; lastDay = dk; }\n    const past = e.ts < now - 5 * 60000, live = Math.abs(e.ts - now) <= 15 * 60000;\n    rows += `<div class="nw ${past ? "past" : ""} ${live ? "live" : ""} ${e === next ? "next" : ""}">\n      <span class="nw-t mono">${e.impact === "holiday" ? "ganztägig" : hm(e.ts)}</span>\n      <span class="imp ${e.impact}" title="${{high: "Hohe", medium: "Mittlere", low: "Geringe", holiday: "Feiertag:"}[e.impact]} Wirkung"><i></i><i></i><i></i></span>\n      <span class="nw-n"><b>${esc(e.title)}</b>${NV.usd ? "" : ` <span class="chip mute">${esc(e.country)}</span>`}${e.impact === "holiday" ? \' <span class="chip warn">Feiertag</span>\' : ""}${newsPauseChip(e)}</span>\n      <span class="nw-v mono">${e.actual ? `<b>${esc(e.actual)}</b> · ` : ""}${e.forecast ? `Prog. ${esc(e.forecast)}` : ""}${e.previous ? `${e.forecast ? " · " : ""}vorher ${esc(e.previous)}` : ""}</span>\n      <span class="nw-c">${live ? \'<span class="chip bad">jetzt</span>\' : past ? "" : e === next ? `<span class="chip">${inMin(e.ts - now)}</span>` : ""}</span>\n    </div>`;\n  }\n  const empty = NEWSD.loading && !NEWSD.events.length ? "News werden geladen …"\n    : NEWSD.error && !NEWSD.events.length ? esc(NEWSD.error)\n    : NV.range === "heute" ? "Heute keine wichtigen Termine. Normaler Handelstag ohne geplante Datenveröffentlichungen." : "Keine Termine in dieser Woche.";\n  box.innerHTML = `<div class="section-h"><h2>Wirtschafts-News</h2>\n      <div class="nw-ctl">\n        <div class="seg" role="group" aria-label="Zeitraum">${[["heute", "Heute"], ["woche", "Woche"]].map(([k, l]) => `<button type="button" data-nr="${k}" aria-pressed="${NV.range === k}">${l}</button>`).join("")}</div>\n        <div class="seg" role="group" aria-label="Wichtigkeit">${[["hoch", "Hoch"], ["wichtig", "Hoch + Mittel"]].map(([k, l]) => `<button type="button" data-ni="${k}" aria-pressed="${NV.imp === k}">${l}</button>`).join("")}</div>\n        <div class="seg" role="group" aria-label="Länder">${[[true, "USD"], [false, "Alle"]].map(([k, l]) => `<button type="button" data-nu="${k}" aria-pressed="${NV.usd === k}">${l}</button>`).join("")}</div>\n      </div></div>\n    <div class="panel nw-box">\n      ${next && next.impact === "high" && next.ts - now < 3 * 3600e3 ? `<div class="nw-alert"><span class="dot bad"></span><b>${esc(next.title)}</b> ${inMin(next.ts - now)} · ${hm(next.ts)} Uhr. Rund um wichtige US-Daten springen NQ und ES oft stark, Stops können durchrutschen.</div>` : ""}\n      ${rows || `<div class="empty" style="border:0">${empty}</div>`}\n      <div class="nw-f"><span class="hint">Uhrzeiten in deiner Ortszeit · Quelle: Forex-Factory-Kalender${NEWSD.fetched ? ` · Stand ${new Date(NEWSD.fetched * 1000).toLocaleTimeString("de-DE", {hour: "2-digit", minute: "2-digit"})}` : ""}${NEWSD.error && NEWSD.events.length ? ` · <span class="neg">${esc(NEWSD.error)}</span>` : ""}</span>\n        <button class="lnk" id="nwRef" style="color:var(--accent)">Neu laden</button></div>\n    </div>`;\n  const save = () => { try { localStorage.setItem("fvg-news", JSON.stringify(NV)); } catch (e) {} newsPanel(); };\n  box.querySelectorAll("[data-nr]").forEach(b => b.onclick = () => { NV.range = b.dataset.nr; save(); });\n  box.querySelectorAll("[data-ni]").forEach(b => b.onclick = () => { NV.imp = b.dataset.ni; save(); });\n  box.querySelectorAll("[data-nu]").forEach(b => b.onclick = () => { NV.usd = b.dataset.nu === "true"; save(); });\n  $("#nwRef").onclick = () => { toast("News werden neu geladen"); loadNews(true); };\n}\nsetInterval(() => loadNews(), 5 * 60000);\n\n/* ───────── Edge-Check: wie gut ist jede Strategie wirklich? ───────── */\nconst EDGE = {data: null, at: 0, open: null, period: "alle"};\ntry { EDGE.period = localStorage.getItem("fvg-edge-p") || "alle"; } catch (e) {}\nfunction wilson(k, n) {   // 95-%-Vertrauensbereich einer Quote\n  if (!n) return [0, 0];\n  const z = 1.96, p = k / n, d = 1 + z * z / n, c = (p + z * z / (2 * n)) / d, h = z * Math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d;\n  return [Math.max(0, c - h) * 100, Math.min(1, c + h) * 100];\n}\nconst DOW = ["Mo", "Di", "Mi", "Do", "Fr"];\nfunction edgeCalc(list) {\n  const n = list.length, w = list.filter(t => t.r > 0), l = list.filter(t => t.r <= 0);\n  const aw = w.length ? w.reduce((a, t) => a + t.r, 0) / w.length : 0, al = l.length ? -l.reduce((a, t) => a + t.r, 0) / l.length : 0;\n  const wr = n ? w.length / n * 100 : 0, base = aw > 0 && al > 0 ? al / (aw + al) * 100 : 100 / 3;\n  const [lo, hi] = wilson(w.length, n), exp = n ? list.reduce((a, t) => a + t.r, 0) / n : 0;\n  const gw = w.reduce((a, t) => a + t.r, 0), gl = -l.reduce((a, t) => a + t.r, 0);\n  const edge = wr - base;\n  const grade = !n ? "–" : lo > base + 5 ? "A" : lo > base ? "B" : wr > base ? "C" : "D";\n  const trust = Math.round(Math.max(0, Math.min(100, 50 + 2 * (lo - base) + (edge > 0 ? edge : 0))) * (0.35 + 0.65 * Math.min(1, n / 40)));\n  return {n, w: w.length, wr, base, lo, hi, exp, pf: gl ? gw / gl : null, edge, grade, trust, aw, al};\n}\nfunction streaks(list) {\n  let cur = 0, curW = null, bw = 0, bl = 0, run = 0, last = null;\n  for (const t of list) { const win = t.r > 0; run = win === last ? run + 1 : 1; last = win; if (win) bw = Math.max(bw, run); else bl = Math.max(bl, run); }\n  cur = run; curW = last;\n  return {cur, curW, bw, bl};\n}\nasync function edgeLoad(force) {\n  if (!force && EDGE.data && Date.now() - EDGE.at < 60000) return;\n  try { EDGE.data = await api("/api/edge"); EDGE.at = Date.now(); } catch (e) { EDGE.err = e.message; }\n}\nasync function edgeView() {\n  const body = $("#stBody");\n  if (!EDGE.data) body.innerHTML = \'<div class="empty">Edge-Check wird berechnet …</div>\';\n  const fresh = !EDGE.data || Date.now() - EDGE.at > 60000;\n  if (fresh) { await edgeLoad(); }\n  else if (body.querySelector(".edge")) return;   // nicht bei jedem Refresh neu aufbauen (aufgeklappte Zeile bleibt)\n  if (STAB !== "edge" || TAB !== "stats") return;\n  const days = {"1m": 31, "3m": 92, "6m": 183, alle: 1e5}[EDGE.period];\n  const since = Date.now() / 1000 - days * 86400;\n  const all = (EDGE.data ? EDGE.data.trades : []).filter(t => (t.closed || t.opened) >= since);\n  const by = {}; all.forEach(t => (by[t.setup] = by[t.setup] || []).push(t));\n  const rows = Object.entries(by).map(([k, l]) => ({k, l, c: edgeCalc(l)})).sort((a, b) => b.c.trust - a.c.trust);\n  const tot = edgeCalc(all), bestRow = rows[0];\n  const spark = l => { let s = 0; const v = l.slice(-60).map(t => (s += t.r)); if (v.length < 2) return ""; const lo = Math.min(0, ...v), hi = Math.max(0, ...v), sp = hi - lo || 1;\n    const pts = v.map((y, i) => `${(i / (v.length - 1) * 80).toFixed(1)},${(22 - (y - lo) / sp * 20).toFixed(1)}`).join(" ");\n    return `<svg viewBox="0 0 80 24" class="spk"><polyline points="${pts}" fill="none" stroke="${v[v.length - 1] >= 0 ? "var(--accent)" : "var(--neg)"}" stroke-width="1.6" vector-effect="non-scaling-stroke"/></svg>`; };\n  const ciBar = c => `<div class="ci"><span class="ci-r" style="left:${c.lo}%;width:${Math.max(1, c.hi - c.lo)}%"></span><span class="ci-b" style="left:${c.base}%"></span><span class="ci-p" style="left:${c.wr}%"></span></div>`;\n  const detail = r => {\n    const l = r.l, st = streaks(l), last20 = edgeCalc(l.slice(-20));\n    const dir = ["long", "short"].map(sd => [sd, edgeCalc(l.filter(t => t.side === sd))]);\n    const wd = DOW.map((d, i) => [d, edgeCalc(l.filter(t => t.ny_weekday === i))]);\n    const hrs = {}; l.forEach(t => (hrs[t.ny_hour] = hrs[t.ny_hour] || []).push(t));\n    const hk = Object.keys(hrs).map(Number).sort((a, b) => a - b);\n    return `<div class="ed-x">\n      <div class="ed-card"><span class="l">Bilanz · Gewinn / Verlust</span>\n        <div class="grid-wl">${l.slice(-200).map(t => `<i class="${t.r > 0 ? "w" : "x"}" title="${dtm(t.closed)} · ${t.r > 0 ? "+" : ""}${num2(t.r)} R"></i>`).join("")}</div>\n        <div class="ed-mini">${[["Aktuell", st.cur ? `${st.cur}${st.curW ? "G" : "V"}` : "–", st.curW ? "pos" : "neg"], ["Längste Gewinnserie", st.bw, "pos"], ["Längste Verlustserie", st.bl, "neg"],\n          ["Letzte 20", pct(last20.wr), last20.wr >= r.c.base ? "pos" : "neg"], ["Gesamt", pct(r.c.wr), ""]].map(([a, b, c]) => `<div><span class="l">${a}</span><b class="${c}">${b}</b></div>`).join("")}</div>\n        <span class="hint">${l.length} Signale${l.length > 200 ? " · neueste 200 gezeigt" : ""} · älteste links</span></div>\n      <div class="ed-card"><span class="l">Wo es funktioniert</span>\n        ${dir.map(([sd, c]) => `<div class="dirrow"><span>${sd === "long" ? "Long" : "Short"}</span><div class="dbar"><i style="width:${c.wr}%"></i><b style="left:${c.base}%"></b></div><span class="mono">${c.n ? pct(c.wr) : "–"}</span><span class="hint">(${c.n})</span></div>`).join("")}\n        <span class="l" style="margin-top:8px">Trefferquote je Wochentag</span>\n        <div class="wd">${wd.map(([d, c]) => `<div class="${!c.n ? "" : c.wr >= c.base ? "ok" : "bad"}"><span>${d}</span><b>${c.n ? Math.round(c.wr) + " %" : "–"}</b><small>${c.n}</small></div>`).join("")}</div>\n        <span class="l" style="margin-top:8px">Stunden (NY) · Ø R</span>\n        <div class="hrs">${hk.length ? hk.map(h => { const c = edgeCalc(hrs[h]); const a = Math.max(-1, Math.min(1, c.exp));\n          return `<div title="${h}:00 NY · ${c.n} Signale · ${pct(c.wr)}" style="background:${a >= 0 ? `rgba(47,211,154,${0.12 + a * 0.55})` : `rgba(255,93,108,${0.12 - a * 0.55})`}"><span>${h}</span><b>${c.exp > 0 ? "+" : ""}${num2(c.exp)}</b></div>`; }).join("") : \'<span class="hint">–</span>\'}</div></div>\n      <div class="ed-card ed-wide"><span class="l">Letzte Signale · neueste zuerst</span>\n        <div class="recent">${l.slice(-14).reverse().map(t => `<span class="${t.r > 0 ? "w" : "x"}">${new Date(t.closed * 1000).toLocaleDateString("de-DE", {weekday: "short", day: "numeric", month: "short"})} <b>${t.r > 0 ? "+" : ""}${num2(t.r)} R</b> ${t.r > 0 ? "✓" : "✗"}</span>`).join("")}</div></div>\n    </div>`;\n  };\n  body.innerHTML = `\n    <section class="panel edge">\n      <div class="ed-top">\n        <div class="ed-k">${[["Trefferquote", tot.n ? pct(tot.wr) : "–", `${tot.n ? (tot.edge >= 0 ? "+" : "") + num2(tot.edge) + " Pkt. über Breakeven" : ""}`],\n          ["Ausgewertete Signale", tot.n, `${rows.length} Strategien`], ["Ø R pro Signal", tot.n ? (tot.exp > 0 ? "+" : "") + num2(tot.exp) : "–", tot.pf ? `Profit-Faktor ${num2(tot.pf)}` : ""],\n          ["Beste Strategie", bestRow ? esc(bestRow.k) : "–", bestRow ? `Vertrauen ${bestRow.c.trust} · Note ${bestRow.c.grade}` : ""]].map(([l, v, sub]) => `<div><span class="l">${l}</span><b>${v}</b><small>${sub}</small></div>`).join("")}</div>\n        <div class="seg" role="group" aria-label="Zeitraum">${[["1m", "1M"], ["3m", "3M"], ["6m", "6M"], ["alle", "Alle"]].map(([k, l]) => `<button type="button" data-ep="${k}" aria-pressed="${EDGE.period === k}">${l}</button>`).join("")}</div>\n      </div>\n      <p class="hint ed-help"><b>So liest du es:</b> Trefferquote = wie oft das Signal ins Ziel lief · <b>Breakeven</b> = Quote, ab der die Strategie bei ihrem Chance-Risiko-Verhältnis Geld verdient · <b>Edge</b> = Abstand dazu · <b>Note A–D</b> = liegt auch der vorsichtige Wert (untere Grenze des 95-%-Bereichs) über Breakeven? · <b>Vertrauen</b> = Gesamtwert aus Edge und Stichprobe (danach sortiert). Gezählt werden alle Signale aus TradingView, auch die du nicht genommen hast.</p>\n      ${rows.length ? `<div class="scroll"><table class="ed-t"><thead><tr><th class="t">Strategie</th><th class="t">Trefferquote · 95 %</th><th>Note</th><th>Breakeven</th><th>Edge</th><th>Ø R</th><th>Signale</th><th class="t">Verlauf</th><th>Vertrauen</th><th></th></tr></thead><tbody>\n        ${rows.map(r => `<tr class="ed-r ${EDGE.open === r.k ? "open" : ""}" data-ek="${esc(r.k)}" tabindex="0">\n          <td class="t"><b>${esc(r.k)}</b><small class="hint">${r.c.aw ? `Ø Gewinn +${num2(r.c.aw)} R · Ø Verlust −${num2(r.c.al)} R` : ""}</small></td>\n          <td class="t"><div class="ci-w"><span class="mono">${pct(r.c.wr)}</span>${ciBar(r.c)}<small class="hint">±${num2((r.c.hi - r.c.lo) / 2)}</small></div></td>\n          <td><span class="grade g${r.c.grade}">${r.c.grade}</span></td>\n          <td class="muted">${pct(r.c.base)}</td>\n          <td class="${cls(r.c.edge)}">${r.c.edge > 0 ? "+" : ""}${num2(r.c.edge)}</td>\n          <td class="${cls(r.c.exp)}">${r.c.exp > 0 ? "+" : ""}${num2(r.c.exp)}</td>\n          <td>${r.c.n}</td>\n          <td class="t">${spark(r.l)}</td>\n          <td><b class="trust" style="color:${r.c.trust >= 70 ? "var(--accent)" : r.c.trust >= 50 ? "var(--fg)" : "var(--muted)"}">${r.c.trust}</b></td>\n          <td><span class="chev">▾</span></td></tr>\n          ${EDGE.open === r.k ? `<tr class="ed-d"><td colspan="${window.innerWidth <= 700 ? 5 : 10}">${detail(r)}</td></tr>` : ""}`).join("")}\n      </tbody></table></div>` : `<div class="empty">Noch keine abgeschlossenen Signale${EDGE.period !== "alle" ? " in diesem Zeitraum" : ""}. Sobald TradingView Signale und Kerzen schickt, füllt sich der Edge-Check von selbst.</div>`}\n    </section>`;\n  body.querySelectorAll("[data-ep]").forEach(b => b.onclick = () => { EDGE.period = b.dataset.ep; try { localStorage.setItem("fvg-edge-p", EDGE.period); } catch (e) {} body.innerHTML = ""; edgeView(); });\n  body.querySelectorAll(".ed-r").forEach(tr => { const t = () => { EDGE.open = EDGE.open === tr.dataset.ek ? null : tr.dataset.ek; body.innerHTML = ""; edgeView(); };\n    tr.onclick = t; tr.onkeydown = e => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); t(); } }; });\n}\n\n/* ───────── Session-Muster aus den gesammelten Kerzen ───────── */\nconst MU = {fam: "auto", data: null, at: 0};\nasync function musterView() {\n  const body = $("#stBody");\n  if (MU.data && Date.now() - MU.at < 120000 && body.querySelector(".muster")) return;\n  if (!MU.data) body.innerHTML = \'<div class="empty">Session-Muster werden berechnet …</div>\';\n  try { MU.data = await api("/api/sessions/" + MU.fam); MU.at = Date.now(); } catch (e) { body.innerHTML = `<div class="empty">${esc(e.message)}</div>`; return; }\n  if (STAB !== "muster" || TAB !== "stats") return;\n  const D = MU.data.days || [], n = D.length;\n  const prob = (k, m) => { const [lo, hi] = wilson(k, m); return {p: m ? k / m * 100 : null, lo, hi, k, m}; };\n  const pr = x => x.m ? `<b class="mono">${Math.round(x.p)} %</b><small class="hint">${x.k} von ${x.m} · 95 %: ${Math.round(x.lo)}–${Math.round(x.hi)} %</small>` : \'<b class="mono muted">–</b><small class="hint">noch keine Daten</small>\';\n  const bar = (parts) => `<div class="pbar">${parts.map(([v, c, l]) => v ? `<i style="width:${v}%;background:${c}" title="${l}: ${Math.round(v)} %"></i>` : "").join("")}</div>`;\n  const brk = key => { const ev = D.map(d => d.events[key]).filter(Boolean); const m = ev.length;\n    const up = ev.filter(e => e.first === "oben").length, dn = ev.filter(e => e.first === "unten").length, none = m - up - dn, both = ev.filter(e => e.both).length;\n    return {m, up: prob(up, m), dn: prob(dn, m), none: prob(none, m), both: prob(both, m),\n      times: ev.filter(e => e.when).map(e => e.when)}; };\n  const card = (title, sub, b) => `<div class="mu-c"><div class="mu-h"><b>${title}</b><small class="hint">${sub}</small></div>\n    ${bar([[b.up.p, "var(--pos)", "oben zuerst"], [b.dn.p, "var(--neg)", "unten zuerst"], [b.none.p, "var(--line2)", "kein Bruch"]])}\n    <div class="mu-g"><div><span class="l">Oben zuerst</span>${pr(b.up)}</div><div><span class="l">Unten zuerst</span>${pr(b.dn)}</div>\n      <div><span class="l">Beide Seiten (Sweep)</span>${pr(b.both)}</div><div><span class="l">Kein Bruch</span>${pr(b.none)}</div></div></div>`;\n  const gaps = D.map(d => d.events.gap).filter(g => g && g.dir !== "keins"), gu = gaps.filter(g => g.dir === "hoch"), gd = gaps.filter(g => g.dir === "runter");\n  const fillMin = gaps.filter(g => g.filled && g.when).map(g => { const [h, m] = g.when.split(":").map(Number); return h * 60 + m - 570; }).sort((a, b) => a - b);\n  const med = fillMin.length ? fillMin[Math.floor(fillMin.length / 2)] : null;\n  const pdh = prob(D.filter(d => d.events.pdh).length, D.filter(d => "pdh" in d.events).length), pdl = prob(D.filter(d => d.events.pdl).length, D.filter(d => "pdl" in d.events).length);\n  const mid = prob(D.filter(d => d.events.mid).length, D.filter(d => "mid" in d.events).length);\n  const hist = key => { const b = Array(7).fill(0); D.forEach(d => { const t = d.events[key]; if (!t) return; const [h, m] = t.split(":").map(Number); b[Math.min(6, Math.max(0, h - 9 - (m < 30 ? 1 : 0)))]++; }); return b; };\n  const hod = hist("hod"), lod = hist("lod"), hmax = Math.max(1, ...hod, ...lod);\n  const HL = ["9:30", "10:30", "11:30", "12:30", "13:30", "14:30", "15:30"];\n  body.innerHTML = `<section class="panel muster">\n    <div class="ed-top"><div class="ed-k">${[["Gesammelte Handelstage", n, MU.data.fam ? MU.data.fam + "-Kerzen aus TradingView" : ""],\n      ["Gap gefüllt", gaps.length ? Math.round(gaps.filter(g => g.filled).length / gaps.length * 100) + " %" : "–", gaps.length ? `${gaps.length} Gaps · Median ${med != null ? med + " Min nach Open" : "–"}` : ""],\n      ["PDH genommen", pdh.m ? Math.round(pdh.p) + " %" : "–", "in der New-York-Session"], ["PDL genommen", pdl.m ? Math.round(pdl.p) + " %" : "–", "in der New-York-Session"]]\n      .map(([l, v, sub]) => `<div><span class="l">${l}</span><b>${v}</b><small>${sub}</small></div>`).join("")}</div>\n      ${(MU.data.fams || []).length > 1 ? `<div class="seg">${MU.data.fams.map(f => `<button type="button" data-mf="${f}" aria-pressed="${MU.data.fam === f}">${f}</button>`).join("")}</div>` : ""}</div>\n    ${n < 20 ? `<p class="hint ed-help">Die App sammelt die Kerzen, die TradingView schickt, und wertet jeden fertigen Handelstag aus. Mit ${n} ${n === 1 ? "Tag" : "Tagen"} sind die Zahlen noch wackelig (siehe 95-%-Bereich). Ab etwa 40 Tagen werden sie belastbar. Dafür muss der Alert der Strategie in TradingView laufen und „Kerzen-Daten an die App senden“ an sein (Standard).</p>` : ""}\n    <div class="mu">\n      ${card("London-Range (02:00–05:00 NY)", "Welche Seite bricht danach zuerst?", brk("london"))}\n      ${card("Initial Balance (09:30–10:30)", "Welche Seite der ersten Stunde bricht zuerst?", brk("ib"))}\n      ${card("Asien-Range (20:00–00:00)", "Welche Seite bricht ab Mitternacht zuerst?", brk("asia"))}\n      <div class="mu-c"><div class="mu-h"><b>Opening-Gap</b><small class="hint">RTH-Open gegen Vortagesschluss · gefüllt bis 16:00</small></div>\n        <div class="mu-g"><div><span class="l">Gap hoch gefüllt</span>${pr(prob(gu.filter(g => g.filled).length, gu.length))}</div>\n          <div><span class="l">Gap runter gefüllt</span>${pr(prob(gd.filter(g => g.filled).length, gd.length))}</div>\n          <div><span class="l">Midnight Open getestet</span>${pr(mid)}</div>\n          <div><span class="l">Median bis Fill</span><b class="mono">${med != null ? med + " Min" : "–"}</b><small class="hint">nach 09:30</small></div></div></div>\n      <div class="mu-c mu-w"><div class="mu-h"><b>Wann entsteht Hoch und Tief des Tages?</b><small class="hint">New-York-Session je Stunde</small></div>\n        <div class="hist">${HL.map((h, i) => `<div><div class="hb"><i class="p" style="height:${hod[i] / hmax * 100}%" title="Tageshoch ${h}: ${hod[i]}"></i><i class="n" style="height:${lod[i] / hmax * 100}%" title="Tagestief ${h}: ${lod[i]}"></i></div><span>${h}</span></div>`).join("")}</div>\n        <div class="legend"><span><i style="background:var(--pos)"></i>Tageshoch</span><span><i style="background:var(--neg)"></i>Tagestief</span></div></div>\n    </div></section>`;\n  body.querySelectorAll("[data-mf]").forEach(b => b.onclick = () => { MU.fam = b.dataset.mf; MU.data = null; body.innerHTML = ""; musterView(); });\n}\n\n/* ───────── Key Levels heute (Cockpit) ───────── */\nconst LV = {fam: "auto", data: null, at: 0};\nasync function levelsLoad() {\n  try { LV.data = await api("/api/levels/" + LV.fam); LV.at = Date.now(); } catch (e) { LV.err = e.message; }\n  if (TAB === "cockpit") levelsPanel();\n}\nfunction levelsPanel() {\n  const box = $("#lvSec"); if (!box) return;\n  if (!LV.data || Date.now() - LV.at > 30000) { if (!levelsPanel._busy) { levelsPanel._busy = true; levelsLoad().finally(() => levelsPanel._busy = false); } if (!LV.data) return; }\n  const d = LV.data, T = d.today;\n  if (!d.fam || !T) { box.innerHTML = `<div class="section-h"><h2>Key Levels heute</h2></div><div class="empty">Erscheinen, sobald TradingView Kerzen schickt (Alert der Strategie läuft, „Kerzen-Daten an die App senden“ an). Ab dem zweiten Tag gibt es auch Vortages-Levels.</div>`; return; }\n  const ev = T.events || {}, price = d.price;\n  const L = [["PDH", "Vortageshoch", T.pdh, ev.pdh], ["PDL", "Vortagestief", T.pdl, ev.pdl], ["PDC", "Vortagesschluss", T.pdc, ev.gap && ev.gap.filled ? ev.gap.when : null],\n    ["ONH", "Overnight-Hoch", T.onh], ["ONL", "Overnight-Tief", T.onl],\n    ["AH", "Asien-Hoch", T.asia_h, ev.asia && ev.asia.first === "oben" ? ev.asia.when : null], ["AL", "Asien-Tief", T.asia_l, ev.asia && ev.asia.first === "unten" ? ev.asia.when : null],\n    ["LH", "London-Hoch", T.lon_h, ev.london && ev.london.first === "oben" ? ev.london.when : null], ["LL", "London-Tief", T.lon_l, ev.london && ev.london.first === "unten" ? ev.london.when : null],\n    ["MO", "Midnight Open", T.mid_open, ev.mid], ["RO", "RTH-Open 09:30", T.rth_open],\n    ["IBH", "IB-Hoch", T.ib_h, ev.ib && ev.ib.first === "oben" ? ev.ib.when : null], ["IBL", "IB-Tief", T.ib_l, ev.ib && ev.ib.first === "unten" ? ev.ib.when : null]]\n    .filter(x => x[2] != null).sort((a, b) => b[2] - a[2]);\n  let rows = "", placed = false;\n  for (const [k, name, v, hit] of L) {\n    if (!placed && price != null && price > v) { rows += `<div class="lv-row now"><span class="lv-k">Kurs</span><span class="lv-n">${esc(d.fam)} jetzt</span><span class="lv-p mono">${px(price)}</span><span></span><span></span></div>`; placed = true; }\n    const dist = price != null ? v - price : null;\n    rows += `<div class="lv-row ${k.startsWith("PD") ? "pd" : ""}"><span class="lv-k">${k}</span><span class="lv-n">${name}</span><span class="lv-p mono">${px(v)}</span>\n      <span class="lv-d mono ${dist == null ? "" : dist > 0 ? "pos" : "neg"}">${dist == null ? "" : (dist > 0 ? "+" : "−") + Math.abs(dist).toFixed(2).replace(".", ",")}</span>\n      <span>${hit ? `<span class="chip ${k === "MO" || k === "PDC" ? "" : "warn"}">${k === "MO" ? "getestet" : k === "PDC" ? "Gap gefüllt" : "gebrochen"} ${hit}</span>` : ""}</span></div>`;\n  }\n  if (!placed && price != null) rows += `<div class="lv-row now"><span class="lv-k">Kurs</span><span class="lv-n">${esc(d.fam)} jetzt</span><span class="lv-p mono">${px(price)}</span><span></span><span></span></div>`;\n  const tags = [];\n  if (ev.gap && ev.gap.dir !== "keins") tags.push(`Gap ${ev.gap.dir} ${Math.abs(ev.gap.size).toFixed(2).replace(".", ",")} Pkt. · ${ev.gap.filled ? "gefüllt " + ev.gap.when : "offen"}`);\n  if (ev.asia) tags.push(`Asien: ${ev.asia.first ? ev.asia.first + " zuerst " + ev.asia.when : "kein Bruch"}`);\n  if (ev.london) tags.push(`London: ${ev.london.first ? ev.london.first + " zuerst " + ev.london.when : "kein Bruch"}${ev.london.both ? " · beide Seiten" : ""}`);\n  if (ev.ib) tags.push(`IB: ${ev.ib.first ? ev.ib.first + " zuerst " + ev.ib.when : "kein Bruch"}`);\n  box.innerHTML = `<div class="section-h"><h2>Key Levels heute</h2>\n      ${(d.fams || []).length > 1 ? `<div class="seg">${d.fams.map(f => `<button type="button" data-lf="${f}" aria-pressed="${d.fam === f}">${f}</button>`).join("")}</div>` : `<p class="hint">${esc(d.fam)} · Handelstag ${esc(T.day.split("-").reverse().join("."))}</p>`}</div>\n    <div class="panel lv-box">${tags.length ? `<div class="lv-tags">${tags.map(t => `<span class="chip mute">${t}</span>`).join("")}</div>` : ""}\n      <div class="lv-list">${rows || \'<div class="empty" style="border:0">Noch keine Levels für heute.</div>\'}</div>\n      <div class="nw-f"><span class="hint">Abstand in Punkten vom aktuellen Kurs · Zeiten in NY · Levels aus den Kerzen, die TradingView schickt</span></div></div>`;\n  box.querySelectorAll("[data-lf]").forEach(b => b.onclick = () => { LV.fam = b.dataset.lf; LV.data = null; levelsLoad(); });\n}\n\n/* ───────── Fremdkapital (Prop-Firm-Challenge) ───────── */\nconst DDT = {eod: "EOD-Trailing (Tagesende)", intraday: "Intraday-Trailing (Echtzeit)", static: "Statisch (fest)"};\nconst mUsd = v => v == null ? "–" : (v < 0 ? "−$" : "$") + Math.abs(v).toLocaleString("de-DE", {maximumFractionDigits: 0});\nfunction chStatus(c) {\n  if (c.breached) return ["bad", "Verlustgrenze erreicht"];\n  if (c.passed) return ["good", "Ziel erreicht"];\n  if (c.daily_hit) return ["bad", "Tageslimit erreicht"];\n  if (c.can_lose < Math.max(250, c.cfg.max_dd * 0.15)) return ["warn", "Wenig Puffer"];\n  return ["", "Läuft"];\n}\nfunction chCard() {\n  const box = $("#chCard"); if (!box) return;\n  const c = S.challenge; box.hidden = !c;\n  if (!c) return;\n  const [st, txt] = chStatus(c), tgt = c.cfg.profit_target, prog = tgt > 0 ? Math.max(0, Math.min(100, c.profit / tgt * 100)) : 0;\n  box.innerHTML = `<button type="button" class="chc" id="chGo">\n    <div class="chc-h"><span class="l">Fremdkapital${c.cfg.name ? " · " + esc(c.cfg.name) : ""}</span><span class="chip ${st}">${txt}</span></div>\n    <div class="chc-g">\n      <div><span class="l">Darfst noch verlieren</span><b class="${c.can_lose <= 0 ? "neg" : ""}">${mUsd(c.can_lose)}</b><small>${c.daily_left != null && c.daily_left < c.buffer ? "Tageslimit" : "bis zur Verlustgrenze"}</small></div>\n      <div><span class="l">Noch bis zum Ziel</span><b class="${c.to_target <= 0 ? "pos" : ""}">${c.to_target <= 0 ? "erreicht" : mUsd(c.to_target)}</b><small>${Math.round(prog)} % von ${mUsd(tgt)}</small></div>\n      <div><span class="l">Konto</span><b>${mUsd(c.equity)}</b><small>Grenze ${mUsd(c.threshold)}</small></div>\n    </div>\n    ${chTrack(c, true)}</button>`;\n  $("#chGo").onclick = () => { TAB = "challenge"; setHash(TAB); window.scrollTo(0, 0); render(true); };\n}\nfunction chTrack(c, small) {   // Weg von der Verlustgrenze bis zum Ziel\n  const lo = c.threshold, hi = c.start + c.cfg.profit_target, span = Math.max(1, hi - lo);\n  const at = v => Math.max(0, Math.min(100, (v - lo) / span * 100));\n  return `<div class="trk ${small ? "sm" : ""}">\n    <div class="trk-b"><i class="trk-f" style="width:${at(c.equity)}%"></i><span class="trk-s" style="left:${at(c.start)}%"></span><span class="trk-e" style="left:${at(c.equity)}%"></span></div>\n    ${small ? "" : `<div class="trk-l"><span class="neg">Grenze ${mUsd(lo)}</span>${at(c.start) > 18 && at(c.start) < 82 ? `<span style="left:${at(c.start)}%">Start ${mUsd(c.start)}</span>` : "<span></span>"}<span class="pos">Ziel ${mUsd(hi)}</span></div>`}</div>`;\n}\nfunction chChart(c) {\n  const d = c.days; if (d.length < 1) return \'<p class="hint">Die Kurve erscheint nach dem ersten Handelstag.</p>\';\n  const W = 900, H = 230, L = 64, R = 14, T = 12, B = 24;\n  const pts = [{balance: c.start, threshold: d.length ? (c.cfg.dd_type === "static" ? c.start - c.cfg.max_dd : c.start - c.cfg.max_dd) : c.threshold, day: ""}, ...d];\n  const tgt = c.start + c.cfg.profit_target;\n  const vals = pts.flatMap(p => [p.balance, p.threshold]).concat([tgt, c.equity]);\n  const lo = Math.min(...vals), hi = Math.max(...vals), pad = (hi - lo) * 0.08 || 100;\n  const y0 = lo - pad, y1 = hi + pad;\n  const x = i => L + (W - L - R) * i / Math.max(1, pts.length - 1), y = v => T + (H - T - B) * (1 - (v - y0) / (y1 - y0));\n  const line = k => pts.map((p, i) => `${i ? "L" : "M"}${x(i).toFixed(1)},${y(p[k]).toFixed(1)}`).join("");\n  const step = pts.map((p, i) => i ? `L${x(i).toFixed(1)},${y(pts[i - 1].threshold).toFixed(1)}L${x(i).toFixed(1)},${y(p.threshold).toFixed(1)}` : `M${x(0)},${y(p.threshold)}`).join("");\n  let g = ""; for (let k = 0; k <= 4; k++) { const v = y0 + (y1 - y0) * k / 4; g += `<line class="gl" x1="${L}" x2="${W - R}" y1="${y(v)}" y2="${y(v)}"/><text x="${L - 8}" y="${y(v) + 4}" text-anchor="end">${mUsd(v)}</text>`; }\n  const every = Math.ceil(pts.length / 8);\n  const xl = pts.map((p, i) => i && (i % every === 0 || i === pts.length - 1) ? `<text x="${x(i)}" y="${H - 6}" text-anchor="middle">${p.day.slice(8)}.${p.day.slice(5, 7)}.</text>` : "").join("");\n  return `<svg viewBox="0 0 ${W} ${H}" class="chart" role="img" aria-label="Kontoverlauf mit Verlustgrenze">${g}${xl}\n    <line x1="${L}" x2="${W - R}" y1="${y(tgt)}" y2="${y(tgt)}" stroke="var(--pos)" stroke-dasharray="5 4" stroke-width="1.2"/><text x="${W - R}" y="${y(tgt) - 6}" text-anchor="end" style="fill:var(--pos)">Ziel</text>\n    <path d="${step}" fill="none" stroke="var(--neg)" stroke-width="1.6" stroke-dasharray="1 0" vector-effect="non-scaling-stroke"/><text x="${W - R}" y="${y(pts[pts.length - 1].threshold) + 14}" text-anchor="end" style="fill:var(--neg)">Verlustgrenze</text>\n    <path d="${line("balance")}" fill="none" stroke="var(--accent)" stroke-width="2.2" vector-effect="non-scaling-stroke"/>\n    ${pts.map((p, i) => `<circle cx="${x(i)}" cy="${y(p.balance)}" r="3" fill="var(--accent)"><title>${p.day || "Start"}: ${mUsd(p.balance)} · Grenze ${mUsd(p.threshold)}</title></circle>`).join("")}</svg>`;\n}\nfunction challenge(full) {\n  const c = S.challenge, cfg = (S.config.challenge || {});\n  if (full !== false || !$("#chWrap")) {\n    $("#main").innerHTML = `<div id="chWrap" style="display:contents"><div id="chLive" style="display:contents"></div><section class="panel" id="mcBox" hidden></section>\n      <details class="set-sec ch-form" id="chForm" ${c ? "" : "open"}><summary><span class="s-ic">${icon(\'<path d="M4 7h10M18 7h2M4 17h4M12 17h8"/><circle cx="16" cy="7" r="2"/><circle cx="10" cy="17" r="2"/>\')}</span>\n        <span class="s-t"><b>Regeln deiner Challenge</b><span class="hint">${c ? `${esc(cfg.name || "Konto")} · ${mUsd(cfg.start_balance)} · Ziel ${mUsd(cfg.profit_target)} · Drawdown ${mUsd(cfg.max_dd)} ${DDT[cfg.dd_type].split(" ")[0]}` : "Einmal eintragen, dann rechnet die App live mit"}</span></span><span></span></summary>\n        <div class="set-b" id="chFormB"></div></details></div>`;\n    chForm();\n  }\n  const live = $("#chLive");\n  if (!c) { live.innerHTML = `<section class="panel ch-empty"><h2 style="font-size:18px;text-transform:none;letter-spacing:0;color:var(--fg)">Fremdkapital-Challenge</h2>\n    <p class="hint" style="font-size:13.5px;line-height:1.6">Trag unten die Regeln deiner Prop-Firm ein (Kontogröße, Profitziel, maximaler Drawdown, Tageslimit …). Danach siehst du hier live, <b>wie viel du noch verlieren darfst</b> und <b>wie viel bis zum Ziel fehlt</b>. Im Cockpit erscheint eine kleine Übersicht. Auf Wunsch stoppt die App den Bot, bevor die Grenze erreicht ist.</p></section>`; return; }\n  const [st, txt] = chStatus(c), tgt = c.cfg.profit_target, prog = tgt > 0 ? Math.max(0, Math.min(100, c.profit / tgt * 100)) : 0;\n  const md = c.cfg.min_days || 0, cons = c.consistency;\n  const rule = (ok, title, val, sub) => `<div class="rl ${ok === true ? "ok" : ok === false ? "no" : ""}"><span class="rl-i">${ok === true ? "✓" : ok === false ? "!" : "·"}</span><div><b>${title}</b><small>${sub}</small></div><span class="mono">${val}</span></div>`;\n  live.innerHTML = `\n    <section class="ch-head"><div><span class="l">${esc(c.cfg.phase || "Challenge")}</span><h2>${esc(c.cfg.name || "Fremdkapital-Konto")} <small>${mUsd(c.start)}</small></h2></div>\n      <div class="ch-hr"><span class="chip ${st}" style="font-size:12.5px;padding:4px 10px">${txt}</span><span class="hint">${c.n_trades} Trades · ${c.cfg.source === "alle" ? "Bot + eigene" : c.cfg.source === "bot" ? "nur Bot" : "nur eigene"}${c.cfg.start_day ? " · seit " + c.cfg.start_day.split("-").reverse().join(".") : ""}</span></div></section>\n    <section class="ch-big">\n      <div class="${c.can_lose <= c.cfg.guard_buffer ? "warn" : ""}"><span class="l">Darfst du noch verlieren</span><b class="${c.can_lose <= 0 ? "neg" : ""}">${mUsd(Math.max(0, c.can_lose))}</b>\n        <small>${c.daily_left != null && c.daily_left < c.buffer ? `Heute begrenzt durchs Tageslimit · bis zur Verlustgrenze ${mUsd(c.buffer)}` : `bis zur Verlustgrenze${c.daily_left != null ? ` · Tageslimit noch ${mUsd(c.daily_left)}` : ""}`}</small></div>\n      <div><span class="l">Noch zu gewinnen</span><b class="${c.to_target <= 0 ? "pos" : ""}">${c.to_target <= 0 ? "Ziel erreicht" : mUsd(c.to_target)}</b>\n        <div class="prog"><i style="width:${prog}%"></i></div><small>${mUsd(c.profit)} von ${mUsd(tgt)} · ${Math.round(prog)} %${cons && !cons.ok && cons.extra > 0 ? ` · für Konsistenz mind. ${mUsd(cons.extra)} mehr` : ""}</small></div>\n      <div><span class="l">Kontostand</span><b>${mUsd(c.equity)}</b><small>${c.upnl ? `davon offen ${sUsd(c.upnl)} · ` : ""}heute ${sUsd(c.today_pnl)}</small></div>\n      <div><span class="l">Verlustgrenze</span><b class="neg">${mUsd(c.threshold)}</b><small>${DDT[c.cfg.dd_type]}${c.locked ? " · fest auf Startkapital" : c.cfg.dd_type !== "static" ? ` · Höchststand ${mUsd(c.hwm)}` : ""}</small></div>\n    </section>\n    <section class="panel">${chTrack(c, false)}</section>\n    <div class="grid2">\n      <section class="section"><h2>Kontoverlauf</h2><div class="panel">${chChart(c)}<div class="legend" style="margin-top:6px"><span><i style="background:var(--accent)"></i>Kontostand (Tagesende)</span><span><i style="background:var(--neg)"></i>Verlustgrenze</span><span><i style="background:var(--pos)"></i>Profitziel</span></div></div></section>\n      <section class="section"><h2>Regeln</h2><div class="panel rules">\n        ${rule(c.to_target <= 0, "Profitziel", c.to_target <= 0 ? "✓" : mUsd(c.to_target), `${mUsd(tgt)} Gewinn · fehlt noch`)}\n        ${rule(!c.breached, "Max. Drawdown", mUsd(c.buffer), `${mUsd(c.cfg.max_dd)} ${DDT[c.cfg.dd_type]} · Puffer`)}\n        ${c.daily_left != null ? rule(!c.daily_hit, "Tageslimit heute", mUsd(Math.max(0, c.daily_left)), `${mUsd(c.cfg.daily_loss)} pro Tag · noch übrig`) : rule(null, "Tageslimit", "aus", "keine Tagesgrenze eingetragen")}\n        ${cons ? rule(cons.ok, `Konsistenz ${cons.pct} %`, cons.share != null ? cons.share.toFixed(0) + " %" : "–", `bester Tag ${mUsd(cons.best)} · darf höchstens ${cons.pct} % des Gewinns sein${!cons.ok && cons.need_total ? ` · Gewinn nötig: ${mUsd(cons.need_total)}` : ""}`) : rule(null, "Konsistenz", "aus", "keine Konsistenzregel eingetragen")}\n        ${md ? rule(c.days_traded >= md, "Mindest-Handelstage", `${c.days_traded} / ${md}`, md > c.days_traded ? `noch ${md - c.days_traded} ${md - c.days_traded === 1 ? "Tag" : "Tage"}` : "erfüllt") : rule(null, "Mindest-Handelstage", c.days_traded, "keine Mindestzahl eingetragen")}\n        ${rule(c.cfg.guard ? true : null, "Bot-Schutz", c.cfg.guard ? "an" : "aus", c.cfg.guard ? `Bot stoppt bei weniger als ${mUsd(c.cfg.guard_buffer)} Spielraum und nimmt keine Trades, deren Risiko größer ist` : "Bot handelt ohne Rücksicht auf die Challenge")}\n      </div></section>\n    </div>\n    <section class="section"><h2>Tage</h2><div class="panel scroll">${c.days.length ? `<table><thead><tr><th class="t">Tag</th><th>Trades</th><th>P&L</th><th>Kontostand</th><th>Grenze danach</th><th>Puffer</th></tr></thead><tbody>\n      ${c.days.slice().reverse().map(d => `<tr><td class="t">${new Date(d.day + "T12:00:00").toLocaleDateString("de-DE", {weekday: "short", day: "2-digit", month: "2-digit"})}</td><td>${d.n}</td><td class="${cls(d.pnl)}">${sUsd(d.pnl)}</td><td>${mUsd(d.balance)}</td><td class="neg">${mUsd(d.threshold)}</td><td>${mUsd(d.balance - d.threshold)}</td></tr>`).join("")}\n      </tbody></table>` : \'<p class="hint">Noch keine Trades seit dem Start der Challenge.</p>\'}</div></section>`;\n  $("#mcBox").hidden = false;\n  if (!MC.data || MC.key !== JSON.stringify(c.cfg)) { if (!MC.busy) mcRun(); } else if (full !== false || !$("#mcBox").innerHTML) mcPanel();\n}\nfunction chForm() {\n  const cf = S.config.challenge || {};\n  const f = (id, label, val, help, attrs = "", type = "number") => `<div class="row"><label for="${id}">${label}${help ? `<small>${help}</small>` : ""}</label><input id="${id}" type="${type}" value="${esc(val ?? "")}" ${attrs}></div>`;\n  $("#chFormB").innerHTML = `\n    ${f("cName", "Name", cf.name, "z. B. Topstep 50K oder Apex 100K", \'maxlength="40" placeholder="Meine Challenge"\', "text")}\n    <div class="row"><label for="cPhase">Phase</label><select id="cPhase">${["Challenge", "Phase 2", "Funded", "Live"].map(x => `<option ${cf.phase === x ? "selected" : ""}>${x}</option>`).join("")}</select></div>\n    ${f("cSize", "Kontogröße / Startkapital ($)", cf.start_balance, "", \'min="1000" step="500"\')}\n    ${f("cStart", "Start der Challenge", cf.start_day, "Nur Trades ab diesem Tag zählen. Leer = alle Trades", "", "date")}\n    <span class="lbl">Regeln der Firma</span>\n    ${f("cTarget", "Profitziel ($)", cf.profit_target, "0 = kein Ziel (z. B. Funded-Konto)", \'min="0" step="100"\')}\n    ${f("cDd", "Maximaler Drawdown ($)", cf.max_dd, "Abstand der Verlustgrenze zum Höchststand bzw. Start", \'min="100" step="100"\')}\n    <div class="row"><label for="cType">Art des Drawdowns<small>EOD: zieht nur zum Tagesende nach · Intraday: zieht sofort mit offenen Gewinnen nach · Statisch: feste Grenze</small></label>\n      <select id="cType">${Object.entries(DDT).map(([k, l]) => `<option value="${k}" ${cf.dd_type === k ? "selected" : ""}>${l}</option>`).join("")}</select></div>\n    <div class="row"><label for="cLock">Grenze stoppt beim Startkapital<small>Bei den meisten Firmen wandert die Grenze höchstens bis zum Startkapital</small></label><input id="cLock" type="checkbox" class="chk" ${cf.lock_at_start ? "checked" : ""}></div>\n    ${f("cDaily", "Tagesverlust-Limit ($)", cf.daily_loss, "0 = keins", \'min="0" step="50"\')}\n    ${f("cCons", "Konsistenzregel (%)", cf.consistency_pct, "Bester Tag darf höchstens so viel % des Gesamtgewinns sein. 0 = keine", \'min="0" max="100" step="5"\')}\n    ${f("cDays", "Mindest-Handelstage", cf.min_days, "0 = keine", \'min="0" step="1"\')}\n    <span class="lbl">Was zählt & Schutz</span>\n    <div class="row"><label>Welche Trades zählen</label><div class="seg" role="group">${[["alle", "Bot + eigene"], ["bot", "Nur Bot"], ["eigen", "Nur eigene"]].map(([k, l]) => `<button type="button" data-cs="${k}" aria-pressed="${cf.source === k}">${l}</button>`).join("")}</div></div>\n    <div class="row"><label for="cGuard">Bot-Schutz<small>Der Bot nimmt keine neuen Trades mehr, wenn der Spielraum unter den Puffer fällt oder das Risiko eines Trades größer ist</small></label><input id="cGuard" type="checkbox" class="chk" ${cf.guard ? "checked" : ""}></div>\n    ${f("cBuf", "Sicherheits-Puffer ($)", cf.guard_buffer, "Abstand, den der Bot zur Grenze immer frei lässt", \'min="0" step="50"\')}\n    <p class="hint" style="margin:0">Trag die Werte genau so ein, wie sie in den Regeln deiner Firma stehen. Die App rechnet mit abgeschlossenen Trades (eigene und Bot) und den offenen Bot-Positionen. Kommissionen und die Uhrzeit des Tageswechsels können bei deiner Firma leicht abweichen. Lass deshalb etwas Puffer.</p>\n    <div class="inline wrap-gap"><button class="btn primary" id="cSave">${cf.enabled ? "Speichern" : "Challenge starten"}</button>${cf.enabled ? \'<button class="btn ghost-danger" id="cOff">Challenge beenden</button>\' : ""}</div>`;\n  let src = cf.source || "alle";\n  document.querySelectorAll("[data-cs]").forEach(b => b.onclick = () => { src = b.dataset.cs; document.querySelectorAll("[data-cs]").forEach(x => x.setAttribute("aria-pressed", x === b)); });\n  const save = async enabled => {\n    const n = id => parseFloat($("#" + id).value) || 0;\n    try {\n      await api("/api/config", {challenge: {enabled, name: $("#cName").value.trim(), phase: $("#cPhase").value, start_balance: n("cSize"), start_day: $("#cStart").value,\n        profit_target: n("cTarget"), max_dd: n("cDd"), dd_type: $("#cType").value, lock_at_start: $("#cLock").checked, daily_loss: n("cDaily"),\n        consistency_pct: n("cCons"), min_days: Math.round(n("cDays")), source: src, guard: $("#cGuard").checked, guard_buffer: n("cBuf")}});\n      S = await api("/api/state"); toast(enabled ? "Challenge gespeichert" : "Challenge beendet"); challenge(true);\n    } catch (e) { toast(e.message); }\n  };\n  $("#cSave").onclick = () => save(true);\n  if ($("#cOff")) $("#cOff").onclick = () => confirmBtn($("#cOff"), "Wirklich beenden?", () => save(false));\n}\n\n\n\n/* ───────── Offene Positionen: Details, Abstände in Ticks und Geld, Stop/Ziel verschieben ───────── */\nlet posKey = "";\nfunction posMath(p, price) {\n  const I = (S.instruments || {})[p.root] || {tick: 0.25, pv: 2}, d = p.side === "long" ? 1 : -1;\n  const pts = (a, b) => (b - a) * d;               // Punkte in Gewinnrichtung\n  const usdOf = pt => pt * I.pv * p.qty;\n  return {I, d, pts, usdOf, ticks: pt => Math.round(pt / I.tick)};\n}\nconst fPts = v => (v > 0 ? "+" : v < 0 ? "−" : "") + Math.abs(v).toLocaleString("de-DE", {minimumFractionDigits: 2, maximumFractionDigits: 2});\nconst fTicks = v => (v > 0 ? "+" : v < 0 ? "−" : "") + Math.abs(v).toLocaleString("de-DE") + " Ticks";\nfunction posPanel() {\n  const box = $("#posBox"); if (!box) return;\n  const key = JSON.stringify(S.positions.map(p => [p.id, p.sl, p.tp, p.qty, p.status]));\n  if (key !== posKey || !box.querySelector(".pcs, .empty")) {\n    posKey = key;\n    box.innerHTML = S.positions.length ? `<div class="pcs">${S.positions.map(posCard).join("")}</div>` : `<div class="empty">Keine offene Position.</div>`;\n    posBind();\n  }\n  S.positions.forEach(posLive);\n}\nfunction posCard(p) {\n  const m = posMath(p, p.last), risk = m.pts(p.entry, p.sl), rew = p.tp != null ? m.pts(p.entry, p.tp) : null;\n  const rr = rew != null && risk < 0 ? rew / -risk : null, paper = p.broker === "paper";\n  const step = m.I.tick, pt = 1;\n  return `<article class="pc ${p.side}" id="pc-${p.id}">\n    <div class="pc-h">\n      <span class="side ${p.side}">${p.side === "long" ? "LONG" : "SHORT"}</span><b class="mono">${p.qty}× ${esc(p.contract)}</b>\n      <span class="chip">${esc(p.setup)}</span>${p.is_test ? \'<span class="chip mute">Test</span>\' : ""}${p.mgmt ? `<span class="chip">${esc(p.mgmt)}</span>` : ""}\n      <span class="hint" id="pcAge-${p.id}"></span>\n      <div class="pc-pl"><b id="pcPl-${p.id}">–</b><small id="pcPl2-${p.id}"></small></div>\n    </div>\n    <div class="pc-sm" id="pcSm-${p.id}"></div>\n    <div class="pc-bar"><div class="pc-track"><i class="pc-risk"></i><i class="pc-rew"></i><span class="pc-mk e" id="pcMe-${p.id}"></span><span class="pc-mk n" id="pcMn-${p.id}"></span></div>\n      <div class="pc-bl"><span class="neg">Stop</span><span class="pc-le" id="pcLe-${p.id}">Einstieg</span><span class="pos">${p.tp != null ? "Ziel" : "kein Ziel"}</span></div></div>\n    <div class="pc-g">\n      <div class="pc-c sl"><span class="l">Stop-Loss</span><b class="mono">${px(p.sl)}</b>\n        <small>${fPts(risk)} Pkt · ${fTicks(m.ticks(risk))}</small><small class="${risk >= 0 ? "pos" : "neg"}">${risk >= 0 ? "gesichert" : "Risiko"} ${sUsd(m.usdOf(risk))} ab Einstieg</small>\n        <small id="pcSlNow-${p.id}"></small></div>\n      <div class="pc-c"><span class="l">Einstieg</span><b class="mono">${px(p.entry)}</b>\n        <small>Kurs jetzt <b class="mono" id="pcNow-${p.id}">–</b> <span id="pcLive-${p.id}"></span></small><small id="pcNowD-${p.id}"></small><small>seit ${dtm(p.opened)}</small></div>\n      <div class="pc-c tp"><span class="l">Take-Profit</span><b class="mono">${p.tp != null ? px(p.tp) : "–"}</b>\n        ${rew != null ? `<small>${fPts(rew)} Pkt · ${fTicks(m.ticks(rew))}</small><small class="pos">Chance ${sUsd(m.usdOf(rew))} ab Einstieg</small><small id="pcTpNow-${p.id}"></small>` : "<small>kein festes Ziel</small>"}</div>\n      <div class="pc-c"><span class="l">Chance / Risiko</span><b class="mono">${rr != null ? "1 : " + rr.toFixed(2).replace(".", ",") : risk >= 0 ? "risikofrei" : "–"}</b>\n        <small>1 Tick = ${m.I.tick.toString().replace(".", ",")} Pkt = ${usd2(m.I.tick * m.I.pv)} je Kontrakt</small><small>1 Pkt = ${usd2(m.I.pv * p.qty)} bei ${p.qty} Kontrakt${p.qty === 1 ? "" : "en"}</small></div>\n    </div>\n    <div class="pc-a">\n      <div class="pc-e"><label for="sl-${p.id}">Stop verschieben</label>\n        <div class="pc-in"><button class="btn" data-adj="sl" data-id="${p.id}" data-d="-${pt}" title="1 Punkt runter">−1</button>\n          <input id="sl-${p.id}" type="number" step="${step}" value="${p.sl}" data-orig="${p.sl}">\n          <button class="btn" data-adj="sl" data-id="${p.id}" data-d="${pt}" title="1 Punkt hoch">+1</button>\n          <button class="btn primary" data-set="sl" data-id="${p.id}">Setzen</button></div>\n        <small class="hint" id="slPrev-${p.id}">&nbsp;</small></div>\n      <div class="pc-e"><label for="tp-${p.id}">Ziel verschieben</label>\n        <div class="pc-in"><button class="btn" data-adj="tp" data-id="${p.id}" data-d="-${pt}" title="1 Punkt runter">−1</button>\n          <input id="tp-${p.id}" type="number" step="${step}" value="${p.tp ?? ""}" data-orig="${p.tp ?? ""}" placeholder="kein Ziel">\n          <button class="btn" data-adj="tp" data-id="${p.id}" data-d="${pt}" title="1 Punkt hoch">+1</button>\n          <button class="btn primary" data-set="tp" data-id="${p.id}">Setzen</button>\n          ${paper && p.tp != null ? `<button class="btn" data-cleartp="${p.id}" title="Ziel entfernen, Trade läuft bis Stop oder manuell">Kein Ziel</button>` : ""}</div>\n        <small class="hint" id="tpPrev-${p.id}">&nbsp;</small></div>\n      <div class="pc-q">\n        <button class="btn be" data-id="${p.id}" ${p.sl === p.entry ? "disabled" : ""}>Stop auf Einstieg (BE)</button>\n        <button class="btn ghost-danger cl" data-id="${p.id}" data-key="cl-${p.id}" data-orig="Position schließen">${armed("cl-" + p.id) ? "Sicher?" : "Position schließen"}</button>\n      </div>\n    </div></article>`;\n}\nfunction posLive(p) {\n  const el = $("#pc-" + p.id); if (!el) return;\n  const m = posMath(p), now = p.last ?? p.entry, inPts = m.pts(p.entry, now);\n  const risk = -m.pts(p.entry, p.sl) || 1e-9, r = inPts / risk;\n  const pl = $("#pcPl-" + p.id); pl.textContent = sUsd(p.upnl ?? m.usdOf(inPts)); pl.className = "mono " + cls(p.upnl ?? inPts);\n  $("#pcPl2-" + p.id).textContent = `${fPts(inPts)} Pkt · ${fTicks(m.ticks(inPts))}${m.pts(p.entry, p.sl) < 0 ? ` · ${r >= 0 ? "+" : "−"}${Math.abs(r).toFixed(2).replace(".", ",")} R` : ""}`;\n  $("#pcNow-" + p.id).textContent = px(now);\n  const lv = $("#pcLive-" + p.id), pAge = p.last_ts ? Math.max(0, Math.round(Date.now() / 1000 - p.last_ts)) : null;\n  if (lv) lv.innerHTML = pAge == null ? "" : pAge <= 45 ? `<span class="live-dot"></span>live · vor ${pAge} s` : `<span class="muted">Stand vor ${pAge < 3600 ? Math.round(pAge / 60) + " Min" : "über 1 Std"}</span>`;\n  const nd = $("#pcNowD-" + p.id); nd.textContent = `${fPts(inPts)} Pkt · ${fTicks(m.ticks(inPts))}`; nd.className = cls(inPts);\n  const toSl = m.pts(now, p.sl);\n  $("#pcSlNow-" + p.id).textContent = `ab jetzt bis Stop: ${fTicks(m.ticks(toSl))} · ${sUsd(m.usdOf(toSl))}`;\n  if (p.tp != null) { const toTp = m.pts(now, p.tp); $("#pcTpNow-" + p.id).textContent = `ab jetzt bis Ziel: ${fTicks(m.ticks(toTp))} · ${sUsd(m.usdOf(toTp))}`; }\n  const age = $("#pcAge-" + p.id); const mins = Math.max(0, Math.round((Date.now() / 1000 - p.opened) / 60)); age.textContent = mins < 60 ? `${mins} Min offen` : `${Math.floor(mins / 60)} Std ${mins % 60} Min offen`;\n  // Leiste: links Stop, Mitte Einstieg, rechts Ziel (ohne Ziel: 2R)\n  const lo = p.sl, hi = p.tp ?? (p.entry + (p.entry - p.sl) * 2);\n  const at = v => Math.max(0, Math.min(100, ((v - lo) / (hi - lo || 1)) * 100));\n  const e = at(p.entry), n = at(now);\n  el.querySelector(".pc-risk").style.width = e + "%"; el.querySelector(".pc-rew").style.left = e + "%"; el.querySelector(".pc-rew").style.width = (100 - e) + "%";\n  $("#pcMe-" + p.id).style.left = e + "%"; $("#pcMn-" + p.id).style.left = n + "%";\n  const le = $("#pcLe-" + p.id); if (le) le.style.left = Math.max(12, Math.min(88, e)) + "%";\n  const sm = $("#pcSm-" + p.id), x = p.smart;\n  if (sm) sm.hidden = !x;\n  if (sm && x) sm.innerHTML = !x ? ""\n    : `<span class="dot ${x.exit ? "warn" : "ok"}"></span><span><b>Bot-Einschätzung:</b> ${x.exit ? "lohnt sich eher nicht mehr" : x.be ? "Stop auf Einstieg (Break-even) wäre besser" : x.hold >= x.now ? "Halten lohnt sich" : "kein klarer Unterschied, bleibt drin"} – ähnliche Trades brachten von hier aus im Schnitt <b class="mono ${cls(x.hold)}">${x.hold > 0 ? "+" : ""}${num2(x.hold)} R</b> (jetzt ${x.now > 0 ? "+" : ""}${num2(x.now)} R${x.be_val != null ? ` · mit Stop auf Einstieg ${x.be_val > 0 ? "+" : ""}${num2(x.be_val)} R` : ""} · ${x.n} Vergleiche · ${x.p_win} % liefen weiter ins Plus)${x.exit ? (/Smart-(BE \\+ )?Ausstieg/.test(p.mgmt || "") ? " · <b>steigt zum Kerzenschluss aus</b>" : " · nur Hinweis, Smart-Ausstieg ist für diese Strategie (noch) nicht übernommen")\n      : x.be ? (/Smart-BE/.test(p.mgmt || "") ? " · <b>zieht den Stop zum Kerzenschluss auf Einstieg</b>" : " · nur Hinweis, Smart-BE ist für diese Strategie (noch) nicht übernommen") : ""}</span>`;\n}\nfunction posPreview(p, which) {\n  const inp = $(`#${which}-${p.id}`), out = $(`#${which}Prev-${p.id}`); if (!inp || !out) return;\n  const v = parseFloat(inp.value), m = posMath(p);\n  if (!isFinite(v) || String(v) === String(inp.dataset.orig)) { out.innerHTML = "&nbsp;"; return; }\n  const d = m.pts(p.entry, v);\n  out.innerHTML = `Neu: ${fPts(d)} Pkt · ${fTicks(m.ticks(d))} ab Einstieg = <b class="${cls(d)}">${sUsd(m.usdOf(d))}</b>`;\n}\nfunction posBind() {\n  const byId = id => S.positions.find(x => x.id === id);\n  document.querySelectorAll("#posBox [data-adj]").forEach(b => b.onclick = () => {\n    const p = byId(b.dataset.id), inp = $(`#${b.dataset.adj}-${p.id}`), I = posMath(p).I;\n    const base = parseFloat(inp.value) || (b.dataset.adj === "tp" ? p.last ?? p.entry : p.sl);\n    inp.value = (Math.round((base + parseFloat(b.dataset.d)) / I.tick) * I.tick).toFixed(2); posPreview(p, b.dataset.adj); });\n  document.querySelectorAll("#posBox .pc-in input").forEach(inp => inp.oninput = () => { const [w, id] = inp.id.split(/-(.+)/); posPreview(byId(id), w); });\n  document.querySelectorAll("#posBox [data-set]").forEach(b => b.onclick = () => {\n    const w = b.dataset.set, v = parseFloat($(`#${w}-${b.dataset.id}`).value);\n    if (!isFinite(v)) return toast(w === "sl" ? "Bitte einen Stop-Preis eintragen" : "Bitte einen Ziel-Preis eintragen");\n    act(() => api(`/api/position/${b.dataset.id}/modify`, {[w]: v}), w === "sl" ? "Stop verschoben" : "Ziel verschoben");\n  });\n  document.querySelectorAll("#posBox [data-cleartp]").forEach(b => b.onclick = () => act(() => api(`/api/position/${b.dataset.cleartp}/modify`, {clear_tp: true}), "Ziel entfernt"));\n  document.querySelectorAll("#posBox .be").forEach(b => b.onclick = () => act(() => api(`/api/position/${b.dataset.id}/breakeven`, {}), "Stop auf Break-even gezogen"));\n  document.querySelectorAll("#posBox .cl").forEach(b => b.onclick = () => confirmBtn(b, "Sicher?", () => act(() => api(`/api/position/${b.dataset.id}/close`, {}), "Position geschlossen")));\n}\nfunction cockpit(full) {\n  const m = $("#main"), t = S.today, lossUsed = t.max_loss > 0 ? Math.min(100, Math.max(0, -t.pnl / t.max_loss * 100)) : 0;\n  if (full || !$("#ck")) m.innerHTML = `<div id="ck" style="display:contents">\n    <div id="setup"></div>\n    <section class="hero" id="hero"></section>\n    <section class="panel stc" id="todayK"></section>\n    <section class="section" id="posSec" hidden><div class="section-h"><h2>Offene Positionen</h2><p class="hint">Jede Position hat einen Stop-Loss beim Broker.</p></div><div id="posBox"></div></section>\n    <section class="section" id="sugSec"><div class="section-h"><h2>Vorschläge</h2><p class="hint" id="sugHint"></p></div><div id="sugs"></div></section>\n    <section id="chCard" hidden></section>\n    <div class="grid2">\n      <section class="section"><div class="section-h"><h2>Heute: Entscheidungen des Bots</h2><button class="btn ghost-danger" id="delTests" data-key="deltests" hidden style="padding:4px 10px;font-size:12px">Test-Daten löschen</button></div><div class="panel scroll" id="sigBox"></div></section>\n      <section class="section" id="newsSec"></section>\n    </div>\n    <section class="panel perf" id="perf"></section>\n    <details class="ck-more" id="ckMore"><summary>Mehr anzeigen: Key Levels &amp; Tagesverlauf · Protokoll</summary>\n      <div class="grid2 ck-2"><section class="section" id="lvSec"></section><section class="section"><h2>Protokoll</h2><div class="panel feed" id="feed"></div></section></div>\n    </details></div>`;\n  setupPanel();\n  heroRender(full);\n  newsPanel();\n  levelsPanel();\n  chCard();\n  const perfKey = JSON.stringify([PERF, S.daily]);\n  if (perfKey !== cockpit._perfKey || full) { cockpit._perfKey = perfKey; $("#perf").innerHTML = perfCard(); bindPerf($("#perf"), () => { cockpit._perfKey = ""; cockpit(false); }); }\n  const tdKey = JSON.stringify([S.summary, S.health, S.balance, S.news_next, S.challenge && [S.challenge.can_lose, S.challenge.to_target], S.config.paused, S.config.auto_mode, S.session_open, S.news_pause, HC_OPEN]);\n  if (tdKey !== cockpit._tdKey || full) { cockpit._tdKey = tdKey; $("#todayK").innerHTML = todayCard(); $("#hcT").onclick = () => { HC_OPEN = !HC_OPEN; cockpit._tdKey = ""; cockpit(false); }; }\n  $("#posSec").hidden = !S.positions.length;\n  $("#sugSec").hidden = S.config.auto_mode && !S.pending.length;   // im Auto-Modus gibt es nichts anzunehmen\n  $("#sugHint").textContent = S.config.auto_mode ? "Auto-Modus ist an: Signale werden ohne Rückfrage ausgeführt." : `Verfallen nach ${S.config.suggestion_timeout_sec} s ohne Antwort.`;\n\n  // Vorschläge nur neu aufbauen, wenn sich die Menge ändert (Eingaben bleiben erhalten)\n  const key = S.pending.map(p => p.id).join(",");\n  if (key !== pendingKey) {\n    pendingKey = key;\n    $("#sugs").innerHTML = S.pending.length ? `<div class="cards">${S.pending.map(sugCard).join("")}</div>`\n      : `<div class="empty">Keine offenen Vorschläge. ${S.config.auto_mode ? "Im Auto-Modus gehen Signale direkt in den Markt." : "Neue Signale aus TradingView erscheinen hier zum Annehmen oder Ablehnen."}</div>`;\n    S.pending.forEach(p => {\n      const card = $(`#s-${p.id}`), q = $(".q", card), sl = $(".sl", card), tp = $(".tp", card);\n      const upd = () => {\n        const inst = S.instruments[p.root], slv = parseFloat(sl.value), qv = parseInt(q.value) || 0;\n        const risk = isFinite(slv) ? Math.abs(p.entry - slv) * qv * inst.pv : NaN;\n        $(".risk", card).textContent = usd(risk);\n        const tpv = parseFloat(tp.value); $(".rr", card).textContent = isFinite(tpv) && isFinite(slv) ? num2(Math.abs(tpv - p.entry) / Math.abs(p.entry - slv)) + " R" : "–";\n      };\n      [q, sl, tp].forEach(i => i.oninput = upd); upd();\n      $(".acc", card).onclick = () => act(() => api(`/api/signal/${p.id}/accept`, {qty: q.value, sl: sl.value, tp: tp.value}), "Trade eröffnet");\n      $(".rej", card).onclick = () => act(() => api(`/api/signal/${p.id}/reject`, {}), "Vorschlag abgelehnt");\n    });\n  }\n  timers();\n\n  posPanel();\n\n  const tlKey = JSON.stringify([S.timeline, S.signals.length && S.signals[0].id]);\n  if (tlKey !== cockpit._tlKey || full) { cockpit._tlKey = tlKey; const op = $("#sigBox .tl-old") && $("#sigBox .tl-old").open; $("#sigBox").innerHTML = timelinePanel(); if (op && $("#sigBox .tl-old")) $("#sigBox .tl-old").open = true; }\n  const dt = $("#delTests");\n  if (dt) {\n    dt.hidden = !(S.signals.some(x => x.is_test) || S.positions.some(x => x.is_test) || S.has_tests);\n    if (!armed("deltests")) dt.textContent = "Test-Daten löschen";\n    dt.onclick = () => confirmBtn(dt, "Alle Tests löschen?", async () => {\n      try { const r = await api("/api/tests/delete", {}); toast(`Gelöscht: ${r.trades} Test-Trades, ${r.signals} Test-Signale`); S = await api("/api/state"); render(true); } catch (e) { toast(e.message); }\n    });\n  }\n  $("#feed").innerHTML = S.events.map(e => `<div><time>${tm(e.ts)}</time><span class="${e.level}">${esc(e.text)}</span></div>`).join("") || `<p class="hint">Noch keine Aktivität.</p>`;\n}\nlet setupKey = "";\nfunction setupPanel() {\n  let hidden = false; try { hidden = localStorage.getItem("fvg-setup-hidden") === "1"; } catch (e) {}\n  const hasSignal = S.signals.some(x => !x.is_test) || !!S.tv.last_msg;\n  let pineCopied = false; try { pineCopied = localStorage.getItem("fvg-pine-copied") === "1"; } catch (e) {}\n  const steps = [\n    {done: !!S.hook_url, title: "Internet-Verbindung", body: S.hook_url ? "Aktiv. TradingView kann deine App erreichen." : `Wird automatisch aufgebaut … (${esc(S.tunnel.status)})`},\n    {done: hasSignal || pineCopied, title: "Script in TradingView", body: `Kopiere das Script, öffne in TradingView unten den <b>Pine Editor</b>, lösche den Inhalt, füge es ein und klicke <b>Zum Chart hinzufügen</b>. Chart: <b>NQ1!</b> oder <b>ES1!</b>, 5 Minuten.\n      <div style="margin-top:8px"><button class="btn" id="cpPine">Script kopieren</button></div>`},\n    {done: S.hook_confirmed, title: "Alert anlegen", body: `In TradingView auf den Wecker klicken → Bedingung <b>FVG Bot</b> → <b>Orderausführungen und alert()-Aufrufe</b>. Unter Benachrichtigungen <b>Webhook-URL</b> anhaken und diese Adresse einfügen:\n      <div class="copyrow" style="margin:8px 0"><div class="code">${S.hook_url ? esc(S.hook_url) : "kommt gleich …"}</div><button class="btn" id="cpHook" ${S.hook_url ? "" : "disabled"}>Kopieren</button></div>\n      Bei Nachricht diesen Text einsetzen: <div class="copyrow" style="margin:8px 0"><div class="code">{{strategy.order.alert_message}}</div><button class="btn" id="cpMsg">Kopieren</button></div>\n      <button class="btn primary" id="hookOk" ${S.hook_url ? "" : "disabled"}>Alert ist angelegt</button>`},\n    {done: hasSignal, title: "Erstes Signal", body: hasSignal ? "Signale kommen an. Fertig!" : `Sobald die Strategie handelt, erscheint hier ein Vorschlag. Probier es jetzt aus: <button class="btn" id="tryIt">Test-Signal senden</button>`},\n  ];\n  const allDone = steps.every(x => x.done);\n  const key = JSON.stringify([hidden, steps.map(x => [x.done, x.body])]);\n  if (key === setupKey) return; setupKey = key;\n  const box = $("#setup");\n  if (hidden || allDone) { box.innerHTML = hidden && !allDone ? `<p class="hint">Einrichtung ausgeblendet · <button class="btn" id="showSetup" style="padding:3px 8px;font-size:12px">Anzeigen</button></p>` : ""; \n    const sh = $("#showSetup"); if (sh) sh.onclick = () => { try { localStorage.removeItem("fvg-setup-hidden"); } catch (e) {} setupKey = ""; setupPanel(); }; return; }\n  const next = steps.findIndex(x => !x.done);\n  box.innerHTML = `<section class="panel"><div class="section-h"><h2>Einrichtung · ${steps.filter(x => x.done).length} von ${steps.length}</h2><button class="btn" id="hideSetup" style="padding:4px 10px;font-size:12px">Ausblenden</button></div>\n    <ol class="wizard">${steps.map((x, i) => `<li class="${x.done ? "done" : i === next ? "now" : ""}"><span class="num">${x.done ? "✓" : i + 1}</span><div><b>${x.title}</b><div class="hint" style="font-size:13px;margin-top:2px">${x.body}</div></div></li>`).join("")}</ol></section>`;\n  $("#hideSetup").onclick = () => { try { localStorage.setItem("fvg-setup-hidden", "1"); } catch (e) {} setupKey = ""; setupPanel(); };\n  const b = id => $("#" + id);\n  if (b("cpPine")) b("cpPine").onclick = async () => { try { const r = await api("/api/pine"); copyText(r.source, "Script"); try { localStorage.setItem("fvg-pine-copied", "1"); } catch (e) {} setupKey = ""; setupPanel(); } catch (e) { toast(e.message); } };\n  if (b("cpHook")) b("cpHook").onclick = () => copyText(S.hook_url, "Adresse");\n  if (b("cpMsg")) b("cpMsg").onclick = () => copyText("{{strategy.order.alert_message}}", "Nachricht");\n  if (b("hookOk")) b("hookOk").onclick = () => act(() => api("/api/hook-confirm", {}), "Super, Alert ist verbunden");\n  if (b("tryIt")) b("tryIt").onclick = () => act(() => api("/api/test-signal", {fam: "NQ", side: "long"}), "Test-Signal gesendet");\n}\nfunction timers() {\n  (S.pending || []).forEach(p => { const el = $(`#s-${p.id} .timer`); if (el) { const s = Math.max(0, Math.round(p.expires - Date.now() / 1000)); el.textContent = `noch ${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`; } });\n}\nfunction sugCard(p) {\n  const inst = S.instruments[p.root];\n  return `<article class="sug ${p.side}" id="s-${p.id}">\n    <div class="sug-h"><span class="side ${p.side}">${p.side === "long" ? "LONG" : "SHORT"}</span><span class="mono">${esc(p.contract)}</span><span class="chip">${esc(p.setup)}</span>${p.is_test ? \'<span class="chip mute">Test</span>\' : ""}<span class="timer"></span></div>\n    <div class="lv"><div><span>Einstieg ca.</span><b>${px(p.entry)}</b></div><div><span>Risiko</span><b class="risk neg">–</b></div><div><span>Chance</span><b class="rr">–</b></div></div>\n    <div class="edit">\n      <label>Anzahl ${esc(p.root)}<input class="q" type="number" min="1" max="${S.config.sizing.max_qty}" step="1" value="${p.qty}"></label>\n      <label>Stop-Loss<input class="sl" type="number" step="${inst.tick}" value="${p.sl}"></label>\n      <label>Ziel<input class="tp" type="number" step="${inst.tick}" value="${p.tp}"></label>\n    </div>\n    ${p.flags && p.flags.length ? `<div class="flags">${p.flags.map(f => `<span class="chip warn">${esc(f)}</span>`).join("")}</div>` : ""}\n    <div class="actions"><button class="btn good acc">Annehmen</button><button class="btn rej">Ablehnen</button></div>\n  </article>`;\n}\n\n/* ───────── Statistik ───────── */\n/* ───────── Grafiken ───────── */\nlet PERF = {period: "monat", src: "alle"};\ntry { PERF = Object.assign(PERF, JSON.parse(localStorage.getItem("fvg-perf") || "{}")); } catch (e) {}\nconst savePerf = () => { try { localStorage.setItem("fvg-perf", JSON.stringify(PERF)); } catch (e) {} };\nconst isoDay = d => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;\nfunction perfData(period, src) {\n  const now = new Date(), today = isoDay(now);\n  let from = "0000";\n  if (period === "heute") from = today;\n  else if (period === "woche") { const d = new Date(now); d.setDate(d.getDate() - ((d.getDay() + 6) % 7)); from = isoDay(d); }\n  else if (period === "monat") from = today.slice(0, 8) + "01";\n  const days = Object.keys(S.daily || {}).filter(k => k >= from && k <= today).sort().map(k => {\n    const d = S.daily[k], b = d.bot || {pnl: 0, n: 0, w: 0}, o = d.eigen || {pnl: 0, n: 0, w: 0};\n    const r = src === "bot" ? b : src === "eigen" ? o : {pnl: b.pnl + o.pnl, n: b.n + o.n, w: b.w + o.w};\n    return {day: k, pnl: r.pnl, n: r.n, w: r.w};\n  }).filter(r => r.n);\n  const n = days.reduce((a, r) => a + r.n, 0), w = days.reduce((a, r) => a + r.w, 0), pnl = days.reduce((a, r) => a + r.pnl, 0);\n  let eq = 0; const curve = days.map(r => (eq += r.pnl));\n  return {days, n, w, l: n - w, pnl, curve, winDays: days.filter(r => r.pnl > 0).length,\n          best: days.reduce((a, r) => !a || r.pnl > a.pnl ? r : a, null), worst: days.reduce((a, r) => !a || r.pnl < a.pnl ? r : a, null)};\n}\nfunction donutSvg(w, l, size = 170) {\n  const r = 62, c = 2 * Math.PI * r, tot = w + l, fw = tot ? w / tot : 0;\n  const gap = tot && w && l ? 3 : 0, lw = Math.max(0, c * fw - gap), ll = Math.max(0, c * (1 - fw) - gap);\n  return `<svg viewBox="0 0 170 170" width="${size}" height="${size}" role="img" aria-label="Gewinn- und Verlust-Trades">\n    <circle cx="85" cy="85" r="${r}" fill="none" stroke="var(--sunk)" stroke-width="16"/>\n    ${tot ? `<circle cx="85" cy="85" r="${r}" fill="none" stroke="var(--pos)" stroke-width="16" stroke-linecap="round" stroke-dasharray="${lw} ${c}" transform="rotate(-90 85 85)"/>\n    <circle cx="85" cy="85" r="${r}" fill="none" stroke="var(--neg)" stroke-width="16" stroke-linecap="round" stroke-dasharray="${ll} ${c}" stroke-dashoffset="${-(c * fw)}" transform="rotate(-90 85 85)"/>` : ""}\n  </svg>`;\n}\nfunction sparkSvg(vals, W = 320, H = 70) {\n  if (vals.length < 2) return `<div class="hint" style="height:${H}px;display:grid;place-items:center">Kurve ab 2 Handelstagen</div>`;\n  const all = [0, ...vals], lo = Math.min(...all), hi = Math.max(...all), span = hi - lo || 1;\n  const x = i => 4 + (W - 8) * i / (all.length - 1), y = v => 6 + (H - 12) * (1 - (v - lo) / span);\n  const line = all.map((v, i) => `${i ? "L" : "M"}${x(i).toFixed(1)},${y(v).toFixed(1)}`).join("");\n  const col = vals[vals.length - 1] >= 0 ? "var(--pos)" : "var(--neg)";\n  return `<svg viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" style="height:${H}px" role="img" aria-label="Equity-Verlauf">\n    <line x1="4" x2="${W - 4}" y1="${y(0)}" y2="${y(0)}" class="gl" stroke-dasharray="3 3"/>\n    <path d="${line}L${x(all.length - 1)},${y(lo)}L${x(0)},${y(lo)}Z" fill="${col}" fill-opacity=".10"/>\n    <path d="${line}" fill="none" stroke="${col}" stroke-width="2" vector-effect="non-scaling-stroke"/></svg>`;\n}\nfunction dayBarsSvg(days) {\n  if (!days.length) return \'<p class="hint">Noch keine Handelstage im Zeitraum.</p>\';\n  const W = 900, H = 200, L = 56, R = 8, T = 10, B = 24, n = days.length;\n  const lo0 = Math.min(0, ...days.map(d => d.pnl)), hi0 = Math.max(0, ...days.map(d => d.pnl));\n  const span = hi0 - lo0 || 100, stepRaw = span / 4, mag = 10 ** Math.floor(Math.log10(stepRaw)), step = [1, 2, 2.5, 5, 10].find(m => m * mag >= stepRaw) * mag;\n  const lo = Math.floor(lo0 / step) * step, hi = Math.ceil(hi0 / step) * step || step;\n  const y = v => T + (H - T - B) * (1 - (v - lo) / (hi - lo)), bw = (W - L - R) / n;\n  let g = ""; for (let v = lo; v <= hi + 1e-9; v += step) g += `<line class="gl" x1="${L}" x2="${W - R}" y1="${y(v)}" y2="${y(v)}"/><text x="${L - 8}" y="${y(v) + 4}" text-anchor="end">${kUsd(v)}</text>`;\n  const every = Math.ceil(n / 10);\n  const bars = days.map((d, i) => { const x0 = L + i * bw + bw * .18, w = Math.max(2, bw * .64), y0 = y(Math.max(0, d.pnl)), h = Math.max(1, Math.abs(y(d.pnl) - y(0)));\n    return `<rect x="${x0}" y="${y0}" width="${w}" height="${h}" rx="2" fill="${d.pnl >= 0 ? "var(--pos)" : "var(--neg)"}"><title>${d.day}: ${sUsd(d.pnl)} · ${d.n} Trades</title></rect>` +\n      (i % every === 0 ? `<text x="${x0 + w / 2}" y="${H - 6}" text-anchor="middle">${d.day.slice(8)}.${d.day.slice(5, 7)}.</text>` : ""); }).join("");\n  return `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="P&L je Handelstag">${g}${bars}</svg>`;\n}\nconst PERIODS = [["heute", "Heute"], ["woche", "Woche"], ["monat", "Monat"], ["gesamt", "Gesamt"]];\nconst SOURCES = [["alle", "Alle"], ["bot", "Bot"], ["eigen", "Eigene"]];\nfunction perfCard(compact) {\n  const d = perfData(PERF.period, PERF.src), wr = d.n ? d.w / d.n * 100 : null;\n  const seg = (list, key) => `<div class="seg" role="group">${list.map(([k, l]) => `<button type="button" data-${key}="${k}" aria-pressed="${PERF[key] === k}">${l}</button>`).join("")}</div>`;\n  return `<div class="perf-h"><h2>Performance</h2><div class="perf-ctl">${seg(PERIODS, "period")}${seg(SOURCES, "src")}</div></div>\n    <div class="perf-b">\n      <div class="ring">${donutSvg(d.w, d.l)}<div class="ring-c"><span class="ring-v ${cls(d.pnl)}">${d.n ? sUsd(d.pnl) : "–"}</span><span class="ring-l">${wr == null ? "keine Trades" : `${Math.round(wr)} % Treffer`}</span></div></div>\n      <div class="perf-side">\n        <div class="perf-stats">\n          <div><span>Gewinner</span><b class="pos">${d.w}</b></div><div><span>Verlierer</span><b class="neg">${d.l}</b></div>\n          <div><span>Handelstage</span><b>${d.days.length}${d.days.length ? ` <small class="hint">(${d.winDays} grün)</small>` : ""}</b></div>\n          <div><span>Ø pro Tag</span><b class="${cls(d.days.length ? d.pnl / d.days.length : 0)}">${d.days.length ? sUsd(d.pnl / d.days.length) : "–"}</b></div>\n        </div>\n        ${compact ? "" : ""}<div class="spark">${sparkSvg(d.curve)}</div>\n      </div>\n    </div>`;\n}\nfunction bindPerf(root, rerender) {\n  root.querySelectorAll("[data-period]").forEach(b => b.onclick = () => { PERF.period = b.dataset.period; savePerf(); rerender(); });\n  root.querySelectorAll("[data-src]").forEach(b => b.onclick = () => { PERF.src = b.dataset.src; savePerf(); rerender(); });\n}\n\nlet STAB = "uebersicht";\ntry { STAB = localStorage.getItem("fvg-stab") || "uebersicht"; } catch (e) {}\nfunction stats() {\n  if (!$("#stWrap")) {\n    $("#main").innerHTML = `<div id="stWrap" style="display:contents">\n      <div class="subtabs" role="tablist">${[["uebersicht", "Übersicht"], ["woche", "Wochenbericht"], ["vergleich", "Bot vs. Backtest"], ["edge", "Edge-Check"], ["muster", "Session-Muster"]].map(([k, l]) =>\n        `<button type="button" role="tab" data-st="${k}" aria-selected="${STAB === k}">${l}</button>`).join("")}</div>\n      <div id="stBody" style="display:contents"></div></div>`;\n    document.querySelectorAll("[data-st]").forEach(b => b.onclick = () => { STAB = b.dataset.st; animOpen(); try { localStorage.setItem("fvg-stab", STAB); } catch (e) {}\n      document.querySelectorAll("[data-st]").forEach(x => x.setAttribute("aria-selected", x === b)); $("#stBody").innerHTML = ""; stats(); });\n  }\n  if (STAB === "edge") return edgeView();\n  if (STAB === "muster") return musterView();\n  if (STAB === "woche") return weekView();\n  if (STAB === "vergleich") return compareView();\n  statsOverview();\n}\nfunction statsOverview() {\n  const st = S.stats;\n  const all = perfData("gesamt", "alle"), last30 = all.days.slice(-30);\n  const setups = Object.entries(st.by_setup).sort((a, b) => b[1].net - a[1].net), maxAbs = Math.max(1, ...setups.map(([, v]) => Math.abs(v.net)));\n  $("#stBody").innerHTML = `\n    <section class="panel perf" id="perfS"></section>\n    <section class="panel"><div class="section-h"><h2>P&L je Handelstag</h2><p class="hint">Letzte ${last30.length} Handelstage, Bot und eigene Trades</p></div>${dayBarsSvg(last30)}</section>\n    <section class="kpis">${[\n      ["Netto-Gewinn", usd(st.net), cls(st.net)], ["Trades", st.n, ""], ["Trefferquote", pct(st.winrate), ""],\n      ["Profit-Faktor", num2(st.pf), st.pf >= 1 ? "pos" : st.pf != null ? "neg" : ""], ["Ø R pro Trade", num2(st.avg_r), cls(st.avg_r)],\n      ["Max. Drawdown", usd(st.max_dd), st.max_dd < 0 ? "neg" : ""], ["Ø Gewinn", usd(st.avg_win), "pos"], ["Ø Verlust", usd(st.avg_loss), "neg"],\n    ].map(([l, v, c]) => `<div class="kpi"><span class="l">${l}</span><span class="v ${c}">${v}</span></div>`).join("")}</section>\n    <section class="panel"><div class="section-h"><h2>Equity des Bots</h2><p class="hint">Kumulierter Gewinn je abgeschlossenem Trade (${esc(S.broker.label)}, ohne Test-Trades)</p></div><div id="eq"></div></section>\n    <div class="grid2">\n      <section class="section"><h2>Nach Strategie</h2><div class="panel">${st.n ? `<div class="hbars">\n        ${setups.map(([k, v]) => `<div class="hbar"><div class="hbar-l"><span class="chip">${esc(k)}</span><span class="hint">${v.n} Trades · ${pct(v.w / v.n * 100)}</span></div>\n          <div class="hbar-t"><div class="hbar-mid"></div><i class="${v.net >= 0 ? "p" : "n"}" style="width:${Math.abs(v.net) / maxAbs * 50}%"></i></div><b class="mono ${cls(v.net)}">${usd(v.net)}</b></div>`).join("")}\n        </div>` : \'<p class="hint">Noch keine abgeschlossenen Trades.</p>\'}</div></section>\n      <section class="section"><h2>Letzte Trades</h2><div class="panel scroll">${st.trades.length ? `<table><thead><tr><th class="t">Geschlossen</th><th class="t">Trade</th><th>Ein</th><th>Aus</th><th class="t">Grund</th><th>Netto</th></tr></thead><tbody>\n        ${st.trades.slice(0, 15).map(t => `<tr><td class="t mono">${dtm(t.closed)}</td><td class="t"><b class="side ${t.side}" style="font-size:12px">${t.side === "long" ? "L" : "S"}</b> ${t.qty}× ${esc(t.root)}</td><td>${px(t.entry)}</td><td>${px(t.exit)}</td><td class="t" style="font-family:var(--f-body);color:var(--muted)">${esc(t.close_reason)}</td><td class="${cls(t.pnl)}">${usd(t.pnl)}</td></tr>`).join("")}\n        </tbody></table>` : \'<p class="hint">Noch keine abgeschlossenen Trades.</p>\'}</div></section>\n    </div>`;\n  $("#eq").innerHTML = equitySvg(st.curve);\n  const pr = () => { $("#perfS").innerHTML = perfCard(); bindPerf($("#perfS"), pr); };\n  pr();\n}\nfunction equitySvg(curve) {\n  if (!curve.length) return \'<p class="hint">Die Kurve erscheint nach dem ersten abgeschlossenen Trade.</p>\';\n  const W = 900, H = 240, L = 60, R = 14, T = 14, B = 22, pts = [{e: 0}, ...curve];\n  const vals = pts.map(p => p.e), lo0 = Math.min(0, ...vals), hi0 = Math.max(0, ...vals);\n  const span = hi0 - lo0 || 100, stepRaw = span / 4, mag = 10 ** Math.floor(Math.log10(stepRaw)), step = [1, 2, 2.5, 5, 10].find(m => m * mag >= stepRaw) * mag;\n  const lo = Math.floor(lo0 / step) * step, hi = Math.ceil(hi0 / step) * step || step;\n  const x = i => L + (W - L - R) * i / Math.max(1, pts.length - 1), y = v => T + (H - T - B) * (1 - (v - lo) / (hi - lo));\n  let g = ""; for (let v = lo; v <= hi + 1e-9; v += step) g += `<line class="gl" x1="${L}" x2="${W - R}" y1="${y(v)}" y2="${y(v)}"/><text x="${L - 8}" y="${y(v) + 4}" text-anchor="end">${usd(v)}</text>`;\n  const line = pts.map((p, i) => `${i ? "L" : "M"}${x(i).toFixed(1)},${y(p.e).toFixed(1)}`).join("");\n  const last = pts[pts.length - 1], col = last.e >= 0 ? "var(--pos)" : "var(--neg)";\n  return `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="Equity-Kurve">\n    <defs><linearGradient id="eqg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="var(--accent)" stop-opacity=".28"/><stop offset="1" stop-color="var(--accent)" stop-opacity="0"/></linearGradient></defs>${g}\n    <path d="${line}L${x(pts.length - 1)},${y(Math.max(lo, 0))}L${x(0)},${y(Math.max(lo, 0))}Z" fill="url(#eqg)"/>\n    <path d="${line}" fill="none" stroke="var(--accent)" stroke-width="2"/><circle cx="${x(pts.length - 1)}" cy="${y(last.e)}" r="4" fill="${col}"/>\n    <text x="${L}" y="${H - 4}">Start</text><text x="${W - R}" y="${H - 4}" text-anchor="end">Trade ${pts.length - 1}</text></svg>`;\n}\n\n/* ───────── Kalender ───────── */\nconst CAL = {y: null, m: null, sel: null, detail: null, filter: "alle"};\ntry { CAL.filter = localStorage.getItem("fvg-cal-filter") || "alle"; } catch (e) {}\nconst MONTHS = ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember"];\nconst iso = d => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;\nconst kUsd = v => { const a = Math.abs(v); return (v < 0 ? "−" : v > 0 ? "+" : "") + "$" + (a >= 1000 ? (a / 1000).toFixed(a >= 10000 ? 0 : 1).replace(".", ",") + "k" : Math.round(a)); };\nconst sUsd = v => (v > 0 ? "+" : "") + usd(v);\n// Tageswerte passend zum Filter: {pnl, n, w, bot, own}\nfunction pick(d) {\n  if (!d) return null;\n  const b = d.bot || {pnl: 0, n: 0, w: 0}, o = d.eigen || {pnl: 0, n: 0, w: 0};\n  const r = CAL.filter === "bot" ? {...b} : CAL.filter === "eigen" ? {...o} : {pnl: b.pnl + o.pnl, n: b.n + o.n, w: b.w + o.w};\n  r.bot = CAL.filter === "eigen" ? 0 : b.n; r.own = CAL.filter === "bot" ? 0 : o.n;\n  return r.n ? r : null;\n}\nfunction countText(r, short) {\n  if (CAL.filter !== "alle") return short ? `${r.n}` : `${r.n} ${r.n === 1 ? "Trade" : "Trades"} · ${Math.round(r.w / r.n * 100)} %`;\n  const parts = [];\n  if (r.bot) parts.push(short ? `${r.bot}B` : `${r.bot} Bot`);\n  if (r.own) parts.push(short ? `${r.own}E` : `${r.own} ${r.own === 1 ? "eigener" : "eigene"}`);\n  return parts.join(short ? " " : " · ");\n}\nconst IC_L = \'<path d="M15 6l-6 6 6 6"/>\', IC_R = \'<path d="M9 6l6 6-6 6"/>\', IC_X = \'<path d="M6 6l12 12M18 6 6 18"/>\';\nfunction calendar() {\n  const now = new Date();\n  if (CAL.y === null) { CAL.y = now.getFullYear(); CAL.m = now.getMonth(); }\n  const D = S.daily || {}, first = new Date(CAL.y, CAL.m, 1), last = new Date(CAL.y, CAL.m + 1, 0);\n  const start = new Date(first); start.setDate(1 - ((first.getDay() + 6) % 7));\n  const todayIso = iso(now), prefix = `${CAL.y}-${String(CAL.m + 1).padStart(2, "0")}`;\n  const mKeys = Object.keys(D).filter(k => k.startsWith(prefix));\n  const mDays = mKeys.map(k => [k, pick(D[k])]).filter(([, r]) => r);\n  const mPnl = mDays.reduce((a, [, r]) => a + r.pnl, 0), wins = mDays.filter(([, r]) => r.pnl > 0), losses = mDays.filter(([, r]) => r.pnl < 0);\n  const mBot = mKeys.reduce((a, k) => a + (D[k].bot ? D[k].bot.pnl : 0), 0), mOwn = mKeys.reduce((a, k) => a + (D[k].eigen ? D[k].eigen.pnl : 0), 0);\n  const mTrades = mDays.reduce((a, [, r]) => a + r.n, 0), mW = mDays.reduce((a, [, r]) => a + r.w, 0);\n  const best = mDays.reduce((a, x) => !a || x[1].pnl > a[1].pnl ? x : a, null), worst = mDays.reduce((a, x) => !a || x[1].pnl < a[1].pnl ? x : a, null);\n  const dLabel = k => new Date(k + "T12:00:00").toLocaleDateString("de-DE", {weekday: "short", day: "numeric", month: "short"});\n  let cells = ["Mo", "Di", "Mi", "Do", "Fr", "Woche"].map(d => `<div class="dow">${d}</div>`).join("");\n  let wkNo = 0;\n  for (let w = new Date(start); w <= last; w.setDate(w.getDate() + 7)) {\n    let wk = {pnl: 0, n: 0, bot: 0, own: 0, w: 0}, wkDays = 0;\n    for (let i = 0; i < 7; i++) {\n      const d = new Date(w); d.setDate(w.getDate() + i);\n      const inMonth = d.getMonth() === CAL.m, k = iso(d), r = inMonth ? pick(D[k]) : null;\n      if (r) { wk.pnl += r.pnl; wk.n += r.n; wk.bot += r.bot; wk.own += r.own; wk.w += r.w; wkDays++; }\n      if (i >= 5) continue;\n      if (!inMonth) { cells += `<div class="day out"><span class="dn">${d.getDate()}</span></div>`; continue; }\n      const c = r ? (r.pnl > 0 ? "win" : r.pnl < 0 ? "loss" : "") : "empty";\n      const dots = r ? Array.from({length: Math.min(r.n, 10)}, (_, j) => `<i class="${j < r.w ? "w" : "l"}"></i>`).join("") : "";\n      cells += `<button type="button" data-day="${k}" class="day ${c} ${k === todayIso ? "today" : ""} ${CAL.sel === k ? "sel" : ""}"\n        aria-label="${d.getDate()}. ${MONTHS[CAL.m]}${r ? `: ${sUsd(r.pnl)}, ${countText(r)}` : ", kein Handel"}">\n        <span class="dn"><b>${d.getDate()}</b></span>\n        ${r ? `<span class="pl ${c === "win" ? "pos" : c === "loss" ? "neg" : ""}"><span class="f">${sUsd(r.pnl)}</span><span class="s">${kUsd(r.pnl)}</span></span>\n          <span class="meta"><span class="dots">${dots}</span><span class="f">${countText(r)}</span></span>` : ""}\n      </button>`;\n    }\n    wkNo++;\n    cells += `<div class="wk"><span class="dn"><span class="f">Woche ${wkNo}</span><span class="s">W${wkNo}</span></span>\n      <span class="pl ${wk.pnl > 0 ? "pos" : wk.pnl < 0 ? "neg" : ""}">${wkDays ? `<span class="f">${sUsd(wk.pnl)}</span><span class="s">${kUsd(wk.pnl)}</span>` : \'<span class="muted">–</span>\'}</span>\n      <span class="meta">${wkDays ? `${wkDays} ${wkDays === 1 ? "Tag" : "Tage"} · ${wk.n} Trades` : "kein Handel"}</span></div>`;\n  }\n  const wr = mDays.length ? wins.length / mDays.length : 0;\n  $("#main").innerHTML = `\n    <section class="section">\n      <div class="cal-top">\n        <div class="cal-mon"><h2>${MONTHS[CAL.m]}<small>${CAL.y}</small></h2>\n          <button class="ibtn" id="calPrev" aria-label="Vorheriger Monat">${icon(IC_L)}</button><button class="ibtn" id="calNext" aria-label="Nächster Monat">${icon(IC_R)}</button>\n          <button class="btn" id="calToday" style="padding:6px 12px">Heute</button></div>\n        <div class="cal-act">\n          <div class="seg" role="group" aria-label="Trades filtern">${[["alle", "Alle"], ["bot", "Bot"], ["eigen", "Eigene"]].map(([k, l]) => `<button type="button" data-f="${k}" aria-pressed="${CAL.filter === k}">${l}</button>`).join("")}</div>\n          <label class="btn" style="cursor:pointer">Importieren<input type="file" id="ownCsv" accept=".csv,.txt" hidden></label>\n          <button class="btn primary" id="ownAdd">+ Trade eintragen</button>\n        </div>\n      </div>\n      <div class="strip">\n        <div><span class="l">Monat</span><span class="v big ${cls(mPnl)}">${sUsd(mPnl)}</span>\n          <span class="s">${CAL.filter === "alle" ? `Bot <b class="${cls(mBot)}">${sUsd(mBot)}</b> · Eigene <b class="${cls(mOwn)}">${sUsd(mOwn)}</b>` : CAL.filter === "bot" ? "nur Bot-Trades" : "nur eigene Trades"}</span></div>\n        <div><span class="l">Gewinntage</span><span class="v">${mDays.length ? Math.round(wr * 100) + " %" : "–"}</span>\n          <div class="wl"><i style="width:${wr * 100}%;background:var(--pos)"></i><i style="width:${mDays.length ? losses.length / mDays.length * 100 : 0}%;background:var(--neg)"></i></div>\n          <span class="s">${wins.length} grün · ${losses.length} rot</span></div>\n        <div><span class="l">Trades</span><span class="v">${mTrades}</span><span class="s">${mTrades ? Math.round(mW / mTrades * 100) + " % Trefferquote" : "&nbsp;"}</span></div>\n        <div><span class="l">Bester Tag</span><span class="v pos">${best && best[1].pnl > 0 ? sUsd(best[1].pnl) : "–"}</span><span class="s">${best && best[1].pnl > 0 ? dLabel(best[0]) : "&nbsp;"}</span></div>\n        <div><span class="l">Schlechtester Tag</span><span class="v neg">${worst && worst[1].pnl < 0 ? sUsd(worst[1].pnl) : "–"}</span><span class="s">${worst && worst[1].pnl < 0 ? dLabel(worst[0]) : "&nbsp;"}</span></div>\n      </div>\n      <div class="calbox"><div class="cal" role="grid" aria-label="Handelskalender">${cells}</div></div>\n      <div class="legend"><span><i style="background:var(--pos)"></i>Gewinntag</span><span><i style="background:var(--neg)"></i>Verlusttag</span>\n        <span>Auf einen Tag klicken: Tages-Stats und Trade eintragen</span><span style="margin-left:auto">Tage nach New-Yorker Handelsdatum</span></div>\n    </section>`;\n  const go = dm => { CAL.m += dm; if (CAL.m < 0) { CAL.m = 11; CAL.y--; } if (CAL.m > 11) { CAL.m = 0; CAL.y++; } calendar(); };\n  $("#calPrev").onclick = () => go(-1); $("#calNext").onclick = () => go(1);\n  $("#calToday").onclick = () => { CAL.y = now.getFullYear(); CAL.m = now.getMonth(); calendar(); };\n  document.querySelectorAll(".seg [data-f]").forEach(b => b.onclick = () => { CAL.filter = b.dataset.f; try { localStorage.setItem("fvg-cal-filter", CAL.filter); } catch (e) {}\n    calendar(); if (CAL.sel && $("#dayDrw")) drawDay(); });\n  document.querySelectorAll(".cal button.day").forEach(b => b.onclick = () => openDay(b.dataset.day));\n  $("#ownAdd").onclick = () => ownTradeDialog(CAL.sel || todayIso);\n  $("#ownCsv").onchange = e => { const f = e.target.files[0]; if (f) importDialog(f); e.target.value = ""; };\n}\n// Tagesansicht als Seitenfenster: Stats des Tages, Trades, direkt eintragen\nasync function openDay(k) {\n  CAL.sel = k;\n  const d = new Date(k + "T12:00:00");\n  if (d.getFullYear() !== CAL.y || d.getMonth() !== CAL.m) { CAL.y = d.getFullYear(); CAL.m = d.getMonth(); }\n  try { CAL.dayTrades = (await api("/api/day/" + k)).trades; CAL.dayErr = null; } catch (e) { CAL.dayErr = e.message; CAL.dayTrades = []; }\n  try { CAL.dayTl = await api("/api/timeline/" + k); } catch (e) { CAL.dayTl = null; }\n  if (TAB === "calendar") calendar();\n  drawDay();\n}\nfunction closeDay() {\n  const el = $("#dayDrw"); if (el) el.remove();\n  CAL.sel = null; document.querySelectorAll(".cal .day.sel").forEach(b => b.classList.remove("sel"));\n}\nfunction shiftDay(k, dir) {\n  const d = new Date(k + "T12:00:00");\n  do { d.setDate(d.getDate() + dir); } while (d.getDay() === 0 || d.getDay() === 6);\n  return iso(d);\n}\nfunction drawDay() {\n  const k = CAL.sel; if (!k) return;\n  const list = (CAL.dayTrades || []).filter(t => CAL.filter === "alle" || t.source === CAL.filter)\n    .slice().sort((a, b) => String(a.closed).localeCompare(String(b.closed)));\n  const pnl = list.reduce((a, t) => a + t.pnl, 0), w = list.filter(t => t.pnl > 0), l = list.filter(t => t.pnl < 0);\n  const gw = w.reduce((a, t) => a + t.pnl, 0), gl = -l.reduce((a, t) => a + t.pnl, 0);\n  const bot = list.filter(t => t.source !== "eigen"), own = list.filter(t => t.source === "eigen");\n  const best = list.reduce((a, t) => !a || t.pnl > a.pnl ? t : a, null), worst = list.reduce((a, t) => !a || t.pnl < a.pnl ? t : a, null);\n  let run = 0; const curve = list.map(t => (run += t.pnl));\n  const title = new Date(k + "T12:00:00").toLocaleDateString("de-DE", {weekday: "long", day: "numeric", month: "long", year: "numeric"});\n  const st = (lb, v, c = "") => `<div><span class="l">${lb}</span><b class="${c}">${v}</b></div>`;\n  const html = `\n    <div class="drw-h">\n      <button class="ibtn" id="dPrev" aria-label="Vorheriger Handelstag">${icon(IC_L)}</button>\n      <div class="drw-t"><span class="l">Tagesansicht</span><h2>${title}</h2></div>\n      <button class="ibtn" id="dNext" aria-label="Nächster Handelstag">${icon(IC_R)}</button>\n      <button class="ibtn" id="dClose" aria-label="Schließen">${icon(IC_X)}</button>\n    </div>\n    <div class="drw-b">\n      ${CAL.dayErr ? `<p class="err-msg">${esc(CAL.dayErr)}</p>` : ""}\n      <div class="drw-pl"><span class="l">Netto${CAL.filter !== "alle" ? (CAL.filter === "bot" ? " · Bot" : " · Eigene") : ""}</span>\n        <b class="${cls(pnl)}">${list.length ? sUsd(pnl) : "–"}</b>\n        ${list.length && CAL.filter === "alle" ? `<span class="hint">Bot <b class="${cls(bot.reduce((a, t) => a + t.pnl, 0))}">${sUsd(bot.reduce((a, t) => a + t.pnl, 0))}</b> · Eigene <b class="${cls(own.reduce((a, t) => a + t.pnl, 0))}">${sUsd(own.reduce((a, t) => a + t.pnl, 0))}</b></span>` : ""}</div>\n      ${list.length ? `<div class="drw-st">\n        ${st("Trades", `${list.length}`)}\n        ${st("Trefferquote", Math.round(w.length / list.length * 100) + " %", w.length >= l.length ? "pos" : "neg")}\n        ${st("Profit-Faktor", gl ? (gw / gl).toFixed(2).replace(".", ",") : (gw ? "∞" : "–"))}\n        ${st("Ø Trade", sUsd(pnl / list.length), cls(pnl))}\n        ${st("Bester", best ? sUsd(best.pnl) : "–", best && best.pnl > 0 ? "pos" : "")}\n        ${st("Schlechtester", worst ? sUsd(worst.pnl) : "–", worst && worst.pnl < 0 ? "neg" : "")}\n      </div>\n      ${list.length > 1 ? `<div class="drw-cv"><span class="l">Verlauf über den Tag</span>${sparkSvg(curve, 400, 64)}</div>` : ""}\n      <div class="drw-list"><span class="l">Trades</span>\n        ${list.map(t => `<div class="tr ${t.pnl > 0 ? "w" : t.pnl < 0 ? "lo" : ""}">\n          <div class="tr-a"><span class="chip ${t.side === "long" ? "good" : "bad"}">${t.side === "long" ? "Long" : "Short"}</span>\n            <b>${t.qty}× ${esc(t.root)}</b><span class="chip ${t.source === "eigen" ? "warn" : ""}">${t.source === "eigen" ? "Eigen" : "Bot"}</span>${t.is_test ? \'<span class="chip mute">Test</span>\' : ""}\n            <span class="tr-p mono ${cls(t.pnl)}">${sUsd(t.pnl)}</span></div>\n          ${tradeDetail(t)}\n          ${ghostLine(t)}\n          ${t.is_test ? "" : journalBox(t)}\n          <div class="tr-b"><span class="tr-n">${esc(t.source === "eigen" ? (t.note || "") : `${t.setup} · ${t.close_reason}`)}</span>\n            ${t.source === "eigen" || t.is_test ? `<button class="lnk owndel" data-id="${t.id}" data-key="del-${t.id}" data-orig="Löschen">${armed("del-" + t.id) ? "Sicher?" : "Löschen"}</button>` : ""}</div>\n        </div>`).join("")}\n      </div>` : `<div class="empty">Keine ${CAL.filter === "bot" ? "Bot-" : CAL.filter === "eigen" ? "eigenen " : ""}Trades an diesem Tag.</div>`}\n      ${CAL.dayTl && CAL.dayTl.items.length ? `<details class="tl-old"><summary class="l" style="cursor:pointer">Bot-Entscheidungen an diesem Tag (${CAL.dayTl.items.length} Signale)</summary><div class="tl">${tlItems(CAL.dayTl.items)}</div></details>` : ""}\n    </div>\n    <div class="drw-f"><button class="btn primary" id="dAdd">+ Trade für diesen Tag eintragen</button></div>`;\n  let el = $("#dayDrw");\n  if (!el) {\n    document.body.insertAdjacentHTML("beforeend", `<div id="dayDrw" class="drw-bg"><aside class="drw" role="dialog" aria-modal="true" aria-label="Tagesansicht"></aside></div>`);\n    el = $("#dayDrw");\n    el.addEventListener("click", e => { if (e.target === el) closeDay(); });\n  }\n  el.querySelector(".drw").innerHTML = html;\n  $("#dClose").onclick = closeDay;\n  $("#dPrev").onclick = () => openDay(shiftDay(k, -1));\n  $("#dNext").onclick = () => openDay(shiftDay(k, 1));\n  $("#dAdd").onclick = () => ownTradeDialog(k);\n  jrBind(el);\n  el.querySelectorAll(".owndel").forEach(b => b.onclick = () => confirmBtn(b, "Sicher?", async () => {\n    try { await api(`/api/own/${b.dataset.id}/delete`, {}); toast("Trade gelöscht"); S = await api("/api/state"); openDay(k); } catch (e) { toast(e.message); }\n  }));\n}\ndocument.addEventListener("keydown", e => { if (e.key === "Escape" && $("#dayDrw") && !$("#mdl")) closeDay(); });\n\n/* Details eines abgeschlossenen Trades: Preise, Punkte, Ticks, CRV und erreichtes R */\nfunction tradeDetail(t) {\n  const I = (S.instruments || {})[t.root], hasPx = t.entry && t.exit != null;\n  const times = t.source === "eigen" && t.opened === t.closed ? "" : `${tm(t.opened)} → ${tm(t.closed)}`;\n  if (!I || !hasPx) return `<div class="tr-b"><span class="mono">${times}</span>${t.entry ? `<span class="mono">${px(t.entry)} → ${px(t.exit)}</span>` : ""}</div>`;\n  const d = t.side === "long" ? 1 : -1, tk = v => Math.round(v / I.tick);\n  const move = (t.exit - t.entry) * d, sl0 = t.initial_sl ?? t.sl;\n  const risk = sl0 != null ? (t.entry - sl0) * d : null, rew = t.tp != null ? (t.tp - t.entry) * d : null;\n  const crv = risk > 0 && rew != null ? rew / risk : null, rr = risk > 0 ? move / risk : null;\n  const mins = t.closed && t.opened && t.closed > t.opened ? Math.round((t.closed - t.opened) / 60) : null;\n  const cell = (l, v, sub, c = "") => `<div><span class="l">${l}</span><b class="mono ${c}">${v}</b>${sub ? `<small>${sub}</small>` : ""}</div>`;\n  return `<div class="td-g">\n    ${cell("Einstieg", px(t.entry), times ? tm(t.opened) : "")}\n    ${cell("Ausstieg", px(t.exit), times ? `${tm(t.closed)}${mins != null ? ` · ${mins < 60 ? mins + " Min" : Math.floor(mins / 60) + " Std " + (mins % 60) + " Min"}` : ""}` : "")}\n    ${cell("Bewegung", `${fPts(move)} Pkt`, fTicks(tk(move)), cls(move))}\n    ${cell("Stop", sl0 != null ? px(sl0) : "–", risk != null ? `${fPts(-risk)} Pkt · ${fTicks(-tk(risk))}` : "", "neg")}\n    ${cell("Ziel", t.tp != null ? px(t.tp) : "–", rew != null ? `${fPts(rew)} Pkt · ${fTicks(tk(rew))}` : "kein Ziel", "pos")}\n    ${cell("CRV geplant", crv != null ? "1 : " + crv.toFixed(2).replace(".", ",") : "–", rr != null ? `erreicht ${rr >= 0 ? "+" : "−"}${Math.abs(rr).toFixed(2).replace(".", ",")} R` : "", rr != null ? cls(rr) : "")}\n  </div>`;\n}\nfunction modal(html) {\n  document.body.insertAdjacentHTML("beforeend", `<div class="modal-bg" id="mdl" role="dialog" aria-modal="true"><div class="panel modal">${html}</div></div>`);\n  const close = () => $("#mdl") && $("#mdl").remove();\n  $("#mdl").addEventListener("click", e => { if (e.target.id === "mdl") close(); });\n  document.addEventListener("keydown", function esc(e) { if (e.key === "Escape") { close(); document.removeEventListener("keydown", esc); } });\n  return close;\n}\nfunction ownTradeDialog(day) {\n  const close = modal(`<h2 style="font-size:18px">Eigenen Trade eintragen</h2>\n    <form id="ownF" class="form" style="gap:10px">\n      <div class="edit" style="grid-template-columns:repeat(2,minmax(0,1fr))">\n        <label>Handelstag<input id="oDay" type="date" value="${day}" required></label>\n        <label>Instrument<select id="oRoot">${["NQ", "MNQ", "ES", "MES"].map(r => `<option>${r}</option>`).join("")}</select></label>\n        <label>Richtung<select id="oSide"><option value="long">Long</option><option value="short">Short</option></select></label>\n        <label>Anzahl<input id="oQty" type="number" min="1" step="1" value="1"></label>\n        <label>Einstieg<input id="oIn" type="number" step="0.25" placeholder="z. B. 21010.25"></label>\n        <label>Ausstieg<input id="oOut" type="number" step="0.25" placeholder="z. B. 21030.50"></label>\n        <label>Gebühren ($)<input id="oFee" type="number" step="0.01" min="0" value="0"></label>\n        <label>oder P&L direkt ($)<input id="oPnl" type="number" step="0.01" placeholder="optional"></label>\n      </div>\n      <div class="edit" style="grid-template-columns:1fr"><label>Notiz<input id="oNote" type="text" maxlength="120" placeholder="z. B. Topstep-Konto, NY-Open"></label></div>\n      <p class="hint" style="margin:0">Ergebnis: <b id="oRes">–</b></p>\n      <p class="err-msg" id="oErr" hidden></p>\n      <div class="actions"><button class="btn primary" type="submit">Speichern</button><button class="btn" type="button" id="oCancel">Abbrechen</button></div>\n    </form>`);\n  const pv = {NQ: 20, MNQ: 2, ES: 50, MES: 5};\n  const calc = () => {\n    const direct = parseFloat($("#oPnl").value);\n    let r = NaN;\n    if (isFinite(direct)) r = direct;\n    else { const a = parseFloat($("#oIn").value), b = parseFloat($("#oOut").value), q = parseInt($("#oQty").value) || 0, f = parseFloat($("#oFee").value) || 0;\n      if (isFinite(a) && isFinite(b)) r = (b - a) * ($("#oSide").value === "long" ? 1 : -1) * q * pv[$("#oRoot").value] - f; }\n    $("#oRes").textContent = isFinite(r) ? sUsd(Math.round(r * 100) / 100) : "–"; $("#oRes").className = cls(r);\n  };\n  $("#ownF").addEventListener("input", calc);\n  $("#oCancel").onclick = close;\n  $("#ownF").onsubmit = async e => {\n    e.preventDefault();\n    const dayVal = $("#oDay").value;\n    try {\n      await api("/api/own/add", {day: dayVal, root: $("#oRoot").value, side: $("#oSide").value, qty: $("#oQty").value,\n        entry: $("#oIn").value, exit: $("#oOut").value, fees: $("#oFee").value, pnl: $("#oPnl").value, note: $("#oNote").value});\n      close(); toast("Eigener Trade gespeichert");\n      S = await api("/api/state");\n      CAL.y = +dayVal.slice(0, 4); CAL.m = +dayVal.slice(5, 7) - 1; openDay(dayVal);\n    } catch (err) { $("#oErr").textContent = err.message; $("#oErr").hidden = false; }\n  };\n  $("#oIn").focus();\n}\nasync function importDialog(file) {\n  const text = await file.text();\n  const close = modal(`<h2 style="font-size:18px">Eigene Trades importieren</h2>\n    <p style="margin:0"><b>${esc(file.name)}</b> · ${text.split(/\\r?\\n/).filter(x => x.trim()).length - 1} Zeilen</p>\n    <p class="hint" style="margin:0">Funktioniert mit CSV-Exporten aus Topstep, Tradovate, NinjaTrader und den meisten Plattformen. Spalten wie Datum, Symbol, Richtung und P&L werden automatisch erkannt. Schon importierte Trades werden übersprungen.</p>\n    <label style="display:flex;gap:8px;align-items:center;font-size:13px"><input type="checkbox" id="iFee" checked> Gebühren-Spalte vom P&L abziehen (falls vorhanden)</label>\n    <p class="err-msg" id="iErr" hidden></p>\n    <div class="actions"><button class="btn primary" id="iGo">Importieren</button><button class="btn" id="iCancel">Abbrechen</button></div>`);\n  $("#iCancel").onclick = close;\n  $("#iGo").onclick = async () => {\n    try {\n      const r = await api("/api/own/import", {csv: text, subtract_fees: $("#iFee").checked});\n      close(); toast(`${r.added} Trades importiert${r.skipped ? `, ${r.skipped} schon vorhanden` : ""}${r.bad ? `, ${r.bad} nicht lesbar` : ""}`);\n      CAL.filter = CAL.filter === "bot" ? "alle" : CAL.filter; await refresh(true);\n    } catch (e) { $("#iErr").textContent = e.message; $("#iErr").hidden = false; }\n  };\n}\n\n/* ───────── Lernmodul ───────── */\nlet LTAB = "uebersicht";\ntry { LTAB = localStorage.getItem("fvg-ltab2") || "uebersicht"; } catch (e) {}\nfunction learn() {\n  if (!$("#lnWrap")) {\n    $("#main").innerHTML = `<div id="lnWrap" style="display:contents">\n      <div class="subtabs ln-tabs" role="tablist"><button type="button" role="tab" data-lt="uebersicht" aria-selected="${LTAB === "uebersicht"}">Übersicht</button><span class="ln-det">Details</span>${[["strategien", "Strategien"], ["varianten", "Ausstiege"], ["ausstiege", "Frühe Ausstiege"], ["sessionziele", "Session-Ziele"], ["regeln", "Regeln"], ["finder", "Strategie-Finder"], ["backtest", "Backtest"]].map(([k, l]) =>\n        `<button type="button" role="tab" class="sm" data-lt="${k}" aria-selected="${LTAB === k}">${l}</button>`).join("")}</div>\n      <div id="lnBody" style="display:contents"></div></div>`;\n    document.querySelectorAll("[data-lt]").forEach(b => b.onclick = () => { LTAB = b.dataset.lt; animOpen(); try { localStorage.setItem("fvg-ltab2", LTAB); } catch (e) {}\n      document.querySelectorAll("[data-lt]").forEach(x => x.setAttribute("aria-selected", x === b)); $("#lnBody").innerHTML = ""; learn(); });\n  }\n  if (LTAB === "varianten") return labVariants();\n  if (LTAB === "regeln") return labRules();\n  if (LTAB === "sessionziele") return labSessions();\n  if (LTAB === "finder") return labFinder();\n  if (LTAB === "backtest") return backtestView();\n  if (LTAB === "ausstiege") { if (!$("#exPanel")) $("#lnBody").innerHTML = \'<section class="panel scroll" id="exPanel"></section>\'; return exitPanel(); }\n  if (LTAB === "uebersicht") return learnOverview();\n  learnStrategies();\n}\nfunction learnStrategies() {\n  const L = S.learning, p = L.params;\n  const stChip = s => ({"aktiv": "good", "halbe Größe": "warn", "pausiert": "bad", "aus": "bad", "lernt": "mute"}[s] || "mute");\n  $("#lnBody").innerHTML = `\n    <section class="panel"><div class="section-h"><div><h2>Strategien je Session</h2>\n      <details><summary class="hint" style="cursor:pointer;margin-top:4px">Wie bewertet wird</summary><p class="hint" style="max-width:75ch;margin-top:4px">Jedes Signal wird im Hintergrund als Schatten-Trade simuliert, auch abgelehnte und blockierte. Nach jeder Session wertet der Bot die letzten ${p.window} Schatten-Trades je Strategie aus.\n      Unter ${num2(p.half_below_r)} R im Schnitt gibt es halbe Größe, unter ${num2(p.pause_below_r)} R eine Pause. Erst ab ${p.min_trades} Trades greift die Bewertung.\n      Pausierte Strategien laufen im Schatten weiter und werden automatisch wieder freigegeben, wenn sie sich erholen. Das Risiko wird nie automatisch über deine Einstellung erhöht.\n      <b>Zusätzlich je Session:</b> Läuft eine Strategie z. B. in Asien schlecht, in New York aber gut, wird sie nur in Asien gebremst (Spalte „Je Session“: ✓ aktiv, ½ halbe Größe, ⏸ pausiert, … lernt noch).</p></details></div>\n      <div style="display:flex;gap:10px;align-items:center"><span class="hint">Letzte Auswertung: ${L.last_run ? dtm(L.last_run) : "noch keine"}</span><button class="btn primary" id="runL">Jetzt auswerten</button></div></div></section>\n    <section class="section"><h2>Strategien</h2><div class="panel scroll">${L.setups.length ? `<table><thead><tr><th class="t">Strategie</th><th class="t">Status</th><th>Ausgewertet</th><th>Gesamt</th><th>Treffer</th><th>Ø R</th><th>Σ R</th><th>Laufend</th><th class="t">Je Session</th><th class="t">Steuerung</th></tr></thead><tbody>\n      ${L.setups.map(s => `<tr><td class="t"><span class="chip">${esc(s.setup)}</span></td>\n        <td class="t"><span class="chip ${stChip(s.effective)}">${esc(s.effective)}</span>${s.manual !== "auto" ? \' <span class="hint">(manuell)</span>\' : ""}</td>\n        <td>${s.n}</td><td>${s.total}</td><td>${pct(s.winrate)}</td><td class="${cls(s.avg_r)}">${num2(s.avg_r)}</td><td class="${cls(s.sum_r)}">${num2(s.sum_r)}</td><td>${s.open}</td>\n        <td class="t wrap" style="min-width:220px">${Object.keys(s.sessions || {}).length ? `<div class="ssn">${["asia", "london", "ny_am", "ny_lunch", "ny_pm", "aus"].filter(k => (s.sessions || {})[k]).map(k => { const x = s.sessions[k];\n          return `<span class="chip ${stChip(x.status)}" title="${esc((S.session_names || {})[k] || k)}: ${x.n} Trades · ${pct(x.winrate)} · Ø ${num2(x.avg_r)} R · ${esc(x.status)}">${{asia: "Asien", london: "London", ny_am: "NY Vorm.", ny_lunch: "NY Mittag", ny_pm: "NY Nachm.", aus: "Sonst"}[k]} ${x.status === "pausiert" ? "⏸" : x.status === "halbe Größe" ? "½" : x.status === "aktiv" ? "✓" : "…"} <b class="mono">${x.avg_r > 0 ? "+" : ""}${num2(x.avg_r)}</b></span>`; }).join("")}</div>` : \'<span class="hint">noch keine Daten</span>\'}</td>\n        <td class="t"><select data-setup="${esc(s.setup)}" class="rule" aria-label="Steuerung ${esc(s.setup)}">${[["auto", "Lernmodul entscheidet"], ["an", "Immer an"], ["aus", "Aus"]].map(([v, l]) => `<option value="${v}" ${s.manual === v ? "selected" : ""}>${l}</option>`).join("")}</select></td></tr>`).join("")}\n      </tbody></table>` : \'<p class="hint">Noch keine Daten. Sobald Signale aus TradingView eintreffen, erscheinen hier alle Strategien.</p>\'}</div></section>\n    <section class="section"><h2>Selbst umgesetzt</h2><div class="panel">${(L.auto_log || []).length ? `<div class="flags" style="flex-direction:column;align-items:flex-start;gap:8px">${L.auto_log.map(i => `<span class="chip wrapc ${/verworfen/.test(i.text) ? "warn" : "good"}">${esc(new Date(i.t * 1000).toLocaleDateString("de-DE"))} · ${esc(i.text)}</span>`).join("")}</div>` : `<p class="hint">${L.params.auto_adopt === false ? "Ausgeschaltet – Übernahmen machst du selbst im Varianten-Labor und Regel-Finder." : "Noch nichts. Jeden Abend nach 16 Uhr NY prüft der Bot Varianten-Labor und Regel-Finder und übernimmt, was sich auf mindestens 20 Signalen klar bewährt hat."}</p>`}</div></section>\n    <section class="section"><h2>Erkenntnisse</h2><div class="panel">${L.insights.length ? `<div class="flags" style="flex-direction:column;align-items:flex-start;gap:8px">${L.insights.map(i => `<span class="chip ${i.kind === "bad" ? "bad" : i.kind === "good" ? "good" : "warn"}">${esc(i.text)}</span>`).join("")}</div>` : \'<p class="hint">Noch keine Auffälligkeiten. Erkenntnisse zu Uhrzeiten erscheinen ab 6 Trades pro Stunde.</p>\'}</div></section>`;\n  $("#runL").onclick = () => act(() => api("/api/learn", {}), "Auswertung fertig");\n  document.querySelectorAll(".rule").forEach(sel => sel.onchange = () =>\n    act(() => api("/api/config", {setup_rules: {[sel.dataset.setup]: sel.value}}), "Gespeichert"));\n}\n\n\n/* ───────── Lernlabor Stufe 1: Varianten-Labor ───────── */\nconst LAB = {v: null, vat: 0, r: null, rat: 0};\nasync function labVariants(force) {\n  const body = $("#lnBody");\n  if (!force && LAB.v && Date.now() - LAB.vat < 60000 && body.querySelector(".lab-v")) return;\n  if (!LAB.v) body.innerHTML = \'<div class="empty">Varianten werden ausgewertet …</div>\';\n  try { LAB.v = await api("/api/lab/variants"); LAB.vat = Date.now(); } catch (e) { body.innerHTML = `<div class="empty">${esc(e.message)}</div>`; return; }\n  if (TAB !== "learn" || LTAB !== "varianten") return;\n  const V = LAB.v, cols = V.variants;\n  const cell = (c, best, isCur, isRec) => !c.n ? \'<td class="muted">–</td>\'\n    : `<td class="vc ${best ? "best" : ""} ${isCur ? "cur" : ""} ${isRec ? "rec" : ""}" title="${c.n} Signale · Trefferquote ${pct(c.wr)} · Σ ${num2(c.sum)} R · 1. Teil ${num2(c.a1)} / 2. Teil ${num2(c.a2)}">\n        <b class="${cls(c.avg)}">${c.avg > 0 ? "+" : ""}${num2(c.avg)}</b><small>${Math.round(c.wr)} % · ${c.n}</small></td>`;\n  body.innerHTML = `<section class="panel lab-v">\n    <div class="section-h"><div><h2 style="font-size:16px;text-transform:none;letter-spacing:0;color:var(--fg)">Varianten-Labor</h2>\n      <p class="hint" style="max-width:85ch;margin-top:4px;line-height:1.6">Für jedes Signal rechnet die App im Hintergrund ${cols.length - 1} Ausstiegs-Varianten mit: feste Ziele von 1R bis 3R, Stop auf Break-even ab +1R, Trailing-Stop, Halten bis Session-Ende und die <b>Smart-Varianten</b> (Smart-Ausstieg, Smart-BE = Stop auf Einstieg, wenn der Trade z. B. zäh wird, oder beides): Sie haben keine feste Regel, sondern wägt nach jeder Kerze ab, was ähnliche frühere Trades von genau diesem Punkt aus noch gebracht haben (gleiche Strategie, gleiche Zeit im Trade, gleicher Stand in R, gleicher Höchststand, ähnliche Volatilität). Bringt Halten im Schnitt deutlich weniger als jetzt auszusteigen, geht er raus; bringt der Stop auf Einstieg auf denselben Verläufen deutlich mehr als der alte Stop, zieht er ihn nach. Für vergangene Signale wurde das rückwirkend gerechnet – jeweils nur mit dem Wissen von damals. Die Zahl ist das <b>Ø R pro Signal</b> (darunter Trefferquote und Anzahl). <b>Grün umrandet</b> = beste Variante, <b>blau</b> = aktuell genutzt.\n      Eine Empfehlung gibt es erst ab ${V.min_n} Signalen, wenn die Variante im Schnitt mindestens 0,15 R besser ist <b>und</b> in beiden Zeit-Hälften vorne liegt, damit es kein Zufall ist.</p></div>\n      <button class="btn" id="labVRef">Neu berechnen</button></div>\n    ${V.setups.length ? `<div class="scroll"><table class="vt"><thead><tr><th class="t">Strategie</th>${cols.map(k => `<th>${k === "Signal-Ziel" ? "Signal-Ziel<br><small>aus TradingView</small>" : esc(k)}</th>`).join("")}<th class="t">Empfehlung</th></tr></thead><tbody>\n      ${V.setups.map(r => { const bestK = cols.filter(k => r.cols[k].n >= 5).sort((a, b) => r.cols[b].avg - r.cols[a].avg)[0];\n        return `<tr><td class="t"><b>${esc(r.setup)}</b><small class="hint">${r.cols["Signal-Ziel"].n} Signale</small></td>\n          ${cols.map(k => cell(r.cols[k], k === bestK, k === r.applied, k === r.rec)).join("")}\n          <td class="t">${r.rec ? `<div class="vrec"><span>Wechsel auf <b>${esc(r.rec)}</b>: ${r.cols[r.rec].avg > 0 ? "+" : ""}${num2(r.cols[r.rec].avg)} R statt ${num2(r.cols[r.applied].avg)} R</span>\n              ${V.broker !== "paper" && r.paper_only.includes(r.rec) ? \'<small class="hint">nur mit Paper-Trading möglich</small>\' : `<button class="btn primary vapply" data-s="${esc(r.setup)}" data-v="${esc(r.rec)}">Übernehmen</button>`}</div>`\n            : r.applied !== "Signal-Ziel" ? `<div class="vrec"><span>Nutzt <b>${esc(r.applied)}</b></span><button class="btn vapply" data-s="${esc(r.setup)}" data-v="Signal-Ziel">Zurück auf Signal-Ziel</button></div>`\n            : `<span class="hint">${r.cols["Signal-Ziel"].n < V.min_n ? `sammelt noch (${r.cols["Signal-Ziel"].n}/${V.min_n})` : "Signal-Ziel ist gut so"}</span>`}</td></tr>`; }).join("")}\n    </tbody></table></div>` : \'<div class="empty">Noch keine Signale. Sobald TradingView Signale und Kerzen schickt, laufen die Varianten automatisch mit.</div>\'}\n    <p class="hint">Ist „Gelerntes selbst umsetzen“ an (Standard), übernimmt der Bot die Empfehlung jeden Abend selbst. „Übernehmen“ ändert, wie der Bot bei dieser Strategie aussteigt: Ziel, Break-even oder Trailing. Der Einstieg bleibt gleich. Trailing und „Bis Session-Ende“ gehen nur mit Paper-Trading, weil Tradovate dafür eine Order ohne festes Ziel bräuchte.</p>\n  </section>`;\n  $("#labVRef").onclick = () => labVariants(true);\n  body.querySelectorAll(".vapply").forEach(b => b.onclick = async () => {\n    try { await api("/api/config", {exit_rules: {[b.dataset.s]: b.dataset.v}}); toast(b.dataset.v === "Signal-Ziel" ? "Zurück auf das Signal-Ziel" : `${b.dataset.s}: Ausstieg ${b.dataset.v} übernommen`); S = await api("/api/state"); labVariants(true); }\n    catch (e) { toast(e.message); }\n  });\n}\n\n/* ───────── Lernlabor Stufe 2: Regel-Finder ───────── */\nasync function labRules(force) {\n  const body = $("#lnBody");\n  if (!force && LAB.r && Date.now() - LAB.rat < 60000 && body.querySelector(".lab-r")) return;\n  if (!LAB.r) body.innerHTML = \'<div class="empty">Regel-Finder sucht …</div>\';\n  try { LAB.r = await api("/api/lab/rules"); LAB.rat = Date.now(); } catch (e) { body.innerHTML = `<div class="empty">${esc(e.message)}</div>`; return; }\n  if (TAB !== "learn" || LTAB !== "regeln") return;\n  const R = LAB.r;\n  const card = (x, strong) => `<div class="rf ${x.action} ${strong ? "" : "weak"}">\n    <div class="rf-h"><span class="chip ${x.action === "avoid" ? "bad" : "good"}">${x.action === "avoid" ? "Meiden" : "Nur dann handeln"}</span><b>${esc(x.setup)}</b><span class="hint">${x.action === "avoid" ? "meiden, wenn" : "nur, wenn"}</span></div>\n    <div class="rf-l">${esc(x.label)}</div>\n    <div class="rf-g">\n      <div><span class="l">Wenn zutrifft</span><b class="${cls(x.avg_match)}">${x.avg_match > 0 ? "+" : ""}${num2(x.avg_match)} R</b><small>${x.n} Signale · ${Math.round(x.wr_match)} %</small></div>\n      <div><span class="l">Sonst</span><b class="${cls(x.avg_rest)}">${x.avg_rest > 0 ? "+" : ""}${num2(x.avg_rest)} R</b><small>${x.n_all - x.n} Signale</small></div>\n      <div><span class="l">Gegenprobe</span><b class="${x.d2 != null && Math.sign(x.d2) === Math.sign(x.avg_match - x.avg_rest) ? "pos" : "neg"}">${x.d2 == null ? "–" : (x.d2 > 0 ? "+" : "") + num2(x.d2) + " R"}</b><small>neueste ${x.n_oos} Signale</small></div>\n      <div><span class="l">Hätte gebracht</span><b class="pos">+${num2(x.effect)} R</b><small>Sicherheit t = ${num2(Math.abs(x.t))}</small></div>\n    </div>\n    ${strong ? (x.applied ? \'<span class="chip good" style="align-self:flex-start">übernommen ✓</span>\' : `<button class="btn primary rfapply" data-i="${R.found.indexOf(x)}" style="align-self:flex-start">Regel übernehmen</button>`) : \'<span class="hint">Beobachten: noch nicht genug Belege, um sie zu übernehmen.</span>\'}\n  </div>`;\n  const cnt = Object.entries(R.setups);\n  body.innerHTML = `<section class="panel lab-r">\n    <div class="section-h"><div><h2 style="font-size:16px;text-transform:none;letter-spacing:0;color:var(--fg)">Regel-Finder</h2>\n      <p class="hint" style="max-width:85ch;margin-top:4px;line-height:1.6">Bei jedem Signal merkt sich die App die Marktlage: Richtung, Uhrzeit, Wochentag, Session, Gap, ob Asien/London/IB schon gebrochen sind, Lage zu Vortageshoch/-tief, Overnight-Range, Midnight Open und RTH-Open.\n      Der Regel-Finder sucht Bedingungen (einzeln und als Paar), unter denen eine Strategie klar besser oder schlechter läuft. <b>Vorgeschlagen</b> wird eine Regel nur, wenn sie in den älteren 60 % der Signale gefunden wurde <b>und</b> in den neuesten 40 % (Gegenprobe) genauso hält, mit hoher Sicherheit (t ≥ 2,5). Getestet wurden ${R.tests} Bedingungen aus ${R.signals} Signalen.</p></div>\n      <button class="btn" id="labRRef">Neu suchen</button></div>\n    ${cnt.length ? `<div class="flags">${cnt.map(([k, n]) => `<span class="chip ${n >= R.min_scope ? "" : "mute"}">${esc(k)}: ${n}${n < R.min_scope ? ` / ${R.min_scope}` : ""}</span>`).join("")}</div>` : ""}\n    ${R.active.length ? `<h3 class="lab-h">Übernommene Regeln</h3><div class="rf-act">${R.active.map((r, i) => `<div class="rfa ${r.active ? "" : "off"}">\n        <span class="chip ${r.action === "avoid" ? "bad" : "good"}">${r.action === "avoid" ? "Meiden" : "Nur dann"}</span>\n        <div><b>${esc(r.setup)}</b> ${r.action === "avoid" ? "meiden, wenn" : "nur, wenn"} ${esc(r.label)}<small class="hint">seit ${new Date(r.added * 1000).toLocaleDateString("de-DE")} · ${r.blocked_n} von ${r.since_n} Signalen geblockt${r.blocked_n ? ` · die hätten ${r.blocked_r > 0 ? "+" : ""}${num2(r.blocked_r)} R gebracht` : ""}</small></div>\n        <button class="btn" data-ra="${i}">${r.active ? "Pausieren" : "Aktivieren"}</button><button class="btn ghost-danger" data-rd="${i}" data-key="rd-${i}">Entfernen</button></div>`).join("")}</div>\n      <p class="hint">Gute Regel: Die geblockten Signale hätten zusammen <b>negativ</b> abgeschnitten. Hätten sie viel Plus gebracht, die Regel lieber pausieren.</p>` : ""}\n    <h3 class="lab-h">Gefundene Regeln</h3>\n    ${R.found.length ? `<div class="rf-grid">${R.found.map(x => card(x, true)).join("")}</div>` : `<div class="empty">${R.signals < 40 ? `Noch zu wenig Signale. Der Regel-Finder braucht mindestens ${R.min_scope} abgeschlossene Signale je Strategie, richtig aussagekräftig wird es ab etwa 60–100.` : "Aktuell keine Regel, die die Gegenprobe sicher besteht. Das ist gut: lieber keine Regel als eine zufällige."}</div>`}\n    ${R.watch.length ? `<h3 class="lab-h">Zum Beobachten</h3><div class="rf-grid">${R.watch.map(x => card(x, false)).join("")}</div>` : ""}\n  </section>`;\n  $("#labRRef").onclick = () => labRules(true);\n  const saveRules = async (list, msg) => { try { await api("/api/config", {rule_filters: list}); toast(msg); S = await api("/api/state"); labRules(true); } catch (e) { toast(e.message); } };\n  const cur = () => (S.config.rule_filters || []).map(r => ({...r}));\n  body.querySelectorAll(".rfapply").forEach(b => b.onclick = () => { const x = R.found[+b.dataset.i];\n    saveRules([...cur(), {setup: x.setup, conds: x.conds, action: x.action, label: x.label, added: Date.now() / 1000, active: true}], "Regel übernommen: der Bot filtert ab jetzt"); });\n  body.querySelectorAll("[data-ra]").forEach(b => b.onclick = () => { const l = cur(); l[+b.dataset.ra].active = !l[+b.dataset.ra].active; saveRules(l, l[+b.dataset.ra].active ? "Regel aktiv" : "Regel pausiert"); });\n  body.querySelectorAll("[data-rd]").forEach(b => b.onclick = () => confirmBtn(b, "Sicher?", () => { const l = cur(); l.splice(+b.dataset.rd, 1); saveRules(l, "Regel entfernt"); }));\n}\n\n\n/* ───────── Backtest: Trade-Liste aus dem TradingView-Strategietester auswerten ───────── */\n/* ───────── Session-Ziele ───────── */\nconst SZ = {data: null, at: 0, err: null};\nasync function labSessions(force) {\n  const body = $("#lnBody");\n  if (force || !SZ.data || Date.now() - SZ.at > 60000) {\n    if (!SZ.data) body.innerHTML = \'<p class="hint">Rechne Kursverläufe durch …</p>\';\n    try { SZ.data = await api("/api/lab/sessions"); SZ.at = Date.now(); SZ.err = null; } catch (e) { SZ.err = e.message; }\n  }\n  if (TAB !== "learn" || LTAB !== "sessionziele") return;\n  const d = SZ.data; if (!d) { body.innerHTML = `<p class="err-msg">${esc(SZ.err || "")}</p>`; return; }\n  const G = d.fit.groups || {}, N = d.names || {}, fam = Object.keys(d.vol || {})[0], vol = fam ? d.vol[fam] : {};\n  const order = ["asia", "london", "ny_am", "ny_lunch", "ny_pm", "aus"];\n  const sess = order.filter(k => G[k]), subs = Object.keys(G).filter(k => k.includes("|")).sort();\n  const pctF = v => Math.round(v * 100) + " %";\n  const row = (k, label) => { const g = G[k], ap = d.applied[k];\n    const st = ap ? `<span class="chip good">übernommen: Ziel ${pctF(ap.f)} · Stop ${pctF(ap.g)}</span>` : g.rec ? `<span class="chip warn">Empfehlung</span>` : g.n < 30 ? `<span class="chip mute">sammelt (${g.n}/30)</span>` : `<span class="chip mute">Signal-Abstände passen</span>`;\n    const better = g.best.f < 1 || g.best.g < 1;\n    return `<tr><td class="t">${label}<small class="hint" style="display:block">${g.n} Signale</small></td>\n      <td>${g.sl_ticks}</td><td>${g.tp_ticks}</td><td>${g.mfe_ticks ?? "–"}</td><td>${pct(g.tp_hit)}</td>\n      <td class="t">${better ? `Ziel ${pctF(g.best.f)} · Stop ${pctF(g.best.g)}` : "wie Signal"}<small class="hint" style="display:block">${num2(g.cur.avg)} → <b class="${cls(g.best.avg)}">${num2(g.best.avg)} R</b> · Hälften ${num2(g.best.a1)} / ${num2(g.best.a2)}</small></td>\n      <td class="t">${st}</td>\n      <td class="t">${g.rec ? `<button class="btn primary" data-szk="${esc(k)}" data-f="${g.rec.f}" data-g="${g.rec.g}" style="padding:4px 10px;font-size:12px">Übernehmen</button>` : ap ? `<button class="btn" data-szk="${esc(k)}" data-rm="1" style="padding:4px 10px;font-size:12px">Zurück</button>` : ""}</td></tr>`; };\n  const head = `<thead><tr><th class="t">Session</th><th>Ø Stop<small class="hint" style="display:block;font-weight:400">Ticks</small></th><th>Ø Ziel<small class="hint" style="display:block;font-weight:400">Ticks</small></th><th>Typische Bewegung<small class="hint" style="display:block;font-weight:400">Ticks in 2 Std</small></th><th>Ziel erreicht</th><th class="t">Bestes Verhältnis</th><th class="t">Status</th><th></th></tr></thead>`;\n  const sm = d.smart || {};\n  body.innerHTML = `\n    <section class="panel"><div class="section-h"><div><h2>Session-Ziele</h2><p class="hint" style="max-width:90ch;margin:4px 0 0;line-height:1.6">Nicht jede Session bewegt sich gleich viel. Für jedes vergangene Signal hat die App den echten Kursverlauf gespeichert und rechnet durch, welche Stop- und Ziel-Abstände in welcher Session wirklich erreicht werden – inklusive Gebühren (engerer Stop = mehr Kontrakte = mehr Gebühren). <b>Typische Bewegung</b> ist, wie weit der Kurs nach dem Einstieg in 2 Stunden meist in Trade-Richtung läuft. Liegt das Ziel weit darüber, ist es in dieser Session unrealistisch. Übernommen wird nur, was in beiden Zeit-Hälften besser war; mit „Gelerntes selbst umsetzen“ macht der Bot das jeden Abend selbst.</p></div>\n      <button class="btn" id="szRe">${sm.busy ? "Rechnet …" : "Neu berechnen"}</button></div></section>\n    ${sess.length ? `<section class="panel scroll"><table>${head}<tbody>${sess.map(k => row(k, esc(N[k] || k))).join("")}</tbody></table></section>`\n      : `<div class="empty">Noch keine fertigen Kursverläufe. Ein Signal zählt, sobald seine Session vorbei ist (16:00 New York) und die Kerzen dafür gespeichert sind.</div>`}\n    ${subs.length ? `<details class="set-sec"><summary><span class="s-ic">${icon(\'<path d="M4 6h16M4 12h16M4 18h10"/>\')}</span><span class="s-t"><b>Je Strategie und Session</b><span class="hint">wird ab 60 Signalen einzeln angepasst, vorher gilt die Session</span></span><span></span></summary><div class="set-b scroll"><table>${head}<tbody>${subs.map(k => { const [a, b] = k.split("|"); return row(k, `${esc(a)}<br><span class="hint">${esc(N[b] || b)}</span>`); }).join("")}</tbody></table></div></details>` : ""}\n    <div class="grid2">\n      <section class="section"><h2>Kerzen-Spanne je Session</h2><div class="panel">${fam ? `<div class="hbars">${order.filter(k => vol[k] != null).map(k => { const mx = Math.max(...order.map(x => vol[x] || 0)); return `<div class="hbar"><div class="hbar-l"><span class="chip">${esc(N[k] || k)}</span></div><div class="hbar-t"><i style="left:0;width:${vol[k] / mx * 100}%;background:var(--accent)"></i></div><b class="mono">${num2(vol[k]).replace(",00", "")} Ticks</b></div>`; }).join("")}</div><p class="hint" style="margin:8px 0 0">Ø Hoch-Tief-Spanne einer ${vol._tf_min}-Minuten-Kerze (${esc(fam)}), letzte 20 Tage.</p>` : \'<p class="hint">Noch keine Kerzen gespeichert.</p>\'}</div></section>\n      <section class="section"><h2>Smart-Ausstieg</h2><div class="panel"><p class="hint" style="margin:0;line-height:1.6">Lernt aus <b>${sm.trades || 0}</b> fertigen Kursverläufen. Nach jeder Kerze vergleicht er einen laufenden Trade mit ähnlichen früheren Situationen und steigt aus, wenn Halten im Schnitt deutlich schlechter war als jetzt rauszugehen. Ob er sich lohnt, steht im <b>Varianten-Labor</b> in der Spalte „Signal-Ziel + Smart-Ausstieg“ – bewährt er sich, übernimmt der Bot ihn selbst. Im Cockpit zeigt jede offene Position die aktuelle Einschätzung.</p></div></section>\n    </div>`;\n  body.querySelectorAll("[data-szk]").forEach(b => b.onclick = async () => {\n    try { await api("/api/lab/sessions/apply", b.dataset.rm ? {key: b.dataset.szk, remove: true} : {key: b.dataset.szk, f: +b.dataset.f, g: +b.dataset.g});\n      toast(b.dataset.rm ? "Zurück auf die Signal-Abstände" : "Übernommen – gilt ab dem nächsten Signal"); S = await api("/api/state"); labSessions(true); } catch (e) { toast(e.message); } });\n  $("#szRe").onclick = async () => { try { await api("/api/lab/sessions/refresh", {}); toast("Wird im Hintergrund neu berechnet"); setTimeout(() => labSessions(true), 4000); } catch (e) { toast(e.message); } };\n}\n/* ───────── Strategie-Finder ───────── */\nconst DF = {data: null, at: 0, err: null, open: null, fam: "NQ", imp: "", impBusy: false};\nfunction dfCurve(v) {\n  if (!v || v.length < 2) return "";\n  const W = 160, H = 34, lo = Math.min(0, ...v), hi = Math.max(0, ...v), sp = hi - lo || 1;\n  const x = i => 2 + (W - 4) * i / (v.length - 1), y = q => 3 + (H - 6) * (1 - (q - lo) / sp);\n  return `<svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" style="width:${W}px;height:${H}px;flex-shrink:0" aria-hidden="true"><line x1="2" x2="${W - 2}" y1="${y(0)}" y2="${y(0)}" class="gl" stroke-dasharray="2 2"/>\n    <path d="${v.map((q, i) => `${i ? "L" : "M"}${x(i).toFixed(1)},${y(q).toFixed(1)}`).join("")}" fill="none" stroke="${v[v.length - 1] >= 0 ? "var(--pos)" : "var(--neg)"}" stroke-width="1.6"/></svg>`;\n}\nasync function labFinder(force) {\n  const body = $("#lnBody");\n  if (force || !DF.data || Date.now() - DF.at > (DF.data && DF.data.state.busy ? 2500 : 30000)) {\n    if (!DF.data) body.innerHTML = \'<p class="hint">Lade …</p>\';\n    try { DF.data = await api("/api/disc"); DF.at = Date.now(); DF.err = null; } catch (e) { DF.err = e.message; }\n  }\n  if (TAB !== "learn" || LTAB !== "finder") return;\n  const d = DF.data; if (!d) { body.innerHTML = `<p class="err-msg">${esc(DF.err || "")}</p>`; return; }\n  const st = d.state || {}, items = d.items || [];\n  const by = k => items.filter(i => i.status === k).sort((a, b) => b.stats.t - a.stats.t);\n  const rel = t => t >= 3.5 ? ["good", "hoch"] : t >= 2.5 ? ["warn", "mittel"] : ["mute", "niedrig"];\n  const card = (it, actions) => { const s = it.stats, f = it.fwd, [rc, rl] = rel(s.t);\n    return `<div class="df-c">\n      <div class="df-h"><b>${esc(it.name)}</b><span class="chip ${rc}" title="t-Wert ${num2(s.t)}">Zuverlässigkeit ${rl}</span>${it.auto ? \'<span class="chip mute">vom Bot gewählt</span>\' : ""}<span style="flex:1"></span>${dfCurve(it.curve)}</div>\n      <p class="hint" style="margin:4px 0 8px;line-height:1.55">${esc(it.desc)}</p>\n      <div class="df-s">\n        <span><small>Rückblick</small><b class="mono">${s.n} Trades</b></span><span><small>Treffer</small><b class="mono">${pct(s.wr)}</b></span>\n        <span><small>Ø nach Gebühren</small><b class="mono ${cls(s.avg)}">${s.avg > 0 ? "+" : ""}${num2(s.avg)} R</b></span><span><small>Profit-Faktor</small><b class="mono">${num2(s.pf)}</b></span>\n        <span><small>Zeit-Hälften</small><b class="mono">${num2(s.avg1)} / ${num2(s.avg2)}</b></span><span><small>pro Woche</small><b class="mono">~${Math.round(s.per_week)}</b></span>\n        ${f ? `<span class="df-f"><small>Probelauf (nach dem Fund)</small><b class="mono ${f.n ? cls(f.avg) : ""}">${f.n} Trades${f.n ? ` · Ø ${f.avg > 0 ? "+" : ""}${num2(f.avg)} R` : ""}</b></span>` : ""}\n      </div>\n      <div class="df-a">${actions}</div></div>`; };\n  const btn = (it, a, l, cl = "") => `<button class="btn ${cl}" data-dfa="${a}" data-id="${esc(it.id)}" style="padding:5px 11px;font-size:12.5px">${l}</button>`;\n  const act = by("aktiv"), bereit = by("bereit"), probe = by("probe"), found = by("gefunden"), gone = by("verworfen");\n  const data = Object.entries(d.data || {});\n  const lowTf = act.some(i => i.tf < 5) || probe.some(i => i.tf < 5);\n  body.innerHTML = `\n    <section class="panel"><div class="section-h"><div><h2>Strategie-Finder</h2><p class="hint" style="max-width:92ch;margin:4px 0 0;line-height:1.6">Sucht in allen gespeicherten 1- und 5-Minuten-Kerzen nach <b>neuen Einstiegen</b> – Orderblock-Retest, Breaker-Block, FVG-Retest, Liquiditäts-Sweep, BOS-Pullback/OTE, Range-Ausbruch, Rückkehr zum Mittel und bekannte Scalping-Konzepte: Judas Swing (Asien-Range-Sweep), Vortages-Hoch/Tief-Sweep (Turtle Soup), Candle Range Theory und Opening Range Breakout – je Session, Richtung und Ziel. Läuft eine Strategie, prüft er jeden Abend, ob es inzwischen eine klar bessere Einstellung desselben Musters gibt; die muss dann ihren eigenen Probelauf bestehen und löst die alte ab. Gerechnet wird ehrlich: nach Gebühren, Stop vor Ziel bei Unklarheit, Einstieg erst dann, wenn die Kerzen live auch ankommen. Was hier gut aussieht, kann trotzdem Zufall sein (bei ${(d.tested || 0).toLocaleString("de-DE")} geprüften Varianten sind ein paar Glückstreffer normal). Deshalb muss jede Strategie erst einen <b>Probelauf</b> auf neuen Kerzen bestehen (20 Trades, Ø mind. +0,1 R), bevor sie mithandelt.</p></div>\n      <div class="inline" style="gap:8px;flex-wrap:wrap;justify-content:flex-end"><button class="btn primary" id="dfRun" ${st.busy ? "disabled" : ""}>${st.busy ? "Sucht …" : "Jetzt suchen"}</button></div></div>\n      ${st.busy ? `<div class="df-prog"><div class="mc-bar" style="margin:10px 0 4px"><i class="p" style="width:${st.total ? Math.round(st.done / st.total * 100) : 3}%;background:var(--accent)"></i></div><span class="hint">${esc(st.step || "")} · ${st.done || 0} / ${st.total || "?"}</span></div>` : ""}\n      ${st.error ? `<p class="err-msg">${esc(st.error)}</p>` : ""}\n      <div class="df-d">${data.length ? data.map(([k, v]) => `<span class="chip ${v.days >= 20 ? "good" : v.days >= 5 ? "warn" : "mute"}">${esc(k)}: ${v.days} Handelstage</span>`).join("") : \'<span class="hint">Noch nicht gesucht.</span>\'}\n        ${d.last_run ? `<span class="hint">Letzte Suche ${dtm(d.last_run)} · sucht jeden Abend nach der Tagesauswertung neu</span>` : ""}</div>\n      <details class="df-imp" ${DF.impBusy || DF.imp ? "open" : ""}><summary class="hint" style="cursor:pointer">Mehr Kursdaten = bessere Suche: Kursdaten importieren (TradingView, Databento, NinjaTrader)</summary>\n        <p class="hint" style="line-height:1.6">Die App sammelt Kerzen selbst, aber das dauert. Schneller: In TradingView den Chart (NQ1! oder ES1!) auf <b>1 Minute</b> (oder 5 Minuten) stellen, weit nach links scrollen, damit viel Verlauf geladen ist, dann oben im Menü des Charts <b>„Chart-Daten exportieren“</b> wählen (je nach TradingView-Abo verfügbar) und die CSV-Datei hier einlesen. <b>Viele Jahre auf einmal:</b> bei Databento (Startguthaben für neue Konten) Datensatz „CME Globex MDP 3.0“, Schema „OHLCV-1m“, Symbol <span class="mono">NQ.c.0</span> bzw. <span class="mono">ES.c.0</span> (fortlaufend), Format CSV – oder in NinjaTrader über „Historische Daten → Export“ (1 Minute). Doppelte Kerzen werden nur einmal gespeichert.</p>\n        <div class="inline" style="gap:8px;flex-wrap:wrap"><select id="dfFam"><option value="NQ" ${DF.fam === "NQ" ? "selected" : ""}>NQ / MNQ</option><option value="ES" ${DF.fam === "ES" ? "selected" : ""}>ES / MES</option></select>\n          <label class="btn ${DF.impBusy ? "disabled" : ""}">${DF.impBusy ? "Liest ein …" : "CSV-Datei wählen"}<input type="file" id="dfFile" accept=".csv,text/csv" hidden ${DF.impBusy ? "disabled" : ""}></label><span class="hint" id="dfMsg" style="max-width:60ch">${esc(DF.imp)}</span></div></details>\n    </section>\n    ${d.bundle > 1 && act.length ? `<div class="banner">Neue Strategien handeln nur mit frischen Kerzen. In TradingView in den Einstellungen der Strategie „Kerzen bündeln“ auf <b>1</b> stellen, sonst fallen die meisten Signale weg.</div>` : ""}\n    ${act.length || bereit.length ? `<section class="section"><h2>Handelt mit</h2><div class="df-list">${[...act, ...bereit].map(it => card(it, it.status === "bereit"\n        ? `<span class="hint">Probelauf bestanden. Dein Broker handelt mit echtem Geld – bitte selbst freigeben.</span>${btn(it, "activate", "Freigeben", "primary")}${btn(it, "discard", "Verwerfen")}`\n        : `<span class="hint">Signale laufen durch alle Schutz-Regeln, das Lernmodul bewertet sie wie jede andere Strategie.</span>${btn(it, "deactivate", "Pausieren")}${btn(it, "discard", "Verwerfen")}`)).join("")}</div></section>` : ""}\n    ${probe.length ? `<section class="section"><h2>Im Probelauf</h2><div class="df-list">${probe.map(it => card(it, `<span class="hint">Wird nur mitgerechnet, handelt noch nicht.${lowTf ? "" : ""}</span>${btn(it, "activate", d.broker === "paper" ? "Sofort mithandeln" : "Freigeben")}${btn(it, "discard", "Verwerfen")}`)).join("")}</div></section>` : ""}\n    <section class="section"><h2>Gefunden</h2>${found.length ? `<div class="df-list">${found.map(it => card(it, `${btn(it, "probe", "Probelauf starten", "primary")}${btn(it, "discard", "Verwerfen")}`)).join("")}</div>`\n      : `<div class="empty">${d.last_run ? "Bei der letzten Suche hat nichts die Prüfung bestanden. Mit mehr Kursdaten steigt die Chance." : "Noch nicht gesucht. Für eine Suche braucht es mindestens rund 3 Handelstage 1-Minuten-Kerzen."}</div>`}</section>\n    ${gone.length ? `<details class="set-sec"><summary><span class="s-ic">${icon(\'<path d="M6 6l12 12M18 6 6 18"/>\')}</span><span class="s-t"><b>Verworfen</b><span class="hint">${gone.length} Strategien – Probelauf nicht bestanden oder von dir verworfen</span></span><span></span></summary><div class="set-b"><div class="df-list">${gone.map(it => card(it, btn(it, "probe", "Neuer Probelauf"))).join("")}</div></div></details>` : ""}`;\n  body.querySelectorAll("[data-dfa]").forEach(b => b.onclick = async () => {\n    try { await api("/api/disc/item", {id: b.dataset.id, action: b.dataset.dfa}); toast({probe: "Probelauf gestartet", activate: "Handelt ab jetzt mit", deactivate: "Pausiert", discard: "Verworfen"}[b.dataset.dfa]); labFinder(true); } catch (e) { toast(e.message); } });\n  $("#dfRun").onclick = async () => { try { await api("/api/disc/run", {}); toast("Suche läuft im Hintergrund"); setTimeout(() => labFinder(true), 800); } catch (e) { toast(e.message); } };\n  $("#dfFam").onchange = e => { DF.fam = e.target.value; };\n  $("#dfFile").onchange = async e => {\n    const f = e.target.files[0]; if (!f) return;\n    DF.impBusy = true; DF.imp = `Lese ${f.name} ein (${Math.round(f.size / 1e6)} MB) – bei großen Dateien 1–2 Minuten, bitte warten …`; labFinder();\n    try { const r = await api("/api/disc/import", {fam: DF.fam, csv: await f.text()});\n      DF.imp = `✓ ${r.bars.toLocaleString("de-DE")} ${r.kind} (${r.days} Handelstage, ${new Date(r.from).toLocaleDateString("de-DE")} – ${new Date(r.to).toLocaleDateString("de-DE")}) importiert. Jetzt „Jetzt suchen“ klicken.`; }\n    catch (err) { DF.imp = "Fehler: " + err.message; }\n    DF.impBusy = false; labFinder(true);\n  };\n  if (st.busy) setTimeout(() => { if (TAB === "learn" && LTAB === "finder") labFinder(true); }, 2500);\n}\nconst BT = {trades: null, name: "", loaded: false, filter: "Alle", err: null, src: "export", live: null, liveAt: 0};\ntry { BT.src = localStorage.getItem("fvg-bt-src") || "export"; } catch (e) {}\nconst BT_NEWS = {\n  FOMC: [20240131,20240320,20240501,20240612,20240731,20240918,20241107,20241218,20250129,20250319,20250507,20250618,20250730,20250917,20251029,20251210,\n         20260128,20260318,20260429,20260617,20260729,20260916,20261028,20261209,20270127,20270317,20270428,20270609,20270728,20270915,20271027,20271208],\n  CPI: [20240111,20240213,20240312,20240410,20240515,20240612,20240711,20240814,20240911,20241010,20241113,20241211,20250115,20250212,20250312,20250410,20250513,\n        20250611,20250715,20250812,20250911,20251024,20251218,20260113,20260213,20260311,20260410,20260512,20260610,20260714,20260812,20260911,20261014,20261110,20261210],\n  NFP_EXTRA: [20251120,20251216,20260109], NFP_SKIP: [20251003,20251107]};\nconst btKey = d => d.getFullYear() * 10000 + (d.getMonth() + 1) * 100 + d.getDate();\nfunction btNews(d) {\n  const k = btKey(d), t = [];\n  if (BT_NEWS.FOMC.includes(k)) t.push("FOMC");\n  if (BT_NEWS.CPI.includes(k)) t.push("CPI");\n  if ((d.getDay() === 5 && d.getDate() <= 7 && !BT_NEWS.NFP_SKIP.includes(k)) || BT_NEWS.NFP_EXTRA.includes(k)) t.push("NFP");\n  return t;\n}\nconst btNum = v => { if (typeof v === "number") return v; if (v == null) return NaN;\n  let x = String(v).replace(/[−–]/g, "-").replace(/[^0-9.,\\-]/g, "");\n  if (x.includes(",") && x.includes(".")) x = x.lastIndexOf(",") > x.lastIndexOf(".") ? x.replace(/\\./g, "").replace(",", ".") : x.replace(/,/g, "");\n  else if (x.includes(",")) x = /^-?\\d{1,3}(,\\d{3})+$/.test(x) ? x.replace(/,/g, "") : x.replace(",", ".");\n  return parseFloat(x); };\nfunction btDate(v) {\n  if (v instanceof Date) return v;\n  if (typeof v === "number") return new Date(Math.round((v - 25569) * 864e5) + new Date().getTimezoneOffset() * 60000);\n  const s = String(v).trim(), m = s.match(/^(\\d{1,2})\\.(\\d{1,2})\\.(\\d{2,4})[ ,T]+(\\d{1,2}):(\\d{2})/);\n  if (m) return new Date(+(m[3].length === 2 ? "20" + m[3] : m[3]), +m[2] - 1, +m[1], +m[4], +m[5]);\n  const d = new Date(s.replace(" ", "T")); return isNaN(d) ? new Date(s) : d;\n}\nconst BT_ID = /^(trade[\\s-]*(#|nr\\.?|nummer|no\\.?|number)|#|nr\\.?)$/i, BT_ID2 = /trade[\\s-]*(#|nr|nummer|no|number)/i;\nfunction btParse(rows) {\n  let hi = -1;\n  for (let i = 0; i < Math.min(rows.length, 40); i++) { const r = rows[i].map(c => String(c ?? "").trim());\n    if (r.some(c => BT_ID.test(c) || BT_ID2.test(c)) && r.some(c => /^(type|typ)\\b/i.test(c) || /date|datum|zeit/i.test(c))) { hi = i; break; } }\n  if (hi < 0) throw new Error("NOHEADER");\n  const h = rows[hi].map(c => String(c ?? "").trim()), ix = re => h.findIndex(c => re.test(c));\n  let cT = ix(BT_ID); if (cT < 0) cT = ix(BT_ID2);\n  const cType = ix(/^(type|typ)\\b/i), cD = ix(/date|datum/i), cS = ix(/^signal/i);\n  const cP = h.findIndex(c => /(net\\s*p&?l|netto[\\s-]*(g&?v|gewinn|p&?l)|^g&v|^p&l|profit|gewinn)/i.test(c) && !/%|cum|kum|run|lauf|draw|max/i.test(c));\n  const miss = [[cT, "Trade-Nummer"], [cType, "Typ"], [cD, "Datum/Uhrzeit"], [cP, "Netto-G&V"]].filter(x => x[0] < 0).map(x => x[1]);\n  if (miss.length) throw new Error("Spalten nicht erkannt: " + miss.join(", ") + ". Gefunden: " + h.filter(Boolean).join(" · "));\n  const by = new Map();\n  for (const r of rows.slice(hi + 1)) {\n    if (r[cT] == null || r[cT] === "") continue;\n    const id = String(r[cT]), t = String(r[cType] || "").toLowerCase(), o = by.get(id) || {};\n    if (/entry|einstieg|eintritt/.test(t)) { o.time = btDate(r[cD]); o.setup = String(cS >= 0 ? r[cS] || "" : ""); o.dir = /short|verkauf/.test(t) ? "Short" : "Long"; }\n    else { if (/offen|open/i.test(String(r[cD]))) o.open = true; else o.exit = btDate(r[cD]); if (!o.dir) o.dir = /short|verkauf/.test(t) ? "Short" : "Long"; }\n    const p = btNum(r[cP]); if (!isNaN(p)) o.pnl = p;\n    by.set(id, o);\n  }\n  const out = [...by.values()].filter(o => !o.open && o.time && !isNaN(o.time) && typeof o.pnl === "number");   // noch offene Trades zählen nicht\n  out.forEach(o => { o.setup = (o.setup || "").trim(); if (!/(long|short)$/i.test(o.setup)) o.setup = ((o.setup || "Trade") + " " + o.dir); });\n  if (!out.length) throw new Error("Keine abgeschlossenen Trades in der Datei gefunden.");\n  return out.sort((a, b) => a.time - b.time);\n}\nasync function btLoadFile(f) {\n  BT.err = null;\n  try {\n    const buf = new Uint8Array(await f.arrayBuffer());\n    let bin = ""; for (let i = 0; i < buf.length; i += 0x8000) bin += String.fromCharCode.apply(null, buf.subarray(i, i + 0x8000));\n    const res = await api("/api/backtest/read", {name: f.name, data: btoa(bin)});\n    let trades = null, lastErr = null;\n    const order = [...res.sheets].sort((a, b) => (/liste|list/i.test(b.name) ? 1 : 0) - (/liste|list/i.test(a.name) ? 1 : 0));\n    for (const sh of order) { try { trades = btParse(sh.rows); break; } catch (e) { if (e.message !== "NOHEADER") lastErr = e; } }\n    if (!trades) {\n      const first = res.sheets.map(x => (x.rows.find(r => r.some(c => String(c).trim())) || []).slice(0, 12).map(c => String(c).trim()).filter(Boolean).join(" | ")).filter(Boolean)[0] || "leer";\n      throw lastErr || new Error(`Keine Trade-Liste gefunden. Erste Zeile der Datei: „${first.slice(0, 300)}“. Bitte im Strategietester die „Liste der Trades“ exportieren, nicht die Chartdaten.`);\n    }\n    BT.trades = trades; BT.name = f.name; BT.filter = "Alle";\n    await api("/api/backtest/save", {name: f.name, trades: trades.map(t => ({time: t.time.getTime(), setup: t.setup, dir: t.dir, pnl: t.pnl}))});\n    toast(`${trades.length} Trades eingelesen`);\n  } catch (e) { BT.err = e.message; }\n  backtestView(true);\n}\nconst btStats = ts => {\n  const n = ts.length, w = ts.filter(t => t.pnl > 0), l = ts.filter(t => t.pnl <= 0);\n  const gp = w.reduce((a, t) => a + t.pnl, 0), gl = -l.reduce((a, t) => a + t.pnl, 0);\n  let eq = 0, pk = 0, dd = 0; for (const t of ts) { eq += t.pnl; pk = Math.max(pk, eq); dd = Math.min(dd, eq - pk); }\n  return {n, net: gp - gl, wr: n ? w.length / n * 100 : null, pf: gl ? gp / gl : (gp ? Infinity : null), dd, avg: n ? (gp - gl) / n : null,\n    aw: w.length ? gp / w.length : null, al: l.length ? -gl / l.length : null};\n};\nfunction btBars(data) {\n  if (!data.length) return \'<p class="hint">Keine Daten.</p>\';\n  const W = 440, H = 190, L = 52, R = 8, T = 10, B = 24, vals = data.map(d => d.v);\n  const lo = Math.min(0, ...vals), hi = Math.max(0, ...vals), span = hi - lo || 1;\n  const y = v => T + (H - T - B) * (1 - (v - lo) / span), bw = (W - L - R) / data.length, every = Math.ceil(data.length / 12);\n  return `<svg viewBox="0 0 ${W} ${H}" role="img"><line class="gl" x1="${L}" x2="${W - R}" y1="${y(0)}" y2="${y(0)}"/>\n    <text x="${L - 6}" y="${y(hi) + 4}" text-anchor="end">${kUsd(hi)}</text><text x="${L - 6}" y="${y(lo) + 4}" text-anchor="end">${kUsd(lo)}</text>\n    ${data.map((d, i) => { const x0 = L + i * bw + bw * .15, w = bw * .7, y0 = y(Math.max(0, d.v)), h = Math.abs(y(d.v) - y(0));\n      return `<rect x="${x0}" y="${y0}" width="${w}" height="${Math.max(1, h)}" rx="1.5" fill="${d.v >= 0 ? "var(--pos)" : "var(--neg)"}"><title>${d.l}: ${sUsd(d.v)}</title></rect>` +\n        (i % every === 0 ? `<text x="${x0 + w / 2}" y="${H - 6}" text-anchor="middle">${d.l}</text>` : ""); }).join("")}</svg>`;\n}\nasync function backtestView(force) {\n  const body = $("#lnBody");\n  if (!BT.loaded) { BT.loaded = true; try { const r = await api("/api/backtest"); if (r.trades && r.trades.length) { BT.trades = r.trades.map(t => ({...t, time: new Date(t.time)})); BT.name = r.name; } } catch (e) {} }\n  if (BT.src === "live" && (!BT.live || Date.now() - BT.liveAt > 60000)) {\n    try { BT.live = (await api("/api/backtest/live")).trades.map(t => ({...t, time: new Date(t.time)})); BT.liveAt = Date.now(); force = true; } catch (e) { BT.err = e.message; }\n  }\n  if (!force && body.querySelector(".bt")) return;\n  if (TAB !== "learn" || LTAB !== "backtest") return;\n  const all = (BT.src === "live" ? BT.live : BT.trades) || [], setups = [...new Set(all.map(t => t.setup))].sort();\n  const ts = BT.filter === "Alle" ? all : all.filter(t => t.setup === BT.filter), st = btStats(ts);\n  const row = (label, x) => `<tr><td class="t">${label}</td><td>${x.n}</td><td>${pct(x.wr)}</td><td>${x.pf == null ? "–" : isFinite(x.pf) ? num2(x.pf) : "∞"}</td><td class="${cls(x.net)}">${usd(x.net)}</td><td class="${cls(x.avg)}">${x.n ? usd(x.avg) : "–"}</td></tr>`;\n  const tbl = (head, rows) => `<div class="scroll"><table><thead><tr>${head.map((h, i) => `<th class="${i ? "" : "t"}">${h}</th>`).join("")}</tr></thead><tbody>${rows.join("")}</tbody></table></div>`;\n  const H6 = ["", "Trades", "Treffer", "PF", "Netto", "Ø Trade"];\n  let curve = [], e = 0; ts.forEach(t => { e += t.pnl; curve.push({t: t.time.getTime() / 1000, e}); });\n  const months = new Map(); ts.forEach(t => { const k = t.time.getFullYear() + "-" + String(t.time.getMonth() + 1).padStart(2, "0"); months.set(k, (months.get(k) || 0) + t.pnl); });\n  const hours = new Map(); ts.forEach(t => { const h = t.time.getHours(); hours.set(h, (hours.get(h) || 0) + t.pnl); });\n  const DN = ["So", "Mo", "Di", "Mi", "Do", "Fr", "Sa"];\n  const news = ts.filter(t => btNews(t.time).length), calm = ts.filter(t => !btNews(t.time).length);\n  body.innerHTML = `<section class="panel bt">\n    <div class="seg" role="group" aria-label="Quelle" style="align-self:flex-start">${[["export", "TradingView-Export"], ["live", "Live-Signale (automatisch)"]].map(([k, l]) => `<button type="button" data-bsrc="${k}" aria-pressed="${BT.src === k}">${l}</button>`).join("")}</div>\n    ${BT.src === "live" ? `<p class="hint" style="margin:0;line-height:1.6;max-width:85ch">Alle Signale, die die Strategie seit dem Start an die App geschickt hat, auch nicht ausgeführte oder blockierte, mit ihrem echten Ausgang (Stop, Ziel oder Ausstieg). Gerechnet für <b>1 Micro-Kontrakt</b> inklusive Gebühren, damit es mit dem TradingView-Backtest vergleichbar ist. Füllt sich von selbst, kein Export nötig.</p>` : `\n    <div class="section-h"><div><h2 style="font-size:16px;text-transform:none;letter-spacing:0;color:var(--fg)">Backtest aus TradingView</h2>\n      <p class="hint" style="max-width:85ch;margin-top:4px;line-height:1.6">Im TradingView-Strategietester „Liste der Trades“ exportieren (CSV oder Excel, deutsch oder englisch) und hier einlesen. Die App wertet aus: Equity, Drawdown, Setups, Monate, Uhrzeiten, Wochentage und News-Tage (FOMC, CPI, NFP). Der letzte Import bleibt gespeichert.</p></div>\n      <div class="inline"><label class="btn primary" style="cursor:pointer">Export einlesen<input type="file" id="btFile" accept=".csv,.xlsx,.xls,.txt" hidden></label></div></div>\n    <div class="bt-drop" id="btDrop">${BT.name ? `Aktuell: <b>${esc(BT.name)}</b> · ${all.length} Trades · neue Datei hierher ziehen zum Ersetzen` : "Datei hierher ziehen"}</div>\n    ${BT.err ? `<p class="err-msg">${esc(BT.err)}</p>` : ""}`}\n  </section>\n  ${all.length ? `\n  <div class="seg bt-seg" role="group" aria-label="Setup">${["Alle", ...setups].map(k => `<button type="button" data-bf="${esc(k)}" aria-pressed="${BT.filter === k}">${esc(k)}</button>`).join("")}</div>\n  <section class="kpis">${[["Netto-Gewinn", usd(st.net), cls(st.net)], ["Trades", st.n, ""], ["Trefferquote", pct(st.wr), ""],\n    ["Profit-Faktor", st.pf == null ? "–" : isFinite(st.pf) ? num2(st.pf) : "∞", st.pf >= 1 ? "pos" : "neg"], ["Max. Drawdown", usd(st.dd), "neg"],\n    ["Ø Gewinn / Verlust", `${usd(st.aw)} / ${usd(st.al)}`, ""], ["Zeitraum", ts.length ? `${ts[0].time.toLocaleDateString("de-DE")} – ${ts[ts.length - 1].time.toLocaleDateString("de-DE")}` : "–", ""]]\n    .map(([l, v, c]) => `<div class="kpi"><span class="l">${l}</span><span class="v ${c}" style="${/Zeitraum|Ø/.test(l) ? "font-size:14px" : ""}">${v}</span></div>`).join("")}</section>\n  <section class="panel"><div class="section-h"><h2>Equity</h2><p class="hint">Kumulierter Netto-Gewinn je Trade</p></div>${equitySvg(curve)}</section>\n  <div class="grid2">\n    <section class="section"><h2>Nach Setup</h2><div class="panel">${tbl(["Setup", ...H6.slice(1)], setups.map(k => row(`<span class="chip">${esc(k)}</span>`, btStats(all.filter(t => t.setup === k)))))}</div></section>\n    <section class="section"><h2>News-Tage</h2><div class="panel">${tbl(["Tag", ...H6.slice(1)], [row("Normale Tage", btStats(calm)), row("Alle News-Tage", btStats(news)),\n      ...["FOMC", "CPI", "NFP"].map(k => row(`<span class="chip warn">${k}</span>`, btStats(ts.filter(t => btNews(t.time).includes(k)))))])}</div></section>\n  </div>\n  <div class="grid2">\n    <section class="section"><h2>Monatlich</h2><div class="panel">${btBars([...months.entries()].map(([k, v]) => ({l: k.slice(2).replace("-", "/"), v})))}</div></section>\n    <section class="section"><h2>Nach Uhrzeit (deine Ortszeit)</h2><div class="panel">${btBars([...hours.entries()].sort((a, b) => a[0] - b[0]).map(([h, v]) => ({l: h + "h", v})))}</div></section>\n  </div>\n  <section class="section"><h2>Nach Wochentag</h2><div class="panel">${tbl(["Tag", ...H6.slice(1)], [1, 2, 3, 4, 5].map(d => row(DN[d], btStats(ts.filter(t => t.time.getDay() === d)))))}</div></section>\n  <section class="section"><h2>Letzte 40 Trades</h2><div class="panel">${tbl(["Einstieg", "Setup", "News", "Netto"], ts.slice(-40).reverse().map(t =>\n    `<tr><td class="t mono">${t.time.toLocaleString("de-DE", {day: "2-digit", month: "2-digit", year: "2-digit", hour: "2-digit", minute: "2-digit"})}</td><td class="t"><span class="chip">${esc(t.setup)}</span></td><td class="t">${btNews(t.time).map(x => `<span class="chip warn">${x}</span>`).join(" ") || "–"}</td><td class="${cls(t.pnl)}">${usd(t.pnl)}</td></tr>`))}</div></section>`\n  : BT.src === "live" ? `<div class="empty">Noch keine abgeschlossenen Signale. Sobald die Strategie in TradingView Trades macht, erscheinen sie hier automatisch.</div>`\n  : `<div class="empty">Noch kein Backtest eingelesen. So geht\'s: TradingView → unten „Strategietester“ → Tabellen-Ansicht → „Liste der Trades“ → Export (CSV oder Excel) → hier „Export einlesen“.</div>`}`;\n  body.querySelectorAll("[data-bsrc]").forEach(b => b.onclick = () => { BT.src = b.dataset.bsrc; BT.filter = "Alle"; try { localStorage.setItem("fvg-bt-src", BT.src); } catch (e) {} backtestView(true); });\n  if (BT.src === "live") { body.querySelectorAll("[data-bf]").forEach(b => b.onclick = () => { BT.filter = b.dataset.bf; backtestView(true); }); return; }\n  $("#btFile").onchange = e => { const f = e.target.files[0]; if (f) btLoadFile(f); e.target.value = ""; };\n  const dz = $("#btDrop");\n  ["dragenter", "dragover"].forEach(ev => dz.addEventListener(ev, e => { e.preventDefault(); dz.classList.add("over"); }));\n  ["dragleave", "drop"].forEach(ev => dz.addEventListener(ev, e => { e.preventDefault(); dz.classList.remove("over"); }));\n  dz.addEventListener("drop", e => { const f = e.dataTransfer.files[0]; if (f) btLoadFile(f); });\n  body.querySelectorAll("[data-bf]").forEach(b => b.onclick = () => { BT.filter = b.dataset.bf; backtestView(true); });\n}\n\n/* ───────── Einstellungen ───────── */\nfunction field(id, label, value, opts = {}) {\n  const attrs = Object.entries(opts.attrs || {}).map(([k, v]) => `${k}="${v}"`).join(" ");\n  const inp = opts.select ? `<select id="${id}" data-cfg>${opts.select.map(([v, l]) => `<option value="${v}" ${String(v) === String(value) ? "selected" : ""}>${l}</option>`).join("")}</select>`\n    : opts.check ? `<input id="${id}" data-cfg type="checkbox" ${value ? "checked" : ""} class="chk">`\n    : `<input id="${id}" data-cfg type="${opts.type || "number"}" value="${esc(value ?? "")}" ${attrs} ${opts.type === "password" ? \'autocomplete="new-password"\' : ""}>`;\n  return `<div class="row ${opts.cls || ""}" ${opts.hidden ? "hidden" : ""} data-row="${id}"><label for="${id}">${label}${opts.help ? `<small>${opts.help}</small>` : ""}</label>${inp}</div>`;\n}\nconst v = id => { const el = $("#" + id); return !el ? undefined : el.type === "checkbox" ? el.checked : el.value; };\nconst num = id => { const x = parseFloat(v(id)); return isFinite(x) ? x : undefined; };\n// Einstellungs-Bereiche zum Aufklappen. Welche offen sind, merkt sich die App.\nlet OPEN = new Set();\ntry { OPEN = new Set(JSON.parse(localStorage.getItem("fvg-open") || "[]")); } catch (e) { /* ohne Speicher alles zu */ }\nconst SIC = {\n  app: \'<rect x="4" y="4" width="16" height="16" rx="4"/><path d="M12 8v5M9.5 10.5 12 13l2.5-2.5M8.5 16h7"/>\',\n  size: \'<path d="M4 18h16M7 18V9M12 18V5M17 18v-6"/>\',\n  risk: \'<path d="M12 3 5 6v5c0 4.4 3 8.3 7 9.5 4-1.2 7-5.1 7-9.5V6z"/><path d="m9 12 2 2 4-4"/>\',\n  notify: \'<path d="M6 16V11a6 6 0 0 1 12 0v5l1.5 2h-15z"/><path d="M10 20a2 2 0 0 0 4 0"/>\',\n  sess: \'<circle cx="12" cy="12" r="8.5"/><path d="M12 7.5V12l3 2"/>\',\n  tv: \'<path d="M4 16 9 10l4 3 7-8"/><path d="M15 5h5v5"/>\',\n  acc: \'<path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1"/><path d="M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1"/>\',\n  adv: \'<path d="M4 7h10M18 7h2M4 17h4M12 17h8"/><circle cx="16" cy="7" r="2"/><circle cx="10" cy="17" r="2"/>\',\n};\nconst intro = t => `<p class="hint" style="margin:0">${t}</p>`;\nconst sec = (key, title, sum, chip, body) => `<details class="set-sec" data-sec="${key}" ${OPEN.has(key) ? "open" : ""}>\n  <summary><span class="s-ic">${icon(SIC[key])}</span><span class="s-t"><b>${title}</b><span class="hint">${sum}</span></span><span class="s-chip">${chip || ""}</span></summary>\n  <div class="set-b">${body}</div></details>`;\n\nlet settingsKey = "";\n// New Yorker Uhrzeit in die Ortszeit des Nutzers umrechnen (aus aktueller NY-Zeit vom Server)\nfunction localTime(hm) {\n  const [nh, nm] = (S.now_ny || "00:00").split(":").map(Number), now = new Date();\n  const off = ((now.getHours() * 60 + now.getMinutes()) - (nh * 60 + nm) + 1440 * 2) % 1440;\n  const rounded = Math.round(off / 30) * 30, [h, m] = hm.split(":").map(Number), t = (h * 60 + m + rounded) % 1440;\n  return `${String(Math.floor(t / 60)).padStart(2, "0")}:${String(t % 60).padStart(2, "0")}`;\n}\nfunction settings() {\n  settingsKey = JSON.stringify([S.tunnel, S.hook_url, S.broker, S.update, S.own_sync && S.own_sync.last, S.own_sync && S.own_sync.error, S.autostart, S.service]);\n  const c = S.config, sz = c.sizing, ss = c.safe_stop, r = c.risk, t = c.tradovate, L = c.learning, dc = c.discord || {};\n  const phoneUrl = (c.public_url || S.tunnel.url || "").replace(/\\/+$/, "");\n  const prev = fam => S.sizing_preview[fam].map((p, i) => {\n    const pts = (fam === "NQ" ? [10, 20, 40, 60] : [3, 5, 10, 15])[i];\n    return `<span class="pv">${pts} Pkt. → ${typeof p === "string" ? "zu weit" : `<b>${p[1]}× ${p[0]}</b> <span class="neg">${usd(p[2])}</span>`}</span>`;\n  }).join("");\n  const updState = S.update.available ? `<span class="chip warn">Version ${esc(S.update.version)} verfügbar</span>`\n    : S.update.error && S.update.checked ? `<span class="chip bad">Prüfung fehlgeschlagen</span>`\n    : `<span class="chip good">aktuell</span>`;\n\n  const sessOn = Object.entries(S.sessions).filter(([k]) => (r.sessions || {})[k]).map(([, x]) => x.name);\n  const sizeSum = (sz.mode === "fixed" ? `${sz.fixed_qty} Kontrakt${sz.fixed_qty == 1 ? "" : "e"} pro Trade` : sz.mode === "risk_usd" ? `${usd(sz.risk_usd)} Risiko pro Trade` : `${sz.risk_pct} % Risiko pro Trade`)\n    + ` · ${{auto: "Mini oder Micro", mini: "nur Mini", micro: "nur Micro"}[sz.contract_type] || ""} · max. ${sz.max_qty}`;\n  const riskSum = `Stop NQ ${ss.NQ.default} / ES ${ss.ES.default} Pkt. · Ziel ${ss.default_rr} R · ${r.max_daily_loss > 0 ? "Tageslimit " + usd(r.max_daily_loss) : "kein Tageslimit"} · ${(c.news || {}).enabled ? `News-Pause ±${c.news.before_min}/${c.news.after_min} Min` : "keine News-Pause"}`;\n  const tunChip = S.tunnel.ok || c.public_url ? `<span class="chip ${S.tunnel.fixed || c.public_url ? "good" : "warn"}">${S.tunnel.fixed || c.public_url ? "feste Adresse" : "wechselnde Adresse"}</span>` : \'<span class="chip bad">getrennt</span>\';\n  const accChip = t.username && t.cid ? (S.own_sync.error ? \'<span class="chip bad">Fehler</span>\' : \'<span class="chip good">Tradovate</span>\') : \'<span class="chip mute">nicht verbunden</span>\';\n  $("#main").innerHTML = `<div class="settings-wrap">\n  ${sec("app", "App & Updates", `Version ${esc(S.version)}${S.autostart ? " · startet mit Windows" : ""} · Handy · Protokoll`, updState, `\n    <div class="row"><label>Installierte Version<small>${S.update.checked ? "Zuletzt geprüft: " + dtm(S.update.checked) : "Die App prüft bei jedem Start und alle 6 Stunden."}</small></label>\n      <div class="inline"><b class="mono">${esc(S.version)}</b> ${updState}</div></div>\n    <div class="row"><label>Programmdatei<small>Diese Datei läuft gerade, auf sie zeigt auch das Desktop-Symbol. Andere Kopien (z. B. „FVG-Trader (1).cmd“ in Downloads) kannst du löschen.</small></label>\n      <div class="inline"><span class="mono" style="font-size:11.5px;word-break:break-all;text-align:right">${esc(S.launcher || "–")}</span></div></div>\n    <div class="row"><label>Nach Updates suchen und installieren<small>${S.update.available && S.update.notes ? esc(S.update.notes) : "Deine Einstellungen und Trades bleiben erhalten."}</small></label>\n      <button class="btn primary" id="updNowSet">Jetzt aktualisieren</button></div>\n    ${field("au", "Updates automatisch installieren", c.auto_update, {check: true, help: "Sucht stündlich nach neuen Versionen und installiert sie selbst, aber nie während ein Trade oder Vorschlag offen ist. Danach startet die App kurz neu."})}\n    ${S.platform.startsWith("win") ? `<div class="row"><label>Desktop-Symbol<small>Legt „FVG Trader“ auf dem Desktop und im Startmenü neu an.</small></label>\n      <button class="btn" id="mkIcon">Desktop-Symbol anlegen</button></div>` : ""}\n    ${S.platform.startsWith("win") ? `<div class="row"><label>Als Dienst starten (ohne Anmeldung)<small>${(S.service || {}).installed\n        ? `Eingerichtet: FVG Trader startet beim Hochfahren des PCs/Servers von selbst, auch ohne dass sich jemand anmeldet.${(S.service || {}).running ? " Läuft gerade als Dienst." : " Läuft gerade noch normal, ab dem nächsten Hochfahren als Dienst."}`\n        : "Ideal für einen Windows-Server: startet beim Hochfahren, ohne Anmeldung. Windows fragt einmal nach Administratorrechten."}</small></label>\n      <button class="tgl" id="svcT" role="switch" aria-checked="${!!(S.service || {}).installed}" aria-label="Als Dienst starten"></button></div>` : ""}\n    ${S.platform.startsWith("win") && !(S.service || {}).installed ? `<div class="row"><label>Mit Windows starten<small>Startet nach deiner Anmeldung still im Hintergrund.</small></label>\n      <button class="tgl" id="asT" role="switch" aria-checked="${S.autostart}" aria-label="Mit Windows starten"></button></div>` : ""}\n    <div class="row"><label>FVG Trader beenden<small>Ohne Beenden läuft der Bot im Hintergrund weiter, auch wenn das Fenster zu ist.</small></label>\n      <button class="btn ghost-danger" id="quit">App beenden</button></div>\n    <span class="lbl">Aufs Handy</span>\n    <div class="copyrow"><div class="code">${esc(phoneUrl || "kommt, sobald die Internet-Verbindung steht")}</div><button class="btn" id="cpPhone" ${phoneUrl ? "" : "disabled"}>Kopieren</button></div>\n    ${intro(`Am Handy öffnen, anmelden und „Zum Startbildschirm“ wählen. ${S.tunnel.fixed || c.public_url ? "Die Adresse bleibt fest." : "Die Adresse ändert sich bei jedem Neustart, mit ngrok-Schlüssel (TradingView) bleibt sie fest."}`)}\n    <span class="lbl">Protokoll</span>\n    <div class="inline wrap-gap"><button class="btn" id="logShow">App-Log anzeigen</button><button class="btn" id="logFolder">Ordner öffnen</button></div>\n    ${intro("Hilfreich, wenn etwas nicht klappt: Log anzeigen, kopieren und in den Chat schicken.")}`)}\n\n  ${sec("size", "Positionsgröße", sizeSum, "", `\n    <div class="row"><label>Methode</label><div class="seg" role="group" aria-label="Methode">${[["fixed", "Feste Anzahl"], ["risk_usd", "Risiko $"], ["risk_pct", "Risiko %"]].map(([k, l]) =>\n      `<button type="button" data-mode="${k}" aria-pressed="${sz.mode === k}">${l}</button>`).join("")}</div></div>\n    ${field("fq", "Kontrakte pro Trade", sz.fixed_qty, {attrs: {min: 1, step: 1}, hidden: sz.mode !== "fixed"})}\n    ${field("ru", "Risiko pro Trade ($)", sz.risk_usd, {attrs: {min: 10, step: 10}, hidden: sz.mode !== "risk_usd", help: "Größe wird aus dem Stop-Abstand berechnet"})}\n    ${field("rp", "Risiko pro Trade (% vom Konto)", sz.risk_pct, {attrs: {min: 0.05, max: 5, step: 0.05}, hidden: sz.mode !== "risk_pct"})}\n    ${field("ct", "Kontrakttyp", sz.contract_type, {select: [["auto", "Automatisch (Mini oder Micro)"], ["mini", "Nur Mini (NQ / ES)"], ["micro", "Nur Micro (MNQ / MES)"]]})}\n    ${field("mq", "Höchstens Kontrakte", sz.max_qty, {attrs: {min: 1, step: 1}})}\n    <div class="preview"><span class="hint">Beispiel mit gespeicherter Einstellung</span><div><b>NQ</b> ${prev("NQ")}</div><div><b>ES</b> ${prev("ES")}</div></div>`)}\n\n  ${sec("risk", "Risiko & Schutz", riskSum, \'<span class="chip good">Safe-Stop an</span>\', `\n    ${intro("Jede Order bekommt einen Stop-Loss. Fehlt er im Signal, nimmt der Bot den Standard-Stop.")}\n    ${field("nqd", "Standard-Stop NQ (Punkte)", ss.NQ.default, {attrs: {step: 0.25, min: 1}})}\n    ${field("esd", "Standard-Stop ES (Punkte)", ss.ES.default, {attrs: {step: 0.25, min: 0.25}})}\n    ${field("rr", "Standard-Ziel (R)", ss.default_rr, {attrs: {step: 0.25, min: 0.5}, help: "Wenn das Signal kein Ziel mitschickt"})}\n    ${field("mdl", "Tagesverlust-Limit ($)", r.max_daily_loss, {attrs: {min: 0, step: 50}, help: "Danach nimmt der Bot heute keine neuen Trades mehr. 0 = aus"})}\n    ${field("mtd", "Max. Trades pro Tag", r.max_trades_day, {attrs: {min: 1, step: 1}})}\n    <span class="lbl">Tages-Stopp</span>\n    ${field("dps", "Tagesziel ($)", r.daily_profit_stop || 0, {attrs: {min: 0, step: 50}, help: "Ist der Tag so weit im Plus, nimmt der Bot heute keine neuen Trades mehr – schützt gute Tage. 0 = aus"})}\n    ${field("dsc", "Beim Tages-Stopp offene Positionen schließen", r.daily_stop_close, {check: true, help: "Gilt für Tagesziel und Tagesverlust-Limit (beide zählen offene Positionen mit)"})}\n    <span class="lbl">News-Pause</span>\n    ${field("nwE", "Rund um wichtige News nicht handeln", (c.news || {}).enabled, {check: true, help: "Nutzt den Wirtschaftskalender (Cockpit → Wirtschafts-News). Gilt zusätzlich zum News-Filter im TradingView-Script."})}\n    ${field("nwB", "Minuten vorher sperren", (c.news || {}).before_min, {attrs: {min: 0, max: 240, step: 1}})}\n    ${field("nwA", "Minuten danach sperren", (c.news || {}).after_min, {attrs: {min: 0, max: 240, step: 1}})}\n    ${field("nwI", "Welche News", (c.news || {}).impact, {select: [["high", "Nur hohe Wichtigkeit (rot)"], ["medium", "Hohe und mittlere (rot + orange)"]]})}\n    ${field("nwU", "Nur US-News", (c.news || {}).usd_only, {check: true, help: "NQ und ES reagieren vor allem auf US-Daten"})}\n    ${field("nwC", "Offene Positionen vorher schließen", (c.news || {}).close_before, {check: true, help: "1 Minute vor dem Termin, damit kein Trade in die Veröffentlichung läuft"})}`)}\n\n  ${sec("notify", "Benachrichtigungen (Discord)", dc.enabled && dc.url ? [dc.trades && "Trades", dc.errors && "Fehler", dc.silence && "Stille", dc.daystop && "Tages-Stopp", dc.daily && "Tagesabschluss", dc.weekly && "Wochenbericht", dc.learn && "Lernmodul"].filter(Boolean).join(" · ") : "aus", dc.enabled && dc.url ? \'<span class="chip good">an</span>\' : \'<span class="chip mute">aus</span>\', `\n    ${intro(`So bekommst du Nachrichten aufs Handy: In Discord einen eigenen Server oder Kanal anlegen → Kanal-Einstellungen (Zahnrad) → <b>Integrationen</b> → <b>Webhooks</b> → <b>Neuer Webhook</b> → <b>Webhook-URL kopieren</b> und hier einfügen.`)}\n    ${field("dcU", "Discord-Webhook-URL", dc.url, {type: "password", help: "Beginnt mit https://discord.com/api/webhooks/ – wie ein Passwort behandeln"})}\n    <div class="row"><label>Verbindung testen<small>Schickt eine Testnachricht in deinen Kanal.</small></label><button class="btn" id="dcTest">Testnachricht senden</button></div>\n    ${field("dcE", "Benachrichtigungen an", dc.enabled, {check: true})}\n    <span class="lbl">Was soll ankommen?</span>\n    ${field("dcT", "Einstieg und Ausstieg", dc.trades, {check: true, help: "Mit Preis, Stop, Ziel und Ergebnis in $ und R"})}\n    ${field("dcF", "Fehler", dc.errors, {check: true, help: "z. B. Order abgelehnt, Broker getrennt (gleiche Meldung höchstens alle 30 Min)"})}\n    ${field("dcS", "TradingView schweigt", dc.silence, {check: true, help: "Wenn bei offenem Markt keine Nachricht mehr kommt (Alert abgelaufen oder pausiert)"})}\n    ${field("dcM", "Stille melden nach (Minuten)", dc.silence_min, {attrs: {min: 10, max: 600, step: 5}})}\n    ${field("dcD", "Tages-Stopp", dc.daystop, {check: true})}\n    ${field("dcA", "Tagesabschluss", dc.daily, {check: true, help: "Täglich nach 16 Uhr New York: Trades, Ergebnis, nicht genommene Signale"})}\n    ${field("dcW", "Wochenbericht", dc.weekly, {check: true, help: "Freitags nach Börsenschluss"})}\n    ${field("dcL", "Lernmodul-Änderungen", dc.learn, {check: true, help: "Wenn der Bot selbst etwas umstellt oder eine Strategie pausiert"})}`)}\n\n  ${sec("sess", "Sessions & Vorschläge", r.all_day ? "Ganztägig" + (sessOn.length ? " · " + sessOn.join(" · ") : "") : sessOn.length ? sessOn.join(" · ") : "keine Session angehakt", `<span class="chip ${S.session_open ? "good" : "mute"}">${S.session_open ? "jetzt offen" : "gerade zu"}</span>`, `\n    ${intro("Hak an, in welchen Sessions der Bot handeln darf. Die gleichen Haken gibt es in den Einstellungen der TradingView-Strategie.")}\n    <div class="sess-list">${Object.entries(S.sessions).map(([k, x]) => `<label class="sess ${(r.sessions || {})[k] ? "on" : ""}">\n      <input type="checkbox" class="chk" data-cfg data-sess="${k}" ${(r.sessions || {})[k] ? "checked" : ""}>\n      <span class="sess-n">${esc(x.name)}</span><span class="sess-t mono">${x.start}–${x.end === "00:00" ? "24:00" : x.end} NY</span><span class="sess-t mono hint">${localTime(x.start)}–${localTime(x.end)} bei dir</span></label>`).join("")}</div>\n    ${field("ad", "Ganztägig handeln", r.all_day, {check: true, help: "Handelt zu jeder Uhrzeit, außer in der Marktpause 17–18 Uhr NY und am Wochenende. In TradingView dafür ebenfalls „Ganztägig handeln“ anhaken."})}\n    ${field("es", "Nur in der Handelszeit handeln", r.enforce_session, {check: true})}\n    ${field("fe", "Zum Ende der Session schließen", r.flat_at_session_end, {check: true, help: "Offene Positionen werden geschlossen, wenn ihre Session endet"})}\n    ${field("to", "Vorschlag verfällt nach (Sekunden)", c.suggestion_timeout_sec, {attrs: {min: 15, step: 15}, help: "Gilt, wenn der Auto-Modus aus ist"})}\n    ${field("le", "Lernmodul aktiv", L.enabled, {check: true, help: "Schwache Strategien bekommen halbe Größe oder Pause"})}\n    ${field("la", "Gelerntes selbst umsetzen", L.auto_adopt !== false, {check: true, help: "Bessere Ausstiege und bewährte Regeln übernimmt der Bot jeden Abend selbst – und verwirft sie wieder, wenn sie nicht halten"})}`)}\n\n  ${sec("tv", "TradingView", "Webhook-Adresse, Alert-Nachricht, Strategie-Script", tunChip, `\n    ${S.remote && S.remote.limit ? `<div class="row"><label>Anfragen über ngrok diesen Monat<small>Kostenlos sind ${S.remote.limit.toLocaleString("de-DE")} im Monat. ${S.remote.projection ? `Hochrechnung bis Monatsende: <b class="${S.remote.projection > S.remote.limit ? "neg" : ""}">${S.remote.projection.toLocaleString("de-DE")}</b>. ` : ""}${Object.keys(S.remote.kinds || {}).length ? "Davon " + Object.entries(S.remote.kinds).sort((a, b) => b[1] - a[1]).map(([k, n]) => `${{kerzen: "Kerzen", live: "Live-Kurs im Trade", signale: "Signale", app: "App über Internet (Handy/anderer PC)"}[k] || k} ${n.toLocaleString("de-DE")}`).join(" · ") + ". " : ""}Sparen: im TradingView-Script (Einstellungen der Strategie → Anzeige & Alerts) „Kerzen bündeln“ und „Live-Kurs im Trade: Sparsam“ oder „Aus“. Die App auf diesem PC (localhost) zählt nicht mit.</small></label>\n      <div class="inline"><b class="mono ${S.remote.n > S.remote.limit * 0.8 ? "neg" : ""}">${S.remote.n.toLocaleString("de-DE")}</b><span class="hint">/ ${S.remote.limit.toLocaleString("de-DE")}</span></div></div>` : ""}\n    <div class="row"><label>Internet-Verbindung<small>${c.public_url ? "Eigene Adresse aus „Erweitert“." : S.tunnel.fixed ? "Feste Adresse: bleibt nach Neustarts gleich, der Alert muss nie wieder angepasst werden." : "Die Adresse wechselt bei jedem Neustart. Mit einem ngrok-Schlüssel wird sie fest."}</small></label>\n      <div class="inline">${S.tunnel.ok || c.public_url ? \'<span class="chip good">aktiv</span>\' : `<span class="chip bad" style="white-space:normal;text-align:left;max-width:100%">${esc(S.tunnel.status)}</span>`}\n        <span class="chip ${S.tunnel.fixed || c.public_url ? "good" : "warn"}">${S.tunnel.fixed || c.public_url ? "feste Adresse" : "wechselnde Adresse"}</span></div></div>\n    ${field("ngt", "ngrok-Schlüssel für feste Adresse", (c.tunnel || {}).ngrok_token, {type: "password", help: "Kostenlos: ngrok.com → registrieren → im Dashboard „Your Authtoken“ kopieren und hier einfügen"})}\n    <div><span class="lbl">Webhook-Adresse für den Alert</span><div class="copyrow"><div class="code" id="hook">${esc(S.hook_url || "wird automatisch erzeugt …")}</div><button class="btn" id="cp" ${S.hook_url ? "" : "disabled"}>Kopieren</button></div></div>\n    <div><span class="lbl">Alert-Nachricht</span><div class="copyrow"><div class="code" id="msgTpl">{{strategy.order.alert_message}}</div><button class="btn" id="cp2">Kopieren</button></div></div>\n    <div class="inline wrap-gap"><button class="btn" id="cpPine2">Strategie-Script kopieren</button><button class="btn" id="tL">Test-Signal senden</button><button class="btn" id="tNet">Webhook über Internet testen</button></div>\n    ${intro("„Test-Signal senden“ prüft nur die App selbst. „Webhook über Internet testen“ schickt eine Nachricht über ngrok an die Webhook-Adresse – genau den Weg, den TradingView nimmt.")}`)}\n\n  ${sec("acc", "Konten & Broker", `Bot handelt über ${c.broker === "tradovate" ? "Tradovate" : "Paper-Trading"}${c.own_sync && c.own_sync.tradovate ? " · eigene Trades werden übernommen" : ""}`, accChip, `\n    ${intro("Einmal verbinden: Deine eigenen Trades kommen dann automatisch in den Kalender.")}\n    <div class="row"><label>TradingView<small>TradingView hat keine Schnittstelle für deine Trades. Handelst du in TradingView über Tradovate, kommen die Trades über die Tradovate-Verknüpfung unten.</small></label>\n      <div class="inline"><span class="chip mute">über Tradovate</span></div></div>\n    <span class="lbl">Tradovate ${t.username && t.cid ? (S.own_sync.error ? \'<span class="chip bad">Fehler</span>\' : \'<span class="chip good">hinterlegt</span>\') : \'<span class="chip mute">nicht verbunden</span>\'}</span>\n    ${field("tenv", "Konto", t.env, {select: [["demo", "Demo"], ["live", "Live (echtes Konto)"]]})}\n    ${field("tu", "Benutzername", t.username, {type: "text", attrs: {autocomplete: "off"}})}\n    ${field("tpw", "Passwort", t.password, {type: "password"})}\n    ${field("tcid", "API cid", t.cid, {type: "text", help: "Tradovate → Einstellungen → API-Zugang (API-Add-on nötig)"})}\n    ${field("tsec", "API secret", t.secret, {type: "password"})}\n    ${field("osync", "Eigene Trades automatisch übernehmen", c.own_sync && c.own_sync.tradovate, {check: true, help: "Alle 10 Minuten. Trades des Bots werden erkannt und nicht doppelt gezählt."})}\n    ${S.own_sync.enabled ? `<div class="row"><label>Letzter Abruf<small>${S.own_sync.error ? `<span class="neg">${esc(S.own_sync.error)}</span>` : S.own_sync.last ? `${S.own_sync.added} neue Trades` : "läuft gleich"}</small></label>\n      <div class="inline"><span class="mono">${S.own_sync.last ? dtm(S.own_sync.last) : "–"}</span></div></div>` : ""}\n    <div class="inline wrap-gap"><button class="btn" id="tvTest">Verbindung testen</button>${S.own_sync.enabled ? \'<button class="btn" id="syncNow">Eigene Trades jetzt abrufen</button>\' : ""}</div>\n    <span class="lbl">Bot-Orders</span>\n    ${field("bk", "Der Bot handelt über", c.broker, {select: [["paper", "Paper-Trading (Simulation)"], ["tradovate", "Tradovate-Konto oben"]], help: c.broker === "tradovate" ? `Status: ${esc(S.broker.status || "–")}` : "Empfohlen, bis der Bot sich bewährt hat"})}\n    <div id="ppd" class="sub" ${c.broker === "paper" ? "" : "hidden"}>\n      ${field("pb", "Startkapital Paper ($)", c.paper.start_balance, {attrs: {min: 1000, step: 1000}})}\n      <div class="inline wrap-gap"><button class="btn ghost-danger" id="pr">Paper-Konto zurücksetzen</button></div>\n    </div>`)}\n\n  ${sec("adv", "Erweitert", "Safe-Stop-Grenzen, Lernmodul, Paper, Kontrakte, eigene Adresse", \'<span class="chip mute">nur bei Bedarf</span>\', `\n    <span class="lbl">Safe-Stop-Grenzen (Punkte)</span>\n    ${field("nqmin", "NQ Minimum", ss.NQ.min, {attrs: {step: 0.25, min: 0.25}})}\n    ${field("nqmax", "NQ Maximum", ss.NQ.max, {attrs: {step: 0.25, min: 1}})}\n    ${field("esmin", "ES Minimum", ss.ES.min, {attrs: {step: 0.25, min: 0.25}})}\n    ${field("esmax", "ES Maximum", ss.ES.max, {attrs: {step: 0.25, min: 0.5}})}\n    <span class="lbl">Bot-Verhalten</span>\n    ${field("mo", "Max. gleichzeitige Positionen", r.max_open, {attrs: {min: 1, step: 1}})}\n    ${field("fx", "Exit-Signalen aus TradingView folgen", c.follow_tv_exits, {check: true})}\n    <span class="lbl">Lernmodul</span>\n    ${field("lw", "Auswerten über letzte Trades", L.window, {attrs: {min: 5, max: 500, step: 1}})}\n    ${field("lm", "Mindest-Trades vor Bewertung", L.min_trades, {attrs: {min: 3, step: 1}})}\n    ${field("lh", "Halbe Größe unter Ø R", L.half_below_r, {attrs: {step: 0.05}})}\n    ${field("lp", "Pause unter Ø R", L.pause_below_r, {attrs: {step: 0.05}})}\n    <span class="lbl">Paper-Trading</span>\n    ${field("psl", "Slippage (Ticks)", c.paper.slippage_ticks, {attrs: {min: 0, step: 1}})}\n    ${field("pc", "Gebühr Mini (NQ/ES) pro Kontrakt & Seite ($)", c.paper.commission, {attrs: {min: 0, step: 0.01}, help: "Alles zusammen: Kommission, Börse, Clearing, NFA. Bei Prop-Firmen (z. B. Apex über Tradovate) steht der Wert in deren Hilfe-Center."})}\n    ${field("pcm", "Gebühr Micro (MNQ/MES) pro Kontrakt & Seite ($)", c.paper.commission_micro ?? 0.75, {attrs: {min: 0, step: 0.01}, help: "Gilt auch für den Strategie-Finder und die Session-Ziele"})}\n    <span class="lbl">Tradovate</span>\n    ${field("tacc", "Kontoname", t.account, {type: "text", help: "Leer = erstes Konto. Bei mehreren Konten (z. B. Topstep) den Namen eintragen."})}\n    ${field("cnq", "Kontrakt NQ / MNQ", c.contracts.NQ, {type: "text", attrs: {placeholder: "automatisch"}})}\n    ${field("ces", "Kontrakt ES / MES", c.contracts.ES, {type: "text", attrs: {placeholder: "automatisch"}})}\n    <span class="lbl">Verbindung & Updates</span>\n    ${field("pu", "Eigene feste Adresse", c.public_url, {type: "url", attrs: {placeholder: "leer = automatisch"}, help: "Nur mit ngrok o. Ä."})}\n    <div class="inline wrap-gap"><button class="btn ghost-danger" id="rt">Neue Webhook-Adresse erzeugen</button>\n      <label class="btn" style="cursor:pointer">Update aus Datei<input type="file" id="updFile" accept=".cmd" hidden></label></div>`)}\n  </div>\n  <div class="savebar" id="savebar" hidden><span class="hint" id="saveMsg">Du hast Änderungen.</span><button class="btn" id="discard">Verwerfen</button><button class="btn primary" id="saveAll">Änderungen speichern</button></div>`;\n\n  document.querySelectorAll("details.set-sec").forEach(d => d.ontoggle = () => {\n    d.open ? OPEN.add(d.dataset.sec) : OPEN.delete(d.dataset.sec);\n    try { localStorage.setItem("fvg-open", JSON.stringify([...OPEN])); } catch (e) { /* egal */ }\n  });\n\n  // Änderungen sammeln, eine Speichern-Leiste\n  let mode = sz.mode;\n  const dirty = () => { settingsDirty = true; $("#savebar").hidden = false; };\n  $("#main").oninput = e => { if (e.target.matches("[data-cfg]")) dirty(); };\n  $("#main").onchange = e => { if (e.target.matches("[data-cfg]")) dirty(); };\n  document.querySelectorAll("[data-mode]").forEach(b => b.onclick = () => {\n    mode = b.dataset.mode; document.querySelectorAll("[data-mode]").forEach(x => x.setAttribute("aria-pressed", x === b));\n    $(\'[data-row="fq"]\').hidden = mode !== "fixed"; $(\'[data-row="ru"]\').hidden = mode !== "risk_usd"; $(\'[data-row="rp"]\').hidden = mode !== "risk_pct"; dirty(); });\n  $("#bk").addEventListener("change", () => { $("#ppd").hidden = v("bk") !== "paper"; });\n  $("#discard").onclick = () => { settingsDirty = false; render(true); };\n  const doSave = async () => {\n    const patch = {\n      sizing: {mode, fixed_qty: v("fq"), risk_usd: num("ru"), risk_pct: num("rp"), contract_type: v("ct"), max_qty: v("mq")},\n      safe_stop: {NQ: {default: num("nqd"), min: num("nqmin"), max: num("nqmax")}, ES: {default: num("esd"), min: num("esmin"), max: num("esmax")}, default_rr: num("rr")},\n      risk: {max_daily_loss: num("mdl"), daily_profit_stop: num("dps") ?? 0, daily_stop_close: v("dsc"), max_trades_day: parseInt(v("mtd")), max_open: parseInt(v("mo")), enforce_session: v("es"), all_day: v("ad"), flat_at_session_end: v("fe"),\n        sessions: Object.fromEntries([...document.querySelectorAll("[data-sess]")].map(x => [x.dataset.sess, x.checked]))},\n      auto_update: v("au"),\n      news: {enabled: v("nwE"), before_min: parseInt(v("nwB")), after_min: parseInt(v("nwA")), impact: v("nwI"), usd_only: v("nwU"), close_before: v("nwC")},\n      suggestion_timeout_sec: parseInt(v("to")), follow_tv_exits: v("fx"),\n      learning: {enabled: v("le"), auto_adopt: v("la"), window: v("lw"), min_trades: v("lm"), half_below_r: num("lh"), pause_below_r: num("lp")},\n      broker: v("bk"), public_url: v("pu").trim(),\n      tradovate: {env: v("tenv"), username: v("tu"), password: v("tpw"), cid: v("tcid"), secret: v("tsec"), account: v("tacc")},\n      contracts: {NQ: v("cnq"), MNQ: v("cnq") ? v("cnq").replace(/^NQ/i, "MNQ") : "", ES: v("ces"), MES: v("ces") ? v("ces").replace(/^ES/i, "MES") : ""},\n      paper: {start_balance: num("pb") ?? c.paper.start_balance, slippage_ticks: parseInt(v("psl")), commission: num("pc"), commission_micro: num("pcm")},\n      own_sync: {tradovate: v("osync")},\n      tunnel: {ngrok_token: (v("ngt") || "").trim()},\n      discord: {url: (v("dcU") || "").trim(), enabled: v("dcE"), trades: v("dcT"), errors: v("dcF"), silence: v("dcS"), silence_min: parseInt(v("dcM")) || 30,\n        daystop: v("dcD"), daily: v("dcA"), weekly: v("dcW"), learn: v("dcL")},\n    };\n    await api("/api/config", patch); settingsDirty = false;\n  };\n  $("#saveAll").onclick = async () => {\n    try { await doSave(); toast("Gespeichert"); await refresh(true); }\n    catch (e) { $("#saveMsg").textContent = e.message; $("#saveMsg").className = "err-msg"; }\n  };\n  $("#tvTest").onclick = async () => {\n    try { if (settingsDirty) await doSave(); const r = await api("/api/tradovate/test", {}); toast(r.ok ? r.status : "Fehler: " + r.status); await refresh(true); }\n    catch (e) { toast(e.message); }\n  };\n  const sn = $("#syncNow"); if (sn) sn.onclick = async () => {\n    sn.disabled = true; sn.textContent = "Rufe ab …";\n    try { const r = await api("/api/own/sync", {}); toast(r.ok ? `${r.added} neue eigene Trades übernommen` : "Fehler: " + r.error); } catch (e) { toast(e.message); }\n    await refresh(true);\n  };\n\n  $("#dcTest").onclick = async () => {\n    const b = $("#dcTest"); b.disabled = true; b.textContent = "Sende …";\n    try { await api("/api/discord/test", {url: (v("dcU") || "").trim()}); toast("Testnachricht gesendet – schau in Discord"); } catch (e) { toast(e.message); }\n    b.disabled = false; b.textContent = "Testnachricht senden";\n  };\n  // Protokoll\n  $("#logShow").onclick = showLog;\n  $("#logFolder").onclick = async () => { try { const r = await api("/api/open-folder", {}); toast("Ordner geöffnet: " + r.folder); } catch (e) { toast(e.message); } };\n\n  // Sofort-Aktionen\n  $("#updNowSet").onclick = async () => {\n    const b = $("#updNowSet"); b.disabled = true; b.textContent = "Suche …";\n    try {\n      const u = await api("/api/update/check", {});\n      if (u.available) return runUpdate(() => api("/api/update/apply", {}));\n      toast(u.error && !u.version ? u.error : `Du hast die neueste Version (${S.version})`);\n    } catch (e) { toast(e.message); }\n    b.disabled = false; b.textContent = "Jetzt aktualisieren"; refresh(true);\n  };\n  const mk = $("#mkIcon"); if (mk) mk.onclick = () => act(() => api("/api/shortcut", {}), "Desktop-Symbol angelegt");\n  const sv = $("#svcT");\n  if (sv) sv.onclick = () => {\n    const on = !(S.service || {}).installed;\n    serviceSet(on);\n  };\n  const as = $("#asT"); if (as) as.onclick = () => act(() => api("/api/autostart", {on: !S.autostart}), !S.autostart ? "Startet ab jetzt mit Windows" : "Autostart aus").then(() => render(true));\n  $("#quit").onclick = () => confirmBtn($("#quit"), S.positions.length ? "Positionen offen. Trotzdem?" : "Wirklich beenden?", async () => {\n    try { await api("/api/shutdown", {}); } catch (e) {}\n    document.body.innerHTML = `<div class="login"><form><h1>FVG Trader ist beendet</h1><p class="hint">Signale aus TradingView werden jetzt nicht verarbeitet. Zum Starten auf das Desktop-Symbol <b>FVG Trader</b> klicken.</p><p class="hint">Du kannst dieses Fenster jetzt schließen.</p></form></div>`;\n    setTimeout(() => { try { window.close(); } catch (e) {} }, 600);\n  });\n  $("#cp").onclick = () => copyText(S.hook_url, "Adresse"); $("#cp2").onclick = () => copyText("{{strategy.order.alert_message}}", "Nachricht");\n  $("#cpPine2").onclick = async () => { try { const r = await api("/api/pine"); copyText(r.source, "Script"); } catch (e) { toast(e.message); } };\n  $("#tNet").onclick = async () => { const b = $("#tNet"); b.disabled = true; b.textContent = "Teste …";\n    try { const r = await api("/api/hook/selftest", {}); toast(`Webhook über das Internet erreichbar (${r.ms} ms). Kommt trotzdem nichts an, liegt es am Alert in TradingView.`); }\n    catch (e) { toast(e.message); }\n    b.disabled = false; b.textContent = "Webhook über Internet testen"; };\n  $("#tL").onclick = () => act(() => api("/api/test-signal", {fam: "NQ", side: "long"}).then(r => { TAB = "cockpit"; setHash("cockpit"); return r; }), "Test-Signal gesendet");\n  const pr = $("#pr"); if (pr) pr.onclick = () => confirmBtn(pr, "Alle Paper-Trades löschen?", () => act(() => api("/api/paper/reset", {}), "Paper-Konto zurückgesetzt").then(() => render(true)));\n  const cpPhone = $("#cpPhone"); if (cpPhone) cpPhone.onclick = () => copyText(phoneUrl, "Adresse");\n  $("#rt").onclick = () => confirmBtn($("#rt"), "Alte Adresse wird ungültig. Sicher?", () => act(() => api("/api/token", {}), "Neue Adresse erzeugt: im TradingView-Alert ersetzen").then(() => render(true)));\n  $("#updFile").onchange = e => { const f = e.target.files[0]; if (!f) return;\n    runUpdate(async () => { const r = await fetch("/api/update/upload", {method: "POST", headers: {"X-Requested-With": "fvg"}, body: f});\n      const j = await r.json().catch(() => ({})); if (!r.ok) throw new Error(j.error || "Update fehlgeschlagen"); return j; }); };\n}\n\nasync function showLog() {\n  let r;\n  try { r = await api("/api/log"); } catch (e) { toast(e.message); return; }\n  let view = "log";\n  const text = () => view === "log" ? (r.log.length ? r.log.join("\\n") : "(noch keine Einträge)") : (r.events.join("\\n") || "(keine Aktivität)");\n  const close = modal(`<div class="section-h"><h2 style="font-size:18px">Protokoll · Version ${esc(r.version)}</h2>\n      <div class="seg" role="group" aria-label="Ansicht"><button type="button" data-v="log" aria-pressed="true">App-Log</button><button type="button" data-v="ev" aria-pressed="false">Aktivität</button></div></div>\n    <pre class="code logbox" id="logTxt"></pre>\n    <p class="hint" style="margin:0;word-break:break-all">Datei: ${esc(r.path)}</p>\n    <div class="actions"><button class="btn primary" id="logCopy">Alles kopieren</button><button class="btn" id="logClose">Schließen</button></div>`);\n  const fill = () => { $("#logTxt").textContent = text(); $("#logTxt").scrollTop = $("#logTxt").scrollHeight; };\n  document.querySelectorAll("#mdl [data-v]").forEach(b => b.onclick = () => { view = b.dataset.v === "log" ? "log" : "ev";\n    document.querySelectorAll("#mdl [data-v]").forEach(x => x.setAttribute("aria-pressed", x === b)); fill(); });\n  fill();\n  $("#logCopy").onclick = () => copyText(`FVG Trader ${r.version}\\n--- App-Log ---\\n${r.log.slice(-120).join("\\n")}\\n--- Aktivität ---\\n${r.events.slice(-60).join("\\n")}`, "Protokoll");\n  $("#logClose").onclick = close;\n}\n\n/* ───────── Nur ein Fenster ───────── */\n// Wird FVG Trader ein zweites Mal geöffnet, übernimmt das neue Fenster; das alte schließt sich oder wird gesperrt.\nconst WIN_ID = Math.random().toString(36).slice(2);\nlet BLOCKED = false;\nconst BC = "BroadcastChannel" in window ? new BroadcastChannel("fvg-trader-fenster") : null;\nfunction claimWindow() { BLOCKED = false; const o = $("#winBlock"); if (o) o.remove(); if (BC) BC.postMessage({t: "claim", id: WIN_ID}); }\nfunction blockWindow() {\n  if (BLOCKED) return;\n  BLOCKED = true;\n  try { window.close(); } catch (e) {}\n  document.body.insertAdjacentHTML("beforeend", `<div id="winBlock" style="position:fixed;inset:0;z-index:60;background:var(--bg);display:grid;place-items:center;padding:16px">\n    <div class="panel" style="max-width:380px;display:flex;flex-direction:column;gap:12px;text-align:center">\n      <h2 style="font-size:19px">In einem anderen Fenster geöffnet</h2>\n      <p class="hint" style="margin:0">FVG Trader läuft schon in einem anderen Fenster. Du kannst dieses hier schließen.</p>\n      <button class="btn primary" id="winHere">Hier weiterverwenden</button></div></div>`);\n  $("#winHere").onclick = () => { claimWindow(); refresh(true); };\n}\nif (BC) BC.onmessage = e => { if (e.data && e.data.t === "claim" && e.data.id !== WIN_ID) blockWindow(); };\n\n/* ───────── Laufzeit ───────── */\n/* Einblenden: neue Blöcke einer Seite kommen gestaffelt weich herein (nur direkt nach dem Seitenwechsel) */\nconst ANIM = {until: 0, seen: new Set(), i: 0};\nconst ANIM_HOSTS = ["main", "#ck", "#stWrap", "#stBody", "#lnWrap", "#lnBody", "#chWrap", "#chLive", "#calWrap"];\nfunction animOpen() { ANIM.until = Date.now() + 2600; ANIM.seen = new Set(); ANIM.i = 0; }\nfunction animEl(el, host) {\n  if (!(el instanceof HTMLElement) || Date.now() > ANIM.until) return;\n  if (getComputedStyle(el).display === "contents") { [...el.children].forEach(c => animEl(c, el)); return; }\n  if (el.hidden || el.tagName === "SCRIPT") return;\n  const key = TAB + "|" + (host && (host.id || host.tagName)) + "|" + [...el.parentNode.children].indexOf(el) + "|" + el.tagName + "." + el.className + "#" + el.id;\n  if (ANIM.seen.has(key)) return;\n  ANIM.seen.add(key);\n  el.style.setProperty("--i", Math.min(ANIM.i++, 8));\n  el.classList.remove("in"); void el.offsetWidth; el.classList.add("in");\n  el.addEventListener("animationend", function done(e) { if (e.target === el) { el.classList.remove("in"); el.style.removeProperty("--i"); el.removeEventListener("animationend", done); } });\n}\nconst ANIM_MO = typeof MutationObserver === "function" ? new MutationObserver(list => {\n  if (Date.now() > ANIM.until) return;\n  for (const m of list) m.addedNodes.forEach(n => animEl(n, m.target));\n  animWatch();\n}) : null;\nfunction animWatch() {\n  if (!ANIM_MO) return;\n  ANIM_HOSTS.forEach(sel => { const h = sel === "main" ? $("#main") : $(sel); if (h && !h._obs) { h._obs = 1; ANIM_MO.observe(h, {childList: true}); } });\n}\nfunction render(full) {\n  if (!S) return;\n  if (full && TAB !== "settings" && $("#main")) { $("#main").oninput = null; $("#main").onchange = null; }\n  if (full) { animOpen(); animWatch(); }\n  pageHead(full);\n  header();\n  const ct = $(".content"); if (ct) ct.classList.toggle("wide", TAB === "chart");\n  document.querySelectorAll("[data-tab]").forEach(x => x.setAttribute("aria-current", x.dataset.tab === TAB));\n  document.title = "FVG Trader · " + (NAV.find(n => n[0] === TAB) || NAV[0])[1];\n  if (TAB === "cockpit") cockpit(full);\n  else if (full) ({calendar, stats, learn, settings, challenge, chart: chartPage}[TAB])();\n  else if (TAB === "chart") {}\n  else if (TAB === "challenge") challenge(false);\n  else if (TAB === "settings" && !settingsDirty && !document.activeElement.matches("input,select")) {\n    // Status-Anzeigen live nachziehen (Verbindung, Broker, Updates, Abruf), ohne Eingaben zu stören\n    const key = JSON.stringify([S.tunnel, S.hook_url, S.broker, S.update, S.own_sync && S.own_sync.last, S.own_sync && S.own_sync.error, S.autostart, S.service]);\n    if (key !== settingsKey) { const y = scrollY; settings(); scrollTo(0, y); }\n  }\n  else if ((TAB === "stats" || TAB === "learn" || TAB === "calendar") && Date.now() > ANIM.until) ({calendar, stats, learn}[TAB])();\n  navInd();\n  if (full) animWatch();\n}\nasync function refresh(full) {\n  S = await api("/api/state");\n  notifyNew();\n  render(full);\n}\nfunction notifyNew() {\n  const ids = S.pending.map(p => p.id), fresh = ids.filter(id => !seenPending.has(id));\n  ids.forEach(id => seenPending.add(id));\n  if (firstLoad) { firstLoad = false; return; }\n  if (!fresh.length) return;\n  const p = S.pending.find(x => x.id === fresh[0]);\n  document.title = "● Neuer Vorschlag · FVG Trader";\n  setTimeout(() => document.title = "FVG Trader", 8000);\n  try { const a = new AudioContext(), o = a.createOscillator(), g = a.createGain(); o.frequency.value = 880; g.gain.value = .08; o.connect(g).connect(a.destination); o.start(); o.stop(a.currentTime + .18); } catch (e) {}\n  if ("Notification" in window && Notification.permission === "granted")\n    new Notification("Neuer Trade-Vorschlag", {body: `${p.side === "long" ? "LONG" : "SHORT"} ${p.qty}× ${p.root} · ${p.setup} · Stop ${px(p.sl)}`});\n}\nasync function start() {\n  TAB = ["cockpit", "chart", "calendar", "stats", "challenge", "learn", "settings"].includes(location.hash.slice(1)) ? location.hash.slice(1) : "cockpit";\n  shell();\n  if ("Notification" in window && Notification.permission === "default") document.addEventListener("click", () => Notification.requestPermission(), {once: true});\n  try { await refresh(true); } catch (e) { return; }\n  startupUpdatePrompt();\n  claimWindow();\n  // Über die Internet-Adresse (Handy) seltener abfragen: ngrok kostenlos erlaubt 20.000 Anfragen im Monat,\n  // und die braucht vor allem TradingView. Im Hintergrund (Tab nicht sichtbar) gar nicht abfragen.\n  const REMOTE_UI = !["localhost", "127.0.0.1", "[::1]"].includes(location.hostname);\n  let lastPoll = Date.now();\n  const poll = async force => {\n    if (BLOCKED || document.hidden) return;\n    if (TAB === "settings" && settingsDirty) return;\n    const every = REMOTE_UI ? (S && S.positions && S.positions.length ? 10000 : 30000) : 2000;\n    if (!force && Date.now() - lastPoll < every) return;\n    lastPoll = Date.now();\n    try { await refresh(false); } catch (e) {}\n  };\n  setInterval(() => poll(false), 1000);\n  document.addEventListener("visibilitychange", () => { if (!document.hidden) poll(true); });\n  setInterval(() => !BLOCKED && S && TAB === "cockpit" && timers(), 1000);\n}\nfetch("/api/auth").then(r => r.json()).then(a => a.logged_in ? start() : showLogin());\nif ("serviceWorker" in navigator) navigator.serviceWorker.register("/sw.js").catch(() => {});\n</script>\n</body>\n</html>\n'

PINE_SOURCE = '// This Pine Script® code is subject to the terms of the Mozilla Public License 2.0\n// Multi-Strategie Futures-Bot für NQ & ES (auch MNQ / MES)\n// Strategien: FVG, inverse FVG, Silver Bullet (FVG 10–11 NY), Opening Range Breakout, Liquidity Sweep (Vortag), VWAP-Reclaim\n// Verbindung zur FVG-Trader-App: Alert mit „Orderausführungen und alert()-Aufrufe“, Webhook = App-URL\n// Script-Version 2.11 (spart ngrok-Anfragen: Kerzen gebündelt, Live-Kurs sparsam)\n// Chart: NQ1! oder ES1!, Timeframe 5m (empfohlen) oder 1m/3m\n// Auto-Trading: Alert auf diese Strategie, Nachricht = {{strategy.order.alert_message}}, Webhook-URL deines Brokers/Connectors\n//@version=6\nstrategy("FVG Bot · Multi-Strategie [NQ·ES]", shorttitle = "FVG Bot", overlay = true,\n     initial_capital = 50000, default_qty_type = strategy.fixed, default_qty_value = 1,\n     commission_type = strategy.commission.cash_per_contract, commission_value = 2.25,\n     slippage = 1, pyramiding = 0, max_boxes_count = 400, max_labels_count = 100,\n     calc_on_every_tick = true, process_orders_on_close = false, margin_long = 0, margin_short = 0)\n// margin_long/short = 0: Futures brauchen nur eine kleine Sicherheitsleistung. Mit TradingViews Standard (100 % des Kontraktwerts)\n// würde z. B. 1 MNQ bei 28.000 Punkten (56.000 $) bei 50.000 $ Startkapital abgelehnt und es gäbe weder Trades noch Signale.\n// calc_on_every_tick: nur für den Live-Kurs an die App. Alle Handelsentscheidungen fallen weiter erst zum Kerzenschluss (barstate.isconfirmed).\n\n// ───────────────────────── Inputs ─────────────────────────\ngrpSetup = "① Setup"\nuseFVG      = input.bool(true,  "FVG-Retest handeln",                     group = grpSetup)\nuseIFVG     = input.bool(true,  "Inverse FVG (iFVG) handeln",             group = grpSetup)\nminGapAtr   = input.float(0.15, "Min. Gap-Größe (× ATR)", minval = 0, step = 0.05, group = grpSetup)\natrLen      = input.int(14,     "ATR-Länge", minval = 1,                  group = grpSetup)\nmaxAge      = input.int(60,     "Max. Alter einer Zone (Bars)", minval = 5, group = grpSetup)\nmaxZones    = input.int(20,     "Max. aktive Zonen", minval = 2, maxval = 100, group = grpSetup)\nneedConfirm = input.bool(true,  "Bestätigungskerze (Close über/unter Zonenmitte)", group = grpSetup)\n\ngrpStrat = "① b Weitere Strategien"\nuseSB       = input.bool(true,  "Silver Bullet (FVG im Fenster 10–11 NY)", group = grpStrat)\nsbWin       = input.session("1000-1100", "Silver-Bullet-Fenster",          group = grpStrat)\nuseORB      = input.bool(true,  "Opening Range Breakout",                  group = grpStrat)\norWin       = input.session("0930-0945", "Opening Range",                  group = grpStrat)\norbLastMin  = input.int(11 * 60, "ORB nur bis (Minute NY, 660 = 11:00)", minval = 0, maxval = 1439, group = grpStrat)\nuseSweep    = input.bool(true,  "Liquidity Sweep Vortageshoch/-tief",      group = grpStrat)\nuseVWAP     = input.bool(true,  "VWAP-Reclaim",                            group = grpStrat)\nvwapLook    = input.int(6,      "VWAP: Kerzen vorher auf der anderen Seite", minval = 2, group = grpStrat)\n\ngrpRisk = "② Risiko"\nrr          = input.float(2.0,  "Ziel (R-Vielfaches)", minval = 0.5, step = 0.25, group = grpRisk)\nslBufTicks  = input.int(4,      "Stop-Puffer (Ticks)", minval = 0,        group = grpRisk)\nminRiskTk   = input.int(8,      "Min. Stop-Abstand (Ticks)", minval = 1,  group = grpRisk)\nmaxRiskAtr  = input.float(3.0,  "Max. Stop-Abstand (× ATR)", minval = 0.5, step = 0.25, group = grpRisk)\nsizing      = input.string("Feste Kontrakte", "Positionsgröße", options = ["Feste Kontrakte", "Risiko in $"], group = grpRisk)\nfixedQty    = input.int(1,      "Kontrakte (fest)", minval = 1,           group = grpRisk)\nriskUsd     = input.float(500,  "Risiko pro Trade ($)", minval = 10,      group = grpRisk)\nmaxQty      = input.int(5,      "Max. Kontrakte", minval = 1,             group = grpRisk)\nuseBE       = input.bool(false, "Stop auf Break-even ab 1R",              group = grpRisk)\nmaxTradesDay= input.int(10,     "Max. Trades pro Tag", minval = 1,        group = grpRisk)\nmaxDayLoss  = input.float(1000, "Tagesverlust-Limit ($, 0 = aus)", minval = 0, group = grpRisk)\n\ngrpTime = "③ Sessions (New Yorker Zeit)"\nuseAllDay   = input.bool(false, "Ganztägig handeln (immer, außer Marktpause 17–18 Uhr)", group = grpTime)\nuseAsia     = input.bool(false, "Asien 20:00–24:00",                      group = grpTime)\nuseLondon   = input.bool(false, "London 02:00–05:00",                     group = grpTime)\nuseNyAm     = input.bool(true,  "New York Vormittag 09:30–11:30",         group = grpTime)\nuseNyLunch  = input.bool(false, "New York Mittag 11:30–13:30",            group = grpTime)\nuseNyPm     = input.bool(true,  "New York Nachmittag 13:30–15:50",        group = grpTime)\nflatEnd     = input.bool(true,  "Außerhalb der Sessions alles schließen", group = grpTime)\n\ngrpBias = "④ Trendfilter"\nuseBias     = input.bool(true,  "Nur mit HTF-Trend handeln",              group = grpBias)\nbiasTf      = input.timeframe("60", "Bias-Timeframe",                     group = grpBias)\nbiasLen     = input.int(50,     "Bias-EMA-Länge", minval = 2,             group = grpBias)\n\ngrpNews = "⑤ News-Filter"\nblockFomc   = input.string("Ab 13:45 NY", "FOMC-Tage",  options = ["Ganzer Tag", "Ab 13:45 NY", "Ignorieren"], group = grpNews)\nblockCpi    = input.string("Bis 10:00 NY", "CPI-Tage",  options = ["Ganzer Tag", "Bis 10:00 NY", "Ignorieren"], group = grpNews)\nblockNfp    = input.string("Bis 10:00 NY", "NFP-Tage",  options = ["Ganzer Tag", "Bis 10:00 NY", "Ignorieren"], group = grpNews)\nblock10     = input.bool(true,  "10:00-Daten sperren (09:50–10:10 NY)",   group = grpNews)\ncustomDates = input.string("",  "Eigene Sperrtage (JJJJMMTT, kommagetrennt)", group = grpNews)\n\ngrpVis = "⑥ Anzeige & Alerts"\nshowZones   = input.bool(true,  "Zonen zeichnen",                         group = grpVis)\nshowEma     = input.bool(true,  "Bias-EMA zeichnen",                      group = grpVis)\nshowDash    = input.bool(true,  "Dashboard anzeigen",                     group = grpVis)\ndashPosStr  = input.string("Oben rechts", "Dashboard-Position", options = ["Oben rechts", "Oben links", "Unten rechts", "Unten links"], group = grpVis)\nwhSymbol    = input.string("",  "Webhook-Symbol (leer = Chart-Symbol)",   group = grpVis)\nsendBars    = input.bool(true,  "Kerzen-Daten an die App senden (Paper-Trading & Lernmodul)", group = grpVis)\nbarBundle   = input.int(3,      "Ohne offenen Trade Kerzen bündeln (1 = jede Kerze einzeln)", minval = 1, maxval = 6, group = grpVis,\n     tooltip = "Spart ngrok-Anfragen: Ohne offenen Trade gehen z. B. 3 Kerzen zusammen in einer Nachricht (alle 15 Min statt alle 5 Min). Im Trade wird jede Kerze sofort geschickt.")\ntickMode    = input.string("Sparsam", "Live-Kurs im Trade", options = ["Aus", "Sparsam", "Normal"], group = grpVis,\n     tooltip = "Sparsam: höchstens alle 60 s und nur, wenn sich der Kurs spürbar bewegt hat oder Stop/Ziel nahe ist. Normal: alle … Sekunden (unten). Stop und Ziel prüft die App unabhängig davon minutengenau.")\ntickSec     = input.int(20,     "Live-Kurs „Normal“ alle … Sekunden (TradingView erlaubt max. 15 Alarme in 3 Min)", minval = 15, maxval = 120, group = grpVis)\n\n// ───────────────────────── Farben ─────────────────────────\ncBull  = #26a69a\ncBear  = #ef5350\ncIBull = #2962ff\ncIBear = #ff9800\ncMuted = #9598a1\n\n// ───────────────────────── Zeit & Kalender ─────────────────────────\nTZ    = "America/New_York"\nnyMin = hour(time, TZ) * 60 + minute(time, TZ)\ndKey  = year(time, TZ) * 10000 + month(time, TZ) * 100 + dayofmonth(time, TZ)\nnewDay = ta.change(dKey) != 0\n\nvar array<int> FOMC = array.from(\n     20240131, 20240320, 20240501, 20240612, 20240731, 20240918, 20241107, 20241218,\n     20250129, 20250319, 20250507, 20250618, 20250730, 20250917, 20251029, 20251210,\n     20260128, 20260318, 20260429, 20260617, 20260729, 20260916, 20261028, 20261209,\n     20270127, 20270317, 20270428, 20270609, 20270728, 20270915, 20271027, 20271208)\n\nvar array<int> CPI = array.from(\n     20240111, 20240213, 20240312, 20240410, 20240515, 20240612, 20240711, 20240814, 20240911, 20241010, 20241113, 20241211,\n     20250115, 20250212, 20250312, 20250410, 20250513, 20250611, 20250715, 20250812, 20250911, 20251024, 20251218,\n     20260113, 20260213, 20260311, 20260410, 20260512, 20260610, 20260714, 20260812, 20260911, 20261014, 20261110, 20261210,\n     20270113, 20270211, 20270310, 20270413, 20270512, 20270610, 20270714, 20270811, 20270914, 20271014, 20271110, 20271210)\n\n// Arbeitsmarktbericht: Regel = 1. Freitag im Monat; Sondertermine (Shutdown 2025 etc.) hier\nvar array<int> NFP_EXTRA = array.from(20251120, 20251216, 20260109)\nvar array<int> NFP_SKIP  = array.from(20251003, 20251107)\n\nvar array<int> CUSTOM = array.new<int>()\nif barstate.isfirst and str.length(customDates) > 0\n    for p in str.split(customDates, ",")\n        float v = str.tonumber(str.replace_all(p, " ", ""))\n        if not na(v)\n            CUSTOM.push(int(v))\n\nisFomc   = FOMC.includes(dKey)\nisCpi    = CPI.includes(dKey)\nisNfp    = (dayofweek(time, TZ) == dayofweek.friday and dayofmonth(time, TZ) <= 7 and not NFP_SKIP.includes(dKey)) or NFP_EXTRA.includes(dKey)\nisCustom = CUSTOM.includes(dKey)\n\nvar string newsReason = "frei"\nnewsBlock = false\nnewsReason := "frei"\nif isCustom\n    newsBlock := true\n    newsReason := "Eigener Sperrtag"\nif isFomc and blockFomc != "Ignorieren" and (blockFomc == "Ganzer Tag" or nyMin >= 13 * 60 + 45)\n    newsBlock := true\n    newsReason := "FOMC"\nif isCpi and blockCpi != "Ignorieren" and (blockCpi == "Ganzer Tag" or nyMin < 10 * 60)\n    newsBlock := true\n    newsReason := "CPI"\nif isNfp and blockNfp != "Ignorieren" and (blockNfp == "Ganzer Tag" or nyMin < 10 * 60)\n    newsBlock := true\n    newsReason := "NFP"\nif block10 and nyMin >= 9 * 60 + 50 and nyMin < 10 * 60 + 10\n    newsBlock := true\n    newsReason := "10:00-Daten"\n\ninAsia   = useAsia    and not na(time(timeframe.period, "2000-2359", TZ))\ninLondon = useLondon  and not na(time(timeframe.period, "0200-0500", TZ))\ninNyAm   = useNyAm    and not na(time(timeframe.period, "0930-1130", TZ))\ninNyLun  = useNyLunch and not na(time(timeframe.period, "1130-1330", TZ))\ninNyPm   = useNyPm    and not na(time(timeframe.period, "1330-1550", TZ))\ninAllDay = useAllDay and na(time(timeframe.period, "1700-1800", TZ))\ninSess   = inAllDay or inAsia or inLondon or inNyAm or inNyLun or inNyPm\n\n// ───────────────────────── Indikatoren ─────────────────────────\natr    = ta.atr(atrLen)\nhtfEma = request.security(syminfo.tickerid, biasTf, ta.ema(close, biasLen)[1], lookahead = barmerge.lookahead_on)\nbiasL  = not useBias or close > htfEma\nbiasS  = not useBias or close < htfEma\nplot(showEma and useBias ? htfEma : na, "Bias-EMA", color = color.new(cMuted, 20), linewidth = 2)\n\n[pdh, pdl] = request.security(syminfo.tickerid, "D", [high[1], low[1]], lookahead = barmerge.lookahead_on)\nvw   = ta.vwap(hlc3)\ninSB = not na(time(timeframe.period, sbWin, TZ))\ninOR = not na(time(timeframe.period, orWin, TZ))\nvar float orH = na\nvar float orL = na\nif inOR and not inOR[1]\n    orH := high\n    orL := low\nelse if inOR\n    orH := math.max(orH, high)\n    orL := math.min(orL, low)\norReady = not inOR and not na(orH) and dayofmonth(time, TZ) == dayofmonth(time[1], TZ)\nplot(useVWAP ? vw : na, "VWAP", color = color.new(cIBull, 40))\nplot(useSweep ? pdh : na, "Vortageshoch", color = color.new(cBear, 50), style = plot.style_stepline)\nplot(useSweep ? pdl : na, "Vortagestief", color = color.new(cBull, 50), style = plot.style_stepline)\nplot(useORB and orReady ? orH : na, "OR-Hoch", color = color.new(cIBear, 30), style = plot.style_linebr)\nplot(useORB and orReady ? orL : na, "OR-Tief", color = color.new(cIBear, 30), style = plot.style_linebr)\n\n// ───────────────────────── Zonen ─────────────────────────\ntype Zone\n    float top\n    float bottom\n    int   dir\n    bool  inverse = false\n    int   born\n    bool  used = false\n    box   bx\n\nvar array<Zone> zones = array.new<Zone>()\n\nzoneColor(Zone z) =>\n    z.inverse ? (z.dir == 1 ? cIBull : cIBear) : (z.dir == 1 ? cBull : cBear)\n\ncloseBox(Zone z) =>\n    if not na(z.bx)\n        z.bx.set_right(bar_index)\n        z.bx.set_bgcolor(color.new(zoneColor(z), 94))\n        z.bx.set_border_color(color.new(zoneColor(z), 85))\n\naddZone(float t, float b, int d) =>\n    Zone z = Zone.new(top = t, bottom = b, dir = d, born = bar_index)\n    if showZones\n        c = zoneColor(z)\n        z.bx := box.new(bar_index - 2, t, bar_index + 1, b, border_color = color.new(c, 55), bgcolor = color.new(c, 82))\n    zones.push(z)\n    if zones.size() > maxZones\n        closeBox(zones.shift())\n\n// Neue Gaps erkennen (Kerzen [2] und [0] überlappen nicht)\nminGap = math.max(minGapAtr * atr, syminfo.mintick * 2)\nif bar_index > 2\n    if low > high[2] and low - high[2] >= minGap\n        addZone(low, high[2], 1)\n    if high < low[2] and low[2] - high >= minGap\n        addZone(low[2], high, -1)\n\n// Zonen pflegen: Invalidierung → Flip zu iFVG, Alter, Ausdehnung\nif zones.size() > 0\n    for i = zones.size() - 1 to 0\n        Zone z = zones.get(i)\n        bool remove = false\n        if z.born < bar_index\n            if bar_index - z.born > maxAge\n                remove := true\n            else if not z.inverse\n                if (z.dir == 1 and close < z.bottom) or (z.dir == -1 and close > z.top)\n                    if useIFVG\n                        closeBox(z)\n                        z.dir     := -z.dir\n                        z.inverse := true\n                        z.born    := bar_index\n                        z.used    := false\n                        if showZones\n                            c = zoneColor(z)\n                            z.bx := box.new(bar_index, z.top, bar_index + 1, z.bottom, border_color = color.new(c, 55), bgcolor = color.new(c, 82))\n                    else\n                        remove := true\n            else\n                if (z.dir == 1 and close < z.bottom) or (z.dir == -1 and close > z.top)\n                    remove := true\n        if remove\n            closeBox(z)\n            zones.remove(i)\n        else if not na(z.bx)\n            z.bx.set_right(bar_index + 1)\n\n// ───────────────────────── Tages-Risiko ─────────────────────────\nvar float dayStart    = 0.0\nvar int   tradesToday = 0\nvar bool  doneOrbL = false\nvar bool  doneOrbS = false\nvar bool  doneSwL  = false\nvar bool  doneSwS  = false\nif newDay\n    dayStart    := strategy.netprofit\n    tradesToday := 0\n    doneOrbL    := false\n    doneOrbS    := false\n    doneSwL     := false\n    doneSwS     := false\ndayPnl  = strategy.netprofit + strategy.openprofit - dayStart\nlossHit = maxDayLoss > 0 and dayPnl <= -maxDayLoss\n\n// ───────────────────────── Webhook-JSON ─────────────────────────\nsym = whSymbol == "" ? syminfo.ticker : whSymbol\njsonEntry(string action, int qty, float sl, float tp, string setup) =>\n    \'{"type":"entry","ticker":"\' + sym + \'","action":"\' + action + \'","setup":"\' + setup + \'","time":\' + str.tostring(time) +\n     \',"quantity":\' + str.tostring(qty) +\n     \',"price":\' + str.tostring(close, format.mintick) +\n     \',"stopLoss":{"type":"stop","stopPrice":\' + str.tostring(sl, format.mintick) + \'}\' +\n     \',"takeProfit":{"limitPrice":\' + str.tostring(tp, format.mintick) + \'}}\'\njsonExit(string setup) =>\n    \'{"type":"exit","ticker":"\' + sym + \'","action":"exit","setup":"\' + setup + \'","price":\' + str.tostring(close, format.mintick) + \'}\'\n\n// ───────────────────────── Einstieg ─────────────────────────\nvar float tSL   = na\nvar float tTP   = na\nvar float tRisk = na\nvar string tId  = ""\nvar bool  beDone = false\n\ncanTrade = inSess and not newsBlock and not lossHit and tradesToday < maxTradesDay and strategy.position_size == 0\n\n// ta-Funktionen global berechnen (nicht in if-Blöcken)\nbool  wasBelow = ta.highest(close - vw, vwapLook)[1] < 0\nbool  wasAbove = ta.lowest(close - vw, vwapLook)[1] > 0\nfloat swingLo  = ta.lowest(low, 5)\nfloat swingHi  = ta.highest(high, 5)\n\n// Kandidaten in fester Reihenfolge prüfen, der erste gültige wird gehandelt\nbool   sigOn   = false\nbool   sigLong = false\nfloat  sigSL   = na\nstring sigName = ""\nfloat  maxRisk = maxRiskAtr * atr\nfloat  minRisk = minRiskTk * syminfo.mintick\nfloat  buf     = slBufTicks * syminfo.mintick\n\nif canTrade and zones.size() > 0\n    for i = zones.size() - 1 to 0\n        Zone z = zones.get(i)\n        bool allowed = z.inverse ? useIFVG : (useFVG or (useSB and inSB))\n        if not sigOn and allowed and not z.used and z.born < bar_index\n            float mid = math.avg(z.top, z.bottom)\n            bool longSig  = z.dir == 1  and biasL and low  <= z.top    and close > z.bottom and (not needConfirm or (close > open and close >= mid))\n            bool shortSig = z.dir == -1 and biasS and high >= z.bottom and close < z.top    and (not needConfirm or (close < open and close <= mid))\n            if longSig or shortSig\n                float sl = longSig ? math.min(z.bottom, low) - buf : math.max(z.top, high) + buf\n                float risk = math.abs(close - sl)\n                if risk >= minRisk and risk <= maxRisk\n                    sigOn   := true\n                    sigLong := longSig\n                    sigSL   := sl\n                    sigName := z.inverse ? "iFVG" : (useSB and inSB) ? "Silver Bullet" : "FVG"\n                    z.used  := true\n\nif canTrade and not sigOn and useSweep and not na(pdh)\n    if not doneSwL and biasL and low < pdl and close > pdl and close > open\n        sigOn   := true\n        sigLong := true\n        sigSL   := low - buf\n        sigName := "Sweep"\n        doneSwL := true\n    else if not doneSwS and biasS and high > pdh and close < pdh and close < open\n        sigOn   := true\n        sigLong := false\n        sigSL   := high + buf\n        sigName := "Sweep"\n        doneSwS := true\n\nif canTrade and not sigOn and useORB and orReady and nyMin < orbLastMin\n    float orMid = math.avg(orH, orL)\n    if not doneOrbL and biasL and close > orH and close[1] <= orH\n        sigOn    := true\n        sigLong  := true\n        sigSL    := math.max(orMid, close - maxRisk) - buf\n        sigName  := "ORB"\n        doneOrbL := true\n    else if not doneOrbS and biasS and close < orL and close[1] >= orL\n        sigOn    := true\n        sigLong  := false\n        sigSL    := math.min(orMid, close + maxRisk) + buf\n        sigName  := "ORB"\n        doneOrbS := true\n\nif canTrade and not sigOn and useVWAP\n    if biasL and wasBelow and close > vw and close > open\n        sigOn   := true\n        sigLong := true\n        sigSL   := swingLo - buf\n        sigName := "VWAP"\n    else if biasS and wasAbove and close < vw and close < open\n        sigOn   := true\n        sigLong := false\n        sigSL   := swingHi + buf\n        sigName := "VWAP"\n\nif sigOn and barstate.isconfirmed\n    float risk = math.abs(close - sigSL)\n    if risk >= minRisk and risk <= maxRisk\n        float tp  = sigLong ? close + rr * risk : close - rr * risk\n        int qty   = sizing == "Feste Kontrakte" ? fixedQty : math.max(1, math.min(maxQty, int(math.floor(riskUsd / (risk * syminfo.pointvalue)))))\n        string id = sigName + (sigLong ? " Long" : " Short")\n        strategy.entry(id, sigLong ? strategy.long : strategy.short, qty = qty, alert_message = jsonEntry(sigLong ? "buy" : "sell", qty, sigSL, tp, id))\n        strategy.exit("Exit " + id, from_entry = id, stop = sigSL, limit = tp, alert_message = jsonExit(id))\n        tSL         := sigSL\n        tTP         := tp\n        tRisk       := risk\n        tId         := id\n        beDone      := false\n        tradesToday += 1\n\n// Break-even\nif useBE and not beDone and strategy.position_size != 0 and barstate.isconfirmed\n    float ep = strategy.position_avg_price\n    if (strategy.position_size > 0 and high >= ep + tRisk) or (strategy.position_size < 0 and low <= ep - tRisk)\n        tSL    := ep\n        beDone := true\n        strategy.exit("Exit " + tId, from_entry = tId, stop = tSL, limit = tTP, alert_message = jsonExit(tId))\n\n// Flat zum Sessionende, vor FOMC und bei Tageslimit\nif strategy.position_size != 0 and barstate.isconfirmed\n    if flatEnd and not inSess\n        strategy.close_all(comment = "Sessionende", alert_message = jsonExit(""))\n    else if isFomc and blockFomc != "Ignorieren" and nyMin >= 13 * 60 + 50\n        strategy.close_all(comment = "FOMC", alert_message = jsonExit(""))\n    else if lossHit\n        strategy.close_all(comment = "Tageslimit", alert_message = jsonExit(""))\n\nplot(strategy.position_size != 0 ? tSL : na, "Stop",   color = cBear, style = plot.style_linebr)\nplot(strategy.position_size != 0 ? tTP : na, "Target", color = cBull, style = plot.style_linebr)\nbgcolor(inSess and newsBlock ? color.new(cIBear, 88) : na, title = "News-Sperre")\n\n// Kerzen-Daten für die App (Paper-Trading prüft damit Stop/Ziel, das Lernmodul die Schatten-Trades,\n// der Live-Chart zeigt sie). Zusätzlich gehen die 1-Minuten-Kerzen innerhalb der Chart-Kerze mit.\nltf1 = timeframe.in_seconds() >= 60 ? "1" : timeframe.period   // nie höher als der Chart, sonst Laufzeitfehler\n[m1t, m1o, m1h, m1l, m1c] = request.security_lower_tf(syminfo.tickerid, ltf1, [time, open, high, low, close])\n// Ohne offenen Trade werden mehrere Kerzen gesammelt und zusammen geschickt (spart Anfragen über ngrok).\nvar string barBuf = ""\nvar string m1Buf  = ""\nvar int    nBuf   = 0\nif sendBars and barstate.isrealtime and barstate.isconfirmed\n    string m1s = ""\n    int m1n = math.min(array.size(m1t), 120)\n    if timeframe.in_seconds() >= 60 and m1n > 0\n        for i = 0 to m1n - 1\n            m1s += (i > 0 ? "," : "") + "[" + str.tostring(array.get(m1t, i)) + "," + str.tostring(array.get(m1o, i), format.mintick) + "," +\n                 str.tostring(array.get(m1h, i), format.mintick) + "," + str.tostring(array.get(m1l, i), format.mintick) + "," +\n                 str.tostring(array.get(m1c, i), format.mintick) + "]"\n    // vor der Marktpause (17:00 NY) und im Trade immer sofort senden\n    int  bundleN = timeframe.in_seconds() <= 900 ? barBundle : 1   // große Kerzen nicht bündeln (Nachricht würde zu lang)\n    bool flush = strategy.position_size != 0 or nBuf + 1 >= bundleN or hour(time_close, "America/New_York") == 17 or\n         dayofweek(time_close, "America/New_York") == dayofweek.friday and hour(time_close, "America/New_York") >= 16\n    if flush\n        alert(\'{"type":"bar","ticker":"\' + sym + \'","time":\' + str.tostring(time) + \',"tf":\' + str.tostring(timeframe.in_seconds() * 1000) +\n             \',"open":\' + str.tostring(open, format.mintick) + \',"high":\' + str.tostring(high, format.mintick) +\n             \',"low":\' + str.tostring(low, format.mintick) + \',"close":\' + str.tostring(close, format.mintick) +\n             \',"bars":[\' + barBuf + \'],"m1":[\' + m1Buf + (m1Buf != "" and m1s != "" ? "," : "") + m1s + \']}\', alert.freq_once_per_bar_close)\n        barBuf := ""\n        m1Buf := ""\n        nBuf := 0\n    else\n        barBuf += (nBuf > 0 ? "," : "") + "[" + str.tostring(time) + "," + str.tostring(open, format.mintick) + "," + str.tostring(high, format.mintick) + "," +\n             str.tostring(low, format.mintick) + "," + str.tostring(close, format.mintick) + "]"\n        m1Buf += (m1Buf != "" and m1s != "" ? "," : "") + m1s\n        nBuf += 1\n\n// Live-Kurs, solange die Strategie im Trade ist. „Sparsam“: nur bei spürbarer Bewegung oder nahe Stop/Ziel.\nvarip int   lastTick   = 0\nvarip float lastTickPx = na\nif tickMode != "Aus" and barstate.isrealtime and not barstate.isconfirmed and strategy.position_size != 0\n    int   gap   = tickMode == "Normal" ? tickSec * 1000 : 60000\n    float dist  = math.abs(strategy.position_avg_price - tSL)\n    float moved = na(lastTickPx) ? dist : math.abs(close - lastTickPx)\n    bool  near  = (not na(tSL) and math.abs(close - tSL) <= dist * 0.3) or (not na(tTP) and math.abs(close - tTP) <= dist * 0.3)\n    bool  go    = tickMode == "Normal" or moved >= math.max(syminfo.mintick * 8, dist * 0.15) or near\n    if go and timenow - lastTick >= gap\n        lastTick := timenow\n        lastTickPx := close\n        alert(\'{"type":"tick","ticker":"\' + sym + \'","price":\' + str.tostring(close, format.mintick) + \',"time":\' + str.tostring(timenow) + \'}\', alert.freq_all)\n\n// ───────────────────────── Statistik je Setup ─────────────────────────\nvar array<string> stName = array.from("FVG", "iFVG", "Silver Bullet", "ORB", "Sweep", "VWAP")\nvar array<int>   stCnt  = array.new<int>(6, 0)\nvar array<int>   stWin  = array.new<int>(6, 0)\nvar array<float> stPnl  = array.new<float>(6, 0.0)\nvar int seen = 0\nif strategy.closedtrades > seen\n    for i = seen to strategy.closedtrades - 1\n        string eid = strategy.closedtrades.entry_id(i)\n        int   k = 0\n        for j = 0 to 5\n            if str.startswith(eid, stName.get(j) + " ")\n                k := j\n        float p = strategy.closedtrades.profit(i)\n        stCnt.set(k, stCnt.get(k) + 1)\n        stPnl.set(k, stPnl.get(k) + p)\n        if p > 0\n            stWin.set(k, stWin.get(k) + 1)\n    seen := strategy.closedtrades\n\n// ───────────────────────── Dashboard ─────────────────────────\ndashPos = switch dashPosStr\n    "Oben links"   => position.top_left\n    "Unten rechts" => position.bottom_right\n    "Unten links"  => position.bottom_left\n    => position.top_right\n\nvar table dash = table.new(dashPos, 2, 21, bgcolor = color.new(#131722, 8), border_color = color.new(#363a45, 0), border_width = 1, frame_color = color.new(#363a45, 0), frame_width = 1)\n\nmoney(float v) =>\n    (v < 0 ? "-$" : "$") + str.tostring(math.abs(v), "#,##0")\npct(float v) =>\n    na(v) ? "–" : str.tostring(v, "0.0") + "%"\nrow(int r, string k, string v, color vc) =>\n    table.cell(dash, 0, r, k, text_color = cMuted, text_size = size.small, text_halign = text.align_left)\n    table.cell(dash, 1, r, v, text_color = vc, text_size = size.small, text_halign = text.align_right)\n\nif showDash and barstate.islast\n    int ct      = strategy.closedtrades\n    float wr    = ct > 0 ? float(strategy.wintrades) / ct * 100 : na\n    float pf    = strategy.grossloss > 0 ? strategy.grossprofit / strategy.grossloss : na\n    float avgT  = ct > 0 ? strategy.netprofit / ct : na\n    int nF = 0\n    int nI = 0\n    for z in zones\n        if z.inverse\n            nI += 1\n        else\n            nF += 1\n    string pos  = strategy.position_size > 0 ? "LONG " + str.tostring(strategy.position_size) : strategy.position_size < 0 ? "SHORT " + str.tostring(math.abs(strategy.position_size)) : "Flat"\n    color posC  = strategy.position_size > 0 ? cBull : strategy.position_size < 0 ? cBear : color.white\n\n    table.cell(dash, 0, 0, "FVG Bot · " + syminfo.ticker + " · " + timeframe.period, text_color = color.white, text_size = size.normal, text_halign = text.align_left)\n    table.merge_cells(dash, 0, 0, 1, 0)\n    row(1,  "Position",          pos, posC)\n    string sName = inAsia ? "Asien" : inLondon ? "London" : inNyAm ? "NY Vormittag" : inNyLun ? "NY Mittag" : inNyPm ? "NY Nachmittag" : inAllDay ? "ganztägig" : "keine"\n    row(2,  "Session",           sName, inSess ? cBull : cMuted)\n    row(3,  "News-Filter",       newsBlock ? "gesperrt · " + newsReason : "frei", newsBlock ? cIBear : cBull)\n    row(4,  "HTF-Bias",          not useBias ? "aus" : close > htfEma ? "bullisch" : "bärisch", not useBias ? cMuted : close > htfEma ? cBull : cBear)\n    row(5,  "Aktive Zonen",      str.tostring(nF) + " FVG · " + str.tostring(nI) + " iFVG", color.white)\n    row(6,  "Trades heute",      str.tostring(tradesToday) + " / " + str.tostring(maxTradesDay), color.white)\n    row(7,  "P&L heute",         money(dayPnl), dayPnl >= 0 ? cBull : cBear)\n    row(8,  "─────",             "", cMuted)\n    row(9,  "Netto-Gewinn",      money(strategy.netprofit), strategy.netprofit >= 0 ? cBull : cBear)\n    row(10, "Trades gesamt",     str.tostring(ct), color.white)\n    row(11, "Trefferquote",      pct(wr), color.white)\n    row(12, "Profit-Faktor",     na(pf) ? "–" : str.tostring(pf, "0.00"), not na(pf) and pf >= 1 ? cBull : cBear)\n    row(13, "Ø Trade",           na(avgT) ? "–" : money(avgT), not na(avgT) and avgT >= 0 ? cBull : cBear)\n    row(14, "Max. Drawdown",     money(-strategy.max_drawdown), cBear)\n    for j = 0 to 5\n        int   n = stCnt.get(j)\n        float w = n > 0 ? float(stWin.get(j)) / n * 100 : na\n        row(15 + j, stName.get(j), n == 0 ? "–" : str.tostring(n) + " · " + pct(w) + " · " + money(stPnl.get(j)), n == 0 ? cMuted : stPnl.get(j) >= 0 ? cBull : cBear)\n'

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
APP_VERSION = "3.0.0"   # wird beim Bauen der Ein-Datei-Version gesetzt

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
