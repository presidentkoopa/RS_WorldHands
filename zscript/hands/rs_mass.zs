// ============================================================================
// WHAT A THING WEIGHS.
//
// One question, asked of anything: how many kilograms is this actor? A barrel
// is sixty, a clip is a third of one, a Cacodemon is four hundred. Everything
// that wants to be thrown, caught, hit with or knocked over asks here, so that
// the barrel that is heavy to throw is also heavy to be hit by.
//
// ---------------------------------------------------------------------------
// WHY NOT Actor.Mass. Doom has a Mass field and it is nearly useless for this.
// It defaults to 100 on every actor, and the engine reads it for exactly one
// thing -- ApplyKickback's thrust divisor. So a Clip and a Cyberdemon both
// report 100, and an INHERITED 100 cannot be told apart from a deliberate 100.
// Trusting it would make a pistol clip as heavy as a player.
//
// It is trusted for MONSTERS and nothing else, because there the numbers were
// actually authored: 50 for a Lost Soul, 400 for a Cacodemon, 1000 for a
// Cyberdemon. Read as kilograms those are close enough to right that inventing
// a second table would be worse.
//
// ---------------------------------------------------------------------------
// THE ORDER, and each step exists because the one after it is wrong for that
// case:
//
//   1  MASSDEF, a per-class lump any pk3 may ship. The authored answer, and the
//      only one that can be right for a specific thing.
//   2  The class's ANCESTORS in MASSDEF. A mod's custom clip that inherits from
//      Clip gets Clip's mass without anyone writing a line for it. This is the
//      difference between a table that covers Doom and a table that covers the
//      four hundred actors every load order actually has.
//   3  The weapon weight service, if the reload package is loaded and the actor
//      is a gun it knows. Real pounds, authored by the weapons lane.
//   4  Monsters: Doom Mass, as above.
//   5  Bounding volume x a density, CLAMPED HARD. A guess, and it says so.
//
// ---------------------------------------------------------------------------
// THE CLAMPS ARE NOT TIDINESS. Doom's default Radius is 20 and default Height
// 16, which is a bounding box of 1600 x 1600 x 16 units. Run through any
// sensible density that is a hundred and ninety kilograms for a pistol clip,
// because the box is a COLLISION box and has nothing to do with the object. So
// the guess is clamped by what kind of thing it is: an Inventory item is
// between 0.1 and 5 kg whatever its box says, and a loose prop between 1 and
// 200. A wrong answer inside those bounds is a mildly odd throw. A wrong answer
// outside them is a medikit that cannot be lifted.
//
// ---------------------------------------------------------------------------
// FIXED WORLD SCALE, NEVER vr_vunits_per_meter. The volume guess converts map
// units to metres with a constant. vr_vunits_per_meter is the player's own
// room-scale comfort setting -- it is how big the WORLD feels to them, it
// differs between two people in the same game, and running mass through it
// would make a barrel weigh one thing on his machine and another on yours.
// That is a desync with a plausible explanation, which is the worst kind.
//
// 32 units to the metre is Doom's own scale: the player is 56 units tall for a
// nominal 1.75 m.
// ============================================================================

class RS_Mass play
{
	// Doom's own world scale. See the header -- this is deliberately not the
	// VR room scale, and the two must never be confused.
	const UNITS_PER_METRE = 32.0;

	// What a loose prop is made of, when nothing better is known. 300 kg/m^3 is
	// somewhere between softwood and a hollow steel drum, which is about right
	// for "a Doom object" and wrong for everything specific -- which is why
	// MASSDEF exists.
	const DEFAULT_DENSITY = 300.0;

	// The guess, fenced. See the header.
	const INV_MIN  = 0.1;
	const INV_MAX  = 5.0;
	const PROP_MIN = 1.0;
	const PROP_MAX = 200.0;

	// ---- the answers --------------------------------------------------------

