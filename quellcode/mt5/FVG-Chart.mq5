//+------------------------------------------------------------------+
//| FVG-Chart.mq5                                                     |
//| Chart-Ansicht passend zur App "FVG Trader":                       |
//|  - Fair Value Gaps (FVG) als Zonen, bis sie gefuellt sind         |
//|  - Sessions wie im Bot (New Yorker Zeit): Asien, London,          |
//|    NY Vormittag, NY Mittag, NY Nachmittag                         |
//|  - Vortageshoch/-tief, Mitternachts-Open, Tagestrenner            |
//|  - ruhiges dunkles Chart-Design (abschaltbar)                     |
//| Einrichten: Indikator auf den Chart ziehen. Fertig.               |
//+------------------------------------------------------------------+
#property copyright "FVG Trader"
#property version   "1.00"
#property description "FVGs, Sessions und Key Levels wie in der App FVG Trader."
#property indicator_chart_window
#property indicator_plots 0

input bool   InpTheme        = true;            // Chart-Design anwenden (dunkel, ohne Gitter)
input bool   InpFvg          = true;            // FVGs anzeigen
input int    InpFvgBars      = 400;             // FVGs aus den letzten X Kerzen
input double InpFvgMin       = 0.0;             // Mindestgroesse eines FVG (Kurs-Einheiten, 0 = alle)
input bool   InpFvgHideFilled = true;           // Gefuellte FVGs ausblenden
input bool   InpSessions     = true;            // Sessions anzeigen (nur bis 1-Stunden-Chart)
input bool   InpLevels       = true;            // Vortageshoch/-tief und Mitternachts-Open
input int    InpDays         = 3;               // Sessions und Linien der letzten X Tage
input color  InpBull         = C'38,166,154';   // Farbe FVG nach oben
input color  InpBear         = C'239,83,80';    // Farbe FVG nach unten

#define PFX "FVGC_"

string   SN[5] = {"Asien", "London", "NY Vormittag", "NY Mittag", "NY Nachmittag"};
int      SS[5] = {-240, 120, 570, 690, 810};    // Start in Minuten ab NY-Mitternacht (Asien beginnt am Vorabend)
int      SE[5] = {0, 300, 690, 810, 950};       // Ende
color    SC[5] = {C'124,92,255', C'41,121,255', C'255,152,0', C'120,144,156', C'0,188,212'};

int      g_srv_off = 0;                         // Serverzeit minus GMT in Sekunden
datetime g_last_bar = 0;
datetime g_last_draw = 0;

//+------------------------------------------------------------------+
//| Zeit: Server <-> New York (mit US-Sommerzeit)                     |
//+------------------------------------------------------------------+
datetime NthSunday(int year, int mon, int n)
  {
   MqlDateTime d;
   d.year = year; d.mon = mon; d.day = 1; d.hour = 0; d.min = 0; d.sec = 0;
   datetime t = StructToTime(d);
   TimeToStruct(t, d);
   int add = (7 - d.day_of_week) % 7;
   return(t + (add + 7 * (n - 1)) * 86400);
  }

int NyOffset(datetime gmt)
  {
   MqlDateTime d;
   TimeToStruct(gmt, d);
   datetime a = NthSunday(d.year, 3, 2) + 7 * 3600;   // 2 Uhr EST
   datetime b = NthSunday(d.year, 11, 1) + 6 * 3600;  // 2 Uhr EDT
   return((gmt >= a && gmt < b) ? -4 * 3600 : -5 * 3600);
  }

datetime ToNy(datetime srv)
  {
   datetime g = srv - g_srv_off;
   return(g + NyOffset(g));
  }

datetime FromNy(datetime ny)
  {
   datetime g = ny + 5 * 3600;
   g = ny - NyOffset(g);
   return(g + g_srv_off);
  }

void UpdateServerOffset()
  {
   long d = (long)TimeTradeServer() - (long)TimeGMT();
   g_srv_off = (int)(MathRound(d / 1800.0) * 1800);
  }

