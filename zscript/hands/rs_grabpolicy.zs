// WHAT A HAND IS ALLOWED TO TAKE HOLD OF, AS DATA.
//
// The rule this replaces was two lines inside the reach code: a pickup in the
// world, yes; everything else, no. Which means a barrel is not grabbable, a
// corpse is not grabbable, and a health bonus -- a +1, an abstract quantity
// wearing a sprite -- is exactly as grabbable as a medikit.
//
// The distinction is not derivable. Nothing on an actor says "this is a thing
// with a shape you could close a hand around" as opposed to "this is a number
// that happens to be on the floor". Doom gives a medikit and a health bonus the
// same flags and very nearly the same collision cylinder -- which is also why
// the two-hand question cannot be answered from an actor's size. It has to be
// stated, and the place to state it is a table.
//
// A TABLE AND NOT A CHAIN OF IFS, because this is the part that gets tuned for a
// year. Every mod brings things that should or should not be grabbable, and the
// answer must be one line added in one place -- not a new branch buried in the
// middle of the code that decides which object your hand is nearest.
//
// Rules are ordered and the FIRST MATCH WINS, so specific sits above general: a
// rule for HealthBonus has to be able to overrule the rule for Inventory.
//
// The table answers TWO questions now, not one: whether a thing may be grabbed
// at all, and -- when several things are in reach at once -- how hard it argues
// for the hand. See the weight field below. That second answer is here for the
// same reason as the first: it is per-class knowledge that cannot be derived
// from an actor, and it gets tuned for years.

class RS_GrabRule : Object
{
	Class<Actor> cls;
	bool   allow;
	int    subject;    // what to CLAIM to the engine's grip arbiter
	int    pose;       // what SHAPE the hand makes -- a different question
	bool   twohand;    // can a second hand join, or does it take it away
	Name   category;   // which menu switch governs this rule, 'None' for always
	String why;        // named, so the log says WHICH rule decided
	double weight;     // how hard this class competes for the hand. 1.0 = neutral

	// WEIGHT IS A PREFERENCE, NOT A GATE, and the difference is the whole
	// design.
	//
	// Everything the table allows used to compete on PURE DISTANCE TO PALM.
	// After a firefight that means the room is full of things nearer your hand
	// than the barrel you are reaching for -- corpses, spent medikits, shell
	// boxes -- and the nearest one wins every time. The feature is grabbing
	// barrels; the clutter was beating the feature in exactly the rooms where
	// the feature is most wanted.
	//
	// The fix belongs HERE and not as a chain of class checks inside the code
	// that picks a target, for the reason at the head of this file: this is the
	// number that gets tuned for a year, and tuning it must stay one line in one
	// place.
	//
	// The reach test still admits on RAW distance -- inside the volume or not --
	// and only the RANKING among things already admitted is weighted. So NOTHING
	// BECOMES UNGRABBABLE: reach at a medikit with nothing else in the volume
	// and you get the medikit, whatever its weight says. Weight decides ties and
	// near-ties and can never veto, which is what makes it safe to be blunt with
	// the numbers.
	//
	// The scale is stated in RS_Reach.Best, which is the only thing that reads
	// it: the score is a SQUARED normalised distance, so dividing it by the
	// weight is the same ranking as dividing linear distance by sqrt(weight).
	// Weight 4 means "counts as half as far away". Weight 0.25 means "counts as
	// twice as far".

	// SUBJECT AND POSE ARE SEPARATE, and that is not redundancy.
	//
	// The subject is arbitration: the engine reads it to decide this hand is
	// spent on an object and must not also count as bracing a weapon. The pose
	// is appearance. Different questions, and the engine's own header argues for
	// keeping them apart.
	//
	// It matters concretely. GRIPSUBJ_Forend and GRIPSUBJ_Foregrip are the two
	// subjects the engine reads as SUPPORTING the other hand's weapon -- claim
	// either for a barrel and the arbiter concludes you are bracing a gun you
	// are not holding. But POSE_HOLD_FOREND, the fat-cylinder hand shape, is
	// exactly right for a barrel. Keeping them apart is what lets a barrel look
	// right without lying to the arbiter.
}

class RS_GrabPolicy : EventHandler
{
	private Array<RS_GrabRule> rules;

