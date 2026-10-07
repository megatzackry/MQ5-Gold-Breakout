//+------------------------------------------------------------------+
//| GoldBreakoutResearch.mq5                                          |
//+------------------------------------------------------------------+
#property copyright "@megatz"
#property version   "3.00"
#property script_show_inputs

//--- Fixed research scope (the study is XAUUSD 2015-2025)
#define RESEARCH_START          D'2015.01.01 00:00'
#define RESEARCH_END            D'2025.12.31 23:59'
#define FIRST_YEAR              2015
#define LAST_YEAR               2025
#define YEAR_COUNT              11                 // LAST_YEAR - FIRST_YEAR + 1
#define ERA2_FIRST_YEAR         2020               // stability split: 2015-2019 vs 2020-2025

//--- Method constants (standards, not tuned values)
#define EMA_WARMUP_FACTOR       3                  // EMA needs ~3x its period to forget its seed
#define ATR_PERIOD              14                 // Wilder's standard ATR
#define DIST_BUCKETS            3                  // breakout distance terciles
#define LOW_SAMPLE_THRESHOLD    30
#define WILSON_Z                1.96               // 95% confidence
#define COVERAGE_TOLERANCE_SEC  604800             // study start/end must be covered within 7 days
#define MIN_RECOMMENDED_MAXBARS 1000000

//--- Trade-model grid
#define STOP_COUNT              3
#define EXIT_COUNT              3
#define COMBO_COUNT             9                  // EXIT_COUNT * STOP_COUNT
#define HORIZON_COUNT           8
#define R_BINS                  6
const double g_stopAtr[STOP_COUNT]    = {1.0, 2.0, 3.0};
const int    g_horizons[HORIZON_COUNT] = {1, 2, 3, 5, 8, 13, 21, 34};   // bars held after entry

//--- Inputs
input string InpPeriodsOverride = "20,50,100,200";            // CSV of MA periods
input string InpOutputPrefix    = "XAUUSD_breakout_v3";       // output file name prefix
input double InpAccountUsd      = 100.0;                      // account size, only used for risk-% columns

enum EBreakDirection { BREAK_BULLISH, BREAK_BEARISH };
enum EExitModel      { EXIT_NEXT_BAR, EXIT_STAIR_STEP, EXIT_MA_FLIP };

//+==================================================================+
//| SECTION 1: small reusable helpers                                 |
//+==================================================================+
void AppendInt(int &arr[], const int value)
{
   const int n = ArraySize(arr);
   ArrayResize(arr, n + 1);
   arr[n] = value;
}

bool IsGold(const string symbol)
{
   return StringFind(symbol, "XAUUSD") == 0;   // allows broker suffixes e.g. XAUUSD.m
}

string DirectionName(const EBreakDirection dir)
{
   return dir == BREAK_BULLISH ? "BULLISH" : "BEARISH";
}

string ExitName(const int model)
{
   switch(model)
   {
      case EXIT_NEXT_BAR:   return "NEXT_BAR";
      case EXIT_STAIR_STEP: return "STAIR_STEP";
      case EXIT_MA_FLIP:    return "MA_FLIP";
   }
   return "?";
}

//--- +1 above the MA, -1 below, 0 exactly on it
int SideOf(const double close, const double ma)
{
   return close > ma ? 1 : (close < ma ? -1 : 0);
}

//--- A session break (weekend, holiday, daily rollover) lies between two candles
bool IsSessionGap(const datetime earlier, const datetime later, const long barSeconds)
{
   return (long)(later - earlier) * 2 > barSeconds * 3;
}

//--- Warm-up lead-in so the longest EMA has converged before the study starts.
//--- x2 because markets are closed roughly 30% of calendar time.
datetime WarmupStart(const ENUM_TIMEFRAMES tf, const int maxPeriod)
{
   const long bars    = (long)maxPeriod * EMA_WARMUP_FACTOR;
   const long seconds = bars * PeriodSeconds(tf) * 2;
   return (datetime)((long)RESEARCH_START - seconds);
}

//--- First day of the month `months` after t's month, at 00:00
datetime AddMonths(const datetime t, const int months)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   const int total = dt.year * 12 + (dt.mon - 1) + months;
   dt.year = total / 12;
   dt.mon  = total % 12 + 1;
   dt.day  = 1;
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   return StructToTime(dt);
}

//--- Fallback for huge ranges: copy one month at a time and append
bool CopyRatesChunked(const string symbol, const ENUM_TIMEFRAMES tf,
                      const datetime from, const datetime to, MqlRates &rates[])
{
   ArrayResize(rates, 0, 500000);
   datetime chunkStart = AddMonths(from, 0);
   while(chunkStart <= to)
   {
      const datetime nextStart = AddMonths(chunkStart, 1);
      const datetime chunkEnd  = (nextStart - 1 < to) ? nextStart - 1 : to;

      MqlRates part[];
      const int got = CopyRates(symbol, tf, chunkStart, chunkEnd, part);
      if(got > 0)
      {
         const int n = ArraySize(rates);
         ArrayResize(rates, n + got, 500000);
         ArrayCopy(rates, part, n, 0, got);
      }
      chunkStart = nextStart;
   }
   return ArraySize(rates) > 0;
}

//--- Loads rates oldest-first. Clamps the start to what the server has,
//--- waits for sync, tries one big copy, then falls back to monthly chunks.
bool LoadRates(const string symbol, const ENUM_TIMEFRAMES tf,
               const datetime from, const datetime to, MqlRates &rates[])
{
   datetime serverFirst = 0;
   SeriesInfoInteger(symbol, tf, SERIES_SERVER_FIRSTDATE, serverFirst);
   const datetime start  = (serverFirst > from) ? serverFirst : from;
   const string   tfName = EnumToString(tf);

   ArraySetAsSeries(rates, false);
   for(int attempt = 0; attempt < 20; attempt++)           // up to ~10 s for sync
   {
      if(SeriesInfoInteger(symbol, tf, SERIES_SYNCHRONIZED))
      {
         ResetLastError();
         if(CopyRates(symbol, tf, start, to, rates) > 0)
            return true;
         PrintFormat("[%s] single CopyRates failed (error %d) - trying monthly chunks", tfName, GetLastError());

         if(CopyRatesChunked(symbol, tf, start, to, rates))
            return true;
         break;
      }
      Sleep(500);
   }

   PrintFormat("[%s] LOAD FAILED: synchronized=%d serverFirst=%s terminalBars=%d lastError=%d",
               tfName,
               (int)SeriesInfoInteger(symbol, tf, SERIES_SYNCHRONIZED),
               TimeToString(serverFirst, TIME_DATE),
               (int)SeriesInfoInteger(symbol, tf, SERIES_BARS_COUNT),
               GetLastError());
   return false;
}

double TrueRange(const MqlRates &bar, const double prevClose)
{
   return MathMax(bar.high - bar.low,
                  MathMax(MathAbs(bar.high - prevClose), MathAbs(bar.low - prevClose)));
}

//--- Wilder ATR, oldest-first, EMPTY_VALUE while warming
void ComputeAtr(const MqlRates &bars[], const int period, double &out[])
{
   const int n = ArraySize(bars);
   ArrayResize(out, n);
   ArrayInitialize(out, EMPTY_VALUE);
   if(n <= period) return;

   double sum = 0.0;
   for(int i = 1; i <= period; i++)
      sum += TrueRange(bars[i], bars[i - 1].close);
   out[period] = sum / period;

   for(int i = period + 1; i < n; i++)
      out[i] = (out[i - 1] * (period - 1) + TrueRange(bars[i], bars[i - 1].close)) / period;
}

//+==================================================================+
//| SECTION 2: statistics (pure functions, no state)                  |
//+==================================================================+

//--- Wilson score interval: honest uncertainty for proportions
void WilsonInterval(const int successes, const int n, double &lo, double &hi)
{
   if(n <= 0) { lo = 0.0; hi = 0.0; return; }
   const double p      = (double)successes / n;
   const double z2     = WILSON_Z * WILSON_Z;
   const double denom  = 1.0 + z2 / n;
   const double centre = (p + z2 / (2.0 * n)) / denom;
   const double half   = WILSON_Z * MathSqrt(p * (1.0 - p) / n + z2 / (4.0 * n * n)) / denom;
   lo = MathMax(0.0, centre - half);
   hi = MathMin(1.0, centre + half);
}

//--- P(Z > |z|), Abramowitz & Stegun 26.2.17 (abs error < 7.5e-8)
double NormalUpperTail(const double z)
{
   const double x = MathAbs(z);
   const double t = 1.0 / (1.0 + 0.2316419 * x);
   const double density = 0.3989422804014327 * MathExp(-0.5 * x * x);
   return density * t * (0.319381530 + t * (-0.356563782 + t * (1.781477937
                       + t * (-1.821255978 + t * 1.330274429))));
}

