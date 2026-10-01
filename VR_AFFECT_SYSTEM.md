# RS_Affect: one way to push, stagger, stun, grab and throw anything

One layer that every system calls to affect monsters and things: melee, shoves, gun bashes, grabs, throws, explosions, parries, and later force pushes or shield bashes. It works on **any** monster from any mod (vanilla, Brutal Doom, random wads) with **no per-monster code**.

Melee (`VR_MELEE_SYSTEM.md`) decides **that** something was hit and how hard (an impulse). RS_Affect decides **what happens to the thing**.

## What the engine already gives us (checked)

| Tool | Where | Use |
| --- | --- | --- |
| **Behaviors**: attach a `Behavior` object to any actor with `AddBehavior`; it ticks with the actor and is saved with the game | Fork `actor.zs:101-110`, `:1052-1056` (engine 4.15.1+) | The per-actor effect state. Nothing has to be added to monster classes |
| Behaviors tick **before** the actor's state timer counts down | `AActor::Tick` (upstream `p_mobj.cpp:4565` vs `:5101`) | Hold a monster's AI by adding 1 to `tics` each tic. Its physics keeps running |
| `freezetics` | Fork `actor.zs:371` | A true full freeze (no movement, no states) for hit-stop |
| `TriggerPainChance(mod, forcedPain)` | Fork `actor.zs:915` | Puts **any** monster into its **own** pain state. With a damage type, it picks `Pain.<type>` if the mod defines one (Brutal Doom does) |
| `DamageMobj(..., DMG_THRUSTLESS)` | Fork `actor.zs:1375` | Damage without Doom's own push, so our push is the only one |
| `SpriteOffset`, `WorldOffset` | Fork `actor.zs:197-198` | Shake, sway and knockdown visuals on any sprite or model, without its own states |
| `InStateSequence`, `FindState("Melee")` | Fork `actor.zs:1394` | "Is this monster attacking right now?" for any monster, by its state labels |
| `GetReplacee` | Fork `actor.zs:810` | Brutal Doom's imp is recognised as an imp, so one data entry covers both |

Nothing here needs engine changes. It's all ZScript in `RS_WorldHands`. The mod's `zscript` version line must be **4.15.1** or higher for Behaviors.

## 1. The API (one static class)

```
class RS_Affect play
{
    // The one call for "something hit it". J = impulse vector (from melee, explosions, anything).
    static void Hit(Actor t, Actor source, Vector3 J, Vector3 at, Name kind = 'Blunt', Name dmgType = 'Melee');

    static void Push   (Actor t, Vector3 force);                 // slow sustained push, no damage (palm held on it)
    static void Stop   (Actor t, int tics);                      // hit-stop: full freeze via freezetics
    static void Hold   (Actor t, int tics);                      // no AI, physics still runs (stagger, stun)
    static bool Grab   (Actor t, PlayerPawn by, int hand);       // attach to a hand; false if too heavy or not allowed
    static void Release(Actor t, Vector3 vel);                   // let go; above a speed, it's a throw
    static bool IsAttacking(Actor t, out bool melee);            // in its Melee or Missile sequence
    static bool InWindup(Actor t);                               // in the first frames of that sequence (telegraph for blocks)
    static RS_Resist Resist(Actor t);                            // its thresholds (section 4)
}
```

**Every** system calls only these. Melee never touches `vel`, `tics` or states directly. That is what makes it universal: one place knows how to affect a monster, and every rule (bosses, flags, mods) lives there.

## 2. What kind of thing it is

`Hit` sorts the target first. This covers "monsters and shit":

