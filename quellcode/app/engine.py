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
        if bar["time"]:
            try:
                self.db.add_bar(fam, bar["time"], bar["open"], bar["high"], bar["low"], bar["close"])
            except Exception as e:  # noqa: BLE001
                self.db.log(f"Kerze nicht gespeichert: {e}", "warn")
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
        """Name der gerade laufenden, angehakten Session oder None."""
        t = t or ny_time()
        on = self.cfg["risk"].get("sessions") or {}
        return next((k for k in TRADING_SESSIONS if on.get(k) and in_session(k, t)), None)

    def _guards(self, fam, risk=None):
        r = self.cfg["risk"]
        if self.cfg["paused"]:
            return "Handel pausiert"
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

    @staticmethod
    def _session_end(obj):
        """16:00 NY des Handelstags, an dem das Signal kam (Abend-Signale gehören zum nächsten Tag)."""
        t = ny_time(obj["bar_time"] / 1000) if obj.get("bar_time") else ny_time(obj["opened"])
        day = t.date() if t.time() < dt.time(16) else t.date() + dt.timedelta(days=1)
        while day.weekday() >= 5:
            day += dt.timedelta(days=1)
        return dt.datetime.combine(day, dt.time(16))

    def _close_variant(self, v, exit_price):
        d = 1 if v["side"] == "long" else -1
        self.db.update_variant(v["id"], status="geschlossen", closed=time.time(), exit=exit_price,
                               r=round((exit_price - v["entry"]) * d / (v["risk"] or 1e-9), 3))

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
                for v in self.db.open_variants():
                    last = (self.last_bar.get(v["fam"]) or {}).get("close")
                    if last:
                        self._close_variant(v, last)
                self.learn()
                self.db.log("Lernmodul: Tagesauswertung abgeschlossen")
                self.db.prune_bars((now - 420 * 86400) * 1000)   # Kerzen älter als ~14 Monate löschen
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

    def chart_data(self, fam=None, days=2):
        """Kerzen + Trades für den Live-Chart im Cockpit."""
        fams = self.db.bar_fams()
        fam = fam if fam in fams else (fams[0] if fams else None)
        if not fam:
            return {"fams": [], "fam": None, "bars": []}
        last = self.db.one("SELECT MAX(t) t FROM bars WHERE fam=?", (fam,))
        anchor = min(time.time(), (last["t"] or 0) / 1000 + 3600) if last and last["t"] else time.time()
        since = anchor - days * 86400   # am Wochenende/abends: ab der letzten Kerze zurückrechnen, damit der Chart nicht leer ist
        bars = [[x["t"], x["o"], x["h"], x["l"], x["c"]] for x in self.db.bars(fam, since * 1000)]
        diffs = sorted(b[0] - a[0] for a, b in zip(bars, bars[1:]) if b[0] > a[0])
        tf = diffs[len(diffs) // 2] if diffs else 300000
        trades = []
        for p in self.db.rows("SELECT * FROM positions WHERE (closed IS NULL OR closed >= ?) OR status='offen'", (since,)):
            if family(p["root"]) != fam or p["broker"] not in (self.broker.name, "eigen"):
                continue
            if p["broker"] == "eigen" and (not p["opened"] or p["opened"] == p["closed"] or not p["entry"]):
                continue   # eigene Trades ohne Uhrzeit/Preis lassen sich nicht einzeichnen
            trades.append({k: p.get(k) for k in ("id", "side", "qty", "root", "entry", "exit", "sl", "tp", "initial_sl",
                                                 "opened", "closed", "pnl", "status", "setup", "is_test", "mgmt")}
                          | {"source": "eigen" if p["broker"] == "eigen" else "bot"})
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
        return {"fams": fams, "fam": fam, "bars": bars, "tf": tf, "trades": trades, "pending": pending, "levels": levels,
                "last": (self.last_bar.get(fam) or {}).get("close")}

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
                "has_tests": bool(self.db.one("SELECT 1 x FROM positions WHERE is_test=1 LIMIT 1")),
                "challenge": self.challenge() if self.cfg["challenge"]["enabled"] else None,
                "own_sync": dict(self.sync_state, enabled=bool(self.cfg["own_sync"].get("tradovate"))),
                "sizing_preview": {fam: [self.size_preview(fam, pts) for pts in
                                         ((10, 20, 40, 60) if fam == "NQ" else (3, 5, 10, 15))]
                                   for fam in ("NQ", "ES")},
            }
