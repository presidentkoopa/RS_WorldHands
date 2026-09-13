// HELD STATE -- who is holding what, and nothing else.
//
// This is deliberately the smallest thing in the package and everything else
// leans on it: hardpoints, gestures, throwing and melee all need to ask "is this
// in a hand, and whose" and all of them need the same answer.
//
// WHY IT IS A TABLE AND NOT A FIELD ON THE OBJECT.
//
// The previous shape was `heldByHand` -- one int, living on the thing being
// held. It cannot represent two hands on one object, so the second hand simply
// overwrote the first hand's number. Nothing failed, nothing printed: the object
// was silently STOLEN out of the other hand, and the hand it left kept behaving
// as though it were still full. A single int also cannot say which hand is
// leading, so a two-handed hold had no way to decide whose palm the object sits
// in.
//
// So the authority is here, in one place, as two slots -- and the object carries
// no state at all. That also sidesteps the fact that a barrel is a stock Doom
// class with nowhere to put a field.
//
// Reading it is a two-element scan. That is free, and it is worth far more than
// the pointer chase it replaces.

class RS_Held : EventHandler
{
	const HAND_MAIN = 0;
	const HAND_OFF  = 1;

	// A hand's part in a hold. PRIMARY owns the object's position and owns the
	// backup of the flags we changed; SUPPORT is the second hand on the same
	// object. Which is which is decided by who got there first, and it survives
	// the primary letting go -- see Release.
	const ROLE_NONE    = 0;
	const ROLE_PRIMARY = 1;
	const ROLE_SUPPORT = 2;

	// What a Take actually did. Callers want this: taking something free, taking
	// it out of your other hand and putting a second hand onto it are three
	// different events and should not sound or buzz the same.
	const TAKE_REFUSED = 0;
	const TAKE_TOOK    = 1;
	const TAKE_JOINED  = 2;
	const TAKE_PASSED  = 3;

	// ---- the state -------------------------------------------------------
	// Indexed by hand. hActor[h] == hActor[1-h] IS the two-handed case; there is
	// no separate flag for it, because a flag and the pointers could disagree.
	private Actor hActor[2];
	private int   hRole[2];
	private int   hSubject[2];
	// The hand SHAPE, carried separately from the subject. The subject is what
	// the engine's arbiter is told; the pose is what the fingers do. See the
	// note on RS_GrabRule for why collapsing the two breaks a barrel.
	private int   hPose[2];

	// The flags we changed on the object, so they can be put back exactly.
	// Stored in the PRIMARY hand's slot and moved when the primary changes.
	// Saved once per object, never per hand: a second hand joining must not
	// re-save flags this system has already modified, or releasing leaves the
	// object permanently weightless and permanently unpickable.
	// hOwnsFlags says which slot is holding the backup, instead of leaving it to
	// be inferred from the role. The inference is currently sound -- a lone
	// holder is always PRIMARY, because Release promotes the survivor -- but it
	// is an invariant spread across three methods, and if any of them ever stops
	// maintaining it the symptom is an object handed back with the wrong flags:
	// permanently weightless, permanently unpickable, and nothing in the log.
	// Cheaper to state it than to keep proving it.
	private bool hOwnsFlags[2];
	// THE SCALE AN OBJECT HAD BEFORE A HAND CLOSED ON IT.
	//
	// Saved because putting it on the follow-hand path CHANGES ITS SIZE, and it
	// has to be given back exactly -- an object that comes back a little
	// different every time it is picked up and dropped is a slow leak nobody
	// can see happening.
	// The renderer's own conversion between the world frame and a controller's,
	// from models.cpp. A const rather than a literal because it appears in two
	// places that must never disagree.
	const FOLLOWHAND_UNIT_SCALE = 0.01;

	private Vector2 hSavedScale[2];
	private bool hSavedSpecial[2];
	private bool hSavedNoGravity[2];
	// THE THIRD PAIR, and the barrel is why. See SaveFlags.
	private bool hSavedThruActors[2];

	// THE ROLL TRIO, borrowed and restored exactly like the three above, and
	// carried by the same hOwnsFlags token so a second hand joining a hold can
	// never re-save what the first hand already changed.
	//
	// A sprite normally turns to face you and has no visible facing of its own,
	// which is why this file used to set no orientation at all. But RS_Pull
	// already proved the way round it: +ROLLSPRITE, +ROLLCENTER and
	// +INTERPOLATEANGLES together make a billboard genuinely read as a solid
	// object turning in 3D, and it uses exactly that to tumble things through
	// the air. Nothing about the trick is specific to flight -- it just needs a
	// roll written each tic, and a hand holding something has a far better
	// number to write than a ballistic arc does.
	//
	// NOT INERT AT ROLL ZERO, which is why these are saved rather than simply
	// switched on and left. +ROLLSPRITE makes hw_sprites apply a pixelstretch
	// rescale to any actor carrying it, and +ROLLCENTER drops the sprite's own
	// offsets -- so a held object would still be drawn differently from a
	// dropped one even with the roll left at zero. Off has to mean untouched.
	private bool   hSavedRollSprite[2];
	private bool   hSavedRollCentre[2];
	private bool   hSavedInterpAng[2];
	private double hSavedRoll[2];

	// YAW AND PITCH TOO, ONCE THE THING IS SOLID.
	//
	// Roll stood alone for as long as a held object was a billboard, and that
	// was correct: a sprite turns to face you, so its yaw is unobservable, and
	// nothing in the renderer reads a sprite's pitch at all. Neither is true of
	// a voxel. A voxel has a front and a top, so all three angles are visible
	// and a barrel that answers only one of them reads as broken in a way the
	// sprite never did.
	//
	// Saved for the same reason roll is: Angle is not decorative on every
	// actor. A monster's facing is live gameplay state, and dropping one that
	// has been turned to match a wrist would leave it aiming somewhere it never
	// chose. Restored on release, on hand-off, and the instant the toggle goes
	// off mid-hold.
	private double hSavedPitch[2];
	private double hSavedAngle[2];

	// Edge detector for the ReadyWeapon watch in WorldTick. Not per-player:
	// the trace is a console print for the local player and nothing else reads
	// it, same as every other diagnostic in this file.
	private bool wasReadyNull;

	// A HELD THING BECOMES A REAL 3D OBJECT, if a voxel exists for it.
	//
	// The roll trick above makes a billboard READ as something turning over,
	// and it is a good illusion, but it is still a flat sprite that always
	// faces you -- turn it far enough and the lie shows. A voxel is genuinely
	// solid, and it is also the only path on which the engine will honour
	// actor PITCH and ROLL at all: VOXELDEF entries can carry UseActorPitch
	// and UseActorRoll (models.cpp:1765-1766), which is exactly what a
	// borrowed weapon MODELDEF cannot.
	//
	// Voxel selection is otherwise all-or-nothing -- keyed on the sprite frame
	// and gated by the global r_drawvoxels -- so this needed an engine change
	// to be possible at all: AActor.VoxelOverride, added 2026-08-28, which
	// ignores that cvar and outranks any model, for one actor at a time.
	// That is what lets a voxel pack sit loaded and inert until something is
	// actually picked up.
	//
	// Saved and restored like every other borrowed flag, under the same
	// hOwnsFlags token, so a dropped object goes back to being whatever it was
	// -- including already-voxel, if the player has r_drawvoxels on globally.
	private bool   hSavedVoxel[2];
	// Whether this hand has scaled the object up for the controller's frame. The
	// hold runs every tic, and the scale must be applied ONCE per take -- see the
	// follow-hand block in CarryOne.
	private bool   hFollowScaled[2];
	// The collision radius it had when taken, 0 when this hand never shrank it.
	// See SaveFlags: a held thing is carried thin.
	private double hSavedRadius[2];

