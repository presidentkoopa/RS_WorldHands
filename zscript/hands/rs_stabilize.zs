// TWO-HAND STABILIZE: THE OFF HAND BRACES THE WEAPON IN THE MAIN HAND.
//
// The engine used to decide this by itself, from nothing but the distance
// between the two controllers, and it was retired for the reason its own
// comment gives: reloading is the gesture that brings the hands together, so
// the guess fired hardest during exactly the moment that least wanted it. What
// the engine kept is the half worth keeping. A hand that CLAIMS the weapon's
// forend, foregrip or support -- GripClaimOff, through the grip arbiter --
// publishes TwoHandedHold on the pawn, and with the engine's own Two Handed
// Weapons option on, the weapon aims along the line between the hands.
//
// This file is the thing that makes the claim, and it makes it from geometry
// the engine never had: THE REACH OVALS. Every weapon model carries a support
// point -- an ellipsoid drawn on the gun through the same PlacementCVars
// machinery the hand ovals use, so it can be seen, moved with sliders while
// the menu is open, and tested from script with the same conversion the hand
// ovals get. When the off hand's reach oval meets it and the grip is squeezed,
// the hand is on the gun. A hand carrying a magazine past it is not: the
// magazine's own claim already owns that hand, first come first served.
//
// PER WEAPON MODEL, NOT PER WEAPON CLASS. The point is on the mesh, and the
// mesh is ModelSwapper's business -- one donor model serves many weapon
// classes, and one weapon class can wear several donors. So the tuning table
// keys on the donor when there is one and on the weapon class when there is
// not, and a weapon nobody has tuned starts from its ARCHETYPE's defaults
// (shotgun, rifle, pistol...) as ModelSwapper classifies it. Every gun in
// every mod gets a plausible support point without authoring; dialling one in
// is a matter of sliders, and the numbers persist on their own.
//
// GRIP TO STABILIZE, AS IT ALWAYS WAS: squeeze inside the support oval and
// hold, and the brace lasts as long as the squeeze does. Pulling the hand
// away, changing weapon or filling the off hand also lets go. Tap-to-latch
// -- one squeeze attaches, the grip is free again -- is a menu switch for
// anyone who would rather not hold a button through a firefight.

// The support point, drawn. Same unit-radius mesh as the reach ovals, riding
// the main hand through PlacementCVars rs_stab -- see MODELDEF. Green idle,
// cyan hot: the volume language rather than the amber/red reach language,
// because it answers a different question ("where does the second hand go",
// not "what could this hand take").
class RS_StabOval : RS_GaugeBase
{
    override String GaugeSkin(bool hot) { return hot ? "rs_vol_hot.png" : "rs_vol_idle.png"; }
}

// One tuned record: how the off hand holds ONE weapon model.
//
// subject is a GRIPSUBJ_* value, or 0 for "whatever the archetype says", or
// -1 for "this one is never braced". The eight doubles are the placement
// cvars verbatim, in the renderer's own units, exactly as the sliders show
// them -- they are copied into the rs_stab_* cvars when the weapon comes up
// and copied back out when a slider moves.
class RS_StabEntry
{
    String key;
    int    subject;
    double ox, oy, oz;
    double s, sx, sy, sz;
}

class RS_Stabilize : EventHandler
{
    // ---- the table ----------------------------------------------------
    private Array<RS_StabEntry> table;

    // The weapon model currently in the main hand: its key, its archetype,
    // and whether its numbers came from the table or from the archetype.
    private String curKey;
    private String curArche;
    private bool   curFromTable;

    // What the rs_stab_* cvars last held, as far as this handler knows. The
    // menu edits those cvars while the playsim is stopped, so the only way to
    // notice a slider moved is to compare on the next tic that runs.
    private bool   lastValid;
    private int    lastSubj;
    private double lastOx, lastOy, lastOz, lastS, lastSx, lastSy, lastSz;

    // ---- the gesture ----------------------------------------------------
    private bool wasGripOff;
    private bool mLatched;
    private int  latchedSubject;

    // True for the one tic in which an off-hand press latched or released a
    // brace. RS_GrabHandler reads it to keep that press from also being a
    // weapon swap -- see the note at its swap branch.
    private bool mTookPress;

    // For the gauge and the readout.
    private bool   insideNow;
    private bool   mPoised;
    private bool   wasInside;
    private bool   wasGripSeen;
    private bool   degenerate;
    private double scoreA, scoreB;

    private RS_GaugeBase viz;

    static RS_Stabilize Get() { return RS_Stabilize(EventHandler.Find("RS_Stabilize")); }

    bool TookPress(int hand) const { return hand == 1 && mTookPress; }
    bool Latched() const           { return mLatched; }

