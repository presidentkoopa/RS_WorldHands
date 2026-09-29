// ============================================================================
// WHAT HAPPENED, WRITTEN DOWN, SO NOBODY HAS TO DESCRIBE IT.
//
// The owner plays in a headset. Everything this lane has built is measured and
// proven up to the moment a real controller gets involved, and that last half
// can only run there -- so the difference between "it works" and "it does
// nothing" is a thing he would otherwise have to notice, interpret and report,
// in his own words, about code he has not read.
//
// That is the wrong job for him and it loses most of the information. He sees
// "the barrel went nowhere"; what actually matters is whether the engine hand
// channel answered, what the peak age was, which measurement path ran, and
// what the launch speed came out at -- five numbers he has no way to see.
//
// So every event writes one line. He plays; the log answers.
//
// THE LOG IS HIS OWN, already: his launch carries
// +logfile "E:/DOOMWork/lastrun.log" (Desktop/test.zdl), so Console.Printf
// lands in a file that survives the session. Nothing new has to be wired up
// and nothing has to be running on this end.
//
// ONE PREFIX, FIXED FIELDS, ONE LINE PER EVENT. `[TELEM]` and key=value, so
// the whole session greps in one pass and a field can be added later without
// breaking a reader. No line is printed per tic: only when something happens.
//
// ON BY DEFAULT, deliberately. A diagnostic that has to be switched on is a
// diagnostic that is off the one time it was needed -- and he should not have
// to remember a console command before playing. It costs a handful of prints
// per throw.
// ============================================================================

class RS_Telem play
{
	static bool On()
	{
		let c = CVar.GetCVar("rs_telemetry", null);
		return c ? c.GetBool() : true;
	}

	static void Line(String s)
	{
		if (On()) Console.Printf("[TELEM] %s", s);
	}
}


// THE CAPABILITY REPORT, once per level.
//
// The single most useful line in the file, and the one that decides how to
// read every other line. If the engine hand channel is not answering then the
// whole render-rate path is inert, every throw fell back to the 35Hz ring, and
// no amount of staring at launch speeds will say why.
//
// Printed a second after the level starts rather than immediately: the ring
// needs a few frames of controller data before it can honestly say whether it
// has any.
class RS_TelemReport : EventHandler
{
	private int t;

	override void WorldLoaded(WorldEvent e) { t = 0; }

	override void WorldTick()
	{
		t++;
		if (t != 35) return;

		let pmo = players[consoleplayer].mo;
		if (!pmo) { RS_Telem.Line("caps player=none"); return; }

		Vector3 hp0 = level.HandPos(0);
		Vector3 hp1 = level.HandPos(1);
		Vector3 hv0 = level.HandVelAtPoint(0, (0, 0, 0), RS_HAND_NOW);
		double age0 = level.HandPeakAgeMs(0);

		let sv = CVar.GetCVar("vr_hand_lever_sign", null);
		double sign = sv ? sv.GetFloat() : 0;

		// handpos/handvel are the two halves of the engine channel; attackpos
		// is the old field, printed beside them so a disagreement between the
		// two is visible rather than inferred.
		RS_Telem.Line(String.Format(
			"caps mp=%d handpos0=%d handpos1=%d handvel0=%d peakms=%.0f leversign=%+.0f attackpos=%d gravity=%.2f armkg=%.0f",
			multiplayer ? 1 : 0,
			hp0 != (0, 0, 0) ? 1 : 0,
			hp1 != (0, 0, 0) ? 1 : 0,
			hv0.Length() > 0 ? 1 : 0,
			age0, sign,
			pmo.AttackPos != (0, 0, 0) ? 1 : 0,
			RS_Flight.TelemNum("rs_throw_gravity", 0.27),
			RS_Flight.TelemNum("rs_throw_arm_kg", 30.0)));

		// WHERE THE HAND IS, ONCE, IN NUMBERS. If reach feels wrong, the
		// distance between the hand and the pawn is the first thing to look at
		// and the last thing he could describe.
		if (hp0 != (0, 0, 0))
			RS_Telem.Line(String.Format("handpos hand=0 at=(%.0f,%.0f,%.0f) pawn=(%.0f,%.0f,%.0f) apart=%.0f",
				hp0.x, hp0.y, hp0.z, pmo.Pos.x, pmo.Pos.y, pmo.Pos.z,
				(hp0 - pmo.Pos).Length()));
	}
}
