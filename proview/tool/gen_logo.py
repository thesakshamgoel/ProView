#!/usr/bin/env python3
"""Generates ProView's logo assets from the vector mark in Logos/Logo 1.ai.

Outputs:
  lib/brand/logo_paths.dart                         ring outlines for the in-app logo, loaders and spinners
  android/.../drawable/ic_launcher_foreground.xml   adaptive icon: glass rings + white play button
  android/.../drawable/ic_launcher_background.xml   adaptive icon: deep blue glass
  android/.../drawable/ic_launcher_monochrome.xml   themed icon (Android 13+)
  android/.../drawable/ic_stat_proview.xml          notification icon
  android/.../drawable/splash_logo.xml              Android 12+ splash: rings turning in opposite directions

Usage: python3 tool/gen_logo.py   (from the proview/ folder)
"""
import math
import os
import re
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AI = os.path.join(ROOT, '..', 'Logos', 'Logo 1.ai')
RES = os.path.join(ROOT, 'android', 'app', 'src', 'main', 'res')
CX, CY, R = 252.0, 248.0, 217.0   # centre and outer radius of the mark in the .ai artboard


def read_rings():
    data = open(AI, 'rb').read()
    for m in re.finditer(rb'\d+ 0 obj\s*<<(.*?)>>\s*stream\r?\n', data, re.S):
        if b'XML' in m.group(1):
            continue
        end = data.find(b'endstream', m.end())
        try:
            text = zlib.decompress(data[m.end():end]).decode('latin1')
        except zlib.error:
            continue
        if ' c\n' not in text:
            continue
        rings, cur = [], None
        for line in text.split('\n'):
            p = line.split()
            if not p:
                continue
            op = p[-1]
            if op == 'm':
                cur = cur if cur is not None else []
                cur.append((0, pts(p)))
            elif op == 'l' and cur is not None:
                q = pts(p)
                if cur[-1][1][-2:] != q:
                    cur.append((1, q))
            elif op == 'c' and cur is not None:
                cur.append((2, pts(p)))
            elif op == 'n' and cur:   # "W n": end of one clipped ring shape
                rings.append(cur)
                cur = None
        rings.sort(key=mean_radius)
        return rings
    raise SystemExit('No vector paths found in ' + AI)


def pts(p):
    nums = [float(x) for x in p[:-1]]
    out = []
    for i in range(0, len(nums), 2):
        out += [round((nums[i] - CX) / R, 4), round(-(nums[i + 1] - CY) / R, 4)]   # unit coords, y down
    return out


def mean_radius(ring):
    xy = [(c[1][-2], c[1][-1]) for c in ring]
    return sum(math.hypot(x, y) for x, y in xy) / len(xy)


def path_data(ring, scale, cx, cy):
    out = []
    for op, p in ring:
        q = ['%.3f' % (cx + v * scale) if i % 2 == 0 else '%.3f' % (cy + v * scale) for i, v in enumerate(p)]
        out.append({0: 'M', 1: 'L', 2: 'C'}[op] + ' '.join(q))
    return ''.join(out) + 'Z'


def play_path(scale, cx, cy):
    """Rounded play triangle as in the reference artwork, in unit coordinates of the mark."""
    corners = [(-0.215, -0.27), (-0.215, 0.27), (0.285, 0.0)]
    rad = 0.075
    segs = []
    for i, (x, y) in enumerate(corners):
        px, py = corners[i - 1]
        nx, ny = corners[(i + 1) % 3]

        def toward(ax, ay, bx, by):
            d = math.hypot(bx - ax, by - ay)
            return ax + (bx - ax) * rad / d, ay + (by - ay) * rad / d
        a = toward(x, y, px, py)
        b = toward(x, y, nx, ny)
        segs.append((a, (x, y), b))
    f = lambda v, c: '%.3f' % (c + v * scale)
    d = 'M%s %s' % (f(segs[0][0][0], cx), f(segs[0][0][1], cy))
    for i, (a, c, b) in enumerate(segs):
        if i:
            d += 'L%s %s' % (f(a[0], cx), f(a[1], cy))
        d += 'Q%s %s %s %s' % (f(c[0], cx), f(c[1], cy), f(b[0], cx), f(b[1], cy))
    return d + 'Z'


