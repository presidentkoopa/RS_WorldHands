// THE GRIP ARBITER.
//
// Three mods write the engine-native per-hand int GripClaimMain / GripClaimOff,
// and each tests ownership by comparing the VALUE rather than the owner:
//
//   RS_Hands     rs_held.zs          on any world object a hand closes on
//   RS_Reload    rr_sequence.zs      on a magazine carried from the pouch
//   RS_Holsters  RS_Holsters.zs      on the chest ammo pouch
//
// RS_Hands assigns GRIPSUBJ_Magazine to Ammo, Health, Armor, Inventory and
// ExplosiveBarrel. RS_Reload's SubjectFor returns GRIPSUBJ_Magazine as its
// DEFAULT case. So picking up a health pack writes the exact same int a
// magazine reload writes, and each mod's "clear only what is mine" guard will
// happily clear the other's claim believing it to be its own.
//
// RS_Holsters USED TO READ the field and swap the hand's real weapon for a fist
// on ANY non-None value, ignoring even its own pouch-enable cvar -- so picking
// anything up off the floor disarmed you. That symptom was fixed on 2026-08-26
// (19b7557) by gating ENTRY to the swap on the pouch actually being involved,
// and it is NOT live any more. Do not re-report it; check RS_Holsters.zs first.
//
// The PROTOCOL flaw below it is untouched by that fix, and is the reason this
// file exists. Holsters is now individually immune because Holsters remembers to
// double-check. Hands and Reload still identify their own claims by value, and
// the FOURTH consumer to touch these fields inherits the identical trap with
// nothing to warn it. A patch on one reader is not a fix to a shared protocol.
//
// ---------------------------------------------------------------------------
// WHY A Service AND NOT AN EventHandler
//
// The fix has to be reachable from three mods that must each still ship and run
// ALONE. A hard reference is not an option: EventHandler.Find("Literal") and
// Service.Find(class<Service>) both resolve their argument at COMPILE time
// (codegen.cpp:12434-12456), and a miss is fatal AND GLOBAL -- thingdef.cpp:
// 420-424 calls I_Error and then refuses to compile every pk3 LATER IN THE
// LOAD ORDER. One missing optional pk3 would take the whole game down.
//
// Service is the one path with no compile-time link in either direction.
// InitServices() (vmnatives.cpp:62-75, called from info.cpp:383) walks
// PClass::AllClasses and instantiates every Service subclass by itself, so this
// class registers with NOBODY naming it -- no MAPINFO entry, no
// AddEventHandlers line, nothing. Consumers find it with
// ServiceIterator.Find(String) (service.zs:154), which takes a plain String and
// whose Next() returns null when absent.
//
// So: whether this is loaded or not, every mod behaves exactly as it does
// today, and neither side names the other.
//
// ---------------------------------------------------------------------------
// V1 WAS DELIBERATELY INERT. IT ANSWERED A HANDSHAKE AND NOTHING ELSE.
//
// That was the right call and it paid off exactly as intended: with no
// test-compile anywhere in this project, proving that a Service subclass in a
// loose pk3 really does auto-register and really is reachable by string had to
// happen BEFORE any logic depended on it, or a silent failure would have had
// two possible causes instead of one.
//
// ---------------------------------------------------------------------------
// THIS IS VERSION 2. IT ARBITRATES, AND IT IS LIVE.
//
// THE LINE ABOVE USED TO READ "NOTHING CALLS IT YET" AND STAYED THAT WAY FOR
// A FORTNIGHT AFTER IT STOPPED BEING TRUE. It was written the day v2 landed
// with the ledger built and no consumer converted; the four conversions
// happened over the following days and nobody came back to this paragraph.
// The cost was real: on 2026-09-08 the owner of this project believed the
// arbiter had never been wired up, on the evidence of this comment, while
// four files were calling it every tic. Corrected here rather than deleted,
// because the failure mode -- a caps-locked status comment outliving its
// status -- is worth one paragraph of warning to whoever edits this next.
//
// v2 added the ledger: who owns each hand, for what subject, and since when.
// It still writes NO engine field and registers NO handler. It is a place to
// record ownership, not an actor in the playsim.
//
// THE FOUR CONSUMERS, all doing real claim / mine / release:
//     rs_held.zs        963, 1023, 1038      (ships with this file)
//     rs_stabilize.zs   547, 567             (ships with this file)
//     RS_Holsters.zs    619, 628, 1399, 1406, 1448, 1459
//     rr_sequence.zs    244, 831, 844, 861
// Every one of those call sites is guarded on a null handle, so this file
// being absent costs identification, not function -- which is the property
// that lets it ship in exactly one pk3 and be optional to the rest.
//
// WHAT IT FIXES. The bug was never contention -- two mods genuinely fighting
// over one hand is rare. The bug was MISIDENTIFICATION: three writers putting
// interchangeable ints in a shared box, then each reading the box and believing
// what it found was its own. So the ledger keys on an OWNER NAME the caller
// supplies, and the only question a consumer ever needs to ask -- "is this
// hand's claim mine?" -- becomes a direct answer instead of a guess.
//
// FIRST-COME-WINS, AND NO PRIORITY LADDER. v1's own note anticipated a priority
// ladder here. Deliberately not built: a ladder means this file must know the
// names and relative rank of every consumer, which is precisely the
// compile-time coupling the Service approach exists to avoid, and it solves
// contention -- a problem this family does not actually have. A claim is held
// until released or expired. If real contention ever shows up, the vocabulary
// below can grow a request for it without breaking anyone, which is what the
// PROTOCOL/-1 contract is for.
//
// THE LEASE EXISTS FOR THE CASE NOBODY CAN CODE AROUND. A consumer that takes
// a claim and then dies, level-changes, or hits an early return without
// releasing would jam that hand forever -- and that failure mode has already
// happened twice in this family under the current scheme (RS_Holsters'
// bHolsterHidden lifecycle bug, and RR_Reload's level-exit-mid-carry jam). A
// claim not renewed within LEASE_TICS is simply treated as absent. Consumers
// hold a claim by re-asserting it, which every one of them is already doing
// every tic anyway.

