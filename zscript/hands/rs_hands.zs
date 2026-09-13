// Rigged VR hand models, drawn on both controllers.
//
// Hands only. This mod deliberately grants no weapons and never touches the
// player's loadout -- an earlier version shipped a fist weapon, which took over
// the off hand and displaced whatever the loadout put there (RS_Main starts
// with a gun in each hand). Drawing hands and deciding what the player holds
// are separate jobs, and this one does only the first.
// =====================================================================
// ALWAYS-ON HANDS
//
// A hand on each controller regardless of what is held, drawn alongside
// the weapon rather than instead of it.
//
// These are NOT weapons, and that is the whole point. A weapon owns its
// hand slot, so the fist above can only appear when nothing else is
// equipped. These ride two psprite layers of their own, so a gun and a
// hand are drawn on the same controller at the same time -- the psprite
// draw loop runs a sprite pass and a model pass as complementary filters,
// not alternatives, so every layer carrying a model gets drawn.
//
// Layer numbers matter. The engine picks which controller a psprite rides
// by its caller, then falls back to the layer ID, treating anything at or
// above PSprite.OFFHANDWEAPON as the off hand. That fallback is what lets
// a non-weapon reach the off hand at all.
// =====================================================================

class RS_HandIdle : Inventory
{
	Default
	{
		Inventory.MaxAmount 1;
		Inventory.InterHubAmount 1;
		+INVENTORY.UNDROPPABLE
		+INVENTORY.UNTOSSABLE
		+INVENTORY.QUIET
		// Model lookup goes through BaseSpriteModelFrames instead of the
		// state's sprite and frame, so the placeholder state below never
		// needs a real sprite.
		+DECOUPLEDANIMATIONS
	}
	States
	{
	Spawn:
		TNT1 A -1;
		Stop;
	}
}

class RS_HandIdleMain : RS_HandIdle {}
class RS_HandIdleOff  : RS_HandIdle {}

class RS_HandsAlwaysOn : EventHandler
{
	const LAYER_MAIN = 900000;
	const LAYER_OFF  = 1900000;   // >= PSprite.OFFHANDWEAPON, which is what puts it on the other controller

	// TRACKS HOW LONG player.PendingWeapon HAS BEEN STUCK, so a permanently
	// aborted switch can be told apart from a normal one still in flight.
	//
	// Proven in a real session, not theorised: a third-party weapon's own
	// Deselect state looped on itself, and the engine's own recursion guard
	// killed it mid-transition -- "Recursive weapon state loop in
	// 'X.5' -- aborted at depth 65". After that, ReadyWeapon/OffhandWeapon
	// keeps pointing at the aborted weapon: not null, just functionally dead
	// -- nothing renders it, nothing can fire it, and no later tic will ever
	// finish the switch that was supposed to replace it.
	//
	// `holding = ReadyWeapon != null` below cannot tell that apart from a
	// real, held weapon, so the hand posed as if gripping a gun that render
	// shows nothing in. Cannot simply gate on PendingWeapon != WP_NOCHANGE
	// either -- that field goes non-NOCHANGE on EVERY ordinary switch too,
	// and suppressing the grip pose for that would flicker the hand to empty
	// on every normal weapon change, trading a rare permanent bug for a
	// constant cosmetic one.
	//
	// So: count tics, not just presence. STUCK_THRESHOLD (70 tics, 2 real
	// seconds) is comfortably longer than any legitimate lower/raise cycle
	// -- even the ~16-tic non-instant path RS_Holsters' own comments cite --
	// so it never fires during a healthy switch and reliably fires once one
	// has genuinely stopped moving.
	const STUCK_THRESHOLD = 70;

	// ONE counter, not one per hand. player.PendingWeapon is itself a single
	// shared field (player.zs:2629 -- `player.PendingWeapon = weap;`, with no
	// hand index anywhere near it), so there is no native way to ask "which
	// hand is the stuck one" -- only "is a switch stuck at all". Once it is,
	// neither hand's ReadyWeapon/OffhandWeapon is trusted as "definitely
	// holding" until it resolves; the rare cost is a legitimate hand's grip
	// pose also going conservative for a couple of tics if only the OTHER
	// hand was actually the broken one, which is a far smaller wrong than a
	// hand staying permanently posed around a gun that renders nothing.
	private int pendingTics;

