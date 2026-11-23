"""Broker-Anbindungen: Paper-Trading (Simulation), Topstep (TopstepX-/ProjectX-API) und MetaTrader 5 (EA FVG-Bridge).

Jede Order wird als Bracket mit Stop-Loss geschickt. Ohne Stop verlässt keine Order die App.
"""
import datetime as dt
import json
import math
import os
import re
import threading
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


# ───────────────────────── Topstep (TopstepX / ProjectX-API) ─────────────────────────
TSX_DEFAULT_URL = "https://api.topstepx.com"
TSX_LIMIT, TSX_MARKET, TSX_STOP = 1, 2, 4          # Order-Arten der API
TSX_BUY, TSX_SELL = 0, 1                           # 0 = Kauf (Bid), 1 = Verkauf (Ask)
TSX_FILLED, TSX_DONE = 2, (2, 3, 4, 5)             # 2 = ausgeführt; 3/4/5 = storniert/abgelaufen/abgelehnt


class TopstepBroker:
    """Topstep über die TopstepX-API (ProjectX Gateway). Benötigt Benutzername und API-Schlüssel aus TopstepX.

    Ablauf je Trade: Market-Order, danach eine Stop-Order und eine Limit-Order fürs Ziel.
    Lässt sich der Stop nicht setzen, wird die Position sofort wieder geschlossen: ohne Stop bleibt nichts offen.
    Wird eine der beiden Schutz-Orders ausgeführt, storniert der Bot die andere."""
    name = "topstep"
    label = "Topstep"

    def __init__(self, cfg):
        self.cfg = cfg
        self.token = None
        self.token_time = 0
        self.account_id = None
        self.account_name = None
        self.accounts = []
        self._contracts = {}      # Kontraktname -> {"id", "tick"}
        self._front = {}          # Wurzel (MNQ) -> (Zeit, Kontraktname)

    @property
    def tcfg(self):
        return self.cfg.setdefault("topstep", {})

    @property
    def base(self):
        return (self.tcfg.get("api_url") or TSX_DEFAULT_URL).rstrip("/") + "/api"

    def _req(self, path, body=None, auth=True):
        if auth:
            self._ensure_token()
        req = urllib.request.Request(self.base + path, data=json.dumps(body or {}).encode(), method="POST")
        req.add_header("Content-Type", "application/json")
        req.add_header("Accept", "application/json")
        if auth:
            req.add_header("Authorization", f"Bearer {self.token}")
        try:
            with urllib.request.urlopen(req, timeout=15) as r:
                raw = r.read().decode() or "{}"
        except urllib.error.HTTPError as e:
            if e.code == 401 and auth:
                self.token = None
            raise BrokerError(f"Topstep {e.code}: {e.read().decode()[:200]}")
        except urllib.error.URLError as e:
            raise BrokerError(f"Topstep nicht erreichbar: {e.reason}")
        try:
            res = json.loads(raw)
        except ValueError:
            raise BrokerError("Topstep: unerwartete Antwort")
        if isinstance(res, dict) and res.get("success") is False:
            msg = res.get("errorMessage") or f"Fehlercode {res.get('errorCode')}"
            raise BrokerError(f"Topstep: {msg}")
        return res

    def _ensure_token(self):
        if self.token and time.time() - self.token_time < 20 * 3600:   # Schlüssel gilt 24 Stunden
            return
        c = self.tcfg
        missing = [n for k, n in (("username", "Benutzername"), ("api_key", "API-Schlüssel")) if not str(c.get(k, "")).strip()]
        if missing:
            raise BrokerError("Topstep-Zugangsdaten fehlen: " + ", ".join(missing))
        try:
            res = self._req("/Auth/loginKey", {"userName": c["username"].strip(), "apiKey": c["api_key"].strip()}, auth=False)
        except BrokerError as e:
            if "nicht erreichbar" in str(e):
                raise
            raise BrokerError("Topstep-Login fehlgeschlagen: Benutzername oder API-Schlüssel prüfen")
        if not isinstance(res, dict) or not res.get("token"):
            raise BrokerError("Topstep-Login fehlgeschlagen: Benutzername oder API-Schlüssel prüfen")
        self.token, self.token_time = res["token"], time.time()
        self._pick_account()

    def _pick_account(self):
        res = self._req("/Account/search", {"onlyActiveAccounts": True})
        accs = [a for a in (res.get("accounts") or []) if isinstance(a, dict)]
        self.accounts = accs
        if not accs:
            raise BrokerError("Kein aktives Topstep-Konto gefunden")
        want = str(self.tcfg.get("account") or "").strip().upper()
        if want:
            acc = next((a for a in accs if str(a.get("name", "")).upper() == want), None)
            if not acc:
                raise BrokerError(f"Konto „{self.tcfg.get('account')}“ nicht gefunden. Vorhanden: " + ", ".join(str(a.get("name")) for a in accs))
        else:
            tradable = [a for a in accs if a.get("canTrade")]
            if len(tradable) != 1:
                raise BrokerError("Bitte den Kontonamen eintragen. Vorhanden: " + ", ".join(str(a.get("name")) for a in accs))
            acc = tradable[0]
        if not acc.get("canTrade"):
            raise BrokerError(f"Konto {acc.get('name')} darf gerade nicht handeln (gesperrt oder Verlustgrenze erreicht)")
        self.account_id, self.account_name = acc["id"], acc.get("name")

    def connect(self):
        self.token = None
        self._ensure_token()
        return f"Verbunden mit Topstep, Konto {self.account_name}"

    def day_summary(self, since_ts):
        """Tagesergebnisse seit since_ts (Handelstag endet 18 Uhr New York): [{day, pnl, cash, n}]."""
        self._ensure_token()
        start = dt.datetime.fromtimestamp(since_ts, dt.timezone.utc)
        res = self._req("/Trade/search", {"accountId": self.account_id, "startTimestamp": start.isoformat(),
                                          "endTimestamp": dt.datetime.now(dt.timezone.utc).isoformat()})
        days = {}
        for t in res.get("trades") or []:
            if not isinstance(t, dict) or t.get("voided"):
                continue
            try:
                ts = dt.datetime.fromisoformat(str(t.get("creationTimestamp")).replace("Z", "+00:00")).timestamp()
            except ValueError:
                continue
            # Topstep-Handelstag: ab 18 Uhr New York zählt der nächste Tag (6 Stunden Versatz, Winterzeit genügt)
            day = (dt.datetime.fromtimestamp(ts, dt.timezone.utc) - dt.timedelta(hours=5) + dt.timedelta(hours=6)).date().isoformat()
            d = days.setdefault(day, {"day": day, "pnl": 0.0, "cash": 0.0, "n": 0})
            d["pnl"] += float(t.get("profitAndLoss") or 0) - float(t.get("fees") or 0)
            d["n"] += 1 if t.get("profitAndLoss") is not None else 0
        return sorted(days.values(), key=lambda d: d["day"])

    def account_names(self):
        return [{"name": a.get("name"), "can_trade": bool(a.get("canTrade")), "balance": a.get("balance")} for a in self.accounts]

    # Kontrakte
    def _search(self, text):
        out = []
        for live in (False, True):
            try:
                res = self._req("/Contract/search", {"searchText": text, "live": live})
            except BrokerError:
                continue
            out += [c for c in (res.get("contracts") or []) if isinstance(c, dict) and c.get("id")]
            if out:
                break
        return out

    def contract_name(self, root):
        override = (self.cfg.get("contracts") or {}).get(root, "").strip()
        if override:
            return override
        hit = self._front.get(root)
        if hit and time.time() - hit[0] < 3600:
            return hit[1]
        name = front_month(root)
        try:
            pat = re.compile(rf"^{re.escape(root)}[FGHJKMNQUVXZ]\d{{1,2}}$")
            cands = [c for c in self._search(root) if pat.match(str(c.get("name", "")))]
            act = [c for c in cands if c.get("activeContract")]
            if act or cands:
                c = (act or cands)[0]
                name = c["name"]
                self._contracts[name] = {"id": c["id"], "tick": float(c.get("tickSize") or 0.25)}
        except BrokerError:
            pass
        self._front[root] = (time.time(), name)
        return name

    def _contract(self, name):
        if name not in self._contracts:
            hit = next((c for c in self._search(name) if str(c.get("name", "")).upper() == name.upper()), None)
            if not hit:
                raise BrokerError(f"Kontrakt {name} bei Topstep nicht gefunden")
            self._contracts[name] = {"id": hit["id"], "tick": float(hit.get("tickSize") or 0.25)}
        return self._contracts[name]

    # Orders
    def _place(self, contract_id, otype, side, qty, limit=None, stop=None, tag=None):
        body = {"accountId": self.account_id, "contractId": contract_id, "type": otype, "side": side, "size": int(qty),
                "limitPrice": limit, "stopPrice": stop, "trailPrice": None}
        if tag:
            body["customTag"] = tag
        res = self._req("/Order/place", body)
        oid = res.get("orderId") if isinstance(res, dict) else None
        if not oid:
            raise BrokerError(f"Order abgelehnt: {res}")
        return oid

    def _cancel(self, order_id):
        if not order_id:
            return
        try:
            self._req("/Order/cancel", {"accountId": self.account_id, "orderId": order_id})
        except BrokerError:
            pass   # schon ausgeführt oder storniert

    def _orders(self, hours=72):
        end = dt.datetime.now(dt.timezone.utc)
        res = self._req("/Order/search", {"accountId": self.account_id,
                                          "startTimestamp": (end - dt.timedelta(hours=hours)).isoformat(),
                                          "endTimestamp": end.isoformat()})
        return {o["id"]: o for o in (res.get("orders") or []) if isinstance(o, dict) and "id" in o}

    def _open_orders(self):
        res = self._req("/Order/searchOpen", {"accountId": self.account_id})
        return {o["id"]: o for o in (res.get("orders") or []) if isinstance(o, dict) and "id" in o}

    def _fill_of(self, order_id, tries=6):
        for _ in range(tries):
            o = self._orders(hours=2).get(order_id)
            if o and o.get("status") == TSX_FILLED and o.get("filledPrice"):
                return float(o["filledPrice"])
            if o and o.get("status") in (3, 4, 5):
                return None
            time.sleep(0.4)
        return None

    def open(self, contract, side, qty, price, sl, tp, tick):
        self._ensure_token()
        con = self._contract(contract)
        cid = con["id"]
        entry_side, exit_side = (TSX_BUY, TSX_SELL) if side == "long" else (TSX_SELL, TSX_BUY)
        tag = "fvg-" + uuid.uuid4().hex[:12]
        oid = self._place(cid, TSX_MARKET, entry_side, qty, tag=tag)
        fill = self._fill_of(oid)
        if fill is None:
            o = self._orders(hours=2).get(oid) or {}
            if o.get("status") in (3, 4, 5):
                raise BrokerError("Topstep hat die Einstiegs-Order nicht ausgeführt (abgelehnt oder storniert)")
            fill = price   # Ausführung noch nicht gemeldet: mit Signalpreis weiter, Stop wird trotzdem gesetzt
        ref = {"orderId": oid, "contractId": cid, "contract": contract, "tag": tag, "stopId": None, "tpId": None}
        try:
            ref["stopId"] = self._place(cid, TSX_STOP, exit_side, qty, stop=sl)
        except BrokerError as e:
            try:   # ohne Stop keine offene Position
                self._place(cid, TSX_MARKET, exit_side, qty)
            except BrokerError as e2:
                raise BrokerError(f"Stop konnte nicht gesetzt werden ({e}) UND Schließen schlug fehl ({e2}). Position sofort in TopstepX prüfen!")
            raise BrokerError(f"Stop konnte nicht gesetzt werden, Position wurde sofort wieder geschlossen: {e}")
        if tp:
            try:
                ref["tpId"] = self._place(cid, TSX_LIMIT, exit_side, qty, limit=tp)
            except BrokerError:
                ref["tpId"] = None   # Stop sitzt, Ziel fehlt: der Bot schließt beim Erreichen des Ziels selbst
        return fill, ref

    def close(self, pos, price, tick):
        ref = pos["broker_ref"]
        exit_side = TSX_SELL if pos["side"] == "long" else TSX_BUY
        open_ = self._open_orders()
        stop_open = ref.get("stopId") in open_
        if not stop_open and ref.get("stopId"):
            st = self._orders().get(ref["stopId"]) or {}
            if st.get("status") == TSX_FILLED:   # Stop war schneller: nichts mehr zu schließen
                self._cancel(ref.get("tpId"))
                return float(st.get("filledPrice") or pos["sl"])
        oid = self._place(ref["contractId"], TSX_MARKET, exit_side, pos["qty"])
        self._cancel(ref.get("stopId"))
        self._cancel(ref.get("tpId"))
        return self._fill_of(oid) or price

    def modify_stop(self, pos, new_sl):
        ref = pos["broker_ref"]
        if not ref.get("stopId"):
            raise BrokerError("Stop-Order-ID unbekannt")
        self._req("/Order/modify", {"accountId": self.account_id, "orderId": ref["stopId"], "stopPrice": new_sl})
        return True

    def modify_target(self, pos, new_tp):
        ref = pos["broker_ref"]
        if new_tp is None:
            self._cancel(ref.get("tpId"))
            ref["tpId"] = None
            return True
        if not ref.get("tpId"):
            raise BrokerError("Diese Position hat beim Broker keine Ziel-Order, das Ziel kann nicht nachträglich gesetzt werden")
        self._req("/Order/modify", {"accountId": self.account_id, "orderId": ref["tpId"], "limitPrice": new_tp})
        return True

    def sync(self, positions):
        """Erkennt Positionen, die beim Broker durch Stop oder Ziel geschlossen wurden, und storniert die übrige Schutz-Order."""
        if not positions:
            return []
        open_ = self._open_orders()
        missing = [p for p in positions if p["broker_ref"].get("stopId") not in open_
                   or (p["broker_ref"].get("tpId") and p["broker_ref"].get("tpId") not in open_)]
        if not missing:
            return []
        hist = self._orders()
        net = {}
        for p in (self._req("/Position/searchOpen", {"accountId": self.account_id}).get("positions") or []):
            if isinstance(p, dict):
                net[p.get("contractId")] = net.get(p.get("contractId"), 0) + int(p.get("size") or 0)
        closed, warn = [], []
        for pos in missing:
            ref = pos["broker_ref"]
            st, tp = hist.get(ref.get("stopId")) or {}, hist.get(ref.get("tpId")) or {}
            if st.get("status") == TSX_FILLED:
                self._cancel(ref.get("tpId"))
                closed.append((pos, float(st.get("filledPrice") or pos["sl"])))
            elif tp.get("status") == TSX_FILLED:
                self._cancel(ref.get("stopId"))
                closed.append((pos, float(tp.get("filledPrice") or pos["tp"])))
            elif not net.get(ref.get("contractId")):
                # von Hand in TopstepX geschlossen: übrige Orders aufräumen
                self._cancel(ref.get("stopId"))
                self._cancel(ref.get("tpId"))
                closed.append((pos, self._last_exit(pos)))
            elif ref.get("stopId") not in open_ and st.get("status") in (3, 4, 5):
                warn.append(pos["contract"])
        if warn and not closed:
            raise BrokerError("Achtung: Stop-Order für " + ", ".join(warn) + " wurde storniert, Position ist ohne Schutz. Bitte in TopstepX prüfen!")
        return closed

    def _last_exit(self, pos):
        """Preis des letzten schließenden Fills auf dem Kontrakt seit Eröffnung der Position."""
        try:
            start = dt.datetime.fromtimestamp(pos.get("opened") or time.time() - 86400, dt.timezone.utc)
            res = self._req("/Trade/search", {"accountId": self.account_id, "startTimestamp": start.isoformat(),
                                              "endTimestamp": dt.datetime.now(dt.timezone.utc).isoformat()})
        except BrokerError:
            return None
        exit_side = TSX_SELL if pos["side"] == "long" else TSX_BUY
        fills = [t for t in (res.get("trades") or []) if isinstance(t, dict) and not t.get("voided")
                 and t.get("contractId") == pos["broker_ref"].get("contractId") and t.get("side") == exit_side
                 and t.get("profitAndLoss") is not None]
        fills.sort(key=lambda t: str(t.get("creationTimestamp", "")))
        return float(fills[-1]["price"]) if fills else None

    def balance(self):
        self._ensure_token()
        res = self._req("/Account/search", {"onlyActiveAccounts": True})
        acc = next((a for a in (res.get("accounts") or []) if a.get("id") == self.account_id), None)
        return float(acc["balance"]) if acc and acc.get("balance") is not None else None


