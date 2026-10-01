# RS_Affect in the engine

This replaces the **implementation** part of `VR_AFFECT_SYSTEM.md`. The gameplay rules stay the same: the target sorting, the reaction ladder, resistances from `Mass`, the `AFFECTDEF` lump, grab and throw, block and parry. What changes is where they live: in the engine's playsim, hooked where the engine already knows the truth, instead of ZScript guessing from outside.

All line numbers are from the fork (`E:\DOOMWork\UZDXREMA\src\playsim`, staged 2026-09-29).

**This document's build order is the only one.** Of the four documents, `VR_MELEE_DESIGN.md` is superseded in scope by `VR_MELEE_SYSTEM.md`, and `VR_AFFECT_SYSTEM.md` is superseded in implementation by this one. Their own build orders are history, not work lists. Melee's Part D steps 1 to 3 are not a parallel track: they are inside step 5 below. Nothing starts that is not a numbered step here.

**Naming: no `RS_` in the engine.** The fork is shared ground for a family of mods, so engine-side this is `affect_*` cvars, an `AFFECTDEF` lump and `FActorAffect` — named for what it does, so the next subsystem that needs to stagger something uses it instead of writing a second one. `RS_` stays on the mod layer.

## Why not ZScript: what was fragile

| ZScript version | Problem | Engine version |
| --- | --- | --- |
| Hold AI by adding 1 to `tics` each tic | Breaks on 0-tic chains, `-1` states, `A_Jump` loops, and mods that set `tics` themselves | One check gates the state countdown (H1) |
| Grab by `SetOrigin` to the hand | Teleports monsters into walls and through doors | Driven with `P_TryMove`: blocked like any move (H1) |
| Impacts guessed from "speed dropped by half" | Misses slow impacts, false hits on friction and slopes | The engine's own blocked-move result: `BlockingLine`, `BlockingMobj`, with the exact velocity before the hit (H2) |
| "Is it attacking" guessed from state labels | Wrong for mods with odd labels | The moment the engine itself sends a monster to its melee state (H4), and the damage call itself (H5) |
| Blocks in `ModifyDamage` on an inventory item | Runs after armour and other items, in inventory order | Checked first, inside `DamageMobj` (H5) |
| Hands sampled at 35 Hz | Curved swings missed | Render-rate sampling in the VR code (L1) |
| Hands, guns and IK go through walls | Hits and shots through geometry | Physical hands in the VR code; the gun fires from the physical muzzle (L1) |

## Three layers

1. **L1, VR input (render rate):** strikers, physical hands, swept hit tests. It produces hit **decisions**.
2. **L2, playsim core:** `FActorAffect` on every actor, hooks H1 to H7. It **applies** hits deterministically, is saved with the game, and works on every actor.
3. **L3, ZScript surface:** natives to call it, virtuals so a mod **can** customise a monster (it never has to), the `AFFECTDEF` lump, and events.

---

## L2: the playsim core

### The state on every actor

Add to `AActor` (`actor.h`, next to `freezetics` at line 2001):

```cpp
struct FActorAffect
{
    int32_t  holdTics     = 0;   // AI held (no state countdown, no chase); physics runs
    int32_t  downTics     = 0;   // knocked down
    int32_t  stunTics     = 0;
    int32_t  knockTics    = 0;   // moving because it was hit; impacts count while > 0
    int32_t  thrownTics   = 0;   // thrown; impacts hit other actors
    double   meter        = 0;   // stagger meter
    int32_t  meleeWindup  = -1;  // level.maptime when the engine sent it to its melee state (H4)
    TObjPtr<AActor*> causer;     // who hit, held or threw it (credit for kills)
    TObjPtr<AActor*> heldBy;     // player pawn holding it, or null
    int8_t   heldHand     = -1;
    DVector3 holdPos;            // where the hand wants it (set each tic from L1)
    // render-only reaction pose, interpolated (see "Rendering")
    float    tiltPitch = 0, tiltRoll = 0, dropZ = 0, shake = 0;
    bool Active() const { return holdTics|downTics|stunTics|knockTics|thrownTics|(heldBy!=nullptr) || meter > 0; }
};
FActorAffect Affect;
```

