#!/usr/bin/env python3
"""Draw the Composer icons for the three Hue drivers.

Bridge: a Hue Bridge Pro seen from above, a flat, matte near-black rounded
rectangle (about 4:3, wider than tall) with a lighter grey edge so the shape
reads on Composer's white list view and its light-grey tree, and a short row
of small bright status LEDs near the front edge.

Light: a Hue Tap dial remote, a light-grey portrait wall plate (about 3:4)
with a circular dial on it: a thin darker ring, a flat disc divided into four
quadrants by a thin cross, and tiny dot clusters (1, 2, 3, 4 dots) marking
the quadrants. At 16 px the dots are dropped (they do not stay legible).

Scene: the same remote with a rainbow ring (hue sweep) instead of the grey
ring and the quadrant dots tinted in four colours.

No logos, text or trademarks; the shapes are the hint.

Each icon is drawn at 8x and downsampled with LANCZOS; the LEDs are placed
on the target pixel grid so they stay crisp at 16 px. Composer wants 16x16
and 32x32 PNGs at 96 DPI (Fundamentals 19, "Driver Icon Management").

Run from the repo root with no arguments:

    python3 tools/make_icons.py

Writes:
    src/hue_bridge/www/images/devices_sm/hue_bridge_pro_16.png
    src/hue_bridge/www/images/devices_lg/hue_bridge_pro_32.png
    src/hue_light/www/images/devices_sm/hue_light_16.png
    src/hue_light/www/images/devices_lg/hue_light_32.png
    src/hue_scene/www/images/devices_sm/hue_scene_16.png
    src/hue_scene/www/images/devices_lg/hue_scene_32.png

Deterministic: no randomness, no timestamps in the files.
"""

import colorsys
import math
import os
import sys

from PIL import Image, ImageDraw

SCALE = 8
DPI = (96, 96)

# Colours (RGBA).
EDGE = (138, 138, 142, 255)        # lighter grey bevel/edge
EDGE_LIGHT = (176, 176, 180, 255)  # top-edge highlight
BODY = (28, 28, 31, 255)           # matte near-black top surface
BODY_SHEEN = (44, 44, 48, 255)     # faint lighter band near the top
LED_WHITE = (236, 244, 255, 255)   # status LEDs (cool white / blue-white)
LED_BLUE = (120, 190, 255, 255)
LED_GLOW = (120, 190, 255, 90)     # soft halo around each LED (32 px only)

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_SM = os.path.join(REPO_ROOT, "src", "hue_bridge", "www", "images",
                      "devices_sm", "hue_bridge_pro_16.png")
OUT_LG = os.path.join(REPO_ROOT, "src", "hue_bridge", "www", "images",
                      "devices_lg", "hue_bridge_pro_32.png")


def _out(driver, name, size):
    sub = "devices_sm" if size == 16 else "devices_lg"
    return os.path.join(REPO_ROOT, "src", driver, "www", "images", sub,
                        "%s_%d.png" % (name, size))


# Remote (Tap dial) colours.
PLATE = (168, 168, 170, 255)        # light-grey matte plate (#a8a8aa)
PLATE_EDGE = (132, 132, 136, 255)   # darker outline so it reads on grey
PLATE_SHADOW = (0, 0, 0, 70)        # soft drop shadow, right and bottom
RING = (120, 120, 124, 255)         # thin dial ring, slightly darker
DISC = (176, 176, 178, 255)         # flat dial disc, same family as plate
CROSS = (128, 128, 132, 255)        # quadrant divider lines (32 px)
CROSS_SM = (104, 104, 108, 255)     # darker divider so it survives 16 px
DOT = (82, 82, 86, 255)             # grey quadrant dots (light icon)
SCENE_DOTS = [                      # quadrant dots for the scene icon
    (242, 92, 84, 255),             # top-left: coral red
    (250, 190, 60, 255),            # top-right: amber
    (72, 190, 120, 255),            # bottom-left: green
    (80, 140, 245, 255),            # bottom-right: blue
]


