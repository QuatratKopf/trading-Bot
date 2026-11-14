"""Broker-Anbindungen: Paper-Trading (Simulation), Topstep (TopstepX-/ProjectX-API) und MetaTrader 5 (EA FVG-Bridge).

Jede Order wird als Bracket mit Stop-Loss geschickt. Ohne Stop verlässt keine Order die App.
"""
import datetime as dt
import json
import math
import os
import re
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


def mt5_family(root):
    return "ES" if "ES" in str(root).upper() else "NQ"


def mt5_default_dir():
    base = os.environ.get("APPDATA") or os.path.expanduser("~")
    return os.path.join(base, "MetaQuotes", "Terminal", "Common", "Files", "FVG")


class Mt5Link:
    """Dateibasierte Verbindung zu allen MT5-Fenstern, in denen der EA FVG-Bridge läuft."""

    def __init__(self, cfg):
        self.cfg = cfg
        self._cache = {}       # Dateiname -> (mtime, Daten)

    @property
    def mcfg(self):
        return self.cfg.setdefault("mt5", {})

    @property
    def dir(self):
        return os.environ.get("FVG_MT5_DIR") or self.mcfg.get("dir") or mt5_default_dir()

    def ensure_dir(self):
        try:
            os.makedirs(self.dir, exist_ok=True)
        except OSError as e:
            raise BrokerError(f"MT5-Ordner nicht beschreibbar: {e}")

    def write_symbols(self, extra=()):
        names = [self.mcfg.get("sym_NQ") or "US100.cash", self.mcfg.get("sym_ES") or "US500.cash", *extra]
        txt = "\r\n".join(dict.fromkeys(n.strip() for n in names if n and n.strip())) + "\r\n"
        path = os.path.join(self.dir, "symbols.txt")
        try:
            with open(path, encoding="latin-1") as f:
                if f.read() == txt.replace("\r\n", "\n"):
                    return
        except OSError:
            pass
        self.ensure_dir()
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="latin-1", newline="") as f:
            f.write(txt)
        os.replace(tmp, path)

    @staticmethod
    def _num(x, d=0.0):
        try:
            return float(x)
        except (TypeError, ValueError):
            return d

    def _parse(self, raw):
        a = {"positions": [], "symbols": {}, "deals": []}
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
        try:
            names = [n for n in os.listdir(self.dir) if n.startswith("status_") and n.endswith(".txt")]
        except OSError:
            return out
        now = time.time()
        for n in names:
            path = os.path.join(self.dir, n)
            try:
                mt = os.path.getmtime(path)
                hit = self._cache.get(n)
                if hit and hit[0] == mt:
                    a = hit[1]
                else:
                    with open(path, encoding="latin-1", errors="replace") as f:
                        a = self._parse(f.read())
                    self._cache[n] = (mt, a)
            except (OSError, ValueError):
                hit = self._cache.get(n)
                if not hit:
                    continue
                mt, a = hit
            login = str(a.get("login") or n[7:-4])
            a = dict(a, login=login, seen=mt, online=now - mt < MT5_ONLINE_SEC,
                     balance=self._num(a.get("balance"), None), equity=self._num(a.get("equity"), None),
                     can_trade=a.get("trade_allowed") == "1")
            out[login] = a
        return out

    def send(self, jobs, wait=8.0):
        """jobs: Liste (login, dict). Schreibt Aufträge, wartet auf die Antworten und gibt sie in derselben Reihenfolge zurück."""
        self.ensure_dir()
        sent = []
        for login, cmd in jobs:
            cid = uuid.uuid4().hex[:12]
            body = dict(cmd, id=cid, expires=int(time.time() + 20))
            txt = "".join(f"{k}={str(v).replace(chr(10), ' ').replace(chr(13), ' ')}\r\n" for k, v in body.items() if v is not None)
            tmp = os.path.join(self.dir, f"tmpcmd_{login}_{cid}.txt")
            with open(tmp, "w", encoding="latin-1", errors="replace", newline="") as f:
                f.write(txt)
            os.replace(tmp, os.path.join(self.dir, f"cmd_{login}_{cid}.txt"))
            sent.append((login, cid))
        results = {}
        end = time.time() + wait
        while len(results) < len(sent) and time.time() < end:
            for login, cid in sent:
                if (login, cid) in results:
                    continue
                path = os.path.join(self.dir, f"res_{login}_{cid}.txt")
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
                os.remove(os.path.join(self.dir, f"cmd_{login}_{cid}.txt"))
                results[(login, cid)] = {"ok": False, "error": "MT5 hat nicht geantwortet (EA oder Algo Trading aus?)"}
            except OSError:
                results[(login, cid)] = {"ok": False, "unclear": True,
                                         "error": "MT5 hat den Auftrag angenommen, aber nicht rechtzeitig geantwortet. Bitte in MT5 prüfen!"}
        return [dict(results[k], login=k[0]) for k in sent]


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
            spec = a["symbols"].get(sym)
            if not spec:
                warnings.append(f"MT5-Konto {login}: Symbol {sym} nicht gefunden, Trade dort ausgelassen")
                continue
            lots = self.lots_for(spec, usd_pp, float(c.get("factor") or 1.0))
            if lots <= 0:
                warnings.append(f"MT5-Konto {login}: Größe unter der Mindest-Lotgröße, Trade dort ausgelassen")
                continue
            mid = (spec["bid"] + spec["ask"]) / 2
            if mid <= 0:
                warnings.append(f"MT5-Konto {login}: kein Kurs für {sym}, Trade dort ausgelassen")
                continue
            off = mid - price
            d = spec["digits"]
            sl_c = round(sl + off, d)
            tp_c = round(tp + off, d) if tp else 0
            if (side == "long" and sl_c >= spec["bid"]) or (side == "short" and sl_c <= spec["ask"]):
                warnings.append(f"MT5-Konto {login}: Stop läge schon hinter dem Kurs, Trade dort ausgelassen")
                continue
            plan[login] = {"offset": off, "lots": lots}
            jobs.append((login, {"action": "open", "symbol": sym, "side": "buy" if side == "long" else "sell",
                                 "volume": f"{lots:.2f}", "sl": sl_c, "tp": tp_c, "magic": MT5_BOT_MAGIC,
                                 "comment": "FVG " + root}))
        if not jobs:
            raise BrokerError("Auf keinem MT5-Konto ausgeführt: " + "; ".join(warnings))
        ref = {"symbol": sym, "root": root, "accounts": {}, "warnings": warnings}
        fill = None
        for r in self.link.send(jobs):
            lg = r["login"]
            if r.get("ok") and r.get("ticket") and r.get("ticket") != "0":
                p = plan[lg]
                entry = self.link._num(r.get("price"), 0) or None
                ref["accounts"][lg] = {"ticket": int(r["ticket"]), "offset": p["offset"], "lots": self.link._num(r.get("volume"), p["lots"]),
                                       "entry": entry, "open": True}
                if fill is None and entry:
                    fill = entry - p["offset"]
            else:
                warnings.append(f"MT5-Konto {lg}: {r.get('error') or 'abgelehnt'}")
        if not ref["accounts"]:
            raise BrokerError("Order auf keinem MT5-Konto ausgeführt: " + "; ".join(warnings))
        return (fill if fill is not None else price), ref

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
                spec = st["symbols"].get(p["symbol"])
                if not spec:
                    entry.setdefault("failed", {})[lg] = "Symbol fehlt"
                    self._say(f"Copytrading: Konto {lg} kennt {p['symbol']} nicht, Kopie ausgelassen", "warn")
                    continue
                step = spec["vol_step"] or 0.01
                lots = math.floor(p["volume"] * float(c.get("factor") or 1.0) / step + 1e-9) * step
                if lots < (spec["vol_min"] or step) - 1e-9:
                    entry.setdefault("failed", {})[lg] = "zu klein"
                    self._say(f"Copytrading: Kopie für Konto {lg} wäre kleiner als die Mindest-Lotgröße", "warn")
                    continue
                jobs.append((lg, {"action": "open", "symbol": p["symbol"], "side": "buy" if p["side"] == "long" else "sell",
                                  "volume": f"{lots:.2f}", "sl": p["sl"], "tp": p["tp"], "magic": MT5_COPY_MAGIC,
                                  "comment": f"Kopie {t}"}))
                meta.append(("open", str(t), lg, round(lots, 2)))
            # Stop/Ziel nachziehen
            if entry["copies"] and (entry.get("sl") != p["sl"] or entry.get("tp") != p["tp"]):
                for lg, cp in entry["copies"].items():
                    if p["sl"] > 0:
                        jobs.append((lg, {"action": "modify", "ticket": cp["ticket"], "sl": p["sl"], "tp": p["tp"]}))
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
                        entry["copies"][lg] = {"ticket": int(r["ticket"]), "lots": self.link._num(r.get("volume"), extra)}
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
