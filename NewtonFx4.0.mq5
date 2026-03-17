//+------------------------------------------------------------------+
//| NewtonFX 4.0 - XAUUSD M15 Trend Strategy                        |
//| Property of Ricardo Alarcon                                      |
//| Recommended Settings Loaded by Default                           |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

//+------------------------------------------------------------------+
//|                     INPUT PARAMETERS                              |
//+------------------------------------------------------------------+

// ==================== RISK MANAGEMENT ====================
input double LotSize            = 0.2;     // Fixed Lot Size
input bool   UseRiskPercent     = false;   // Use Risk % Instead of Fixed Lots
input double RiskPercent        = 1.0;     // Risk % of Equity Per Trade
input int    MaxTradesPerDay    = 5;       // Max Trades Per Day
input double DailyStopPct      = 5.0;     // Daily Max Drawdown % (kill switch)
input double WeeklyStopPct     = 15.0;    // Weekly Max Drawdown % (kill switch)

// ==================== ENTRY SIGNALS ====================
input int    EMA_FastLen        = 47;      // EMA Fast Period
input int    EMA_SlowLen        = 99;      // EMA Slow Period
input int    ADX_Len            = 8;       // ADX Period
input double MinADX             = 36.0;    // ADX Minimum Threshold
input double MinVolRatio        = 1.15;    // Relative Volume Minimum
input int    Fibo_Len           = 10;      // Fibonacci Lookback Bars
input double FiboMinRetrace     = 0.236;   // Fibonacci Min Retracement
input double FiboMaxRetrace     = 0.786;   // Fibonacci Max Retracement

// ==================== ATR & DYNAMIC REGIME ====================
input int    ATR_Len            = 10;      // ATR Fast Period
input int    ATR_SlowLen        = 94;      // ATR Slow Period
input double VR_Min             = 0.9;     // Volatility Ratio Min Clamp
input double VR_Max             = 1.35;    // Volatility Ratio Max Clamp
input double K_SL              = 0.35;    // VR Sensitivity - Stop Loss
input double K_TP              = 0.25;    // VR Sensitivity - Take Profit
input double K_BE              = 0.30;    // VR Sensitivity - Break Even
input double K_TR              = 0.40;    // VR Sensitivity - Trailing

// ==================== STOP LOSS & TAKE PROFIT ====================
input double SL_ATR_Mult        = 3.2;     // Stop Loss (ATR multiplier)
input double TP_ATR_Mult        = 9.5;     // Take Profit (ATR multiplier)
input double BE_ATR_Trigger     = 4.0;     // Break Even Trigger (ATR multiplier)
input double Trail_ATR_Mult     = 2.5;     // Trailing Stop (ATR multiplier)
input double Trail_Offset_ATR   = 1.0;     // Trailing Offset (ATR multiplier)
input double TrailAfterBE_Mult  = 7.5;     // Trailing After BE (ATR multiplier)

// ==================== PARTIAL CLOSE ====================
input bool   UsePartialClose    = true;    // Enable Partial Close
input double PartialCloseATR    = 1.5;     // Partial Close Distance (ATR mult)
input double PartialClosePct    = 50.0;    // Partial Close % of Position

// ==================== DYNAMIC TP ====================
input bool   UseDynamicTP       = true;    // Enable Dynamic TP
input double DynTP_MinMult      = 11.1;    // Dynamic TP Min Floor (ATR mult)

// ==================== SESSION FILTERS ====================
input bool   UseSessionLocks    = true;    // Enable Session Filters
input int    AsiaStartHour      = 0;       // Asia Block Start (server hour)
input int    AsiaEndHour        = 7;       // Asia Block End (server hour)
input bool   UseRolloverLock    = true;    // Block Around Rollover
input int    RolloverHour       = 8;       // Rollover Hour (server time)
input int    RolloverMinute     = 8;       // Rollover Minute
input int    RolloverBlockBeforeM = 15;    // Block Minutes Before Rollover
input int    RolloverBlockAfterM  = 15;    // Block Minutes After Rollover

// ==================== EXECUTION ====================
input long   MagicNumber        = 1000;    // Magic Number
input int    SlippagePoints     = 30;      // Max Slippage (points)
input double MaxSpreadPoints    = 390.0;   // Max Spread (points)
input int    DelaySeconds       = 0;       // Delay Between Trades (seconds)

//+------------------------------------------------------------------+
//|                     INDICATOR HANDLES                             |
//+------------------------------------------------------------------+
int emaFastHandle = INVALID_HANDLE;
int emaSlowHandle = INVALID_HANDLE;
int adxHandle     = INVALID_HANDLE;
int atrFastHandle = INVALID_HANDLE;
int atrSlowHandle = INVALID_HANDLE;

//+------------------------------------------------------------------+
//|                     STATE VARIABLES                               |
//+------------------------------------------------------------------+
datetime lastTradeTime = 0;