class RS_GripArbiterService : Service
{
	// TWO CONSTANTS, NOT ONE, AND THE SPLIT IS THE WHOLE POINT.
	//
	// IDENTITY is "are you the arbiter". It is frozen at 1 FOREVER and must
	// never be bumped for any reason.
	//
	// PROTOCOL is "which arbiter are you". It gets bumped whenever the request
	// vocabulary changes in a way a consumer could not survive.
	//
	// These were the same const, and both requests returned it. That is a trap
	// with a fuse on it: consumers test IDENTITY for presence -- RS_Reload does
	// `GetInt("grip.hello") != RR_ARB_PROTO` and treats a mismatch as ABSENT --
	// so the very first time v2 bumped the shared const, every consumer would
	// have decided the arbiter was missing and silently stopped arbitrating,
	// with the pk3 sitting right there answering the call. You would be
	// debugging a lookup that reports "absent" while the thing is loaded.
	//
	// Both files' comments already described hello as identity and version as
	// version. One shared const meant that was not actually true.
	const IDENTITY = 1;
	const PROTOCOL = 2;

	// ONE SLOT PER HAND PER PLAYER. Indexed [pnum * HANDS + hand], the same
	// flattening RS_Holsters uses for its own per-player tables, because
	// ZScript has no 2D arrays.
	//
	// Per-PLAYER and not just per-hand even though this family is effectively
	// single-player (RR_Reload documents its own hard single-player limit):
	// the engine fields this shadows live on the pawn, so a ledger keyed only
	// by hand would silently alias two players onto one slot. Sizing it right
	// costs 8 ints and removes a whole class of future confusion.
	const HANDS = 2;
	const SLOTS = MAXPLAYERS * HANDS;

	// ~2 seconds at 35Hz. Long enough that a consumer re-asserting every tic
	// can never lapse through a frame hitch, short enough that a hand freed by
	// a dead claimant is usable again before the player notices. Nothing about
	// the design depends on the exact figure.
	const LEASE_TICS = 70;

	// 'None' means free. Deliberately the same spelling as GRIPSUBJ_None's
	// intent so the two read alike at a call site, though this is a Name and
	// that is an int -- they are separate things and this file never conflates
	// them.
	private Name  mOwner[SLOTS];
	private int   mSubject[SLOTS];
	private int   mTic[SLOTS];

	// "THIS HAND IS AT A GUN PART" -- the tic it was last said, per slot. Not a
	// claim: nothing is held, and nobody is refused the hand. It only tells a
	// hand's OTHER uses to stand back while it hovers inside a part's volume --
	// the distance-grab laser locking a barrel behind the slide you are about
	// to rack is the case it exists for. Stale after one tic, so a caller that
	// stops saying it stops meaning it.
	private int   mNearTic[SLOTS];

