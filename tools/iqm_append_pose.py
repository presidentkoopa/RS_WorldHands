# Bakes new poses onto the end of hand_left.iqm, in place, without Blender.
#
# The normal route to a new pose is tools_export_poses.py, which needs Blender
# and the source FBX. This does not: a pose is one row of num_fc uint16s in the
# framedata block, so any pose expressible as "frame A, but with these joints
# taken from frame B" can be written directly.
#
# That is what make_hero.py was already doing at RENDER time -- it took the fist
# and grafted the middle finger's straight rotations onto it, then threw the
# result away with the image. This makes that kind of thing permanent.
#
# Appending is safe here because framedata is the second-to-last section and
# bounds is the last, so a row goes in at the framedata end and only ofs_bounds
# moves. New frames land ABOVE every existing index, so nothing already wired
# shifts meaning. The script refuses to run if it finds any other layout.
#
# Usage:  python tools/iqm_append_pose.py [--dry-run]
import sys, os, struct
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from iqm_inspect import IQM

MODEL = "models/hands/hand_left.iqm"

# iqmheader field byte offsets this script rewrites.
H_FILESIZE, H_NUM_FRAMES, H_OFS_FRAMES, H_OFS_BOUNDS = 20, 92, 100, 104
H_OFS_COMMENT, H_OFS_EXT = 112, 120

# Channel groups within a pose's 10 slots.
TRS_ROT = (3, 4, 5, 6)              # quaternion only
TRS_ALL = (0, 1, 2, 3, 4, 5, 6)     # translation + quaternion

# ---------------------------------------------------------------------------
# What to append, in order. Each entry becomes one new frame at the end.
#
# grafts: (bone-name prefix, channels, source frame) -- those joints' channels
# are taken from the source frame instead of the base frame.
# ---------------------------------------------------------------------------
APPEND = [
    dict(
        name="POSE_REACH_CLAW",
        base=241, grafts=[],
        desc="REACH-CLAW (fingers spread and relaxed, about to take hold)",
        # Source frame 241, VERBATIM. Out of the one relaxed-claw stretch in the
        # animator's performance, roughly frames 199-248.
        #
        # An earlier version of this grafted the wrist back to frame 0's on the
        # reasoning that every other pose in the set sits wrist-neutral and lets
        # the controller orient the hand. That reasoning is not wrong in general,
        # but it was applied to a pose that was PICKED BY EYE off a render of the
        # raw frame -- so the 38 degrees of wrist it removed were part of what
        # was being chosen, and the result was a visibly different pose from the
        # one asked for. The shape that got picked is the shape that ships.
    ),
    dict(
        name="POSE_SALUTE",
        base=5, grafts=[("MIDDLE_F", TRS_ROT, 0)],
        desc="SALUTE (middle finger extended, thumb clear)",
        # The hero render, made permanent. make_hero.py composed this at RENDER
        # time -- fist, with the middle finger's straight rotations grafted on --
        # and threw it away with the image every run.
        #
        # Base is thumbout (5) rather than fist (3) because the owner asked for
        # the thumb out. Both are wrist-neutral, so only the finger is grafted.
    ),
]


def channel_starts(poses):
    starts, k = [], 0
    for _, mask, _, _ in poses:
        starts.append(k)
        k += bin(mask).count("1")
    return starts, k


def channel_index(starts, mask, joint, c):
    if not (mask & (1 << c)):
        return None
    return starts[joint] + bin(mask & ((1 << c) - 1)).count("1")


def main():
    dry = "--dry-run" in sys.argv
    m = IQM(MODEL)
    b = bytearray(m.b)
    orig_len, orig_frames, orig_bounds = len(b), m.num_frames, m.ofs_bounds

    # ---- refuse any layout these assumptions do not fit --------------------
    frames_end = m.ofs_frames + m.num_frames * m.num_fc * 2
    if m.ofs_bounds != frames_end:
        raise SystemExit("bounds does not directly follow framedata (%d vs %d)"
                         % (m.ofs_bounds, frames_end))
    if m.ofs_bounds + m.num_frames * 32 != len(b):
        raise SystemExit("bounds is not the last section; refusing to append")
    for off, what in ((H_OFS_COMMENT, "comment"), (H_OFS_EXT, "extension")):
        o = struct.unpack_from("<I", b, off)[0]
        if o and o > m.ofs_frames:
            raise SystemExit("%s block sits past framedata; refusing" % what)

    starts, total = channel_starts(m.poses)
    if total != m.num_fc:
        raise SystemExit("channel count %d != num_fc %d" % (total, m.num_fc))

    def cstr(o):
        e = m.txt.find(b"\0", o); return m.txt[o:e].decode()
    names = [cstr(struct.unpack_from("<I", m.b, m.ofs_joints + i * 48)[0])
             for i in range(m.num_joints)]

    def row(f):
        return np.array(m.framedata[f * m.num_fc:(f + 1) * m.num_fc], dtype=np.uint16)

    # ---- build every row from the ORIGINAL framedata -----------------------
    rows = []
    for spec in APPEND:
        new = row(spec["base"])
        touched = []
        for prefix, channels, srcf in spec["grafts"]:
            src = row(srcf)
            joints = [i for i, n in enumerate(names) if n.startswith(prefix)]
            if not joints:
                raise SystemExit("no joints named %s*" % prefix)
            for j in joints:
                mask = m.poses[j][1]
                for c in channels:
                    k = channel_index(starts, mask, j, c)
                    if k is not None:
                        new[k] = src[k]
            touched += [names[j] for j in joints]
        rows.append(new)
        print("%-16s base f%-5d <- %s" % (spec["name"], spec["base"], ", ".join(touched)))

    # ---- bounds, from the actual skinned mesh ------------------------------
    m.framedata = np.concatenate([m.framedata] + [r for r in rows])
    m.num_frames += len(rows)
    bounds = b""
    for i, spec in enumerate(APPEND):
        idx = orig_frames + i
        v = m.skin(idx)
        bbmin, bbmax = v.min(0), v.max(0)
        xyr = float(np.sqrt(v[:, 0] ** 2 + v[:, 1] ** 2).max())
        r = float(np.sqrt((v ** 2).sum(1)).max())
        bounds += struct.pack("<8f", *bbmin, *bbmax, xyr, r)
        print("  -> frame %d  %-16s radius %.2f" % (idx, spec["name"], r))

    if dry:
        print("\n--dry-run: nothing written.")
        return

    # ---- splice ------------------------------------------------------------
    payload = b"".join(r.tobytes() for r in rows)
    out = bytearray()
    out += b[:frames_end]      # header .. end of framedata
    out += payload             # the new frames
    out += b[frames_end:]      # the whole bounds block, shifted
    out += bounds              # bounds for the new frames

    struct.pack_into("<I", out, H_FILESIZE,   len(out))
    struct.pack_into("<I", out, H_NUM_FRAMES, orig_frames + len(rows))
    struct.pack_into("<I", out, H_OFS_BOUNDS, orig_bounds + len(payload))
    # The single anim spans the whole framedata; extend it or the new frames
    # are unreachable through the animation.
    if struct.unpack_from("<I", out, m.ofs_anims + 8)[0] == orig_frames:
        struct.pack_into("<I", out, m.ofs_anims + 8, orig_frames + len(rows))
        print("extended anim 0 to %d frames" % (orig_frames + len(rows)))

    open(MODEL, "wb").write(out)
    print("\nwrote %s  %d -> %d bytes" % (MODEL, orig_len, len(out)))
    print("ofs_bounds %d -> %d" % (orig_bounds, orig_bounds + len(payload)))


if __name__ == "__main__":
    main()
