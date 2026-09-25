# Renders every hand pose that is actually WIRED INTO the set.
#
# "Wired in" means a named constant in ZScript points at the frame. That is a
# much smaller set than the model's 1298 frames: the source animation at
# 11..1288 is 1278 frames of an animator's performance that nothing addresses
# by name, so none of it appears here except the one frame that does
# (POSE_FIST_AUTHORED = 513, kept for comparison against the synthetic fist).
#
# Three banks, and they are NOT contiguous -- see rs_hands.zs:184-239:
#   0..10       synthetic, baked from finger-curl angles by tools_export_poses.py
#   513         one authored frame out of the source animation
#   1289..1297  authored hold poses (HOLD_BASE)
#   1298..1299  appended later by tools/iqm_append_pose.py, no Blender involved
#
# Output: one PNG per pose plus a contact sheet, both labelled and numbered.
#
# Every tile is rendered at ONE shared scale and centre, unlike the per-frame
# autoscale in iqm_inspect.py's own sheet. That autoscale made a closed fist
# fill the same box as a splayed reach, so the poses could not be compared --
# which is the entire point of a sheet. The bounds are taken over every pose in
# the set, so a fist reads as smaller than a reach because it IS smaller.
import sys, os, math
import numpy as np
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from iqm_inspect import IQM

# (frame, POSE_ constant, in-game description from RS_Hands.PoseName)
#
# Descriptions are copied from rs_hands.zs:160-178 so the sheet says the same
# thing the pose debug readout says.
POSES = [
    # -- bank A: synthetic, frames 0..10 ------------------------------------
    (   0, "POSE_OPEN",          "nothing held (rest -- MODELDEF is dialled against this)"),
    (   1, "POSE_POINT",         "GRIP (3-4-5 closed), index and thumb out"),
    (   2, "POSE_TRIGGER",       "TRIGGER (index curled), empty hand"),
    (   3, "POSE_FIST",          "FIST (all closed) -- melee punch"),
    (   4, "POSE_PINCH",         "PINCH (thumb to index)"),
    (   5, "POSE_THUMBOUT",      "THUMB OUT (fist, thumb clear) -- mag release"),
    (   6, "POSE_GRIPFIRE",      "GRIP+FIRE (index curled, thumb parked)"),
    (   7, "POSE_GRIP_TU",       "GRIP, thumb up"),
    (   8, "POSE_READY_TD",      "READY (finger on trigger), thumb down"),
    (   9, "POSE_READY_TU",      "READY (finger on trigger), thumb up"),
    (  10, "POSE_FIRE_TU",       "FIRE, thumb up"),
    # -- bank B: one authored frame from the source animation ---------------
    ( 513, "POSE_FIST_AUTHORED", "the animator's fist, kept for comparison"),
    # -- bank C: authored hold poses, HOLD_BASE = 1289 ----------------------
    (1289, "POSE_HOLD_ROUND",    "HOLD a round -- one cartridge, fingertips"),
    (1290, "POSE_HOLD_SHELL",    "HOLD a shell -- fuller grip"),
    (1291, "POSE_INSERT",        "INSERT (thumb driving it home)"),
    (1292, "POSE_HOLD_SLIDE",    "HOLD the slide -- pinched on the serrations"),
    (1293, "POSE_HOLD_MAG",      "HOLD a magazine -- thumb along the spine"),
    (1294, "POSE_HOLD_FOREGRIP", "HOLD a foregrip -- vertical"),
    (1295, "POSE_HOLD_FOREND",   "HOLD the forend -- pump, a fat cylinder"),
    (1296, "POSE_REACH",         "REACH (fingers splayed)"),
    (1297, "POSE_SUPPORT",       "SUPPORT (round the firing hand)"),
    # -- bank D: appended by tools/iqm_append_pose.py, not by the Blender bake -
    (1298, "POSE_REACH_CLAW",    "REACH-CLAW (spread, relaxed) -- source frame 241 verbatim"),
    (1299, "POSE_SALUTE",        "SALUTE (middle finger extended, thumb clear)"),
]

AZ, EL = 35.0, 18.0     # matches iqm_inspect.py's sheet view
TILE   = 420
COLS   = 4
BG     = (13, 15, 19)
PANEL  = (18, 21, 26)


def rot(az, el):
    a, e = math.radians(az), math.radians(el)
    Ry = np.array([[math.cos(a), 0, math.sin(a)], [0, 1, 0], [-math.sin(a), 0, math.cos(a)]])
    Rx = np.array([[1, 0, 0], [0, math.cos(e), -math.sin(e)], [0, math.sin(e), math.cos(e)]])
    return Ry, Rx