// BE state
double bePriceLong    = 0.0;
double bePriceShort   = 0.0;
bool   beTriggeredLong  = false;
bool   beTriggeredShort = false;

// Partial close state
bool   partialClosed     = false;
double partialClosePrice = 0.0;

// Frozen regime params at entry
double entryATR   = 0.0;
double entryVR    = 1.0;
double slMultDyn  = 0.0;
double tpMultDyn  = 0.0;
double beMultDyn  = 0.0;
double trMultDyn  = 0.0;
double trOffDyn   = 0.0;
double entryLotSize = 0.0;

// Kill-switch tracking
double dayEquityStart  = 0.0;
double weekEquityStart = 0.0;
int    dayOfYearTrack  = -1;
int    weekOfYearTrack = -1;

//+------------------------------------------------------------------+
//|                     HELPER FUNCTIONS                              |
//+------------------------------------------------------------------+
double Clamp(double x, double lo, double hi)
{
   if(x < lo) return lo;
   if(x > hi) return hi;
   return x;
}

double NormPrice(double price)
{
   return NormalizeDouble(price, _Digits);
}

double NormLots(double lots)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0) step = 0.01;
   lots = MathFloor(lots / step) * step;
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   return Clamp(lots, minLot, maxLot);
}

int GetDayOfYear()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   return dt.day_of_year;
}

int GetWeekOfYear()
{
   return GetDayOfYear() / 7;
}

//+------------------------------------------------------------------+
//|                     RISK MANAGEMENT                              |
//+------------------------------------------------------------------+
double CalcPositionSize(double slDistance)
{
   if(!UseRiskPercent || slDistance <= 0)
      return LotSize;

   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount = equity * RiskPercent / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue <= 0 || tickSize <= 0)
      return LotSize;

   double slTicks = slDistance / tickSize;
   double lots    = riskAmount / (slTicks * tickValue);
   lots = NormLots(lots);

   Print("RiskSizing: equity=", DoubleToString(equity,2),
         " risk$=", DoubleToString(riskAmount,2),
         " SLdist=", DoubleToString(slDistance,_Digits),
         " lots=", DoubleToString(lots,2));
   return lots;
}

//+------------------------------------------------------------------+
//|                     KILL SWITCH                                   |
//+------------------------------------------------------------------+
void ResetDayWeekIfNeeded()
{
   int doy = GetDayOfYear();
   int woy = GetWeekOfYear();
   if(dayOfYearTrack != doy)
   {
      dayOfYearTrack = doy;
      dayEquityStart = AccountInfoDouble(ACCOUNT_EQUITY);
   }
   if(weekOfYearTrack != woy)
   {
      weekOfYearTrack = woy;
      weekEquityStart = AccountInfoDouble(ACCOUNT_EQUITY);
   }
}

bool KillSwitchOk()
{
   ResetDayWeekIfNeeded();
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(dayEquityStart <= 0.0 || weekEquityStart <= 0.0) return true;

   double dayDD  = (dayEquityStart  - eq) / dayEquityStart  * 100.0;
   double weekDD = (weekEquityStart - eq) / weekEquityStart * 100.0;

   if(dayDD >= DailyStopPct)
   {
      Print("KillSwitch: Daily DD ", DoubleToString(dayDD,2), "% >= ", DoubleToString(DailyStopPct,2), "%");
      return false;
   }
   if(weekDD >= WeeklyStopPct)
   {
      Print("KillSwitch: Weekly DD ", DoubleToString(weekDD,2), "% >= ", DoubleToString(WeeklyStopPct,2), "%");
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//|                     SESSION FILTERS                               |
//+------------------------------------------------------------------+
double GetSpreadPoints()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0) return 1e9;
   return (ask - bid) / _Point;
}

bool InAsiaWindow()
{
   if(!UseSessionLocks) return false;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;
   if(AsiaStartHour < AsiaEndHour)
      return (h >= AsiaStartHour && h < AsiaEndHour);
   return (h >= AsiaStartHour || h < AsiaEndHour);
}

bool InRolloverWindow()
{
   if(!UseSessionLocks || !UseRolloverLock) return false;
   datetime now = TimeCurrent();
   MqlDateTime dt; TimeToStruct(now, dt);
   MqlDateTime r = dt;
   r.hour = RolloverHour; r.min = RolloverMinute; r.sec = 0;
   datetime roll = StructToTime(r);
   datetime rollTomorrow = roll + 86400;
   int beforeSec = RolloverBlockBeforeM * 60;
   int afterSec  = RolloverBlockAfterM  * 60;
   bool inToday = (now >= (roll - beforeSec) && now <= (roll + afterSec));
   bool inNext  = (now >= (rollTomorrow - beforeSec) && now <= (rollTomorrow + afterSec));
   return (inToday || inNext);
}

