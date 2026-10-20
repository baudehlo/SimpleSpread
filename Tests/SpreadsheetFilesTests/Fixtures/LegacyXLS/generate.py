"""Generate synthetic BIFF8 regression fixtures; xlwt/xlrd are needed only to regenerate them.

python3 -m venv /tmp/simplespread-xls-fixtures
/tmp/simplespread-xls-fixtures/bin/pip install xlwt==1.3.0 xlrd==2.0.2
/tmp/simplespread-xls-fixtures/bin/python generate.py
"""
from datetime import datetime
from pathlib import Path
import struct

import xlrd
import xlwt
from xlwt.CompoundDoc import XlsDoc

OUTPUT = Path(__file__).parent


def business_export():
    book = xlwt.Workbook(encoding="utf-8")
    book.set_colour_RGB(0x21, 36, 88, 132)
    sheet = book.add_sheet("业务报表")
    header = xlwt.easyxf(
        "font: name Arial, height 280, bold on, colour white;"
        "pattern: pattern solid, fore_colour 33;"
        "alignment: horiz center, vert center, wrap on;"
        "borders: left thin, right thin, top thin, bottom double;"
    )
    border = xlwt.easyxf("borders: left thin, right thin, top thin, bottom thin;")
    date = xlwt.easyxf(num_format_str="yyyy-mm-dd")
    money = xlwt.easyxf(num_format_str="#,##0.00")
    percent = xlwt.easyxf(num_format_str="0.00%")
    sheet.write_merge(0, 1, 0, 3, "年度业务汇总", header)
    sheet.row(0).height = 600
    sheet.row(1).height = 420
    sheet.col(0).width = 20 * 256
    sheet.col(1).width = 12 * 256
    sheet.col(2).width = 16 * 256
    sheet.col(3).width = 14 * 256
    for column, label in enumerate(["项目", "金额", "日期", "完成率"]):
        sheet.write(2, column, label, border)
    sheet.write(3, 0, "华东")
    sheet.write(3, 1, 1234.5, money)
    sheet.write(3, 2, datetime(2026, 10, 17), date)
    sheet.write(3, 3, 0.125, percent)
    sheet.write(4, 0, "华南")
    sheet.write(4, 1, -42.25, money)
    sheet.write(4, 2, True)
    sheet.write(4, 3, False)
    sheet.write(5, 0, "00123")
    sheet.write(5, 1, 1.23456789)
    sheet.write(5, 2, "")
    sheet.write(5, 3, "café")
    sheet.row(6).hidden = True
    sheet.col(4).hidden = True
    sheet.panes_frozen = True
    sheet.horz_split_pos = 3
    sheet.vert_split_pos = 1
    detail = book.add_sheet("明细")
    detail.write(0, 0, "重复文本")
    detail.write(1, 0, "重复文本")
    detail.write(2, 0, "长文本" * 4000)
    detail.write(3, 0, "ASCII-" * 2000)
    detail.write(4, 0, "emoji 😀")
    detail.write(5, 0, xlwt.Formula("1+2"))
    hidden = book.add_sheet("隐藏")
    hidden.visibility = 1
    hidden.write(0, 0, "保留隐藏工作表")
    path = OUTPUT / "business-export.xls"
    book.save(str(path))

    check = xlrd.open_workbook(path, formatting_info=True)
    first = check.sheet_by_index(0)
    assert check.sheet_names() == ["业务报表", "明细", "隐藏"]
    assert first.merged_cells == [(0, 2, 0, 4)]
    assert first.cell_value(3, 1) == 1234.5
    assert first.cell_value(3, 2) == 46312
    assert first.rowinfo_map[0].height == 600
    assert first.colinfo_map[0].width == 5120
    assert check.sheet_by_index(1).cell_value(2, 0) == "长文本" * 4000
    assert check.sheet_by_index(1).cell_value(4, 0) == "emoji 😀"
    assert check.sheet_by_index(2).visibility == 1
    style = check.xf_list[first.cell_xf_index(0, 0)]
    assert check.colour_map[style.background.pattern_colour_index] == (36, 88, 132)
    assert style.border.bottom_line_style == 6


