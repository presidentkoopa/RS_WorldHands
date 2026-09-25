# Bakes the hand pose frames, keeping the source animation.
#
# Earlier versions of this script opened by wiping the FBX's animation and
# authoring poses from computed finger curls. That threw away the real asset:
# the source carries 1278 authored frames holding somewhere between 60 and 100
# genuinely distinct hand shapes -- an animator's performance, far better than
# anything derived from five curl angles.
#
# So now BOTH are kept. The synthetic poses stay at frames 0..10 so every index
# already wired into ZScript and MENUDEF keeps meaning what it meant, and the
# entire source animation follows at frame 11 onwards, verbatim. Roughly 300KB
# for the lot.
#
# Frame 0 must stay the rest pose -- the MODELDEF placement is dialled in
# against it.
import bpy, sys, os, math
from mathutils import Vector, Euler, Quaternion

argv = sys.argv[sys.argv.index("--") + 1:]
fbx, out_dir, scale, rot_x = argv[0], argv[1], float(argv[2]), math.radians(float(argv[3]))

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.fbx(filepath=fbx)

PIVOT_BONE = "HANDPALM_joint"
FINGERS = ["INDEX", "MIDDLE_F", "RING", "PINK", "THUMB"]
# All FOUR joints per finger, not three.
#
# UP_TOP was being skipped entirely. On the four fingers that is nearly
# harmless -- those bones carry between 0.0 and 0.3 total vertex weight -- but
# THUMB_UP_TOP_joint carries 159 verts and 37.8, as much as the thumb's own
# base. The thumb's last segment has been rigid the whole time.
SEGS    = ["BASE", "MID", "TOP", "UP_TOP"]

# The tip-most joint, for anything measuring where a finger ENDS.
TIPSEG  = "UP_TOP"

# How much of the named curl each joint takes, and it is NOT a taper any more.
#
# It used to fall away toward the tip -- 1.0, 0.9, 0.6 -- so the fingertip bent
# least of all. Real fingers do the opposite: the middle knuckle is the one that
# folds hardest. At a full fist a hand runs roughly 90 degrees at the knuckle,
# 110 at the middle joint and 70 at the last, so the middle takes MORE than the
# knuckle, not less.
#
# Getting this backwards is what left the last segment of each finger standing
# up out of a closed fist, and it is why forcing more curl to fix that drove the
# tips through the palm instead of tucking them into it: the arc was too wide,
# so the only way to bring the tip down was to push it past the palm entirely.
TAPER   = {"BASE": 1.0, "MID": 1.2, "TOP": 0.78, "UP_TOP": 0.35}

#            index middle ring pink thumb
POSES = [
    ("open",    [  0,   0,   0,   0,   0]),   # 0  rest -- placement depends on this
    ("point",   [  0,  85,  90,  90,  14]),   # 1  on a gun, finger off the trigger
                                          #    Thumb 14, not 25. This is the ONLY pose with a
                                          #    straight index, so it is the only one where the
                                          #    thumb never collides with a curled finger and
                                          #    never hits the clamp. At 25 the taper compounds
                                          #    to 83 degrees of cumulative wrap -- MORE than the
                                          #    fist, whose thumb is stopped at 59 by hitting its
                                          #    own fingers -- and the thumb swings clear of the
                                          #    hand entirely. Measured, not guessed.
    ("trigger", [ 80,   0,   0,   0,   0]),   # 2  empty hand, index alone
    ("fist",    [ 85,  85,  90,  90,  30]),   # 3  melee punch
    ("pinch",   [ -1,  85,  90,  90,  -1]),   # 4  solved below
    ("thumbout",[ 85,  85,  90,  90,   0]),   # 5  fist, thumb clear
    ("gripfire",[ 85,  85,  90,  90,  25]),   # 6  trigger pulled
    ("grip_tu", [  0,  85,  90,  90,   0]),   # 7  thumb lifted
    ("ready_td",[ 30,  85,  90,  90,  25]),   # 8  index ON the trigger
    ("ready_tu",[ 30,  85,  90,  90,   0]),   # 9  index ON the trigger, thumb lifted
    ("fire_tu", [ 85,  85,  90,  90,   0]),   # 10 firing, thumb lifted
]

arm  = bpy.data.objects.get("Armature")
mesh = bpy.data.objects.get("Hand_Low")

# ---------------------------------------------------------------------------
# Capture the source animation BEFORE anything is cleared.
#
# matrix_basis is the pose transform relative to the bone's rest position, so
# it survives the repivot and re-orientation applied to the object below --
# those change the rest pose, and these deltas still mean the same thing
# against it.
# ---------------------------------------------------------------------------
src_range = arm.animation_data.action.frame_range
src_start, src_end = int(src_range[0]), int(src_range[1])
scn = bpy.context.scene

bone_names = [pb.name for pb in arm.pose.bones]
source_frames = []
for f in range(src_start, src_end + 1):
    scn.frame_set(f)
    frame = {}
    for pb in arm.pose.bones:
        loc, rot, sca = pb.matrix_basis.decompose()
        frame[pb.name] = (loc.copy(), rot.copy(), sca.copy())
    source_frames.append(frame)
print(f"captured {len(source_frames)} source frames ({src_start}..{src_end})")

for ob in bpy.data.objects: ob.animation_data_clear()
for ac in list(bpy.data.actions): bpy.data.actions.remove(ac)

def unparent(ob):
    if ob.parent is None: return
    bpy.ops.object.select_all(action='DESELECT')
    ob.select_set(True); bpy.context.view_layer.objects.active = ob
    bpy.ops.object.parent_clear(type='CLEAR_KEEP_TRANSFORM')

def apply_to(a, m, **kw):
    bpy.ops.object.select_all(action='DESELECT')
    a.select_set(True); m.select_set(True)
    bpy.context.view_layer.objects.active = a
    bpy.ops.object.transform_apply(**kw)
    bpy.context.view_layer.update()

unparent(arm); unparent(mesh)
bpy.context.view_layer.update()
delta = -(arm.matrix_world @ arm.data.bones.get(PIVOT_BONE).head_local)
for ob in (arm, mesh): ob.location = ob.location + delta
bpy.context.view_layer.update()
apply_to(arm, mesh, location=True, rotation=False, scale=False)
for ob in (arm, mesh): ob.rotation_euler = (rot_x, 0.0, 0.0)
bpy.context.view_layer.update()
apply_to(arm, mesh, location=False, rotation=True, scale=False)

# --- measure each joint's flexion axis --------------------------------------
# Quaternion mode from here on. The probe below turns joints about ARBITRARY
# axes, not about X, Y or Z, and an euler triple cannot express that.
for pb in arm.pose.bones:
    pb.rotation_mode = 'QUATERNION'
    pb.rotation_quaternion = (1.0, 0.0, 0.0, 0.0)
bpy.context.view_layer.update()

M = arm.matrix_world
kn   = ((M @ arm.pose.bones["PINK_BASE_joint"].head) - (M @ arm.pose.bones["INDEX_BASE_joint"].head)).normalized()
midv = ((M @ arm.pose.bones[f"MIDDLE_F_{TIPSEG}_joint"].tail) - (M @ arm.pose.bones["MIDDLE_F_BASE_joint"].head)).normalized()
pn   = kn.cross(midv).normalized()
OPPOSE_TARGET = M @ arm.pose.bones["MIDDLE_F_BASE_joint"].head

# Real sizes need a unit scale, and this file's units are arbitrary. The span
# across the knuckles is a known human dimension, so measuring it converts
# everything else without having to know what a unit is here. Defined this early
# because every diagnostic below reports in centimetres, and a number in
# arbitrary units tells you nothing about whether a hand looks right.
KNUCKLE_SPAN_CM = 7.5
_span = ((M @ arm.pose.bones["INDEX_BASE_joint"].head)
       - (M @ arm.pose.bones["PINK_BASE_joint"].head)).length
