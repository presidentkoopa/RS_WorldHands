# Build RS_WorldHands.pk3
#
# Adapted from RS_VR_Unified/build.ps1, which was the best packer in this
# family: an ALLOWLIST rather than an exclusion list (a lump name ignores its
# extension, so a stray MODELDEF.bak in a pk3 root has silently shadowed the
# real MODELDEF before), entry-by-entry .NET zip writing (Compress-Archive and
# CreateFromDirectory both write BACKSLASHES on Windows PowerShell, which
# GZDoom tolerates and SLADE does not), and post-build verification of its own
# output.
#
# CHECKS 7, 8 AND 9 ARE NEW, and each one exists because the spin-out from
# RS_VR_Unified on 2026-09-08 nearly shipped that exact fault:
#
#   7  every cvar the code names is DECLARED in this package's CVARINFO.
#      Unified kept the hand cvars in two separate regions of its file -- the
#      block at the top where you would look, and nineteen rs_stab_* stranded
#      at the bottom AFTER the weapon wheel's section. An undeclared cvar is
#      not an error in ZScript, it is a zero, so copying "the hands section"
#      would have shipped a stabilize system whose every slider silently read
#      its default.
#
#   8  every OptionMenu is REACHABLE from a menu hooked into the engine's own.
#      RS_HandsOptions links only the two placement pages; grab, distance grab,
#      throwing, feedback, the aiming ray, what-is-grabbable and stabilize all
#      hung off RS_VRUnifiedOptions, which did NOT come across. That compiles
#      clean, loads clean, and reads in a headset as the grab system having
#      been stripped out, when every cvar and class is present and merely
#      orphaned.
#
#   9  every MODELDEF Model/Skin path resolves to a packed entry. A model that
#      cannot find its mesh draws nothing and logs nothing.
#
# NO KEYCONF, DELIBERATELY. Unified's KEYCONF is entirely holster, anchor-grip
# and wheel aliases; not one line of it is a hand. The three netevents this
# package listens for (rs-stab-print, rs-stab-reset-weapon, rs-stab-reset-all)
# are fired by SafeCommand rows in MENUDEF, so there is nothing to bind.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$root = $PSScriptRoot
$out  = Join-Path $root 'RS_WorldHands.pk3'

# A missing one of these is an error, not a warning. A package silently missing
# its MAPINFO registers no event handlers at all, which reads in-headset as
# "the whole mod does nothing."
$requiredLumps = @('zscript.txt', 'MAPINFO.txt', 'CVARINFO.txt', 'MENUDEF.txt')
$optionalLumps = @('MODELDEF.txt', 'TEXTURES.txt', 'TRNSLATE.txt', 'SNDINFO.txt', 'ANIMDEFS.txt')
$contentDirs   = @('zscript', 'models', 'graphics', 'sprites', 'sounds')

$files = @()
foreach ($f in $requiredLumps) {
    $p = Join-Path $root $f
    if (-not (Test-Path $p)) { throw "REQUIRED lump missing: $f" }
    $files += Get-Item $p
}
foreach ($f in $optionalLumps) {
    $p = Join-Path $root $f
    if (Test-Path $p) { $files += Get-Item $p }
}
foreach ($d in $contentDirs) {
    $p = Join-Path $root $d
    if (Test-Path $p) { $files += Get-ChildItem $p -Recurse -File }
}

if (Test-Path $out) { Remove-Item $out -Force }

$fs  = [System.IO.File]::Open($out, 'Create')
$zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
foreach ($f in $files) {
    $rel = ($f.FullName.Substring($root.Length + 1)) -replace '\\', '/'
    $e   = $zip.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Optimal)
    $st  = $e.Open()
    $b   = [System.IO.File]::ReadAllBytes($f.FullName)
    $st.Write($b, 0, $b.Length)
    $st.Close()
}
$zip.Dispose()
$fs.Close()

# ---------------------------------------------------------------- verification
$z     = [System.IO.Compression.ZipFile]::OpenRead($out)
$names = @{}
$z.Entries | ForEach-Object { $names[$_.FullName.ToLower()] = $true }
$fail  = 0

function Read-Entry($zz, $name) {
    $e = $zz.Entries | Where-Object { $_.FullName -eq $name }
    if (-not $e) { return '' }
    $r = New-Object System.IO.StreamReader($e.Open())
    $t = $r.ReadToEnd(); $r.Close()
    return $t
}

