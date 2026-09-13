// The reach volume, drawn.
//
// The grab radius was 26 map units -- 76 cm -- and completely invisible, which
// is why two things came at once and why a miss and a mis-aim looked identical.
// You cannot tune a volume you cannot see.
//
// WHY A MODEL AND NOT BEAMS. The first version drew this with 84 beams per hand,
// rebuilt every tic through Level.SetBeam. It worked and it destroyed the
// framerate. This is one model draw per hand with no per-tic work at all: the
// idle/hot swap is a sprite FRAME change, and MODELDEF has already bound a
// different skin to each frame, so nothing is recomputed to change colour.
//
// The mesh is unit radius, so the per-axis placement scale IS the semi-axis in
// map units. What you see is exactly the volume that grabs -- and it is drawn
// from the same three cvars RS_Reach.Score tests against, so it cannot drift.

class RS_GaugeBase : Actor
{
    Default
    {
        +NOGRAVITY; +NOBLOCKMAP; +NOINTERACTION; +DONTSPLASH;
        // NO +DECOUPLEDANIMATIONS, and that is load-bearing.
        //
        // These blocks use FrameIndex, and FrameIndex and DECOUPLEDANIMATIONS are
        // mutually exclusive: a decoupled actor resolves its model through
        // BaseSpriteModelFrames, which ONLY BaseFrame populates. Set the flag on
        // a FrameIndex model and the lookup finds nothing and draws nothing --
        // silently, with no error anywhere.
        RenderStyle "Add";
        Alpha 0.55;
        Radius 1; Height 1;
    }
    // Position comes from MODELDEF FollowMainHand/FollowOffHand at DRAW rate.
    // Nothing here sets it -- a script-set position lives on the playsim tick,
    // and the playsim STOPS when a menu opens, which froze these in mid-air
    // exactly when you were in the menu trying to tune them.
    //
    // The actor is still CULLED on its real world position while being DRAWN at
    // your hand, so it has to be kept near the player or it silently vanishes.
    override void Tick()
    {
        Super.Tick();
        let p = players[consoleplayer].mo;
        if (p) SetOrigin(AnchorPos(p), false);
    }

    // Where the gauge is parked for culling. The handler's WorldTick runs
    // BEFORE thinkers, so anything it SetOrigin()s is overwritten here on
    // the same tic -- a subclass that belongs somewhere other than the feet
    // has to say so through this, not through the handler.
    virtual Vector3 AnchorPos(PlayerPawn p) { return p.Pos; }

    // ONE MODELDEF slot per gauge; hot/idle is a skin swap, exactly as
    // RS_HolsterMarker does it. The two-slot form drew both skins every
    // frame -- a FrameIndex picks a frame per slot, never which slot shows
    // -- so the orange "hot" wireframe was permanently visible and the
    // Spawn/Hot state change did nothing on screen.
    virtual String GaugeModel()        { return "rs_wiresphere.obj"; }
    virtual String GaugeSkin(bool hot) { return hot ? "rs_grab_hot.png" : "rs_grab_idle.png"; }
    void SetHot(bool hot)
    {
        A_ChangeModel(GetClassName(), 0, "models", GaugeModel(), 0, "models", GaugeSkin(hot));
    }
    States
    {
    Spawn:
        RSGB A -1;
        Stop;
    Hot:
        RSGB B -1;
        Stop;
    }
}

class RS_GrabOvalMain : RS_GaugeBase { }
class RS_GrabOvalOff  : RS_GaugeBase { }

// THE FACE VOLUME, DRAWN.
//
// Same unit-radius mesh as the reach oval and the same rule: the sphere you see
// IS the radius the gesture tests, because both read rs_use_face_reach. A tuning
// gauge that can disagree with what it gauges is worse than none.
//
// No Follow flag -- this one belongs at your HEAD, and it is placed from HmdPos
// each tic rather than riding a controller.
//
// It sits where you cannot look at it, which is exactly why it is not the answer
// to "how do I know something is in range" -- the flash and the tick are. This
// is for dialling the number and then switching off.
class RS_FaceVol : RS_GaugeBase
{
    override Vector3 AnchorPos(PlayerPawn p) { return p.HmdPos; }
    override String GaugeSkin(bool hot) { return hot ? "rs_vol_hot.png" : "rs_vol_idle.png"; }
}

