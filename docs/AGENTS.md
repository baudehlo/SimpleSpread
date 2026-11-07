# AI agents (MCP)

SimpleSpread can let an AI agent — Claude Code, Claude Desktop, Cursor, or
any other [Model Context Protocol](https://modelcontextprotocol.io) client —
read and edit the spreadsheets open in its windows. The edits happen in the
live document: you watch values, formulas and formatting change as the agent
works, and every change can be undone with ⌘Z.

## Turning it on

1. SimpleSpread ▸ Settings… (⌘,) ▸ **Agents**.
2. Switch on **Allow AI agents to read and edit open spreadsheets**. The
   status line shows `Listening at http://127.0.0.1:52700/mcp`.
3. Copy the setup for your agent:
   - **Claude Code**: copy the command and run it in Terminal:

     ```sh
     claude mcp add --transport http simplespread http://127.0.0.1:52700/mcp \
       --header "Authorization: Bearer <token>"
     ```

   - **Other clients**: copy the `mcpServers` JSON into the client's MCP
     configuration (it uses the HTTP transport with an `Authorization`
     header).
4. Open a spreadsheet and ask the agent to work on it: "add a Doohickeys
   row to the items table and bold the grand total".

The setting is remembered; the server starts with the app while it's on.

## What an agent can do

| Tool | What it does |
| --- | --- |
| `list_documents` | Open documents (front-most first): id, name, path, unsaved changes, sheets with their used ranges, charts and pivot tables, the sheet showing, the selection |
| `read_range` | A range's values, formulas and (optionally) formatted text as JSON, or its values as CSV; default the used range |
| `write_cells` | Write a block of cells. Text is read as typed: `=SUM(B2:B9)`, `12%`, `$4.50`, `1/15/2026`; `'00123` stays text; `null` leaves a cell alone |
| `clear_range` | Clear values and formulas, keeping formatting |
| `format_range` | Bold/italic/underline/strikethrough, number format (preset or code), font, size, text and fill colour, alignment, wrap |
| `insert_rows`, `delete_rows`, `insert_columns`, `delete_columns` | Structural edits; formulas adjust as for the user's own |
| `set_column_width` | Column widths in points |
| `add_sheet`, `rename_sheet`, `delete_sheet` | Sheets; renames update formulas |
| `list_charts` | A sheet's charts: type, title, legend, data range, each series' cells and colour, position and size |
| `insert_chart` | A column, bar, line, area, pie, doughnut or scatter chart of a block of cells, made as Insert ▸ Chart makes it, with title, legend, axis titles, colours, place and size |
| `update_chart`, `delete_chart` | Change any of those (or the data range), move, resize or delete a chart |
| `list_pivot_tables` | Pivot tables: source, the fields on rows, columns, filters and values, each field's items, layout |
| `create_pivot_table` | A pivot table over a table of data, with its fields set up, on a new sheet or at a cell |
| `update_pivot_table` | Fields, summaries (sum, average, count, …), show values as a percentage, which items show, layout, grand totals |
| `group_pivot_field` | Group dates by years, quarters, months or days, or numbers into ranges; or ungroup |
| `refresh_pivot_tables`, `delete_pivot_table` | Recompute pivot tables after their data changes; delete one and clear its cells |
| `select_range` | Select and scroll to cells, to show you something |
| `screenshot` | A picture of the document's window as you see it (cells, formatting, charts), optionally after scrolling to a range |
| `save_document` | Save to the document's own .xlsx file, when that loses nothing |
| `close_document` | Close a document's window, when it has no unsaved changes |

Ranges are A1 style: `B2`, `A1:D20`, `A:C`, `3:5`, `Sheet2!A1:B4`,
`'My Sheet'!A1`, or `selection` for the cells you've selected ("format the
selection as currency" works). Tools act on the front-most window's
document unless the agent names one.

Behaviour worth knowing:

- **One undo step per tool call**, shown as "Undo Agent Edit", "Undo Agent
  Format", … in the Edit menu.
- **Edits show the sheet they change**: if the agent writes to another sheet,
  the window switches to it. Edits don't move your selection
  (`select_range` does).
- **Same protections as your edits**: cells inside a pivot table can't be
  written, and rows or columns can't be inserted through one. The agent gets
  the reason as an error; no alert appears in your window.
- **Nothing is overwritten unasked.** An edit that would replace cells in the
  way (a pivot table growing over data, say) fails unless the agent passes
  `replace: true`; agents are told to check with you first. You're never
  shown a question an agent caused.
- **Pivot tables don't follow their data by themselves**, as in Excel: after
  changing the source, the agent calls `refresh_pivot_tables`. Pivot tables
  from Excel with features SimpleSpread keeps but can't recompute are listed
  as not editable.
- **At most 10,000 cells** are read or written per call (100,000 when
  reading CSV). A bigger range (whole columns, say) is cut down to the part
  of the sheet in use.
- **Dates read as dates.** `read_range` gives dates and times as
  `2026-01-15`, `2026-01-15 13:30:00` or `13:30:00` (not serial numbers),
  in JSON and CSV alike, and `write_cells` reads those back as dates.
- **Screenshots** are drawn by SimpleSpread itself, so they need no
  screen-recording permission, and are at most 1568 pixels on the long
  side. Taking one with a `range` moves your view there.
- **Saving is limited to what loses nothing.** `save_document` writes over
  the document's own .xlsx file. It refuses a document that has never been
  saved, or came from a CSV or Excel 97–2003 file (you choose where with
  File ▸ Save As…), and a file holding content SimpleSpread can't write
  back (you decide between saving a copy and saving anyway). Undo still
  works after an agent saves, but the file on disk has the changes.
- **Closing never discards work.** `close_document` must name the document,
  and refuses one with unsaved changes, one still saving, or while you are
  typing in a cell. Closing the last window quits SimpleSpread, which ends
  the agent's connection.
- **Opening is outside the server.** The sandbox only lets SimpleSpread
  open files you hand it, so there is no open tool. An agent with a shell
  (Claude Code) can run `open -a SimpleSpread path/to/file.xlsx`, the same
  request a Finder double-click makes, then wait for the file in
  `list_documents`. With more than one copy of SimpleSpread installed,
  macOS picks which one opens it.

## Security

- **Off by default.** Nothing listens until you switch it on.
- **This Mac only.** The server listens on 127.0.0.1; other machines can't
  reach it.
- **Token required.** Every request must carry the bearer token from
  Settings. **Reset Token** issues a new one and disconnects every agent set
  up with the old one.
- **No web pages.** Requests whose `Host` or `Origin` header names anything
  but this machine are refused, so a website can't reach the server by DNS
  rebinding.

Anything that holds the token can read and change your open spreadsheets,
so give it only to agents you trust.

## Troubleshooting

- **"Port 52700 is in use by another app"**: pick another port in
  Settings ▸ Agents, then copy the setup again (the URL includes the port).
- **401 / "Missing or wrong token"**: the agent's configuration has an old
  token. Copy the setup again.
- **"No spreadsheets are open in SimpleSpread"**: open a document first;
  agents only see documents in open windows.

## For developers

- `Sources/SpreadsheetUI/Mac/MCPHTTPServer.swift`: the Streamable HTTP
  transport (Network.framework, POST only, one JSON reply per request,
  `Connection: close`; GET answers 405, which the spec allows for servers
  without event streams).
- `MCPProtocol.swift`: `JSONValue` and the JSON-RPC dispatch (`initialize`,
  `ping`, `tools/list`, `tools/call`; protocol revisions 2024-11-05 to
  2025-11-25).
- `MCPTools.swift`: the tools, calling `SpreadsheetDocument` on the main
  actor; `MCPTools+ChartsAndPivots.swift`: the chart and pivot table tools,
  over the same commands as the Chart panel and PivotTable Fields panel.
- `Mac/AgentAccess.swift`: Settings ▸ Agents and the server's lifecycle.
- Tests: `Tests/SpreadsheetUITests/MCPServerTests.swift`, including a request
  over a live socket.

Try it without an agent:

```sh
curl -s http://127.0.0.1:52700/mcp -H "Authorization: Bearer <token>" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_documents","arguments":{}}}'
```