- Serialize it in `AActor::Serialize` (`p_mobj.cpp:230`), so saves and loads work mid-grab or mid-throw.
- Expose it to ZScript read-only.
- Nothing about the actor's own flags is changed. Held and thrown behaviour is done by the hooks below reading `Affect`. That means no "save the flags, restore the flags" bookkeeping, which was the most fragile part of the ZScript plan.

### The hooks

**H1: `AActor::Tick` (`p_mobj.cpp:4637`)**

- **State countdown, line 5259:**
  ```cpp
  if (tics != -1 && !Affect.HoldsAI())   // [AFFECT] held, stunned or down: no states, so no actions and no chase
  ```
  `HoldsAI()` is `holdTics || stunTics || downTics || heldBy`. Movement and gravity still run, so a staggered monster slides with its knockback.
- **Counters:** tick `Affect`'s counters down, and drain `meter`, just after the `freezetics` early return (`:4694`). So hit-stop (`freezetics`) also pauses the reaction timers, which is correct.
- **Held:** before `P_XYMovement` is called (`:5100`), if `heldBy` is set:
  - set `Vel` to (`holdPos` − position) / 1 tic, clamped to `affect_hold_maxspeed`, and zero gravity for that actor this tic;
  - normal movement then moves it with `P_TryMove`, so walls and doors block it like anything else;
  - if it's blocked and the hand is more than `affect_hold_break` away, the grab breaks (the hand is pulling it through a wall).
- **Stand-up:** when `downTics` reaches 0, send it to its `See` state, or a `Knockdown.Recover` label if the class has one.

**H2: blocked move in `P_XYMovement` (`p_mobj.cpp:2682-2683`)**

The engine already tells you exactly what stopped the move and how fast it was going (`startvel`, line 2675). Add, right after `BlockingLine` and `BlockingMobj` are read:

```cpp
if (mo->Affect.knockTics > 0 || mo->Affect.thrownTics > 0)
    Affect_Impact(mo, BlockingMobj, BlockingLine, DVector3(startvel, mo->Vel.Z));
```

`Affect_Impact` does the following:

- damage to `mo` from the speed into the wall, along the wall normal (a glancing slide does little). The kill is credited to `causer`;
- if `BlockingMobj` is set, damage and a stagger to that actor too, from `mo`'s mass × speed. That's the thrown imp hitting a zombie;
- clears `thrownTics`, so it hits once.

**`BlockingMobj` alone is not enough, and `Vel` is already gone.** `RS_Flight.Impact` found both of these the hard way (`rs_flight.zs`, 2026-09-28):

- `P_XYMovement` zeroes `Vel` when it refuses a move, so by the time anything can see the hit the speed reads zero. Reading `startvel` above is right and must stay right — never substitute `mo->Vel`.
- A **non-solid** target never sets `BlockingMobj` at all: a pickup, or a body dropped on a monster's head, passes straight through the blocked-move path. So `Affect_Impact` cannot rely on `BlockingMobj` to find what it hit. It sweeps `mo`'s box along the step it just moved and takes the first actor on it; `BlockingMobj` is only a fast path when it happens to be set.

**H3: landing in `P_ZMovement` (`p_mobj.cpp:3196`)**

Next to the existing `P_MonsterFallingDamage` call (which only fires at `Vel.Z < -23`, and only with the compat option), add:

```cpp
if (mo->Affect.knockTics > 0 || mo->Affect.thrownTics > 0) Affect_Impact(mo, nullptr, nullptr, mo->Vel);
```

This covers a knock off a ledge, an uppercut landing, and a throw into the floor.

**H4: melee wind-up in `A_DoChase` (`p_enemy.cpp:2621`)**

This is the one place the engine decides "attack in melee now":

```cpp
actor->SetState (meleestate);
actor->Affect.meleeWindup = actor->Level->maptime;   // [AFFECT] telegraph starts here
```

