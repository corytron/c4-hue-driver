#!/usr/bin/env python3
"""Draw the Composer icons for the three Hue drivers.

Composer shows a driver's icon at 16 px (the project tree and the Items
pane) and 32 px (List View), 96 DPI (Fundamentals 19, "Driver Icon
Management"). Both are too small for line art to look like anything, so
every icon is rendered as a lit, shaded object on a 512 px master canvas
(32x the 16 px icon, 16x the 32 px icon) and then downsampled:

  * a height map of the object (plate, remote, buttons, grooves, body)
    drives a directional light from the top-left: bevelled edges get a
    highlight on the lit side and a shadow on the far side, button pillows
    and grooves shade the same way, glossy parts get a specular term and
    dips get ambient occlusion;
  * every surface has a gradient albedo, matte plastic gets a touch of
    grain, and the object casts a soft drop shadow onto the transparent
    background;
  * the geometry is laid out in whole target pixels (plate outline, remote
    outline, groove rows, LED cells) so the strongest edges land on the
    pixel grid after the LANCZOS downsample, and each size gets its own
    unsharp mask and contrast tuning so the 16 px version still reads.

Designs (no logos, text or trademarks; the shapes are the hint):

Hue Light  the Philips Hue dimmer switch from the owner's photo: a white
           portrait wall plate with softly rounded corners and a thin
           bevel; inset in it a tall rounded rocker remote, proud of the
           plate, split by three grooves into four stacked buttons marked
           "I", a large sun, a small sun and "O".
Hue Scene  the same switch lit for a scene: each button glows a different
           colour from within and the glow bleeds out onto the plate.
Hue Bridge the Hue Bridge Pro from above: a flat near-black, slightly
           glossy rounded rectangle with a sheen band, a lighter rim and
           three small status LEDs (white, blue, white) with soft halos
           near the front edge.

Run from the repo root with no arguments:

    python3 tools/make_icons.py

Writes:
    src/hue_bridge/www/images/devices_sm/hue_bridge_pro_16.png
    src/hue_bridge/www/images/devices_lg/hue_bridge_pro_32.png
    src/hue_light/www/images/devices_sm/hue_light_16.png
    src/hue_light/www/images/devices_lg/hue_light_32.png
    src/hue_scene/www/images/devices_sm/hue_scene_16.png
    src/hue_scene/www/images/devices_lg/hue_scene_32.png

    python3 tools/make_icons.py --inspect DIR

also writes the 512 px masters (icons_v2_master_<name>.png) and a sheet
(icons_v2_sheet.png) showing each icon at 1x, 4x and 8x on white and on
Composer's #f0f0f0, for eyeballing.

Pillow only (12.x) plus the standard library. Deterministic: the grain
comes from a seeded generator, and the PNGs carry no timestamps.
"""

import colorsys
import math
import os
import random
import sys

from PIL import Image, ImageChops, ImageDraw, ImageEnhance, ImageFilter

MASTER = 512
DPI = (96, 96)

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def out_path(driver, name, size):
    sub = "devices_sm" if size == 16 else "devices_lg"
    return os.path.join(REPO_ROOT, "src", driver, "www", "images", sub,
                        "%s_%d.png" % (name, size))


# --------------------------------------------------------------------------
# Low-level helpers. Everything is drawn on a MASTER x MASTER canvas; S is
# the number of master pixels per target pixel, and all geometry arguments
# are in target pixels so the same drawing code serves both sizes.
# --------------------------------------------------------------------------

def _clamp(v):
    return 0 if v < 0 else 255 if v > 255 else int(v)


def _box(S, x0, y0, x1, y1):
    """Target-pixel box (x1/y1 exclusive) as an inclusive master box."""
    return (round(x0 * S), round(y0 * S), round(x1 * S) - 1, round(y1 * S) - 1)


def rrect(S, box, radius, value=255):
    """L mask of a rounded rectangle; box/radius in target pixels."""
    m = Image.new("L", (MASTER, MASTER), 0)
    ImageDraw.Draw(m).rounded_rectangle(_box(S, *box), radius=radius * S,
                                        fill=value)
    return m