// The collision volume of whatever is in reach, drawn around it.
//
// A sphere pasted over a model tells you nothing you did not already know. The
// COLLISION volume is the invisible thing, and invisible is how a swapped pair of
// half-extents left an object resting halfway through the floor with nothing on
// screen to say why.
//
// Green idle, cyan when your hand is in it -- a different colour family from the
// amber/red reach language on purpose, because it answers a different question.
class RS_VolumeBox : Actor
{
    Default
    {
        +NOGRAVITY; +NOBLOCKMAP; +NOINTERACTION; +DONTSPLASH;
        RenderStyle "Add";
        Alpha 0.45;
        Radius 1; Height 1;
    }
    States
    {
    Spawn:
        RSGB A -1;
        Stop;
    Hot:
        RSGB B -1;
        Stop;
    }
}

class RS_GrabViz : EventHandler
{
    private RS_GaugeBase viz[2];
    private RS_VolumeBox vol[2];

    // THE MASTER SCALE IS NO LONGER PINNED AT LEVEL LOAD, and removing that is
    // the point of this comment surviving where the code did not.
    //
    // It used to be forced back to 1 every WorldLoaded. The reasoning was sound
    // at the time: the master had no slider, so a stale value sitting in the ini
    // was invisible and quietly multiplied everything, and the per-axis numbers
    // were meant to be the whole size.
    //
    // Both halves of that are now false. The master has its own labelled slider
    // (OVERALL SIZE), so it is not invisible; and it has to carry real work,
    // because this volume rides the hand through the viewmodel transform where a
    // unit-radius mesh is already metres across -- the useful master value is
    // around 0.025, which the per-axis sliders cannot express at all.
    //
    // So the pin stopped protecting anything and started destroying the setting:
    // dial the size in, change map, and it is 40x bigger again. Cvars persist on
    // their own. Nothing here should be writing to one at level load.

