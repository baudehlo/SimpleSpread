# Excel oracle files

`created-pivots-refreshed-by-excel.xlsx` is `PivotOracleWorkbook.make()` (13 pivot
tables built by SimpleSpread over seeded random data) after a round trip through
real Excel: uploaded to Excel for the web on 2026-10-11, refreshed there with
Data ▸ Refresh All, and downloaded with File ▸ Create a Copy ▸ Download a Copy.
`PivotOracleComparisonTests` compares SimpleSpread's own layout of the same
pivots with Excel's, cell by cell.

If `PivotOracleWorkbook` changes, regenerate this file the same way: write the
workbook with `SIMPLESPREAD_PIVOT_ORACLE_OUT=<file> swift test --filter
PivotOracleWorkbookTests`, then repeat the Excel steps.

`round2-refreshed-by-excel.xlsx` is the same for `PivotOracleRound2.make()` (19
pivots: column-only and value-only layouts, show values as difference / % of /
% difference / running total, custom subtotals, blank rows, items with no data,
wrapped report filters, Values on rows, summaries over errors and blanks),
written with `SIMPLESPREAD_PIVOT_ORACLE2_OUT=<file> swift test --filter
PivotOracleRound2Tests`.

`round3-refreshed-by-excel.xlsx` is the same for `PivotOracleRound3.make()` (6
pivots grouped in SimpleSpread: dates by years / quarters / months and by days,
whole numbers and fractions into ranges), written with
`SIMPLESPREAD_PIVOT_ORACLE3_OUT=<file> swift test --filter PivotOracleRound3Tests`.

`charts-by-excel.xlsx` holds charts as Excel writes them, for
`ChartReadingTests`. It started as four openpyxl charts (column, line, pie,
stacked bar) over a small sales table; on 2026-10-15 it was uploaded to
Excel for the web, twelve more were added there from Insert (clustered
column, line, pie, clustered bar, scatter, column + line combo, 100% stacked
column, line with markers, doughnut, stacked area, waterfall, radar; all
dropped at the same spot), and it was downloaded with File ▸ Create a Copy ▸
Download a Copy.