	override void WorldTick()
	{
		if (consoleplayer < 0 || consoleplayer >= MAXPLAYERS)
			return;
		if (!playeringame[consoleplayer])
			return;

		let player = players[consoleplayer];
		let pawn = player.mo;
		if (pawn == null)
			return;

		CVar cShow = CVar.GetCVar("rs_hands", player);
		if (cShow != null && !cShow.GetBool())
		{
			Clear(player, LAYER_MAIN);
			Clear(player, LAYER_OFF);
			// StandInForFist hides the weapon layer while a fist is equipped
			// and only ever un-hides it on its NEXT call -- which this early
			// out skips. Left alone, NoDraw sticks on the DPSprite (the engine
			// reuses the layer object across weapon switches and serialises
			// the flag), so every gun raised in that hand afterwards renders
			// nothing until rs_hands is switched back on.
			UnhideWeaponLayers(player);
			return;
		}

		// Count how long PendingWeapon has been stuck, then forget the count
		// the instant it is not -- this has to self-heal every tic, since a
		// switch that resolves normally 4 tics from now must not leave a
		// leftover count sitting around from an earlier, unrelated one.
		if (player.PendingWeapon != WP_NOCHANGE)
			pendingTics++;
		else
			pendingTics = 0;
		bool switchStuck = pendingTics > STUCK_THRESHOLD;

		// GripContext is None only when the squeeze is not held -- every other
		// value is a context that claimed an already-held grip -- so != 0 is a
		// reliable "squeeze down" regardless of what the grip is bound to.
		//
		// A weapon in the hand counts as gripped on its own. That is the
		// "hands hold the gun" half: the fingers wrap the moment something is
		// equipped, without the player having to hold the squeeze down to keep
		// them there, and the trigger still curls the index on top.
		int buttons = player.cmd.buttons;
		Show(player, pawn, LAYER_MAIN, "RS_HandIdleMain",
			player.ReadyWeapon != null && !switchStuck, pawn.GripContextMain != 0,
			(buttons & BT_ATTACK) != 0, pawn.FingerTouchMain,
			pawn.GripSubjectMain);
		Show(player, pawn, LAYER_OFF,  "RS_HandIdleOff",
			player.OffhandWeapon != null && !switchStuck, pawn.GripContextOff != 0,
			(buttons & BT_OFFHANDATTACK) != 0, pawn.FingerTouchOff,
			pawn.GripSubjectOff);
	}

	// Debug only: last pose reported per hand, so the trace prints on change
	// rather than once per tic.
	private int dbgMain, dbgOff;

	// Pose blending state, per hand. from -> to over blendTics, so the fingers
	// travel between poses instead of teleporting.
	private int blendFromMain, blendToMain, blendTicsMain;
	private int blendFromOff,  blendToOff,  blendTicsOff;

	private double ReadF(PlayerInfo player, String name, double def)
	{
		CVar c = CVar.GetCVar(name, player);
		return (c != null) ? c.GetFloat() : def;
	}

	private string PoseName(int p)
	{
		if (p == POSE_HOLD_ROUND)    return "HOLD a round";
		if (p == POSE_HOLD_SHELL)    return "HOLD a shell";
		if (p == POSE_INSERT)        return "INSERT (thumb driving it home)";
		if (p == POSE_HOLD_SLIDE)    return "HOLD the slide";
		if (p == POSE_HOLD_MAG)      return "HOLD a magazine";
		if (p == POSE_HOLD_FOREGRIP) return "HOLD a foregrip";
		if (p == POSE_HOLD_FOREND)   return "HOLD the forend";
		if (p == POSE_REACH)         return "REACH (fingers splayed)";
		if (p == POSE_SUPPORT)       return "SUPPORT (round the firing hand)";
		if (p == POSE_FIRE_TU)  return "FIRE, thumb up";
		if (p == POSE_READY_TU) return "READY (finger on trigger), thumb up";
		if (p == POSE_READY_TD) return "READY (finger on trigger), thumb down";
		if (p == POSE_GRIP_TU)  return "GRIP, thumb up";
		if (p == POSE_GRIPFIRE) return "GRIP+FIRE (index curled, thumb parked)";
		if (p == POSE_THUMBOUT) return "THUMB OUT (fist, thumb clear)";
		if (p == POSE_PINCH)   return "PINCH (thumb to index)";
		if (p == POSE_FIST)    return "FIST (all closed)";
		if (p == POSE_TRIGGER) return "TRIGGER (index curled)";
		if (p == POSE_POINT)   return "GRIP (3-4-5 closed)";
		return "OPEN";
	}

