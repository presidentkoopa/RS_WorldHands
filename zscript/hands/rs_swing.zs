// HOW FAST YOUR HANDS ARE MOVING, and how fast they were moving a moment ago.
//
// One foundation, four features. A flick that pulls something to you, a throw, a
// grenade and a melee swing are all the same measurement read at different
// moments -- so this measures, and says nothing about what any of it means.
//
// THE PEAK, NOT THE LAST SAMPLE. This is the whole reason the class exists
// rather than two lines wherever a speed is wanted. By the time you open your
// fingers to release something, your arm is already slowing down: the last
// sample is deceleration, and a throw built on it comes out limp no matter how
// hard you actually threw. The peak over the last fifth of a second is what your
// arm did, and it is what a thrown object should inherit.
//
// A ring buffer of PER-TIC DELTAS rather than of positions. Deltas are what
// every consumer wants, they are what "peak" is taken over, and keeping
// positions would mean every reader re-deriving the same subtraction and being
// free to get the window wrong in its own way.
//
// THE LINEAR SAMPLES ARE NATIVE VELOCITY NOW, not a position difference. Before
// AttackVel/OffhandVel existed (actor.zs), the only way to know how fast a
// controller was moving was to sample its position every tic and subtract --
// which meant carrying a stale previous sample forward, rotating it by however
// far the player had turned in the meantime, and eating a full tic of lag
// before the fastest instant of a swing ever reached this buffer. A native
// velocity reading has none of that: no previous sample to go stale, no turn
// to compensate (the engine already rotates it into the room-yaw frame the
// same way it does the position), and no differencing lag. The "peak, not the
// last sample" logic below is unchanged and still earns its keep -- a hand
// genuinely IS decelerating by the time you open your fingers, that part was
// always real -- this only removes the SECOND, artificial lag that used to be
// stacked on top of it. The wrist (angular) samples have not made this jump
// yet; see the note in WorldTick.

class RS_Swing : EventHandler
{
	// ~180ms. The playsim runs at 35Hz, so a tic is 28.6ms and seven of them is
	// 200ms -- close enough, and an odd count means the window has a middle.
	const WINDOW = 7;

	// Flat and indexed hand*WINDOW + slot. ZScript has no two-dimensional fixed
	// array, and faking one with an array of objects would put an allocation in
	// front of a number that is read every tic.
	private Vector3 delta[14];
	private int  head[2];
	private int  filled[2];
	// Last tic's TOTAL accumulated turn, so the per-tic delta can be derived.
	// Still needed for the WRIST samples below -- see the note in WorldTick --
	// even though the linear samples no longer use it.
	private double lastTurn;
	private bool  turnPrimed;

	// HOW FAST THE WRIST IS TIPPING UP, same window and same shape as the
	// translation samples beside it.
	//
	// Added 2026-08-28 for a seated-comfort reason rather than a technical one.
	// The pull gesture was a TRANSLATION -- drag your whole hand back toward
	// your body -- which is a shoulder movement, and a shoulder movement is
	// exactly what someone in a chair with armrests cannot do repeatedly. A
	// wrist tip is the same intent expressed by the one joint that is still
	// free when your elbow is resting on something.
	//
	// SIGN: stored so POSITIVE MEANS TIPPING UP, which is the opposite of the
	// raw field. RS_Reach.HandPitch returns true-signed pitch, and RS_Basis.Fwd
	// builds its Z as -sin(pitch), so pointing up is pitch going NEGATIVE. The
	// per-tic sample is therefore (previous - current), and every consumer gets
	// to read "up is a bigger positive number" instead of re-deriving that.
	private double dPitchUp[14];
	private double lastPitch[2];

	// ---- THE WRIST -------------------------------------------------------
	//
	// NOTHING THROWN IN THIS PROJECT HAS EVER SPUN, because the only rotation
	// sampled was pitch -- and that only to spot a flick. A thrown object with
	// no angular velocity reads as a frisbee that does not spin: it travels
	// correctly and looks dead doing it.
	//
	// Degrees per tic, per axis, in the same ring as the position deltas so a
	// throw can ask about both over the same window.
	//
	// Yaw is stored TURN-COMPENSATED like the position deltas: snap-turning
	// rotates the whole world around you, and without subtracting it a turn
	// while holding something reads as an enormous wrist flick.
	private Vector3 dAng[14];
	private Vector3 lastAng[2];
	private bool    angPrimed[2];

	// WHICH SAMPLE WAS THE PEAK, so a throw can ask how long ago it was. A peak
	// from the far end of the window belonged to a different motion -- a
	// gesture, a stumble, the swing before this one -- and counting it is why a
	// throw sometimes fires with a speed you did not just produce.

	private bool   pitchPrimed[2];

