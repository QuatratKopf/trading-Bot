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

from brokers import BROKERS, BrokerError
from db import DB
from discovery import DC_DETECTORS, DC_TPS, dc_describe, dc_detect, dc_evaluate, dc_name_of, dc_prepare, dc_simulate, dc_stats

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
        _t = threading.Timer(8, lambda: self.learn_paths_async(adopt=self.cfg["learning"].get("auto_adopt", True))); _t.daemon = True; _t.start()
        if time.time() - (self.disc.get("last_run") or 0) > 20 * 3600:
            _t = threading.Timer(90, self.disc_async); _t.daemon = True; _t.start()

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
        self.db.update_position(pos["id"], status="geschlossen", closed=time.time(), exit=round_tick(exit_price, tick),
                                pnl=round(pnl, 2), close_reason=reason)
        self.db.log(f"{pos['side'].upper()} {pos['qty']}× {pos['root']} geschlossen ({reason}) · {_fmt(pnl, '+,.0f')} $",
                    "info" if pnl >= 0 else "warn")
        if pos["broker"] != "eigen":
            r_ = self._r_of(dict(pos, pnl=pnl))
            self.notify("trades", f"{'✅' if pnl > 0 else '❌'} {pos['side'].upper()} {pos['qty']}× {pos['root']} geschlossen · {pos['setup']}" + (" (Test)" if pos.get("is_test") else ""),
                        f"{reason} · {_fmt(pos['entry'], '.2f')} → {_fmt(exit_price, '.2f')} · **{_fmt(pnl, '+,.0f')} $**" + (f" ({_fmt(r_, '+.2f')} R)" if r_ is not None else "")
                        + f"\nHeute: {_fmt(self.today_pnl(), '+,.0f')} $", "good" if pnl > 0 else "bad")

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
                             "daystop_day": self.learning.get("daystop_day")}
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
            for row in self.variant_view()["setups"]:
                rec = row["rec"]
                if not rec or rec == row["applied"]:
                    continue
                if rec == "Signal-Ziel":
                    er.pop(row["setup"], None)
                else:
                    er[row["setup"]] = rec
                c = row["cols"][rec]
                done.append(f"{row['setup']}: Ausstieg {row['applied']} → {rec} (Ø {_fmt(c['avg'], '+.2f')} R aus {c['n']} Signalen)")
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
            rows = self.db.rows("SELECT t, o, h, l, c FROM bars1 WHERE fam=? AND t>=? ORDER BY t DESC LIMIT ?",
                                (fam, since_ms, limit * tf_min + tf_min))[::-1]
        else:
            rows = self.db.rows("SELECT t, o, h, l, c FROM bars1 WHERE fam=? AND t>=? ORDER BY t", (fam, since_ms))
        if tf_min == 1:
            bars = [[r["t"], r["o"], r["h"], r["l"], r["c"]] for r in rows]
        else:
            # nur vollständige Blöcke (sonst ist die letzte Kerze noch nicht fertig)
            agg = {}
            for r in rows:
                b = r["t"] - r["t"] % tf_ms
                x = agg.get(b)
                if x is None:
                    agg[b] = [b, r["o"], r["h"], r["l"], r["c"], 1, r["t"]]
                else:
                    x[2], x[3], x[4], x[5], x[6] = max(x[2], r["h"]), min(x[3], r["l"]), r["c"], x[5] + 1, r["t"]
            merged = {b: x[:5] for b, x in agg.items() if x[6] >= b + tf_ms - 60000}
            if not limit:
                chart = self.db.rows("SELECT t, o, h, l, c FROM bars WHERE fam=? AND t>=? ORDER BY t", (fam, since_ms))
                if chart and (self._tf_of([[x["t"]] for x in chart[:200]]) or 0) == tf_ms:
                    for x in chart:
                        merged.setdefault(x["t"], [x["t"], x["o"], x["h"], x["l"], x["c"]])
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
            since = (time.time() - 730 * 86400) * 1000   # höchstens 2 Jahre (Rechenzeit)
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
            st = "ok" if age < tf * 2 + 120 else ("off" if not mo else "warn" if age < 1800 else "bad")
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
