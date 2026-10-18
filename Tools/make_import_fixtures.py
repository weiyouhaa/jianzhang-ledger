#!/usr/bin/env python3
"""生成导入解析器测试用的合成账单（格式与支付宝 / 微信真实导出一致，数据为虚构）。
用法：python3 Tools/make_import_fixtures.py Tests/Fixtures/import"""
import sys, os

out = sys.argv[1] if len(sys.argv) > 1 else "."
os.makedirs(out, exist_ok=True)

alipay_pre = """------------------------------------------------------------------------------------
导出信息：
姓名：测试用户
支付宝账户：138******00
起始时间：[2026-10-01 00:00:00]    终止时间：[2026-10-17 23:59:59]
导出交易类型：[全部]
导出时间：[2026-10-18 09:00:00]
共11笔记录
收入：1笔 500.00元
支出：7笔 866.40元
不计收支：3笔 3199.01元

特别提示：
1.本回单内容可表明支付宝受理了相应支付交易申请，因系统原因或通讯故障等偶发因素导致本回单与实际交易结果不符时，以实际交易情况为准；
2.请勿将本回单作为收款方发货的凭据使用，请查证账户实际到账情况后再进行发货操作；
3.支付宝快捷支付等非余额支付方式可能既产生支付宝交易也同步产生银行交易，因此请勿使用本回单进行重复记账；
4.本回单如经任何涂改、编造，均立即失去效力；
5.部分账单如：充值提现、账户转存或者个人设置收支等不计入为收入或者支出，记为不计收支类；
6.因统计逻辑不同，明细金额直接累加后，可能会和下方统计金额不一致，请以实际交易金额为准；
7.禁止将本回单用于非法用途；
8.本明细仅展示当前账单中的交易，不包括已删除的记录；
9.本明细仅供个人对账使用。

------------------------支付宝（中国）网络技术有限公司  电子客户回单------------------------
"""
alipay_rows = [
    "交易时间,交易分类,交易对方,对方账号,商品说明,收/支,金额,收/付款方式,交易状态,交易订单号,商家订单号,备注,",
    "2026-10-17 20:12:12,交通出行,华南畅行高速科技有限公司,hn***@etc.cn,高速通行费,支出,46.00,交通银行信用卡(7316),交易成功,2026101722001400000001\t,ETC20261017001\t,,",
    "2026-10-17 12:18:05,餐饮美食,星巴克,sb***@starbucks.cn,星巴克咖啡(国贸店),支出,35.00,花呗,交易成功,2026101722001400000002\t,SB000002\t,,",
    "2026-10-16 09:00:00,日用百货,盒马鲜生,hm***@freshhema.com,盒马订单,支出,286.40,招商银行信用卡(1024),交易成功,2026101622001400000003\t,HM000003\t,,",
    "2026-10-15 20:00:00,服饰装扮,优衣库官方旗舰店,uq***@uniqlo.cn,衬衫,支出,199.00,余额宝,退款成功,2026101522001400000004\t,UQ000004\t,,",
    "2026-10-15 21:00:00,退款,优衣库官方旗舰店,uq***@uniqlo.cn,退款-衬衫,不计收支,199.00,余额宝,退款成功,2026101522001400000004_R1\t,UQ000004\t,,",
    "2026-10-14 10:00:00,投资理财,余额宝,,余额宝-2026.10.13-收益发放,不计收支,0.01,余额宝,交易成功,2026101422001400000005\t,\t,,",
    "2026-10-13 08:00:00,转账红包,张三,zs***@qq.com,转账,收入,500.00,,交易成功,2026101322001400000006\t,\t,,",
    "2026-10-12 18:30:00,餐饮美食,美团,mt***@meituan.com,美团订单-外卖,支出,45.60,账户余额,交易关闭,2026101222001400000007\t,MT000007\t,,",
    "2026-10-11 09:00:00,信用借还,招商银行,,信用卡还款-招商银行(1024),不计收支,3000.00,招商银行储蓄卡(6688),还款成功,2026101122001400000008\t,\t,,",
    "2026-10-10 11:11:11,充值缴费,中国移动,cm***@10086.cn,话费充值,支出,50.00,账户余额,交易成功,2026101022001400000009\t,CM000009\t,,",
    "2026-10-09 15:00:00,文化休闲,猫眼电影,my***@maoyan.com,电影票,支出,69.90,花呗,交易成功,2026100922001400000010\t,MY000010\t,,",
]
alipay_text = alipay_pre + "\n".join(alipay_rows) + "\n"
with open(os.path.join(out, "alipay-gbk.csv"), "wb") as f:
    f.write(alipay_text.replace("\n", "\r\n").encode("gb18030"))
with open(os.path.join(out, "alipay-utf8.csv"), "w", encoding="utf-8") as f:
    f.write(alipay_text)