	// THE CORPSE ANSWER, ONE OBJECT, REFILLED.
	//
	// The corpse rule cannot live in the table above because it turns on STATE
	// and not class -- the same imp is a monster and then a prop, a second apart
	// -- so it is built at the moment it is asked for. It was built with `new`
	// every time, and "every time" here means per corpse per blockmap candidate
	// per hand per tic, on a floor after a firefight, on Quest-class hardware.
	//
	// Nothing outlives the call. Every caller reads subject, pose, twohand,
	// weight and why straight out of it and is done; the one field that would
	// make a shared instance wrong -- cls, which differs per corpse -- is read
	// by nobody, and it is still filled in so that stays true rather than merely
	// convenient. Weight is safe to share for the opposite reason: every corpse
	// carries the same one.
	//
	// Not built in Build() with the rest: a null pointer that comes back null
	// from a savegame is refilled by the check at the point of use, which is the
	// same "ask the thing itself rather than a flag about it" discipline the
	// table's own guard uses.
	private RS_GrabRule corpseRule;

	static RS_GrabPolicy Get()
	{
		return RS_GrabPolicy(EventHandler.Find("RS_GrabPolicy"));
	}

	// A HAND MAY TAKE A THING AS SOMETHING ELSE.
	//
	// The mod that knows what a thing is FOR can hand back a different actor to
	// be held in its place -- a weapon mod turning a map's sprite clip into the
	// magazine its guns seat, which a sprite never could be. Every Service whose
	// name contains "GrabBecomeService" is asked GetObject("grab.become",
	// intArg = hand, objectArg = the thing). One that answers with an Actor
	// other than the thing has spawned the replacement; the original is removed
	// HERE, so nothing is left behind and nothing is removed twice. Null, or the
	// thing itself, leaves it alone. The caller then asks the grab rules about
	// what is actually going to be held.
	//
	// Never for a thing already in a hand -- the caller checks. Swapping the
	// actor under RS_Held's other slot would leave that hand holding nothing.
	static Actor Become(int hand, Actor a)
	{
		if (!a) return a;
		let it = ServiceIterator.Find("GrabBecomeService");
		Service s;
		while (s = it.Next())
		{
			let b = Actor(s.GetObject("grab.become", "", hand, 0, a, 'RS_WorldHands'));
			if (!b || b == a) continue;
			a.Destroy();
			return b;
		}
		return a;
	}

	// INHERITANCE-AWARE, which is the whole reason this is not a name compare.
	//
	// A rule written for Ammo has to cover every shell box in every mod that
	// ever derived from it. And the `is` operator cannot help: it takes a class
	// written out at compile time, which is precisely what a data table cannot
	// do. So walk the chain, the way stock Ammo.GetParentClass already does.
	static bool Inherits(Actor a, Class<Actor> want)
	{
		if (!a || !want) return false;
		// Class<Object> and not Class<Actor>: GetParentClass returns the parent
		// as Class<Object>, and assigning that back into a Class<Actor> is a
		// narrowing conversion the compiler refuses. Stock Ammo.GetParentAmmo
		// walks the chain in Class<Object> for exactly this reason. The target
		// is widened to match rather than the walk being narrowed.
		Class<Object> c = a.GetClass();
		Class<Object> w = want;
		while (c)
		{
			if (c == w) return true;
			c = c.GetParentClass();
		}
		return false;
	}

	// WEIGHT IS LAST AND DEFAULTED, so a line that does not care about priority
	// is written exactly as it was before this went in -- neutral, pure
	// distance, today's behaviour. A trailing default on a plain ZScript method
	// is stock practice: A_SpriteOffset(double ox = 0.0, double oy = 0.0),
	// wadsrc actions.zs:159.
	private void Rule(Name clsName, bool allow, int subject, int pose,
		bool twohand, Name category, String why, double weight = 1.0)
	{
		// A CLASS THAT DOES NOT EXIST IS NOT AN ERROR. This table names Doom
		// classes and it loads under Heretic and Hexen too, where half of them
		// are absent. A missing class means a rule that can never match, which
		// is the correct outcome -- and skipping it quietly is the only way the
		// table can name classes from mods that may or may not be loaded.
		Class<Actor> c = clsName;
		if (!c) return;

		RS_GrabRule r = RS_GrabRule(new("RS_GrabRule"));
		r.cls      = c;
		r.allow    = allow;
		r.subject  = subject;
		r.pose     = pose;
		r.twohand  = twohand;
		r.category = category;
		r.why      = why;
		// A zero or negative weight is a typo in a table line, not a request to
		// divide by zero in the middle of a per-tic blockmap scan. Fall back to
		// neutral, the same way SemiAxes handles a zeroed master scale
		// (rs_grab.zs, `if (m <= 0) m = 1.0;`).
		r.weight   = (weight > 0) ? weight : 1.0;
		rules.Push(r);
	}

	private void Deny(Name clsName, String why)
	{
		Rule(clsName, false, GRIPSUBJ_None, -1, false, 'None', why);
	}

