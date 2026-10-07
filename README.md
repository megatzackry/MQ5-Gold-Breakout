# XAUUSD Quantitative Breakout Analysis

<img width="1672" height="941" alt="Algorithmic Trading and Gold Analytics" src="https://github.com/user-attachments/assets/4fbf565f-c90b-45c9-8eb3-c4a147222eb4" />

A 10-year quantitative research engine built in MQL5 to backtest moving average breakout strategies on Gold (XAUUSD).

This project tests a mechanical hypothesis: *Does a pure, single-candle moving average breakout carry a tradable edge on Gold?* By computing thousands of simulated trades across a grid of timeframes, moving averages, and exit models from 2015 to 2025, this repository explores market momentum, the realities of spread drag, and the structural differences between intraday noise and macro trends.

## Key Findings

* **The Curve-Fitting Trap:** The highest-performing isolated setup (M30 timeframe, 20-period EMA, +982.3 R) masked a highly noisy environment. Averaging all tested variables on the M30 timeframe yielded a negative expectancy (-14.25 R).
* **The Macro Trend Effect:** Higher timeframes (H4, H8, H12, D1) demonstrated structural robustness. Without optimizing for specific periods or averages (SMA, EMA, WMA), the higher timeframes consistently captured genuine market inertia and positive expectancy.

## Repository Structure

* `GoldBreakoutResearch.mq5`: The core MQL5 research script. It executes the backtest grid (Timeframes x MAs x Periods x Exits x Stops) directly on historical chart data without look-ahead bias.

## Methodology

The testing engine relies on strict, objective rules to ensure accurate expectancy modeling:

* **Asset & Scope:** XAUUSD, 2015-01-01 to 2025-12-31.
* **Signal:** A candle closes definitively through the moving average.
* **Execution:** Entry occurs at the OPEN of the next candle. Intrabar adverse moves are assumed to trigger stops before favourable moves.
* **Risk & Costs:** Risk is standardized using ATR-based hard stops (1R). Historical bar spread is deducted from the gross R, and stops gapped over the weekend fill at the opening print.
* **Exit Models:** Evaluated across three models (Next Bar, Stair-Step Trail, and MA Flip) and three stop distances (1, 2, and 3 ATR).

## How to Run the Engine

This script is designed to run directly on a MetaTrader 5 (MT5) chart, circumventing the limitations of the standard Strategy Tester for multi-timeframe batch research.

1. **Prepare Terminal:** Navigate to `Tools > Options > Charts` and set `Max bars in chart` to **Unlimited**.
2. **Download History:** Open each timeframe (W1 down to M15) for XAUUSD and scroll back to ensure historical server data is locally synchronized.
3. **Execute:** Attach `GoldBreakoutResearch.mq5` to any XAUUSD chart as a script.
4. **Retrieve Data:** Expect a few minutes of runtime (M15 and M30 processing dominates CPU time). The output data pipeline will write the CSV reports to your `MQL5\Files\` directory.

## Future Exploration

This repository establishes a baseline for trend-following mechanics. Future iterations will explore:

* Volatility-adjusted position sizing and regime detection filters.
* Cross-asset correlation testing (e.g., comparing XAGUSD momentum vs XAUUSD).
* Integration of Python-based machine learning models to classify and filter low-probability structural setups prior to execution.
