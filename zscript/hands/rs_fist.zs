// A hand's fallback identity: whatever "empty" looks like for this player,
// and the ability to actually put that in a hand.
//
// MOVED HERE FROM RS_Holsters.zs, 2026-08-28. It started as Holsters' own
// private helper -- the only lane that ever needed to turn a full hand back
// into a fist was the one that empties hands into holsters. It belongs here
// instead because the underlying idea isn't a holster concept at all: RS_Hands
// is what already claims to be the always-on hand, the drop-in Fist for
// whatever a hand isn't currently holding. Any lane that needs to empty a
// hand -- not just this one, not just today -- should ask THIS file, not
// grow its own copy. RS_HolsterManager calls RS_HandFist.FindOrMakeFist now
// instead of keeping its own.
//
// PLAY SCOPE, DECLARED, same reasoning as RS_Reach right above this file's
// sibling in rs_grab.zs: a class that names neither a scope nor a parent
// defaults to DATA, and data cannot call a play function -- which is
// everything interesting below (Actor.Spawn, AttachToOwner, reading
// pawn.player.ReadyWeapon/OffhandWeapon all require play).
class RS_HandFist play
{
	// Whatever this player's melee weapon actually is. Walks inventory rather
	// than naming a class, so it survives new player classes and new fist
	// variants without edits here.
	// Must return a fist that ALREADY belongs to the hand being filled.
	// MoveWeaponToHand's first guard is:
	//     if (weap.bNoHandSwitch && weap.bOffhandWeapon != (hand == 1)) return;
	// and every fist here carries +WEAPON.NOHANDSWITCH -- so handing it the
	// main-hand fist for the off hand makes it bail SILENTLY. That was the
	// "offhand never lets go of the gun" bug: the store happened, the hand
	// was never emptied, and nothing reported a failure.
	// One definition of "is this a fist", used by both the store guard and the
	// fist lookup. Name-based first -- see the note at the store guard --
	// PLUS a fallback for a pack that replaces Fist under an unrelated name.
	//
	// BrutalDoom's own melee weapon is "ACTOR Melee_Attacks : BrutalWeapon
	// Replaces Fist" -- no "Fist" anywhere in the class name, so the naming
	// convention alone never finds it. Every store attempt committed the
	// weapon to the holster table, then found no fist to put in the now-
	// empty hand and rolled the whole thing back -- "no %s-hand fist to
	// empty into" on literally every press, which is what "BrutalDoom does
	// not holster anything" turned out to mean. GetReplacement asks the
	// engine's own replacement table what currently occupies Fist's slot,
	// which is exactly the relationship a pack in this shape actually
	// declares, regardless of what it named the result.
	static bool IsFistClass(class<Actor> cls)
	{
		if (cls == null)
			return false;
		// GetClassName() is a Name; IndexOf is a String method, so it has
		// to land in a string first.
		// THE ONE DEFINITION. RS_HandsAlwaysOn.IsFist delegates here, so the
		// drawing side and the store guard cannot disagree about a weapon:
		// a Fist subclass, any class with "fist" in its name (any case), or
		// whatever replaces Fist in DECORATE.
		if (cls is 'Fist')
			return true;
		string cn = cls.GetClassName();
		cn = cn.MakeLower();
		if (cn.IndexOf("fist") >= 0)
			return true;

		class<Actor> repl = Actor.GetReplacement((class<Actor>)("Fist"));
		return repl != null && repl == cls;
	}