double TwoSidedP(const double z)
{
   return MathMin(1.0, 2.0 * NormalUpperTail(z));
}

//--- Two-sided p-value: is proportion k1/n1 different from k2/n2? (pooled z-test)
double TwoProportionP(const int k1, const int n1, const int k2, const int n2)
{
   if(n1 <= 0 || n2 <= 0) return EMPTY_VALUE;
   const double pooled = (double)(k1 + k2) / (n1 + n2);
   const double se     = MathSqrt(pooled * (1.0 - pooled) * (1.0 / n1 + 1.0 / n2));
   if(se <= 0.0) return 1.0;
   return TwoSidedP(((double)k1 / n1 - (double)k2 / n2) / se);
}

//--- Linear-interpolated quantile (copies and sorts, input untouched)
double Quantile(const double &values[], const double q)
{
   const int n = ArraySize(values);
   if(n == 0) return EMPTY_VALUE;
   double sorted[];
   ArrayCopy(sorted, values);
   ArraySort(sorted);
   const double pos = q * (n - 1);
   const int    lo  = (int)MathFloor(pos);
   const int    hi  = (int)MathCeil(pos);
   return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - lo);
}

//--- Running mean/variance (Welford) with parallel merge
struct SMoments
{
   int    n;
   double mean;
   double m2;

   void Reset() { n = 0; mean = 0.0; m2 = 0.0; }

   void Add(const double x)
   {
      n++;
      const double d = x - mean;
      mean += d / n;
      m2   += d * (x - mean);
   }

   void Merge(const SMoments &o)
   {
      if(o.n == 0) return;
      if(n == 0) { n = o.n; mean = o.mean; m2 = o.m2; return; }
      const int    total = n + o.n;
      const double delta = o.mean - mean;
      m2   = m2 + o.m2 + delta * delta * ((double)n * o.n / total);
      mean = mean + delta * o.n / total;
      n    = total;
   }

   double Variance() const { return n > 1 ? m2 / (n - 1) : 0.0; }
   double Mean()     const { return n > 0 ? mean : EMPTY_VALUE; }

   //--- t-statistic of the mean against zero
   double TStat() const
   {
      if(n < 2) return EMPTY_VALUE;
      const double se = MathSqrt(Variance() / n);
      return se > 0.0 ? mean / se : EMPTY_VALUE;
   }

   //--- 95% half-width of the mean
   double HalfWidth() const
   {
      return n > 1 ? WILSON_Z * MathSqrt(Variance() / n) : EMPTY_VALUE;
   }
};

double WelchT(const SMoments &a, const SMoments &b)
{
   if(a.n < 2 || b.n < 2) return EMPTY_VALUE;
   const double se = MathSqrt(a.Variance() / a.n + b.Variance() / b.n);
   return se > 0.0 ? (a.mean - b.mean) / se : EMPTY_VALUE;
}

//+==================================================================+
//| SECTION 3: moving averages (Strategy pattern)                     |
//|   Oldest-first, O(n), EMPTY_VALUE while warming                   |
//+==================================================================+
class IMovingAverage
{
public:
   virtual            ~IMovingAverage() {}
   virtual string     Name() const = 0;
   virtual int        WarmupBars(const int period) const = 0;   // bars needed before the MA is trustworthy
   virtual void       Compute(const double &price[], const int period, double &out[]) const = 0;

protected:
   bool PrepareOutput(const int n, const int period, double &out[]) const
   {
      ArrayResize(out, n);
      ArrayInitialize(out, EMPTY_VALUE);
      return period >= 1 && n >= period;
   }
};

class CSma : public IMovingAverage
{
public:
   virtual string Name() const { return "SMA"; }
   virtual int    WarmupBars(const int period) const { return period; }

   virtual void Compute(const double &price[], const int period, double &out[]) const
   {
      const int n = ArraySize(price);
      if(!PrepareOutput(n, period, out)) return;

      double sum = 0.0;
      for(int i = 0; i < n; i++)
      {
         sum += price[i];
         if(i >= period) sum -= price[i - period];
         if(i >= period - 1) out[i] = sum / period;
      }
   }
};

class CEma : public IMovingAverage
{
public:
   virtual string Name() const { return "EMA"; }
   virtual int    WarmupBars(const int period) const { return period * EMA_WARMUP_FACTOR; }

   virtual void Compute(const double &price[], const int period, double &out[]) const
   {
      const int n = ArraySize(price);
      if(!PrepareOutput(n, period, out)) return;

      const double alpha = 2.0 / (period + 1.0);
      double seed = 0.0;                       // seed with SMA of first window
      for(int i = 0; i < period; i++) seed += price[i];
      out[period - 1] = seed / period;

      for(int i = period; i < n; i++)
         out[i] = alpha * price[i] + (1.0 - alpha) * out[i - 1];
   }
};

class CWma : public IMovingAverage
{
public:
   virtual string Name() const { return "WMA"; }
   virtual int    WarmupBars(const int period) const { return period; }

   virtual void Compute(const double &price[], const int period, double &out[]) const
   {
      const int n = ArraySize(price);
      if(!PrepareOutput(n, period, out)) return;

      const double denom = period * (period + 1.0) / 2.0;
      double sum = 0.0, weighted = 0.0;        // window sum, weights 1..period (oldest = 1)
      for(int i = 0; i < n; i++)
      {
         if(i < period)
         {
            sum      += price[i];
            weighted += price[i] * (i + 1);
         }
         else
         {
            weighted = weighted - sum + period * price[i];   // O(1) slide
            sum      = sum - price[i - period] + price[i];
         }
         if(i >= period - 1) out[i] = weighted / denom;
      }
   }
};

IMovingAverage *CreateMovingAverage(const ENUM_MA_METHOD method)
{
   switch(method)
   {
      case MODE_SMA:  return new CSma();
      case MODE_EMA:  return new CEma();
      case MODE_LWMA: return new CWma();
   }
   return NULL;
}

//+==================================================================+
//| SECTION 4: study design (timeframes + fixed period policy)        |
//+==================================================================+
struct STimeframe
{
   ENUM_TIMEFRAMES tf;
   string          label;
};

void AddFrame(STimeframe &frames[], const ENUM_TIMEFRAMES tf, const string label)
{
   const int n = ArraySize(frames);
   ArrayResize(frames, n + 1);
   frames[n].tf    = tf;
   frames[n].label = label;
}

void BuildTimeframes(STimeframe &frames[])
{
   ArrayResize(frames, 0);
   AddFrame(frames, PERIOD_W1,  "W1");
   AddFrame(frames, PERIOD_D1,  "D1");
   AddFrame(frames, PERIOD_H12, "H12");
   AddFrame(frames, PERIOD_H8,  "H8");
   AddFrame(frames, PERIOD_H4,  "H4");
   AddFrame(frames, PERIOD_H1,  "H1");
   AddFrame(frames, PERIOD_M30, "M30");
   AddFrame(frames, PERIOD_M15, "M15");
}

//--- Fixed periods. Nothing is dropped silently: under-covered cells are flagged instead.
class CPeriodPolicy
{
   int m_periods[];
public:
   CPeriodPolicy(const string csv)
   {
      string parts[];
      const int k = StringSplit(csv, ',', parts);
      for(int i = 0; i < k; i++)
      {
         const int p = (int)StringToInteger(parts[i]);
         if(p > 0) AppendInt(m_periods, p);
      }
      if(ArraySize(m_periods) == 0)
      {
         const int standard[] = {20, 50, 100, 200};
         for(int i = 0; i < ArraySize(standard); i++) AppendInt(m_periods, standard[i]);
      }
   }

   int Count() const         { return ArraySize(m_periods); }
   int At(const int i) const { return m_periods[i]; }

   int Max() const
   {
      int best = 0;
      for(int i = 0; i < ArraySize(m_periods); i++) best = MathMax(best, m_periods[i]);
      return best;
   }
};

//+==================================================================+
//| SECTION 5: data for one timeframe (+ coverage guard + spreads)    |
//+==================================================================+
struct STimeframeSummary
{
   datetime firstBar, lastBar;
   int      barsTotal, barsInWindow;
   int      pairs, up, down, gaps;        // candle->next-candle pairs inside the window
   double   medianAtr;
   double   medianSpread;                 // price units
   double   zeroSpreadPct;                // % of window bars with no recorded spread
   bool     startCovered, endCovered, truncated;

   void Reset()
   {
      firstBar = 0; lastBar = 0;
      barsTotal = 0; barsInWindow = 0;
      pairs = 0; up = 0; down = 0; gaps = 0;
      medianAtr = EMPTY_VALUE; medianSpread = EMPTY_VALUE; zeroSpreadPct = EMPTY_VALUE;
      startCovered = false; endCovered = false; truncated = false;
   }