	// The last value THIS system wrote to GripClaimMain/Off, kept apart from the
	// slot above because the slot is gone by the time the claim needs clearing.
	// The convention on GripClaim* is "clear only a value that is yours", and
	// after a release hSubject is already None -- so comparing against it says
	// the claim was never ours and the hand stays flagged as holding something
	// for the rest of the level, with stabilize permanently stood down.
	private int hClaimed[2];

	// ---- the grip arbiter -------------------------------------------------
	//
	// DUPLICATED FROM RR_Reload'S ArbiterProbe ON PURPOSE, and it must stay
	// duplicated. A shared client helper would have to live somewhere, and
	// every consumer naming that somewhere gets a COMPILE-TIME dependency on
	// it -- which is fatal AND GLOBAL if the file is absent (thingdef.cpp:
	// 420-424 refuses every pk3 later in the load order). The whole reason the
	// arbiter is a Service reachable by string is that neither side may name
	// the other. Three small copies of a lookup is the price of that, and it is
	// the correct price.
	//
	// Trimmed against RR_Reload's version: no proto logging, no tri-state seen
	// flag. Those exist there because that file's conversion was staged as a
	// deliverable in itself. This one only needs the handle.
	private Service arbiter;
	private int     arbWait;

	const RS_ARB_RETRY = 350;    // ~10s at 35Hz; a miss re-checks, a hit does not
	const RS_ARB_IDENT = 1;      // the arbiter's frozen IDENTITY, never its PROTOCOL
	// NOT A const: ZScript constants may only be int, float, string or bool,
	// so a Name const fails at load with "Bad type for constant definiton".
	// The owner name is inlined as a literal at each call site instead.

	// A COUNTDOWN, NOT A DEADLINE. ServiceIterator.Find allocates a fresh
	// iterator per call, so a game without the arbiter would otherwise build one
	// every tic forever to learn the same nothing -- and a saved `gametic + N`
	// deadline goes stale across a process restart, where gametic returns to 0.
	private void ArbiterFind()
	{
		if (arbiter) return;
		if (arbWait > 0) { arbWait--; return; }

		ServiceIterator it = ServiceIterator.Find("RS_GripArbiterService");
		Service s;
		while (s = it.Next())
		{
			// IDENTITY, not presence: ServiceIterator matches on a
			// case-insensitive SUBSTRING, so a hit is not proof of identity.
			if (s.GetInt("grip.hello", "", 0, 0, null, 'None') != RS_ARB_IDENT)
				continue;
			arbiter = s;
			break;
		}

		// Only a miss arms the throttle, so the re-resolve after a savegame load
		// lands on the next tic rather than up to ten seconds later.
		if (!arbiter) arbWait = RS_ARB_RETRY;
	}

	// ---- access ----------------------------------------------------------

	static RS_Held Get()
	{
		return RS_Held(EventHandler.Find("RS_Held"));
	}

	Actor HeldBy(int hand) const
	{
		if (hand != HAND_MAIN && hand != HAND_OFF) return null;
		return hActor[hand];
	}

	bool HandIsFull(int hand) const
	{
		return HeldBy(hand) != null;
	}

	bool IsHeld(Actor a) const
	{
		return a != null && (hActor[0] == a || hActor[1] == a);
	}

	// Bit 0 = main hand, bit 1 = off hand. 3 means both.
	int HandsOn(Actor a) const
	{
		if (!a) return 0;
		int m = 0;
		if (hActor[0] == a) m |= 1;
		if (hActor[1] == a) m |= 2;
		return m;
	}

	bool TwoHanded(Actor a) const
	{
		return HandsOn(a) == 3;
	}

	// -1 when nobody holds it.
	int PrimaryHand(Actor a) const
	{
		if (!a) return -1;
		for (int h = 0; h < 2; h++)
			if (hActor[h] == a && hRole[h] == ROLE_PRIMARY) return h;
		return -1;
	}

	int SubjectIn(int hand) const
	{
		if (hand != HAND_MAIN && hand != HAND_OFF) return GRIPSUBJ_None;
		return hSubject[hand];
	}

	// -1 when this hand is holding nothing, which is also "let the controllers
	// decide", so a caller can pass it straight through.
	int PoseIn(int hand) const
	{
		if (hand != HAND_MAIN && hand != HAND_OFF) return -1;
		return hActor[hand] ? hPose[hand] : -1;
	}

	// ---- policy ----------------------------------------------------------

	private static double Num(String n, PlayerInfo p, double d)
	{
		let c = CVar.GetCVar(n, p);
		return c ? c.GetFloat() : d;
	}
	private static bool Flag(String n, PlayerInfo p, bool d)
	{
		let c = CVar.GetCVar(n, p);
		return c ? c.GetBool() : d;
	}

	// ---- taking and letting go -------------------------------------------

	// The one call that changes anything. Returns a TAKE_* telling the caller
	// what it got, which is never "nothing happened" by accident: a refusal is
	// TAKE_REFUSED and says so.
	// twohand comes from the grabbability table (RS_GrabRule), not from a size
	// guess made here. It was a size guess for exactly one commit: a medikit and
	// a barrel have nearly the same collision cylinder in Doom, so the cylinder
	// cannot answer this and the table has to.
	int Take(int hand, Actor a, int subject, int pose, bool twohand, PlayerInfo p)
	{
		if (!a) return TAKE_REFUSED;
		if (hand != HAND_MAIN && hand != HAND_OFF) return TAKE_REFUSED;
		// A full hand must let go first. Swapping in place is a real gesture but
		// it is a DECISION, and the decision belongs to whoever called this.
		if (hActor[hand]) return TAKE_REFUSED;

		int other = 1 - hand;

		// THE SECOND-GRAB CASE, which is the whole reason this class exists.
		if (hActor[other] == a)
		{
			if (Flag("rs_hold_twohand", p, true) && twohand)
			{
				// Join as support. The other hand keeps position and keeps the
				// flag backup -- it was primary and still is.
				hActor[hand]   = a;
				hRole[hand]    = ROLE_SUPPORT;
				hSubject[hand] = subject;
				hPose[hand]    = pose;
				return TAKE_JOINED;
			}
			if (Flag("rs_hold_pass", p, true))
			{
				// Hand to hand. The flags move with the object, not with the
				// hand: MoveFlagsTo copies the backup across before the old slot
				// is wiped, so the object is never left owning nothing.
				MoveFlagsTo(hand, other);
				hActor[hand]   = a;
				hRole[hand]    = ROLE_PRIMARY;
				hSubject[hand] = subject;
				hPose[hand]    = pose;
				ClearSlot(other);
				return TAKE_PASSED;
			}
			return TAKE_REFUSED;
		}

		// Free object.
		hActor[hand]   = a;
		hRole[hand]    = ROLE_PRIMARY;
		hSubject[hand] = subject;
		hPose[hand]    = pose;
		SaveFlags(hand, a);
		return TAKE_TOOK;
	}

