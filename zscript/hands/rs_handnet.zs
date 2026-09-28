// ============================================================================
// WHAT A HAND DECIDES, TRAVELLING AS A COMMAND.
//
// THE RULE THIS EXISTS FOR (Engine docs/CROSSPLATFORM_COOP_RULE.md): gameplay may
// depend only on the playsim, the usercmd and server cvars -- never on a machine's
// input devices, its VR pose, or a per-player toggle. A desktop player with hands
// switched off and a VR player in a headset have to stay in step.
//
// WHY A BUTTON WAS ALWAYS SAFE AND A HAND WAS NOT. A button press travels as a
// usercmd: every machine sees the same INPUT and reaches the same decision by
// construction. Taking hold of a barrel had no such path -- one machine decided,
// moved the barrel, and nothing else ever heard. Two machines then disagreed about
// where a solid object was, which is as bad as a desync gets.
//
// So the DECISION travels and the pose stays home:
//
//   rs_hand_take:<netid>   this hand took hold of that actor, with this kind of hold
//   rs_hand_drop:<hand>    this hand let go, at this measured velocity
//
// THE APPLIER READS NOTHING. Not a cvar, not a controller, not consoleplayer. Every
// value it needs is IN the command, because a value re-derived locally is two
// machines quietly disagreeing. The velocity is measured off the controller by the
// machine that has one and travels as three integers.
//
// THE CARRY DOES NOT TRAVEL. The grab travels once; after that the actor is held by
// that player and every machine moves it the same way from the holder's own
// replicated position. A per-tic carry would be streaming, not a decision, and it
// would make one player's controller the source of truth for a playsim position --
// the exact thing this removes. Release travels again, carrying the velocity.
// The price, accepted deliberately: other machines see the object follow the HOLDER,
// not the holder's HAND. If that ever needs to be visible it is presentation and it
// goes in a local path, never in the playsim position.
//
// IDENTITY. Object.GetNetworkID() / Object.GetNetworkEntity(id) -- the engine's own
// network entity table (src/common/objects/dobject.cpp). Note that CLIENTSIDE actors
// are never given an id (AddNetworkEntity returns early on IsClientSide), so a
// clientside prop can never be the subject of one of these; nothing that is grabbable
// is clientside, but it is a real wall and worth knowing it is there.
// ============================================================================

class RS_HandNet : EventHandler
{
	// Velocity travels as thousandths, so the integer is the same on every machine
	// and nothing depends on anyone's float formatting.
	const VSCALE = 1000.0;

	// ---- senders, called by the machine that has the controller --------------

	static void SendTake(Actor a, int hand, int subject, int pose, bool twohand)
	{
		if (!a) return;
		uint id = a.GetNetworkID();
		if (id == 0) return;     // clientside or untracked: it cannot travel, so do not pretend
		EventHandler.SendNetworkEvent(String.Format("rs_hand_take:%u", id),
		                              hand, subject, pose | (twohand ? 0x10000 : 0));
	}

	// `vel` IS THE HAND'S MOTION, NOT THE THROW (2026-09-28).
	//
	// Units per tic, relative to the player, with nothing spent on it: no mass,
	// no server throw scale, no player velocity. The applier puts all three on
	// in RS_Held.Release, identically everywhere.
	//
	// WHY NOT SEND THE FINISHED NUMBER. It was simpler and it was wrong. Mass,
	// the throw scale and the thrower's velocity are all knowable from the
	// playsim, so sending them means one machine's answer overwrites what every
	// other machine would have worked out -- and the day those disagree, the
	// object lands somewhere different on each and nothing says why. Send only
	// what needs a controller. Derive the rest.
	static void SendDrop(int hand, Vector3 vel)
	{
		EventHandler.SendNetworkEvent(String.Format("rs_hand_drop:%d", hand),
		                              int(round(vel.x * VSCALE)),
		                              int(round(vel.y * VSCALE)),
		                              int(round(vel.z * VSCALE)));
	}

	// ---- the appliers, run by EVERY machine ---------------------------------

	override void NetworkProcess(ConsoleEvent e)
	{
		if (e.Player < 0 || e.Player >= MAXPLAYERS || !playeringame[e.Player]) return;
		let pmo = players[e.Player].mo;
		if (!pmo || !pmo.player) return;

		let held = RS_Held.Get();
		if (!held) return;

		// The guard that used to stand here -- "return unless e.Player is this
		// machine's" -- is GONE. It existed only because RS_Held had nowhere to put
		// another player's hands: applying a remote release would have cleared the
		// local player's slot. The state is per player now, so every machine applies
		// every command for the player it names, which is the whole point.

		if (e.Name.Left(13) == "rs_hand_take:")
		{
			// A command whose actor is gone, or was never known here, is DROPPED.
			// Never a guess at something nearby -- a guess is the disagreement we
			// are removing, wearing a helpful face.
			let a = Actor(Object.GetNetworkEntity(e.Name.Mid(13).ToInt()));
			if (!a) return;

			int hand = e.Args[0];
			if (hand != 0 && hand != 1) return;
			held.Take(e.Player, hand, a, e.Args[1], e.Args[2] & 0xFFFF,
			          (e.Args[2] & 0x10000) != 0, players[e.Player]);
			return;
		}

		if (e.Name.Left(13) == "rs_hand_drop:")
		{
			int hand = e.Name.Mid(13).ToInt();
			if (hand != 0 && hand != 1) return;
			Vector3 v = (e.Args[0] / VSCALE, e.Args[1] / VSCALE, e.Args[2] / VSCALE);
			held.Release(e.Player, hand, pmo, players[e.Player], true, v);
			return;
		}
	}
}
