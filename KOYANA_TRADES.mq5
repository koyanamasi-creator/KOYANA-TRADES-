//+------------------------------------------------------------------+
//|                                                KOYANA_TRADES.mq5 |
//| Breakout EA using the last complete M5 range and M1 confirmation. |
//| Trades only during London and New York sessions in South Africa. |
//| Risk management is set to 1:3 reward-to-risk.                   |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "KOYANA TRADES: M5 breakout with SL/TP and session filters."

#include <Trade/Trade.mqh>

CTrade trade;

input double RiskPercent       = 0.50;     // Risk per trade as % of equity
input double RewardRiskRatio   = 3.0;      // 1:3 risk-to-reward
input int    MaxSpreadPoints   = 30;       // Maximum allowed spread in points
input int    DeviationPoints   = 10;
input int    StopBufferPoints  = 2;        // Extra buffer beyond the M5 range
input ulong  MagicNumber       = 5112026;

input int LondonStartHourSAST   = 9;
input int LondonStartMinuteSAST = 0;
input int LondonEndHourSAST     = 12;
input int LondonEndMinuteSAST   = 0;

input int NewYorkStartHourSAST   = 14;
input int NewYorkStartMinuteSAST = 0;
input int NewYorkEndHourSAST     = 17;
input int NewYorkEndMinuteSAST   = 0;

datetime lastM1BarTime = 0;
int trackedDate = -1;
bool tradedLondonToday = false;
bool tradedNewYorkToday = false;

int DateKey(const MqlDateTime &dt)
{
   return dt.year * 10000 + dt.mon * 100 + dt.day;
}

bool IsInsideWindow(const int currentMinute,
                    const int startHour,
                    const int startMinute,
                    const int endHour,
                    const int endMinute)
{
   int start = startHour * 60 + startMinute;
   int end   = endHour * 60 + endMinute;

   if(start == end)
      return false;

   if(start < end)
      return (currentMinute >= start && currentMinute < end);

   return (currentMinute >= start || currentMinute < end);
}

bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         return true;
   }
   return false;
}

double CalculateVolumeForRisk(const ENUM_ORDER_TYPE orderType,
                             const double entryPrice,
                             const double stopPrice)
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double maxRisk = equity * (RiskPercent / 100.0);
   if(equity <= 0.0 || maxRisk <= 0.0)
      return 0.0;

   double result = 0.0;
   if(!OrderCalcProfit(orderType, _Symbol, 1.0, entryPrice, stopPrice, result))
      return 0.0;

   double lossPerLot = MathAbs(result);
   if(lossPerLot <= 0.0)
      return 0.0;

   double volume = maxRisk / lossPerLot;
   double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(minVol <= 0.0 || maxVol <= 0.0 || stepVol <= 0.0)
      return 0.0;

   volume = MathFloor(volume / stepVol) * stepVol;
   if(volume < minVol)
      return 0.0;
   if(volume > maxVol)
      volume = maxVol;

   return NormalizeDouble(volume, 2);
}

bool StopsValid(const double entryPrice,
                const double stopPrice,
                const double targetPrice)
{
   long minStopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDistance = (double)minStopLevel * _Point;
   if(minDistance <= 0.0)
      return true;

   if(MathAbs(entryPrice - stopPrice) < minDistance)
      return false;
   if(MathAbs(entryPrice - targetPrice) < minDistance)
      return false;

   return true;
}

void TryOpenBreakoutTrade(const bool buySignal,
                          const double rangeHigh,
                          const double rangeLow,
                          const bool londonAllowed,
                          const bool newYorkAllowed)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   double spreadPoints = (tick.ask - tick.bid) / _Point;
   if(MaxSpreadPoints > 0 && spreadPoints > MaxSpreadPoints)
      return;

   double entry = buySignal ? tick.ask : tick.bid;
   double stop  = 0.0;
   double take  = 0.0;

   if(buySignal)
   {
      stop = rangeLow - StopBufferPoints * _Point;
      double risk = entry - stop;
      if(risk <= 0.0)
         return;
      take = entry + (RewardRiskRatio * risk);
   }
   else
   {
      stop = rangeHigh + StopBufferPoints * _Point;
      double risk = stop - entry;
      if(risk <= 0.0)
         return;
      take = entry - (RewardRiskRatio * risk);
   }

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   entry = NormalizeDouble(entry, digits);
   stop = NormalizeDouble(stop, digits);
   take = NormalizeDouble(take, digits);

   if(!StopsValid(entry, stop, take))
      return;

   ENUM_ORDER_TYPE orderType = buySignal ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double volume = CalculateVolumeForRisk(orderType, entry, stop);
   if(volume <= 0.0)
      return;

   bool placed = false;
   if(buySignal)
      placed = trade.Buy(volume, _Symbol, 0.0, stop, take, "KOYANA TRADES");
   else
      placed = trade.Sell(volume, _Symbol, 0.0, stop, take, "KOYANA TRADES");

   if(placed)
   {
      if(londonAllowed)
         tradedLondonToday = true;
      if(newYorkAllowed)
         tradedNewYorkToday = true;

      Print("KOYANA TRADES: breakout trade opened, volume=", volume,
            " SL=", stop, " TP=", take);
   }
}

int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(DeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   Print("KOYANA TRADES initialized on:", _Symbol);
   return INIT_SUCCEEDED;
}

void OnTick()
{
   datetime nowUtc = TimeGMT();
   datetime nowSast = nowUtc + 2 * 3600;
   MqlDateTime dt;
   TimeToStruct(nowSast, dt);

   int currentDate = DateKey(dt);
   if(currentDate != trackedDate)
   {
      trackedDate = currentDate;
      tradedLondonToday = false;
      tradedNewYorkToday = false;
   }

   int nowMinute = dt.hour * 60 + dt.min;

   bool inLondon = IsInsideWindow(nowMinute,
                                  LondonStartHourSAST,
                                  LondonStartMinuteSAST,
                                  LondonEndHourSAST,
                                  LondonEndMinuteSAST);

   bool inNewYork = IsInsideWindow(nowMinute,
                                   NewYorkStartHourSAST,
                                   NewYorkStartMinuteSAST,
                                   NewYorkEndHourSAST,
                                   NewYorkEndMinuteSAST);

   bool londonAllowed = inLondon && !tradedLondonToday;
   bool newYorkAllowed = inNewYork && !tradedNewYorkToday;

   if(!HasOpenPosition() && (londonAllowed || newYorkAllowed))
   {
      MqlRates m1[];
      ArraySetAsSeries(m1, true);
      if(CopyRates(_Symbol, PERIOD_M1, 0, 3, m1) < 3)
         return;

      if(m1[0].time == lastM1BarTime)
         return;
      lastM1BarTime = m1[0].time;

      MqlRates m5[];
      ArraySetAsSeries(m5, true);
      if(CopyRates(_Symbol, PERIOD_M5, 0, 3, m5) < 3)
         return;

      double rangeHigh = m5[1].high;
      double rangeLow  = m5[1].low;

      bool buyBreak = (m1[2].close <= rangeHigh && m1[1].close > rangeHigh);
      bool sellBreak = (m1[2].close >= rangeLow && m1[1].close < rangeLow);

      if(buyBreak)
         TryOpenBreakoutTrade(true, rangeHigh, rangeLow, londonAllowed, newYorkAllowed);
      else if(sellBreak)
         TryOpenBreakoutTrade(false, rangeHigh, rangeLow, londonAllowed, newYorkAllowed);
   }
}

void OnDeinit(const int reason)
{
   Print("KOYANA TRADES removed. Reason=", reason);
}
//+------------------------------------------------------------------+
