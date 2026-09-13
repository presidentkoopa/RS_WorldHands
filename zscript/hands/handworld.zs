// The hands as WORLD ACTORS, riding the controllers through MDL_FOLLOWMAINHAND
// and MDL_FOLLOWOFFHAND.
//
// The psprite hands work, and they work because RenderHUDModel reads the
// controller transform itself, every frame. But a psprite hand is drawn relative
// to your eye: it can never be grabbed, never collide, never hold a world object
// by an arbitrary point. Everything the plan is aiming at needs the hand to be a
// thing in the world, on the same footing as the gun.
//
// This is the same wire the M9 world actor uses, pointed at the other two poses.
//
// THREE THINGS THAT LOOK LIKE TRACKING FAILURE AND ARE NOT:
//   - a TNT1 sprite is never drawn, model or not -- it is an instruction to skip
//     the actor entirely, checked before any model is considered.
//   - the actor is CULLED on its true world position while being DRAWN at your
//     hand, so it must be kept near the player or it silently vanishes.
//   - world-path scale is vr_vunits_per_meter (34 units/metre). The HUD path
//     works out to 173.44. A model scaled for one is wildly wrong on the other,
//     and that is the entire "100x" class of bug in one sentence.

class RS_HandWorldBase : Actor
{
    Default
    {
        +NOGRAVITY;
        +NOBLOCKMAP;
        +NOINTERACTION;
        // MUST be present, and its absence is a hard crash rather than a warning.
        // The MODELDEF block for these ends in BaseFrame, which registers into
        // BaseSpriteModelFrames -- and that registry is what a DECOUPLEDANIMATIONS
        // actor's model lookup reads. BaseFrame without the flag is a mismatched
        // pair: the model is registered somewhere nothing consults, and the lookup
        // walks a path that was never set up. It took the game down on map load
        // with nothing in the log at all.
        +DECOUPLEDANIMATIONS;
        Radius 1;
        Height 1;
        RenderStyle "Normal";
    }


    // ---- POSES -------------------------------------------------------------
    //
    // HOW A POSE ACTUALLY REACHES THE BONES, because this is the part every
    // previous attempt got wrong.
    //
    // The hand rig carries ONE clip, "ArmatureAction", 1298 frames. The poses
    // are FRAMES of it: 0-10 are the baked hand shapes and 1289-1297 are the
    // manipulation set. There is no separate animation to play and nothing to
    // start -- holding a grip is one frame re-asserted.
    //
    // The decoupled animation path resolves a frame through MODELDEF's sprite
    // letter table, which caps at MAX_SPRITE_FRAMES. No sprite letter can name
    // frame 1293. That is the whole reason the manipulation set has been
    // authored and unreachable this entire time -- not a rigging problem, an
    // addressing one.
    //
    // ModelFrame / ModelFrameNext / ModelFrameLerp address a frame by NUMBER
    // and bypass that table. They existed only on DPSprite, which is why the
    // psprite hands could be posed and world-actor hands never could; they are
    // now on AActor too (actor.h, RS fork).
    //
    // The lerp blends BONE MATRICES, not sprite frames -- the fingers travel
    // from one shape to the other, so a grip closes rather than appearing
    // closed. Setting both frames equal with a lerp of 0 is an explicit
    // instruction NOT to blend, and that reads as the hand teleporting.

    const POSE_OPEN     = 0;   // rest
    const POSE_POINT    = 1;   // 3-4-5 closed, index and thumb out
    const POSE_TRIGGER  = 2;   // index curled alone
    const POSE_FIST     = 3;
    const POSE_PINCH    = 4;   // thumb meets index -- magazines, shells, slide
    const POSE_THUMBOUT = 5;   // fist, thumb clear -- magazine release
    const POSE_GRIPFIRE = 6;   // on a gun, trigger pulled
    const POSE_GRIP_TU  = 7;   // on a gun, thumb lifted
    const POSE_READY_TD = 8;   // index resting ON the trigger, thumb wrapped
    const POSE_READY_TU = 9;   // index on the trigger, thumb lifted
    const POSE_FIRE_TU  = 10;  // firing, thumb lifted
    const POSE_MAX      = 10;

