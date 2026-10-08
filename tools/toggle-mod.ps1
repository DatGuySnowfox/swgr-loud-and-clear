<#
    Turns the mod on or off in place, for A/B testing against the unmodified game.

    UE4SS decides what to load from THREE places, and an earlier version of this
    script only touched one of them, so toggling off did nothing at all:

      enabled.txt  a marker file in the mod folder. Loads the mod on its own,
                   regardless of what the other two say. This is the one that
                   matters, and the one that was being missed.
      mods.txt     "Name : 0" or "Name : 1", with load order.
      mods.json    {"mod_name": ..., "mod_enabled": true|false}

    All three are handled here. Nothing is deleted: enabled.txt is renamed, so
    -On puts it back.

        .\toggle-mod.ps1 -Off
        .\toggle-mod.ps1 -On
        .\toggle-mod.ps1            # report current state
#>
[CmdletBinding()]
param(
    [string] $GamePath = "C:\Program Files (x86)\Steam\steamapps\common\STAR WARS Galactic Racer",
    [switch] $On,
    [switch] $Off
)

$ErrorActionPreference = "Stop"
$ModName = "LoudAndClear"
$ModsDir = Join-Path $GamePath "Griffin\Binaries\Win64\ue4ss\Mods"
if (-not (Test-Path $ModsDir)) { throw "Mods folder not found at '$ModsDir'" }

$marker    = Join-Path $ModsDir "$ModName\enabled.txt"
$markerOff = Join-Path $ModsDir "$ModName\enabled.txt.off"
$modsTxt   = Join-Path $ModsDir "mods.txt"
$modsJson  = Join-Path $ModsDir "mods.json"

function Report {
    $m = if (Test-Path $marker) { "present" } elseif (Test-Path $markerOff) { "renamed off" } else { "absent" }
    $t = "-"
    if (Test-Path $modsTxt) {
        foreach ($line in Get-Content -LiteralPath $modsTxt) {
            if ($line -match ("^\s*" + [regex]::Escape($ModName) + "\s*:\s*([01])")) { $t = $Matches[1] }
        }
    }
    $j = "-"
    if (Test-Path $modsJson) {
        $raw = [System.IO.File]::ReadAllText($modsJson)
        if ($raw -match ('"mod_name"\s*:\s*"' + [regex]::Escape($ModName) + '"\s*,\s*"mod_enabled"\s*:\s*(true|false)')) {
            $j = $Matches[1]
        }
    }
    # enabled.txt alone is enough to load, so it decides the verdict.
    $loads = (Test-Path $marker) -or ($t -eq "1") -or ($j -eq "true")
    Write-Host "  enabled.txt : $m"
    Write-Host "  mods.txt    : $t"
    Write-Host "  mods.json   : $j"
    Write-Host "  => $ModName will $(if ($loads) { 'LOAD' } else { 'NOT load' })" `
        -ForegroundColor $(if ($loads) { "Yellow" } else { "Green" })
}

if (-not ($On -or $Off)) { Report; return }

$want = [bool]$On

# 1. the marker file, which overrides everything else
if ($want) {
    if ((Test-Path $markerOff) -and -not (Test-Path $marker)) {
        Move-Item -LiteralPath $markerOff -Destination $marker
    }
    elseif (-not (Test-Path $marker)) {
        New-Item -ItemType File -Path $marker | Out-Null
    }
}
elseif (Test-Path $marker) {
    if (Test-Path $markerOff) { Remove-Item -LiteralPath $markerOff -Force }
    Move-Item -LiteralPath $marker -Destination $markerOff
}

# 2. mods.txt, line-wise so nothing else is disturbed
if (Test-Path $modsTxt) {
    $updated = Get-Content -LiteralPath $modsTxt | ForEach-Object {
        if ($_ -match ("^\s*" + [regex]::Escape($ModName) + "\s*:")) {
            "$ModName : $(if ($want) { 1 } else { 0 })"
        } else { $_ }
    }
    Set-Content -LiteralPath $modsTxt -Value @($updated) -Encoding utf8
}

# 3. mods.json, by targeted text replacement. This file is UE4SS's, and
#    reserialising it lost eight entries once already.
if (Test-Path $modsJson) {
    $raw = [System.IO.File]::ReadAllText($modsJson)
    $pattern = '("mod_name"\s*:\s*"' + [regex]::Escape($ModName) + '"\s*,\s*"mod_enabled"\s*:\s*)(true|false)'
    if ($raw -match $pattern) {
        $replaced = [regex]::Replace($raw, $pattern, ('${1}' + $(if ($want) { "true" } else { "false" })), 1)
        [System.IO.File]::WriteAllText($modsJson, $replaced, (New-Object System.Text.UTF8Encoding($false)))
    }
}

Write-Host "  $ModName is now $(if ($want) { 'ON' } else { 'OFF' }). Restart the game."
Write-Host ""
Report