# 1. Forward slashes only.
$bad = @($z.Entries | Where-Object { $_.FullName -match '\\' }).Count
if ($bad -gt 0) { Write-Warning "$bad entries contain backslashes"; $fail++ }

# 2. Nothing that is not a lump.
$stray = @($z.Entries | Where-Object { $_.FullName -match '(?i)(\.md$|\.ps1$|\.py$|\.json$|\.bak$|^\.claude/|^docs/|^tools/|^media/)' })
foreach ($s in $stray) { Write-Warning "stray non-lump packed: $($s.FullName)"; $fail++ }

# 3. Every #include resolves to a packed entry.
$zstxt = Read-Entry $z 'zscript.txt'
$inc = 0; $incMiss = 0
$included = @{}
foreach ($line in ($zstxt -split "`n")) {
    if ($line -match '^\s*#include\s+"([^"]+)"') {
        $inc++
        $included[$matches[1].ToLower()] = $true
        if (-not $names.ContainsKey($matches[1].ToLower())) {
            Write-Warning "unresolved #include: $($matches[1])"; $incMiss++; $fail++
        }
    }
}

# 3b. THE OTHER DIRECTION. A .zs that is PACKED but never #included compiles to
#     nothing, so every class in it is silently absent -- and the first symptom
#     is "Unknown identifier" in whichever OTHER file used it, pointing at a
#     line that is perfectly correct.
$orphanZs = 0
foreach ($e in $z.Entries) {
    if ($e.FullName -match '(?i)\.zs$' -and -not $included.ContainsKey($e.FullName.ToLower())) {
        Write-Warning "packed but never #included (its classes will not exist): $($e.FullName)"
        $orphanZs++; $fail++
    }
}

# 4. Exactly one version line, and it is 5.0.0.
$vers = @([regex]::Matches($zstxt, '(?m)^\s*version\s+"([^"]+)"'))
if ($vers.Count -ne 1) { Write-Warning "zscript.txt has $($vers.Count) version lines, expected exactly 1"; $fail++ }
elseif ($vers[0].Groups[1].Value -ne '5.0.0') { Write-Warning "version is $($vers[0].Groups[1].Value), expected 5.0.0"; $fail++ }

# 5. Every AddEventHandlers name is a class that exists.
$mitxt = Read-Entry $z 'MAPINFO.txt'
$allZs = ''
foreach ($e in ($z.Entries | Where-Object { $_.FullName -match '(?i)\.zs$' })) {
    $r = New-Object System.IO.StreamReader($e.Open())
    $allZs += $r.ReadToEnd(); $r.Close()
}
$declared = @([regex]::Matches($allZs, '(?im)^\s*class\s+([A-Za-z0-9_]+)') | ForEach-Object { $_.Groups[1].Value.ToLower() })