    override void WorldTick()
    {
        let p = players[consoleplayer];
        if (!p || !p.mo) return;
        let pmo = p.mo;

        bool show    = RS_Reach.Flag("rs_grabviz", p, true);
        bool showVol = RS_Reach.Flag("rs_volviz",  p, true);

        // NO MENU CHECK HERE, deliberately, and it was tried on 2026-08-29.
        //
        // The stranded-lock failure this would have papered over (audit #6) is
        // already fixed at source: RS_Pull.WorldTick calls AbortAll the moment
        // either rs_grab or rs_dgrab reads false, which drops both locks and
        // puts any flight back the way it was found. Hiding the drawing would
        // have hidden a symptom that no longer occurs.
        //
        // It could not have worked in any case. WorldTick does not run while a
        // menu holds the playsim, so a check placed in it cannot fire at the one
        // moment it is asking about -- and Menu.GetCurrentMenu is ui scope,
        // which play cannot call at all.

        // ASKED ONCE, FOR BOTH DRAWINGS. RS_GrabHandler ticks ahead of this one
        // (the MAPINFO order), so its answer for this tic is already sitting
        // there -- and the note further down about not scanning twice was
        // written for the box while the oval a few lines above it was doing
        // exactly that, once per hand, every tic, blockmap query and all.
        let gh = RS_GrabHandler.Get();

        for (int h = 0; h < 2; h++)
        {
            // ---- the reach oval on the hand ------------------------------
            if (!show)
            {
                if (viz[h]) { viz[h].Destroy(); viz[h] = null; }
            }
            else
            {
                if (!viz[h])
                {
                    String cls = (h == 0) ? "RS_GrabOvalMain" : "RS_GrabOvalOff";
                    viz[h] = RS_GaugeBase(Actor.Spawn(cls, pmo.Pos));
                }
                if (viz[h])
                {
                    viz[h].Alpha = RS_Reach.Num("rs_grabviz_alpha", p, 0.55);
                    // The handler's near pick, not a second RS_Reach.Best. It is
                    // the same scan and it can come back with a different answer
                    // -- the oval going hot for one object while the box drawn
                    // below promises another is precisely the disagreement this
                    // gauge exists to rule out.
                    //
                    // It also goes cold for a FULL hand, where the old scan stayed
                    // hot. That is the honest reading: the oval means "a squeeze
                    // takes this", and a squeeze on a full hand does not take
                    // anything, it lets go.
                    Actor best = gh ? gh.NearTargetFor(h) : null;
                    if (RS_Reach.Flag("rs_grabviz_onlywhenhot", p, false) && !best)
                        viz[h].Alpha = 0;
                    State want = best ? viz[h].FindState("Hot") : viz[h].FindState("Spawn");
                    if (want && viz[h].CurState != want)
                    {
                        viz[h].SetState(want);
                        viz[h].SetHot(best);   // the skin swap the state alone cannot make
                    }
                }
            }

            // ---- the volume of whatever is in reach ----------------------
            // WHAT THE SQUEEZE WOULD TAKE -- asked of the handler that will
            // actually take it, rather than worked out again here. Two scans
            // are two answers, and a box that promises a different object than
            // the one that arrives is the exact failure the drawn volume is
            // supposed to make impossible.
            // `gh` is resolved once above the loop now, and the oval uses it
            // too: this note applied to the oval all along.
            Actor target = (showVol && gh) ? gh.TargetFor(h) : null;
            if (!target)
            {
                if (vol[h]) { vol[h].Destroy(); vol[h] = null; }
                continue;
            }
            if (!vol[h])
                vol[h] = RS_VolumeBox(Actor.Spawn("RS_VolumeBox", target.Pos));
            if (!vol[h]) continue;

            // Doom's cylinder, drawn as the box that bounds it: Radius across,
            // Height tall, centred on the middle of that height rather than on
            // the actor's feet -- the origin of a Doom actor is the FLOOR of its
            // volume, and drawing a centred mesh on it puts half the box
            // underground.
            vol[h].SetOrigin((target.Pos.x, target.Pos.y, target.Pos.z + target.Height * 0.5), false);
            vol[h].Angle = target.Angle;
            vol[h].Scale = (target.Radius, target.Height * 0.5);

            State w = vol[h].FindState("Hot");
            if (w && vol[h].CurState != w) vol[h].SetState(w);
        }

        DrawAimBeams(pmo, p);
        MarkConsidered(pmo, p);
        DrawFaceVolume(pmo, p);
    }

    private RS_GaugeBase faceViz;

    private void DrawFaceVolume(PlayerPawn pmo, PlayerInfo p)
    {
        if (!RS_Reach.Flag("rs_use_face_viz", p, false)
            || !RS_Reach.Flag("rs_use_at_face", p, true))
        {
            if (faceViz) { faceViz.Destroy(); faceViz = null; }
            return;
        }

        if (!faceViz)
            faceViz = RS_GaugeBase(Actor.Spawn("RS_FaceVol", pmo.Pos));
        if (!faceViz) return;

        // The mesh is unit radius, so the actor scale IS the radius in map
        // units -- the same relationship the reach oval relies on.
        double r = RS_Reach.Num("rs_use_face_reach", p, 12.0);
        faceViz.SetOrigin(pmo.HmdPos, false);
        faceViz.Scale = (r, r);
        faceViz.Alpha = RS_Reach.Num("rs_grabviz_alpha", p, 0.55) * 0.5;
    }

