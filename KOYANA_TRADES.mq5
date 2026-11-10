//+------------------------------------------------------------------+
//|                                                KOYANA_TRADES.mq5 |
//| Multi-symbol M5 breakout EA with M1 close confirmation.         |
//| Session inputs use South African Standard Time (UTC+2).           |
//+------------------------------------------------------------------+
#property strict
#property version   "1.10"
#property description "KOYANA TRADES: multi-symbol M5 breakout, M1 confirmation and risk controls."

#include <Trade/Trade.mqh>

CTrade trade;

// Broker symbol names vary. Keep these names only if they match Market Watch;
// otherwise edit this list to the exact names shown by your MT5 broker.
input string SymbolsToTrade       = "USDJPY,GBPUSD,USDCHF,EURUSD,XAUUSD,US30,BITUSD,BITCOIN";
input double RiskPercent          = 0.25;    // Risk per trade as % of equity
input double RewardRiskRatio      = 3.0;     // 1:3 risk-to-reward
input int    MaxOpenPositions     = 3;       // Across all symbols for this EA
input int    MaxSpreadPoints      = 0;       // 0 disables; set broker-specific value per symbol
input int    DeviationPoints      = 10;
input int    StopBufferPoints     = 2;       // Extra buffer beyond M5 range
input ulong  MagicNumber          = 5112026;

input int LondonStartHourSAST     = 9;
input int LondonStartMinuteSAST   = 0;
input int LondonEndHourSAST       = 12;
input int LondonEndMinuteSAST     = 0;
input int NewYorkStartHourSAST    = 14;
input int NewYorkStartMinuteSAST  = 0;
input int NewYorkEndHourSAST      = 17;
input int NewYorkEndMinuteSAST    = 0;

struct SymbolState
{
   string   symbol;
   datetime lastM1BarTime;
   int      trackedDate;
   bool     tradedLondonToday;
   bool     tradedNewYorkToday;
};

SymbolState states[];

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
   int end = endHour * 60 + endMinute;
   if(start == end)
      return false;
   if(start < end)
      return currentMinute >= start && currentMinute < end;
   return currentMinute >= start || currentMinute < end;
}

// Resolve exact broker symbols first, then common prefix/suffix variants
// such as EURUSD.a or mEURUSD. Ambiguous partial matches are not guessed.
string ResolveSymbol(string requested)
{
   StringTrimLeft(requested);
   StringTrimRight(requested);
   if(requested == "")
      return "";

   if(SymbolSelect(requested, true))
      return requested;

   string wanted = requested;
   StringToUpper(wanted);
   string match = "";
   int total = SymbolsTotal(false);
   for(int i = 0; i < total; ++i)
   {
      string candidate = SymbolName(i, false);
      string upperCandidate = candidate;
      StringToUpper(upperCandidate);
      if(StringFind(upperCandidate, wanted) >= 0)
      {
         if(match != "")
         {
            Print("KOYANA TRADES: Ambiguous broker symbol for '", requested,
                  "'. Set the exact name in SymbolsToTrade; skipping it.");
            return "";
         }
         match = candidate;
      }
   }

   if(match != "" && SymbolSelect(match, true))
      return match;

   Print("KOYANA TRADES: Symbol '", requested,
         "' not found. Check broker's Market Watch symbol name.");
   return "";
}

int CountOpenPositionsByMagic()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         ++count;
   }
   return count;
}

bool HasOpenPositionForSymbol(const string symbol)
{
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         return true;
   }
   return false;
}

int VolumeDigits(const double step)
{
   for(int digits = 0; digits <= 8; ++digits)
   {
      if(MathAbs(step - NormalizeDouble(step, digits)) < 1e-10)
         return digits;
   }
   return 8;
}