	// Pose frames baked into the model. Stable slots -- reload and weapon
	// interaction poses append as 4, 5, 6 and nothing already authored moves.
	const POSE_OPEN    = 0;   // nothing held
	const POSE_POINT   = 1;   // fingers 3-4-5 closed, index and thumb out
	const POSE_TRIGGER = 2;   // index curled only
	// The SYNTHETIC fist, not the authored one, and that is a reversal.
	//
	// Source frame 503 was used first, on the reasonable assumption that an
	// animator's fist beats one derived from five curl angles. Then the
	// fingertips were measured, because the splay between them is exactly what
	// stands out when you are constantly closing your hand on things:
	//
	//     authored source frame 503   idx-mid 0.00152  mid-ring 0.00146  ring-pink 0.00176
	//     synthetic fist (pose 3)     idx-mid 0.00145  mid-ring 0.00081  ring-pink 0.00085
	//
	// A third less spread overall, and nearly half on the middle and ring pair
	// that was the worst of it. The synthetic fist wins because it gets the
	// knuckle adduction the exporter now solves for -- the sideways squeeze
	// that draws the fingers together as they close -- and a captured frame
	// cannot, being captured verbatim.
	//
	// Frame 513 stays in the model and stays reachable from Force pose.
	const POSE_FIST    = 3;
	const POSE_FIST_AUTHORED = 513;   // the animator's, kept for comparison
	const POSE_PINCH   = 4;   // thumb meets index -- magazines, shells, slide, charging handle
	const POSE_THUMBOUT= 5;   // fist with the thumb clear, for a magazine release
	const POSE_GRIPFIRE= 6;   // on a gun with the trigger pulled -- thumb as POSE_POINT
	const POSE_GRIP_TU = 7;   // on a gun, thumb lifted clear
	const POSE_READY_TD= 8;   // index resting ON the trigger, thumb wrapped
	const POSE_READY_TU= 9;   // index resting ON the trigger, thumb lifted
	const POSE_FIRE_TU = 10;  // trigger pulled, thumb lifted
	const POSE_MAX     = 10;

	// The model also carries the ENTIRE source animation after the poses above
	// -- 1278 authored frames, roughly 60 to 100 genuinely distinct hand shapes
	// from the original rig. They are kept because an animator's performance
	// beats anything derived from five curl angles, and 300KB is cheap.
	//
	// Source frame N lives at model frame SOURCE_BASE + (N - 1).
	const SOURCE_BASE  = 11;
	const SOURCE_COUNT = 1278;

	// Interaction poses -- what the hand does to a WEAPON rather than to a
	// controller. Solved against real-world sizes by the exporter (a pinch on a
	// 2cm shell, a wrap round a 4.5cm forend) rather than typed in, and parked
	// AFTER the source animation so that none of the indices above moved: the
	// exporter writes these numbers out to hand_frames.txt so they cannot drift
	// from the model.
	const HOLD_BASE          = 1289;
	const POSE_HOLD_ROUND    = HOLD_BASE + 0;   // one cartridge, fingertips
	const POSE_HOLD_SHELL    = HOLD_BASE + 1;   // a shotgun shell, fuller grip
	const POSE_INSERT        = HOLD_BASE + 2;   // thumb driving it home
	const POSE_HOLD_SLIDE    = HOLD_BASE + 3;   // pinched on the serrations
	const POSE_HOLD_MAG      = HOLD_BASE + 4;   // wrapped, thumb along the spine
	const POSE_HOLD_FOREGRIP = HOLD_BASE + 5;   // vertical foregrip
	const POSE_HOLD_FOREND   = HOLD_BASE + 6;   // pump, a fat cylinder
	const POSE_REACH         = HOLD_BASE + 7;   // fingers splayed, about to grab
	const POSE_SUPPORT       = HOLD_BASE + 8;   // wrapped round the firing hand

	// Bits of FingerTouchMain / FingerTouchOff, published by the OpenXR layer
	// from the controller's capacitive pads. Contact, not press.
	const TOUCH_THUMB  = 1;
	const TOUCH_INDEX  = 2;