    const HOLD_BASE     = 1289;
    const POSE_HOLD_ROUND    = HOLD_BASE + 0;   // one cartridge, fingertips
    const POSE_HOLD_SHELL    = HOLD_BASE + 1;
    const POSE_INSERT        = HOLD_BASE + 2;   // thumb driving it home
    const POSE_HOLD_SLIDE    = HOLD_BASE + 3;   // pinched on the serrations
    const POSE_HOLD_MAG      = HOLD_BASE + 4;
    const POSE_HOLD_FOREGRIP = HOLD_BASE + 5;
    const POSE_HOLD_FOREND   = HOLD_BASE + 6;   // a fat cylinder -- a barrel
    const POSE_REACH         = HOLD_BASE + 7;   // splayed, about to take hold
    const POSE_SUPPORT       = HOLD_BASE + 8;   // wrapped round the firing hand

    // Capacitive pads. Where the fingers REST, which buttons cannot report: a
    // thumb lying on the stick and a thumb lifted clear are the same button
    // state, and so are a finger indexed along the frame and one on the trigger.
    const TOUCH_THUMB = 1;
    const TOUCH_INDEX = 2;

    // Blend state.
    private int    poseFrom, poseTo;
    private double poseT;

    // What the thing being HELD wants this hand to look like, -1 for nothing.
    // Written by whatever took hold of something -- a gun's grab handler knows
    // it was caught by the barrel and this is how it says so. Deliberately not
    // a set of weapon-specific flags: any future weapon says what shape it
    // needs and needs no support here.
    int poseHold;

    // WEARING ANOTHER MESH.
    //
    // Another package can dress this hand in a mesh of its own -- RS_VRBody puts
    // its Quake hands on it with A_ChangeModel and a MODELDEF of theirs, which
    // brings that mesh's scale and sliders along. The hand stays THIS actor, so
    // everything that holds it -- grabbing, pinning to a slide, the pose
    // publishers -- keeps working unchanged.
    //
    // Two things do change, and they are why this is here rather than in the
    // package doing the dressing:
    //
    //   FRAMES. Every pose here is written as a frame number of hand_left.iqm
    //   (0-10, 1289+). A worn mesh numbers its poses its own way, so the frames
    //   are mapped at the one place they are written -- Tick -- and this actor
    //   stays their only writer. remapFrom/remapTo pairs, remapElse for the rest.
    //
    //   BONES. A worn mesh may have no skeleton. Asking one for HANDPALM_joint
    //   prints "Could not find bone" on every call, several times a tic, so a
    //   reader checks `worn` first and takes the mesh's origin as the palm.
    //
    // Set through RS_HandPoseService "pose.wear" (below), so the dresser never
    // names this class.
    bool       worn;
    Array<int> remapFrom;
    Array<int> remapTo;
    int        remapElse;

    int WornFrame(int f) const
    {
        if (!worn) return f;
        for (int i = 0; i < remapFrom.Size(); i++)
            if (remapFrom[i] == f) return remapTo[i];
        return remapElse;
    }

    void SetPose(int frame)
    {
        if (frame == poseTo) return;
        // Interrupting a blend keeps the ORIGINAL start rather than snapping to
        // the abandoned target first.
        if (poseT >= 1.0) poseFrom = poseTo;
        poseTo = frame;
        poseT  = 0;
    }

    int GetPose() const { return poseTo; }

    // Called by the holder every tic it wants a shape; -1 hands control back to
    // the controllers.
    void HoldPose(int frame) { poseHold = frame; }

    override void PostBeginPlay()
    {
        Super.PostBeginPlay();
        poseFrom = POSE_OPEN;
        poseTo   = POSE_OPEN;
        poseT    = 1.0;
        poseHold = -1;
    }

    override void Tick()
    {
        Super.Tick();

        // Position is for CULLING only -- the renderer takes the draw transform
        // straight from the controller. moving=false so no interpolation is
        // retained: this transform is authored elsewhere and smearing it between
        // tics is exactly the drift the world path exists to avoid.
        let p = players[consoleplayer].mo;
        if (p)
            SetOrigin(p.Pos, false);

        // Advance the blend and publish it. Written every tic rather than only
        // on change: these are renderer-owned fields with no serialisation, and
        // a value written once and never refreshed is exactly the kind of thing
        // that survives until the first save/load and then quietly stops.
        double speed = 4.0;
        let c = CVar.GetCVar("rs_handworld_blend", players[consoleplayer]);
        if (c && c.GetFloat() > 0) speed = c.GetFloat();

        if (poseT < 1.0)
        {
            poseT += 1.0 / speed;
            if (poseT >= 1.0) { poseT = 1.0; poseFrom = poseTo; }
        }

        // In the worn mesh's own numbering when one is worn -- see WornFrame.
        ModelFrame     = WornFrame(poseFrom);
        ModelFrameNext = WornFrame(poseTo);
        ModelFrameLerp = poseT;
    }