	// A slot is live only if it has an owner AND the lease has not run out.
	// Every read goes through this rather than testing mOwner directly, so
	// expiry can never be forgotten at one call site and honoured at another --
	// which is the exact shape of the bug this whole file exists to end.
	private bool slotLive(int s) const
	{
		if (s < 0 || s >= SLOTS)   return false;
		if (mOwner[s] == 'None')   return false;
		// level.time restarts on every map while this Service does not, so
		// a lease stamped late on the previous level reads as a large
		// NEGATIVE age here and would pass for minutes. Negative = dead.
		int age = level.time - mTic[s];
		return age >= 0 && age <= LEASE_TICS;
	}

	// -1 for a bad index, so a caller that passes nonsense gets the same
	// "unknown" answer the vocabulary already reserves rather than silently
	// operating on slot 0 -- which would be another player's main hand.
	private int slotOf(Object pawnObj, int hand) const
	{
		if (hand < 0 || hand >= HANDS) return -1;
		let pmo = PlayerPawn(pawnObj);
		if (pmo == null || pmo.player == null) return -1;
		int pnum = pmo.PlayerNumber();
		if (pnum < 0 || pnum >= MAXPLAYERS) return -1;
		return (pnum * HANDS) + hand;
	}

	// An override takes NEITHER the scope keyword NOR the parameter defaults
	// from the virtual it overrides -- both are inherited from Service's own
	// declaration (engine/service.zs:47), and restating either is a compile
	// error ("Attempt to change scope for virtual function", "Default values
	// for parameter of virtual override not allowed"), not a harmless repeat.
	//
	// All six parameters are spelled out because that is the form the shipped
	// precedent uses -- RS_Main/zscript/systems/ui/RS_TierPalette.zs:121 is a
	// working Service in this same engine and this signature is copied from it
	// character for character.
	//
	// GetInt is the ONLY override. GetString, GetName, GetDouble, GetObject and
	// the clearscope *Data variants are left alone: a virtual's scope can never
	// be changed after the fact, so guessing wrong about one costs a build,
	// while adding a new override later costs nothing.
	override int GetInt(String request, string stringArg, int intArg, double doubleArg, Object objectArg, Name nameArg)
	{
		// THE HANDSHAKE, and it exists because ServiceIterator matching is a
		// case-insensitive SUBSTRING test, not equality (service.zs:167-176).
		// Find("RS_GripArbiterService") would also return any service whose
		// class name merely CONTAINS that text. A hit is therefore not proof of
		// identity, so a consumer must ask something only this class answers
		// and check the answer. Anything else returns 0 through Service's own
		// base GetInt and is correctly treated as "not the arbiter".
		if (request == "grip.hello")   return IDENTITY;   // frozen at 1, never bump
		if (request == "grip.version") return PROTOCOL;   // bump this one instead

		// ------------------------------------------------------------------
		// THE LEDGER. Every request below takes the same two identifying
		// arguments and nothing else:
		//
		//   objectArg = the PlayerPawn        (which player)
		//   intArg    = 0 main / 1 off        (which hand)
		//   nameArg   = the caller's own name (who is asking)
		//
		// nameArg is the whole point. It is a string the CALLER chooses for
		// itself ('RS_Holsters', 'RR_Reload', ...) and it never has to be
		// registered here, so a new consumer needs no edit to this file --
		// which is the same no-compile-time-coupling property that made
		// Service the right base class to begin with.
		//
		// doubleArg carries the subject on a claim (a GRIPSUBJ_* value), and
		// is ignored by every other request. It is a double because that is
		// the free parameter left in the signature; it is used as an int.
		// ------------------------------------------------------------------
		int s = slotOf(objectArg, intArg);

		// CLAIM. Grants if the hand is free, if the lease has run out, or if
		// the asker already owns it -- that last case is what makes a claim
		// double as a renewal, so a consumer re-asserting every tic (which
		// all three already do) holds its claim with no extra request.
		// Returns 1 granted, 0 denied. Denied means somebody else holds it.
		if (request == "grip.claim")
		{
			if (s < 0) return -1;
			// A live lease refuses every other claimant -- EXCEPT a lease
			// whose subject is the pouch. A hand in the pouch is reaching,
			// not holding, and the lane that puts ammunition into it (the
			// reload) takes the hand over from the lane that owns the pouch
			// (the holsters). Without this the reload's claim was denied on
			// every carry, its Abort() could never answer "mine", and the
			// holsters' pouch exit cleared the field and handed the gun
			// back mid-carry. The displaced owner sees grip.mine == 0 and
			// stands down until the taker releases.
			if (slotLive(s) && mOwner[s] != nameArg && mSubject[s] != GRIPSUBJ_Pouch) return 0;

			mOwner[s]   = nameArg;
			mSubject[s] = int(doubleArg);
			mTic[s]     = level.time;
			return 1;
		}

		// IS THIS HAND MINE? The one question the old scheme could not answer,
		// and the reason every consumer had to guess from a shared int. 1 yes,
		// 0 no. A dead lease answers 0, so a caller never has to think about
		// expiry itself.
		if (request == "grip.mine")
		{
			if (s < 0) return -1;
			return (slotLive(s) && mOwner[s] == nameArg) ? 1 : 0;
		}

		// WHAT IS THIS HAND DOING? The subject of whoever holds it, for a
		// consumer that needs to react to another mod's claim (posing a hand
		// for a magazine it did not spawn, say) rather than just identify its
		// own. Returns 0 when the hand is free -- callers that care about the
		// difference between "free" and "held for subject 0" should ask
		// grip.held first.
		if (request == "grip.subject")
		{
			if (s < 0) return -1;
			return slotLive(s) ? mSubject[s] : 0;
		}

		// IS ANYONE HOLDING THIS HAND? Ownership-blind. 1 held, 0 free.
		if (request == "grip.held")
		{
			if (s < 0) return -1;
			return slotLive(s) ? 1 : 0;
		}

		// RELEASE, and ONLY IF IT IS YOURS. A consumer cannot clear another's
		// claim even by accident, which is the specific failure the old
		// value-compare scheme allowed. Returns 1 released, 0 not yours (or
		// already free) -- and releasing something you do not own is a no-op
		// rather than an error, so a defensive release on a cleanup path is
		// always safe to call.
		if (request == "grip.release")
		{
			if (s < 0) return -1;
			if (!slotLive(s) || mOwner[s] != nameArg) return 0;

			mOwner[s]   = 'None';
			mSubject[s] = 0;
			mTic[s]     = 0;
			return 1;
		}

		// AT A PART: say it every tic the hand is inside a gun part's volume
		// (doubleArg 1), or stop saying it (0). Not exclusive, not a claim.
		if (request == "grip.near")
		{
			if (s < 0) return -1;
			mNearTic[s] = (doubleArg > 0) ? level.time : -1000;
			return 1;
		}

		// IS THIS HAND AT A PART, as of this tic or the last? 1 yes, 0 no.
		if (request == "grip.nearq")
		{
			if (s < 0) return -1;
			int age = level.time - mNearTic[s];
			return (age >= 0 && age <= 1) ? 1 : 0;
		}

		// EVERY OTHER REQUEST RETURNS -1, NOT 0.
		//
		// Service's API has no way to signal "I do not answer that" -- the base
		// implementations return zero, and zero is a perfectly good answer to
		// plenty of real questions. So the vocabulary reserves -1 for "unknown
		// request" and no request may ever use -1 as a meaningful reply. A
		// consumer that gets -1 knows the arbiter is present but does not speak
		// this request, which is exactly the case a future protocol bump
		// creates, and it can fall back rather than believing a zero.
		return -1;
	}