//+------------------------------------------------------------------+
//|                     TRADE COUNTING                                |
//+------------------------------------------------------------------+
int CountTodayTrades()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime dayStart = StructToTime(dt);
   if(!HistorySelect(dayStart, TimeCurrent()))
      return 0;
   int cnt = 0;
   int deals = HistoryDealsTotal();
   for(int i=0; i<deals; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol) continue;
      if((long)HistoryDealGetInteger(ticket, DEAL_MAGIC) != MagicNumber) continue;
      long entry = (long)HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_IN) cnt++;
   }
   return cnt;
}

//+------------------------------------------------------------------+
//|                     ATR REGIME                                    |
//+------------------------------------------------------------------+
bool GetATRRegime(double &atrFast, double &atrSlow, double &vr)
{
   double aF[1], aS[1];
   if(CopyBuffer(atrFastHandle, 0, 0, 1, aF) <= 0) return false;
   if(CopyBuffer(atrSlowHandle, 0, 0, 1, aS) <= 0) return false;
   atrFast = aF[0];
   atrSlow = aS[0];
   if(atrFast <= 0 || atrSlow <= 0) return false;
   vr = Clamp(atrFast / atrSlow, VR_Min, VR_Max);
   return true;
}

void ComputeDynamicMultipliers(double vr,
                               double &slM, double &tpM, double &beM, double &trM, double &trOffM)
{
   slM    = SL_ATR_Mult      * (1.0 + K_SL*(vr - 1.0));
   tpM    = TP_ATR_Mult      * (1.0 + K_TP*(vr - 1.0));
   beM    = BE_ATR_Trigger   * (1.0 + K_BE*(vr - 1.0));
   trM    = Trail_ATR_Mult   * (1.0 + K_TR*(vr - 1.0));
   trOffM = Trail_Offset_ATR * (1.0 + K_TR*(vr - 1.0));
   slM    = MathMax(0.10, slM);
   tpM    = MathMax(0.10, tpM);
   beM    = MathMax(0.10, beM);
   trM    = MathMax(0.10, trM);
   trOffM = MathMax(0.00, trOffM);
}

//+------------------------------------------------------------------+
//|                     POSITION HELPERS                              |
//+------------------------------------------------------------------+
bool SelectMyPosition()
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      return true;
   }
   return false;
}

void ResetTradeState()
{
   entryATR   = 0.0;
   entryVR    = 1.0;
   slMultDyn  = 0.0;
   tpMultDyn  = 0.0;
   beMultDyn  = 0.0;
   trMultDyn  = 0.0;
   trOffDyn   = 0.0;
   entryLotSize = 0.0;
   beTriggeredLong  = false;
   beTriggeredShort = false;
   bePriceLong      = 0.0;
   bePriceShort     = 0.0;
   partialClosed    = false;
   partialClosePrice = 0.0;
}

//+------------------------------------------------------------------+
//|                     EXECUTION WRAPPERS                            |
//+------------------------------------------------------------------+
bool SendBuy(double lots, double price, double sl, double tp, const string comment)
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   sl = NormPrice(sl);
   tp = NormPrice(tp);

   if(trade.Buy(lots, _Symbol, price, sl, tp, comment))
   {
      Print("BUY at ", DoubleToString(price, _Digits),
            " SL=", DoubleToString(sl, _Digits),
            " TP=", DoubleToString(tp, _Digits),
            " Lots=", DoubleToString(lots, 2));
      return true;
   }

   Print("BUY failed, retrying...");
   Sleep(150);
   double newPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(newPrice <= 0) return false;
   double diff = newPrice - price;
   sl = NormPrice(sl + diff);
   tp = NormPrice(tp + diff);

   if(trade.Buy(lots, _Symbol, newPrice, sl, tp, comment))
   {
      Print("BUY retry OK at ", DoubleToString(newPrice, _Digits));
      return true;
   }
   Print("BUY retry also failed");
   return false;
}

bool SendSell(double lots, double price, double sl, double tp, const string comment)
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   sl = NormPrice(sl);
   tp = NormPrice(tp);

   if(trade.Sell(lots, _Symbol, price, sl, tp, comment))
   {
      Print("SELL at ", DoubleToString(price, _Digits),
            " SL=", DoubleToString(sl, _Digits),
            " TP=", DoubleToString(tp, _Digits),
            " Lots=", DoubleToString(lots, 2));
      return true;
   }

   Print("SELL failed, retrying...");
   Sleep(150);
   double newPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(newPrice <= 0) return false;
   double diff = newPrice - price;
   sl = NormPrice(sl + diff);
   tp = NormPrice(tp + diff);

   if(trade.Sell(lots, _Symbol, newPrice, sl, tp, comment))
   {
      Print("SELL retry OK at ", DoubleToString(newPrice, _Digits));
      return true;
   }
   Print("SELL retry also failed");
   return false;
}