def _box(x0, y0, x1, y1):
    """Target-pixel box (inclusive edges in pixel units) scaled to the
    supersampled canvas. x1/y1 are exclusive pixel edges, so a 1-pixel dot
    at (5, 5) is _box(5, 5, 6, 6)."""
    return (x0 * SCALE, y0 * SCALE, x1 * SCALE - 1, y1 * SCALE - 1)


def draw_icon(size, body, radius, edge_px, leds, led_px, glow):
    """Render one icon.

    size     target width/height in pixels
    body     (x0, y0, x1, y1) of the device outline in target pixels
    radius   corner radius in target pixels
    edge_px  width of the grey edge in target pixels
    leds     list of (x, y, colour) top-left target pixel of each LED
    led_px   LED size in target pixels
    glow     halo radius in target pixels around each LED (0 = none)
    """
    big = size * SCALE
    img = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    x0, y0, x1, y1 = body

    # Grey edge: the full outline.
    d.rounded_rectangle(_box(x0, y0, x1, y1), radius=radius * SCALE, fill=EDGE)

    # Slightly lighter highlight along the top edge, so the edge reads as a
    # bevel rather than a flat frame.
    hl = _box(x0, y0, x1, y0 + edge_px * 1.5)
    hl_img = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(hl_img).rounded_rectangle(
        _box(x0, y0, x1, y1), radius=radius * SCALE, fill=EDGE_LIGHT)
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rectangle(hl, fill=255)
    img.paste(hl_img, (0, 0), mask)
    d = ImageDraw.Draw(img)

    # Near-black top surface inset by the edge width.
    e = edge_px
    inner_r = max(radius - e, 0.5) * SCALE
    d.rounded_rectangle(_box(x0 + e, y0 + e, x1 - e, y1 - e),
                        radius=inner_r, fill=BODY)

    # A faint sheen band in the upper third of the surface: keeps the body
    # from reading as a solid blob and suggests a matte plastic top.
    band_h = (y1 - y0 - 2 * e) * 0.28
    sheen_img = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(sheen_img).rounded_rectangle(
        _box(x0 + e, y0 + e, x1 - e, y1 - e), radius=inner_r, fill=BODY_SHEEN)
    sheen_mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(sheen_mask).rectangle(
        _box(x0 + e, y0 + e, x1 - e, y0 + e + band_h), fill=255)
    img.paste(sheen_img, (0, 0), sheen_mask)
    d = ImageDraw.Draw(img)

    # Status LEDs on the pixel grid.
    if glow:
        glow_layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
        gd = ImageDraw.Draw(glow_layer)
        for lx, ly, _colour in leds:
            gd.ellipse(_box(lx - glow, ly - glow, lx + led_px + glow,
                            ly + led_px + glow), fill=LED_GLOW)
        img = Image.alpha_composite(img, glow_layer)
        d = ImageDraw.Draw(img)
    for lx, ly, colour in leds:
        if led_px > 1:
            d.rounded_rectangle(_box(lx, ly, lx + led_px, ly + led_px),
                                radius=SCALE * led_px * 0.35, fill=colour)

    out = img.resize((size, size), Image.Resampling.LANCZOS)
    if led_px <= 1:
        # A 1-px dot loses brightness under the LANCZOS kernel; stamp the
        # pixel after the downsample so it stays crisp at 16 px.
        for lx, ly, colour in leds:
            out.putpixel((int(lx), int(ly)), colour)
    return out


def icon_16():
    # Body 14 x 11 (about 4:3), centred: x 1..15, y 2.5..13.5.
    body = (1, 2.5, 15, 13.5)
    # Three 1-px LEDs one pixel above the lower edge.
    leds = [(5, 11, LED_WHITE), (7, 11, LED_BLUE), (9, 11, LED_WHITE)]
    return draw_icon(16, body, radius=2.5, edge_px=1, leds=leds, led_px=1,
                     glow=0)