	// THE HAND'S REACH VOLUME, ASKED FROM OUTSIDE.
	//
	// A weapon package decides whether a hand is AT one of its parts by whether
	// the hand's reach oval -- the one drawn on the hand, the one this package
	// grabs with -- meets the part's own. It cannot compute that oval itself:
	// the math is RS_Reach's, and a copy would drift from the drawing. So it
	// asks here. Same identifying arguments as the ledger (objectArg pawn,
	// intArg hand); a world point travels as stringArg "x y z".
	//
	//   reach.score  (GetDouble) how far into this hand's oval the point is,
	//                squared and normalised: <= 1 inside. -1 unknown.
	//   reach.centre (GetString) the oval's centre, "x y z". "" unknown.
	override double GetDouble(String request, string stringArg, int intArg, double doubleArg, Object objectArg, Name nameArg)
	{
		let pmo = PlayerPawn(objectArg);
		if (request == "reach.score" && pmo && pmo.player && (intArg == 0 || intArg == 1))
		{
			Array<String> v;
			stringArg.Split(v, " ", TOK_SKIPEMPTY);
			if (v.Size() < 3) return -1;
			Vector3 w = (v[0].ToDouble(), v[1].ToDouble(), v[2].ToDouble());
			return RS_Reach.Score(pmo, pmo.player, intArg, w);
		}
		return -1;
	}

	override String GetString(String request, string stringArg, int intArg, double doubleArg, Object objectArg, Name nameArg)
	{
		let pmo = PlayerPawn(objectArg);
		if (request == "reach.centre" && pmo && pmo.player && (intArg == 0 || intArg == 1))
		{
			Vector3 c = RS_Reach.Centre(pmo, pmo.player, intArg);
			return String.Format("%.4f %.4f %.4f", c.x, c.y, c.z);
		}
		return "";
	}
}