RING_COLORS = [   # inner -> outer: light cyan-blue to deep blue, like the reference render
    ('#FF63B3FF', '#FF2F6BF2'),
    ('#FF55A4FF', '#FF2A63EE'),
    ('#FF4B97FF', '#FF2459E8'),
    ('#FF4290FF', '#FF1F55E6'),
]


def gradient(start, end, x1, y1, x2, y2):
    return ('<aapt:attr name="android:fillColor"><gradient android:type="linear" '
            'android:startX="%.2f" android:startY="%.2f" android:endX="%.2f" android:endY="%.2f" '
            'android:startColor="%s" android:endColor="%s"/></aapt:attr>' % (x1, y1, x2, y2, start, end))


def write_icon(rings, name, size, mark_radius, colored, with_play=True, groups=False):
    c = size / 2
    body = []
    for i, ring in enumerate(rings):
        d = path_data(ring, mark_radius, c, c)
        if colored:
            s, e = RING_COLORS[i]
            path = ('<path android:pathData="%s" android:fillType="evenOdd" android:fillAlpha="0.86">%s</path>'
                    % (d, gradient(s, e, c - mark_radius, c - mark_radius, c + mark_radius, c + mark_radius)))
        else:
            path = '<path android:pathData="%s" android:fillType="evenOdd" android:fillColor="#FFFFFFFF"/>' % d
        if groups:
            path = ('<group android:name="ring%d" android:pivotX="%.1f" android:pivotY="%.1f">%s</group>'
                    % (i, c, c, path))
        body.append(path)
    if with_play:
        d = play_path(mark_radius, c, c)
        if colored:
            body.append('<path android:pathData="%s">%s</path>' % (
                d, gradient('#FF6FC3FF', '#FF1E5BEA', c + mark_radius * 0.3, c - mark_radius * 0.3,
                            c - mark_radius * 0.2, c + mark_radius * 0.3)))
        else:
            body.append('<path android:pathData="%s" android:fillColor="#FFFFFFFF"/>' % d)
    xml = ('<?xml version="1.0" encoding="utf-8"?>\n'
           '<!-- Generated by tool/gen_logo.py from Logos/Logo 1.ai. -->\n'
           '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
           '    xmlns:aapt="http://schemas.android.com/aapt"\n'
           '    android:width="%ddp" android:height="%ddp"\n'
           '    android:viewportWidth="%d" android:viewportHeight="%d">\n    %s\n</vector>\n'
           % (size, size, size, size, '\n    '.join(body)))
    with open(os.path.join(RES, 'drawable', name), 'w') as f:
        f.write(xml)


def write_launcher_foreground(rings):
    """App icon: luminous white glass rings around a solid white play button, on the blue background."""
    size, r = 108, 30.5
    c = size / 2
    body = []
    for i, ring in enumerate(rings):
        d = path_data(ring, r, c, c)
        body.append('<path android:pathData="%s" android:fillType="evenOdd" android:fillAlpha="%.2f">%s</path>'
                    % (d, [0.46, 0.52, 0.60, 0.72][i],
                       gradient('#FFFFFFFF', '#FFBFDDFF', c - r, c - r, c + r, c + r)))
    play = play_path(r * 1.0, c + r * 0.025, c)
    shadow = play_path(r * 1.0, c + r * 0.025, c + 1.2)
    body.append('<path android:pathData="%s" android:fillColor="#40081E6B"/>' % shadow)
    body.append('<path android:pathData="%s">%s</path>' % (play, gradient('#FFFFFFFF', '#FFD6E8FF', c - r * 0.3, c - r * 0.4, c + r * 0.4, c + r * 0.5)))
    xml = ('<?xml version="1.0" encoding="utf-8"?>\n'
           '<!-- Generated by tool/gen_logo.py from Logos/Logo 1.ai. -->\n'
           '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
           '    xmlns:aapt="http://schemas.android.com/aapt"\n'
           '    android:width="108dp" android:height="108dp"\n'
           '    android:viewportWidth="108" android:viewportHeight="108">\n    %s\n</vector>\n' % '\n    '.join(body))
    with open(os.path.join(RES, 'drawable', 'ic_launcher_foreground.xml'), 'w') as f:
        f.write(xml)