CM = _span / KNUCKLE_SPAN_CM
print(f"knuckle span {_span:.5f} units = {KNUCKLE_SPAN_CM}cm, so 1cm = {CM:.5f} units")

# Earlier versions picked, per joint, whichever of the six signed cardinal axes
# carried the fingertip furthest toward the palm. That fixed fingers bending
# backwards, but it left a subtler artifact that shows constantly once you are
# gripping things: a real finger joint's hinge is not aligned to X, Y or Z, so
# the nearest cardinal is always a few degrees off, and rotating about it drags
# the tip SIDEWAYS as well as inward. Every joint carries its own error, they
# compound down the chain, and the result is a closed hand whose fingertips
# splay apart instead of sitting together -- worst on the middle and ring
# fingers, whose true hinges are the most oblique.
#
# So the axis is no longer snapped to a cardinal. It is searched over the whole
# sphere of directions, coarse then fine, and scored on TWO things: how far the
# tip travels toward the palm, and how far it drifts out of the finger's own
# plane of flexion. The second term is the fix -- lateral drift is exactly the
# splay, so penalising it directly is what removes it.
TEST_DEG   = 85.0
LATERAL_W  = 3.0    # a degree of splay costs three times a degree of curl

def sphere_axes(step_deg, around=None, span_deg=None):
    """Unit directions to try. Whole sphere, or a cone around a previous best."""
    out = []
    if around is None:
        for th in range(0, 181, step_deg):
            st = math.sin(math.radians(th)); ct = math.cos(math.radians(th))
            for ph in range(0, 360, step_deg):
                v = Vector((st * math.cos(math.radians(ph)), ct,
                            st * math.sin(math.radians(ph))))
                if v.length > 1e-6:
                    out.append(v.normalized())
                if th in (0, 180):
                    break          # the poles are one direction, not thirty-six
    else:
        # A local cone: two axes perpendicular to the current best, swept.
        up = Vector((0, 0, 1)) if abs(around.z) < 0.9 else Vector((1, 0, 0))
        e1 = around.cross(up).normalized()
        e2 = around.cross(e1).normalized()
        r = math.radians(span_deg)
        n = max(2, int(span_deg / step_deg))
        for i in range(-n, n + 1):
            for j in range(-n, n + 1):
                v = around + e1 * (r * i / n) + e2 * (r * j / n)
                if v.length > 1e-6:
                    out.append(v.normalized())
    return out

def score_axis(pb, tip_pb, axis, rest, lat, oppose):
    pb.rotation_quaternion = Quaternion(axis, math.radians(TEST_DEG))
    bpy.context.view_layer.update()
    now = M @ tip_pb.tail
    pb.rotation_quaternion = (1.0, 0.0, 0.0, 0.0)
    if oppose:
        # The thumb opposes rather than flexes -- it swings ACROSS the palm
        # toward the far knuckles instead of folding into the palm plane -- so
        # it is scored on arriving there, with no lateral term to apply.
        return (now - OPPOSE_TARGET).length
    d = now - rest
    return d.dot(pn) + LATERAL_W * abs(d.dot(lat))

# The six signed cardinal axes, which is all the earlier version considered.
# Kept, because it turns out to be the right answer for one of the five digits.
CARDINALS = [Vector(v) for v in
             ((1,0,0), (-1,0,0), (0,1,0), (0,-1,0), (0,0,1), (0,0,-1))]

def free_axis(pb, tip_pb, lat, oppose=False, cardinal_only=False):
    rest = M @ tip_pb.tail
    best = None
    for axis in (CARDINALS if cardinal_only else sphere_axes(15)):
        sc = score_axis(pb, tip_pb, axis, rest, lat, oppose)
        if best is None or sc < best[0]:
            best = (sc, axis)
    if not cardinal_only:
        for axis in sphere_axes(3, around=best[1], span_deg=15):
            sc = score_axis(pb, tip_pb, axis, rest, lat, oppose)
            if sc < best[0]:
                best = (sc, axis)
    bpy.context.view_layer.update()
    return best[1], best[0]

AXES = {}

# Sideways squeeze at the knuckle, per finger, in degrees at full curl. Solved
# further down; empty here so everything above runs as pure flexion.
ADDUCT = {}
ADDUCT_AXES = {}
MAX_CURL = {}

def set_finger(fing, deg, clamp=True):
    """clamp=False for a hand closing on an OBJECT.

    The ceiling exists to stop a fingertip entering the palm, and a hand wrapped
    round a shotgun forend never gets near it -- there is 4.5cm of gun in the
    way. Applying it there is not merely unnecessary, it is destructive: it
    clamped the magazine, foregrip and forend wraps to the same 60 degrees and
    collapsed three distinct holds into one shape.

    MAX_CURL is also empty until it is solved, so everything that runs before
    that measures an unclamped hand -- which is what those solvers need, one of
    them being the ceiling solve itself."""
    if clamp and deg > 0 and fing in MAX_CURL:
        deg = min(deg, MAX_CURL[fing])
    for sg in SEGS:
        pb = arm.pose.bones.get(f"{fing}_{sg}_joint")
        if not pb: continue
        q = Quaternion(AXES[pb.name], math.radians(deg * TAPER[sg]))
        # Adduction lives at the knuckle only, and scales with how far the
        # finger has closed. Scaling matters: an open hand must come out
        # completely unmodified, because frame 0 is the rest pose and the whole
        # MODELDEF placement is dialled in against it.
        if sg == "BASE" and fing in ADDUCT:
            q = q @ Quaternion(ADDUCT_AXES[fing], math.radians(ADDUCT[fing] * deg / 90.0))
        pb.rotation_quaternion = q

def rest_pose():
    for pb in arm.pose.bones:
        pb.rotation_quaternion = (1.0, 0.0, 0.0, 0.0)
    bpy.context.view_layer.update()

# Where along a finger to measure. Measuring the TIP alone was not enough and
# the failure was specific: adduction happens at the knuckle, so it swings the
# WHOLE finger, and an objective that only looks at the far end will happily
# separate the tips while folding the middles of two fingers into each other.
# A ring finger fused to a pinky at the second knuckle scores perfectly on tips.
#
# Three points down each finger instead, so the pair has to stay apart along its
# whole length rather than only at the end.
SAMPLES = (("MID", "head"), ("TOP", "head"), ("TOP", "tail"))

def tip_spread():
    """Separation between adjacent fingers, sampled down their length.

    Nine numbers -- three pairs at three points each -- flattened, and every one
    of them wants to be about a knuckle-spacing."""
    out = []
    for seg, end in SAMPLES:
        pts = []
        for f in ("INDEX", "MIDDLE_F", "RING", "PINK"):
            pb = arm.pose.bones[f"{f}_{seg}_joint"]
            pts.append(M @ (pb.tail if end == "tail" else pb.head))
        out += [(pts[i + 1] - pts[i]).length for i in range(3)]
    return out

def spread_at_full_curl():
    rest_pose()
    for f in ("INDEX", "MIDDLE_F", "RING", "PINK"):
        set_finger(f, 90)
    bpy.context.view_layer.update()
    g = tip_spread()
    rest_pose()
    return g

# ---------------------------------------------------------------------------
# Solve both ways, then let the measurement decide.
#
# Free axes are the better idea and they do fix the four fingers, but the thumb
# came out worse in a way that mattered: the pinch it could reach went from
# 2.2cm to 4.4cm, because the thumb is scored on arriving at a TARGET rather
# than on staying in a plane, and three joints each independently overshooting
# toward that target compound into a thumb that misses the index entirely.
#
# Rather than pick one and hope, both are computed and the fingertip splay at
# full curl is measured for each. Whichever closes the hand more tightly wins,
# and the numbers are printed so the choice is visible rather than asserted.
# The thumb is judged on its own terms -- the pinch it can reach -- because
# splay says nothing about a digit that does not sit in the row.
# ---------------------------------------------------------------------------
FINGER4 = ("INDEX", "MIDDLE_F", "RING", "PINK")
free_ax, card_ax, thumb_free, thumb_card = {}, {}, {}, {}