//+------------------------------------------------------------------+
//| Hilfen fuers Zeichnen                                             |
//+------------------------------------------------------------------+
color Mix(color a, color b, double k)
  {
   int ai = (int)a, bi = (int)b;
   int r = (int)((ai & 0xFF) * k + (bi & 0xFF) * (1 - k));
   int g = (int)(((ai >> 8) & 0xFF) * k + ((bi >> 8) & 0xFF) * (1 - k));
   int bl = (int)(((ai >> 16) & 0xFF) * k + ((bi >> 16) & 0xFF) * (1 - k));
   return((color)(r | (g << 8) | (bl << 16)));
  }

color Bg()
  {
   return((color)ChartGetInteger(0, CHART_COLOR_BACKGROUND));
  }

void Rect(string name, datetime t1, double p1, datetime t2, double p2, color fill, color border)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, p1, t2, p2);
   ObjectSetInteger(0, name, OBJPROP_TIME, 0, t1);
   ObjectSetDouble(0, name, OBJPROP_PRICE, 0, p1);
   ObjectSetInteger(0, name, OBJPROP_TIME, 1, t2);
   ObjectSetDouble(0, name, OBJPROP_PRICE, 1, p2);
   ObjectSetInteger(0, name, OBJPROP_COLOR, fill);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   if(border != clrNONE)
     {
      string b = name + "_r";
      if(ObjectFind(0, b) < 0)
         ObjectCreate(0, b, OBJ_RECTANGLE, 0, t1, p1, t2, p2);
      ObjectSetInteger(0, b, OBJPROP_TIME, 0, t1);
      ObjectSetDouble(0, b, OBJPROP_PRICE, 0, p1);
      ObjectSetInteger(0, b, OBJPROP_TIME, 1, t2);
      ObjectSetDouble(0, b, OBJPROP_PRICE, 1, p2);
      ObjectSetInteger(0, b, OBJPROP_COLOR, border);
      ObjectSetInteger(0, b, OBJPROP_FILL, false);
      ObjectSetInteger(0, b, OBJPROP_BACK, true);
      ObjectSetInteger(0, b, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, b, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, b, OBJPROP_HIDDEN, true);
     }
  }

void Line(string name, datetime t1, datetime t2, double price, color c, int style, string text)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_TREND, 0, t1, price, t2, price);
   ObjectSetInteger(0, name, OBJPROP_TIME, 0, t1);
   ObjectSetDouble(0, name, OBJPROP_PRICE, 0, price);
   ObjectSetInteger(0, name, OBJPROP_TIME, 1, t2);
   ObjectSetDouble(0, name, OBJPROP_PRICE, 1, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, c);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   if(text != "")
      Text(name + "_t", t2, price, text, c, ANCHOR_RIGHT_LOWER);
  }

void Text(string name, datetime t, double price, string text, color c, ENUM_ANCHOR_POINT anchor)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_TEXT, 0, t, price);
   ObjectSetInteger(0, name, OBJPROP_TIME, 0, t);
   ObjectSetDouble(0, name, OBJPROP_PRICE, 0, price);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, "Segoe UI");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, name, OBJPROP_COLOR, c);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, anchor);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

void VLine(string name, datetime t, color c)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_VLINE, 0, t, 0);
   ObjectSetInteger(0, name, OBJPROP_TIME, 0, t);
   ObjectSetInteger(0, name, OBJPROP_COLOR, c);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

bool RangeHL(datetime a, datetime b, double &hi, double &lo)
  {
   if(b <= a)
      return(false);
   double h[], l[];
   int n = CopyHigh(_Symbol, _Period, a, b - 1, h);
   if(n <= 0 || CopyLow(_Symbol, _Period, a, b - 1, l) <= 0)
      return(false);
   hi = h[ArrayMaximum(h)];
   lo = l[ArrayMinimum(l)];
   return(true);
  }