def write_launcher_background():
    xml = """<?xml version="1.0" encoding="utf-8"?>
<!-- Deep blue glass: bright top-left, rich indigo bottom-right, with a soft highlight. -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:aapt="http://schemas.android.com/aapt"
    android:width="108dp" android:height="108dp" android:viewportWidth="108" android:viewportHeight="108">
    <path android:pathData="M0,0h108v108h-108z">
        <aapt:attr name="android:fillColor">
            <gradient android:type="linear" android:startX="14" android:startY="0" android:endX="94" android:endY="108">
                <item android:offset="0" android:color="#FF5CA8FF"/>
                <item android:offset="0.5" android:color="#FF2F6BF2"/>
                <item android:offset="1" android:color="#FF1A33B8"/>
            </gradient>
        </aapt:attr>
    </path>
    <path android:pathData="M0,0h108v108h-108z">
        <aapt:attr name="android:fillColor">
            <gradient android:type="radial" android:centerX="30" android:centerY="20" android:gradientRadius="70">
                <item android:offset="0" android:color="#55FFFFFF"/>
                <item android:offset="1" android:color="#00FFFFFF"/>
            </gradient>
        </aapt:attr>
    </path>
</vector>
"""
    with open(os.path.join(RES, 'drawable', 'ic_launcher_background.xml'), 'w') as f:
        f.write(xml)


def write_splash_animation():
    """Each ring turns one lobe (36 degrees), alternating directions, then settles."""
    anim_dir = os.path.join(RES, 'animator')
    os.makedirs(anim_dir, exist_ok=True)
    targets = []
    for i in range(4):
        sign = 1 if i % 2 == 0 else -1
        name = 'splash_ring%d' % i
        with open(os.path.join(anim_dir, name + '.xml'), 'w') as f:
            f.write('<?xml version="1.0" encoding="utf-8"?>\n'
                    '<objectAnimator xmlns:android="http://schemas.android.com/apk/res/android"\n'
                    '    android:propertyName="rotation" android:duration="900"\n'
                    '    android:valueFrom="0" android:valueTo="%d"\n'
                    '    android:interpolator="@android:interpolator/fast_out_slow_in"/>\n' % (sign * 36))
        targets.append('<target android:name="ring%d" android:animation="@animator/%s"/>' % (i, name))
    with open(os.path.join(RES, 'drawable', 'splash_logo_animated.xml'), 'w') as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n'
                '<animated-vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
                '    android:drawable="@drawable/splash_logo">\n    %s\n</animated-vector>\n' % '\n    '.join(targets))


def write_dart(rings):
    lines = ['// Generated by tool/gen_logo.py from Logos/Logo 1.ai: the four woven rings of the ProView mark,',
             '// in unit coordinates (centre 0,0, outer radius 1, y down), innermost ring first.',
             '// Ops: 0 moveTo(x, y), 1 lineTo(x, y), 2 cubicTo(x1, y1, x2, y2, x, y).',
             '',
             'const List<List<double>> kLogoRings = [']
    for ring in rings:
        flat = []
        for op, p in ring:
            flat.append(op)
            flat += p
        lines.append('  [' + ', '.join('%g' % v for v in flat) + '],')
    lines.append('];')
    with open(os.path.join(ROOT, 'lib', 'brand', 'logo_paths.dart'), 'w') as f:
        f.write('\n'.join(lines) + '\n')


if __name__ == '__main__':
    rings = read_rings()
    assert len(rings) == 4, 'expected 4 rings, found %d' % len(rings)
    write_dart(rings)
    # Adaptive icons are 108dp with a 66dp safe circle; the mark sits inside it.
    write_launcher_foreground(rings)
    write_launcher_background()
    write_icon(rings, 'ic_launcher_monochrome.xml', 108, 30, colored=False)
    write_icon(rings, 'ic_stat_proview.xml', 24, 11.5, colored=False)
    # Android 12+ splash icons are 240dp with a 160dp safe circle.
    write_icon(rings, 'splash_logo.xml', 240, 72, colored=True, groups=True)
    write_splash_animation()
    print('Logo assets written.')
