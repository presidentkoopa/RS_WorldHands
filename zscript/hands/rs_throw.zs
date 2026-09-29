// THROWING, AND THE DIFFERENCE BETWEEN A THROW AND A DROP.
//
// This is small because the hard part was built first. RS_Swing already keeps
// the peak of the last ~180ms of hand movement, already measures it relative to
// the player so walking is not a throw, and already discards a snap turn. All
// that is left is: read it at the moment of release, scale it, and write it to
// the actor's Vel.
//
// AND THEN DOOM DOES EVERYTHING ELSE. P_XYMovement and P_ZMovement give gravity,
// floors, ceilings, stairs, wall sliding, bouncing and impact -- for a thrown
// object those are not features to implement, they are what an actor with a
// velocity already does. That is the entire argument for 35Hz on the playsim in
// one sentence, and it is why the physics module was not worth its cost.
//
// THE PEAK, NOT THE LAST SAMPLE. By the time your fingers open, your arm is
// already slowing down. A throw built on the instantaneous speed at release
// comes out limp no matter how hard it felt, and no amount of scaling fixes it
// because the number being scaled is the deceleration.

// PLAY SCOPE, DECLARED -- the same trap RS_Reach fell into. A plain class's
// statics default to data, and data cannot call a play function, which is what
// RS_Swing.Get and RS_Reach.Flag both are.
class RS_Throw play
{
	// Below this it is a DROP, and that distinction matters more than the
	// number. A release at rest that inherits a peak from a fifth of a second
	// ago is an object leaping out of your hand for no reason -- most obviously
	// when you let go of something right after catching it, where the catch's
	// own motion is still sitting in the window.
	//
	// Under the threshold the object leaves at the hand's CURRENT speed rather
	// than at zero: setting it down while walking should not make it hang in the
	// air behind you.
	// AIM FROM THE RELEASE, SPEED FROM THE PEAK.
	//
	// The note above is right that the peak is the speed -- by the time your
	// fingers open your arm is already slowing, and a throw built on the speed
	// at release comes out limp no matter how hard it felt.
	//
	// But it took the DIRECTION from that same sample too, and that is why
	// throws feel wrong rather than merely weak. Your hand travels an ARC. The
	// fastest instant of that arc is several tics before you let go and is
	// pointing somewhere else along the curve, so the object leaves heading
	// where your hand was going a fifth of a second ago instead of where you
	// were aiming when you opened your fingers.
	//
	// Magnitude from the peak, heading from the last few samples averaged --
	// the tangent of the arc at release. See RS_Swing.ThrowVelocity.
	static Vector3 VelocityFor(int hand, PlayerPawn pmo, PlayerInfo p)
	{
		let sw = RS_Swing.Get();
		if (!sw || !RS_Reach.Flag("rs_throw", p, true)) return (0, 0, 0);

		double need = RS_Swing.MetresPerSecToUnitsPerTic(
			RS_Reach.Num("rs_throw_min", p, 1.2));

		// TOO SLOW IS A DROP. Opening your hand while standing still should let
		// go of the thing; a threshold is the only thing separating that from a
		// very gentle throw.
		if (sw.PeakSpeed(hand) < need) return pmo.Vel;

		double scale = RS_Reach.Num("rs_throw_scale", p, 1.0);

		// OFF HAND, SEPARATELY. Most people's off arm genuinely throws with
		// less wrist snap and follow-through than their main arm -- that is
		// true swinging a bat and true here too, tracking notwithstanding.
		// A flat 1.0 multiplier here can't fix biomechanics, but it gives
		// the player their own dial for "my off-hand throws feel short"
		// instead of them just living with it or blaming the tracking.
		if (hand == 1)
			scale *= RS_Reach.Num("rs_throw_scale_off", p, 1.0);

		int    aim   = int(RS_Reach.Num("rs_throw_aim", p, 3));

		// AND THE FAST BIT HAS TO BELONG TO THIS RELEASE. The window is about a
		// fifth of a second, so without this a flick made before you even picked
		// the object up is still the newest peak and becomes its throw -- which
		// reads as the game launching things at random.
		int grace = int(RS_Reach.Num("rs_throw_grace", p, 4));
		if (sw.PeakAge(hand) > grace)
			return sw.LastVelocity(hand) * scale + pmo.Vel;

		Vector3 v = sw.ThrowVelocity(hand, aim);
		if (v.Length() <= 0) return pmo.Vel;

		v = Arc(v, p);

		// The hand's motion is measured relative to the player, so a thrown
		// object would be launched relative to the player too -- throw a barrel
		// while sprinting forward and it would fall short by exactly your own
		// speed. The pawn's velocity goes back in here, once, at the only place
		// it is wanted.
		return v * scale + pmo.Vel;
	}

