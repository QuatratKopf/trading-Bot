"""Broker-Anbindungen: Paper-Trading (Simulation), Tradovate (REST-API) und Topstep (TopstepX-/ProjectX-API).

Jede Order wird als Bracket mit Stop-Loss geschickt. Ohne Stop verlässt keine Order die App.
"""
import datetime as dt
import json
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


BROKERS = {"paper": PaperBroker, "tradovate": TradovateBroker, "topstep": TopstepBroker}