	static RS_Swing Get()
	{
		return RS_Swing(EventHandler.Find("RS_Swing"));
	}

	// MAP UNITS PER TIC is the unit everything here is in, because that is what
	// the samples natively are and converting on the way in would round twice.
	// 34 units is a metre and there are 35 tics in a second, so one unit per tic
	// is very nearly exactly one metre per second -- which makes the numbers
	// readable without a conversion in the middle of the measurement.
	static double UnitsPerTicToMetresPerSec(double u)
	{
		return u * 35.0 / 34.0;
	}
	static double MetresPerSecToUnitsPerTic(double m)
	{
		return m * 34.0 / 35.0;
	}

	// The fastest single tic in the window, as a VECTOR -- direction included,
	// because a throw needs to know which way and a flick needs to know whether
	// it came toward you. Zero length when there is nothing recorded yet.
	Vector3 PeakVelocity(int hand) const
	{
		if (hand != 0 && hand != 1) return (0, 0, 0);
		Vector3 best = (0, 0, 0);
		double bestLen = -1.0;
		int n = filled[hand];
		for (int i = 0; i < n; i++)
		{
			Vector3 d = delta[hand * WINDOW + i];
			double len = d.Length();
			if (len > bestLen) { bestLen = len; best = d; }
		}
		return best;
	}

	// THE SAME SEARCH, ANSWERING HOW LONG AGO INSTEAD. Walked backwards from
	// the newest sample so the answer is in tics-before-now, which is what a
	// caller deciding "was that peak part of THIS throw" actually wants.
	//
	// Not folded into PeakVelocity: that is const and called from several
	// places per tic, and giving it a side effect to cache this would make one
	// of those places quietly responsible for another's answer.
	int PeakAgeTics(int hand) const
	{
		if (hand != 0 && hand != 1) return 999;
		int n = filled[hand];
		if (n <= 0) return 999;

		double bestLen = -1.0;
		int bestAge = 999;
		for (int i = 1; i <= n; i++)
		{
			int idx = head[hand] - i;
			while (idx < 0) idx += WINDOW;
			double len = delta[hand * WINDOW + idx].Length();
			if (len > bestLen) { bestLen = len; bestAge = i - 1; }
		}
		return bestAge;
	}

	// Magnitude of the above, map units per tic.
	double PeakSpeed(int hand) const
	{
		return PeakVelocity(hand).Length();
	}

	// The fastest UPWARD wrist tip in the window, DEGREES PER TIC, positive.
	// Zero or negative means the wrist was level or tipping down across the
	// whole window -- callers test against a positive threshold, so a downward
	// flick can never satisfy an upward gesture by magnitude alone.
	//
	// The peak and not the last sample, for the identical reason PeakVelocity
	// exists: by the time the fingers open the wrist is already settling, so
	// the final sample is the recovery rather than the flick.
	double PeakPitchUp(int hand) const
	{
		if (hand != 0 && hand != 1) return 0.0;
		double best = 0.0;
		int n = filled[hand];
		for (int i = 0; i < n; i++)
		{
			double d = dPitchUp[hand * WINDOW + i];
			if (d > best) best = d;
		}
		return best;
	}

	// The most recent tic only. Deliberately available and deliberately NOT what
	// a release should use -- see the note at the top. It is here for things
	// that genuinely want "right now", like deciding whether a hand is currently
	// still.
	// ---- WHAT ACTUALLY LEAVES YOUR HAND -----------------------------------
	//
	// AIM FROM THE RELEASE, SPEED FROM THE PEAK.
	//
	// Every throw in this project used the peak sample whole -- its speed AND
	// its direction -- and that is why they feel flat. Your hand travels an ARC.
	// The fastest instant of that arc is usually several tics before you let go
	// and is pointing somewhere else along the curve, so the object leaves in
	// the direction your hand was going a fifth of a second ago rather than
	// where you were aiming when you opened your fingers.
	//
	// You do genuinely throw as hard as your peak -- that part was right. What
	// was wrong was taking the heading from the same sample. So: magnitude from
	// the peak, direction from the last few samples averaged, which is the
	// tangent of the arc at the moment of release.
	//
	// Averaged rather than the single last sample because one tic of a tracked
	// hand is noisy, and a throw is too committed a gesture to hand its heading
	// to 28 milliseconds of jitter.
	Vector3 ThrowVelocity(int hand, int aimSamples = 3) const
	{
		if (hand != 0 && hand != 1) return (0, 0, 0);
		int n = filled[hand];
		if (n <= 0) return (0, 0, 0);

		double speed = PeakVelocity(hand).Length();
		if (speed <= 0) return (0, 0, 0);

		// The newest `aimSamples`, walking backwards from the head.
		Vector3 aim = (0, 0, 0);
		int take = min(aimSamples, n);
		for (int i = 1; i <= take; i++)
		{
			int idx = head[hand] - i;
			while (idx < 0) idx += WINDOW;
			aim += delta[hand * WINDOW + idx];
		}

		// A RELEASE WITH NO DIRECTION IS A DROP. Stopping dead and opening your
		// hand should let go of the thing, not fling it at your peak speed in
		// whatever direction the averaging happened to leave.
		if (aim.Length() < 0.0001) return (0, 0, 0);

		return aim.Unit() * speed;
	}

