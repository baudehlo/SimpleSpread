# SimpleSpread — Function Reference

156 built-in functions. Names are case-insensitive; arguments in square
brackets are optional; `...` is variadic. Semantics follow Google Sheets /
Excel shared behavior (see docs/RESEARCH.md for the coercion and criteria
rules that apply across all functions).

## Math (33)

| Function | Notes |
|---|---|
| SUM(v1, ...) | Ranges skip text/bool/blank; literals coerce |
| SUMIF(range, criterion, [sum_range]) | Criteria semantics; sum_range paired by offset |
| SUMIFS(sum_range, crit_range1, crit1, ...) | AND of all criteria; dimensions must match |
| SUMPRODUCT(a1, [a2, ...]) | Elementwise products; bools 1/0; text 0; dims must match |
| SUMSQ(v1, ...) | Sum of squares |
| PRODUCT(v1, ...) | |
| ABS(x), SIGN(x) | |
| SQRT(x), SQRTPI(x) | Negative → #NUM! |
| EXP(x), LN(x), LOG(x, [base=10]), LOG10(x) | Domain errors → #NUM! |
| PI() | |
| INT(x) | Floor: INT(-1.5) = -2 |
| TRUNC(x, [places=0]) | Toward zero: TRUNC(-1.5) = -1 |
| ROUND(x, [places=0]) | Half away from zero; negative places round left of decimal |
| ROUNDUP / ROUNDDOWN(x, [places=0]) | Away from / toward zero |
| MROUND(x, factor) | Nearest multiple; mixed signs → #NUM! |
| CEILING(x, [factor=1]) | CEILING(-2.5,2) = -2; x>0 with factor<0 → #NUM! |
| FLOOR(x, [factor=1]) | FLOOR(-2.5,2) = -4 |
| MOD(a, b) | Result takes divisor's sign; b=0 → #DIV/0! |
| QUOTIENT(a, b) | Truncated division |
| POWER(a, b) | 0^0 and non-finite results → #NUM! |
| EVEN(x), ODD(x) | Round away from zero to even/odd |
| FACT(n) | 0 ≤ n ≤ 170 |
| COMBIN(n, k) | |
| GCD(v1, ...), LCM(v1, ...) | Non-negative integers |
| RAND() | Volatile, [0, 1) |
| RANDBETWEEN(lo, hi) | Volatile, inclusive integers; lo > hi → #NUM! |

## Statistical (27)

| Function | Notes |
|---|---|
| AVERAGE / AVERAGEA(v1, ...) | A-variant counts text as 0, bools as 1/0; empty → #DIV/0! |
| AVERAGEIF(range, crit, [avg_range]) / AVERAGEIFS(avg, r1, c1, ...) | No match → #DIV/0! |
| COUNT(v1, ...) | Numbers only in ranges; coercible literals count |
| COUNTA(v1, ...) | All non-empty (errors included) |
| COUNTBLANK(range) | Blanks and "" |
| COUNTIF(range, crit) / COUNTIFS(r1, c1, ...) | |
| COUNTUNIQUE(v1, ...) | Distinct values (text case-insensitive) |
| MAX / MIN / MAXA / MINA(v1, ...) | Empty set → 0 |
| MAXIFS / MINIFS(range, r1, c1, ...) | No match → 0 |
| MEDIAN(v1, ...) | Midpoint interpolation |
| MODE(v1, ...) | No repeat → #N/A |
| LARGE / SMALL(data, n) | n out of range → #NUM! |
| RANK(x, data, [ascending=FALSE]) | Ties share top rank; absent → #N/A |
| PERCENTILE(data, p) | Inclusive, linear interpolation; p ∉ [0,1] → #NUM! |
| QUARTILE(data, q) | = PERCENTILE(data, q/4) |
| STDEV / VAR(v1, ...) | Sample (n−1); < 2 points → #DIV/0! |
| STDEVP / VARP(v1, ...) | Population |

## Logical (13)

| Function | Notes |
|---|---|
| IF(cond, then, [else=FALSE]) | Lazy: only the taken branch evaluates |
| IFS(c1, v1, [c2, v2, ...]) | First true wins; none → #N/A; lazy |
| IFERROR(value, [fallback]) | One-arg form returns blank; catches thrown evaluation errors too |
| IFNA(value, fallback) | Catches only #N/A |
| AND / OR / XOR(v1, ...) | Ranges skip text/blank; no logical values at all → #VALUE! |
| NOT(x) | |
| TRUE(), FALSE() | |
| SWITCH(subject, case1, val1, ..., [default]) | Case-insensitive equality; lazy |

## Text (26)