    // THE FLASH -- what state a thing is in, said in colour.
    //
    //   considered / lasered over    neutral <-> ORANGE
    //   in your hand                 ORANGE  <-> GREEN
    //   in flight toward you         nothing, the flash stops
    //
    // Flight stops it because the arc IS the feedback at that point: the object
    // is crossing the room at you and there is nothing left to tell you. A thing
    // still flashing while it flies reads as unfinished business.
    //
    // NOT A MODEL SWAP. The sprite-versus-model decision happens in
    // hw_sprites.cpp before any per-instance override is read -- a voxel is keyed
    // on the SPRITE NAME, and CMDL_HIDEMODEL is checked later still, in
    // CalcModelOverrides, where it just refuses to draw. Hiding a voxel gets you
    // an invisible object, not a sprite. Translation works on either.
    //
    // SAVED BEFORE IT IS CHANGED and restored to the saved value, never to
    // none. Plenty of actors carry a translation already -- a mod's recoloured
    // ammo, a Hexen player class -- and blanket-clearing would strip it off
    // anything we ever pointed at, permanently, with nothing to say why.
    private Actor        litActor[2];
    private TranslationID litWas[2];
    private bool         litHeld[2];

    private void ClearMark(int h)
    {
        if (litActor[h])
            litActor[h].Translation = litWas[h];
        litActor[h] = null;
    }

    private void MarkConsidered(PlayerPawn pmo, PlayerInfo p)
    {
        bool on = RS_Reach.Flag("rs_grab_lightup", p, true);
        let gh   = RS_GrabHandler.Get();
        let held = RS_Held.Get();
        let pull = RS_Pull.Get();

        // Half a period. The whole point is SLOW -- fast enough to read as
        // alive, slow enough that a room full of pickups is not a strobe.
        double period = RS_Reach.Num("rs_grab_flash", p, 24.0);
        if (period < 2) period = 2;
        bool phase = (int(level.time / (period * 0.5)) & 1) != 0;

        for (int h = 0; h < 2; h++)
        {
            // FOUR STATES, and the colour says which one you are in.
            //
            //   considered      neutral <-> orange   the cone is on it
            //   LOCKED          orange  <-> green    the grip took hold of it
            //   in flight       nothing              the flash stops
            //   in your hand    green, solid         settled, it is yours
            //
            // Flight clearing the flash entirely is deliberate and it is what
            // was asked for: the arc IS the feedback by then, and a thing still
            // pulsing while it crosses the room reads as unfinished business.
            Actor want = null;
            bool inHand = false;
            bool locked = false;

            if (on)
            {
                if (pull && pull.Flying(h))
                {
                    want = null;
                }
                else if (held && held.HeldBy(h))
                {
                    want = held.HeldBy(h);
                    inHand = true;
                }
                else if (pull && pull.Locked(h))
                {
                    want = pull.Locked(h);
                    locked = true;
                }
                else if (gh)
                {
                    want = gh.TargetFor(h);
                }
            }

            if (litActor[h] != want)
            {
                ClearMark(h);

                // ONE HAND OWNS A GIVEN OBJECT'S COLOUR, and this guard is the
                // whole bug behind "it stayed selected after the map changed".
                //
                // Both hands can be considering the same thing -- pointing at
                // one barrel with both is the normal way to two-hand it. Hand 0
                // marks it and writes orange. Hand 1 then captures
                // want.Translation as the "original" to restore later, and what
                // it captures is the ORANGE hand 0 just wrote. From then on
                // hand 1 restores orange, and the object is permanently lit with
                // nothing selecting it, for the rest of its life.
                //
                // Exactly the flag-ownership trap RS_Held guards against with
                // hOwnsFlags, in a second place. Save what you found, and only
                // if you are the one who found it.
                if (want && litActor[1 - h] != want)
                {
                    litWas[h] = want.Translation;
                    litActor[h] = want;
                }
            }
            litHeld[h] = inHand;

            if (!litActor[h]) continue;

            // Held pulses ORANGE to GREEN; considered pulses NEUTRAL to ORANGE.
            // Orange is the shared end of both, so taking hold of something
            // continues the colour it was already showing instead of starting a
            // new one -- the flash changes what it is doing, not what it is.
            // IN FACE RANGE the held cycle changes its far end rather than its
            // near one: green stays, and the thing it alternates with becomes
            // cyan. Green means "mine" everywhere, so every state of a thing
            // you own is a variation on the same colour and only the second
            // colour says what is newly true.
            // Orange is the shared end of the first two cycles, so taking hold
            // of something at range continues the colour it was already showing
            // rather than starting a new one -- the flash changes what it is
            // doing, not what it is.
            let rt = RS_Route.Get();
            if (inHand && rt && rt.AtFace(h, pmo, p))
            {
                // Ready to use -- the one place green stops being solid.
                litActor[h].A_SetTranslation(phase ? 'RS_GrabCyan' : 'RS_GrabGreen');
            }
            else if (inHand)
            {
                // Settled. It is yours and nothing is pending, so it holds one
                // colour instead of pulsing: a thing already in your hand does
                // not need to keep asking for attention.
                litActor[h].A_SetTranslation('RS_GrabGreen');
            }
            else if (locked)
            {
                // GRABBED AT RANGE. Orange to green -- taken hold of, not yet
                // pulled.
                litActor[h].A_SetTranslation(phase ? 'RS_GrabGreen' : 'RS_GrabOrange');
            }
            else if (phase)
            {
                litActor[h].A_SetTranslation('RS_GrabOrange');
            }
            else
            {
                litActor[h].Translation = litWas[h];
            }
        }
    }

