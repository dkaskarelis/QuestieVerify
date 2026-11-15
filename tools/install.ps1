# QuestieVerify installer for Windows. Start it by double-clicking "Install QuestieVerify.bat".
# Uses only Windows PowerShell 5.1, which every Windows 10/11 PC has: nothing else to install.
#
# 1. Finds WoW Forever (or asks you to pick its folder) and checks that Questie is installed.
# 2. If the ForeverDB addon is installed, builds QuestieVerify's data file from it
#    (Data from ForeverDB.net, https://foreverdb.net; GPL-3.0 with an attribution term).
#    If QuestieForeverFixes is installed, its prerequisites are added too
#    (xelblch/questie-forever-fixes, https://github.com/xelblch/questie-forever-fixes, MIT).
# 3. Copies QuestieVerify into Interface\AddOns\QuestieVerify.
#
# For development: -DataOnly <ForeverDB folder> [-Fixes <folder>] -Out <file> only builds the data file.
param(
    [string]$Forever = "",
    [switch]$Elevated,
    [string]$DataOnly = "",
    [string]$Fixes = "",
    [string]$Out = ""
)
$ErrorActionPreference = "Stop"
$Here = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)   # the QuestieVerify folder
$AddonFiles = @("QuestieVerify.toc", "QuestieVerify.lua", "Options.lua", "README.md", "LICENSE")
$Multi = [Text.RegularExpressions.RegexOptions]::Multiline

function Say($msg, $color = "Gray") { Write-Host $msg -ForegroundColor $color }
function Fail($msg) {
    Write-Host ""
    Write-Host $msg -ForegroundColor Red
    if ($Elevated) { Read-Host "Press Enter to close" | Out-Null }
    exit 1
}
# Any unexpected error: show it and, in the administrator window, wait so it can be read before the window closes.
trap {
    Write-Host ""
    Write-Host "Something went wrong: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "The install may be incomplete. Try running the installer again." -ForegroundColor Red
    if ($Elevated) { Read-Host "Press Enter to close" | Out-Null }
    exit 1
}