| Target | Test | What `Hit` does |
| --- | --- | --- |
| **Live monster** | `bISMONSTER`, `health > 0` | The full reaction ladder (section 3) |
| **Corpse** | `bCORPSE` or `health <= 0` | Push only. BD may gib it from its own damage type; pass the damage anyway with 0 damage and let BD decide |
| **Projectile** | `bMISSILE` | **Deflect:** new velocity along the swing at its own speed, and its `target` (the shooter) becomes the player, so it now hurts monsters. A parried fireball goes back |
| **Shootable prop** (barrel, breakable) | `bSHOOTABLE`, not a monster | Damage, plus a push by mass |
| **Pickup** | `bSPECIAL` | Push; `Grab` allowed |
| **Other player** | `player != null` | Only if friendly fire or deathmatch; scaled down |
| **Friendly monster** | `bFRIENDLY` | Only a push (you can shove your allies out of the way) |
| **Anything else** (solid decoration) | | Nothing. The physical hand just stops on it |

Flags are always respected, so mods that mark things still behave:

- `bINVULNERABLE`, `bNODAMAGE`: no damage, still flinch.
- `bDONTTHRUST`: no push.
- `bNOPAIN`: no pain state, but the generic stagger still applies.
- `bBOSS`: capped at stagger.
- `bDORMANT`: nothing.

## 3. The reaction ladder (live monsters)

`|J|` against the monster's own thresholds (section 4). Each level includes the ones above it.

| Level | Universal effect | Uses the mod's own states when present |
| --- | --- | --- |
| **Flinch** | `Stop` 2 tics (hit-stop), `SpriteOffset` shake for 4 tics | none |
| **Stagger** | `TriggerPainChance(dmgType, true)`; if it has no pain state, `Hold` 6 to 12 tics with a shake | `Pain.Melee`, `Pain` |
| **Knockback** | `vel += J / Mass`, in 3D (an uppercut lifts). Stagger meter added | none |
| **Knockdown** | `Hold` 35 to 70 tics. Visual: sprites tip over (`bROLLSPRITE`, roll to about 80 degrees, drop `WorldOffset.Z`), models pitch back. Stands back up at the end | A state labelled `Knockdown` or `Kicked` if the class has one (a small list of labels in the data lump) |
| **Stun** | `Hold` about 50 tics, a wobble, grabs allowed | A `Stun` label if it has one |

**Stagger meter.** Each hit adds `|J|` to a meter on the monster's Behavior. The meter drains over time. A stun happens when the meter crosses the stun threshold, so three quick medium hits stun something that one big hit only staggers. A single hit can't stun a boss.

**Afterwards.** The monster targets whoever hit it (`target = source`). Optionally it's `bFRIGHTENED` for a moment after a knockdown, so it backs off instead of instantly retaliating.

**Landing and walls.** While knocked back or thrown, the Behavior watches for a sudden stop: speed drops by more than half in one tic, or a hard landing. The impact becomes damage to the monster, and to whatever it hit if that was an actor. Knocking an imp into a wall or off a ledge hurts it. Doom has no fall damage for monsters, so this is new, and it's universal.

## 4. Resistances (no per-monster code)

Default, from what every actor already has:

```
stagger   = Mass * 0.45          // imp (100) 45, pinky (400) 180, baron (1000) 450
flinch    = stagger * 0.4
knockback = stagger * 1.3
knockdown = stagger * 2.0
stun      = stagger * 3.0        // on the meter
grab      = Mass <= 150 && !bBOSS
```

Overrides live in one text lump, `RSAFFECT`, by class. It's looked up through `GetReplacee`, so the vanilla name covers every mod that replaces it:

```
DoomImp          stagger 45
Demon            knockdown 999            // pinkies don't fall over
Cacodemon        knockback 400 grab 0
Cyberdemon       stagger 999              // flinch only
labels  knockdown "Kicked" "Knockdown"    // state labels to try before the generic knockdown
labels  stun      "Stun" "Stunned"
```

A monster with no entry and odd flags still works from its `Mass`. A mod monster with a silly `Mass` (0 or 99999) is clamped to 50 to 2000.

## 5. The Behavior (one per affected actor)