    // IS THIS HAND THE GUN'S RIGHT NOW -- braced, or in the support oval with
    // a squeeze about to brace it. RS_GrabHandler asks before it lets the hand
    // reach, lock, pull or swap: a hand on the gun does none of those.
    bool HoldsHand(int hand) const { return hand == 1 && (mLatched || mTookPress || mPoised); }

    // ---- archetypes -------------------------------------------------------
    //
    // WHERE THE SECOND HAND GOES ON A GUN NOBODY HAS TUNED, by archetype, in
    // ModelSwapper's vocabulary. The numbers are placement-cvar units dialled
    // for rs_grab_scale_space = 1 with the master at the same 0.025 the hand
    // ovals ship with: one scale unit is then 0.85 map units, 2.5cm, and an
    // offset is measured in that axis's own semi-axis. Long guns get an oval
    // 6cm across and 12cm along the barrel, sitting a hand's reach forward and
    // an inch under the line; a pistol gets a 7cm ball wrapped just ahead of
    // and below the firing hand. All of it is a starting point for a slider.
    //
    // A subject of -1 is "never": nothing to brace on a fist, a chainsaw or a
    // grenade about to be thrown. Anything nobody has named gets the pistol
    // wrap, because that is only a pose and cannot misfire.
    static void ArchetypeDefaults(String a, out int subj,
                                  out double ox, out double oy, out double oz,
                                  out double s, out double sx, out double sy, out double sz)
    {
        s = 0.025; sx = 2.5; sy = 5.0; sz = 2.5;
        ox = 0.0; oy = 0.0; oz = -0.4;
        subj = GRIPSUBJ_Forend;

        if (a == "shotgun" || a == "supershotgun")            { oy = 2.2; return; }
        if (a == "rifle" || a == "sniper" || a == "railgun")   { oy = 2.6; return; }
        if (a == "machinegun")                                 { oy = 2.4; return; }
        if (a == "rocket" || a == "launcher")                  { oy = 2.0; return; }
        if (a == "plasma" || a == "flamethrower"
         || a == "bfg" || a == "unmaker")                      { oy = 2.2; return; }
        if (a == "chaingun") { subj = GRIPSUBJ_Foregrip; oy = 1.8; oz = -0.6; return; }
        if (a == "smg")      { subj = GRIPSUBJ_Foregrip; oy = 1.2; oz = -0.6; return; }
        if (a == "grenade" || a == "melee" || a == "kick" || a == "saw" || a == "axe")
        {
            subj = -1; oz = 0.0; return;
        }

        // pistol, revolver, and anything unnamed
        subj = GRIPSUBJ_Support;
        sx = 3.0; sy = 3.0; sz = 3.0;
        oy = 0.3; oz = -0.3;
    }


    static String SubjectName(int subj)
    {
        if (subj == GRIPSUBJ_Forend)   return "FOREND";
        if (subj == GRIPSUBJ_Foregrip) return "FOREGRIP";
        if (subj == GRIPSUBJ_Support)  return "SUPPORT";
        if (subj < 0)                  return "never";
        if (subj == 0)                 return "archetype default";
        return String.Format("subject %d", subj);
    }

    // The slot fallback when ModelSwapper is not loaded. A copy of the last
    // rule in its classifier and nothing more -- the same "three small copies
    // is the price of no compile-time link" the arbiter probes pay.
    static String SlotArchetype(Weapon w)
    {
        if (!w) return "";
        if (w.bMeleeWeapon && w.AmmoType1 == null && w.AmmoType2 == null) return "melee";
        int slot = w.SlotNumber;
        if (slot == 1) return "melee";
        if (slot == 2) return "pistol";
        if (slot == 3) return "shotgun";
        if (slot == 4) return "chaingun";
        if (slot == 5) return "rocket";
        if (slot == 6) return "plasma";
        if (slot == 7) return "bfg";
        if (slot == 8) return "bfg";
        if (slot == 9) return "flamethrower";
        return "pistol";
    }

    // ---- who is in the main hand --------------------------------------
    //
    // ModelSwapper answers by string through a Service, the same way the grip
    // arbiter is reached: nothing here names it, and it can be absent.
    private void Resolve(PlayerInfo p, out String key, out String arche)
    {
        key = ""; arche = "";
        Weapon w = p.ReadyWeapon;
        if (!w) return;
        String cls = w.GetClassName();

        let it = ServiceIterator.Find("RS_WeaponArchetypeService");
        Service svc = it.Next();
        if (svc && svc.GetInt("hello") == 1)
        {
            String donor = svc.GetString("weapon.donor", "", 0);
            key   = (donor.Length() > 0) ? donor : cls;
            arche = svc.GetString("weapon.archetype", cls);
            if (arche.Length() == 0) arche = SlotArchetype(w);
            return;
        }
        key   = cls;
        arche = SlotArchetype(w);
    }