def rect(S, box, value=255):
    m = Image.new("L", (MASTER, MASTER), 0)
    ImageDraw.Draw(m).rectangle(_box(S, *box), fill=value)
    return m


def blur(img, r_px, S):
    if r_px <= 0:
        return img
    return img.filter(ImageFilter.GaussianBlur(r_px * S))


def shift(img, dx_px, dy_px, S):
    return ImageChops.offset(img, round(dx_px * S), round(dy_px * S))


def solid(colour):
    return Image.new("RGBA", (MASTER, MASTER), colour)


def layer(mask, colour, alpha=1.0):
    """RGBA layer of one colour whose alpha is the mask times alpha."""
    out = Image.new("RGBA", (MASTER, MASTER), colour[:3] + (0,))
    if alpha != 1.0:
        mask = mask.point([_clamp(v * alpha) for v in range(256)])
    out.putalpha(mask)
    return out


def over(dst, src):
    return Image.alpha_composite(dst, src)


def lin_grad(S, p0, p1):
    """L gradient, 0 at target point p0 rising to 255 at p1, clipped."""
    x0, y0 = p0[0] * S, p0[1] * S
    dx, dy = (p1[0] - p0[0]) * S, (p1[1] - p0[1]) * S
    n = dx * dx + dy * dy
    kx, ky = dx / n, dy / n
    # Each axis is stored offset by 128 so a negative share survives the
    # 8-bit image; add() removes both offsets and clips the sum to 0..255.
    xs = [_clamp(128 + 255 * kx * (x - x0)) for x in range(MASTER)]
    ys = [_clamp(128 + 255 * ky * (y - y0)) for y in range(MASTER)]
    gx = Image.new("L", (MASTER, 1))
    gx.putdata(xs)
    gy = Image.new("L", (1, MASTER))
    gy.putdata(ys)
    return ImageChops.add(gx.resize((MASTER, MASTER), Image.Resampling.NEAREST),
                          gy.resize((MASTER, MASTER), Image.Resampling.NEAREST),
                          1.0, -256)


def radial(S, centre, r_px, inner=0.0):
    """L: 255 at the centre falling to 0 at radius r (smoothstep)."""
    cx, cy = centre[0] * S, centre[1] * S
    r = r_px * S
    ri = inner * S
    data = []
    for y in range(MASTER):
        dy = y + 0.5 - cy
        for x in range(MASTER):
            d = math.hypot(x + 0.5 - cx, dy)
            if d <= ri:
                data.append(255)
            elif d >= r:
                data.append(0)
            else:
                t = (d - ri) / (r - ri)
                data.append(int(255 * (1 - t * t * (3 - 2 * t))))
    m = Image.new("L", (MASTER, MASTER))
    m.putdata(data)
    return m


def grad_fill(mask, c0, c1, S, p0, p1):
    """RGBA: colour c0 at p0 shading to c1 at p1, cut out by mask."""
    g = lin_grad(S, p0, p1)
    col = Image.composite(solid(c1 + (255,)), solid(c0 + (255,)), g)
    col.putalpha(mask)
    return col


def modulate(img, signed, gain_hi, gain_lo, mask=None):
    """Lighten where signed > 128 and darken where < 128 (RGB only)."""
    hi = signed.point([_clamp((v - 128) * gain_hi) for v in range(256)])
    lo = signed.point([_clamp((128 - v) * gain_lo) for v in range(256)])
    if mask is not None:
        hi = ImageChops.multiply(hi, mask)
        lo = ImageChops.multiply(lo, mask)
    a = img.getchannel("A")
    white = solid((255, 255, 255, 0))
    white.putalpha(a)
    black = solid((0, 0, 0, 0))
    black.putalpha(a)
    out = Image.composite(white, img, hi)
    return Image.composite(black, out, lo)