	// ---- THE TABLE -------------------------------------------------------

	// GUARDED ON THE TABLE BEING EMPTY, not on a "have I built this" flag.
	//
	// A flag and the thing it describes are two pieces of state that can
	// disagree, and a savegame is where they do it: this handler's fields are
	// serialised, so a restored `built = true` sitting over an array that did
	// not come back leaves the table permanently empty and every object in the
	// world permanently ungrabbable, with nothing logged. Asking the array
	// whether it is populated cannot get out of step with the array.
	private void Build()
	{
		if (rules.Size() > 0) return;

		// -- DENIED, and specific, so these sit above the general allows -----

		// The "+1" pickups. A health bonus is not a small medikit, it is a
		// number with a sprite: there is no object there to close a hand round,
		// and picking one up by hand and having it NOT heal you would read as
		// broken. Walk over them.
		Deny('HealthBonus', "a +1 is a number, not an object");
		Deny('ArmorBonus',  "a +1 is a number, not an object");

		// Powerup spheres and artefacts hover, spin and glow. They are not
		// props, and a hand closing on one raises the question of what happens
		// when you let go of a soulsphere, which has no good answer.
		Deny('Soulsphere', "not a prop");
		Deny('Megasphere', "not a prop");
		Deny('InvulnerabilitySphere', "not a prop");
		Deny('Blursphere', "not a prop");
		Deny('Infrared',   "not a prop");
		Deny('RadSuit',    "worn, not carried");
		Deny('Allmap',     "not a prop");
		Deny('Berserk',    "not a prop");

		// -- ALLOWED, specific ----------------------------------------------

		// The barrel. Big, round, and the single most satisfying thing in Doom
		// to pick up and put somewhere else. Two hands, because it is the size
		// of a thing you would need two hands for -- and FOREND is the shape a
		// hand makes round a fat cylinder.
		//
		// The heaviest weight in the table, because this is the thing the whole
		// system is for. 4.0 -- it competes as though it were at half the
		// distance -- so a shell box lying nearer your palm does not quietly win
		// the barrel you were plainly reaching for.
		Rule('ExplosiveBarrel', true, GRIPSUBJ_Magazine,
			RS_HandWorldBase.POSE_HOLD_FOREND, true, 'Barrels', "a barrel", 4.0);

		// THE OTHER BARREL, and it is not related to the one above in any way
		// the engine can see. BurningBarrel is a plain decoration -- `class
		// BurningBarrel : Actor` with Radius 16, Height 32 and +SOLID -- while
		// ExplosiveBarrel is an Actor of its own lineage. Nothing inherits from
		// anything here, so the rule above could never have covered it.
		//
		// Which meant the one prop in Doom that most obviously reads as "a
		// barrel you could pick up" was the one you could not, with no reason
		// visible in the game. Added 2026-08-28 on exactly that report.
		//
		// Same shape, weight and category as its cousin: it is the same object
		// to a pair of hands, so it should compete the same way and answer the
		// same switch. +SOLID is no obstacle -- SaveFlags borrows THRUACTORS
		// for the duration of any hold, which is what already lets the
		// explosive one be carried.
		//
		// NOT AN Inventory, and that is fine: Decide's ownership test only runs
		// when the cast succeeds, so a decoration simply skips it. This is the
		// first non-Inventory entry in the table and the path is worth knowing
		// about -- every other vanilla prop is ungrabbable for want of a line
		// exactly like this one.
		Rule('BurningBarrel', true, GRIPSUBJ_Magazine,
			RS_HandWorldBase.POSE_HOLD_FOREND, true, 'Barrels', "a burning barrel", 4.0);

		// -- ALLOWED, general -------------------------------------------------

		// Ammunition. Boxes, clips, shells, cells: objects, one hand each.
		//
		// Below neutral. Ammo is the most numerous thing on a cleared floor and
		// the least interesting to have chosen for you; walking over it works
		// and always has.
		Rule('Ammo', true, GRIPSUBJ_Magazine,
			RS_HandWorldBase.POSE_HOLD_MAG, false, 'None', "ammunition", 0.6);

		// Weapons on the floor. Held by the grip, one hand, and deliberately NOT
		// two-handable here: a weapon in two hands is the stabilize and support
		// system's business, not this one's. Defaults OFF -- picking a shotgun
		// up by hand instead of walking over it is a whole interaction and it
		// wants deciding on purpose.
		//
		// Weighted UP despite that, and because of it: the switch is off by
		// default, so having it on is an explicit statement that you want to
		// take guns off the ground by hand. Having done that, the gun should not
		// lose to the clip lying next to it.
		Rule('Weapon', true, GRIPSUBJ_Grip,
			RS_HandWorldBase.POSE_POINT, false, 'Weapons', "a weapon on the floor", 2.0);

		// Health and armour, the real ones -- the bonuses were denied above.
		// Below neutral for the same reason as ammo: numerous, and picked up
		// perfectly well by walking.
		Rule('Health', true, GRIPSUBJ_Magazine,
			RS_HandWorldBase.POSE_HOLD_MAG, false, 'None', "a health item", 0.6);
		Rule('Armor', true, GRIPSUBJ_Magazine,
			RS_HandWorldBase.POSE_HOLD_MAG, false, 'None', "armour", 0.6);

		// Keys. Small, and a key held in your hand and offered to a lock is one
		// of the few genuinely new things hands make possible.
		//
		// Above neutral. There are never many of them, reaching for one is
		// always deliberate, and a keycard is small enough that something duller
		// is easily nearer the palm than it is.
		Rule('Key', true, GRIPSUBJ_Round,
			RS_HandWorldBase.POSE_HOLD_ROUND, false, 'None', "a key", 2.0);

		// The catch-all for anything else a mod leaves in the world. LAST, so
		// every rule above overrules it.
		//
		// NEUTRAL, deliberately, and it is the only line where neutral is the
		// considered answer rather than the absence of one: this rule fires when
		// we do not know what the object is, and pure distance is the honest
		// answer to that. A mod that wants better says so with its own line.
		Rule('Inventory', true, GRIPSUBJ_Magazine,
			RS_HandWorldBase.POSE_HOLD_MAG, false, 'None', "a pickup in the world", 1.0);
	}

