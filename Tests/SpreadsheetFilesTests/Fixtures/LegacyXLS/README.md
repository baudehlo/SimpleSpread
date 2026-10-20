# 旧版 XLS 回归样本

这里的工作簿由 `generate.py` 使用 [xlwt 1.3.0](https://github.com/python-excel/xlwt)
独立生成，并用 [xlrd 2.0.2](https://github.com/python-excel/xlrd) 回读核验。
样本全部为合成数据，没有用户文件；应用和 Swift 测试运行时不依赖 Python。

- `business-export.xls`：三个工作表、中英文及 emoji、跨 SST/CONTINUE 的长文本、
  合并表头、字体、调色板、边框、对齐、行高、列宽、隐藏项、冻结窗格、日期、
  数字和布尔值。含一个 `1+2` 公式；xlwt 不计算公式，缓存为空，因此导入后
  该单元格为空，并必须提示公式仅按缓存值导入。
- `dates-1904.xls`：1904 日期系统，日期序列号 44850 应归一为 46312；
  普通数值 42.5 不应发生偏移。
- `layout-and-tab-order.xls`：工作表标签顺序与物理子流顺序相反；默认调色板、
  默认行高和行列样式、未冻结的分割窗格，以及压缩 Unicode 的 U+0080 字符。
- `formula-caches.xls`：在 xlwt 生成的公式记录中显式填写数值、布尔、错误、
  空字符串和 Unicode 字符串缓存，再用 xlrd 验证；测试导入后不触发重新计算。

重新生成时，在隔离虚拟环境安装上述固定版本，然后运行 `generate.py`。
脚本末尾使用独立读取器断言关键值和格式，Swift 的 `XLSTests` 进一步验证
导入、编辑、写出 XLSX 和重新打开。
