# Throwing and weight: plan

**Goal:** throws feel natural, like a baseball, a frisbee or a newspaper. Everything has weight: a barrel is heavy, a baseball is light, and a thrown barrel knocks a monster down.

**Owner's constraint:** everything is netplay-safe, including tossing an item from one hand to the other.

**Where the work goes:** almost all of it is ZScript in **RS_WorldHands** and **RS_ShieldSaw**. There is one small engine change (§5.1).

Pointers are to the working trees on 2026-09-26. This plan was reviewed against the code, and the review's corrections are folded in.

---

## 1. The netplay contract (read first)

The system already follows this. Every change below must keep following it.

- **Playsim state depends only on the playsim, the usercmd and server cvars.** Never on a machine's controller, VR pose, user or local cvar, or locally loaded resource (for example, whether a voxel pack is loaded). See `Engine docs/CROSSPLATFORM_COOP_RULE.md` and the header of `rs_handnet.zs`.
- **Decisions travel; poses stay home.** The machine with the controller measures, decides and sends one network event. Every machine applies it identically:
  - `rs_hand_take:<netid>`: this hand took hold of that actor.
  - `rs_hand_drop:<hand>`: this hand let go, with this velocity.
- **Controller-derived values are computed only on the sender** and carried in the event: wrist lever, peak, aim, spin and throw roll. Receivers read nothing local.
- **After release, everything is plain playsim, identical everywhere:** flight, gravity, drag, impact and mass.
  - Use a named playsim RNG, such as `random[RSFlight]`.
  - Masses and velocities are doubles held in the tracker. Never write them into `Actor.Mass`, which is an int the engine also reads.
- **Local presentation is fine:** haptics, hand lag while holding, and hand-follow visuals.
- **Renderer-owned fields are read only on the sender:** `AttackVel`, `AttackAngularVel`, `OffhandVel`, `OffhandAngularVel`, `MainHandRoll` and `OffhandRoll`. None of them is serialised.
- **Event limits:** `SendNetworkEvent` has 3 int args. Extra values go in the event name as `:`-separated ints (thousandths for fractions). That keeps it to one event per decision, with no ordering problems.

---

## 2. What exists today

### `rs_swing.zs`
- Once per tic (35 Hz), reads native controller velocity (`AttackVel`/`OffhandVel`, map units/s, room-yaw frame). Divides it by TICRATE into a 7-tic ring (~200 ms).
- Wrist angles are hand-differenced at 35 Hz.
- ~378 notes that the frame of the native angular velocity is **not yet verified in the headset**.

### `rs_throw.zs`
- Speed comes from the peak sample. Direction comes from the mean of the last 3 tics (~86 ms).
- Adds `rs_throw_lift` (0.35) × flat speed upward.
- Multiplies by `rs_throw_scale`, then adds `pmo.Vel` (~86–93).
- A release under `rs_throw_min` (1.2 m/s) is a drop.

### `rs_held.zs` `Release()` (~554)
- If the other hand still holds the object, that hand is promoted and the function returns (~563–576). Only the last hand throws.
- Otherwise it steps the object clear of the body, restores flags and sets `a.Vel`.
- `KeepVoxelInFlight` (~283) tracks thrown voxels, but it's called only `if (drawnAsVoxel)`, which depends on the local voxel pack.

### `rs_handnet.zs`
Take and drop commands are correct. Drop args are velocity in thousandths of a unit per tic.

### Shield: `rs_shieldsaw.zs` `LaunchNow()` (~676)
- It's a `Projectile` (NOGRAVITY), Speed 22.
- Free-throw speed is clamped to `Speed × 0.5..2`, i.e. 11–44 u/tic.
- **Existing desync.** `LaunchNow` runs on every machine but:
  - asks the service for `throw.spin.roll`, which reads each machine's own controller;
  - reads `OffhandRoll`/`MainHandRoll`, which are renderer-owned.

  Today that only changes the look. §6 would make it change the flight.
- Spin floor `rs_ss_spin_base` is 26°/tic, which is **~2.5 rev/s**. The code comment saying 0.75 is wrong.

### Weight
- Doom's `Actor.Mass` (default 100) is used only by `ApplyKickback` (`interaction.zs`): `thrust = damage × 0.125 × kickback / Mass`, capped at 32.
- Guns carry real pounds (WMSHEET `baseweight`), used for recoil only.
- `rs_held.zs` ~1195's `Radius × Height` is a haptic strain factor, not physics.