	// Deliberately "something decides which pose this hand shows", with grip and
	// trigger being the first thing plugged in. Reload logic can set a pose the
	// same way later without this needing to change shape.
	// One fist for every mod. A mod's fist often does NOT descend from Fist --
	// plenty define their own weapon base -- so an inheritance test alone is not
	// enough, hence the name check too. Deliberately narrow: a false positive hides a real gun, which is far
	// worse than missing an exotic melee weapon, so this only matches things
	// that announce themselves as fists.
	private bool IsFist(Weapon w)
	{
		// RS_HandFist.IsFistClass is the single definition; a second one here
		// drifted (case-sensitive vs not, replacement or not) and the hand
		// drew a weapon as empty that the holsters refused to store into.
		return w != null && RS_HandFist.IsFistClass(w.GetClass());
	}

	// Stand in for a mod's fist weapon: stop the weapon drawing and show the
	// hand instead. The weapon is untouched otherwise -- it keeps its states,
	// damage, ammo and slot, so the mod still decides what punching DOES. Only
	// what you SEE changes, which is why this needs no cooperation from the mod
	// and no edits to its fist class.
	private bool StandInForFist(PlayerInfo player, int layer)
	{
		CVar c = CVar.GetCVar("rs_hands_fists", player);
		bool want = (c == null) || c.GetBool();

		bool isMain = (layer == LAYER_MAIN);
		Weapon w = isMain ? player.ReadyWeapon : player.OffhandWeapon;
		bool fist = want && IsFist(w);

		// Cleared as well as set. Leaving NoDraw behind on a layer that later
		// holds a gun would hide the gun.
		let wpsp = player.FindPSprite(isMain ? PSprite.WEAPON : PSprite.OFFHANDWEAPON);
		if (wpsp != null)
			wpsp.NoDraw = fist;

		return fist;
	}

	// What the hand is CLOSED ON beats what its buttons are doing, because it
	// is strictly better information. A grip button says the player squeezed;
	// a subject says the player squeezed ON A SHELL, and only one of those can
	// be posed correctly.
	//
	// The engine arbitrates the subject (see Actor.GripSubjectMain/Off) from
	// claims written by whichever mod knows -- RS_Reloading for ammo, a weapon
	// mod for its own furniture -- so this needs no knowledge of any of them.
	//
	// Returns -1 for "nothing claimed", which falls through to the button
	// poses below.
	// Local copies rather than a reach into RS_Reach: this class is registered
	// first in MAPINFO and a cross-class static call at load order zero is a way
	// to fail the whole package for no gain. Two lines each.
	static double RS_Hands_Num(String n, PlayerInfo p, double d)
	{
		let c = CVar.GetCVar(n, p);
		return c ? c.GetFloat() : d;
	}

	static double RS_Hands_NormDeg(double a)
	{
		while (a >  180.0) a -= 360.0;
		while (a < -180.0) a += 360.0;
		return a;
	}

	private int PoseForSubject(int subj, bool holding)
	{
		// A hand with its own weapon in it is not supporting anything, whatever
		// the arbiter concluded. Guarded here rather than in the engine because
		// this is the only side that knows what is in the OTHER hand, and a
		// support pose laid over a gun would show the fingers wrapped round
		// thin air beside it.
		if (subj == GRIPSUBJ_Support && holding)
			return -1;

		switch (subj)
		{
		case GRIPSUBJ_Round:     return POSE_HOLD_ROUND;
		case GRIPSUBJ_Shell:     return POSE_HOLD_SHELL;
		case GRIPSUBJ_Inserting: return POSE_INSERT;
		case GRIPSUBJ_Magazine:  return POSE_HOLD_MAG;
		case GRIPSUBJ_Forend:    return POSE_HOLD_FOREND;
		case GRIPSUBJ_Foregrip:  return POSE_HOLD_FOREGRIP;
		case GRIPSUBJ_Slide:     return POSE_HOLD_SLIDE;
		case GRIPSUBJ_Support:   return POSE_SUPPORT;
		case GRIPSUBJ_Holster:   return POSE_REACH;
		case GRIPSUBJ_Pouch:     return POSE_REACH;   // reaching for a magazine, same splay
		}

		// GRIPSUBJ_Grip deliberately falls through. A hand on a pistol grip is
		// already the best-served case here -- six poses covering trigger
		// pulled, finger resting on the trigger, and thumb up or wrapped, all
		// dialled in -- and a single flat "holding a grip" frame would be a
		// downgrade, not an addition.
		return -1;
	}