	static Weapon FindOrMakeFist(PlayerPawn pawn, bool offhand)
	{
		Weapon spare = null;
		Weapon otherHandWeapon = offhand ? pawn.player.ReadyWeapon : pawn.player.OffhandWeapon;

		// Remembered even when it never becomes SPARE below -- the clone
		// fallback further down needs a class to copy even when every
		// existing instance is busy. Any recognised fist instance names it;
		// they are never a mix of classes in practice (one player, one
		// active tier), so which one wins when there is a choice does not
		// matter.
		class<Actor> fistClass = null;

		for (Inventory item = pawn.Inv; item != null; item = item.Inv)
		{
			let w = Weapon(item);
			if (w == null)
				continue;
			if (!IsFistClass(w.GetClass()))
				continue;

			if (w.bOffhandWeapon == offhand)
				return w;      // the one that belongs in this hand

			fistClass = w.GetClass();

			// A CANDIDATE FOR THE FALLBACK BELOW, remembered but not returned
			// yet -- an exact match anywhere later in the chain still wins.
			// Never the weapon currently seated in the OTHER hand: that
			// instance is busy, full stop, no flag fixup changes that.
			if (spare == null && w != otherHandWeapon)
				spare = w;
		}

		if (spare != null)
		{
			// THE FALLBACK, DONE THE WAY THE OLD ONE WASN'T.
			//
			// A genuinely-named, unclaimed off-hand fist (this arsenal's own
			// "Offhand_Fist") was sitting right there in inventory and
			// findFist walked past it, because
			// bOffhandWeapon is not a fixed "which hand this is for" label --
			// it is the engine's own live "which hand did I most recently get
			// seated in" tracker (player.zs:2629,
			// `weap.bOffhandWeapon = hand == 1;`, written unconditionally
			// inside MoveWeaponToHand every time a weapon is placed). A fist
			// that has never yet been drawn into ANY hand still reads its
			// class default, which is false for both -- so a genuinely
			// off-hand-only fist that has simply never been used yet fails
			// the exact-match test above for the exact same reason a
			// main-hand one would.
			//
			// The comment this replaces tried a fallback that returned a
			// mismatched fist WITHOUT fixing its flag first, and that failed
			// for a documented reason: MoveWeaponToHand's own first guard is
			//     if (weap.bNoHandSwitch && weap.bOffhandWeapon != (hand==1)) return;
			// and every fist here carries +WEAPON.NOHANDSWITCH, so hand it a
			// fist still flagged for the wrong side and MoveWeaponToHand
			// bails SILENTLY before doing anything -- the store completes,
			// the hand is never emptied, and nothing reports why.
			//
			// So: set the flag to match the hand THIS CALL is filling, before
			// handing it back. That is exactly what MoveWeaponToHand would do
			// to it anyway, the moment it successfully seats -- doing it here
			// only means the guard sees a fist already correctly labelled for
			// where it is about to go, instead of rejecting it on the way in.
			spare.bOffhandWeapon = offhand;
			// A sister is a same-hand twin (the powered-up form), so it takes
			// the same label -- UNLESS it is the fist seated in the other hand,
			// which an older build of the clone branch below used to wire up
			// as a sister. Relabelling that one would flip the other hand.
			if (spare.SisterWeapon != null && spare.SisterWeapon != otherHandWeapon)
				spare.SisterWeapon.bOffhandWeapon = offhand;
			return spare;
		}

		// CONFIRMED IN HEADSET, 2026-08-28, FOR BRUTAL DOOM'S CLASSIC MODE
		// SPECIFICALLY -- not "Brutal Doom" broadly, and that distinction
		// matters: BD/Project Brutality ship a separate old-school weapon
		// set alongside their main one, and the inventory dump that proved
		// this was single-instance ("ClassicFist", permanently offhand=0
		// because it happened to be the main hand's weapon at spawn) was
		// taken in that mode. Nothing here was re-tested against BD's main
		// weapon set.
		//
		// Reasoned, not verified, for that main set: BD's non-Classic melee
		// weapon has historically been implemented as a class that REPLACES
		// Fist in DECORATE (long-standing BD architecture, not specific to
		// this install), which IsFistClass's replacement check above would
		// catch the same way regardless of what the class is named -- so
		// this same single-instance problem, if it exists there too, should
		// hit this same branch. Not confirmed.
		//
		// KNOWN GAP: Project Brutality's melee is tiered -- multiple distinct
		// classes as the player finds upgrades, not necessarily one static
		// class. Any tier that neither has "Fist" in its name nor replaces
		// Fist in DECORATE slips past IsFistClass entirely, and this whole
		// mechanism -- old code and this fallback both -- never engages for
		// it. Unverified either way; would need PB's own source or another
		// headset pass to confirm, neither of which this fix has.
		//
		// WHY THE MECHANISM STILL APPLIES REGARDLESS OF WHICH CLASS TRIGGERS
		// IT: nothing below names "ClassicFist" or any other specific class.
		// It clones whatever IsFistClass actually recognised. This mod's own
		// tiers never hit this branch at all -- their starting loadout spawns
		// one instance PER HAND -- so for them this is dead code, not a
		// changed behaviour.
		//
		// So: clone it. fistClass names whatever was actually found, not a
		// class this mod picked -- a Brutal Doom player keeps Brutal Doom's
		// own fists, damage and animations included, in both hands, rather
		// than one hand quietly switching to this mod's native fist.
		//
		// Spawn + AttachToOwner, NOT GiveInventory: GiveInventory on a class
		// already owned re-enters TryPickup/HandlePickup against the
		// EXISTING instance (that is how ammo top-ups from a floor pickup
		// work) -- for a Weapon that means "find the one already owned, add
		// its ammo, hand back that same pointer," never a second, distinct,
		// hand-holdable instance. AttachToOwner skips TryPickup entirely and
		// inserts a freshly spawned actor straight into the inventory chain,
		// which is the only one of the two that can produce a genuinely
		// second instance of a class built with no idea this engine ever
		// wants two of it at once.
		//
		// NO IN-REPO PRECEDENT for AttachToOwner specifically -- every other
		// line in this fix mirrors an already-proven pattern elsewhere in
		// this codebase; this call does not. If this is where a load fails,
		// this is the line to look at first.
		if (fistClass != null)
		{
			let fresh = Weapon(Actor.Spawn(fistClass, pawn.Pos, NO_REPLACE));
			if (fresh != null)
			{
				fresh.AttachToOwner(pawn);
				fresh.bOffhandWeapon = offhand;

				// NOT sister-linked to the fist in the other hand. SisterWeapon
				// means "this weapon's other form, in the SAME hand" to the
				// engine: BringUpWeapon and MoveWeaponToHand both write
				// SisterWeapon.bOffhandWeapon = <the hand being filled>, and
				// Weapon.OnDestroy destroys the sister. A cross-hand link
				// therefore relabelled the other hand's fist on every raise
				// (punches traced from the wrong controller) and made
				// WeaponsMatch treat the two as one weapon, which is what
				// turned every seat of this clone into a no-op hand switch.
				// AttachToOwner already set SisterWeapon from SisterWeaponType,
				// which is the only sister a fist should have.
				//
				// The clone is the same CLASS as the donor, so the seat must
				// go through MoveWeaponToHand with exactInstance -- see
				// RS_Holsters.moveWeaponInstant.
				return fresh;
			}

			// Spawn returned null. Actor.Spawn only does that for a bad
			// class or a bad position, neither of which applies here
			// (fistClass came from a live instance's own GetClass(), and
			// pawn.Pos is the pawn's own position) -- reaching this is a
			// signal something is wrong with the CLASS itself, not with
			// this call, so it says so instead of quietly falling through
			// to the same silent null every caller here already refuses to
			// tolerate everywhere else.
			Console.Printf("\cgRS_HandFist: recognised %s as a fist but could not spawn a second one",
				fistClass.GetClassName());
		}

		// Nothing was even recognised as a fist anywhere in this player's
		// inventory -- not a busy one, not a free one, nothing to clone
		// either. Every player in a Doom-descended game owns SOME melee
		// weapon, so reaching this means IsFistClass's own two checks
		// (name contains "Fist", or replaces Fist in DECORATE) both missed
		// whatever this content pack actually uses -- see the KNOWN GAP
		// note above. No safe class to substitute exists from in here:
		// this mod's own native tiers are chosen by player class, and that
		// selection lives outside this file (RS_Main, not part of this
		// merge), so guessing one blind risks handing back a fist that
		// belongs to a different player class entirely. Loud and empty-
		// handed beats silent and wrong.
		Console.Printf("\cgRS_HandFist: no fist-class weapon found anywhere in inventory for the %s hand",
			offhand ? "off" : "main");
		return null;
	}
}
