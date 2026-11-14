//+------------------------------------------------------------------+
//| FVG-Bridge.mq5                                                    |
//| Verbindet MetaTrader 5 mit der App "FVG Trader".                  |
//|                                                                   |
//| So funktioniert es:                                               |
//|  - Die App legt Auftraege als kleine Textdateien in den           |
//|    gemeinsamen MT5-Ordner (Common\Files\FVG).                     |
//|  - Dieser EA liest sie, fuehrt sie aus und schreibt das Ergebnis  |
//|    zurueck. Ausserdem meldet er jede Sekunde Kontostand,          |
//|    offene Positionen und abgeschlossene Deals.                    |
//|  - Keine Internetverbindung noetig, alles bleibt auf deinem PC.   |
//|                                                                   |
//| Einrichten: EA auf einen beliebigen Chart ziehen,                 |
//| "Algo Trading" oben in MT5 einschalten. Fertig.                   |
//| Pro MT5-Fenster (= pro Konto) einmal.                             |
//+------------------------------------------------------------------+
#property copyright "FVG Trader"
#property version   "1.00"
#property description "Verbindung zur App FVG Trader: Bot-Orders und Copytrading."

#include <Trade\Trade.mqh>

input long InpMagic    = 260626;  // Magic-Nummer fuer Bot-Orders
input int  InpSlippage = 30;      // Erlaubte Abweichung beim Einstieg (Punkte)

#define BRIDGE_VERSION "1"

CTrade   trade;
string   DIR = "FVG\\";
long     g_login = 0;
int      g_tick = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   g_login = AccountInfoInteger(ACCOUNT_LOGIN);
   FolderCreate("FVG", FILE_COMMON);
   trade.SetExpertMagicNumber((ulong)InpMagic);
   trade.SetDeviationInPoints((ulong)InpSlippage);
   EventSetMillisecondTimer(250);
   WriteStatus();
   Print("FVG-Bridge gestartet fuer Konto ", g_login);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   long login = AccountInfoInteger(ACCOUNT_LOGIN);
   if(login != g_login)
      g_login = login;   // Konto im selben Fenster gewechselt
   if(g_login <= 0)
      return;
   ProcessCommands();
   g_tick++;
   if(g_tick % 4 == 0)
      WriteStatus();
  }

//+------------------------------------------------------------------+
void OnTick()
  {
  }

//+------------------------------------------------------------------+
//| Hilfen                                                            |
//+------------------------------------------------------------------+
string Trim(string s)
  {
   StringTrimLeft(s);
   StringTrimRight(s);
   return(s);
  }

string Clean(string s)
  {
   StringReplace(s, "\r", " ");
   StringReplace(s, "\n", " ");
   StringReplace(s, "|", "/");
   return(s);
  }

string Err(string msg)
  {
   return("ok=0\r\nerror=" + Clean(msg) + "\r\n");
  }

string Get(string &keys[], string &vals[], string k)
  {
   for(int i = 0; i < ArraySize(keys); i++)
      if(keys[i] == k)
         return(vals[i]);
   return("");
  }

bool ReadKV(string path, string &keys[], string &vals[])
  {
   int f = FileOpen(path, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ);
   if(f == INVALID_HANDLE)
      return(false);
   int n = 0;
   while(!FileIsEnding(f))
     {
      string line = Trim(FileReadString(f));
      int p = StringFind(line, "=");
      if(p <= 0)
         continue;
      ArrayResize(keys, n + 1);
      ArrayResize(vals, n + 1);
      keys[n] = StringSubstr(line, 0, p);
      vals[n] = StringSubstr(line, p + 1);
      n++;
     }
   FileClose(f);
   return(n > 0);
  }

void WriteAtomic(string name, string content)
  {
   string tmp = DIR + "tmp_" + name;
   int f = FileOpen(tmp, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(f == INVALID_HANDLE)
      return;
   FileWriteString(f, content);
   FileClose(f);
   if(!FileMove(tmp, FILE_COMMON, DIR + name, FILE_COMMON | FILE_REWRITE))
      FileDelete(tmp, FILE_COMMON);
  }

double NormVol(string sym, double vol)
  {
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double mn   = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double mx   = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   if(step <= 0)
      step = 0.01;
   vol = MathFloor(vol / step + 1e-9) * step;
   if(vol < mn - 1e-9)
      return(0);
   if(mx > 0 && vol > mx)
      vol = mx;
   return(NormalizeDouble(vol, 2));
  }

ulong FindPosition(string sym, string comment)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t > 0 && PositionGetString(POSITION_SYMBOL) == sym && PositionGetString(POSITION_COMMENT) == comment)
         return(t);
     }
   return(0);
  }