def draw(verts, tris, size, az, el, centre, scale, bg):
    """Painter's-algorithm render at a CALLER-SUPPLIED centre and scale."""
    Ry, Rx = rot(az, el)
    p = verts @ Ry.T @ Rx.T
    q = (p - centre) / scale
    xs = q[:, 0] * size * 0.80 + size / 2
    ys = -q[:, 1] * size * 0.80 + size / 2
    zs = q[:, 2]

    img = Image.new("RGB", (size, size), bg)
    d = ImageDraw.Draw(img)

    A, B, C = verts[tris[:, 0]], verts[tris[:, 1]], verts[tris[:, 2]]
    n = np.cross(B - A, C - A)
    ln = np.linalg.norm(n, axis=1); ln[ln == 0] = 1
    n = n / ln[:, None]
    nr = n @ Ry.T @ Rx.T
    L = np.array([0.35, 0.55, 0.75]); L = L / np.linalg.norm(L)
    sh = np.clip(np.abs(nr @ L), 0, 1) * 0.78 + 0.22

    for t in np.argsort(zs[tris].mean(1)):
        i, j, k = tris[t]; s = sh[t]
        d.polygon([(xs[i], ys[i]), (xs[j], ys[j]), (xs[k], ys[k])],
                  fill=(int(232 * s), int(206 * s), int(184 * s)))
    return img


def font(sz, bold=False):
    for name in (("segoeuib.ttf", "arialbd.ttf") if bold else ("segoeui.ttf", "arial.ttf")):
        try:
            return ImageFont.truetype(name, sz)
        except OSError:
            pass
    return ImageFont.load_default()


def elide(d, text, fnt, maxw):
    """Trim to fit maxw. The captions sit directly under a tile and a long one
    ran straight into the next column's caption, which read as the wrong pose's
    description rather than as overflow."""
    if d.textlength(text, font=fnt) <= maxw:
        return text
    while text and d.textlength(text + "...", font=fnt) > maxw:
        text = text[:-1]
    return text.rstrip() + "..."


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else "models/hands/hand_left.iqm"
    out = sys.argv[2] if len(sys.argv) > 2 else "docs/images/poses"
    os.makedirs(out, exist_ok=True)

    m = IQM(src)
    for fr, const, _ in POSES:
        if fr >= m.num_frames:
            raise SystemExit("frame %d (%s) is past the model's %d frames"
                             % (fr, const, m.num_frames))

    skins = [m.skin(fr) for fr, _, _ in POSES]

    # One shared centre and scale over the whole set, so the tiles compare.
    Ry, Rx = rot(AZ, EL)
    allp = np.concatenate([v @ Ry.T @ Rx.T for v in skins])
    mn, mx = allp.min(0), allp.max(0)
    centre = (mn + mx) / 2
    scale = (mx - mn).max() or 1.0

    f_num = font(30, bold=True)
    f_const = font(23, bold=True)
    f_desc = font(19)
    f_frame = font(19, bold=True)

    tiles = []
    for i, ((fr, const, desc), v) in enumerate(zip(POSES, skins), start=1):
        img = draw(v, m.tris, TILE, AZ, EL, centre, scale, PANEL)
        d = ImageDraw.Draw(img)
        # Number and frame index burned into the render itself, so a single
        # tile lifted out of the sheet still says what it is.
        d.text((14, 10), "%02d" % i, fill=(255, 214, 120), font=f_num)
        d.text((TILE - 14, 16), "frame %d" % fr, fill=(120, 190, 255),
               font=f_frame, anchor="ra")
        img.save(os.path.join(out, "%02d_%s_f%d.png" % (i, const.lower(), fr)))
        tiles.append(img)
        print("  %02d  frame %-5d %s" % (i, fr, const))

    # ---- contact sheet ----------------------------------------------------
    pad, cap, head = 16, 62, 92
    rows = (len(tiles) + COLS - 1) // COLS
    W = COLS * TILE + pad * (COLS + 1)
    H = head + rows * (TILE + cap) + pad * (rows + 1)
    sheet = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(sheet)

    d.text((pad + 4, 22), "RS_Hands -- every pose wired into the set",
           fill=(240, 244, 250), font=font(34, bold=True))
    d.text((pad + 4, 62),
           "%d poses in hand_left.iqm  |  0-10 synthetic  |  513 authored  |  "
           "1289-1299 HOLD_BASE  |  frames 11-1288 are the unaddressed source animation"
           % len(POSES),
           fill=(150, 162, 180), font=font(19))

    for i, (img, (fr, const, desc)) in enumerate(zip(tiles, POSES)):
        cx = pad + (i % COLS) * (TILE + pad)
        cy = head + pad + (i // COLS) * (TILE + cap + pad)
        sheet.paste(img, (cx, cy))
        d.text((cx + 2, cy + TILE + 8), elide(d, "%02d  %s" % (i + 1, const), f_const, TILE - 6),
               fill=(235, 240, 248), font=f_const)
        d.text((cx + 2, cy + TILE + 35), elide(d, desc, f_desc, TILE - 6),
               fill=(146, 158, 176), font=f_desc)

    path = os.path.join(out, "wired_poses_sheet.png")
    sheet.save(path)
    print("\nwrote %s  %dx%d" % (path, sheet.size[0], sheet.size[1]))
    print("wrote %d individual pose PNGs to %s" % (len(tiles), out))


if __name__ == "__main__":
    main()