	// LET GO, AND MAYBE THROW.
	//
	// Pass a player and the object leaves at the peak speed of your last ~180ms
	// of hand movement; pass none and it is a plain drop. Both are the same act
	// -- opening your hand -- and the difference is entirely in how fast the
	// hand was going, which is exactly how it works with a real object.
	//
	// The velocity is applied AFTER the flags are restored, because restoring
	// zeroes Vel: the object has to be an ordinary actor again before it can be
	// given the velocity that makes it fly.
	void Release(int hand, PlayerPawn pmo = null, PlayerInfo p = null)
	{
		if (hand != HAND_MAIN && hand != HAND_OFF) return;
		Actor a = hActor[hand];
		if (!a) return;

		int other = 1 - hand;
		bool otherStillHas = (hActor[other] == a);

		if (otherStillHas)
		{
			// Promote the remaining hand. It inherits the flag backup, because
			// the object is still held and its flags must stay ours until the
			// LAST hand comes off it.
			if (hRole[hand] == ROLE_PRIMARY)
			{
				MoveFlagsTo(other, hand);
				hRole[other] = ROLE_PRIMARY;
			}
			ClearSlot(hand);
			return;
		}

		// THE VELOCITY IS SOLVED BEFORE THE FLAGS GO BACK, because clearing the
		// player is only possible while the object can still pass through them.
		Vector3 v = (pmo && p) ? RS_Throw.VelocityFor(hand, pmo, p) : (0, 0, 0);

		// STEP IT CLEAR OF YOUR OWN BODY FIRST, or a thrown object goes UP and
		// nowhere else.
		//
		// Confirmed in headset on barrels, which is where it shows worst. The
		// hold borrows THRUACTORS so a solid object can sit inside your
		// collision cylinder at all; RestoreFlags hands that back. So the
		// instant you let go, a barrel is solid again AND still overlapping you
		// -- your radius is 16 and its own is 10, and anything in your hand is
		// well inside that 26. P_XYMovement then refuses every horizontal step
		// into you, while P_ZMovement is not blocked the same way, so the
		// throw's upward component survives and its forward component dies on
		// the first tic. It reads as momentum turning into height.
		//
		// Moved along the throw while THRUACTORS is still borrowed, so the step
		// itself can pass through you, and via TryMove so it cannot pass through
		// GEOMETRY -- throwing at a wall you are standing against must not post
		// the object into it. A refused step just leaves the object where it
		// was, which is the old behaviour and no worse.
		if (v.Length() > 0)
		{
			// The radius it is about to get back, not the thin one it is carried at:
			// the step has to clear you by the size that will collide with you.
			double clearBy = pmo.Radius + max(a.Radius, hSavedRadius[hand]) + 2.0;
			Vector2 dir = (v.x, v.y);
			if (dir.Length() > 0.01)
			{
				dir = dir / dir.Length();
				a.TryMove((a.Pos.x + dir.x * clearBy, a.Pos.y + dir.y * clearBy), 1);
			}
		}

		RestoreFlags(hand, a);
		ClearSlot(hand);

		// LAST, and only for the hand that actually let go of it. A two-handed
		// object released by one hand is still held by the other, and that path
		// returned above -- you cannot throw something you are still holding.
		if (pmo && p)
		{
			if (v.Length() > 0)
			{
				// Vel only. RestoreFlags put NOGRAVITY back one line above, and
				// ClearSlot has already zeroed the backup -- reading it here
				// would be reading state this method just wiped.
				a.Vel = v;
				let sw = RS_Swing.Get();
				if (sw) sw.Forget(hand);
				if (Flag("rs_hand_debug", p, true))
					Console.Printf("[RSTHROW] hand %d threw %s at %.1f m/s",
						hand, a.GetClassName(),
						RS_Swing.UnitsPerTicToMetresPerSec(v.Length()));
			}
		}
	}

	void ReleaseAll()
	{
		Release(HAND_MAIN);
		Release(HAND_OFF);
	}

	private void ClearSlot(int hand)
	{
		hActor[hand]   = null;
		hRole[hand]    = ROLE_NONE;
		hSubject[hand] = GRIPSUBJ_None;
		hPose[hand]    = -1;
		hOwnsFlags[hand]       = false;
		hSavedSpecial[hand]    = false;
		hSavedNoGravity[hand]  = false;
		hSavedThruActors[hand] = false;
		hSavedRollSprite[hand] = false;
		hSavedRollCentre[hand] = false;
		hSavedInterpAng[hand]  = false;
		hSavedRoll[hand]       = 0.0;
		hSavedPitch[hand]      = 0.0;
		hSavedAngle[hand]      = 0.0;
		hSavedVoxel[hand]      = false;
	}

	// Whether held objects turn with the wrist at all. Read per-use rather than
	// cached because it is a menu toggle, and switching it off has to put the
	// borrowed flags back on the very next tic -- see CarryOne.
	private bool RotateHeld(PlayerInfo p) const
	{
		return Flag("rs_hold_rotate", p, true);
	}

	// Whether a held object should become its voxel. Read per-use for the same
	// reason as the rotate toggle: switching it off has to put the object back
	// on the next tic, not at release.
	private bool VoxelHeld(PlayerInfo p) const
	{
		return Flag("rs_hold_voxel", p, true);
	}

