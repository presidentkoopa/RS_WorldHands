// DISTANCE GRABBING -- point at a thing across the room and it comes to you.
//
// Three parts, kept apart because they fail differently:
//
//   RS_Cone   the question "what am I pointing at". Pure geometry, no state.
//   RS_Pull   the flight. The only part that owns state, and it owns it per
//             hand for exactly as long as an object is in the air.
//   the hook  in RS_GrabHandler: a squeeze with nothing in your palm asks the
//             cone instead of giving up.
//
// REACH AND SPREAD ARE SEPARATE NUMBERS. How FAR you can pull from and how
// PRECISELY you have to point are different complaints with different fixes, and
// a single "cone size" slider forces one to be wrong to make the other right.

class RS_Cone play
{
	// The hand's forward axis. Same basis, same +90 on yaw, same order as
	// RS_Reach -- because a cone that tests one convention while the reach
	// volume tests another is two systems that disagree about where your hand
	// points, and that reads in the headset as the aim being randomly off.
	static Vector3 Dir(PlayerPawn pmo, int hand)
	{
		double yaw = ((hand == 0) ? pmo.AttackAngle : pmo.OffhandAngle) + 90;
		double pit = RS_Reach.HandPitch(pmo, hand);
		double rol = ((hand == 0) ? pmo.MainHandRoll : pmo.OffhandRoll);
		return RS_Basis.Fwd(yaw, pit, rol);
	}

	// The best thing in this hand's cone, or null.
	//
	// Scored on ANGLE FIRST and distance second, because pointing is what you
	// are actually doing. A nearer object well off your axis is not what you
	// meant; the thing you are pointing straight at is, even if something else
	// is closer to your hand.
	static Actor Best(PlayerPawn pmo, PlayerInfo p, int hand)
	{
		let pol = RS_GrabPolicy.Get();
		if (!pol) return null;

		double reach  = RS_Reach.Num("rs_dgrab_reach",  p, 512.0);
		double spread = RS_Reach.Num("rs_dgrab_spread", p, 12.0);
		if (reach <= 0 || spread <= 0) return null;

		Vector3 origin = RS_Reach.Centre(pmo, p, hand);
		Vector3 dir    = Dir(pmo, hand);

		// Compared as a COSINE, so the test is one dot product and no inverse
		// trig runs per candidate. cos is monotonically decreasing over 0..180,
		// so "within the spread" is "dot product at least this big".
		double cosLimit = cos(spread);

		Actor best = null;
		double bestScore = -2.0;

		// WHAT IS ALREADY IN A HAND IS NOT IN THE CONE, and the near path has had
		// this guard from the start (RS_Reach.Best). Without it the cone will
		// happily pick the object in your OTHER fist -- it is a legal grab
		// candidate, it is within reach, and it is usually the thing you are
		// looking straight at -- and then a flick tears it out of that hand and
		// throws it across the room at this one. There is no gesture for "yank it
		// out of my own grip", so there is nothing this could have meant.
		//
		// Broader than the near guard on purpose. The near path deliberately
		// keeps the other hand's object as a target, because closing on it there
		// means a second hand joining or a hand-to-hand pass, and RS_Held.Take
		// handles both. Nothing on the flight path does: RS_Pull.Start would
		// simply take it.
		let held = RS_Held.Get();

		BlockThingsIterator it =
			BlockThingsIterator.CreateFromPos(origin.x, origin.y, origin.z, reach, reach, false);
		while (it.Next())
		{
			Actor a = it.thing;
			if (!a || a == pmo) continue;
			if (held && held.IsHeld(a)) continue;
			if (!pol.Decide(a, pmo, p)) continue;

			// The MIDDLE of the thing, not its origin. A Doom actor's origin is
			// the floor of its volume, so aiming at a barrel by eye and testing
			// against its feet means pointing at the floor in front of it.
			Vector3 mid = (a.Pos.x, a.Pos.y, a.Pos.z + a.Height * 0.5);
			Vector3 d = mid - origin;
			double dist = d.Length();
			if (dist > reach || dist < 0.01) continue;

			double c = (d / dist) dot dir;
			if (c < cosLimit) continue;

			// Through walls is not pointing at it. Checked last, because it is
			// the only expensive test here and by this point at most a handful
			// of candidates have survived the cheap ones.
			if (RS_Reach.Flag("rs_dgrab_sight", p, true) && !pmo.CheckSight(a))
				continue;

			// Angle dominates; distance only separates two things you are
			// pointing at equally well.
			double score = c - (dist / reach) * 0.25;
			if (score > bestScore) { bestScore = score; best = a; }
		}
		return best;
	}
}

// THE FLIGHT.
//
// Owns an object for the fraction of a second between the squeeze and the catch,
// and owns nothing else. On arrival it hands over to RS_Held and forgets.
class RS_Pull : EventHandler
{
	private Actor   flyActor[2];
	private int     flyTic[2];
	private int     flyTotal[2];
	private Vector3 flyStart[2];

	// THE ARC THIS PARTICULAR PULL IS ALLOWED, decided once at launch.
	//
	// It used to be recomputed every tic as a flat fraction of the pull
	// distance, with no idea what was overhead, and then clamped against the
	// local ceiling when it did not fit. Clamping is the wrong remedy: it does
	// not lower the arc, it SQUASHES it, pinning the object to whatever surface
	// it met and dragging it there. Every "it hops and settles instead of
	// sailing" report is that clamp doing its job.
	//
	// Deciding up front against the LOWEST ceiling anywhere on the route means
	// a pull under a low doorway is simply a flatter pull that still arrives,
	// rather than a pretty arc that fails. See MeasureArc.
	private double  flyArc[2];