	// HOW LONG AGO THE FAST BIT WAS, in tics. A caller wanting a throw to be
	// THIS motion rather than any motion still in the window asks this.
	int PeakAge(int hand) const { return PeakAgeTics(hand); }

	// ---- THE SPIN ---------------------------------------------------------
	//
	// Degrees per tic about yaw, pitch and roll, averaged over the release
	// samples for the same reason the aim is: one tic of wrist is noise.
	//
	// Averaged rather than peaked, unlike the speed. A throw's SPEED is a
	// single explosive instant, but its SPIN is the wrist rolling through the
	// whole release -- taking the peak there would read the sharpest jitter as
	// the intent.
	Vector3 ThrowSpin(int hand, int samples = 3) const
	{
		if (hand != 0 && hand != 1) return (0, 0, 0);
		int n = filled[hand];
		if (n <= 0) return (0, 0, 0);

		Vector3 sum = (0, 0, 0);
		int take = min(samples, n);
		for (int i = 1; i <= take; i++)
		{
			int idx = head[hand] - i;
			while (idx < 0) idx += WINDOW;
			sum += dAng[hand * WINDOW + idx];
		}
		return sum / take;
	}

	// Degrees wrap at 360 and a wrist crossing that boundary reads as a 359
	// degree flick without this.
	private static double Wrap180(double d)
	{
		while (d >  180.0) d -= 360.0;
		while (d < -180.0) d += 360.0;
		return d;
	}

	Vector3 LastVelocity(int hand) const
	{
		if (hand != 0 && hand != 1) return (0, 0, 0);
		if (filled[hand] <= 0) return (0, 0, 0);
		int last = head[hand] - 1;
		if (last < 0) last = WINDOW - 1;
		return delta[hand * WINDOW + last];
	}

	// Throw the history away. Called when the hand teleports rather than moves
	// -- a level change, a respawn -- because the delta across a teleport is an
	// enormous fictional velocity that would read as the throw of a lifetime.
	void Forget(int hand)
	{
		if (hand != 0 && hand != 1) return;

		// THE TURN BASELINE IS SHARED AND IS NO LONGER CLEARED HERE.
		//
		// It used to be, for a real reason: keeping a stale lastTurn across a
		// teleport means the next tic differences against a number from before
		// the reset, and across a savegame that is a whole session's turn in
		// one tic -- which rotates the previous palm sample into nonsense and
		// manufactures the fastest throw of your life.
		//
		// But lastTurn/turnPrimed are ONE pair shared by BOTH hands, while this
		// function is per-hand, so clearing them here punished the hand that was
		// not being forgotten. A successful flick calls Forget(hand) on itself
		// (rs_grab.zs), and that de-primed turn compensation globally: on the
		// very next tic the OTHER hand differenced an uncompensated sample and
		// read a phantom ~24 m/s. Since PeakVelocity holds the maximum for the
		// whole window, that fiction then survived a fifth of a second -- long
		// enough for that hand to hurl whatever it held across the map, or fire
		// a pull nobody asked for.
		//
		// The teleport case that wanted the clear is handled where it actually
		// belongs: ForgetAll, which is what WorldLoaded/WorldUnloaded call.
		head[hand] = 0;
		filled[hand] = 0;
		pitchPrimed[hand] = false;
		for (int i = 0; i < WINDOW; i++)
		{
			delta[hand * WINDOW + i] = (0, 0, 0);
			dPitchUp[hand * WINDOW + i] = 0.0;
			dAng[hand * WINDOW + i] = (0, 0, 0);
		}
	}

	void ForgetAll()
	{
		Forget(0);
		Forget(1);

		// HERE, not in Forget. This is the teleport path -- level change,
		// respawn, savegame -- and it is the only one where the shared turn
		// baseline is genuinely stale. Clearing it per-hand instead was what
		// let one hand's flick corrupt the other hand's velocity; see Forget.
		turnPrimed = false;
	}