	private void SaveFlags(int hand, Actor a)
	{
		hOwnsFlags[hand]       = true;
		hSavedSpecial[hand]    = a.bSPECIAL;
		hSavedNoGravity[hand]  = a.bNOGRAVITY;
		hSavedThruActors[hand] = a.bTHRUACTORS;
		hSavedRollSprite[hand] = a.bROLLSPRITE;
		hSavedRollCentre[hand] = a.bROLLCENTER;
		hSavedInterpAng[hand]  = a.bINTERPOLATEANGLES;
		hSavedRoll[hand]       = a.Roll;
		hSavedPitch[hand]      = a.Pitch;
		hSavedAngle[hand]      = a.Angle;
		hSavedVoxel[hand]      = a.VoxelOverride;
		hFollowScaled[hand]    = false;

		// SPECIAL cleared is the one that is not optional. An item in your hand
		// is an item permanently inside your own collision cylinder, so Doom's
		// touch check fires every single tic and the thing you just picked up
		// vanishes into inventory on the frame you grab it -- which is the exact
		// behaviour holding is meant to replace.
		a.bSPECIAL   = false;
		a.bNOGRAVITY = true;

		// AND THRUACTORS, WHICH IS WHY YOU COULD NEVER HOLD A BARREL.
		//
		// Nothing here cleared SOLID, and CarryOne moves the object with TryMove
		// -- Doom's real movement, which is the whole reason a carried thing
		// stops at walls. An ExplosiveBarrel is +SOLID and so are you, so the
		// move is refused the moment the palm comes within barrel radius plus
		// player radius, 10 + 16 = 26 map units. That is most of the envelope a
		// hand can reach: the object never moved, ShouldBreak measured the gap it
		// never closed, and the barrel was dropped a few tics after every grab.
		// It read exactly like the reach volume missing, which is why it survived
		// so long -- and rs_grabpolicy calls the barrel "the single most
		// satisfying thing in Doom to pick up".
		//
		// THRUACTORS rather than clearing SOLID, for two reasons. PIT_CheckThing
		// tests `(thing->flags2 | tm.thing->flags2) & MF2_THRUACTORS`
		// (p_map.cpp:1444) -- an OR, so one flag on the object excuses the pair
		// in BOTH directions, and you can walk while carrying it as well as carry
		// it while walking. And SOLID is load-bearing for everything else about
		// the object: what shoots it, what it blocks, what a corpse pile looks
		// like. Borrowing the smaller flag is the smaller lie, and it is put back
		// exactly, the same way the other two are.
		a.bTHRUACTORS = true;

		// CARRIED THIN, WHICH IS WHY ARMOUR KEPT CATCHING ON THINGS.
		//
		// CarryOne moves a held thing with TryMove at its FULL collision radius,
		// and a pickup's radius is its floor footprint, not the size of the thing
		// in your fist: armour is 20, a medikit 20. So armour held at the palm was
		// refused by any wall, doorframe or ledge within 20 units of your hand --
		// the drawn sprite stayed behind, snagged, while the hand went on. A
		// radius of HELD_RADIUS still stops at walls (it cannot be posted through
		// geometry), it just no longer fills a doorway. Put back exactly on
		// release, like every other flag borrowed here.
		hSavedRadius[hand] = a.Radius;
		if (a.Radius > HELD_RADIUS) a.A_SetSize(HELD_RADIUS, -1);

		a.Vel = (0, 0, 0);
	}

	const HELD_RADIUS = 2.0;

	private void MoveFlagsTo(int to, int from)
	{
		if (!hOwnsFlags[from]) return;      // nothing to hand over
		hOwnsFlags[to]         = true;
		hSavedSpecial[to]      = hSavedSpecial[from];
		hSavedNoGravity[to]    = hSavedNoGravity[from];
		hSavedThruActors[to]   = hSavedThruActors[from];
		hSavedRollSprite[to]   = hSavedRollSprite[from];
		hSavedRollCentre[to]   = hSavedRollCentre[from];
		hSavedInterpAng[to]    = hSavedInterpAng[from];
		hSavedRoll[to]         = hSavedRoll[from];
		hSavedPitch[to]        = hSavedPitch[from];
		hSavedAngle[to]        = hSavedAngle[from];
		hSavedVoxel[to]        = hSavedVoxel[from];
		hFollowScaled[to]      = hFollowScaled[from];
		hSavedRadius[to]       = hSavedRadius[from];
		hSavedRadius[from]     = 0;
		hOwnsFlags[from]       = false;
	}

	private void RestoreFlags(int hand, Actor a)
	{
		// Refusing to guess. A slot that never took the backup has nothing to put
		// back, and writing its zeroed defaults onto the object would strip
		// SPECIAL off a pickup that arrived with it -- the exact silent
		// unpickable-forever failure the ownership flag is here to prevent.
		if (!hOwnsFlags[hand]) return;

		// STOP DRAWING IT IN A CONTROLLER'S FRAME. Without this a dropped object
		// follows your hand around the level while its real body lies on the
		// floor -- and the flag survives a savegame, so it would outlast the
		// session that set it.
		a.FollowHandMode = 0;
		a.FollowHandOfs  = (0, 0, 0);

		// BACK TO THE SIZE IT WAS. Restored from what was saved rather than
		// multiplied back, so a dropped object is bit-for-bit the size it was
		// picked up at however many times it has changed hands.
		if (hFollowScaled[hand] && hSavedScale[hand].x > 0) a.Scale = hSavedScale[hand];
		hFollowScaled[hand] = false;

		a.bSPECIAL    = hSavedSpecial[hand];
		a.bNOGRAVITY  = hSavedNoGravity[hand];
		a.bTHRUACTORS = hSavedThruActors[hand];

		// Roll included, and the roll VALUE as well as the three flags. Without
		// it a barrel set down after being turned over stays cocked at whatever
		// angle your wrist happened to be at, forever -- the same failure
		// RS_Pull.RestoreTumble exists to prevent for a caught object.
		a.bROLLSPRITE        = hSavedRollSprite[hand];
		a.bROLLCENTER        = hSavedRollCentre[hand];
		a.bINTERPOLATEANGLES = hSavedInterpAng[hand];
		a.Roll               = hSavedRoll[hand];

		// Pitch and Angle with it. Angle especially: it is the one of the three
		// that other code reads. Put a turned barrel down and it should sit the
		// way it sat, not aimed wherever your wrist finished.
		a.Pitch              = hSavedPitch[hand];
		a.Angle              = hSavedAngle[hand];

		// Back to whatever it was, which is not always false: a player running
		// r_drawvoxels globally may have picked up something that was already
		// a voxel, and putting it down must not take that away.
		a.VoxelOverride      = hSavedVoxel[hand];

		// Its own footprint back -- see SaveFlags.
		if (hSavedRadius[hand] > 0 && a.Radius != hSavedRadius[hand])
			a.A_SetSize(hSavedRadius[hand], -1);
		hSavedRadius[hand] = 0;

		a.Vel = (0, 0, 0);
	}

	// ---- carrying --------------------------------------------------------

