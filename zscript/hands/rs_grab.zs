// HAND GRABBING.
//
// This lives in the HANDS package, and that is the whole point of it being here.
// It was written inside a weapon package because that is where I happened to be
// working, and deleting that weapon deleted the hands' grab volume, the
// closest-point maths and the collision-box drawing along with it -- none of
// which have anything to do with any gun.
//
// Nothing below knows what a weapon is. It knows about a hand, a volume, and
// whether something is inside it.

// The actor-space basis for a yaw/pitch/roll triple.
//
// Composed in the SAME order the physics module does -- Rz(yaw) * Ry(pitch) *
// Rx(roll), Quat::FromEulerDeg in p_physics.cpp. Shared, because a drawn volume
// and a tested volume picking different conventions is exactly how "correct at
// rest, wrong as you turn" happens.
//
// Three functions rather than one with out-parameters: an `out Vector3` hands
// the ZScript JIT a register type it has no case for and kills the whole class
// at load with "Unknown REGT value passed to EmitPARAM". That is a crash on map
// load, not a warning.
class RS_Basis
{
    // An angle folded into -180..180, so a distance-from-target comparison
    // means what it says either side of the wrap. Lives here because RS_Basis
    // is already the shared home for angle work both the drawn and the tested
    // side read.
    static double NormDeg(double a)
    {
        while (a >  180.0) a -= 360.0;
        while (a < -180.0) a += 360.0;
        return a;
    }

    static Vector3 Fwd(double yaw, double pit, double rol)
    {
        return ( cos(yaw)*cos(pit), sin(yaw)*cos(pit), -sin(pit) );
    }
    static Vector3 Side(double yaw, double pit, double rol)
    {
        double cy = cos(yaw), sy = sin(yaw);
        double cp = cos(pit), sp = sin(pit);
        double cr = cos(rol), sr = sin(rol);
        return ( cy*sp*sr - sy*cr, sy*sp*sr + cy*cr, cp*sr );
    }
    static Vector3 Up(double yaw, double pit, double rol)
    {
        double cy = cos(yaw), sy = sin(yaw);
        double cp = cos(pit), sp = sin(pit);
        double cr = cos(rol), sr = sin(rol);
        return ( cy*sp*cr + sy*sr, sy*sp*cr - cy*sr, cp*cr );
    }
}

// The geometry of reaching for something. No handler, no state -- just the
// questions, so the gauge that draws the volume and the code that grabs cannot
// disagree about where it is or how big it is.
// PLAY SCOPE, DECLARED. Without it the statics below default to DATA, and data
// cannot call a play function -- which is every interesting thing in here:
// TransformByNamedBone and ModelPointToWorld read a world actor, and RS_Held.Get
// and RS_GrabPolicy.Get are statics on EventHandlers, so they inherit play from
// their class. The failure reads far worse than it is, because one refused call
// leaves its `let` variable undeclared and every later use of it reports as an
// unknown identifier on its own line.
class RS_Reach play
{
    // THE HUNDRED THE RENDERER TAKES OUT OF A PLACEMENT OFFSET.
    //
    // models.cpp translates by (offset / xscale), so a placement offset is in
    // the MODEL's units. Every followed model used to carry a MODELDEF Scale
    // near 0.01 to cancel the missing model-unit conversion, and that tiny
    // divisor is what made these cvars map-unit-sized. With the conversion
    // restored and the scales back to 1.0, the same cvar is a hundred times
    // bigger for the same movement.
    //
    // PlacementOffset is the SCRIPT side of that identical offset and has no
    // xscale to divide by, so the factor is stated once here. Class scope
    // because ZScript constants may not be declared inside a function body --
    // "Unexpected 'const'", at load, taking the package with it.
    const FOLLOWHAND_UNITS = 100.0;

    // WHICH WAY THIS HAND POINTS, VERTICALLY -- and the minus sign is the
    // whole reason this is a function.
    //
    // AttackPitch is stored NEGATED. The engine writes
    // `AttackPitch = -weaponangles[PITCH]` (vk_openxrdevice.cpp), and every
    // direction builder in the tree then applies `z = -sin(pitch)` -- both
    // AngleToVector in hw_vrwheel.cpp and LaserAngleToVector in hw_weapon.cpp.
    // Feed the stored value straight into that and the two negations cancel:
    // the direction comes out vertically INVERTED, and raising your hand points
    // the ray at the floor.
    //
    // The engine's own laser sight avoids it by reading raw weaponangles rather
    // than AttackPitch. Stock ZScript avoids it by negating first -- see
    // weaponmace.zs, `directionPitch = -player.mo.AttackPitch`. This is that
    // negation, in one place, so the drawn ray and the tested volume cannot end
    // up on opposite sides of it.
    static double HandPitch(PlayerPawn pmo, int hand)
    {
        return -((hand == 0) ? pmo.AttackPitch : pmo.OffhandPitch);
    }

    static double Num(String n, PlayerInfo p, double d)
    {
        let c = CVar.GetCVar(n, p);
        return c ? c.GetFloat() : d;
    }
    static bool Flag(String n, PlayerInfo p, bool d)
    {
        let c = CVar.GetCVar(n, p);
        return c ? c.GetBool() : d;
    }
    // A colour cvar comes back as a packed int, same as any literal colour.
    static color Col(String n, PlayerInfo p, color d)
    {
        let c = CVar.GetCVar(n, p);
        return c ? color(c.GetInt()) : d;
    }
    // A LIST cvar -- an int chosen from a MENUDEF OptionValue block, not a
    // quantity. Read through GetInt like Col does rather than through Num,
    // because a float round-trip on an enumeration is a way to land between two
    // cases and match neither.
    static int Opt(String n, PlayerInfo p, int d)
    {
        let c = CVar.GetCVar(n, p);
        return c ? c.GetInt() : d;
    }

    // Find this hand's world-actor, so its bones can be read.
    static Actor Hand(int hand)
    {
        String cls = (hand == 0) ? "RS_HandWorldMain" : "RS_HandWorldOff";
        ThinkerIterator it = ThinkerIterator.Create(cls);
        return Actor(it.Next());
    }

    // THE THREE SEMI-AXES OF THE REACH VOLUME, IN MAP UNITS, returned in the
    // order the RENDERER scales them: x sideways, y forward, z up.
    //
    // Its own function because two things need it and they must not be able to
    // disagree: the ellipsoid test in ScoreAt, and -- in mesh space, see below --
    // the centre offset in Centre, because the renderer measures that offset in
    // semi-axes rather than in map units.
    //
    // NAMED BY THE AXIS THEY ACTUALLY SCALE, not by the letter in the cvar,
    // because the two did not agree and the disagreement was the bug.
    //
    // The renderer puts _scale_x on the same matrix axis as _ofs_x, which is
    // SIDEWAYS (see the note in Centre): models.cpp:716-719 multiplies
    // scaleFactorX by wPlaceAxis[0] and scaleFactorY -- the forward one -- by
    // wPlaceAxis[1], i.e. by _scale_y. The test had x on forward and y on
    // sideways, so the drawn oval was long across the palm while the tested
    // ellipsoid was long along the fingers. Both at once, and neither visible
    // from inside the other.
    //
    // The class defaults moved with the mapping (CVARINFO), so a fresh config
    // still reaches further along the fingers than through the wrist -- the shape
    // the sliders promise -- and the tested volume is the same one it always was.
    // An ini with tuned numbers in it keeps them and will need one re-dial, which
    // is unavoidable: those numbers were tuned against a drawing that was lying
    // about which way round it was.
    static Vector3 SemiAxes(PlayerInfo p, int hand)
    {
        String pre = (hand == 0) ? "rs_grab_m" : "rs_grab_o";
        return SemiAxesPre(pre, p);
    }

    // THE SAME THREE NUMBERS FOR ANY PLACEMENT PREFIX. The hand ovals are not
    // the only ellipsoid drawn through PlacementCVars and tested from script:
    // the two-hand stabilize point (rs_stabilize.zs) is one more, riding the
    // main hand under its own prefix. It has to convert its sliders exactly the
    // way the hand ovals do, or "what you see is what braces" stops being true
    // for the same reason it once stopped being true for grabbing. One body,
    // parameterised by prefix; SemiAxes above is now a name lookup on top of it.
    static Vector3 SemiAxesPre(String pre, PlayerInfo p)
    {
        double m  = Num(pre .. "_scale",   p, 1.0);  if (m <= 0) m = 1.0;
        double aSide = Num(pre .. "_scale_x", p, 2.2) * m;
        double aFwd  = Num(pre .. "_scale_y", p, 3.2) * m;
        double aUp   = Num(pre .. "_scale_z", p, 1.6) * m;

        // WHICH SPACE THE THREE NUMBERS ARE IN, and this CANNOT be settled from
        // source -- only by looking at the oval in a headset. So both readings
        // are here and a cvar picks, defaulting to the one that has always been
        // in force so nothing moves for anyone who does not go looking.
        //
        // The case for MAP UNITS is this code's own history, the 3.2 / 2.2 / 1.6
        // defaults, which are sane map-unit semi-axes for a hand (34 units to a
        // metre, a fist about 2), and MODELDEF.txt, which asserted it flatly
        // until this went in.
        //
        // The case for MESH SPACE is everything on the drawing side. The oval is
        // a unit-radius sphere at MODELDEF Scale 1.0 riding MDL_FOLLOWMAINHAND,
        // so its transform is GetWeaponTransform -- and that matrix carries
        // `scale(vr_vunits_per_meter, ...)` (vk_openxrdevice.cpp:5927), which
        // makes one mesh unit ONE METRE. That is what CVARINFO.txt means by "a
        // unit-radius mesh arrives already metres across", it is why MENUDEF
        // ships an OVERALL SIZE slider that starts at 0.005, and it is why
        // RS_GrabViz's own note says the useful master value is around 0.025.
        // Under that reading the drawn semi-axis in map units is scale * master
        // * 34, and the tested one was 34x too small the moment the oval was
        // dialled to look right -- straight down onto the 0.05 floor below.
        //
        // Read live rather than hardcoded at 34: vr_vunits_per_meter is a user
        // setting, and a player who changes their world scale would otherwise
        // find the test silently detached from the drawing all over again.
        if (Opt("rs_grab_scale_space", p, 0) == 1)
        {
            double k = Num("vr_vunits_per_meter", p, 34.0);
            if (k < 0.001) k = 34.0;
            aSide *= k;
            aFwd  *= k;
            aUp   *= k;
        }

        // AFTER the conversion, never before. The floor is a guard against a
        // zeroed slider collapsing the volume to a point, and it is stated in map
        // units -- applying it to a mesh-space number would clamp a perfectly
        // ordinary 0.025 up to 0.05 and double the oval.
        if (aSide < 0.05) aSide = 0.05;
        if (aFwd  < 0.05) aFwd  = 0.05;
        if (aUp   < 0.05) aUp   = 0.05;
        return (aSide, aFwd, aUp);
    }

