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

// A PLAIN EventHandler, AND IT MUST STAY ONE. Do not make this static.
//
// A plain EventHandler's fields are SERIALIZED WITH THE LEVEL. A StaticEventHandler
// is marked OF_Transient (events.cpp:337): it persists across levels but its fields
// are NOT saved. Making this static sounds like an improvement and is a trap.
//
// hOwnsFlags and the four hSaved* arrays are the ONLY record that a held object was
// ever normal -- its gravity, its solidity, its scale. The object's flags are saved
// by the engine. If the backup that undoes them is not saved with them, a save taken
// while something is in your hand restores the modified object and loses the record
// of what it used to be: an object handed back permanently weightless and permanently
// unpickable, with nothing anywhere to say why.
//
// The general form is in Engine docs/CROSSPLATFORM_COOP_RULE.md: a mask and the state
// that clears it are serialized together or cleared together, never one without the
// other. This is that rule, and being a plain EventHandler is how it is kept.
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
	// ---- PER PLAYER, FLAT, ONE INDEX HELPER -------------------------------
	//
	// These were [2] -- indexed by HAND and nothing else -- so they described one
	// player's two hands: whichever machine they happened to run on. That is why a
	// network command could not be applied for anybody but yourself. Applying a
	// remote player's release cleared YOUR hand slot, because there was no other
	// slot to clear.
	//
	// Flat MAXPLAYERS*2 with IX(pnum, hand), rather than a two-dimensional array,
	// because one helper reads better than [pn][h] everywhere and cannot be
	// silently mis-indexed by transposing two subscripts.
	//
	// THE TWO-HANDED CASE IS STILL A COMPARISON, NOT A FLAG: hActor[IX(pn,0)] ==
	// hActor[IX(pn,1)] for THE SAME pn. Compare across players and it compiles, it
	// looks plausible, and two people holding the same barrel read as one person
	// holding it in both hands.
	// pnum * 2 + hand. Static so it can be used from anywhere that has a number.
	static int IX(int pnum, int hand) { return pnum * 2 + hand; }

	private Actor hActor[MAXPLAYERS * 2];
	private int   hRole[MAXPLAYERS * 2];
	private int   hSubject[MAXPLAYERS * 2];
	// The hand SHAPE, carried separately from the subject. The subject is what
	// the engine's arbiter is told; the pose is what the fingers do. See the
	// note on RS_GrabRule for why collapsing the two breaks a barrel.
	// PER PLAYER, and the comment that used to stand here was wrong in an
	// instructive way. It said: the pose is what THIS machine draws, this machine
	// draws one pair of hands, so it needs no player. The CONSUMER really is local
	// -- RS_HandWorldHandler is one pair of drawn hands and always will be. But the
	// WRITER stopped being local when WorldTick started looping players: Take()
	// writes a pose for whichever pnum the command names, so a remote player
	// closing their fist on a barrel rewrote the shape of the LOCAL player's hand.
	// A local consumer does not make the storage local. Index it by the player it
	// belongs to, and read only your own at the point of draw.
	private int   hPose[MAXPLAYERS * 2];

	// WHEN THIS HAND LAST SHARED ITS OBJECT WITH THE OTHER ONE, in maptime.
	//
	// A two-handed heave throws harder than a one-handed one, and by the time
	// the LAST hand lets go there is nothing left to see it by: the first
	// hand's release takes the early exit in Release, clears its own slot, and
	// the survivor then looks exactly like a hand that was alone all along. So
	// the moment the first hand comes off, it stamps the survivor, and the
	// final release reads the stamp.
	//
	// Indexed per player AND hand. Several fields further down are [2] and
	// predate WorldTick looping players -- see the note on hPose for what that
	// cost the last time. No reason for a new one to repeat it.
	private int   hTwoHandTic[MAXPLAYERS * 2];

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
	private bool hOwnsFlags[MAXPLAYERS * 2];
	// THE SCALE AN OBJECT HAD BEFORE A HAND CLOSED ON IT.
	//
	// Saved because putting it on the follow-hand path CHANGES ITS SIZE, and it
	// has to be given back exactly -- an object that comes back a little
	// different every time it is picked up and dropped is a slow leak nobody
	// can see happening.
	// [HANDUNITS 2026-10-02] REMOVED. This was the renderer's old conversion between the
	// world frame and a controller's, and its last user is gone -- see the note in the
	// follow-hand block below. The engine now divides vr_vunits_per_meter back out on the
	// hand path, so both frames are map units and there is no conversion to mirror.
	//
	// DELETED RATHER THAN SET TO 1, deliberately. A constant named for a conversion that no
	// longer happens is worse than no constant: the next person to need a hand-unit number
	// finds it, assumes it is current, and reintroduces the factor it used to apply.

	private Vector2 hSavedScale[MAXPLAYERS * 2];
	private bool hSavedSpecial[MAXPLAYERS * 2];
	private bool hSavedNoGravity[MAXPLAYERS * 2];
	// THE THIRD PAIR, and the barrel is why. See SaveFlags.
	private bool hSavedThruActors[MAXPLAYERS * 2];

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
	// PER PLAYER. This mirrors PlayerPawn.GripClaimMain/Off -- which is per PAWN --
	// so keeping one copy per HAND meant four players shared two ints. The failure
	// was not subtle: with player 1 holding a shotgun, player 1's tic leaves
	// hClaimed[MAIN] set; player 2's tic then finds their own hand empty, sees a
	// non-None claim standing, and goes to work on PLAYER 2's pawn -- releasing
	// their arbiter lease and zeroing their GripClaimMain -- then wipes the record
	// so player 1's real lease is never released at all.
	private int hClaimed[MAXPLAYERS * 2];

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

	// ---- thrown voxels: MOVED (2026-09-28) -----------------------------------
	//
	// The list that kept a thrown object drawn as its voxel until it landed now
	// lives in RS_Flight, as one flag on the entry every release already makes
	// (RS_Flight.FLIGHT_VOXEL). It was always the same list: "what is in the
	// air, and for how long". Keeping two of them meant two answers to when an
	// object had landed, and only one of them was ever asked.
	//
	// Release pushes the flag; SaveFlags takes the pre-throw value back through
	// RS_Flight.End when a hand catches something still in flight.

	static RS_Held Get()
	{
		return RS_Held(EventHandler.Find("RS_Held"));
	}

	Actor HeldBy(int pnum, int hand) const
	{
		if (hand != HAND_MAIN && hand != HAND_OFF) return null;
		return hActor[IX(pnum, hand)];
	}

	bool HandIsFull(int pnum, int hand) const
	{
		return HeldBy(pnum, hand) != null;
	}

	// HELD BY ANYBODY, which is the question every caller was actually asking.
	//
	// This took no player before and could only see the local one, so a barrel in a
	// remote player's hands read as free -- and the answer gates whether a grab or a
	// distance-pull may start. Now it means what it says. IsHeldBy(pnum, a) is below
	// for the rarer case where a caller means one specific player.
	bool IsHeld(Actor a) const
	{
		if (!a) return false;
		for (int i = 0; i < MAXPLAYERS; ++i)
			if (playeringame[i] && (hActor[IX(i, 0)] == a || hActor[IX(i, 1)] == a))
				return true;
		return false;
	}

	bool IsHeldBy(int pnum, Actor a) const
	{
		return a != null && (hActor[IX(pnum, 0)] == a || hActor[IX(pnum, 1)] == a);
	}

	// Bit 0 = main hand, bit 1 = off hand. 3 means both.
	int HandsOn(int pnum, Actor a) const
	{
		if (!a) return 0;
		int m = 0;
		if (hActor[IX(pnum, 0)] == a) m |= 1;
		if (hActor[IX(pnum, 1)] == a) m |= 2;
		return m;
	}

	bool TwoHanded(int pnum, Actor a) const
	{
		return HandsOn(pnum, a) == 3;
	}

	// -1 when nobody holds it.
	int PrimaryHand(int pnum, Actor a) const
	{
		if (!a) return -1;
		for (int h = 0; h < 2; h++)
			if (hActor[IX(pnum, h)] == a && hRole[IX(pnum, h)] == ROLE_PRIMARY) return h;
		return -1;
	}

	int SubjectIn(int pnum, int hand) const
	{
		if (hand != HAND_MAIN && hand != HAND_OFF) return GRIPSUBJ_None;
		return hSubject[IX(pnum, hand)];
	}

	// -1 when this hand is holding nothing, which is also "let the controllers
	// decide", so a caller can pass it straight through.
	int PoseIn(int pnum, int hand) const
	{
		if (hand != HAND_MAIN && hand != HAND_OFF) return -1;
		return hActor[IX(pnum, hand)] ? hPose[IX(pnum, hand)] : -1;
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

	// A SERVER cvar, read with no player. Anything that decides where a thrown
	// object ends up has to come out the same on every machine, so it must not
	// be reachable per player -- passing a PlayerInfo to a server cvar works
	// and hides the mistake. The default is repeated at every call site on
	// purpose: an undeclared cvar in ZScript is not an error, it is 0.0, and a
	// throw scale of zero is a game where nothing can be thrown at all.
	private static double ServerNum(String n, double d)
	{
		let c = CVar.GetCVar(n, null);
		return c ? c.GetFloat() : d;
	}

	// ---- taking and letting go -------------------------------------------

	// The one call that changes anything. Returns a TAKE_* telling the caller
	// what it got, which is never "nothing happened" by accident: a refusal is
	// TAKE_REFUSED and says so.
	// twohand comes from the grabbability table (RS_GrabRule), not from a size
	// guess made here. It was a size guess for exactly one commit: a medikit and
	// a barrel have nearly the same collision cylinder in Doom, so the cylinder
	// cannot answer this and the table has to.
	// CAN THIS HAND TAKE THAT, AND NOTHING ELSE.
	//
	// A TRUE PREDICATE: it reads, it decides, it changes nothing, and calling it
	// twice answers the same both times. That is the whole point -- a caller that
	// wants to ASK (may I show a grab prompt, may a distance-pull start, is this
	// worth sending a command for) had no way to ask without doing, so it either
	// guessed at the reasons or committed and hoped.
	//
	// EVERY REFUSAL LIVES HERE, AND THERE ARE FIVE. Take() is now this plus the
	// act, so the two cannot drift: there is no reason to refuse that this does
	// not know about, by construction rather than by discipline.
	//
	// WHY IT IS SAFE TO ASK ON ONE MACHINE AND ACT ON ANOTHER. Every input is the
	// same everywhere: the actor and the slots are playsim, and the two cvars are
	// read through players[pnum] -- the player the grab BELONGS to, never
	// consoleplayer. `user` cvars are CVAR_USERINFO and userinfo is networked
	// (c_cvars.cpp:254 fires UserInfoChanged on every change, the same path that
	// already carries name and colour), so CVar.GetCVar(n, players[pnum]) answers
	// identically on every machine. Reading a per-player toggle is not the hazard;
	// reading the LOCAL player's toggle on a path every machine runs is.
	bool CanTake(int pnum, int hand, Actor a, bool twohand, PlayerInfo p) const
	{
		if (!a) return false;
		if (hand != HAND_MAIN && hand != HAND_OFF) return false;

		// A full hand must let go first. Swapping in place is a real gesture but
		// it is a DECISION, and the decision belongs to whoever called this.
		if (hActor[IX(pnum, hand)]) return false;

		int other = 1 - hand;

		// SOMEBODY ELSE IS HOLDING IT. This test was NOT here, and Take had no
		// opinion on it at all: the callers each checked IsHeld first and the
		// check happened to be enough while IsHeld could only see the local
		// player. It stopped being enough twice over -- once when IsHeld learned
		// to see everybody, and once when the appliers started running a remote
		// player's take on this machine, where no caller-side check has run.
		// Without it, two players grabbing one barrel both come out ROLE_PRIMARY
		// and both CarryOne calls write its position every tic: the object sits
		// wherever the later loop iteration put it, differently on each machine.
		// That is the exact disagreement the command path exists to remove, so
		// the refusal belongs in the predicate every machine evaluates.
		if (IsHeld(a) && !IsHeldBy(pnum, a)) return false;

		// THE SECOND-GRAB CASE: your other hand already has it. Allowed only if
		// one of the two policies says so -- join it as support, or pass it hand
		// to hand. Neither, and the answer is no.
		if (hActor[IX(pnum, other)] == a)
			return (Flag("rs_hold_twohand", p, true) && twohand)
			    || Flag("rs_hold_pass", p, true);

		return true;      // free object, free hand
	}

	int Take(int pnum, int hand, Actor a, int subject, int pose, bool twohand, PlayerInfo p)
	{
		if (!CanTake(pnum, hand, a, twohand, p)) return TAKE_REFUSED;

		int other = 1 - hand;

		// THE SECOND-GRAB CASE, which is the whole reason this class exists.
		// CanTake has already said yes, so these branches pick WHICH act it is.
		// The conditions are repeated rather than remembered because a bool passed
		// down from the predicate is a second thing to keep in step; the reads are
		// two cvar lookups and they cannot disagree with what was just decided.
		if (hActor[IX(pnum, other)] == a)
		{
			if (Flag("rs_hold_twohand", p, true) && twohand)
			{
				// Join as support. The other hand keeps position and keeps the
				// flag backup -- it was primary and still is.
				hActor[IX(pnum, hand)]   = a;
				hRole[IX(pnum, hand)]    = ROLE_SUPPORT;
				hSubject[IX(pnum, hand)] = subject;
				hPose[IX(pnum, hand)] = pose;
				return TAKE_JOINED;
			}
			if (Flag("rs_hold_pass", p, true))
			{
				// Hand to hand. The flags move with the object, not with the
				// hand: MoveFlagsTo copies the backup across before the old slot
				// is wiped, so the object is never left owning nothing.
				MoveFlagsTo(pnum, hand, other);
				hActor[IX(pnum, hand)]   = a;
				hRole[IX(pnum, hand)]    = ROLE_PRIMARY;
				hSubject[IX(pnum, hand)] = subject;
				hPose[IX(pnum, hand)] = pose;
				ClearSlot(pnum, other);
				return TAKE_PASSED;
			}
			return TAKE_REFUSED;   // unreachable: CanTake refuses this above
		}

		// Free object.
		hActor[IX(pnum, hand)]   = a;
		hRole[IX(pnum, hand)]    = ROLE_PRIMARY;
		hSubject[IX(pnum, hand)] = subject;
		hPose[IX(pnum, hand)] = pose;
		SaveFlags(pnum, hand, a);
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
	// THE VELOCITY IS CARRIED, NOT RE-MEASURED.
	//
	// haveVel says the caller is an APPLIER running a command that already contains
	// the throw, measured once on the machine that has a controller. Re-deriving it
	// here would ask every machine to read a pose it does not have, which is the
	// whole defect this removes. Without it (death, level change, a teardown) the
	// old local path stands and the velocity is zero anyway.
	void Release(int pnum, int hand, PlayerPawn pmo = null, PlayerInfo p = null,
	             bool haveVel = false, Vector3 carriedVel = (0, 0, 0))
	{
		if (hand != HAND_MAIN && hand != HAND_OFF) return;
		Actor a = hActor[IX(pnum, hand)];
		if (!a) return;

		int other = 1 - hand;
		bool otherStillHas = (hActor[IX(pnum, other)] == a);

		if (otherStillHas)
		{
			// STAMP THE SURVIVOR. This is the only moment anything can tell
			// that the object was held in two hands -- a tic later the slot is
			// cleared and the remaining hand is indistinguishable from one that
			// never had help. See hTwoHandTic.
			hTwoHandTic[IX(pnum, other)] = level.maptime;

			// Promote the remaining hand. It inherits the flag backup, because
			// the object is still held and its flags must stay ours until the
			// LAST hand comes off it.
			if (hRole[IX(pnum, hand)] == ROLE_PRIMARY)
			{
				MoveFlagsTo(pnum, other, hand);
				hRole[IX(pnum, other)] = ROLE_PRIMARY;
			}
			ClearSlot(pnum, hand);
			return;
		}

		// THE VELOCITY IS SOLVED BEFORE THE FLAGS GO BACK, because clearing the
		// player is only possible while the object can still pass through them.
		//
		// WHAT ARRIVES IS THE HAND'S MOTION AND NOTHING ELSE (2026-09-28).
		// Mass, the server throw scale and the thrower's own velocity are all
		// knowable from the playsim, so they are spent HERE, on every machine,
		// rather than baked in by the one machine that had a controller. Only
		// the part that needs a controller travels. See rs_handnet.zs.
		Vector3 vhand;
		if (haveVel)            vhand = carriedVel;
		else if (pmo && p)      vhand = RS_Throw.HandVelocityFor(hand, pmo, p, a);
		else                    vhand = (0, 0, 0);

		// WEIGHT, AND WHY ONE NUMBER IS ENOUGH.
		//
		//     keep = armKg / (armKg + objectKg)
		//
		// A 0.15 kg baseball keeps 99% of the hand's speed, a 5 kg shield 86%,
		// a 60 kg barrel a third. Nothing needs a special case and nothing
		// needs a table: every object in the game gets a weight you can feel
		// through the throw, from the one mass lookup.
		//
		// TWO HANDS DOUBLE THE ARM rather than doubling the speed -- a barrel
		// goes from a third to a half, which is a heave, and a baseball goes
		// from 99% to 99.5%, which is nothing. That asymmetry is the point: a
		// second hand should matter enormously for the heavy thing and not at
		// all for the light one, and it falls out of the same formula.
		double objectKg = RS_Mass.Kg(a);
		double armKg    = ServerNum("rs_throw_arm_kg", 30.0);
		if (armKg <= 0) armKg = 30.0;
		bool twoHanded  = (level.maptime - hTwoHandTic[IX(pnum, hand)]) <= 10
		                  && hTwoHandTic[IX(pnum, hand)] > 0;
		if (twoHanded) armKg *= 2.0;

		double keep = armKg / (armKg + max(objectKg, 0.0));

		// THE PLAYER'S OWN MOTION GOES BACK IN HERE, ONCE. The hand is measured
		// relative to the player, so without this a barrel thrown while
		// sprinting falls short by exactly your running speed. Added after the
		// mass scaling, never before it: your body carrying the object is not
		// your arm throwing it, and weight does not slow down the bit that was
		// already moving with you.
		Vector3 v = vhand * keep * ServerNum("rs_throw_scale", 1.0);
		if (pmo) v += pmo.Vel;

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

		// A THROWN VOXEL STAYS A VOXEL IN FLIGHT. Read before RestoreFlags puts
		// the pre-grab value back and ClearSlot wipes the backup.
		bool drawnAsVoxel = a.VoxelOverride;
		RestoreFlags(pnum, hand, a);
		ClearSlot(pnum, hand);

		// INTO THE AIR -- AND EVERY RELEASE GOES, not every throw.
		//
		// This used to be gated on `v.Length() > 0`, so a throw got the flight
		// treatment and a gentle set-down got Doom's raw gravity. Two fall
		// rates for one object, and the player reporting it as a bug would have
		// been right: put a medikit down and it drops like a stone, lob the
		// same medikit and it floats. The drop/throw threshold decides which
		// VELOCITY an object leaves with (rs_throw_min, in RS_Throw) and it
		// does not get to decide how the thing falls. (Designer, 2026-09-28.)
		//
		// RS_Flight writes the velocity itself, corrects gravity every world
		// step, applies drag, and forgets the object once it lands. Nothing on
		// the actor is modified, so losing the list to a save or a level change
		// costs nothing but the correction.
		//
		// The voxel state rides along as a flag rather than a second list --
		// see RS_Flight.FLIGHT_VOXEL. `drawnAsVoxel` is local and depends on
		// whether a voxel pack is loaded on THIS machine, which is exactly the
		// kind of thing that must never reach the playsim; it reaches only the
		// render override, which is where it always went.
		// RestoreFlags has already put VoxelOverride back to its pre-grab value
		// by this line, so the flight saves the right thing to land with and
		// nothing here has to second-guess it. Do NOT reinstate voxelBeforeGrab
		// by hand: RestoreFlags refuses to act on a slot that never took a
		// backup, and writing the zeroed default over a real value is the
		// silent kind of wrong.
		int flightFlags = RS_Mass.Flags(a);
		if (drawnAsVoxel) flightFlags |= RS_Flight.FLIGHT_VOXEL;

		RS_Flight.Launch(a, v, objectKg, RS_Mass.Drag(a), flightFlags, pmo);

		// LAST, and only for the hand that actually let go of it. A two-handed
		// object released by one hand is still held by the other, and that path
		// returned above -- you cannot throw something you are still holding.
		if (pmo && p)
		{
			let sw = RS_Swing.Get();
			if (sw) sw.Forget(hand);
			RS_Telem.Line(String.Format(
				"throw hand=%d obj=%s kg=%.3f in_mps=%.2f out_mps=%.2f keep=%.2f two=%d scale=%.2f",
				hand, a.GetClassName(), objectKg,
				RS_Mass.UnitsPerTicToMetresPerSec(vhand.Length()),
				RS_Mass.UnitsPerTicToMetresPerSec(v.Length()),
				keep, twoHanded ? 1 : 0, ServerNum("rs_throw_scale", 1.0)));
		}

		// The stamp is spent. Left standing, a hand that once shared an object
		// would throw the NEXT one with a doubled arm for ten more tics.
		hTwoHandTic[IX(pnum, hand)] = 0;
	}

	void ReleaseAll(int pnum)
	{
		Release(pnum, HAND_MAIN);
		Release(pnum, HAND_OFF);
	}

	private void ClearSlot(int pnum, int hand)
	{
		hActor[IX(pnum, hand)]   = null;
		hRole[IX(pnum, hand)]    = ROLE_NONE;
		hSubject[IX(pnum, hand)] = GRIPSUBJ_None;
		hPose[IX(pnum, hand)] = -1;
		hOwnsFlags[IX(pnum, hand)]       = false;
		hSavedSpecial[IX(pnum, hand)]    = false;
		hSavedNoGravity[IX(pnum, hand)]  = false;
		hSavedThruActors[IX(pnum, hand)] = false;
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

	private void SaveFlags(int pnum, int hand, Actor a)
	{
		hOwnsFlags[IX(pnum, hand)]       = true;
		hSavedSpecial[IX(pnum, hand)]    = a.bSPECIAL;
		hSavedNoGravity[IX(pnum, hand)]  = a.bNOGRAVITY;
		hSavedThruActors[IX(pnum, hand)] = a.bTHRUACTORS;
		hSavedRollSprite[hand] = a.bROLLSPRITE;
		hSavedRollCentre[hand] = a.bROLLCENTER;
		hSavedInterpAng[hand]  = a.bINTERPOLATEANGLES;
		hSavedRoll[hand]       = a.Roll;
		hSavedPitch[hand]      = a.Pitch;
		hSavedAngle[hand]      = a.Angle;
		// GRABBING SOMETHING STILL IN THE AIR. End its flight FIRST and take
		// back the voxel value it had before it was ever thrown -- not the one
		// the flight imposed on it, or the object would come out of this hold
		// drawn as a voxel for good. RS_Flight.End does both in one call, and
		// it must happen before the line below records what we are saving.
		hSavedVoxel[hand]      = RS_Flight.End(a, a.VoxelOverride);
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

	private void MoveFlagsTo(int pnum, int to, int from)
	{
		if (!hOwnsFlags[IX(pnum, from)]) return;      // nothing to hand over
		hOwnsFlags[IX(pnum, to)]         = true;
		hSavedSpecial[IX(pnum, to)]      = hSavedSpecial[IX(pnum, from)];
		hSavedNoGravity[IX(pnum, to)]    = hSavedNoGravity[IX(pnum, from)];
		hSavedThruActors[IX(pnum, to)]   = hSavedThruActors[IX(pnum, from)];
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
		hOwnsFlags[IX(pnum, from)]       = false;
	}

	private void RestoreFlags(int pnum, int hand, Actor a)
	{
		// Refusing to guess. A slot that never took the backup has nothing to put
		// back, and writing its zeroed defaults onto the object would strip
		// SPECIAL off a pickup that arrived with it -- the exact silent
		// unpickable-forever failure the ownership flag is here to prevent.
		if (!hOwnsFlags[IX(pnum, hand)]) return;

		// STOP DRAWING IT IN A CONTROLLER'S FRAME. Without this a dropped object
		// follows your hand around the level while its real body lies on the
		// floor -- and the flag survives a savegame, so it would outlast the
		// session that set it.
		a.FollowHandMode = 0;
		a.FollowHandOfs  = (0, 0, 0);

		// BACK TO THE SIZE IT WAS. Restored from what was saved rather than
		// multiplied back, so a dropped object is bit-for-bit the size it was
		// picked up at however many times it has changed hands.
		if (hFollowScaled[hand] && hSavedScale[IX(pnum, hand)].x > 0) a.Scale = hSavedScale[IX(pnum, hand)];
		hFollowScaled[hand] = false;

		a.bSPECIAL    = hSavedSpecial[IX(pnum, hand)];
		a.bNOGRAVITY  = hSavedNoGravity[IX(pnum, hand)];
		a.bTHRUACTORS = hSavedThruActors[IX(pnum, hand)];

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
	private void CarryOne(int pnum, PlayerPawn pmo, PlayerInfo p, int hand, Actor a)
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
			// [HANDUNITS 2026-10-02] THE x100 IS GONE. THE RATIO IS NOW 1.
			//
			// This divided by FOLLOWHAND_UNIT_SCALE (0.01), i.e. multiplied the held
			// object's Scale by a HUNDRED, to compensate for a hand frame that used to
			// draw one model unit at 0.34 map units while the floor drew it at 1.
			//
			// The engine no longer does that: ObjectToWorldMatrix divides
			// vr_vunits_per_meter back out on the hand path too (models.cpp), so BOTH
			// frames are map units and there is nothing left to compensate for. The x100
			// is pure leftover, and it is why a picked-up barrel or medikit was drawn a
			// hundred times its floor size -- which reads as "it disappeared", because an
			// object that large is all you can see and has no recognisable silhouette.
			//
			// RS_VR_Reload migrated through this same problem first and set
			// wm_world_factor to 1.0 for exactly this reason (loose.zs); the two packages
			// now agree, which they did not while this stood.
			//
			// THE SAVE STAYS, and it is not redundant. An object can be scaled by
			// something else while it is held -- a mod, a pickup effect -- and it still
			// has to be given back exactly what it came with. The save also remains the
			// guard against the original bug in this block: it used to scale EVERY tic,
			// a hundredfold then ten thousand then a million, and saved each grown size
			// as the one to restore.
			if (!hFollowScaled[hand])
			{
				hSavedScale[IX(pnum, hand)] = a.Scale;
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
				if (hSavedScale[IX(pnum, hand)].x > 0) a.Scale = hSavedScale[IX(pnum, hand)];
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
		if (!hOwnsFlags[IX(pnum, hand)]) return;

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
	// ---- WHAT HEAVY LOOKS LIKE -----------------------------------------------
	//
	// A held object is drawn on the controller transform by the engine, which
	// means it tracks the hand PERFECTLY -- and perfect tracking is what makes
	// a barrel feel like a balloon. Nothing about carrying one differs from
	// carrying a clip except a number nobody can see.
	//
	// So a heavy thing hangs lower, and dips further when you swing it.
	//
	// THE FRAME IS THE MODEL'S OWN, AND THAT IS WHY THERE IS NO SIDEWAYS LAG.
	//
	// The first version of this trailed the object behind the hand's motion,
	// using the hand velocity straight from the engine ring. That is a WORLD
	// vector, and FollowHandOfs is not a world offset: models.cpp sums it with
	// MODELDEF's own Offset and the placement sliders and applies it as a
	// translate BEFORE the model rotations, in the model's local frame, with Z
	// additionally divided by pixelstretch. Feeding it a world velocity would
	// have sent a held object darting off in whatever direction the mesh's
	// local axes happened to point -- a visible bug, and a worse one than not
	// having the feature.
	//
	// So the DIRECTION is fixed and local -- down, in the only sense this frame
	// has -- and the hand's SPEED modulates the magnitude instead. A heavy
	// thing dips when you swing it and settles when you stop, which is the half
	// of the lag that actually reads as weight, and it cannot point the wrong
	// way because it only ever points one way.
	//
	// PRESENTATION, AND LOCAL. FollowHandOfs moves where the model is DRAWN and
	// nothing in the playsim reads it, so a machine that draws it differently is
	// not a machine that disagrees. Written for the console player only: the
	// hand it describes is the only one this machine has a controller for.
	private void HoldSag(int pnum, PlayerPawn pmo, PlayerInfo p, int hand, Actor a)
	{
		if (pnum != consoleplayer) return;   // presentation, see above
		if (!a || a.FollowHandMode == 0) return;

		double amount = Num("rs_hold_sag", p, 1.0);
		if (amount <= 0) { a.FollowHandOfs = (0, 0, 0); return; }

		// The same logarithmic order the strain haptic uses, and for the same
		// reason: what reads is the ORDER of weights -- clip, medikit, shield,
		// barrel -- not the ratio between them.
		double kg    = RS_Mass.Kg(a);
		double heavy = clamp(log10(max(kg, 0.0) + 1.0) / 1.8, 0.0, 1.0);

		// HOW HARD IT IS BEING SWUNG. Magnitude only: a speed has no frame to
		// get wrong. Zero on a desktop, which is correct -- there is no hand.
		double swing = 0;
		if (RS_Reach.Flag("rs_throw_engine", p, true))
		{
			Vector3 hv = level.HandVelAtPoint(hand, (0, 0, 0), RS_HAND_NOW);
			swing = clamp(hv.Length() / TICRATE / 6.0, 0.0, 1.0);
		}

		double droop = heavy * amount
		             * (Num("rs_hold_sag_max", p, 3.0)
		                + swing * Num("rs_hold_dip_max", p, 4.0));

		a.FollowHandOfs = (0, 0, -droop);
	}

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
		// SCALED BY MASS, AND THE REASON IT WAS NOT IS GONE.
		//
		// This used to read Radius*Height, and said so: "Doom actors have no
		// mass, and inventing a mass table would be a worse answer than the
		// number already on the actor." That was correct when it was written
		// and it is not correct now -- RS_Mass exists, MASSDEF ships the
		// vanilla numbers, and it is the same table the throw already weighs
		// things against.
		//
		// It also fixes a case the old proxy got backwards. A barrel is 16x32
		// and a medikit 20x16, so by bounding box the MEDIKIT is the heavier
		// of the two: 320 against 512, but only because the barrel is narrow.
		// By mass it is 1.5 kg against 60. The hand should not have to be told
		// which of those is heavier.
		//
		// LOGARITHMIC, because a barrel is four hundred times a clip and a
		// controller has one motor. What the player needs is an ORDER -- clip,
		// medikit, shield, barrel, each noticeably heavier than the last -- not
		// a linear ratio that pins everything above a few kilos to maximum.
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
				// Capped at both ends: a mod's 900 kg prop must not be able to
				// ask for an intensity the runtime never expected, and nothing
				// is so light that it vanishes.
				double kg   = RS_Mass.Kg(a);
				double bulk = clamp(0.5 + log10(max(kg, 0.0) + 1.0) * 0.9, 0.5, 2.0);
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

	// EVERY IN-GAME PLAYER, NOT JUST THIS MACHINE'S.
	//
	// The carry, the flag restore and the dead-hands release all live below, and
	// they are CONSEQUENCES the playsim has to reach identically everywhere. Run
	// for consoleplayer alone, they advanced on one machine and not the others --
	// which is a divergence with no command anywhere to blame it on.
	//
	// The per-player work is TickPlayer. Anything genuinely local -- a cvar read, a
	// controller pose, a debug line -- stays keyed to consoleplayer inside it and
	// says so, because a cvar is allowed to speak only for the person whose cvar it
	// is. The test is whether the DECISION is local, not whether the state is.
	override void WorldTick()
	{
		for (int i = 0; i < MAXPLAYERS; ++i)
			if (playeringame[i] && players[i].mo)
				TickPlayer(i);
	}

	private void TickPlayer(int pnum)
	{
		let p = players[pnum];
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
				if (hActor[IX(pnum, 0)]) h0 = hActor[IX(pnum, 0)].GetClassName();
				String h1 = "-";
				if (hActor[IX(pnum, 1)]) h1 = hActor[IX(pnum, 1)].GetClassName();

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
			if (!hActor[IX(pnum, h)] && hRole[IX(pnum, h)] != ROLE_NONE) ClearSlot(pnum, h);
			// A pickup can KEEP the world actor: Inventory.CreateCopy returns
			// self when GoAway() is false, so a face-use of, say, a Cell you
			// own no gun for turns the thing in your hand into an owned,
			// invisible inventory item. Still pointed at from here, it would
			// be TryMove'd every tic, keep the hand full, and take throw
			// velocity and restored flags on release. Forget it instead.
			let owned = Inventory(hActor[IX(pnum, h)]);
			if (owned && owned.Owner) ClearSlot(pnum, h);
		}

		// Dead hands hold nothing. ClearClaims after ReleaseAll, never instead
		// of it: ReleaseAll empties the slots, and this is what withdraws what
		// those slots had published.
		if (pmo.Health <= 0) { ReleaseAll(pnum); ClearClaims(pnum, pmo); return; }

		// Switching grabbing off mid-hold has to LET GO, not stop carrying.
		// The input handler is gated on the same cvar, so a hold left standing
		// here would have nothing left able to release it -- and the switch is a
		// menu entry, which is the one place a player can reach from inside a
		// headset. Stranding an object behind the off position of its own toggle
		// is not a state anything can get out of.
		if (!Flag("rs_grab", p, true)) { ReleaseAll(pnum); ClearClaims(pnum, pmo); return; }

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
			if (hActor[IX(pnum, h)] && hRole[IX(pnum, h)] == ROLE_PRIMARY)
				CarryOne(pnum, pmo, p, h, hActor[IX(pnum, h)]);
		}

		for (int h = 0; h < 2; h++)
		{
			Actor a = hActor[IX(pnum, h)];
			if (!a) continue;

			// For a SUPPORT hand this measures the gap between your two hands,
			// because the object sits at the primary palm -- so pulling your
			// hands apart takes the second one off it, which is what pulling
			// your hands apart means.
			// How heavy it LOOKS, every tic, beside how heavy it feels.
			HoldSag(pnum, pmo, p, h, a);

			if (ShouldBreak(pmo, p, h, a))
			{
				if (Flag("rs_hand_debug", p, true))
					Console.Printf("[RSHELD] hand %d lost %s -- too far from the palm",
						h, a.GetClassName());
				Release(pnum, h);
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
			//
			// AND SINCE PROTOCOL 3 (2026-10-01) THE GRANT ITSELF WRITES THE FIELD.
			// The arbiter publishes GripClaim* the instant it books the claim, so
			// writing it here as well would be a second writer saying the same
			// thing -- and a second writer is the whole bug. The direct write is
			// kept for the case it was always for: this package loaded without the
			// arbiter, where nothing else can do it.
			bool granted = !arbiter
				|| arbiter.GetInt("grip.claim", "", h, hSubject[IX(pnum, h)], pmo, 'RS_Held') == 1;
			if (granted)
			{
				if (!arbiter)
				{
					if (h == HAND_MAIN) pmo.GripClaimMain = hSubject[IX(pnum, h)];
					else                pmo.GripClaimOff  = hSubject[IX(pnum, h)];
				}
				hClaimed[IX(pnum, h)] = hSubject[IX(pnum, h)];
			}

			// Doubles as a renewal -- this runs every tic while holding, which
			// is exactly what keeps the lease alive.

			// And tell the hand model what shape to be, when the world hands are
			// the ones on screen. One tic behind, because the pose handler is
			// registered ahead of this one -- invisible on a finger blend.
			// LOCAL PLAYER ONLY, and this is the one place consoleplayer is the
			// RIGHT answer. The rule is not "never consoleplayer" -- it is that
			// GAMEPLAY may not key off it, because it names a different person on
			// every machine. Choosing what the hands on YOUR screen look like is
			// presentation, and presentation is exactly what consoleplayer is for.
			// Without the gate this ran once per player per tic into a single pair
			// of drawn hands, last player wins.
			if (pnum == consoleplayer)
			{
				let hd = RS_HandWorldHandler.Get(h);
				if (hd) hd.HoldPose(hPose[IX(pnum, h)]);
			}
		}

		ClearClaims(pnum, pmo);
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
	private void ClearClaims(int pnum, PlayerPawn pmo)
	{
		if (!pmo) return;

		// Clear the claim for an empty hand, but only if the value standing there
		// is one we put there. More than one mod writes these.
		for (int h = 0; h < 2; h++)
		{
			if (hActor[IX(pnum, h)]) continue;
			if (hClaimed[IX(pnum, h)] == GRIPSUBJ_None) continue;

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
				ours = ((h == HAND_MAIN) ? pmo.GripClaimMain : pmo.GripClaimOff) == hClaimed[IX(pnum, h)];

			// WITH THE ARBITER, THE RELEASE BELOW TAKES THE FIELD DOWN FOR US
			// (PROTOCOL 3). Zeroing it here as well is the same second-writer
			// problem in reverse, and it is worse than the set: a release that is
			// refused -- because the hand is someone else's now -- would still
			// have blanked THEIR claim. Only the no-arbiter path writes.
			if (ours && !arbiter)
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

			hClaimed[IX(pnum, h)] = GRIPSUBJ_None;

			if (pnum == consoleplayer)          // presentation, see the note above
			{
				let hd = RS_HandWorldHandler.Get(h);
				if (hd && hd.poseHold >= 0) hd.HoldPose(-1);
			}
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
		// EVERY player, not just this machine's. The held state now has a slot per
		// player, so releasing only your own would leave every other player's slots
		// pointing at actors from the map that just ended.
		for (int i = 0; i < MAXPLAYERS; ++i) ReleaseAll(i);
	}

	override void WorldUnloaded(WorldEvent e)
	{
		// ReleaseAll empties the slots; ClearClaims withdraws what the tic
		// loop PUBLISHED -- GripClaim* on the pawn and the arbiter lease.
		// The pawn travels to the next map, this handler does not, and the
		// engine never clears the field itself, so a hold across an exit
		// left that hand reading as closed on an object for the whole of
		// the following map.
		// APPLIED, NEVER SENT, AND FOR EVERY PLAYER.
		//
		// Not sent because a level exit is exactly when gamestate stops being
		// GS_LEVEL, and SendNetworkEvent refuses and sends NOTHING in that state
		// (events.cpp:385). A release that only travels is a release that never
		// happens on the one path that most needs it -- an object left owned,
		// weightless and unpickable, with the record of what it used to be gone.
		// Every machine sees this event on the same tic, so applying directly is
		// both safe and the only thing that works.
		for (int i = 0; i < MAXPLAYERS; ++i)
		{
			ReleaseAll(i);
			if (playeringame[i] && players[i].mo) ClearClaims(i, players[i].mo);
		}
	}
}
