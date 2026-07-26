#!/usr/bin/env python3
"""Rebuild the Rai app icon from vector-traced sources in assets/icon-src/.

  background.png  reconstructed empty squircle (RGBA, 1024x1024)
  mark_alpha.png  shepherd mark coverage, potrace-traced at 8x (white = mark)
  mark_color.png  stroke color field at mask resolution

Usage: python3 scripts/make_icon.py [figure-fraction]

figure-fraction is the mark's height as a fraction of the squircle height
(default 0.72). Writes Resources/icon_1024.png, the full Rai.iconset,
Resources/Rai.icns and assets/rai-icon.png.
"""
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / 'assets' / 'icon-src'

FIGURE_FRACTION = float(sys.argv[1]) if len(sys.argv) > 1 else 0.72

bg = Image.open(SRC / 'background.png').convert('RGBA')
a_vec = np.asarray(Image.open(SRC / 'mark_alpha.png').convert('L'), dtype=np.float64) / 255.0
color = Image.open(SRC / 'mark_color.png').convert('RGB')

# interior squircle bounds from the canvas alpha
alpha = np.asarray(bg)[..., 3]
opaque = alpha > 200
rows = np.where(opaque.any(axis=1))[0]
cols = np.where(opaque.any(axis=0))[0]
ry0, ry1, rx0, rx1 = rows.min(), rows.max(), cols.min(), cols.max()

# scale mark to the requested fraction of the squircle height, center it
target_h = int((ry1 - ry0) * FIGURE_FRACTION)
target_w = int(round(target_h * a_vec.shape[1] / a_vec.shape[0]))
a_img = Image.fromarray((a_vec * 255).astype(np.uint8), 'L').resize((target_w, target_h), Image.LANCZOS)
c_img = color.resize((target_w, target_h), Image.LANCZOS)
sprite = Image.fromarray(
    np.dstack([np.asarray(c_img), np.asarray(a_img)[..., None]]), 'RGBA')

out = bg.copy()
px = (rx0 + rx1) // 2 - target_w // 2
py = (ry0 + ry1) // 2 - target_h // 2
out.alpha_composite(sprite, (px, py))
print(f'mark {target_w}x{target_h} ({FIGURE_FRACTION:.0%} of squircle) at {px},{py}')

out.save(ROOT / 'Resources' / 'icon_1024.png')
iconset = ROOT / 'Resources' / 'Rai.iconset'
sizes = {'icon_16x16.png': 16, 'icon_16x16@2x.png': 32, 'icon_32x32.png': 32,
         'icon_32x32@2x.png': 64, 'icon_128x128.png': 128, 'icon_128x128@2x.png': 256,
         'icon_256x256.png': 256, 'icon_256x256@2x.png': 512,
         'icon_512x512.png': 512, 'icon_512x512@2x.png': 1024}
for name, s in sizes.items():
    out.resize((s, s), Image.LANCZOS).save(iconset / name)
out.resize((400, 400), Image.LANCZOS).save(ROOT / 'assets' / 'rai-icon.png')
subprocess.run(['iconutil', '-c', 'icns', str(iconset),
                '-o', str(ROOT / 'Resources' / 'Rai.icns')], check=True)
print('wrote icon_1024.png, Rai.iconset, Rai.icns, rai-icon.png')