    // WHERE THE HAND ACTUALLY IS -- the palm bone, when it can be read.
    //
    // Not the raw controller position. The controller origin sits at the wrist;
    // HANDPALM_joint sits at the hand model's own origin, which is where a thing
    // being held ends up. Using the wrist for the reach test and the palm for the
    // seat meant those two were answering to different geometry, and no amount of
    // slider work makes different geometry agree.
    //
    // Falls back to the controller position when the world hands are off or the
    // pose has not been published -- an unpublished transform loads identity, and
    // a palm at the world origin would put the reach volume in the far corner of
    // the map.
    static Vector3 Palm(PlayerPawn pmo, PlayerInfo p, int hand)
    {
        Vector3 c = (hand == 0) ? pmo.AttackPos : pmo.OffhandPos;

        let hd = Hand(hand);
        if (hd)
        {
            // A worn mesh without a skeleton has no palm bone: its origin is the
            // palm, and asking would print "Could not find bone" every call.
            let hw = RS_HandWorldBase(hd);
            Vector3 hb = (0,0,0);
            if (!hw || !hw.worn) hb = hd.TransformByNamedBone('HANDPALM_joint', (0,0,0));
            Vector3 pw, pf, pu;
            [pw, pf, pu] = hd.ModelPointToWorld(hb.x, hb.y, hb.z);
            if ((pw - pmo.Pos).Length() <= 120) c = pw;
        }
        return c;
    }

    // The palm, pushed out by this hand's own placement offsets -- the centre
    // of the reach oval. Split from Palm above because the stabilize point
    // needs the bare palm to hang ITS offsets off, under a different prefix.
    static Vector3 Centre(PlayerPawn pmo, PlayerInfo p, int hand)
    {
        String pre = (hand == 0) ? "rs_grab_m" : "rs_grab_o";
        Vector3 c = Palm(pmo, p, hand);

        double yaw = ((hand == 0) ? pmo.AttackAngle : pmo.OffhandAngle) + 90;
        double pit = HandPitch(pmo, hand);
        double rol = ((hand == 0) ? pmo.MainHandRoll : pmo.OffhandRoll);

        // X IS SIDEWAYS, Y IS FORWARD. It was the other way round here, and here
        // only, which meant the slider captioned "Forward / back" pushed the
        // TESTED centre along the fingers and the DRAWN oval sideways -- the one
        // thing this whole class exists to make impossible.
        //
        // These are not our cvars alone. MODELDEF hands the same three names to
        // the engine as `PlacementCVars rs_grab_m`, and the engine sums _ofs_x
        // into the same matrix component as vr_hand_ofs_x -- literally the same
        // translate() call, models.cpp:982 on the HUD path and :723 on the world
        // path this model actually draws through. vr_hand_ofs_x is captioned
        // "Left / Right" (MENUDEF.txt:113), and so is rs_hw_main_ofs_x (:60), and
        // so is every other _ofs_x in this family. There is one odd man out and
        // it was this function.
        //
        // The SENSE of each slider -- whether positive is left or right -- is not
        // decidable from source, because it depends on the controller frame's
        // handedness and the auto-reverse mirror the main hand carries. It also
        // does not need to be: a slider pushing the wrong way is fixed by dragging
        // it the other way, and it will be dragged either way during tuning.
        Vector3 o = PlacementOffset(pre, p, SemiAxes(p, hand));

        return c
            + RS_Basis.Side(yaw, pit, rol) * o.x
            + RS_Basis.Fwd(yaw, pit, rol)  * o.y
            + RS_Basis.Up(yaw, pit, rol)   * o.z;
    }

    // THE THREE PLACEMENT OFFSETS, IN MAP UNITS, for any prefix -- (sideways,
    // forward, up), the same order SemiAxesPre returns. `ax` is that prefix's
    // own semi-axes, because in mesh space the offset is measured in them.
    //
    // IN MESH SPACE THE OFFSET IS MEASURED IN SEMI-AXES, not in map units,
    // and that is the renderer's doing rather than a choice made here.
    //
    // VSMatrix::translate and ::scale both POST-multiply (matrix.cpp:177 and
    // :210), and models.cpp calls scale BEFORE translate -- so the vertex
    // meets the translate first and the scale second, and the placement
    // offset comes out multiplied by the placement scale. The engine divides
    // the offset by the MODELDEF scale to cancel that, but not by
    // wPlaceScale or wPlaceAxis. With the master at the ~0.025 mesh space
    // wants, the drawn oval moves a fortieth as far as the tested centre did.
    //
    // One mesh radius maps to one semi-axis, so multiplying by the semi-axis
    // is exactly what the renderer does and the two land on the same spot.
    // Under the map-units reading none of this applies: the offset is a
    // distance and stays one, which is why this is behind the same switch.
    static Vector3 PlacementOffset(String pre, PlayerInfo p, Vector3 ax)
    {
        double ox = Num(pre .. "_ofs_x", p, 0);
        double oy = Num(pre .. "_ofs_y", p, 0);
        double oz = Num(pre .. "_ofs_z", p, 0);

        if (Opt("rs_grab_scale_space", p, 0) == 1)
        {
            ox *= ax.x;
            oy *= ax.y;
            oz *= ax.z;
        }

        // AND THE HUNDRED THE RENDERER TAKES OUT, TAKEN OUT HERE TOO.
        //
        // models.cpp translates by (offset / xscale) -- so the offset is in the
        // MODEL's units, not map units. Every followed model used to carry a
        // MODELDEF Scale near 0.01 to cancel the missing model-unit conversion,
        // and that tiny divisor is what made these numbers map-unit-sized. With
        // the conversion restored and the scales back to 1.0, the same cvar is a
        // hundred times bigger for the same movement.
        //
        // This function is the SCRIPT side of the same offset -- it feeds
        // Centre, which is where the aim beam starts, where the reach test is
        // measured from, and what OvalsOverlap compares. It has no xscale to
        // divide by, so the factor is stated once, here, and every consumer
        // agrees with the renderer again.
        //
        // Named rather than inlined: it is the engine's 0.01 seen from the other
        // side, and the next person to find a hundred somewhere should be able
        // to grep for it.
        ox /= FOLLOWHAND_UNITS;
        oy /= FOLLOWHAND_UNITS;
        oz /= FOLLOWHAND_UNITS;

        return (ox, oy, oz);
    }

    // How far into the reach volume a world point is: <= 1 is inside, smaller is
    // more central, above 1 is outside.
    //
    // An ELLIPSOID and not a sphere. A hand reaches further along the fingers
    // than it does through the back of the wrist, and a sphere wide enough to
    // touch the fingertips also grabs things behind you. The three semi-axes are
    // the same three cvars the renderer scales the drawn oval with -- which was
    // the CLAIM long before it was true; see SemiAxes for what it took to make
    // "what you see is what grabs" an actual statement about this code.
    static double Score(PlayerPawn pmo, PlayerInfo p, int hand, Vector3 world)
    {
        return ScoreAt(pmo, p, hand, world, Centre(pmo, p, hand));
    }

    // DO THE TWO REACH OVALS ACTUALLY OVERLAP?
    //
    // Not "are the palms close". The swap gesture used to be a flat
    // centre-to-centre distance (8 map units) which had nothing to do with the
    // ovals it was named after: with the shipped tuning the ovals are about
    // 0.85 x 3.4 x 2.55 units in semi-axes, so they only TOUCH at 6.8 units
    // even along their longest axis. The gesture fired before the hands met,
    // in every orientation -- close, never deliberate.
    //
    // This asks the ellipsoid instead, and asks it BOTH WAYS: the other palm
    // inside MY oval, and my palm inside THEIRS. Symmetric, so neither hand's
    // wrist angle decides it alone, and it tightens and loosens with the
    // hands' own tuning rather than against a number that meant one thing at
    // one oval size and something else at the next.
    //
    // `depth` is in OVAL RADII, and Score is a squared normalised distance:
    //   1.0  the palms genuinely meet -- each one on the other's centre.
    //   2.0  the two surfaces just touch. Anything above that is proximity
    //        again, which is the thing this replaced.
    static bool OvalsOverlap(PlayerPawn pmo, PlayerInfo p, int hand, double depth)
    {
        if (!pmo || !p) return false;
        if (depth <= 0.0) depth = 1.0;
        double lim = depth * depth;

        Vector3 mine  = Centre(pmo, p, hand);
        Vector3 other = Centre(pmo, p, 1 - hand);

        // A DEGENERATE OVAL CANNOT DECIDE THIS, AND THIS IS WHY THE GESTURE
        // DIED. The oval's size depends on rs_grab_scale_space: with it at 1
        // the shipped numbers give semi-axes of roughly 0.85 x 3.4 x 2.55 map
        // units, a hand-sized volume the test means something against. With it
        // at 0 the SAME numbers give 0.05 x 0.1 x 0.075 -- under three
        // millimetres, smaller than the palm the oval is meant to describe --
        // and no human hand can satisfy an overlap test against that.
        //
        // The flat distance this replaced did not care about oval size, which
        // is exactly why it worked on a profile where the ovals had collapsed.
        // So when the oval is too small to be a hand, the gesture falls back
        // to a plain distance rather than becoming unreachable.
        Vector3 ax = SemiAxes(p, hand);
        double biggest = max(ax.x, max(ax.y, ax.z));
        if (biggest < 1.0)
            return (mine - other).Length() <= Num("rs_swap_overlap_min", p, 6.0);

        return Score(pmo, p, hand,     other) <= lim
            && Score(pmo, p, 1 - hand, mine)  <= lim;
    }