---

## 3. Why throws feel wrong

1. **Gravity is ~3.7× too strong at hand scale.**
   - Engine gravity is 1 u/tic² at sv_gravity 800, which is 1225 u/s².
   - At ~34 u/m that's ~36 m/s², against a real 9.8.
   - Players overthrow ("have to yeet it"). `rs_throw_lift` patches over this.
2. **The wrist is ignored.** Only the controller origin's linear velocity is used. A frisbee or newspaper flick is mostly rotation, and the object's centre sits away from the controller.
3. **No mass.** Everything leaves at the same speed and falls the same way.
4. **The peak is sampled at 35 Hz.** A flick's fastest instant falls between samples, so throws are weaker and less consistent than the arm.
5. **Aim includes follow-through.** The last 86 ms is deceleration. An overhand follow-through heads down.
6. **Shield:** the speed band flattens soft and hard throws. It has no glide and only modest spin.

---

## 4. Weight

### 4.1 `RS_Mass`

- A **Service**, per the cross-pk3 rule. It returns kilograms as a double.
- For monsters, Doom `Mass` counts as kilograms: player 100, Lost Soul 50, Cacodemon 400, Cyberdemon 1000.

Lookup order:

1. **A per-class `MASSDEF` lump**, read from every loaded pk3. Later entries override earlier ones.
   ```
   mass "Clip"            0.3   drag 0.002
   mass "Medikit"         1.5   drag 0.003
   mass "ExplosiveBarrel" 60    drag 0.001   impact explode
   mass "RS_Newspaper"    0.4   drag 0.04    flutter
   ```
   `drag` is in 1/(u/tic); see §4.3.
2. **Guns:** WMSHEET `baseweight` lb × 0.4536.
3. **Voxel size, baked offline, never read live.**
   - Loading a voxel pack is a local choice, so reading voxel bounds at runtime would desync.
   - Instead, a small tool reads the pack once and **writes MASSDEF entries**: scaled bounding volume × a density class, default 300 kg/m³.
   - Those entries ship in **RS_WorldHands itself**, not in the optional voxel pack.
4. **Monsters** (`bIsMonster`): Doom `Mass`.
5. **Everything else:** `(2·Radius)² × Height` in m³ × density, **clamped**: Inventory 0.1–5 kg, other props 1–200 kg.
   - The default Radius of 20 would otherwise make a clip weigh 50–195 kg.
   - Non-monsters never use `Mass`, because an inherited 100 can't be told apart from an explicit 100.

### 4.2 Launch speed

The sender sends **hand-relative velocity only** (u/tic, wrist included): no player velocity, no scale, no lift. The applier then computes, on every machine:

```
f(m)  = armKg / (armKg + m)             rs_throw_arm_kg (server), default 30
v_out = v_hand × f(m) × rs_throw_scale + pmo.Vel
```

- `rs_throw_scale` becomes a **server** cvar and is applied here only. Remove it from `VelocityFor`.
- **Two hands:** use `armKg × 2` if the object was held two-handed within ~10 tics.
  - The first hand's release returns early, so record `twoHandedUntilTic` in playsim hold state while both hands hold.
  - Read it on the final release.

| Object | Mass | Speed kept |
|---|---|---|
| Baseball | 0.15 kg | 99% |
| Shield | 5 kg | 86% |
| Barrel | 60 kg | 33% (two hands: 50%) |

`armKg` 30 is deliberately super-human, because this is Doomguy.

### 4.3 `RS_Flight`, the flight tracker (playsim)

Replaces and generalises `thrownVoxel`.

- **Push an entry for every throw, unconditionally.** "Drawn as voxel" becomes a separate local, visual-only field.
- Entry: `actor, savedGravity, drag, flags, thrower, launchTic, lastVel, m`.

**On release:**
- Save `a.Gravity`, then set `a.Gravity = savedGravity × rs_throw_gravity`.
- `rs_throw_gravity` is a server cvar, default **0.27** (real g at hand scale).
- Scale the saved value, don't overwrite it: `Gravity` multiplies level and sector gravity.

