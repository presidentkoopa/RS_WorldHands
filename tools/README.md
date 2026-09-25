# RS_WorldHands tools — how the hand model is built

Restored 2026-09-25 from `E:\DOOMWork\_old\RS_Hands\tools`, which is where they had been left when
the package was reorganised. `HANDS_AND_POSES.md` names `tools_export_poses.py` at this path, and
until now the folder was empty.

`build.ps1` treats `^tools/` as stray, so nothing here is packed.

---

## THE CHAIN, END TO END

```
hand_final.fbx                     E:\oldshit\DXR-main\models\hands\ (24 MB)
      |  tools_export_poses.py     Blender. 11 synthetic poses at 0..10, then the
      |                            source animation verbatim from frame 11.
      v
hand_left.iqm                      1298 frames
      |  iqm_append_pose.py        appends frames 1298 (REACH-CLAW) and 1299 (SALUTE)
      |
      |  RS_VRBody/tools/ermac/build_left_poses.py
      |                            splices Ermac's fitted animation on: 1298 + f is his
      v                            off hand, 1494 + f his gun hand
hand_left_poses.iqm                1705 frames -- THE MODEL MODELDEF LOADS
```

`hand_ermac.iqm` is the same 1705 frames on the glove mesh. `hand_left.iqm` (1298 frames) is the
pre-Ermac model and is **stale** — the retired part rig still points at it, which is 407 frames it
cannot reach.

---

## THE FILES

| File | What it does | Runs under |
|---|---|---|
| `tools_export_poses.py` | Bakes the hand poses from the FBX. Frame 0 must stay the rest pose — the MODELDEF placement is dialled against it. | **Blender** (`bpy`) |
| `iqm_append_pose.py` | Appends a pose to a finished IQM without re-baking. How REACH-CLAW and SALUTE got in. | python |
| `iqm_inspect.py` | Joints, poses, anims, frame counts of an IQM. | python |
| `render_wired_poses.py` | Renders each named pose. **Carries the authoritative name→index table** (see below). | python |
| `make_hero.py` | Composes the salute at render time — the fist with the middle finger's own straight rotations. Superseded by the baked `POSE_SALUTE`; kept because it is the worked example of composing a pose from two others. | python |

**`make_hero.py` has a stale `sys.path` line** pointing at a scratch folder from a 2026 session
(`iqmrender`). It will not run as-is. Left as written rather than guessed at.

---

## THE POSE TABLE

From `render_wired_poses.py`, which is the only place the names and indices live together:

| Frame | Name | What |
|---|---|---|
| 0 | `POSE_OPEN` | nothing held — **rest, MODELDEF is dialled against this** |
| 1 | `POSE_POINT` | grip (3-4-5 closed), index and thumb out |
| 2 | `POSE_TRIGGER` | index curled, empty hand |
| 3 | `POSE_FIST` | all closed — melee punch |
| 4 | `POSE_PINCH` | thumb to index |
| 5 | `POSE_THUMBOUT` | fist, thumb clear — mag release |
| 6 | `POSE_GRIPFIRE` | grip + fire (index curled, thumb parked) |
| 7 | `POSE_GRIP_TU` | grip, thumb up |
| 8 | `POSE_READY_TD` | finger on trigger, thumb down |
| 9 | `POSE_READY_TU` | finger on trigger, thumb up |
| 10 | `POSE_FIRE_TU` | fire, thumb up |
| 513 | `POSE_FIST_AUTHORED` | the animator's fist, kept for comparison |
| 1289 | `POSE_HOLD_ROUND` | one cartridge, fingertips |
| 1290 | `POSE_HOLD_SHELL` | a shell — fuller grip |
| 1291 | `POSE_INSERT` | thumb driving it home |
| 1292 | `POSE_HOLD_SLIDE` | pinched on the serrations |
| 1293 | `POSE_HOLD_MAG` | thumb along the spine |
| 1294 | `POSE_HOLD_FOREGRIP` | vertical foregrip |
| 1295 | `POSE_HOLD_FOREND` | pump — a fat cylinder |
| 1296 | `POSE_REACH` | fingers splayed |
| 1297 | `POSE_SUPPORT` | round the firing hand |
| 1298 | `POSE_REACH_CLAW` | spread, relaxed — source frame 241 verbatim |
| 1299 | `POSE_SALUTE` | middle finger extended, thumb clear |

**Ermac's gun grips are NOT in this table and are NOT absolute frame numbers.** MODELDEF:92 lists
them as offsets into his gun-hand bank, which begins at **1494**:

| Gun | MODELDEF says | Actual frame |
|---|---|---|
| pistol | 6 (trigger 7–13) | **1500** (trigger **1501–1507**) |
| chainsaw | 29 | **1523** |
| shotgun | 30 | **1524** |
| super shotgun | 47 | **1541** |
| chaingun | 84 / 85 | **1578 / 1579** |
| rocket launcher | 95 / 96 | **1589 / 1590** |
| plasma rifle | 106 / 107 | **1600 / 1601** |
| BFG | 113 / 114 | **1607 / 1608** |

An earlier draft of `HANDS_AND_POSES.md` copied the left column as absolute frames. Frame 6 is
`POSE_GRIPFIRE` and frame 30 is an unnamed frame of the source animation, so every one of those
grips would have worn the wrong shape. Corrected there on 2026-09-25.

---

## TWO WARNINGS BEFORE RE-RUNNING THE BAKE

1. **This copy of `tools_export_poses.py` bakes 11 poses. The shipped model carries more.** Its
   `POSES` list (`:53`) has 11 entries; MODELDEF:51 records that `hand_left` carries 20 where an
   older model carried 11, and warns that switching to the older one "would have silently lost nine
   poses". So **this file is one revision behind the model on disk.** Re-running it as-is would
   regenerate the 11 and lose banks C and D. Bank C (1289–1297) and bank D (1298–1299) would have to
   be re-appended with `iqm_append_pose.py`, and the Ermac splice re-run.
2. **Frame 0 is load-bearing.** Every MODELDEF placement number in this package is dialled against
   the rest pose. A bake that moves frame 0 moves every hand in the game.

**So do not re-bake to add a pose.** Append it with `iqm_append_pose.py`, which is what that tool
exists for and how the last two poses got in.