def light_map(H, S, d_px):
    """Directional derivative of the height map along the light (top-left
    to bottom-right), centred on 128: >128 faces the light."""
    d = max(1, round(d_px * S))
    return ImageChops.subtract(ImageChops.offset(H, -d, -d),
                               ImageChops.offset(H, d, d), 1.0, 128)


def shade(img, H, S, d_px=0.2, gain_hi=1.6, gain_lo=1.6, mask=None):
    return modulate(img, light_map(H, S, d_px), gain_hi, gain_lo, mask)


def specular(img, H, S, d_px, strength, gloss_mask, power=3, soften=0.0):
    L = light_map(H, S, d_px)
    lut = [_clamp(255 * strength * max(0.0, (v - 128) / 127.0) ** power)
           for v in range(256)]
    spec = ImageChops.multiply(L.point(lut), gloss_mask)
    spec = blur(spec, soften, S)
    white = solid((255, 255, 255, 0))
    white.putalpha(img.getchannel("A"))
    return Image.composite(white, img, spec)


def occlusion(img, H, S, r_px, gain, mask=None):
    """Darken dips: where the blurred height is above the local height."""
    ao = ImageChops.subtract(blur(H, r_px, S), H, 1.0, 128)
    return modulate(img, ao, 0.0, gain, mask)


def grain(img, S, amount, seed, mask=None):
    """Matte-plastic grain, seeded so the output never changes."""
    rng = random.Random(seed)
    n = MASTER * MASTER
    noise = Image.frombytes("L", (MASTER, MASTER),
                            bytes(rng.getrandbits(8) for _ in range(n)))
    noise = blur(noise, 0.03, S)
    return modulate(img, noise, amount, amount, mask)


def drop_shadow(mask, S, dx, dy, r, alpha, colour=(0, 0, 0)):
    sh = blur(shift(mask, dx, dy, S), r, S)
    return layer(sh, colour + (0,), alpha)


def stroke(S, box, radius, width_px, c0, c1, alpha, p0, p1):
    """A gradient-coloured outline, c0 at p0 to c1 at p1, drawn just inside
    the rounded box (width in target pixels)."""
    outer = rrect(S, box, radius)
    inner = rrect(S, (box[0] + width_px, box[1] + width_px,
                      box[2] - width_px, box[3] - width_px),
                  max(radius - width_px, 0.1))
    ring = ImageChops.subtract(outer, inner)
    col = grad_fill(ring, c0, c1, S, p0, p1)
    if alpha != 1.0:
        col.putalpha(ring.point([_clamp(v * alpha) for v in range(256)]))
    return col


def add_height(H, mask, amount, r_px, S):
    """Add (or subtract) a blurred mask to the height map."""
    m = blur(mask, r_px, S) if r_px else mask
    if amount >= 0:
        return ImageChops.add(H, m.point([_clamp(v * amount / 255.0)
                                          for v in range(256)]))
    return ImageChops.subtract(H, m.point([_clamp(v * -amount / 255.0)
                                           for v in range(256)]))


def hsv(h, s, v):
    r, g, b = colorsys.hsv_to_rgb(h % 1.0, s, v)
    return (int(r * 255 + 0.5), int(g * 255 + 0.5), int(b * 255 + 0.5))


# --------------------------------------------------------------------------
# Finishing: master -> target size.
# --------------------------------------------------------------------------

def finish(master, size, sharpen, contrast, gamma):
    out = master.resize((size, size), Image.Resampling.LANCZOS)
    if sharpen:
        radius, percent = sharpen
        # Sharpen premultiplied so transparent neighbours (black, alpha 0)
        # cannot ring dark fringes into the edge pixels.
        out = out.convert("RGBa").filter(
            ImageFilter.UnsharpMask(radius, percent, 0)).convert("RGBA")
    if contrast != 1.0:
        out = ImageEnhance.Contrast(out).enhance(contrast)
    if gamma != 1.0:
        lut = [_clamp(255 * (v / 255.0) ** gamma + 0.5) for v in range(256)]
        r, g, b, a = out.split()
        out = Image.merge("RGBA", (r.point(lut), g.point(lut), b.point(lut), a))
    return out


