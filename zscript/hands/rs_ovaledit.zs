// ============================================================================
// GRIP POINT ADJUSTMENT WITH THE STICKS.
//
// Hold the adjust key: the sticks stop moving you and move one grip oval instead. Tap the
// next key to step to the next oval. Let go and the sticks are yours again.
//
// WHY THE STICKS AND NOT A MENU. A menu pauses the game. The gun is in your hand, the oval
// is attached to the gun, and the whole question being answered is "does this oval sit where
// my other hand goes" -- which cannot be seen while nothing is moving. Every previous attempt
// at this was a slider page, and every one of them was useless for that reason.
//
// HOW THE STICKS ARE TAKEN, AND IT MUST BE THIS WAY.
//
// level.SuppressVRInput stops stick movement AND snap turn, at the place in the OpenXR input
// path where both are decided. level.GetRawStickMove and level.GetRawStickTurn read the same
// sticks and deliberately bypass that suppression, so the stick is dead to the game and live
// to us in the same tic.
//
// PlayerInfo.AxisMask is the obvious-looking alternative and it does NOTHING here: it zeroes
// the movement in the ticcmd, which in this fork is far downstream of where VR walking and
// snap turn are decided. Built, shipped, and the player walked and snap-turned exactly as
// before (2026-09-25). Do not reach for it again.
//
// BOTH RAW READS ARE LOCAL -- this machine's own sticks, like a controller pose. They only
// ever write cvars on the machine holding the controller, which is what these are. Never let
// either decide anything the playsim resolves.
//
// WHAT IT DRIVES, AND WHY TWO DIFFERENT SETS OF CVARS
//
// The support oval is this package's own (rs_stab_*), so it is written directly.
//
// The gun's ammo and action ovals belong to RS_VR_Reload, which keeps a scratch set for
// exactly this purpose: wm_tune_gun picks the hand, wm_tune_part the part, wm_tune_for
// claims the scratch for that one slot, and wm_tune_ofs_* / wm_tune_r are the numbers. They
// are renderer-read, so a tuned oval moves live. Driven BY CVAR NAME: nothing here names a
// class in that package, so this file costs nothing when it is not loaded.
// ============================================================================

class RS_OvalEdit : EventHandler
{
	// HELD, AND THE RELEASE SAYS SO. A +alias fires once on the way down and once on the way
	// up, never in between, so there is no "held" to poll. The countdown is a dead man's
	// switch for a release that never arrives -- a lost key-up, a level change with the key
	// down -- because a stuck suppression is a player who cannot walk or turn with nothing on
	// screen to blame. Sixty seconds: longer than any real hold, shorter than a session.
	const HOLD_TICS = 35 * 60;

	private int  held;
	private bool suppressing;
	private int  sel;            // 0 support, 1.. the gun's parts
	private bool wasStabViz, wasShowGrabs, savedViz;

	// How many of Reload's part slots to offer. Its scratch is keyed on a raw part index and
	// a card has at most sixteen; stepping past a gun's real count simply tunes nothing, and
	// the oval that lights up tells you which one you are on. Asking the card would mean
	// naming a class in another package.
	const PARTS = 8;
	// 0 the main hand's own seat, 1 the off hand's, 2 the support oval, 3.. the gun's parts.
	//
	// THE HAND SEATS ARE HERE BECAUSE THEY ARE THE OTHER HALF OF THE SAME QUESTION. An oval
	// that looks wrong on the gun is as often a hand sitting wrong on the controller, and
	// the two can only be told apart by moving one and watching the other. Adjusting them
	// from different places -- one on a menu page, one on the sticks -- is what made that
	// comparison impossible.
	const SEL_GUN_MAIN  = 0;
	const SEL_GUN_OFF   = 1;
	const SEL_HAND_MAIN = 2;
	const SEL_HAND_OFF  = 3;
	const SEL_SUPPORT   = 4;
	const SEL_PART0     = 5;
	const STEPS = SEL_PART0 + PARTS;

	override void OnRegister() { sel = 0; }