   bool   CoverageOk() const { return startCovered && endCovered && !truncated; }
   double UpPct()      const { return pairs > 0 ? 100.0 * up   / pairs : EMPTY_VALUE; }
   double DownPct()    const { return pairs > 0 ? 100.0 * down / pairs : EMPTY_VALUE; }
   double GapPct()     const { return pairs > 0 ? 100.0 * gaps / pairs : EMPTY_VALUE; }
};

class CTimeframeData
{
public:
   string          label;
   ENUM_TIMEFRAMES tf;
   MqlRates        bars[];
   double          closes[];
   double          atr[];
   double          spread[];           // price units per bar (history spread, median-filled when missing)
   int             years[];
   int             firstWindowIdx;     // first bar on/after RESEARCH_START
   int             lastWindowIdx;      // last bar on/before RESEARCH_END
   bool            startCovered, endCovered, truncated;
   double          medianSpread;
   double          zeroSpreadPct;

   CTimeframeData() : label(""), tf(PERIOD_CURRENT), firstWindowIdx(0), lastWindowIdx(-1),
                      startCovered(false), endCovered(false), truncated(false),
                      medianSpread(0.0), zeroSpreadPct(0.0) {}

   int Count() const { return ArraySize(bars); }

   bool Load(const string symbol, const ENUM_TIMEFRAMES timeframe, const string name,
             const datetime from, const datetime to, const int maxPeriod)
   {
      tf    = timeframe;
      label = name;
      if(!LoadRates(symbol, tf, WarmupStart(tf, maxPeriod), to, bars)) return false;

      const int n = ArraySize(bars);
      ArrayResize(closes, n);
      ArrayResize(years, n);
      for(int i = 0; i < n; i++)
      {
         closes[i] = bars[i].close;
         MqlDateTime dt;
         TimeToStruct(bars[i].time, dt);
         years[i] = dt.year;
      }
      ComputeAtr(bars, ATR_PERIOD, atr);

      firstWindowIdx = n;
      lastWindowIdx  = -1;
      for(int i = 0; i < n; i++)
      {
         if(firstWindowIdx == n && bars[i].time >= from) firstWindowIdx = i;
         if(bars[i].time <= to) lastWindowIdx = i;
      }

      startCovered = firstWindowIdx < n &&
                     (long)(bars[firstWindowIdx].time - from) <= COVERAGE_TOLERANCE_SEC;
      endCovered   = lastWindowIdx >= 0 &&
                     (long)(to - bars[lastWindowIdx].time) <= COVERAGE_TOLERANCE_SEC;
      truncated    = n >= (int)TerminalInfoInteger(TERMINAL_MAXBARS);

      if(firstWindowIdx >= n || lastWindowIdx < 0) return false;
      BuildSpreads(symbol);
      return true;
   }

private:
   //--- History spread (points -> price). Bars without one get the window median.
   void BuildSpreads(const string symbol)
   {
      const int    n     = ArraySize(bars);
      const double point = SymbolInfoDouble(symbol, SYMBOL_POINT);

      double nonZero[];
      ArrayResize(nonZero, 0, 4096);
      for(int i = firstWindowIdx; i <= lastWindowIdx; i++)
      {
         if(bars[i].spread <= 0) continue;
         const int k = ArraySize(nonZero);
         ArrayResize(nonZero, k + 1, 4096);
         nonZero[k] = (double)bars[i].spread;
      }
      const double medianPoints = ArraySize(nonZero) > 0
                                  ? Quantile(nonZero, 0.5)
                                  : (double)SymbolInfoInteger(symbol, SYMBOL_SPREAD);
      medianSpread = medianPoints * point;

      ArrayResize(spread, n);
      int zero = 0;
      for(int i = 0; i < n; i++)
      {
         if(bars[i].spread > 0) spread[i] = bars[i].spread * point;
         else
         {
            spread[i] = medianSpread;
            if(i >= firstWindowIdx && i <= lastWindowIdx) zero++;
         }
      }
      const int windowBars = lastWindowIdx - firstWindowIdx + 1;
      zeroSpreadPct = windowBars > 0 ? 100.0 * zero / windowBars : 0.0;
   }

public:
   //--- Unconditional facts about this timeframe (the "any candle" baseline)
   void Profile(STimeframeSummary &s) const
   {
      s.Reset();
      const int  n          = ArraySize(bars);
      const long barSeconds = PeriodSeconds(tf);
      s.firstBar      = bars[0].time;
      s.lastBar       = bars[n - 1].time;
      s.barsTotal     = n;
      s.startCovered  = startCovered;
      s.endCovered    = endCovered;
      s.truncated     = truncated;
      s.medianSpread  = medianSpread;
      s.zeroSpreadPct = zeroSpreadPct;

      double atrInWindow[];
      ArrayResize(atrInWindow, 0, 4096);
      for(int i = firstWindowIdx; i <= lastWindowIdx; i++)
      {
         s.barsInWindow++;
         if(atr[i] != EMPTY_VALUE)
         {
            const int k = ArraySize(atrInWindow);
            ArrayResize(atrInWindow, k + 1, 4096);
            atrInWindow[k] = atr[i];
         }
         if(i + 1 < n)
         {
            s.pairs++;
            if(closes[i + 1] > closes[i])      s.up++;
            else if(closes[i + 1] < closes[i]) s.down++;
            if(IsSessionGap(bars[i].time, bars[i + 1].time, barSeconds)) s.gaps++;
         }
      }
      s.medianAtr = Quantile(atrInWindow, 0.5);
   }
};

//+==================================================================+
//| SECTION 6: crossings and per-event measurements                   |
//+==================================================================+
//--- +1 bullish close-through, -1 bearish close-through, 0 none
int CrossDirection(const double &closes[], const double &ma[], const int b)
{
   if(b < 1 || ma[b - 1] == EMPTY_VALUE || ma[b] == EMPTY_VALUE) return 0;
   if(closes[b - 1] <= ma[b - 1] && closes[b] > ma[b]) return 1;
   if(closes[b - 1] >= ma[b - 1] && closes[b] < ma[b]) return -1;
   return 0;
}

//--- For every bar: index of the previous / next crossing (any direction)
class CCrossMap
{
public:
   int prevCross[];     // -1 = none before
   int nextCross[];     // n  = none after

   void Build(const double &closes[], const double &ma[])
   {
      const int n = ArraySize(closes);
      ArrayResize(prevCross, n);
      ArrayResize(nextCross, n);

      int last = -1;
      for(int b = 0; b < n; b++)
      {
         prevCross[b] = last;
         if(CrossDirection(closes, ma, b) != 0) last = b;
      }
      int next = n;
      for(int b = n - 1; b >= 0; b--)
      {
         nextCross[b] = next;
         if(CrossDirection(closes, ma, b) != 0) next = b;
      }
   }
};

//--- Everything we measure about one (candle, next candle) pair
struct SEvent
{
   bool   sameSide;      // next close still on the trend side of the MA
   bool   respected;     // next close beyond this close, in trend direction
   bool   bodyDir;       // next candle body in trend direction
   bool   higherHigh;    // next high > this high
   bool   lowerLow;      // next low  < this low
   bool   contExt;       // extended in the trend direction (HH for bull, LL for bear)
   bool   advExt;        // extended against the trend       (LL for bull, HH for bear)
   bool   isolated;      // no other crossing in the previous `period` bars
   bool   gapNext;       // a session break lies between the two candles
   bool   whipKnown;     // enough bars exist to judge whipsaw
   bool   whipsaw;       // another crossing within `period` bars
   double retAtr;        // (next close - close) in trend direction, in ATR units
   double distAtr;       // |close - MA| in ATR units
   int    year;
};

void BuildEvent(const int dir, const MqlRates &cur, const MqlRates &next,
                const double maCur, const double maNext, const double atr,
                const int year, const long barSeconds, SEvent &e)
{
   const double sign = (double)dir;
   e.sameSide   = sign * (next.close - maNext)    > 0.0;
   e.respected  = sign * (next.close - cur.close) > 0.0;
   e.bodyDir    = sign * (next.close - next.open) > 0.0;
   e.higherHigh = next.high > cur.high;
   e.lowerLow   = next.low  < cur.low;
   e.contExt    = dir > 0 ? e.higherHigh : e.lowerLow;
   e.advExt     = dir > 0 ? e.lowerLow   : e.higherHigh;
   e.gapNext    = IsSessionGap(cur.time, next.time, barSeconds);
   e.retAtr     = sign * (next.close - cur.close) / atr;
   e.distAtr    = MathAbs(cur.close - maCur) / atr;
   e.year       = year;
   e.isolated   = false;
   e.whipKnown  = false;
   e.whipsaw    = false;
}

