// ============================================================================
// WHAT IS IN THE AIR, AND WHAT THE AIR DOES TO IT.
//
// Everything that leaves a hand is tracked here until it comes to rest: thrown,
// lobbed, or simply let go of. A single list, one entry per object, ticked once
// per WORLD step.
//
// WHY EVERY RELEASE AND NOT EVERY THROW. Thrown objects fall at a corrected
// gravity (see below) and dropped ones would fall at Doom's. Set a medikit down
// while walking and it drops like a stone; toss the same medikit and it floats.
// Two rates for one object reads as a bug, and the player is right -- it is one.
// So the drop/throw threshold decides only WHICH velocity an object leaves with.
// It does not decide how it falls. (Owner + designer, 2026-09-28.)
//
// ---------------------------------------------------------------------------
// GRAVITY IS ADDED BACK, NOT TURNED DOWN. The obvious implementation is
// `a.Gravity *= rs_throw_gravity` on release and put it back on landing. Do not
// do that. Actor.Gravity is SAVED STATE: quicksave mid-flight and the object
// goes into the savegame carrying a third of its gravity, this tracker does not
// (it is rebuilt empty), and nothing ever puts it back. The object falls wrong
// for the rest of the game and there is no way to tell why.
//
// So nothing on the actor is modified. Each world step this adds back the part
// of gravity we did not want:
//
//     Vel.Z += GetGravity() * (1 - rs_throw_gravity)
//
// and the engine subtracts the whole of it during the step. The net is the
// fraction we asked for, and the only state is in this list. Lose the list --
// to a save, a load, a hub change, a mod unloading -- and every object simply
// falls at Doom's gravity again. That is a harmless failure, which is the only
// kind worth designing for.
//
// THE CONDITIONS ARE THE ENGINE'S, COPIED EXACTLY. AActor::FallAndSink
// (p_mobj.cpp) subtracts gravity only when `Z() > floorz + 2`, the actor is not
// NOGRAVITY, and it is not in water -- a submerged non-player sinks at
// WATER_SINK_SPEED instead and gets no gravity at all. Add back without those
// three and a crate resting on the floor is pushed gently upward forever, and a
// barrel in a nukage pool climbs out. They are checked here in the same order.
//
// ---------------------------------------------------------------------------
// WORLDSTEP, NOT WORLDTICK, and this is the whole reason WorldStep exists.
// WorldTick fires every REAL tic; WorldStep fires once per WORLD step, after
// it ("Engine docs/SLOWMO_PLAN.md", src/p_tick.cpp). At full speed they are the
// same thing. In slow motion they are not: a flight ticked on WorldTick would
// have gravity added back five times for every one time the engine took it off,
// and everything in the air would rise. Hooked here, a thrown barrel slows with
// the world for free and no slow-mo code has to know this file exists.
//
// After the step rather than before it costs one tic of lag on the correction,
// which is a fixed offset and does not accumulate. Being right in slow motion
// is worth more than a tic.
//
// ---------------------------------------------------------------------------
// GENERAL ON PURPOSE. Nothing in here knows about hands. Launch() takes a
// velocity, a mass, a drag and some flags; RS_Held is merely its first caller.
// A grenade, a gib, a severed limb or a physics prop from another package can
// push into the same list without this file changing. Mass and drag are LOOKED
// UP BY THE CALLER (RS_Mass) rather than here, so a caller that already knows
// its own mass does not pay for a second lookup and does not have to agree with
// ours.
//
// NETPLAY. Everything below is plain playsim: it reads actor state, a server
// cvar and a named playsim RNG, and nothing else. No controller, no VR pose, no
// user cvar, no consoleplayer. Given the same release on two machines it does
// the same thing on both, which is the entire contract
// ("Engine docs/CROSSPLATFORM_COOP_RULE.md").
// ============================================================================

class RS_Flight : EventHandler
{
	// ---- flags a caller can ask for ---------------------------------------

	const FLIGHT_FLUTTER = 0x1;   // a light flat thing: wobbles as it falls
	const FLIGHT_EXPLODE = 0x2;   // a hard impact damages the object itself
	const FLIGHT_VOXEL   = 0x4;   // was drawn as its voxel when it left the hand

	// ---- the list ----------------------------------------------------------
	//
	// Parallel arrays rather than a data class, matching the thrown-voxel list
	// this replaces. Vector3 is not a dynamic-array element type in ZScript, so
	// the remembered velocity is three doubles; that is not a style choice.

	private Array<Actor>  fActor;
	private Array<Actor>  fThrower;
	private Array<double> fMass;      // kg
	private Array<double> fDrag;      // per (unit/tic)
	private Array<int>    fFlags;
	private Array<int>    fTics;      // world steps since launch
	private Array<double> fVelX;      // the velocity the NEXT step will move with
	private Array<double> fVelY;
	private Array<double> fVelZ;
	private Array<bool>   fVoxelSaved;