    // THE AIMING RAY.
    //
    // It DRAWS EVEN WHEN IT HAS FOUND NOTHING, and that is the point. The first
    // version only appeared once something was locked, which is exactly
    // backwards: a ray is hardest to aim at the precise moment it is not hitting
    // anything, and that is when you need to see where it points so you can
    // sweep onto something.
    //
    // One beam per hand, not a mesh. The first reach gauge in this package drew
    // its volume with 84 beams per hand rebuilt every tic and destroyed the
    // framerate, so the count matters more than the shape.
    //
    // SetBeamCount is global to the level and cannot be read back, so this
    // claims slots 0 and 1 and anything else wanting beams must start at 2.
    // Said out loud because a silent clash reads as beams flickering for no
    // reason at all.
    private void DrawAimBeams(PlayerPawn pmo, PlayerInfo p)
    {
        if (!RS_Reach.Flag("rs_dgrab_beam", p, true)
            || !RS_Reach.Flag("rs_dgrab", p, true)
            || !RS_Reach.Flag("rs_grab", p, true)     // the master switch: RS_Pull aborts on it, the ray must too
            || pmo.Health <= 0)
        {
            // BLANK THE TWO SLOTS WE OWN -- never lower the count. Fixed
            // 2026-08-26: this used to call Level.SetBeamCount(0, 0, 0),
            // which is LEVEL-WIDE, so switching rs_dgrab_beam or rs_dgrab off
            // destroyed every beam in the level rather than just ours. The
            // comment 8 lines above already says this claims slots 0 and 1
            // and "anything else wanting beams must start at 2" -- lowering
            // the count to zero breaks exactly that contract.
            //
            // Zero length AND zero intensity, the same pair the per-hand
            // branch below uses at :438 -- either alone still leaves a dot
            // sitting at the origin.
            if (beamsOn)
            {
                Level.SetBeam(0, (0,0,0), (0,0,0), 0, 0, 0x000000, 0);
                Level.SetBeam(1, (0,0,0), (0,0,0), 0, 0, 0x000000, 0);
                beamsOn = false;
            }
            return;
        }

        let gh   = RS_GrabHandler.Get();
        let held = RS_Held.Get();
        let pull = RS_Pull.Get();
        if (!gh) return;

        if (!beamsOn)
        {
            beamsOn = true;
        }

        // Pushed EVERY TIC rather than once, so the sliders move the beam while
        // you are looking at it. Five field writes and a count -- cheaper than
        // the lookup that decides whether to bother.
        //
        // Both of these are LEVEL-WIDE. There is no way to read either back, so
        // this owns the beam look for everything, and anything else wanting
        // beams inherits it. Nothing else in the load uses them; said out loud
        // because a silent clash reads as the laser randomly changing character.
        Level.SetBeamCount(2,
            RS_Reach.Num("rs_beam_glow", p, 0.35),
            RS_Reach.Num("rs_beam_fog",  p, 0.2));
        Level.SetBeamLook(
            RS_Reach.Num("rs_beam_airglow", p, 1.0),
            RS_Reach.Num("rs_beam_scroll",  p, 6.0),
            RS_Reach.Num("rs_beam_depth",   p, 0.25),
            RS_Reach.Num("rs_beam_taper",   p, 0.35),
            RS_Reach.Num("rs_beam_flare",   p, 1.5));

        // EVERY STATE IS ITS OWN LINE. Idle, candidate and locked each carry a
        // colour, a thickness and an opacity, because they are three different
        // messages and telling them apart at a glance is the whole reason the
        // ray is drawn at all.
        bool reel   = RS_Reach.Flag("rs_dgrab_beam_reel", p, true);
        double soft = RS_Reach.Num("rs_beam_soft", p, 0.5);

        for (int h = 0; h < 2; h++)
        {
            // PALM DOWN, OR NO LASER.
            //
            // A hand held the way you hold a gun is not reaching for anything
            // across the room -- it is aiming a weapon, or just hanging at your
            // side. Turning the wrist over so the palm faces the floor, the way
            // you take hold of a handlebar, is a deliberate act and nothing else
            // asks for that shape, so it is safe to hang the reach on.
            //
            // Compared as a distance from the target using the ABSOLUTE roll:
            // a right wrist turning palm-down rolls one way and a left wrist the
            // other, so one number covers both hands with no per-hand sign.
            // A gun grip sits near zero, so the two are ~90 degrees apart and
            // cannot be confused.
            // The lock is resolved BEFORE the palm gate: a lock is only
            // palm-gated on acquisition (rs_grab.zs) and RS_Pull keeps it
            // through any wrist roll, so its reeling beam must keep drawing
            // -- otherwise the object pulses as locked and a flick still
            // hauls it in while the line that explains that has vanished.
            Actor lk = pull ? pull.Locked(h) : null;
            // THE IDLE LINE KEEPS DRAWING WHILE YOUR HANDS ARE TOGETHER, and
            // that is deliberate rather than an oversight.
            //
            // It was blanked here for one build, on the reasoning that a line
            // across the room from a two-handed grip is just clutter. But the
            // idle beam is a TUNING AID -- it shows where the hand points when
            // it is pointing at nothing, which is exactly when aim is hardest to
            // judge -- and hiding it is the job of rs_beam_idle_show, one switch
            // that turns it off everywhere.
            //
            // What actually had to stop is the ability to LOCK and PULL, and
            // that is stood down in rs_grab.zs where the cone acquires. The line
            // is now honest about it: it draws, and it takes nothing.
            if (!lk && RS_Reach.Flag("rs_dgrab_palm", p, true))
            {
                double rl = abs(RS_Basis.NormDeg((h == 0) ? pmo.MainHandRoll : pmo.OffhandRoll));
                double tgt = RS_Reach.Num("rs_dgrab_palm_roll", p, 90.0);
                double tol = RS_Reach.Num("rs_dgrab_palm_tol",  p, 30.0);
                if (abs(rl - tgt) > tol)
                {
                    Level.SetBeam(h, (0,0,0), (0,0,0), 0, 0, 0x000000, 0);
                    continue;
                }
            }

            // A HAND FULL OF SOMETHING IS NOT AIMING. Nothing else silences it.
            if (held && held.HandIsFull(h))
            {
                // Zero length AND zero intensity -- either alone still leaves a
                // dot sitting at the origin.
                Level.SetBeam(h, (0,0,0), (0,0,0), 0, 0, 0x000000, 0);
                continue;
            }

            Vector3 a = RS_Reach.Centre(pmo, p, h);
            Actor t  = lk ? lk : gh.FarTargetFor(h);

            if (t)
            {
                color  col = lk ? RS_Reach.Col("rs_beam_lock_color", p, 0x50FF70)
                                : RS_Reach.Col("rs_beam_hot_color",  p, 0xFFC060);
                double th  = lk ? RS_Reach.Num("rs_beam_lock_thick", p, 0.9)
                                : RS_Reach.Num("rs_beam_hot_thick",  p, 0.7);
                double al  = lk ? RS_Reach.Num("rs_beam_lock_alpha", p, 1.0)
                                : RS_Reach.Num("rs_beam_hot_alpha",  p, 1.0);

                // Ends ON the thing, and takes its colour from the state: amber
                // while you are only pointing at it, green once your fist is
                // closed. The same two colours the object itself is flashing, so
                // the line and the thing can never disagree about what is
                // happening.
                Vector3 b = (t.Pos.x, t.Pos.y, t.Pos.z + t.Height * 0.5);

                // REELING IT IN. Drawn from the OBJECT to your hand once your
                // fist is closed on it, and from your hand outward otherwise.
                //
                // Every directional part of the beam look runs start to end:
                // the scroll travels that way, the taper is thin at the start,
                // the flare is bright at the end. Swapping the endpoints turns
                // all three round at once -- the energy runs toward you, the
                // line narrows at the far end, and the bright spot sits in your
                // palm. Pointing at a thing and hauling it in stop looking like
                // the same act, which is the whole job of the lock state.
                if (lk && reel)
                    Level.SetBeam(h, b, a, th, soft, col, al);
                else
                    Level.SetBeam(h, a, b, th, soft, col, al);
            }
            else
            {
                // FOUND NOTHING. Drawing here is a choice, not an oversight: a
                // ray is hardest to aim when it is not hitting anything, which
                // is exactly when you want to see where it points. Off is still
                // available -- a permanent line in your vision may be worse than
                // the aiming problem it solves, and only you can say.
                if (!RS_Reach.Flag("rs_beam_idle_show", p, true))
                {
                    Level.SetBeam(h, (0,0,0), (0,0,0), 0, 0, 0x000000, 0);
                    continue;
                }

                // Its own length, so a short stub is possible without shortening
                // the reach itself. 0 means "as far as I could actually pull
                // from", which is the honest default: the line ends where the
                // ability does.
                double len = RS_Reach.Num("rs_beam_idle_len", p, 0.0);
                if (len <= 0) len = RS_Reach.Num("rs_dgrab_reach", p, 512.0);

                Vector3 b = a + RS_Cone.Dir(pmo, h) * len;
                Level.SetBeam(h, a, b,
                    RS_Reach.Num("rs_beam_idle_thick", p, 0.4), soft,
                    RS_Reach.Col("rs_beam_idle_color", p, 0x506070),
                    RS_Reach.Num("rs_beam_idle_alpha", p, 0.35));
            }
        }
    }

    private bool beamsOn;

    override void WorldUnloaded(WorldEvent e)
    {
        ClearMark(0);
        ClearMark(1);
    }

    // The handler is rebuilt per level so these are already null -- but a
    // savegame restores fields, and a restored pointer to an actor from the
    // level it was saved in is exactly the sort of thing that survives just
    // long enough to write a colour onto the wrong object.
    override void WorldLoaded(WorldEvent e)
    {
        // ClearMark, not a bare null: on a savegame load the pointers are
        // live and the actor was serialised in whatever colour it had at
        // save time. Nulling leaves it orange or green for the rest of the
        // level; restoring is a no-op when the pointer is dead anyway.
        ClearMark(0);
        ClearMark(1);
        if (faceViz) { faceViz.Destroy(); faceViz = null; }
    }
}