	override void WorldTick()
	{
		let p = players[consoleplayer];
		if (!p || !p.mo) return;
		let pmo = p.mo;

		// TURNING IS NOT AN ARM MOVEMENT, AND VRTurnYaw IS NOT A DELTA.
		//
		// Still relevant to the WRIST samples below, which are still measured
		// by differencing AttackAngle/OffhandAngle -- angles that snap-turning
		// visibly changes without a muscle moving. VRTurnYaw is the engine's
		// `snapTurn`, which ACCUMULATES rather than reporting this frame's
		// turn, so the delta is taken here once and reused.
		double turn = pmo.VRTurnYaw;
		double dTurn = 0;
		if (turnPrimed) dTurn = turn - lastTurn;
		lastTurn = turn;
		turnPrimed = true;

		for (int h = 0; h < 2; h++)
		{
			// ---- LINEAR: NATIVE CONTROLLER VELOCITY, NOT A HAND-ROLLED DIFF ---
			//
			// AttackVel/OffhandVel (actor.zs) are OpenXR's own XrSpaceVelocity,
			// read at vk_openxrdevice.cpp's updateHandPose alongside the pose
			// itself. This buffer used to hold a position difference instead --
			// RS_Reach.Centre() sampled every tic, subtracted from the previous
			// sample, with the player's own turn rotated back into the stale
			// sample first because a WORLD-space position difference smears in
			// exactly however much the room turned underneath it. Two whole
			// problems (differencing lag, turn contamination) that a native
			// velocity reading simply does not have: the runtime already
			// reports the controller's motion directly, and vk_openxrdevice.cpp
			// already rotates it into the current room-yaw frame every tic --
			// see the comment there ("SAME TRANSFORM AS POSITION, MINUS THE
			// TRANSLATION") -- the same way AttackPos/OffhandPos always were.
			// There is no stale sample left to spin and no lastPalm left to
			// prime; a velocity reading does not go stale the way a position
			// difference does, because it was never a difference to begin with.
			//
			// Native velocity is per SECOND; this buffer is per TIC (see the
			// class doc on UnitsPerTicToMetresPerSec) -- /TICRATE is the only
			// conversion this needs.
			Vector3 vel = ((h == 0) ? pmo.AttackVel : pmo.OffhandVel) / TICRATE;

			// ---- ANGULAR (WRIST): STILL HAND-DIFFERENCED ----------------------
			//
			// AttackAngularVel/OffhandAngularVel exist now too (same native
			// source), but they are WORLD-frame angular velocity -- rotation
			// about the vertical axis and the two horizontal axes -- not
			// wrist-local pitch/roll rate. Turning that into "how fast is the
			// wrist tipping" needs an additional rotation by the hand's own
			// current yaw that has not been derived and checked in a headset
			// yet. Getting it wrong here breaks ThrowSpin and the chair-comfort
			// pull gesture for everyone, so both stay on angle-differencing
			// until that derivation exists and has been checked. Worth doing
			// next, not worth guessing now.
			//
			// Yaw has the snap-turn subtracted for the same reason the old
			// position deltas needed it: turning rotates the room, not the
			// wrist.
			Vector3 ang = ( (h == 0) ? pmo.AttackAngle  : pmo.OffhandAngle,
			                (h == 0) ? pmo.AttackPitch  : pmo.OffhandPitch,
			                (h == 0) ? pmo.MainHandRoll : pmo.OffhandRoll );
			if (!angPrimed[h]) { lastAng[h] = ang; angPrimed[h] = true; }

			Vector3 da = ( Wrap180(ang.x - lastAng[h].x - dTurn),
			               Wrap180(ang.y - lastAng[h].y),
			               Wrap180(ang.z - lastAng[h].z) );
			lastAng[h] = ang;

			// THE WRIST-TIP SAMPLE. Needs no turn compensation, same as before:
			// turning the player rotates both hands about the VERTICAL axis,
			// which changes their yaw and position but leaves pitch untouched.
			//
			// Negated on the way in so positive reads as tipping UP -- see the
			// note on dPitchUp for why the raw field runs the other way.
			double pit = RS_Reach.HandPitch(pmo, h);
			double up  = 0.0;
			if (pitchPrimed[h]) up = lastPitch[h] - pit;
			lastPitch[h]   = pit;
			pitchPrimed[h] = true;

			// Written at the SAME head index for all three buffers, and before
			// head advances, so sample i of one is always the same tic as
			// sample i of the others. Two counters could drift apart; one
			// cannot.
			delta[h * WINDOW + head[h]]    = vel;
			dAng[h * WINDOW + head[h]]     = da;
			dPitchUp[h * WINDOW + head[h]] = up;
			head[h] = (head[h] + 1) % WINDOW;
			if (filled[h] < WINDOW) filled[h]++;
		}
	}

	override void WorldLoaded(WorldEvent e) { ForgetAll(); }
	override void WorldUnloaded(WorldEvent e) { ForgetAll(); }
}