    // ---- the table ------------------------------------------------------
    //
    // Packed into one archived string cvar, the way ModelSwapper keeps its
    // picks: ZScript cannot write files, and the JSON profile natives take
    // doubles only, which leaves no way to enumerate keys that are class
    // names. Written only when a slider moves. Not a per-tick cost.
    //
    //   key:subject:ox:oy:oz:s:sx:sy:sz;key:...
    private void LoadTable()
    {
        table.Clear();
        let c = CVar.FindCVar("rs_stab_table");
        if (!c) return;
        String blob = c.GetString();
        if (blob.Length() == 0) return;

        Array<String> recs;
        blob.Split(recs, ";");
        for (int i = 0; i < recs.Size(); i++)
        {
            if (recs[i].Length() == 0) continue;
            Array<String> f;
            recs[i].Split(f, ":");
            if (f.Size() < 9) continue;
            let e = RS_StabEntry(new("RS_StabEntry"));
            e.key     = f[0];
            e.subject = f[1].ToInt();
            e.ox = f[2].ToDouble();  e.oy = f[3].ToDouble();  e.oz = f[4].ToDouble();
            e.s  = f[5].ToDouble();  e.sx = f[6].ToDouble();  e.sy = f[7].ToDouble();
            e.sz = f[8].ToDouble();
            table.Push(e);
        }
    }

    private void SaveTable()
    {
        let c = CVar.FindCVar("rs_stab_table");
        if (!c) return;
        String blob = "";
        for (int i = 0; i < table.Size(); i++)
        {
            let e = table[i];
            blob = blob .. String.Format("%s:%d:%.3f:%.3f:%.3f:%.4f:%.3f:%.3f:%.3f;",
                e.key, e.subject, e.ox, e.oy, e.oz, e.s, e.sx, e.sy, e.sz);
        }
        c.SetString(blob);
    }

    private int FindEntry(String key) const
    {
        for (int i = 0; i < table.Size(); i++)
            if (table[i].key == key) return i;
        return -1;
    }

    // ---- the cvars the sliders drive ------------------------------------
    private void SetF(PlayerInfo p, String n, double v)
    {
        let c = CVar.GetCVar(n, p);
        if (c) c.SetFloat(v);
    }
    private void SetI(PlayerInfo p, String n, int v)
    {
        let c = CVar.GetCVar(n, p);
        if (c) c.SetInt(v);
    }
    private static bool Same(double a, double b) { return abs(a - b) < 0.0001; }

    private void PushToCvars(PlayerInfo p, int subj,
                             double ox, double oy, double oz,
                             double s, double sx, double sy, double sz)
    {
        SetI(p, "rs_stab_subject", subj);
        SetF(p, "rs_stab_ofs_x",   ox);
        SetF(p, "rs_stab_ofs_y",   oy);
        SetF(p, "rs_stab_ofs_z",   oz);
        SetF(p, "rs_stab_scale",   s);
        SetF(p, "rs_stab_scale_x", sx);
        SetF(p, "rs_stab_scale_y", sy);
        SetF(p, "rs_stab_scale_z", sz);
        lastSubj = subj;
        lastOx = ox; lastOy = oy; lastOz = oz;
        lastS = s; lastSx = sx; lastSy = sy; lastSz = sz;
        lastValid = true;
    }

    // A NEW WEAPON MODEL IN THE MAIN HAND: its numbers go into the sliders.
    private void Adopt(PlayerInfo p, String key, String arche, bool dbg)
    {
        if (mLatched) Unlatch(p.mo, dbg, "the weapon changed");
        curKey   = key;
        curArche = arche;
        curFromTable = false;
        if (key.Length() == 0) { lastValid = false; return; }

        int subj; double ox, oy, oz, s, sx, sy, sz;
        int i = FindEntry(key);
        if (i >= 0)
        {
            let e = table[i];
            subj = e.subject;
            ox = e.ox; oy = e.oy; oz = e.oz;
            s = e.s; sx = e.sx; sy = e.sy; sz = e.sz;
            curFromTable = true;
        }
        else
        {
            ArchetypeDefaults(arche, subj, ox, oy, oz, s, sx, sy, sz);
            // The table stores 0 for "archetype default" so a weapon that
            // gets re-classified later follows the new answer; the resolved
            // subject is only ever computed at use, in EffectiveSubject.
            subj = 0;

            // A weapon may say how far its forend is from its grip, in real
            // inches, through the engine's own Weapon.StabilizeDistance. That
            // is the one number the engine already lets a weapon author, and
            // it is honoured here as the forward offset when nothing has been
            // tuned by hand. Converted into the cvar's own units, whichever
            // space those are in this session.
            Weapon w = p.ReadyWeapon;
            if (w && w.StabilizeDistance > 0.0)
            {
                double k = RS_Reach.Num("vr_vunits_per_meter", p, 34.0);
                if (k < 0.001) k = 34.0;
                double units = w.StabilizeDistance * 0.0254 * k;
                if (RS_Reach.Opt("rs_grab_scale_space", p, 0) == 1)
                    oy = units / max(0.0001, sy * s * k);
                else
                    oy = units;
            }
        }
        PushToCvars(p, subj, ox, oy, oz, s, sx, sy, sz);

        // THE `if (dbg)` HERE WAS DELETED AND ITS CLOSING BRACE WAS NOT.
        //
        // That left a stray `}` closing the CLASS forty lines early, so the
        // next method declaration parsed at file scope and the whole package
        // failed to load with "Unexpected 'private'" pointing at a line that is
        // perfectly correct -- the usual signature of a brace fault, which is
        // reported where the parser gave up rather than where the brace is.
        //
        // Restored rather than papered over by deleting the brace: `dbg` is a
        // parameter of this method and had no other use left, and the sibling
        // SyncFromCvars gates its own [RSSTAB] line exactly this way. An
        // unconditional print here would put a console line on every weapon
        // switch for everyone.
        //
        // Carried in from RS_VR_Unified on 2026-09-08 -- the file is byte
        // identical to that one, so THAT COPY IS ALSO BROKEN and will not load
        // until the same fix is applied there.
        if (dbg)
        {
            Console.Printf("[RSSTAB] main hand: %s (%s) -- %s, off hand holds it as %s", key, arche,
                curFromTable ? "tuned numbers" : "archetype defaults", SubjectName(EffectiveSubject(p)));
        }
    }

