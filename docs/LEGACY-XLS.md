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

On opening, the app explains the import limitations and lists any detected
content it cannot preserve. Charts, images, macros, pivot tables, external links,
rich text run formatting, conditional formatting, data validation, print settings,
and other advanced features are outside the supported import scope. Macros and
external links are not executed. Keep the original file to view this content in
an application with full support for legacy Excel files.

Encrypted workbooks, pre-BIFF8 formats, files without worksheets, and malformed
containers or records produce errors. To bound resource use for abnormal input,
the importer accepts files up to 256 MiB and up to 1,000,000 cell records. Inputs
that exceed these limits are rejected rather than silently truncated.

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
They also compare values and formatting through import, editing, XLSX export,
and reopening. Fixture provenance and a reproducible generator are available in
[`Tests/SpreadsheetFilesTests/Fixtures/LegacyXLS`](../Tests/SpreadsheetFilesTests/Fixtures/LegacyXLS).

```sh
swift test --filter 'XLSTests|XLSRecordTests|XLSImportTests|XLSFileOpenTests|CompoundFileReaderTests'
```