//+------------------------------------------------------------------+
//|                     VISUAL PANEL (HUD)                            |
//+------------------------------------------------------------------+
void DrawPanel()
{
   int x = 10, y = 30, lineH = 18;
   color clrTitle = clrGold;
   color clrLabel = clrWhite;
   color clrValue = clrLimeGreen;
   color clrOff   = clrGray;
   string font = "Consolas";
   int fontSize = 9;

   // Read current indicators
   double emaFast[2], emaSlow[2], adxArr[1];
   bool hasIndicators = true;
   if(CopyBuffer(emaFastHandle, 0, 1, 2, emaFast) <= 0) hasIndicators = false;
   if(CopyBuffer(emaSlowHandle, 0, 1, 2, emaSlow) <= 0) hasIndicators = false;
   if(CopyBuffer(adxHandle,     0, 1, 1, adxArr)  <= 0) hasIndicators = false;

   double atrF = 0, atrS = 0, vr = 0;
   bool hasATR = GetATRRegime(atrF, atrS, vr);

   double close = iClose(_Symbol, _Period, 1);
   double spread = GetSpreadPoints();

   // Title
   ObjectCreate(0, "NF4_title", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, "NF4_title", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, "NF4_title", OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, "NF4_title", OBJPROP_YDISTANCE, y);
   ObjectSetString(0, "NF4_title", OBJPROP_TEXT, "=== NewtonFX 4.0 ===");
   ObjectSetString(0, "NF4_title", OBJPROP_FONT, font);
   ObjectSetInteger(0, "NF4_title", OBJPROP_FONTSIZE, fontSize+1);
   ObjectSetInteger(0, "NF4_title", OBJPROP_COLOR, clrTitle);
   y += lineH + 4;

   // Signal conditions
   string labels[];
   string values[];
   color  colors[];
   int count = 0;

   // Resize arrays
   ArrayResize(labels, 12);
   ArrayResize(values, 12);
   ArrayResize(colors, 12);

   if(hasIndicators && hasATR)
   {
      // 1. EMA Trend
      bool emaLong  = (emaFast[1] > emaSlow[1]);
      bool emaShort = (emaFast[1] < emaSlow[1]);
      labels[count] = "EMA Trend:";
      values[count] = emaLong ? "BULLISH" : (emaShort ? "BEARISH" : "FLAT");
      colors[count] = emaLong ? clrLimeGreen : (emaShort ? clrOrangeRed : clrOff);
      count++;

      // 2. Price vs EMAs
      bool aboveEmas = (close > emaFast[1] && close > emaSlow[1]);
      bool belowEmas = (close < emaFast[1] && close < emaSlow[1]);
      labels[count] = "Price/EMA:";
      values[count] = aboveEmas ? "ABOVE" : (belowEmas ? "BELOW" : "BETWEEN");
      colors[count] = (aboveEmas || belowEmas) ? clrLimeGreen : clrOff;
      count++;

      // 3. ADX
      labels[count] = "ADX:";
      values[count] = DoubleToString(adxArr[0], 1) + " / " + DoubleToString(MinADX, 0);
      colors[count] = (adxArr[0] >= MinADX) ? clrLimeGreen : clrOrangeRed;
      count++;

      // 4. Volume
      double vol = (double)iVolume(_Symbol, _Period, 1);
      double avgVol = 0;
      for(int i=2; i<=21; i++) avgVol += (double)iVolume(_Symbol, _Period, i);
      avgVol /= 20.0;
      double volRatio = vol / (avgVol > 0 ? avgVol : 1.0);
      labels[count] = "VolRatio:";
      values[count] = DoubleToString(volRatio, 2) + " / " + DoubleToString(MinVolRatio, 2);
      colors[count] = (volRatio >= MinVolRatio) ? clrLimeGreen : clrOrangeRed;
      count++;

      // 5. Fibonacci
      int idxHigh = iHighest(_Symbol, _Period, MODE_HIGH, Fibo_Len, 1);
      int idxLow  = iLowest(_Symbol, _Period, MODE_LOW,  Fibo_Len, 1);
      if(idxHigh >= 0 && idxLow >= 0)
      {
         double fiboHigh = iHigh(_Symbol, _Period, idxHigh);
         double fiboLow  = iLow(_Symbol, _Period, idxLow);
         double range = fiboHigh - fiboLow;
         if(range > 0)
         {
            double retrace = (close - fiboLow) / range;
            bool fibOK = (retrace >= FiboMinRetrace && retrace <= FiboMaxRetrace) ||
                         ((1.0-retrace) >= FiboMinRetrace && (1.0-retrace) <= FiboMaxRetrace);
            labels[count] = "Fibo:";
            values[count] = DoubleToString(retrace, 3);
            colors[count] = fibOK ? clrLimeGreen : clrOrangeRed;
            count++;
         }
      }

      // 6. Spread
      labels[count] = "Spread:";
      values[count] = DoubleToString(spread, 0) + " / " + DoubleToString(MaxSpreadPoints, 0);
      colors[count] = (spread <= MaxSpreadPoints) ? clrLimeGreen : clrOrangeRed;
      count++;

      // 7. VR (Volatility Ratio)
      labels[count] = "VR:";
      values[count] = DoubleToString(vr, 3);
      colors[count] = clrValue;
      count++;

      // 8. ATR
      labels[count] = "ATR:";
      values[count] = DoubleToString(atrF, _Digits);
      colors[count] = clrValue;
      count++;

      // 9. Position status
      if(SelectMyPosition())
      {
         long posType = PositionGetInteger(POSITION_TYPE);
         double posProfit = PositionGetDouble(POSITION_PROFIT);
         labels[count] = "Position:";
         values[count] = (posType == POSITION_TYPE_BUY ? "BUY " : "SELL ") +
                         DoubleToString(posProfit, 2) + " $";
         colors[count] = (posProfit >= 0) ? clrLimeGreen : clrOrangeRed;
         count++;

         labels[count] = "BE:";
         bool beDone = (posType == POSITION_TYPE_BUY) ? beTriggeredLong : beTriggeredShort;
         values[count] = beDone ? "TRIGGERED" : "WAITING";
         colors[count] = beDone ? clrLimeGreen : clrOff;
         count++;

         labels[count] = "Partial:";
         values[count] = partialClosed ? "CLOSED" : "WAITING";
         colors[count] = partialClosed ? clrLimeGreen : clrOff;
         count++;
      }
      else
      {
         // Signal readiness score
         int score = 0;
         if(adxArr[0] >= MinADX) score++;
         if(volRatio >= MinVolRatio) score++;
         if(emaLong || emaShort) score++;
         if(aboveEmas || belowEmas) score++;
         if(spread <= MaxSpreadPoints) score++;

         labels[count] = "Signal:";
         values[count] = IntegerToString(score) + "/5 conditions";
         colors[count] = (score >= 4) ? clrLimeGreen : ((score >= 3) ? clrYellow : clrOrangeRed);
         count++;
      }
   }
   else
   {
      labels[0] = "Status:";
      values[0] = "Loading indicators...";
      colors[0] = clrOff;
      count = 1;
   }

   // Draw all lines
   for(int i=0; i<count; i++)
   {
      string nameL = "NF4_l" + IntegerToString(i);
      string nameV = "NF4_v" + IntegerToString(i);

      ObjectCreate(0, nameL, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, nameL, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, nameL, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, nameL, OBJPROP_YDISTANCE, y + i * lineH);
      ObjectSetString(0, nameL, OBJPROP_TEXT, labels[i]);
      ObjectSetString(0, nameL, OBJPROP_FONT, font);
      ObjectSetInteger(0, nameL, OBJPROP_FONTSIZE, fontSize);
      ObjectSetInteger(0, nameL, OBJPROP_COLOR, clrLabel);

      ObjectCreate(0, nameV, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, nameV, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, nameV, OBJPROP_XDISTANCE, x + 110);
      ObjectSetInteger(0, nameV, OBJPROP_YDISTANCE, y + i * lineH);
      ObjectSetString(0, nameV, OBJPROP_TEXT, values[i]);
      ObjectSetString(0, nameV, OBJPROP_FONT, font);
      ObjectSetInteger(0, nameV, OBJPROP_FONTSIZE, fontSize);
      ObjectSetInteger(0, nameV, OBJPROP_COLOR, colors[i]);
   }

   // Clean up extra objects from previous draws
   for(int i=count; i<12; i++)
   {
      ObjectDelete(0, "NF4_l" + IntegerToString(i));
      ObjectDelete(0, "NF4_v" + IntegerToString(i));
   }
}