double CalculateVolumeForRisk(const string symbol,
                              const ENUM_ORDER_TYPE orderType,
                              const double entryPrice,
                              const double stopPrice)
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * RiskPercent / 100.0;
   if(equity <= 0.0 || riskMoney <= 0.0)
      return 0.0;

   double oneLotResult = 0.0;
   if(!OrderCalcProfit(orderType, symbol, 1.0, entryPrice, stopPrice, oneLotResult))
   {
      Print("KOYANA TRADES: OrderCalcProfit failed for ", symbol,
            ". Error=", GetLastError());
      return 0.0;
   }

   double lossPerLot = MathAbs(oneLotResult);
   if(lossPerLot <= 0.0)
      return 0.0;

   double minVolume = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxVolume = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double stepVolume = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   if(minVolume <= 0.0 || maxVolume <= 0.0 || stepVolume <= 0.0)
      return 0.0;

   // Round down to avoid exceeding the configured percentage risk.
   double volume = MathFloor((riskMoney / lossPerLot) / stepVolume) * stepVolume;
   volume = NormalizeDouble(volume, VolumeDigits(stepVolume));
   if(volume < minVolume)
   {
      Print("KOYANA TRADES: Minimum lot would exceed risk budget for ", symbol,
            "; trade skipped.");
      return 0.0;
   }
   if(volume > maxVolume)
      volume = maxVolume;
   return volume;
}

bool StopsValid(const string symbol,
                const double entryPrice,
                const double stopPrice,
                const double targetPrice)
{
   long stopsLevel = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double minDistance = (double)stopsLevel * point;
   if(minDistance <= 0.0)
      return true;
   return MathAbs(entryPrice - stopPrice) >= minDistance &&
          MathAbs(entryPrice - targetPrice) >= minDistance;
}

void TryOpenTrade(SymbolState &state,
                  const bool isBuy,
                  const double rangeHigh,
                  const double rangeLow,
                  const bool londonAllowed,
                  const bool newYorkAllowed)
{
   string symbol = state.symbol;
   MqlTick tick;
   if(!SymbolInfoTick(symbol, tick))
      return;

   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0.0)
      return;
   double spreadPoints = (tick.ask - tick.bid) / point;
   if(MaxSpreadPoints > 0 && spreadPoints > MaxSpreadPoints)
   {
      Print("KOYANA TRADES: Spread too high for ", symbol, "; skipped.");
      return;
   }

   double entry = isBuy ? tick.ask : tick.bid;
   double stop = 0.0;
   double target = 0.0;
   if(isBuy)
   {
      stop = rangeLow - StopBufferPoints * point;
      double riskDistance = entry - stop;
      if(riskDistance <= 0.0)
         return;
      target = entry + RewardRiskRatio * riskDistance;
   }
   else
   {
      stop = rangeHigh + StopBufferPoints * point;
      double riskDistance = stop - entry;
      if(riskDistance <= 0.0)
         return;
      target = entry - RewardRiskRatio * riskDistance;
   }

   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   entry = NormalizeDouble(entry, digits);
   stop = NormalizeDouble(stop, digits);
   target = NormalizeDouble(target, digits);
   if(!StopsValid(symbol, entry, stop, target))
   {
      Print("KOYANA TRADES: SL/TP violates broker stop distance for ", symbol,
            "; skipped.");
      return;
   }

   ENUM_ORDER_TYPE orderType = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double volume = CalculateVolumeForRisk(symbol, orderType, entry, stop);
   if(volume <= 0.0)
      return;

   bool submitted = false;
   if(isBuy)
      submitted = trade.Buy(volume, symbol, 0.0, stop, target, "KOYANA TRADES");
   else
      submitted = trade.Sell(volume, symbol, 0.0, stop, target, "KOYANA TRADES");

   uint retcode = trade.ResultRetcode();
   bool accepted = submitted &&
                   (retcode == TRADE_RETCODE_DONE ||
                    retcode == TRADE_RETCODE_DONE_PARTIAL ||
                    retcode == TRADE_RETCODE_PLACED);
   if(!accepted)
   {
      Print("KOYANA TRADES: Order failed for ", symbol, ": ",
            trade.ResultRetcodeDescription());
      return;
   }

   if(londonAllowed)
      state.tradedLondonToday = true;
   if(newYorkAllowed)
      state.tradedNewYorkToday = true;
   Print("KOYANA TRADES: Order accepted for ", symbol,
         ", volume=", volume, ", SL=", stop, ", TP=", target);
}