//--- Counters for one cohort of events (reusable for any slice)
struct SCounts
{
   int n, same, resp, body;
   int neither, hhOnly, llOnly, both;
   int contExt, advExt, gapNext;
   int whipN, whipK;

   void Reset()
   {
      n = 0; same = 0; resp = 0; body = 0;
      neither = 0; hhOnly = 0; llOnly = 0; both = 0;
      contExt = 0; advExt = 0; gapNext = 0;
      whipN = 0; whipK = 0;
   }

   void Add(const SEvent &e)
   {
      n++;
      if(e.sameSide)  same++;
      if(e.respected) resp++;
      if(e.bodyDir)   body++;
      if(e.higherHigh && e.lowerLow) both++;
      else if(e.higherHigh)          hhOnly++;
      else if(e.lowerLow)            llOnly++;
      else                           neither++;
      if(e.contExt) contExt++;
      if(e.advExt)  advExt++;
      if(e.gapNext) gapNext++;
      if(e.whipKnown) { whipN++; if(e.whipsaw) whipK++; }
   }

   void Merge(const SCounts &o)
   {
      n += o.n; same += o.same; resp += o.resp; body += o.body;
      neither += o.neither; hhOnly += o.hhOnly; llOnly += o.llOnly; both += o.both;
      contExt += o.contExt; advExt += o.advExt; gapNext += o.gapNext;
      whipN += o.whipN; whipK += o.whipK;
   }
};

struct SDistanceBuckets
{
   double  cut1, cut2;
   SCounts bucket[DIST_BUCKETS];

   void Reset()
   {
      cut1 = EMPTY_VALUE; cut2 = EMPTY_VALUE;
      for(int i = 0; i < DIST_BUCKETS; i++) bucket[i].Reset();
   }
};

//--- All next-candle statistics for one cohort (breakout events, or the baseline)
class CCohortStats
{
   bool   m_keepEvents;
   SEvent m_events[];
public:
   SCounts  all;
   SCounts  isolated;                 // de-clustered subset
   SCounts  noGap;                    // next candle not across a session break
   SCounts  byYear[YEAR_COUNT];
   SMoments ret;                      // next-candle return in ATR units, trend direction

   CCohortStats(const bool keepEvents) : m_keepEvents(keepEvents)
   {
      all.Reset(); isolated.Reset(); noGap.Reset(); ret.Reset();
      for(int y = 0; y < YEAR_COUNT; y++) byYear[y].Reset();
   }

   void Add(const SEvent &e)
   {
      all.Add(e);
      if(e.isolated) isolated.Add(e);
      if(!e.gapNext) noGap.Add(e);
      const int y = e.year - FIRST_YEAR;
      if(y >= 0 && y < YEAR_COUNT) byYear[y].Add(e);
      ret.Add(e.retAtr);

      if(m_keepEvents)
      {
         const int k = ArraySize(m_events);
         ArrayResize(m_events, k + 1, 4096);
         m_events[k] = e;
      }
   }

   //--- Merge a range of calendar years into one counter (stability splits)
   void Era(const int fromYear, const int toYear, SCounts &out) const
   {
      out.Reset();
      for(int y = fromYear; y <= toYear; y++)
         out.Merge(byYear[y - FIRST_YEAR]);
   }

   double MedianRet() const
   {
      const int n = ArraySize(m_events);
      if(n == 0) return EMPTY_VALUE;
      double v[];
      ArrayResize(v, n);
      for(int i = 0; i < n; i++) v[i] = m_events[i].retAtr;
      return Quantile(v, 0.5);
   }

   //--- Split events into terciles of breakout distance (data-derived cutoffs)
   void Distances(SDistanceBuckets &out) const
   {
      out.Reset();
      const int n = ArraySize(m_events);
      if(n < DIST_BUCKETS) return;

      double d[];
      ArrayResize(d, n);
      for(int i = 0; i < n; i++) d[i] = m_events[i].distAtr;
      out.cut1 = Quantile(d, 1.0 / 3.0);
      out.cut2 = Quantile(d, 2.0 / 3.0);

      for(int i = 0; i < n; i++)
      {
         const double x = m_events[i].distAtr;
         const int    k = x <= out.cut1 ? 0 : (x <= out.cut2 ? 1 : 2);
         out.bucket[k].Add(m_events[i]);
      }
   }
};

//+==================================================================+
//| SECTION 7: trade simulation (every signal is traded)              |
//+==================================================================+
struct STrade
{
   double grossR;       // before spread
   double netR;         // after spread
   double mfeR;         // best excursion while open, in R
   double maeR;         // worst excursion while open, in R
   int    bars;         // candles endured
};

//--- Mutable state of one open trade, handed to the exit rule each candle
struct STradeState
{
   int    dir;          // +1 long, -1 short
   int    entryIdx;
   double entry;
   double risk;         // 1R in price units
   double stop;
   double mfe;          // favourable excursion so far, price units
   double mae;          // adverse excursion so far, price units
};

//--- Exit strategy interface. Called AFTER a candle survived its stop.
//--- May move s.stop. Returns true to leave the market at `fill`.
class IExitRule
{
public:
   virtual        ~IExitRule() {}
   virtual string Name() const = 0;
   virtual bool   OnBar(const int i, CTimeframeData &data, const double &ma[],
                        const MqlRates &bar, STradeState &s, double &fill) = 0;
};

//--- Close of the entry candle: the research's "next candle", priced in R
class CNextBarExit : public IExitRule
{
public:
   virtual string Name() const { return "NEXT_BAR"; }
   virtual bool OnBar(const int i, CTimeframeData &data, const double &ma[],
                      const MqlRates &bar, STradeState &s, double &fill)
   {
      if(i != s.entryIdx) return false;
      fill = bar.close;
      return true;
   }
};

//--- Stair-step trail: after each completed R level the stop sits one whole R behind it.
//--- +1R reached -> stop at breakeven, +2R -> stop at +1R, +3R -> +2R ...
class CStairStepExit : public IExitRule
{
public:
   virtual string Name() const { return "STAIR_STEP"; }
   virtual bool OnBar(const int i, CTimeframeData &data, const double &ma[],
                      const MqlRates &bar, STradeState &s, double &fill)
   {
      const int level = (int)MathFloor(s.mfe / s.risk + 1e-9);
      if(level >= 1)
      {
         const double newStop = s.entry + s.dir * (level - 1) * s.risk;
         if(s.dir * (newStop - s.stop) > 0.0) s.stop = newStop;
      }
      return false;
   }
};

//--- Leave at the next open once a candle closes back through the MA
class CMaFlipExit : public IExitRule
{
public:
   virtual string Name() const { return "MA_FLIP"; }
   virtual bool OnBar(const int i, CTimeframeData &data, const double &ma[],
                      const MqlRates &bar, STradeState &s, double &fill)
   {
      if(ma[i] == EMPTY_VALUE) return false;
      if(SideOf(bar.close, ma[i]) != -s.dir) return false;
      fill = (i + 1 < data.Count()) ? data.bars[i + 1].open : bar.close;
      return true;
   }
};

class CTradeSimulator
{
   IExitRule *m_rules[EXIT_COUNT];
public:
   CTradeSimulator()
   {
      m_rules[EXIT_NEXT_BAR]   = new CNextBarExit();
      m_rules[EXIT_STAIR_STEP] = new CStairStepExit();
      m_rules[EXIT_MA_FLIP]    = new CMaFlipExit();
   }

   ~CTradeSimulator()
   {
      for(int i = 0; i < EXIT_COUNT; i++) delete m_rules[i];
   }

   //--- Enter at the open of entryIdx, risk stopMult x ATR, leave per the chosen rule.
   void Run(const int rule, const double stopMult, const int dir, const int entryIdx,
            const double atr, const double spreadPrice,
            CTimeframeData &data, const double &ma[], STrade &t)
   {
      STradeState s;
      s.dir      = dir;
      s.entryIdx = entryIdx;
      s.entry    = data.bars[entryIdx].open;
      s.risk     = stopMult * atr;
      s.stop     = s.entry - dir * s.risk;
      s.mfe      = 0.0;
      s.mae      = 0.0;

      const int n = data.Count();
      double exitPrice = data.bars[n - 1].close;      // still open at end of data
      int    held      = n - entryIdx;

      for(int i = entryIdx; i < n; i++)
      {
         const MqlRates bar = data.bars[i];
         const double adverse = dir > 0 ? bar.low : bar.high;
         s.mae = MathMax(s.mae, dir * (s.entry - adverse));

         //--- adverse-first: if the stop was touched this candle, we are out
         if(dir * (s.stop - adverse) >= 0.0)
         {
            exitPrice = (dir * (s.stop - bar.open) >= 0.0) ? bar.open : s.stop;   // gap fills at the open
            held      = i - entryIdx + 1;
            break;
         }

         const double favourable = dir > 0 ? bar.high : bar.low;
         s.mfe = MathMax(s.mfe, dir * (favourable - s.entry));

         double fill = 0.0;
         if(m_rules[rule].OnBar(i, data, ma, bar, s, fill))
         {
            exitPrice = fill;
            held      = i - entryIdx + 1;
            break;
         }
      }

      t.grossR = dir * (exitPrice - s.entry) / s.risk;
      t.netR   = t.grossR - spreadPrice / s.risk;
      t.mfeR   = s.mfe / s.risk;
      t.maeR   = s.mae / s.risk;
      t.bars   = held;
   }
};