	override void NetworkProcess(ConsoleEvent e)
	{
		if (e.Player != consoleplayer) return;
		if (e.Name ~== "rs_ovaledit")     { Enter(); return; }
		if (e.Name ~== "rs_ovaledit_off") { held = 0; return; }
		if (e.Name ~== "rs_ovalnext")     { Step(); return; }
	}

	private void Enter()
	{
		held = HOLD_TICS;
	}

	private void Step()
	{
		sel = (sel + 1) % STEPS;
		Announce();
	}

	// SAID ON SCREEN, BECAUSE THE PERSON USING THIS IS WEARING A HEADSET. He cannot read a
	// console and cannot reach a keyboard. A diagnostic that needs a desktop to act on is a
	// diagnostic for a problem that only exists in VR.
	private void Announce()
	{
		String what;
		if      (sel == SEL_GUN_MAIN)  what = "THE GUN in your main hand";
		else if (sel == SEL_GUN_OFF)   what = "THE GUN in your off hand";
		else if (sel == SEL_HAND_MAIN) what = "MAIN HAND seat";
		else if (sel == SEL_HAND_OFF)  what = "OFF HAND seat";
		else if (sel == SEL_SUPPORT)   what = "SUPPORT point";
		else                           what = String.Format("gun part %d", sel - SEL_PART0);
		Console.MidPrint(smallfont, String.Format("\c[Gold]%s\c-\n%s", what,
			"push = move across / along, turn = up-down and size"));
	}

	private static double Cvf(String n, double def)
	{
		let c = CVar.GetCVar(n, players[consoleplayer]);
		return c ? c.GetFloat() : def;
	}
	private static void Setf(String n, double v)
	{
		let c = CVar.GetCVar(n, players[consoleplayer]);
		if (c) c.SetFloat(float(v));
	}
	private static void Seti(String n, int v)
	{
		let c = CVar.GetCVar(n, players[consoleplayer]);
		if (c) c.SetInt(v);
	}
	private static void Setb(String n, bool v)
	{
		let c = CVar.GetCVar(n, players[consoleplayer]);
		if (c) c.SetInt(v ? 1 : 0);
	}
	private static bool Cvb(String n, bool def)
	{
		let c = CVar.GetCVar(n, players[consoleplayer]);
		return c ? c.GetInt() != 0 : def;
	}

	override void WorldTick()
	{
		bool on = held > 0;
		if (on) held--;

		// THE RELEASE IS HANDLED BEFORE ANYTHING CAN RETURN EARLY -- no missing pawn, no
		// dead player, no absent gun may skip giving the sticks back.
		if (!on)
		{
			if (suppressing)
			{
				suppressing = false;
				level.SuppressVRInput(false);
				// The ovals go back to whatever the player had them at. Turning them on is
				// part of entering the mode, so turning them off is part of leaving it --
				// and leaving them on would look like the mode never ended.
				if (savedViz)
				{
					savedViz = false;
					Setb("rs_stab_viz",    wasStabViz);
					Setb("wm_show_grabs",  wasShowGrabs);
				}
			}
			return;
		}

		if (!suppressing)
		{
			suppressing = true;
			level.SuppressVRInput(true);
			// YOU CANNOT AIM AT WHAT YOU CANNOT SEE. Both viz toggles come on for the
			// duration; the player's own settings are kept and put back on release.
			if (!savedViz)
			{
				savedViz     = true;
				wasStabViz   = Cvb("rs_stab_viz",   false);
				wasShowGrabs = Cvb("wm_show_grabs", true);
				Setb("rs_stab_viz",   true);
				Setb("wm_show_grabs", true);
			}
			Announce();
		}

		Vector2 mv = level.GetRawStickMove();
		Vector2 tn = level.GetRawStickTurn();

		// A DEADZONE, because a stick at rest is not at zero, and a value nudged every tic by
		// a resting stick drifts all session without anyone touching it.
		double across = (abs(mv.y) < 0.15) ? 0 : mv.y;
		double along  = (abs(mv.x) < 0.15) ? 0 : mv.x;
		double updown = (abs(tn.x) < 0.15) ? 0 : tn.x;
		double size   = (abs(tn.y) < 0.15) ? 0 : tn.y;
		if (across == 0 && along == 0 && updown == 0 && size == 0) return;

		double rate = clamp(Cvf("rs_oval_rate", 0.12), 0.005, 1.0);

		if      (sel == SEL_GUN_MAIN)  MoveGun(0, across, along, updown, size, rate);
		else if (sel == SEL_GUN_OFF)   MoveGun(1, across, along, updown, size, rate);
		else if (sel == SEL_HAND_MAIN) MoveSeat("rs_hw_main", across, along, updown, size, rate);
		else if (sel == SEL_HAND_OFF)  MoveSeat("rs_hw_off",  across, along, updown, size, rate);
		else if (sel == SEL_SUPPORT)   MoveSupport(across, along, updown, size, rate);
		else                           MovePart(sel - SEL_PART0, across, along, updown, size, rate);
	}