def icon_32():
    # Body 28 x 21 (4:3), centred: x 2..30, y 5.5..26.5.
    body = (2, 5.5, 30, 26.5)
    # Three 2-px LEDs with a soft halo, two pixels above the lower edge.
    leds = [(10, 22, LED_WHITE), (15, 22, LED_BLUE), (20, 22, LED_WHITE)]
    return draw_icon(32, body, radius=4.5, edge_px=1.25, leds=leds, led_px=2,
                     glow=1)


def _rainbow_ring(size, cx, cy, r_out, r_in):
    """A hue sweep around a circle on the supersampled canvas, saturated
    but not neon. Returns an RGBA layer."""
    big = size * SCALE
    layer = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    px = layer.load()
    cxs, cys = cx * SCALE, cy * SCALE
    ro, ri = r_out * SCALE, r_in * SCALE
    for y in range(int(cys - ro) - 1, int(cys + ro) + 2):
        for x in range(int(cxs - ro) - 1, int(cxs + ro) + 2):
            dx, dy = x + 0.5 - cxs, y + 0.5 - cys
            dist = math.hypot(dx, dy)
            if ri <= dist < ro:
                hue = (math.atan2(dy, dx) / (2 * math.pi) + 0.5) % 1.0
                rr, gg, bb = colorsys.hsv_to_rgb(hue, 0.78, 0.92)
                px[x, y] = (int(rr * 255), int(gg * 255), int(bb * 255), 255)
    return layer


def draw_remote(size, plate, radius, shadow_px, dial_r, ring_px, cross_px,
                dots, dot_px, dot_colours, rainbow, cross_colour=CROSS):
    """Render the Tap-dial remote.

    plate        (x0, y0, x1, y1) of the wall plate in target pixels
    radius       plate corner radius in target pixels
    shadow_px    drop-shadow offset (right/bottom) in target pixels
    dial_r       outer radius of the dial ring, target pixels
    ring_px      ring thickness, target pixels
    cross_px     thickness of the quadrant lines, target pixels
    dots         list of four lists of (x, y) dot centres (target pixels);
                 empty lists draw nothing
    dot_px       dot diameter in target pixels
    dot_colours  one RGBA per quadrant
    rainbow      True for the hue-sweep ring
    """
    big = size * SCALE
    img = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    x0, y0, x1, y1 = plate
    cx, cy = (x0 + x1) / 2.0, (y0 + y1) / 2.0

    # Drop shadow offset right and bottom.
    if shadow_px:
        sh = Image.new("RGBA", img.size, (0, 0, 0, 0))
        ImageDraw.Draw(sh).rounded_rectangle(
            _box(x0 + shadow_px, y0 + shadow_px, x1 + shadow_px,
                 y1 + shadow_px), radius=radius * SCALE, fill=PLATE_SHADOW)
        img = Image.alpha_composite(img, sh)

    d = ImageDraw.Draw(img)
    # Plate with a thin darker outline.
    d.rounded_rectangle(_box(x0, y0, x1, y1), radius=radius * SCALE,
                        fill=PLATE_EDGE)
    e = 0.75 if size >= 32 else 0.5
    d.rounded_rectangle(_box(x0 + e, y0 + e, x1 - e, y1 - e),
                        radius=max(radius - e, 0.5) * SCALE, fill=PLATE)

    # Dial: ring then disc.
    def circle(r, fill):
        d.ellipse(_box(cx - r, cy - r, cx + r, cy + r), fill=fill)

    if rainbow:
        img = Image.alpha_composite(
            img, _rainbow_ring(size, cx, cy, dial_r, dial_r - ring_px))
        d = ImageDraw.Draw(img)
    else:
        circle(dial_r, RING)
    circle(dial_r - ring_px, DISC)

    # Quadrant cross, clipped to the disc.
    r_in = dial_r - ring_px
    half = cross_px / 2.0
    cross = Image.new("RGBA", img.size, (0, 0, 0, 0))
    cd = ImageDraw.Draw(cross)
    cd.rectangle(_box(cx - half, cy - r_in, cx + half, cy + r_in),
                 fill=cross_colour)
    cd.rectangle(_box(cx - r_in, cy - half, cx + r_in, cy + half),
                 fill=cross_colour)
    clip = Image.new("L", img.size, 0)
    ImageDraw.Draw(clip).ellipse(
        _box(cx - r_in, cy - r_in, cx + r_in, cy + r_in), fill=255)
    img.paste(cross, (0, 0), Image.composite(
        cross.getchannel("A"), Image.new("L", img.size, 0), clip))
    d = ImageDraw.Draw(img)

    # Dot clusters, one per quadrant.
    rd = dot_px / 2.0
    for quadrant, colour in zip(dots, dot_colours):
        for dx, dy in quadrant:
            d.ellipse(_box(dx - rd, dy - rd, dx + rd, dy + rd), fill=colour)

    return img.resize((size, size), Image.Resampling.LANCZOS)