	static double Kg(Actor a)
	{
		if (!a) return 0;

		let t = RS_MassTable.Get();
		if (t)
		{
			int i = t.FindFor(a.GetClass());
			if (i >= 0 && t.dMass[i] > 0) return t.dMass[i];
		}

		// A gun the reload package knows the real weight of. Asked before the
		// monster and volume paths because it is authored data and they are
		// not; asked after MASSDEF because a MASSDEF line is someone
		// deliberately overriding it.
		double lb = GunPounds(a);
		if (lb > 0) return lb * 0.45359237;

		if (a.bIsMonster) return max(1.0, double(a.Mass));

		return Guess(a);
	}

	// Per (unit/tic), the number RS_Flight divides by. A newspaper is 0.04 and
	// a cannonball is 0.0005. Zero -- the default -- is a vacuum, which is what
	// Doom has always had and what most objects should keep.
	static double Drag(Actor a)
	{
		if (!a) return 0;
		let t = RS_MassTable.Get();
		if (!t) return 0;
		int i = t.FindFor(a.GetClass());
		return (i >= 0) ? t.dDrag[i] : 0.0;
	}

	// RS_Flight's FLIGHT_* bits, as declared by MASSDEF's `flutter` and
	// `impact explode` words.
	static int Flags(Actor a)
	{
		if (!a) return 0;
		let t = RS_MassTable.Get();
		if (!t) return 0;
		int i = t.FindFor(a.GetClass());
		return (i >= 0) ? t.dFlags[i] : 0;
	}

	// Did anyone actually state this one, or is it the volume guess? The same
	// distinction the weapon weight service draws with `has`, and for the same
	// reason: a caller that wants to refuse to act on a guess can.
	static bool IsStated(Actor a)
	{
		if (!a) return false;
		let t = RS_MassTable.Get();
		if (t && t.FindFor(a.GetClass()) >= 0) return true;
		if (GunPounds(a) > 0) return true;
		return a.bIsMonster;
	}

	// ---- speed, in units both halves of a formula agree about ---------------
	//
	// Map units per tic to metres per second, at the fixed world scale. The
	// impact energy formula needs real m/s or its numbers mean nothing, and it
	// must get the same answer on every machine.

	static double UnitsPerTicToMetresPerSec(double u)
	{
		return u * TICRATE / UNITS_PER_METRE;
	}

	static double MetresPerSecToUnitsPerTic(double m)
	{
		return m * UNITS_PER_METRE / TICRATE;
	}

	// ---- the fallbacks -------------------------------------------------------

	// A gun whose real weight the weapons lane measured, in pounds, or 0.
	//
	// ASKED BY STRING THROUGH A SERVICE, never by naming a class in the reload
	// package. A ZScript class reference to a pk3 that is absent, or that loads
	// later, is fatal AND GLOBAL -- it takes down every mod after it in the
	// load order. That cost RS_Grenade the whole game three times.
	//
	// `has` IS ASKED FIRST AND THE DOUBLE IS NOT ITS ANSWER. Most guns in the
	// fleet state no weight, and the service returns 0.0 for those. 0.0 means
	// "nobody measured this", never "it is weightless" -- take it as a mass and
	// every energy weapon becomes a feather.
	private static double GunPounds(Actor a)
	{
		if (!a) return 0;
		let it = ServiceIterator.Find("RS_WeaponWeightService");
		if (!it) return 0;
		Service sv = null;
		Service s;
		// EXACT name: ServiceIterator.Find matches a case-insensitive SUBSTRING
		// of the class name, so a near-miss can answer first and look right.
		while (s = it.Next())
			if (s.GetClassName() == 'RS_WeaponWeightService') { sv = s; break; }
		if (!sv) return 0;

		// The actor itself as the subject -- this asks about a specific weapon,
		// not about what some hand is holding, so the hand argument is unused
		// and the pawn path is never taken.
		if (sv.GetInt("weapon.weight.has", "", -1, 0, a) != 1) return 0;
		double lb = sv.GetDouble("weapon.weight.lbs", "", -1, 0, a);
		return lb > 0 ? lb : 0;
	}