# ------------------------------------------------------------------ data file (ForeverDB + questie-forever-fixes)
function ReadText($path) {
    return ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)) -replace "`r`n", "`n"
}
$LuaStr = '"((?:[^"\\]|\\.)*)"'
function Block($src, $name) {
    $m = [regex]::Match($src, "^ns\." + [regex]::Escape($name) + "\s*=\s*\{", $Multi)
    if (-not $m.Success) { throw "ns.$name not found in the ForeverDB addon" }
    $start = $m.Index + $m.Length
    $end = $src.IndexOf("`n}", $start)
    return $src.Substring($start, $end - $start)
}
function StringEntries($src, $name) {
    $out = @{}
    foreach ($m in [regex]::Matches((Block $src $name), "^\[(\d+)\]=" + $LuaStr, $Multi)) {
        $out[[int]$m.Groups[1].Value] = $m.Groups[2].Value
    }
    return $out
}
function LuaQuote([string]$s) { return '"' + $s.Replace('\', '\\').Replace('"', '\"') + '"' }
function Num($s) { $s = "$s".Trim(); if ($s -eq "") { return 0 }; return [int]$s }
function Field($f, $i) { if ($i -lt $f.Count) { return $f[$i] } return "" }
function Digits($s) { return @([regex]::Matches($s, "\d+") | ForEach-Object { $_.Value }) }   # "1, 2,3" -> 1 2 3
$B36 = "0123456789abcdefghijklmnopqrstuvwxyz"
function Unpoint([string]$tok) {   # base-36 map spot -> uiMap id
    [long]$v = 0
    foreach ($ch in $tok.ToLower().ToCharArray()) {
        $d = $B36.IndexOf($ch)
        if ($d -lt 0) { return 0 }
        $v = $v * 36 + $d
    }
    return [long][math]::Floor($v / 1000000)
}

function BuildData($fdbDir, $qffDir, $outPath) {
    if (Test-Path (Join-Path $fdbDir "ForeverDB")) { $fdbDir = Join-Path $fdbDir "ForeverDB" }
    $data = Join-Path $fdbDir "Data"
    $toc = ReadText (Join-Path $fdbDir "ForeverDB.toc")
    $version = [regex]::Match($toc, "^## Version:\s*(\S+)", $Multi).Groups[1].Value
    if (-not $version) { throw "no version in ForeverDB.toc" }
    $qfSrc = ReadText (Join-Path $data "QuestForever.lua")
    $qcSrc = ReadText (Join-Path $data "QuestClassic.lua")
    $build = [regex]::Match($qfSrc, "build (\S+?)\.\s").Groups[1].Value
    if (-not $build) { throw "no client build in QuestForever.lua" }

    $qf = StringEntries $qfSrc "qfQuests"
    $qc = StringEntries $qcSrc "qcQuests"

    function Spots($name) {
        $o = @{}
        foreach ($m in [regex]::Matches((Block $qfSrc $name), '^\[(\d+)\]=\{s="([^"]*)"', $Multi)) {
            $maps = @{}
            foreach ($t in ($m.Groups[2].Value -split "\s+")) {
                if ($t -ne "") { $u = Unpoint $t; if ($u -ne 0) { $maps[$u] = 1 } }
            }
            if ($maps.Count -gt 0) { $o[[int]$m.Groups[1].Value] = @($maps.Keys | Sort-Object) }
        }
        return $o
    }
    $seenMaps = Spots "qfSeen"
    $poiMaps = Spots "qfPoi"

    $gone = @{}
    foreach ($m in [regex]::Matches((Block $qcSrc "qcGone"), "^\[(\d+)\]=1", $Multi)) { $gone[[int]$m.Groups[1].Value] = 1 }
    $excl = StringEntries $qcSrc "qcExcl"

    $offers = @{}
    $offSrc = ReadText (Join-Path $data "QuestOffers.lua")
    foreach ($m in [regex]::Matches((Block $offSrc "questOffers"), "^\[(\d+)\]=\{(.*)\},?$", $Multi)) {
        $offers[[int]$m.Groups[1].Value] = @([regex]::Matches($m.Groups[2].Value, $LuaStr) | ForEach-Object { $_.Groups[1].Value })
    }

    $trainers = @{}
    $npcSrc = ReadText (Join-Path $data "NPCs.lua")
    $tm = [regex]::Match($npcSrc, "^ns\.classTrainers\s*=\s*\{(.*)\}\s*$", $Multi)
    if ($tm.Success) {
        foreach ($c in [regex]::Matches($tm.Groups[1].Value, "([A-Z]+)=\{([\d,\s]*)\}")) {
            $trainers[$c.Groups[1].Value] = Digits $c.Groups[2].Value
        }
    }

    # Merge Classic + Forever the way the ForeverDB addon does (QuestData.lua Q.quest): Forever wins for what it has.
    $ids = @{}
    foreach ($k in $qf.Keys) { $ids[$k] = 1 }
    foreach ($k in $qc.Keys) { $ids[$k] = 1 }
    $sb = New-Object Text.StringBuilder
    $rowCount = 0; $foreverCount = 0
    foreach ($qid in ($ids.Keys | Sort-Object)) {
        $side = ""; $races = 0; $classes = 0; $needAll = ""; $needAny = ""; $ex = 0; $starts = ""; $ssrc = ""
        $after = 0; $by = 0; $new = 0; $seenMin = 0; $minLv = 0
        if ($qc.ContainsKey($qid)) {
            $f = $qc[$qid].Split("|")
            $minLv = Num (Field $f 2)
            $side = Field $f 3; $classes = Num (Field $f 4); $races = Num (Field $f 5)
            $needAll = Field $f 6; $needAny = Field $f 7; $ex = Num (Field $f 8)
            $starts = Field $f 9; $ssrc = "c"
        }
        $inQf = $qf.ContainsKey($qid)
        if ($inQf) {
            $f = $qf[$qid].Split("|")
            if ((Num (Field $f 2)) -gt 0) { $minLv = Num (Field $f 2) }
            if ((Field $f 4).Trim() -ne "") { $starts = Field $f 4; $ssrc = "s" }
            $by = Num (Field $f 6)
            $new = if ((Field $f 7) -eq "1") { 1 } else { 0 }
            $after = Num (Field $f 8)
            $seenMin = Num (Field $f 9)
            if ($side -eq "" -and @("a", "h") -contains (Field $f 10)) { $side = Field $f 10 }
            $foreverCount++
        }
        $omaps = @(); $osrc = ""
        if ($seenMaps.ContainsKey($qid)) { $omaps = $seenMaps[$qid]; $osrc = "s" }
        elseif ($poiMaps.ContainsKey($qid)) { $omaps = $poiMaps[$qid]; $osrc = "p" }
        $isGone = if ($gone.ContainsKey($qid) -and -not $inQf) { 1 } else { 0 }
        $vals = @((LuaQuote $side), $races, $classes, (LuaQuote $needAll.Trim()), (LuaQuote $needAny.Trim()), $ex, $after,
            (LuaQuote $starts.Trim()), (LuaQuote $ssrc), $isGone, $by, $new, (LuaQuote ($omaps -join " ")), (LuaQuote $osrc),
            $minLv, $seenMin, $(if ($inQf) { 1 } else { 0 }))
        [void]$sb.Append("[$qid]={" + ($vals -join ",") + "},`n")
        $rowCount++
    }

    # questie-forever-fixes: manual (Fixes.lua) wins over generated (Generated.lua)
    $qff = @{}
    if ($qffDir) {
        foreach ($fname in @("Generated.lua", "Fixes.lua")) {
            $path = Join-Path $qffDir $fname
            if (-not (Test-Path -LiteralPath $path)) { continue }
            $src = ReadText $path
            foreach ($m in [regex]::Matches($src, "\[(\d+)\]\s*=\s*\{")) {
                $depth = 1; $i = $m.Index + $m.Length
                while ($depth -gt 0 -and $i -lt $src.Length) {
                    $j = $src.IndexOfAny([char[]]"{}", $i)
                    if ($j -lt 0) { $i = $src.Length; break }
                    if ($src[$j] -eq "{") { $depth++ } else { $depth-- }
                    $i = $j + 1
                }
                $body = $src.Substring($m.Index + $m.Length, [math]::Max(0, $i - 1 - ($m.Index + $m.Length)))
                $single = [regex]::Match($body, "preQuestSingle\s*=\s*\{([\d,\s]*)\}")
                $group = [regex]::Match($body, "preQuestGroup\s*=\s*\{([\d,\s]*)\}")
                if ($single.Success -or $group.Success) {
                    $qff[[int]$m.Groups[1].Value] = @(((Digits $single.Groups[1].Value) -join " "),
                                                      ((Digits $group.Groups[1].Value) -join " "))
                }
            }
        }
    }

    $L = New-Object Text.StringBuilder
    [void]$L.Append("-- Data from ForeverDB.net (https://foreverdb.net), ForeverDB Companion $version, client build $build.`n")
    [void]$L.Append("-- ForeverDB.net's data is GPL-3.0 with an attribution term: credit `"Data from ForeverDB.net (https://foreverdb.net)`".`n")
    [void]$L.Append("-- Community prerequisites from xelblch/questie-forever-fixes (https://github.com/xelblch/questie-forever-fixes), MIT.`n")
    [void]$L.Append("-- Generated by the QuestieVerify installer for personal use. Do not edit by hand.`n")
    [void]$L.Append("local _, ns = ...`n")
    [void]$L.Append("ns.fdb = { version = $(LuaQuote $version), build = $(LuaQuote $build) }`n")
    [void]$L.Append("-- [quest] = { side, races mask, classes mask, needs all, needs one of, exclusive group, offered after,`n")
    [void]$L.Append("--   starts, starts source (s players, c Classic), gone, players who saw it, new in Forever,`n")
    [void]$L.Append("--   uiMaps where offered, those maps' source (s players, p client), min level, lowest level seen completing, in Forever data }`n")
    [void]$L.Append("ns.fdb.quests = {`n")
    [void]$L.Append($sb.ToString())
    [void]$L.Append("}`n-- [quest] = rules of who it is NOT offered to: `"side;CLASS;Race`", empty = any`nns.fdb.offers = {`n")
    foreach ($q in ($offers.Keys | Sort-Object)) { [void]$L.Append("[$q]={" + (($offers[$q] | ForEach-Object { LuaQuote $_ }) -join ",") + "},`n") }
    [void]$L.Append("}`nns.fdb.excl = {`n")
    foreach ($g in ($excl.Keys | Sort-Object)) { [void]$L.Append("[$g]=$(LuaQuote $excl[$g]),`n") }
    [void]$L.Append("}`nns.fdb.trainers = {`n")
    foreach ($c in ($trainers.Keys | Sort-Object -CaseSensitive)) { [void]$L.Append("$c={" + ($trainers[$c] -join ",") + "},`n") }
    [void]$L.Append("}`n-- [quest] = { preQuestSingle (one of), preQuestGroup (all) }`nns.qff = {`n")
    foreach ($q in ($qff.Keys | Sort-Object)) { [void]$L.Append("[$q]={$(LuaQuote $qff[$q][0]),$(LuaQuote $qff[$q][1])},`n") }
    [void]$L.Append("}`n")

    $dir = Split-Path -Parent $outPath
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    [IO.File]::WriteAllText($outPath, $L.ToString(), (New-Object Text.UTF8Encoding $false))
    Say ("  ForeverDB {0}: {1} quests ({2} in Forever data), {3} offer rules, {4} exclusive groups; community fixes: {5}" -f `
        $version, $rowCount, $foreverCount, $offers.Count, $excl.Count, $qff.Count)
}

if ($DataOnly) {
    if (-not $Out) { $Out = Join-Path $Here "Data\ForeverDB.lua" }
    BuildData $DataOnly $Fixes $Out
    exit 0
}

# ------------------------------------------------------------------ find WoW Forever
function AddonsUnder($root) {
    if (-not $root) { return $null }
    $root = $root.Trim().Trim('"').TrimEnd('\')
    foreach ($p in @("$root\_forever_\Interface\AddOns", "$root\Interface\AddOns", $root)) {
        if ((Test-Path -LiteralPath $p -PathType Container) -and (Split-Path -Leaf $p) -eq "AddOns" -and
            ((Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent $p))) -eq "_forever_")) { return $p }
    }
    return $null
}
function FindForever {
    $roots = New-Object Collections.ArrayList
    foreach ($key in @("HKLM:\SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft",
                       "HKLM:\SOFTWARE\Blizzard Entertainment\World of Warcraft")) {
        try {
            $ip = (Get-ItemProperty -Path $key -ErrorAction Stop).InstallPath
            if ($ip) { [void]$roots.Add((Split-Path -Parent $ip.TrimEnd('\'))) }   # ...\_retail_ -> the WoW folder
        } catch {}
    }
    # Local hard drives only: checking a disconnected network drive can hang for a long time.
    foreach ($d in ([IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq "Fixed" -and $_.IsReady })) {
        foreach ($sub in @("Program Files\World of Warcraft", "Program Files (x86)\World of Warcraft",
                           "World of Warcraft", "Games\World of Warcraft", "Battle.net\World of Warcraft")) {
            [void]$roots.Add((Join-Path $d.RootDirectory.FullName $sub))
        }
    }
    foreach ($r in $roots) { $a = AddonsUnder $r; if ($a) { return $a } }
    return $null
}
function PickFolder {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $dlg = New-Object Windows.Forms.FolderBrowserDialog
        $dlg.Description = "QuestieVerify couldn't find WoW Forever. Pick your World of Warcraft folder (the one that has _forever_ in it)."
        $dlg.ShowNewFolderButton = $false
        # An invisible always-on-top owner keeps the picker in front of the console window instead of behind it.
        $owner = New-Object Windows.Forms.Form -Property @{ TopMost = $true; ShowInTaskbar = $false }
        try {
            if ($dlg.ShowDialog($owner) -eq [Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
        } finally { $owner.Dispose() }
    } catch {}
    return $null
}

Say ""
Say "QuestieVerify installer" "Cyan"
Say "-----------------------" "Cyan"
$addons = if ($Forever) { AddonsUnder $Forever } else { FindForever }
if (-not $addons) {
    Say "Couldn't find WoW Forever by itself. A window will ask you to pick your World of Warcraft folder." "Yellow"
    $addons = AddonsUnder (PickFolder)
}
if (-not $addons) {
    Fail ("Couldn't find WoW Forever's AddOns folder.`n" +
          "Start WoW Forever once from Battle.net (that creates the folder), then run the installer again`n" +
          "and pick the World of Warcraft folder that has _forever_ inside it.")
}
$foreverRoot = Split-Path -Parent (Split-Path -Parent $addons)
Say "WoW Forever: $foreverRoot"

# Program Files needs administrator rights to write; ask Windows once if we can't.
$probe = Join-Path $addons ".questieverify-write-test"
try { [IO.File]::WriteAllText($probe, "x"); Remove-Item -LiteralPath $probe -Force }
catch {
    if ($Elevated) { Fail "Windows wouldn't let the installer write to $addons, even as administrator." }
    Say "This folder needs administrator rights. Windows will ask you to allow the installer..." "Yellow"
    try {
        Start-Process powershell -Verb RunAs -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
            "`"$($MyInvocation.MyCommand.Path)`"", "-Elevated", "-Forever", "`"$foreverRoot`"")
        Say "The install continues in the new window."
    } catch { Fail "The installer wasn't allowed to run as administrator, so nothing was installed." }
    exit 0
}

if (-not (Test-Path -LiteralPath (Join-Path $addons "Questie") -PathType Container)) {
    Fail ("Questie isn't installed. Install Questie first (CurseForge app or Wago app, search 'Questie'),`n" +
          "then double-click 'Install QuestieVerify' again.")
}
Say "  Questie: found" "Green"

$dataFile = Join-Path $Here "Data\ForeverDB.lua"
$fdb = Join-Path $addons "ForeverDB"
$hasData = $false
if (Test-Path -LiteralPath (Join-Path $fdb "ForeverDB.toc")) {
    Say "  ForeverDB addon: found, reading its quest data (Data from ForeverDB.net, https://foreverdb.net)" "Green"
    $qffDir = Join-Path $addons "QuestieForeverFixes"
    if (-not (Test-Path -LiteralPath (Join-Path $qffDir "Fixes.lua"))) { $qffDir = "" }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "QuestieVerify-ForeverDB.lua"
    try { BuildData $fdb $qffDir $tmp; $hasData = $true }
    catch { Say "  Couldn't read the ForeverDB data ($($_.Exception.Message)). Installing without it." "Yellow" }
} else {
    Say "  ForeverDB addon: not installed." "Yellow"
    Say "  QuestieVerify works without it, but ForeverDB's quest data is what catches most wrong markers." "Yellow"
    Say "  Install the free ForeverDB addon (CurseForge or Wago app, search 'ForeverDB'), then run this again." "Yellow"
}

$target = Join-Path $addons "QuestieVerify"
New-Item -ItemType Directory -Force (Join-Path $target "Data") | Out-Null
foreach ($name in $AddonFiles) {
    $src = Join-Path $Here $name
    if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $target $name) -Force }
}
if ($hasData) {
    Copy-Item -LiteralPath $tmp -Destination (Join-Path $target "Data\ForeverDB.lua") -Force
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
} elseif ((Test-Path -LiteralPath $dataFile) -and -not (Test-Path -LiteralPath (Join-Path $target "Data\ForeverDB.lua"))) {
    Copy-Item -LiteralPath $dataFile -Destination (Join-Path $target "Data\ForeverDB.lua") -Force
}

Say ""
Say "Done! QuestieVerify is installed in $target" "Green"
Say "If WoW is running, quit it completely and start it again (/reload isn't enough for a new addon)."
Say "In game, type /qv to open QuestieVerify's options."
if ($Elevated) { Say ""; Read-Host "Press Enter to close" | Out-Null }