**Every tic:**
- Drag: `Vel /= (1 + drag × |Vel|)`. This is stable at any speed; the subtractive form reverses direction for light objects.
- `flutter`: a small side wobble from `random[RSFlight]`.
- Store `lastVel`.

**Ending a flight:**
- Ends when the object rests on the floor, is picked up, is caught (§7), or `WorldUnloaded` fires (hubs).
- Always restore `savedGravity`.
- **End the flight before any `Take`/`SaveFlags`**, as `TakeThrownVoxel` does. Otherwise a caught object keeps flight gravity.

**Also:**
- Savegames: keep the tracker in a handler that saves with the level, or end every flight on save/load.
- Remove `rs_throw_lift` (set it to 0). Real gravity makes the arc.

### 4.4 Impact: the barrel into the imp

**Detection.**
- Handler WorldTick runs **before** thinkers move, and `P_XYMovement` zeroes a non-missile's Vel when it's blocked. So:
  - use the stored `lastVel`;
  - don't rely on `BlockingMobj` alone. Non-solid pickups never set it, and neither does a straight drop onto a head.
- Each tic, run an overlap test (`BlockThingsIterator`) on the box swept by the object's movement. Optionally make the object SOLID while it's in flight and restore it afterwards.
- The engine still blocks against the thrower. The step-clear in `Release` handles that; the ~8-tic thrower guard is for damage.

**Momentum.** RS_Mass for **both** bodies. The barrel is 60 here, not its Doom Mass of 100.

```
n    = unit(vRel), vRel = lastVel_obj − target.Vel, vn = dot(vRel, n)
Δv_t =  (1+e) × m/(m+M) × vn × n     target; respect DONTTHRUST; cap 32 u/tic
Δv_o = −(1+e) × M/(m+M) × vn × n     object
e    = restitution, default 0.3
```

A heavy target barely moves, and a light one never flies off faster than it was hit.

**Damage.**
- `0.5 × m[kg] × (|vRel| in m/s)² × rs_throw_dmg_scale`, only above a minimum speed.
- Apply it with `DamageMobj(object, thrower, dmg, 'Thrown', DMG_THRUSTLESS)`. That credits the kill and plays the pain frame, the sprite-friendly reaction.
- `DMG_THRUSTLESS` stops `ApplyKickback` adding a second push based on the thrower's current weapon.
- Convert u/tic to m/s with a fixed server-side constant, never the local `vr_vunits_per_meter`.

**Barrels.** `impact explode` makes a hard hit damage the object itself too, so a barrel thrown into a pack explodes on contact.

### 4.5 Holding (local presentation)

- Heavy objects lag and sag behind the hand; light ones snap to it. Driven from mass in `rs_stabilize.zs`.
- Haptics on grab, impact and catch scale with mass.
- **Visual only.** Other machines already show the object following the holder ("carry does not travel").

---

## 5. Throw measurement (sender only)

### 5.1 Render-rate peak capture (engine, small)

In `vk_openxrdevice.cpp` `updateHandPose`, where `AttackVel`/`AttackAngularVel` are written each frame, keep a per-hand ring of the last ~250 ms of `{time, pos, linearVel, angularVel}`. Expose it read-only:

```
native readonly vector3 AttackVelPeak;       // map units/s
native readonly vector3 AttackAngVelAtPeak;  // rad/s, same sample
native readonly vector3 AttackPosAtPeak;
native readonly double  AttackPeakAgeMs;
native vector3 HandVelAvg(int hand, double fromMsAgo, double toMsAgo);
// Offhand* equivalents
```

- Never serialised. Read only on the sender, then `/ TICRATE` to get u/tic.
- `rs_swing.zs` falls back to its 35 Hz ring when these are absent.

### 5.2 The wrist lever (ω × r)

```
r     = object centre − controller position, from the SAME sample (map units)
v_obj = v_hand + (ω × r)                     units/s, then / TICRATE
```

- **First, verify in the headset** that `AttackAngularVel` is rad/s about the map axes, in the same frame as `AttackPos`. `rs_swing.zs` ~378 flags this. Spin the controller about a known axis and log it.
- User cvar `rs_throw_wrist` (default 1.0) scales the ω × r term. It's applied before sending, so it's safe.

### 5.3 Aim

- Direction: mean velocity from the peak to ~40 ms after it (`HandVelAvg`).
- Speed: the peak.
- The fallback keeps `rs_throw_aim`.