	// TRYMOVE AND NOT SETORIGIN, and this is the single line that makes 35Hz the
	// right rate rather than a compromise. TryMove is Doom's own movement: it
	// runs the blockmap, the line checks and the step logic, so a carried object
	// STOPS AT WALLS and rides up stairs. SetOrigin would post it straight
	// through geometry, and getting that back was the entire goal of the
	// abandoned "wire the solver to the renderer" work.
	//
	// Z first, then XY. TryMove tests the position at the actor's CURRENT height,
	// so moving XY before Z tests a height the object is about to leave.
	private void CarryOne(PlayerPawn pmo, PlayerInfo p, int hand, Actor a)
	{
		// PALM, NOT CENTRE, AND THE DIFFERENCE IS AN ORBIT.
		//
		// This read RS_Reach.Centre, which is the palm PUSHED OUT by the reach
		// oval's own placement offsets -- rs_grab_m_ofs_x/y/z. Those offsets
		// exist to place the VOLUME you reach with, and they are applied in the
		// wrist's own axes (RS_Basis.Side/Fwd/Up), so they turn with the wrist.
		//
		// A held object sitting at that point therefore sat a few units off the
		// hand and SWEPT AROUND IT as the wrist rolled -- reported as clips
		// floating and orbiting the hand. The further the reach oval is dialled
		// from the palm, the wider the orbit, which is why it reads as random.
		//
		// Palm is the HANDPALM_joint bone: the hand model's own origin, and the
		// point a thing being held actually occupies. RS_Reach split the two
		// functions apart for exactly this reason and its own header says which
		// is which.
		Vector3 palm = RS_Reach.Palm(pmo, p, hand);

		// A Doom actor's origin is the FLOOR of its volume, not its centre, so an
		// object placed at the palm hangs with its middle a half-height above it.
		palm.z -= a.Height * 0.5;

		// SetZ DOES NOT COLLIDE -- it is a write, not a move. TryMove below
		// guards the horizontal, so a hand pushed at a wall leaves the object
		// against it, but raising your hand under a low ceiling would post the
		// object straight into the ceiling with nothing to stop it. Clamped
		// against the floor and ceiling the object is standing under, which is
		// this tic's XY: near enough, and it re-clamps every tic as it travels.
		double lo = a.floorz;
		double hi = a.ceilingz - a.Height;
		if (hi < lo) hi = lo;
		palm.z = clamp(palm.z, lo, hi);

		a.Vel = (0, 0, 0);
		a.SetZ(palm.z);
		a.TryMove((palm.x, palm.y), 1);

		// ---- AND DRAW IT LOCKED TO THE HAND -----------------------------
		//
		// TryMove above is the PLAYSIM half and it stays: it is what makes a
		// carried thing stop at walls and ride up stairs, and it is what
		// ShouldBreak measures. But it runs at 35Hz, and the headset does not.
		//
		// So a held object lagged the hand by two or three frames and SWAM
		// around it -- and a script-set position carries no orientation at all
		// beyond the roll written below, so it also pitched and rolled on its
		// own. Reported as "it orbits my hand and rotates wildly", and it is not
		// a tuning problem: 35Hz is simply not the rate a thing in your fist has
		// to move at.
		//
		// FollowHandMode is the engine field that exists for this. It puts the
		// actor in a controller's frame and resolves the transform at DRAW rate,
		// which is the same wire the hand on a moving slide already rides.
		//
		// BOTH HALVES, DELIBERATELY. The playsim position stays true -- so the
		// object still collides, still stops at walls, still gets culled
		// correctly, and ShouldBreak still notices when it is snagged and lets
		// go. What changes is only where it is DRAWN. When the two diverge the
		// hold is about to break anyway, which is exactly when you want to see
		// the object in your hand rather than stuck in the wall behind you.
		//
		// Mode 1 is the main hand's frame, 2 the off hand's.
		// ONLY FOR SOMETHING SOLID. A controller's frame is a MODEL feature: a
		// sprite ignores FollowHandMode and is drawn where the actor stands. So a
		// held thing is drawn in the hand only when it is a model -- its own
		// MODELDEF, or a voxel when voxels are on and a pack has one for it. A
		// voxel pack is optional; without one a caught barrel is a sprite, and it
		// is carried at the palm by the TryMove above, which is exactly where it
		// should be drawn.
		bool solidInHand = a.HasModelFrame() || (VoxelHeld(p) && a.HasVoxelFrame());
		if (Flag("rs_hold_followhand", p, true) && solidInHand)
		{
			a.FollowHandMode = (hand == HAND_MAIN) ? 1 : 2;
			a.FollowHandOfs  = (0, 0, 0);

			// ---- AND ITS SIZE HAS TO SURVIVE THE MOVE -------------------
			//
			// THE TWO PATHS MEASURE IN DIFFERENT UNITS, and picking something up
			// moves it from one to the other.
			//
			// On the ordinary world path one model unit is one map unit. On the
			// follow-hand path the renderer applies a 0.01 conversion, because
			// that frame carries vr_vunits_per_meter and everything in it is
			// expressed in metres. A MODELDEF scale authored for a thing lying
			// on the floor is therefore a HUNDRED TIMES too small the instant a
			// hand closes on it -- and the object visibly shrinks in your grip.
			//
			// Reported as "when I gravity grab a bullet or clip from the ground
			// the scale is off". It is not the object's scale that is wrong; it
			// is that nothing converted between the two frames.
			//
			// Compensated here rather than by asking every mod to author two
			// scales: an object does not know it is about to be picked up, and
			// a convention that every grabbable must carry a second number is a
			// convention most things will get wrong.
			//
			// The factor is the renderer's own, named rather than spelled 100 --
			// see the followHandUnitScale in models.cpp. If that ever changes,
			// these two must change with it.
			//
			// ONCE PER TAKE. This block runs every tic, and it used to scale every
			// tic: a hundredfold, then ten thousand, then a million -- and saved each
			// grown size as the one to restore, so a caught object vanished into its
			// own size and stayed enormous after it was put down.
			if (!hFollowScaled[hand])
			{
				hSavedScale[hand] = a.Scale;
				a.Scale = (a.Scale.x / FOLLOWHAND_UNIT_SCALE, a.Scale.y / FOLLOWHAND_UNIT_SCALE);
				hFollowScaled[hand] = true;
			}
			// NO PlacementPrefix. There is one held-object seat for every class
			// of thing a hand can close on -- barrels, medikits, keys, corpses
			// -- and one set of sliders could not describe them all. A mod that
			// wants its own object placed exactly says so by setting the prefix
			// on that actor itself; this leaves it alone rather than imposing a
			// shared one.
		}
		else if (hFollowScaled[hand] || a.FollowHandMode != 0)
		{
			// BACK TO THE PALM. Not solid (the pack was unloaded, voxels were
			// switched off mid-hold) or follow-hand turned off: stop drawing it in a
			// frame a sprite does not use, and give back the size it had.
			a.FollowHandMode = 0;
			a.FollowHandOfs  = (0, 0, 0);
			if (hFollowScaled[hand])
			{
				if (hSavedScale[hand].x > 0) a.Scale = hSavedScale[hand];
				hFollowScaled[hand] = false;
			}
		}

		// ---- orientation ------------------------------------------------
		//
		// This used to be a comment saying orientation could not be done until
		// meshes arrived, because a sprite always turns to face you and so has
		// no facing to set. That was true of YAW and only of yaw. ROLL is
		// visible on a billboard, and RS_Pull has been proving it for as long
		// as distance grab has existed -- +ROLLSPRITE, +ROLLCENTER and
		// +INTERPOLATEANGLES together make a flat sprite read as a solid thing
		// turning over. It just needs a roll written every tic, and a hand has
		// a much better number for that than a ballistic arc does.
		//
		// So: a held barrel now tips with your wrist. Turn your hand over and
		// it turns over.
		//
		// ONE HAND'S ROLL, THE OWNER'S. A two-handed carry has two wrists and
		// they disagree; picking the flag-owning hand means the object follows
		// whichever hand is actually carrying it, and keeps following the same
		// one when the other lets go (MoveFlagsTo hands ownership over).
		//
		// The switch is read every tic rather than latched, so turning it off
		// in the menu restores the borrowed flags immediately instead of at the
		// next release.
		if (!hOwnsFlags[hand]) return;

		// A VOXEL FOR AS LONG AS IT IS HELD, if one exists for this thing.
		//
		// Free when it does not: the engine falls straight through to the
		// ordinary model/sprite path when the actor's current frame has no
		// voxel, so this costs a null check on everything else. Set every tic
		// alongside the toggle read, so switching voxels off in the menu puts
		// the object back on the next tic rather than at release.
		// Only where a voxel exists for this thing. A pack is optional, and setting
		// the override without one asks the renderer for nothing, every tic.
		a.VoxelOverride = VoxelHeld(p) && a.HasVoxelFrame();

		if (RotateHeld(p))
		{
			a.bROLLSPRITE        = true;
			a.bROLLCENTER        = true;
			a.bINTERPOLATEANGLES = true;

			// MainHandRoll/OffhandRoll, NOT AttackRoll. The playsim zeroes
			// AttackRoll every tic inside P_PlayerThink, before any WorldTick
			// hook runs, so reading it here would return a constant zero and
			// nothing would ever turn. Same side-channel RS_HardPoints and
			// wr_gunhud already read for the same reason.
			//
			// NEGATED. Confirmed in headset 2026-08-28: turning the wrist one
			// way rolled the barrel the other. A sprite's roll and a
			// controller's roll are measured about axes that point opposite
			// ways -- the same class of mismatch as AttackPitch being stored
			// pre-negated, and the same fix. Reported on a barrel because a
			// barrel has an obvious upright; it was wrong for everything
			// held, since this is the one line that sets it.
			//
			// Written raw, not smoothed: +INTERPOLATEANGLES hands it to the
			// renderer's own deltaangle lerp, which takes the short way round
			// the 0/360 wrap. A second smoother here could only ever disagree
			// with it. Safe to write in WorldTick because p_tick.cpp takes each
			// actor's PrevAngles snapshot BEFORE the hook runs, so last tic's
			// roll is still intact when this overwrites it.
			a.Roll = -((hand == HAND_MAIN) ? pmo.MainHandRoll : pmo.OffhandRoll);

			// ALL THREE AXES ONCE IT IS SOLID.
			//
			// Gated on VoxelOverride and not on the toggle, because that is
			// exactly the condition under which the other two become visible.
			// A billboard has no observable yaw and the renderer reads no
			// sprite pitch, so writing either on a sprite would cost a tic of
			// work to change nothing -- and writing Angle in particular is not
			// free of consequence, since other code reads an actor's facing.
			//
			// Pitch comes from RS_Reach.HandPitch rather than a second negation
			// written out here. AttackPitch and OffhandPitch are both stored
			// pre-negated by the VR backends, that function is where the tree
			// already undoes it, and a private copy of the sign would be one
			// more place to disagree with the ray that tested the grab.
			//
			// Yaw is taken raw. AttackAngle and OffhandAngle are absolute world
			// yaws in the same convention Actor.Angle uses, so unlike the other
			// two there is no sign to undo -- turning the wrist left turns the
			// barrel left.
			if (a.VoxelOverride)
			{
				// NEGATED, confirmed in a headset 2026-08-30: tilting the hand
				// toward you tipped the barrel away and the other way round.
				//
				// HandPitch is TRUE-SIGNED -- positive is tipping up -- because
				// that is what a direction ray needs, and it exists precisely so
				// the ray and the tested volume cannot disagree about the sign.
				// Actor.Pitch is the opposite convention: positive means looking
				// DOWN, the same as the player's own pitch. The renderer says so
				// too, applying pitch POSITIVE while it negates both yaw and roll
				// (models.cpp, the actor rotation block).
				//
				// So the negation belongs here, at the point where a ray-space
				// number is written into an actor field, and NOT inside HandPitch
				// -- that would flip every grab ray in the package to fix one
				// barrel.
				a.Pitch = -RS_Reach.HandPitch(pmo, hand);
				// +90: the engine stores AttackAngle/OffhandAngle 90 degrees off
				// actor-yaw convention and every consumer adds it back (p_map.cpp
				// aimAngle, rs_grab.zs, rr_point.zs). Raw, the carried prop faced
				// a quarter turn off the wrist for the whole hold.
				a.Angle = ((hand == HAND_MAIN) ? pmo.AttackAngle : pmo.OffhandAngle) + 90.0;
			}

			// WHAT THIS PATH ACTUALLY WROTE.
			//
			// The engine-side [RSVOX] trace reports the angles it finds on the
			// actor, which is the OUTCOME. When those came back as exact zeroes
			// on a tracked wrist there was no way to tell from outside whether
			// this block had run and written zero, or never run at all -- the
			// carry could equally have been a distance-grab flight, where
			// RS_Pull owns the actor and nothing here executes.
			//
			// One line a second per hand, so the two traces can be read against
			// each other: if this prints and [RSVOX] still shows zeroes, the
			// write is being overwritten downstream.
			if (Flag("rs_hand_trace", p, true) && (level.time % 35) == 0)
			{
				// WEAPON STATE ALONGSIDE THE CARRY.
				//
				// "Firing while gripping a held object starts an endless firing
				// cycle", reported 2026-08-29. Nothing in this mod presses the
				// attack button or sets a weapon state, so the loop is being
				// driven by something the carry does to the weapon slots rather
				// than by input -- and refire climbing, or PendingWeapon never
				// clearing, would each produce exactly this symptom by a
				// different route. Printed together so one run tells them apart.
				String wn = "none";
				if (p.ReadyWeapon) wn = p.ReadyWeapon.GetClassName();
				String on = "none";
				if (p.OffhandWeapon) on = p.OffhandWeapon.GetClassName();
				String pn = "-";
				if (p.PendingWeapon && p.PendingWeapon != WP_NOCHANGE) pn = p.PendingWeapon.GetClassName();

				// THE CONTROLLER NEXT TO THE ACTOR, which is the whole point.
				//
				// Three sign errors were found in this block on 2026-08-29/30 --
				// roll, then the body-axis wrap, then pitch -- and every one of
				// them cost a headset run to find, because the trace printed
				// what was WRITTEN and the engine trace printed what was READ,
				// and neither printed what the HAND WAS DOING. A sign error is
				// invisible in either half alone and obvious across the pair.
				//
				// hand* are the raw controller numbers, true-signed the way the
				// rest of the package reads them. actor* are what this block
				// wrote. If the hand tips one way and the actor number moves the
				// other, that is the bug, on one line, with nobody in a headset.
				double hYaw = (hand == HAND_MAIN) ? pmo.AttackAngle  : pmo.OffhandAngle;
				double hPit = RS_Reach.HandPitch(pmo, hand);
				double hRol = (hand == HAND_MAIN) ? pmo.MainHandRoll : pmo.OffhandRoll;

				Console.Printf("[RSHOLD] hand %d carrying %s  vox=%d  | hand yaw=%.1f pitch=%.1f roll=%.1f  -> actor yaw=%.1f pitch=%.1f roll=%.1f  | ready=%s off=%s pending=%s refire=%d attackdown=%d",
					hand, a.GetClassName(), a.VoxelOverride ? 1 : 0,
					hYaw, hPit, hRol,
					a.Angle, a.Pitch, a.Roll,
					wn, on, pn, p.refire, p.attackdown ? 1 : 0);
			}
		}
		else
		{
			// Switched off mid-hold. Put back exactly what was borrowed --
			// these flags are not inert at roll zero (ROLLSPRITE rescales,
			// ROLLCENTER drops the sprite's offsets), so leaving them set would
			// keep drawing a held object differently from a dropped one.
			a.bROLLSPRITE        = hSavedRollSprite[hand];
			a.bROLLCENTER        = hSavedRollCentre[hand];
			a.bINTERPOLATEANGLES = hSavedInterpAng[hand];
			a.Roll               = hSavedRoll[hand];
			a.Pitch              = hSavedPitch[hand];
			a.Angle              = hSavedAngle[hand];
		}
	}