This is the block and parry window. It's universal for everything that uses `A_Chase` (vanilla, Brutal Doom, nearly every mod). A monster with custom melee code gets no telegraph, but H5 still catches its hit.

**H5: incoming damage, top of `DamageMobj` (`p_interaction.cpp:1093`)**

Before armour, powerups or anything else:

```cpp
if (target->player && source && source == inflictor && !(source->flags & MF_MISSILE))
{
    // A melee hit on a player: the source hit directly, no projectile.
    const EGuard g = VR_GuardTest(target->player, source);   // L1's arm and gun capsules vs the line source->player
    if (g == EGuard::Parry) { Affect_Hit(source, target, parryImpulse, ...); return -1; }   // cancelled
    if (g == EGuard::Block) damage = int(damage * blockFactor);   // arm 0.5, gun 0.25
}
```

- `VR_GuardTest` asks L1 whether an arm or gun capsule is between the attacker and the player's head or torso at this moment.
- It's a **parry** if that capsule also moved toward the attacker above the gate speed within `affect_parry_window`, and the swing started after `source->Affect.meleeWindup`.
- A `-1` return is already the "no damage, no event" path (`DoDamageMobj`, line 1634).

The same hook also stops friendly-fire melee between players unless friendly fire is on.

**H6: death, `AActor::Die` (`p_interaction.cpp:316`)**

- If it's held, drop it.
- Clear `holdTics`, `stunTics` and `downTics`, so the death state runs normally.
- Keep `causer` for the kill credit.

**H7: the grip arbiter**

The player side keeps `heldActor[2]`. `Affect_Grab` and `Affect_Release` are the only writers. The weapon grip code checks it, so a hand holding a monster can't pick up a gun, and the other way round. `TObjPtr` clears itself when the actor is destroyed, so nothing dangles across level changes.

### The reaction ladder (engine function)

`Affect_Hit(AActor* t, AActor* source, DVector3 J, DVector3 at, FName kind, FName dmgType)` is the only entry point. Everything calls it: the network hit command (L1), the ZScript native, explosions if you want them, H5's parry.

