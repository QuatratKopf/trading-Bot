# FVG Trader

Trading-Bot für NQ- und ES-Futures. Er empfängt die Signale einer TradingView-Strategie, berechnet die Positionsgröße, setzt immer einen Stop-Loss und handelt entweder automatisch oder nach deiner Freigabe.

## Starten

1. **FVG-Trader.cmd** herunterladen (oben auf die Datei klicken → Download-Symbol).
2. Doppelklick. Fehlt Python, wird es einmalig automatisch installiert.
3. Die App öffnet sich in einem eigenen Fenster und legt ein Symbol **FVG Trader** auf dem Desktop an.

Mac/Linux: `python3 FVG-Trader.cmd`

## Updates

Beim Start prüft die App, ob hier eine neue Version liegt, und fragt **„Jetzt aktualisieren?“**. Ein Klick auf Ja genügt. Einstellungen, Trades und Lernstand bleiben erhalten (Ordner `FVG-Trader-Daten` neben der Datei).

| Datei | Zweck |
|---|---|
| `FVG-Trader.cmd` | Die komplette App in einer Datei |
| `version.json` | Versionsnummer und Prüfsumme für das Update-Popup |
| `releases/` | Jede Version als eigene, unveränderliche Datei (Quelle für Updates) |
| `quellcode/` | Quellcode, aus dem `FVG-Trader.cmd` gebaut wird (`python3 quellcode/build_onefile.py 2.19.0 "Notiz"`) |

## Funktionen

- Strategien: FVG, iFVG, Silver Bullet, Opening Range Breakout, Liquidity Sweep, VWAP-Reclaim (Pine Script in der App kopierbar)
- Auto-Modus an/aus, sonst Vorschläge zum Annehmen oder Ablehnen
- Sessions zum Anhaken: Asien, London, New York Vormittag, Mittag, Nachmittag, oder ganztägig (in App und Strategie)
- Performance-Ring im Cockpit (Zeitraum und Quelle wählbar), Tages-P&L-Grafik, Equity-Kurve
- Positionsgröße: feste Anzahl, Risiko in $ oder in % vom Konto, Mini oder Micro
- Pflicht-Stop-Loss (Safe-Stop), Tagesverlust-Limit, News-Filter im Script und News-Pause in der App (Wirtschaftskalender), Notaus
- Lernmodul: bewertet jede Strategie täglich anhand von Schatten-Trades, gesamt und je Session
- Backtest im Lernmodul: Trade-Liste aus dem TradingView-Strategietester einlesen (CSV/Excel) und nach Setup, Monat, Uhrzeit, Wochentag und News-Tagen auswerten
- Varianten-Labor: rechnet je Signal 8 Ausstiegs-Varianten mit (1R–3R, Break-even, Trailing, Session-Ende) und empfiehlt die beste nach Gegenprobe
- Regel-Finder: merkt sich die Marktlage je Signal und findet Bedingungen, unter denen eine Strategie klar besser oder schlechter läuft; Regeln per Klick als Filter übernehmen
- Kalender mit Tages-, Wochen- und Monats-P&L, eigene Trades (eintragen oder CSV-Import), Filter Bot/Eigene, Statistiken
- Reiter Fremdkapital: Prop-Firm-Challenge live (Verlustgrenze EOD/Intraday/statisch, Profitziel, Tageslimit, Konsistenz, Mindesttage, Bot-Schutz) plus Karte im Cockpit
- Offene Positionen: Einstieg, Stop und Ziel mit Abstand in Punkten, Ticks und Geld; Stop und Ziel verschieben, Break-even, Schließen
- Dienst-Modus für Windows-Server: startet beim Hochfahren ohne Anmeldung (Einstellungen → App & Updates)
- Key Levels im Cockpit: Vortageshoch/-tief/-schluss, Overnight, Asien, London, Midnight Open, Initial Balance, Gap
- Edge-Check je Strategie: Trefferquote mit 95-%-Bereich, Breakeven, Edge, Note A–D, Vertrauen, Wochentage, Stunden
- Session-Muster aus gesammelten Kerzen: Gap-Fill, London-/IB-/Asien-Breakout, PDH/PDL genommen, Zeitpunkt von Tageshoch und -tief
- Wirtschafts-News im Cockpit: wichtige US-Termine (CPI, NFP, FOMC …) mit Countdown
- Paper-Trading und Tradovate (Demo/Live); eigene Tradovate-Trades werden automatisch in den Kalender übernommen

Keine Anlageberatung. Futures sind gehebelt, teste zuerst im Paper-Modus.