	// LET GO OF WHAT WE CANNOT ACTUALLY CARRY.
	//
	// TryMove refuses when the object cannot fit, so a hand pushed into a wall
	// leaves the object behind while the hand keeps going. Without a break the
	// object stays "held" from the far side of the geometry and gets dragged
	// through the level the moment a gap appears. The distance is the same
	// number in the menu, so a break that fires too eagerly is tunable rather
	// than a rebuild.
	private bool ShouldBreak(PlayerPawn pmo, PlayerInfo p, int hand, Actor a)
	{
		double brk = Num("rs_hold_break", p, 40.0);
		if (brk <= 0) return false;
		// THE SAME POINT THE CARRY AIMS AT. Measuring the gap from the reach
		// oval's centre while the object is carried to the palm makes the two
		// disagree by however far those sliders are dialled -- so a hold could
		// read as strained, buzz, and break while the object was sitting exactly
		// where it was put.
		Vector3 palm = RS_Reach.Palm(pmo, p, hand);
		Vector3 mid  = (a.Pos.x, a.Pos.y, a.Pos.z + a.Height * 0.5);
		double gap = (mid - palm).Length();

		// THE GAP IS A FEELING, NOT JUST A THRESHOLD.
		//
		// This number was already being computed every tic and read exactly
		// once, as a yes/no. But it is a measurement of how far the object is
		// LAGGING BEHIND the palm that is asking for it -- which is precisely
		// what "this is heavy" and "this is snagged on something" feel like.
		// TryMove refuses when the object cannot fit, so dragging a barrel
		// around a corner or lifting something into a ceiling opens that gap
		// long before the hold actually breaks. Reading it continuously instead
		// of only at the limit costs one call and turns a silent failure into a
		// warning you can feel.
		//
		// SCALED BY SIZE, using the collision cylinder every other hand
		// mechanism already reads, so a corpse drags limp and a barrel fights
		// you. Radius*Height rather than mass because Doom actors have no mass
		// -- and the barrel is 16x32 while a medikit is 20x16, which is close
		// enough to right that inventing a mass table would be a worse answer
		// than the number already on the actor.
		//
		// NORMALISED AGAINST THE BREAK DISTANCE so it reaches full strength
		// exactly as the hold is about to fail, whatever that distance is tuned
		// to. Nothing is felt while the object is tracking properly.
		double buzz = Num("rs_hold_haptic", p, 0.6);
		if (buzz > 0)
		{
			double strain = gap / brk;
			if (strain > 0.15)
			{
				// Cheap size proxy, capped: a big prop should feel heavier than
				// a small one, but a mod's oversized actor must not be able to
				// ask for an intensity the runtime never expected.
				double bulk = clamp((a.Radius * a.Height) / 512.0, 0.5, 2.0);
				double amp  = clamp(strain * buzz * bulk, 0.0, 1.0);

				// Short and re-issued every tic rather than one long buzz: the
				// strain changes continuously and a long pulse would describe
				// the gap as it was when it started, not as it is.
				level.VRHaptic(hand, amp, 20.0);
			}
		}

		return gap > brk;
	}