1. **Sort the target:** the table in `VR_AFFECT_SYSTEM.md` section 2 (monster, corpse, projectile, prop, pickup, player, friendly, other).
2. **Resist:** defaults from `Mass`, overridden by `AFFECTDEF` through `GetReplacee` (parsed once at startup with the engine's `FScanner`).
3. **Flags:** respected as in the earlier doc (`MF2_INVULNERABLE`, `MF2_DONTTHRUST`, `MF_NOPAIN` and so on). They're read, never changed.
4. **Damage:**
   ```cpp
   P_DamageMobj(t, source, source, dmg, dmgType, DMG_THRUSTLESS, angleOf(J))
   ```
   Brutal Doom sees a normal `Melee` damage (gore, deaths, its own pain states). `DMG_THRUSTLESS` keeps Doom's own push out of it (`p_interaction.cpp:1315`).
5. **Push:** `t->Vel += J / clampedMass` in 3D, and set `knockTics` so H2 and H3 watch for impacts.
6. **Ladder:**
   - flinch: `freezetics = 2`;
   - stagger: `TriggerPainChance(dmgType, true)`, or `holdTics` if it has no pain state;
   - knockdown: `downTics`, or a label from `AFFECTDEF` if the class has one;
   - stun: from `meter`.
7. **Virtual:** before any of this, call `t->OnAffected(source, J, kind)` (L3). A mod can return false to take over or refuse. The default does nothing, so the engine's behaviour applies to everything.

### Rendering the reaction

The `tilt*`, `dropZ` and `shake` fields on `Affect` are **render-only**, interpolated between tics:

- **Sprites:** add to the sprite's roll and position at draw time. There's no need to set `ROLLSPRITE` on the actor.
- **Models:** apply as an extra rotation about the actor's feet before the model transform. It works for MD3, IQM and Source models alike.
- **Knockdown:** tip over about 80 degrees and drop. **Flinch:** a 3-tic shake. **Stun:** a slow wobble.

A mod's own knockdown state (from `AFFECTDEF` labels) replaces the tilt when present. Later, skeletal monsters can take an additive bone offset (a hit recoil on the struck bone), since the fork already does bone-level posing.

---

## L1: VR input (render rate)

This lives with the VR rig code, the same place that feeds the body IK.

1. **Striker sampling. THE HAND RING ALREADY EXISTS -- DO NOT BUILD A SECOND.** The throwing lane shipped a render-rate per-hand ring in the engine this week, and it answers exactly the question a striker asks:

   ```
   level.HandVelAtPoint(hand, offsetMapUnits, when)   // when: RS_HAND_NOW / RS_HAND_PEAK / RS_HAND_THROW
   level.HandPeakAgeMs(hand)                          // ms since that fastest instant, -1 if none
   ```

   Verified present at both halves: `VR_HandVelAtPoint` in `hw_vrmodes.cpp:2298`, the thunk in `vmthunks.cpp:7780`, the declaration in `doombase.zs:1087`, and `EVRHandWhen` in `constants.zs:1678`.

   The offset is in **map units on purpose**, and the `v + ω × r` cross product is done in the XR frame with only the linear result mapped out. That matters more than it looks: map space Z is stretched by pixelstretch, so an angular term computed in it is wrong in a way that still looks plausible. Consume this; never recompute it.

   **The hand index is the trap.** The ring is keyed by PHYSICAL side while every script read is ABSTRACT. `VR_MAINHAND` is 0, but `GetMainHandIndex()` returns 1 for right-handed controls, so main-hand motion once filed itself under the off hand and the entire render-rate path was dead with no error anywhere (fixed in `34ecfd0a39`). `OpenXR_GetThumbstick` and `VR_ScriptHaptic` already do the swap. Any new hand-indexed native needs it too.

   What is still this step's own work is everything that is **not** a hand: gun strike points from the card (an offset into the same call), elbows and forearms, the head, and the feet. A gun part is not a new ring, it is a different `offsetMapUnits` into the existing one.
2. **Physical hands.** Every render frame, sweep each hand from its last physical position toward the tracked one against lines, 3D floors and solid actors (the engine's `FTraceInfo` / `P_PathTraverse`). It stops at the surface.
   - The physical pose is what the IK arm reaches for, what's drawn, and **what the gun fires from**. The muzzle position used for hitscans and projectiles is the physical one, so a barrel poked through a wall is stopped at the wall and can't shoot past it.
   - The separation between tracked and physical drives haptics and a sustained push (`Affect_Push`).
3. **Swept hit test.** At each game tic, sweep every armed striker's buffered path (not one chord) against actors in the blockmap. Then apply the gates, locks and travel rule from `VR_MELEE_SYSTEM.md`, and the line-of-reach trace from the shoulder.
4. **Send, don't apply.** A passing hit becomes a network command. Add a new `DEM_` code (e.g. `DEM_VRSTRIKE`) carrying:
   - the tic;
   - the target's network id;
   - the striker id;
   - `J`;
   - the contact point.

   Every machine, including the local one, applies it with `Affect_Hit` at that tic. The receiver rejects a strike whose contact point is further than the target's radius + 16 from the target, so a bad client can't hit across the map.
5. **Grab input.** A held monster's `holdPos` is sent the same way each tic while held (a small `DEM_VRHOLD`: target, hand, position), because the playsim needs it deterministically.

---

## L3: the ZScript surface

**Natives:**
- `Actor.AffectHit(source, J, at, kind, dmgType)`;
- `AffectPush`, `AffectHold(tics)`, `AffectGrab(pawn, hand)`, `AffectRelease(vel)`;
- read-only `Affect` fields;
- `InMeleeWindup()`.

**Virtuals on `Actor`, all with empty defaults, so no mod needs them:**

```
virtual bool OnAffected(Actor source, Vector3 J, Name kind)    // false = I handled it (a mod's custom reaction)
virtual bool CanBeGrabbed(Actor by)                            // default: engine's resist rule
virtual void OnImpact(Actor hitThing, Vector3 vel)             // after H2 or H3
```

**Event:** `WorldThingAffected(e)` on `EventHandler` for anything that wants to watch, for example sounds, scoring or achievements.

**Data:** the `AFFECTDEF` lump, same format as before.

**Cvars:** `affect_*` for thresholds and times, plus `affect_debug`:
- `1` prints each hit (target, J, resist, rung reached);
- `2` also draws strikers, physical hands, swept paths and guard capsules.

---

---

## RS_ShieldSaw: the third caller, and it is already built

`E:\DOOMWork\RS_ShieldSaw` (3,641 lines, standalone) is not a future consumer of this system. It **already implements three of its rungs**, in shipped ZScript, and it does one of them better than the plan above describes. It is the proof of the "assume a second caller" rule, so it sets requirements rather than waiting on them.

| What ShieldSaw already has | Where | What this system does about it |
| --- | --- | --- |
| **Projectile deflect, working.** `sweepDeflect()` sweeps for missiles every tic; `deflect(mo, n)` gives the missile a new velocity off the shield normal, and with `rs_ss_deflect_aim` **retargets the shooter**, so a deflected fireball hurts whoever fired it. Per-type impact sounds (bullet, fire, energy, goo) | `rs_shieldsaw.zs:368-470` | This is the deflect rung of step 4, finished, and more complete than the one-line version in `VR_AFFECT_SYSTEM.md` §2. `Affect_Hit`'s missile branch **adopts this behaviour**, including the retarget and the normal-based reflect. It is not re-invented |
| **A saw striker, working.** `A_ShieldGrind()` is continuous trace damage while in contact, with no one-hit rule — exactly the `saw` kind in `VR_MELEE_SYSTEM.md` B6 | `rs_shieldsaw.zs:500` | Becomes a saw striker at step 5 rather than staying a weapon attack. Its own trap is recorded there: the grind trace **starts inside the deflector's own box** and terminated on it, because a bounding box containing a trace origin is an intercept at frac 0 |
| **A grip-arbiter caller.** It claims the off hand by string through `ServiceIterator`, with no compile-time link, so it still runs alone | README, "Compatibility" | **H7 is constrained by this.** The engine arbiter must keep the by-string service route answering, or publish a native that ShieldSaw can ask instead. H7 is not free to be the only arbiter |

### What ShieldSaw asks the engine for

Two of its known gaps are engine gaps, and both belong to this work rather than to it:

1. **Hitscans have no victim-side veto.** Missiles are handled: `CanCollideWith` works because the fork widened the `PIT_CheckThing` gate to fire for missile-vs-shootable. There is no equivalent for a hitscan, so a shot fired *through* the deflector still stops on it, and a shield cannot stop a bullet. **This is the same idiom, one level down, and it is general** — any guard, any mod, wants to decide whether a trace is allowed to end on it. It lands with H5 at step 7, because block and parry need the same question answered for the player's own body and gun.
2. **`HandMoving()` is stubbed `true`,** so every release throws and you cannot put the shield back except at the mount. It needs published off-hand velocity. Step 5 publishes point velocity for every striker (`v + ω × r`) as its first job, so this stops being a gap without anything being written for it — `HandMoving()` becomes a threshold test.

### Where it lands in the order

No new steps. It attaches to three that already exist:

- **Step 4** (target sorting) takes the deflect behaviour from `sweepDeflect`/`deflect` instead of writing a new missile branch.
- **Step 5** (strikers) adds the saw striker and retires `A_ShieldGrind`'s own trace; `HandMoving()` becomes real here.
- **Step 7** (H4/H5, block and parry) adds the **shield as a guard capsule** beside the arm and gun ones in `VR_GuardTest`, and brings the victim-side hitscan veto. The parked "ShieldSaw block" backlog item is this step and nothing else.

**Nothing in ShieldSaw is edited before step 4.** It works today; it is a reference until there is something to hand it.

## Tests

1. `affect_test <impulse>`: hits the actor under your crosshair with a set impulse from the front. Run it on an imp, a pinky, a baron, a cyberdemon and a Brutal Doom imp. Expected: the rung reached matches the resist table in the debug line.
2. **Walls:** `affect_test 400` on an imp against a wall. It takes impact damage once (H2), with no repeat hits while it's pressed there.
3. **Ledge:** knock an imp off a ledge. It takes damage once on landing (H3).
4. **Hold:** stagger a monster that's mid-`A_Chase` and mid-0-tic chain (a Brutal Doom monster is a good test). It stops acting and resumes cleanly afterwards.
5. **Grab:** walk backwards through a doorway holding an imp. It follows through the door and never goes into a wall. Close a door between you: the grab breaks.
6. **Save and load:** save while holding a monster, while one is knocked down, and while one is mid-throw. Load each: the state is the same.
7. **Parry:** stand in front of an imp and parry. The attack is cancelled and the imp staggers. Block with the gun: reduced damage.
8. **Multiplayer:** two players, one hits, both machines show the same reaction on the same tic.

## Built: steps 1 to 4 (engine commit 676efb323b, 2026-09-29)

Steps 1 to 4 are in the fork and build clean. What is proven and what is not:

**Proven.** Compiles with no errors and no warnings. The engine boots to `BOOT: ok (420 tics, 12 s of play)`. The `AFFECTDEF` parser reads a real lump to the expected counts (3 class overrides, 2 knockdown labels, 2 stun labels).

**Not proven.** THE REACTION LADDER HAS NEVER RUN. `affect_test` needs a monster under the crosshair in a live level, and the boot harness cannot arrange that: `+exec` drains before the map loads, and `wait` does not defer across it. So every threshold, every rung and every impact path below is written and compiled but has never been executed once. Treat the numbers as unmeasured until someone stands in front of an imp and types `affect_test 400`.

**One documented number does not add up.** `stagger = Mass * 0.45` makes an imp stagger at 45, while `VR_MELEE_SYSTEM.md` gives a fist an effective mass of 3, so a hard 6 m/s punch computes to 18 and would never stagger an imp. One of the two scales is wrong and only a headset can say which. Rather than bake a guess, every impulse is multiplied by `affect_impulse_scale` on the way in.

**Two things added that this document did not call for**, both required rather than optional:

- **H6, `AActor::Die`.** The state-countdown gate would otherwise freeze a staggered monster partway through its own death sequence.
- **A per-step actor sweep** after `P_XYMovement`, because the blocked-move hook cannot see a non-solid target at all (see H2).

**One thing left out.** `P_TriggerPainChance` had to be exposed in `p_local.h`; it was `static` in `p_interaction.cpp`.

## Build order

1. `FActorAffect` + serialize + H1 (hold, counters) + `Affect_Hit` with flinch, stagger and knockback + `affect_test` + debug print.
2. H2 and H3 impacts. **`RS_Flight.Impact` retires here.** It is the same job in ZScript and there is never a second one: once H2 and H3 land, `rs_flight.zs` deletes its own impact path and calls `Affect_Hit` instead, keeping only what is actually about flight (the mass and drag table, the airborne list, catching). Its two findings above are the reason its removal is safe rather than a loss.
3. The `AFFECTDEF` lump, knockdown with the render tilt, and the stun meter.
4. Target sorting (projectile deflect, corpses, props, pickups). The deflect branch adopts RS_ShieldSaw's `sweepDeflect`/`deflect`, retarget included.
5. L1 striker sampling, physical hands (including the gun firing from the physical muzzle), the swept test and `DEM_VRSTRIKE`. Melee is live from here. Published point velocity lands here, which is also what RS_ShieldSaw's stubbed `HandMoving()` needs; the saw striker replaces `A_ShieldGrind`'s own trace.
6. The grip arbiter + grab and throw (H7, H1 held, `DEM_VRHOLD`).
7. H4 + H5: block and parry, with the shield as a third guard capsule and the victim-side hitscan veto RS_ShieldSaw's deflector needs. This step is the parked "ShieldSaw block" item.
8. The L3 virtuals and event.
9. Trackers as extra strikers.

Steps 1 to 4 need no VR at all: all of it can be tested with `affect_test` on a flat screen.