# ───────────────────────── MetaTrader 5 (mehrere Konten, Copytrading) ─────────────────────────
# Die App spricht mit MT5 über Textdateien im gemeinsamen MT5-Ordner (Common\Files\FVG).
# In jedem MT5-Fenster läuft der EA „FVG-Bridge“: er führt Aufträge aus und meldet jede Sekunde den Kontostand.
MT5_BOT_MAGIC = 260626        # Orders des Bots
MT5_COPY_MAGIC = 260627       # Kopien aus dem Copytrading
MT5_PV = {"NQ": 20.0, "MNQ": 2.0, "ES": 50.0, "MES": 5.0}
MT5_ONLINE_SEC = 12


MT5_CONS_SAFETY = 0.8        # Konsistenz: Bot hört schon bei 80 % des erlaubten Tagesgewinns auf (Puffer)


def mt5_day_pnl(a):
    """Heutiges Ergebnis eines MT5-Kontos (Tag des Broker-Servers): geschlossene Trades + offene Positionen."""
    today = str(a.get("today") or "").replace(".", "-")
    real = sum(float(d.get("pnl") or 0) for d in a.get("days") or [] if today and d.get("day") == today)
    bal, eq = a.get("balance"), a.get("equity")
    return round(real + ((eq - bal) if bal is not None and eq is not None else 0.0), 2)


def mt5_cons_cap(c):
    """Höchster Tagesgewinn, bis zu dem der Bot auf diesem Konto handelt (Konsistenzregel), oder None, wenn aus."""
    try:
        pct, tgt = float(c.get("cons_pct") or 0), float(c.get("cons_target") or 0)
    except (TypeError, ValueError):
        return None
    if not c.get("cons_on") or pct <= 0 or tgt <= 0:
        return None
    return round(tgt * pct / 100 * MT5_CONS_SAFETY, 2)


def mt5_cons_block(c, a):
    """Grund, warum heute auf diesem Konto kein neuer Trade mehr geht (Konsistenzregel), sonst ''."""
    cap = mt5_cons_cap(c)
    if cap is None or not a:
        return ""
    pnl = mt5_day_pnl(a)
    if pnl >= cap:
        p_, c_ = f"{pnl:+,.0f}".replace(",", "."), f"{cap:,.0f}".replace(",", ".")
        return f"Konsistenzregel: heute schon {p_} $ (Grenze {c_} $), dort heute keine neuen Trades"
    return ""


MT5_RULE_SAFETY = 0.9        # Firmen-Regeln: höchstens 90 % des noch erlaubten Verlusts für einen neuen Trade


def mt5_rule_limits(c):
    """Firmen-Regeln eines MT5-Kontos in $ (aus Kontogröße und Prozenten) oder None, wenn aus."""
    try:
        size = float(c.get("rule_size") or 0)
        pct = {k: float(c.get("rule_" + k) or 0) for k in ("daily", "total", "trade", "target")}
    except (TypeError, ValueError):
        return None
    if not c.get("rules_on") or size <= 0:
        return None
    return {"size": size, "daily": size * pct["daily"] / 100, "floor": size * (1 - pct["total"] / 100) if pct["total"] > 0 else 0.0,
            "trade": size * pct["trade"] / 100, "target": size * (1 + pct["target"] / 100) if pct["target"] > 0 else 0.0}


def mt5_open_risk(a):
    """Möglicher Verlust aller offenen Positionen bis zu ihren Stops, ab dem jetzigen Kurs. None = Position ohne Stop."""
    tot = 0.0
    for p in a.get("positions") or []:
        spec = (a.get("symbols") or {}).get(p["symbol"])
        if p["sl"] <= 0 or not spec or spec["tick_size"] <= 0:
            return None
        px = spec["bid"] if p["side"] == "long" else spec["ask"]
        dist = (px - p["sl"]) if p["side"] == "long" else (p["sl"] - px)
        tot += max(0.0, dist) / spec["tick_size"] * spec["tick_value"] * p["volume"]
    return tot


def mt5_rule_room(c, a):
    """Wie viel $ ein neuer Trade auf diesem Konto höchstens riskieren darf (Firmen-Regeln), und warum.
    (None, '') = keine Regeln eingetragen; (0, Grund) = heute kein neuer Trade."""
    L = mt5_rule_limits(c)
    if L is None or not a:
        return None, ""
    bal, eq = a.get("balance"), a.get("equity")
    eq = eq if eq is not None else bal
    if eq is None:
        return 0.0, "Firmen-Regeln: Kontostand unbekannt, kein neuer Trade"
    if L["target"] and bal is not None and bal >= L["target"]:
        return 0.0, "Firmen-Regeln: Gewinnziel erreicht (" + f"{bal:,.0f}".replace(",", ".") + " $), keine neuen Trades mehr"
    open_r = mt5_open_risk(a)
    if open_r is None:
        return 0.0, "Firmen-Regeln: offene Position ohne Stop-Loss, deshalb kein neuer Trade"
    rooms = []
    if L["trade"] > 0:
        rooms.append((L["trade"], "Verlust pro Trade"))
    if L["daily"] > 0:
        rooms.append((L["daily"] + min(0.0, mt5_day_pnl(a)) - open_r, "Tagesverlust"))
    if L["floor"] > 0:
        rooms.append((eq - L["floor"] - open_r, "Gesamtverlust"))
    if not rooms:
        return None, ""
    room, what = min(rooms)
    room = round(room * MT5_RULE_SAFETY, 2)
    if room <= 0:
        return 0.0, f"Firmen-Regeln: Grenze „{what}“ fast erreicht, heute kein neuer Trade"
    return room, what