### 5.4 Spin

Taken from ω on the sender, projected onto the object's axes, in °/tic.

### 5.5 One event per release

```
rs_hand_drop:<hand>:<spinYaw>:<spinPitch>:<spinRoll>    spin in thousandths of °/tic
args = v_hand x, y, z in thousandths of u/tic           hand-relative, wrist included
```

The applier parses the name as ints, then applies §4.2 and §4.3 from actor data.

---

## 6. The shield

- **Fix the desync first.**
  - Measure spin and throw roll on the sender (in `MeasureRelease`) and carry them in the `rs-ss-throw` event name as ints.
  - `LaunchNow` stops reading the service and `OffhandRoll`/`MainHandRoll`.
- **Speed.** Replace the `Speed × 0.5..2` clamp with `v_out` (§4.2, shield ~5 kg), floored at 6 u/tic.
  - Without the clamp, a typical ~10 u/tic throw is slower than today's minimum of 11.
- **Glide.** The shield is NOGRAVITY, so apply a per-tic vertical term in `RS_ShieldInFlight`: `Vel.z −= g × 0.4 − lift`.
  - `lift` is proportional to spin × forward speed × how flat the throw plane is (from the sent roll).
  - Homing (`aimAt`, `GoHome`) overwrites Vel, so glide applies only on free throws before homing starts.
- **Spin.** Raise `rs_ss_spin_base` from 26 to ~60°/tic (~6 rev/s), with the sent wrist spin on top.
- Locked routes still steer the disc.

---

## 7. Tossing between hands

This works with the existing netcode.

1. **Release** sends `rs_hand_drop`, and the object flies under `RS_Flight`.
2. **The catcher's machine decides the catch.** Each tic, for each `RS_Flight` object: if a local hand is within `rs_catch_radius` (server, default 12) with its grip closing, send `rs_hand_take:<netid>`. That's the same command a grab uses.
3. **Every machine applies the take.**
   - Only accept it if the object is in `RS_Flight` and free.
   - **End the flight (restoring gravity) before** `Take` saves flags.

**Rules:**
- A hand can't catch its own throw for ~6 tics.
- The same path catches a teammate's throw.

**Known limit (presentation only):** other players see the object snap to the holder, not to the exact hand, because the off hand isn't in the usercmd. Adding it later changes nothing here.

---

## 8. Order and size

| # | Work | Where | Size |
|---|---|---|---|
| 1 | `RS_Flight`: real gravity, stable drag, no lift, restore rules | RS_WorldHands | S |
| 2 | Send hand-relative velocity; apply scale and player velocity once | RS_WorldHands | S |
| 3 | `RS_Mass`, MASSDEF, clamps, voxel-to-MASSDEF tool | RS_WorldHands + tools | M |
| 4 | Mass-scaled launch, two-hand record | RS_WorldHands | S |
| 5 | Impact: overlap test, momentum, damage, barrel explode | RS_WorldHands | M |
| 6 | Shield desync fix | RS_ShieldSaw | S |
| 7 | Render-rate peak capture | **engine** | S |
| 8 | Verify ω frame; wrist lever, aim, spin | RS_Swing / RS_Throw | M |
| 9 | Shield speed, glide, spin | RS_ShieldSaw | S |
| 10 | Hand-to-hand catch | RS_WorldHands | M |
| 11 | Mass-scaled hold lag and haptics (local) | RS_WorldHands | S |

Items 1–4 fix most of "I have to yeet it". Items 7–8 fix the frisbee and the newspaper.

---

## 9. How to test

- **Light item, gentle underhand toss:** lands a few metres away, in a soft arc.
- **Barrel, same motion:** barely leaves the hand. Two hands and a heave lob it.
- **Barrel into an imp:** knockback, pain frame, explosion. Into a Cyberdemon: it barely moves.
- **Shield, wrist-only flick:** flies. A flat throw with spin glides.
- **Newspaper:** flutters, slows, and drops short.
- **Hand-to-hand catch:** the caught item has normal gravity afterwards.
- **Netplay, two clients** (one desktop, one VR; one with a voxel pack, one without):
  - Throw, catch between hands, catch a teammate's throw, and use the shield.
  - Positions, damage and holder must match on both machines. Run the desync tooling.
- **Save mid-flight, then load:** the object lands normally with the right gravity.
