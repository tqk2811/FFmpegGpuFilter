# Draws the generic banknote used by the Dollar Bills II effect (textures/bill.png).
# Everything is generated here from shapes and noise; no photo or scan is involved.
# Run: py -I make-bill.py   (needs NumPy and Pillow 10.1+ with FreeType for the default font)
import math
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 512, 216
rng = np.random.default_rng(7)

PAPER = np.array([228, 229, 206], float)
INK = np.array([92, 112, 92], float)
DARK = np.array([58, 74, 60], float)
SEAL = np.array([58, 124, 84], float)

yy, xx = np.mgrid[0:H, 0:W].astype(float)

# Paper with fine wavy engraving lines across it.
img = np.tile(PAPER, (H, W, 1))
waves = 0.5 + 0.5 * np.sin(xx * 0.9 + 6.0 * np.sin(yy * 0.07) + 3.0 * np.sin(xx * 0.013))
img -= (waves[..., None] ** 6) * 26.0 * np.array([1.0, 0.8, 1.0])
img += rng.normal(0.0, 3.0, (H, W, 1))


def blend(mask, color, alpha=1.0):
    global img
    m = np.clip(mask, 0.0, 1.0)[..., None] * alpha
    img = img * (1.0 - m) + color * m


# Border frame and an inner rule.
edge = np.minimum(np.minimum(xx, W - 1 - xx), np.minimum(yy, H - 1 - yy))
blend((edge < 9).astype(float), INK, 0.5)
blend(((edge > 12) & (edge < 14)).astype(float), INK, 0.7)
# Guilloche band inside the frame.
band = (edge >= 14) & (edge < 24)
rosette = 0.5 + 0.5 * np.sin((xx + yy) * 0.45) * np.sin((xx - yy) * 0.45)
blend(band * (rosette > 0.75), INK, 0.6)

# Oval portrait frame, right of centre, with a stylised bust inside.
cx, cy, rx, ry = W * 0.6, H * 0.5, 62.0, 84.0
d = np.sqrt(((xx - cx) / rx) ** 2 + ((yy - cy) / ry) ** 2)
blend(((d > 0.9) & (d < 1.0)).astype(float), INK, 0.9)
blend(((d > 0.8) & (d < 0.84)).astype(float), INK, 0.6)
inside = d < 0.8
shade = 0.5 + 0.5 * np.sin(yy * 1.3)
blend(inside * 0.25 * shade, INK)
head = np.sqrt(((xx - cx) / 24.0) ** 2 + ((yy - (cy - 18.0)) / 30.0) ** 2) < 1.0
shoulders = (np.sqrt(((xx - cx) / 52.0) ** 2 + ((yy - (cy + 62.0)) / 40.0) ** 2) < 1.0) & inside
hair = head & (yy < cy - 30.0)
blend(shoulders.astype(float), DARK, 0.85)
blend(head.astype(float), INK * 1.25, 0.9)
blend(hair.astype(float), DARK, 0.9)
blend((head & (np.abs(xx - cx) > 12.0)).astype(float), DARK, 0.35)

# Round seal on the left.
sx, sy = W * 0.23, H * 0.52
ang = np.arctan2(yy - sy, xx - sx)
r = np.hypot(xx - sx, yy - sy) / (26.0 + 2.0 * np.sin(ang * 24.0))
blend((r < 1.0).astype(float), SEAL, 0.85)
blend(((r > 0.55) & (r < 0.68)).astype(float), PAPER, 0.8)

pil = Image.fromarray(np.clip(img, 0, 255).astype(np.uint8), "RGB")
draw = ImageDraw.Draw(pil)
font = ImageFont.load_default(size=40)
small = ImageFont.load_default(size=13)
for (x, y) in [(22, 18), (W - 92, H - 58)]:
    draw.text((x, y), "100", font=font, fill=tuple(int(c) for c in DARK))
draw.text((W - 88, 22), "100", font=ImageFont.load_default(size=30), fill=tuple(int(c) for c in INK))
draw.text((26, H - 50), "100", font=ImageFont.load_default(size=30), fill=tuple(int(c) for c in INK))
draw.text((W * 0.33, 26), "ONE HUNDRED", font=small, fill=tuple(int(c) for c in DARK))
draw.text((W * 0.08, H * 0.66), "AB 0123456 C", font=small, fill=tuple(int(c) for c in SEAL))
draw.text((W * 0.74, H * 0.3), "AB 0123456 C", font=small, fill=tuple(int(c) for c in SEAL))
pil = pil.filter(ImageFilter.GaussianBlur(0.6))
pil.save(os.path.join(os.path.dirname(os.path.abspath(__file__)), "bill.png"), optimize=True)