//+------------------------------------------------------------------+
//| Design                                                            |
//+------------------------------------------------------------------+
void ApplyTheme()
  {
   ChartSetInteger(0, CHART_MODE, CHART_CANDLES);
   ChartSetInteger(0, CHART_COLOR_BACKGROUND, C'16,19,28');
   ChartSetInteger(0, CHART_COLOR_FOREGROUND, C'138,148,168');
   ChartSetInteger(0, CHART_COLOR_GRID, C'30,35,48');
   ChartSetInteger(0, CHART_SHOW_GRID, false);
   ChartSetInteger(0, CHART_COLOR_CHART_UP, InpBull);
   ChartSetInteger(0, CHART_COLOR_CANDLE_BULL, InpBull);
   ChartSetInteger(0, CHART_COLOR_CHART_DOWN, InpBear);
   ChartSetInteger(0, CHART_COLOR_CANDLE_BEAR, InpBear);
   ChartSetInteger(0, CHART_COLOR_CHART_LINE, C'138,148,168');
   ChartSetInteger(0, CHART_COLOR_BID, C'120,130,150');
   ChartSetInteger(0, CHART_COLOR_ASK, C'90,100,120');
   ChartSetInteger(0, CHART_COLOR_LAST, C'138,148,168');
   ChartSetInteger(0, CHART_COLOR_STOP_LEVEL, InpBear);
   ChartSetInteger(0, CHART_SHOW_VOLUMES, CHART_VOLUME_HIDE);
   ChartSetInteger(0, CHART_SHOW_PERIOD_SEP, false);
   ChartSetInteger(0, CHART_SHIFT, true);
   ChartSetInteger(0, CHART_SHOW_ASK_LINE, true);
  }

//+------------------------------------------------------------------+
//| Zeichnen                                                          |
//+------------------------------------------------------------------+
void DrawFvgs(const int total, const datetime &time[], const double &high[], const double &low[])
  {
   color bg = Bg();
   color bullFill = Mix(InpBull, bg, 0.22), bearFill = Mix(InpBear, bg, 0.22);
   color bullDone = Mix(InpBull, bg, 0.10), bearDone = Mix(InpBear, bg, 0.10);
   int from = MathMax(2, total - InpFvgBars);
   datetime right = time[total - 1] + PeriodSeconds() * 8;
   double minSize = MathMax(InpFvgMin, 2 * _Point);
   for(int i = from; i < total; i++)
     {
      bool bull = low[i] > high[i - 2] && low[i] - high[i - 2] >= minSize;
      bool bear = high[i] < low[i - 2] && low[i - 2] - high[i] >= minSize;
      if(!bull && !bear)
         continue;
      double top = bull ? low[i] : low[i - 2];
      double bot = bull ? high[i - 2] : high[i];
      datetime end = right;
      bool filled = false;
      for(int j = i + 1; j < total; j++)
        {
         if((bull && low[j] <= bot) || (bear && high[j] >= top))
           {
            filled = true;
            end = time[j];
            break;
           }
        }
      if(filled && InpFvgHideFilled)
         continue;
      string name = PFX + "fvg_" + IntegerToString((long)time[i - 1]) + (bull ? "_b" : "_s");
      color fill = bull ? (filled ? bullDone : bullFill) : (filled ? bearDone : bearFill);
      Rect(name, time[i - 1], top, end, bot, fill, clrNONE);
     }
  }

void DrawSessions(datetime now_srv)
  {
   if(PeriodSeconds() > 3600)
      return;
   color bg = Bg();
   datetime ny_now = ToNy(now_srv);
   datetime ny_mid = (datetime)(((long)ny_now / 86400) * 86400);
   for(int k = 0; k < InpDays + 2; k++)
     {
      datetime mid = ny_mid - k * 86400;
      MqlDateTime d;
      TimeToStruct(mid, d);
      if(d.day_of_week == 0 || d.day_of_week == 6)
         continue;
      for(int s = 0; s < 5; s++)
        {
         datetime a = FromNy(mid + SS[s] * 60);
         datetime b = FromNy(mid + SE[s] * 60);
         if(a > now_srv)
            continue;
         if(b > now_srv)
            b = now_srv + PeriodSeconds();
         double hi, lo;
         if(!RangeHL(a, b, hi, lo))
            continue;
         string name = PFX + "ses_" + IntegerToString((long)mid) + "_" + IntegerToString(s);
         Rect(name, a, hi, b, lo, Mix(SC[s], bg, 0.10), Mix(SC[s], bg, 0.55));
         Text(name + "_n", a, hi, " " + SN[s], Mix(SC[s], bg, 0.85), ANCHOR_LEFT_LOWER);
        }
     }
  }

