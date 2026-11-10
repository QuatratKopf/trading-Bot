"""Strategie-Finder: sucht in den gespeicherten Kursdaten nach Einstiegs-Modellen bekannter Trader
(ICT 2022, Silver Bullet, Judas Swing, Turtle Soup, Opening Range Breakout, Holy Grail, Orderblock, Breaker, OTE, CRT …)
und verlangt für jedes Modell mehrere unabhängige Bestätigungen. Bewertet wird ehrlich: nach Gebühren,
mit Prüfung in einer späteren Zeit-Hälfte und danach im Probelauf auf neuen Kerzen."""
import math

DC_DETECTORS = {
    "fvg":   {"name": "FVG-Retest", "short": "FVG", "N": (30,), "K": (0.3, 0.5, 0.8)},
    "ob":    {"name": "Orderblock-Retest", "short": "Orderblock", "N": (5, 10, 20), "K": (1.0, 1.5, 2.0)},
    "brk":   {"name": "Breaker-Block", "short": "Breaker", "N": (5, 10, 20), "K": (1.0, 1.5, 2.0)},
    "sweep": {"name": "Liquiditäts-Sweep", "short": "Sweep", "N": (10, 20, 40), "K": (0.0, 0.15, 0.3)},
    "bos":   {"name": "BOS-Pullback / OTE", "short": "OTE", "N": (10, 20, 40), "K": (0.5, 0.618, 0.705, 0.79)},
    "rng":   {"name": "Range-Ausbruch", "short": "Range", "N": (10, 20, 40), "K": (2.0, 3.0, 4.0)},
    "mr":    {"name": "Rückkehr zum Mittel", "short": "Mittel", "N": (20, 50), "K": (1.5, 2.0, 2.5)},
    "judas": {"name": "Judas Swing (Asia-Range-Sweep)", "short": "Judas Swing", "N": (1,), "K": (0.0, 0.1, 0.25)},
    "pdhl":  {"name": "Turtle Soup (Vortages-Hoch/Tief)", "short": "Turtle Soup", "N": (1,), "K": (0.0, 0.1, 0.25)},
    "crt":   {"name": "Candle Range Theory", "short": "CRT", "N": (15, 60, 240), "K": (0.0, 0.15)},
    "orb":   {"name": "Opening Range Breakout", "short": "ORB", "N": (5, 15, 30), "K": (0.5, 1.0)},
    "hg":    {"name": "Holy Grail (Trend-Rücklauf zur EMA)", "short": "Holy Grail", "N": (20,), "K": (25.0, 30.0)},
}
# Herkunft der Modelle (für die Anzeige)
DC_ORIGIN = {
    "fvg": "ICT (Michael Huddleston)", "ob": "ICT / Smart Money", "brk": "ICT / Smart Money", "sweep": "ICT / Smart Money",
    "bos": "ICT (Optimal Trade Entry)", "judas": "ICT (Power of 3)", "pdhl": "Linda Raschke & Larry Connors", "crt": "Candle Range Theory",
    "orb": "Toby Crabel / Zarattini-Studie", "hg": "Linda Raschke", "rng": "klassischer Ausbruch", "mr": "klassische Gegenbewegung",
}