	// Bounding volume times a density, clamped by what kind of thing it is.
	// This is the answer for everything nobody has said anything about, which
	// in any real load order is most actors.
	private static double Guess(Actor a)
	{
		double w = 2.0 * a.Radius / UNITS_PER_METRE;
		double h = a.Height / UNITS_PER_METRE;
		double m = w * w * h * DEFAULT_DENSITY;

		// bISMONSTER is handled by the caller; this is items and props.
		if (a is 'Inventory') return clamp(m, INV_MIN, INV_MAX);
		return clamp(m, PROP_MIN, PROP_MAX);
	}
}


// ============================================================================
// THE TABLE, READ ONCE.
//
// MASSDEF, from every pk3 in the load order, later entries winning. A handler
// rather than a Service because it holds state and is built lazily on first
// use; the Service below is only the door other packages knock on.
//
//   mass "Clip"            0.3   drag 0.002
//   mass "Medikit"         1.5   drag 0.003
//   mass "ExplosiveBarrel" 60    drag 0.001   impact explode
//   mass "RS_Newspaper"    0.4   drag 0.04    flutter
//
// The class name is matched EXACTLY first, then up the inheritance chain. A
// line for Clip therefore covers every mod's derived clip without anyone
// writing a second line, and a line naming the derived class still beats it.
// ============================================================================

class RS_MassTable : EventHandler
{
	Array<Class<Actor> > dClass;
	Array<double>        dMass;
	Array<double>        dDrag;
	Array<int>           dFlags;

	// A class we have already resolved, so the ancestor walk runs once per
	// class rather than once per throw.
	private Array<Class<Actor> > cacheClass;
	private Array<int>           cacheIndex;

	private bool loaded;

	static RS_MassTable Get()
	{
		let t = RS_MassTable(EventHandler.Find("RS_MassTable"));
		if (t && !t.loaded) t.Load();
		return t;
	}

	// The row for this class: its own, else its nearest ancestor's, else -1.
	int FindFor(Class<Actor> cls)
	{
		if (!cls) return -1;

		// LOOPED, NOT Array.Find. Find() on an array of class pointers is not
		// exercised anywhere in this tree -- RS_Roster keeps a Class<Actor>
		// array and walks it by hand -- and the failure mode for guessing
		// wrong about a dynamic-array method is a load-time abort, not a
		// compile error. The cache below means each class pays for this once.
		for (int c = 0; c < cacheClass.Size(); c++)
			if (cacheClass[c] == cls) return cacheIndex[c];

		int found = -1;
		for (Class<Actor> k = cls; k; k = (Class<Actor>)(k.GetParentClass()))
		{
			for (int i = 0; i < dClass.Size(); i++)
				if (dClass[i] == k) { found = i; break; }
			if (found >= 0) break;
		}

		cacheClass.Push(cls);
		cacheIndex.Push(found);
		return found;
	}

	// ---- parsing -------------------------------------------------------------

	private void Load()
	{
		loaded = true;
		int lump = -1;
		while ((lump = Wads.FindLump("MASSDEF", lump + 1, Wads.GLOBALNAMESPACE)) >= 0)
			ParseOne(Wads.ReadLump(lump), lump);
	}