print("=== solving flexion axes ===")
for f in FINGERS:
    tip = None
    for sg in reversed(SEGS):
        if arm.pose.bones.get(f"{f}_{sg}_joint"):
            tip = arm.pose.bones[f"{f}_{sg}_joint"]; break
    # The finger's plane of flexion: along the finger, and palmward. Anything
    # perpendicular to both is sideways, and sideways is the splay.
    base = M @ arm.pose.bones[f"{f}_BASE_joint"].head
    fdir = ((M @ tip.tail) - base).normalized()
    lat  = fdir.cross(pn).normalized()
    opp  = (f == "THUMB")
    for sg in SEGS:
        pb = arm.pose.bones.get(f"{f}_{sg}_joint")
        if not pb: continue
        a_free, _ = free_axis(pb, tip, lat, oppose=opp)
        a_card, _ = free_axis(pb, tip, lat, oppose=opp, cardinal_only=True)
        (thumb_free if opp else free_ax)[pb.name] = a_free
        (thumb_card if opp else card_ax)[pb.name] = a_card

def pinch_reach(thumb_axes):
    """Closest the index and thumb tips can be brought together."""
    AXES.update(thumb_axes)
    itip_l = arm.pose.bones[f"INDEX_{TIPSEG}_joint"]
    ttip_l = arm.pose.bones[f"THUMB_{TIPSEG}_joint"]
    best = None
    for idx in range(0, 95, 5):
        for th in range(0, 95, 5):
            set_finger("INDEX", idx); set_finger("THUMB", th)
            bpy.context.view_layer.update()
            d = ((M @ itip_l.tail) - (M @ ttip_l.tail)).length
            if best is None or d < best: best = d
    rest_pose()
    return best

AXES.update(free_ax); AXES.update(thumb_free)
g_free = spread_at_full_curl()
AXES.update(card_ax)
g_card = spread_at_full_curl()

print(f"  fingertip splay, free axes      "
      f"{g_free[0]:.5f} {g_free[1]:.5f} {g_free[2]:.5f}  total {sum(g_free):.5f}")
print(f"  fingertip splay, cardinal axes  "
      f"{g_card[0]:.5f} {g_card[1]:.5f} {g_card[2]:.5f}  total {sum(g_card):.5f}")
if sum(g_free) <= sum(g_card):
    AXES.update(free_ax); print("  -> fingers: FREE axes (tighter fist)")
else:
    AXES.update(card_ax); print("  -> fingers: CARDINAL axes (tighter fist)")

AXES.update(free_ax if sum(g_free) <= sum(g_card) else card_ax)
r_free = pinch_reach(thumb_free)
r_card = pinch_reach(thumb_card)
print(f"  thumb reach, free axes     {r_free:.5f}")
print(f"  thumb reach, cardinal axes {r_card:.5f}")
if r_free <= r_card:
    AXES.update(thumb_free); print("  -> thumb: FREE axes (closer pinch)")
else:
    AXES.update(thumb_card); print("  -> thumb: CARDINAL axes (closer pinch)")
rest_pose()

# ---------------------------------------------------------------------------
# CONVERGENCE -- the sideways squeeze this rig does not have
#
# With the hinge axes right, the fingers still close into four parallel planes,
# and the gaps between the fingertips survive the curl: measured, a closed hand
# here holds its tips further apart than an open one in places. A real fist
# does the opposite. The tips converge onto the palm, because a real knuckle
# ADDUCTS as well as flexes -- it swings sideways, drawing the fingers together
# -- and nothing in this rig or in the pose data does that.
#
# So it is added: a small sideways rotation at each knuckle, on top of the flex,
# growing with how far the finger has closed. Two things are measured rather
# than guessed. The axis, found the same way the flexion axis was -- the one
# that carries the tip along the finger's own lateral direction with the least
# palmward travel. And the angle, solved by minimising the measured fingertip
# spread, one finger at a time, repeatedly, until it stops improving.
# ---------------------------------------------------------------------------
# How far each fingertip actually travels toward the palm at full curl. A
# finger whose joints were given a wrong axis does not fold, and that is
# invisible in a list of axes but obvious in one number.
print("=== fold check: tip travel at 90 degrees ===")
for f in FINGER4 + ("THUMB",):
    rest_pose()
    tip = arm.pose.bones[f"{f}_{TIPSEG}_joint"]
    a = M @ tip.tail
    set_finger(f, 90)
    bpy.context.view_layer.update()
    b = M @ tip.tail
    rest_pose()
    print(f"  {f:<10} travels {(a - b).length / CM:5.2f}cm, "
          f"{((a - b).dot(pn)) / CM:+5.2f}cm of it palmward")

print("=== solving knuckle adduction ===")
for f in FINGER4:
    pb  = arm.pose.bones[f"{f}_BASE_joint"]
    tip = arm.pose.bones[f"{f}_{TIPSEG}_joint"]
    base = M @ pb.head
    fdir = ((M @ tip.tail) - base).normalized()
    lat  = fdir.cross(pn).normalized()
    rest = M @ tip.tail
    best = None
    for axis in sphere_axes(10):
        pb.rotation_quaternion = Quaternion(axis, math.radians(30.0))
        bpy.context.view_layer.update()
        d = (M @ tip.tail) - rest
        pb.rotation_quaternion = (1.0, 0.0, 0.0, 0.0)
        # Sideways as much as possible, palmward as little as possible: this is
        # the complement of the flexion axis, not a second version of it.
        sc = -abs(d.dot(lat)) + abs(d.dot(pn))
        if best is None or sc < best[0]:
            best = (sc, axis, d.dot(lat))
    # Sign it so positive degrees always move the tip toward the middle finger,
    # whichever side of the hand this one is on.
    toward = 1.0 if f in ("INDEX",) else -1.0
    if f == "MIDDLE_F":
        toward = 0.0
    ax = best[1]
    if best[2] * toward < 0:
        ax = -ax
    ADDUCT_AXES[f] = ax
    ADDUCT[f] = 0.0
rest_pose()

def total_spread():
    rest_pose()
    for f in FINGER4:
        set_finger(f, 90)
    bpy.context.view_layer.update()
    g = tip_spread()
    rest_pose()
    return sum(g), g

# What "together" actually means.
#
# Minimising the tip gaps was the wrong target, and wrong in a way that shows:
# the objective is happiest when the fingers are driven THROUGH each other, and
# a middle fingertip then pokes out of the side of a closed fist. Fingers in a
# real fist sit side by side touching, about a finger-width apart at the tips --
# they do not converge to a point.
#
# The rig already knows that width: it is the spacing across the knuckles. So
# the target is measured from the hand rather than assumed, and the objective
# becomes "bring the tips to the spacing the knuckles already have".
KNUCKLE_GAPS = []
for a, b in (("INDEX", "MIDDLE_F"), ("MIDDLE_F", "RING"), ("RING", "PINK")):
    KNUCKLE_GAPS.append((((M @ arm.pose.bones[f"{a}_BASE_joint"].head)
                        - (M @ arm.pose.bones[f"{b}_BASE_joint"].head)).length))
print(f"  knuckle spacing (the target)     "
      f"{KNUCKLE_GAPS[0]:.5f} {KNUCKLE_GAPS[1]:.5f} {KNUCKLE_GAPS[2]:.5f}")

