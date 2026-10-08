<#
    Turns the mod on or off in place, for A/B testing against the unmodified game.

    Flips the mods.txt entry rather than deleting anything, so nothing has to be
    reinstalled and the comparison is one keystroke apart.

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
$modsTxt = Join-Path $GamePath "Griffin\Binaries\Win64\ue4ss\Mods\mods.txt"
if (-not (Test-Path $modsTxt)) { throw "mods.txt not found at '$modsTxt'" }

$lines = @(Get-Content -LiteralPath $modsTxt)
$current = $null
foreach ($line in $lines) {
    if ($line -match ("^\s*" + [regex]::Escape($ModName) + "\s*:\s*([01])")) { $current = $Matches[1] }
}
if ($null -eq $current) { throw "$ModName is not listed in mods.txt" }

if (-not ($On -or $Off)) {
    Write-Host "  $ModName is currently $(if ($current -eq '1') { 'ON' } else { 'OFF' })"
    return
}

$want = if ($On) { "1" } else { "0" }
$updated = $lines | ForEach-Object {
    if ($_ -match ("^\s*" + [regex]::Escape($ModName) + "\s*:")) { "$ModName : $want" } else { $_ }
}
Set-Content -LiteralPath $modsTxt -Value $updated -Encoding utf8
Write-Host "  $ModName is now $(if ($want -eq '1') { 'ON' } else { 'OFF' }). Restart the game."