    States
    {
    Spawn:
        PIST A -1;   // any REAL sprite; TNT1 would skip the actor entirely
        Stop;
    }
}

class RS_HandWorldMain : RS_HandWorldBase { }
class RS_HandWorldOff  : RS_HandWorldBase { }

// Spawns them and keeps exactly one of each alive.
class RS_HandWorldHandler : EventHandler
{
    static bool Flag(String name, PlayerInfo p, bool fallback)
    {
        let c = CVar.GetCVar(name, p);
        return c ? c.GetBool() : fallback;
    }

    // Live reconcile state. No field initializers in this codebase, so both
    // rely on the zero-default: lastWantValid starts false, which forces the
    // first WorldTick after a load to evaluate rather than compare against a
    // meaningless zero.
    private bool lastWant;
    private bool lastWantValid;

    // Spawn or destroy the world hands to match the cvar. IDEMPOTENT -- it
    // spawns only what is missing and destroys only what is unwanted -- which
    // is what makes it safe to call every time the setting changes rather than
    // only at level load.
    private void Reconcile()
    {
        for (int i = 0; i < MAXPLAYERS; i++)
        {
            if (!playeringame[i] || players[i].mo == null) continue;
            let p = players[i];
            let pmo = p.mo;

            bool want = Flag("rs_handworld", p, true);

            for (int k = 0; k < 2; k++)
            {
                String cls = (k == 0) ? "RS_HandWorldMain" : "RS_HandWorldOff";
                bool found = false;
                ThinkerIterator it = ThinkerIterator.Create(cls);
                Actor a;
                while (a = Actor(it.Next()))
                {
                    if (!want) { a.Destroy(); }
                    else found = true;
                }
                if (want && !found)
                    Actor.Spawn(cls, pmo.Pos);
            }

            Console.Printf("[HANDWORLD] world hands %s", want ? "ON" : "off");
        }
    }

    override void WorldLoaded(WorldEvent e)
    {
        Reconcile();

        // Seed the live-change detector so the first tick does not immediately
        // reconcile a second time for no reason.
        let p = players[consoleplayer];
        if (p)
        {
            lastWant = Flag("rs_handworld", p, true);
            lastWantValid = true;
        }
    }

    // Find a hand, so anything holding something can ask for a shape.
    static RS_HandWorldBase Get(int hand)
    {
        String cls = (hand == 0) ? "RS_HandWorldMain" : "RS_HandWorldOff";
        ThinkerIterator it = ThinkerIterator.Create(cls);
        Actor a = Actor(it.Next());
        return RS_HandWorldBase(a);
    }

    // WHAT THE HAND IS CLOSED ON -> WHAT SHAPE IT MAKES.
    //
    // The same table RS_HandsAlwaysOn.PoseForSubject carries for the psprite
    // hands, in the same order, so the two cannot drift. -1 means the subject
    // says nothing useful and the ladder falls through.
    //
    // GRIPSUBJ_Grip is deliberately absent, exactly as it is over there: a hand
    // on a pistol grip is already the best-served case, with six poses covering
    // trigger pulled, finger resting and thumb up or wrapped, and one flat
    // "holding a grip" frame would be a downgrade rather than an addition.
    static int PoseForSubject(int subj)
    {
        switch (subj)
        {
        // A SINGLE CARTRIDGE IS A PINCH BEFORE IT IS A HOLD.
        //
        // POSE_PINCH -- thumb meets index -- is what the mesh carries for the
        // moment of taking one, and POSE_HOLD_ROUND is the fuller fingertip
        // grip once it is yours. Both were authored and neither was reachable:
        // nothing mapped to PINCH at all.
        //
        // Round takes the pinch when the hand is still CLOSING on it (the
        // engine reports a holster/pouch-style reach as its own subject, so a
        // Round claim means it is already in hand) -- so this stays HOLD_ROUND
        // and PINCH is reached through the reach subjects below, where a hand
        // going for something small should already be shaped for it.
        case GRIPSUBJ_Round:     return RS_HandWorldBase.POSE_HOLD_ROUND;
        case GRIPSUBJ_Shell:     return RS_HandWorldBase.POSE_HOLD_SHELL;
        case GRIPSUBJ_Inserting: return RS_HandWorldBase.POSE_INSERT;
        case GRIPSUBJ_Magazine:  return RS_HandWorldBase.POSE_HOLD_MAG;
        case GRIPSUBJ_Forend:    return RS_HandWorldBase.POSE_HOLD_FOREND;
        case GRIPSUBJ_Foregrip:  return RS_HandWorldBase.POSE_HOLD_FOREGRIP;
        case GRIPSUBJ_Slide:     return RS_HandWorldBase.POSE_HOLD_SLIDE;
        case GRIPSUBJ_Support:   return RS_HandWorldBase.POSE_SUPPORT;
        case GRIPSUBJ_Holster:   return RS_HandWorldBase.POSE_REACH;
        case GRIPSUBJ_Pouch:     return RS_HandWorldBase.POSE_REACH;
        }
        return -1;
    }

