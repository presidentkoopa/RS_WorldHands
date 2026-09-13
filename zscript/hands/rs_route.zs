// USING SOMETHING YOU ARE HOLDING, by bringing it to your face.
//
// This is the counterpart to switching walk-over off. Once the room stops
// emptying itself as you cross it, every pickup has to be USED somewhere, and
// that somewhere has to be a place you can only reach on purpose.
//
// The face is the right place for exactly that reason. Your own collision
// cylinder is not -- an object held in your hand is permanently inside it, so
// consuming on body contact would mean everything you picked up was used the
// instant you touched it, which is the walk-over behaviour under a new name.
// Your head is somewhere you have to deliberately raise your hand to.
//
// HmdPos is real world-space head position, not an aim ray (actor.zs), so this
// is genuinely "where your face is" and works the same standing, crouched or
// leaning.

class RS_Route : EventHandler
{
	// Edge-logged, so bringing something up and not using it does not spam.
	private bool wasNear[2];

	static RS_Route Get()
	{
		return RS_Route(EventHandler.Find("RS_Route"));
	}

	private static bool Flag(String n, PlayerInfo p, bool d)
	{
		let c = CVar.GetCVar(n, p);
		return c ? c.GetBool() : d;
	}
	private static double Num(String n, PlayerInfo p, double d)
	{
		let c = CVar.GetCVar(n, p);
		return c ? c.GetFloat() : d;
	}

	// Is this hand's held object close enough to your face to be used? Asked by
	// the flash, so the colour and the gesture cannot disagree about the radius.
	bool AtFace(int hand, PlayerPawn pmo, PlayerInfo p) const
	{
		if (hand != 0 && hand != 1 || !pmo || !p) return false;
		if (!Flag("rs_use_at_face", p, true)) return false;
		let held = RS_Held.Get();
		Actor a = held ? held.HeldBy(hand) : null;
		if (!a) return false;

		// THE SAME TEST THE USE ITSELF APPLIES, and it was missing here.
		//
		// This function exists to drive the cyan flash in rs_grabviz -- the
		// signal that says "bring this the rest of the way and it will do
		// something". WorldTick below refuses anything that is not an unowned
		// Inventory, on the stated grounds that a barrel at your face is just a
		// barrel at your face. But this only measured DISTANCE, so a barrel,
		// a corpse or any other prop flashed the promise anyway and then did
		// nothing when it arrived.
		//
		// A signal that fires when the action will not is worse than no signal:
		// it teaches the player the gesture is unreliable, when in fact the
		// gesture was never available for that object.
		let inv = Inventory(a);
		if (!inv || inv.Owner) return false;

		Vector3 mid = (a.Pos.x, a.Pos.y, a.Pos.z + a.Height * 0.5);
		return (mid - pmo.HmdPos).Length() <= Num("rs_use_face_reach", p, 12.0);
	}

	override void WorldTick()
	{
		let p = players[consoleplayer];
		if (!p || !p.mo) return;
		let pmo = p.mo;
		if (pmo.Health <= 0) return;
		if (!Flag("rs_use_at_face", p, true)) return;

		let held = RS_Held.Get();
		if (!held) return;

		double reach = Num("rs_use_face_reach", p, 12.0);
		bool dbg = Flag("rs_hand_debug", p, true);

		for (int h = 0; h < 2; h++)
		{
			Actor a = held.HeldBy(h);
			if (!a) { wasNear[h] = false; continue; }

			// Only the hand that is PRIMARY on it. A two-handed object brought
			// up would otherwise be offered to your face twice in one tic, and
			// the second offer would run against an object the first already
			// consumed.
			if (held.PrimaryHand(a) != h) { wasNear[h] = false; continue; }

			Vector3 mid = (a.Pos.x, a.Pos.y, a.Pos.z + a.Height * 0.5);
			bool near = (mid - pmo.HmdPos).Length() <= reach;

			if (!near) { wasNear[h] = false; continue; }
			if (wasNear[h]) continue;      // already resolved this approach
			wasNear[h] = true;

			// A TICK ON ARRIVAL, AND A CAVEAT WORTH KEEPING IN THE CODE.
			//
			// Haptics have never been proven to work in this tree. They get
			// reached for constantly and nothing has ever confirmed a pulse
			// actually arrives at the controller.
			//
			// So this is not asserted, it is instrumented: the engine's
			// vr_haptic_debug traces the path end to end for exactly this
			// reason -- "a pulse that never reached the runtime and a pulse the
			// controller ignored are indistinguishable from inside the
			// headset". Turn it on and read [HAPTIC]. If nothing prints, the
			// call never left; if "runtime accepted" prints and you felt
			// nothing, the problem is past this code. Either is a finding.
			if (Flag("rs_use_face_haptic", p, true))
				level.VRHaptic(h, Num("rs_use_face_haptic_amp", p, 0.35), 20.0);

			// Only things that DO something. A barrel at your face is a barrel
			// at your face; refusing it here is what keeps the gesture meaning
			// "use this" rather than "delete whatever I am holding".
			let inv = Inventory(a);
			if (!inv || inv.Owner) continue;

			// SPECIAL is off while held, and that is fine -- CallTryPickup is
			// the pickup itself, not the touch check that leads to it. This is
			// the same call Doom makes when you walk over the thing, so a mod's
			// own pickup behaviour runs exactly as it would have.
			bool took = inv.CallTryPickup(pmo);
			if (dbg)
				Console.Printf("[RSUSE] hand %d brought %s to your face -- %s",
					h, a.GetClassName(), took ? "used" : "refused");

			// A successful pickup destroys or hides the world copy, which nulls
			// the held slot on its own next tic. A refusal leaves it in your
			// hand, which is the honest outcome: full health and a medikit you
			// are still carrying.
		}
	}

	override void WorldLoaded(WorldEvent e) { wasNear[0] = false; wasNear[1] = false; }
}
