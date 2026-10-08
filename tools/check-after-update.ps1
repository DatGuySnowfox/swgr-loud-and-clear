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

# --- 2. the signatures ----------------------------------------------------

# Delegated to check-signatures.py rather than scanned here.
#
# This used to walk the executable byte by byte in PowerShell: around 490 million
# loop iterations, minutes of CPU, to check one anchor. The Python checker does
# the whole job in under a second with a compiled regex, and does it better,
# because it resolves all four signatures to addresses instead of only confirming
# that an anchor still exists. An anchor that still matches on a changed binary is
# exactly the case that looks fine and is not.

if (Test-Path $exe) {
    Write-Host ""
    Write-Host "Signatures"

    $checker = Join-Path $PSScriptRoot "check-signatures.py"
    $python = $null
    foreach ($candidate in @("python", "py", "python3")) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($cmd) { $python = $cmd.Source; break }
    }

    if (-not (Test-Path $checker)) {
        Warn "check-signatures.py is missing, cannot verify the signatures"
        $notes += "restore tools/check-signatures.py and re-run"
    }
    elseif (-not $python) {
        Warn "Python not found, so the signatures were NOT checked."
        Warn "This is the part that matters most after a patch. Install Python"
        Warn "and run: python tools\check-signatures.py"
        $notes += "signatures unverified (no Python)"
    }
    else {
        $output = & $python $checker --exe $exe 2>&1
        $failed = $LASTEXITCODE -ne 0
        foreach ($line in $output) {
            $text = [string]$line
            if ($text -match "^\s*\w+\s+\d+ match") { Write-Host "  $($text.Trim())" }
            elseif ($text -match "WOULD BE REJECTED|^All signatures") { Write-Host "  $($text.Trim())" }
        }
        if ($failed) {
            Bad "one or more signatures would be rejected, see above"
            $problems += "signatures do not resolve on this build"
        }
        else {
            Ok "all four resolve cleanly on this build"
        }
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
$mod = Join-Path $GamePath "Griffin\Binaries\Win64\ue4ss\Mods\LoudAndClear\Scripts\main.lua"
if (Test-Path $mod) {
    $deployed = (Get-FileHash -LiteralPath $mod -Algorithm SHA256).Hash
    $source = (Get-FileHash -LiteralPath (Join-Path $RepoRoot "Mods\LoudAndClear\Scripts\main.lua") -Algorithm SHA256).Hash
    if ($deployed -eq $source) { Ok "deployed copy matches the repo" }
    else { $notes += "deployed copy differs from the repo (run install.ps1 -ModOnly)" }
}
else {
    $notes += "mod is not deployed (run install.ps1)"
}

# --- 6. stale baseline ---------------------------------------------------

Write-Host ""
Write-Host "Captured baseline"
$baseline = Join-Path $env:LOCALAPPDATA "StarWarsGalacticRacer\Saved\LoudAndClear-baseline.txt"
if (Test-Path $baseline) {
    $classLines = Select-String -LiteralPath $baseline -Pattern "^class:" | ForEach-Object { $_.Line }
    if ($classLines) {
        Ok "present: $($classLines -join ', ')"
        if ($hash -ne $known.game.sha256) {
            $notes += "exe changed, so run lac_forget in game to re-capture authored volumes"
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