    // THE SAME QUESTION WITH THE CENTRE ALREADY IN HAND.
    //
    // Score's old shape called Centre itself, and Centre walks the thinker list
    // looking for the hand actor. Best asks Score once per blockmap candidate
    // while holding the very same centre in a local, so a room with a dozen
    // pickups in it walked every thinker in the level a dozen times per hand per
    // tic -- for an answer that cannot change between two candidates.
    //
    // Split rather than changed in place: Score is public surface that other
    // packages read, and a signature change there is a compile error in a repo
    // this one cannot see. The wrapper above keeps that contract exactly.
    static double ScoreAt(PlayerPawn pmo, PlayerInfo p, int hand, Vector3 world, Vector3 centre)
    {
        // (sideways, forward, up) -- the renderer's order, resolved in one place
        // so this test and the drawn oval cannot pick different letters.
        Vector3 ax = SemiAxes(p, hand);

        double yaw = ((hand == 0) ? pmo.AttackAngle : pmo.OffhandAngle) + 90;
        double pit = HandPitch(pmo, hand);
        double rol = ((hand == 0) ? pmo.MainHandRoll : pmo.OffhandRoll);

        Vector3 d = world - centre;
        double fx = (d dot RS_Basis.Fwd(yaw, pit, rol))  / ax.y;
        double fy = (d dot RS_Basis.Side(yaw, pit, rol)) / ax.x;
        double fz = (d dot RS_Basis.Up(yaw, pit, rol))   / ax.z;
        return fx*fx + fy*fy + fz*fz;
    }

    // THE CLOSEST POINT ON A THING'S OWN COLLISION VOLUME.
    //
    // Testing a hand against an actor's ORIGIN -- a single point -- means a long
    // object is only grabbable at one spot on it and the rest is not grabbable at
    // all. Testing the volume means the whole thing is, and the point that comes
    // back is WHERE you caught it, which is the number anything downstream needs.
    //
    // Doom gives every actor a cylinder: Radius and Height, the same volume that
    // stops you walking through it. So a barrel, a medikit, a corpse and an ammo
    // box are all grabbable with nothing authored per thing.
    static Vector3 ClosestOn(Actor g, Vector3 world)
    {
        double z = clamp(world.z, g.Pos.z, g.Pos.z + g.Height);
        Vector2 r = (world.x - g.Pos.x, world.y - g.Pos.y);
        double len = r.Length();
        if (len > g.Radius && len > 0.0001) r = r * (g.Radius / len);
        return (g.Pos.x + r.x, g.Pos.y + r.y, z);
    }

    // Is this something a hand should be able to take hold of?
    //
    // The answer lives in RS_GrabPolicy, as a table. It used to live here as
    // `bSpecial && Inventory`, which made a barrel ungrabbable, a corpse
    // ungrabbable, and a +1 health bonus exactly as grabbable as a medikit.
    //
    // The policy also handles the case that catches everyone: an object ALREADY
    // IN A HAND has had SPECIAL cleared (RS_Held.SaveFlags -- an item inside
    // your own collision cylinder is touched every tic and would vanish into
    // inventory the instant you grabbed it), so a naive pickup test answers NO
    // for exactly the object the other hand is reaching for. Two-handed holds
    // and hand-to-hand passes would be unreachable, and would look for all the
    // world like the reach volume had missed.
    static bool Grabbable(Actor g, PlayerPawn pmo, PlayerInfo p = null)
    {
        let pol = RS_GrabPolicy.Get();
        if (!pol) return false;
        if (!p) p = players[consoleplayer];
        return pol.Decide(g, pmo, p) != null;
    }

    // The best thing in this hand's reach, or null. Bounded blockmap query, so it
    // is cheap enough to run every tic for the gauge as well as on a squeeze.
    //
    // WHAT THIS HAND ALREADY HOLDS IS NOT A TARGET FOR THIS HAND. The other
    // hand's is -- that is how a second hand joins or takes over. Without the
    // distinction the gauge draws a box round the thing in your own fist and
    // says you could grab it, while a squeeze would in fact let go of it: the
    // one thing the drawn volume is not allowed to do is disagree with what the
    // squeeze will actually do.
    //
    // ADMISSION AND RANKING ARE TWO SEPARATE TESTS, and they used to be one.
    //
    // The old loop kept a single running best that started at 1.0 -- the
    // ellipsoid surface -- so "is this in reach" and "is this the best thing in
    // reach" were decided by the same compare against the same number. Which
    // means the winner was PURE DISTANCE TO PALM with no idea what anything was:
    // on a floor after a firefight, the corpse a few units nearer your hand beat
    // the barrel you were plainly reaching for, every single time.
    //
    // Splitting them lets the table's weight steer the choice without ever being
    // able to remove anything from the game:
    //
    //   admission  raw score against the surface, exactly as before. Unweighted,
    //              so reaching at a medikit with nothing else in the volume
    //              still gets you the medikit however lightly it is weighted.
    //              NOTHING CAN BECOME UNGRABBABLE by tuning the table.
    //   ranking    score divided by weight, among things already admitted.
    //
    // The score is a SQUARED normalised distance (see ScoreAt), so dividing it
    // by the weight ranks identically to dividing linear distance by
    // sqrt(weight): weight 4 competes as though at half the distance, weight
    // 0.25 as though at twice. Blunt on purpose, and safe to be blunt because a
    // weight can only ever lose to something else in the volume, never to
    // nothing.
    static Actor Best(PlayerPawn pmo, PlayerInfo p, int hand)
    {
        Vector3 c = Centre(pmo, p, hand);
        Actor best = null;
        double bestAdj = 0;
        // Both looked up ONCE. Best runs every tic for both hands from the
        // gauge as well as on a squeeze, and asking the handler registry per
        // candidate actor in the blockmap query is pure waste.
        let held = RS_Held.Get();
        let pol  = RS_GrabPolicy.Get();
        if (!pol) return null;
        BlockThingsIterator it = BlockThingsIterator.CreateFromPos(c.x, c.y, c.z, 48, 48, false);
        while (it.Next())
        {
            Actor a = it.thing;
            if (held && held.HeldBy(hand) == a) continue;
            // The RULE, not just its yes/no. The weight is per-class data and
            // this is the one place that reads it; asking Decide twice -- once
            // for the answer and once for the number -- would be the same
            // blockmap-rate walk down the table run twice.
            //
            // Read within this iteration and never kept: a corpse's rule is a
            // single shared instance that Decide refills per call (see the field
            // note in RS_GrabPolicy), so `r` is only valid until the next one.
            let r = pol.Decide(a, pmo, p);
            if (!r) continue;
            // ScoreAt, not Score, and `c` is why: Score would re-derive this
            // exact centre per candidate, and deriving it walks every thinker in
            // the level looking for the hand actor.
            double sc = ScoreAt(pmo, p, hand, ClosestOn(a, c), c);
            if (sc > 1.0) continue;                        // 1.0 is the surface

            double w = r.weight;
            if (w <= 0) w = 1.0;        // a bad table line must not divide by 0

            // AN OBJECT ALREADY IN THE OTHER FIST IS INTENT, NOT CLUTTER.
            //
            // Best skips only THIS hand's own object, four lines up. Leaving the
            // OTHER hand's object as a candidate is deliberate and documented at
            // :356-362 -- it is the entire mechanism by which a second hand
            // joins a two-handed carry, and by which a thing is passed from hand
            // to hand.
            //
            // Weighting broke that without meaning to. A corpse being dragged is
            // 0.25 in the table and a barrel is 4.0, so a barrel anywhere in the
            // joining hand's volume beat the corpse unless the corpse was four
            // times nearer the palm -- and CVARINFO advertises exactly that
            // route as working ("turn it on and drag a body about").
            //
            // Floor weight rather than exempt from weighting: a reach that lands
            // on something already held is a reach AT it, so it should win ties
            // against clutter, but a genuinely better candidate at point-blank
            // range should still be allowed to. IsHeld is used this way already
            // at rs_grabpolicy.zs:308 and rs_distance.zs:76.
            if (held && held.IsHeld(a) && w < 4.0) w = 4.0;

            double adj = sc / w;

            // `!best ||` rather than a sentinel start value: there is no
            // meaningful "worse than anything" number once the score is divided
            // by an open-ended weight, and "have I picked one yet" is the thing
            // actually being asked. `<=` keeps the old tie behaviour, where the
            // later candidate wins.
            if (!best || adj <= bestAdj) { bestAdj = adj; best = a; }
        }
        return best;
    }
}


// THE INPUT END OF GRABBING. Decides WHEN and WHAT; RS_Held decides what being
// held actually means and does the carrying.
//
// Split because they fail differently and change at different rates. Which
// object your hand is nearest is a targeting question that will be rewritten
// wholesale when the distance-grab cone lands; whether that object is in one
// hand or two is a state question that must not be rewritten at all.
class RS_GrabHandler : EventHandler
{
    private bool wasGrip[2];

