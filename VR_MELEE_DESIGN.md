# VR Melee: punch, pistol-whip, shove

A melee hit is a **real swing that passes through an enemy**, not a button and not "arm reached out". Each swing lands **once**. The hand must slow down or pull back before it can hit again, which is what rules out infinite attacks.

## What already exists (reuse it)

- `RS_WorldHands/zscript/hands/rs_swing.zs`, `RS_Swing`: hand speed from OpenXR's native velocity (`AttackVel` / `OffhandVel`), plus the peak over the last ~200 ms. Its header already names melee as one of its consumers.
- `rs_fistweapon.zs`: today's punch is a trigger press that calls `A_CustomPunch` at 52 units. Keep it as a fallback (`rs_melee_button 1`); make the swing the default.
- Body IK (in progress): the drawn hand is where the controller is, so what you see is what hits.
- `RS_VR_Reload` weight service: guns already have a weight; use it to scale pistol-whip damage.

## 1. What counts as a hit

Each tic, per hand:

1. **Strike point.** Empty hand: the knuckles (fist) or the palm centre (open hand). Gun held: the gun's `strike` point from its WMCARD (see 5). Take the point this tic and last tic.
2. **Swept test, not a point test.** Test the segment last-tic to this-tic against every nearby monster's box (`BlockThingsIterator`, radius about 64). A fast swing covers about 6 to 10 units per tic, so a point test misses.
3. **Speed gate.** The hand's speed along the swing must be at least `rs_melee_min_speed` (default **2.5 m/s**). Below that it's a touch, not a hit.
4. **Direction gate.** The velocity must point INTO the target: `dot(normalised velocity, direction to target centre) >= 0.5`. Dragging a hand sideways out of an enemy, or pulling back through one, does nothing.

All four must pass.

## 2. Why it can't become an infinite attack

Four independent locks, each enough on its own to stop the obvious exploits:

| Lock | Rule | Stops |
| --- | --- | --- |
| **One hit per swing** | After a hit, that hand is **disarmed**. It re-arms only when its speed drops below `rs_melee_rearm_speed` (**0.8 m/s**) for 3 tics, or the hand moves 16+ units away from the struck target. | Waggling the controller inside an enemy; one long swing through a crowd hitting the same enemy every tic |
| **Per-target cooldown** | The same hand can't hit the same target again for `rs_melee_target_cooldown` (**14 tics, 0.4 s**). The other hand can, so a left-right combo still works. | Fast small jabs at one spot |
| **Hand inside a monster** | If the strike point starts the tic already inside the box, no hit. Only an entry counts. | Resting a hand inside an enemy, or walking into one with a hand out |
| **Damage from speed, capped** | Damage scales from the gate speed up to `rs_melee_full_speed` (**6 m/s**) and stops there. A limit of hits per second per hand (**3**) backs it up. | Controller jitter or tracking spikes producing huge hits |

Tracking glitches: ignore any tic where the controller lost tracking, and any single-tic speed above **15 m/s** (not humanly possible; it's a tracking jump). `RS_Swing.Forget()` already exists for this.

## 3. The three moves

The **leading part of the hand** decides the move. No buttons.

| Move | When | Effect |
| --- | --- | --- |
| **Punch** | Empty hand, grip squeezed (fist), knuckles leading: velocity roughly along the finger axis | Damage `rs_melee_punch_dmg x speed factor`, small knockback, damage type `Melee` |
| **Pistol-whip** | Holding a gun, any direction that passes the gates, using the gun's `strike` point | Damage `card strikedmg x speed factor x weight factor`, stun chance, damage type `Melee`. The gun stays in the hand; no ammo used |
| **Shove** | Empty hand, open (grip not squeezed), **palm leading**: `dot(palm normal, velocity) >= 0.6` | Little or no damage. Thrust along the swing: `force = k x speed x 100 / target.Mass`. Short stagger (pain state, 6 to 10 tics of no attack) |
| **Two-hand shove** | Both hands open, palms forward, within 20 units of each other, both passing the gates in the same 2 tics | One shove at 2.5x force; knocks down or pushes off ledges. Counts as one hit for the locks |

Palm normal and finger axis come from the body's hand frame (the same one the FRIK fix builds), or from the RS hand if no body is worn.

## 4. Feel

- **Haptics:** a short pulse on the hitting hand, scaled by damage. `level.VRHaptic(hand, strength, ms)` already exists.
- **Hit-stop:** freeze the struck monster for 2 tics. Sells the impact without touching the player's frame rate.
- **The hand doesn't pass through:** after a hit, hold the drawn hand at the contact point for 2 to 3 tics (the IK already takes any target). Without this, the hand visibly goes through the enemy and the hit reads as a miss.
- **Sound:** a punch or whip sound by damage type; Brutal Doom's own melee sounds when BD22 is loaded.
- **Brutal Doom gore:** pass damage type `Melee` (or BD's own kick or punch types) with the player as inflictor. BD's death and gore states key off damage type.

## 5. Data

Add to each gun's WMCARD `grip` block (the one from the handoff):

```
strike    x y z     // the part that hits: pistol butt, rifle stock, shotgun muzzle; gun md3 space
strikedmg 15        // base damage at full speed
```

Defaults per weapon type when a card has none:

| Type | Strike point | Damage |
| --- | --- | --- |
| pistol | butt | 15 |
| rifle / shotgun | muzzle end | 20 |
| heavy (chaingun, rocket launcher, BFG) | muzzle end | 25, slower rearm |
| saw | none (it's already a melee weapon) | none |

## 6. Where it goes

- **New file `RS_WorldHands/zscript/hands/rs_melee.zs`:** an `EventHandler`. It reads `RS_Swing`, does the swept test and the gates, and holds the locks per hand.
- **Decide locally, apply everywhere.** The swing is measured on the player's own machine. The hit is sent as a network event (target, hand, move, damage, force vector), and every machine applies it. Same pattern as the holster draw (`rs_hol_move:`). Without this, multiplayer desyncs.
- **One owner of the hand.** Melee asks the grip arbiter whether the hand is free before it counts an open-hand shove. A hand that's holding or grabbing something isn't shoving.
- **Cvars** (all `rs_melee_*`): on/off, the four speeds, cooldown, damages, the button fallback, and `rs_melee_debug`. With debug on, it prints each swing's speed and which gate or lock stopped it, so a tuning problem is one log line.

## 7. Build order

1. Punch with an empty hand, all four locks, debug log. Test: waggle a hand inside an imp. It must hit once.
2. Shove (open palm).
3. Pistol-whip, with the strike point from the card.
4. Two-hand shove, haptics, hit-stop, hand held at the contact point.
5. The network event (needed before any multiplayer test).