//+==================================================================+
//| SECTION 8: R statistics                                           |
//+==================================================================+
int RBin(const double r)
{
   if(r <= -0.5) return 0;      // loss
   if(r <=  0.5) return 1;      // scratch / breakeven
   if(r <=  1.5) return 2;      // ~ +1R
   if(r <=  2.5) return 3;      // ~ +2R
   if(r <=  4.5) return 4;      // +3R .. +4R
   return 5;                    // runners
}

struct SRStats
{
   int      n, wins;
   double   sumGross, sumWin, sumLoss;       // win/loss sums are on net R
   double   sumMfe, sumMae, sumHold, sumCost;
   double   equity, peak, maxDD;             // sequential, in signal order
   SMoments net;                             // net R moments (mean, variance, t)
   int      bins[R_BINS];

   void Reset()
   {
      n = 0; wins = 0;
      sumGross = 0.0; sumWin = 0.0; sumLoss = 0.0;
      sumMfe = 0.0; sumMae = 0.0; sumHold = 0.0; sumCost = 0.0;
      equity = 0.0; peak = 0.0; maxDD = 0.0;
      net.Reset();
      for(int i = 0; i < R_BINS; i++) bins[i] = 0;
   }

   void Add(const STrade &t)
   {
      n++;
      sumGross += t.grossR;
      net.Add(t.netR);
      if(t.netR > 0.0) { wins++; sumWin += t.netR; } else sumLoss += t.netR;
      sumMfe  += t.mfeR;
      sumMae  += t.maeR;
      sumHold += t.bars;
      sumCost += t.grossR - t.netR;
      equity  += t.netR;
      peak     = MathMax(peak, equity);
      maxDD    = MathMax(maxDD, peak - equity);
      bins[RBin(t.netR)]++;
   }

   //--- Additive merge (era splits). Equity/drawdown are sequence-dependent and are not merged.
   void MergeBasic(const SRStats &o)
   {
      n += o.n; wins += o.wins;
      sumGross += o.sumGross; sumWin += o.sumWin; sumLoss += o.sumLoss;
      sumMfe += o.sumMfe; sumMae += o.sumMae; sumHold += o.sumHold; sumCost += o.sumCost;
      net.Merge(o.net);
   }

   double Exp()      const { return n > 0 ? net.mean : EMPTY_VALUE; }
   double ExpGross() const { return n > 0 ? sumGross / n : EMPTY_VALUE; }
   double PF()       const { return sumLoss < 0.0 ? sumWin / (-sumLoss) : EMPTY_VALUE; }
   double AvgWin()   const { return wins > 0 ? sumWin / wins : EMPTY_VALUE; }
   double AvgLoss()  const { return (n - wins) > 0 ? sumLoss / (n - wins) : EMPTY_VALUE; }
   double Payoff()   const { return (wins > 0 && sumLoss < 0.0) ? AvgWin() / MathAbs(AvgLoss()) : EMPTY_VALUE; }
   double ExpLo()    const { return n > 1 ? net.mean - net.HalfWidth() : EMPTY_VALUE; }
   double ExpHi()    const { return n > 1 ? net.mean + net.HalfWidth() : EMPTY_VALUE; }
};

//--- All R statistics for one (cohort, stop, exit) combination
class CTradeLedger
{
public:
   SRStats all;
   SRStats isolated;
   SRStats byYear[YEAR_COUNT];

   CTradeLedger()
   {
      all.Reset(); isolated.Reset();
      for(int y = 0; y < YEAR_COUNT; y++) byYear[y].Reset();
   }

   void Add(const STrade &t, const bool isIsolated, const int year)
   {
      all.Add(t);
      if(isIsolated) isolated.Add(t);
      const int y = year - FIRST_YEAR;
      if(y >= 0 && y < YEAR_COUNT) byYear[y].Add(t);
   }

   void Era(const int fromYear, const int toYear, SRStats &out) const
   {
      out.Reset();
      for(int y = fromYear; y <= toYear; y++)
         out.MergeBasic(byYear[y - FIRST_YEAR]);
   }
};

//--- Forward return (ATR units) by number of bars held: where does the edge live and die?
struct SHorizonCohort
{
   SMoments m[HORIZON_COUNT];
   int      pos[HORIZON_COUNT];

   void Reset()
   {
      for(int h = 0; h < HORIZON_COUNT; h++) { m[h].Reset(); pos[h] = 0; }
   }

   void Add(const int h, const double r)
   {
      m[h].Add(r);
      if(r > 0.0) pos[h]++;
   }
};

class CHorizonStats
{
public:
   SHorizonCohort brk;
   SHorizonCohort iso;
   SHorizonCohort base;
   CHorizonStats() { brk.Reset(); iso.Reset(); base.Reset(); }
};

//--- Everything measured for one (cell, direction)
class CDirectionResult
{
public:
   CCohortStats  breakout;
   CCohortStats  baseline;
   CTradeLedger  breakoutR[COMBO_COUNT];
   CTradeLedger  baselineR[COMBO_COUNT];
   CHorizonStats horizons;
   CDirectionResult() : breakout(true), baseline(false) {}
};

//+==================================================================+
//| SECTION 9: observation (the actual research logic)                |
//+==================================================================+
class CBreakoutObserver
{
   CTradeSimulator m_sim;

   //--- clustering context: how isolated is this breakout, did it fail within one MA window?
   void Annotate(const int b, const int n, const int period, const CCrossMap &cross, SEvent &e) const
   {
      const int prev = cross.prevCross[b];
      e.isolated = (prev < 0) || (b - prev >= period);

      const int next = cross.nextCross[b];
      if(next < n)
      {
         e.whipKnown = true;
         e.whipsaw   = (next - b) <= period;
      }
      else
      {
         e.whipKnown = (n - 1 - b) >= period;
         e.whipsaw   = false;
      }
   }

   //--- Forward return after `h` bars held, entry at the next open, in ATR units
   void RecordHorizons(CDirectionResult *res, const bool isBreakout, const SEvent &e,
                       const int side, const int b, CTimeframeData &data)
   {
      const int    n     = data.Count();
      const double entry = data.bars[b + 1].open;
      for(int h = 0; h < HORIZON_COUNT; h++)
      {
         const int exitIdx = b + g_horizons[h];
         if(exitIdx >= n) break;
         const double r = side * (data.closes[exitIdx] - entry) / data.atr[b];
         if(isBreakout)
         {
            res.horizons.brk.Add(h, r);
            if(e.isolated) res.horizons.iso.Add(h, r);
         }
         else
            res.horizons.base.Add(h, r);
      }
   }

   //--- Trade the signal under every (exit model x stop size) combination
   void RecordTrades(CDirectionResult *res, const bool isBreakout, const SEvent &e,
                     const int side, const int b, CTimeframeData &data, const double &ma[])
   {
      for(int rule = 0; rule < EXIT_COUNT; rule++)
      {
         for(int s = 0; s < STOP_COUNT; s++)
         {
            STrade t;
            m_sim.Run(rule, g_stopAtr[s], side, b + 1, data.atr[b], data.spread[b + 1], data, ma, t);
            const int combo = rule * STOP_COUNT + s;
            if(isBreakout) res.breakoutR[combo].Add(t, e.isolated, e.year);
            else           res.baselineR[combo].Add(t, false, e.year);
         }
      }
   }