def dates_1904():
    book = xlwt.Workbook()
    book.dates_1904 = True
    sheet = book.add_sheet("Dates")
    sheet.write(0, 0, datetime(2026, 10, 17), xlwt.easyxf(num_format_str="yyyy-mm-dd"))
    sheet.write(1, 0, 42.5)
    path = OUTPUT / "dates-1904.xls"
    book.save(str(path))
    check = xlrd.open_workbook(path)
    assert check.datemode == 1
    assert check.sheet_by_index(0).cell_value(0, 0) == 44850


def layout_and_tab_order():
    book = xlwt.Workbook()
    first = book.add_sheet("PhysicalFirst")
    first.row_default_height = 400
    first.col(1).set_style(xlwt.easyxf(num_format_str="0.00%"))
    first.row(2).set_style(xlwt.easyxf("font: bold on;"))
    first.write(0, 0, "red", xlwt.easyxf("font: colour red;"))
    first.write(1, 0, "white", xlwt.easyxf("pattern: pattern solid, fore_colour white;"))
    first.write(3, 0, "control \u0080")
    first.write(4, 0, "plain")
    first.panes_frozen = False
    first.horz_split_pos = 12
    first.vert_split_pos = 20
    second = book.add_sheet("PhysicalSecond")
    second.write(0, 0, "Second")
    stream = book.get_biff_data()
    records = []
    position = 0
    while position < len(stream):
        record, length = struct.unpack_from("<HH", stream, position)
        records.append((record, stream[position:position + 4 + length]))
        position += 4 + length
        if record == 0x000A:
            break
    indexes = [index for index, (kind, _) in enumerate(records) if kind == 0x0085]
    assert len(indexes) == 2
    # Change only tab order; physical substream positions and BOUNDSHEET pointers stay unchanged.
    records[indexes[0]], records[indexes[1]] = records[indexes[1]], records[indexes[0]]
    reordered = b"".join(payload for _, payload in records) + stream[position:]
    path = OUTPUT / "layout-and-tab-order.xls"
    XlsDoc().save(str(path), reordered)
    check = xlrd.open_workbook(path, formatting_info=True)
    assert check.sheet_names() == ["PhysicalSecond", "PhysicalFirst"]
    first = check.sheet_by_index(1)
    assert first.cell_value(3, 0) == "control \u0080"
    assert first.default_row_height == 400
    assert check.xf_list[first.colinfo_map[1].xf_index].format_key == 10
    assert not first.panes_are_frozen


def formula_caches():
    book = xlwt.Workbook()
    sheet = book.add_sheet("Cached")
    for row, formula in enumerate(["1+2", "1=1", "1/0", '""', '"缓存结果"']):
        sheet.write(row, 0, xlwt.Formula(formula))
    stream = book.get_biff_data()
    output = bytearray()
    position = 0
    while position < len(stream):
        kind, length = struct.unpack_from("<HH", stream, position)
        payload = bytearray(stream[position + 4:position + 4 + length])
        position += length + 4
        trailing = b""
        if kind == 0x0006:
            row = struct.unpack_from("<H", payload)[0]
            if row == 0:
                payload[6:14] = struct.pack("<d", 3)
            else:
                value_type, value = {1: (1, 1), 2: (2, 0x07), 3: (3, 0), 4: (0, 0)}[row]
                payload[6:14] = bytes([value_type, 0, value, 0, 0, 0, 255, 255])
            if row == 4:
                text = "缓存结果".encode("utf-16-le")
                string = struct.pack("<HB", len(text) // 2, 1) + text
                trailing = struct.pack("<HH", 0x0207, len(string)) + string
        output.extend(struct.pack("<HH", kind, len(payload)) + payload + trailing)
    path = OUTPUT / "formula-caches.xls"
    # xlwt does not evaluate formulas; populate each cache type and verify it independently with xlrd.
    XlsDoc().save(str(path), bytes(output))
    check = xlrd.open_workbook(path).sheet_by_index(0)
    assert check.cell_value(0, 0) == 3
    assert check.cell_value(1, 0) == 1 and check.cell_type(1, 0) == xlrd.XL_CELL_BOOLEAN
    assert check.cell_value(2, 0) == 7 and check.cell_type(2, 0) == xlrd.XL_CELL_ERROR
    assert check.cell_value(3, 0) == ""
    assert check.cell_value(4, 0) == "缓存结果"


business_export()
dates_1904()
layout_and_tab_order()
formula_caches()
print("Generated four BIFF8 fixtures and independently verified them with xlrd.")
