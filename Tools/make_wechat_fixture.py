#!/usr/bin/env python3
"""渲染合成的「微信支付」两笔付款截图（虚构商户 / 金额 / 卡尾号），供 VisionCheck 跑真实 Vision OCR。
布局要素与真实账单页一致：两张付款卡片、「昨天 下午3:25」式时间标题、零钱 / 信用卡(尾号) 支付方式、对方已收款。
用法：python3 Tools/make_wechat_fixture.py Tests/Fixtures/wechat-two-payments.png"""
import sys
from PIL import Image, ImageDraw, ImageFont

S = 3  # 按 @3x 渲染（逻辑尺寸 472×1024）
W, H = 472, 1024
REG = "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc"
MED = "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc"  # 本机无 Medium 字重，用 Bold 代替
BOLD = "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc"
def font(path, size): return ImageFont.truetype(path, size * S, index=2)  # SC

img = Image.new("RGB", (W * S, H * S), (237, 237, 237))
d = ImageDraw.Draw(img)
def text(x, y, s, f, fill=(25, 25, 25), anchor="la"):
    d.text((x * S, y * S), s, font=f, fill=fill, anchor=anchor)
def rect(x0, y0, x1, y1, fill, r=0):
    d.rounded_rectangle((x0 * S, y0 * S, x1 * S, y1 * S), radius=r * S, fill=fill)
def circle(cx, cy, r, fill):
    d.ellipse(((cx - r) * S, (cy - r) * S, (cx + r) * S, (cy + r) * S), fill=fill)
def line(x0, y0, x1, y1, fill=(232, 232, 232), w=1):
    d.line((x0 * S, y0 * S, x1 * S, y1 * S), fill=fill, width=w * S)

# 状态栏 + 导航栏
rect(0, 0, W, 106, (247, 247, 247))
text(88, 32, "8:50", font(BOLD, 19), anchor="mm")
rect(398, 24, 428, 40, (30, 30, 30), r=5); text(413, 32, "88", font(BOLD, 11), fill=(255, 255, 255), anchor="mm")
text(W / 2, 83, "微信支付", font(MED, 18), anchor="mm")
d.line((28 * S, 74 * S, 20 * S, 83 * S, 28 * S, 92 * S), fill=(30, 30, 30), width=2 * S)
line(0, 106, W, 106, (220, 220, 220))

def header(y, s): text(W / 2, y, s, font(REG, 14), fill=(160, 160, 160), anchor="mm")

# 第一笔：零钱
header(139, "昨天 下午3:25")
rect(24, 164, 448, 570, (255, 255, 255), r=10)
circle(54, 195, 13, (250, 173, 20))
text(77, 195, "阿芳", font(MED, 16), anchor="lm")
text(W / 2, 282, "使用零钱支付", font(REG, 15), anchor="mm")
text(W / 2, 333, "¥18.00", font(MED, 38), anchor="mm")
text(42, 411, "交易状态", font(REG, 15), fill=(120, 120, 120), anchor="lm")
text(130, 411, "支付成功，对方已收款", font(MED, 15), anchor="lm")
line(42, 447, 430, 447)
text(42, 479, "查看交易详情", font(REG, 15), anchor="lm"); text(424, 479, "›", font(REG, 20), fill=(180, 180, 180), anchor="mm")
line(42, 510, 430, 510)
text(77, 540, "留言", font(MED, 15), anchor="lm"); circle(55, 540, 9, (60, 60, 60))
text(408, 540, "可给对方留言致谢、咨询", font(REG, 14), fill=(120, 120, 120), anchor="rm")

# 第二笔：信用卡
header(608, "昨天 晚上8:12")
rect(24, 633, 448, 910, (255, 255, 255), r=10)
circle(54, 664, 11, (232, 64, 120))
text(77, 664, "华南畅行高速科技有限公司", font(MED, 16), anchor="lm")
line(24, 696, 448, 696, (240, 240, 240))
text(W / 2, 751, "使用交通银行信用卡 (7316) 支付", font(REG, 15), anchor="mm")
text(W / 2, 803, "¥46.00", font(MED, 38), anchor="mm")
text(W / 2, 857, "账单详情 ›", font(REG, 14), fill=(120, 120, 120), anchor="mm")

# 底部工具栏
rect(0, 926, W, H, (247, 247, 247)); line(0, 926, W, 926, (220, 220, 220))
for x, s in [(122, "我的账单"), (262, "支付服务"), (402, "优惠")]:
    text(x, 956, s, font(MED, 15), anchor="mm")
for x in (52, 192, 332): line(x, 936, x, 976, (225, 225, 225))
circle(26, 956, 12, (90, 90, 90))

out = sys.argv[1] if len(sys.argv) > 1 else "wechat-two-payments.png"
img.save(out, optimize=True)
print("wrote", out)