# --------------------------------------------------------------------------
# The dimmer switch (Hue Light, and Hue Scene with the colour flair).
# --------------------------------------------------------------------------

# Albedo. The plate is white in the photo; on Composer's white and light-grey
# backgrounds it needs a visible rim and a drop shadow to read, so the plate
# sits a touch below white and the remote a touch above it.
PLATE_TL, PLATE_BR = (251, 251, 248), (229, 229, 225)
REMOTE_TL, REMOTE_BR = (255, 255, 253), (240, 240, 237)
GROOVE = (172, 172, 168)
GLYPH = (108, 108, 112)
# The rims are the rounded edges themselves: lit on the top-left, in shadow
# on the bottom-right. The dark side plus the drop shadow give the white
# plate its silhouette on Composer's white and light-grey backgrounds.
REMOTE_RIM_TL, REMOTE_RIM_BR = (214, 214, 218), (140, 140, 144)

# Scene: the four buttons glow in a hue sweep (top to bottom).
SCENE_HUES = [0.07, 0.30, 0.55, 0.80]   # amber, green, azure, violet


def dimmer_geometry(size):
    """Whole-pixel layout per size. Button rows are (y0, y1) exclusive."""
    if size == 32:
        return dict(
            plate=(5, 1, 26, 30), plate_r=2.0,
            remote=(11, 5, 20, 26), remote_r=1.4,
            grooves=[10, 15, 20],
            buttons=[(5, 10), (11, 15), (16, 20), (21, 26)],
            cx=15.5,
            shadow=(0.9, 1.2, 1.1, 0.45),
            remote_shadow=(0.45, 0.7, 0.55, 0.42),
            rim=1.0, rim_tl=(200, 200, 204), rim_br=(98, 98, 102),
            remote_rim=0.5, remote_rim_alpha=0.8, groove_alpha=0.8,
            glyphs=True,
        )
    return dict(
        plate=(3, 0, 13, 15), plate_r=1.5,
        remote=(5, 2, 11, 13), remote_r=1.0,
        grooves=[4, 7, 10],
        buttons=[(2, 4), (5, 7), (8, 10), (11, 13)],
        cx=8.0,
        shadow=(0.8, 1.0, 0.9, 0.5),
        remote_shadow=(0.4, 0.6, 0.45, 0.45),
        rim=1.0, rim_tl=(178, 178, 182), rim_br=(96, 96, 100),
        remote_rim=0.4, remote_rim_alpha=0.6, groove_alpha=1.0,
        glyphs=False,
    )


def draw_glyphs(S, g):
    """L mask of the I, big sun, small sun and O marks, one per button."""
    glyph = Image.new("L", (MASTER, MASTER), 0)
    d = ImageDraw.Draw(glyph)
    cx = g["cx"]
    rows = g["buttons"]

    # "I": a 1 px bar, three pixels tall, in the top button.
    y0, y1 = rows[0]
    cy = (y0 + y1) / 2.0
    d.rounded_rectangle(_box(S, cx - 0.5, cy - 1.5, cx + 0.5, cy + 1.5),
                        radius=0.2 * S, fill=255)

    def sun(cy, disc_r, ray_in, ray_out, ray_w, rays=8):
        d.ellipse(_box(S, cx - disc_r, cy - disc_r, cx + disc_r, cy + disc_r),
                  fill=255)
        for i in range(rays):
            a = 2 * math.pi * i / rays
            d.line([((cx + math.cos(a) * ray_in) * S,
                     (cy + math.sin(a) * ray_in) * S),
                    ((cx + math.cos(a) * ray_out) * S,
                     (cy + math.sin(a) * ray_out) * S)],
                   fill=255, width=max(1, round(ray_w * S)))

    y0, y1 = rows[1]
    sun((y0 + y1) / 2.0, disc_r=0.62, ray_in=1.0, ray_out=1.75, ray_w=0.42)
    y0, y1 = rows[2]
    sun((y0 + y1) / 2.0, disc_r=0.46, ray_in=0.8, ray_out=1.35, ray_w=0.36)

    # "O": a ring in the bottom button.
    y0, y1 = rows[3]
    cy = (y0 + y1) / 2.0
    r = 1.45
    d.ellipse(_box(S, cx - r, cy - r, cx + r, cy + r), outline=255,
              width=max(1, round(0.6 * S)))
    return glyph