    // A SLIDER MOVED: the numbers go into the table under this weapon model.
    private void SyncFromCvars(PlayerInfo p, bool dbg)
    {
        if (!lastValid || curKey.Length() == 0) return;

        int    subj = RS_Reach.Opt("rs_stab_subject", p, 0);
        double ox = RS_Reach.Num("rs_stab_ofs_x",   p, 0);
        double oy = RS_Reach.Num("rs_stab_ofs_y",   p, 0);
        double oz = RS_Reach.Num("rs_stab_ofs_z",   p, 0);
        double s  = RS_Reach.Num("rs_stab_scale",   p, 0.025);
        double sx = RS_Reach.Num("rs_stab_scale_x", p, 2.5);
        double sy = RS_Reach.Num("rs_stab_scale_y", p, 5.0);
        double sz = RS_Reach.Num("rs_stab_scale_z", p, 2.5);

        if (subj == lastSubj && Same(ox, lastOx) && Same(oy, lastOy) && Same(oz, lastOz)
            && Same(s, lastS) && Same(sx, lastSx) && Same(sy, lastSy) && Same(sz, lastSz))
            return;

        int i = FindEntry(curKey);
        if (i < 0)
        {
            let fresh = RS_StabEntry(new("RS_StabEntry"));
            fresh.key = curKey;
            table.Push(fresh);
            i = table.Size() - 1;
        }
        let e = table[i];
        e.subject = subj;
        e.ox = ox; e.oy = oy; e.oz = oz;
        e.s = s; e.sx = sx; e.sy = sy; e.sz = sz;
        curFromTable = true;
        SaveTable();

        lastSubj = subj;
        lastOx = ox; lastOy = oy; lastOz = oz;
        lastS = s; lastSx = sx; lastSy = sy; lastSz = sz;

        if (dbg) Console.Printf("[RSSTAB] saved %s: %s  ofs %.2f/%.2f/%.2f  size %.3f x %.1f/%.1f/%.1f",
            curKey, SubjectName(subj), ox, oy, oz, s, sx, sy, sz);
    }

    // What the off hand would claim on this weapon: the slider's answer, or
    // the archetype's when the slider says "default", or nothing when the
    // weapon itself says it does not stabilize.
    private int EffectiveSubject(PlayerInfo p)
    {
        int v = RS_Reach.Opt("rs_stab_subject", p, 0);
        if (v != 0) return v;

        Weapon w = p.ReadyWeapon;
        if (w && w.StabilizeDistance < 0.0) return -1;

        int subj; double ox, oy, oz, s, sx, sy, sz;
        ArchetypeDefaults(curArche, subj, ox, oy, oz, s, sx, sy, sz);
        return subj;
    }

    // ---- geometry -------------------------------------------------------
    //
    // THE OVAL YOU SEE IS THE OVAL THAT DECIDES, LITERALLY. The engine can
    // hand script the exact object-to-world matrix it will draw an actor
    // with -- AActor.ModelPointToWorld replays ObjectToWorldMatrix, controller
    // transform, PlacementCVars, per-axis scale, pixel stretch and all (see
    // models.cpp, ModelWorldTransform). So the test does not reconstruct the
    // oval from the sliders in some space that may or may not be the
    // renderer's; it asks the gauge actor where its centre and its three
    // axis tips are drawn THIS frame, and tests the palm against that
    // ellipsoid. No unit question, no sign question, no space switch. If the
    // palm is inside the green oval on screen, it is inside here.
    //
    // The gauge therefore exists whenever the weapon can be braced, whether
    // or not the player wants to see it -- hidden is alpha zero, not absent.