	// TICS THE OBJECT WAITS ON YOUR PALM BEFORE IT RESOLVES AS A MISS.
	//
	// Without this the catch could not be made at any real range, and the reason
	// is a tick-order trap rather than anything wrong with the catch test.
	//
	// The arc used to reach t == 1.0, place the object exactly on the palm, and
	// call Impact() in the SAME pass -- so the object existed at the catch point
	// for zero tics. Worse, RS_GrabHandler (registered 4th in MAPINFO) asks
	// CatchableBy BEFORE RS_Pull (7th) runs, so the only position the catch test
	// ever saw was the one written the PREVIOUS tic, i.e. the second-to-last
	// sample of the arc. At default speed that sample sits ~23 units short and
	// ~13 units above the palm, against a catch volume with semi-axes
	// (2.2, 3.2, 1.6). It scores ~17 where <= 1.0 is required. The window was
	// not tight, it was shut.
	//
	// That also explains why this survived testing: the residual gap is a
	// constant number of units, not a fraction, so a SHORT pull lands inside the
	// volume anyway. Under ~50-70 units it catches fine, which is arm's reach --
	// exactly the distance someone tests at first.
	//
	// So the object now parks on the palm for a few tics and keeps tracking it
	// (t is clamped at 1.0, so the position code above keeps re-solving to the
	// live palm). That gives the earlier-registered catch test real tics at the
	// real arrival position. Miss the whole window and it still hits you, which
	// is the point of the mechanic -- the medikit heals you, the barrel hurts.
	private int     flyHold[2];

	// Four tics, ~114ms. Long enough that the catch test gets several real looks
	// including one after the hand's own pose has settled, short enough that a
	// missed catch still reads as an impact rather than the object hovering.
	const CATCH_HOLD_TICS = 4;
	// The LAUNCH distance, kept for the whole flight. Arc height is a fraction
	// of it, and re-measuring each tic would shrink the arc as the object closed
	// on you -- flattening the parabola into a straight line exactly as it
	// arrived, which is the one moment you are looking at it.
	private double  flyDist[2];

	// THE OBJECT'S OWN FLAGS, SAVED HERE AND HANDED OVER INTACT.
	//
	// Flight has to switch gravity off and pickup-on-touch off, exactly as
	// holding does. If it did that and then called RS_Held.Take, Take would save
	// the flags it found -- which are the ones flight just changed -- and record
	// "this object was always weightless and never touchable" as its original
	// state. Releasing it later would leave it floating and unpickable forever.
	//
	// So the true values are captured before flight touches anything, and put
	// back one line before the handover, so the state Take saves is the truth.
	private bool flySavedSpecial[2];
	private bool flySavedNoGrav[2];
	// THE THIRD ONE, and the barrel is why -- see the note in Start.
	private bool flySavedThruActors[2];

	// THE OBJECT'S REAL SIZE, put back the moment it stops flying.
	//
	// A Doom pickup's radius is a PICKUP-TRIGGER volume, not a physical hull --
	// a clip is radius 20, the same as a shotgun guy, because that is how near
	// you have to walk to collect it. It is a few units across to look at.
	//
	// Flying a 40-unit-wide box through a doorway for an object the size of a
	// fist is what produced twelve blocked pulls in one session, every one of
	// them a radius-20 pickup and not one of them a radius-10 barrel.
	private double flySavedRadius[2];
	private double flySavedHeight[2];

	// THE TUMBLE, saved under exactly the same discipline and for exactly the
	// same reason. See SaveTumble.
	//
	// The ORIGINAL values, not "off": +ROLLSPRITE is something an actor may
	// legitimately ship with -- Heretic's phoenix rod flame does
	// (wadsrc/static/zscript/actors/heretic/weaponphoenix.zs:381) -- and
	// clearing it on arrival would permanently un-roll something that was never
	// ours to change. Same argument as hSavedThruActors in RS_Held.
	private bool   flySavedRollSprite[2];
	private bool   flySavedRollCentre[2];
	private bool   flySavedInterpAng[2];
	private double flySavedRoll[2];

	// VOXEL FOR THE WHOLE GESTURE, not just the hold.
	//
	// RS_Held already turns a HELD object into its voxel. But the gesture the
	// owner described is one continuous thing -- lock on, flick, watch it sail
	// over, catch it, carry it -- and having it pop from sprite to voxel at the
	// instant of the catch would make the seam the most visible part of it. So
	// the override goes on at the LOCK and stays on until the object stops
	// being yours.
	//
	// Two slots because a lock and a flight are different lifetimes: an object
	// can be locked and never flown (you let go of the grip), or flown and
	// never caught. Each needs its own saved value and its own restore, or one
	// path hands back a value the other never took.
	//
	// SAVED, NEVER ASSUMED FALSE, for the same reason as every other borrowed
	// flag here: a player running r_drawvoxels globally may lock onto something
	// that was ALREADY a voxel, and letting go must not take that away.
	private bool   lockSavedVoxel[2];
	private bool   flySavedVoxel[2];

	// Turns for THIS flight, read once at launch and not per tic. Read per tic
	// and nudging the slider mid-flight would JUMP the barrel to a new angle
	// rather than change the rate it is turning at, because the angle is the
	// turn count times the progress.
	private double flyTurns[2];

	// THE LOCK -- grabbed, and still across the room.
	//
	// This is the state the system was missing, and its absence is why a squeeze
	// used to launch things instantly. There are THREE acts, not two:
	//
	//   point   the cone considers it            neutral <-> orange
	//   GRIP    you take hold of it at range     orange  <-> green
	//   flick   you pull it to you               the flash stops
	//
	// The grip does not move anything. It says "that one", and it keeps saying
	// it until you flick, let go, or lose it. Collapsing the grip and the flick
	// into one act removes the only moment where you can change your mind.
	private Actor lockActor[2];

	static RS_Pull Get()
	{
		return RS_Pull(EventHandler.Find("RS_Pull"));
	}

	bool Flying(int hand) const
	{
		return (hand == 0 || hand == 1) && flyActor[hand] != null;
	}

	Actor Locked(int hand) const
	{
		if (hand != 0 && hand != 1) return null;
		return lockActor[hand];
	}