	private int PoseFor(bool holding, bool grip, bool trigger, int touch)
	{
		// Where the fingers REST, which buttons cannot report. A thumb lying on
		// the stick and a thumb lifted clear are the same button state; so are
		// a finger indexed along the frame and a finger sitting on the trigger.
		bool thumbDown = (touch & TOUCH_THUMB) != 0;
		bool onTrigger = (touch & TOUCH_INDEX) != 0;

		// A weapon in this hand is its own branch, and it has to be: the fist
		// pose folds the thumb ACROSS the fingers, which is a punch, not a
		// grip. Routing grip+trigger there re-posed the thumb every time the
		// player fired. On a gun only the index moves -- the thumb is wrapped
		// on the frame and stays put -- so POSE_GRIPFIRE carries the same
		// thumb angle as POSE_POINT and differs only in the index.
		if (holding)
		{
			if (trigger)   return thumbDown ? POSE_GRIPFIRE : POSE_FIRE_TU;
			if (onTrigger) return thumbDown ? POSE_READY_TD : POSE_READY_TU;
			return thumbDown ? POSE_POINT : POSE_GRIP_TU;
		}

		if (grip && trigger) return POSE_FIST;

		// Empty-hand grip: three fingers closed, index out. Where the thumb goes
		// is the player's choice, read off the capacitive pad rather than
		// assumed -- rest your thumb on the controller and it tucks in, lift it
		// and it stands up.
		//
		// POSE_GRIP_TU is now an authored frame with the thumb genuinely raised,
		// so it serves an empty hand as well as a hand on a gun -- which is why
		// the separate finger-gun pose it briefly had is gone again.
		if (grip)            return thumbDown ? POSE_POINT : POSE_GRIP_TU;
		if (trigger)         return POSE_TRIGGER;
		return POSE_OPEN;
	}