    // What an EMPTY hand does. A hand holding something has its shape decided by
    // the thing it is holding, which is the only party that knows whether it was
    // caught by the grip or the barrel.
    static int PoseForEmpty(bool grip, bool trigger, int touch)
    {
        bool thumbDown = (touch & RS_HandWorldBase.TOUCH_THUMB) != 0;

        if (grip && trigger) return RS_HandWorldBase.POSE_FIST;
        // Empty-hand grip: three fingers closed, index out. Where the thumb goes
        // is the player's, read off the pad rather than assumed -- rest it on the
        // controller and it tucks in, lift it and it stands up.
        if (grip)    return thumbDown ? RS_HandWorldBase.POSE_POINT
                                      : RS_HandWorldBase.POSE_GRIP_TU;
        if (trigger) return RS_HandWorldBase.POSE_TRIGGER;
        return RS_HandWorldBase.POSE_OPEN;
    }

    override void WorldTick()
    {
        let p = players[consoleplayer];
        if (!p || !p.mo) return;
        let pmo = p.mo;

        // LIVE RECONCILE. rs_handworld used to be read only in WorldLoaded, so
        // toggling it in the menu did nothing until the next map -- while the
        // menu presented it as an ordinary switch. There is no menu callback for
        // a cvar in ZScript, so a cheap compare against the last value is the
        // only way to notice; RS_GrabPolicy already does exactly this for
        // rs_grab_nowalkover (rs_grabpolicy.zs:265-272).
        //
        // A bool compare per tic is nothing next to the two ThinkerIterators
        // below, and Reconcile only runs on an actual change.
        bool wantWorld = Flag("rs_handworld", p, true);
        if (!lastWantValid || wantWorld != lastWant)
        {
            lastWant = wantWorld;
            lastWantValid = true;
            Reconcile();
        }

        // A forced pose beats everything, and it is HELD rather than latched --
        // leaving the menu on a pose parks the hand there for as long as it takes
        // to look at it. There is no console in play; this is how a pose gets
        // inspected at all.
        int forced = -1;
        let cf = CVar.GetCVar("rs_handworld_forcepose", p);
        if (cf && cf.GetInt() >= 0)
        {
            // The menu numbers the poses 0..19 continuously, because a dropdown
            // that jumps from 10 to 1289 would be absurd. The manipulation set
            // really does live past the source animation, so anything above
            // POSE_MAX is mapped across to where it actually is.
            int v = cf.GetInt();
            forced = (v <= RS_HandWorldBase.POSE_MAX)
                ? v
                : min(RS_HandWorldBase.HOLD_BASE + (v - RS_HandWorldBase.POSE_MAX - 1),
                      RS_HandWorldBase.HOLD_BASE + 8);
        }

        for (int h = 0; h < 2; h++)
        {
            let hd = Get(h);
            if (!hd) continue;

            bool grip = (h == 0) ? (pmo.GripContextMain != 0) : (pmo.GripContextOff != 0);
            bool trig = (h == 0) ? ((p.cmd.buttons & BT_ATTACK) != 0)
                                 : ((p.cmd.buttons & BT_OFFHANDATTACK) != 0);
            int touch = (h == 0) ? pmo.FingerTouchMain : pmo.FingerTouchOff;

            // A POSE PUBLISHED BY THE BODY, third of four rungs.
            //
            // RS_VRBody owns the hand SLOT even when this package owns the hand
            // ACTOR: when it is loaded it stands its own hands down (one hand
            // per controller, and this one can grab) but keeps saying what shape
            // the hand should be in, because that is a body-level fact -- a
            // holster being reached into, a ladder, an armour pickup.
            //
            // A FRAME NUMBER, ALREADY TRANSLATED, and it has to be. The two
            // packages do not share a pose vocabulary: they agree up to index 6
            // and diverge from 7 (GRIP vs GRIP_TU), and RS_VRBody numbers twenty
            // poses contiguously where these eleven are followed by a jump to
            // HOLD_BASE. An INDEX passed across that boundary makes the wrong
            // shape and only for the poses anyone cares about. So RS_VRBody
            // resolves it against whichever hand mesh is in the slot and
            // publishes the result, exactly as poseHold is already a number and
            // not a set of weapon flags.
            //
            // BELOW poseHold on purpose. Something physically in this hand knows
            // better than the body does; -1 is "nothing to say" and falls
            // through to the controllers, so a body with no opinion leaves an
            // idle hand alone.
            //
            // Soft by cvar name, so RS_VRBody absent reads as -1 and this rung
            // never fires.
            int bodyPose = -1;
            let cb = CVar.GetCVar((h == 0) ? "rs_body_poseframe_main"
                                           : "rs_body_poseframe_off", p);
            if (cb) bodyPose = cb.GetInt();

            // WHAT THE HAND IS CLOSED ON, which is the rung this ladder never
            // had -- and the reason a world hand would not pose for a slide, a
            // magazine or anything else a mod claimed.
            //
            // The psprite hands have had it since they were written:
            // RS_HandsAlwaysOn.PoseForSubject reads pawn.GripSubjectMain/Off and
            // maps it to a shape. That field is published by the engine from the
            // per-hand CLAIM a mod writes -- vk_openxrdevice.cpp, `if (claimed >
            // 0) subj = claimed;` -- so any mod that says "this hand is on a
            // slide" already gets the pinched-serrations pose on the psprite
            // hand and got NOTHING on the world one.
            //
            // Same mapping, same source, so the two hand systems finally agree.
            // General by construction: nothing here knows which mod made the
            // claim, only what the hand is holding.
            //
            // BELOW poseHold, because something physically in this hand -- a
            // barrel RS_Held is carrying -- knows better than a subject does.
            // ABOVE the body and the controllers, because both of those are
            // guesses by comparison.
            int subjPose = -1;
            if (Flag("rs_handworld_subject", p, true))
            {
                int subj = (h == 0) ? pmo.GripSubjectMain : pmo.GripSubjectOff;
                subjPose = PoseForSubject(subj);
            }

            int want;
            if (forced >= 0)           want = forced;
            else if (hd.poseHold >= 0) want = hd.poseHold;
            else if (subjPose >= 0)    want = subjPose;
            else if (bodyPose >= 0)    want = bodyPose;
            else                       want = PoseForEmpty(grip, trig, touch);

            int before = hd.GetPose();
            hd.SetPose(want);

            let cd = CVar.GetCVar("rs_handworld_debug", p);
            if (cd && cd.GetBool() && before != want)
                Console.Printf("[HANDPOSE] %s -> frame %d  (grip=%d trigger=%d touch=%d hold=%d)",
                    (h == 0) ? "MAIN" : "OFF ", want, grip, trig, touch, hd.poseHold);
        }
    }
}