def render_dimmer(size, scene):
    S = MASTER // size
    g = dimmer_geometry(size)
    px0, py0, px1, py1 = g["plate"]
    rx0, ry0, rx1, ry1 = g["remote"]
    far = (px1 + 2, py1 + 2)            # the gradient's dark end
    near = (px0 - 2, py0 - 2)           # the lit end

    plate_m = rrect(S, g["plate"], g["plate_r"])
    remote_m = rrect(S, g["remote"], g["remote_r"])
    groove_m = Image.new("L", (MASTER, MASTER), 0)
    for gy in g["grooves"]:
        groove_m = ImageChops.lighter(
            groove_m, rect(S, (rx0 + 0.35, gy, rx1 - 0.35, gy + 1)))
    groove_m = ImageChops.multiply(groove_m, remote_m)
    button_m = ImageChops.subtract(remote_m, groove_m)

    # ---- height map ----
    H = Image.new("L", (MASTER, MASTER), 0)
    H = add_height(H, plate_m, 140, 0.6, S)       # plate with a soft bevel
    H = add_height(H, remote_m, 60, 0.3, S)       # remote proud of the plate
    for y0, y1 in g["buttons"]:                   # gentle pillow per button
        bm = ImageChops.multiply(rrect(S, (rx0, y0, rx1, y1), 0.8), remote_m)
        H = add_height(H, bm, 14, 1.2, S)
    H = add_height(H, groove_m, -34, 0.18, S)     # grooves cut in

    # ---- albedo ----
    img = solid((0, 0, 0, 0))
    sdx, sdy, sr, sa = g["shadow"]
    img = over(img, drop_shadow(plate_m, S, sdx, sdy, sr, sa))
    img = over(img, drop_shadow(plate_m, S, 0.15, 0.25, 0.25, 0.35))
    img = over(img, grad_fill(plate_m, PLATE_TL, PLATE_BR, S, near, far))
    img = grain(img, S, 0.09, seed=11, mask=plate_m)

    if scene:
        img = over(img, scene_glow(S, g, plate_m, remote_m))

    # Remote shadow and contact occlusion onto the plate.
    rdx, rdy, rr, ra = g["remote_shadow"]
    under = ImageChops.subtract(plate_m, remote_m)
    sh = drop_shadow(remote_m, S, rdx, rdy, rr, ra)
    sh.putalpha(ImageChops.multiply(sh.getchannel("A"), under))
    img = over(img, sh)
    ao = drop_shadow(remote_m, S, 0, 0, 0.3, 0.3)
    ao.putalpha(ImageChops.multiply(ao.getchannel("A"), under))
    img = over(img, ao)

    # Remote body, grooves and glyphs.
    img = over(img, grad_fill(remote_m, REMOTE_TL, REMOTE_BR, S, near, far))
    img = grain(img, S, 0.05, seed=23, mask=remote_m)
    img = over(img, layer(groove_m, GROOVE + (0,), g["groove_alpha"]))
    if scene:
        img = over(img, scene_buttons(S, g, button_m))
    if g["glyphs"]:
        glyph = draw_glyphs(S, g)
        colour = (60, 60, 64) if scene else GLYPH
        img = over(img, layer(glyph, colour + (0,), 0.55 if scene else 0.9))
        H = add_height(H, glyph, -6, 0.05, S)

    # ---- lighting ----
    obj = plate_m
    img = shade(img, H, S, d_px=0.22, gain_hi=1.4, gain_lo=1.5, mask=obj)
    img = occlusion(img, H, S, r_px=0.6, gain=1.1, mask=obj)
    img = specular(img, H, S, d_px=0.3, strength=0.9, gloss_mask=remote_m,
                   power=2.5, soften=0.08)
    # A soft broad highlight across the top of the remote: glossy plastic
    # reflecting the room.
    hot = ImageChops.multiply(
        radial(S, ((rx0 + rx1) / 2.0 - 1.0, ry0 + 1.5), 5.0), remote_m)
    img = over(img, layer(hot, (255, 255, 255, 0), 0.22))

    # ---- outlines ----
    img = over(img, stroke(S, g["remote"], g["remote_r"], g["remote_rim"],
                           REMOTE_RIM_TL, REMOTE_RIM_BR, g["remote_rim_alpha"],
                           near, far))
    img = over(img, stroke(S, g["plate"], g["plate_r"], g["rim"],
                           g["rim_tl"], g["rim_br"], 0.95, near, far))
    return img


