"""生成 1024x1024 占位 App 图标（无透明通道）。用法: python3 Tools/make_icon.py"""
from PIL import Image, ImageDraw, ImageFilter

S = 1024
img = Image.new("RGB", (S, S))
top, bottom = (40, 190, 140), (20, 110, 170)
px = img.load()
for y in range(S):
    for x in range(S):
        t = (x * 0.35 + y * 0.65) / S
        px[x, y] = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))

# 阴影
shadow = Image.new("L", (S, S), 0)
ImageDraw.Draw(shadow).rounded_rectangle((262, 222, 782, 842), radius=70, fill=110)
shadow = shadow.filter(ImageFilter.GaussianBlur(28))
img.paste((10, 60, 80), (0, 0), shadow)

d = ImageDraw.Draw(img)
# 账本卡片
d.rounded_rectangle((252, 196, 772, 816), radius=70, fill=(255, 255, 255))
d.rounded_rectangle((252, 196, 330, 816), radius=40, fill=(225, 245, 238))
for i in range(5):
    y = 270 + i * 120
    d.ellipse((276, y, 306, y + 30), fill=(40, 170, 130))

# ¥ 符号
c = (25, 140, 125)
w = 46
cx = 551
d.line((cx - 130, 330, cx, 500), fill=c, width=w)
d.line((cx + 130, 330, cx, 500), fill=c, width=w)
d.line((cx, 495, cx, 700), fill=c, width=w)
d.line((cx - 120, 540, cx + 120, 540), fill=c, width=w - 8)
d.line((cx - 120, 615, cx + 120, 615), fill=c, width=w - 8)
for (x, y) in [(cx - 130, 330), (cx + 130, 330), (cx, 700)]:
    d.ellipse((x - w / 2, y - w / 2, x + w / 2, y + w / 2), fill=c)

img.save("Ledger/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")
print("ok")