	// ---- THE SAME THROW, MEASURED AND NOT YET SPENT -----------------------
	//
	// WHAT THE HAND DID, AND NOTHING ELSE. No player velocity, no server
	// scale, no lift, no mass. Just the speed and heading of the hand at the
	// moment the fingers opened, in units per tic, relative to the player.
	//
	// WHY THIS EXISTS SEPARATELY FROM VelocityFor. A release travels between
	// machines as three integers (rs_handnet.zs). Everything the RECEIVER can
	// work out for itself must be worked out there rather than sent, or two
	// machines that disagree about a cvar put the object in two different
	// places. Mass, the server throw scale and the thrower's own velocity are
	// all knowable from the playsim, so they are applied on arrival, in
	// RS_Held.Release. Only the part that needs a controller travels.
	//
	// AND VelocityFor STAYS EXACTLY AS IT WAS. It is a published service
	// (`throw.vel.*`) and four packages outside this one read it -- the
	// grenade, the thrown gun, the lightsaber and the shield -- every one of
	// them expecting a velocity it can hand straight to an actor. Quietly
	// changing what it means would have changed all four with no error
	// anywhere, which is how a system starts throwing things differently and
	// nobody can say when it began. New meaning, new request name.
	//
	// NO LIFT HERE, DELIBERATELY. rs_throw_lift existed to fake an arc under a
	// gravity 3.7x too strong for a human arm. RS_Flight corrects the gravity
	// instead, so the arc is the real one and a fudge on top of it would bend
	// every throw upward twice.
	// `held` is what is about to leave the hand. Given one, the measurement is
	// taken at the OBJECT'S centre rather than at the controller's origin --
	// see FromEngine. Without one this is the hand itself, which is what every
	// caller wanted before the lever existed.
	static Vector3 HandVelocityFor(int hand, PlayerPawn pmo, PlayerInfo p, Actor held = null)
	{
		// THE ENGINE FIRST, AND THE 35Hz RING ONLY IF IT HAS NOTHING.
		Vector3 fromEngine = FromEngine(hand, pmo, p, held);
		if (fromEngine.Length() > 0) return fromEngine;

		let sw = RS_Swing.Get();
		if (!sw || !RS_Reach.Flag("rs_throw", p, true)) return (0, 0, 0);

		double need = RS_Swing.MetresPerSecToUnitsPerTic(
			RS_Reach.Num("rs_throw_min", p, 1.2));

		// TOO SLOW IS A DROP -- and a drop is a zero here, not a refusal. The
		// applier adds the player's own velocity to whatever arrives, so a zero
		// becomes "leaves at exactly the speed you were walking", which is what
		// setting something down while moving should do.
		if (sw.PeakSpeed(hand) < need) return (0, 0, 0);

		// THE OFF-HAND DIAL IS A USER CVAR AND IT IS APPLIED HERE ON PURPOSE.
		// Most people's off arm throws with less snap than their main one, and
		// that is a fact about the player, not about the game -- so it is a
		// personal setting. It stays netplay-safe because it is spent BEFORE
		// the velocity is sent: what travels is already the number this player
		// meant, and no receiver ever reads the cvar.
		double personal = (hand == 1) ? RS_Reach.Num("rs_throw_scale_off", p, 1.0) : 1.0;

		int aim   = int(RS_Reach.Num("rs_throw_aim", p, 3));
		int grace = int(RS_Reach.Num("rs_throw_grace", p, 4));

		// AND THE FAST BIT HAS TO BELONG TO THIS RELEASE -- see VelocityFor.
		if (sw.PeakAge(hand) > grace)
			return sw.LastVelocity(hand) * personal;

		Vector3 v = sw.ThrowVelocity(hand, aim);
		if (v.Length() <= 0) return (0, 0, 0);
		return v * personal;
	}