    // THIS TIC'S TARGETS, RESOLVED ONCE.
    //
    // Three things need to know what a squeeze would take: the squeeze itself,
    // the drawn box that promises it, and the grab claim that tells the engine
    // this grip is not a shift key. Each of them scanning independently is the
    // same blockmap query three times AND three answers that can disagree --
    // the box promising one object while the squeeze takes another is exactly
    // the class of bug the drawn volume exists to rule out.
    private Actor nearTarget[2];
    private Actor farTarget[2];

    static RS_GrabHandler Get()
    {
        return RS_GrabHandler(EventHandler.Find("RS_GrabHandler"));
    }

    // What a squeeze on this hand would take right now, near or far, or null.
    Actor TargetFor(int hand) const
    {
        if (hand != 0 && hand != 1) return null;
        return nearTarget[hand] ? nearTarget[hand] : farTarget[hand];
    }

    // The cone's pick only -- null when the thing is already in your palm. The
    // beam wants this rather than TargetFor: a line drawn to something you are
    // touching is a line you cannot see, starting inside its own target.
    Actor FarTargetFor(int hand) const
    {
        if (hand != 0 && hand != 1) return null;
        return nearTarget[hand] ? null : farTarget[hand];
    }

    // THE NEAR PICK ALONE, for the gauge that draws the reach volume.
    //
    // It exists so RS_GrabViz can stop running its own RS_Reach.Best. That scan
    // is a blockmap query plus a Score per candidate, it was running a second
    // time for the same hand in the same tic, and the function it ran in already
    // carried a comment forbidding exactly that for the box a few lines below.
    // The oval and the box now come out of one answer, which is also the only
    // way the oval can be honest: it goes hot for what a squeeze would TAKE, and
    // a squeeze on a full hand does not take, it lets go.
    Actor NearTargetFor(int hand) const
    {
        if (hand != 0 && hand != 1) return null;
        return nearTarget[hand];
    }

    // IS THIS GRIP SPOKEN FOR? Asked once, answered once, used twice.
    //
    // Holding something, reaching for something, pulling something and having
    // hold of something at range are the four states that mean this squeeze
    // belongs to grabbing. Two places need that answer -- the GrabClaim written
    // to the engine, and the holster stand-down that decides whether to throw
    // this hand's squeeze away -- and they were written out separately.
    //
    // They drifted immediately. The stand-down listed three of the four and left
    // out HandIsFull, which reads as a small omission and is not: for a hand that
    // is CARRYING something both target slots are unconditionally nulled at the
    // top of the tic and Locked() is always null, so all three of its conditions
    // are false by construction. Standing in a holster volume -- which is where
    // an arm hanging at your side lives more or less permanently -- the guard
    // fired and skipped every release path below it. The hand could never let go.
    //
    // One function, so a fifth state added later cannot be added to one of them.
    private bool GripSpokenFor(int hand, RS_Held held, RS_Pull pull,
                               PlayerPawn pmo, PlayerInfo p) const
    {
        if (!held) return false;
        return held.HandIsFull(hand) || TargetFor(hand) != null
            || (pull && (pull.Flying(hand) || pull.Locked(hand) != null))
            || SwapPoised(hand, held, pmo, p);
    }

    // THE FIFTH STATE, and the one the comment above predicted.
    //
    // Hands brought together to pass a weapon is a grip that MEANS something,
    // and it was not on the list -- so the main hand's squeeze fell all the way
    // through the engine's context ladder to GRIPCTX_Modifier
    // (vk_openxrdevice.cpp:3750). The modifier remaps the thumbstick's
    // direction keys to a different set entirely, so the player stops dead for
    // as long as the grip is held.
    //
    // That is the whole of "passing a weapon to the main hand stops me, but
    // passing to the off hand does not": only isMain reaches the modifier
    // branch, so only that direction freezes. Diagnosed by the user, 2026-08-29.
    //
    // The engine already solved this exact class of bug once -- GRIPCTX_Object
    // was deliberately moved ABOVE the modifier so that closing a fist round a
    // magazine would stop standing analog turning down. This is the same fault
    // with a different trigger, and it is fixed the same way: claim the grip,
    // and the ladder never reaches the shift layer.
    //
    // The conditions are the SWAP GESTURE'S OWN, deliberately. A claim that
    // fired on proximity alone would kill the modifier every time the hands
    // passed near each other; this fires only when a squeeze would actually
    // swap, so the modifier is given up exactly when it is not what the grip
    // means.
    // The subjects the pouch and the reload lane put on a hand.
    // THE SUBJECTS THAT MEAN "THIS HAND IS WORKING A GUN".
    //
    // GRIPSUBJ_Slide JOINED THE LIST. A hand dragging a slide back is as spoken
    // for as one carrying a magazine -- more so, since the motion is a straight
    // pull toward you and the distance grab reads a straight pull toward you as
    // a flick. Racking a pistol therefore hauled whatever the cone had locked
    // across the room at your head, mid-reload.
    //
    // Forend and Foregrip are deliberately absent: those mean a hand BRACING a
    // weapon, which the arbiter reads differently, and a braced hand is not
    // reaching for anything either way.
    private static bool ReloadSubject(int subj)
    {
        return subj == GRIPSUBJ_Pouch || subj == GRIPSUBJ_Magazine || subj == GRIPSUBJ_Shell
            || subj == GRIPSUBJ_Round || subj == GRIPSUBJ_Inserting
            ;
    }

    // THE SLIDE IS NOT ON THAT LIST, AND PUTTING IT THERE BROKE THE GRAB.
    //
    // ReloadSubject is read by the stand-down at the top of the squeeze loop,
    // and that stand-down `continue`s past EVERYTHING -- near grab, cone, lock,
    // flick, swap. Adding the slide there to stop the cone firing mid-rack took
    // the near grab with it: a hand that had touched a slide could not pick
    // anything up at all.
    //
    // The cone was the only thing that needed stopping, so the slide is tested
    // where the cone is acquired and nowhere else.
    private static bool WorkingAGun(int subj)
    {
        return ReloadSubject(subj) || subj == GRIPSUBJ_Slide;
    }

    private bool SwapPoised(int hand, RS_Held held, PlayerPawn pmo, PlayerInfo p) const
    {
        if (!pmo || !p) return false;
        // Feeding a chest-drawn magazine puts the hands together: not a swap.
        if (ReloadSubject((hand == 0) ? pmo.GripSubjectMain : pmo.GripSubjectOff)) return false;
        if (!RS_Reach.Flag("rs_swap_overlap", p, true)) return false;

        // Carrying anything makes this a two-handed join, not a pass.
        if (held.HandIsFull(hand) || held.HandIsFull(1 - hand)) return false;
        if (nearTarget[hand]) return false;

        Weapon src = (hand == 0) ? p.OffhandWeapon : p.ReadyWeapon;
        if (!src || src.bNoHandSwitch || RS_HandFist.IsFistClass(src.GetClass()))
            return false;

        // PALM UP, OR IT IS NOT A PASS.
        //
        // Overlapping ovals alone was the whole test, so ANY two hands brought
        // together swapped weapons -- including the two postures that mean
        // something else entirely: a hand coming under the gun to brace it, and
        // a hand coming over the top to work the slide. Both put the palms
        // together by definition, so both traded guns instead.
        //
        // Turning a palm over and closing it is a deliberate act and nothing
        // else in the scheme asks for it, which is exactly why it is the pass.
        // Same numbers the distance-grab beam gates on, read as a distance from
        // 90 degrees using the ABSOLUTE roll -- a right wrist turning over rolls
        // one way and a left the other, so one number covers both hands.
        if (RS_Reach.Flag("rs_swap_needs_palm", p, true))
        {
            double rl  = abs(RS_Basis.NormDeg((hand == 0) ? pmo.MainHandRoll : pmo.OffhandRoll));
            double tgt = RS_Reach.Num("rs_dgrab_palm_roll", p, 90.0);
            double tol = RS_Reach.Num("rs_dgrab_palm_tol",  p, 30.0);
            if (abs(rl - tgt) > tol) return false;
        }

        return RS_Reach.OvalsOverlap(pmo, p, hand,
            RS_Reach.Num("rs_swap_overlap_depth", p, 2.0));
    }