def spread_error(gaps):
    """Distance from the target, counted at every sample point.

    A pair that has closed to less than the target is penalised HARDER than one
    that is too far apart, because those two failures are not equally bad to
    look at: too far apart is a hand that is slightly splayed, too close is two
    fingers occupying the same space, and one of those is unmistakable."""
    err = 0.0
    for si in range(len(SAMPLES)):
        for i in range(3):
            d = gaps[si * 3 + i] - KNUCKLE_GAPS[i]
            err += (-d * 3.0) if d < 0.0 else d
    return err

base_total, base_gaps = total_spread()
def show(label, g):
    for si, (seg, end) in enumerate(SAMPLES):
        print(f"  {label if si == 0 else '':<8}{seg + ' ' + end:<10}"
              f"{g[si*3]:.5f} {g[si*3+1]:.5f} {g[si*3+2]:.5f}")

show("before", base_gaps)
print(f"          error {spread_error(base_gaps):.5f}")

# Coordinate descent. The gaps are pairwise, so the fingers are not independent
# and one pass is not enough; three settles it, and it is cheap.
for _ in range(3):
    for f in FINGER4:
        if f == "MIDDLE_F":
            continue      # the middle finger is the one the others converge on
        keep = ADDUCT[f]
        best = (spread_error(total_spread()[1]), keep)
        # Capped at what a knuckle can actually do. A finger abducts and
        # adducts about 15-20 degrees at the MCP and no further, so a search
        # allowed past that is not finding a better hand, it is exploiting the
        # objective by folding fingers through one another.
        for deg in range(-16, 17, 2):
            ADDUCT[f] = float(deg)
            t = spread_error(total_spread()[1])
            if t < best[0]:
                best = (t, float(deg))
        ADDUCT[f] = best[1]

fin_total, fin_gaps = total_spread()
for f in FINGER4:
    print(f"  {f:<10} adduct {ADDUCT[f]:+5.1f} deg at full curl")
be, fe = spread_error(base_gaps), spread_error(fin_gaps)
show("after", fin_gaps)
print(f"          error {fe:.5f}   ({100.0 * (be - fe) / be:+.1f}%)")
rest_pose()

itip = arm.pose.bones[f"INDEX_{TIPSEG}_joint"]
ttip = arm.pose.bones[f"THUMB_{TIPSEG}_joint"]
best = None
for idx in range(0, 95, 5):
    for th in range(0, 95, 5):
        set_finger("INDEX", idx); set_finger("THUMB", th)
        bpy.context.view_layer.update()
        d = ((M @ itip.tail) - (M @ ttip.tail)).length
        if best is None or d < best[0]: best = (d, idx, th)
set_finger("INDEX", 0); set_finger("THUMB", 0)
bpy.context.view_layer.update()
gap, pinch_idx, pinch_th = best
POSES[4] = ("pinch", [pinch_idx, 85, 90, 90, pinch_th])
print(f"pinch solved: index {pinch_idx} thumb {pinch_th}, gap {gap:.5f}")

# ---------------------------------------------------------------------------
# HOW FAR EACH FINGER MAY CLOSE
#
# Every pose here names one curl angle and every finger obeys it. Fingers are
# not the same length, so the same angle does not put their tips in the same
# place: the middle finger, being longest, travels furthest and drives its tip
# straight through the palm, while the little finger stops short of it. Both
# are visible, and the first is the one that reads as fingertips disappearing
# into the hand.
#
# So each finger gets its own ceiling, measured. The tip is swept through the
# curl range and watched against the plane of the palm, and the finger stops
# where its tip is resting ON the palm rather than inside it. Angles below the
# ceiling are untouched, so every pose keeps its character and only the deep end
# of the curl changes.
#
# Solved here, AFTER the pinch: everything above needs to measure an unclamped
# hand, and one of the things it measures is how far a finger can reach.
def tip_height(f):
    """How far the fingertip is from the surface of the palm."""
    bpy.context.view_layer.update()
    tip = M @ arm.pose.bones[f"{f}_{TIPSEG}_joint"].tail
    ab = PALM_B - PALM_A
    t = max(0.0, min(1.0, (tip - PALM_A).dot(ab) / ab.dot(ab)))
    return (tip - (PALM_A + ab * t)).length

PALM_A = M @ arm.pose.bones["HANDPALM_joint"].head
PALM_B = M @ arm.pose.bones["MIDDLE_F_BASE_joint"].head

# How much room a fingertip needs from the palm's CENTRE LINE before it stops
# overlapping the palm. Two parts, and both are measured rather than assumed,
# because the first attempt at this used a guessed number and produced ceilings
# of five degrees for every finger.
#
#   the finger's own radius   -- half a knuckle spacing
#   the palm's half thickness -- from the MESH, not the skeleton
#
# The mesh part is the one that matters. The bones say a fingertip at full curl
# sits comfortably clear of the palm's centre line, and it does; the palm is
# simply thicker than its centre line, so the tip is inside the geometry while
# the skeleton reports it outside. That is the difference between measuring a
# rig and measuring a hand.
FINGER_RADIUS = KNUCKLE_GAPS[0] * 0.5

_mm = mesh.matrix_world
_lat_lo = (( M @ arm.pose.bones["INDEX_BASE_joint"].head) - PALM_A).dot(kn)
_lat_hi = (( M @ arm.pose.bones["PINK_BASE_joint"].head) - PALM_A).dot(kn)
if _lat_lo > _lat_hi: _lat_lo, _lat_hi = _lat_hi, _lat_lo
_near, _lo, _hi = [], None, None
for v in mesh.data.vertices:
    w = _mm @ v.co
    ab = PALM_B - PALM_A
    t = (w - PALM_A).dot(ab) / ab.dot(ab)
    # Between the index and little-finger knuckles as well as along the palm:
    # the thumb ruins it otherwise. Its base sits squarely in the palm's span
    # and stands well proud of it, so an unfiltered scan measures palm-plus-
    # thumb and reports a hand two and a half times too thick -- which came out
    # as every finger being forbidden to close past sixty degrees.
    lat = (w - PALM_A).dot(kn)
    if 0.15 < t < 0.85 and _lat_lo < lat < _lat_hi:
        d = (w - PALM_A).dot(pn)
        _lo = d if _lo is None else min(_lo, d)
        _hi = d if _hi is None else max(_hi, d)
# CAPPED, and the cap is doing the work.
#
# The scan keeps reporting about 7cm, which is not a palm -- this model carries a
# forearm stub, and the stretch of it being sampled is round and thick. Filtering
# by position along the palm and by lateral span both failed to exclude it, and
# the consequence was not subtle: a 7cm palm forbids every finger from closing
# past sixty degrees, so the hand can never make a fist at all.
#
# Rather than keep chasing a filter, the measurement is bounded by something
# known: a palm is about as thick as a finger is wide. The scan stays, printed,
# because when it disagrees with the bound it is saying something about the
# mesh worth knowing -- it just no longer gets to set the number.
_measured = ((_hi - _lo) * 0.5) if (_lo is not None) else FINGER_RADIUS

# How much clearance a fingertip needs, in finger-radii.
#
# Set from what the model actually shows rather than from a thickness model,
# because every thickness model tried here was wrong in a different direction.
# The evidence is a closed fist seen from the palm: at 85 degrees the index and
# middle fingernails emerge THROUGH the palm while the ring finger, clamped to
# the same 85, sits correctly at the edge of it. Same angle, different result,
# because they are different lengths -- which is the whole reason these ceilings
# exist.
#
# So the number is whatever makes the two offenders stop before 85 while leaving
# the two that already behave alone. Raising it costs a little curl at the very
# deepest end of a fist; leaving it low costs fingertips through the palm, and
# only one of those is visible from inside a headset.
PALM_CLEAR_RADII = 2.4
PALM_HALF = min(_measured, FINGER_RADIUS)
CLEARANCE = FINGER_RADIUS * PALM_CLEAR_RADII
print(f"  palm scan says {_measured*2/CM:.2f}cm thick (forearm stub, not trusted)"
      f"  ->  fingertips stop {CLEARANCE/CM:.2f}cm from the palm centre line")