void CleanupPanel()
{
   ObjectDelete(0, "NF4_title");
   for(int i=0; i<12; i++)
   {
      ObjectDelete(0, "NF4_l" + IntegerToString(i));
      ObjectDelete(0, "NF4_v" + IntegerToString(i));
   }
}

//+------------------------------------------------------------------+
//|                     INIT / DEINIT                                 |
//+------------------------------------------------------------------+
int OnInit()
{
   emaFastHandle = iMA(_Symbol, _Period, EMA_FastLen, 0, MODE_EMA, PRICE_CLOSE);
   emaSlowHandle = iMA(_Symbol, _Period, EMA_SlowLen, 0, MODE_EMA, PRICE_CLOSE);
   adxHandle     = iADX(_Symbol, _Period, ADX_Len);
   atrFastHandle = iATR(_Symbol, _Period, ATR_Len);
   atrSlowHandle = iATR(_Symbol, _Period, ATR_SlowLen);

   if(emaFastHandle == INVALID_HANDLE || emaSlowHandle == INVALID_HANDLE ||
      adxHandle == INVALID_HANDLE || atrFastHandle == INVALID_HANDLE || atrSlowHandle == INVALID_HANDLE)
   {
      Print("Error initializing indicators");
      return INIT_FAILED;
   }

   dayEquityStart  = AccountInfoDouble(ACCOUNT_EQUITY);
   weekEquityStart = AccountInfoDouble(ACCOUNT_EQUITY);
   dayOfYearTrack  = GetDayOfYear();
   weekOfYearTrack = GetWeekOfYear();

   ResetTradeState();

   Print("NewtonFX v4.0 initialized. Equity=", DoubleToString(dayEquityStart, 2),
         " Magic=", MagicNumber,
         " RiskMode=", UseRiskPercent ? DoubleToString(RiskPercent,1)+"%" : DoubleToString(LotSize,2)+" lots");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(emaFastHandle != INVALID_HANDLE) IndicatorRelease(emaFastHandle);
   if(emaSlowHandle != INVALID_HANDLE) IndicatorRelease(emaSlowHandle);
   if(adxHandle     != INVALID_HANDLE) IndicatorRelease(adxHandle);
   if(atrFastHandle != INVALID_HANDLE) IndicatorRelease(atrFastHandle);
   if(atrSlowHandle != INVALID_HANDLE) IndicatorRelease(atrSlowHandle);
   CleanupPanel();
}