def mt5_family(root):
    return "ES" if "ES" in str(root).upper() else "NQ"


def mt5_default_dir():
    base = os.environ.get("APPDATA") or os.path.expanduser("~")
    return os.path.join(base, "MetaQuotes", "Terminal", "Common", "Files", "FVG")


class Mt5Link:
    """Dateibasierte Verbindung zu allen MT5-Fenstern, in denen der EA FVG-Bridge läuft."""

    def __init__(self, cfg):
        self.cfg = cfg
        self._cache = {}       # Pfad -> (mtime, Daten)
        self._dir_of = {}      # Login -> Ordner, in dem seine Bridge schreibt

    @property
    def mcfg(self):
        return self.cfg.setdefault("mt5", {})

    @property
    def dir(self):
        return os.environ.get("FVG_MT5_DIR") or self.mcfg.get("dir") or mt5_default_dir()

    def diag(self):
        """Was die App im Austausch-Ordner sieht: Anzahl Statusdateien und wie alt die neueste ist."""
        try:
            names = [n for n in os.listdir(self.dir) if n.startswith("status_") and n.endswith(".txt")]
        except OSError:
            return {"dir": self.dir, "exists": False, "files": 0, "age": None}
        ages = []
        for n in names:
            try:
                ages.append(time.time() - os.path.getmtime(os.path.join(self.dir, n)))
            except OSError:
                pass
        return {"dir": self.dir, "exists": True, "files": len(names), "age": round(min(ages)) if ages else None}

    @property
    def dirs(self):
        """Alle Ordner, in denen Bridges schreiben können: der eingestellte und der eigene der App
        (MT5-Programme, die die App selbst startet, schreiben in den Ordner ihres Windows-Benutzers)."""
        out = [self.dir]
        if not os.environ.get("FVG_MT5_DIR") and os.path.normcase(mt5_default_dir()) != os.path.normcase(self.dir):
            out.append(mt5_default_dir())
        return out

    def dir_for(self, login):
        return self._dir_of.get(str(login)) or self.dir

    def ensure_dir(self):
        try:
            os.makedirs(self.dir, exist_ok=True)
        except OSError as e:
            raise BrokerError(f"MT5-Ordner nicht beschreibbar: {e}")

    def sym_for(self, login, fam):
        """Symbolname für Nasdaq (NQ) bzw. S&P 500 (ES) auf diesem Konto: eigener Name oder der allgemeine."""
        c = (self.mcfg.get("accounts") or {}).get(str(login)) or {}
        return (str(c.get("sym_" + fam) or "").strip() or str(self.mcfg.get("sym_" + fam) or "").strip()
                or ("US500.cash" if fam == "ES" else "US100.cash"))

    def fam_of(self, login, symbol):
        for fam in ("NQ", "ES"):
            if symbol == self.sym_for(login, fam):
                return fam
        return None

    def write_symbols(self, extra=()):
        names = [self.mcfg.get("sym_NQ") or "US100.cash", self.mcfg.get("sym_ES") or "US500.cash", *extra]
        for c in (self.mcfg.get("accounts") or {}).values():
            names += [c.get("sym_NQ") or "", c.get("sym_ES") or ""]
        txt = "\r\n".join(dict.fromkeys(n.strip() for n in names if n and n.strip())) + "\r\n"
        self.ensure_dir()
        for d in self.dirs:
            if d != self.dir and not os.path.isdir(d):
                continue
            path = os.path.join(d, "symbols.txt")
            try:
                with open(path, encoding="latin-1") as f:
                    if f.read() == txt.replace("\r\n", "\n"):
                        continue
            except OSError:
                pass
            try:
                tmp = path + ".tmp"
                with open(tmp, "w", encoding="latin-1", newline="") as f:
                    f.write(txt)
                os.replace(tmp, path)
            except OSError:
                pass

    @staticmethod
    def _num(x, d=0.0):
        try:
            return float(x)
        except (TypeError, ValueError):
            return d

    def _parse(self, raw):
        a = {"positions": [], "symbols": {}, "deals": [], "days": [], "nqc": []}
        for line in raw.splitlines():
            k, _, v = line.strip().partition("=")
            if not _:
                continue
            if k == "pos":
                f = v.split("|")
                if len(f) >= 11:
                    a["positions"].append({"ticket": int(f[0]), "symbol": f[1], "side": "long" if f[2] == "0" else "short",
                                           "volume": self._num(f[3]), "price": self._num(f[4]), "sl": self._num(f[5]),
                                           "tp": self._num(f[6]), "magic": int(self._num(f[7])), "comment": f[8],
                                           "time": int(self._num(f[9])), "profit": self._num(f[10])})
            elif k == "sym":
                f = v.split("|")
                if len(f) >= 10 and f[1] == "1":
                    a["symbols"][f[0]] = {"bid": self._num(f[2]), "ask": self._num(f[3]), "digits": int(self._num(f[4])),
                                          "tick_size": self._num(f[5]), "tick_value": self._num(f[6]),
                                          "vol_min": self._num(f[7]), "vol_step": self._num(f[8]), "vol_max": self._num(f[9])}
                elif f:
                    a["symbols"].setdefault(f[0], None)
            elif k == "nqc":   # Nasdaq-Kandidaten dieses Kontos (FVG-Bridge ab 2.07)
                f = v.split("|")
                if f and f[0]:
                    a["nqc"].append({"name": f[0], "desc": f[1] if len(f) > 1 else "", "trade": (f[2] if len(f) > 2 else "1") == "1"})
            elif k == "chart":
                sym, _, mins = v.partition("|")
                a["chart"] = {"symbol": sym, "minutes": int(self._num(mins, 0))}
            elif k == "dsum":
                f = v.split("|")
                if len(f) >= 4:
                    a["days"].append({"day": f[0].replace(".", "-"), "pnl": self._num(f[1]), "cash": self._num(f[2]),
                                      "n": int(self._num(f[3]))})
            elif k == "deal":
                f = v.split("|")
                if len(f) >= 8:
                    a["deals"].append({"deal": int(f[0]), "position": int(f[1]), "symbol": f[2], "price": self._num(f[3]),
                                       "pnl": self._num(f[4]), "time": int(self._num(f[5])), "reason": f[6], "volume": self._num(f[7])})
            else:
                a[k] = v
        return a

    def accounts(self):
        """Alle MT5-Konten, die sich gemeldet haben: login -> Status."""
        out = {}
        now = time.time()
        for d in self.dirs:
            try:
                names = [n for n in os.listdir(d) if n.startswith("status_") and n.endswith(".txt")]
            except OSError:
                continue
            for n in names:
                path = os.path.join(d, n)
                try:
                    mt = os.path.getmtime(path)
                    hit = self._cache.get(path)
                    if hit and hit[0] == mt:
                        a = hit[1]
                    else:
                        with open(path, encoding="latin-1", errors="replace") as f:
                            a = self._parse(f.read())
                        self._cache[path] = (mt, a)
                except (OSError, ValueError):
                    hit = self._cache.get(path)
                    if not hit:
                        continue
                    mt, a = hit
                login = str(a.get("login") or n[7:-4])
                if login in out and out[login]["seen"] >= mt:
                    continue   # dasselbe Konto in zwei Ordnern: die neuere Meldung gilt
                a = dict(a, login=login, seen=mt, online=now - mt < MT5_ONLINE_SEC, dir=d,
                         balance=self._num(a.get("balance"), None), equity=self._num(a.get("equity"), None),
                         can_trade=a.get("trade_allowed") == "1")
                out[login] = a
                self._dir_of[login] = d
        return out

    def send(self, jobs, wait=8.0):
        """jobs: Liste (login, dict). Schreibt Aufträge, wartet auf die Antworten und gibt sie in derselben Reihenfolge zurück."""
        self.ensure_dir()
        if any(str(lg) not in self._dir_of for lg, _ in jobs):
            self.accounts()   # Ordner der Konten ermitteln
        sent = []
        for login, cmd in jobs:
            cid = uuid.uuid4().hex[:12]
            body = dict(cmd, id=cid, expires=int(time.time() + 20))
            txt = "".join(f"{k}={str(v).replace(chr(10), ' ').replace(chr(13), ' ')}\r\n" for k, v in body.items() if v is not None)
            tmp = os.path.join(self.dir_for(login), f"tmpcmd_{login}_{cid}.txt")
            with open(tmp, "w", encoding="latin-1", errors="replace", newline="") as f:
                f.write(txt)
            os.replace(tmp, os.path.join(self.dir_for(login), f"cmd_{login}_{cid}.txt"))
            sent.append((login, cid))
        results = {}
        end = time.time() + wait
        while len(results) < len(sent) and time.time() < end:
            for login, cid in sent:
                if (login, cid) in results:
                    continue
                path = os.path.join(self.dir_for(login), f"res_{login}_{cid}.txt")
                try:
                    with open(path, encoding="latin-1", errors="replace") as f:
                        raw = f.read()
                    os.remove(path)
                except OSError:
                    continue
                r = {}
                for line in raw.splitlines():
                    k, sep, v = line.strip().partition("=")
                    if sep:
                        r[k] = v
                r["ok"] = r.get("ok") == "1"
                results[(login, cid)] = r
            if len(results) < len(sent):
                time.sleep(0.15)
        for login, cid in sent:
            if (login, cid) in results:
                continue
            try:   # keine Antwort: Auftrag zurückziehen, damit er nicht später ausgeführt wird
                os.remove(os.path.join(self.dir_for(login), f"cmd_{login}_{cid}.txt"))
                results[(login, cid)] = {"ok": False, "error": "MT5 hat nicht geantwortet (EA oder Algo Trading aus?)"}
            except OSError:
                results[(login, cid)] = {"ok": False, "unclear": True,
                                         "error": "MT5 hat den Auftrag angenommen, aber nicht rechtzeitig geantwortet. Bitte in MT5 prüfen!"}
        return [dict(results[k], login=k[0]) for k in sent]