// POSING A WORLD HAND FROM OUTSIDE THIS PACKAGE.
//
// The world hand already has four ways to be told what shape to make -- the
// debug forcepose, poseHold, RS_VRBody's published frame, and the controllers
// -- and until now only code INSIDE this pk3 could reach poseHold. RS_Held
// calls it for a barrel, RS_Stabilize calls it for a brace, and a weapon mod
// holding its own gun had nothing: it fell through to PoseForEmpty, which knows
// only OPEN, TRIGGER, POINT, GRIP_TU and FIST. A hand wrapped round a pistol
// was posed exactly like an empty one.
//
// REACHED BY STRING, NEVER BY CLASS, and that is the whole reason this is a
// Service rather than a public method. Naming RS_HandWorldHandler from another
// pk3 is a COMPILE-TIME dependency, and thingdef.cpp refuses every pk3 later in
// the load order when a named class is absent -- fatal and global, for a mod
// that merely wanted a nicer hand. The grip arbiter and ModelSwapper are both
// reached this way for the same reason; this is the third.
//
// GENERAL, NOT A FAVOUR TO ONE CALLER. It takes a hand and a FRAME NUMBER and
// says nothing about guns: holsters, hardpoints, a ladder, a door handle and
// the next weapon mod all want the same thing, and none of them should need a
// line in here. The frame vocabulary is RS_HandWorldBase's own constants, which
// callers can read off this file.
//
// OWNERSHIP, so two systems cannot un-pose each other. A release only clears a
// pose the same owner set -- the same discipline GripClaim* uses, and for the
// same reason: more than one thing writes these.
class RS_HandPoseService : Service play
{
    // Per hand: what was published and who published it. Frame -1 is "nothing
    // to say", which hands the shape back to the rungs below poseHold.
    private int  poseOwnerSet[2];
    private Name poseOwner[2];