wechat_pre = [
    ["微信支付账单明细"], ["微信昵称：[测试]"], ["起始时间：[2026-10-01 00:00:00] 终止时间：[2026-10-17 23:59:59]"],
    ["导出类型：[全部]"], ["导出时间：[2026-10-18 09:00:00]"], [""], ["共9笔记录"], ["收入：1笔 88.00元"],
    ["支出：6笔 302.50元"], ["中性交易：2笔 3000.00元"], ["注："],
    ["1. 充值/提现/理财通购买/零钱通存取/信用卡还款等交易，将计入中性交易"],
    ["2. 本明细仅展示当前账单中的交易，不包括已删除的记录"], ["3. 本明细仅供个人对账使用"], [""],
    ["----------------------微信支付账单明细列表--------------------"],
]
wechat_header = ["交易时间", "交易类型", "交易对方", "商品", "收/支", "金额(元)", "支付方式", "当前状态", "交易单号", "商户单号", "备注"]
wechat_rows = [
    ["2026-10-17 15:25:00", "商户消费", "阿芳", "收款方备注:二维码收款", "支出", "¥18.00", "零钱", "支付成功", "4200000001202610170001 ", "10001 ", "/"],
    ["2026-10-17 20:12:00", "商户消费", "华南畅行高速科技有限公司", "高速通行费", "支出", "¥46.00", "交通银行信用卡(7316)", "支付成功", "4200000001202610170002 ", "10002 ", "/"],
    ["2026-10-16 12:00:00", "商户消费", "美团", "美团订单", "支出", "¥30.00", "零钱", "已退款(￥5.00)", "4200000001202610160003 ", "10003 ", "/"],
    ["2026-10-16 13:00:00", "美团-退款", "美团", "/", "收入", "¥5.00", "零钱", "已退款(￥5.00)", "5000000001202610160004 ", "10003 ", "/"],
    ["2026-10-15 09:00:00", "微信红包", "李四", "/", "收入", "¥88.00", "/", "已存入零钱", "1000039501202610150005 ", "/", "/"],
    ["2026-10-14 20:00:00", "零钱通", "/", "转入零钱通-来自零钱", "/", "¥1000.00", "零钱", "支付成功", "4200000001202610140006 ", "/", "/"],
    ["2026-10-13 10:00:00", "信用卡还款", "招商银行", "信用卡还款", "/", "¥2000.00", "招商银行储蓄卡(6688)", "支付成功", "4200000001202610130007 ", "/", "/"],
    ["2026-10-12 08:00:00", "扫二维码付款", "早餐店", "二维码付款", "支出", "¥8.50", "零钱", "支付失败", "4200000001202610120008 ", "/", "/"],
    ["2026-10-11 18:00:00", "转账", "王五", "/", "支出", "¥200.00", "零钱", "对方已收钱", "1000050001202610110009 ", "/", "/"],
]

import csv
with open(os.path.join(out, "wechat.csv"), "w", encoding="utf-8-sig", newline="") as f:
    w = csv.writer(f)
    for r in wechat_pre:
        w.writerow(r + [""] * (len(wechat_header) - 1))
    w.writerow(wechat_header)
    for r in wechat_rows:
        w.writerow(r)

try:
    import openpyxl
    wb = openpyxl.Workbook()
    ws = wb.active
    ws.title = "Sheet1"
    for r in wechat_pre:
        ws.append(r)
    ws.append(wechat_header)
    for r in wechat_rows:
        ws.append(r)
    wb.save(os.path.join(out, "wechat.xlsx"))
    print("wrote wechat.xlsx")
except ImportError:
    print("openpyxl not installed; skipped xlsx")
print("done")

# 手工构造一个使用 sharedStrings 的 xlsx（微信真实导出即为共享字符串表）
import zipfile
from xml.sax.saxutils import escape

all_rows = [r + [""] * 0 for r in wechat_pre] + [wechat_header] + wechat_rows
strings, index = [], {}
def sid(s):
    if s not in index:
        index[s] = len(strings); strings.append(s)
    return index[s]
def col(i):
    s = ""
    i += 1
    while i:
        i, r = divmod(i - 1, 26); s = chr(65 + r) + s
    return s
sheet_rows = []
for ri, r in enumerate(all_rows, start=1):
    cells = []
    for ci, v in enumerate(r):
        if v == "":
            continue
        cells.append(f'<c r="{col(ci)}{ri}" t="s"><v>{sid(v)}</v></c>')
    sheet_rows.append(f'<row r="{ri}">' + "".join(cells) + "</row>")
sheet = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
         '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>'
         + "".join(sheet_rows) + "</sheetData></worksheet>")
sst = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
       f'<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="{len(strings)}" uniqueCount="{len(strings)}">'
       + "".join(f"<si><t xml:space=\"preserve\">{escape(s)}</t></si>" for s in strings) + "</sst>")
with zipfile.ZipFile(os.path.join(out, "wechat-shared.xlsx"), "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("[Content_Types].xml", '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>')
    z.writestr("xl/workbook.xml", '<?xml version="1.0" encoding="UTF-8"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheets><sheet name="Sheet1" sheetId="1"/></sheets></workbook>')
    z.writestr("xl/sharedStrings.xml", sst)
    z.writestr("xl/worksheets/sheet1.xml", sheet)
print("wrote wechat-shared.xlsx")
