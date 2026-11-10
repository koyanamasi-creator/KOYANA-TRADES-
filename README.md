# KOYANA TRADES

This repository contains a MetaTrader 5 EA named `KOYANA TRADES`.

## What it does
- Uses a breakout of the previous completed 5-minute candle.
- Confirms the breakout using a closed 1-minute candle.
- Trades only during London and New York sessions in South African Standard Time (SAST, UTC+2).
- Uses risk management with a 1:3 reward-to-risk ratio.
- Sets stop-loss and take-profit automatically.
- Works for forex, metals, and stocks if your broker supports them in MetaTrader 5.

## Risk settings
- `RiskPercent = 0.50` means risk 0.5% of equity per trade.
- `RewardRiskRatio = 3.0` means 1:3 risk-to-reward.
- `SL` and `TP` are generated from the breakout range and the risk distance.

## How to use
1. Open MetaEditor in MT5.
2. Create a new Expert Advisor file named `KOYANA_TRADES.mq5`.
3. Copy the source code from `KOYANA_TRADES.mq5` in this repo into the file.
4. Compile the EA.
5. Attach it to an M1 chart for the symbol you want to trade.
6. Test in a demo account before live trading.

## Important note
No EA can guarantee profit. This strategy is a template and should be tested and adjusted to your broker, symbols, and market conditions.