	override void OnRegister()
	{
		Build();
	}

	// ---- WALKING OVER THINGS ---------------------------------------------
	//
	// Doom picks an item up the instant your collision cylinder touches it, and
	// in VR your cylinder arrives a long time before your hand does. So every
	// pickup in the room is gone before you can reach for one, and the grab you
	// were about to make never gets a chance to happen.
	//
	// Suppressing it is one flag: SPECIAL off and P_TouchSpecialThing never
	// fires. What makes it more than one line is that the flag has to be put
	// back -- when the switch is turned off again, and only on the things this
	// system turned it off on.
	//
	// ENFORCED RATHER THAN REMEMBERED. Nothing records which items were
	// suppressed; the sweep just sets every grabbable floor item to the state
	// the switch currently asks for. A record of what we changed is a second
	// copy of the truth, and it goes stale the first time something spawns,
	// dies or gets picked up while the record is not looking.

	private bool lastNoWalk;
	private int  lastCats;   // bitmask of the category switches, see WorldTick

	private void ApplyOne(Actor a, PlayerPawn pmo, PlayerInfo p, bool noWalk)
	{
		if (!a) return;

		// A held item is left alone. Turning the switch off while something is
		// in your hand would otherwise hand SPECIAL back to an object sitting
		// inside your own collision cylinder, and it would vanish into your
		// inventory out of your closed fist.
		let held = RS_Held.Get();
		if (held && held.IsHeld(a)) return;

		let inv = Inventory(a);
		if (!inv || inv.Owner) return;

		// Never resurrect something that was already hidden. An invisible or
		// unrendered item is deliberately not a pickup, and handing it SPECIAL
		// makes it collectable by walking through empty-looking air.
		// GetRenderStyle(), not RenderStyle. The field is declared
		// `native private int RenderStyle;` (actor.zs:628, with the engine's own
		// note that it "is kept private until its real type has been implemented
		// into the VM"), so reading it from an EventHandler is a hard "Private
		// member not accessible" compile error -- fatal and global. The public
		// read is `native clearscope int GetRenderStyle() const` at actor.zs:971,
		// which returns the symbolic index and is legal from play scope.
		if (a.bINVISIBLE || a.GetRenderStyle() == STYLE_None) return;

		// RESTORE TO THE CLASS DEFAULT, never unconditionally to true. Fixed
		// 2026-08-26: this was `a.bSPECIAL = !noWalk;`, which GRANTS SPECIAL to
		// every qualifying Inventory actor when walk-over is switched back on,
		// including ones that shipped without it and were never pickups. This
		// mod only ever suppresses, so the most it should ever restore is what
		// the class itself declares.
		//
		// The `default.` accessor has precedent in the family -- RS_Reload
		// reads w.default.AmmoGive1 at rr_feed.zs:296.
		// NOT an early return on a null rule. Decide() is null when the
		// category is switched off, and a pickup whose SPECIAL was cleared
		// while the category was ON has to get walk-over back -- otherwise
		// it can be neither walked over nor grabbed until the next map.
		bool grabbable = (Decide(a, pmo, p) != null);
		a.bSPECIAL = (noWalk && grabbable) ? false : a.default.bSPECIAL;
	}