# The palm as a SEGMENT, wrist to knuckles, not as an infinite plane.
#
# Height above a plane was the obvious measure and it is useless here: a flat
# hand already has its fingertips IN the plane of the palm, so the test trips at
# zero degrees and every finger gets a ceiling of five. Measured that way, an
# open hand is already inside itself.
#
# Distance to the palm is the measure that behaves: large when the finger is
# extended, falling steadily as it closes, and reaching a finger's radius at the
# moment the tip is resting on the palm rather than in it.

print("=== how far each finger may close ===")
for f in FINGER4:
    rest_pose()
    limit = 110
    for deg in range(0, 115, 5):
        set_finger(f, deg)
        if tip_height(f) < CLEARANCE:
            limit = max(0, deg - 5)
            break
    rest_pose()
    set_finger(f, limit)
    h = tip_height(f)
    rest_pose()
    MAX_CURL[f] = limit
    note = "" if limit >= 110 else "   <- cannot reach a full fist"
    print(f"  {f:<10} ceiling {limit:3d} deg, tip {h/CM:5.2f}cm above the palm{note}")
rest_pose()

# The by-eye override is gone.
#
# Index and middle were pinned to 60 degrees because at 85 their tips came
# through the palm -- but that was the inverted taper talking. With the middle
# knuckle folding hardest, as a real finger does, the tip curls INTO the fist
# instead of describing a wide arc that can only clear the palm by going through
# it. The solver gets to answer again.


# ---------------------------------------------------------------------------
# INTERACTION POSES -- what the hand does to a WEAPON, not to a controller.
#
# Appended AFTER the source animation rather than beside the poses at 0..10,
# because those frame numbers are API: POSE_FIST is source frame 503 sitting at
# model frame 513, and inserting anything ahead of it would move every index
# already wired into ZScript and MENUDEF.
#
# Solved rather than typed in. A hold only reads as a hold when the fingers
# close to the size of the thing being held -- a hand shaped for a shotgun
# shell, wrapped around a single 9mm round, looks like a fist with a gap in it
# -- and the angles that do that depend on this rig's proportions. So each pose
# names a real-world diameter and the script searches for the curls producing
# it. Same principle as the measured flexion axes above: measure the rig,
# do not assume it.
# ---------------------------------------------------------------------------

# Unit scale (CM) is measured up with the palm normal -- see above.

def tip_gap():
    bpy.context.view_layer.update()
    return ((M @ itip.tail) - (M @ ttip.tail)).length

def rest_all():
    rest_pose()

def solve_pinch(diam_cm, others):
    """Index and thumb closed until their tips sit diam_cm apart.

    A pinch on a thin object, with the remaining fingers curled out of the way
    at whatever the caller asks for -- how far they close is character rather
    than geometry: a hand on a slide keeps them loose, a hand holding a shell
    tucks them in.

    This rig cannot pinch tighter than about 2.2cm -- the thumb is short and
    the tips never actually meet -- so anything smaller than that comes back as
    the tightest pinch available and says so rather than failing quietly."""
    want = diam_cm * CM
    for fi, f in enumerate(["MIDDLE_F", "RING", "PINK"]):
        set_finger(f, others[fi], clamp=False)
    best = None
    for idx in range(0, 95, 5):
        for th in range(0, 95, 5):
            set_finger("INDEX", idx, clamp=False)
            set_finger("THUMB", th, clamp=False)
            err = abs(tip_gap() - want)
            # Tie-break toward the more closed hand. Several angle pairs hit
            # the same gap -- one with the fingers barely bent and the object
            # held out in front, one with them curled round it -- and only the
            # second reads as holding something.
            if best is None or (err, -(idx + th)) < (best[0], -(best[1] + best[2])):
                best = (err, idx, th)
    rest_all()
    _, idx, th = best
    note = "  (rig minimum, target unreachable)" if best[0] / CM > 0.3 else ""
    print(f"  pinch {diam_cm}cm -> index {idx} thumb {th}  off by {best[0]/CM:.2f}cm{note}")
    return [idx, others[0], others[1], others[2], th]

# Where a held cylinder touches the palm: across it, under the knuckles. Used
# as the palm-side contact point when solving a wrap.
PALM_CONTACT = "MIDDLE_F_BASE_joint"

def wrap_gap():
    bpy.context.view_layer.update()
    return ((M @ itip.tail) - (M @ arm.pose.bones[PALM_CONTACT].head)).length

def solve_wrap(diam_cm):
    """All four fingers curled round a cylinder of diam_cm, thumb opposing.

    Fingertip-to-thumbtip is the wrong measure here, and using it produced
    nonsense: as the fingers curl past the thumb that distance falls and then
    rises again, so a fat forend and a thin magazine both matched at near-flat
    curls and the fatter one came out LESS closed than the thinner one.

    The measure that is monotonic is fingertip to PALM. A cylinder rests
    against the palm with the fingertips round its far side, so the tip ends up
    about one diameter from the palm contact point -- and that distance falls
    steadily as the fingers close, all the way from flat to fist, so there is
    exactly one curl that produces it.

    The thumb is solved afterwards against the settled fingers, opposing across
    the object, and for that the tip-to-tip measure is right: the two are on
    opposite sides of it."""
    want = diam_cm * CM

    best = None
    for c in range(0, 100, 5):
        for f in ("INDEX", "MIDDLE_F", "RING", "PINK"):
            set_finger(f, c, clamp=False)
        err = abs(wrap_gap() - want)
        if best is None or err < best[0]:
            best = (err, c)
    _, c = best
    for f in ("INDEX", "MIDDLE_F", "RING", "PINK"):
        set_finger(f, c, clamp=False)

    tbest = None
    for th in range(0, 70, 5):
        set_finger("THUMB", th, clamp=False)
        err = abs(tip_gap() - want)
        if tbest is None or err < tbest[0]:
            tbest = (err, th)
    _, th = tbest
    rest_all()
    note = "  (rig minimum, target unreachable)" if best[0] / CM > 0.5 else ""
    print(f"  wrap  {diam_cm}cm -> fingers {c} thumb {th}  "
          f"off by {best[0]/CM:.2f}cm palm, {tbest[0]/CM:.2f}cm thumb{note}")
    return [c, c, c, c, th]


# ---------------------------------------------------------------------------
# FIND THE POSES THE ANIMATOR ALREADY MADE
#
# Everything above this line builds hand shapes out of five curl angles. That
# was always the second-best option and the results said so: fingertips through
# the palm, last segments standing up out of a closed fist, an adduction solver
# chasing an objective that kept finding new ways to be degenerate. Every one of
# those is a symptom of deriving a hand from numbers.
#
# The source carries 1278 authored frames of somebody animating this exact rig.
# A real fist is in there, correctly folded, with every joint doing what it
# should -- including the ones the synthetic path never drove at all. So the
# poses are FOUND rather than invented: each slot describes what it wants in
# terms that can be measured, every source frame is measured once, and the best
# match wins.
#
# The synthetic curls stay as the fallback for any slot the source has no answer
# for, and the chosen frame numbers are printed so a bad match is visible rather
# than mysterious.
# ---------------------------------------------------------------------------

# The bones that carry the hand itself rather than the shape of it.
ROOT_BONES = ("Root_joint", "HANDPALM_joint")