	// Take hold of it where it stands. Nothing moves.
	bool Lock(int hand, Actor a, PlayerPawn pmo, PlayerInfo p)
	{
		if (hand != 0 && hand != 1 || !a) return false;
		if (flyActor[hand]) return false;
		let held = RS_Held.Get();
		if (held && held.HandIsFull(hand)) return false;
		// Not something a hand already has hold of -- see the note in
		// RS_Cone.Best. Refused here as well as filtered there because the cone
		// is not the only thing that can name a target, and this is the door the
		// object actually leaves through.
		if (held && held.IsHeld(a)) return false;

		// NOR SOMETHING THE OTHER HAND IS ALREADY PULLING OR HAS LOCKED.
		//
		// Both hands driving one actor is not a harmless duplicate: each flight
		// saves the object's SPECIAL/NOGRAVITY/THRUACTORS before touching them,
		// so the second save records the values the FIRST flight had already
		// changed -- weightless and pass-through -- as the originals. Whichever
		// flight ends last then restores that fiction. The object is left
		// permanently weightless and permanently walk-through, hanging in the
		// air, and nothing in the game will ever put it back: the true values
		// were overwritten and are gone.
		//
		// Exactly the hazard RS_Held.hOwnsFlags exists to prevent for a
		// two-handed carry, which solves it by having one owner of the backup.
		// Flight has no equivalent, and does not need one -- there is no gesture
		// that means "pull it with both hands", so refusing is the whole fix.
		//
		// Both slots are checked, not just the flight: a lock is what a flick
		// turns into a flight, so allowing the second lock only defers the
		// collision to the moment both are flicked.
		int other = 1 - hand;
		if (flyActor[other] == a || lockActor[other] == a) return false;

		// Voxel from the moment it is yours. Free on anything without one --
		// the engine falls through to the ordinary sprite path.
		let heldSys = RS_Held.Get();
		lockSavedVoxel[hand] = heldSys ? heldSys.TakeThrownVoxel(a, a.VoxelOverride) : a.VoxelOverride;
		if (RS_Reach.Flag("rs_grab_voxel", p, true)) a.VoxelOverride = true;

		lockActor[hand] = a;
		if (RS_Reach.Flag("rs_hand_debug", p, true))
			Console.Printf("[RSPULL] hand %d LOCKED %s -- flick to pull it", hand, a.GetClassName());
		return true;
	}

	void Unlock(int hand)
	{
		if (hand != 0 && hand != 1) return;

		// Put the voxel state back. Unlock is every ending a LOCK has that is
		// not a launch -- you opened your hand, it died, it left range, your
		// hand filled up, grab was switched off -- so this is the one place all
		// of them pass through. Start() takes its own copy before this runs,
		// which is what keeps a launch from restoring a value mid-flight.
		if (lockActor[hand]) lockActor[hand].VoxelOverride = lockSavedVoxel[hand];
		lockSavedVoxel[hand] = false;

		lockActor[hand] = null;
	}

	// A lock is not forever. It survives you looking away -- you already decided
	// -- but not the object dying, not your hand filling up, and not the thing
	// leaving the range you could have pulled it from anyway.
	private void ValidateLock(int hand, PlayerPawn pmo, PlayerInfo p)
	{
		Actor a = lockActor[hand];
		if (!a) return;
		let held = RS_Held.Get();
		if (held && held.HandIsFull(hand)) { Unlock(hand); return; }
		double reach = RS_Reach.Num("rs_dgrab_reach", p, 512.0);
		Vector3 mid = (a.Pos.x, a.Pos.y, a.Pos.z + a.Height * 0.5);
		if ((mid - RS_Reach.Centre(pmo, p, hand)).Length() > reach * 1.25)
		{
			if (RS_Reach.Flag("rs_hand_debug", p, true))
				Console.Printf("[RSPULL] hand %d lost its lock on %s -- out of range",
					hand, a.GetClassName());
			Unlock(hand);
		}
	}

	Actor FlyingActor(int hand) const
	{
		if (hand != 0 && hand != 1) return null;
		return flyActor[hand];
	}

	// ---- the tumble ------------------------------------------------------
	//
	// END OVER END, AND WHY IT TAKES THREE RENDERFLAGS TO GET THERE.
	//
	// A vanilla barrel is a BILLBOARD SPRITE, and a billboard ignores actor roll
	// completely unless +ROLLSPRITE says otherwise -- hw_sprites.cpp:565 gates
	// the entire rotation on that one flag. Without it the pull is a smooth
	// translation with the object dead flat the whole way over, which is exactly
	// what it was.
	//
	// +ROLLCENTER is the half that makes it a TUMBLE rather than a swing.
	// hw_sprites.cpp:518 rotates about the sprite's MIDDLE when it is set and
	// about the sprite's offset origin -- a barrel's FEET -- when it is not.
	// Rolling a barrel about its feet is a thing pivoting on the floor; rolling
	// it about its middle is a thing turning over in the air, which is the only
	// reading of "end over end".
	//
	// +INTERPOLATEANGLES is the third and it is not optional either. Roll is
	// written once per tic, 35 times a second, and hw_sprites.cpp:1187 only
	// reaches for InterpolatedAngles -- the deltaangle lerp at
	// actor.h:1567-1573, which smooths Yaw, Pitch AND Roll and takes the short
	// way round the 0/360 wrap -- when this flag is on. Off, the tumble steps in
	// whole tics and strobes. On, the renderer smooths it for free, and nothing
	// in here has to hand-roll a second interpolator that could only ever
	// disagree with the engine's. Setting roll in WorldTick is safe for that
	// lerp because p_tick.cpp:465 takes every actor's PrevAngles snapshot BEFORE
	// the WorldTick hook runs, so the previous tic's roll is still intact when
	// this writes the new one.
	//
	// SET ONLY WHEN THE TUMBLE IS ACTUALLY ON, and that is why flyTurns is
	// consulted here rather than just in the tic loop. +ROLLSPRITE is NOT inert
	// at roll zero: hw_sprites.cpp:1409 applies a pixelstretch rescale to any
	// actor carrying it, and +ROLLCENTER drops the sprite's own offsets
	// (hw_sprites.cpp:575). Turning the feature off in the menu has to mean the
	// object is drawn exactly as it would have been.
	private void SaveTumble(int hand, Actor a, PlayerInfo p)
	{
		flySavedRollSprite[hand] = a.bROLLSPRITE;
		flySavedRollCentre[hand] = a.bROLLCENTER;
		flySavedInterpAng[hand]  = a.bINTERPOLATEANGLES;
		flySavedRoll[hand]       = a.Roll;
		flyTurns[hand]           = RS_Reach.Num("rs_dgrab_tumble", p, 2.0);

		// Its OWN copy, taken before the lock's is handed back. Start() runs
		// while the object is still locked, so the value here is the one the
		// LOCK imposed -- taking it now and restoring it on every flight exit
		// is what stops a flight from ending on a stale sprite state.
		flySavedVoxel[hand] = lockSavedVoxel[hand];
		if (RS_Reach.Flag("rs_grab_voxel", p, true)) a.VoxelOverride = true;

		ArmTumble(hand, a);
	}