void DrawLevels(datetime now_srv, datetime last_bar)
  {
   color bg = Bg();
   datetime right = last_bar + PeriodSeconds() * 12;
   // Vortageshoch/-tief aus der Tageskerze des Servers
   double pdh = iHigh(_Symbol, PERIOD_D1, 1), pdl = iLow(_Symbol, PERIOD_D1, 1);
   datetime d0 = iTime(_Symbol, PERIOD_D1, 0);
   if(pdh > 0 && pdl > 0 && d0 > 0)
     {
      Line(PFX + "pdh", d0, right, pdh, Mix(InpBull, bg, 0.75), STYLE_DASH, "PDH ");
      Line(PFX + "pdl", d0, right, pdl, Mix(InpBear, bg, 0.75), STYLE_DASH, "PDL ");
     }
   // Mitternachts-Open (NY 00:00) und Tagestrenner
   datetime ny_mid = (datetime)(((long)ToNy(now_srv) / 86400) * 86400);
   for(int k = 0; k < InpDays + 2; k++)
     {
      datetime mid = ny_mid - k * 86400;
      MqlDateTime d;
      TimeToStruct(mid, d);
      if(d.day_of_week == 0 || d.day_of_week == 6)
         continue;
      datetime t = FromNy(mid);
      VLine(PFX + "day_" + IntegerToString((long)mid), t, Mix(C'138,148,168', bg, 0.30));
      if(k == 0 && t <= now_srv)
        {
         int sh = iBarShift(_Symbol, _Period, t, false);
         double mo = sh >= 0 ? iOpen(_Symbol, _Period, sh) : 0;
         if(mo > 0)
            Line(PFX + "mo", t, right, mo, Mix(C'255,193,7', bg, 0.75), STYLE_DOT, "Mitternacht ");
        }
     }
  }

void DrawInfo(datetime now_srv)
  {
   datetime ny = ToNy(now_srv);
   MqlDateTime d;
   TimeToStruct(ny, d);
   int m = d.hour * 60 + d.min;
   string ses = "keine Session";
   for(int s = 0; s < 5; s++)
     {
      int a = SS[s], b = SE[s];
      if((a < 0 && (m >= 1440 + a || m < b)) || (a >= 0 && m >= a && m < b))
         ses = SN[s];
     }
   string name = PFX + "info";
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 12);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, 22);
   ObjectSetString(0, name, OBJPROP_TEXT, StringFormat("FVG Trader  ·  NY %02d:%02d  ·  %s", d.hour, d.min, ses));
   ObjectSetString(0, name, OBJPROP_FONT, "Segoe UI Semibold");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
   ObjectSetInteger(0, name, OBJPROP_COLOR, (color)ChartGetInteger(0, CHART_COLOR_FOREGROUND));
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpTheme)
      ApplyTheme();
   UpdateServerOffset();
   EventSetTimer(30);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   ObjectsDeleteAll(0, PFX);
   ChartRedraw();
  }

void OnTimer()
  {
   UpdateServerOffset();
   DrawInfo(TimeTradeServer());
   ChartRedraw();
  }

int OnCalculate(const int rates_total, const int prev_calculated, const datetime &time[],
                const double &open[], const double &high[], const double &low[], const double &close[],
                const long &tick_volume[], const long &volume[], const int &spread[])
  {
   if(rates_total < 5)
      return(rates_total);
   ArraySetAsSeries(time, false);
   ArraySetAsSeries(high, false);
   ArraySetAsSeries(low, false);
   datetime last = time[rates_total - 1];
   datetime now_srv = TimeTradeServer();
   if(prev_calculated == 0 || last != g_last_bar || now_srv - g_last_draw >= 60)
     {
      g_last_bar = last;
      g_last_draw = now_srv;
      ObjectsDeleteAll(0, PFX);
      if(InpSessions)
         DrawSessions(now_srv);
      if(InpFvg)
         DrawFvgs(rates_total, time, high, low);
      if(InpLevels)
         DrawLevels(now_srv, last);
     }
   DrawInfo(now_srv);
   ChartRedraw();
   return(rates_total);
  }
//+------------------------------------------------------------------+
