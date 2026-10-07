"""Render the Nexus header image.

1300x372, drawn at 2x and downscaled for clean edges.

Styled as a cockpit HUD readout: starfield, planet limb, scanlines, corner
brackets. Evokes the setting without touching any trademarked logo or typeface,
which matters for a fan mod page.

The mixer on the right is doing real work rather than decorating. It shows the
voice channel pushed up and the maskers pulled down against a 0 dB reference,
using the mod's actual default values, so the picture and the mod agree.

    python tools/make-header.py
    python tools/make-header.py --out docs/header.png
"""
import argparse
import math
import os
import random
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 1300, 372
SCALE = 2
SEED = 20261007

FONTS = "C:/Windows/Fonts/"
TITLE_FONTS = ["bahnschrift.ttf", "segoeuib.ttf", "arialbd.ttf", "impact.ttf"]
BODY_FONTS = ["segoeuib.ttf", "arialbd.ttf"]
MONO_FONTS = ["consolab.ttf", "cour.ttf"]

SPACE_TOP = (9, 13, 24)
SPACE_BOTTOM = (4, 6, 12)
GOLD = (255, 232, 31)          # the crawl yellow, as a colour not a logo
GOLD_DIM = (184, 164, 40)
AMBER = (255, 186, 73)
HUD_BLUE = (96, 150, 200)
HUD_BLUE_DIM = (54, 86, 120)
TEXT = (236, 242, 250)
MUTED = (132, 150, 176)

# Real defaults. Voice is class_boost 1.7x expressed in dB for comparability.
CHANNELS = [
    ("VOICE",   20 * math.log10(1.70), True),
    ("MUSIC",   20 * math.log10(0.60), False),
    ("CROWDS",  20 * math.log10(0.65), False),
    ("AIRFLOW", 20 * math.log10(0.65), False),
    ("ENGINES", 20 * math.log10(0.70), False),
    ("AMBIENT", 20 * math.log10(0.80), False),
]


def load(candidates, size):
    for name in candidates:
        path = os.path.join(FONTS, name)
        if os.path.isfile(path):
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                continue
    return ImageFont.load_default()


def fit_font(candidates, text, max_width, start, floor=28):
    """Largest size at which text fits max_width, so the title cannot collide."""
    probe = ImageDraw.Draw(Image.new("RGB", (8, 8)))
    size = start
    while size > floor:
        font = load(candidates, size)
        if probe.textlength(text, font=font) <= max_width:
            return font
        size -= 2
    return load(candidates, floor)


def starfield(size):
    w, h = size
    img = Image.new("RGB", size, SPACE_BOTTOM)
    draw = ImageDraw.Draw(img)
    for y in range(h):
        t = (y / max(h - 1, 1)) ** 0.8
        draw.line([(0, y), (w, y)],
                  fill=tuple(round(a + (b - a) * t)
                             for a, b in zip(SPACE_TOP, SPACE_BOTTOM)))

    rng = random.Random(SEED)
    stars = Image.new("RGBA", size, (0, 0, 0, 0))
    sd = ImageDraw.Draw(stars)
    for _ in range(460):
        x, y = rng.uniform(0, w), rng.uniform(0, h)
        r = rng.choice([0.7, 0.7, 0.9, 1.1, 1.4]) * SCALE
        a = rng.randint(40, 190)
        tint = rng.choice([(255, 255, 255), (214, 228, 255), (255, 244, 214)])
        sd.ellipse((x - r, y - r, x + r, y + r), fill=tint + (a,))
    # A handful of brighter stars with a soft bloom.
    bloom = Image.new("RGBA", size, (0, 0, 0, 0))
    bd = ImageDraw.Draw(bloom)
    for _ in range(14):
        x, y = rng.uniform(0, w), rng.uniform(0, h * 0.8)
        r = rng.uniform(1.6, 2.6) * SCALE
        bd.ellipse((x - r, y - r, x + r, y + r), fill=(255, 255, 255, 220))
    bloom = bloom.filter(ImageFilter.GaussianBlur(3 * SCALE))

    img = Image.alpha_composite(img.convert("RGBA"), bloom)
    img = Image.alpha_composite(img, stars)
    return img.convert("RGB")


def planet_limb(img):
    """A dark planet edge across the bottom with a thin lit rim."""
    w, h = img.size
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)

    # Lowered and flattened so the limb reads as a horizon rather than cutting
    # through the mixer labels on the right.
    cx, cy = w * 0.38, h * 3.15
    r = h * 2.78
    box = (cx - r, cy - r, cx + r, cy + r)

    # Rim light first, then the body over it, leaving a bright sliver.
    rim = Image.new("RGBA", img.size, (0, 0, 0, 0))
    rd = ImageDraw.Draw(rim)
    rd.ellipse(box, fill=AMBER + (170,))
    rim = rim.filter(ImageFilter.GaussianBlur(5 * SCALE))
    layer = Image.alpha_composite(layer, rim)

    # The body sits just below the rim, a touch lighter than space so the limb
    # reads as a planet rather than a bare arc.
    d = ImageDraw.Draw(layer)
    d.ellipse((box[0], box[1] + 3.5 * SCALE, box[2], box[3] + 3.5 * SCALE),
              fill=(11, 16, 28, 255))

    return Image.alpha_composite(img.convert("RGBA"), layer).convert("RGB")