def apply_source(n, pose_only=False):
    """Put the rig into authored source frame n (1-based).

    pose_only strips the root motion, and a pose MUST use it. An authored frame
    holds where the animator's whole hand was and which way it was facing at
    that instant, because the clip is a performance and the hand travels through
    it. Lifted wholesale into a pose slot, that arrives as the hand shifting a
    few centimetres and rolling over whenever the pose changes -- a grip that
    backs the palm away from you, a punch whose wrist pivots backwards.

    Where the hand is and which way it points belongs to the controller and to
    MODELDEF. What an authored frame is wanted for is the fingers."""
    for pb in arm.pose.bones:
        if pose_only and pb.name in ROOT_BONES:
            pb.location = (0.0, 0.0, 0.0)
            pb.rotation_quaternion = (1.0, 0.0, 0.0, 0.0)
            pb.scale = (1.0, 1.0, 1.0)
            continue
        loc, rot, sca = source_frames[n - 1][pb.name]
        pb.location = loc
        pb.rotation_quaternion = rot
        pb.scale = sca
    bpy.context.view_layer.update()

def _palm_dist(f):
    """Fingertip distance from the palm. Small means closed."""
    tip = M @ arm.pose.bones[f"{f}_{TIPSEG}_joint"].tail
    ab = PALM_B - PALM_A
    t = max(0.0, min(1.0, (tip - PALM_A).dot(ab) / ab.dot(ab)))
    return (tip - (PALM_A + ab * t)).length

def measure_frame():
    """Everything a pose selector might want to ask about the current pose."""
    m = {}
    for f in FINGER4 + ("THUMB",):
        m[f] = _palm_dist(f)
    m["pinch"] = ((M @ arm.pose.bones[f"INDEX_{TIPSEG}_joint"].tail)
                - (M @ arm.pose.bones[f"THUMB_{TIPSEG}_joint"].tail)).length
    tips = [M @ arm.pose.bones[f"{f}_{TIPSEG}_joint"].tail for f in FINGER4]
    m["splay"] = sum((tips[i + 1] - tips[i]).length for i in range(3))
    # Through the palm: a tip that has crossed to the far side of it.
    m["through"] = min(_palm_dist(f) for f in FINGER4)
    return m

print(f"=== measuring {len(source_frames)} authored frames ===")
SRC = []
for n in range(1, len(source_frames) + 1):
    apply_source(n, pose_only=True)
    SRC.append(measure_frame())
rest_pose()

# Every measurement normalised to its own range across the clip, so a selector
# can say "as closed as this hand gets" and "thumb as far out as it goes" in the
# same breath and have the two weigh equally. Without this the raw units decide,
# and whichever quantity happens to be numerically larger silently wins -- which
# is how the fist, the trigger finger and the thumb-out fist all came back as
# the same frame.
def _rng(key):
    lo = min(m[key] for m in SRC)
    hi = max(m[key] for m in SRC)
    return lo, max(1e-9, hi - lo)

_curl_lo, _curl_sp = None, None
for m in SRC:
    m["fingers"] = sum(m[f] for f in FINGER4)
_R = {k: _rng(k) for k in ("fingers", "INDEX", "MIDDLE_F", "RING", "PINK",
                           "THUMB", "pinch", "splay")}

def norm(m, key):
    """0 at this clip's minimum for that measurement, 1 at its maximum."""
    lo, sp = _R[key]
    return (m[key] - lo) / sp

def closedness(m):
    """0 = as open as this clip ever gets, 1 = as closed."""
    return 1.0 - norm(m, "fingers")

def three(m):
    """How closed the three non-index fingers are, 0 open .. 1 closed.

    The LEAST closed of the three, not their average. An average lets one finger
    stand straight up and hide behind the other two: a frame with the middle
    finger extended and the ring and little fingers curled averages out as a
    perfectly good grip, and what you get on screen is a hand throwing up two
    fingers. Taking the minimum means all three have to be down before the frame
    counts as closed, which is what the phrase was always supposed to mean."""
    return 1.0 - max(norm(m, "MIDDLE_F"), norm(m, "RING"), norm(m, "PINK"))

def index_shut(m):
    return 1.0 - norm(m, "INDEX")

def thumb_out(m):
    return norm(m, "THUMB")

print(f"  clip range: fingers {_R['fingers'][0]/CM:.1f}..{(_R['fingers'][0]+_R['fingers'][1])/CM:.1f}cm"
      f" from the palm, pinch {_R['pinch'][0]/CM:.2f}..{(_R['pinch'][0]+_R['pinch'][1])/CM:.2f}cm")

# Minimum clearance a fingertip must keep from the palm for a frame to be
# usable. The animator's own poses respect the hand's geometry, so this only
# rejects frames caught mid-transition with a tip passing through it.
MIN_CLEAR = FINGER_RADIUS

_taken = {}

# How different a frame must be from every pose already chosen.
#
# Refusing only the exact frame was not enough, and the result was obvious in
# hindsight: the fist landed on 689 and the trigger-pulled grip on 688, adjacent
# frames whose measurements agree to two decimal places. Three more poses came
# out of frames 311, 312 and 313. A clip is continuous, so the frame beside a
# good match is very nearly as good a match -- and picking it gives you two
# slots holding one hand.
#
# Measured in pose space rather than in frame numbers, because a clip can hold
# two genuinely different hands four frames apart and the same hand for two
# hundred. Distance is over the normalised measurements, so it means "how
# differently is this hand shaped" and not "how far apart were they filmed".
# A PREFERENCE, not a wall.
#
# As a hard rule at 0.35 this refused everything after the seventh pick and sent
# thirteen poses back to the synthetic path -- worse than the duplicates it was
# meant to stop. The clip turns out to have less measured variety than its 1278
# frames suggest: it is one long weapon-handling performance, so most of it is
# variations on a grip and the useful poses are genuinely close together.
#
# So closeness is penalised rather than forbidden. A frame that repeats one
# already taken has to be a much better match than a fresh one to win, and when
# nothing fresh exists the pose still gets the best hand available instead of
# falling back to arithmetic.
MIN_SEPARATION = 0.22
CROWDING = 2.5

_SEP_KEYS = ("fingers", "INDEX", "MIDDLE_F", "RING", "PINK", "THUMB", "pinch")

def pose_distance(a, b):
    return max(abs(norm(a, k) - norm(b, k)) for k in _SEP_KEYS)

def pick(name, score, unique=True, require=None):
    """Lowest score wins, among frames that are usable, not a near-repeat of
    something already chosen, and that actually MEET the pose's requirements.

    The requirement is the important half. Without it the picker always returns
    something, and "something" for a pose the clip does not contain is the
    least-bad wrong answer -- which is how a fist-with-the-thumb-clear came back
    as a fully open hand. This clip only ever puts the thumb out when the hand
    is open, so that pose is genuinely not in it, and the honest result is to say
    so and let the synthetic one stand."""
    best = None
    for i, m in enumerate(SRC):
        n = i + 1
        if m["through"] < MIN_CLEAR:
            continue
        if require is not None and not require(m):
            continue
        # Crowding is a preference, but exact repeats stay forbidden: once the
        # requirement filters narrow the pool, the soft penalty stops being
        # enough and two slots land on the identical frame, which is one pose
        # and a wasted slot.
        if unique and n in _taken:
            continue
        v = score(m)
        if unique and _taken:
            near = min(pose_distance(m, SRC[t - 1]) for t in _taken)
            if near < MIN_SEPARATION:
                v += (MIN_SEPARATION - near) * CROWDING
        if best is None or v < best[0]:
            best = (v, n)
    if best is None:
        print(f"  {name:<10} nothing matched -- keeping the synthetic pose")
        return None
    n = best[1]; m = SRC[n - 1]
    _taken[n] = name
    print(f"  {name:<10} source frame {n:<5d}  closed {closedness(m):.2f}"
          f"  3-4-5 {three(m):.2f}  index {index_shut(m):.2f}  thumb-out {thumb_out(m):.2f}")
    return n

print("=== choosing a source frame per pose ===")
POSE_SOURCE = {}

# NOTE: "open" is deliberately absent. Model frame 0 must stay the RIG'S REST
# POSE, not the flattest authored frame -- the MODELDEF placement, the scale
# calibration and the bounds are all dialled against it, and swapping in an
# authored frame that merely looks open moves every one of them.