	private void Sweep(PlayerPawn pmo, PlayerInfo p, bool noWalk)
	{
		ThinkerIterator it = ThinkerIterator.Create("Inventory");
		Actor a;
		while (a = Actor(it.Next()))
			ApplyOne(a, pmo, p, noWalk);
	}

	override void WorldThingSpawned(WorldEvent e)
	{
		let p = players[consoleplayer];
		if (!p || !p.mo) return;
		bool noWalk = Flag("rs_grab_nowalkover", p, true);
		if (!noWalk) return;
		ApplyOne(e.Thing, p.mo, p, noWalk);
	}

	override void WorldLoaded(WorldEvent e)
	{
		let p = players[consoleplayer];
		if (!p || !p.mo) return;
		lastNoWalk = Flag("rs_grab_nowalkover", p, true);
		Sweep(p.mo, p, lastNoWalk);
	}

	override void WorldTick()
	{
		let p = players[consoleplayer];
		if (!p || !p.mo) return;

		// One bool compare per tic. The sweep only runs on the tic the switch
		// actually moves -- there is no menu callback for a cvar, and polling a
		// bool is cheaper than the ThinkerIterator it guards.
		bool noWalk = Flag("rs_grab_nowalkover", p, true);
		// The category switches move the same way, and a sweep is the only
		// thing that applies a change to pickups already on the map.
		int cats = (Flag("rs_grab_barrels", p, true)  ? 1 : 0)
		         | (Flag("rs_grab_weapons", p, false) ? 2 : 0)
		         | (Flag("rs_grab_corpses", p, true) ? 4 : 0);
		if (noWalk == lastNoWalk && cats == lastCats) return;
		bool walkChanged = (noWalk != lastNoWalk);
		lastNoWalk = noWalk;
		lastCats   = cats;
		Sweep(p.mo, p, noWalk);
		if (walkChanged)
			Console.Printf("[RSGRAB] walking over pickups is now %s",
				noWalk ? "OFF -- reach for them" : "ON -- vanilla pickup");
	}

	// ---- the question ----------------------------------------------------

	private static bool Flag(String n, PlayerInfo p, bool d)
	{
		let c = CVar.GetCVar(n, p);
		return c ? c.GetBool() : d;
	}

	private static bool CategoryOn(Name cat, PlayerInfo p)
	{
		if (cat == 'Barrels') return Flag("rs_grab_barrels", p, true);
		if (cat == 'Weapons') return Flag("rs_grab_weapons", p, false);
		// TRUE, matching CVARINFO (rs_grab_corpses ships ON). This fallback is what runs when the
		// cvar cannot be found at all, and a fallback that disagrees with the
		// shipped default is a system that behaves differently depending on
		// whether a lookup succeeded -- the worst kind of intermittent. See
		// CVARINFO for why corpses are off: the novelty was beating the feature.
		if (cat == 'Corpses') return Flag("rs_grab_corpses", p, true);
		return true;
	}

