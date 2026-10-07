<#
    Run this after the game updates, BEFORE launching with the mod installed.

    The mod's own Lua is durable: it resolves assets by name and guards every
    reflection call. The fragile layer is underneath it. Three of the four files
    in ue4ss/UE4SS_Signatures/ derive the image base from an anchor pattern and
    then jump to a HARDCODED absolute RVA, valid only for one exact exe build:

        local ImageBase = MatchAddress - 0x238D414
        return ImageBase + 0xAB747C8

    The anchor is a distinctive sequence that occurs exactly once, so after a
    patch it will very likely still match. UE4SS then reports a successful scan
    and hands the engine wrong pointers for GMalloc, FName::ToString and
    FName_Constructor. That tends to crash rather than fail cleanly, which is
    why this is worth checking before launching rather than after.

    Usage:
        .\check-after-update.ps1
#>

[CmdletBinding()]
param(
    [string] $GamePath = "C:\Program Files (x86)\Steam\steamapps\common\STAR WARS Galactic Racer"
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$problems = @()
$notes = @()

function Ok($m)   { Write-Host "  [ ok ] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  [warn] $m" -ForegroundColor Yellow }
function Bad($m)  { Write-Host "  [FAIL] $m" -ForegroundColor Red }

$known = Get-Content -LiteralPath (Join-Path $PSScriptRoot "known-build.json") -Raw | ConvertFrom-Json
Write-Host ""
Write-Host "Verified against build from $($known.verified)"
Write-Host ""

# --- 1. the game executable ----------------------------------------------

Write-Host "Game executable"
$exe = Join-Path $GamePath $known.game.exe.Replace("/", "\")
if (-not (Test-Path $exe)) {
    Bad "not found at $exe"
    $problems += "exe missing"
}
else {
    $size = (Get-Item $exe).Length
    $hash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLower()

    if ($hash -eq $known.game.sha256) {
        Ok "unchanged, signature RVAs are still valid"
    }
    else {
        Bad "CHANGED. Size $size (was $($known.game.size))."
        Bad "The hardcoded RVAs in UE4SS_Signatures are now stale."
        $problems += "exe changed: signature files must be re-derived before launching"
    }
}

# --- 2. the anchor pattern ------------------------------------------------

if (Test-Path $exe) {
    Write-Host ""
    Write-Host "Signature anchor"
    # 48 8D 0D ? ? ? ? E8 ? ? ? ? E8 ? ? ? ? E8 ? ? ? ? C6 05 ? ? ? ? 01
    $bytes = [System.IO.File]::ReadAllBytes($exe)
    $matchCount = 0
    $firstAt = -1
    for ($i = 0; $i -lt $bytes.Length - 29; $i++) {
        if ($bytes[$i] -ne 0x48) { continue }
        if ($bytes[$i+1] -ne 0x8D -or $bytes[$i+2] -ne 0x0D) { continue }
        if ($bytes[$i+7] -ne 0xE8 -or $bytes[$i+12] -ne 0xE8 -or $bytes[$i+17] -ne 0xE8) { continue }
        if ($bytes[$i+22] -ne 0xC6 -or $bytes[$i+23] -ne 0x05 -or $bytes[$i+28] -ne 0x01) { continue }
        $matchCount++
        if ($firstAt -lt 0) { $firstAt = $i }
    }

    if ($matchCount -eq $known.signature_anchor.expected_matches) {
        if ($hash -eq $known.game.sha256) {
            Ok "matches once, at file offset 0x$($firstAt.ToString('X'))"
        }
        else {
            Warn "still matches once, at 0x$($firstAt.ToString('X')), but on a CHANGED exe."
            Warn "This is the dangerous case: the scan will look successful and"
            Warn "resolve to wrong addresses. Do not launch until the RVAs are redone."
        }
    }
    elseif ($matchCount -eq 0) {
        Warn "no longer matches. UE4SS will fail its scan and refuse to start,"
        Warn "which at least fails loudly rather than crashing."
        $problems += "anchor pattern gone"
    }
    else {
        Warn "matches $matchCount times (expected 1). Ambiguous, scan will reject."
        $problems += "anchor pattern ambiguous"
    }
}

# --- 3. foreign signature overrides --------------------------------------

Write-Host ""
Write-Host "Signature folder"
$sigDir = Join-Path $GamePath "Griffin\Binaries\Win64\ue4ss\UE4SS_Signatures"
if (Test-Path $sigDir) {
    $foreign = Get-ChildItem -Path $sigDir -Filter "*.lua" -File |
        Where-Object { Select-String -LiteralPath $_.FullName -Pattern "SWZeroCompany|SWZC" -Quiet }
    if ($foreign) {
        Bad "foreign game-specific overrides are back:"
        $foreign | ForEach-Object { Bad "   $($_.Name)" }
        Bad "These hard-reject when their own exe is absent and kill UE4SS at startup."
        $problems += "foreign signature overrides present (move them out of the folder)"
    }
    else {
        Ok "no foreign overrides"
    }
}
else {
    Warn "not found, UE4SS may not be installed"
}

# --- 4. settings that get reverted ---------------------------------------

Write-Host ""
Write-Host "UE4SS settings"
$ini = Join-Path $GamePath "Griffin\Binaries\Win64\ue4ss\UE4SS-settings.ini"
if (Test-Path $ini) {
    $text = Get-Content -LiteralPath $ini -Raw
    if ($text -match "EnableHotReloadSystem\s*=\s*1") { Ok "hot reload enabled" }
    else { $notes += "hot reload is off (EnableHotReloadSystem = 0), so Ctrl+R will not work" }
}

# --- 5. the mod itself ----------------------------------------------------

Write-Host ""
Write-Host "Mod"
$mod = Join-Path $GamePath "Griffin\Binaries\Win64\ue4ss\Mods\DialogueMix\Scripts\main.lua"
if (Test-Path $mod) {
    $deployed = (Get-FileHash -LiteralPath $mod -Algorithm SHA256).Hash
    $source = (Get-FileHash -LiteralPath (Join-Path $RepoRoot "Mods\DialogueMix\Scripts\main.lua") -Algorithm SHA256).Hash
    if ($deployed -eq $source) { Ok "deployed copy matches the repo" }
    else { $notes += "deployed copy differs from the repo (run install.ps1 -ModOnly)" }
}
else {
    $notes += "mod is not deployed (run install.ps1)"
}

# --- 6. stale baseline ---------------------------------------------------

Write-Host ""
Write-Host "Captured baseline"
$baseline = Join-Path $env:LOCALAPPDATA "StarWarsGalacticRacer\Saved\DialogueMix-baseline.txt"
if (Test-Path $baseline) {
    $classLines = Select-String -LiteralPath $baseline -Pattern "^class:" | ForEach-Object { $_.Line }
    if ($classLines) {
        Ok "present: $($classLines -join ', ')"
        if ($hash -ne $known.game.sha256) {
            $notes += "exe changed, so run dmx_forget in game to re-capture authored volumes"
        }
    }
}
else {
    Ok "none yet, will be captured on first apply"
}

# --- verdict -------------------------------------------------------------

Write-Host ""
if ($problems.Count -gt 0) {
    Write-Host "DO NOT LAUNCH with the mod installed yet:" -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    Write-Host ""
    Write-Host "To get back to a safe state, either:"
    Write-Host "  1. Get a UE4SS build matching the new game version, or"
    Write-Host "  2. Delete the three RVA-based files from UE4SS_Signatures"
    Write-Host "     (GMalloc.lua, FName_ToString.lua, FName_Constructor.lua)"
    Write-Host "     and let the generic scanner try instead. It may not find them,"
    Write-Host "     but a failed scan is safer than a wrong address."
    Write-Host "  3. Or just remove the mod: .\tools\uninstall.ps1 -All"
}
else {
    Write-Host "Safe to launch." -ForegroundColor Green
}

if ($notes.Count -gt 0) {
    Write-Host ""
    Write-Host "Also worth doing:"
    $notes | ForEach-Object { Write-Host "  - $_" }
}
Write-Host ""