def scene_glow(S, g, plate_m, remote_m):
    """Coloured light bleeding from behind the remote onto the plate: a
    vertical hue sweep matching the button colours, strongest next to the
    remote and fading across the plate."""
    rx0, ry0, rx1, ry1 = g["remote"]
    rows = g["buttons"]
    # Colour field: hue follows the button centres top to bottom.
    centres = [(y0 + y1) / 2.0 for y0, y1 in rows]
    data = []
    for y in range(MASTER):
        ty = y / float(S)
        if ty <= centres[0]:
            h = SCENE_HUES[0]
        elif ty >= centres[-1]:
            h = SCENE_HUES[-1]
        else:
            for i in range(len(centres) - 1):
                if centres[i] <= ty <= centres[i + 1]:
                    t = (ty - centres[i]) / (centres[i + 1] - centres[i])
                    h = SCENE_HUES[i] + (SCENE_HUES[i + 1] - SCENE_HUES[i]) * t
                    break
        data.append(hsv(h, 0.86, 1.0))
    col = Image.new("RGB", (1, MASTER))
    col.putdata(data)
    col = col.resize((MASTER, MASTER), Image.Resampling.NEAREST).convert("RGBA")
    # Falloff: the remote silhouette grown and blurred, minus the remote.
    halo = blur(rrect(S, (rx0 - 0.6, ry0 - 0.6, rx1 + 0.6, ry1 + 0.6),
                      g["remote_r"] + 0.6), 1.3, S)
    halo = ImageChops.lighter(
        halo, blur(rrect(S, (rx0 - 0.3, ry0 - 0.3, rx1 + 0.3, ry1 + 0.3),
                         g["remote_r"] + 0.3), 0.5, S))
    halo = ImageChops.multiply(halo, ImageChops.subtract(plate_m, remote_m))
    halo = halo.point([_clamp(v * 0.95) for v in range(256)])
    col.putalpha(halo)
    return col


def scene_buttons(S, g, button_m):
    """Each button lit from within: saturated at the rim, a hot, whiter
    core towards the centre, like a backlit key."""
    rx0, _ry0, rx1, _ry1 = g["remote"]
    out = solid((0, 0, 0, 0))
    for (y0, y1), h in zip(g["buttons"], SCENE_HUES):
        bm = ImageChops.multiply(rrect(S, (rx0, y0, rx1, y1), 0.6), button_m)
        base = layer(bm, hsv(h, 0.68, 1.0) + (0,), 0.92)
        core = radial(S, ((rx0 + rx1) / 2.0, (y0 + y1) / 2.0),
                      max((rx1 - rx0) * 0.55, 1.2))
        core = ImageChops.multiply(core, bm)
        base = over(base, layer(core, hsv(h, 0.30, 1.0) + (0,), 0.85))
        fade = ImageChops.multiply(lin_grad(S, (0, y0), (0, y1)), bm)
        base = over(base, layer(fade, (40, 0, 60, 0), 0.22))
        out = over(out, base)
    # Bloom: the lit buttons spill a little light over the grooves and the
    # remote's edge, so they read as emitters rather than paint.
    bloom = out.convert("RGBa").filter(
        ImageFilter.GaussianBlur(0.45 * S)).convert("RGBA")
    bloom.putalpha(bloom.getchannel("A").point(
        [_clamp(v * 0.55) for v in range(256)]))
    return over(bloom, out)


