"""Smooth a transferred skin's weights in place, and nothing else.

WHY THIS EXISTS. hand_ermac.iqm is Ermac's glove mesh carrying OUR skeleton, and its weights were
produced by projecting every one of his vertices onto the nearest point of our already-weighted hand
and taking that triangle's blend (RS_VRBody/tools/ermac/build_ermac_iqm.py). That algorithm is sound
and the projection is a proper closest-point-on-triangle, but it assumes the two meshes have the
same SILHOUETTE -- and a glove does not have a hand's silhouette. A glove vertex in the valley
between two fingers, or out on the padded back, finds its nearest hand point on the wrong finger.

Nothing downstream caught it because a single wrong vertex is invisible in the bind pose. It only
appears once a joint rotates, and then that vertex is dragged somewhere its neighbours are not: the
fingers collapse into a lump from the fist onward, which is exactly what the pose sheet shows
(docs/images/poses_ermac against docs/images/poses_rs -- same renderer, same scale).

WHAT IT DOES. Laplacian smoothing of the weights over the mesh's own edge graph. Each vertex's
weights are averaged with its neighbours', a few times. An isolated vertex bound to the wrong finger
is outvoted by everyone around it; a whole region that is correctly bound barely moves, because its
neighbours already agree with it. It needs no reference mesh, so it works on the shipped model with
the original alignment data long gone.

WHAT IT DOES NOT DO. It cannot invent a binding nobody got right -- if a whole patch of the glove is
on the wrong bone, smoothing spreads that patch rather than fixing it. It is the cheap first pass.
If the sheet still reads badly after this, the answer is a real transfer with a normal check, or
weight painting, and neither is this script.

SAFETY. Only the BLENDINDEXES and BLENDWEIGHTS arrays are rewritten, in place, at their existing
offsets and their existing ubyte4 size. Positions, normals, UVs, triangles, joints, poses, anims and
frames are byte-for-byte untouched, so the bind pose and every animation frame are exactly what they
were. A .bak is written beside the file.

    python reweight_glove.py <model.iqm> [passes]     default 4 passes
"""
import os
import shutil
import struct
import sys

import numpy as np

VA_BLENDINDEXES, VA_BLENDWEIGHTS = 4, 5


