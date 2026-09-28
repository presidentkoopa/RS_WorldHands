// ============================================================================
// A THROW WITH NO ARM ATTACHED.
//
// Everything after the fingers open is plain playsim: mass, gravity, drag,
// flight, impact. None of it needs a headset, a controller or a hand. The only
// thing that ever needed one was MEASURING the throw -- and that measurement
// arrives at RS_Held.Release as three numbers.
//
// So this puts three numbers in by hand. It spawns an object, takes hold of it,
// and releases it with a velocity computed from a speed and an angle. From
// there it is the same code path a real throw takes, on the same seam the
// network uses (rs_handnet.zs sends exactly this and no more), which is why
// this is a real test and not a mock: the half it skips is the half that cannot
// desync, and the half it exercises is all of the rest.
//
// WHAT IT IS FOR. Being able to answer "does a 0.3 kg clip thrown at 8 m/s go
// as far as it should" without putting a headset on. It prints the measured
// range beside the range the arithmetic says to expect, so a wrong mass, a
// wrong gravity scale or a wrong drag shows up as two numbers that disagree
// rather than as a feeling that something is off.
//
// INERT UNLESS ASKED. rs_throwtest is 0 and nothing below runs. It ships
// because it is as useful from the console mid-game as it is in a boot test,
// and because a test that lives somewhere else rots.
//
// NETPLAY. The netevent path is a network event, so every machine runs it. The
// timed path keys off a SERVER cvar and level.maptime, which are the same
// everywhere. Neither reads a controller, a pose or consoleplayer.
//
//   netevent rs-throw-test
//   rs_throwtest 200            fire once at maptime 200 (boot tests)
//   rs_throwtest_class ExplosiveBarrel
//   rs_throwtest_speed 8        metres per second of hand motion
//   rs_throwtest_pitch 20       degrees above horizontal
//   rs_throwtest_hands 2        two-handed: doubles the arm
// ============================================================================

class RS_ThrowTest : EventHandler
{
	private Actor watched;
	private int   fired;        // maptime we fired at, 0 = not armed this level
	private int   startTic;
	private Vector3 startPos;
	private double launchSpeed; // units/tic, what the object actually left at
	private double peakZ;
	private double objectKg;
	private Actor  target;       // something to throw AT, so impact is measured too
	private int    targetHP0;
	private Vector3 targetPos0;
	private bool   hitCeiling;   // the throw was cut short by the room, not by physics
	private int    touchTic;     // first step on the floor, which is not the same as stopped
	private double touchRun;     // how far it had travelled by then, in units

	static RS_ThrowTest Get() { return RS_ThrowTest(EventHandler.Find("RS_ThrowTest")); }

	private static double SNum(String n, double d)
	{
		let c = CVar.GetCVar(n, null);
		return c ? c.GetFloat() : d;
	}
	private static String SStr(String n, String d)
	{
		let c = CVar.GetCVar(n, null);
		return c ? c.GetString() : d;
	}

	override void NetworkProcess(ConsoleEvent e)
	{
		if (e.Name != "rs-throw-test") return;
		if (e.Player < 0 || e.Player >= MAXPLAYERS || !playeringame[e.Player]) return;
		Fire(e.Player);
	}

	override void WorldTick()
	{
		int at = int(SNum("rs_throwtest", 0));

		// ARMED, SAID OUT LOUD. A test that silently does nothing is worse
		// than one that fails: the run comes back green and the green means
		// "the throw never happened". Printed once, at the tic the level
		// starts counting from, so the log says what it is waiting for.
		if (at > 0 && level.maptime == 1)
			Console.Printf("[RSTHROWTEST] armed for maptime %d", at);

		if (at > 0 && fired == 0 && level.maptime == at)
		{
			fired = level.maptime;
			// consoleplayer is the only player a boot test has, and the timed
			// path exists FOR boot tests. A real multiplayer run uses the
			// netevent, which names its own player.
			Fire(consoleplayer);
		}
	}

	override void WorldLoaded(WorldEvent e) { fired = 0; watched = null; }

	// ---- the throw -----------------------------------------------------------

