// THE FIST IS THE HAND. A UNIVERSAL ONE.
//
// WHY IT LIVES HERE AND NOT IN A WEAPON MOD. RS_WorldHands already draws a real
// hand on each controller at headset rate -- occluded by walls, lit by the room,
// able to grab, hold, pass and throw. The thing you punch with is that hand. So
// the fist belongs to whoever owns the hands, and every weapon set that loads
// beside this one gets it for free rather than shipping its own.
//
// NO MODEL AND NO SPRITE, DELIBERATELY. A psprite fist would be a flat picture
// of a hand hanging in front of a real one. This weapon exists only to BE a
// weapon: something the wheel can select, something that occupies a hand,
// something that can hit. What you look at was always there.
//
// IT REPLACES THE VANILLA FIST rather than sitting beside it. Two things in
// slot 1, one of them a drawing, is the exact confusion this package exists to
// end -- and `replaces` means every map, every mod and every pickup that hands
// out a Fist hands out this instead, with nothing needing to know.
//
// ONE PER HAND. The off-hand copy carries +WEAPON.OFFHANDWEAPON, which is what
// puts it in player.OffhandWeapon and what makes SetPsprite target the off-hand
// layer. Without a second class there is no way to hold a fist in the hand that
// is not your main one, which is most of the point of having two.

class RS_WorldFist : Weapon replaces Fist
{
	Default
	{
		Weapon.SelectionOrder 3700;
		Weapon.Kickback 100;
		Weapon.SlotNumber 1;

		// NO AmmoType, so CheckAmmo never refuses the swing.
		//
		// WIMPY + MELEEWEAPON keep the engine's own weapon-picking from ever
		// choosing this over something loaded: a fist is what you have left, not
		// something to switch to.
		+WEAPON.WIMPY_WEAPON
		+WEAPON.MELEEWEAPON
		+WEAPON.NOALERT
		+WEAPON.NOAUTOAIM
		Obituary "$OB_MPFIST";
		Tag "$TAG_FIST";
	}

	// TNT1, SO THERE IS NOTHING TO HIDE.
	//
	// This used to be PUNG with the layer set NoDraw by whatever was hiding
	// view-models. That is a fight, not a fix: RS_HandsAlwaysOn.StandInForFist
	// CLEARS NoDraw on any weapon layer it does not recognise as a fist, and the
	// pistol package sets it on every layer -- so which of the two ticked last
	// decided whether you saw a flat fist that frame.
	//
	// A psprite whose sprite is TNT1 keeps ticking and keeps running its states;
	// the renderer simply skips it. (The "TNT1 stops the actor" rule is about
	// world actors, not view layers.) So the states below still fire, still
	// punch, still A_ReFire -- and no one has to agree about NoDraw, because
	// there is no picture either way.
	// A HAND THAT IS BUSY DOES NOT PUNCH.
	//
	// One trigger, two jobs. Pulling a slide or dropping a magazine is done with
	// the same button that fires whatever is in that hand -- so every rack threw
	// a punch as well, and the fist animation played over the gun you were
	// working on. Reported as "the sprite fists going crazy when I rack".
	//
	// The grip arbiter already knows: whoever took the hand claimed it, so if
	// this hand is spoken for by anything, the swing is not ours to make. Asked
	// by string through ServiceIterator so nothing here names another mod -- if
	// the arbiter is absent, the answer is "not busy" and a fist behaves exactly
	// as it always did.
	action bool RS_HandBusy()
	{
		let pmo = players[consoleplayer].mo;
		if (!pmo) return false;

		int hand = invoker.bOffhandWeapon ? 1 : 0;

		ServiceIterator it = ServiceIterator.Find("RS_GripArbiterService");
		Service sv;
		while (sv = it.Next())
		{
			if (sv.GetInt("grip.hello", "", 0, 0, null, 'None') != 1) continue;
			return sv.GetInt("grip.held", "", hand, 0, pmo, 'RS_WorldFist') == 1;
		}
		return false;
	}

	States
	{
	Ready:
		TNT1 A 1 A_WeaponReady();
		Loop;
	Deselect:
		TNT1 A 1 A_Lower();
		Loop;
	Select:
		TNT1 A 1 A_Raise();
		Loop;
	Fire:
		// NOT WHILE THAT HAND IS ON SOMETHING. Straight back to Ready, no
		// animation, no sound -- the hand is racking a slide and the punch was
		// never asked for.
		TNT1 A 0
		{
			if (invoker.RS_HandBusy()) return ResolveState("Ready");
			return ResolveState(null);
		}
		// A_CustomPunch rather than A_Punch so the REACH can be stated. Vanilla
		// punches at 64 units, which from inside a headset is a lunge: your fist
		// connects with something a long way past where you can see it is. 52 is
		// about an arm.
		TNT1 A 3;
		TNT1 B 2 A_CustomPunch(RS_WorldFist.Damage(), true, 0, "BulletPuff", 52);
		TNT1 C 2;
		TNT1 D 2;
		TNT1 C 2;
		TNT1 B 1 A_ReFire();
		Goto Ready;
	}

	// Damage in one place so both hands agree and it is one line to change.
	// 2d10, matching the stock fist, so this is a drop-in and not a buff.
	static int Damage()
	{
		return 2 * random[RSFist](1, 10);
	}
}

// The same weapon, in the other hand.
class RS_WorldFistOff : RS_WorldFist
{
	Default
	{
		+WEAPON.OFFHANDWEAPON
		Weapon.SelectionOrder 3701;
		Tag "$TAG_FIST";
	}
}

// GIVE BOTH, ONCE, AND DO NOT ARGUE ABOUT THE SLOT AFTERWARDS.
//
// The replacement above covers every Fist the game hands out, but a player who
// starts with one gets only the main-hand copy -- nothing in Doom has ever
// needed a second. So the off-hand one is granted here.
//
// PlayerSpawned rather than a player class: a custom PlayerPawn would mean a
// class, a MAPINFO entry and a fight with every other mod that also wants a say
// in your loadout.
class RS_WorldFistGiver : EventHandler
{
	override void PlayerSpawned(PlayerEvent e)
	{
		if (e.PlayerNumber != consoleplayer) return;
		let pmo = players[e.PlayerNumber].mo;
		if (!pmo) return;

		if (!pmo.FindInventory("RS_WorldFistOff"))
			pmo.A_GiveInventory("RS_WorldFistOff", 1);
	}
}