   void Record(CDirectionResult *res, const bool isBreakout, const SEvent &e,
               const int side, const int b, CTimeframeData &data, const double &ma[])
   {
      if(isBreakout) res.breakout.Add(e);
      else           res.baseline.Add(e);
      RecordHorizons(res, isBreakout, e, side, b, data);
      RecordTrades(res, isBreakout, e, side, b, data, ma);
   }

public:
   //--- Breakout : close crosses the MA (prev close on/below -> above, or mirror).
   //--- Baseline : close AND previous close on the same side (no crossing).
   void Observe(CTimeframeData &data, const double &ma[], CCrossMap &cross, const int period,
                CDirectionResult &bull, CDirectionResult &bear)
   {
      const int  n          = data.Count();
      const long barSeconds = PeriodSeconds(data.tf);
      const int  first      = MathMax(data.firstWindowIdx, 1);
      const int  last       = MathMin(data.lastWindowIdx, n - 2);

      for(int b = first; b <= last; b++)
      {
         if(ma[b - 1] == EMPTY_VALUE || ma[b] == EMPTY_VALUE || ma[b + 1] == EMPTY_VALUE) continue;
         if(data.atr[b] == EMPTY_VALUE || data.atr[b] <= 0.0) continue;

         const int  crossDir   = CrossDirection(data.closes, ma, b);
         const bool isBreakout = crossDir != 0;
         int        side       = crossDir;
         if(!isBreakout)
         {
            side = SideOf(data.closes[b], ma[b]);
            if(side == 0 || SideOf(data.closes[b - 1], ma[b - 1]) != side) continue;
         }

         SEvent e;
         BuildEvent(side, data.bars[b], data.bars[b + 1], ma[b], ma[b + 1],
                    data.atr[b], data.years[b], barSeconds, e);
         if(isBreakout) Annotate(b, n, period, cross, e);

         CDirectionResult *res = side > 0 ? GetPointer(bull) : GetPointer(bear);
         Record(res, isBreakout, e, side, b, data, ma);
      }
   }
};

//+==================================================================+
//| SECTION 10: reporting                                             |
//+==================================================================+
string NumCell(const double v, const int digits = 2)
{
   if(v == EMPTY_VALUE || !MathIsValidNumber(v)) return "";
   return DoubleToString(v, digits);
}

string Pct(const int k, const int n)
{
   return n > 0 ? NumCell(100.0 * k / n) : "";
}

class CRow
{
   string m_header;
   string m_line;
   bool   m_empty;
public:
   CRow() : m_header(""), m_line(""), m_empty(true) {}

   void Add(const string name, const string value)
   {
      if(!m_empty) { m_header += ","; m_line += ","; }
      m_header += name;
      m_line   += value;
      m_empty   = false;
   }
   void AddInt(const string name, const int v)                     { Add(name, IntegerToString(v)); }
   void AddNum(const string name, const double v, const int d = 2) { Add(name, NumCell(v, d)); }

   string Header() const { return m_header; }
   string Line()   const { return m_line; }
};

class CCsvFile
{
   int  m_handle;
   bool m_headerWritten;

   void WriteLine(const string line)
   {
      if(m_handle != INVALID_HANDLE)
         FileWriteString(m_handle, line + "\r\n");
   }
public:
   CCsvFile() : m_handle(INVALID_HANDLE), m_headerWritten(false) {}
   ~CCsvFile() { Close(); }

   bool Open(const string file)
   {
      m_handle = FileOpen(file, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_SHARE_READ);
      return m_handle != INVALID_HANDLE;
   }

   void WriteRow(const CRow &row)
   {
      if(!m_headerWritten) { WriteLine(row.Header()); m_headerWritten = true; }
      WriteLine(row.Line());
   }

   void Close()
   {
      if(m_handle != INVALID_HANDLE) { FileClose(m_handle); m_handle = INVALID_HANDLE; }
   }
};

//--- Identity of one result cell
struct SCellId
{
   string          tf;
   datetime        firstBar;
   string          ma;
   int             period;
   EBreakDirection dir;
   bool            coverageOk;
   bool            warmOk;
   double          uncondRespPct;   // P(next close moves in this direction) for ANY candle on this TF
   double          medianAtr;       // price units
   double          usdPerPrice;     // USD P&L per 1.00 price move at the minimum lot
   double          accountUsd;
};

//--- Column-group builders (each used by several reports)
void AddIdentity(CRow &row, const SCellId &id)
{
   row.Add("timeframe", id.tf);
   row.Add("ma", id.ma);
   row.AddInt("period", id.period);
   row.Add("direction", DirectionName(id.dir));
}

void AddProportion(CRow &row, const string prefix, const int k, const int n)
{
   double lo = 0.0, hi = 0.0;
   if(n > 0) WilsonInterval(k, n, lo, hi);
   row.AddNum(prefix + "_pct",   n > 0 ? 100.0 * k / n : EMPTY_VALUE);
   row.AddNum(prefix + "_ci_lo", n > 0 ? 100.0 * lo : EMPTY_VALUE);
   row.AddNum(prefix + "_ci_hi", n > 0 ? 100.0 * hi : EMPTY_VALUE);
}

//--- n, same-side % (+CI), respected % (+CI)
void AddCohort(CRow &row, const string prefix, const SCounts &c)
{
   row.AddInt(prefix + "_n", c.n);
   AddProportion(row, prefix + "_same", c.same, c.n);
   AddProportion(row, prefix + "_resp", c.resp, c.n);
}

//--- Lift in percentage points over the baseline + two-proportion p-values
void AddLift(CRow &row, const string prefix, const SCounts &ev, const SCounts &base)
{
   const bool ok = ev.n > 0 && base.n > 0;
   row.AddNum(prefix + "_same_lift_pp", ok ? 100.0 * ((double)ev.same / ev.n - (double)base.same / base.n) : EMPTY_VALUE);
   row.AddNum(prefix + "_same_p",       ok ? TwoProportionP(ev.same, ev.n, base.same, base.n) : EMPTY_VALUE, 6);
   row.AddNum(prefix + "_resp_lift_pp", ok ? 100.0 * ((double)ev.resp / ev.n - (double)base.resp / base.n) : EMPTY_VALUE);
   row.AddNum(prefix + "_resp_p",       ok ? TwoProportionP(ev.resp, ev.n, base.resp, base.n) : EMPTY_VALUE, 6);
}

void AddWicks(CRow &row, const SCounts &c)
{
   row.AddInt("wick_neither_n",  c.neither);
   row.AddInt("wick_hh_only_n",  c.hhOnly);
   row.AddInt("wick_ll_only_n",  c.llOnly);
   row.AddInt("wick_both_n",     c.both);
   row.Add("wick_neither_pct",   Pct(c.neither, c.n));
   row.Add("wick_hh_only_pct",   Pct(c.hhOnly, c.n));
   row.Add("wick_ll_only_pct",   Pct(c.llOnly, c.n));
   row.Add("wick_both_pct",      Pct(c.both, c.n));
   row.Add("cont_ext_pct",       Pct(c.contExt, c.n));     // extended in trend direction (any)
   row.Add("adv_ext_pct",        Pct(c.advExt, c.n));      // extended against the trend (any)
   row.Add("body_dir_pct",       Pct(c.body, c.n));
}

void AddReturns(CRow &row, CDirectionResult &r)
{
   row.AddNum("ret_mean_atr",      r.breakout.ret.Mean(), 3);
   row.AddNum("ret_median_atr",    r.breakout.MedianRet(), 3);
   row.AddNum("ret_t",             r.breakout.ret.TStat(), 2);
   row.AddNum("base_ret_mean_atr", r.baseline.ret.Mean(), 3);
   row.AddNum("ret_lift_t",        WelchT(r.breakout.ret, r.baseline.ret), 2);
}

void AddClustering(CRow &row, const SCounts &c)
{
   row.AddInt("whipsaw_n", c.whipN);
   row.Add("whipsaw_pct",  Pct(c.whipK, c.whipN));     // another crossing within one MA window
   row.Add("gap_next_pct", Pct(c.gapNext, c.n));
}

void AddDistance(CRow &row, const SDistanceBuckets &db)
{
   const string labels[] = {"near", "mid", "far"};
   row.AddNum("dist_q33_atr", db.cut1, 3);
   row.AddNum("dist_q67_atr", db.cut2, 3);
   for(int i = 0; i < DIST_BUCKETS; i++)
   {
      row.AddInt(labels[i] + "_n", db.bucket[i].n);
      row.Add(labels[i] + "_same_pct", Pct(db.bucket[i].same, db.bucket[i].n));
      row.Add(labels[i] + "_resp_pct", Pct(db.bucket[i].resp, db.bucket[i].n));
   }
}