| Function | Notes |
|---|---|
| CONCATENATE / CONCAT(v1, ...) | Ranges flattened row-major |
| TEXTJOIN(delim, ignore_empty, v1, ...) | |
| LEFT / RIGHT(text, [n=1]) | n < 0 → #VALUE! |
| MID(text, start, length) | 1-based; start past end → "" |
| LEN(text) | Character (grapheme) count |
| FIND(needle, text, [start=1]) | Case-sensitive, no wildcards; miss → #VALUE! |
| SEARCH(pattern, text, [start=1]) | Case-insensitive, wildcards `* ? ~` |
| SUBSTITUTE(text, find, replace, [occurrence]) | All occurrences unless nth given |
| REPLACE(text, position, length, new) | |
| UPPER / LOWER / PROPER(text) | |
| TRIM(text) | Strips AND collapses internal space runs |
| CLEAN(text) | Removes control characters |
| REPT(text, n) | Result capped at 32,767 chars |
| EXACT(a, b) | The case-sensitive comparison |
| TEXT(value, format_code) | Full number-format renderer |
| VALUE(text) | Numbers, %, $, dates, times → number |
| CHAR(n), CODE(text) | Unicode scalars |
| T(value) | Text passes through, else "" |
| REGEXMATCH / REGEXEXTRACT / REGEXREPLACE(text, pattern, [replacement]) | ICU regex (NSRegularExpression), not RE2; EXTRACT returns first capture group if present, miss → #N/A; REPLACE supports $1 templates |

## Date & time (24)

| Function | Notes |
|---|---|
| DATE(y, m, d) | Overflow normalizes; years < 1900 get +1900 |
| TIME(h, m, s) | Wraps mod 24h |
| DATEVALUE / TIMEVALUE(text) | en-US formats + ISO |
| TODAY(), NOW() | Volatile |
| YEAR / MONTH / DAY / HOUR / MINUTE / SECOND(serial) | Accept date strings |
| WEEKDAY(serial, [type=1]) | 1: Sun=1..7, 2: Mon=1..7, 3: Mon=0..6 |
| WEEKNUM(serial, [type=1]) | Types 1, 2, 11–17, 21 (ISO) |
| ISOWEEKNUM(serial) | |
| EDATE(serial, months) | Day clamped to month end |
| EOMONTH(serial, months) | |
| DATEDIF(start, end, unit) | Y, M, D, MD, YM, YD; start > end → #NUM! |
| DAYS(end, start) | |
| NETWORKDAYS(start, end, [holidays]) | Mon–Fri inclusive |
| WORKDAY(start, days, [holidays]) | Exclusive of start |
| YEARFRAC(start, end, [basis=0]) | 0: 30/360 US, 1: act/act, 2: act/360, 3: act/365, 4: 30E/360 |

## Lookup & reference (13)

| Function | Notes |
|---|---|
| VLOOKUP(key, range, index, [sorted=TRUE]) | Sorted default = largest ≤ key; FALSE = exact with wildcards |
| HLOOKUP(key, range, index, [sorted=TRUE]) | Row-wise mirror |
| XLOOKUP(key, lookup, result, [missing], [match=0], [search=1]) | Match 0/1/−1/2; search ±1/±2 (−: last match wins) |
| MATCH(key, range, [type=1]) | 1-D only; 1/0/−1 |
| INDEX(range, row, [col]) | 1-based; out of bounds → #REF!; 1-D single-arg convenience |
| LOOKUP(key, lookup, [result]) | Largest ≤ key |
| CHOOSE(n, v1, ...) | Lazy; out of range → #NUM! |
| ADDRESS(row, col, [mode=1], [a1=TRUE], [sheet]) | Modes 1–4 |
| ROW([ref]), COLUMN([ref]) | No-arg form = own cell |
| ROWS(range), COLUMNS(range) | |

## Info (14)

ISBLANK, ISNUMBER, ISTEXT, ISNONTEXT, ISLOGICAL, ISERROR, ISERR (non-#N/A),
ISNA, ISEVEN, ISODD, N, NA(), TYPE (1/2/4/16), ERROR.TYPE (1–8; non-error →
#N/A). The IS* family inspects errors without propagating them — including
errors thrown mid-evaluation (`ISERROR(1/0)` → TRUE).

## Financial (10)

| Function | Notes |
|---|---|
| PMT(rate, nper, pv, [fv=0], [type=0]) | Sign convention: money out < 0 |
| IPMT / PPMT(rate, period, nper, pv, [fv], [type]) | IPMT + PPMT = PMT |
| FV / PV(rate, nper, pmt, [pv/fv], [type]) | |
| NPER(rate, pmt, pv, [fv], [type]) | |
| RATE(nper, pmt, pv, [fv], [type], [guess=0.1]) | Iterative; #NUM! on non-convergence |
| NPV(rate, cf1, ...) | First cashflow discounted one period |
| IRR(cashflows, [guess=0.1]) | Needs ≥1 positive and ≥1 negative flow |
| XIRR(cashflows, dates, [guess=0.1]) | Actual/365 exponents |

## Known deviations from Google Sheets

- No array results / spilling: functions that would return ranges into the
  grid (SPLIT, FILTER, UNIQUE, TRANSPOSE, ARRAYFORMULA) are absent; INDEX
  with row/col 0 errors instead of returning a slice.
- INDIRECT and OFFSET are not implemented (dynamic references defeat static
  dependency analysis; see roadmap).
- REGEX* use ICU syntax rather than RE2 (superset for common patterns).
- LEN counts grapheme clusters, not UTF-16 code units.
- Circular references display #CYCLE! rather than #REF!-with-message.
- Locale is fixed to en-US for input parsing and function argument text.