class Mt5Terminals:
    """MT5-Starter: legt je Konto eine eigene (portable) MT5-Kopie an, spielt FVG-Bridge ein, meldet sich
    über eine Start-Datei automatisch an, legt die Bridge auf den Chart und hält das Programm am Laufen."""

    def __init__(self, cfg, data_dir, sources):
        self.cfg = cfg
        self.base = os.path.join(data_dir, "mt5")
        self.sources = sources          # Funktion: () -> (Bridge-Quelltext, Chart-Quelltext)
        self.state = {}                 # id -> {"step", "error", "pid", "started", "restarts"}
        self.log = []                   # (Stufe, Text) fürs Protokoll
        self._procs = {}                # id -> Popen (nur zum Prüfen, ob noch läuft)
        self._ps = (0, {})              # (Zeit, {Pfad: [PIDs]}) laufende terminal64.exe
        self._busy = set()
        self.link = None                # Mt5Link (von der Engine gesetzt): MT5 sauber über FVG-Bridge schließen

    # ── Grundlagen ──
    @property
    def terms(self):
        return (self.cfg.get("mt5") or {}).get("terminals") or []

    def folder(self, t):
        return os.path.join(self.base, t["id"])

    @staticmethod
    def exe_of(folder):
        for n in ("terminal64.exe", "terminal.exe"):
            p = os.path.join(folder, n)
            if os.path.isfile(p):
                return p
        return None

    def _say(self, msg, level="info"):
        self.log.append((level, msg))

    @staticmethod
    def installs():
        """Gefundene MT5-Installationen (Vorlagen), z. B. das FTMO- oder IQ-MT5."""
        found = {}
        appdata = os.environ.get("APPDATA") or ""
        base = os.path.join(appdata, "MetaQuotes", "Terminal")
        try:
            names = os.listdir(base)
        except OSError:
            names = []
        for n in names:
            o = os.path.join(base, n, "origin.txt")
            try:
                raw = open(o, "rb").read()
                txt = raw.decode("utf-16") if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else raw.decode("utf-8", "replace")
                path = txt.strip().strip("\x00").strip()
            except OSError:
                continue
            if path and Mt5Terminals.exe_of(path):
                found[os.path.normcase(path)] = path
        for root in (os.environ.get("ProgramFiles"), os.environ.get("ProgramFiles(x86)")):
            if not root:
                continue
            try:
                for n in os.listdir(root):
                    p = os.path.join(root, n)
                    if os.path.isdir(p) and Mt5Terminals.exe_of(p):
                        found.setdefault(os.path.normcase(p), p)
            except OSError:
                pass
        return [{"path": p, "name": os.path.basename(p.rstrip("\\/"))} for p in sorted(found.values())]

    @staticmethod
    def data_folders():
        """[(Datenordner, Programmpfad)] der normal installierten MT5 (dort liegt u. a. die Serverliste servers.dat)."""
        import glob
        out = []
        bases = [os.path.join(os.environ.get("APPDATA") or "", "MetaQuotes", "Terminal")]
        if os.name == "nt":
            bases += glob.glob(os.path.join(os.environ.get("SystemDrive", "C:") + "\\", "Users", "*", "AppData", "Roaming", "MetaQuotes", "Terminal"))
        seen = set()
        pairs = []
        for base in bases:
            if os.path.normcase(base) in seen:
                continue
            seen.add(os.path.normcase(base))
            try:
                pairs += [(base, n) for n in os.listdir(base)]
            except OSError:
                pass
        for base, n in pairs:
            try:
                raw = open(os.path.join(base, n, "origin.txt"), "rb").read()
                txt = raw.decode("utf-16") if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else raw.decode("utf-8", "replace")
            except OSError:
                continue
            out.append((os.path.join(base, n), txt.strip().strip("\x00").strip()))
        return out

    def copy_servers(self, t):
        """Serverliste (servers.dat) der Firma in die eigene MT5-Kopie übernehmen. Ohne sie kennt eine frische
        Kopie z. B. „BeyondIQCapital-Server“ nicht und die Anmeldung scheitert still."""
        import shutil
        src = os.path.normcase((t.get("base") or "").rstrip("\\/"))
        names = [str(t.get("server") or "").strip()]
        needles = [n.encode(enc) for n in names if n for enc in ("utf-16-le", "utf-8")]
        words = {w for w in re.split(r"[^a-z0-9]+", str(t.get("server") or "").lower()) if len(w) >= 3} - {"server", "demo", "live", "real"}
        best = (0, 0, None)
        for data, origin in self.data_folders():
            f = os.path.join(data, "config", "servers.dat")
            if not os.path.isfile(f):
                f = os.path.join(data, "Config", "servers.dat")
                if not os.path.isfile(f):
                    continue
            oname = re.sub(r"[^a-z0-9]+", "", os.path.basename(origin.rstrip("\\/")).lower())
            try:   # kennt diese Serverliste den Server schon (dort war man schon mal angemeldet)?
                raw = open(f, "rb").read()
                known = any(n in raw for n in needles)
            except OSError:
                known = False
            score = (4 if known else 3 if os.path.normcase(origin.rstrip("\\/")) == src
                     else 2 if any(w in oname or oname and oname in w for w in words) else 1)
            cand = (score, os.path.getmtime(f), f)
            if cand[:2] > best[:2]:
                best = cand
        if not best[2]:
            return False
        d = os.path.join(self.folder(t), "Config")
        os.makedirs(d, exist_ok=True)
        try:
            shutil.copy2(best[2], os.path.join(d, "servers.dat"))
            return True
        except OSError:
            return False

    def _ensure_include(self, t):
        """FVG-Bridge braucht <Trade\\Trade.mqh>. Eine frische Kopie hat die MT5-Standard-Bibliothek erst nach dem
        ersten Start, deshalb aus der Vorlage (oder einem installierten MT5) übernehmen."""
        import shutil
        dst = os.path.join(self.folder(t), "MQL5", "Include")
        if os.path.isfile(os.path.join(dst, "Trade", "Trade.mqh")):
            return True
        src = (t.get("base") or "").rstrip("\\/")
        cands = [os.path.join(src, "MQL5", "Include")] if src else []
        same = [d for d, o in self.data_folders() if os.path.normcase(o.rstrip("\\/")) == os.path.normcase(src)]
        cands += [os.path.join(d, "MQL5", "Include") for d in same]
        cands += [os.path.join(d, "MQL5", "Include") for d, _ in self.data_folders() if d not in same]
        for c in cands:
            if os.path.isfile(os.path.join(c, "Trade", "Trade.mqh")):
                try:
                    shutil.copytree(c, dst, dirs_exist_ok=True)
                    self._say(f"MT5 „{t['name']}“: MT5-Standard-Bibliothek übernommen")
                    return True
                except OSError:
                    continue
        return False

    def _compile(self, t):
        import subprocess
        dst = self.folder(t)
        me = next((os.path.join(dst, n) for n in ("metaeditor64.exe", "metaeditor.exe") if os.path.isfile(os.path.join(dst, n))), None)
        if not me or os.name != "nt":
            return
        self._ensure_include(t)
        st = self.state.setdefault(t["id"], {})
        st["step"] = "übersetze FVG-Bridge …"
        for sub, fn in (("Experts", "FVG-Bridge.mq5"), ("Indicators", "FVG-Chart.mq5")):
            try:
                # MetaEditor/MT5 lesen den Pfad nach „/compile:“ selbst aus: mit Leerzeichen (z. B. „Neuer Ordner“)
                # nur in der Form /compile:"Pfad", sonst endet er beim ersten Leerzeichen
                cl = f'"{me}" /portable /compile:"{os.path.join(dst, "MQL5", sub, fn)}" /log:"{os.path.join(dst, "kompilieren.log")}"'
                subprocess.run(cl, timeout=120, creationflags=0x08000000)
            except (OSError, subprocess.SubprocessError) as e:
                self._say(f"MT5 „{t['name']}“: Übersetzen von {fn} fehlgeschlagen: {e}", "warn")
        st["step"] = ""
        if not os.path.isfile(os.path.join(dst, "MQL5", "Experts", "FVG-Bridge.ex5")):
            self._say(f"MT5 „{t['name']}“: FVG-Bridge ließ sich noch nicht übersetzen, nächster Versuch beim nächsten Start", "warn")

    def _ensure_servers(self, t):
        """Serverliste der Kopie: fehlt sie, übernehmen. Kennt sie den Server des Kontos nicht, aber ein anderes MT5
        auf diesem Rechner schon, dessen Liste nachholen (z. B. nachdem man sich dort einmal angemeldet hat)."""
        import shutil
        dst = self.folder(t)
        cur = next((os.path.join(dst, c, "servers.dat") for c in ("Config", "config") if os.path.isfile(os.path.join(dst, c, "servers.dat"))), None)
        if not cur:
            if self.copy_servers(t):
                self._say(f"MT5 „{t['name']}“: Serverliste der Firma übernommen")
            return
        if self._knows_server(cur, t):
            return
        src = self._server_file_knowing(t)
        if src and os.path.normcase(src) != os.path.normcase(cur):
            try:
                shutil.copy2(cur, cur + ".vorher")   # nichts still überschreiben
                shutil.copy2(src, cur)
                self._say(f"MT5 „{t['name']}“: Serverliste mit „{t.get('server')}“ aus einem anderen MT5 übernommen")
            except OSError:
                pass

    @staticmethod
    def _knows_server(path, t):
        name = str(t.get("server") or "").strip()
        if not name:
            return True
        try:
            raw = open(path, "rb").read()
        except OSError:
            return False
        return any(name.encode(enc) in raw for enc in ("utf-16-le", "utf-8"))

    def _server_file_knowing(self, t):
        """servers.dat eines installierten MT5, das den Server des Kontos kennt (neueste zuerst), sonst None."""
        best = None
        for data, _origin in self.data_folders():
            for c in ("config", "Config"):
                f = os.path.join(data, c, "servers.dat")
                if os.path.isfile(f) and self._knows_server(f, t):
                    if not best or os.path.getmtime(f) > os.path.getmtime(best):
                        best = f
                    break
        return best

    @staticmethod
    def _read_log(path, tail=400):
        try:
            raw = open(path, "rb").read()[-200000:]
        except OSError:
            return []
        if raw[:2] == b"\xff\xfe" or raw[1:200:2].count(0) > 50:   # MT5 schreibt Protokolle als UTF-16
            txt = raw[len(raw) % 2:].decode("utf-16-le", "replace")
        else:
            txt = raw.decode("utf-8", "replace")
        return [l.strip().lstrip("\ufeff") for l in txt.splitlines() if l.strip()][-tail:]

    @staticmethod
    def _newest(folder, pattern="*.log"):
        import glob
        fs = glob.glob(os.path.join(folder, pattern))
        return max(fs, key=os.path.getmtime) if fs else None

    def diagnose(self, t):
        """Grund aus den MT5-Protokollen der Kopie lesen: (kurzer Satz, letzte Zeilen). Leer, wenn nichts auffällt."""
        dst = self.folder(t)
        if not os.path.isdir(dst):
            return "", []
        ex5 = os.path.join(dst, "MQL5", "Experts", "FVG-Bridge.ex5")
        if self.exe_of(dst) and not os.path.isfile(ex5):
            comp = self._read_log(os.path.join(dst, "kompilieren.log"), 30)
            errs = [l for l in comp if " error" in l.lower() or "error " in l.lower()]
            return ("FVG-Bridge wurde in dieser MT5-Kopie nicht übersetzt (FVG-Bridge.ex5 fehlt). "
                    "Bitte „Neu starten“, sonst in dieser Kopie einmal den MetaEditor öffnen."), (errs or comp)[-5:]
        lines = []
        lg = self._newest(os.path.join(dst, "logs"))
        if lg:
            lines = self._read_log(lg)
        hint = ""
        last = {}
        for i, l in enumerate(lines):
            low = l.lower()
            for k, pat in (("cfg", "cannot load config"), ("auth_fail", "authorization on"), ("auth_ok", "authorized on"), ("no_srv", "no connection"),
                           ("invalid", "invalid account"), ("ea_ok", "fvg-bridge"), ("algo_off", "automated trading is disabled"),
                           ("algo_off", "algo trading is disabled")):
                if pat in low:
                    if k == "auth_fail" and "failed" not in low:
                        continue
                    if k == "ea_ok" and not ("loaded successfully" in low or "removed" in low or "cannot" in low):
                        continue
                    last[k] = (i, l)
        if "cfg" in last and last["cfg"][0] > last.get("auth_ok", (-1,))[0]:
            hint = "MT5 konnte die Start-Datei mit Login und Server nicht lesen. Bitte „Neu starten“."
        elif "auth_fail" in last and last["auth_fail"][0] > last.get("auth_ok", (-1,))[0] or "invalid" in last:
            hint = ("Anmeldung abgelehnt: Login, Passwort (Trading-/Master-Passwort, nicht Investor) oder Server stimmt nicht. "
                    "Unter „Bearbeiten“ prüfen.")
        elif "no_srv" in last and last["no_srv"][0] > last.get("auth_ok", (-1,))[0]:
            hint = "MT5 findet den Server nicht. Server-Name genau wie in den Zugangsdaten eintragen und die richtige MT5-Vorlage der Firma wählen."
        elif "ea_ok" in last and ("removed" in last["ea_ok"][1].lower() or "cannot" in last["ea_ok"][1].lower()):
            hint = "FVG-Bridge wurde in MT5 entfernt oder konnte nicht geladen werden. Bitte „Neu starten“."
        elif "algo_off" in last:
            hint = "In diesem MT5 ist Algo Trading aus. Bitte „Neu starten“ oder im MT5-Fenster oben „Algo Trading“ einschalten."
        elif lines and "auth_ok" not in last:
            tried = any(k in l.lower() for l in lines for k in ("authoriz", "connection to", "network"))
            if not tried:
                hint = (f"MT5 versucht gar nicht, sich anzumelden: Diese MT5-Kopie kennt den Server „{t.get('server') or '?'}“ noch nicht. "
                        "Einmal im MT5-Fenster dieses Kontos über Datei → „Bei Handelskonto anmelden“ den Server suchen und mit "
                        "Login und Passwort anmelden. Stimmt der Server-Name nicht genau mit den Zugangsdaten überein, unter „Bearbeiten“ korrigieren.")
            else:
                hint = "MT5 hat sich noch nicht beim Server angemeldet."
        keys = ("authoriz", "connection", "fvg-bridge", "account", "trading", "error", "failed", "expert")
        rel = [l for l in lines if any(k in l.lower() for k in keys)][-4:] or lines[-4:]
        ea = self._newest(os.path.join(dst, "MQL5", "Logs"))
        if ea:
            rel += [l for l in self._read_log(ea, 50) if "fvg" in l.lower() or "error" in l.lower() or "fehler" in l.lower()][-3:]
        mask = str(t.get("password") or "")
        rel = [(l.replace(mask, "•••") if len(mask) >= 4 else l)[:220] for l in rel]
        return hint, rel

    # ── laufende Programme ──
    def _running_map(self):
        """{Programmpfad (klein): [PIDs]} aller laufenden terminal64.exe. Unter Windows per PowerShell, höchstens alle 10 s."""
        import subprocess
        ts, m = self._ps
        if time.time() - ts < 10:
            return m
        m = {}
        if os.name == "nt":
            try:
                out = subprocess.run(["powershell", "-NoProfile", "-Command",
                                      "Get-Process terminal64,terminal -ErrorAction SilentlyContinue | "
                                      "ForEach-Object { \"$($_.Id)|$($_.Path)\" }"],
                                     capture_output=True, text=True, timeout=20, creationflags=0x08000000).stdout
                for line in out.splitlines():
                    pid, _, path = line.strip().partition("|")
                    if path:
                        m.setdefault(os.path.normcase(os.path.dirname(path)), []).append(int(pid))
            except (OSError, ValueError, subprocess.SubprocessError):
                pass
        self._ps = (time.time(), m)
        return m

    def running(self, t):
        p = self._procs.get(t["id"])
        if p is not None and p.poll() is None:
            return True
        return bool(self._running_map().get(os.path.normcase(self.folder(t))))

    # ── Einrichten ──
    def setup(self, t):
        """Kopie der Vorlage anlegen (nur beim ersten Mal), Bridge und Chart-Vorlage einspielen und übersetzen."""
        import shutil
        import subprocess
        st = self.state.setdefault(t["id"], {})
        dst = self.folder(t)
        src = t.get("base") or ""
        if not self.exe_of(dst):
            if not src or not self.exe_of(src):
                raise BrokerError("MT5-Vorlage nicht gefunden: bitte das MT5-Programm der Firma auswählen")
            st["step"] = "kopiere MT5 …"
            os.makedirs(self.base, exist_ok=True)
            shutil.copytree(src, dst, dirs_exist_ok=True,
                            ignore=shutil.ignore_patterns("logs", "*.log", "Tester", "Bases", "tmp"))
        self._ensure_servers(t)
        bridge, chart = self.sources()
        for sub, fn, code in (("Experts", "FVG-Bridge.mq5", bridge), ("Indicators", "FVG-Chart.mq5", chart)):
            d = os.path.join(dst, "MQL5", sub)
            os.makedirs(d, exist_ok=True)
            with open(os.path.join(d, fn), "w", encoding="utf-8-sig", newline="\r\n") as f:
                f.write(code)
        self._compile(t)
        st["step"] = ""
        st["ready"] = True

    def _ini(self, t):
        fam = "NQ"
        acc = ((self.cfg.get("mt5") or {}).get("accounts") or {}).get(str(t["login"])) or {}
        sym = acc.get("sym_" + fam) or (self.cfg.get("mt5") or {}).get("sym_" + fam) or "US100.cash"
        mins = int((self.cfg.get("mt5") or {}).get("chart_minutes") or 5)
        per = {1: "M1", 3: "M3", 5: "M5", 15: "M15", 30: "M30", 60: "H1", 240: "H4"}.get(mins, "M5")
        return ("[Common]\r\n"
                f"Login={t['login']}\r\nPassword={t.get('password') or ''}\r\nServer={t['server']}\r\n"
                "KeepPrivate=1\r\nNewsEnable=0\r\nCertInstall=1\r\n"
                "[Experts]\r\nAllowLiveTrading=1\r\nAllowDllImport=0\r\nEnabled=1\r\nAccount=0\r\nProfile=0\r\n"
                f"[StartUp]\r\nExpert=FVG-Bridge\r\nSymbol={sym}\r\nPeriod={per}\r\n")

    def start(self, t, reason="von Hand"):
        import subprocess
        if t["id"] in self._busy:
            raise BrokerError("wird gerade eingerichtet")
        if self.running(t):
            return {"ok": True, "already": True}
        self._busy.add(t["id"])
        st = self.state.setdefault(t["id"], {})
        try:
            if not st.get("ready") or not self.exe_of(self.folder(t)):
                self.setup(t)
            dst = self.folder(t)
            self._ensure_servers(t)
            if not os.path.isfile(os.path.join(dst, "MQL5", "Experts", "FVG-Bridge.ex5")):
                self._compile(t)
            ini = os.path.join(dst, "fvg-start.ini")
            with open(ini, "w", encoding="utf-16", newline="") as f:   # MT5 liest die Start-Datei als Unicode
                f.write(self._ini(t))
            fake = os.environ.get("FVG_MT5_LAUNCH")   # nur für Tests: nachgebautes MT5
            if os.name == "nt" and os.environ.get("FVG_SERVICE") and not fake:
                user = self._start_as_user(t, self.exe_of(dst), dst, ini)
                st.update(started=time.time(), pid=0, manual_stop=False, user=user)
                self._ps = (0, {})
                self._scrub_later(t, ini)
                self._say(f"MT5 „{t['name']}“ ({t['login']}) im Benutzerkonto {user} gestartet ({reason})")
                return {"ok": True}
            if fake:
                cmd = [sys_executable(), fake, dst, ini]
                kw = {}
            else:
                exe = self.exe_of(dst)
                if os.name != "nt":
                    raise BrokerError("MT5 automatisch starten geht nur unter Windows")
                cmd = f'"{exe}" /portable /config:"{ini}"'   # Form /config:"Pfad", sonst stört ein Leerzeichen im Pfad
                si = subprocess.STARTUPINFO()
                si.dwFlags |= 0x00000001           # STARTF_USESHOWWINDOW
                si.wShowWindow = 7                 # minimiert, ohne den Fokus zu nehmen
                kw = {"startupinfo": si, "creationflags": 0x00000008 | 0x00000200}   # unabhängig von der App
            self._procs[t["id"]] = subprocess.Popen(cmd, cwd=dst, close_fds=True, **kw)
            st.update(started=time.time(), pid=self._procs[t["id"]].pid, manual_stop=False)
            self._ps = (0, {})

            self._scrub_later(t, ini)
            self._say(f"MT5 „{t['name']}“ ({t['login']}) gestartet ({reason})")
            return {"ok": True}
        except (OSError, BrokerError) as e:
            st["error"] = str(e)
            raise BrokerError(f"MT5 „{t['name']}“ konnte nicht starten: {e}")
        finally:
            self._busy.discard(t["id"])

    def _scrub_later(self, t, ini):
        def scrub():   # Passwort aus der Start-Datei entfernen, sobald MT5 sie gelesen hat
            time.sleep(90)
            try:
                with open(ini, "w", encoding="utf-16", newline="") as f:
                    f.write(self._ini(dict(t, password="")))
            except OSError:
                pass
        threading.Thread(target=scrub, daemon=True).start()

    def _start_as_user(self, t, exe, dst, ini):
        """Als Dienst: MT5 direkt in der Windows-Sitzung des angemeldeten Benutzers starten (auch wenn das
        Remotedesktop-Fenster zu ist). Klappt das nicht, über eine Windows-Aufgabe."""
        import subprocess
        try:   # vorher: angemeldete Benutzer dürfen die von SYSTEM angelegte Kopie beschreiben (Protokolle, Einstellungen)
            subprocess.run(["icacls", dst, "/grant", "*S-1-5-11:(OI)(CI)M", "/T", "/Q"], capture_output=True, timeout=120,
                           creationflags=0x08000000)
        except (OSError, subprocess.SubprocessError):
            pass
        try:
            user, pid = user_session_spawn(f'"{exe}" /portable /config:"{ini}"', dst)
        except Exception as e:   # noqa: BLE001  (ctypes kann alles Mögliche werfen; dann Weg über die Aufgabe)
            if getattr(e, "nouser", False):
                raise BrokerError("Die App läuft als Dienst, aber niemand ist am PC/Server angemeldet. MT5 braucht ein angemeldetes "
                                  "Windows-Konto: einmal per Remotedesktop anmelden, das Fenster danach nur schließen (nicht abmelden).")
            self._say(f"MT5 „{t['name']}“: direkter Start in der Benutzer-Sitzung ging nicht ({e}), versuche Windows-Aufgabe", "info")
            return self._start_via_task(t, exe, dst, ini)
        return user

    def _start_via_task(self, t, exe, dst, ini):
        """Die App läuft als Dienst (Konto SYSTEM, ohne Bildschirm). Ein von dort gestartetes MT5 hätte kein Fenster und
        schriebe in den Ordner von SYSTEM. Darum MT5 über eine Windows-Aufgabe im angemeldeten Benutzerkonto starten."""
        import subprocess
        q = lambda s: "'" + str(s).replace("'", "''") + "'"
        task = "FVG Trader MT5 " + t["id"]
        script = f"""$ErrorActionPreference = 'Stop'
$o = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Select-Object -First 1 | Invoke-CimMethod -MethodName GetOwner
if (-not $o -or -not $o.User) {{ Write-Output 'NOUSER'; exit 0 }}
$u = if ($o.Domain) {{ $o.Domain + '\\' + $o.User }} else {{ $o.User }}
& icacls {q(dst)} /grant ($u + ':(OI)(CI)F') /T /Q | Out-Null
$a = New-ScheduledTaskAction -Execute {q(exe)} -Argument {q('/portable /config:"' + ini + '"')} -WorkingDirectory {q(dst)}
$p = New-ScheduledTaskPrincipal -UserId $u -LogonType Interactive -RunLevel Highest
$s = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName {q(task)} -Action $a -Principal $p -Settings $s -Force | Out-Null
Start-ScheduledTask -TaskName {q(task)}
Write-Output ('OK ' + $u)
"""
        try:
            r = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script],
                               capture_output=True, text=True, timeout=60, creationflags=0x08000000)
        except (OSError, subprocess.SubprocessError) as e:
            raise BrokerError(f"Start im Benutzerkonto fehlgeschlagen: {e}")
        out = (r.stdout or "").strip().splitlines()
        last = out[-1] if out else ""
        if last == "NOUSER":
            raise BrokerError("Die App läuft als Dienst, aber niemand ist am PC/Server angemeldet. MT5 braucht ein angemeldetes "
                              "Windows-Konto: einmal per Remotedesktop anmelden, das Fenster danach nur schließen (nicht abmelden).")
        if not last.startswith("OK "):
            err = ((r.stderr or "").strip().splitlines() or ["unbekannter Fehler"])[-1]
            raise BrokerError(f"Start im Benutzerkonto fehlgeschlagen: {err[:200]}")
        return last[3:]

    def _quit_clean(self, t):
        """MT5 über FVG-Bridge (ab 2.06) sauber schließen lassen. Nur so speichert MT5 eine neue Anmeldung und die
        Serverliste. True, wenn MT5 danach wirklich zu ist."""
        if self.link is None or os.environ.get("FVG_MT5_LAUNCH"):
            return False
        try:
            a = self.link.accounts().get(str(t["login"])) or {}
            if not a.get("online") or self.link._num(a.get("version"), 0) < 2.06:
                return False
            r = self.link.send([(str(t["login"]), {"action": "quit"})], wait=6.0)
            if not r or not r[0].get("ok"):
                return False
        except Exception:  # noqa: BLE001
            return False
        for _ in range(20):
            time.sleep(1)
            self._ps = (0, {})
            if not self._running_map().get(os.path.normcase(self.folder(t))):
                return True
        return False

    def stop(self, t, manual=True):
        import subprocess
        if self._quit_clean(t):
            self._procs.pop(t["id"], None)
        pids = list(self._running_map().get(os.path.normcase(self.folder(t)), []))
        p = self._procs.pop(t["id"], None)
        if p is not None and p.poll() is None:
            pids.append(p.pid)
        for pid in set(pids):
            try:
                if os.name == "nt":
                    subprocess.run(["taskkill", "/PID", str(pid), "/T"], capture_output=True, timeout=20, creationflags=0x08000000)
                else:
                    os.kill(pid, 15)
            except (OSError, subprocess.SubprocessError):
                pass
        if os.name == "nt" and pids:   # hängt MT5 z. B. in einem offenen Dialog, hart beenden
            for _ in range(8):
                time.sleep(1)
                self._ps = (0, {})
                if not self._running_map().get(os.path.normcase(self.folder(t))):
                    break
            else:
                for pid in self._running_map().get(os.path.normcase(self.folder(t)), []):
                    try:
                        subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"], capture_output=True, timeout=20, creationflags=0x08000000)
                    except (OSError, subprocess.SubprocessError):
                        pass
        self._ps = (0, {})
        st = self.state.setdefault(t["id"], {})
        st["stopped"] = time.time()
        st["manual_stop"] = manual
        self._say(f"MT5 „{t['name']}“ beendet" + (" (bleibt aus bis zum nächsten Start)" if manual else ""))
        return {"ok": True}

    def watch(self, accounts):
        """Wächter: Konten mit „automatisch starten“, deren MT5 nicht läuft oder sich lange nicht meldet, neu starten."""
        for t in self.terms:
            if not t.get("auto", True) or t["id"] in self._busy:
                continue
            st = self.state.setdefault(t["id"], {})
            if st.get("manual_stop"):
                continue   # von Hand beendet: bleibt aus, bis jemand „Starten“ drückt
            if time.time() - st.get("started", 0) < 180 or time.time() - st.get("stopped", 0) < 60:
                continue   # gerade gestartet oder von Hand beendet: abwarten
            a = accounts.get(str(t["login"])) or {}
            alive = self.running(t)
            if alive and a.get("online"):
                st["restarts"] = 0
                st["error"] = ""
                continue
            if alive and (not a or time.time() - a.get("seen", 0) < 300):
                continue   # läuft, meldet sich aber (noch) nicht: z. B. Anmeldung läuft, Wochenende
            if alive:
                self._say(f"MT5 „{t['name']}“ meldet sich seit über 5 Minuten nicht: Neustart", "warn")
                self.stop(t, manual=False)
                st["stopped"] = 0
            if st.get("started"):   # der allererste Start zählt nicht als Neustart
                st["restarts"] = st.get("restarts", 0) + 1
            if st.get("restarts", 0) >= 2:
                st["error"] = ("MT5 meldet sich nach dem Start nicht. Bitte Login, Passwort (Trading-Passwort, nicht Investor) "
                               "und Server prüfen, oder einmal „Neu starten“ und im MT5-Fenster nachsehen.")
            if st.get("restarts", 0) > 5:
                if st.get("restarts") == 6:
                    self._say(f"MT5 „{t['name']}“ startet immer wieder nicht. Bitte prüfen (Login, Server, Vorlage).", "error")
                continue
            try:
                self.start(t, reason="Wächter")
            except BrokerError as e:
                self._say(str(e), "error")