	// THE GUN ITSELF -- ITS OWN PLACEMENT CVARS, FOUND AND NOT HARDCODED.
	//
	// Every gun's MODELDEF block names a PlacementCVars prefix, and those cvars are the one
	// channel read on the RENDER path -- so they are what moves a gun while you look at it.
	// Script could not see that name until GetModelPlacementPrefix was added for this
	// (engine, 2026-09-25), and the cost of not being able to see it is on record: RS_VR_Weapons
	// carries 1,451 near-identical sliders, ten per gun, because a menu page per gun was the
	// only way to reach them.
	//
	// So this writes THE SAME cvars those sliders write. Nothing new to save, nothing to bake,
	// and whatever is set when you let go is simply what that gun's placement is.
	//
	// WHICH PROP IS IN WHICH HAND is asked of where it is DRAWN, not of a field. A gun rides
	// its controller inside the draw, so its actor position is not where you see it --
	// ModelPointToWorld replays the same matrix the draw used and answers where it really is.
	// Nearest controller wins. Found by class NAME through ThinkerIterator, which answers
	// null for an absent class rather than refusing to compile, so this costs nothing when
	// RS_VR_Reload is not loaded.
	private Actor GunInHand(PlayerPawn pmo, int hand)
	{
		Vector3 want = (hand == 0) ? pmo.AttackPos : pmo.OffhandPos;
		if (want == (0, 0, 0)) return null;
		Actor best = null;
		double bestD = 1e18;
		let it = ThinkerIterator.Create("WM_Prop");
		Actor a;
		while (a = Actor(it.Next()))
		{
			if (!a.HasModelFrame()) continue;
			Vector3 at, f, u;
			[at, f, u] = a.ModelPointToWorld(0, 0, 0);
			if (at == (0, 0, 0)) continue;
			double d = (at - want).Length();
			if (d < bestD) { bestD = d; best = a; }
		}
		// A GUN FURTHER AWAY THAN AN ARM IS NOT IN THIS HAND. Without this the off hand's
		// gun answers for an empty main hand, and a nudge lands on the wrong weapon.
		return (bestD <= 40.0) ? best : null;
	}

	private void MoveGun(int hand, double across, double along, double updown, double size, double rate)
	{
		let pmo = players[consoleplayer].mo;
		if (!pmo) return;
		Actor g = GunInHand(pmo, hand);
		if (!g) return;
		Name pre = g.GetModelPlacementPrefix(0);
		// A MODEL WITH NO PlacementCVars LINE CANNOT BE MOVED THIS WAY, and saying so beats
		// writing None_ofs_x into nothing -- which is exactly the silent failure the engine's
		// own note at that resolution site describes.
		if (pre == 'None') { Console.MidPrint(smallfont, "\c[Red]that gun has no placement cvars"); return; }
		String p = String.Format("%s", pre);
		if (across != 0) Setf(p .. "_ofs_x", Cvf(p .. "_ofs_x", 0.0) + across * rate);
		if (along  != 0) Setf(p .. "_ofs_y", Cvf(p .. "_ofs_y", 0.0) + along  * rate);
		if (updown != 0) Setf(p .. "_ofs_z", Cvf(p .. "_ofs_z", 0.0) + updown * rate);
		if (size   != 0)
		{
			double sc = Cvf(p .. "_scale", 1.0);
			if (sc <= 0.0) sc = 1.0;
			Setf(p .. "_scale", clamp(sc * (1.0 + size * rate), 0.05, 8.0));
		}
	}

