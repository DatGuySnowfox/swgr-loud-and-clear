<#
    Deploys UE4SS and the DialogueMix mod into STAR WARS: Galactic Racer.

    Nothing here touches the game's own files. UE4SS loads through a dwmapi.dll
    proxy placed next to the shipping exe, and everything else lives in a ue4ss
    subfolder beside it. Uninstalling is deleting those two things, which is what
    uninstall.ps1 does.

    Usage:
        .\install.ps1                  # deploy UE4SS + the mod
        .\install.ps1 -ModOnly         # refresh just the Lua, UE4SS already there
        .\install.ps1 -Force           # overwrite an existing UE4SS deployment
#>

[CmdletBinding()]
param(
    [string] $GamePath = "C:\Program Files (x86)\Steam\steamapps\common\STAR WARS Galactic Racer",
    [string] $UE4SSZip = (Join-Path $env:USERPROFILE "Downloads\UE4SS For Star Wars Zero Company 9 1.1 2026-09-09T16-14Z LXoSV32rq.zip"),
    [switch] $ModOnly,
    [switch] $Force
)

$ErrorActionPreference = "Stop"
$ModName = "DialogueMix"
$RepoRoot = Split-Path -Parent $PSScriptRoot

function Say($message) { Write-Host "  $message" }

# --- validate target ------------------------------------------------------

$BinariesDir = Join-Path $GamePath "Griffin\Binaries\Win64"
$ShippingExe = Join-Path $BinariesDir "SWGR-Win64-Shipping.exe"

if (-not (Test-Path $ShippingExe)) {
    throw "SWGR-Win64-Shipping.exe not found under '$BinariesDir'. Pass -GamePath with the right install directory."
}
Say "game found: $BinariesDir"

$Ue4ssDir = Join-Path $BinariesDir "ue4ss"
$ProxyDll = Join-Path $BinariesDir "dwmapi.dll"

# --- deploy UE4SS ---------------------------------------------------------