$handlers = @()
foreach ($m in [regex]::Matches($mitxt, '(?i)AddEventHandlers\s*=\s*([^\r\n}]+)')) {
    $handlers += ([regex]::Matches($m.Groups[1].Value, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
}
$hMiss = 0
foreach ($h in $handlers) {
    if ($declared -notcontains $h.ToLower()) { Write-Warning "MAPINFO registers undefined handler: $h"; $hMiss++; $fail++ }
}

# 5b. Defined but not registered. FAILS HERE, unlike in Unified -- the wheel had
#     a documented reason for shipping unregistered handlers and this package
#     has none. Every EventHandler here is meant to run.
$hUnreg = @()
foreach ($m in [regex]::Matches($allZs, '(?im)^\s*class\s+([A-Za-z0-9_]+)\s*:\s*(?:Static)?EventHandler\b')) {
    $hn = $m.Groups[1].Value
    if ($handlers -notcontains $hn) { $hUnreg += $hn }
}
foreach ($hn in $hUnreg) { Write-Warning "EventHandler defined but NOT registered in MAPINFO: $hn"; $fail++ }

# 6. No duplicate class name.
$dupes = @($declared | Group-Object | Where-Object { $_.Count -gt 1 })
foreach ($d in $dupes) { Write-Warning "duplicate class declaration: $($d.Name) x$($d.Count)"; $fail++ }

# 7. EVERY CVAR THE CODE NAMES IS DECLARED HERE. See the header.
#
#    rs_grab_m and rs_grab_o are the two exceptions and they are not cvars --
#    they are MODELDEF PlacementCVars PREFIXES, from which rs_grab.zs:150,244
#    builds the real names at runtime. The derived rs_grab_m_ofs_x etc. are
#    declared and are checked like everything else.
$cvtxt = Read-Entry $z 'CVARINFO.txt'
$cvDecl = @{}
foreach ($m in [regex]::Matches($cvtxt, '(?im)^\s*(?:server|user|nosave|noarchive)\s+\w+\s+([A-Za-z_][A-Za-z0-9_]*)\s*=')) {
    $cvDecl[$m.Groups[1].Value.ToLower()] = $true
}
$prefixes = @('rs_grab_m', 'rs_grab_o')

# CVARS ANOTHER PACKAGE OWNS, READ DEFENSIVELY. Not a way to silence this check
# -- a name goes here only with a call site that handles absence, and the entry
# says which.
#
#   rs_body_poseframe_main / _off
#       Declared by RS_VRBody. It owns the hand SLOT even when this package owns
#       the hand ACTOR, and publishes what shape the hand should be in as an
#       already-translated FRAME NUMBER (the two mods do not share a pose
#       vocabulary -- they diverge at index 7). handworld.zs reads them through
#       CVar.GetCVar and leaves bodyPose at -1 when the handle is null, so
#       RS_VRBody absent means that rung never fires and the controllers drive
#       the hand exactly as before.
$foreign = @('rs_body_poseframe_main', 'rs_body_poseframe_off')

$cvMiss = 0
$seen = @{}
foreach ($m in [regex]::Matches($allZs, '"(rs_[a-z0-9_]+)"')) {
    $n = $m.Groups[1].Value
    if ($seen.ContainsKey($n)) { continue }
    $seen[$n] = $true
    if ($prefixes -contains $n) { continue }
    if ($foreign  -contains $n) { continue }
    if (-not $cvDecl.ContainsKey($n.ToLower())) {
        Write-Warning "cvar named in code but NOT declared in CVARINFO (reads as zero, silently): $n"
        $cvMiss++; $fail++
    }
}

# 8. EVERY OptionMenu IS REACHABLE. See the header.
$mntxt = Read-Entry $z 'MENUDEF.txt'
$pages = @([regex]::Matches($mntxt, '(?im)^\s*OptionMenu\s+"?([A-Za-z0-9_]+)"?') | ForEach-Object { $_.Groups[1].Value })
$linked = @{}
foreach ($m in [regex]::Matches($mntxt, '(?im)^\s*Submenu\s+"[^"]*"\s*,\s*"?([A-Za-z0-9_]+)"?')) {
    $linked[$m.Groups[1].Value.ToLower()] = $true
}
$orphanPage = 0
foreach ($p in $pages) {
    if (-not $linked.ContainsKey($p.ToLower())) {
        Write-Warning "OptionMenu defined but NOTHING links to it (unreachable in game): $p"
        $orphanPage++; $fail++
    }
}
# And the reverse: a Submenu pointing at a page this package does not define is
# a dead row -- silent, and exactly what lifting a package out of another one
# produces.
$deadLink = 0
foreach ($k in $linked.Keys) {
    $hit = $false
    foreach ($p in $pages) { if ($p.ToLower() -eq $k) { $hit = $true } }
    if (-not $hit) { Write-Warning "Submenu points at a menu this package does not define: $k"; $deadLink++; $fail++ }
}

# 9. EVERY MODELDEF ASSET RESOLVES TO A PACKED ENTRY.
$mdtxt = Read-Entry $z 'MODELDEF.txt'
$mdMiss = 0
$curPath = ''
foreach ($line in ($mdtxt -split "`n")) {
    if ($line -match '^\s*//') { continue }
    if ($line -match '(?i)^\s*Path\s+"([^"]+)"') { $curPath = $matches[1].Trim('/'); continue }
    if ($line -match '(?i)^\s*(?:Model\s+\d+|Skin\s+\d+|SurfaceSkin\s+\d+\s+\d+)\s+"([^"]+)"') {
        $asset = $matches[1]
        if ($asset -eq '') { continue }
        $rel = $asset
        if ($curPath -ne '') { $rel = "$curPath/$asset" }
        if (-not $names.ContainsKey($rel.ToLower())) {
            Write-Warning "MODELDEF asset not packed (model draws nothing, logs nothing): $rel"
            $mdMiss++; $fail++
        }
    }
}

# 10. BRACE BALANCE PER .ZS, IGNORING COMMENTS AND LITERALS.
#
#     Not a parser -- it cannot catch a missing semicolon. It catches the one
#     fault that costs the most time to read, because the compiler reports it in
#     the wrong place: a stray '}' closes the CLASS early, and every declaration
#     after it parses at file scope. The error you get names the next method and
#     says "Unexpected 'private'", pointing at a line that is perfectly correct,
#     dozens of lines from the actual brace.
#
#     rs_stabilize.zs shipped exactly this way in RS_VR_Unified: an `if (dbg)`
#     was deleted and its closing brace left behind. It came across in the
#     2026-09-08 spin-out byte-identical, took the whole package down on load,
#     and the message pointed at line 346 while the brace was at 342.
#
#     Comments and string/name literals are stripped first -- a '}' inside a
#     comment (this file's own notes contain several) would otherwise report a
#     phantom mismatch, which is worse than no check at all.
function Get-CodeOnly([string]$t) {
    $sb = New-Object System.Text.StringBuilder
    $i = 0; $n = $t.Length; $st = 'code'
    while ($i -lt $n) {
        $c = $t[$i]
        switch ($st) {
            'code' {
                if ($c -eq '/' -and $i + 1 -lt $n -and $t[$i+1] -eq '/') { $st = 'lc'; $i += 2; continue }
                if ($c -eq '/' -and $i + 1 -lt $n -and $t[$i+1] -eq '*') { $st = 'bc'; $i += 2; continue }
                if ($c -eq '"')  { $st = 'dq'; $i++; continue }
                if ($c -eq "'")  { $st = 'sq'; $i++; continue }
                [void]$sb.Append($c); $i++
            }
            'lc' { if ($c -eq "`n") { $st = 'code' }; $i++ }
            'bc' { if ($c -eq '*' -and $i + 1 -lt $n -and $t[$i+1] -eq '/') { $st = 'code'; $i += 2; continue }; $i++ }
            default {
                if ($c -eq [char]0x5C) { $i += 2; continue }          # backslash escape
                if (($st -eq 'dq' -and $c -eq '"') -or ($st -eq 'sq' -and $c -eq "'")) { $st = 'code' }
                $i++
            }
        }
    }
    return $sb.ToString()
}

$braceBad = 0
foreach ($e in ($z.Entries | Where-Object { $_.FullName -match '(?i)\.zs$' })) {
    $r = New-Object System.IO.StreamReader($e.Open())
    $src = $r.ReadToEnd(); $r.Close()
    $code = Get-CodeOnly $src
    $ob = ([regex]::Matches($code, '\{')).Count
    $cb = ([regex]::Matches($code, '\}')).Count
    if ($ob -ne $cb) {
        Write-Warning "brace mismatch in $($e.FullName): $ob open, $cb close ($($ob - $cb)). A stray brace closes the class early; the compiler will blame a later line."
        $braceBad++; $fail++
    }
}

$n  = $z.Entries.Count
$kb = [math]::Round((Get-Item $out).Length / 1KB, 1)
$z.Dispose()

Write-Host ""
Write-Host "RS_WorldHands.pk3  --  $n entries, $kb KB"
Write-Host "  backslash entries : $bad"
Write-Host "  stray files       : $($stray.Count)"
Write-Host "  #includes         : $inc checked, $incMiss unresolved, $orphanZs orphaned"
Write-Host "  event handlers    : $($handlers.Count) registered, $hMiss undefined, $($hUnreg.Count) unregistered"
Write-Host "  classes           : $($declared.Count) declared, $($dupes.Count) duplicated"
Write-Host "  cvars             : $($cvDecl.Count) declared, $cvMiss named-but-undeclared"
Write-Host "  menus             : $($pages.Count) pages, $orphanPage unreachable, $deadLink dead links"
Write-Host "  modeldef assets   : $mdMiss missing"
Write-Host "  brace balance     : $braceBad files unbalanced"
if ($fail -gt 0) { throw "package verification failed ($fail problems)" }
Write-Host "  VERIFIED OK"