	// Put the flags back on without re-saving. Only the refused-catch path needs
	// this: the object stays in the air, so it has to keep flying as a tumbling
	// thing, but its true values were captured at launch and re-saving here
	// would record the state flight itself imposed -- the same mistake the
	// flySaved* trio above exists to prevent.
	private void ArmTumble(int hand, Actor a)
	{
		if (flyTurns[hand] == 0) return;
		a.bROLLSPRITE        = true;
		a.bROLLCENTER        = true;
		a.bINTERPOLATEANGLES = true;
	}

	// Every exit from the flight goes through here -- caught, aborted, or hit
	// you. Roll included: without it a caught barrel sits in your hand cocked at
	// whatever angle it happened to arrive at, forever.
	private void RestoreTumble(int hand, Actor a)
	{
		a.bROLLSPRITE        = flySavedRollSprite[hand];
		a.bROLLCENTER        = flySavedRollCentre[hand];
		a.bINTERPOLATEANGLES = flySavedInterpAng[hand];
		a.Roll               = flySavedRoll[hand];

		// Every flight ending passes through here -- caught, aborted, blocked,
		// or arrived uncaught -- which is exactly why the voxel state goes back
		// here too. A CATCH immediately re-imposes it from RS_Held, so the
		// object never visibly flickers; every other ending is a thing that is
		// no longer yours and should stop being solid.
		a.VoxelOverride      = flySavedVoxel[hand];
	}

	// HOW HIGH THIS PULL CAN ARC WITHOUT MEETING A CEILING.
	//
	// Walks the straight line the object is about to travel and asks each point
	// what is overhead, keeping the WORST answer -- one low doorway halfway
	// along governs the whole flight, because the object has to fit through it.
	//
	// Returns the arc height that fits, which the caller then takes as a cap on
	// the arc it wanted. Never negative, and zero is a perfectly good answer: it
	// means a flat pull, which still arrives.
	//
	// SAMPLED, NOT SWEPT. A real swept-volume test is what TryMove already does
	// per tic; this only has to be right about the ROOF, and the roof changes at
	// sector boundaries. Sampling densely enough to land in every sector the
	// line crosses gets the same answer far more cheaply, and this runs once per
	// pull rather than once per tic.
	//
	// The floor matters too: the object cannot start below the highest floor on
	// the route either, and headroom is the gap between those two.
	private double MeasureArc(Actor a, Vector3 from, Vector3 to)
	{
		// One sample per 24 units, bounded. A Doom doorway is 64 wide and the
		// narrowest sector worth noticing is smaller than that, so this lands
		// inside anything that could actually stop the object.
		double span = (to - from).Length();
		int samples = clamp(int(span / 24.0), 4, 48);

		double minCeil =  1e30;
		double maxFloor = -1e30;

		for (int i = 0; i <= samples; i++)
		{
			double t = double(i) / double(samples);
			Vector2 pt = (from.x + (to.x - from.x) * t,
			              from.y + (to.y - from.y) * t);

			Sector sec = level.PointInSector(pt);
			if (!sec) continue;

			double c = sec.ceilingplane.ZatPoint(pt);
			double f = sec.floorplane.ZatPoint(pt);
			if (c < minCeil)  minCeil = c;
			if (f > maxFloor) maxFloor = f;
		}

		// Nothing sampled cleanly -- refuse to invent a number and let the
		// caller keep the arc it asked for. The per-tic clamp is still there as
		// the backstop it was always meant to be.
		if (minCeil > 1e29 || maxFloor < -1e29) return -1.0;

		// A margin, because the object is a box and not a point: its top corners
		// reach higher than its centre when it tumbles, and the tumble is on by
		// default.
		double margin = 8.0;
		double room = minCeil - maxFloor - a.Height - margin;

		// The arc rides ON TOP of the line between the two ends, so the height
		// already spent getting from the floor up to the higher end is not
		// available to the arc.
		double lineTop = max(from.z, to.z);
		double avail   = (minCeil - a.Height - margin) - lineTop;

		double cap = min(room, avail);
		return cap > 0.0 ? cap : 0.0;
	}