//--- Full R profile of one cohort
void AddRBlock(CRow &row, const string prefix, const SRStats &s)
{
   row.AddInt(prefix + "_n", s.n);
   AddProportion(row, prefix + "_win", s.wins, s.n);
   row.AddNum(prefix + "_exp_gross_r", s.ExpGross(), 3);
   row.AddNum(prefix + "_exp_net_r",   s.Exp(), 3);
   row.AddNum(prefix + "_exp_ci_lo",   s.ExpLo(), 3);
   row.AddNum(prefix + "_exp_ci_hi",   s.ExpHi(), 3);
   row.AddNum(prefix + "_exp_t",       s.net.TStat(), 2);
   row.AddNum(prefix + "_pf",          s.PF(), 2);
   row.AddNum(prefix + "_avg_win_r",   s.AvgWin(), 3);
   row.AddNum(prefix + "_avg_loss_r",  s.AvgLoss(), 3);
   row.AddNum(prefix + "_payoff",      s.Payoff(), 2);
   row.AddNum(prefix + "_total_net_r", s.n > 0 ? s.net.mean * s.n : EMPTY_VALUE, 1);
   row.AddNum(prefix + "_maxdd_r",     s.n > 0 ? s.maxDD : EMPTY_VALUE, 1);
   row.AddNum(prefix + "_avg_hold",    s.n > 0 ? s.sumHold / s.n : EMPTY_VALUE, 1);
   row.AddNum(prefix + "_avg_mfe_r",   s.n > 0 ? s.sumMfe / s.n : EMPTY_VALUE, 3);
   row.AddNum(prefix + "_avg_mae_r",   s.n > 0 ? s.sumMae / s.n : EMPTY_VALUE, 3);
   row.AddNum(prefix + "_avg_cost_r",  s.n > 0 ? s.sumCost / s.n : EMPTY_VALUE, 4);
}

//--- Expectancy edge over the baseline, in R, with a Welch t-statistic
void AddRLift(CRow &row, const string prefix, const SRStats &ev, const SRStats &base)
{
   const bool ok = ev.n > 0 && base.n > 0;
   row.AddNum(prefix + "_exp_lift_r", ok ? ev.net.mean - base.net.mean : EMPTY_VALUE, 3);
   row.AddNum(prefix + "_exp_lift_t", ok ? WelchT(ev.net, base.net) : EMPTY_VALUE, 2);
}

void AddRBins(CRow &row, const SRStats &s)
{
   const string labels[] = {"le_m0p5", "m0p5_0p5", "0p5_1p5", "1p5_2p5", "2p5_4p5", "gt_4p5"};
   for(int i = 0; i < R_BINS; i++)
      row.Add("rbin_" + labels[i] + "_pct", Pct(s.bins[i], s.n));
}

//--- Short R profile (eras, years)
void AddRBrief(CRow &row, const string prefix, const SRStats &s)
{
   row.AddInt(prefix + "_n", s.n);
   row.Add(prefix + "_win_pct",     Pct(s.wins, s.n));
   row.AddNum(prefix + "_exp_net_r", s.Exp(), 3);
   row.AddNum(prefix + "_sum_net_r", s.n > 0 ? s.net.mean * s.n : EMPTY_VALUE, 1);
}

void AddHorizonCohort(CRow &row, const string prefix, const SHorizonCohort &c, const int h)
{
   row.AddInt(prefix + "_n", c.m[h].n);
   row.AddNum(prefix + "_mean_atr", c.m[h].Mean(), 3);
   row.AddNum(prefix + "_t",        c.m[h].TStat(), 2);
   row.Add(prefix + "_hit_pct",     Pct(c.pos[h], c.m[h].n));
}

class CReport
{
   CCsvFile m_summary;
   CCsvFile m_yearly;
   CCsvFile m_timeframes;
   CCsvFile m_rmult;
   CCsvFile m_rmultYearly;
   CCsvFile m_horizon;

   void WriteSummary(const SCellId &id, CDirectionResult &r)
   {
      SCounts era1, era2;
      r.breakout.Era(FIRST_YEAR, ERA2_FIRST_YEAR - 1, era1);
      r.breakout.Era(ERA2_FIRST_YEAR, LAST_YEAR, era2);
      SDistanceBuckets db;
      r.breakout.Distances(db);

      CRow row;
      AddIdentity(row, id);
      row.Add("first_bar", TimeToString(id.firstBar, TIME_DATE));
      row.Add("coverage_ok", id.coverageOk ? "yes" : "NO");
      row.Add("warm_ok",     id.warmOk ? "yes" : "NO");
      row.Add("low_sample",  r.breakout.all.n < LOW_SAMPLE_THRESHOLD ? "YES" : "no");

      AddCohort(row, "all",    r.breakout.all);
      AddCohort(row, "iso",    r.breakout.isolated);
      AddCohort(row, "nogap",  r.breakout.noGap);
      AddCohort(row, "base",   r.baseline.all);
      AddCohort(row, "era1",   era1);
      AddCohort(row, "era2",   era2);

      AddLift(row, "lift_all", r.breakout.all,      r.baseline.all);
      AddLift(row, "lift_iso", r.breakout.isolated, r.baseline.all);
      row.AddNum("uncond_resp_pct", id.uncondRespPct);

      AddWicks(row, r.breakout.all);
      AddReturns(row, r);
      AddClustering(row, r.breakout.all);
      AddDistance(row, db);
      m_summary.WriteRow(row);
   }

   void WriteYearly(const SCellId &id, CDirectionResult &r)
   {
      for(int y = 0; y < YEAR_COUNT; y++)
      {
         CRow row;
         AddIdentity(row, id);
         row.AddInt("year", FIRST_YEAR + y);
         AddCohort(row, "brk",  r.breakout.byYear[y]);
         AddCohort(row, "base", r.baseline.byYear[y]);
         m_yearly.WriteRow(row);
      }
   }

   //--- One row per (exit model x stop size)
   void WriteRMultiples(const SCellId &id, CDirectionResult &r)
   {
      for(int combo = 0; combo < COMBO_COUNT; combo++)
      {
         const int    rule = combo / STOP_COUNT;
         const double mult = g_stopAtr[combo % STOP_COUNT];

         SRStats era1, era2;
         r.breakoutR[combo].Era(FIRST_YEAR, ERA2_FIRST_YEAR - 1, era1);
         r.breakoutR[combo].Era(ERA2_FIRST_YEAR, LAST_YEAR, era2);

         const double riskUsd = id.medianAtr == EMPTY_VALUE ? EMPTY_VALUE : mult * id.medianAtr * id.usdPerPrice;

         CRow row;
         AddIdentity(row, id);
         row.Add("exit_model", ExitName(rule));
         row.AddNum("stop_atr", mult, 1);
         row.Add("coverage_ok", id.coverageOk ? "yes" : "NO");
         row.Add("warm_ok",     id.warmOk ? "yes" : "NO");
         row.AddNum("median_risk_usd",      riskUsd, 2);
         row.AddNum("risk_pct_of_account",  riskUsd == EMPTY_VALUE ? EMPTY_VALUE : 100.0 * riskUsd / id.accountUsd, 1);

         AddRBlock(row, "all",  r.breakoutR[combo].all);
         AddRBlock(row, "iso",  r.breakoutR[combo].isolated);
         AddRBlock(row, "base", r.baselineR[combo].all);
         AddRLift(row, "lift_all", r.breakoutR[combo].all,      r.baselineR[combo].all);
         AddRLift(row, "lift_iso", r.breakoutR[combo].isolated, r.baselineR[combo].all);
         AddRBins(row, r.breakoutR[combo].all);
         AddRBrief(row, "era1", era1);
         AddRBrief(row, "era2", era2);
         m_rmult.WriteRow(row);

         for(int y = 0; y < YEAR_COUNT; y++)
         {
            CRow yrow;
            AddIdentity(yrow, id);
            yrow.Add("exit_model", ExitName(rule));
            yrow.AddNum("stop_atr", mult, 1);
            yrow.AddInt("year", FIRST_YEAR + y);
            AddRBrief(yrow, "brk",  r.breakoutR[combo].byYear[y]);
            AddRBrief(yrow, "base", r.baselineR[combo].byYear[y]);
            m_rmultYearly.WriteRow(yrow);
         }
      }
   }

   //--- One row per holding horizon
   void WriteHorizons(const SCellId &id, CDirectionResult &r)
   {
      for(int h = 0; h < HORIZON_COUNT; h++)
      {
         CRow row;
         AddIdentity(row, id);
         row.AddInt("horizon_bars", g_horizons[h]);
         AddHorizonCohort(row, "brk",  r.horizons.brk,  h);
         AddHorizonCohort(row, "iso",  r.horizons.iso,  h);
         AddHorizonCohort(row, "base", r.horizons.base, h);
         const bool ok = r.horizons.brk.m[h].n > 0 && r.horizons.base.m[h].n > 0;
         row.AddNum("lift_atr", ok ? r.horizons.brk.m[h].mean - r.horizons.base.m[h].mean : EMPTY_VALUE, 3);
         row.AddNum("lift_t",   ok ? WelchT(r.horizons.brk.m[h], r.horizons.base.m[h]) : EMPTY_VALUE, 2);
         m_horizon.WriteRow(row);
      }
   }

public:
   bool Open(const string prefix)
   {
      return m_summary.Open(prefix + "_summary.csv") &&
             m_yearly.Open(prefix + "_yearly.csv") &&
             m_timeframes.Open(prefix + "_timeframes.csv") &&
             m_rmult.Open(prefix + "_rmult.csv") &&
             m_rmultYearly.Open(prefix + "_rmult_yearly.csv") &&
             m_horizon.Open(prefix + "_horizon.csv");
   }

