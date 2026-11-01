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
