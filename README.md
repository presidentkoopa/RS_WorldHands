# RS_WorldHands

The VR hand system, lifted whole out of `RS_VR_Unified` on 2026-09-08.

Hands that exist in the world rather than on the HUD. They track the
controllers at headset rate, close on things, carry them, pass them between
each other, pull them in from across the room on a beam, throw them, and brace
one hand's weapon with the other.

## Do not load this beside RS_VR_Unified

All thirty classes here are still in Unified. Two classes of one name is a
fatal compile error, not a merge — so this package **replaces** Unified's hand
half rather than supplementing it. Load one or the other.

The wheel already left Unified as `RS_WeaponSelectionSystem`. What remains in
Unified after this is holsters, hardpoints and reload.

## What is in it

| | |
|---|---|
| source | 12 files, 7,426 lines, byte-identical to Unified's |
| classes | 29 in `zscript/hands/` + `RS_GripArbiterService` |
| handlers | 10, registered in `MAPINFO.txt` in their original order |
| cvars | 104 declared |
| menus | 14 pages, 331 rows |
| models | 9 MODELDEF blocks |

## The features, and where each one lives

| | |
|---|---|
| grab, hold, release | `rs_grab.zs`, `rs_held.zs` |
| what is grabbable, and as what | `rs_grabpolicy.zs` |
| **distance grab — the laser, the reel, the flick** | `rs_distance.zs` |
| **passing an object between hands** | `rs_held.zs` — `rs_hold_pass` |
| **two hands on one object** | `rs_held.zs` — `rs_hold_twohand` |
| throwing | `rs_throw.zs`, `rs_swing.zs` |
| where a released thing goes | `rs_route.zs` |
| the ovals, the colour flash, the beam | `rs_grabviz.zs` + `TRNSLATE.txt` |
| two-hand stabilize | `rs_stabilize.zs` |
| the world hands themselves | `handworld.zs`, `rs_hands.zs`, `rs_fist.zs` |
| who owns which hand | `zscript/arbiter/rs_griparbiter.zs` |

## Building

```powershell
.\build.ps1
```

Writes `RS_WorldHands.pk3` and then verifies it — nine checks, and a failure
throws rather than warning. Three of those checks exist specifically because
the spin-out nearly shipped that fault:

- **every cvar the code names is declared here.** Unified split the hand cvars
  across two regions of `CVARINFO.txt` — the obvious block at the top, and
  nineteen `rs_stab_*` stranded at the bottom *after the weapon wheel's
  section*. An undeclared cvar is not an error in ZScript, it is a zero.
- **every `OptionMenu` is reachable.** `RS_HandsOptions` links only the two
  placement pages; the other ten hung off `RS_VRUnifiedOptions`, which did not
  come across. Orphaned menus compile clean and read in a headset as the
  feature having been removed.
- **every MODELDEF asset resolves.** A model that cannot find its mesh draws
  nothing and logs nothing.

## Two things that will bite

**Placement sliders are MODELDEF `PlacementCVars` and nothing else.**
`rs_hw_main`, `rs_hw_off`, `rs_grab_m`, `rs_grab_o`, `rs_stab`. The renderer
reads them every frame it draws, which is why they move the model *while the
menu is open*. Nothing in ZScript may write these actors' `Scale`, `angle`,
`pitch` or `roll` — two writers on one transform reads exactly like a dead
slider. See `EngineDocs5.0.x/PLACEMENT.md`.

**`TNT1` is not an invisible sprite.** It instructs the engine to skip the
actor entirely, before any model is considered. A perfect MODELDEF then draws
nothing and logs nothing. `handworld.zs:168` uses `PIST A -1` for this reason
and says so on the line.

## No KEYCONF

Unified's is entirely holster, anchor-grip and wheel aliases; not one line of
it is a hand. The three netevents this package listens for — `rs-stab-print`,
`rs-stab-reset-weapon`, `rs-stab-reset-all` — are fired by `SafeCommand` rows
in MENUDEF, so there is nothing to bind.

## Working with RS_VRBody

Both put a hand on the controller from the same `hand_left.iqm`, in the same
follow-hand frame, at the same scale. Loading both without arranging something
gives you **two hands per controller**, separated by however far the two sets
of placement sliders disagree — and neither looks broken enough to notice fast.

The arrangement, as of 2026-09-08:

- **RS_VRBody stands its own hands down** whenever `RS_HandWorldMain` exists.
  One hand per controller, and it is this one, because this one can grab. The
  toggle is `rs_body_defer_hands` (default on); off puts the body's hands back
  and you get both.
- **RS_VRBody keeps saying what shape the hand should be in.** That is a
  body-level fact — a holster being reached into, a ladder, a pickup — so it
  survives the slot being handed over. It publishes to
  `rs_body_poseframe_main` / `_off` and `handworld.zs` consumes them as one
  more publisher, below `poseHold` and above the controllers.

**It publishes a frame number, not a pose index, and that is not incidental.**
The two mods do not share a pose vocabulary:

| index | RS_VRBody `RPOSE_` | RS_WorldHands `POSE_` |
|---|---|---|
| 0–6 | `OPEN`…`GRIPFIRE` | identical |
| 7 | `GRIP` | `GRIP_TU` |
| 8 | `GRIP_TU` | `READY_TD` |
| 9+ | `HOLD_ROUND`…`SALUTE` (contiguous to 19) | `READY_TU`, `FIRE_TU`, then a jump to 1289 |

They agree up to 6 and diverge from 7 — which is every pose worth having. An
index passed across that boundary makes the wrong shape, silently, and only for
the interesting poses. So RS_VRBody resolves the pose against whichever hand
mesh is actually on the controller and publishes the result. `poseHold` was
already a frame number rather than a set of weapon flags for the same reason.

**Only one writer touches `ModelFrame`.** `RS_HandWorldBase.Tick` runs its own
blend and writes all three frame fields every tic. RS_VRBody's `poseHand()`
writes the identical three. That is why the body defers the *pose* as well as
the actor — two writers a tic apart is what made the placement sliders read as
dead for a night.

## Optional neighbours

Reached by string through `ServiceIterator`, so each is absent-safe and none is
named at compile time in either direction:

- `RS_WeaponArchetypeService` — `rs_stabilize.zs:192`, sizes the brace oval
  from a weapon's archetype record.
- `RS_GripArbiterService` — ships **here**, and is also consumed by
  `RS_Holsters.zs` and `rr_sequence.zs` in whatever package those live in.

**Asked of any mod that ships one** (every Service whose class name contains the
string; with none loaded, the hands behave exactly as if the question did not exist —
all three live beside each other in `rs_grabpolicy.zs`):

- `GrabBecomeService` — `GetObject("grab.become", hand, thing)`: hand back a
  different actor to be taken in the thing's place (`RS_GrabPolicy.Become`).
- `GrabTakeService` — `GetInt("grab.take", intArg hand, doubleArg 1 caught / 0 off
  the floor, objectArg thing)`: answer 1 to use the thing up instead of holding it,
  asked before the built-in ammo/health/weapon rules at both a floor grab and a catch
  (`RS_GrabPolicy.AskTake`).
- `GrabEventService` — `GetInt("grab.event", stringArg event, intArg hand, doubleArg
  1 from the air / 0 off the floor, objectArg thing)`, answer ignored:
  `pull.lock`, `pull.unlock`, `pull.start`, `pull.caught`, `pull.refused`,
  `pull.missed`, `pull.blocked`, `pull.aborted` (`RS_GrabPolicy.Tell`).