	// Begin a pull. Returns false if it could not start, so the caller can say
	// so rather than silently doing nothing.
	bool Start(int hand, Actor a, PlayerPawn pmo, PlayerInfo p)
	{
		// EVERY REFUSAL SAYS WHY.
		//
		// These five guards each returned false in silence, which made "the pull
		// did nothing" mean any of: the squeeze never arrived, the cone found
		// nothing, this hand is full, something is already flying, or the target
		// is in the other fist. Five different faults with one symptom and no way
		// to tell them apart from inside a headset -- and one of them, "nothing
		// in the cone", is not even reached here because the caller gives up
		// first.
		//
		// Named rather than numbered: a log line that says "hand full" is read
		// once, and a line that says "refused at guard 3" is read against this
		// file forever.
		let held = RS_Held.Get();
		String why = "";

		if (hand != 0 && hand != 1)         why = "bad hand index";
		else if (!a)                        why = "no target";
		else if (flyActor[hand])            why = "this hand already has something in flight";
		else if (!held)                     why = "RS_Held missing";
		else if (held.HandIsFull(hand))     why = "this hand is already holding something";
		// Nor out of the other hand. Same reason as Lock: this is the call that
		// would actually launch it.
		else if (held.IsHeld(a))            why = "target is held by a hand already";

		if (why != "")
		{
			if (RS_Reach.Flag("rs_hand_trace", p, true))
			{
				String tn = "nothing";
				if (a) tn = a.GetClassName();
				Console.Printf("[RSPULL] hand %d refused %s -- %s", hand, tn, why);
			}
			return false;
		}

		// FLIGHT TIME COMES FROM THE DISTANCE, so near and far pulls travel at
		// the same SPEED. A fixed tic count meant a thing across the room moved
		// three times faster than one at your feet -- the far pull a blur, the
		// near one a drift, and both driven by the same slider.
		Vector3 mid0 = (a.Pos.x, a.Pos.y, a.Pos.z + a.Height * 0.5);
		double dist = (mid0 - RS_Reach.Centre(pmo, p, hand)).Length();
		double upt  = RS_Swing.MetresPerSecToUnitsPerTic(
			RS_Reach.Num("rs_dgrab_speed", p, 15.0));
		if (upt < 0.1) upt = 0.1;
		double lo = RS_Reach.Num("rs_dgrab_time_min", p, 6.0);
		double hi = RS_Reach.Num("rs_dgrab_time_max", p, 70.0);
		if (lo < 1) lo = 1;
		if (hi < lo) hi = lo;
		double tics = clamp(dist / upt, lo, hi);

		// The arc it WANTS, then the arc the route allows. Measured against the
		// palm rather than the player's feet, because the palm is where the
		// flight actually ends.
		Vector3 palm = RS_Reach.Centre(pmo, p, hand);
		double wantArc = dist * RS_Reach.Num("rs_dgrab_arc", p, 0.15);
		double capArc  = MeasureArc(a, mid0, palm);
		flyArc[hand] = (capArc < 0.0) ? wantArc : min(wantArc, capArc);

		lockActor[hand] = null;
		flyActor[hand] = a;
		flyTic[hand]   = 0;
		flyHold[hand]  = 0;   // a fresh pull gets a fresh catch window
		flyTotal[hand] = int(tics);
		flyStart[hand] = mid0;
		flyDist[hand]  = dist;

		flySavedSpecial[hand]    = a.bSPECIAL;
		flySavedNoGrav[hand]     = a.bNOGRAVITY;
		flySavedThruActors[hand] = a.bTHRUACTORS;
		flySavedRadius[hand]     = a.Radius;
		flySavedHeight[hand]     = a.Height;

		// SPECIAL IS LEFT ALONE, and that is the whole design in one line.
		//
		// Holding an object clears it, because an item inside your own collision
		// cylinder would be collected every tic. Flight is the opposite case: an
		// object crossing the room at you SHOULD resolve if it reaches you.
		// Missing a catch is not a dropped ball -- it is the medikit hitting you
		// and healing you, the ammo box hitting you and giving you ammo, the
		// barrel hitting you and hurting. There is no outcome where you flicked
		// something and nothing happened.
		//
		// NOGRAVITY still goes on: the arc is authored, and gravity fighting it
		// mid-flight would drag every pull into the floor.
		a.bNOGRAVITY = true;

		// AND THRUACTORS, FOR THE LAST FEW TICS OF THE ARC.
		//
		// The flight is driven with TryMove (see the note there), and the arc
		// homes to your PALM -- so every pull ends with the object crossing
		// inside your own collision cylinder. A +SOLID thing, a barrel above all,
		// is refused that move by PIT_CheckThing, and the blocked branch below
		// reads a refusal as "it hit geometry" and aborts the pull. The barrel
		// therefore dropped out of the air roughly an arm's length short, every
		// single time, and the catch window never opened at all.
		//
		// The same flag and the same reasoning as RS_Held.SaveFlags, which is the
		// point: an object handed from flight to a hand must not change what it
		// is on the way. Cleared again one line before the handover in Catch, so
		// what RS_Held records as the object's true state is the object's true
		// state, and put back by Abort and Impact on every path that does not end
		// in a hand.
		a.bTHRUACTORS = true;

		// AND SHRUNK TO SOMETHING THE SIZE IT LOOKS.
		//
		// A_SetSize rather than writing Radius directly, because the actor has to
		// be re-linked into the blockmap at the new size or every collision test
		// goes on using the old one and nothing changes.
		//
		// CAPPED, NOT SCALED. A barrel at radius 10 already fits everywhere it
		// needs to and there is no reason to touch it; only the oversized pickup
		// volumes come down. Height is left alone -- it was never the problem,
		// and shrinking it would drop the object out of its own arc.
		//
		// Put back on all three exits, and that matters more than usual: a clip
		// left at radius 8 is a clip you have to stand on top of to collect.
		//
		// 2, NOT 8. At 8 a pulled armour was still 16 units wide and caught on a
		// window frame it visibly fitted through. Thin still stops at walls -- a
		// pull cannot reach through geometry -- it just forgives an opening.
		// The same width RS_Held carries a thing at, so nothing changes size on
		// the catch.
		if (a.Radius > 2.0) a.A_SetSize(2.0, a.Height);

		// AND THE TUMBLE. Last, because it is the only one of the four that is
		// purely cosmetic -- if it were ever to be dropped, nothing above it
		// changes. See SaveTumble for what the three flags each do.
		SaveTumble(hand, a, p);

		a.Vel = (0, 0, 0);

		// WHAT LAUNCHED, AND WITH WHAT ROOM TO DO IT IN.
		//
		// "Armour and barrels sail, corpses and stimpacks hop" is a report about
		// two classes of object behaving differently, and nothing above treats
		// them differently -- so the difference has to be in their numbers, not
		// in the code path. These are the numbers the arc is then clamped
		// against: an object whose ceiling room is smaller than the arc it was
		// given cannot fly, and will be squashed onto the floor and dragged
		// there instead, which is what a hop looks like.
		//
		// Printed at launch rather than per tic: one line per pull, naming the
		// thing, how far it has to come, how long it has been given, and how
		// much vertical room it actually has.
		if (RS_Reach.Flag("rs_hand_trace", p, true))
			// DROPPED AND THE Z GAP ARE THE TWO NEW COLUMNS, and they are here
			// because of a specific observation: a clip dropped by a dead
			// zombieman pulls, and the SAME class placed by the mapper does not.
			// Reported 2026-08-29.
			//
			// Those two differ in almost nothing except bDROPPED and how they
			// came to be standing where they are. A dropped item was placed by
			// the playsim and had to find a position it fits in; a map-placed
			// one was put there by a mapper and can be flush with, or slightly
			// inside, the floor. zgap says which: anything other than 0 means
			// the thing is not sitting where the floor says it should be, and a
			// negative one means it is embedded -- which is a TryMove that fails
			// on tic 1 and looks exactly like a hop.
			Console.Printf("[RSPULL] hand %d launched %s  dist=%.0f tics=%d  r=%.0f h=%.0f  floorz=%.0f ceilz=%.0f headroom=%.0f  arc=%.0f  dropped=%d zgap=%.1f special=%d nograv=%d",
				hand, a.GetClassName(), dist, int(tics),
				a.Radius, a.Height, a.floorz, a.ceilingz,
				a.ceilingz - a.floorz - a.Height,
				flyArc[hand],
				a.bDROPPED ? 1 : 0, a.Pos.z - a.floorz,
				a.bSPECIAL ? 1 : 0, a.bNOGRAVITY ? 1 : 0);

		return true;
	}