```
class RS_AffectState : Behavior
{
    int    holdTics;         // AI held, physics runs
    double meter;            // stagger meter, drains each tic
    int    downTics;         // knocked down
    PlayerPawn heldBy; int heldHand;
    bool   thrown; Vector3 lastVel;
    // original values, restored on removal
    bool   oNoGravity, oThruActors, oRollSprite; double oRoll; Vector3 oWorldOffset;

    override void Tick()
    {
        // Hold: the state timer is counted down after this, so +1 cancels it (states with -1 or 0 tics are left alone).
        if (holdTics > 0) { holdTics--; if (Owner.tics > 0) Owner.tics++; }
        meter = max(0, meter - drainPerTic);
        // held: move to the hand, cancel velocity (sections 6 and 7)
        // thrown or knocked back: check for a sudden stop, then deal impact damage
        // knockdown: animate roll and offset in and out
        // idle and nothing active: restore the originals and remove itself
        // dead while held: drop it, restore, remove
    }
}
```

It's created on first contact (`t.FindBehavior(...) ?? t.AddBehavior(...)`) and removes itself when nothing is active, so idle monsters carry nothing. Behaviors are saved with the game, so a save made mid-grab loads correctly.

**Always restore.** Every flag or value the Behavior changes is stored first and put back on removal or death. This is the main rule that keeps it from breaking other mods' monsters.

## 6. Grab and hold

- `Grab` checks `Resist.grab`, or a stunned or downed state, and asks the **grip arbiter**: one owner per hand, the same as weapons.
- While held:
  - each tic, the Behavior moves the monster toward the hand with `SetOrigin`, lagging by weight;
  - `vel` is zeroed and `Hold` is kept at 1 or more;
  - `bNOGRAVITY` and `bTHRUACTORS` are on, so it doesn't block you;
  - it can't attack, since it's held.
- It breaks free after `rs_affect_grab_time` (**3 s**), or when something else damages it.

## 7. Throw

`Release` with hand speed above `rs_affect_throw_speed` (**2 m/s**) turns the monster into a thrown body for up to 2 s:

- `bTHRUACTORS` is off again;
- each tic, it sweeps its box against actors (`BlockThingsIterator`), and the first one hit takes impact damage from the thrown one's `Mass × speed`. Both get a stagger;
- walls and floors give impact damage through the sudden-stop rule (section 3).

## 8. Defence hooks (for blocks and parries)

- **Telegraph:** `InWindup(t)` is true for the first frames of a monster's `Melee` sequence, found by label. This works on every monster with a `Melee` state.
- **Block:** a `RS_Guard` inventory item on the player overrides `ModifyDamage`. When the damage source is attacking in melee (`IsAttacking`, `melee` is true) and an arm or gun striker is between it and the player, the damage is reduced and `RS_Affect.Hit` gives the attacker a flinch.
- **Parry:** the same, plus the swing test from melee: the attacker gets a stagger and its attack is cancelled with `Hold`.
- **Projectile parry:** the deflect rule from section 2.

## 9. Multiplayer

All calls are `play` scope and deterministic. Melee sends one network event per hit; every machine calls `RS_Affect.Hit` with the same numbers, so every machine gets the same reaction. Nothing random except through the play RNG.

## 10. Build order

1. `RS_Affect.Hit` with flinch, stagger and knockback, the Behavior with `Hold`, and the default resistances. Test from the console (`rs_affect_test`: hits whatever you're looking at with a set impulse) on an imp, a pinky, a baron and a Brutal Doom imp.
2. The `RSAFFECT` lump and `GetReplacee` lookup.
3. Knockdown (generic and by label) and the stagger meter's stun.
4. Sudden-stop impact damage.
5. Target sorting: projectile deflect, corpses, props, pickups.
6. Grab and throw, once the grip arbiter owns hands.
7. The guard item for block and parry.

Melee step 3 (`VR_MELEE_SYSTEM.md` Part D) calls `RS_Affect.Hit` from its first hit, so build RS_Affect step 1 first.