# ───────── Bestätigungen: unabhängige Gründe für einen Trade, nur aus Kerzen berechnet, die schon fertig sind ─────────
CF_FACTORS = {
    "fvg":   {"name": "Fair Value Gap", "short": "FVG",
              "text": "Der Kurs testet gerade eine offene Kurslücke (Fair Value Gap) in Trade-Richtung."},
    "sweep": {"name": "Liquiditäts-Sweep", "short": "Sweep",
              "text": "In den letzten 45 Minuten wurden auf der Gegenseite Stops abgeholt (Vortag, Asien, London, NY-Vormittag oder markantes Hoch/Tief) und der Kurs kam zurück."},
    "mss":   {"name": "Strukturbruch (MSS)", "short": "MSS",
              "text": "In den letzten 30 Minuten hat eine kräftige Kerze das letzte Zwischenhoch bzw. -tief in Trade-Richtung durchbrochen und der Kurs hält sich darüber."},
    "ob":    {"name": "Orderblock", "short": "OB",
              "text": "Der Kurs reagiert an der letzten Gegenkerze vor einem starken Ausbruch."},
    "htf":   {"name": "Übergeordneter Trend", "short": "Trend",
              "text": "Der 15-Minuten-Trend (EMA 50) und der Stunden-Trend zeigen beide in Trade-Richtung, der Kurs liegt auf der richtigen Seite."},
    "pd":    {"name": "Günstige Zone", "short": "Zone",
              "text": "Long im unteren Drittel der 24-Stunden-Spanne (Discount), Short im oberen Drittel (Premium)."},
    "kerze": {"name": "Umkehrkerze", "short": "Kerze",
              "text": "Die Signalkerze selbst zeigt Ablehnung: Hammer/Pin-Bar oder eine Kerze, die die vorherige Gegenkerze komplett umschließt."},
}
CF_KEYS = tuple(CF_FACTORS)
CF_BIT = {k: 1 << i for i, k in enumerate(CF_KEYS)}
# Welche Bestätigung ein Auslöser selbst schon mitbringt (zählt als eine)
DC_OWN = {"fvg": "fvg", "ob": "ob", "sweep": "sweep", "judas": "sweep", "pdhl": "sweep", "crt": "sweep", "bos": "mss"}
CF_TRIPLES = (("sweep", "mss", "htf"), ("sweep", "mss", "fvg"), ("sweep", "mss", "pd"), ("sweep", "mss", "kerze"),
              ("mss", "htf", "fvg"), ("sweep", "fvg", "htf"), ("sweep", "kerze", "pd"), ("mss", "htf", "kerze"), ("sweep", "fvg", "pd"))


def cf_mask(keys):
    m = 0
    for k in keys:
        m |= CF_BIT[k]
    return m


def cf_keys(mask):
    return [k for k in CF_KEYS if mask & CF_BIT[k]]


def cf_reqs(det, min_conf):
    """Pflicht-Bestätigungen, die der Finder für einen Auslöser durchprobiert (Auslöser zählt als eine)."""
    own = DC_OWN.get(det)
    rest = [k for k in CF_KEYS if k != own]
    singles = [(a,) for a in rest]
    pairs = [(a, b) for i, a in enumerate(rest) for b in rest[i + 1:]]
    triples = [t for t in CF_TRIPLES if own not in t]
    need = max(1, int(min_conf) - 1)
    pool = {1: singles + pairs, 2: pairs + triples, 3: triples}.get(need, triples)
    return [r for r in pool if len(r) >= need]