bool RetOk(uint rc)
  {
   return(rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED || rc == TRADE_RETCODE_DONE_PARTIAL);
  }

//+------------------------------------------------------------------+
//| Auftraege                                                         |
//+------------------------------------------------------------------+
void ProcessCommands()
  {
   string name;
   string pattern = DIR + "cmd_" + IntegerToString(g_login) + "_*.txt";
   long h = FileFindFirst(pattern, name, FILE_COMMON);
   if(h == INVALID_HANDLE)
      return;
   string files[];
   int n = 0;
   do
     {
      ArrayResize(files, n + 1);
      files[n] = name;
      n++;
     }
   while(FileFindNext(h, name));
   FileFindClose(h);
   for(int i = 0; i < n; i++)
      HandleCommand(files[i]);
  }

void HandleCommand(string fname)
  {
   string path = DIR + fname;
   string keys[];
   string vals[];
   bool ok = ReadKV(path, keys, vals);
   FileDelete(path, FILE_COMMON);
   if(!ok)
      return;
   string id = Get(keys, vals, "id");
   string action = Get(keys, vals, "action");
   long expires = StringToInteger(Get(keys, vals, "expires"));
   string res = "id=" + id + "\r\n";
   if(expires > 0 && (long)TimeGMT() > expires)
      res += Err("Auftrag zu alt, nicht ausgefuehrt");
   else
      if(action == "open")
         res += DoOpen(keys, vals);
      else
         if(action == "close")
            res += DoClose(keys, vals);
         else
            if(action == "modify")
               res += DoModify(keys, vals);
            else
               if(action == "ping")
                  res += "ok=1\r\n";
               else
                  res += Err("unbekannter Auftrag " + action);
   WriteAtomic("res_" + IntegerToString(g_login) + "_" + id + ".txt", res);
  }

string DoOpen(string &keys[], string &vals[])
  {
   string sym     = Get(keys, vals, "symbol");
   string side    = Get(keys, vals, "side");
   double vol     = StringToDouble(Get(keys, vals, "volume"));
   double sl      = StringToDouble(Get(keys, vals, "sl"));
   double tp      = StringToDouble(Get(keys, vals, "tp"));
   string comment = Get(keys, vals, "comment");
   long   magic   = StringToInteger(Get(keys, vals, "magic"));
   if(!SymbolSelect(sym, true))
      return(Err("Symbol " + sym + " gibt es in diesem Konto nicht"));
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   sl  = NormalizeDouble(sl, digits);
   tp  = tp > 0 ? NormalizeDouble(tp, digits) : 0.0;
   vol = NormVol(sym, vol);
   if(vol <= 0)
      return(Err("Lotgroesse zu klein fuer " + sym));
   if(sl <= 0)
      return(Err("Ohne Stop-Loss wird keine Order geschickt"));
   if(side != "buy" && side != "sell")
      return(Err("Richtung fehlt"));
   trade.SetExpertMagicNumber((ulong)(magic > 0 ? magic : InpMagic));
   trade.SetTypeFillingBySymbol(sym);
   bool sent;
   if(side == "buy")
      sent = trade.Buy(vol, sym, 0.0, sl, tp, comment);
   else
      sent = trade.Sell(vol, sym, 0.0, sl, tp, comment);
   trade.SetExpertMagicNumber((ulong)InpMagic);
   uint rc = trade.ResultRetcode();
   if(!sent || !RetOk(rc))
      return(Err("Order abgelehnt: " + trade.ResultRetcodeDescription() + " (" + IntegerToString((long)rc) + ")"));
   double price = trade.ResultPrice();
   ulong ticket = 0;
   ulong deal = trade.ResultDeal();
   if(deal > 0 && HistoryDealSelect(deal))
      ticket = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
   if(ticket == 0)
      ticket = FindPosition(sym, comment);
   if(ticket > 0 && PositionSelectByTicket(ticket))
     {
      if(PositionGetDouble(POSITION_SL) <= 0)
        {
         // Stop wurde nicht mitgenommen: nachtraeglich setzen, sonst sofort schliessen
         if(!trade.PositionModify(ticket, sl, tp))
           {
            trade.PositionClose(ticket);
            return(Err("Stop-Loss konnte nicht gesetzt werden, Position sofort geschlossen"));
           }
        }
      price = PositionGetDouble(POSITION_PRICE_OPEN);
      vol = PositionGetDouble(POSITION_VOLUME);
     }
   return("ok=1\r\nticket=" + IntegerToString((long)ticket) + "\r\nprice=" + DoubleToString(price, digits) +
          "\r\nvolume=" + DoubleToString(vol, 2) + "\r\n");
  }