	// ---- WHAT THE ENGINE MEASURED, AT THE OBJECT RATHER THAN AT THE HAND ----
	//
	// Two things script cannot do for itself, both done in LevelLocals.
	//
	// THE WRIST. A thrown object is not at the controller's origin. Its centre
	// sits away from the hand, and a frisbee or a newspaper flick is mostly
	// ROTATION -- so the speed that matters is the hand's linear velocity plus
	// omega x r. That cross product is only valid in a uniformly scaled space
	// and MAP SPACE IS NOT ONE: the vertical is divided by pixelstretch and the
	// angular velocity is not scaled at all. Computed here it would be wrong in
	// Z by up to a fifth, varying with wrist orientation -- which is precisely
	// the axis a frisbee lives on. The engine does it where the numbers are
	// still isotropic metres and hands back a plain velocity.
	//
	// THE SAMPLE RATE. The playsim runs at 35Hz and a flick does not. The
	// fastest instant of a throw falls between two tics, so a peak read off the
	// tic grid is weaker and less repeatable than the arm that made it. The
	// engine keeps a quarter second at render rate.
	//
	// RS_HAND_THROW is speed from the peak and heading from just after it. Both
	// halves matter and they are different samples: the hand travels an ARC, so
	// its fastest instant points somewhere else along that curve, and taking
	// the heading from there sends the object where the hand was going a fifth
	// of a second ago rather than where it was aimed when the fingers opened.
	//
	// MAP UNITS PER SECOND COME BACK. Everything in the playsim is per TIC.
	static Vector3 FromEngine(int hand, PlayerPawn pmo, PlayerInfo p, Actor held)
	{
		if (!pmo || !RS_Reach.Flag("rs_throw_engine", p, true)) return (0, 0, 0);

		// THE OFFSET IS A MAP-UNIT DIFFERENCE AND IT STAYS ONE. Do not convert
		// it to metres on the way in: the vertical is scaled differently from
		// the horizontals, so that conversion is the exact mistake the engine
		// call exists to prevent. It meets the stretch once, inside.
		Vector3 offset = (0, 0, 0);
		if (held)
		{
			// The REAL hand, for the same reason RS_Reach.Palm reads it: in a
			// netgame AttackPos is the canonical shooting point rebuilt from
			// the usercmd, not where the controller is, so a lever measured
			// from it would be the distance from the object to the player's
			// chest. Falls back to the old field when there is no controller.
			Vector3 handPos = level.HandPos(hand);
			if (handPos == (0, 0, 0))
				handPos = (hand == 0) ? pmo.AttackPos : pmo.OffhandPos;
			if (handPos.Length() > 0) offset = held.Pos - handPos;
		}

		// THE FAST BIT HAS TO BELONG TO THIS RELEASE. Same question
		// rs_throw_grace asks of the 35Hz ring, asked of the render-rate one --
		// a flick made before the object was even picked up is still the newest
		// peak, and without this it becomes the throw. Milliseconds here
		// because the ring is not on the tic grid.
		double ageMs = level.HandPeakAgeMs(hand);
		double graceMs = RS_Reach.Num("rs_throw_grace", p, 4) * 1000.0 / TICRATE;
		int when = (ageMs >= 0 && ageMs <= graceMs) ? RS_HAND_THROW : RS_HAND_NOW;

		Vector3 vPoint = level.HandVelAtPoint(hand, offset, when) / TICRATE;
		if (vPoint.Length() <= 0)
		{
			// THE ENGINE HAD NOTHING, so the 35Hz ring answers instead. Said
			// out loud because it is the single most useful thing to know when
			// a throw comes out wrong: every other number means something
			// different depending on which path produced it.
			RS_Telem.Line(String.Format("measure hand=%d path=fallback reason=no-engine-sample agems=%.0f",
				hand, ageMs));
			return (0, 0, 0);
		}

		// THE WRIST DIAL, AND WHY IT IS TWO CALLS. rs_throw_wrist scales the
		// lever and nothing else, so it has to be separable from the hand's own
		// motion -- and the engine deliberately never exposes a raw angular
		// velocity for anyone to scale. Asking a second time at the controller
		// origin gives the hand alone, and the difference IS the lever.
		double wrist = RS_Reach.Num("rs_throw_wrist", p, 1.0);
		if (offset.Length() > 0 && wrist != 1.0)
		{
			Vector3 vHand = level.HandVelAtPoint(hand, (0, 0, 0), when) / TICRATE;
			vPoint = vHand + (vPoint - vHand) * wrist;
		}

		// A DROP IS STILL A DROP. The threshold is the same one the 35Hz path
		// uses, asked of the same quantity.
		double need = RS_Swing.MetresPerSecToUnitsPerTic(RS_Reach.Num("rs_throw_min", p, 1.2));
		if (vPoint.Length() < need)
		{
			RS_Telem.Line(String.Format("measure hand=%d path=engine verdict=drop mps=%.2f need=%.2f",
				hand, RS_Mass.UnitsPerTicToMetresPerSec(vPoint.Length()),
				RS_Mass.UnitsPerTicToMetresPerSec(need)));
			return (0, 0, 0);
		}

		// WHAT THE WRIST ADDED, separately from what the arm did. If a flick
		// throws nothing, this line says whether the lever was zero (no wrist
		// term at all -- offset, sign or angular velocity) or simply small.
		Vector3 vHandOnly = level.HandVelAtPoint(hand, (0, 0, 0), when) / TICRATE;
		RS_Telem.Line(String.Format(
			"measure hand=%d path=engine when=%d agems=%.0f offset=%.0f arm_mps=%.2f point_mps=%.2f lever_mps=%.2f",
			hand, when, ageMs, offset.Length(),
			RS_Mass.UnitsPerTicToMetresPerSec(vHandOnly.Length()),
			RS_Mass.UnitsPerTicToMetresPerSec(vPoint.Length()),
			RS_Mass.UnitsPerTicToMetresPerSec((vPoint - vHandOnly).Length())));

		// The off-hand dial, spent here on the sender exactly as below.
		double personal = (hand == 1) ? RS_Reach.Num("rs_throw_scale_off", p, 1.0) : 1.0;
		return vPoint * personal;
	}