	// WHAT TAKING HOLD OF THIS ACTUALLY DOES.
	//
	// Called by every path that puts something in a hand -- a near grab and a
	// catch out of the air alike -- BEFORE the held-state machine is told about
	// it. Returns true when the object was consumed and must not be held.
	//
	// The weapon rule, in full:
	//   own 0 or 1, hand empty  -> equipped and ready to fire
	//   own 2                   -> vanishes, and lands as its own ammo
	//   hand not empty          -> held as an object, equipped by nothing
	//
	// Two is the dual-wield ceiling, so a third of the same gun is only worth
	// what is in it. That case needs no code: Weapon.TryPickup on a weapon you
	// already own gives you its ammo and takes the world copy away, which is
	// precisely the behaviour wanted, so it is simply allowed to happen.
	//
	// Everything that is NOT a weapon is held, deliberately. Health and armour
	// are consumed at your face and nowhere else -- if catching a medikit used
	// it, catching would be indistinguishable from the walk-over that was
	// switched off on purpose.
	// fromAir: the object arrived by RS_Pull (a catch) rather than off the
	// floor. Only a catch consumes health/armour on the spot -- see below.
	bool OnTake(int hand, Actor a, RS_GrabRule rule, PlayerPawn pmo, PlayerInfo p, bool fromAir = false)
	{
		if (!a || !rule || !pmo) return false;

		// AMMUNITION GOES TO THE POUCH NOW, and this branch is the OLD
		// behaviour, kept behind rs_use_ammo_pouch for anyone who wants it.
		//
		// The old argument was: nobody brings a shell box to their mouth, so
		// health and armour get the face gesture and ammo just resolves. The
		// face half of that still stands and is untouched. The other half did
		// not survive contact with the actual game.
		//
		// A box you DON'T catch lands at your feet and is collected by standing
		// there anyway. So resolving one on the catch produced the identical
		// outcome as missing it -- the catch was skilful and paid exactly what
		// fumbling paid. Holding it until you put it in the pouch is what makes
		// catching an act rather than an event, and the pouch is the same
		// anchor RR_Reload draws magazines out of, so ammunition goes back in
		// the way it comes out. The stow itself lives in RS_Holsters, which
		// owns that anchor.
		//
		// This switch was inert for a long time -- the pouch it named had died
		// with RS_UnifiedVR, and the note here said so. It is live as of
		// 2026-08-28.
		if (Inherits(a, 'Ammo') && !Flag("rs_use_ammo_pouch", p, true))
		{
			let inv = Inventory(a);
			if (inv && !inv.Owner)
			{
				bool got = inv.CallTryPickup(pmo);
				if (Flag("rs_hand_debug", p, true))
					Console.Printf("[RSTAKE] %s -- %s", a.GetClassName(),
						got ? "ammo taken on catch" : "refused, holding it");
				return got;
			}
		}

		// HEALTH AND ARMOUR APPLY ON CATCH, BY DOOM'S OWN RULES.
		//
		// CallTryPickup IS the decision, not a wrapper round one: stock Health
		// refuses at full, stock Armor refuses when it would not improve what
		// you already wear, and every mod's own rule runs untouched. Asking it
		// is the whole test -- "do I need this" has one correct answer per item
		// and it was never ours to invent.
		//
		// Refused means you keep holding it. Full health and a medikit in your
		// hand is the right outcome: it is still a medikit, and it will still be
		// one when you are hurt.
		// ON CATCH ONLY. A medikit picked up off the floor by hand is HELD --
		// it is consumed at your face (RS_Route) and nowhere else, which is
		// the contract the header above states and the one rs_use_at_face
		// exists for. Without the fromAir gate a floor grab used it on the
		// spot, exactly like the walk-over that rs_grab_nowalkover turns off.
		if (fromAir && (Inherits(a, 'Health') || Inherits(a, 'Armor')))
		{
			let hinv = Inventory(a);
			if (hinv && !hinv.Owner)
			{
				bool used = hinv.CallTryPickup(pmo);
				if (Flag("rs_hand_debug", p, true))
					Console.Printf("[RSTAKE] %s -- %s", a.GetClassName(),
						used ? "used on catch" : "not needed, holding it");
				return used;
			}
		}

		if (rule.category != 'Weapons') return false;

		let w = Weapon(a);
		if (!w) return false;

		int owned = pmo.CountInv(a.GetClassName());
		let held = RS_Held.Get();
		bool handFree = !held || !held.HandIsFull(hand);

		if (owned >= 2)
		{
			// Stock pickup. It gives the ammo and removes the world copy.
			bool took = w.CallTryPickup(pmo);
			if (Flag("rs_hand_debug", p, true))
				Console.Printf("[RSTAKE] %s -- already carrying two, %s",
					a.GetClassName(), took ? "took its ammo" : "refused");
			return took;
		}

		if (!handFree) return false;    // hold it; arming is a separate decision

		bool took = w.CallTryPickup(pmo);
		if (took && pmo.player)
		{
			// THE INSTANCE IN THE INVENTORY, which is `w` only when this class
			// was not owned before. For an owned class TryPickup routes into
			// the owned weapon's HandlePickup, takes the ammo and puts the
			// world copy into HoldAndDestroy -- pointing PendingWeapon at
			// that dying actor made the held gun dip and pop back with
			// nothing raised.
			let mine = Weapon(pmo.FindInventory(w.GetClass()));   // class<Weapon>, which FindInventory accepts
			if (mine == null) mine = w;

			// THE HAND THAT REACHED FOR IT. BringUpWeapon picks the slot from
			// bOffhandWeapon alone, and a weapon fresh off the floor has it
			// false -- so an off-hand grab used to raise the gun in the MAIN
			// hand and leave the reaching hand empty. Same write
			// SwitchWeaponHand makes before its own BringUpWeapon.
			mine.bOffhandWeapon = (hand == 1);
			if (mine.SisterWeapon != null)
				mine.SisterWeapon.bOffhandWeapon = (hand == 1);

			// PendingWeapon rather than ReadyWeapon: the switch has to go
			// through BringUpWeapon or the raise animation never runs and the
			// gun appears already up, which reads as a glitch.
			pmo.player.PendingWeapon = mine;
		}
		if (Flag("rs_hand_debug", p, true))
			Console.Printf("[RSTAKE] %s -- %s", a.GetClassName(),
				took ? "equipped" : "refused, holding it instead");
		return took;
	}