# --------------------------------------------------------------------------
# The Hue Bridge Pro.
# --------------------------------------------------------------------------

BRIDGE_TL, BRIDGE_BR = (72, 72, 78), (20, 20, 23)
BRIDGE_RIM_TL, BRIDGE_RIM_BR = (168, 168, 174), (84, 84, 90)
LED_WHITE = (240, 246, 255)
LED_BLUE = (96, 176, 255)


def bridge_geometry(size):
    if size == 32:
        return dict(
            body=(3, 5, 29, 26), r=3.0,
            leds=[((11, 22, 13, 24), LED_WHITE), ((15, 22, 17, 24), LED_BLUE),
                  ((19, 22, 21, 24), LED_WHITE)],
            halo=1.9, rim=1.0,
            shadow=(0.9, 1.3, 1.3, 0.5),
        )
    return dict(
        body=(1, 3, 15, 14), r=1.8,
        leds=[((5, 11, 6, 12), LED_WHITE), ((7, 11, 8, 12), LED_BLUE),
              ((9, 11, 10, 12), LED_WHITE)],
        halo=1.2, rim=1.0,
        shadow=(0.7, 1.0, 0.9, 0.55),
    )


def render_bridge(size):
    S = MASTER // size
    g = bridge_geometry(size)
    bx0, by0, bx1, by1 = g["body"]
    near, far = (bx0 - 2, by0 - 2), (bx1 + 2, by1 + 2)
    body_m = rrect(S, g["body"], g["r"])

    # Height map: a flat slab with a rounded edge and the faintest dome so
    # the top catches the light unevenly.
    H = Image.new("L", (MASTER, MASTER), 0)
    H = add_height(H, body_m, 170, 0.5, S)
    H = add_height(H, body_m, 16, 3.0, S)

    img = solid((0, 0, 0, 0))
    sdx, sdy, sr, sa = g["shadow"]
    img = over(img, drop_shadow(body_m, S, sdx, sdy, sr, sa))
    img = over(img, drop_shadow(body_m, S, 0.2, 0.3, 0.3, 0.4))
    img = over(img, grad_fill(body_m, BRIDGE_TL, BRIDGE_BR, S, near, far))
    img = grain(img, S, 0.06, seed=37, mask=body_m)

    # Glossy top: a broad environment reflection in the upper-left and a
    # sharper diagonal sheen band across the upper third.
    env = ImageChops.multiply(radial(S, (bx0 + 2, by0 + 1), (bx1 - bx0) * 0.8),
                              body_m)
    img = over(img, layer(env, (255, 255, 255, 0), 0.16))
    band = Image.new("L", (MASTER, MASTER), 0)
    h = by1 - by0
    ImageDraw.Draw(band).polygon(
        [((bx0 - 1) * S, (by0 + h * 0.22) * S),
         ((bx1 + 1) * S, (by0 + h * 0.05) * S),
         ((bx1 + 1) * S, (by0 + h * 0.30) * S),
         ((bx0 - 1) * S, (by0 + h * 0.50) * S)], fill=255)
    band = ImageChops.multiply(blur(band, 0.9, S), body_m)
    img = over(img, layer(band, (255, 255, 255, 0), 0.20))

    # Lighting: bevel highlight on the lit edges, shadow on the far ones.
    img = shade(img, H, S, d_px=0.25, gain_hi=1.3, gain_lo=1.2, mask=body_m)
    img = specular(img, H, S, d_px=0.3, strength=0.75, gloss_mask=body_m,
                   power=2.0, soften=0.1)
    # Rim: lighter all round so the near-black slab has a silhouette on
    # white, brightest where the light hits.
    img = over(img, stroke(S, g["body"], g["r"], g["rim"],
                           BRIDGE_RIM_TL, BRIDGE_RIM_BR, 0.9, near, far))

    # Status LEDs: halo, then the pixel-aligned core.
    for box, colour in g["leds"]:
        cx, cy = (box[0] + box[2]) / 2.0, (box[1] + box[3]) / 2.0
        halo = ImageChops.multiply(radial(S, (cx, cy), g["halo"]), body_m)
        img = over(img, layer(halo, colour + (0,), 0.55))
    for box, colour in g["leds"]:
        core = rrect(S, box, (box[2] - box[0]) * 0.45)
        img = over(img, layer(core, colour + (0,), 1.0))
        glint = rrect(S, (box[0] + 0.15, box[1] + 0.1, box[2] - 0.45,
                          box[3] - 0.55), 0.3)
        img = over(img, layer(glint, (255, 255, 255, 0), 0.6))
    return img