    // The drawn ellipsoid this tic: centre and the three semi-axis VECTORS in
    // world space. FIELDS, not out-parameters: the ZScript JIT has no case for
    // a vector out-param and kills the whole class at load with "Unknown REGT
    // value passed to EmitPARAM" -- the exact failure RS_Basis's header warns
    // about, and this file hit it once.
    private Vector3 dC, dA0, dA1, dA2;

    // False when there is no gauge to ask, or it collapsed.
    private bool DrawnOval()
    {
        dC = (0, 0, 0); dA0 = (0, 0, 0); dA1 = (0, 0, 0); dA2 = (0, 0, 0);
        if (!viz) return false;
        Vector3 c, f, u, e0, e1, e2;
        [c,  f, u] = viz.ModelPointToWorld(0, 0, 0);
        [e0, f, u] = viz.ModelPointToWorld(1, 0, 0);
        [e1, f, u] = viz.ModelPointToWorld(0, 1, 0);
        [e2, f, u] = viz.ModelPointToWorld(0, 0, 1);
        dC = c;
        dA0 = e0 - c; dA1 = e1 - c; dA2 = e2 - c;
        return dA0.Length() > 0.05 && dA1.Length() > 0.05 && dA2.Length() > 0.05;
    }

    // Squared normalised distance of a world point from the drawn ellipsoid:
    // <= 1 is inside the surface you can see.
    private double DrawnScore(Vector3 world)
    {
        Vector3 d = world - dC;
        double l0 = dA0.Length(), l1 = dA1.Length(), l2 = dA2.Length();
        double f0 = (d dot dA0) / (l0 * l0);
        double f1 = (d dot dA1) / (l1 * l1);
        double f2 = (d dot dA2) / (l2 * l2);
        return f0*f0 + f1*f1 + f2*f2;
    }

    // WHERE THE OFF PALM IS, by the same rule: the centre of its own drawn
    // reach oval when that gauge is up, because that is the thing the player
    // is lining up with the green one. Falls back to the reach code's tested
    // centre when the hand ovals are switched off.
    private Vector3 OffPalm(PlayerPawn pmo, PlayerInfo p)
    {
        ThinkerIterator it = ThinkerIterator.Create("RS_GrabOvalOff");
        Actor g = Actor(it.Next());
        if (g)
        {
            Vector3 c, f, u;
            [c, f, u] = g.ModelPointToWorld(0, 0, 0);
            if ((c - pmo.Pos).Length() <= 200) return c;
        }
        return RS_Reach.Centre(pmo, p, 1);
    }

    // IS THE OFF HAND IN THE SUPPORT OVAL? `depth` is in oval radii: 1.0 is
    // the drawn surface, above it counts a hand that far outside as in.
    //
    // With no drawable oval to ask (gauge missing, or collapsed to nothing)
    // the test falls back to a plain distance from the main hand and says so,
    // rather than becoming unreachable.
    private bool Meets(PlayerPawn pmo, PlayerInfo p, double depth)
    {
        Vector3 palm = OffPalm(pmo, p);
        degenerate = !DrawnOval();
        if (degenerate)
        {
            double dist = (palm - RS_Reach.Palm(pmo, p, 0)).Length();
            scoreA = dist; scoreB = dist;
            return dist <= RS_Reach.Num("rs_stab_min", p, 6.0);
        }
        if (depth <= 0.0) depth = 1.0;
        scoreA = DrawnScore(palm);
        scoreB = (palm - dC).Length();
        return scoreA <= depth * depth;
    }

    // ---- the off hand's availability ------------------------------------
    //
    // A hand that is holding something, carrying a magazine, inside a holster
    // or the pouch, or wearing its own gun is not free to brace. Most of that
    // is the arbiter's ledger; the rest is state the engine or RS_Held already
    // publish.
    private Service Arbiter()
    {
        let it = ServiceIterator.Find("RS_GripArbiterService");
        Service s = it.Next();
        if (s && s.GetInt("grip.hello") == 1) return s;
        return null;
    }

