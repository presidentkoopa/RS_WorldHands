# VR Melee: review of the first plan, and the full system

This builds on `VR_MELEE_DESIGN.md` and replaces its scope. The first plan is a good **hit filter**: gates, locks, one hit per swing. It is not yet a **melee system**. It only knows "a point on a hand moved fast into a cylinder". Everything below is what that misses, and how to build it properly now that there is an IK body and XR trackers are coming.

---

## Part A: what the first plan does not cover

### A1. Things that make it hacky or exploitable

| Gap | What goes wrong | Fix (Part B section) |
| --- | --- | --- |
| **Hitting through walls** | The swept segment is only tested against monsters. Swing your arm through a wall or a closed door and you hit the imp behind it. | Line trace from the shoulder to the contact point; the hand stops at walls (B4) |
| **Hands pass through everything** | The drawn hand goes into walls, enemies and doors. The "hold the hand at contact for 2 tics" item is a patch for this, not a fix. | A physical hand that stops at surfaces (B4) |
| **Wrist flick** | Speed is measured at the controller. A small, fast flick of the wrist passes the 2.5 m/s gate with 5 cm of travel. That is the real "infinite attack", and the locks don't stop it because each flick re-arms. | A travel requirement, plus the swing must come from the arm (elbow and shoulder speed from IK) (B3) |
| **Running with a fist out** | World velocity includes your locomotion. Stick-run into an imp with your arm held out and the speed gate passes. | Measure the swing relative to the body; add locomotion only as a deliberate "charge" bonus (B3) |
| **Wrong speed for guns** | The muzzle of a shotgun swung from the wrist moves far faster than the hand. The plan uses hand speed for the gun's strike point. | Point velocity = hand velocity + angular velocity × lever arm (B3) |
| **Moving targets** | A charging pinky running into a still fist counts as a slow hit, and a fleeing one as a fast one. | Use relative velocity: strike point minus target (B3) |
| **Tic rate vs render rate** | Game logic runs at 35 Hz; the hands are tracked at 90 Hz or more. A curved swing (hook, uppercut) is sampled as a straight chord between tics and misses targets near the arc. | Record the hand pose every render frame into a buffer; the tic tests the whole buffered path (B3) |
| **Multiplayer timing** | The hit is decided locally against where the target was on this machine. | Keep the network event, but include the tic and the target's position, and let the receiver reject a hit that is off by more than the target's radius (B8) |

### A2. Things a real melee system has that the plan doesn't

| Missing | Why it matters |
| --- | --- |
| **Only the fist and one gun point can hit** | No elbows, forearms, the gun's barrel sweeping sideways, knees, feet, or headbutts. The IK body now gives all of these. |
| **No hit location** | Doom monsters are one cylinder. There are no head hits, no hits from behind, no low hits. |
| **No weight** | Damage is speed only. A swing with a BFG and one with a pistol feel the same apart from a multiplier. Two hands on a rifle butt-stroke should hit harder than one. |
| **Reactions are only "pain state"** | No stagger that scales with the hit, no knockdown, no directional knockback, no lift from an uppercut. |
| **No defence** | Monsters melee you (imp claw, pinky bite, revenant punch, baron swipe). You can't block, parry or duck them. Melee without defence is only half a system. |
| **No grabs** | Grabbing an enemy, holding it at arm's length, throwing it, or pulling it into a punch. It needs to share the grip arbiter with weapons. |
| **No kicks or stomps** | Brutal Doom has a kick. **It cannot be driven by measured foot speed** -- see the kick note in B6. |
| **Blades and the chainsaw** | Slash vs stab, edge direction, a blade that sticks in. The chainsaw is continuous contact, which breaks "one hit per swing" on purpose. |
| **Non-monster targets** | Barrels, breakable decorations, switches (punching a switch should press it), other players, friendly monsters. |
| **Seated play and accessibility** | Short reach, one-handed, seated. The button fallback covers some of this; reach scaling doesn't exist. |
| **Per-body tuning** | Arm lengths differ between the seven bodies. Speeds are in real m/s (fine); reach and contact sizes are in map units and must come from the worn body. |
| **Debug view** | Log lines exist; a drawn view of hit volumes and swing paths doesn't. Tuning melee blind is slow. |