void ProcessSymbol(SymbolState &state, const MqlDateTime &sast, const int nowMinute)
{
   int date = DateKey(sast);
   if(date != state.trackedDate)
   {
      state.trackedDate = date;
      state.tradedLondonToday = false;
      state.tradedNewYorkToday = false;
   }

   bool inLondon = IsInsideWindow(nowMinute, LondonStartHourSAST,
                                  LondonStartMinuteSAST, LondonEndHourSAST,
                                  LondonEndMinuteSAST);
   bool inNewYork = IsInsideWindow(nowMinute, NewYorkStartHourSAST,
                                   NewYorkStartMinuteSAST, NewYorkEndHourSAST,
                                   NewYorkEndMinuteSAST);
   bool londonAllowed = inLondon && !state.tradedLondonToday;
   bool newYorkAllowed = inNewYork && !state.tradedNewYorkToday;
   if(!londonAllowed && !newYorkAllowed)
      return;
   if(HasOpenPositionForSymbol(state.symbol))
      return;
   if(MaxOpenPositions > 0 && CountOpenPositionsByMagic() >= MaxOpenPositions)
      return;

   MqlRates m1[];
   ArraySetAsSeries(m1, true);
   if(CopyRates(state.symbol, PERIOD_M1, 0, 3, m1) < 3)
      return;
   if(m1[0].time == state.lastM1BarTime)
      return;
   state.lastM1BarTime = m1[0].time;

   MqlRates m5[];
   ArraySetAsSeries(m5, true);
   if(CopyRates(state.symbol, PERIOD_M5, 0, 2, m5) < 2)
      return;

   // Previous completed M5 candle is the range; M1 close confirms breakout.
   double rangeHigh = m5[1].high;
   double rangeLow = m5[1].low;
   bool brokeUp = (m1[2].close <= rangeHigh && m1[1].close > rangeHigh);
   bool brokeDown = (m1[2].close >= rangeLow && m1[1].close < rangeLow);

   if(brokeUp)
      TryOpenTrade(state, true, rangeHigh, rangeLow, londonAllowed, newYorkAllowed);
   else if(brokeDown)
      TryOpenTrade(state, false, rangeHigh, rangeLow, londonAllowed, newYorkAllowed);
}

int OnInit()
{
   if(RiskPercent <= 0.0 || RewardRiskRatio <= 0.0 || StopBufferPoints < 0 ||
      LondonStartHourSAST < 0 || LondonStartHourSAST > 23 ||
      LondonEndHourSAST < 0 || LondonEndHourSAST > 23 ||
      NewYorkStartHourSAST < 0 || NewYorkStartHourSAST > 23 ||
      NewYorkEndHourSAST < 0 || NewYorkEndHourSAST > 23 || MaxOpenPositions < 0)
   {
      Print("KOYANA TRADES: Invalid input values.");
      return INIT_PARAMETERS_INCORRECT;
   }

   string requested[];
   ushort delimiter = StringGetCharacter(",", 0);
   int requestedCount = StringSplit(SymbolsToTrade, delimiter, requested);
   if(requestedCount <= 0)
   {
      Print("KOYANA TRADES: SymbolsToTrade is empty.");
      return INIT_PARAMETERS_INCORRECT;
   }

   ArrayResize(states, 0);
   for(int i = 0; i < requestedCount; ++i)
   {
      string resolved = ResolveSymbol(requested[i]);
      if(resolved == "")
         continue;

      bool duplicate = false;
      for(int j = 0; j < ArraySize(states); ++j)
      {
         if(states[j].symbol == resolved)
         {
            duplicate = true;
            break;
         }
      }
      if(duplicate)
         continue;

      int index = ArraySize(states);
      ArrayResize(states, index + 1);
      states[index].symbol = resolved;
      states[index].lastM1BarTime = 0;
      states[index].trackedDate = -1;
      states[index].tradedLondonToday = false;
      states[index].tradedNewYorkToday = false;
      Print("KOYANA TRADES: Enabled symbol ", resolved);
   }

   if(ArraySize(states) == 0)
   {
      Print("KOYANA TRADES: No configured symbols are available; check SymbolsToTrade.");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(DeviationPoints);
   EventSetTimer(1);
   Print("KOYANA TRADES initialized. Attach to one chart; EA scans configured symbols.");
   return INIT_SUCCEEDED;
}

void OnTimer()
{
   datetime sastNow = TimeGMT() + 2 * 60 * 60;
   MqlDateTime sast;
   TimeToStruct(sastNow, sast);
   int nowMinute = sast.hour * 60 + sast.min;

   for(int i = 0; i < ArraySize(states); ++i)
      ProcessSymbol(states[i], sast, nowMinute);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   Print("KOYANA TRADES stopped. Reason=", reason);
}
//+------------------------------------------------------------------+