	// A HAND'S OWN SEAT ON THE CONTROLLER -- rs_hw_main / rs_hw_off, the placement cvars the
	// hand's MODELDEF names. These are read on the RENDER path, so they move the hand while
	// you look at it, which is the whole reason this channel exists.
	//
	// SIZE IS NOT TOUCHED HERE. A hand's scale is the one number on it that must not drift:
	// it is what every grab distance, every oval radius and all fourteen tuned gun seats were
	// measured against. Rescaling the hand silently invalidates all of them, so that decision
	// stays where it can be thought about rather than nudged by a thumb. The fourth axis
	// moves the hand ALONG the controller instead.
	private void MoveSeat(String pre, double across, double along, double updown, double depth, double rate)
	{
		if (across != 0) Setf(pre .. "_ofs_x", Cvf(pre .. "_ofs_x", 0.0) + across * rate);
		if (along  != 0) Setf(pre .. "_ofs_y", Cvf(pre .. "_ofs_y", 0.0) + along  * rate);
		if (updown != 0) Setf(pre .. "_ofs_z", Cvf(pre .. "_ofs_z", 0.0) + updown * rate);
		if (depth  != 0) Setf(pre .. "_ofs_y", Cvf(pre .. "_ofs_y", 0.0) + depth  * rate * 0.5);
	}

	// THE SUPPORT OVAL -- this package's own placement cvars. The same three the menu's
	// sliders write, so whatever is set when you stop is simply what it is: rs_stabilize
	// copies them into that weapon model's record on its own.
	private void MoveSupport(double across, double along, double updown, double size, double rate)
	{
		if (across != 0) Setf("rs_stab_ofs_x", Cvf("rs_stab_ofs_x", 0.0) + across * rate);
		if (along  != 0) Setf("rs_stab_ofs_y", Cvf("rs_stab_ofs_y", 0.0) + along  * rate);
		if (updown != 0) Setf("rs_stab_ofs_z", Cvf("rs_stab_ofs_z", 0.0) + updown * rate);
		// Size is a multiplier, so it is nudged proportionally and floored: a scale that
		// reaches zero is an oval the renderer stops drawing, and it cannot be grown back
		// because every further nudge multiplies nothing.
		if (size != 0)
		{
			double s = Cvf("rs_stab_scale", 0.025);
			s = clamp(s * (1.0 + size * rate), 0.005, 4.0);
			Setf("rs_stab_scale", s);
		}
	}

	// A GUN PART -- RS_VR_Reload's tuning scratch, by cvar name.
	//
	// wm_tune_for CLAIMS THE SCRATCH FOR ONE SLOT and Reload refuses to read it for any
	// other, so it has to be set with the gun and part or the numbers go nowhere. Its own
	// menu computes it the same way: gun * 16 + part + 1.
	//
	// Gun 0 is the main hand. Nothing here is written if the cvars are absent, which is what
	// happens when Reload is not loaded -- Setf on a missing cvar does nothing at all.
	private void MovePart(int part, double across, double along, double updown, double size, double rate)
	{
		Seti("wm_tune_gun",  0);
		Seti("wm_tune_part", part);
		Seti("wm_tune_for",  0 * 16 + part + 1);

		if (across != 0) Setf("wm_tune_ofs_x", Cvf("wm_tune_ofs_x", 0.0) + across * rate);
		if (along  != 0) Setf("wm_tune_ofs_y", Cvf("wm_tune_ofs_y", 0.0) + along  * rate);
		if (updown != 0) Setf("wm_tune_ofs_z", Cvf("wm_tune_ofs_z", 0.0) + updown * rate);
		// wm_tune_r is a reach BALL radius where 0 means "the card's own", so it starts from
		// a sane radius rather than from zero the first time it is touched.
		if (size != 0)
		{
			double r = Cvf("wm_tune_r", 0.0);
			if (r <= 0.0) r = 3.0;
			Setf("wm_tune_r", clamp(r + size * rate * 8.0, 0.25, 32.0));
		}
	}
}
