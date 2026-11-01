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
| `quellcode/` | Quellcode, aus dem `FVG-Trader.cmd` gebaut wird (`python3 quellcode/build_onefile.py 1.9.7 "Notiz"`) |

## Funktionen

- Strategien: FVG, iFVG, Silver Bullet, Opening Range Breakout, Liquidity Sweep, VWAP-Reclaim (Pine Script in der App kopierbar)
- Auto-Modus an/aus, sonst Vorschläge zum Annehmen oder Ablehnen
- Positionsgröße: feste Anzahl, Risiko in $ oder in % vom Konto, Mini oder Micro
- Pflicht-Stop-Loss (Safe-Stop), Tagesverlust-Limit, News-Filter, Notaus
- Lernmodul: bewertet jede Strategie täglich anhand von Schatten-Trades
- Kalender mit Tages-, Wochen- und Monats-P&L, eigene Trades (eintragen oder CSV-Import), Filter Bot/Eigene, Statistiken
- Paper-Trading und Tradovate (Demo/Live); eigene Tradovate-Trades werden automatisch in den Kalender übernommen

Keine Anlageberatung. Futures sind gehebelt, teste zuerst im Paper-Modus.