//+------------------------------------------------------------------+
//|                     TRADE TRANSACTION                             |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      if(trans.symbol != _Symbol) return;
      ulong dealTicket = trans.deal;
      if(dealTicket == 0) return;
      if(!HistoryDealSelect(dealTicket)) return;
      if((long)HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != MagicNumber) return;
      long entry = (long)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
      {
         if(!SelectMyPosition())
         {
            Print("Position closed - resetting trade state");
            ResetTradeState();
         }
      }
   }
}

//+------------------------------------------------------------------+
//|                     ON TICK                                       |
//+------------------------------------------------------------------+
void OnTick()
{
   if((TimeCurrent() - lastTradeTime) < DelaySeconds) return;

   static datetime lastBarTime = 0;
   datetime currentBarTime = iTime(_Symbol, _Period, 0);
   if(currentBarTime != lastBarTime)
   {
      lastBarTime = currentBarTime;
      CheckForSignal();
      DrawPanel();
   }

   ManagePositions();
}

//+------------------------------------------------------------------+
//|                     ENTRY LOGIC                                   |
//+------------------------------------------------------------------+
void CheckForSignal()
{
   // Session locks
   if(UseSessionLocks)
   {
      if(InAsiaWindow()) return;
      if(InRolloverWindow()) return;
   }

   // Kill switch
   if(!KillSwitchOk()) return;

   // Spread filter
   double spread = GetSpreadPoints();
   if(spread > MaxSpreadPoints) return;

   // Trades/day limit
   int todayTrades = CountTodayTrades();
   if(todayTrades >= MaxTradesPerDay) return;

   // Only 1 position at a time
   if(SelectMyPosition()) return;

   // Read indicators
   double emaFast[2], emaSlow[2], adx[1];
   if(CopyBuffer(emaFastHandle, 0, 1, 2, emaFast) <= 0) return;
   if(CopyBuffer(emaSlowHandle, 0, 1, 2, emaSlow) <= 0) return;
   if(CopyBuffer(adxHandle,     0, 1, 1, adx)     <= 0) return;
   if(adx[0] < MinADX) return;

   // ATR regime
   double atrF, atrS, vr;
   if(!GetATRRegime(atrF, atrS, vr)) return;

   // Dynamic multipliers
   double slM, tpM, beM, trM, trOffM;
   ComputeDynamicMultipliers(vr, slM, tpM, beM, trM, trOffM);

   double close = iClose(_Symbol, _Period, 1);
   if(close <= 0) return;

   // Fibonacci pullback
   int idxHigh = iHighest(_Symbol, _Period, MODE_HIGH, Fibo_Len, 1);
   int idxLow  = iLowest(_Symbol, _Period, MODE_LOW,  Fibo_Len, 1);
   if(idxHigh < 0 || idxLow < 0) return;

   double fiboHigh = iHigh(_Symbol, _Period, idxHigh);
   double fiboLow  = iLow(_Symbol, _Period, idxLow);
   double range = fiboHigh - fiboLow;
   if(range <= 0) return;
   double retrace = (close - fiboLow) / range;

   // Volume ratio
   double vol = (double)iVolume(_Symbol, _Period, 1);
   double avgVol = 0.0;
   for(int i=2; i<=21; i++) avgVol += (double)iVolume(_Symbol, _Period, i);
   avgVol /= 20.0;
   double volRatio = vol / (avgVol > 0 ? avgVol : 1.0);

   bool fibLongOK  = (retrace >= FiboMinRetrace && retrace <= FiboMaxRetrace);
   bool fibShortOK = ((1.0 - retrace) >= FiboMinRetrace && (1.0 - retrace) <= FiboMaxRetrace);
   bool volOK      = (volRatio >= MinVolRatio);

   // EMA crossover confirmation
   bool emaCrossLong  = (emaFast[1] > emaSlow[1]);
   bool emaCrossShort = (emaFast[1] < emaSlow[1]);

   bool longCond  = (close > emaSlow[1] && close > emaFast[1] && emaCrossLong  && fibLongOK  && volOK);
   bool shortCond = (close < emaSlow[1] && close < emaFast[1] && emaCrossShort && fibShortOK && volOK);

   // === LONG ===
   if(longCond)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(ask <= 0) return;

      double slDist = slM * atrF;
      double sl = NormPrice(ask - slDist);
      double tp = NormPrice(ask + tpM * atrF);
      double lots = CalcPositionSize(slDist);

      // Freeze params
      entryATR   = atrF;  entryVR    = vr;
      slMultDyn  = slM;   tpMultDyn  = tpM;  beMultDyn  = beM;
      trMultDyn  = trM;   trOffDyn   = trOffM;
      entryLotSize = lots;

      bePriceLong = ask + beMultDyn * entryATR;
      beTriggeredLong = false;
      partialClosed   = false;
      partialClosePrice = ask + PartialCloseATR * entryATR;

      Print("LONG: ADX=", DoubleToString(adx[0],1),
            " VR=", DoubleToString(vr,2),
            " ATR=", DoubleToString(atrF,_Digits),
            " Lots=", DoubleToString(lots,2));

      if(SendBuy(lots, ask, sl, tp, "LONG"))
         lastTradeTime = TimeCurrent();
      return;
   }

   // === SHORT ===
   if(shortCond)
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(bid <= 0) return;

      double slDist = slM * atrF;
      double sl = NormPrice(bid + slDist);
      double tp = NormPrice(bid - tpM * atrF);
      double lots = CalcPositionSize(slDist);

      // Freeze params
      entryATR   = atrF;  entryVR    = vr;
      slMultDyn  = slM;   tpMultDyn  = tpM;  beMultDyn  = beM;
      trMultDyn  = trM;   trOffDyn   = trOffM;
      entryLotSize = lots;

      bePriceShort = bid - beMultDyn * entryATR;
      beTriggeredShort = false;
      partialClosed    = false;
      partialClosePrice = bid - PartialCloseATR * entryATR;

      Print("SHORT: ADX=", DoubleToString(adx[0],1),
            " VR=", DoubleToString(vr,2),
            " ATR=", DoubleToString(atrF,_Digits),
            " Lots=", DoubleToString(lots,2));

      if(SendSell(lots, bid, sl, tp, "SHORT"))
         lastTradeTime = TimeCurrent();
      return;
   }
}

