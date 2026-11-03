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