string DoClose(string &keys[], string &vals[])
  {
   ulong ticket = (ulong)StringToInteger(Get(keys, vals, "ticket"));
   double vol = StringToDouble(Get(keys, vals, "volume"));
   if(ticket == 0 || !PositionSelectByTicket(ticket))
      return("ok=1\r\nclosed=0\r\n");
   string sym = PositionGetString(POSITION_SYMBOL);
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double have = PositionGetDouble(POSITION_VOLUME);
   trade.SetTypeFillingBySymbol(sym);
   bool sent;
   if(vol > 0 && vol < have - 1e-9)
     {
      vol = NormVol(sym, vol);
      if(vol <= 0)
         return("ok=1\r\nclosed=0\r\n");
      sent = trade.PositionClosePartial(ticket, vol);
     }
   else
      sent = trade.PositionClose(ticket);
   uint rc = trade.ResultRetcode();
   if(!sent || !RetOk(rc))
      return(Err("Schliessen abgelehnt: " + trade.ResultRetcodeDescription() + " (" + IntegerToString((long)rc) + ")"));
   return("ok=1\r\nclosed=1\r\nprice=" + DoubleToString(trade.ResultPrice(), digits) + "\r\n");
  }

string DoModify(string &keys[], string &vals[])
  {
   ulong ticket = (ulong)StringToInteger(Get(keys, vals, "ticket"));
   if(ticket == 0 || !PositionSelectByTicket(ticket))
      return(Err("Position ist nicht mehr offen"));
   string sym = PositionGetString(POSITION_SYMBOL);
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   string s_sl = Get(keys, vals, "sl");
   string s_tp = Get(keys, vals, "tp");
   double sl = s_sl == "" ? PositionGetDouble(POSITION_SL) : NormalizeDouble(StringToDouble(s_sl), digits);
   double tp = s_tp == "" ? PositionGetDouble(POSITION_TP) : NormalizeDouble(StringToDouble(s_tp), digits);
   if(sl <= 0)
      return(Err("Stop-Loss darf nicht entfernt werden"));
   bool sent = trade.PositionModify(ticket, sl, tp);
   uint rc = trade.ResultRetcode();
   if(rc == TRADE_RETCODE_NO_CHANGES)
      return("ok=1\r\n");
   if(!sent || !RetOk(rc))
      return(Err("Aendern abgelehnt: " + trade.ResultRetcodeDescription() + " (" + IntegerToString((long)rc) + ")"));
   return("ok=1\r\n");
  }

//+------------------------------------------------------------------+
//| Statusmeldung (jede Sekunde)                                      |
//+------------------------------------------------------------------+
string SymLine(string sym)
  {
   if(!SymbolSelect(sym, true))
      return("sym=" + sym + "|0\r\n");
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   return("sym=" + sym + "|1|" +
          DoubleToString(SymbolInfoDouble(sym, SYMBOL_BID), digits) + "|" +
          DoubleToString(SymbolInfoDouble(sym, SYMBOL_ASK), digits) + "|" +
          IntegerToString(digits) + "|" +
          DoubleToString(SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE), 8) + "|" +
          DoubleToString(SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE), 8) + "|" +
          DoubleToString(SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN), 2) + "|" +
          DoubleToString(SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP), 2) + "|" +
          DoubleToString(SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX), 2) + "\r\n");
  }