    private bool OffHandBusy(PlayerInfo p, PlayerPawn pmo)
    {
        // ONLY THE TWO THINGS THAT ACTUALLY MEAN THE HAND IS ELSEWHERE. A
        // hand holding a world object, and a hand mid-reload -- the case the
        // old proximity stabilize was removed for. Nothing else: not a holster
        // nearby, not whatever weapon class the off hand happens to wear, not
        // a stale lease. Every extra guard here was one more silent reason for
        // a hand visibly inside the oval to do nothing.
        let held = RS_Held.Get();
        if (held && held.HandIsFull(1)) return true;

        // A hand with its own weapon in it -- a grenade, a second gun -- is
        // not empty, and only an empty hand grabs the other hand's gun. A
        // fist is what an empty hand wears here, so a fist does not count.
        Weapon ow = p.OffhandWeapon;
        if (ow && !RS_HandFist.IsFistClass(ow.GetClass())) return true;

        int claim = pmo.GripClaimOff;
        if (claim == GRIPSUBJ_Round || claim == GRIPSUBJ_Shell || claim == GRIPSUBJ_Inserting
         || claim == GRIPSUBJ_Magazine || claim == GRIPSUBJ_Pouch)
            return true;
        return false;
    }

    // ---- latching -------------------------------------------------------
    private static int PoseFor(int subj)
    {
        if (subj == GRIPSUBJ_Forend)   return RS_HandWorldBase.POSE_HOLD_FOREND;
        if (subj == GRIPSUBJ_Foregrip) return RS_HandWorldBase.POSE_HOLD_FOREGRIP;
        if (subj == GRIPSUBJ_Support)  return RS_HandWorldBase.POSE_SUPPORT;
        return -1;
    }

    // Tell the engine, through the arbiter, that the off hand is on the gun.
    // ASK FIRST, WRITE ON A GRANT -- the same order RS_Held settled on after
    // a denied claim had already clobbered the field. Renewed every tic while
    // mLatched, which is what keeps the lease alive; a denial means someone
    // else owns the hand now, and the brace ends.
    private bool Claim(PlayerPawn pmo, int subj)
    {
        let arb = Arbiter();
        bool granted = !arb
            || arb.GetInt("grip.claim", "", 1, subj, pmo, 'RS_Stabilize') == 1;
        if (!granted) return false;

        pmo.GripClaimOff = subj;

        // The HUD hand poses itself from the engine's published subject. The
        // WORLD hand takes its shape from whoever holds it, the way RS_Held
        // tells it about a barrel.
        let hd = RS_HandWorldHandler.Get(1);
        if (hd) hd.HoldPose(PoseFor(subj));
        return true;
    }

    // Take back only what is ours: the value we wrote, the lease we hold, the
    // pose we asked for. More than one system writes each of these.
    private void Release(PlayerPawn pmo)
    {
        if (pmo && pmo.GripClaimOff == latchedSubject) pmo.GripClaimOff = 0;

        let arb = Arbiter();
        if (arb && pmo) arb.GetInt("grip.release", "", 1, 0, pmo, 'RS_Stabilize');

        let hd = RS_HandWorldHandler.Get(1);
        if (hd && hd.poseHold == PoseFor(latchedSubject)) hd.HoldPose(-1);
    }

    private void Latch(PlayerPawn pmo, PlayerInfo p, int subj, bool dbg)
    {
        mLatched = true;
        latchedSubject = subj;
        if (!Claim(pmo, subj))
        {
            mLatched = false;
            Console.Printf("[RSSTAB] brace refused: the arbiter says the off hand is spoken for");
            return;
        }
        if (RS_Reach.Flag("rs_stab_haptic", p, true)) level.VRHaptic(1, 0.5, 35.0);
        Console.Printf("[RSSTAB] BRACED %s as %s", curKey, SubjectName(subj));
    }

    private void Unlatch(PlayerPawn pmo, bool dbg, String why)
    {
        if (!mLatched) return;
        Release(pmo);
        mLatched = false;
        Console.Printf("[RSSTAB] let go -- %s", why);
    }

    // ---- the gauge ------------------------------------------------------
    //
    // Position comes from MODELDEF FollowMainHand at DRAW rate, which is what
    // makes the sliders move it live while the menu holds the playsim, and
    // what lets Meets above read its drawn transform. This keeps it alive
    // whenever the weapon can be braced, shows or hides it, and parks it near
    // the player so it is not culled.
    private void UpdateViz(PlayerInfo p, PlayerPawn pmo, bool exist, bool shown)
    {
        if (!exist)
        {
            if (viz) { viz.Destroy(); viz = null; }
            return;
        }
        if (!viz) viz = RS_GaugeBase(Actor.Spawn("RS_StabOval", pmo.Pos));
        if (!viz) return;

        double a = shown ? RS_Reach.Num("rs_grabviz_alpha", p, 0.55) : 0.0;
        viz.Alpha = mLatched ? min(1.0, a * 1.6) : a;
    }

    private void SetVizHot(bool hot)
    {
        if (!viz) return;
        State want = hot ? viz.FindState("Hot") : viz.FindState("Spawn");
        if (want && viz.CurState != want)
        {
            viz.SetState(want);
            viz.SetHot(hot);
        }
    }

