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
	private Array<Actor>  fLastHit;   // who this object last hit, so it cannot grind
	private Array<int>    fLastHitTic;
	// Where it left from, for the telemetry line at the other end. A distance
	// is the one number that says whether a throw went anywhere, and it cannot
	// be recovered after the fact.
	private Array<double> fStartX;
	private Array<double> fStartY;

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

	// The same read, reachable from the telemetry report, which wants to state
	// the settings a session actually ran with rather than the ones anybody
	// assumed. A log that does not say what gravity was is a log that cannot
	// explain a throw.
	static double TelemNum(String n, double d) { return SNum(n, d); }

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
		RS_Telem.Line(String.Format("caught obj=%s kg=%.3f airtics=%d",
			a.GetClassName(), f.fMass[i], f.fTics[i]));
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

	// ---- CATCHING ------------------------------------------------------------
	//
	// The nearest thing in the air to a given point, or null. Everything about
	// WHERE a hand is stays out of here: this takes a position and a radius and
	// answers a question about the flight list, which is the only part a
	// machine without a controller can also agree on.
	//
	// WHY A SEPARATE RADIUS FROM AN ORDINARY GRAB. A thrown object crosses a
	// hand-sized reach volume in about two tics. Asking the player to close
	// their fingers inside that window is asking them to do something nobody
	// can do, and it reads as the catch being broken rather than as being
	// fast. So a thing in flight is catchable from further out, and the reach
	// test does not apply to it at all.
	//
	// YOU CANNOT CATCH YOUR OWN THROW, for a moment. Without this, the same
	// held grip that released an object takes it straight back on the next tic
	// and it never leaves the hand -- and the player cannot tell whether they
	// threw it, because from the inside nothing happened. The guard runs from
	// the LAUNCH, so it is the same count on every machine.
	//
	// A teammate's throw has no such guard, and needs none: catching what
	// someone else threw you is the whole point.
	static Actor CatchableAt(Vector3 point, double radius, Actor catcher, int guardTics)
	{
		let f = Get();
		if (!f) return null;

		let held = RS_Held.Get();
		Actor best = null;
		double bestD = radius * radius;

		for (int i = 0; i < f.fActor.Size(); i++)
		{
			Actor a = f.fActor[i];
			if (!a || a.bDESTROYED) continue;
			if (catcher && f.fThrower[i] == catcher && f.fTics[i] <= guardTics) continue;

			// Held by somebody already -- a second hand arriving on an object
			// in flight is a grab, not a catch, and RS_Held decides that.
			// IsHeld, not IsHeldBy: a barrel in a REMOTE player's hands must
			// not read as free here either.
			if (held && held.IsHeld(a)) continue;

			Vector3 d = a.Pos - point;
			double dd = d dot d;
			if (dd < bestD) { bestD = dd; best = a; }
		}
		return best;
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
			fLastHit[i] = null;
			fLastHitTic[i] = 0;
			fStartX[i] = a.Pos.x;
			fStartY[i] = a.Pos.y;
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
		fLastHit.Push(null);
		fLastHitTic.Push(0);
		fStartX.Push(a.Pos.x);
		fStartY.Push(a.Pos.y);

		// A THROWN VOXEL STAYS A VOXEL UNTIL IT LANDS. With r_voxels_mode "held
		// & grabbed only", VoxelOverride is the only thing keeping the object
		// drawn as its voxel, and handing the pre-grab value back at release
		// popped a thrown barrel into its sprite the instant it left the
		// fingers. Render state only: nothing in the playsim reads it, and
		// whether a voxel pack is even loaded is a local choice.
		if (flags & FLIGHT_VOXEL) a.VoxelOverride = true;

		if (SNum("rs_throw_debug", 0) > 0)
			Console.Printf("[RSFLIGHT] push %s at index %d of %d: %.3f kg, drag %.4f, flags %d",
				a.GetClassName(), fActor.Size() - 1, fActor.Size(), massKg, drag, flags);
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
		fLastHit.Delete(i);
		fLastHitTic.Delete(i);
		fStartX.Delete(i);
		fStartY.Delete(i);
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

			// WHAT IT JUST HIT. Before anything below touches the remembered
			// velocity, because that velocity is the only surviving record of
			// how fast the object was going into the move that has just
			// happened -- see the note where it is stored.
			Impact(i, a);
			if (!a || a.bDESTROYED) { Drop(i); continue; }

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
			if ((resting && fTics[i] > 4) || fTics[i] > maxTics)
			{
				RS_Telem.Line(String.Format("land obj=%s kg=%.3f tics=%d ran=%.1fm%s",
					a.GetClassName(), fMass[i], fTics[i],
					(a.Pos.xy - (fStartX[i], fStartY[i])).Length() / RS_Mass.UNITS_PER_METRE,
					fTics[i] > maxTics ? " TIMEOUT" : ""));
				Drop(i);
				continue;
			}
		}
	}


	// ---- hitting things -------------------------------------------------------
	//
	// THE VELOCITY IS ALREADY GONE BY THE TIME YOU CAN SEE THE HIT.
	// P_XYMovement zeroes Vel when a move is refused, so an object that has just
	// slammed into an imp reports a speed of zero. Everything below reads the
	// remembered velocity instead: the one the step that just ran moved with.
	//
	// AND BlockingMobj IS NOT ENOUGH ON ITS OWN. A non-solid pickup never sets
	// it, and neither does a barrel dropped straight onto a head. So the box is
	// swept for anything overlapping, every step, and the blocking actor is only
	// one of the candidates.
	//
	// NOT SOLID IN FLIGHT. Making a thrown object SOLID would let the overlap
	// test go away, and it was considered and refused: thrown objects would jam
	// doors and body-block the player, and worse, a SOLID object stops dead on
	// contact -- which means P_XYMovement zeroes the very velocity the momentum
	// transfer needs. It would break this function, not just add risk.
	// (Designer, 2026-09-28.)
	private void Impact(int i, Actor a)
	{
		// massObj / massTarget, NOT m and M. ZSCRIPT IDENTIFIERS ARE
		// CASE-INSENSITIVE, so `double M = ...` below was the SAME VARIABLE as
		// `m` and silently overwrote the object's mass with the target's. The
		// physics then read a 0.35 kg clip as 100 kg: it did 200 damage (the
		// cap) to an imp and threw it a metre and a half. It compiled without a
		// word and the arithmetic was correct all along -- only the inputs were
		// the same number twice. Caught 2026-09-28 by printing both.
		double massObj = fMass[i];
		if (massObj <= 0) return;

		Vector3 lastVel = (fVelX[i], fVelY[i], fVelZ[i]);
		double sp = lastVel.Length();
		if (sp <= 0) return;

		double minMS = SNum("rs_throw_dmg_min", 2.0);
		if (RS_Mass.UnitsPerTicToMetresPerSec(sp) < minMS) return;

		Actor thrower = fThrower[i];
		int guard = int(SNum("rs_throw_hit_tics", 8));
		double e = clamp(SNum("rs_throw_restitution", 0.3), 0.0, 1.0);

		let it = BlockThingsIterator.Create(a, a.Radius + sp + 8.0);
		while (it.Next())
		{
			Actor t = it.thing;
			if (!t || t == a) continue;
			if (!t.bSHOOTABLE && !t.bSOLID) continue;
			if (t.Health <= 0 && t.bSHOOTABLE) continue;

			// YOUR OWN THROW CANNOT HIT YOU, for the first few tics. The step
			// clear in RS_Held.Release moves the object out of your cylinder;
			// this is the other half, for the barrel that comes back down on
			// the head of the person who lobbed it straight up. After the
			// guard it is fair game, which is funnier and also correct.
			if (t == thrower && fTics[i] <= guard) continue;

			// NEVER THE SAME TARGET TWICE IN A ROW, with no time limit on it.
			//
			// This was a ten-step window and that was not enough. An object
			// that comes to rest against a monster keeps overlapping it, and
			// the monster keeps walking into the object, so the relative speed
			// never quite falls to nothing: a thrown clip hit the same imp six
			// times on the way to stopping. Harmless there because each hit
			// rounded to under a point, but the same slide with a crate would
			// have ground the imp down for free.
			//
			// "In a row" rather than "ever", so a barrel ploughing through a
			// line still hits each of them, and can come back to the first one
			// after touching a second.
			if (fLastHit[i] == t) continue;

			// REALLY OVERLAPPING, in Z as well. BlockThingsIterator works on the
			// 2D blockmap, so without this a barrel rolling under a walkway
			// hits whatever is standing on it.
			if (a.Pos.z + a.Height <= t.Pos.z || t.Pos.z + t.Height <= a.Pos.z) continue;

			double massTarget = RS_Mass.Kg(t);
			if (massTarget <= 0) massTarget = 1.0;

			Vector3 vRel = lastVel - t.Vel;
			double rel = vRel.Length();
			if (rel <= 0) continue;
			Vector3 n = vRel / rel;

			// MOMENTUM, BOTH WAYS. A heavy target barely moves and a light one
			// never leaves faster than it was hit -- both fall out of the mass
			// ratio rather than being special-cased.
			if (!t.bDONTTHRUST)
			{
				Vector3 dT = n * ((1.0 + e) * (massObj / (massObj + massTarget)) * rel);
				if (dT.Length() > 32.0) dT = dT / dT.Length() * 32.0;   // the engine's own kickback ceiling
				t.Vel += dT;
			}
			a.Vel -= n * ((1.0 + e) * (massTarget / (massObj + massTarget)) * rel);

			// ENERGY, IN JOULES, SCALED. Half m v squared with v in real metres
			// per second -- converted with the FIXED world scale, never
			// vr_vunits_per_meter, which is a personal comfort setting and
			// would make the same throw hurt differently on two machines.
			double ms  = RS_Mass.UnitsPerTicToMetresPerSec(rel);
			double dmg = 0.5 * massObj * ms * ms * SNum("rs_throw_dmg_scale", 0.1);

			// THE CAP, AND WHY IT IS ONE NUMBER AND NOT TWO.
			//
			// A cap proportional to the target's own health was proposed and is
			// wrong: an imp has 60 hit points, so any sane fraction of it stops
			// a thrown barrel killing an imp -- which is the entire feature. A
			// flat ceiling does what was actually asked. A boss has thousands
			// of hit points and 200 cannot one-shot it; an imp has sixty and
			// 200 very much can. (Designer, 2026-09-28: "add a damage cap so a
			// fast barrel can't one-shot a boss".)
			dmg = min(dmg, SNum("rs_throw_dmg_cap", 200.0));

			// WHAT THE ARITHMETIC ACTUALLY DID. Off by default. An impact
			// resolves in one step and leaves nothing behind but a health
			// number, so when that number is wrong there is no other way to
			// see which of the five inputs produced it.
			RS_Telem.Line(String.Format("hit obj=%s objkg=%.3f tgt=%s tgtkg=%.1f mps=%.2f dmg=%.0f tics=%d",
				a.GetClassName(), massObj, t.GetClassName(), massTarget, ms, dmg, fTics[i]));

			if (t.bSHOOTABLE && dmg >= 1)
			{
				// DamageMobj, not a raw health subtraction: it credits the kill
				// to whoever threw it and plays the pain frame, which is the
				// reaction a sprite can actually show.
				//
				// DMG_THRUSTLESS because the push is handled above, from the
				// object's mass. Without it ApplyKickback adds a second shove
				// derived from the THROWER'S CURRENT WEAPON, so the barrel
				// would hit harder while you happen to be holding a rocket
				// launcher.
				t.DamageMobj(a, thrower, int(dmg), 'Thrown', DMG_THRUSTLESS);
			}

			fLastHit[i] = t;
			fLastHitTic[i] = level.maptime;

			// AND THE OBJECT ITSELF, if MASSDEF said so. A barrel thrown into a
			// crowd goes off on contact instead of landing among them intact.
			if (fFlags[i] & FLIGHT_EXPLODE)
			{
				double hard = SNum("rs_throw_explode_ms", 4.0);
				if (ms >= hard)
				{
					a.DamageMobj(a, thrower, max(int(dmg), 1000), 'Thrown', DMG_THRUSTLESS);
					return;   // the entry is dropped by the caller on the next line
				}
			}

			// One target per step. The next step sweeps again, so a barrel
			// through a line still reaches all of them -- it just does not
			// resolve four collisions in one instant with one velocity.
			return;
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
		fLastHit.Clear();
		fLastHitTic.Clear();
		fStartX.Clear();
		fStartY.Clear();
	}
}
