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