if (-not $ModOnly) {
    $alreadyInstalled = (Test-Path $ProxyDll) -and (Test-Path $Ue4ssDir)

    if ($alreadyInstalled -and -not $Force) {
        Say "UE4SS already deployed, leaving it alone (use -Force to replace)"
    }
    else {
        if (-not (Test-Path $UE4SSZip)) {
            throw "UE4SS archive not found at '$UE4SSZip'. Pass -UE4SSZip with its location."
        }

        $staging = Join-Path $env:TEMP ("ue4ss-stage-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        try {
            Say "expanding $(Split-Path -Leaf $UE4SSZip)"
            Expand-Archive -LiteralPath $UE4SSZip -DestinationPath $staging -Force

            # Some builds nest everything under a per-game folder, some do not.
            $sourceProxy = Get-ChildItem -Path $staging -Filter "dwmapi.dll" -Recurse -File | Select-Object -First 1
            if ($null -eq $sourceProxy) { throw "no dwmapi.dll inside the archive" }
            $sourceRoot = $sourceProxy.Directory.FullName

            $sourceUe4ss = Join-Path $sourceRoot "ue4ss"
            if (-not (Test-Path $sourceUe4ss)) { throw "no ue4ss folder next to dwmapi.dll inside the archive" }

            if ($alreadyInstalled) {
                $backup = Join-Path $BinariesDir ("ue4ss.backup-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
                Say "backing up existing deployment to $(Split-Path -Leaf $backup)"
                Move-Item -LiteralPath $Ue4ssDir -Destination $backup
            }

            Copy-Item -LiteralPath $sourceProxy.FullName -Destination $ProxyDll -Force
            Copy-Item -LiteralPath $sourceUe4ss -Destination $BinariesDir -Recurse -Force
            Say "UE4SS deployed"
        }
        finally {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if (-not (Test-Path $Ue4ssDir)) {
    throw "'$Ue4ssDir' does not exist. Run without -ModOnly to deploy UE4SS first."
}

# --- deploy the mod -------------------------------------------------------

$ModsDir = Join-Path $Ue4ssDir "Mods"
$ModSource = Join-Path $RepoRoot "Mods\$ModName"
$ModTarget = Join-Path $ModsDir $ModName

if (-not (Test-Path $ModSource)) { throw "mod source missing at '$ModSource'" }

New-Item -ItemType Directory -Path $ModsDir -Force | Out-Null
if (Test-Path $ModTarget) { Remove-Item -LiteralPath $ModTarget -Recurse -Force }
Copy-Item -LiteralPath $ModSource -Destination $ModsDir -Recurse -Force
Say "mod copied to ue4ss\Mods\$ModName"

# --- register the mod -----------------------------------------------------

# UE4SS reads mods.json on newer builds and mods.txt on older ones. Whichever
# this build happens to use, the mod needs an enabled entry in it.

$modsTxt = Join-Path $ModsDir "mods.txt"
if (Test-Path $modsTxt) {
    $lines = @(Get-Content -LiteralPath $modsTxt)
    if ($lines -match "^\s*$ModName\s*:") {
        Say "mods.txt already lists $ModName"
    }
    else {
        # Built-in mods must stay last, so insert ahead of any trailing blank lines.
        Add-Content -LiteralPath $modsTxt -Value "$ModName : 1" -Encoding utf8
        Say "registered in mods.txt"
    }
}

$modsJson = Join-Path $ModsDir "mods.json"
if (Test-Path $modsJson) {
    # Append-only, by text. This file belongs to UE4SS, not to us.
    #
    # Two earlier attempts here did parse-and-reserialize and both damaged it.
    # ConvertTo-Json in PowerShell 5.1 wrapped the array in {value:[...],
    # Count:n}, burying the built-in mods inside a junk entry; the rewrite meant
    # to repair that silently produced an empty set and left only our own entry,
    # dropping the other eight. Reserialising a file you do not own turns a
    # missing-entry problem into a data-loss problem, so this now only ever
    # inserts, and never rewrites what is already there.

    $raw = [System.IO.File]::ReadAllText($modsJson)

    if ($raw -match ('"mod_name"\s*:\s*"' + [regex]::Escape($ModName) + '"')) {
        Say "mods.json already lists $ModName"
    }
    else {
        $close = $raw.LastIndexOf("]")
        if ($close -lt 0) {
            Warn "mods.json has no closing bracket, leaving it alone"
            Warn "register $ModName by hand, or rely on mods.txt"
        }
        else {
            $head = $raw.Substring(0, $close).TrimEnd()
            $separator = ""
            if ($head.EndsWith("}")) { $separator = "," }
            $entry = '    {"mod_name": "' + $ModName + '", "mod_enabled": true}'
            $updated = $head + $separator + "`n" + $entry + "`n]`n"

            Copy-Item -LiteralPath $modsJson -Destination "$modsJson.bak" -Force
            # No BOM: a BOM can break a strict JSON parser.
            [System.IO.File]::WriteAllText($modsJson, $updated, (New-Object System.Text.UTF8Encoding($false)))
            Say "registered in mods.json (previous kept as mods.json.bak)"
        }
    }
}

# --- AOB signatures -------------------------------------------------------

# UE4SS locates engine internals by scanning for byte patterns. Packages for
# other games sometimes ship overrides that hardcode absolute addresses, or that
# reject outright when their own exe is missing. Both break this game, one of
# them dangerously: a hardcoded address still "matches" after a patch and
# resolves to the wrong place, which crashes instead of erroring.
#
# The files in Signatures/ find the same targets by content and resolve
# relatively, so they tolerate a shifted layout.

$SigSource = Join-Path $RepoRoot "Signatures"
$SigTarget = Join-Path $Ue4ssDir "UE4SS_Signatures"

if (Test-Path $SigSource) {
    New-Item -ItemType Directory -Path $SigTarget -Force | Out-Null

    # Quarantine anything tied to another game rather than deleting it.
    $foreign = Get-ChildItem -Path $SigTarget -Filter "*.lua" -File -ErrorAction SilentlyContinue |
        Where-Object { Select-String -LiteralPath $_.FullName -Pattern "SWZeroCompany|SWZC" -Quiet }
    if ($foreign) {
        $quarantine = Join-Path $SigTarget "disabled-foreign"
        New-Item -ItemType Directory -Path $quarantine -Force | Out-Null
        foreach ($f in $foreign) {
            Move-Item -LiteralPath $f.FullName -Destination (Join-Path $quarantine $f.Name) -Force
            Say "quarantined foreign signature: $($f.Name)"
        }
    }

    foreach ($sig in Get-ChildItem -Path $SigSource -Filter "*.lua" -File) {
        $dest = Join-Path $SigTarget $sig.Name
        if (Test-Path $dest) {
            $existing = Get-Content -LiteralPath $dest -Raw
            if ($existing -match "ImageBase\s*=\s*MatchAddress\s*-") {
                Copy-Item -LiteralPath $dest -Destination "$dest.hardcoded-bak" -Force
                Say "replacing address-based $($sig.Name) (old kept as .hardcoded-bak)"
            }
        }
        Copy-Item -LiteralPath $sig.FullName -Destination $dest -Force
    }
    Say "deployed $((Get-ChildItem -Path $SigSource -Filter '*.lua').Count) content-based signatures"

    $checker = Join-Path $PSScriptRoot "check-signatures.py"
    if (Test-Path $checker) {
        Say "validate them any time with: python tools\check-signatures.py"
    }
}

# --- engine version sanity check -----------------------------------------

$settings = Join-Path $Ue4ssDir "UE4SS-settings.ini"
if (Test-Path $settings) {
    $text = Get-Content -LiteralPath $settings -Raw
    $major = [regex]::Match($text, "MajorVersion\s*=\s*(\d+)")
    $minor = [regex]::Match($text, "MinorVersion\s*=\s*(\d+)")
    if ($major.Success -and $minor.Success) {
        Say "UE4SS engine override is set to $($major.Groups[1].Value).$($minor.Groups[1].Value)"
        Say "if UE4SS fails to attach, try bumping MinorVersion in UE4SS-settings.ini"
    }
}

Write-Host ""
Write-Host "Done. Launch the game, then:" -ForegroundColor Green
Write-Host "  Ctrl+F8  dump the audio graph to UE4SS.log"
Write-Host "  Ctrl+F7  apply the mix changes"
Write-Host "  Ctrl+F9  restore authored levels"
Write-Host ""
Write-Host "Log: $(Join-Path $Ue4ssDir 'UE4SS.log')"