    // A DEFAULT THAT CHANGED CANNOT REACH A PROFILE THAT ALREADY SAVED THE
    // OLD ONE. rs_swap_overlap_depth shipped at 1.0 for one build -- palms
    // touching centre to centre, about 2.5cm, a gesture you have to aim
    // rather than make -- and every profile that ran that build wrote the 1.0
    // into its ini, where it outranks the 2.0 the cvar now declares. So the
    // swap stayed broken for exactly the people who had already tried it.
    //
    // Corrected once, on the version stamp, and only for a value inside the
    // range that build could have written: anyone who deliberately set 1.2
    // because they liked it keeps it.
    override void OnRegister()
    {
        let p = players[consoleplayer];
        if (!p) return;

        let ver = CVar.GetCVar("rs_hands_cfgver", p);
        if (!ver) return;
        int have = ver.GetInt();
        if (have >= 3) return;

        if (have < 1)
        {
            let d = CVar.GetCVar("rs_swap_overlap_depth", p);
            if (d && d.GetFloat() < 1.5)
            {
                d.SetFloat(2.0);
                Console.Printf("\cj[RSSWAP] hand swap distance was left at the old %.1f -- set to 2.0, the ovals meeting.", 1.0);
            }
        }

        // THE OVAL SPACE SWITCH, SAVED AT 0 BY AN OLDER DEFAULT. Under 0 the
        // test reads the oval numbers as map units, and the shipped numbers --
        // a 0.025 master, dialled against the DRAWN oval, which the renderer
        // scales in mesh space -- come out at a twentieth of a unit. Every
        // oval collapses to a dot, OvalsOverlap gives up and falls back to a
        // flat 6-unit distance, and the swap is proximity again with the
        // ovals drawn hand-sized and deciding nothing. The near grab is worse:
        // it only ever hits with the palm inside the target.
        //
        // CVARINFO ships 1 now, and an ini that saved 0 outranks it forever.
        // Corrected once, and only when the master is small enough that it
        // can only have been dialled in mesh space: anyone who set 0 on
        // purpose with map-unit numbers keeps it.
        if (have < 2)
        {
            let sp = CVar.GetCVar("rs_grab_scale_space", p);
            let m  = CVar.GetCVar("rs_grab_m_scale", p);
            if (sp && m && sp.GetInt() == 0 && m.GetFloat() < 0.2)
            {
                sp.SetInt(1);
                Console.Printf("\cj[RSGRAB] oval sizes were being read as map units against mesh-space numbers -- set to the drawn mesh space, so the ovals you see are the ovals that decide.");
            }
        }

        // THE PLACEMENT OFFSETS MOVED BY 100 WITH THE ENGINE FIX.
        //
        // models.cpp divides a placement offset by the model's own scale before
        // translating (`(xoffset + wPlaceOfs[0] + followHandOfs.X) / xscale`).
        // The world follow-hand branch was missing the model-unit conversion the
        // HUD branch applies, so every followed model carried a compensating
        // MODELDEF Scale of about 0.01 -- and that tiny divisor is what made a
        // slider range of -1..1 the right size.
        //
        // With the conversion added and the scales back to 1.0, the SAME slider
        // value now moves the hand a hundredth as far. The sliders are not dead;
        // they are a hundred times too fine for their range. So the range grew
        // and the saved numbers grow with it, or a seat dialled yesterday
        // silently becomes no offset at all.
        //
        // Only values that could have come from the old range: anything already
        // past 1.0 was set after the change and is left alone.
        if (have < 3)
        {
            bool moved = false;
            static const String OFS[] = {
                "rs_hw_main_ofs_x", "rs_hw_main_ofs_y", "rs_hw_main_ofs_z",
                "rs_hw_off_ofs_x",  "rs_hw_off_ofs_y",  "rs_hw_off_ofs_z" };
            for (int i = 0; i < 6; ++i)
            {
                let c = CVar.GetCVar(OFS[i], p);
                if (!c) continue;
                double v = c.GetFloat();
                if (v != 0.0 && abs(v) <= 1.0) { c.SetFloat(v * 100.0); moved = true; }
            }
            // THE OVALS AND THE SUPPORT POINT MOVE WITH EVERYTHING ELSE.
            //
            // These are read TWICE and the two readers disagreed. The RENDERER
            // divides a placement offset by the model scale (models.cpp:1017),
            // so it needs the hundred. RS_Reach.Centre did not -- and that
            // centre is where the aim beam starts, so scaling the cvar alone
            // threw the laser origin a hundred times out.
            //
            // Fixed at the reader rather than by leaving the cvar behind: see
            // FOLLOWHAND_UNITS in RS_Reach.PlacementOffset. Both sides now agree
            // and the drawn oval is the tested oval again.
            static const String MORE[] = {
                "rs_grab_m_ofs_x", "rs_grab_m_ofs_y", "rs_grab_m_ofs_z",
                "rs_grab_o_ofs_x", "rs_grab_o_ofs_y", "rs_grab_o_ofs_z",
                "rs_stab_ofs_x",   "rs_stab_ofs_y",   "rs_stab_ofs_z" };
            for (int i = 0; i < 9; ++i)
            {
                let c = CVar.GetCVar(MORE[i], p);
                if (!c) continue;
                double v = c.GetFloat();
                if (v != 0.0 && abs(v) <= 1.0) { c.SetFloat(v * 100.0); moved = true; }
            }

            if (moved)
                Console.Printf("\cjRS_WorldHands: hand placement offsets scaled x100 to match the model-unit fix in models.cpp. Options > World Hands to re-seat.");
        }

        ver.SetInt(3);
    }