   void Close()
   {
      m_summary.Close(); m_yearly.Close(); m_timeframes.Close();
      m_rmult.Close(); m_rmultYearly.Close(); m_horizon.Close();
   }

   void WriteTimeframe(const string label, const STimeframeSummary &s)
   {
      CRow row;
      row.Add("timeframe", label);
      row.Add("first_bar", TimeToString(s.firstBar, TIME_DATE));
      row.Add("last_bar",  TimeToString(s.lastBar, TIME_DATE));
      row.AddInt("bars_total",     s.barsTotal);
      row.AddInt("bars_in_window", s.barsInWindow);
      row.Add("start_covered", s.startCovered ? "yes" : "NO");
      row.Add("end_covered",   s.endCovered ? "yes" : "NO");
      row.Add("truncated",     s.truncated ? "YES" : "no");
      row.Add("coverage_ok",   s.CoverageOk() ? "yes" : "NO");
      row.AddNum("up_close_pct",     s.UpPct());
      row.AddNum("down_close_pct",   s.DownPct());
      row.AddNum("session_gap_pct",  s.GapPct());
      row.AddNum("median_atr_usd",   s.medianAtr, 3);
      row.AddNum("median_spread_usd", s.medianSpread, 3);
      row.AddNum("zero_spread_pct",  s.zeroSpreadPct, 1);
      m_timeframes.WriteRow(row);
   }

   void WriteCell(const SCellId &id, CDirectionResult &r)
   {
      WriteSummary(id, r);
      WriteYearly(id, r);
      WriteRMultiples(id, r);
      WriteHorizons(id, r);

      const int stair2 = EXIT_STAIR_STEP * STOP_COUNT + 1;   // STAIR_STEP with the 2 ATR stop
      PrintFormat("%s %s(%d) %s | n=%d same=%s%% (base %s%%) resp=%s%% (base %s%%) | stair/2ATR expR=%s (base %s) iso_n=%d",
                  id.tf, id.ma, id.period, DirectionName(id.dir), r.breakout.all.n,
                  Pct(r.breakout.all.same, r.breakout.all.n), Pct(r.baseline.all.same, r.baseline.all.n),
                  Pct(r.breakout.all.resp, r.breakout.all.n), Pct(r.baseline.all.resp, r.baseline.all.n),
                  NumCell(r.breakoutR[stair2].all.Exp(), 3), NumCell(r.baselineR[stair2].all.Exp(), 3),
                  r.breakout.isolated.n);
   }
};

//+==================================================================+
//| SECTION 11: experiment orchestration                              |
//+==================================================================+
class CBreakoutExperiment
{
   string            m_symbol;
   datetime          m_from;
   datetime          m_to;
   CPeriodPolicy     m_policy;
   CBreakoutObserver m_observer;
   CReport          *m_report;
   double            m_usdPerPrice;
   double            m_accountUsd;

   void RunCell(CTimeframeData &data, const STimeframeSummary &summary,
                IMovingAverage *ma, const int period)
   {
      double series[];
      ma.Compute(data.closes, period, series);

      CCrossMap cross;
      cross.Build(data.closes, series);

      CDirectionResult bull, bear;
      m_observer.Observe(data, series, cross, period, bull, bear);

      SCellId id;
      id.tf          = data.label;
      id.firstBar    = summary.firstBar;
      id.ma          = ma.Name();
      id.period      = period;
      id.coverageOk  = summary.CoverageOk();
      id.warmOk      = data.firstWindowIdx >= ma.WarmupBars(period);
      id.medianAtr   = summary.medianAtr;
      id.usdPerPrice = m_usdPerPrice;
      id.accountUsd  = m_accountUsd;

      if(!id.warmOk)
         PrintFormat("*** WARNING [%s] %s(%d): only %d bars before %s, %d needed -> warm_ok=NO",
                     data.label, id.ma, period, data.firstWindowIdx,
                     TimeToString(m_from, TIME_DATE), ma.WarmupBars(period));

      id.dir           = BREAK_BULLISH;
      id.uncondRespPct = summary.UpPct();
      m_report.WriteCell(id, bull);

      id.dir           = BREAK_BEARISH;
      id.uncondRespPct = summary.DownPct();
      m_report.WriteCell(id, bear);
   }

   bool RunTimeframe(const STimeframe &frame)
   {
      CTimeframeData data;
      if(!data.Load(m_symbol, frame.tf, frame.label, m_from, m_to, m_policy.Max()))
      {
         PrintFormat("*** [%s] could not load history - skipped", frame.label);
         return false;
      }

      STimeframeSummary summary;
      data.Profile(summary);
      m_report.WriteTimeframe(frame.label, summary);

      PrintFormat("[%s] %d bars loaded (%d in window), %s -> %s | median spread %s, zero-spread bars %s%%",
                  frame.label, summary.barsTotal, summary.barsInWindow,
                  TimeToString(summary.firstBar, TIME_DATE), TimeToString(summary.lastBar, TIME_DATE),
                  NumCell(summary.medianSpread, 3), NumCell(summary.zeroSpreadPct, 1));
      if(!summary.CoverageOk())
         PrintFormat("*** WARNING [%s] coverage problem: startCovered=%d endCovered=%d truncated=%d "
                     "(raise Max bars in chart / download history). Results are flagged coverage_ok=NO.",
                     frame.label, summary.startCovered, summary.endCovered, summary.truncated);

      const ENUM_MA_METHOD methods[] = {MODE_SMA, MODE_EMA, MODE_LWMA};
      for(int m = 0; m < ArraySize(methods); m++)
      {
         IMovingAverage *ma = CreateMovingAverage(methods[m]);
         if(ma == NULL) continue;
         for(int p = 0; p < m_policy.Count(); p++)
            RunCell(data, summary, ma, m_policy.At(p));
         delete ma;
      }
      return true;
   }

public:
   CBreakoutExperiment(const string symbol, const datetime from, const datetime to,
                       const string periodsCsv, CReport *report,
                       const double usdPerPrice, const double accountUsd)
      : m_symbol(symbol), m_from(from), m_to(to), m_policy(periodsCsv), m_report(report),
        m_usdPerPrice(usdPerPrice), m_accountUsd(accountUsd) {}

   void Run()
   {
      STimeframe frames[];
      BuildTimeframes(frames);

      //--- Multiple comparisons: count the headline hypotheses we are about to test
      const int cells     = ArraySize(frames) * 3 * m_policy.Count() * 2;     // TF x MA x period x direction
      const int testsNext = cells * 2;                                        // same-side, respected
      const int testsR    = cells * COMBO_COUNT;                              // expectancy per exit x stop
      PrintFormat("Multiple comparisons: %d next-candle tests (Bonferroni alpha %.6f), %d R-expectancy tests (Bonferroni alpha %.7f). "
                  "Benjamini-Hochberg FDR is applied in the analysis step.",
                  testsNext, 0.05 / testsNext, testsR, 0.05 / testsR);

      for(int i = 0; i < ArraySize(frames); i++)
         RunTimeframe(frames[i]);
   }
};

//+==================================================================+
//| Entry point                                                       |
//+==================================================================+
void OnStart()
{
   if(!IsGold(_Symbol))
   {
      Alert("GoldBreakoutResearch runs on XAUUSD only. Attach it to an XAUUSD chart.");
      return;
   }
   SymbolSelect(_Symbol, true);

   const int maxBars = (int)TerminalInfoInteger(TERMINAL_MAXBARS);
   if(maxBars < MIN_RECOMMENDED_MAXBARS)
      PrintFormat("*** WARNING: 'Max bars in chart' = %d. Set it to Unlimited (Tools > Options > Charts) "
                  "or M15/M30 history will be truncated.", maxBars);

   //--- USD P&L per 1.00 price move at the broker's minimum lot (data-derived, not assumed)
   double contract = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   double minLot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(contract <= 0.0) contract = 100.0;
   if(minLot   <= 0.0) minLot   = 0.01;
   PrintFormat("Contract size %.2f, minimum lot %.2f -> USD per 1.00 price move = %.2f",
               contract, minLot, contract * minLot);

   CReport report;
   if(!report.Open(InpOutputPrefix))
   {
      PrintFormat("Cannot open output files with prefix %s (error %d)", InpOutputPrefix, GetLastError());
      return;
   }

   const uint started = GetTickCount();
   CBreakoutExperiment experiment(_Symbol, RESEARCH_START, RESEARCH_END, InpPeriodsOverride,
                                  &report, contract * minLot, InpAccountUsd);
   experiment.Run();

   report.Close();
   PrintFormat("Done in %.1f s. Results: MQL5\\Files\\%s_*.csv", (GetTickCount() - started) / 1000.0, InpOutputPrefix);
}
