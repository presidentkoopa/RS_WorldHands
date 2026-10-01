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

On a gun part the sticks work in two passes, one stop each:

| Stop | Move stick push / pull | Move stick left / right | Turn stick left / right | Turn stick push / pull |
| --- | --- | --- | --- | --- |
| **WHERE** | along the barrel | across | up / down | size (keeps its shape) |
| **SHAPE** | length | width | height | size (keeps its shape) |

Size on a part scales its length, width and height together. It never touches
"reach as a ball", which would throw the card's shape away and make a sphere.

There is a 0.15 deadzone, because a stick at rest is not at zero and a value nudged
every tic by a resting stick drifts all session without anyone touching it.

Speed is `rs_oval_rate`, default `0.12`.

---

## What it steps through

In this order:

1. **The gun in your main hand**: where it sits in your hand, and its scale
2. **The gun in your off hand**: same
3. **Main hand seat**: where your hand model sits on the controller
4. **Off hand seat**: same
5. **The support point**: where your off hand braces a two-handed gun
6. **Every part of the guns in your hands, both hands, by name.** Each part is
   two stops: WHERE, then SHAPE. The label says which gun, which part and which pass,
   for example `OFF gun: slide -- SHAPE`.

The part list is read from what RS_VR_Reload publishes for the guns you are actually
holding (`wm_gp_name_*`), the same list its own grab-point page uses. It is rebuilt
every time you press next, so it follows weapon changes. Empty slots and brace points
are not offered.

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
- **A level change is a release too.** The handler is registered per map, so it dies
  with the level and takes the countdown with it. It therefore gives the sticks back
  and restores your oval settings when the level unloads. Your own settings are also
  written to `rs_oval_pending` (archived) while the mode is on, so a quit or crash with
  the button down is undone on the next map load. Before 2026-09-29 neither was true:
  a map change mid-hold saved the forced-on ovals into your ini.

---

## Where your numbers go

**Everything saves when you let go of the button**, and the ini is written right
then, so a crash doesn't lose it.

### Gun placement, hand seats and the support point

These write `user` cvars (the same ones the menu sliders write), and the support
point is filed per weapon model into `rs_stab_table`. All of it lands in your ini.
Nothing to confirm.

**MODELDEF is never edited.** To make a tuned value the shipped default for
everybody, it still has to be baked into CVARINFO, which is what the
`// owner's tuned value, baked in ...` comments there record.

### Gun part ovals

The adjuster uses RS_VR_Reload's own bake, the same one its grab-point page's Bake
button runs. A part is saved when you step off it or let go of the button:

- the card lines are printed to the console,
- they are kept in the **bake ledger** (`wm_bake_ledger_*`, in the ini) and the ini
  is written,
- in single player the numbers are written straight into the card in play, and the
  ledger is laid over the cards at every map load. **So the part stays where you put
  it, this session and every one after.**

The shipped card files are still the defaults for everybody else. The ledger is your
machine's copy on top of them, until its lines are pasted into the cards. The ledger
holds 64 parts; clear it on the grab-point page once they're pasted.

**In a netgame** cards must read the same on every machine, so the ledger is not laid
over them there. The part keeps its tuning while you play (it stays in the tuning
scratch) and is saved to the ledger when you move on to another part.

---

## Known gaps

These are real and currently unfixed.

**The support oval has one size number from the sticks.** It carries three axis
scales in its cvars, but the sticks only move its overall multiplier. Gun part ovals
do have length, width and height (the SHAPE pass).

**Clearing the bake ledger does not undo cards already changed this session.** The
cards go back to shipped on the next map load.

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