	private void Fire(int pnum)
	{
		if (!playeringame[pnum]) return;
		let pmo = players[pnum].mo;
		if (!pmo || !pmo.player) return;
		let p = players[pnum];

		let held = RS_Held.Get();
		if (!held) { Console.Printf("[RSTHROWTEST] no RS_Held"); return; }

		String cname = SStr("rs_throwtest_class", "ExplosiveBarrel");
		Class<Actor> cls = (Class<Actor>)(Object.FindClass(cname, "Actor"));
		if (!cls) { Console.Printf("[RSTHROWTEST] no such class: %s", cname); return; }

		// SOMETHING TO HIT, when asked. Impact is the half of this feature that
		// cannot be checked by watching an arc: knockback, damage and the kill
		// credit all happen in one step and leave nothing behind but numbers.
		target = null;
		String tname = SStr("rs_throwtest_target", "");
		if (tname != "")
		{
			Class<Actor> tcls = (Class<Actor>)(Object.FindClass(tname, "Actor"));
			if (!tcls) { Console.Printf("[RSTHROWTEST] no such target class: %s", tname); }
			else
			{
				double tdist = SNum("rs_throwtest_dist", 3.0) * RS_Mass.UNITS_PER_METRE;
				target = Actor.Spawn(tcls, pmo.Vec3Angle(tdist, pmo.angle, 0));
				if (target)
				{
					targetHP0  = target.Health;
					targetPos0 = target.Pos;
					Console.Printf("[RSTHROWTEST] target %s at %.1f m, %d hp, %.1f kg",
						tname, tdist / RS_Mass.UNITS_PER_METRE, targetHP0, RS_Mass.Kg(target));
				}
			}
		}

		double speed = SNum("rs_throwtest_speed", 8.0);
		double pitch = SNum("rs_throwtest_pitch", 20.0);
		int    hands = int(SNum("rs_throwtest_hands", 1));

		// In front of the player at about chest height, far enough out that the
		// step-clear in Release has somewhere to put it.
		//
		// AND LOW ENOUGH TO FIT. A barrel is 56 units tall and E1M1's start
		// room is 72, so spawning one 40 up buries its top in the ceiling: it
		// cannot move, it drops straight down, and the run reports a throw that
		// went nowhere. Chest height is the intent, the room has the last word.
		Actor probe = Actor.Spawn(cls, pmo.Vec3Angle(40, pmo.angle, 0));
		if (!probe) { Console.Printf("[RSTHROWTEST] %s did not spawn", cname); return; }
		double headroom = probe.ceilingz - probe.floorz - probe.Height - 4.0;
		double zoff = clamp(40.0, 0.0, max(headroom, 0.0));
		Actor a = probe;
		if (zoff > 0) a.SetZ(a.Pos.z + zoff);
		if (headroom < 8)
			Console.Printf("[RSTHROWTEST] warning: %.0f units of headroom -- this room is too low to throw in",
				headroom);

		// The same call the network applier makes. GRIPSUBJ_Magazine is what
		// the grab policy hands out for a loose prop, and the pose is the one
		// a free grab uses.
		int took = held.Take(pnum, 0, a, GRIPSUBJ_Magazine, -1, false, p);
		if (took == RS_Held.TAKE_REFUSED)
		{
			Console.Printf("[RSTHROWTEST] hand 0 refused to take %s", cname);
			a.Destroy();
			return;
		}

		// TWO HANDS, AND THE SECOND ONE HAS TO COME OFF AGAIN. The doubled arm
		// is stamped by the FIRST hand releasing (hTwoHandTic), so a test that
		// only takes with both and releases with one would be testing the
		// single-handed path while saying "two".
		if (hands >= 2)
		{
			held.Take(pnum, 1, a, GRIPSUBJ_Magazine, -1, true, p);
			held.Release(pnum, 1, pmo, p, true, (0, 0, 0));
		}

		// The hand's motion: the player's facing, pitched up. Units per tic, at
		// the fixed world scale -- never vr_vunits_per_meter, which is a
		// personal comfort setting and would make this test mean something
		// different on every machine.
		double u = RS_Mass.MetresPerSecToUnitsPerTic(speed);
		Vector3 vhand = (
			cos(pmo.angle) * cos(pitch) * u,
			sin(pmo.angle) * cos(pitch) * u,
			sin(pitch) * u);

		objectKg  = RS_Mass.Kg(a);
		startPos  = a.Pos;
		startTic  = level.maptime;
		peakZ      = a.Pos.z;
		hitCeiling = false;
		touchTic   = 0;
		touchRun   = 0;
		watched    = a;

		held.Release(pnum, 0, pmo, p, true, vhand);

		launchSpeed = a.Vel.Length();

		Console.Printf("[RSTHROWTEST] %s  %.3f kg%s  hand %.1f m/s at %.0f deg  ->  left at %.1f m/s",
			cname, objectKg, (hands >= 2 ? " two-handed" : ""), speed, pitch,
			RS_Mass.UnitsPerTicToMetresPerSec(launchSpeed));
	}

	// ---- watching it come down ------------------------------------------------
	//
	// WorldStep, so the sampling slows with the world exactly as the flight
	// does. On WorldTick a slow-motion run would print five lines per step and
	// count five tics of flight time for one.

