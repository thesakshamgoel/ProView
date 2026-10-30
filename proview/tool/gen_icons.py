#!/usr/bin/env python3
"""Builds ProView's launcher icon, splash and notification icon from the original logo, unchanged.

The logo is Logos/Logo 1.png exactly as designed: nothing is added to it and it isn't recoloured. It is only
scaled and centred on the canvases Android needs.

Outputs (from the proview/ folder):
  assets/brand/logo.png                                       the logo, copied as is (used inside the app)
  android/.../res/drawable-nodpi/ic_launcher_foreground.png   adaptive icon foreground: the logo on transparency
  android/.../res/drawable-nodpi/ic_launcher_monochrome.png   themed icon (Android 13+): the logo's silhouette
  android/.../res/drawable-nodpi/splash_logo.png              system splash
  android/.../res/drawable-nodpi/ic_stat_proview.png          notification icon: white silhouette
  android/.../res/drawable/ic_launcher_background.xml         plain white behind the logo

Usage: python3 tool/gen_icons.py
"""
import os
import shutil

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, '..', 'Logos', 'Logo 1.png')
RES = os.path.join(ROOT, 'android', 'app', 'src', 'main', 'res')
NODPI = os.path.join(RES, 'drawable-nodpi')


def on_canvas(img, canvas, fraction):
    """Centres [img] on a transparent square canvas so that it fills [fraction] of its height."""
    scale = canvas * fraction / max(img.size)
    w, h = round(img.width * scale), round(img.height * scale)
    out = Image.new('RGBA', (canvas, canvas), (0, 0, 0, 0))
    out.alpha_composite(img.resize((w, h), Image.LANCZOS), ((canvas - w) // 2, (canvas - h) // 2))
    return out


def silhouette(img):
    """White wherever the logo has any ink; for the monochrome and notification icons."""
    mask = img.getchannel('A').point(lambda v: 255 if v > 24 else 0)
    out = Image.new('RGBA', img.size, (255, 255, 255, 0))
    out.putalpha(mask)
    white = Image.new('RGBA', img.size, (255, 255, 255, 255))
    white.putalpha(mask)
    return white


logo = Image.open(SRC).convert('RGBA')
os.makedirs(NODPI, exist_ok=True)
os.makedirs(os.path.join(ROOT, 'assets', 'brand'), exist_ok=True)
shutil.copyfile(SRC, os.path.join(ROOT, 'assets', 'brand', 'logo.png'))

# Adaptive icons are 108dp with a 72dp-wide safe circle; the mark sits comfortably inside it.
on_canvas(logo, 432, 0.58).save(os.path.join(NODPI, 'ic_launcher_foreground.png'))
on_canvas(silhouette(logo), 432, 0.58).save(os.path.join(NODPI, 'ic_launcher_monochrome.png'))
on_canvas(logo, 576, 0.62).save(os.path.join(NODPI, 'splash_logo.png'))
on_canvas(silhouette(logo), 96, 0.92).save(os.path.join(NODPI, 'ic_stat_proview.png'))

with open(os.path.join(RES, 'drawable', 'ic_launcher_background.xml'), 'w') as f:
    f.write('<?xml version="1.0" encoding="utf-8"?>\n'
            '<!-- Plain white behind the logo, as in the original artwork. -->\n'
            '<shape xmlns:android="http://schemas.android.com/apk/res/android" android:shape="rectangle">\n'
            '    <solid android:color="#FFFFFFFF"/>\n'
            '</shape>\n')
print('icons written')