    // ---- lifecycle ------------------------------------------------------
    override void OnRegister()
    {
        LoadTable();
        curKey = "";
        lastValid = false;
        mLatched = false;

        // NOTHING HERE TOUCHES AN ENGINE CVAR. Two Handed Weapons is the
        // engine's own switch (Options > VR Controls), and script setting a
        // non-mod cvar is a VM abort -- it crashed the game the one time it
        // was tried. The player turns it on; this handler only reads it.
        //
        // The first build shipped tap-to-latch on. Grip-to-stabilize is a
        // HOLD, as it always was; an ini that saved the tap default goes back,
        // once, on this stamp. rs_stab_latch is this package's own cvar.
        let p = players[consoleplayer];
        let ver = p ? CVar.GetCVar("rs_stab_cfgver", p) : null;
        if (!ver) return;
        if (ver.GetInt() < 2)
        {
            let lt = CVar.GetCVar("rs_stab_latch", p);
            if (lt && lt.GetBool()) lt.SetBool(false);
        }
        ver.SetInt(2);
    }

    // The claim lives on the pawn and the pawn travels. Clear it here or the
    // next map starts with the off hand flagged as bracing a gun that is not
    // there -- the exact jam RR_Reload and RS_Holsters each hit once already.
    override void WorldUnloaded(WorldEvent e)
    {
        let p = players[consoleplayer];
        if (p && p.mo && mLatched) Release(p.mo);
        mLatched = false;
        if (viz) { viz.Destroy(); viz = null; }
    }

    override void WorldTick()
    {
        mTookPress = false;
        insideNow = false;
        mPoised = false;

        let p = players[consoleplayer];
        if (!p || !p.mo) return;
        let pmo = p.mo;

        bool on  = RS_Reach.Flag("rs_stab", p, true);
        bool dbg = RS_Reach.Flag("rs_stab_debug", p, false);

        // THE RAW SQUEEZE, and not GripContext -- the context latches to an
        // object the moment anything claims, and never shows a release edge.
        // Tracked before any early return so an edge is never lost across a
        // toggle.
        bool grip  = pmo.GripHeldOff;
        bool press = grip && !wasGripOff;
        wasGripOff = grip;

        if (!on)
        {
            Unlatch(pmo, dbg, "stabilize switched off");
            UpdateViz(p, pmo, false, false);
            return;
        }

        // Whose numbers are in the sliders.
        String key, arche;
        Resolve(p, key, arche);
        if (key != curKey) Adopt(p, key, arche, dbg);
        else               SyncFromCvars(p, dbg);

        int  subj        = EffectiveSubject(p);
        bool weaponWants = key.Length() > 0 && subj > 0;
        bool offBusy     = OffHandBusy(p, pmo);
        bool canBrace    = weaponWants && pmo.health > 0 && !offBusy;

        // The gauge first, because the test asks it where it is drawn.
        UpdateViz(p, pmo, weaponWants, RS_Reach.Flag("rs_stab_viz", p, true));

        double depth = RS_Reach.Num("rs_stab_depth", p, 1.25);
        bool inside  = weaponWants && Meets(pmo, p, depth);
        insideNow = inside;

        // THE MAIN GRIP ONLY MATTERS WHERE A SWAP IS ALSO POSSIBLE. The rule
        // exists to tell a pistol brace from a hand swap, which are the same
        // tap with the palms together. On a rifle the support oval is a
        // forearm away from the other palm, no swap can fire, and demanding
        // the gun hand squeeze as well just made the brace fail for no reason
        // anyone could see.
        // ONE LINE PER EVENT, ALWAYS. These are the three facts a headset
        // cannot show and a log can: the hand crossed into the ring, it
        // crossed out, and the engine saw the off grip at all. None of them
        // repeats per tic, so none of them is spam.
        if (inside != wasInside)
        {
            Console.Printf("[RSSTAB] off hand %s the ring  (in-oval %.2f, grip %d, busy %d)",
                inside ? "ENTERED" : "left", scoreA, grip ? 1 : 0, offBusy ? 1 : 0);
            wasInside = inside;
        }
        if (grip && !wasGripSeen)
        {
            Console.Printf("[RSSTAB] off grip seen by the engine for the first time this map");
            wasGripSeen = true;
        }

        bool needMain  = RS_Reach.Flag("rs_stab_need_main_grip", p, true);
        bool latchMode = RS_Reach.Flag("rs_stab_latch", p, true);
        bool swapHere  = needMain && RS_Reach.Flag("rs_swap_overlap", p, true)
            && RS_Reach.OvalsOverlap(pmo, p, 1, RS_Reach.Num("rs_swap_overlap_depth", p, 2.0));
        bool poised    = canBrace && inside && (!swapHere || pmo.GripHeldMain);
        mPoised = poised;

        if (mLatched)
        {
            String why = "";
            bool keep = true;
            if (!canBrace)                { keep = false; why = offBusy ? "the off hand got busy" : "nothing to brace"; }
            else if (latchedSubject != subj) { keep = false; why = "the hold changed"; }

            if (keep && latchMode && press) { keep = false; why = "squeezed again"; mTookPress = true; }
            if (keep && !latchMode && !grip) { keep = false; why = "the grip opened"; }

            // PULLED AWAY. The break margin is wider than the meeting depth so
            // a braced hand can drift a little without dropping off, the way a
            // real hand on a forend does not need to sit on one exact spot.
            if (keep)
            {
                if (degenerate)
                {
                    if (scoreA > RS_Reach.Num("rs_stab_min", p, 6.0) * 1.5) { keep = false; why = "too far from the gun"; }
                }
                else
                {
                    double brk = RS_Reach.Num("rs_stab_break", p, 2.5);
                    if (scoreA > brk * brk) { keep = false; why = "too far from the gun"; }
                }
            }

            if (!keep)
            {
                Unlatch(pmo, dbg, why);
            }
            else if (!Claim(pmo, latchedSubject))
            {
                // The lease was refused mid-hold: someone else now owns the
                // hand. Nothing of ours is standing, so just stop.
                mLatched = false;
                if (dbg) Console.Printf("[RSSTAB] let go -- the arbiter gave the off hand to someone else");
            }
        }
        // HOLD MODE IS LEVEL-TRIGGERED, like the original: grip held while the
        // hand is in the oval engages, whichever came first -- squeeze then
        // reach, or reach then squeeze. Only tap mode wants the edge.
        else if (poised && (latchMode ? press : grip))
        {
            Latch(pmo, p, subj, dbg);
            mTookPress = press;
        }
        else if (press && weaponWants)
        {
            // EVERY SQUEEZE THAT DOES NOTHING SAYS WHY, on the press edge
            // only. Always when the hand was IN the oval -- that is the one
            // press the player expected to work, and one line for it is
            // never spam.
            Console.Printf("[RSSTAB] off hand squeezed and did not brace: %s -- in-oval %.2f (need <= %.2f), main grip %d, off hand busy %d, swap possible here %d",
                inside ? "hand is in the oval" : "hand is not in the oval",
                scoreA, degenerate ? RS_Reach.Num("rs_stab_min", p, 6.0) : depth * depth,
                pmo.GripHeldMain ? 1 : 0, offBusy ? 1 : 0, swapHere ? 1 : 0);
        }

        SetVizHot(inside || mLatched);
    }