	static RS_Flight Get()
	{
		return RS_Flight(EventHandler.Find("RS_Flight"));
	}

	// ---- server policy -----------------------------------------------------
	//
	// Server cvars, read with a null player: a flight must look the same on
	// every machine, so nothing here may be a per-player preference. Defaults
	// repeated in each call so an absent CVARINFO is a known number rather than
	// a zero -- an undeclared cvar in ZScript is not an error, it is 0.0, and a
	// gravity scale of zero would leave everything hanging in the air.

	private static double SNum(String n, double d)
	{
		let c = CVar.GetCVar(n, null);
		return c ? c.GetFloat() : d;
	}

	// ---- the door ----------------------------------------------------------

	// Push an object into the air. Safe to call on something already tracked --
	// the entry is refreshed rather than duplicated, which is what a catch and
	// an immediate re-throw does.
	//
	// `vel` is written to the actor here. The caller has already stepped it
	// clear of whatever threw it; this is the last word on where it is going.
	static void Launch(Actor a, Vector3 vel, double massKg, double drag,
	                   int flags = 0, Actor thrower = null)
	{
		let f = Get();
		if (!f || !a) return;
		f.Push(a, vel, massKg, drag, flags, thrower);
	}

	// Take an object out of the air. Call this BEFORE anything saves the
	// object's flags -- a catch that saves flags first and ends the flight
	// second has already recorded our in-flight state as the object's own.
	// Returns the voxel value the object had before it was ever thrown, so a
	// catch can restore it; `current` comes back for anything not tracked.
	static bool End(Actor a, bool current = false)
	{
		let f = Get();
		if (!f || !a) return current;
		int i = f.fActor.Find(a);
		if (i >= f.fActor.Size()) return current;
		bool saved = f.fVoxelSaved[i];
		bool wasVoxel = (f.fFlags[i] & FLIGHT_VOXEL) != 0;
		f.Drop(i);
		return wasVoxel ? saved : current;
	}

	static bool InFlight(Actor a)
	{
		let f = Get();
		if (!f || !a) return false;
		return f.fActor.Find(a) < f.fActor.Size();
	}

	// The mass an object is flying with, for whatever has to answer to it --
	// an impact, a catch, a haptic. Zero if it is not in the air.
	static double MassOf(Actor a)
	{
		let f = Get();
		if (!f || !a) return 0.0;
		int i = f.fActor.Find(a);
		return (i < f.fActor.Size()) ? f.fMass[i] : 0.0;
	}

	// The velocity the object carried into this step, which is NOT the same as
	// a.Vel once P_XYMovement has refused a move and zeroed it. Anything asking
	// "how hard did that hit" wants this one.
	static Vector3 LastVelOf(Actor a)
	{
		let f = Get();
		if (!f || !a) return (0, 0, 0);
		int i = f.fActor.Find(a);
		if (i >= f.fActor.Size()) return (0, 0, 0);
		return (f.fVelX[i], f.fVelY[i], f.fVelZ[i]);
	}

	static Actor ThrowerOf(Actor a)
	{
		let f = Get();
		if (!f || !a) return null;
		int i = f.fActor.Find(a);
		return (i < f.fActor.Size()) ? f.fThrower[i] : null;
	}

	static int TicsOf(Actor a)
	{
		let f = Get();
		if (!f || !a) return -1;
		int i = f.fActor.Find(a);
		return (i < f.fActor.Size()) ? f.fTics[i] : -1;
	}

	// ---- the list, kept -----------------------------------------------------

	private void Push(Actor a, Vector3 vel, double massKg, double drag,
	                  int flags, Actor thrower)
	{
		a.Vel = vel;

		int i = fActor.Find(a);
		if (i < fActor.Size())
		{
			// Already in the air: refresh in place. The voxel value it came in
			// with is kept, because that is the pre-grab value and a second
			// throw must not overwrite it with the flight's own.
			fThrower[i] = thrower;
			fMass[i]    = massKg;
			fDrag[i]    = drag;
			fFlags[i]   = (fFlags[i] & FLIGHT_VOXEL) | flags;
			fTics[i]    = 0;
			fVelX[i]    = vel.x; fVelY[i] = vel.y; fVelZ[i] = vel.z;
			return;
		}

		fActor.Push(a);
		fThrower.Push(thrower);
		fMass.Push(massKg);
		fDrag.Push(drag);
		fFlags.Push(flags);
		fTics.Push(0);
		fVelX.Push(vel.x);
		fVelY.Push(vel.y);
		fVelZ.Push(vel.z);
		fVoxelSaved.Push((flags & FLIGHT_VOXEL) != 0 ? a.VoxelOverride : false);

		// A THROWN VOXEL STAYS A VOXEL UNTIL IT LANDS. With r_voxels_mode "held
		// & grabbed only", VoxelOverride is the only thing keeping the object
		// drawn as its voxel, and handing the pre-grab value back at release
		// popped a thrown barrel into its sprite the instant it left the
		// fingers. Render state only: nothing in the playsim reads it, and
		// whether a voxel pack is even loaded is a local choice.
		if (flags & FLIGHT_VOXEL) a.VoxelOverride = true;
	}

