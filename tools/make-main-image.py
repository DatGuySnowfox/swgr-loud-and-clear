"""Composite the mod title and a cockpit HUD onto generated key art.

    python tools/make-main-image.py art.png
    python tools/make-main-image.py art.png --out docs/main-1920x1080.png

Source art is scaled to cover 1920x1080 and centre-cropped, so an input that is
not exactly 16:9 does not get stretched.

Text sits at the top because measuring the reference art put the calmest region
there (mean luminance 248, stddev 3), but calm and bright means light text needs
help: a soft scrim plus a dark shadow under the glow keeps it legible without
flattening the sky.

The game name is set in a plain font on purpose. Naming the game a mod is for is
normal, reproducing its logo typeface is a different thing.
"""
import argparse
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 1920, 1080

FONTS = "C:/Windows/Fonts/"
TITLE_FONTS = ["bahnschrift.ttf", "segoeuib.ttf", "arialbd.ttf"]
BODY_FONTS = ["bahnschrift.ttf", "segoeuib.ttf", "arialbd.ttf"]
MONO_FONTS = ["consolab.ttf", "cour.ttf"]

CYAN = (178, 232, 248)
CYAN_DIM = (122, 196, 222)
CYAN_FAINT = (90, 150, 176)
WARM = (240, 214, 178)
SHADOW = (4, 10, 18)


def load(candidates, size):
    for name in candidates:
        path = os.path.join(FONTS, name)
        if os.path.isfile(path):
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                continue
    return ImageFont.load_default()


