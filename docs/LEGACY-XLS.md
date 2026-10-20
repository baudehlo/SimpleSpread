# Excel 97–2003（XLS）导入

SimpleSpread 可以打开使用 BIFF8 的 `.xls` 文件，并将编辑后的内容保存为
`.xlsx`。原始 `.xls` 保持不变；不支持写出 `.xls`。

Mac 的“打开”面板和 Finder 文件关联均接受 `.xls`。iPad 先创建独立的
XLSX 副本，再交给文档系统处理，避免自动保存覆盖源文件。

## 支持范围

- 数字、文本、布尔值、错误值、空白单元格和多个工作表。
- 中文、Unicode、共享字符串及跨 CONTINUE 记录的长文本。
- 合并区域、字体、字号、粗斜体、下划线、删除线、字体颜色、纯色填充、
  四边边框、基本对齐、自动换行、缩进和数字格式。
- 行高、列宽、行列格式、隐藏行列和工作表、冻结窗格。
- 日期格式及 1904 日期系统的归一化。
- 公式的缓存结果。公式文本不会恢复，导入后不会按原公式重新计算；
  如果生成文件的软件没有写入缓存结果，该单元格可能为空。

打开时会显示有限导入说明，并列出识别出的未保留内容。图表、图片、宏、
数据透视表、外部链接、富文本片段样式、条件格式、数据验证、打印设置等
不属于本次导入保证范围；宏和外部链接不会执行。原始文件应保留，以便
在完整支持旧版 Excel 的软件中查看这些内容。

加密工作簿、BIFF8 之前的格式、缺少工作表的文件以及损坏的容器或记录会
返回错误。为了限制异常输入的资源消耗，导入器最多接收 256 MiB 文件和
1,000,000 条单元格记录；超过限制会明确拒绝，不截断后宣称导入成功。

## 实现与验证

应用运行时没有新增依赖：

```text
CFB 容器（FAT / DIFAT / miniFAT）
  → BIFF8 记录、共享字符串、样式
  → 现有 Workbook 模型
  → 现有 XLSXWriter
```

格式依据：

- [Microsoft MS-CFB](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-cfb/53989ce4-7b05-4f8d-829b-d08d6148375b)
- [Microsoft MS-XLS：BOF](https://learn.microsoft.com/en-us/openspecs/office_file_formats/ms-xls/4d6a3d1e-d7c5-405f-bbae-d01e9cb79366)
- [Microsoft MS-XLS：CellXF](https://learn.microsoft.com/en-us/openspecs/office_file_formats/ms-xls/671c8577-901f-4215-9ebf-6f5890e5896d)
- [Microsoft MS-XLS：FontIndex](https://learn.microsoft.com/en-us/openspecs/office_file_formats/ms-xls/b3413c2b-ca5b-4988-86be-ab44bfe9e4d3)

测试包含损坏容器、mini-stream、外部 DIFAT、字符串边界、独立写入器生成的
业务表样本，以及“导入 → 修改 → 保存 XLSX → 重开”的值和格式比对。
样本来源和可重复生成脚本位于
[`Tests/SpreadsheetFilesTests/Fixtures/LegacyXLS`](../Tests/SpreadsheetFilesTests/Fixtures/LegacyXLS)。

```sh
swift test --filter 'XLSTests|XLSRecordTests|XLSImportTests|XLSFileOpenTests|CompoundFileReaderTests'
```