	// ---- THE ARC ----------------------------------------------------------
	//
	// PEOPLE THROW UPWARDS AND DO NOT NOTICE THEY ARE DOING IT.
	//
	// A real throw is lobbed: you aim above what you want to hit and let gravity
	// bring it down. In a headset almost nobody does that -- you point at the
	// target and flick, because the room-scale motion your body makes is a
	// straight push at what you are looking at. Take that literally and
	// everything you throw is a flat line drive that hits the floor short, which
	// reads as the throw being weak when it is actually just level.
	//
	// So lift is added in proportion to how HARD you threw, not as a fixed
	// angle: a gentle underhand toss stays gentle and a hard throw arcs, which
	// is what the same motion does with a real object in a real hand.
	//
	// Proportional to the FLAT speed specifically, so throwing straight up does
	// not add more up. Lifted from RS_Grenade, which had this as rsvg_lift and
	// was the only thrower in the project that arced -- which is most of why the
	// grenade felt better to throw than anything else.
	static Vector3 Arc(Vector3 v, PlayerInfo p)
	{
		double lift = RS_Reach.Num("rs_throw_lift", p, 0.35);
		if (lift <= 0) return v;
		double flat = (v.x, v.y, 0).Length();
		return (v.x, v.y, v.z + flat * lift);
	}