# A fist: everything shut, and the four fingers sitting together rather than
# fanned. Weighted so closedness dominates and splay only breaks ties.
POSE_SOURCE["fist"]     = pick("fist",     lambda m: -closedness(m) + norm(m, "splay") * 0.2,
                                   require=lambda m: three(m) > 0.8 and index_shut(m) > 0.8)

# Index out, the other three in -- the shape of a hand on a grip with the finger
# off the trigger, and of a finger gun.
POSE_SOURCE["point"]    = pick("point",    lambda m: -three(m) + index_shut(m) + thumb_out(m),
                                   require=lambda m: three(m) > 0.65 and index_shut(m) < 0.45)

# Index alone on an otherwise open hand.
POSE_SOURCE["trigger"]  = pick("trigger",  lambda m: -index_shut(m) + three(m),
                                   require=lambda m: three(m) < 0.35 and index_shut(m) > 0.45)

# The frame where the index and thumb tips come closest.
POSE_SOURCE["pinch"]    = pick("pinch",    lambda m: norm(m, "pinch"))

# A fist with the thumb clear of it, for working a magazine release.
POSE_SOURCE["thumbout"] = pick("thumbout", lambda m: -closedness(m) - thumb_out(m),
                                   require=lambda m: three(m) > 0.7 and thumb_out(m) > 0.55)

# ---- on a weapon -------------------------------------------------------
# This is a weapon-handling rig, so the grips are in here somewhere. All four
# want the three lower fingers shut; they differ in the index and the thumb.
POSE_SOURCE["gripfire"] = pick("gripfire", lambda m: -three(m) - index_shut(m) + thumb_out(m),
                                   require=lambda m: three(m) > 0.7 and index_shut(m) > 0.7)
POSE_SOURCE["grip_tu"]  = pick("grip_tu",  lambda m: -three(m) + index_shut(m) - thumb_out(m),
                                   require=lambda m: three(m) > 0.65 and thumb_out(m) > 0.5)

# Index resting ON the trigger: halfway, not straight and not pulled.
def _ready(thumb_sign):
    def f(m):
        return -three(m) + abs(index_shut(m) - 0.5) * 2.0 + thumb_sign * thumb_out(m)
    return f
POSE_SOURCE["ready_td"] = pick("ready_td", _ready(+1.0),
                                   require=lambda m: three(m) > 0.65 and 0.3 < index_shut(m) < 0.75)
POSE_SOURCE["ready_tu"] = pick("ready_tu", _ready(-1.0),
                                   require=lambda m: three(m) > 0.65 and 0.3 < index_shut(m) < 0.75 and thumb_out(m) > 0.4)
POSE_SOURCE["fire_tu"]  = pick("fire_tu",  lambda m: -three(m) - index_shut(m) - thumb_out(m),
                                   require=lambda m: three(m) > 0.7 and index_shut(m) > 0.7 and thumb_out(m) > 0.4)

# ---- holding things ----------------------------------------------------
# The interaction poses come out of the clip too. This rig was animated
# handling a weapon, so a hand on a magazine and a hand on a forend are both in
# there somewhere, done properly, by someone who could see what they were doing.
#
# Sized by the pinch measurement where the object is held in the fingers, and by
# how far the hand has closed where it is wrapped round something. The targets
# are the same real-world sizes the synthetic solver used -- what changes is
# that the answer is now looked up rather than computed.
print("=== choosing a source frame per hold ===")
HOLD_SOURCE = {}

def by_pinch(cm, tuck):
    """Held in the fingertips at roughly this width, with the rest of the hand
    closed by `tuck` (0 loose .. 1 shut)."""
    want = cm * CM
    def f(m):
        return abs(m["pinch"] - want) / _R["pinch"][1] + abs(three(m) - tuck)
    return f

def by_wrap(closed, thumb):
    """Wrapped round something, closed this far, thumb placed this way."""
    def f(m):
        return abs(closedness(m) - closed) + abs(thumb_out(m) - thumb) * 0.7
    return f

# A hand wrapped round something has all three lower fingers on it. Nothing that
# leaves one standing up qualifies, however well it scores otherwise.
WRAPPED = lambda m: three(m) > 0.55
PINCHED = lambda m: three(m) > 0.3

HOLD_SOURCE["hold_round"]    = pick("hold_round",    by_pinch(1.0, 0.85), require=PINCHED)
HOLD_SOURCE["hold_shell"]    = pick("hold_shell",    by_pinch(2.0, 0.60), require=PINCHED)
HOLD_SOURCE["insert"]        = pick("insert",        by_pinch(2.0, 0.75), require=PINCHED)
HOLD_SOURCE["hold_slide"]    = pick("hold_slide",    by_pinch(2.6, 0.35), require=PINCHED)
HOLD_SOURCE["hold_mag"]      = pick("hold_mag",      by_wrap(0.90, 0.10), require=WRAPPED)
HOLD_SOURCE["hold_foregrip"] = pick("hold_foregrip", by_wrap(0.85, 0.70), require=WRAPPED)
HOLD_SOURCE["hold_forend"]   = pick("hold_forend",   by_wrap(0.70, 0.35), require=WRAPPED)
HOLD_SOURCE["support"]       = pick("support",       by_wrap(0.75, 0.05), require=WRAPPED)
HOLD_SOURCE["reach"]         = pick("reach",         lambda m: closedness(m) + thumb_out(m) * -0.5)
for k, v in list(HOLD_SOURCE.items()):
    if v is None:
        del HOLD_SOURCE[k]

for k, v in list(POSE_SOURCE.items()):
    if v is None:
        del POSE_SOURCE[k]

print("=== solving interaction poses ===")
HOLD_POSES = [
    # A single cartridge, held in the fingertips. The other fingers tuck in --
    # there is nothing for them to do, and an open hand would drop it.
    # The pinch itself comes out the same for both of these -- the rig cannot
    # close tighter than about 2.2cm, so a 9mm round and a 12-gauge shell ask
    # for the same fingertips. What separates them is the rest of the hand: a
    # round is held delicately with the other fingers tucked right in, a shell
    # is a fuller grip. That difference is what makes them readable apart.
    ("hold_round",    solve_pinch(1.0, [80, 80, 80])),
    # A 12-gauge shell: twice the round, and the difference is visible.
    ("hold_shell",    solve_pinch(2.0, [55, 50, 45])),
    # Pushing that shell into the loading gate. The thumb drives it home while
    # the pinch holds, so this is the shell pose with the thumb carried
    # further -- which is what lets it blend cleanly out of hold_shell instead
    # of re-forming the whole hand. Filled in below, once the shell is solved.
    ("insert",        None),
    # Thumb and index on the serrations, the rest deliberately loose. Racking a
    # slide is a pinch and a pull, not a grab.
    ("hold_slide",    solve_pinch(2.6, [40, 35, 30])),
    # A magazine, wrapped in the palm rather than pinched -- you carry one in
    # the whole hand, base down, and feed it in.
    ("hold_mag",      solve_wrap(2.4)),   # thumb overridden below
    # A vertical foregrip, as on an SMG.
    ("hold_foregrip", solve_wrap(3.2)),
    # A shotgun forend: the fattest thing the hand closes on.
    ("hold_forend",   solve_wrap(4.5)),
    # Fingers splayed, about to take hold of something. Negative curl is
    # extension, which makes this the one pose that opens PAST rest -- and that
    # is what makes a reach read as reaching rather than as a hand that stopped
    # moving.
    ("reach",         [-12, -12, -12, -12, -15]),
    # The support hand on a handgun, and the one pose here that is AUTHORED
    # rather than solved, because the solver's premise does not hold: it models
    # a cylinder resting against the palm, and this hand is wrapped round
    # another hand. Asked for 6.5cm -- a fist with a pistol in it -- it
    # returned a curl of 5 degrees, an almost flat hand, because at that size
    # the fingertips are already the right distance away before they bend at
    # all. Correct arithmetic, wrong model.
    #
    # What a support hand actually does is lie ACROSS the backs of the firing
    # hand's fingers, following the same curve, so it ends up curled about as
    # far as the hand it is wrapping. The index is a little straighter than the
    # rest: it sits forward, under the trigger guard.
    #
    # The thumb is the tell. A modern two-handed pistol hold points the support
    # thumb forward along the frame rather than wrapping it round the back --
    # wrapping it is the grip people are taught out of, and it would read here
    # as a second hand trying to take the gun off you.
    ("support",       [70, 75, 75, 75, 8]),
]
_shell = HOLD_POSES[1][1]
HOLD_POSES[2] = ("insert", [_shell[0], _shell[1], _shell[2], _shell[3], _shell[4] + 18])