    override void WorldTick()
    {
        // CLEARED BEFORE ANY EARLY RETURN, and that ordering is the whole point.
        //
        // These two are published state: the flash, the volume box and the aim
        // beam all read them through the accessors above, and RS_GrabViz ticks
        // after this handler. Every bail below used to leave last tic's answer
        // standing, so switching grabbing off -- or simply dying -- left an
        // object lit and boxed with a beam drawn to it, promising a grab from a
        // system that had stopped running.
        for (int h = 0; h < 2; h++)
        {
            nearTarget[h] = null;
            farTarget[h]  = null;
        }

        let p = players[consoleplayer];
        if (!p || !p.mo) return;
        let pmo = p.mo;

        // Dead: RS_Held, RS_Pull and RS_Route all stop here, and this one
        // kept targeting, claiming, locking and taking from the corpse's
        // hand position. Targets were nulled above; withdraw the claims too.
        if (pmo.Health <= 0)
        {
            pmo.GrabClaimMain = false;
            pmo.GrabClaimOff  = false;
            wasGrip[0] = false;
            wasGrip[1] = false;
            return;
        }

        // EVERY EXIT BELOW MUST WITHDRAW THE CLAIM, NOT JUST SKIP RESTATING IT.
        //
        // GrabClaimMain/Off are written once, at the bottom of this function.
        // NOTHING ELSE EVER CLEARS THEM: the engine only ever reads them
        // (declared actor.h, consumed in the OpenXR device), so a claim left
        // true stays true until something in here writes false.
        //
        // So the early exits used to leak. Reach at a barrel -- claim goes true
        // -- then open the menu and switch rs_grab off: the `Flag("rs_grab")`
        // exit below fires before the write, and the engine goes on believing
        // that hand has something to take FOR THE REST OF THE LEVEL. The grip
        // stops resolving as the shift layer, so every grip+button binding
        // silently stops working, with nothing on screen to say why.
        //
        // RS_Held.ClearClaims already covers every one of its exits for
        // GripClaim* for exactly this reason; this is the same discipline
        // applied to the pair this handler owns.
        if (!RS_Reach.Flag("rs_grab", p, true))
        {
            pmo.GrabClaimMain = false;
            pmo.GrabClaimOff  = false;
            return;
        }

        let held = RS_Held.Get();
        if (!held)
        {
            pmo.GrabClaimMain = false;
            pmo.GrabClaimOff  = false;
            return;
        }

        bool toggle = RS_Reach.Flag("rs_hold_toggle", p, true);
        bool dbg    = RS_Reach.Flag("rs_hand_debug", p, true);
        // The focused channel. "The cone found nothing" is one of the five
        // answers to "why did my pull do nothing", and the other four are in
        // RS_Pull.Start -- so it has to be readable without turning the noisy
        // half on, or the set is incomplete exactly when it is being read.
        bool trace  = RS_Reach.Flag("rs_hand_trace", p, true);
        bool useCone = RS_Reach.Flag("rs_dgrab", p, true);
        let pull = RS_Pull.Get();

        // Resolve both hands' targets BEFORE acting on either, so the claim
        // published below and the box drawn later are the same answer the
        // squeeze uses.
        for (int hand = 0; hand < 2; hand++)
        {
            nearTarget[hand] = null;
            farTarget[hand]  = null;
            if (held.HandIsFull(hand)) continue;

            // AN OBJECT IN FLIGHT IS A TARGET, not a reason to stop looking.
            //
            // This is what makes the catch a matter of timing. CatchableBy only
            // answers once the thing is inside this hand's reach volume, and it
            // is homing to your palm -- so it becomes catchable near the end of
            // its arc and not before. Grab too early and you grab nothing.
            //
            // Nothing else is considered while something of yours is inbound.
            // Being offered a different object mid-catch is how you end up
            // holding the wrong thing and watching the right one hit you.
            if (pull && pull.Flying(hand))
            {
                nearTarget[hand] = pull.CatchableBy(hand, pmo, p);
                continue;
            }

            nearTarget[hand] = RS_Reach.Best(pmo, p, hand);
            // Not something RS_Pull is flying or holding for the OTHER hand.
            // Taking it here would SaveFlags the flight's fiction (no gravity,
            // thru-actors, rolled) as the object's real state and leave two
            // solvers driving one actor. RS_Pull guards the reverse direction
            // itself (rs_distance.zs Lock/Start); this is the near side of it.
            if (pull && nearTarget[hand] != null
                && (pull.FlyingActor(1 - hand) == nearTarget[hand]
                    || pull.Locked(1 - hand) == nearTarget[hand]))
                nearTarget[hand] = null;
            // The cone is only asked when the palm is empty-handed AND empty of
            // anything to close on. Direct reach always wins: a thing you are
            // already touching is unambiguously the thing you meant.
            // PALM DOWN OR NO REACH, not merely no laser.
            //
            // The beam is drawn from farTarget, so gating only the drawing
            // hid the ray and left the grab reaching exactly as before -- the
            // hand still pulled things across the room in a gun grip, with
            // nothing on screen to say it was about to. Gating the TARGET is
            // what actually moves the feature onto the gesture: no target, no
            // beam, no lock, no pull.
            //
            // Same numbers the beam uses, read the same way, so what you see
            // and what will happen cannot disagree.
            bool palmOk = true;
            if (RS_Reach.Flag("rs_dgrab_palm", p, true))
            {
                double rl  = abs(RS_Basis.NormDeg((hand == 0) ? pmo.MainHandRoll : pmo.OffhandRoll));
                double tgt = RS_Reach.Num("rs_dgrab_palm_roll", p, 90.0);
                double tol = RS_Reach.Num("rs_dgrab_palm_tol",  p, 30.0);
                palmOk = (abs(rl - tgt) <= tol);
            }

            // HANDS TOGETHER IS NEVER A REACH ACROSS THE ROOM.
            //
            // Every gesture that brings the palms into one another means
            // something local -- passing a weapon over, racking a slide,
            // wrapping a second hand round a grip. None of them is "lock that
            // barrel forty metres away", and the cone had no idea: a squeeze
            // made with the hands meeting would take the cone's pick as well,
            // so a two-handed hold came with a barrel locked and flashing at
            // the far end of the room, and letting go flicked it at your head.
            //
            // The SAME test the swap gesture and the pose ladder use, so what
            // stands the cone down and what performs the gesture cannot
            // disagree about whether the hands have met.
            //
            // The NEAR grab is deliberately untouched: closing on something
            // your palm is actually inside is unambiguous however your hands
            // are arranged, and that is the path a second hand joining a
            // two-handed carry goes down.
            bool handsMet = RS_Reach.Flag("rs_dgrab_not_when_met", p, true)
                && RS_Reach.OvalsOverlap(pmo, p, hand,
                    RS_Reach.Num("rs_swap_overlap_depth", p, 2.0));

            // A HAND ON A GUN'S PARTS IS NOT AIMING ACROSS THE ROOM.
            //
            // While it is dragging a slide, pulling a magazine or reaching into
            // the pouch, that hand belongs to the weapon. The cone had no idea
            // and went on locking things -- so a rack, which is a hard straight
            // pull toward yourself, is exactly the motion the flick gesture
            // watches for, and the reload ended with a barrel flying at you.
            //
            // Read off the subject the arbiter publishes rather than a second
            // proximity test: whichever mod owns that hand has already said so,
            // and a test invented here could disagree with it.
            int subj = (hand == 0) ? pmo.GripSubjectMain : pmo.GripSubjectOff;
            bool onTheGun = WorkingAGun(subj);

            // AND WHILE IT IS MERELY AT ONE. A weapon package says so every tic
            // the hand is inside a part's volume (grip.near), before anything is
            // held -- so the laser does not lock a barrel behind the slide you
            // are reaching for, only to fire when you rack it.
            if (!onTheGun)
            {
                let arb = ServiceIterator.Find("RS_GripArbiterService").Next();
                if (arb && arb.GetInt("grip.nearq", "", hand, 0, pmo, 'RS_Grab') == 1) onTheGun = true;
            }

            if (!nearTarget[hand] && useCone && palmOk && !handsMet && !onTheGun)
                farTarget[hand] = RS_Cone.Best(pmo, p, hand);
        }

        // TELL THE ENGINE THIS GRIP IS NOT A SHIFT KEY.
        //
        // With vr_secondary_button_mappings on, the dominant grip is the
        // modifier layer whenever it is held, and that layer stands analog
        // turning down -- so reaching for a barrel stopped you turning. The
        // claim outranks the modifier, so the grip means grabbing exactly while
        // there is something to grab and goes back to being the modifier when
        // there is not.
        //
        // Written every tic, both values, like HolsterClaim* -- a per-frame
        // claim that is not restated has been withdrawn.
        // A LOCK COUNTS. It was missing, and its absence undid the whole point
        // of the claim: hold the grip on a barrel, turn to look somewhere else,
        // and the cone stops finding it -- so the claim went false, the arbiter
        // handed the grip back to the modifier layer, and the modifier layer
        // zeroes analog turn. You would be standing there gripping something and
        // unable to turn, which is the exact fault GrabClaim was added to fix.
        //
        // Holding something, reaching for something, pulling something and
        // having hold of something at range are all "this grip is spoken for" --
        // stated once, in GripSpokenFor, because the stand-down below needs the
        // same four conditions and used to carry its own copy of three of them.
        // A HAND ON THE GUN REACHES FOR NOTHING. Braced, or inside the support
        // oval about to be, the off hand is spoken for by the weapon: no near
        // grab, no distance grab, no lock, no box drawn round a pickup it
        // would not take. RS_Stabilize ticks ahead of this handler (MAPINFO)
        // so its answer is this tic's. The targets are cleared here rather
        // than skipped below because the gauge and the beam read them too, and
        // a beam promising a pull from a bracing hand is a lie.
        let stab = RS_Stabilize.Get();
        for (int h = 0; h < 2; h++)
        {
            if (stab && stab.HoldsHand(h))
            {
                nearTarget[h] = null;
                farTarget[h]  = null;
            }
        }

        pmo.GrabClaimMain = GripSpokenFor(0, held, pull, pmo, p);
        pmo.GrabClaimOff  = GripSpokenFor(1, held, pull, pmo, p);

        for (int hand = 0; hand < 2; hand++)
        {
            // THE RAW SQUEEZE, and not GripContext.
            //
            // GripContext was the obvious field and it is a trap here. It is
            // published even while the grip is released -- a hand keeps holding
            // a magazine when you relax your fingers, and the pose has to keep
            // showing that -- so the moment RS_Held claims a subject the context
            // latches to GRIPCTX_Object and never returns to None. Testing
            // `context != 0` for the button therefore works perfectly until the
            // first successful grab and then reports the grip as held forever,
            // which means a toggle can never see the release that would let go.
            // GripHeld* is the button itself.
            bool grip = (hand == 0) ? pmo.GripHeldMain : pmo.GripHeldOff;
            bool press   = grip && !wasGrip[hand];
            bool release = !grip && wasGrip[hand];
            wasGrip[hand] = grip;

            // The squeeze of a hand on the gun belongs to the brace -- it
            // latched it, released it, or is holding it. Nothing below may
            // spend it. The edge above is still tracked so a hand that comes
            // off the gun does not see a stale press.
            if (stab && stab.HoldsHand(hand)) continue;

            // A hand inside a holster volume is reaching for a weapon, and a
            // world object that happens to be at your hip is not what it came
            // for. The arbiter has already worked this out; ask it rather than
            // running a second proximity test that can disagree.
            int ctx = (hand == 0) ? pmo.GripContextMain : pmo.GripContextOff;

            // EVERY SQUEEZE THAT DOES NOTHING SAYS WHY, on the press edge only.
            //
            // A grip that produces no lock is indistinguishable from a grip
            // that never arrived, and from inside a headset there is no way to
            // tell which -- there is no console to ask, and the two have
            // completely different causes. This is one line per press, naming
            // the state of every input the decision reads.
            if (press && dbg && !held.HandIsFull(hand)
                && !(pull && pull.Flying(hand))
                && !nearTarget[hand] && !farTarget[hand]
                && !(pull && pull.Locked(hand)))
            {
                Vector3 c = RS_Reach.Centre(pmo, p, hand);
                // Assigned, not ternaried. GetClassName returns a Name and
                // "none" is a String, and ?: will not mix the two -- the exact
                // error this file already carries a comment about, made again.
                // An assignment coerces Name to string fine; a ternary has to
                // settle on one type before the assignment ever happens.
                string nearName = "none";
                if (nearTarget[hand]) nearName = nearTarget[hand].GetClassName();
                Console.Printf("[RSGRIP] hand %d squeezed, nothing to lock: ctx=%d near=%s palm=(%.0f %.0f %.0f) reach=%.0f spread=%.0f",
                    hand, ctx, nearName,
                    c.x, c.y, c.z,
                    RS_Reach.Num("rs_dgrab_reach", p, 512.0),
                    RS_Reach.Num("rs_dgrab_spread", p, 12.0));
            }

            // A HOLSTER ONLY WINS WHEN THERE IS NOTHING TO GRAB.
            //
            // This used to refuse the grip outright on GRIPCTX_Holster, and it
            // is the likeliest reason the off hand could never lock anything:
            // holsters are anchored to your BODY, and an off hand resting at
            // your side sits inside one more or less permanently. Every squeeze
            // it made was thrown away before the cone was even consulted.
            //
            // The arbiter's priority is about which system OWNS the grip, and it
            // is right that a holster outranks a general reach. But a hand
            // pointing across the room at a barrel is not reaching for its own
            // hip, and the cone having a target is exactly the evidence of that.
            // So: no target, the holster keeps the grip; a target, and the grip
            // was clearly meant for it.
            //
            // AND A FULL HAND IS EVIDENCE TOO -- see GripSpokenFor, which is now
            // the single statement of what "this grip is mine" means. Written out
            // here as three of its four conditions, this guard could not tell a
            // hand reaching into a holster from a hand standing over one with a
            // barrel already in it, and let go of neither.
            //
            // HARDPOINT COUNTS AS WELL AS HOLSTER. Same argument exactly: a body
            // hardpoint is anchored to you, so a hand at rest is inside one, and
            // the arbiter publishes GRIPCTX_Hardpoint there rather than
            // GRIPCTX_Holster (constants.zs:1644). Only the holster half was
            // written, so the same "cannot let go at your own hip" fault survived
            // at every hardpoint. The other half of the hardpoint story -- a
            // shared "the grip was consumed this tic" latch that both doSwap
            // implementations would check -- needs the merged tree and is not
            // here; this is only the stand-down, which is local and correct on
            // its own.
            // Named apart from the function it came from. ZScript identifiers
            // are case-insensitive, and a local that differs from a method of the
            // same class by case alone does compile here -- `Vector3 dir =
            // Dir(...)` in rs_distance.zs is exactly that and has always worked
            // -- but it reads as a definition of the thing it is calling, and
            // this is not the file to spend a headset run finding that out in.
            bool spokenFor = GripSpokenFor(hand, held, pull, pmo, p);
            // THE POUCH, AND A CARRY OUT OF IT, BELONG TO THE RELOAD LANE. A
            // hand reaching into the chest pouch carries GRIPSUBJ_Pouch and a
            // hand carrying ammunition out of it carries the reload's own
            // subject; the engine's ladder reads any claim as GRIPCTX_Object,
            // so this lane never stood down for either and the squeeze that
            // drew a magazine also locked a cone target or hand-swapped.
            // (RS_Held's own holds use the same subjects with a FULL hand.)
            int subjHere = (hand == 0) ? pmo.GripSubjectMain : pmo.GripSubjectOff;
            bool reloadReach = ReloadSubject(subjHere) && !(held && held.HandIsFull(hand));
            if (reloadReach)
            {
                if (press && dbg)
                    Console.Printf("[RSGRIP] hand %d ignored -- reaching in the pouch / carrying ammunition", hand);
                continue;
            }
            if ((ctx == GRIPCTX_Holster || ctx == GRIPCTX_Hardpoint) && !spokenFor)
            {
                if (press && dbg)
                    Console.Printf("[RSGRIP] hand %d ignored -- arbiter says ctx=%d and nothing is in reach", hand, ctx);
                continue;
            }

            bool full = held.HandIsFull(hand);

            // THE FLICK. A yank of an empty hand toward yourself, at something
            // the cone has already locked, pulls it -- no button.
            //
            // Everything about it is a condition rather than a gesture parser,
            // and each one is here to stop a false pull rather than to describe
            // a motion:
            //   - the hand must be EMPTY and not already pulling. Otherwise the
            //     flick that throws something would immediately pull it back.
            //   - there must be a LOCK. A flick with nothing selected is just
            //     you moving your arm, which happens constantly.
            //   - the motion must come TOWARD you. Measured against the cone's
            //     own aim axis, so a forward swing -- a punch, a throw -- can
            //     never read as "come here" however hard it is.
            // The speed itself is the last test, not the first: any of the
            // above being false means the question was never asked.
            // HOLD THE GRIP TO KEEP THE LOCK. LET GO TO THROW IT.
            //
            // The grip is not a toggle here, it is a fist. You close it on the
            // thing and it stays yours while your fingers stay shut; open them
            // and it is gone. The whole gesture is one continuous act rather
            // than three separate button events, which is why it reads as
            // taking hold of something rather than operating a machine.
            //
            // AND THE RELEASE IS WHERE THE DECISION IS MADE. Open your hand
            // while it is moving and the object is thrown to you; open it at
            // rest and you simply let go. There is no separate flick input to
            // get wrong -- the same act means both things, and which one you
            // got is decided by whether your arm was doing anything.
            Actor locked = pull ? pull.Locked(hand) : null;

            if (!full && pull && !pull.Flying(hand))
            {
                // Close on it. Only while the cone actually has something --
                // squeezing at empty air locks nothing.
                if (grip && !locked && farTarget[hand])
                {
                    if (pull.Lock(hand, farTarget[hand], pmo, p))
                    {
                        locked = farTarget[hand];
                        continue;
                    }
                    if (press && dbg)
                        Console.Printf("[RSGRIP] hand %d had %s in the cone and Lock REFUSED it (ctx=%d)",
                            hand, farTarget[hand].GetClassName(), ctx);
                }
                else if (press && trace && grip && !locked && !farTarget[hand] && !nearTarget[hand])
                {
                    Console.Printf("[RSGRIP] hand %d: cone found nothing (ctx=%d)", hand, ctx);
                }

                // Open your hand. Moving = throw it to me; still = let it go.
                if (release && locked)
                {
                    let sw = RS_Swing.Get();
                    Vector3 v = sw ? sw.PeakVelocity(hand) : (0, 0, 0);
                    double need = RS_Swing.MetresPerSecToUnitsPerTic(
                        RS_Reach.Num("rs_flick_speed", p, 2.5));

                    // Toward you, still. A forward swing releasing at speed is
                    // a throw away from yourself, and reading that as "come
                    // here" is the one confusion this gesture cannot afford
                    // once real throwing shares the same arm.
                    double toward = -(v dot RS_Cone.Dir(pmo, hand));
                    bool pulledBack = v.Length() >= need && toward > 0;

                    // TIP THE WRIST UP, which is the default as of 2026-08-28,
                    // and the reason is ergonomic rather than technical.
                    //
                    // Dragging the whole hand back toward the body is a
                    // SHOULDER movement. Seated, with an elbow on an armrest,
                    // that is the one motion you cannot make repeatedly -- and
                    // this mod is played seated. A wrist tip is the same intent
                    // routed through the joint that is still free.
                    //
                    // Degrees per tic, so it is a RATE and not a total: a slow
                    // deliberate lift of the whole forearm never crosses it, no
                    // matter how far it travels, while a sharp tip of the wrist
                    // does immediately. That is what separates the gesture from
                    // ordinary aiming, and it is why raising the threshold is
                    // the fix if it ever misfires -- not shortening the window.
                    double upRate = sw ? sw.PeakPitchUp(hand) : 0.0;
                    bool flickedUp = upRate >= RS_Reach.Num("rs_flick_pitch", p, 5.0);

                    // Mode, not an OR. Accepting both would put the old
                    // shoulder-pull back in as an accidental trigger for
                    // exactly the player the wrist gesture exists to serve --
                    // draw your hand back to rest and the pull fires.
                    int mode = RS_Reach.Opt("rs_dgrab_flick_mode", p, 1);
                    bool gesture = (mode == 0) ? pulledBack : flickedUp;

                    bool flicked = RS_Reach.Flag("rs_dgrab_flick", p, true) && gesture;

                    if (flicked && pull.Start(hand, locked, pmo, p))
                    {
                        // The peak lingers in the window for a fifth of a second
                        // after the motion stops, which is long enough to fire a
                        // second pull the instant the first one lands.
                        if (sw) sw.Forget(hand);
                        // Reports whichever number actually decided it, so a
                        // misfire can be tuned against the right threshold
                        // instead of the one that happened to be printed.
                        if (dbg) Console.Printf("[RSPULL] hand %d FLICKED %s (%s)",
                            hand, locked.GetClassName(),
                            (mode == 0)
                                ? String.Format("%.1f m/s", RS_Swing.UnitsPerTicToMetresPerSec(v.Length()))
                                : String.Format("%.1f deg/tic up", upRate));
                        continue;
                    }

                    pull.Unlock(hand);
                    if (dbg) Console.Printf("[RSPULL] hand %d opened its hand -- %s let go",
                        hand, locked.GetClassName());
                    continue;
                }
            }

            // HOLD-TO-KEEP: let go when the fingers open. Toggle exists because
            // holding a squeeze closed for a whole session is a hand cramp, and
            // hold-to-keep exists because a toggle drops things you meant to
            // keep. H3VR ships both for the same reason.
            //
            // A THROW RELEASES IN EITHER MODE, and without this throwing did not
            // work at all at defaults.
            //
            // rs_hold_toggle ships true, and in toggle mode the only release is
            // a second PRESS -- everything below the `if (!press) continue;`
            // gate needs a press edge. So opening your hand did nothing, and the
            // only way to throw was to hit the grip button at the exact peak of
            // a swing. That is not a gesture anybody would find, and it is why
            // throwing read as missing rather than as awkward.
            //
            // A fast release is unambiguous: nothing else in the scheme means
            // "open your hand while your arm is moving hard". Below the same
            // threshold a throw already uses (rs_throw_min), toggle keeps
            // behaving exactly as before -- open your hand slowly and you go on
            // holding the thing, which is the whole point of the mode.
            bool throwRelease = false;
            if (toggle && release && full)
            {
                let sw = RS_Swing.Get();
                double need = RS_Swing.MetresPerSecToUnitsPerTic(
                    RS_Reach.Num("rs_throw_min", p, 1.2));
                throwRelease = RS_Reach.Flag("rs_throw", p, true)
                    && sw && sw.PeakSpeed(hand) >= need;
            }

            if (((!toggle && release) || throwRelease) && full)
            {
                Actor was = held.HeldBy(hand);
                String wasName = "something";
                if (was) wasName = was.GetClassName();
                held.Release(hand, pmo, p);
                if (dbg) Console.Printf("[RSHELD] hand %d let go of %s", hand, wasName);
                continue;
            }

            // CATCH. The same input that threw it takes it out of the air.
            //
            // A HELD GRIP CATCHES, not only a fresh press edge, and this sits
            // above the `!press` gate for that reason alone.
            //
            // Below the gate it needed a NEW press in the handful of tics the
            // object was inside your reach volume -- so the natural thing, which
            // is to close your hand and hold it out waiting for the thing to
            // arrive, could never catch anything. Your fist was already shut when
            // the window opened, there was no edge left to give, and the object
            // sailed through your closed hand and hit you. Holding your hand open
            // and snapping it shut at the right instant was the only motion that
            // worked, which is the opposite of how catching feels.
            //
            // The MISS LOG stays on the edge. It fires when you reached and the
            // thing was not there yet, and that is a per-attempt message: on a
            // held grip it would print every tic of the flight.
            if (pull && pull.Flying(hand))
            {
                if (grip && nearTarget[hand] && pull.Catch(hand, pmo, p)) continue;
                // Reached for it and it was not there yet. Said out loud,
                // because a catch that silently does nothing is indistinguish-
                // able from an input that never arrived.
                if (press && dbg)
                {
                    // GetClassName() returns Name, not string -- ?: needs
                    // both branches the SAME type, which a ternary mixing a
                    // Name-typed call with a string literal does not give it
                    // (this was one of the real compile errors:
                    // "Incompatible types for ?: operator"). Plain if/else
                    // instead, not another ternary -- an assignment coerces
                    // Name->string fine, but that only helps once the value
                    // on the right is already settled to one type.
                    Actor flying = pull.FlyingActor(hand);
                    string flyingName = "air";
                    if (flying)
                        flyingName = flying.GetClassName();
                    Console.Printf("[RSPULL] hand %d grabbed at %s and missed", hand, flyingName);
                }
                continue;
            }

            if (!press) continue;

            // HANDS TOGETHER, GRIP: TAKE WHAT THE OTHER HAND IS HOLDING.
            //
            // Bring your palms together and squeeze, and the weapon crosses
            // over. The hand you squeeze is the hand doing the TAKING, which is
            // why this passes `hand` straight through: SwitchWeaponHand's
            // argument is the DESTINATION -- it lifts the weapon out of the
            // other slot and brings it up in this one.
            //
            // THE SAME CALL THE switchhand KEYBIND MAKES, deliberately, rather
            // than a second swap implementation living over here. A gesture and
            // a key that do the same thing should reach the same code, or they
            // drift and only one of them ever gets the next fix.
            //
            // SAFE FROM HERE, and it is not safe from everywhere: that CCMD
            // queues the call through the net layer specifically BECAUSE a
            // console command runs outside P_Ticker, and SwitchWeaponHand nulls
            // BOTH weapon slots before repopulating them -- land a psprite tick
            // inside that window and TickPSprites destroys both layers, which
            // is the weapons-flashing-and-vanishing bug documented at the CCMD.
            // This is an EventHandler WorldTick, already inside the tick, so
            // the swap completes between psprite ticks the same way the
            // multiplayer path does.
            //
            // ABOVE the grab handling, so overlapping hands mean "swap" and not
            // "grab whatever happens to be between us". Consumes the press.
            // ONLY WHEN NEITHER HAND IS CARRYING ANYTHING, and that guard is
            // not paranoia -- without it this breaks two-handed carry outright.
            //
            // rs_hold_twohand ships on, and joining a second hand to something
            // works by bringing that hand TO the object the first one holds and
            // squeezing. That puts the palms a few units apart by definition,
            // which is exactly the condition below. So gripping to two-hand a
            // barrel would have swapped weapons instead, every time, and the
            // barrel is the one object the policy explicitly marks two-handed.
            //
            // nearTarget matters for the same reason from the other direction:
            // something grabbable inside this hand's volume means the press was
            // a reach, not a swap. A weapon swap is what a grip means only when
            // there is nothing else it could mean.
            bool carrying = held && (held.HandIsFull(hand) || held.HandIsFull(1 - hand));

            // A BRACE AND A SWAP CAN BE THE SAME TAP. An off-hand squeeze with
            // the palms together while the main hand holds a pistol is both
            // "take the pistol" and "wrap my second hand round it", and the
            // gesture cannot tell them apart -- only the rule can. RS_Stabilize
            // runs ahead of this handler (MAPINFO order) and says whether this
            // press latched or released a brace; if it did, the press was spent
            // and this is not a swap. The rule that separates them lives over
            // there: a brace wants the main grip held too, a swap wants it open.
            let stab = RS_Stabilize.Get();
            bool braced = stab && stab.TookPress(hand);

            // THE SAME PALM GATE THE CLAIM USES. SwapPoised above decides
            // whether this grip is spoken for; this decides whether it swaps.
            // They have to agree, or the modifier layer is given up for a
            // gesture that then does not happen.
            bool palmUp = true;
            if (RS_Reach.Flag("rs_swap_needs_palm", p, true))
            {
                double srl  = abs(RS_Basis.NormDeg((hand == 0) ? pmo.MainHandRoll : pmo.OffhandRoll));
                double stgt = RS_Reach.Num("rs_dgrab_palm_roll", p, 90.0);
                double stol = RS_Reach.Num("rs_dgrab_palm_tol",  p, 30.0);
                palmUp = (abs(srl - stgt) <= stol);
            }

            if (RS_Reach.Flag("rs_swap_overlap", p, true) && palmUp && !carrying && !nearTarget[hand] && !braced)
            {
                // THE SAME TEST THE CLAIM USES. SwapPoised above and this
                // both go through RS_Reach.OvalsOverlap, so the grip that
                // claims the context and the grip that swaps can never
                // disagree about what "overlapped" means.
                double depth = RS_Reach.Num("rs_swap_overlap_depth", p, 2.0);

                // Tuning readout: the two scores in oval radii, printed while
                // the palms are anywhere near each other, so the depth above
                // can be set from what the hands actually do rather than from
                // a guess. Squared, so 1.0 is the oval's own surface.
                if (dbg)
                {
                    Vector3 mine  = RS_Reach.Centre(pmo, p, hand);
                    Vector3 other = RS_Reach.Centre(pmo, p, 1 - hand);
                    Vector3 ax    = RS_Reach.SemiAxes(p, hand);
                    Console.Printf("[RSSWAP] hand %d palms %.1f apart, oval %.2f/%.2f/%.2f, overlap %.2f/%.2f (need <= %.2f)",
                        hand, (mine - other).Length(), ax.x, ax.y, ax.z,
                        RS_Reach.Score(pmo, p, hand, other),
                        RS_Reach.Score(pmo, p, 1 - hand, mine),
                        depth * depth);
                }

                if (RS_Reach.OvalsOverlap(pmo, p, hand, depth))
                {
                    // THERE HAS TO BE SOMETHING WORTH TAKING.
                    //
                    // SwitchWeaponHand nulls BOTH weapon slots before it
                    // repopulates them, and it only ever restores two things:
                    // the weapon it lifted out of the source slot, and
                    // PickNextWeapon's answer. Anything sitting in the
                    // DESTINATION slot is not among them -- it is orphaned
                    // unless PickNextWeapon happens to name it.
                    //
                    // Which is exactly what a second press does. Pass a gun
                    // main->off and the main hand is left holding a fist; press
                    // again with the hands still together and the source is now
                    // that fist, both slots are nulled, the fist comes back, and
                    // the GUN -- the thing in the destination hand -- is gone
                    // completely. Reported 2026-08-28, reproduced from the
                    // engine source above.
                    //
                    // Refusing when the source hand holds nothing but a fist is
                    // both the fix and the right rule anyway: passing a fist is
                    // not a thing anyone means to do, and a second squeeze with
                    // the hands still overlapped means "I already did this",
                    // not "throw the gun away".
                    //
                    // The source is resolved the same way SwitchWeaponHand
                    // resolves it -- destination `hand` takes from the OTHER
                    // slot -- so this cannot disagree with what the call does.
                    Weapon src = (hand == 0) ? p.OffhandWeapon : p.ReadyWeapon;
                    bool passable = src && !src.bNoHandSwitch
                                        && !RS_HandFist.IsFistClass(src.GetClass());

                    if (passable)
                    {
                        pmo.SwitchWeaponHand(hand);
                        level.VRHaptic(hand, 0.5, 35.0);
                        if (dbg) Console.Printf("[RSSWAP] hand %d took %s from the other hand", hand, src.GetClassName());
                        continue;
                    }

                    if (dbg)
                    {
                        String srcName = "nothing";
                        if (src) srcName = src.GetClassName();
                        Console.Printf("[RSSWAP] hand %d refused: other hand holds %s", hand, srcName);
                    }
                }
            }

            if (toggle && full)
            {
                Actor was = held.HeldBy(hand);
                String wasName = "something";
                if (was) wasName = was.GetClassName();
                held.Release(hand, pmo, p);
                if (dbg) Console.Printf("[RSHELD] hand %d let go of %s", hand, wasName);
                continue;
            }

            Actor a = nearTarget[hand];

            // A GRIP PRESS AT ARM'S LENGTH IS A LOCK, NOT A LAUNCH.
            //
            // Nothing moves. You have taken hold of the thing where it stands,
            // and it stays there flashing orange-green until you flick it to
            // you, press again to let go, or lose it out of range.
            //
            // Pressing again while already locked releases -- the same toggle
            // the near grab uses, so the grip means one thing at both ranges.
            // Locking is not handled here any more -- holding the grip IS the
            // lock, resolved above before any press edge is considered. A press
            // at a distant object with nothing in your palm falls through to
            // the refusal below, which says where it looked.

            if (!a)
            {
                // Says where it looked, not just that it failed. A refusal that
                // does not name its own centre is indistinguishable from an
                // input that never arrived.
                if (dbg)
                {
                    Vector3 c = RS_Reach.Centre(pmo, p, hand);
                    Console.Printf("[RSHELD] hand %d: nothing in reach. centre=(%.1f %.1f %.1f)",
                        hand, c.x, c.y, c.z);
                }
                continue;
            }

            // Asked ONCE, and the same answer feeds all three questions. Three
            // separate lookups for "may I", "what shape" and "one hand or two"
            // are three answers that can disagree about the same object.
            // TAKEN AS SOMETHING ELSE, when the mod that owns what it is for
            // says so -- before the rules, so they speak for what is held.
            if (!held.IsHeld(a)) a = RS_GrabPolicy.Become(hand, a);
            if (!a) continue;

            let pol = RS_GrabPolicy.Get();
            let rule = pol ? pol.Decide(a, pmo, p) : null;
            if (!rule) continue;

            // Some things resolve instead of being held -- a weapon that
            // equips, a third copy that becomes ammo. Same rule whether it came
            // off the floor or out of the air. A mod's GrabTakeService is asked
            // first (RS_GrabPolicy.AskTake); with none loaded it answers nothing
            // and OnTake decides, as before.
            if (RS_GrabPolicy.AskTake(hand, a, false) || pol.OnTake(hand, a, rule, pmo, p)) continue;

            int result = held.Take(hand, a, rule.subject, rule.pose, rule.twohand, p);

            if (dbg)
            {
                String what = "REFUSED";
                if (result == RS_Held.TAKE_TOOK)        what = "took";
                else if (result == RS_Held.TAKE_JOINED) what = "put a second hand on";
                else if (result == RS_Held.TAKE_PASSED) what = "took over";
                Console.Printf("[RSHELD] hand %d %s %s (%s)",
                    hand, what, a.GetClassName(), rule.why);
            }
        }
    }
}