	// TAKE IT OUT OF THE AIR.
	//
	// Hands the object over to the held-state machine mid-flight and stops
	// driving it. Returns false when it could not be taken, so the caller can
	// leave the object flying rather than dropping it on a refusal.
	//
	// The real flags go back BEFORE the handover, every time -- RS_Held.Take
	// saves what it finds, and what it would find otherwise is the state flight
	// imposed. An object released later would be weightless forever.
	bool Catch(int hand, PlayerPawn pmo, PlayerInfo p)
	{
		if (hand != 0 && hand != 1) return false;
		Actor a = flyActor[hand];
		if (!a) return false;

		let held = RS_Held.Get();
		let pol  = RS_GrabPolicy.Get();
		let rule = pol ? pol.Decide(a, pmo, p) : null;
		if (!held || !rule) return false;

		a.bSPECIAL    = flySavedSpecial[hand];
		a.bNOGRAVITY  = flySavedNoGrav[hand];
		a.bTHRUACTORS = flySavedThruActors[hand];
			a.A_SetSize(flySavedRadius[hand], flySavedHeight[hand]);
		// Before the handover for the same reason as the three above, plus one
		// of its own: RS_Held.SaveFlags does not know about the roll flags, so
		// if flight left them set they would never come off at all.
		RestoreTumble(hand, a);

		// TAKEN AS SOMETHING ELSE, when the mod that owns what it is for says so
		// (RS_GrabPolicy.Become). Flight's flags went back onto the original just
		// above, and it is gone now; the replacement never flew.
		Actor b = RS_GrabPolicy.Become(hand, a);
		if (b != a)
		{
			a = b;
			flyActor[hand] = a;
			rule = a ? pol.Decide(a, pmo, p) : null;
			if (!rule)
			{
				flyActor[hand] = null;
				flyHold[hand]  = 0;
				return false;
			}
		}

		// Consumed on the way in -- a weapon that equipped, or a third copy that
		// became ammo. There is nothing left to hold.
		if (pol.OnTake(hand, a, rule, pmo, p, true))   // fromAir: this is the catch
		{
			flyActor[hand] = null;
			flyHold[hand]  = 0;
			return true;
		}

		int res = held.Take(hand, a, rule.subject, rule.pose, rule.twohand, p);
		if (res == RS_Held.TAKE_REFUSED)
		{
			// Put flight's own flags back and keep flying. A refused catch must
			// not leave the object half-owned by nobody -- and that includes
			// THRUACTORS, or the rest of the arc runs into you and aborts.
			a.bNOGRAVITY  = true;
			a.bTHRUACTORS = true;
			// And it must not stop tumbling either -- it is still in the air.
			// Roll itself needs no repair: the tic loop writes it outright from
			// the saved value and the progress, so the next tic puts it back
			// where the arc says it should be.
			ArmTumble(hand, a);
			return false;
		}

		flyActor[hand] = null;
		flyHold[hand]  = 0;
		if (RS_Reach.Flag("rs_hand_debug", p, true))
			Console.Printf("[RSPULL] hand %d CAUGHT %s (%s)", hand, a.GetClassName(), rule.why);
		return true;
	}

	// Which flying object, if any, is inside this hand's reach volume right now.
	// This is what makes catching a matter of TIMING rather than a button that
	// always works: the object homes to your palm, so it is only catchable once
	// it has nearly got there.
	Actor CatchableBy(int hand, PlayerPawn pmo, PlayerInfo p)
	{
		if (hand != 0 && hand != 1) return null;
		Actor a = flyActor[hand];
		if (!a) return null;
		// ScoreAt with the centre we already have. Score would derive it a second
		// time, and deriving it walks the thinker list for the hand actor -- twice
		// per hand per tic for one number that cannot have changed in between.
		Vector3 c = RS_Reach.Centre(pmo, p, hand);
		return (RS_Reach.ScoreAt(pmo, p, hand, RS_Reach.ClosestOn(a, c), c) <= 1.0) ? a : null;
	}

	// Put the object back the way it was found and forget it. Not a drop and not
	// a catch -- this is the path for a pull that cannot finish.
	private void Abort(int hand)
	{
		Actor a = flyActor[hand];
		if (a)
		{
			a.bSPECIAL    = flySavedSpecial[hand];
			a.bNOGRAVITY  = flySavedNoGrav[hand];
			a.bTHRUACTORS = flySavedThruActors[hand];
			a.A_SetSize(flySavedRadius[hand], flySavedHeight[hand]);
			RestoreTumble(hand, a);
			a.Vel = (0, 0, 0);
		}
		flyActor[hand] = null;
		flyHold[hand]  = 0;
	}

	void AbortAll()
	{
		Abort(0);
		Abort(1);
		Unlock(0);
		Unlock(1);
	}