	// Null means no.
	//
	// The RULE comes back rather than a bool, so the caller gets the subject,
	// the pose and the two-hand answer out of the same decision. Three separate
	// lookups are three answers that can disagree about one object.
	RS_GrabRule Decide(Actor a, PlayerPawn pmo, PlayerInfo p)
	{
		if (!a || a == pmo || !p) return null;

		// Never, whatever the table says. Not policy -- these are the difference
		// between an object and a thing that is not there.
		if (a.bNOINTERACTION) return null;
		if (a.bMISSILE)       return null;      // in flight, not on the floor
		if (a.player)         return null;      // another player
		if (a.Radius <= 0 || a.Height <= 0) return null;

		// LIVING THINGS ARE NOT PROPS. A live imp is doing something, and taking
		// it out of the world by closing a hand round it is not an interaction,
		// it is a way of deleting monsters. A corpse is a prop, and one worth
		// having. Handled here rather than in the table because it turns on
		// STATE, not class -- the same imp is both, a second apart.
		if (a.bISMONSTER)
		{
			if (a.Health > 0) return null;
			if (!CategoryOn('Corpses', p)) return null;

			// One instance, refilled -- see the field. Every value is written on
			// every pass, so a stale one cannot survive from the last corpse.
			if (!corpseRule) corpseRule = RS_GrabRule(new("RS_GrabRule"));
			corpseRule.cls      = a.GetClass();
			corpseRule.allow    = true;
			corpseRule.subject  = GRIPSUBJ_Magazine;
			corpseRule.pose     = RS_HandWorldBase.POSE_HOLD_FOREND;
			corpseRule.twohand  = true;                   // it is a body
			corpseRule.category = 'Corpses';
			corpseRule.why      = "a corpse";
			// THE LOWEST WEIGHT IN THE SYSTEM, and the reason the switch above
			// it now defaults off. A corpse is a large collision cylinder lying
			// exactly where the fighting was, which is exactly where you are
			// standing when you reach for something -- so on pure distance a
			// body wins over almost anything worth having. 0.25: it competes as
			// though it were at twice the distance. Turn corpses on and you can
			// still drag one about; you just have to reach for the body rather
			// than for the barrel behind it.
			corpseRule.weight   = 0.25;
			return corpseRule;
		}

		// WHAT A MOD SAID ABOUT ITS OWN THING BEATS THE TABLE.
		//
		// Strictly more specific: a rule naming a class was written by whoever
		// made that class, and it knows a single ejected cartridge wants the
		// fingertip pose rather than the magazine wrap. Above the general rules
		// for the same reason HealthBonus sits above Inventory.
		//
		// The ownership test below still runs on it -- a registered rule says
		// what a thing IS, not that it is lying on the floor.
		let svc = RS_GrabRuleService.Find();
		if (svc)
		{
			let r = svc.Match(a);
			if (r)
			{
				let inv = Inventory(a);
				if (inv && inv.Owner) return null;
				return r;
			}
		}

		Build();
		for (int i = 0; i < rules.Size(); i++)
		{
			let r = rules[i];
			if (!Inherits(a, r.cls)) continue;
			if (!r.allow) return null;
			if (!CategoryOn(r.category, p)) return null;

			// OWNERSHIP, not SPECIAL, decides whether an Inventory item is on
			// the floor.
			//
			// SPECIAL used to be the test, and it cannot be one any more: this
			// file now clears SPECIAL deliberately, to stop you hoovering things
			// up by walking over them. Under the old test that suppression would
			// have made every pickup in the level ungrabbable at the same moment
			// it made them unwalkable -- the feature would have removed the
			// items from the game entirely.
			//
			// An Inventory with no Owner is lying in the world. One with an
			// Owner is in somebody's pockets and is not a thing in the room at
			// all. That is the real question, and it does not care what SPECIAL
			// happens to be.
			let inv = Inventory(a);
			if (inv && inv.Owner) return null;
			return r;
		}
		return null;
	}
}