	private void ParseOne(String text, int lump)
	{
		Array<String> lines;
		text.Replace("\r", "");
		text.Split(lines, "\n");

		for (int n = 0; n < lines.Size(); n++)
		{
			String line = lines[n];

			// Comments, either spelling. Cut before tokenising so a `#` inside
			// a line ends it rather than becoming a token.
			int h = line.IndexOf("#");
			if (h >= 0) line = line.Left(h);
			int sl = line.IndexOf("//");
			if (sl >= 0) line = line.Left(sl);

			// Quotes are noise once the line is split -- the class name is one
			// token either way, and requiring them would reject half the
			// MASSDEFs anyone writes by hand.
			line.Replace("\"", " ");
			line.Replace("\t", " ");

			Array<String> tok;
			line.Split(tok, " ", TOK_SKIPEMPTY);
			if (tok.Size() < 3) continue;
			if (!(tok[0] ~== "mass")) continue;

			// FindClass, NOT an assignment from the string. `Class<Actor> c =
			// "Literal"` resolves at COMPILE time and is fine for a literal;
			// given a runtime string it does not do what it reads like. This
			// one comes out of a lump, so it has to be looked up.
			Class<Actor> cls = (Class<Actor>)(Object.FindClass(tok[1], "Actor"));
			if (!cls)
			{
				// A line naming a class no pk3 in this load order defines is
				// NORMAL, not an error: one MASSDEF may cover several sets. Say
				// so only when someone is looking.
				let dev = CVar.FindCVar("developer");
				if (dev && dev.GetInt() >= 1)
					Console.Printf("[RSMASS] %s:%d names no class: %s",
						Wads.GetLumpFullName(lump), n + 1, tok[1]);
				continue;
			}

			double kg = tok[2].ToDouble();
			if (kg <= 0) continue;

			double drag = 0;
			int flags = 0;
			for (int t = 3; t < tok.Size(); t++)
			{
				if (tok[t] ~== "drag" && t + 1 < tok.Size()) { drag = tok[++t].ToDouble(); }
				else if (tok[t] ~== "flutter") { flags |= RS_Flight.FLIGHT_FLUTTER; }
				else if (tok[t] ~== "impact" && t + 1 < tok.Size())
				{
					if (tok[t + 1] ~== "explode") flags |= RS_Flight.FLIGHT_EXPLODE;
					t++;
				}
			}

			// LATER WINS, in place. A second line for the same class overwrites
			// the first rather than appending, so a pk3 loaded after another can
			// correct it -- which is the whole reason the lump is read from
			// every archive instead of just the first.
			int i = -1;
			for (int q = 0; q < dClass.Size(); q++)
				if (dClass[q] == cls) { i = q; break; }

			if (i >= 0)
			{
				dMass[i] = kg; dDrag[i] = drag; dFlags[i] = flags;
			}
			else
			{
				dClass.Push(cls); dMass.Push(kg); dDrag.Push(drag); dFlags.Push(flags);
			}
		}

		// The ancestor cache was built against the old table.
		cacheClass.Clear();
		cacheIndex.Clear();
	}
}


// ============================================================================
// THE DOOR. Other packages ask by string, so nothing compiles against this one.
//
//   GetDouble("mass.kg",   "", 0, 0, actor)   kilograms
//   GetDouble("mass.drag", "", 0, 0, actor)   per (unit/tic)
//   GetInt   ("mass.flags","", 0, 0, actor)   RS_Flight.FLIGHT_* bits
//   GetInt   ("mass.stated","",0, 0, actor)   1 authored, 0 a volume guess
// ============================================================================

class RS_MassService : Service
{
	override double GetDouble(String request, String stringArg, int intArg, double doubleArg, Object objectArg, Name nameArg)
	{
		let a = Actor(objectArg);
		if (!a) return 0;
		if (request ~== "mass.kg")   return RS_Mass.Kg(a);
		if (request ~== "mass.drag") return RS_Mass.Drag(a);
		return 0;
	}

	override int GetInt(String request, String stringArg, int intArg, double doubleArg, Object objectArg, Name nameArg)
	{
		// IDENTITY. ServiceIterator matches a case-insensitive SUBSTRING of the
		// class name, so finding something proves nothing on its own.
		if (request ~== "mass.hello") return 1;

		let a = Actor(objectArg);
		if (!a) return 0;
		if (request ~== "mass.flags")  return RS_Mass.Flags(a);
		if (request ~== "mass.stated") return RS_Mass.IsStated(a) ? 1 : 0;
		// Kilograms in thousandths, for a caller that only has the int channel.
		if (request ~== "mass.grams")  return int(RS_Mass.Kg(a) * 1000.0);
		return 0;
	}
}