	override void WorldTick()
	{
		let p = players[consoleplayer];
		if (!p || !p.mo) return;
		let pmo = p.mo;

		// rs_grab AS WELL AS rs_dgrab, and the master switch is the one that was
		// missing.
		//
		// Distance grab is downstream of grab: the lock is taken by
		// RS_GrabHandler and a flick is read there too. Switch rs_grab off with
		// something locked and that handler clears its own claims and returns
		// (rs_grab.zs, the Flag("rs_grab") exit) -- but this handler kept
		// running, because it only ever asked about rs_dgrab. The lock therefore
		// survived with nothing left able to reach it: the object went on
		// pulsing and the reeling beam went on being drawn to the palm for the
		// rest of the level, and the grip that would normally clear it no longer
		// resolved at all. Anything already in the air also finished its arc and
		// hit you, with the whole grab system supposedly switched off.
		//
		// AbortAll puts flights back the way they were found and drops both
		// locks, which is exactly what "off" should mean.
		if (pmo.Health <= 0
			|| !RS_Reach.Flag("rs_grab",  p, true)
			|| !RS_Reach.Flag("rs_dgrab", p, true))
		{
			AbortAll();
			return;
		}


		ValidateLock(0, pmo, p);
		ValidateLock(1, pmo, p);

		let held = RS_Held.Get();

		for (int h = 0; h < 2; h++)
		{
			Actor a = flyActor[h];
			// An actor pointer nulls itself when the actor dies, so a target
			// crushed or consumed mid-flight clears its own slot. The saved
			// flags do not, and a stale pair of those is what the NEXT pull
			// would hand to RS_Held.
			if (!a) { if (flyTic[h] != 0) { flyTic[h] = 0; flyHold[h] = 0; } continue; }

			flyTic[h]++;
			double t = double(flyTic[h]) / double(flyTotal[h]);
			if (t > 1.0) t = 1.0;

			// LINEAR, because a thrown object has constant horizontal speed.
			//
			// This was a cubic ease-out and it was wrong twice over. A parabola
			// does not decelerate horizontally -- only gravity acts on it, and
			// gravity is vertical. And the numbers were brutal: over a 12-tic
			// flight from 512 units it covered 23% of the distance in the FIRST
			// TIC, which is 121 m/s.
			//
			// Worse, it destroyed the arc. The lift peaked at t=0.5, by which
			// point the ease-out had already carried the object 88% of the way
			// there -- so the whole hump happened inside the last 13% of the
			// distance. It was not an arc, it was a straight line with a hook on
			// the end.
			// ACCELERATES. Starts slow, picks up speed -- the thing is being
			// PULLED, and a pull that begins at full speed reads as a teleport
			// with a delay rather than as something taking hold of an object.
			//
			// t^2 by default. The old curve was the exact opposite -- a cubic
			// ease-OUT, fastest at the instant of launch, which is where the
			// 121 m/s first tic came from.
			double acc = RS_Reach.Num("rs_dgrab_accel", p, 1.6);
			if (acc < 0.25) acc = 0.25;
			double e = t ** acc;

			// HOMES TO WHERE YOUR HAND IS NOW, re-read every tic, not to where
			// it was when you squeezed. Over a third of a second your hand has
			// moved, and an object flying to a stale point arrives beside it.
			Vector3 palm = RS_Reach.Centre(pmo, p, h);

			Vector3 pos = flyStart[h] + (palm - flyStart[h]) * e;

			// The lift, applied on top of the straight line. Zero at both ends
			// and highest in the middle -- sin over 0..180 does that with no
			// special-casing at either end. It is what makes the object come UP
			// to you over the floor between rather than dragging through it.
			// THE PARABOLA. 4h*t*(1-t) is the canonical one: zero at both ends,
			// peak of exactly h at the midpoint, quadratic in between -- the
			// shape gravity actually makes. sin(180t) was a sine hump: close
			// enough to look right written down, not the same curve.
			//
			// Height is a FRACTION OF THE LAUNCH DISTANCE, so the arc keeps its
			// shape at every range rather than a long pull reading flat and a
			// short one reading as a lob. That is what makes near and far feel
			// like the same gesture.
			// KEYED ON e, NOT t, and that is the difference between an arc and a
			// swoop. e is how far along the PATH it is; t is how far through the
			// clock. Key the height on time while the travel accelerates and the
			// peak lands a quarter of the way along in space -- the object
			// leaps up beside itself and then falls the whole way to you.
			//
			// On e, the shape in SPACE is a clean symmetric parabola whatever
			// the speed curve is doing, and the acceleration is free to be
			// whatever feels right without bending the arc out of shape.
			// Decided at launch by MeasureArc against the whole route, not
			// recomputed here from the distance alone. The old line could not
			// know what was overhead, so a pull under a low ceiling asked for an
			// arc that did not fit and got squashed flat by the clamp below --
			// which is a drag along the floor, not a flight.
			double arcH = flyArc[h];
			pos.z += 4.0 * arcH * e * (1.0 - e);

			// TRYMOVE, NOT SETORIGIN. The object is a real thing crossing the
			// room: it clips doorframes, and it can reach your body. SetOrigin
			// is a write, not a move -- it tests nothing, so the old flight
			// passed through walls and through you, and arrival was
			// unconditional. Nothing could ever be missed.
			//
			// Z first, then XY, for the same reason CarryOne does it: TryMove
			// tests at the actor's CURRENT height.
			//
			// CLAMPED AGAINST THE ROOM, and without this the arc is what breaks
			// the pull. Height is a FRACTION of the launch distance and nothing
			// bounded it -- a 300-unit pull lifts a barrel 45 units, putting its
			// top near 87, which is fine under a 128 ceiling and jammed under a
			// doorway or a low room. TryMove then refuses, the flight Aborts,
			// the flags go back and gravity drops it: the object hops and
			// settles instead of sailing, and it does so INTERMITTENTLY,
			// depending only on what the ceiling happens to be between you and
			// it. Confirmed from a headset log -- "lost ExplosiveBarrel --
			// blocked in flight" on some pulls and not others.
			//
			// The same clamp CarryOne already applies for the same reason, and
			// it is the arc that gives way rather than the pull: a flatter
			// trajectory under a low ceiling is a pull that works, while the
			// prettier arc is a pull that fails.
			double flyZ = pos.z - a.Height * 0.5;
			double lo = a.floorz;
			double hi = a.ceilingz - a.Height;
			if (hi < lo) hi = lo;
			a.SetZ(clamp(flyZ, lo, hi));
			bool moved = a.TryMove((pos.x, pos.y), 1);

			// LIFT IT OUT BEFORE DRAGGING IT SIDEWAYS.
			//
			// A blocked FIRST tic is not the object hitting something on the way
			// over -- it has not gone anywhere yet. It is the object still
			// standing where it was found, in a space too tight to move
			// sideways out of. Confirmed 2026-08-30: twelve blocked pulls, all
			// but two on tic 1, all with zclamp=0, and every one of them a
			// radius-20 pickup. A barrel is radius 10 and was never blocked
			// once.
			//
			// That is also the whole of "map-placed clips will not pull but
			// dropped ones will". Nothing differs about the clips -- a mapper
			// puts ammo in alcoves and corners and against walls, where a
			// 40-unit-wide box has nowhere to go, while a clip dropped by a
			// dying zombieman is lying in open floor.
			//
			// So: try again a little higher, the way a hand would. Three steps
			// covers a step, a kerb and a low shelf; beyond that the object is
			// genuinely walled in and the pull SHOULD fail, because a pull that
			// can reach through geometry is the thing TryMove is here to stop.
			//
			// Only on failure, so nothing that was already moving pays for it,
			// and the Z is put back when a lift does not help -- otherwise a
			// refused pull would leave the object hanging above where it sat.
			if (!moved)
			{
				double keepZ = a.Pos.z;
				for (int lift = 1; lift <= 3 && !moved; lift++)
				{
					double tryZ = keepZ + lift * 6.0;
					if (tryZ + a.Height > a.ceilingz) break;
					a.SetZ(tryZ);
					moved = a.TryMove((pos.x, pos.y), 1);
				}
				if (!moved) a.SetZ(keepZ);
			}

			a.Vel = (0, 0, 0);

			// BLOCKED. It hit geometry on the way over, so it stops there and
			// falls. That is a miss, and a miss is what makes catching mean
			// anything.
			if (!moved)
			{
				// WHERE AND WHEN, not just that it happened.
				//
				// "Blocked in flight" is true of an object that died on its
				// first tic still sitting on its own floor, and of one that
				// crossed most of the room and clipped a doorframe -- and those
				// are completely different bugs. Dying on tic 0 or 1 means it
				// never left, which points at the launch position or the Z
				// clamp rather than at anything it hit on the way.
				//
				// zclamp reports whether the arc was squashed by the room this
				// tic: if the height it wanted is not the height it got, the
				// object is being dragged along a surface instead of flying,
				// which is what a hop looks like from the outside.
				if (RS_Reach.Flag("rs_hand_trace", p, true))
					Console.Printf("[RSPULL] hand %d lost %s -- blocked on tic %d/%d  at (%.0f %.0f %.0f)  wanted z=%.0f got z=%.0f  floorz=%.0f ceilz=%.0f  zclamp=%d",
						h, a.GetClassName(), flyTic[h], flyTotal[h],
						a.Pos.x, a.Pos.y, a.Pos.z,
						flyZ, a.Pos.z, a.floorz, a.ceilingz,
						(flyZ < lo || flyZ > hi) ? 1 : 0);
				Abort(h);
				continue;
			}

			// END OVER END, and it is one line because the three renderflags set in
			// Start did all the work -- see SaveTumble.
			//
			// KEYED ON t, NOT ON e, and that is the opposite choice from the arc
			// height directly above. e is the travel curve and it ACCELERATES:
			// roll on e and the barrel hangs almost still at launch and whips
			// round at the end, which reads as the pull spinning it up. A thing
			// tumbling through the air turns at a CONSTANT rate, and a constant
			// rate is linear in TIME, which is what t is.
			//
			// Turns across the whole flight rather than turns per second, for the
			// same reason the arc is a fraction of the distance rather than a
			// number of units: near and far pulls then look like the same gesture
			// instead of the long one reading as a lazy roll and the short one as
			// a blur.
			//
			// Nothing smooths this and nothing should. +INTERPOLATEANGLES hands
			// it to the renderer's own deltaangle lerp; a second smoother here
			// would only ever disagree with it.
			if (flyTurns[h] != 0)
				a.Roll = flySavedRoll[h] + flyTurns[h] * 360.0 * t;

			if (t < 1.0) continue;

			// ARRIVED. Hold it on the palm rather than resolving here, so the
			// catch test -- which runs EARLIER in the tick order than this
			// handler -- gets real looks at the real arrival position. See
			// flyHold's own note for why resolving in this pass made the catch
			// impossible past arm's reach.
			//
			// Position keeps updating through the hold because t is clamped at
			// 1.0 above, so e is 1.0 and the object re-solves onto the live
			// palm every tic -- it follows your hand while you close on it
			// instead of hanging at the point it happened to arrive.
			if (flyHold[h] < CATCH_HOLD_TICS)
			{
				flyHold[h]++;
				continue;
			}

			// THE ARC RAN OUT AND YOU DID NOT CLOSE YOUR HAND. It hits you.
			//
			// This used to test the object against your BODY every tic and
			// resolve there -- which could not work, and made catching
			// impossible rather than merely hard. Your radius plus a medikit's
			// is 36 map units, over a metre, and the object is flying to your
			// PALM, which is always well inside that. The impact fired before
			// the thing ever reached your hand: the catch window closed before
			// it opened.
			//
			// It resolves at the END of the arc instead, which is also the only
			// place it means anything -- the whole point is that missing the
			// catch is not a dropped ball, it is the medikit healing you, the
			// ammo box arming you, the barrel hurting.
			//
			// Explicit, not left to Doom's touch check: an item moving into a
			// STATIONARY player never fires P_TouchSpecialThing, because that
			// runs when the PLAYER moves into a special and not the reverse. A
			// perfect pull at someone standing still would pass through them
			// and wait forever.
			Impact(a, pmo, p, h);
		}
	}