def user_session_spawn(cmdline, cwd):
    """Programm aus einem Windows-Dienst (SYSTEM) heraus in der Sitzung des angemeldeten Benutzers starten
    (WTSQueryUserToken + CreateProcessAsUser). Nimmt die aktive Sitzung, sonst eine getrennte Remotedesktop-Sitzung.
    Gibt (Benutzer, PID) zurück. OSError mit .nouser=True, wenn niemand angemeldet ist."""
    import ctypes
    from ctypes import wintypes as W
    wts, adv, k32, uenv = ctypes.WinDLL("wtsapi32", use_last_error=True), ctypes.WinDLL("advapi32", use_last_error=True), \
        ctypes.WinDLL("kernel32", use_last_error=True), ctypes.WinDLL("userenv", use_last_error=True)

    class SessInfo(ctypes.Structure):
        _fields_ = [("SessionId", W.DWORD), ("pWinStationName", W.LPWSTR), ("State", ctypes.c_int)]

    class StartupInfo(ctypes.Structure):
        _fields_ = [("cb", W.DWORD), ("lpReserved", W.LPWSTR), ("lpDesktop", W.LPWSTR), ("lpTitle", W.LPWSTR),
                    ("dwX", W.DWORD), ("dwY", W.DWORD), ("dwXSize", W.DWORD), ("dwYSize", W.DWORD),
                    ("dwXCountChars", W.DWORD), ("dwYCountChars", W.DWORD), ("dwFillAttribute", W.DWORD),
                    ("dwFlags", W.DWORD), ("wShowWindow", W.WORD), ("cbReserved2", W.WORD),
                    ("lpReserved2", ctypes.c_void_p), ("hStdInput", W.HANDLE), ("hStdOutput", W.HANDLE), ("hStdError", W.HANDLE)]

    class ProcInfo(ctypes.Structure):
        _fields_ = [("hProcess", W.HANDLE), ("hThread", W.HANDLE), ("dwProcessId", W.DWORD), ("dwThreadId", W.DWORD)]

    def fail(what):
        return OSError(f"{what} (Windows-Fehler {ctypes.get_last_error()})")

    pinfo, count = ctypes.POINTER(SessInfo)(), W.DWORD()
    if not wts.WTSEnumerateSessionsW(None, 0, 1, ctypes.byref(pinfo), ctypes.byref(count)):
        raise fail("Sitzungen nicht lesbar")
    try:
        sess = [(pinfo[i].SessionId, pinfo[i].State) for i in range(count.value)]
    finally:
        wts.WTSFreeMemory(pinfo)
    token, user = None, ""
    for sid, state in sorted([x for x in sess if x[1] in (0, 4)], key=lambda x: x[1]):   # 0 = aktiv, 4 = getrennt
        tk = W.HANDLE()
        if wts.WTSQueryUserToken(W.ULONG(sid), ctypes.byref(tk)):
            buf, n = W.LPWSTR(), W.DWORD()
            name = dom = ""
            if wts.WTSQuerySessionInformationW(None, sid, 5, ctypes.byref(buf), ctypes.byref(n)):   # Benutzername
                name = buf.value or ""
                wts.WTSFreeMemory(buf)
            if wts.WTSQuerySessionInformationW(None, sid, 7, ctypes.byref(buf), ctypes.byref(n)):   # Domäne
                dom = buf.value or ""
                wts.WTSFreeMemory(buf)
            token, user = tk, (dom + "\\" + name) if dom else name
            break
    if token is None:
        e = OSError("niemand angemeldet")
        e.nouser = True
        raise e
    primary, env = W.HANDLE(), ctypes.c_void_p()
    try:
        if not adv.DuplicateTokenEx(token, 0x02000000, None, 2, 1, ctypes.byref(primary)):
            raise fail("Anmelde-Token nicht kopierbar")
        if not uenv.CreateEnvironmentBlock(ctypes.byref(env), primary, False):
            env = ctypes.c_void_p()
        si = StartupInfo()
        si.cb = ctypes.sizeof(StartupInfo)
        si.lpDesktop = "winsta0\\default"
        si.dwFlags = 0x00000001          # STARTF_USESHOWWINDOW
        si.wShowWindow = 7               # minimiert, ohne Fokus
        pi = ProcInfo()
        cmd = ctypes.create_unicode_buffer(cmdline)
        flags = 0x00000400 | 0x00000200   # CREATE_UNICODE_ENVIRONMENT | CREATE_NEW_PROCESS_GROUP
        if not adv.CreateProcessAsUserW(primary, None, cmd, None, None, False, flags, env, cwd, ctypes.byref(si), ctypes.byref(pi)):
            raise fail("Start in der Benutzer-Sitzung abgelehnt")
        k32.CloseHandle(pi.hThread)
        k32.CloseHandle(pi.hProcess)
        return user, pi.dwProcessId
    finally:
        if env:
            uenv.DestroyEnvironmentBlock(env)
        if primary:
            k32.CloseHandle(primary)
        k32.CloseHandle(token)