void WriteStatus()
  {
   string s = "";
   bool can = TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) != 0 && MQLInfoInteger(MQL_TRADE_ALLOWED) != 0 &&
              AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) != 0;
   s += "version=" + BRIDGE_VERSION + "\r\n";
   s += "login=" + IntegerToString(g_login) + "\r\n";
   s += "server=" + Clean(AccountInfoString(ACCOUNT_SERVER)) + "\r\n";
   s += "company=" + Clean(AccountInfoString(ACCOUNT_COMPANY)) + "\r\n";
   s += "currency=" + AccountInfoString(ACCOUNT_CURRENCY) + "\r\n";
   s += "balance=" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + "\r\n";
   s += "equity=" + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2) + "\r\n";
   s += "trade_allowed=" + (can ? "1" : "0") + "\r\n";
   s += "connected=" + (TerminalInfoInteger(TERMINAL_CONNECTED) != 0 ? "1" : "0") + "\r\n";
   s += "time=" + IntegerToString((long)TimeGMT()) + "\r\n";
   // Symbole, die die App kennen moechte
   string wanted[];
   int nw = 0;
   int f = FileOpen(DIR + "symbols.txt", FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ);
   if(f != INVALID_HANDLE)
     {
      while(!FileIsEnding(f))
        {
         string line = Trim(FileReadString(f));
         if(line == "")
            continue;
         ArrayResize(wanted, nw + 1);
         wanted[nw] = line;
         nw++;
        }
      FileClose(f);
     }
   // offene Positionen
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0)
         continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      s += "pos=" + IntegerToString((long)t) + "|" + sym + "|" +
           IntegerToString(PositionGetInteger(POSITION_TYPE)) + "|" +
           DoubleToString(PositionGetDouble(POSITION_VOLUME), 2) + "|" +
           DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), digits) + "|" +
           DoubleToString(PositionGetDouble(POSITION_SL), digits) + "|" +
           DoubleToString(PositionGetDouble(POSITION_TP), digits) + "|" +
           IntegerToString(PositionGetInteger(POSITION_MAGIC)) + "|" +
           Clean(PositionGetString(POSITION_COMMENT)) + "|" +
           IntegerToString(PositionGetInteger(POSITION_TIME)) + "|" +
           DoubleToString(PositionGetDouble(POSITION_PROFIT), 2) + "\r\n";
      bool known = false;
      for(int k = 0; k < nw; k++)
         if(wanted[k] == sym)
            known = true;
      if(!known)
        {
         ArrayResize(wanted, nw + 1);
         wanted[nw] = sym;
         nw++;
        }
     }
   for(int k = 0; k < nw; k++)
      s += SymLine(wanted[k]);
   // abgeschlossene Deals der letzten 3 Tage
   datetime now = TimeCurrent();
   if(HistorySelect(now - 3 * 86400, now + 86400))
     {
      int total = HistoryDealsTotal();
      int start = total > 300 ? total - 300 : 0;
      for(int i = start; i < total; i++)
        {
         ulong d = HistoryDealGetTicket(i);
         if(d == 0)
            continue;
         long entry = HistoryDealGetInteger(d, DEAL_ENTRY);
         if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY && entry != DEAL_ENTRY_INOUT)
            continue;
         string sym = HistoryDealGetString(d, DEAL_SYMBOL);
         int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
         long reason = HistoryDealGetInteger(d, DEAL_REASON);
         string why = reason == DEAL_REASON_SL ? "sl" : (reason == DEAL_REASON_TP ? "tp" : (reason == DEAL_REASON_SO ? "so" : "other"));
         double pnl = HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_COMMISSION) + HistoryDealGetDouble(d, DEAL_SWAP);
         s += "deal=" + IntegerToString((long)d) + "|" +
              IntegerToString(HistoryDealGetInteger(d, DEAL_POSITION_ID)) + "|" + sym + "|" +
              DoubleToString(HistoryDealGetDouble(d, DEAL_PRICE), digits) + "|" +
              DoubleToString(pnl, 2) + "|" +
              IntegerToString(HistoryDealGetInteger(d, DEAL_TIME)) + "|" + why + "|" +
              DoubleToString(HistoryDealGetDouble(d, DEAL_VOLUME), 2) + "\r\n";
        }
     }
   WriteAtomic("status_" + IntegerToString(g_login) + ".txt", s);
  }
//+------------------------------------------------------------------+