//+------------------------------------------------------------------+
//|                     POSITION MANAGEMENT                          |
//+------------------------------------------------------------------+
void ManagePositions()
{
   if(!SelectMyPosition()) return;

   // Use frozen ATR. If lost (restart), recalculate from current regime
   double atrF = entryATR;
   if(atrF <= 0.0)
   {
      double atrS, vrNow;
      if(!GetATRRegime(atrF, atrS, vrNow)) return;
      ComputeDynamicMultipliers(vrNow, slMultDyn, tpMultDyn, beMultDyn, trMultDyn, trOffDyn);
      entryATR = atrF;
   }

   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(currentBid <= 0 || currentAsk <= 0) return;

   long   posType   = (long)PositionGetInteger(POSITION_TYPE);
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double tp        = PositionGetDouble(POSITION_TP);
   double curSL     = PositionGetDouble(POSITION_SL);
   double posVolume = PositionGetDouble(POSITION_VOLUME);
   ulong  posTicket = (ulong)PositionGetInteger(POSITION_TICKET);

   // Recover state after EA restart
   if(posType == POSITION_TYPE_BUY && bePriceLong <= 0.0)
   {
      bePriceLong       = openPrice + beMultDyn * atrF;
      partialClosePrice = openPrice + PartialCloseATR * atrF;
      if(curSL >= openPrice && curSL > 0.0)
         beTriggeredLong = true;
      if(entryLotSize <= 0) entryLotSize = posVolume;
      Print("BUY state recovered: BE=", DoubleToString(bePriceLong,_Digits),
            " Partial=", DoubleToString(partialClosePrice,_Digits));
   }
   if(posType == POSITION_TYPE_SELL && bePriceShort <= 0.0)
   {
      bePriceShort      = openPrice - beMultDyn * atrF;
      partialClosePrice = openPrice - PartialCloseATR * atrF;
      if(curSL <= openPrice && curSL > 0.0)
         beTriggeredShort = true;
      if(entryLotSize <= 0) entryLotSize = posVolume;
      Print("SELL state recovered: BE=", DoubleToString(bePriceShort,_Digits),
            " Partial=", DoubleToString(partialClosePrice,_Digits));
   }

   // Live ATR for dynamic TP
   double liveATR = atrF;
   if(UseDynamicTP)
   {
      double liveATR_buf[1];
      if(CopyBuffer(atrFastHandle, 0, 0, 1, liveATR_buf) > 0 && liveATR_buf[0] > 0)
         liveATR = liveATR_buf[0];
   }

   // ==================== BUY MANAGEMENT ====================
   if(posType == POSITION_TYPE_BUY)
   {
      double finalSL = curSL;
      double finalTP = tp;
      bool   needModify = false;

      // 1. Break-even
      if(!beTriggeredLong && currentBid >= bePriceLong)
      {
         finalSL = NormPrice(openPrice);
         beTriggeredLong = true;
         needModify = true;
         Print("BUY BE triggered at ", DoubleToString(currentBid, _Digits));
      }
      bool isBEd = beTriggeredLong;

      // 2. Partial close
      if(UsePartialClose && !partialClosed && currentBid >= partialClosePrice)
      {
         double closeLots = NormLots(posVolume * PartialClosePct / 100.0);
         double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
         if(closeLots >= minLot && (posVolume - closeLots) >= minLot)
         {
            trade.SetExpertMagicNumber(MagicNumber);
            if(trade.PositionClosePartial(posTicket, closeLots))
            {
               Print("BUY partial close: ", DoubleToString(closeLots,2),
                     " lots at ", DoubleToString(currentBid, _Digits));
               partialClosed = true;
            }
         }
      }

      // 3. Dynamic TP
      if(UseDynamicTP)
      {
         double dynTP = NormPrice(openPrice + tpMultDyn * liveATR);
         double minTP = NormPrice(openPrice + DynTP_MinMult * liveATR);
         if(dynTP < minTP) dynTP = minTP;
         if(dynTP > currentBid + _Point && MathAbs(dynTP - tp) > liveATR * 0.05)
         {
            finalTP = dynTP;
            needModify = true;
         }
      }

      // 4. Trailing stop (tighter after BE)
      double effectiveTrailMult = isBEd ? TrailAfterBE_Mult : trMultDyn;
      double offset = trOffDyn * atrF;
      double newSL  = NormPrice(currentBid - effectiveTrailMult * atrF);
      if(currentBid > openPrice + offset && newSL > finalSL)
      {
         finalSL = newSL;
         needModify = true;
      }

      // 5. Apply modifications
      if(needModify && (finalSL != curSL || finalTP != tp))
      {
         if(trade.PositionModify(posTicket, finalSL, finalTP))
         {
            if(finalSL != curSL) Print("BUY SL -> ", DoubleToString(finalSL, _Digits), isBEd ? " (tight)" : "");
            if(finalTP != tp)    Print("BUY TP -> ", DoubleToString(finalTP, _Digits));
         }
      }
      return;
   }

   // ==================== SELL MANAGEMENT ====================
   if(posType == POSITION_TYPE_SELL)
   {
      double finalSL = curSL;
      double finalTP = tp;
      bool   needModify = false;

      // 1. Break-even
      if(!beTriggeredShort && currentAsk <= bePriceShort)
      {
         finalSL = NormPrice(openPrice);
         beTriggeredShort = true;
         needModify = true;
         Print("SELL BE triggered at ", DoubleToString(currentAsk, _Digits));
      }
      bool isBEd = beTriggeredShort;

      // 2. Partial close
      if(UsePartialClose && !partialClosed && currentAsk <= partialClosePrice)
      {
         double closeLots = NormLots(posVolume * PartialClosePct / 100.0);
         double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
         if(closeLots >= minLot && (posVolume - closeLots) >= minLot)
         {
            trade.SetExpertMagicNumber(MagicNumber);
            if(trade.PositionClosePartial(posTicket, closeLots))
            {
               Print("SELL partial close: ", DoubleToString(closeLots,2),
                     " lots at ", DoubleToString(currentAsk, _Digits));
               partialClosed = true;
            }
         }
      }

      // 3. Dynamic TP
      if(UseDynamicTP)
      {
         double dynTP = NormPrice(openPrice - tpMultDyn * liveATR);
         double minTP = NormPrice(openPrice - DynTP_MinMult * liveATR);
         if(dynTP > minTP) dynTP = minTP;
         if(dynTP < currentAsk - _Point && MathAbs(dynTP - tp) > liveATR * 0.05)
         {
            finalTP = dynTP;
            needModify = true;
         }
      }

      // 4. Trailing stop (tighter after BE)
      double effectiveTrailMult = isBEd ? TrailAfterBE_Mult : trMultDyn;
      double offset = trOffDyn * atrF;
      double newSL  = NormPrice(currentAsk + effectiveTrailMult * atrF);
      if(currentAsk < openPrice - offset && (newSL < finalSL || finalSL == 0.0))
      {
         finalSL = newSL;
         needModify = true;
      }

      // 5. Apply modifications
      if(needModify && (finalSL != curSL || finalTP != tp))
      {
         if(trade.PositionModify(posTicket, finalSL, finalTP))
         {
            if(finalSL != curSL) Print("SELL SL -> ", DoubleToString(finalSL, _Digits), isBEd ? " (tight)" : "");
            if(finalTP != tp)    Print("SELL TP -> ", DoubleToString(finalTP, _Digits));
         }
      }
      return;
   }
}
//+------------------------------------------------------------------+