def sys_executable():
    import sys
    return sys.executable


class Mt5Broker:
    """Der Bot handelt über MetaTrader 5 – auf allen Konten, bei denen „Bot handelt hier“ angehakt ist.
    Preise aus TradingView (NQ/ES) werden über den aktuellen Abstand auf das MT5-Symbol (z. B. US100.cash) umgerechnet."""
    name = "mt5"
    label = "MetaTrader 5"

    def __init__(self, cfg):
        self.cfg = cfg
        self.link = Mt5Link(cfg)

    @property
    def mcfg(self):
        return self.link.mcfg

    def _bot_accounts(self):
        conf = self.mcfg.get("accounts") or {}
        return [(lg, c) for lg, c in conf.items() if c.get("bot")]

    def connect(self):
        self.link.ensure_dir()
        self.link.write_symbols()
        accs = self.link.accounts()
        on = [lg for lg, _ in self._bot_accounts() if accs.get(lg, {}).get("online")]
        total = len(self._bot_accounts())
        if not total:
            return "MetaTrader 5: noch kein Konto für den Bot angehakt"
        return f"MetaTrader 5: {len(on)} von {total} Konten verbunden"

    def contract_name(self, root):
        sym = self.mcfg.get("sym_" + mt5_family(root)) or ("US500.cash" if mt5_family(root) == "ES" else "US100.cash")
        return f"{sym} ({root})"

    @staticmethod
    def _split(contract):
        m = re.match(r"^(.*) \((\w+)\)$", contract or "")
        return (m.group(1), m.group(2)) if m else (contract, "MNQ")

    @staticmethod
    def lots_for(spec, usd_per_point, factor):
        """Lotgröße, die usd_per_point × factor entspricht (abgerundet auf die Schrittweite)."""
        if not spec or spec["tick_size"] <= 0 or spec["tick_value"] <= 0:
            return 0.0
        per_lot = spec["tick_value"] / spec["tick_size"]
        step = spec["vol_step"] or 0.01
        lots = math.floor(usd_per_point * factor / per_lot / step + 1e-9) * step
        if spec["vol_max"] and lots > spec["vol_max"]:
            lots = spec["vol_max"]
        return round(lots, 2) if lots >= (spec["vol_min"] or step) - 1e-9 else 0.0

    def open(self, contract, side, qty, price, sl, tp, tick):
        sym, root = self._split(contract)
        self.link.write_symbols()
        accs = self.link.accounts()
        conf = self._bot_accounts()
        if not conf:
            raise BrokerError("Kein MT5-Konto für den Bot angehakt (Einstellungen → MetaTrader 5)")
        need = [(lg, self.link.sym_for(lg, mt5_family(root))) for lg, _ in conf]
        for _ in range(6):   # neu eingetragenes Symbol: kurz warten, bis FVG-Bridge es meldet
            if all(not (accs.get(lg) or {}).get("online") or s_ in ((accs.get(lg) or {}).get("symbols") or {}) for lg, s_ in need):
                break
            time.sleep(0.5)
            accs = self.link.accounts()
        usd_pp = qty * MT5_PV.get(root, 2.0)
        jobs, plan, warnings = [], {}, []
        for login, c in conf:
            a = accs.get(login)
            if not a or not a["online"]:
                warnings.append(f"MT5-Konto {login}: nicht verbunden, Trade dort ausgelassen")
                continue
            if not a["can_trade"]:
                warnings.append(f"MT5-Konto {login}: Algo Trading ist aus, Trade dort ausgelassen")
                continue
            cb = mt5_cons_block(c, a)
            if cb:
                warnings.append(f"MT5-Konto {login}: {cb}")
                continue
            sym_a = self.link.sym_for(login, mt5_family(root))
            spec = a["symbols"].get(sym_a)
            if not spec:
                warnings.append(f"MT5-Konto {login}: Symbol {sym_a} nicht gefunden (Name prüfen unter Einstellungen → MetaTrader 5), Trade dort ausgelassen")
                continue
            fac = float(c.get("factor") or 1.0)
            room, why = mt5_rule_room(c, a)
            if room is not None and room <= 0:
                warnings.append(f"MT5-Konto {login}: {why}")
                continue
            risk_acc = usd_pp * fac * abs(price - sl)
            if room is not None and risk_acc > room:
                fac = fac * room / risk_acc   # Firmen-Regeln: Trade auf das erlaubte Risiko verkleinern
                warnings.append(f"MT5-Konto {login}: wegen Firmen-Regel „{why}“ verkleinert auf höchstens {room:,.0f} $ Risiko".replace(",", "."))
            lots = self.lots_for(spec, usd_pp, fac)
            if lots <= 0:
                warnings.append(f"MT5-Konto {login}: Größe unter der Mindest-Lotgröße" + (" (Firmen-Regeln lassen nur wenig Risiko zu)" if room is not None else "") + ", Trade dort ausgelassen")
                continue
            mid = (spec["bid"] + spec["ask"]) / 2
            if mid <= 0:
                warnings.append(f"MT5-Konto {login}: kein Kurs für {sym_a}, Trade dort ausgelassen")
                continue
            off = mid - price
            d = spec["digits"]
            sl_c = round(sl + off, d)
            tp_c = round(tp + off, d) if tp else 0
            if (side == "long" and sl_c >= spec["bid"]) or (side == "short" and sl_c <= spec["ask"]):
                warnings.append(f"MT5-Konto {login}: Stop läge schon hinter dem Kurs, Trade dort ausgelassen")
                continue
            plan[login] = {"offset": off, "lots": lots, "symbol": sym_a}
            jobs.append((login, {"action": "open", "symbol": sym_a, "side": "buy" if side == "long" else "sell",
                                 "volume": f"{lots:.2f}", "sl": sl_c, "tp": tp_c, "magic": MT5_BOT_MAGIC,
                                 "comment": "FVG " + root}))
        if not jobs:
            raise BrokerError("Auf keinem MT5-Konto ausgeführt: " + "; ".join(warnings))
        ref = {"symbol": sym, "root": root, "accounts": {}, "warnings": warnings}
        fill = None
        sent_at = time.time()
        before = {lg: {p["ticket"] for p in (accs.get(lg) or {}).get("positions") or []} for lg in plan}
        for r in self.link.send(jobs):
            lg = r["login"]
            if r.get("ok") and r.get("ticket") in (None, "", "0"):
                # MT5 hat ausgeführt, die Bridge kennt das Ticket aber nicht: die Position in den MT5-Daten suchen
                pos = self._find_new_position(lg, plan[lg]["symbol"], MT5_BOT_MAGIC, before.get(lg, set()), side)
                if pos:
                    r["ticket"], r["price"], r["volume"] = str(pos["ticket"]), str(pos["price"]), str(pos["volume"])
                else:
                    r["ok"] = False
                    r["error"] = ("Order wurde in MT5 ausgeführt, aber die Position ist der App unbekannt. "
                                  "Bitte in MT5 prüfen und bei Bedarf von Hand schließen")
            if r.get("ok") and r.get("ticket") and r.get("ticket") != "0":
                p = plan[lg]
                entry = self.link._num(r.get("price"), 0) or None
                ref["accounts"][lg] = {"ticket": int(r["ticket"]), "offset": p["offset"], "lots": self.link._num(r.get("volume"), p["lots"]),
                                       "entry": entry, "open": True, "symbol": p["symbol"]}
                if fill is None and entry:
                    fill = entry - p["offset"]
            else:
                warnings.append(f"MT5-Konto {lg}: {r.get('error') or 'abgelehnt'}")
        if not ref["accounts"]:
            raise BrokerError("Order auf keinem MT5-Konto ausgeführt: " + "; ".join(warnings))
        return (fill if fill is not None else price), ref

    def _find_new_position(self, login, symbol, magic, known, side, wait=4.0):
        """Bot-Position auf diesem Konto/Symbol, die vor dem Senden noch nicht da war (aus der Statusmeldung der Bridge)."""
        end = time.time() + wait
        while True:
            st = self.link.accounts().get(str(login)) or {}
            cands = [p for p in st.get("positions") or [] if p["symbol"] == symbol and p["magic"] == magic
                     and p["side"] == side and p["ticket"] not in known]
            if cands:
                newest = max(cands, key=lambda p: (p["time"], p["ticket"]))
                return newest
            if time.time() > end:
                return None
            time.sleep(0.5)

    def _open_tickets(self, pos):
        return [(lg, a) for lg, a in (pos["broker_ref"].get("accounts") or {}).items() if a.get("open", True)]

    def close(self, pos, price, tick):
        jobs = [(lg, {"action": "close", "ticket": a["ticket"]}) for lg, a in self._open_tickets(pos)]
        exit_ = None
        errors = []
        for r in self.link.send(jobs) if jobs else []:
            a = pos["broker_ref"]["accounts"][r["login"]]
            if r.get("ok"):
                a["open"] = False
                px = self.link._num(r.get("price"), 0)
                if exit_ is None and px:
                    exit_ = px - a["offset"]
            else:
                errors.append(f"{r['login']}: {r.get('error')}")
        if errors and len(errors) == len(jobs):
            raise BrokerError("Schließen fehlgeschlagen – " + "; ".join(errors))
        return exit_ if exit_ is not None else self._exit_from_deals(pos) or price

    def _modify(self, pos, key, val):
        jobs = []
        for lg, a in self._open_tickets(pos):
            v = 0 if val is None else val + a["offset"]
            jobs.append((lg, {"action": "modify", "ticket": a["ticket"], key: f"{v:.5f}"}))
        if not jobs:
            return True
        res = self.link.send(jobs)
        bad = [f"{r['login']}: {r.get('error')}" for r in res if not r.get("ok")]
        if bad and len(bad) == len(res):
            raise BrokerError("Ändern fehlgeschlagen – " + "; ".join(bad))
        return True

    def modify_stop(self, pos, new_sl):
        return self._modify(pos, "sl", new_sl)

    def modify_target(self, pos, new_tp):
        return self._modify(pos, "tp", new_tp)

    def _exit_from_deals(self, pos, accs=None):
        accs = accs or self.link.accounts()
        for lg, a in (pos["broker_ref"].get("accounts") or {}).items():
            deals = [d for d in (accs.get(lg) or {}).get("deals", []) if d["position"] == a["ticket"]]
            if deals:
                deals.sort(key=lambda d: d["time"])
                return deals[-1]["price"] - a["offset"]
        return None

    def sync(self, positions):
        if not positions:
            return []
        accs = self.link.accounts()
        closed = []
        for pos in positions:
            ref = pos["broker_ref"]
            still = False
            for lg, a in (ref.get("accounts") or {}).items():
                if not a.get("open", True):
                    continue
                st = accs.get(lg)
                if not st or not st["online"] or st["seen"] < (pos.get("opened") or 0) + 1:
                    still = True       # Konto meldet sich gerade nicht: abwarten
                    continue
                if any(p["ticket"] == a["ticket"] for p in st["positions"]):
                    still = True
                else:
                    a["open"] = False
            if not still:
                closed.append((pos, self._exit_from_deals(pos, accs)))
        return closed

    def balance(self):
        accs = self.link.accounts()
        for lg, _ in self._bot_accounts():
            if accs.get(lg, {}).get("online") and accs[lg].get("balance") is not None:
                return accs[lg]["balance"]
        return None