    override int GetInt(String request, String stringArg, int intArg, double doubleArg, Object objectArg, Name nameArg)
    {
        // IDENTITY, not presence. ServiceIterator matches on a case-insensitive
        // SUBSTRING, so finding something is not proof of finding THIS -- every
        // consumer in this family checks a hello before trusting a handle.
        if (request ~== "pose.hello") return 1;

        int hand = intArg;
        if (hand != 0 && hand != 1) return 0;

        if (request ~== "pose.set")
        {
            let hd = RS_HandWorldHandler.Get(hand);
            if (!hd) return 0;              // world hands are off; nothing to pose

            int frame = int(doubleArg);

            // A RELEASE ONLY CLEARS WHAT THIS OWNER SET. Anything else is one
            // mod switching off another's pose, which is invisible from either
            // side and reads as the hand randomly going slack.
            if (frame < 0)
            {
                if (poseOwnerSet[hand] == 0 || poseOwner[hand] != nameArg) return 0;
                hd.HoldPose(-1);
                poseOwnerSet[hand] = 0;
                poseOwner[hand]    = 'None';
                return 1;
            }

            hd.HoldPose(frame);
            poseOwnerSet[hand] = 1;
            poseOwner[hand]    = nameArg;
            return 1;
        }

        // Is the pose standing on this hand mine? Asked before a release by
        // anything that keeps its own copy of what it published.
        if (request ~== "pose.mine")
            return (poseOwnerSet[hand] == 1 && poseOwner[hand] == nameArg) ? 1 : 0;

        // The frame currently published, or -1. Lets a caller see what it is
        // about to overwrite without keeping a second copy of the truth.
        if (request ~== "pose.get")
        {
            let hd = RS_HandWorldHandler.Get(hand);
            return hd ? hd.poseHold : -1;
        }

        // WEARING ANOTHER MESH -- see RS_HandWorldBase.worn. stringArg is
        // "from:to,from:to,*:else", the hand's own pose frames mapped onto the
        // worn mesh's; "" takes it off. The caller puts the mesh on itself
        // (A_ChangeModel, with its own MODELDEF); this only says how to pose it
        // and that it has no skeleton to ask.
        if (request ~== "pose.wear")
        {
            let hd = RS_HandWorldHandler.Get(hand);
            if (!hd) return 0;
            hd.remapFrom.Clear();
            hd.remapTo.Clear();
            hd.remapElse = 0;
            hd.worn = stringArg.Length() > 0;
            if (!hd.worn) return 1;
            Array<String> pairs;
            stringArg.Split(pairs, ",", TOK_SKIPEMPTY);
            for (int i = 0; i < pairs.Size(); i++)
            {
                Array<String> kv;
                pairs[i].Split(kv, ":", TOK_SKIPEMPTY);
                if (kv.Size() != 2) continue;
                if (kv[0] == "*") { hd.remapElse = kv[1].ToInt(); continue; }
                hd.remapFrom.Push(kv[0].ToInt());
                hd.remapTo.Push(kv[1].ToInt());
            }
            return 1;
        }

        // Can this hand be asked for a bone? 1 yes, 0 no (it wears a mesh
        // without a skeleton), -1 there is no hand.
        if (request ~== "pose.bones")
        {
            let hd = RS_HandWorldHandler.Get(hand);
            return hd ? (hd.worn ? 0 : 1) : -1;
        }

        return 0;
    }
}