	// ---- the tic ---------------------------------------------------------

	override void WorldTick()
	{
		let p = players[consoleplayer];
		if (!p || !p.mo) { return; }
		let pmo = p.mo;

		// WATCH THE MAIN HAND'S WEAPON SLOT GO EMPTY.
		//
		// A run on 2026-08-29 showed ready=none for 14 of 34 carry samples --
		// the main hand's ReadyWeapon sitting null while something was held. A
		// null ready weapon is the state the engine reacts to by trying to bring
		// SOMETHING up, so it is a live candidate for all three of the endless
		// firing cycle, the momentary stop when a weapon is passed to the main
		// hand, and whatever else reads that slot.
		//
		// Sampling once a second could only ever say it HAPPENED. This catches
		// the tic it happens on and prints what else was true right then, which
		// is what actually names the cause. Prints on the EDGE only, so a hand
		// that is legitimately empty for a while costs one line, not one a tic.
		if (Flag("rs_hand_trace", p, true))
		{
			bool nowNull = (p.ReadyWeapon == null);
			if (nowNull != wasReadyNull)
			{
				wasReadyNull = nowNull;
				String on = "none";
				if (p.OffhandWeapon) on = p.OffhandWeapon.GetClassName();
				String pn = "-";
				if (p.PendingWeapon && p.PendingWeapon != WP_NOCHANGE) pn = p.PendingWeapon.GetClassName();

				// ASSIGNED, NOT TERNARIED -- GetClassName returns a Name and
				// "NULL"/"-" are Strings, and ?: will not mix the two. An
				// assignment coerces Name to String fine; a ternary has to
				// settle on one type before the assignment happens. This file
				// already carries this warning once, in the [RSGRIP] print, and
				// it was made again anyway.
				String rn = "NULL";
				if (!nowNull) rn = p.ReadyWeapon.GetClassName();
				String h0 = "-";
				if (hActor[0]) h0 = hActor[0].GetClassName();
				String h1 = "-";
				if (hActor[1]) h1 = hActor[1].GetClassName();

				Console.Printf("[RSWEAP] tic %d: ReadyWeapon -> %s  | off=%s pending=%s  mainHolds=%s offHolds=%s  refire=%d attackdown=%d",
					level.time, rn, on, pn, h0, h1,
					p.refire, p.attackdown ? 1 : 0);
			}
		}

		// BEFORE the death return below, not after: a hand emptied by dying
		// still wants its lease released, and that path exits early.
		ArbiterFind();

		// An actor pointer nulls itself when the actor is destroyed, so a crushed
		// or consumed object empties its slot on its own. The role and the flag
		// backup do not, and a stale role is what decides the NEXT hold, so
		// reconcile before anything reads the table.
		for (int h = 0; h < 2; h++)
		{
			if (!hActor[h] && hRole[h] != ROLE_NONE) ClearSlot(h);
			// A pickup can KEEP the world actor: Inventory.CreateCopy returns
			// self when GoAway() is false, so a face-use of, say, a Cell you
			// own no gun for turns the thing in your hand into an owned,
			// invisible inventory item. Still pointed at from here, it would
			// be TryMove'd every tic, keep the hand full, and take throw
			// velocity and restored flags on release. Forget it instead.
			let owned = Inventory(hActor[h]);
			if (owned && owned.Owner) ClearSlot(h);
		}

		// Dead hands hold nothing. ClearClaims after ReleaseAll, never instead
		// of it: ReleaseAll empties the slots, and this is what withdraws what
		// those slots had published.
		if (pmo.Health <= 0) { ReleaseAll(); ClearClaims(pmo); return; }

		// Switching grabbing off mid-hold has to LET GO, not stop carrying.
		// The input handler is gated on the same cvar, so a hold left standing
		// here would have nothing left able to release it -- and the switch is a
		// menu entry, which is the one place a player can reach from inside a
		// headset. Stranding an object behind the off position of its own toggle
		// is not a state anything can get out of.
		if (!Flag("rs_grab", p, true)) { ReleaseAll(); ClearClaims(pmo); return; }

		// CARRY FIRST, THEN TEST THE BREAK, in two passes and not one.
		//
		// The break asks whether the carry actually landed, so it has to run
		// after the carry or it is measuring last tic. Testing first also breaks
		// a hold the instant it is made: on the tic you grab something it is
		// still lying where it was, up to its own radius from your palm, and it
		// has not been moved yet.
		//
		// Two passes rather than one loop because with two hands on one object
		// only the primary moves it, and the primary is whichever hand got there
		// first -- so in a single loop the support hand's break test can run
		// before the primary has moved anything.
		for (int h = 0; h < 2; h++)
		{
			// Only the PRIMARY hand moves it. Two hands both writing a position
			// every tic is two solvers fighting, and the object ends up sitting
			// at whichever one ran last.
			if (hActor[h] && hRole[h] == ROLE_PRIMARY)
				CarryOne(pmo, p, h, hActor[h]);
		}

		for (int h = 0; h < 2; h++)
		{
			Actor a = hActor[h];
			if (!a) continue;

			// For a SUPPORT hand this measures the gap between your two hands,
			// because the object sits at the primary palm -- so pulling your
			// hands apart takes the second one off it, which is what pulling
			// your hands apart means.
			if (ShouldBreak(pmo, p, h, a))
			{
				if (Flag("rs_hand_debug", p, true))
					Console.Printf("[RSHELD] hand %d lost %s -- too far from the palm",
						h, a.GetClassName());
				Release(h);
				continue;
			}

			// Tell the engine's grip arbiter this hand is closed on a thing.
			// That is what turns the context into GRIPCTX_Object, which stands
			// two-hand stabilize down -- without it, holding something in each
			// hand and bringing them together reads as bracing a weapon.
			//
			// The convention (actor.zs) is SET while holding, and clear only a
			// value that is ours. Release does the clearing.
			// ASK FIRST, WRITE ON A GRANT. Writing the engine field and then
			// asking meant a denied claim (the hand is carrying a reload
			// magazine, or is inside the pouch's claim) had already clobbered
			// the field -- and ClearClaims, which only clears what grip.mine
			// says is ours, then left it clobbered after the release.
			bool granted = !arbiter
				|| arbiter.GetInt("grip.claim", "", h, hSubject[h], pmo, 'RS_Held') == 1;
			if (granted)
			{
				if (h == HAND_MAIN) pmo.GripClaimMain = hSubject[h];
				else                pmo.GripClaimOff  = hSubject[h];
				hClaimed[h] = hSubject[h];
			}

			// Doubles as a renewal -- this runs every tic while holding, which
			// is exactly what keeps the lease alive.

			// And tell the hand model what shape to be, when the world hands are
			// the ones on screen. One tic behind, because the pose handler is
			// registered ahead of this one -- invisible on a finger blend.
			let hd = RS_HandWorldHandler.Get(h);
			if (hd) hd.HoldPose(hPose[h]);
		}

		ClearClaims(pmo);
	}