# A magazine is thinner than the hand can close, so the wrap solver bottoms out
# on it and returns the same full curl as the foregrip -- two identical frames,
# which is a wasted pose. The thumb is what actually distinguishes them, and
# not arbitrarily: you hold a magazine to FEED it, thumb running ALONG the
# spine so it can push, where a foregrip is squeezed with the thumb wrapped
# right round. So the fingers stay as solved and the thumb is set to the job.
_mag = HOLD_POSES[4][1]
HOLD_POSES[4] = ("hold_mag", [_mag[0], _mag[1], _mag[2], _mag[3], 12])


# --- is the splay ours, or the animator's? ---------------------------------
# The fist shown for a mod's fist weapon is SOURCE frame 503, not the synthetic
# one. If the authored frame is the one that fans the fingertips apart, then no
# amount of axis work here changes it and the fix is to point POSE_FIST at the
# synthetic fist instead. Measured, not argued about.
def spread_of_source(n):
    rest_pose()
    for pb in arm.pose.bones:
        loc, rot, sca = source_frames[n - 1][pb.name]
        pb.location = loc; pb.rotation_quaternion = rot; pb.scale = sca
    bpy.context.view_layer.update()
    g = tip_spread(); rest_pose(); return g

def spread_of_curls(curls):
    rest_pose()
    for fi, fing in enumerate(FINGERS):
        set_finger(fing, curls[fi])
    bpy.context.view_layer.update()
    g = tip_spread(); rest_pose(); return g

print("=== fingertip splay: authored fist vs synthetic ===")
for n in (500, 503, 510, 600):
    if n - 1 < len(source_frames):
        g = spread_of_source(n)
        print(f"  authored source frame {n:<5d}  {g[0]:.5f} {g[1]:.5f} {g[2]:.5f}  total {sum(g):.5f}")
g = spread_of_curls([85, 85, 90, 90, 30])
print(f"  synthetic fist (pose 3)      {g[0]:.5f} {g[1]:.5f} {g[2]:.5f}  total {sum(g):.5f}")
g = spread_of_curls([0, 85, 90, 90, 25])
print(f"  synthetic grip (pose 1)      {g[0]:.5f} {g[1]:.5f} {g[2]:.5f}  total {sum(g):.5f}")

# --- author every frame in quaternion mode ---------------------------------
# One rotation mode for the whole action: rotation_mode is per bone, not per
# frame, so the synthetic poses and the captured source cannot use different
# ones.
for pb in arm.pose.bones:
    pb.rotation_mode = 'QUATERNION'
    pb.rotation_quaternion = (1.0, 0.0, 0.0, 0.0)
    pb.location = (0.0, 0.0, 0.0)
    pb.scale = (1.0, 1.0, 1.0)
bpy.context.view_layer.update()

def key_all(frame):
    for pb in arm.pose.bones:
        pb.keyframe_insert("location", frame=frame)
        pb.keyframe_insert("rotation_quaternion", frame=frame)
        pb.keyframe_insert("scale", frame=frame)

frame_no = 1
for i, (name, curls) in enumerate(POSES):
    scn.frame_set(frame_no)

    # An authored frame beats anything derived from curl angles, so if one was
    # found for this slot it is used verbatim -- every bone, every channel,
    # including the joints the synthetic path never touched.
    src = POSE_SOURCE.get(name)
    if src is not None:
        apply_source(src, pose_only=True)
        key_all(frame_no)
        print(f"  frame {i}: {name}  <- authored source frame {src}")
        frame_no += 1
        continue

    for pb in arm.pose.bones:
        pb.rotation_quaternion = (1.0, 0.0, 0.0, 0.0)
        pb.location = (0.0, 0.0, 0.0)
        pb.scale = (1.0, 1.0, 1.0)
    # Through set_finger rather than reimplemented, so an authored frame gets
    # exactly the hand the solvers above were measuring -- adduction included.
    for fi, fing in enumerate(FINGERS):
        set_finger(fing, curls[fi])
    key_all(frame_no)
    print(f"  frame {i}: {name}  (synthetic -- no authored frame matched)")
    frame_no += 1

SOURCE_BASE = frame_no - 1     # model frame index of source frame 1
for fi, frame in enumerate(source_frames):
    scn.frame_set(frame_no)
    for pb in arm.pose.bones:
        loc, rot, sca = frame[pb.name]
        pb.location = loc
        pb.rotation_quaternion = rot
        pb.scale = sca
    key_all(frame_no)
    frame_no += 1

print(f"  frames {SOURCE_BASE}..{frame_no - 2}: source animation ({len(source_frames)} frames)")

HOLD_BASE = frame_no - 1       # model frame index of HOLD_POSES[0]
for i, (name, curls) in enumerate(HOLD_POSES):
    scn.frame_set(frame_no)
    for pb in arm.pose.bones:
        pb.rotation_quaternion = (1.0, 0.0, 0.0, 0.0)
        pb.location = (0.0, 0.0, 0.0)
        pb.scale = (1.0, 1.0, 1.0)
    src = HOLD_SOURCE.get(name)
    if src is not None:
        apply_source(src, pose_only=True)
        key_all(frame_no)
        print(f"  frame {HOLD_BASE + i}: {name}  <- authored source frame {src}")
        frame_no += 1
        continue

    # Every one of these closes on something -- a round, a magazine, a forend --
    # so the palm ceiling does not apply. See set_finger.
    for fi, fing in enumerate(FINGERS):
        set_finger(fing, curls[fi], clamp=(name == "reach"))
    key_all(frame_no)
    print(f"  frame {HOLD_BASE + i}: {name}  {curls}  (synthetic)")
    frame_no += 1

total = frame_no - 1
scn.frame_start, scn.frame_end = 1, total
print(f"TOTAL {total} frames; source frame N is model frame {SOURCE_BASE} + (N - 1)")

# The ZScript constants, emitted rather than counted by hand. The whole point of
# appending is that nothing already wired up moves, and a base counted wrong
# would move all of the new ones at once.
with open(os.path.join(out_dir, "hand_frames.txt"), "w") as fh:
    fh.write(f"const SOURCE_BASE  = {SOURCE_BASE};\n")
    fh.write(f"const SOURCE_COUNT = {len(source_frames)};\n")
    fh.write(f"const HOLD_BASE    = {HOLD_BASE};\n")
    for i, (name, curls) in enumerate(HOLD_POSES):
        fh.write(f"const POSE_{name.upper():<13} = HOLD_BASE + {i};\n")
print("wrote hand_frames.txt")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import iqm_export
matfun = lambda prefix, image: prefix + os.path.splitext(image)[0]
bpy.ops.object.select_all(action='DESELECT')
arm.select_set(True); mesh.select_set(True)
bpy.context.view_layer.objects.active = mesh
out = os.path.join(out_dir, "hand_left.iqm")
iqm_export.exportIQM(bpy.context, out, "IQM", True, True, True, False, scale, matfun, False, "", False)
print(f"OK size={os.path.getsize(out)}")