---

## Part B: the full system

One idea runs through it: **strikers hit targets, impulse decides the result**. Every body part or held thing that can hit is a striker. Every contact produces an impulse. Damage, stagger and knockback all come from that impulse and the target's own resistances. There are no per-move special cases, so there is nothing to exploit between them.

### B1. Strikers

A striker is a capsule (two points and a radius) attached to something that moves.

| Striker | Capsule | Source of position | Source of velocity |
| --- | --- | --- | --- |
| Fist / knuckles | across the knuckles | tracked hand | tracked (OpenXR) |
| Palm | palm centre, flat | tracked hand | tracked |
| Forearm | elbow to wrist | IK | tracked hand + IK elbow, blended |
| Elbow | small sphere at the elbow | IK, or elbow tracker | IK elbow delta, or tracker |
| Gun parts | butt, barrel, muzzle from the card | tracked hand + card | hand + angular × lever arm |
| Blade | edge line from the card | tracked hand + card | same, plus edge normal |
| Foot | toe to heel | foot tracker, or IK leg | tracker (none without one) |
| Knee | small sphere | knee tracker, or IK | tracker or IK delta |
| Head | sphere at the forehead | HMD | HMD velocity |
| Body | torso capsule | waist tracker, or body root | waist tracker or HMD |

**Trust rule:** only tracked points are trusted for **speed**. IK-solved points (elbow and knee without a tracker) are trusted for **where** they are, not for how fast, because the solver can snap. An IK striker takes its speed from the nearest tracked point.

Each striker has: `kind` (blunt, edge, point, saw), `mass` (see B3), `radius`, and which grip state enables it (a fist needs grip squeezed, a palm needs it open).

### B2. Targets and hit location

Doom actors stay cylinders for collision. Melee adds a **hit zone** from where on the cylinder the contact lands:

- **Height:** the top ~20% (from the monster's melee data, see C3) is the head; the bottom 25% is the legs; the rest is the body.
- **Side:** compare the contact direction with the monster's facing: front, side, back.
- Zones multiply damage and stagger (head ×1.5 damage ×2 stagger; back ×1.5 stagger; legs ×2 knockdown chance).
- Brutal Doom already has head and decapitation deaths. Pass the zone to it (a damage type such as `MeleeHead`) instead of inventing new gore.

Also targets: barrels and breakables (damage, no reaction), switches and doors (a contact from a fist or palm = use, no speed gate), other players (only with friendly fire on), corpses (BD corpse kicking, no damage).

### B3. The swing: speed, travel, impulse

**Sample at render rate. FOR HANDS THIS IS ALREADY BUILT** -- the throwing lane's engine ring, `level.HandVelAtPoint(hand, offsetMapUnits, when)` with `RS_HAND_NOW / RS_HAND_PEAK / RS_HAND_THROW`, plus `level.HandPeakAgeMs(hand)`. A gun's strike point is not a second ring, it is a different `offsetMapUnits` into that one, and the cross product is already done in the XR frame so pixelstretch never corrupts it. Its hand index is PHYSICAL while script reads are ABSTRACT; do the swap or the whole path goes silently dead.

What still has to be sampled here is everything that is not a hand: elbows, forearms, the head and the feet. Each tic, the melee code sweeps each striker's capsule along the **whole buffered path**, not a single chord. This is the only fix for curved swings that doesn't mean running game logic at 90 Hz.

**Point velocity.** For anything held: `v_point = v_hand + ω_hand × (point - hand)`. OpenXR gives angular velocity alongside linear (`XrSpaceVelocity.angularVelocity`). If the engine doesn't pass it to ZScript yet, add it next to `AttackVel`.

**Relative to the body.** `v_swing = v_point - v_body`, where `v_body` is the waist tracker's velocity, or the HMD's horizontal velocity if there is none, or the pawn's velocity. Locomotion adds nothing unless `rs_melee_charge 1`, which adds a capped part of it back for a deliberate running punch.

**Relative to the target.** `v_rel = v_swing - v_target` along the contact normal. This is what goes into the gates.

**Travel gate (kills the wrist flick).** The striker must have moved at least `rs_melee_min_travel` (**15 cm**, real) along a roughly consistent direction within the last ~250 ms. For arm strikers there is a second test: the elbow (or shoulder, for a straight punch) must itself be moving at least 40% of the hand's speed. A flick moves the hand and not the elbow.

**Impulse.** `J = m_eff × v_rel`, where

- `m_eff` for a fist ~ `rs_melee_arm_mass` (a notional 3, in arbitrary units);
- for a held gun: arm + the gun's weight (the `RS_VR_Reload` weight service already has it);
- two hands on the same gun: ×1.6;
- for a foot: 5; for the body: 10; for the head: 4.

Damage, stagger and knockback all read `J`. Damage is capped at the value `J` gives at `rs_melee_full_speed`, as before.

The first plan's gates and locks stay. They now apply to `v_rel` and per striker:

- one hit per swing per striker, not per hand, so an elbow followed by a fist on the same arm is two strikes;
- a per-target cooldown;
- entry only (a striker already inside doesn't count);
- the tracking-glitch filter.

### B4. Physical hands (the anti-hack core)

The hand you **see** and the hand that **hits** are the same thing, and neither goes through walls.

- Keep two hand poses: the **tracked** pose (the controller) and the **physical** pose (what is drawn and what strikes).
- Each render frame, move the physical hand toward the tracked one with a short sweep against **walls, floors, closed doors and solid actors**. If it hits something, it stops at the surface.
- The IK body targets the **physical** hand, so the arm stops too. The existing IK already takes any target.
- The separation (tracked minus physical) is how hard you're pushing. Use it for:
  - haptics proportional to the push;
  - pushing a monster slowly (a sustained shove with no speed at all; see B6);
  - a hand that "slides" along walls.
- If the separation goes over `rs_melee_hand_break` (**40 cm**, for example the tracked hand is through a wall), snap the physical hand back to the tracked one along a clear path, or fade it until it's reachable. Never draw it through the wall.
- **Line-of-reach check:** before any hit is accepted, trace from the shoulder (IK) to the contact point. If the trace is blocked, no hit. This alone kills hitting through walls and doors.

Guns follow the physical hand. A gun barrel against a wall stops too. That is the same rule as the hand, and it removes shooting through walls with a barrel poked through them. Most VR shooters get this wrong.

### B5. Reactions

Replace "pain state" with a small reaction ladder, driven by `J` against the monster's thresholds (C3):

| Level | When | Effect |
| --- | --- | --- |
| **Flinch** | J > flinch | 2-tic hit-stop, pain sound, no state change |
| **Stagger** | J > stagger | Pain state, no attacks for 6 to 12 tics, pushed along the hit direction |
| **Knockback** | J > knockback | Thrust `J / Mass` in 3D (an uppercut lifts, a downward chop pushes down), can push off ledges |
| **Knockdown** | J > knockdown, or a leg hit with a stagger | A downed state (BD has these for some monsters): vulnerable, stompable |
| **Stun** | Three staggers within 2 s, or a head hit over the stagger level | A longer window that allows grabs and finishers (B7) |

Big monsters (baron, cyberdemon) have high thresholds and never go past flinch or stagger. That is the balance lever, so there's no need for per-monster special cases.

### B6. The moves fall out of the system

None of these is a special case in code. Each one is a striker plus a grip state plus the impulse:

- **Punch, hook, uppercut:** the fist striker. The direction of `v_rel` gives the knockback direction.
- **Elbow:** the elbow striker, short range, high stagger.
- **Pistol-whip, butt-stroke, barrel swipe:** gun striker parts from the card.
- **Shove:** the palm striker, low damage, knockback-heavy (a `kind` multiplier).
- **Sustained push:** a palm or gun pressed against a monster with no speed. The physical-hand separation (B4) pushes it slowly. That is "holding an enemy back", with no damage.
- **Two-hand shove:** two palm strikers hitting the same target within 2 tics sum their impulses.
- **Kick and stomp: DRIVEN BY THE ANIMATION, NOT BY MEASURED SPEED.** This is the one striker that breaks the rule the rest of the system runs on, and it breaks it because the foot is **IK-solved and has no tracker**. A solved joint snaps: the body lane measured a twist bone turning 178 degrees in a single frame while the arm around it moved less than one unit. A velocity read off that would occasionally be enormous, and a monster would occasionally be launched across the room for no reason the player could see or repeat.

  So a kick is a **committed action with a known strength**, not a swing whose speed is read. It emits a fixed impulse along the leg's direction at the contact frame. That is also what a universal kick for every mod actually wants, because almost no one has foot trackers.

  A foot tracker, when one exists, upgrades this to a real striker by the B9 rule -- the striker's velocity simply becomes trusted. Nothing else about the kick changes. Per the owner's note, SlimeVR trackers come after the bodies work, so treat that as later.

  A stomp is a downward kick on a downed target.
- **Knee:** the knee striker on a staggered target in front of you.
- **Headbutt:** the head striker. It has a cost: a short screen shake and a brief minimum-speed lock for the head.
- **Body check:** the body striker with `rs_melee_charge`.
- **Stab and slash:** a blade striker. An edge counts only when the edge normal faces the velocity; a point counts only when the velocity is along the blade. A stab can **stick**: the blade stays in until pulled back past a force, or the target dies.
- **Chainsaw:** a saw striker. It is continuous: damage every tic while in contact, with no one-hit rule. Its own lock is the saw's ammo and a damage cap per second.

### B7. Grabs and finishers

- **Grab:** squeezing the grip while the open hand is in contact with a stunned or downed monster, or any small one (zombieman, imp), attaches it to the hand through the grip arbiter. The same arbiter decides weapons, so a hand can't hold a gun and a monster at once.
- **Held:** the monster follows the physical hand with a weight lag (heavy ones drag the hand down), and it can't attack.
- **Release with speed:** a throw, with velocity from the hand × a weight factor. A thrown monster is a projectile and damages what it hits.
- **Pull into a punch:** the other hand's strike on a held monster gets the stun bonus.
- **Finishers:** a strike over the stagger threshold on a stunned target kills it with BD's melee death. This is optional, gated behind a cvar.
- **Limits:** you can't hold anything above `rs_melee_grab_mass`. A held monster breaks free after a few seconds or when it takes a hit from something else.

### B8. Defence

- **Player hurtbox follows the body.** Check whether the fork already sets the player's height from the headset (ducking). If it doesn't, melee defence needs it: crouching in real life must lower the hurtbox so a swing goes over.
- **Block:** when a monster's melee attack fires, test whether any arm or gun striker capsule sits between the attacker and your head or torso. If one does, the damage is reduced (a gun blocks more than an arm), the monster flinches, and you feel a haptic.
- **Parry:** a block where that striker was moving toward the attacker above the speed gate in the last 150 ms. The attack is cancelled and the monster is staggered.
- **Telegraph:** monster melee needs a visible or audible wind-up for blocks to be fair. Most Doom monsters already have a pre-attack frame. Read it (the frame before `A_MeleeAttack` or a custom melee call) and start the block window there.
- **Projectiles:** blocking fireballs with a gun is a later option (the same capsule test against the missile's path). Not part of melee v1.

### B9. XR trackers: what each one adds

OpenXR: `XR_HTCX_vive_tracker_interaction`, or the generic body-tracker extensions where the runtime has them. Each tracker gives a pose and a velocity (`xrLocateSpace` with `XrSpaceVelocity`).

| Tracker role | Melee gets | Body/IK gets |
| --- | --- | --- |
| **Waist** | True body velocity for B3; the body striker; real dodge and body check | Real body yaw (replaces the `BodyYaw` deadzone heuristic); real hips |
| **Feet (left, right)** | Kicks, stomps, knees (with the IK leg) | Real legs instead of a procedural walk |
| **Elbows** | A trusted elbow speed for the travel gate; accurate elbow strikes | Elbow IK becomes fixed, not solved |
| **Knees** | Accurate knee strikes | Knee IK becomes fixed |
| **Chest** | A better torso striker and block volume | Spine bend |

Build the tracker layer as **optional sources for the same striker table**. Without a foot tracker, the foot striker doesn't exist and the kick falls back to a button (BD's kick). Nothing in melee should check "is there a tracker"; it only checks whether that striker has a trusted velocity.

---

## Part C: data

### C1. Per body (`.avatar`)

Arm and leg lengths already come from the rig. Add striker capsule radii scaled by body size, and the head sphere offset from the eye. Reach limits (for seated play, `rs_melee_reach_scale`) apply to the tracked-to-shoulder distance, not to map units.

### C2. Per weapon (WMCARD `grip` block)

```
strike  butt   x y z  radius 2
strike  barrel x y z  to x y z radius 1.5
strike  muzzle x y z  radius 2
edge    x y z  to x y z  normal x y z     // blades only
point   x y z  dir x y z                  // stab tip, blades only
meleekind blunt | edge | saw
```

The weight already exists (`RS_VR_Reload`). The defaults per weapon type from the first plan stay for cards with no data.

### C3. Per monster (a small lump, `MELEEINF`, with defaults from Mass and Health)

```
monster DoomImp    head 0.22 flinch 20 stagger 45 knockback 60 knockdown 90 grab 1
monster BaronOfHell head 0.18 flinch 80 stagger 250 knockback 999 knockdown 999 grab 0
```

When there is no entry: `stagger = Mass × 0.45`, the other thresholds scale from that, and `grab = Mass <= 150`. Brutal Doom's replacement classes are matched by their parent class, so one entry covers BD and vanilla.

---

## Part D: build order

Each step is testable on its own and doesn't need the later ones.

1. **Striker table and the render-rate buffer**, with the debug draw (`rs_melee_debug 2` draws the capsules and the swept paths). Nothing hits yet. Test: swing and watch the paths.
2. **Physical hands and the line-of-reach check (B4).** Test: push your hand into a wall, and it stops. Swing through a door at an imp, and nothing happens.
3. **Impulse, relative velocity and the travel gate (B3), for the fist only**, with the first plan's locks. Tests:
   - A wrist flick does nothing.
   - Running with a fist out does nothing.
   - A real punch hits once.
   - Waggling inside an imp hits once.
4. **Reactions and hit zones (B5, B2), with `MELEEINF` defaults.**
5. **All arm and gun strikers**: elbow, forearm, palm, gun parts, with the card data.
6. **Defence (B8)**: first check the player hurtbox, then block, then parry.
7. **Grabs (B7)** through the grip arbiter.
8. **Trackers (B9)**: waist first (body velocity and yaw), then feet.
9. **Blades and the chainsaw**, once BD22's weapons are in.
10. **Network event** with the tic and target position (A1). It's needed before any multiplayer test, so move it earlier if multiplayer comes first.

## Part E: what not to do

- **No melee "states" on the weapon.** Melee must never need the gun to switch to a melee weapon or play a melee animation. The hand is the weapon.
- **No reach extension, no auto-lunge, no magnetism.** If the hand didn't get there, it didn't hit.
- **No per-move code paths.** A new move is a new striker or a new card entry, never a new branch.
- **No physics engine.** Everything above is capsule sweeps and a few line traces per tic, which is cheap in ZScript or in the engine. A physics engine would be a second source of truth fighting the IK.
- **Don't trust IK speed.** Solved joints snap; only tracked devices give velocity.
