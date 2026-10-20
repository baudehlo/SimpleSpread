# Excel 97–2003 (XLS) Import

SimpleSpread opens BIFF8 `.xls` files and saves edited workbooks as `.xlsx`.
The original `.xls` file remains unchanged; writing `.xls` files is not supported.

The Mac open panel and Finder file association both accept `.xls` files. On iPad,
the importer creates a separate XLSX copy before handing it to the document
system, so autosave cannot overwrite the source file.

## Supported Content

- Numbers, text, booleans, errors, blank cells, and multiple worksheets.
- Chinese text, Unicode, shared strings, and long text spanning CONTINUE records.
- Merged ranges, fonts, font sizes, bold, italic, underline, strikethrough, font
  colors, solid fills, borders on all four sides, basic alignment, text wrapping,
  indentation, and number formats.
- Row heights, column widths, row and column styles, hidden rows, columns and
  worksheets, and frozen panes.
- Date formats and normalization of the 1904 date system.
- Cached formula results. Formula expressions are not restored or recalculated
  after import. Cells may be empty if the application that created the file did
  not write cached results.

On opening, a notice says the workbook was opened as an XLSX copy and names
what it couldn't bring over, as the XLSX importer does: formulas (kept as their
last values), charts, images, comments, hyperlinks, conditional formatting, data
validation, macros, links to other workbooks, pivot tables, protection, print
headers and footers, rich text runs, grouped rows or columns, and formatting the
app can't show (rotated text, pattern fills, diagonal borders). Macros and
external links are never run. Keep the original file to see this content in an
application with full support for legacy Excel files.

Records the importer doesn't use are skipped, as Excel's own readers do, and the
compound-file container is read as leniently as other readers read it (files cut
short inside their last sector, FAT sectors not marked as such, case-insensitive
stream names). Encrypted workbooks, pre-BIFF8 formats, files without worksheets,
and damage to what is imported (cells, strings, styles, sector chains) produce
errors. Files over 256 MiB are rejected.

## Implementation and Validation

No new runtime dependencies are required:

```text
CFB container (FAT / DIFAT / miniFAT)
  → BIFF8 records, shared strings, and styles
  → existing Workbook model
  → existing XLSXWriter
```

Format references:

- [Microsoft MS-CFB](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-cfb/53989ce4-7b05-4f8d-829b-d08d6148375b)
- [Microsoft MS-XLS: BOF](https://learn.microsoft.com/en-us/openspecs/office_file_formats/ms-xls/4d6a3d1e-d7c5-405f-bbae-d01e9cb79366)
- [Microsoft MS-XLS: CellXF](https://learn.microsoft.com/en-us/openspecs/office_file_formats/ms-xls/671c8577-901f-4215-9ebf-6f5890e5896d)
- [Microsoft MS-XLS: FontIndex](https://learn.microsoft.com/en-us/openspecs/office_file_formats/ms-xls/b3413c2b-ca5b-4988-86be-ab44bfe9e4d3)

Tests cover malformed containers, mini-streams, external DIFAT sectors, string
boundaries, and synthetic business-report fixtures from an independent writer.
The importer was also checked against the 321 `.xls` files in Apache POI's test
data: it opens 312 (the rest are encrypted, pre-BIFF8 or damaged), and every
sheet's values match xlrd's except where 1904 dates are normalized.
They also compare values and formatting through import, editing, XLSX export,
and reopening. Fixture provenance and a reproducible generator are available in
[`Tests/SpreadsheetFilesTests/Fixtures/LegacyXLS`](../Tests/SpreadsheetFilesTests/Fixtures/LegacyXLS).

```sh
swift test --filter 'XLSTests|XLSRecordTests|XLSImportTests|XLSFileOpenTests|CompoundFileReaderTests'
```