# --------------------------------------------------------------------------
# Output.
# --------------------------------------------------------------------------

FINISH = {
    # size: (unsharp (radius, percent), contrast, gamma)
    32: ((0.7, 65), 1.06, 0.98),
    16: ((0.6, 90), 1.12, 0.96),
}


def build_all():
    """Returns [(driver, name, size, master, icon)] in output order."""
    jobs = [
        ("hue_bridge", "hue_bridge_pro", 16, lambda: render_bridge(16)),
        ("hue_bridge", "hue_bridge_pro", 32, lambda: render_bridge(32)),
        ("hue_light", "hue_light", 16, lambda: render_dimmer(16, False)),
        ("hue_light", "hue_light", 32, lambda: render_dimmer(32, False)),
        ("hue_scene", "hue_scene", 16, lambda: render_dimmer(16, True)),
        ("hue_scene", "hue_scene", 32, lambda: render_dimmer(32, True)),
    ]
    out = []
    for driver, name, size, fn in jobs:
        master = fn()
        sharpen, contrast, gamma = FINISH[size]
        out.append((driver, name, size, master,
                    finish(master, size, sharpen, contrast, gamma)))
    return out


def save(img, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path, format="PNG", dpi=DPI, optimize=True)
    check = Image.open(path)
    print("wrote %s (%dx%d, %s, dpi=%s)" % (
        os.path.relpath(path, REPO_ROOT), check.width, check.height,
        check.mode, check.info.get("dpi")))


def inspection_sheet(results, out_dir):
    scales = (1, 4, 8)
    pad = 12
    cell = 32 * 8
    cols = len(results)
    row_h = sum(32 * s for s in scales) + pad * (len(scales) + 1)
    sheet = Image.new("RGB", (cols * (cell + pad) + pad, row_h * 2 + pad),
                      (255, 255, 255))
    d = ImageDraw.Draw(sheet)
    for bi, bg in enumerate(((255, 255, 255), (240, 240, 240))):
        y_top = bi * row_h + pad
        d.rectangle((0, bi * row_h, sheet.width, (bi + 1) * row_h), fill=bg)
        for ci, (driver, name, size, master, icon) in enumerate(results):
            x = pad + ci * (cell + pad)
            y = y_top
            d.text((x, y - 10), "%s %d" % (name, size), fill=(90, 90, 90))
            for s in scales:
                big = icon.resize((size * s, size * s),
                                  Image.Resampling.NEAREST)
                sheet.paste(big, (x, y + pad), big)
                y += 32 * s + pad
    path = os.path.join(out_dir, "icons_v2_sheet.png")
    sheet.save(path)
    print("wrote", path)
    for driver, name, size, master, icon in results:
        mp = os.path.join(out_dir, "icons_v2_master_%s_%d.png" % (name, size))
        master.save(mp)
        print("wrote", mp)


def main(argv):
    inspect = None
    if len(argv) >= 3 and argv[1] == "--inspect":
        inspect = argv[2]
    results = build_all()
    for driver, name, size, master, icon in results:
        save(icon, out_path(driver, name, size))
    if inspect:
        os.makedirs(inspect, exist_ok=True)
        inspection_sheet(results, inspect)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

# Automated fix for issue #123: The grouped_light queue ran at the lights' ten requests a second although Hue asks for one