	private void Drop(int i)
	{
		// The voxel it was drawn as during the flight goes back to what it was
		// before the grab. A caller that wants it kept (a catch) reads the
		// return of End() and sets it again itself.
		Actor a = fActor[i];
		if (a && (fFlags[i] & FLIGHT_VOXEL)) a.VoxelOverride = fVoxelSaved[i];

		fActor.Delete(i);
		fThrower.Delete(i);
		fMass.Delete(i);
		fDrag.Delete(i);
		fFlags.Delete(i);
		fTics.Delete(i);
		fVelX.Delete(i);
		fVelY.Delete(i);
		fVelZ.Delete(i);
		fVoxelSaved.Delete(i);
	}

	// ---- one world step -----------------------------------------------------

	override void WorldStep()
	{
		if (fActor.Size() == 0) return;

		// Once per step, not once per object. GetCVar is a hash lookup and the
		// answer cannot change between two objects in the same step.
		double gscale  = SNum("rs_throw_gravity", 0.27);
		double flutter = SNum("rs_throw_flutter", 0.35);
		int    maxTics = int(SNum("rs_throw_maxtics", 1400));

		for (int i = fActor.Size() - 1; i >= 0; i--)
		{
			Actor a = fActor[i];

			// Gone, eaten, or turned into something else mid-flight.
			if (!a || a.bDESTROYED) { Drop(i); continue; }

			fTics[i]++;

			// GRAVITY, ADDED BACK. The engine has already taken the whole of it
			// off during the step that just ran; this returns the part we did
			// not want. The three conditions are AActor::FallAndSink's own --
			// see the header.
			if (gscale < 1.0 && a.Pos.Z > a.floorz + 2 && !a.bNOGRAVITY && a.waterlevel == 0)
				a.Vel.Z += a.GetGravity() * (1.0 - gscale);

			// DRAG, DIVISIVE. `Vel -= Vel * drag` looks equivalent and is not:
			// for a light object with a large drag the subtraction overshoots
			// zero and the thing flies backwards. Dividing cannot change sign
			// at any speed, which is the only property that matters here.
			double drag = fDrag[i];
			if (drag > 0)
			{
				double sp = a.Vel.Length();
				if (sp > 0) a.Vel = a.Vel / (1.0 + drag * sp);
			}

			// FLUTTER. A newspaper or a sheet of card does not fall straight.
			// Sideways only and small -- this is a wobble, not a wind. Named
			// playsim RNG so two machines draw the same numbers; an unnamed
			// random() here would desync the moment anything used it.
			if ((fFlags[i] & FLIGHT_FLUTTER) && flutter > 0 && a.Pos.Z > a.floorz + 2)
			{
				a.Vel.x += FRandom[RSFlight](-flutter, flutter);
				a.Vel.y += FRandom[RSFlight](-flutter, flutter);
			}

			// THE VELOCITY THE NEXT STEP WILL MOVE WITH, remembered now because
			// after that step it may not exist. P_XYMovement zeroes Vel when a
			// move is refused, so by the time anything notices the object has
			// hit a wall or an imp, the number that says how hard is already
			// gone. Impact reads this, never a.Vel.
			fVelX[i] = a.Vel.x;
			fVelY[i] = a.Vel.y;
			fVelZ[i] = a.Vel.z;

			// LANDED. On the floor and no longer really moving. The two-step
			// grace is there because the first step after a throw can legally
			// show the object still inside the floor slab it was standing on.
			bool resting = (a.Pos.Z <= a.floorz + 1.0) && (a.Vel.Length() < 1.0);
			if ((resting && fTics[i] > 4) || fTics[i] > maxTics) { Drop(i); continue; }
		}
	}

	// ---- the level goes away ------------------------------------------------
	//
	// Both ends, deliberately. WorldLoaded covers a savegame load, a new game
	// and arriving in a hub; WorldUnloaded covers leaving one. An Actor pointer
	// from a level that no longer exists is the kind of thing that is fine for
	// a hundred runs and then is not.
	//
	// Nothing needs restoring on the way out -- that is the point of adding
	// gravity back rather than turning it down. Anything still in the air when
	// the list is cleared simply finishes its fall at Doom's own rate.

	override void WorldLoaded(WorldEvent e) { Clear(); }
	override void WorldUnloaded(WorldEvent e) { Clear(); }

	private void Clear()
	{
		fActor.Clear();
		fThrower.Clear();
		fMass.Clear();
		fDrag.Clear();
		fFlags.Clear();
		fTics.Clear();
		fVelX.Clear();
		fVelY.Clear();
		fVelZ.Clear();
		fVoxelSaved.Clear();
	}
}
