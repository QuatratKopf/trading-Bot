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
