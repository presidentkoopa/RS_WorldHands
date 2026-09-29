# The grip adjuster

**What it is:** hold a button, and your thumbsticks stop moving you and start moving
one piece of the gun-in-hand setup instead. Tap a second button to step to the next
piece. Let go and the sticks are yours again.

**Where it lives:** `RS_WorldHands/zscript/hands/rs_ovaledit.zs`, class `RS_OvalEdit`.
Two controls in the options list, both unbound by default:

- *Grip points: adjust with the sticks (hold)*
- *Grip points: next point*

Bind them to something you can reach with a gun in each hand. Shoulder buttons work.

---

## Why it is sticks and not a menu

A menu pauses the game. The gun is in your hand, the oval is attached to the gun, and
the question being answered is *"does this oval sit where my other hand actually
goes"* — which you cannot see while nothing is moving.

Every previous attempt at this was a slider page, and every one of them was useless
for that reason. This is written down because it will look like an obvious
simplification to somebody later.

---

## The controls

Both sticks are live at once, so you can move a thing on all four axes without
letting go of anything.

| Stick | Direction | What it does |
| --- | --- | --- |
| Move | push / pull | along |
| Move | left / right | across |
| Turn | left / right | up / down |
| Turn | push / pull | size |

There is a 0.15 deadzone, because a stick at rest is not at zero and a value nudged
every tic by a resting stick drifts all session without anyone touching it.

Speed is `rs_oval_rate`, default `0.12`.

---

## What it steps through

Thirteen stops, in this order:

1. **The gun in your main hand** — where it sits in your hand, and its scale
2. **The gun in your off hand** — same
3. **Main hand seat** — where your hand model sits on the controller
4. **Off hand seat** — same
5. **The support point** — where your off hand braces a two-handed gun
6. **Gun parts 0–7** — each part's grab point and how big a reach it has

The hand seats are in the same cycle on purpose. An oval that looks wrong on the gun
is as often a hand sitting wrong on the controller, and the two can only be told
apart by moving one and watching the other. Splitting them across two interfaces is
what made that comparison impossible before.

### What a "gun part" is

The parts are whatever that gun's card defines — a slide, a magazine, a pump, a bolt,
a break lever. In practice the reload system draws **two ovals per gun**: where the
ammunition goes, and where the action is. That is deliberate and it is a design
ruling, not a limitation:

> *This mod is concerned with where the ammo drops, ejects and inserts, and where the
> slide, rack or pump is. Two points per gun. Nothing else.* — owner, 2026-09-25

There used to be 141 `part support` entries across the card set, so a gun drew an
oval for its magazine, its action **and** every support point, and the display was
unreadable.

---

## What happens when you enter the mode

- **The ovals come on.** `rs_stab_viz` and `wm_show_grabs` are both forced on for the
  duration and put back to your own settings on release. You cannot aim at what you
  cannot see.
- **It tells you what you are on**, on screen, because you are in a headset and
  cannot read a console or reach a keyboard.
- **There is a 60-second dead man's switch.** If the button-release is ever lost — a
  dropped key-up, a level change with the button down — suppression ends anyway. A
  stuck suppression is a player who cannot walk or turn with nothing on screen to
  blame.

---

## Where your numbers go

This is the part that is **not uniform**, and it is the thing most worth knowing
before you spend an hour tuning something.

### Gun placement and hand seats — permanent, immediately

They write the same cvars the menu sliders write, and those cvars are `user`, so they
land in your ini and stay there. Whatever is set when you let go is simply what that
gun's placement now is. Nothing to save, nothing to confirm.

**MODELDEF is never edited.** A gun's MODELDEF block only *names* the prefix its
placement cvars use (`PlacementCVars wm_main`). The adjuster writes those cvars. If a
tuned value should become the shipped default for everybody, that is a separate
deliberate step — baking it into CVARINFO, which is what the
`// owner's tuned value, baked in 2026-09-15 (was 0.0)` comments in that file record.

### The support point — permanent, per weapon, automatic

It writes live cvars; the stabilize system notices the change, files it into a table
keyed by that weapon's model, and saves. So each gun remembers its own support point
without you doing anything.

### Gun part grab points — SCRATCH ONLY

These go into a tuning scratch set (`wm_tune_*`) that is claimed for one gun and one
part at a time. **They do not persist.** They must be baked into the gun's card
afterwards, which prints the card lines to paste.

If you tune six guns' grab points in one session and quit without baking, you have
lost six guns' worth of work. This is the single most important thing on this page.

---

## Known gaps

These are real and currently unfixed.

**Gun parts are main-hand only.** The code hardcodes the main hand when it claims the
tuning scratch, so the off-hand gun's parts cannot be adjusted with the sticks at all.
This matters more than it sounds: the Pistolet is an off-hand gun, so the showpiece
pistol's slide and magazine are unreachable this way. Fixing it needs a way to say
which hand you are tuning — realistically a fourteenth stop in the cycle.

**Eight of a possible sixteen parts.** A card can carry sixteen parts; the cycle
offers eight. Stepping past a gun's real count harmlessly tunes nothing, but parts
8–15 have no way in.

**Ovals have one size number, not three.** "Size" is a single ball radius for gun
parts. There is no separate height, width and depth. The support oval does carry
three axis scales in its cvars, but the sticks only move its overall multiplier — so
you cannot make an oval tall and narrow from in-game.

**The on-screen label is a flat 2D line.** It is a HUD overlay pinned to your view,
not something in the world. We have a billboard system — real depth-tested quads,
occluded by walls, already used by the weapon wheel and RS_Main's panels — and the
labels are an obvious candidate for it. Nothing is blocking that; it simply has not
been done.

**Hand scale is deliberately not adjustable.** The fourth axis moves the hand along
the controller instead. A hand's scale is the one number on it that must not drift:
every grab distance, every oval radius and all fourteen tuned gun seats were measured
against it. Rescaling the hand silently invalidates all of them, so that decision
stays somewhere it can be thought about rather than nudged by a thumb.

---

## Notes for anyone editing this file's code

- **Nothing here names a class in RS_VR_Reload.** All cross-package work goes by cvar
  name, and the gun prop class is looked up at runtime. This is not stylistic: a
  string literal in `ThinkerIterator.Create` is resolved at *compile* time, so loading
  RS_WorldHands without RS_VR_Reload died before the game started. Keep it by name.
- **Which gun is in which hand is asked of where it is *drawn*.** A gun rides its
  controller inside the draw, so its actor position is not where you see it. The code
  replays the same matrix the renderer used and takes the nearest controller,
  rejecting anything further away than an arm.
- **`PlayerInfo.AxisMask` does not work for taking the sticks.** It zeroes movement in
  the ticcmd, which in this fork is far downstream of where VR walking and snap turn
  are decided. It was built, shipped, and the player walked and snap-turned exactly as
  before. Do not reach for it again.