	// IT HIT YOU. Resolve it as whatever it is.
	private void Impact(Actor a, PlayerPawn pmo, PlayerInfo p, int h)
	{
		flyActor[h] = null;
		flyHold[h]     = 0;
		a.bSPECIAL    = flySavedSpecial[h];
		a.bNOGRAVITY  = flySavedNoGrav[h];
		// Put back BEFORE the resolve below. Impact is where a missed pull
		// becomes a pickup or a hit, and both of those are ordinary Doom
		// interactions that have to happen to an ordinary Doom actor.
		a.bTHRUACTORS = flySavedThruActors[h];
		a.A_SetSize(flySavedRadius[h], flySavedHeight[h]);
		// And the same for the tumble, before the resolve. A barrel that survives
		// the hit is an ordinary barrel again from here on, standing the way up
		// it was standing before you pulled it.
		RestoreTumble(h, a);
		a.Vel = (0, 0, 0);

		bool dbg = RS_Reach.Flag("rs_hand_debug", p, true);

		// A MISS JUST DROPS IT. There is no other outcome, and there is no
		// longer a switch to ask for one.
		//
		// The original behaviour resolved a missed catch as a real event: the
		// medikit healed you, the ammo box armed you, the barrel hurt you. The
		// argument was that missing should cost something. What it actually
		// meant was that you could not pull a medikit ACROSS A ROOM TO CARRY
		// IT -- reaching for one at range and fumbling it spent the item where
		// it stood, and there was no way to ask for the pull without also
		// accepting the pickup.
		//
		// That was already the default (rs_dgrab_impact 0). Now the branch is
		// gone entirely, and removing the OPTION is the point rather than a
		// tidy-up: an interaction whose failure mode is "you take damage" is
		// one people stop using, and it does not matter that the damage is off
		// by default if the mechanic still reads as risky. Pulling something
		// toward you should be as free to get wrong as picking it up is.
		//
		// It lands as an ordinary object, still there, still walk-over-able,
		// still grabbable by hand. Every flag was put back above, so it is a
		// completely ordinary Doom actor from here -- gravity included, which
		// is what carries it down to your feet from the palm it was flying to.
		if (dbg) Console.Printf("[RSPULL] %s arrived uncaught -- dropped", a.GetClassName());
	}

	override void WorldLoaded(WorldEvent e) { AbortAll(); }
	override void WorldUnloaded(WorldEvent e) { AbortAll(); }
}