class Mt5Copier:
    """Copytrading: Positionen des Hauptkontos (von Hand eröffnet) werden auf die angehakten Konten kopiert.
    Stop, Ziel, Teilschließungen und Schließen werden nachgezogen. Kopiert wird erst, wenn die Position einen Stop hat."""

    def __init__(self, cfg, state_path):
        self.cfg = cfg
        self.link = Mt5Link(cfg)
        self.path = state_path
        self.state = {"map": {}, "started": False}
        self.status = {"last": None, "error": "", "copies": 0, "waiting": []}
        self.log = []          # (Stufe, Text) für das Protokoll der App
        try:
            with open(state_path, encoding="utf-8") as f:
                self.state.update(json.load(f))
        except (OSError, ValueError):
            pass

    def _save(self):
        tmp = self.path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(self.state, f)
        os.replace(tmp, self.path)

    def _say(self, msg, level="info"):
        self.log.append((level, msg))

    def tick(self):
        cc = (self.cfg.get("mt5") or {}).get("copy") or {}
        master = str(cc.get("master") or "")
        if not cc.get("enabled") or not master:
            self.state["started"] = False
            return
        accs = self.link.accounts()
        m = accs.get(master)
        if not m or not m["online"]:
            self.status["error"] = f"Hauptkonto {master} meldet sich nicht"
            return
        self.status["error"] = ""
        conf = (self.cfg.get("mt5") or {}).get("accounts") or {}
        followers = [(lg, c) for lg, c in conf.items() if c.get("copy") and lg != master]
        mpos = {p["ticket"]: p for p in m["positions"] if p["magic"] not in (MT5_BOT_MAGIC, MT5_COPY_MAGIC)}
        mp = self.state["map"]
        if not self.state.get("started"):
            # beim Einschalten bereits offene Positionen nicht nachträglich kopieren
            for t in mpos:
                mp.setdefault(str(t), {"skip": True})
            self.state["started"] = True
            self._save()
        jobs, meta = [], []
        waiting = []
        self.link.write_symbols(extra=[p["symbol"] for p in mpos.values()])
        for t, p in mpos.items():
            entry = mp.setdefault(str(t), {"copies": {}, "sl": None, "tp": None, "vol": p["volume"]})
            if entry.get("skip"):
                continue
            if p["sl"] <= 0 and not entry["copies"]:
                waiting.append(p["symbol"])
                continue
            for lg, c in followers:
                if lg in entry["copies"] or lg in entry.get("failed", {}):
                    continue
                st = accs.get(lg)
                if not st or not st["online"] or not st["can_trade"]:
                    continue
                cb = mt5_cons_block(c, st)
                if cb:
                    entry.setdefault("failed", {})[lg] = "Konsistenzregel"
                    self._say(f"Copytrading: Konto {lg} · {cb}", "warn")
                    continue
                fam = self.link.fam_of(master, p["symbol"])
                fsym = self.link.sym_for(lg, fam) if fam else p["symbol"]
                spec = st["symbols"].get(fsym)
                if not spec:
                    entry.setdefault("failed", {})[lg] = "Symbol fehlt"
                    self._say(f"Copytrading: Konto {lg} kennt {fsym} nicht, Kopie ausgelassen", "warn")
                    continue
                mspec = m["symbols"].get(p["symbol"]) or {}
                step = spec["vol_step"] or 0.01
                ratio = 1.0
                if fsym != p["symbol"] and mspec.get("tick_size") and spec["tick_size"] and spec["tick_value"]:
                    ratio = (mspec["tick_value"] / mspec["tick_size"]) / (spec["tick_value"] / spec["tick_size"])
                lots = math.floor(p["volume"] * ratio * float(c.get("factor") or 1.0) / step + 1e-9) * step
                off = 0.0
                if fsym != p["symbol"] and mspec.get("bid") and spec["bid"]:
                    off = (spec["bid"] + spec["ask"]) / 2 - (mspec["bid"] + mspec["ask"]) / 2
                d = spec["digits"]
                room, why = mt5_rule_room(c, st)
                if room is not None and p["sl"] > 0 and spec["tick_size"] > 0:
                    risk_c = abs(p["price"] - p["sl"]) / spec["tick_size"] * spec["tick_value"] * lots
                    if room <= 0:
                        entry.setdefault("failed", {})[lg] = "Firmen-Regeln"
                        self._say(f"Copytrading: Konto {lg} · {why}", "warn")
                        continue
                    if risk_c > room:
                        lots = math.floor(lots * room / risk_c / step + 1e-9) * step
                        self._say(f"Copytrading: Kopie für Konto {lg} wegen Firmen-Regel „{why}“ verkleinert", "info")
                if lots < (spec["vol_min"] or step) - 1e-9:
                    entry.setdefault("failed", {})[lg] = "zu klein"
                    self._say(f"Copytrading: Kopie für Konto {lg} wäre kleiner als die Mindest-Lotgröße", "warn")
                    continue
                jobs.append((lg, {"action": "open", "symbol": fsym, "side": "buy" if p["side"] == "long" else "sell",
                                  "volume": f"{lots:.2f}", "sl": round(p["sl"] + off, d), "tp": round(p["tp"] + off, d) if p["tp"] else 0,
                                  "magic": MT5_COPY_MAGIC, "comment": f"Kopie {t}"}))
                meta.append(("open", str(t), lg, (round(lots, 2), off)))
            # Stop/Ziel nachziehen
            if entry["copies"] and (entry.get("sl") != p["sl"] or entry.get("tp") != p["tp"]):
                for lg, cp in entry["copies"].items():
                    if p["sl"] > 0:
                        o = cp.get("off", 0.0)
                        jobs.append((lg, {"action": "modify", "ticket": cp["ticket"], "sl": f"{p['sl'] + o:.5f}",
                                          "tp": f"{p['tp'] + o:.5f}" if p["tp"] else 0}))
                        meta.append(("modify", str(t), lg, None))
            # Teilschließung
            if entry["copies"] and entry.get("vol") and p["volume"] < entry["vol"] - 1e-9:
                frac = 1 - p["volume"] / entry["vol"]
                for lg, cp in entry["copies"].items():
                    jobs.append((lg, {"action": "close", "ticket": cp["ticket"], "volume": f"{cp['lots'] * frac:.2f}"}))
                    meta.append(("partial", str(t), lg, cp["lots"] * (1 - frac)))
        # Hauptposition geschlossen: Kopien schließen
        for t, entry in list(mp.items()):
            if int(t) in mpos:
                continue
            if entry.get("skip") or not entry.get("copies"):
                mp.pop(t, None)
                continue
            for lg, cp in entry["copies"].items():
                jobs.append((lg, {"action": "close", "ticket": cp["ticket"]}))
                meta.append(("close", t, lg, None))
        self.status["waiting"] = waiting
        if jobs:
            results = self.link.send(jobs)
            for (kind, t, lg, extra), r in zip(meta, results):
                entry = mp.get(t)
                if entry is None:
                    continue
                if kind == "open":
                    if r.get("ok") and r.get("ticket") not in (None, "", "0"):
                        entry["copies"][lg] = {"ticket": int(r["ticket"]), "lots": self.link._num(r.get("volume"), extra[0]), "off": extra[1]}
                        self.status["copies"] += 1
                        self._say(f"Copytrading: Trade {t} auf Konto {lg} kopiert ({entry['copies'][lg]['lots']:g} Lot)")
                    elif not r.get("unclear"):
                        entry.setdefault("failed", {})[lg] = r.get("error") or "abgelehnt"
                        self._say(f"Copytrading: Kopie auf Konto {lg} fehlgeschlagen: {r.get('error')}", "error")
                elif kind == "partial" and r.get("ok"):
                    entry["copies"][lg]["lots"] = round(extra, 2)
                elif kind == "close":
                    if r.get("ok"):
                        entry["copies"].pop(lg, None)
                    else:
                        self._say(f"Copytrading: Kopie auf Konto {lg} ließ sich nicht schließen: {r.get('error')}", "error")
            for t, entry in list(mp.items()):
                if int(t) not in mpos and not entry.get("copies"):
                    mp.pop(t, None)
        for t, p in mpos.items():
            e = mp.get(str(t))
            if e and not e.get("skip") and e.get("copies"):
                e["sl"], e["tp"], e["vol"] = p["sl"], p["tp"], p["volume"]
        self.status["last"] = time.time()
        self._save()


BROKERS = {"paper": PaperBroker, "topstep": TopstepBroker, "mt5": Mt5Broker}