def cover(img, size):
    """Scale to cover and centre-crop, so nothing is stretched."""
    tw, th = size
    scale = max(tw / img.width, th / img.height)
    nw, nh = round(img.width * scale), round(img.height * scale)
    img = img.resize((nw, nh), Image.LANCZOS)
    return img.crop(((nw - tw) // 2, (nh - th) // 2,
                     (nw - tw) // 2 + tw, (nh - th) // 2 + th))


def tracked(draw, xy, text, font, fill, tracking=0, anchor_centre=False):
    """Pillow has no letter-spacing, so step through the string."""
    widths = [draw.textlength(c, font=font) for c in text]
    total = sum(widths) + tracking * max(len(text) - 1, 0)
    x, y = xy
    if anchor_centre:
        x -= total / 2
    for c, w in zip(text, widths):
        draw.text((x, y), c, font=font, fill=fill)
        x += w + tracking
    return total


def text_layer(size, draw_fn):
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    draw_fn(ImageDraw.Draw(layer))
    return layer


def scrim(img, height_frac=0.42, strength=150):
    """Darken the top so light text holds up over a bright sky."""
    w, h = img.size
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    span = int(h * height_frac)
    for y in range(span):
        t = 1.0 - (y / span)
        d.line([(0, y), (w, y)], fill=SHADOW + (int(strength * (t ** 1.6)),))
    return Image.alpha_composite(img.convert("RGBA"), layer)


def hud(draw, f_mono, f_small):
    s = 1
    inset, L, t = 42, 54, 2

    for (cx, cy, dx, dy) in ((inset, inset, 1, 1), (W - inset, inset, -1, 1),
                             (inset, H - inset, 1, -1), (W - inset, H - inset, -1, -1)):
        draw.line((cx, cy, cx + dx * L, cy), fill=CYAN_FAINT, width=t)
        draw.line((cx, cy, cx, cy + dy * L), fill=CYAN_FAINT, width=t)

    # Left readouts
    for i, line in enumerate(["THRUST 92%", "ENG 1: ACTIVE", "ENG 2: ACTIVE"]):
        draw.text((74, 74 + i * 30), line, font=f_mono, fill=CYAN_DIM)

    # Right readouts, right-aligned
    for i, line in enumerate(["LAPS 03/05", "POS: 02", "FUEL: 81%"]):
        w = draw.textlength(line, font=f_mono)
        draw.text((W - 74 - w, 74 + i * 30), line, font=f_mono, fill=CYAN_DIM)

    # Side meters
    for side in (0, 1):
        x = 74 if side == 0 else W - 86
        for i in range(4):
            y = H // 2 - 70 + i * 36
            draw.rectangle((x, y, x + 12, y + 22), outline=CYAN_FAINT, width=2)
            if i < 3 - side:
                draw.rectangle((x + 3, y + 3, x + 9, y + 19), fill=CYAN_FAINT)

    # Bottom status
    draw.text((74, H - 104), "BOT L: VECTOR [312.18]", font=f_mono, fill=CYAN_DIM)
    draw.text((74, H - 74), "STATUS: NOMINAL", font=f_mono, fill=CYAN_DIM)

    label = "SHIELD [88%]"
    w = draw.textlength(label, font=f_mono)
    draw.text((W - 74 - w, H - 104), label, font=f_mono, fill=CYAN_DIM)
    bar_x0, bar_x1 = W - 74 - 230, W - 74
    draw.rectangle((bar_x0, H - 72, bar_x1, H - 60), outline=CYAN_FAINT, width=2)
    draw.rectangle((bar_x0 + 3, H - 69, bar_x0 + 3 + int((bar_x1 - bar_x0 - 6) * 0.88),
                    H - 63), fill=CYAN_DIM)


def render(source):
    art = Image.open(source).convert("RGB")
    img = cover(art, (W, H))
    img = scrim(img)

    f_title = load(TITLE_FONTS, 132)
    f_sub = load(BODY_FONTS, 38)
    f_game = load(TITLE_FONTS, 62)
    f_mono = load(MONO_FONTS, 22)
    f_small = load(MONO_FONTS, 18)

    cx = W // 2

    def draw_text(d):
        tracked(d, (cx, 96), "LOUD AND CLEAR", f_title, CYAN + (255,),
                tracking=6, anchor_centre=True)
        tracked(d, (cx, 252), "DIALOGUE YOU CAN ACTUALLY HEAR", f_sub,
                CYAN_DIM + (255,), tracking=7, anchor_centre=True)

    # Glow: the same text blurred underneath, plus a hard dark shadow so it
    # survives the bright sky behind it.
    glow = text_layer((W, H), draw_text).filter(ImageFilter.GaussianBlur(18))
    shadow = text_layer((W, H), lambda d: (
        tracked(d, (cx + 3, 99), "LOUD AND CLEAR", f_title, SHADOW + (190,),
                tracking=6, anchor_centre=True),
        tracked(d, (cx + 2, 254), "DIALOGUE YOU CAN ACTUALLY HEAR", f_sub,
                SHADOW + (170,), tracking=7, anchor_centre=True),
    )).filter(ImageFilter.GaussianBlur(5))

    img = Image.alpha_composite(img, shadow)
    img = Image.alpha_composite(img, glow)
    img = Image.alpha_composite(img, text_layer((W, H), draw_text))

    # Game name low and centred, warm against all the cyan.
    def draw_game(d):
        tracked(d, (cx, H - 212), "STAR WARS: GALACTIC RACER", f_game,
                WARM + (255,), tracking=5, anchor_centre=True)

    gshadow = text_layer((W, H), lambda d: tracked(
        d, (cx + 2, H - 209), "STAR WARS: GALACTIC RACER", f_game,
        SHADOW + (200,), tracking=5, anchor_centre=True)
    ).filter(ImageFilter.GaussianBlur(6))
    img = Image.alpha_composite(img, gshadow)
    img = Image.alpha_composite(img, text_layer((W, H), draw_game))

    hud_layer = text_layer((W, H), lambda d: hud(d, f_mono, f_small))
    img = Image.alpha_composite(img, hud_layer)

    return img.convert("RGB")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source")
    ap.add_argument("--out", default="docs/main-1920x1080.png")
    args = ap.parse_args()
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    img = render(args.source)
    img.save(args.out, "PNG", optimize=True)
    print("wrote %s  %dx%d  %.0f KB"
          % (args.out, img.width, img.height, os.path.getsize(args.out) / 1024))
    return 0


if __name__ == "__main__":
    sys.exit(main())