    // ---- the menu's buttons ---------------------------------------------
    override void NetworkProcess(ConsoleEvent e)
    {
        let p = players[consoleplayer];
        if (!p || !p.mo) return;

        if (e.Name == "rs-stab-print")
        {
            if (curKey.Length() == 0)
            {
                Console.Printf("\c[Gold]RS_STAB: nothing in the main hand");
                return;
            }
            Console.Printf("\c[Gold]RS_STAB: %s (%s) -- %s", curKey, curArche,
                curFromTable ? "tuned by hand" : "archetype defaults, nothing saved yet");
            Console.Printf("  off hand holds it as: %s", SubjectName(EffectiveSubject(p)));
            Console.Printf("  offset fwd %.2f  side %.2f  up %.2f   size %.3f x %.1f/%.1f/%.1f",
                RS_Reach.Num("rs_stab_ofs_y", p, 0), RS_Reach.Num("rs_stab_ofs_x", p, 0),
                RS_Reach.Num("rs_stab_ofs_z", p, 0), RS_Reach.Num("rs_stab_scale", p, 0.025),
                RS_Reach.Num("rs_stab_scale_x", p, 2.5), RS_Reach.Num("rs_stab_scale_y", p, 5.0),
                RS_Reach.Num("rs_stab_scale_z", p, 2.5));
            Console.Printf("  right now: %s, palm %.2f oval radii in (1 = surface), %.1f units from its centre, %d weapon models tuned in all",
                mLatched ? "BRACED" : (insideNow ? "hand in the oval" : "hand outside"),
                scoreA, scoreB, table.Size());
            return;
        }

        if (e.Name == "rs-stab-reset-weapon")
        {
            if (curKey.Length() == 0) return;
            int i = FindEntry(curKey);
            if (i >= 0) { table.Delete(i); SaveTable(); }
            Console.Printf("\c[Gold]RS_STAB: %s back to its archetype defaults", curKey);
            curKey = "";   // re-adopted next tic, which refills the sliders
            return;
        }

        if (e.Name == "rs-stab-reset-all")
        {
            table.Clear();
            SaveTable();
            Console.Printf("\c[Gold]RS_STAB: every weapon model back to archetype defaults");
            curKey = "";
            return;
        }
    }
}