def arrays(d, ofs_va, n_va):
    out = {}
    for i in range(n_va):
        t, fl, fmt, size, ofs = struct.unpack_from("<5I", d, ofs_va + i * 20)
        out[t] = (fmt, size, ofs)
    return out


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "models/hands/hand_ermac.iqm"
    passes = int(sys.argv[2]) if len(sys.argv) > 2 else 4
    d = bytearray(open(path, "rb").read())
    assert d[:16] == b"INTERQUAKEMODEL\0", "%s: not an IQM" % path

    h = struct.unpack_from("<27I", d, 16)
    n_vert, ofs_va, n_va = h[8], h[9], h[7]
    n_tri, ofs_tri = h[10], h[11]

    va = arrays(d, ofs_va, n_va)
    assert VA_BLENDINDEXES in va and VA_BLENDWEIGHTS in va, "%s: no skin weights" % path
    bi_fmt, bi_size, bi_ofs = va[VA_BLENDINDEXES]
    bw_fmt, bw_size, bw_ofs = va[VA_BLENDWEIGHTS]
    # ubyte4 both, which is what makes an in-place patch safe. Anything else and the arrays would
    # have to be rebuilt and every later offset moved -- refuse rather than guess.
    assert (bi_fmt, bi_size) == (1, 4) and (bw_fmt, bw_size) == (1, 4), \
        "expected ubyte4 blend arrays, got idx fmt %d size %d / wt fmt %d size %d" % (bi_fmt, bi_size, bw_fmt, bw_size)

    BI = np.frombuffer(bytes(d[bi_ofs:bi_ofs + n_vert * 4]), dtype=np.uint8).reshape(n_vert, 4).astype(np.int32)
    BW = np.frombuffer(bytes(d[bw_ofs:bw_ofs + n_vert * 4]), dtype=np.uint8).reshape(n_vert, 4).astype(np.float64)
    tris = np.frombuffer(bytes(d[ofs_tri:ofs_tri + n_tri * 12]), dtype="<u4").reshape(n_tri, 3).astype(np.int64)

    n_joint = int(BI.max()) + 1
    W = np.zeros((n_vert, n_joint))
    for k in range(4):
        np.add.at(W, (np.arange(n_vert), BI[:, k]), BW[:, k])
    s = W.sum(axis=1, keepdims=True)
    W /= np.where(s > 0, s, 1.0)

    # THE EDGE GRAPH, FROM THE TRIANGLES. Welded by POSITION, not by index: a UV seam splits one
    # physical vertex into several, and smoothing that treats them as unrelated leaves a hard line
    # of un-smoothed weights straight down the seam -- which on a glove runs along the fingers,
    # exactly where the deformation is worst.
    pos_fmt, pos_size, pos_ofs = va[0]
    P = np.frombuffer(bytes(d[pos_ofs:pos_ofs + n_vert * 12]), dtype="<f4").reshape(n_vert, 3)
    key = np.round(P.astype(np.float64), 4)
    _, weld, inv = np.unique(key, axis=0, return_index=True, return_inverse=True)
    n_weld = inv.max() + 1

    e = np.vstack([tris[:, [0, 1]], tris[:, [1, 2]], tris[:, [2, 0]]])
    e = inv[e]
    e = np.vstack([e, e[:, ::-1]])
    e = e[e[:, 0] != e[:, 1]]

    Wm = np.zeros((n_weld, n_joint))
    np.add.at(Wm, inv, W)
    cnt = np.bincount(inv, minlength=n_weld).reshape(-1, 1)
    Wm /= np.maximum(cnt, 1)

    deg = np.bincount(e[:, 0], minlength=n_weld).reshape(-1, 1).astype(np.float64)
    moved = 0.0
    for _ in range(passes):
        acc = np.zeros_like(Wm)
        np.add.at(acc, e[:, 0], Wm[e[:, 1]])
        nb = acc / np.maximum(deg, 1)
        # HALF AND HALF. Replacing a vertex with its neighbours' average outright washes the whole
        # skin toward the mean and a fist stops closing at all; keeping half of the original keeps
        # every correctly-bound region where it is while still outvoting a lone wrong vertex.
        new = 0.5 * Wm + 0.5 * np.where(deg > 0, nb, Wm)
        moved = max(moved, np.abs(new - Wm).max())
        Wm = new

    W = Wm[inv]
    order = np.argsort(-W, axis=1)[:, :4]
    top = np.take_along_axis(W, order, axis=1)
    top = top / np.maximum(top.sum(axis=1, keepdims=True), 1e-9)
    w255 = np.floor(top * 255.0).astype(np.int64)
    w255[np.arange(n_vert), 0] += 255 - w255.sum(axis=1)   # the largest takes the rounding
    assert (w255.sum(axis=1) == 255).all(), "weights must sum to 255"
    assert w255.min() >= 0 and w255.max() <= 255

    changed = int((order.astype(np.uint8) != BI.astype(np.uint8)).any(axis=1).sum())
    d[bi_ofs:bi_ofs + n_vert * 4] = order.astype(np.uint8).tobytes()
    d[bw_ofs:bw_ofs + n_vert * 4] = w255.astype(np.uint8).tobytes()

    bak = path + ".preweight.bak"
    if not os.path.exists(bak):
        shutil.copy2(path, bak)
    open(path, "wb").write(bytes(d))
    print("%s: %d verts (%d welded), %d passes, largest weight move %.3f" % (
        os.path.basename(path), n_vert, n_weld, passes, moved))
    print("  %d vert(s) changed their bone set (%.0f%%); backup at %s" % (
        changed, 100.0 * changed / n_vert, os.path.basename(bak)))


if __name__ == "__main__":
    main()