	// ---- THE SPIN YOUR WRIST PUT ON IT ------------------------------------
	//
	// The note below used to say tumbling "is a system, not a line". It was
	// right that a single angle change at release is not a tumble -- but the
	// missing piece was never the tracking, it was that NOTHING MEASURED THE
	// WRIST. RS_Swing sampled position and pitch, so there was no angular
	// velocity to give an object even if something had wanted one.
	//
	// It measures all three now. Degrees per tic as (yaw, pitch, roll); what
	// spends it is whatever is flying, which advances its own angles while it
	// is in the air. That part IS still per-object, and correctly so: a saw
	// spins about its face, a grenade tumbles end over end, and only they know
	// which.
	//
	// Scaled separately from the velocity because they are separate intents. A
	// hard straight throw and a lazy spinning one are both things a player
	// means, and one multiplier cannot express both.
	static Vector3 SpinFor(int hand, PlayerInfo p)
	{
		let sw = RS_Swing.Get();
		if (!sw || !RS_Reach.Flag("rs_throw", p, true)) return (0, 0, 0);
		if (!RS_Reach.Flag("rs_throw_spin", p, true))   return (0, 0, 0);

		int aim = int(RS_Reach.Num("rs_throw_aim", p, 3));
		return sw.ThrowSpin(hand, aim) * RS_Reach.Num("rs_throw_spin_scale", p, 1.0);
	}
}


// ---- THE DOOR ---------------------------------------------------------------
//
// Reached by string, so a package can throw without naming a class in here.
//
// That is not tidiness. RS_Grenade deliberately removed its reference to
// RS_Throw because the coupling "broke the whole game three separate times
// across three folder layouts" -- a ZScript class reference to a pk3 that is
// absent, or that loads later, is fatal AND global and takes down every mod
// after it. So the grenade grew its own thrower, the shield grew another, and
// the same flick threw three objects three different distances.
//
// A service has no such coupling: ask, and if nothing answers use your own.
class RS_ThrowService : Service
{
	override int GetInt(String request, String stringArg, int intArg, double doubleArg, Object objectArg, Name nameArg)
	{
		// IDENTITY. ServiceIterator matches a case-insensitive SUBSTRING of the
		// class name, so finding something proves nothing on its own.
		if (request == "throw.hello") return 1;

		let pmo = PlayerPawn(objectArg);
		if (!pmo || !pmo.player) return 0;
		int hand = clamp(intArg, 0, 1);

		// THOUSANDTHS. A Service returns an int and there is no double channel,
		// and a throw needs finer resolution than whole units per tic.
		if (request == "throw.vel.x" || request == "throw.vel.y" || request == "throw.vel.z")
		{
			Vector3 v = RS_Throw.VelocityFor(hand, pmo, pmo.player);
			if (request == "throw.vel.x") return int(v.x * 1000.0);
			if (request == "throw.vel.y") return int(v.y * 1000.0);
			return int(v.z * 1000.0);
		}

		// THE HAND'S OWN MOTION, WITH NOTHING SPENT ON IT YET (2026-09-28).
		//
		// A SECOND REQUEST RATHER THAN A CHANGE TO THE ONE ABOVE. Four packages
		// outside this one read `throw.vel.*` and every one of them expects a
		// velocity ready to hand to an actor -- player motion in, scale
		// applied. Redefining it would have changed all four silently, which is
		// a fault with no error message and no obvious start date.
		//
		// Ask for this one when you intend to apply mass, the server scale and
		// the thrower's velocity yourself -- which is what anything sending a
		// release across the network has to do. See RS_Throw.HandVelocityFor.
		if (request == "throw.vel.hand.x" || request == "throw.vel.hand.y" || request == "throw.vel.hand.z")
		{
			Vector3 v = RS_Throw.HandVelocityFor(hand, pmo, pmo.player);
			if (request == "throw.vel.hand.x") return int(v.x * 1000.0);
			if (request == "throw.vel.hand.y") return int(v.y * 1000.0);
			return int(v.z * 1000.0);
		}

		if (request == "throw.spin.yaw" || request == "throw.spin.pitch" || request == "throw.spin.roll")
		{
			Vector3 s = RS_Throw.SpinFor(hand, pmo.player);
			if (request == "throw.spin.yaw")   return int(s.x * 1000.0);
			if (request == "throw.spin.pitch") return int(s.y * 1000.0);
			return int(s.z * 1000.0);
		}

		// Did that count as a throw at all, or was it a drop?
		if (request == "throw.iscast")
		{
			let sw = RS_Swing.Get();
			if (!sw) return 0;
			double need = RS_Swing.MetresPerSecToUnitsPerTic(
				RS_Reach.Num("rs_throw_min", pmo.player, 1.2));
			return (sw.PeakSpeed(hand) >= need) ? 1 : 0;
		}

		return 0;
	}
}
