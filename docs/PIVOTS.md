# Pivot tables

A pivot table summarizes a table of data: totals by region, counts by
month, averages by product, and so on. SimpleSpread's pivot tables work
like Excel's and are saved in the same format, so a pivot made in either
app opens and works in the other.

## Your data

Pivot tables read a range with a heading in the first row and one record
per row below it, for example:

| Region | Product | Date | Units | Price |
|---|---|---|---|---|
| East | Apples | 3/2/2025 | 12 | 2.50 |
| West | Pears | 3/4/2025 | 7 | 3.10 |

Every column needs a heading. Blank cells are fine.

## Creating a pivot table

1. Click anywhere in your data, or select the exact range you want.
2. Choose **Insert ▸ PivotTable…**.
3. Check the **Data range** (SimpleSpread fills in the data around the
   active cell) and choose where to put the pivot table: **A new sheet**, or
   **This sheet** at a cell you name.
4. Click **Create**.

The pivot table starts empty and the **PivotTable Fields** panel opens
beside the grid.

## The PivotTable Fields panel

The panel shows whenever the active cell is inside a pivot table. Hide or
show it with **Data ▸ Hide PivotTable Fields** / **Show PivotTable Fields**,
or the button at its top right.

At the top is a list of your data's columns, called **fields**. Check a
field to add it: fields of numbers go to **Values** and are summed, and
other fields go to **Rows**. Uncheck a field to remove it.

Below the list are four areas. Drag fields into them, between them, or up
and down within one:

- **Rows**: one row in the pivot table for each item (each region, say).
  Put several fields here to nest them: products within regions.
- **Columns**: one column for each item.
- **Values**: what to summarize, such as the sum of Units.
- **Filters**: a drop-down above the pivot table that shows one item, or
  all of them.

Once there are two or more fields in Values, a **Σ Values** entry appears in
Columns. Move it to Rows to list the values down the side instead of across.

Every change redraws the pivot table and can be undone with **⌘Z**.

### Field menus

Click the arrow on a field in one of the areas (or right-click it) for more
options.

**Fields in Values:**

- **Summarize Values By**: Sum, Count, Average, Max, Min, Product, Count
  Numbers, StdDev, StdDevp, Var, Varp.
- **Show Values As**: No Calculation (the plain summary), % of Grand Total, % of Column Total, % of Row Total,
  Index, Difference From, % Of, % Difference From, Running Total In. For
  the last four, pick the field and the item to compare against. That item
  can be a specific one, or **(previous)** or **(next)**.
- **Rename…**: the heading shown in the pivot table, such as "Total units"
  instead of "Sum of Units".

**Fields in Rows, Columns and Filters:**

- **Filter Items…**: choose which items to show.
- **Sort**: Ascending, Descending, or Manual (keep the current order).
- **Group**: see below.
- **Show Items With No Data**: list every item even where a combination
  has no records.
- **Blank Line After Each Item** (Rows only).
- **Show Subtotals** (Rows and Columns).

Every field menu also has **Move Up**, **Move Down**, **Move To** and
**Remove**.

### Layout

At the bottom of the panel:

- **Layout**: **Compact** puts all row fields in one indented column,
  **Outline** gives each row field its own column, and **Tabular** does the
  same with subtotals below each group rather than above.
- **Grand totals for rows** and **Grand totals for columns**.

## Grouping

Grouping turns many items into a few.

- **Dates**: on a date field's menu choose **Group**, then Years,
  Quarters, Months, Days, or a combination such as Years, Quarters and
  Months. Each coarser level becomes its own field (Years, Quarters) placed
  before the date field.
- **Numbers**: choose **Group into Ranges…** and set where the ranges start
  and end and how wide each one is (for example 0 to 100 by 10, giving
  0-9, 10-19 and so on). Values outside the range are gathered into a
  group at each end, such as "<0".
- **Ungroup** removes the grouping, including any Years or Quarters fields
  it added.

Grouping applies to every pivot table that reads the same data.

## Refreshing

A pivot table keeps a snapshot of its data. After you change the source,
choose **Data ▸ Refresh** (**⌥F5**) with the active cell in the pivot table,
or **Data ▸ Refresh All** (**⌃⌥F5**) for every pivot table in the workbook.
New items are added in sorted order, and your filters, sorting and grouping
are kept.

## Working around a pivot table

- You can't type into a pivot table, paste into it or clear part of it.
  Use the panel instead.
- You can't insert or delete rows or columns that cut through a pivot
  table. Inserting above or to the left of one moves it.
- If a pivot table needs to grow over cells that already hold data,
  SimpleSpread asks before replacing them. It won't let one pivot table
  overlap another.
- To delete a pivot table, select all of it and press Delete, or delete its
  sheet.
- `GETPIVOTDATA` reads a value from a pivot table in a formula. See
  [FUNCTIONS.md](FUNCTIONS.md).

## Pivot tables from Excel

Pivot tables in Excel files open, recompute, refresh and save. A few Excel
features can't be recalculated in SimpleSpread:

- data from OLAP cubes or the Data Model
- calculated items
- label and value filters (such as "begins with" or "greater than")
- the newer Show Values As options, such as Rank and % of Parent
- totals that include filtered-out items

A pivot table that uses any of these still shows its values and is saved
back unchanged, so it keeps working in Excel. The panel explains why it
can't be edited. Slicers and timelines aren't supported.