	private void Show(PlayerInfo player, PlayerPawn pawn, int layer, Name cls, bool holding, bool grip, bool trigger, int touch, int subject)
	{
		let hand = pawn.FindInventory(cls);
		if (hand == null)
		{
			pawn.GiveInventory(cls, 1);
			hand = pawn.FindInventory(cls);
			if (hand == null)
				return;
		}

		let psp = player.FindPSprite(layer);
		if (psp == null || psp.Caller != hand)
		{
			// FindState, not ResolveState -- ResolveState is an action
			// function and aborts when called without state context.
			State st = hand.FindState("Spawn");
			if (st == null)
				return;
			player.SetPsprite(layer, st, false, hand);
			psp = player.FindPSprite(layer);
			if (psp == null)
				return;
		}


		CVar cScale = CVar.GetCVar("rs_hand_scale", player);
		double s = (cScale != null) ? cScale.GetFloat() : 1.0;
		if (s <= 0.0)
			s = 1.0;
		psp.scale = (s, s);

		// The poses are frames of one baked clip and this picks one. There is
		// nothing to play, so no animation state is involved -- a held grip is
		// the same frame re-asserted, not a clip being restarted.
		//
		// This only reaches the bones because ProcessModelFrame now honours an
		// explicitly addressed frame on the decoupled path. Before that fix it
		// fell through to CalculateBonesOnlyOffsets and every pose rendered as
		// the rest pose.
		// A fist beats the grip poses outright: a hand holding nothing but its
		// own fist is closed, and the gun-handling poses would read as gripping
		// a weapon that is not there.
		// A fist weapon means the hand is EMPTY, not that the hand is frozen.
		//
		// This used to force POSE_FIST outright, which locked the hand shut:
		// with no gun equipped Doom hands you the Fist, so the stand-in fired
		// permanently and the trigger and grip stopped doing anything at all.
		// The hand you are least likely to be holding something with became the
		// only one that could not move.
		//
		// So the fist weapon is fed in as "holding nothing" instead, and the
		// ordinary empty-hand poses run: open at rest, index curls on the
		// trigger, closes to a fist when you squeeze, thumb up for a finger
		// gun. Punching still makes a fist -- the attack IS the trigger -- and
		// the weapon still does the damage; only what you see is ours.
		bool fistWeapon = StandInForFist(player, layer);
		int pose = PoseFor(holding && !fistWeapon, grip, trigger, touch);

		// Anything the hand has actually taken hold of overrides that. Checked
		// after the fist stand-in rather than before it so that a fist weapon
		// still shows a fist -- there is nothing in that hand to hold.
		// Same notion of "empty" as PoseFor above: a fist stand-in means the
		// hand has nothing in it, so it CAN support the other hand's gun.
		int held = PoseForSubject(subject, holding && !fistWeapon);
		if (held >= 0)
			pose = held;

		// WHAT THE HELD-STATE MACHINE SAYS BEATS THE SUBJECT.
		//
		// Those are two different questions and RS_GrabRule keeps them apart on
		// purpose. A barrel CLAIMS Magazine, because Forend and Foregrip are the
		// two subjects the engine reads as "supporting the other hand's weapon"
		// and claiming either would have the arbiter conclude you are bracing a
		// gun you are not holding. But the SHAPE a hand makes round a barrel is
		// the forend shape. Read the subject alone and every barrel in the game
		// is held like a magazine.
		//
		// Only consulted for a hand actually holding something -- PoseIn returns
		// -1 otherwise, which is the same "not my business" the rest of this
		// chain already uses.
		let hs = RS_Held.Get();
		if (hs)
		{
			int hp = hs.PoseIn((layer == LAYER_MAIN) ? 0 : 1);
			if (hp >= 0)
				pose = hp;
		}

		// REACHING. Fingers splayed while this hand has something locked at a
		// distance, and for the whole time that thing is in the air.
		//
		// The flight half is the one that matters. A pull takes a third of a
		// second and has to be CAUGHT, and the hand reverting to rest for that
		// whole window is the game showing you nothing at the exact moment you
		// need to know something is inbound. An open hand is what a person does
		// when something is thrown to them.
		//
		// Below the held pose on purpose: once something is actually IN the
		// hand, its own shape wins. You cannot be reaching for a thing you are
		// already holding.
		if (hs && hs.PoseIn((layer == LAYER_MAIN) ? 0 : 1) < 0)
		{
			int hnd = (layer == LAYER_MAIN) ? 0 : 1;
			let pl = RS_Pull.Get();
			// THE THREE ACTS, IN THE HAND.
			//
			//   pointing at it   the controllers decide -- nothing imposed
			//   LOCKED on it     a FIST. You have closed on it at range.
			//   catching it      REACH. Open, because it is coming to you.
			//
			// Fist for the lock rather than the splayed reach: splayed is what a
			// hand does BEFORE it takes hold, and the whole point of the lock is
			// that you already have. It opens again for the flight, because the
			// next thing you do is catch.
			if (pl && pl.Flying(hnd))
				pose = POSE_REACH;
			else if (pl && pl.Locked(hnd))
				pose = POSE_FIST;
		}

		// A forced pose beats the controllers entirely. Held rather than
		// latched, so leaving the menu setting alone parks the hand on that
		// frame for as long as it takes to look at it.
		CVar cForce = CVar.GetCVar("rs_hands_forcepose", player);
		if (cForce != null && cForce.GetInt() >= 0)
		{
			// The menu numbers every pose continuously, 0..18, because a
			// dropdown with a jump from 10 to 1289 in it would be absurd. The
			// interaction poses really do live past the source animation, so
			// anything above POSE_MAX is mapped across to where it actually
			// is.
			int v = cForce.GetInt();
			pose = (v <= POSE_MAX)
				? v
				: min(HOLD_BASE + (v - POSE_MAX - 1), HOLD_BASE + 8);
		}

		// Scrubbing the source animation, so a good shape can be found by eye
		// and then wired in by frame number. Beats guessing angles.
		CVar cSrc = CVar.GetCVar("rs_hands_srcframe", player);
		if (cSrc != null && cSrc.GetInt() >= 0)
			pose = SOURCE_BASE + min(cSrc.GetInt(), SOURCE_COUNT - 1);

		// Blend into the new pose instead of snapping to it.
		//
		// ModelFrame/ModelFrameNext/ModelFrameLerp exist precisely for this --
		// the renderer blends bone matrices between the two frames by the lerp
		// factor -- and setting the lerp to 0 with both frames equal, as this
		// did before, is an explicit instruction NOT to blend. So every pose
		// change was a single-tic jump between rigged poses, which reads as the
		// hand teleporting between shapes.
		//
		// Blending BONE MATRICES, not sprite frames: the fingers travel from one
		// pose to the other, so a grip closes rather than appearing closed.
		bool isMain = (layer == LAYER_MAIN);
		int from = isMain ? blendFromMain : blendFromOff;
		int to   = isMain ? blendToMain   : blendToOff;

		// Read UNCONDITIONALLY and let the <= 0 test below do the snapping.
		// Fixed 2026-08-26: the guard used to be `cSpeed.GetFloat() > 0.0`,
		// so setting rs_hands_blend to 0 meant the cvar was never read at all
		// and speed kept its 4.0 default -- which made the (speed <= 0.0)
		// branch below unreachable and blending impossible to turn off.
		// CVARINFO.txt:43 states "0 disables blending and poses snap".
		double speed = 4.0;
		CVar cSpeed = CVar.GetCVar("rs_hands_blend", player);
		if (cSpeed != null)
			speed = cSpeed.GetFloat();

		if (pose != to)
		{
			// Target changed mid-blend. Two frame numbers cannot express an
			// in-between pose, so the closest thing to "start from where the
			// fingers ARE" is the nearer end of the blend in progress: past
			// halfway, continue from the old target; before it, from the old
			// start. (The previous test, `tics > 0 ? from : to`, always chose
			// the old START -- tics is never 0 here -- which was the backwards
			// flick it claimed to prevent.)
			int ticsNow = isMain ? blendTicsMain : blendTicsOff;
			double prog = (speed <= 0.0) ? 1.0 : double(ticsNow) / speed;
			from = (prog >= 0.5) ? to : from;
			to = pose;
			if (isMain) { blendFromMain = from; blendToMain = to; blendTicsMain = 0; }
			else        { blendFromOff  = from; blendToOff  = to; blendTicsOff  = 0; }
		}

		int tics = isMain ? blendTicsMain : blendTicsOff;

		double f = (speed <= 0.0) ? 1.0 : double(tics) / speed;
		if (f >= 1.0)
		{
			// Arrived. Park on the target so a held pose is not re-blended every
			// tic, which would leave the fingers permanently trembling.
			f = 1.0;
			from = to;
			if (isMain) blendFromMain = from; else blendFromOff = from;
		}
		else
		{
			if (isMain) blendTicsMain++; else blendTicsOff++;
		}

		psp.ModelFrame     = from;
		psp.ModelFrameNext = to;
		psp.ModelFrameLerp = f;

		CVar cDbg = CVar.GetCVar("rs_hands_debug", player);
		if (cDbg != null && cDbg.GetBool())
		{
			// isMain is already in scope, set by the blend above.
			int last = isMain ? dbgMain : dbgOff;
			if (pose != last)
			{
				if (isMain) dbgMain = pose; else dbgOff = pose;
				Console.Printf("[HANDS   ] %s grip=%s trigger=%s -> frame %d  %s",
					isMain ? "MAIN" : "OFF ",
					grip ? "1" : "0", trigger ? "1" : "0",
					pose, PoseName(pose));
			}
		}
	}

	private void Clear(PlayerInfo player, int layer)
	{
		// Pass the layer's own caller. With a null caller the engine derives
		// one from the layer id -- ReadyWeapon for anything but the offhand
		// layer -- and if THAT is null GetPSprite returns nothing and the hand
		// stays drawn, frozen on its last pose, for as long as rs_hands is off.
		let psp = player.FindPSprite(layer);
		if (psp != null)
			player.SetPsprite(layer, null, false, psp.Caller);
	}

	// See the rs_hands-off branch in WorldTick. Any early exit taken after
	// StandInForFist may have hidden a weapon layer must undo that.
	private void UnhideWeaponLayers(PlayerInfo player)
	{
		let wm = player.FindPSprite(PSprite.WEAPON);
		if (wm != null) wm.NoDraw = false;
		let wo = player.FindPSprite(PSprite.OFFHANDWEAPON);
		if (wo != null) wo.NoDraw = false;
	}
}
