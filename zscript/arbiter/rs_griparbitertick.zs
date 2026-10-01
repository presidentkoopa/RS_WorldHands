// THE GRIP ARBITER'S HEARTBEAT.
//
// Everything the arbiter knows lives in rs_griparbiter.zs. This file is the one
// thing that file cannot do for itself: TICK.
//
// WHY A SECOND CLASS AT ALL. Service declares only Get* virtuals (engine/
// service.zs). There is no Tick, no WorldLoaded, no WorldUnloaded and no
// SetOrder on it -- InitServices() instantiates the object and then nothing in
// the engine ever calls it again unless a consumer asks it something. So an
// arbiter built only as a Service can never notice anything on its own: a lapsed
// lease is only retired when somebody happens to ask about that exact hand, a
// destroyed actor's pointer is kept until the same accident, and a map change
// goes by entirely unobserved. All three were true of PROTOCOL 2, and all three
// are the kind of fault that shows up as "the left hand stopped working after a
// level" rather than as an error.
//
// WHY IT IS STILL A Service THAT HOLDS THE STATE. Unchanged and still the whole
// point: three mods must each ship and run ALONE, and EventHandler.Find("Name")
// resolves at COMPILE time with a miss that is fatal AND GLOBAL (thingdef.cpp:
// 420-424 refuses every pk3 later in the load order). Nothing outside this pk3
// may ever name this handler. Consumers keep talking to the Service by string,
// exactly as they do today; this class is private plumbing between the two.
//
// WHY StaticEventHandler AND NOT EventHandler. A plain EventHandler is created
// per map and SERIALIZED into savegames; this one owns no state worth saving and
// must run on a savegame load, which a non-static handler deliberately does not
// (events.cpp:671 skips WorldLoaded for handlers restored from a save -- which
// is precisely the boundary we have to clear at).
//
// WHY WorldTick AND NOT WorldStep. The lease is measured on level.realtime,
// which keeps running in a freeze and under slow motion (g_levellocals.h:1336).
// Sweeping on the WORLD clock instead would mean a frozen world never retires a
// lapsed claim -- the exact jam the lease exists to prevent, reintroduced
// through the back door.
//
// WHY THE ORDER IS LATE. EventManager::RegisterHandler links a handler before
// the first one with a strictly GREATER Order (events.cpp:288-294), so every
// handler that declares none -- which is all thirteen in this pk3's MAPINFO --
// keeps registration sequence at Order 0 and anything above 0 lands after the
// lot. 10000 is simply "last", with four digits of room for anything that must
// one day be later still.
//
// NOTHING HERE DECIDES ANYTHING. The sweep retires what has already expired by
// the Service's own rules and drops references to actors the playsim has already
// destroyed. It cannot grant, deny or move a claim, and it must never learn how
// to: the moment two places can change the ledger, "who owns this hand" has two
// answers again, which is the bug the whole arbiter was built to end.

class RS_GripArbiterTick : StaticEventHandler
{
	// The Service, found once and kept. Not found in OnRegister: InitServices()
	// runs from info.cpp:383 at VM setup and handlers register later, so the
	// order is safe today -- but a cached null would be permanent and silent,
	// and a lazy look costs one map iteration on the first tic of a session.
	private Service mArb;
	private bool    mLooked;

	// THE HANDSHAKE IS NOT OPTIONAL HERE EITHER. ServiceIterator.Find matches a
	// case-insensitive SUBSTRING of the class name over a map in undefined order
	// (service.zs:167), so a hit is not proof of identity. Ask something only the
	// arbiter answers and check the answer, the same as every consumer does.
	private Service arb()
	{
		if (mLooked) return mArb;
		mLooked = true;

		let it = ServiceIterator.Find("RS_GripArbiterService");
		Service s;
		while (s = it.Next())
		{
			if (s.GetInt("grip.hello") == 1) { mArb = s; break; }
		}
		return mArb;
	}

	override void OnRegister()
	{
		SetOrder(10000);
	}

	// BOTH BOUNDARIES, AND BOTH FOR THE SAME REASON. level.realtime is reset to 0
	// on a map change and on a savegame load (ResetWorldClock, g_levellocals.h:
	// 1448) while the Service is neither destroyed nor serialized, so its stamps
	// outlive the clock they were taken from. A stamp LARGER than the new clock
	// is caught by the arbiter's negative-age guard; a stamp that happens to be
	// SMALL is not, and reads as a live claim for the first two seconds of the
	// new map -- held by a mod instance that no longer exists, on a hand nobody
	// can take back. Two seconds is long enough to lose a draw.
	override void WorldLoaded(WorldEvent e)
	{
		let a = arb();
		if (a) a.GetInt("grip.clearall");

		// ONE LINE PER LEVEL SAYING WHETHER THE LEDGER IS THERE AT ALL, and it
		// earns its place: "is the arbiter present" is the question every
		// consumer answers for itself by handshake and NOBODY can answer from
		// outside. A substring lookup that silently found nothing, and a
		// consumer quietly falling back to acting alone, look identical from a
		// log -- which is how PROTOCOL 2 spent a fortnight believed to be
		// unwired while four files called it every tic.
		let c = CVar.GetCVar("rs_grip_debug", null);
		if (c == null || c.GetInt() <= 0) return;
		if (a == null)
		{
			Console.Printf("[GRIP] NO ARBITER -- ServiceIterator found nothing answering grip.hello");
			return;
		}
		Console.Printf("[GRIP] arbiter present, protocol %d, ledger cleared for %s",
			a.GetInt("grip.version"), level.MapName);
	}

	override void WorldUnloaded(WorldEvent e)
	{
		let a = arb();
		if (a) a.GetInt("grip.clearall");
	}

	override void WorldTick()
	{
		let a = arb();
		if (a == null) return;

		int touched = a.GetInt("grip.sweep");

		// THE DEBUG LINE, and it prints only on a tic where something actually
		// changed. A ledger that prints every tic is a ledger nobody reads: the
		// one event you are looking for scrolls past inside a second. 1 prints
		// the sweep; 2 prints the whole ledger with it.
		if (touched <= 0) return;
		let c = CVar.GetCVar("rs_grip_debug", null);
		if (c == null || c.GetInt() <= 0) return;

		Console.Printf("[GRIP] sweep retired %d at realtime %d", touched, level.realtime);
		if (c.GetInt() < 2) return;

		for (int p = 0; p < MAXPLAYERS; p++)
		{
			if (!playeringame[p]) continue;
			let pmo = players[p].mo;
			if (pmo == null) continue;
			for (int h = 0; h < 2; h++)
			{
				int held = a.GetInt("grip.held", "", h, 0, pmo);
				if (held != 1) continue;
				// Through String locals, not straight into the format call: a
				// Name is an int handle, and %s on one prints a number or
				// refuses to compile depending on where you do it.
				String own = a.GetName("grip.owner",  "", h, 0, pmo);
				String att = a.GetName("grip.attach", "", h, 0, pmo);
				Console.Printf("[GRIP]   p%d %s owner=%s subj=%d prio=%d pre=%d attach=%s",
					p, (h == 0) ? "main" : "off", own,
					a.GetInt("grip.subject", "", h, 0, pmo),
					a.GetInt("grip.prio",    "", h, 0, pmo),
					a.GetInt("grip.preempt", "", h, 0, pmo),
					att);
			}
		}
	}
}
