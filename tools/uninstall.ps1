<#
    Removes UE4SS and the DialogueMix mod from STAR WARS: Galactic Racer.

    Usage:
        .\uninstall.ps1              # remove just the mod, leave UE4SS in place
        .\uninstall.ps1 -All         # remove UE4SS and the dwmapi.dll proxy too
#>

[CmdletBinding()]
param(
    [string] $GamePath = "C:\Program Files (x86)\Steam\steamapps\common\STAR WARS Galactic Racer",
    [switch] $All
)

$ErrorActionPreference = "Stop"
$ModName = "DialogueMix"

$BinariesDir = Join-Path $GamePath "Griffin\Binaries\Win64"
$Ue4ssDir = Join-Path $BinariesDir "ue4ss"

function Say($message) { Write-Host "  $message" }

if (-not (Test-Path $BinariesDir)) {
    throw "game binaries not found under '$BinariesDir'. Pass -GamePath with the right install directory."
}

$ModTarget = Join-Path $Ue4ssDir "Mods\$ModName"
if (Test-Path $ModTarget) {
    Remove-Item -LiteralPath $ModTarget -Recurse -Force
    Say "removed ue4ss\Mods\$ModName"
}
else {
    Say "mod was not installed"
}

$modsTxt = Join-Path $Ue4ssDir "Mods\mods.txt"
if (Test-Path $modsTxt) {
    $kept = @(Get-Content -LiteralPath $modsTxt | Where-Object { $_ -notmatch "^\s*$ModName\s*:" })
    Set-Content -LiteralPath $modsTxt -Value $kept -Encoding utf8
    Say "deregistered from mods.txt"
}

$modsJson = Join-Path $Ue4ssDir "Mods\mods.json"
if (Test-Path $modsJson) {
    # Excise just our object by text, for the same reason install.ps1 inserts by
    # text: reserialising this file lost eight entries once already.
    $raw = [System.IO.File]::ReadAllText($modsJson)
    $pattern = ',?\s*\{[^{}]*"mod_name"\s*:\s*"' + [regex]::Escape($ModName) + '"[^{}]*\}'

    if ($raw -match $pattern) {
        $updated = [regex]::Replace($raw, $pattern, "", 1)
        # If ours was the first entry, a leading comma can be left behind.
        $updated = $updated -replace '\[\s*,', '['
        Copy-Item -LiteralPath $modsJson -Destination "$modsJson.bak" -Force
        [System.IO.File]::WriteAllText($modsJson, $updated, (New-Object System.Text.UTF8Encoding($false)))
        Say "deregistered from mods.json (previous kept as mods.json.bak)"
    }
    else {
        Say "mods.json does not list $ModName"
    }
}

if ($All) {
    if (Test-Path $Ue4ssDir) {
        Remove-Item -LiteralPath $Ue4ssDir -Recurse -Force
        Say "removed ue4ss"
    }
    $proxy = Join-Path $BinariesDir "dwmapi.dll"
    if (Test-Path $proxy) {
        Remove-Item -LiteralPath $proxy -Force
        Say "removed dwmapi.dll proxy"
    }
    Get-ChildItem -Path $BinariesDir -Filter "ue4ss.backup-*" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        Say "note: backup left in place at $($_.Name)"
    }
}

Write-Host ""
Write-Host "Done. The game is back to stock." -ForegroundColor Green