def cf_compute(o, h, l, c, P, tf):
    """Je Kerze zwei Bitmasken (Long, Short): welche Bestätigungen zum Schluss dieser Kerze vorliegen."""
    N = len(c)
    FL, FS = [0] * N, [0] * N
    if N < 30:
        return FL, FS
    atr, hm, day = P["atr"], P.get("hm"), P.get("day")
    tf = max(1, int(tf))
    B_FVG, B_SW, B_MSS, B_OB, B_HTF, B_PD, B_KZ = (CF_BIT[k] for k in CF_KEYS)
    w_sw, w_ms, w_rt = max(4, 45 // tf), max(3, 30 // tf), 2
    z_age, life, life_major = max(20, 150 // tf), max(200, 1440 // tf), max(600, 3 * 1440 // tf)
    n_htf, k_htf = max(20, 750 // tf), max(3, 60 // tf)
    a_htf, a_h2 = 2.0 / (n_htf + 1), 2.0 / (4 * n_htf + 1)
    n_pd = max(50, 1440 // tf)
    PV, PM = max(8, 30 // tf), max(3, 10 // tf)
    hi10, lo10 = _dc_rmax(P, h, 10), _dc_rmin(P, l, 10)
    from collections import deque
    highs, lows = [], []          # Liquidität: [Kurs, entstanden, wichtig, angestochen seit, Extrem]
    pend_h = pend_l = 0
    hi_min = lo_max = None
    sw_l, sw_s = (-10 ** 9, 0.0), (-10 ** 9, 0.0)   # letzter Sweep: (Kerze, Extrem)
    last_sh = last_sl = None
    mss_d, mss_i, mss_lv = 0, -10 ** 9, 0.0
    zl, zs, obl, obs = [], [], [], []   # offene Zonen: [oben, unten, verfällt]
    rt_l = rt_s = ort_l = ort_s = -10 ** 9
    ema, ema2, em = c[0], c[0], [0.0] * N
    qmax, qmin = deque(), deque()
    cur_day = None
    dh = dl = None
    rng = {"asia": [1200, 1440, None, None], "london": [120, 300, None, None], "nyam": [570, 690, None, None]}

    def add(lst, price, i, major, is_high):
        if price is None or (is_high and c[i] >= price) or (not is_high and c[i] <= price):
            return
        lst.append([price, i, major, -1, price])
        if len(lst) > 40:
            for x in lst:
                if not x[2]:
                    lst.remove(x)
                    break
            else:
                lst.pop(0)

    for i in range(N):
        a = atr[i]
        hi, lo, cl, op = h[i], l[i], c[i], o[i]
        changed = False
        # ── neue Liquiditäts-Marken: Vortag und Sessions ──
        if day is not None:
            if day[i] != cur_day:
                if cur_day is not None:
                    add(highs, dh, i, True, True)
                    add(lows, dl, i, True, False)
                    changed = True
                cur_day, dh, dl = day[i], hi, lo
            else:
                if hi > dh:
                    dh = hi
                if lo < dl:
                    dl = lo
            m = hm[i]
            for r in rng.values():
                if r[0] <= m < r[1]:
                    r[2] = hi if r[2] is None or hi > r[2] else r[2]
                    r[3] = lo if r[3] is None or lo < r[3] else r[3]
                elif r[2] is not None:
                    add(highs, r[2], i, True, True)
                    add(lows, r[3], i, True, False)
                    r[2] = r[3] = None
                    changed = True
        # ── markante Hochs/Tiefs (bestätigt nach PV Kerzen) ──
        if i >= 2 * PV:
            j = i - PV
            if h[j] >= max(h[j - PV:i + 1]):
                add(highs, h[j], i, False, True)
                changed = True
            if l[j] <= min(l[j - PV:i + 1]):
                add(lows, l[j], i, False, False)
                changed = True
        # ── Sweep: Marke angestochen und zurück geschlossen (bis zu 2 Kerzen später) ──
        if highs and (pend_h or changed or hi_min is None or hi > hi_min):
            keep = []
            for lv in highs:
                pr = lv[0]
                if i - lv[1] > (life_major if lv[2] else life):
                    continue
                if lv[3] >= 0:
                    if hi > lv[4]:
                        lv[4] = hi
                    if cl < pr:
                        sw_s = (i, lv[4])
                        continue
                    if i - lv[3] >= 2:
                        continue
                    keep.append(lv)
                elif hi > pr and lv[1] < i:
                    if cl < pr:
                        sw_s = (i, hi)
                        continue
                    lv[3], lv[4] = i, hi
                    keep.append(lv)
                else:
                    keep.append(lv)
            highs = keep
            pend_h = sum(1 for lv in highs if lv[3] >= 0)
            hi_min = min(lv[0] for lv in highs) if highs else None
        if lows and (pend_l or changed or lo_max is None or lo < lo_max):
            keep = []
            for lv in lows:
                pr = lv[0]
                if i - lv[1] > (life_major if lv[2] else life):
                    continue
                if lv[3] >= 0:
                    if lo < lv[4]:
                        lv[4] = lo
                    if cl > pr:
                        sw_l = (i, lv[4])
                        continue
                    if i - lv[3] >= 2:
                        continue
                    keep.append(lv)
                elif lo < pr and lv[1] < i:
                    if cl > pr:
                        sw_l = (i, lo)
                        continue
                    lv[3], lv[4] = i, lo
                    keep.append(lv)
                else:
                    keep.append(lv)
            lows = keep
            pend_l = sum(1 for lv in lows if lv[3] >= 0)
            lo_max = max(lv[0] for lv in lows) if lows else None
        # ── Strukturbruch: Schluss durch das letzte Zwischenhoch/-tief mit kräftiger Kerze ──
        if a:
            if last_sh is not None and cl > last_sh:
                if cl - op >= a:
                    mss_d, mss_i, mss_lv = 1, i, last_sh
                last_sh = None
            if last_sl is not None and cl < last_sl:
                if op - cl >= a:
                    mss_d, mss_i, mss_lv = -1, i, last_sl
                last_sl = None
        if i >= 2 * PM:
            j = i - PM
            if h[j] >= max(h[j - PM:i + 1]):
                last_sh = h[j]
            if l[j] <= min(l[j - PM:i + 1]):
                last_sl = l[j]
        # ── FVG und Orderblock: Retest offener Zonen ──
        if zl:
            keep = []
            for z in zl:
                if i > z[2] or cl < z[1]:
                    continue
                if lo <= z[0]:
                    rt_l = i
                    continue
                keep.append(z)
            zl = keep
        if zs:
            keep = []
            for z in zs:
                if i > z[2] or cl > z[0]:
                    continue
                if hi >= z[1]:
                    rt_s = i
                    continue
                keep.append(z)
            zs = keep
        if obl:
            keep = []
            for z in obl:
                if i > z[2] or cl < z[1]:
                    continue
                if lo <= z[0]:
                    ort_l = i
                    continue
                keep.append(z)
            obl = keep
        if obs:
            keep = []
            for z in obs:
                if i > z[2] or cl > z[0]:
                    continue
                if hi >= z[1]:
                    ort_s = i
                    continue
                keep.append(z)
            obs = keep
        if a and i >= 2:
            if lo > h[i - 2] and lo - h[i - 2] >= 0.4 * a:
                zl.append([lo, h[i - 2], i + z_age])
                if len(zl) > 12:
                    zl.pop(0)
            elif hi < l[i - 2] and l[i - 2] - hi >= 0.4 * a:
                zs.append([l[i - 2], hi, i + z_age])
                if len(zs) > 12:
                    zs.pop(0)
            if hi10[i] is not None:
                if cl > hi10[i] and cl - op >= a:
                    for j in range(i - 1, max(i - 6, 0), -1):
                        if c[j] < o[j]:
                            obl.append([h[j], l[j], i + z_age * 2])
                            if len(obl) > 8:
                                obl.pop(0)
                            break
                elif cl < lo10[i] and op - cl >= a:
                    for j in range(i - 1, max(i - 6, 0), -1):
                        if c[j] > o[j]:
                            obs.append([h[j], l[j], i + z_age * 2])
                            if len(obs) > 8:
                                obs.pop(0)
                            break
        # ── Trend und 24-Stunden-Spanne ──
        ema += a_htf * (cl - ema)
        ema2 += a_h2 * (cl - ema2)
        em[i] = ema
        while qmax and h[qmax[-1]] <= hi:
            qmax.pop()
        qmax.append(i)
        while qmin and l[qmin[-1]] >= lo:
            qmin.pop()
        qmin.append(i)
        while qmax[0] <= i - n_pd:
            qmax.popleft()
        while qmin[0] <= i - n_pd:
            qmin.popleft()
        fl = fs = 0
        if i - rt_l < w_rt:
            fl |= B_FVG
        if i - rt_s < w_rt:
            fs |= B_FVG
        if i - sw_l[0] <= w_sw and cl > sw_l[1]:
            fl |= B_SW
        if i - sw_s[0] <= w_sw and cl < sw_s[1]:
            fs |= B_SW
        if i - mss_i <= w_ms:
            if mss_d > 0 and cl > mss_lv:
                fl |= B_MSS
            elif mss_d < 0 and cl < mss_lv:
                fs |= B_MSS
        if i - ort_l < w_rt:
            fl |= B_OB
        if i - ort_s < w_rt:
            fs |= B_OB
        if i >= n_htf:
            back = em[i - k_htf]
            if cl > ema > back and cl > ema2:
                fl |= B_HTF
            elif cl < ema < back and cl < ema2:
                fs |= B_HTF
        if i >= n_pd // 4:
            top, bot = h[qmax[0]], l[qmin[0]]
            if cl < bot + 0.382 * (top - bot):
                fl |= B_PD
            elif cl > top - 0.382 * (top - bot):
                fs |= B_PD
        rg = hi - lo
        if a and i and rg >= 0.8 * a:
            bd = abs(cl - op)
            if cl > op:
                if (c[i - 1] < o[i - 1] and cl >= o[i - 1] and op <= c[i - 1] and bd >= 0.5 * rg) or \
                        (min(op, cl) - lo >= 2 * bd and min(op, cl) - lo >= 0.5 * rg and hi - cl <= 0.25 * rg):
                    fl |= B_KZ
            if cl < op:
                if (c[i - 1] > o[i - 1] and cl <= o[i - 1] and op >= c[i - 1] and bd >= 0.5 * rg) or \
                        (hi - max(op, cl) >= 2 * bd and hi - max(op, cl) >= 0.5 * rg and cl - lo <= 0.25 * rg):
                    fs |= B_KZ
            elif cl >= op and min(op, cl) - lo >= 2 * bd and min(op, cl) - lo >= 0.6 * rg:
                fl |= B_KZ
        FL[i], FS[i] = fl, fs
    return FL, FS


# ───────── Bias: zu Beginn jeder Session wird aus fünf Bausteinen eine Tagesrichtung bestimmt ─────────
BS_PARTS = {
    "struktur": "Tages-Struktur",
    "schluss": "Schluss des Vortags",
    "trend": "Stunden-Trend",
    "nacht": "Verlauf seit Handelsstart",
    "woche": "Wochen-Eröffnung",
}
BS_SESS = (("asia", 1200, 1440), ("london", 120, 300), ("ny_am", 570, 690), ("ny_lunch", 690, 810), ("ny_pm", 810, 950))


def bs_sess(m):
    for k, a, b in BS_SESS:
        if a <= m < b:
            return k
    return None


def bias_compute(o, h, l, c, P):
    """Bias je Kerze (+1 bullisch, −1 bärisch, 0 neutral), festgelegt zu Beginn jeder Session und bis zur nächsten gültig.
    Rückgabe: (Liste, Einzelheiten der letzten Analyse). Nutzt nur Kerzen, die zum Session-Beginn schon fertig waren."""
    import datetime as _dt
    N = len(c)
    B = [0] * N
    hm, day, t = P.get("hm"), P.get("day"), P.get("t")
    if not hm or N < 2:
        return B, None
    d1 = d2 = None                 # letzter und vorletzter fertiger Handelstag: (hoch, tief, schluss)
    cur_day, dh, dl = None, None, None
    wk_open = None
    sw_lo = sw_hi = False          # seit Handelsstart unter das Vortagestief / über das Vortageshoch gelaufen
    ema, a_h, eh, last_hour = None, 2.0 / 49, [], None
    prev_sess, cur, info = None, 0, None
    for i in range(N):
        if day[i] != cur_day:
            if cur_day is not None:
                d2, d1 = d1, (dh, dl, c[i - 1])
            cur_day, dh, dl = day[i], h[i], l[i]
            sw_lo = sw_hi = False
            if _dt.date.fromordinal(day[i]).weekday() == 0 or wk_open is None:
                wk_open = o[i]
        else:
            if h[i] > dh:
                dh = h[i]
            if l[i] < dl:
                dl = l[i]
        hour = (day[i], hm[i] // 60)
        if hour != last_hour:
            if i:
                ema = c[i - 1] if ema is None else ema + a_h * (c[i - 1] - ema)
                eh.append(ema)
            last_hour = hour
        sess = bs_sess(hm[i])
        if sess and sess != prev_sess and d1:
            px = o[i]
            parts = []

            def part(key, v, text):
                parts.append({"k": key, "name": BS_PARTS[key], "v": v, "text": text})
            if d2:
                if d1[2] > d2[0]:
                    part("struktur", 1, "Der Vortag hat über dem Hoch des Tages davor geschlossen: Käufer haben die Kontrolle.")
                elif d1[2] < d2[1]:
                    part("struktur", -1, "Der Vortag hat unter dem Tief des Tages davor geschlossen: Verkäufer haben die Kontrolle.")
                elif d1[0] > d2[0] and d1[1] >= d2[1]:
                    part("struktur", -1, "Der Vortag hat das Hoch des Tages davor nur kurz überschritten und darunter geschlossen: Ausbruch gescheitert.")
                elif d1[1] < d2[1] and d1[0] <= d2[0]:
                    part("struktur", 1, "Der Vortag hat das Tief des Tages davor nur kurz unterschritten und darüber geschlossen: Ausbruch nach unten gescheitert.")
                else:
                    part("struktur", 0, "Der Vortag blieb innerhalb der Spanne des Tages davor oder hat beide Seiten geholt: keine klare Richtung.")
            rng = d1[0] - d1[1]
            pos = (d1[2] - d1[1]) / rng if rng > 0 else 0.5
            part("schluss", 1 if pos >= 0.67 else -1 if pos <= 0.33 else 0,
                 f"Der Vortag hat im {'oberen' if pos >= 0.67 else 'unteren' if pos <= 0.33 else 'mittleren'} Drittel seiner Spanne geschlossen.")
            if len(eh) >= 12:
                back = eh[-7] if len(eh) >= 7 else eh[0]
                if px > ema > back:
                    part("trend", 1, "Der Kurs liegt über dem steigenden 48-Stunden-Schnitt.")
                elif px < ema < back:
                    part("trend", -1, "Der Kurs liegt unter dem fallenden 48-Stunden-Schnitt.")
                else:
                    part("trend", 0, "Der Stunden-Trend ist uneinheitlich.")
            if sw_lo and not sw_hi and px > d1[1]:
                part("nacht", 1, "Seit Handelsstart wurde das Vortagestief abgeholt und der Kurs ist wieder darüber: Stops unten sind raus.")
            elif sw_hi and not sw_lo and px < d1[0]:
                part("nacht", -1, "Seit Handelsstart wurde das Vortageshoch abgeholt und der Kurs ist wieder darunter: Stops oben sind raus.")
            elif px > d1[0]:
                part("nacht", 1, "Der Kurs hält sich über dem Vortageshoch.")
            elif px < d1[1]:
                part("nacht", -1, "Der Kurs hält sich unter dem Vortagestief.")
            else:
                part("nacht", 0, "Der Kurs liegt innerhalb der Vortagesspanne, ohne dass eine Seite abgeholt wurde." if not (sw_lo or sw_hi)
                     else "Seit Handelsstart wurden beide Seiten der Vortagesspanne angelaufen.")
            if wk_open is not None:
                part("woche", 1 if px > wk_open else -1 if px < wk_open else 0,
                     f"Der Kurs liegt {'über' if px > wk_open else 'unter' if px < wk_open else 'auf'} der Wochen-Eröffnung.")
            score = sum(x["v"] for x in parts)
            cur = 1 if score >= 2 else -1 if score <= -2 else 0
            info = {"dir": cur, "score": score, "max": len(parts), "parts": parts, "sess": sess, "t": t[i] if t else None, "px": px,
                    "levels": {"pdh": d1[0], "pdl": d1[1], "pdc": d1[2], "wo": wk_open}}
        prev_sess = sess
        if d1:
            if l[i] < d1[1]:
                sw_lo = True
            if h[i] > d1[0]:
                sw_hi = True
        B[i] = cur
    return B, info


DC_TPS = (1.0, 1.5, 2.0, 3.0)
DC_SESS_SHORT = {"asia": "Asien", "london": "London", "ny_am": "NY-Vorm.", "ny_lunch": "NY-Mittag", "ny_pm": "NY-Nachm.",
              "aus": "Randzeiten", "alle": "ganztags", "sb": "SB-Fenster"}
DC_SESSIONS = ("alle", "asia", "london", "ny_am", "ny_lunch", "ny_pm", "sb")


def dc_in_sb(m):
    """Silver-Bullet-Fenster (New York): 3–4, 10–11 und 14–15 Uhr."""
    return 180 <= m < 240 or 600 <= m < 660 or 840 <= m < 900


def _dc_num(v):
    return (f"{v:g}").replace(".", ",")


def dc_describe(det, n, k, tf, d, tp, req=(), sess="alle"):
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
        "hg": f"Holy Grail: Starker Trend (ADX über {_dc_num(k)}), der Kurs läuft zur {n}er-EMA zurück. Schließt danach eine Kerze "
              f"{'über dem Hoch' if d > 0 else 'unter dem Tief'} der Vorkerze: {side} mit dem Trend. Stop hinter dem Rücklauf.",
    }[det]
    extra = ""
    if req:
        extra = " Pflicht dazu: " + " und ".join(CF_FACTORS[r]["name"] for r in req) + "."
    if sess == "sb":
        extra += " Nur in den Silver-Bullet-Fenstern (3–4, 10–11, 14–15 Uhr New York)."
    return f"{t}{extra} Ziel {_dc_num(tp)}R. Zeiteinheit {tf} Min."


def dc_model(det, req, sess):
    """Bekannter Name des Modells, wenn Auslöser und Bestätigungen dazu passen."""
    r = set(req)
    if det == "fvg" and sess == "sb":
        return "Silver Bullet"
    if det == "fvg" and {"sweep", "mss"} <= r:
        return "ICT 2022"
    return DC_DETECTORS[det]["short"]


def dc_name_of(det, tf, d, sess, req=(), fam="NQ"):
    base = dc_model(det, req, sess)
    rest = [r for r in req if not (base == "ICT 2022" and r in ("sweep", "mss"))]
    plus = "".join("+" + CF_FACTORS[r]["short"] for r in rest)
    where = "" if sess == "sb" and base == "Silver Bullet" else " " + DC_SESS_SHORT.get(sess, sess)
    name = f"{'' if fam == 'NQ' else fam + ' '}{base}{plus} {tf}m {'L' if d > 0 else 'S'}{where}"
    return name[:40]


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


def _dc_adx(h, l, c, n=14):
    """ADX mit +DI/−DI nach Wilder."""
    N = len(c)
    adx, pdi, mdi = [None] * N, [None] * N, [None] * N
    trs = pds = mds = 0.0
    dxs, dxn, prev = 0.0, 0, None
    for i in range(1, N):
        up, dn = h[i] - h[i - 1], l[i - 1] - l[i]
        pdm = up if up > dn and up > 0 else 0.0
        mdm = dn if dn > up and dn > 0 else 0.0
        tr = max(h[i] - l[i], abs(h[i] - c[i - 1]), abs(l[i] - c[i - 1]))
        if i <= n:
            trs, pds, mds = trs + tr, pds + pdm, mds + mdm
            if i < n:
                continue
        else:
            trs, pds, mds = trs - trs / n + tr, pds - pds / n + pdm, mds - mds / n + mdm
        if trs <= 0:
            continue
        p_, m_ = 100 * pds / trs, 100 * mds / trs
        pdi[i], mdi[i] = p_, m_
        dx = 100 * abs(p_ - m_) / (p_ + m_) if p_ + m_ > 0 else 0.0
        if dxn < n:
            dxs, dxn = dxs + dx, dxn + 1
            if dxn == n:
                prev = dxs / n
                adx[i] = prev
        else:
            prev = (prev * (n - 1) + dx) / n
            adx[i] = prev
    return adx, pdi, mdi


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
    elif det == "hg":
        key = ("adx", 14)
        if key not in P["cache"]:
            P["cache"][key] = _dc_adx(h, l, c)
        adx, pdi, mdi = P["cache"][key]
        ek = ("ema", n)
        if ek not in P["cache"]:
            e_, al, arr = c[0], 2.0 / (n + 1), [0.0] * N
            for i in range(N):
                e_ += al * (c[i] - e_)
                arr[i] = e_
            P["cache"][ek] = arr
        ema = P["cache"][ek]
        touch = None   # [richtung, kerze, extrem]
        for i in range(max(3 * 14 + n, start), N):
            a = atr[i]
            if not a or adx[i] is None:
                continue
            if touch:
                d, ti, ext = touch
                ext = min(ext, l[i]) if d > 0 else max(ext, h[i])
                touch[2] = ext
                if i - ti > 5 or (d > 0 and c[i] < ema[i] - 1.5 * a) or (d < 0 and c[i] > ema[i] + 1.5 * a):
                    touch = None
                elif d > 0 and c[i] > h[i - 1]:
                    out.append((i, 1, ext - tick))
                    touch = None
                    continue
                elif d < 0 and c[i] < l[i - 1]:
                    out.append((i, -1, ext + tick))
                    touch = None
                    continue
            if touch is None and adx[i] >= k:
                if pdi[i] > mdi[i] and l[i] <= ema[i] and c[i] > ema[i] - a and c[i - 1] > ema[i - 1]:
                    touch = [1, i, l[i]]
                elif mdi[i] > pdi[i] and h[i] >= ema[i] and c[i] < ema[i] + a and c[i - 1] < ema[i - 1]:
                    touch = [-1, i, h[i]]
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


def dc_simulate(sigs, o, h, l, c, t, tf_ms, entry_idx, cost_fn, min_stop, max_hold, F=None, own=0):
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
        m = ((F[0] if d > 0 else F[1])[i] | own) if F else own
        trades.append({"i": i, "e": e, "d": d, "risk": risk, "rs": rs, "ex": ex, "cost": cost_fn(entry, risk), "t": t[e], "m": m})
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


def dc_evaluate(trades, sess_of, tp_idx, d, sess, need=0, hm=None):
    """Trades einer Kandidaten-Strategie (Richtung, Session, Ziel, Pflicht-Bestätigungen) ohne Überschneidung, nach Gebühren."""
    out, busy = [], -1
    for tr in trades:
        if tr["d"] != d or tr["e"] <= busy or tr["m"] & need != need:
            continue
        if sess == "sb":
            if hm is None or not dc_in_sb(hm[tr["e"]]):
                continue
        elif sess != "alle" and sess_of(tr["t"]) != sess:
            continue
        busy = tr["ex"][tp_idx]
        out.append((tr["t"], tr["rs"][tp_idx] - tr["cost"]))
    return out