def remote_16(rainbow):
    # Plate 11 x 14 (about 3:4), centred: x 2.5..13.5, y 1..15; the shadow
    # takes the spare half pixel on the right/bottom.
    plate = (2.5, 1, 13.5, 15)
    # Dial radius 4.5 around the plate centre (8, 8): ring 1 px, cross 1 px.
    # Dots are dropped at this size; they would not survive the downsample.
    return draw_remote(16, plate, radius=2, shadow_px=0.5, dial_r=4.5,
                       ring_px=1, cross_px=1, dots=[[], [], [], []],
                       dot_px=0, dot_colours=SCENE_DOTS if rainbow else [DOT] * 4,
                       rainbow=rainbow, cross_colour=CROSS_SM)


def remote_32(rainbow):
    # Plate 22 x 29, centred: x 5..27, y 1..30.
    plate = (5, 1, 27, 30)
    cx, cy = 16.0, 15.5
    # Dial radius 10, ring 1.25, cross 1. Dot clusters sit inside each
    # quadrant: 1 top-left, 2 top-right, 3 bottom-left, 4 bottom-right.
    o = 4.4   # quadrant centre offset from the dial centre
    s = 2.0   # spacing between dots in a cluster
    tl = (cx - o, cy - o)
    tr = (cx + o, cy - o)
    bl = (cx - o, cy + o)
    br = (cx + o, cy + o)
    dots = [
        [tl],
        [(tr[0] - s / 2, tr[1]), (tr[0] + s / 2, tr[1])],
        [(bl[0] - s, bl[1] + s / 2), (bl[0], bl[1] - s / 2),
         (bl[0] + s, bl[1] + s / 2)],
        [(br[0] - s / 2, br[1] - s / 2), (br[0] + s / 2, br[1] - s / 2),
         (br[0] - s / 2, br[1] + s / 2), (br[0] + s / 2, br[1] + s / 2)],
    ]
    return draw_remote(32, plate, radius=3.5, shadow_px=1, dial_r=10,
                       ring_px=1.25, cross_px=1, dots=dots, dot_px=1.8,
                       dot_colours=SCENE_DOTS if rainbow else [DOT] * 4,
                       rainbow=rainbow)


def save(img, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path, format="PNG", dpi=DPI, optimize=True)
    print("wrote %s (%dx%d, %s, dpi=%s)" % (
        os.path.relpath(path, REPO_ROOT), img.width, img.height, img.mode,
        DPI))


def main():
    save(icon_16(), OUT_SM)
    save(icon_32(), OUT_LG)
    save(remote_16(False), _out("hue_light", "hue_light", 16))
    save(remote_32(False), _out("hue_light", "hue_light", 32))
    save(remote_16(True), _out("hue_scene", "hue_scene", 16))
    save(remote_32(True), _out("hue_scene", "hue_scene", 32))
    return 0


if __name__ == "__main__":
    sys.exit(main())