	// TAKE BACK WHAT WE PUBLISHED FOR A HAND THAT IS NOW EMPTY.
	//
	// Its own function because the tic has three exits and this used to sit at
	// the bottom of only one of them. Die, or switch grabbing off in the menu
	// mid-hold, and ReleaseAll emptied the slots and returned -- past this --
	// leaving GripClaim* standing at the subject of an object nobody was holding
	// any more. Nothing else can clear it: the convention is that only the writer
	// clears its own value, and the writer had just returned. The engine went on
	// reading the hand as closed on a thing for the rest of the level, with
	// two-hand stabilize stood down and the pose latched to whatever was last
	// held.
	//
	// IDEMPOTENT, which is what makes calling it from every exit safe. A hand
	// with nothing published (hClaimed == None) is skipped, so the extra calls on
	// the ordinary path cost two compares.
	//
	// The pose reset rides along for the same reason: a hand that is no longer
	// holding anything must stop being told to hold something, and it fails the
	// same way -- fingers frozen round an object that is gone.
	private void ClearClaims(PlayerPawn pmo)
	{
		if (!pmo) return;

		// Clear the claim for an empty hand, but only if the value standing there
		// is one we put there. More than one mod writes these.
		for (int h = 0; h < 2; h++)
		{
			if (hActor[h]) continue;
			if (hClaimed[h] == GRIPSUBJ_None) continue;

			// ASK, DON'T INFER. The value compare below is what this family's
			// whole claim-collision bug is made of: rs_grabpolicy assigns
			// GRIPSUBJ_Magazine to every Ammo/Health/Armor/Inventory/barrel
			// grab and RR_Reload returns the same value as its own default, so
			// "the int still holds what I wrote" never distinguished our claim
			// from theirs. Kept as the answer when no arbiter is loaded --
			// unchanged behaviour, not a new risk.
			bool ours;
			if (arbiter)
				ours = arbiter.GetInt("grip.mine", "", h, 0, pmo, 'RS_Held') == 1;
			else
				ours = ((h == HAND_MAIN) ? pmo.GripClaimMain : pmo.GripClaimOff) == hClaimed[h];

			if (ours)
			{
				if (h == HAND_MAIN) pmo.GripClaimMain = GRIPSUBJ_None;
				else                pmo.GripClaimOff  = GRIPSUBJ_None;
			}

			// Outside the test on purpose: releasing a slot this package does
			// not hold is a no-op, so it is always safe, and it means a hand
			// emptied by death or by switching grab off mid-hold cannot leave a
			// lease standing for the rest of the level.
			if (arbiter)
				arbiter.GetInt("grip.release", "", h, 0, pmo, 'RS_Held');

			hClaimed[h] = GRIPSUBJ_None;

			let hd = RS_HandWorldHandler.Get(h);
			if (hd && hd.poseHold >= 0) hd.HoldPose(-1);
		}
	}

	// RELEASE, not clear, and the difference is the whole bug class this file
	// exists to avoid.
	//
	// A level change makes a fresh handler with empty slots, so this does
	// nothing there. The case that matters is a SAVEGAME taken while holding
	// something: the handler serialises, and so does the object -- with the
	// flags this system changed, SPECIAL off and NOGRAVITY on, saved as if they
	// were its own. Wiping the slots on load throws away the only record of what
	// those flags used to be, and the item is left floating and unpickable for
	// the rest of the game with nothing to explain why. Releasing puts them
	// back first.
	//
	// The object drops at your feet rather than staying in your hand. Carrying a
	// hold across a save is the persistence item, and it needs the pouch and the
	// holsters solved with it.
	override void WorldLoaded(WorldEvent e)
	{
		ReleaseAll();
	}

	override void WorldUnloaded(WorldEvent e)
	{
		// ReleaseAll empties the slots; ClearClaims withdraws what the tic
		// loop PUBLISHED -- GripClaim* on the pawn and the arbiter lease.
		// The pawn travels to the next map, this handler does not, and the
		// engine never clears the field itself, so a hold across an exit
		// left that hand reading as closed on an object for the whole of
		// the following map.
		ReleaseAll();
		let p = players[consoleplayer];
		if (p && p.mo) ClearClaims(p.mo);
	}
}