// A MOD REGISTERS ITS OWN GRABBABLE THING, AT RUNTIME.
//
// The table above is per-class knowledge, and the header says it right: every
// mod brings things that should or should not be grabbable, and the answer must
// be one line in one place. That was true when the only mod was this one.
//
// With a family of them it stops working. A weapon mod's ejected round wants
// POSE_HOLD_ROUND, its magazine wants POSE_HOLD_MAG, and the only way to say so
// was a line in Build() naming that mod's classes -- per-mod special-casing in
// the shared package, and a table that grows a section per lane. Worse, the
// numbers it needs (GRIPSUBJ_*, POSE_HOLD_*) are declared over here, so a mod
// wanting to name them takes a COMPILE-TIME dependency on this pk3 and every
// pk3 after it dies when this one is absent.
//
// So: the same shape the grip arbiter and the hand pose already use. A Service,
// reached by string, that takes a CLASS NAME as text and the three answers the
// rule carries. Nothing here learns any mod's name, and no mod names anything
// here.
//
// REGISTERED RULES SIT ABOVE THE BUILT-IN TABLE, because they are strictly more
// specific: a mod naming its own class knows more about it than a rule written
// for Inventory. Ordered among themselves by registration, first match wins,
// exactly like the table.
//
// INHERITANCE-AWARE, the same way. A mod registering its own Ammo base covers
// everything it derives from it, which is the whole reason Inherits exists.
class RS_GrabRuleService : Service play
{
    // The rules mods have added this session. Rebuilt on load like the table --
    // a Service is not serialised, and every consumer re-registers in its own
    // OnRegister, so there is nothing to persist and nothing to go stale.
    private Array<RS_GrabRule> added;

    // Reached from RS_GrabPolicy.Decide, which is inside this pk3 and may name
    // this class freely.
    static RS_GrabRuleService Find()
    {
        ServiceIterator it = ServiceIterator.Find("RS_GrabRuleService");
        Service s;
        while (s = it.Next())
        {
            let g = RS_GrabRuleService(s);
            if (g) return g;
        }
        return null;
    }

    // The first registered rule matching this actor, or null.
    RS_GrabRule Match(Actor a)
    {
        for (int i = 0; i < added.Size(); i++)
        {
            let r = added[i];
            if (!r.cls) continue;
            if (!RS_GrabPolicy.Inherits(a, r.cls)) continue;
            return r;
        }
        return null;
    }

    override int GetInt(String request, String stringArg, int intArg, double doubleArg, Object objectArg, Name nameArg)
    {
        // IDENTITY, not presence -- ServiceIterator matches a case-insensitive
        // SUBSTRING, so every consumer in this family checks a hello first.
        if (request ~== "grab.hello") return 1;

        // grab.rule -- stringArg is the class name, intArg the GRIPSUBJ_*
        // subject, doubleArg the POSE_* frame, nameArg the registering mod.
        // A pose of -1 means "no opinion, let the controllers decide".
        if (request ~== "grab.rule")
        {
            Class<Actor> c = stringArg;
            // A CLASS THAT DOES NOT EXIST IS NOT AN ERROR, the same as in the
            // table: a mod may register for something that is not loaded, and a
            // rule that can never match is the correct outcome.
            if (!c) return 0;

            // Re-registering a class REPLACES rather than stacks, so a mod that
            // registers in OnRegister and again after a level change does not
            // grow the list every map.
            for (int i = 0; i < added.Size(); i++)
            {
                if (added[i].cls == c) { added.Delete(i); break; }
            }

            let r = RS_GrabRule(new("RS_GrabRule"));
            r.cls      = c;
            r.allow    = true;
            r.subject  = intArg;
            r.pose     = int(doubleArg);
            // Two-hand and weight ride the same call rather than needing two
            // more requests: a magazine and a corpse differ on both, and a
            // caller that cares about one usually cares about the other.
            // Packed into nameArg's slot would be worse than a sane default.
            r.twohand  = false;
            r.category = 'None';
            r.weight   = 1.0;
            r.why      = String.Format("registered by %s", nameArg);
            added.Push(r);
            return 1;
        }

        // grab.weight -- tune an already-registered class. Split from the rule
        // above because weight is the number that gets dialled for a year and
        // the subject is the one that never changes.
        if (request ~== "grab.weight")
        {
            Class<Actor> c = stringArg;
            if (!c) return 0;
            for (int i = 0; i < added.Size(); i++)
            {
                if (added[i].cls != c) continue;
                if (doubleArg > 0) added[i].weight = doubleArg;
                added[i].twohand = (intArg != 0);
                return 1;
            }
            return 0;
        }

        if (request ~== "grab.forget")
        {
            Class<Actor> c = stringArg;
            if (!c) return 0;
            for (int i = 0; i < added.Size(); i++)
            {
                if (added[i].cls != c) continue;
                added.Delete(i);
                return 1;
            }
            return 0;
        }

        return 0;
    }
}