	override void WorldStep()
	{
		if (!watched) return;

		if (watched.bDESTROYED)
		{
			Console.Printf("[RSTHROWTEST] object destroyed in flight after %d tics",
				level.maptime - startTic);
			watched = null;
			return;
		}

		peakZ = max(peakZ, watched.Pos.z);

		// THE TRAJECTORY ITSELF, when asked. A summary line can agree with the
		// arithmetic for two wrong reasons that cancel; a column of heights
		// cannot. Off by default because it is a line per world step.
		if (SNum("rs_throwtest_trace", 0) > 0 && RS_Flight.InFlight(watched))
			Console.Printf("[RSTRACE] t=%3d  z=%7.2f (floor %7.2f, +%6.2f)  vel %6.2f %6.2f %6.2f  g=%.3f",
				level.maptime - startTic, watched.Pos.z, watched.floorz,
				watched.Pos.z - watched.floorz,
				watched.Vel.x, watched.Vel.y, watched.Vel.z,
				watched.GetGravity());

		// THE ROOM, NOT THE PHYSICS. A throw that clips the ceiling loses its
		// rise and every number after it is about the map. Said out loud
		// because the first run of this test threw a clip at 45 degrees in
		// E1M1's start room, lost 3.26 u/tic of climb to the ceiling at tic 4,
		// and produced a peak height that looked exactly like broken gravity.
		if (!hitCeiling && watched.Vel.z > 0
		    && watched.Pos.z + watched.Height >= watched.ceilingz - 0.1)
			hitCeiling = true;

		// TOUCHDOWN IS NOT REST. Doom zeroes Vel.Z on the floor and the object
		// then SLIDES under friction, sometimes for as long again as it flew.
		// The flight only ends when it stops, so reporting that distance as
		// "range" quietly measures the throw plus the skid.
		if (touchTic == 0 && watched.Pos.z <= watched.floorz + 1.0
		    && level.maptime - startTic > 1)
		{
			touchTic = level.maptime - startTic;
			touchRun = (watched.Pos.xy - startPos.xy).Length();
		}

		if (RS_Flight.InFlight(watched)) return;

		// STOPPED. Everything below is measured, then compared with what the
		// arithmetic says it should have been. Two numbers that disagree name
		// their own fault: a wrong range with the right launch speed is gravity
		// or drag; a wrong launch speed is mass or the throw scale.
		int    tics  = level.maptime - startTic;
		double restM = (watched.Pos.xy - startPos.xy).Length() / RS_Mass.UNITS_PER_METRE;
		double flyM  = touchRun / RS_Mass.UNITS_PER_METRE;
		double riseM = (peakZ - startPos.z) / RS_Mass.UNITS_PER_METRE;

		// Doom's own gravity in m/s^2 at this object, times the correction the
		// flight applies. GetGravity is per tic squared.
		double gscale = SNum("rs_throw_gravity", 0.27);
		double gDoom  = watched.GetGravity() * TICRATE * TICRATE / RS_Mass.UNITS_PER_METRE;
		double g      = gDoom * gscale;

		double v0    = RS_Mass.UnitsPerTicToMetresPerSec(launchSpeed);
		double pitch = SNum("rs_throwtest_pitch", 20.0);

		// LAUNCH HEIGHT IS IN THE FORMULA, because a throw from the chest lands
		// further than one from the floor and v^2 sin(2a) / g quietly assumes
		// it does not. Flat ground, no drag, no step-clear offset:
		//
		//     t = (vz + sqrt(vz^2 + 2 g h)) / g ,  range = vxy * t
		double h    = (startPos.z - watched.floorz) / RS_Mass.UNITS_PER_METRE;
		double vz   = v0 * sin(pitch);
		double vxy  = v0 * cos(pitch);
		double want = 0.0;
		if (g > 0) want = vxy * (vz + sqrt(vz * vz + 2.0 * g * max(h, 0.0))) / g;

		Console.Printf("[RSTHROWTEST] flew %.1f m in %d tics, then slid to %.1f m at %d tics; peak %.2f m up%s",
			flyM, touchTic, restM, tics, riseM,
			hitCeiling ? "  -- HIT THE CEILING, the range below means nothing" : "");
		Console.Printf("[RSTHROWTEST] expected %.1f m: %.1f m/s at %.0f deg from %.2f m up, under %.1f m/s^2 (Doom's own is %.1f)",
			want, v0, pitch, h, g, gDoom);

		// WHAT THE TARGET MADE OF IT. Damage taken and how far it was shoved,
		// which are the two halves of an impact and come from different code.
		if (target)
		{
			double shoved = (target.Pos.xy - targetPos0.xy).Length() / RS_Mass.UNITS_PER_METRE;
			Console.Printf("[RSTHROWTEST] target: %d -> %d hp (%d damage), shoved %.2f m%s",
				targetHP0, target.Health, targetHP0 - target.Health, shoved,
				target.Health <= 0 ? ", KILLED" : "");
			target = null;
		}

		watched = null;
	}
}