def scanlines(img, alpha=16, step=3):
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    for y in range(0, img.size[1], step * SCALE):
        d.line([(0, y), (img.size[0], y)], fill=(0, 0, 0, alpha), width=SCALE)
    return Image.alpha_composite(img.convert("RGBA"), layer).convert("RGB")


def corner_brackets(draw, colour, inset, length, width):
    s = SCALE
    x0, y0 = inset * s, inset * s
    x1, y1 = (W - inset) * s, (H - inset) * s
    L, t = length * s, max(1, width * s)
    for (cx, cy, dx, dy) in ((x0, y0, 1, 1), (x1, y0, -1, 1),
                             (x0, y1, 1, -1), (x1, y1, -1, -1)):
        draw.line((cx, cy, cx + dx * L, cy), fill=colour, width=t)
        draw.line((cx, cy, cx, cy + dy * L), fill=colour, width=t)


def add_glow(img, boxes, colour, blur, alpha):
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    for box in boxes:
        x0, y0, x1, y1 = box
        pad = 12 * SCALE
        d.rounded_rectangle((x0 - pad, y0 - pad, x1 + pad, y1 + pad),
                            radius=14 * SCALE, fill=colour + (alpha,))
    layer = layer.filter(ImageFilter.GaussianBlur(blur))
    return Image.alpha_composite(img.convert("RGBA"), layer).convert("RGB")


def render():
    size = (W * SCALE, H * SCALE)
    s = SCALE

    img = starfield(size)
    img = planet_limb(img)

    # ---- mixer geometry (right side) ----------------------------------
    panel_left = 742 * s
    panel_right = (W - 62) * s
    baseline = 196 * s
    unit = 10.5 * s
    bar_w = 40 * s
    gap = ((panel_right - panel_left) - bar_w * len(CHANNELS)) / (len(CHANNELS) - 1)

    bars = []
    for i, (name, db, is_voice) in enumerate(CHANNELS):
        x0 = panel_left + i * (bar_w + gap)
        x1 = x0 + bar_w
        extent = abs(db) * unit
        box = ((x0, baseline - extent, x1, baseline) if db >= 0
               else (x0, baseline, x1, baseline + extent))
        bars.append((box, name, db, is_voice))

    img = add_glow(img, [b for b, _, _, v in bars if v], AMBER, 22 * s, 120)
    draw = ImageDraw.Draw(img)

    # ---- title block (left) -------------------------------------------
    x = 74 * s
    title = "LOUD AND CLEAR"
    f_title = fit_font(TITLE_FONTS, title, 560 * s, 78 * s, floor=40 * s)
    f_sub = load(BODY_FONTS, 24 * s)
    f_meta = load(MONO_FONTS, 15 * s)
    f_label = load(BODY_FONTS, 13 * s)
    f_value = load(MONO_FONTS, 14 * s)

    draw.text((x, 118 * s), title, font=f_title, fill=GOLD)
    draw.text((x, 198 * s), "Dialogue you can actually hear.",
              font=f_sub, fill=TEXT)
    draw.rectangle((x, 243 * s, x + 74 * s, 245 * s), fill=AMBER)
    draw.text((x, 262 * s), "STAR WARS: GALACTIC RACER  //  UE4SS",
              font=f_meta, fill=MUTED)

    # ---- HUD frame ----------------------------------------------------
    corner_brackets(draw, HUD_BLUE_DIM, inset=20, length=34, width=1)
    draw.line((700 * s, 86 * s, 700 * s, (H - 86) * s), fill=HUD_BLUE_DIM, width=s)

    # ---- 0 dB reference, labelled clear of the bars --------------------
    rule_left = panel_left - 14 * s
    draw.line((rule_left, baseline, panel_right + 10 * s, baseline),
              fill=HUD_BLUE_DIM, width=s)
    zero = "0 dB"
    zw = draw.textlength(zero, font=f_label)
    draw.text((rule_left - zw - 12 * s, baseline - 8 * s), zero,
              font=f_label, fill=HUD_BLUE)

    # ---- bars ---------------------------------------------------------
    for box, name, db, is_voice in bars:
        x0, y0, x1, y1 = box
        colour = AMBER if is_voice else HUD_BLUE_DIM
        draw.rounded_rectangle(box, radius=3 * s, fill=colour)

        cap = (255, 226, 170) if is_voice else HUD_BLUE
        if db >= 0:
            draw.rectangle((x0, y0, x1, y0 + 4 * s), fill=cap)
        else:
            draw.rectangle((x0, y1 - 4 * s, x1, y1), fill=cap)

        label_y = (y0 - 26 * s) if db >= 0 else (y1 + 10 * s)
        value_y = (y0 - 46 * s) if db >= 0 else (y1 + 28 * s)
        cx = (x0 + x1) / 2
        for text, fy, font, fill in (
            (name, label_y, f_label, TEXT if is_voice else MUTED),
            ("%+.1f" % db, value_y, f_value, AMBER if is_voice else HUD_BLUE),
        ):
            tw = draw.textlength(text, font=font)
            draw.text((cx - tw / 2, fy), text, font=font, fill=fill)

    img = scanlines(img)
    return img.resize((W, H), Image.LANCZOS)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="docs/header-1300x372.png")
    args = ap.parse_args()
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    img = render()
    img.save(args.out, "PNG", optimize=True)
    print("wrote %s  %dx%d  %.0f KB"
          % (args.out, img.width, img.height, os.path.getsize(args.out) / 1024))
    return 0


if __name__ == "__main__":
    sys.exit(main())
