# Loud and Clear

A UE4SS Lua mod for STAR WARS: Galactic Racer that makes dialogue intelligible
during races. It lifts the dialogue sound classes and ducks the music, crowds,
airflow and engines that bury them.

Defaults: dialogue at **1.7x**, maskers cut by **2 to 4.5 dB**. Both tunable, and
tunable live without restarting the game.

## Install

Needs a UE4SS build with UE 5.6 support. See
[Troubleshooting](#ue4ss-fails-to-start) if yours is older.

```powershell
git clone https://github.com/DatGuySnowfox/swgr-loud-and-clear
cd swgr-loud-and-clear
.\tools\install.ps1
```

The installer finds the game under Steam, deploys UE4SS if it is not already
there, copies the mod, and registers it in both `mods.txt` and `mods.json`.
Useful flags:

| Flag | Effect |
| --- | --- |
| `-ModOnly` | Refresh just the Lua. Use this after editing config. |
| `-Force` | Replace an existing UE4SS deployment, backing the old one up. |
| `-GamePath <dir>` | Non-default install location. |
| `-UE4SSZip <file>` | Point at a specific UE4SS archive. |

Remove it with `.\tools\uninstall.ps1`, or `-All` to take UE4SS out too.

## Using it

It applies itself a few seconds after the audio graph comes up, every launch.
There is nothing to press to get the normal behaviour.

### Keys

| Key | Action |
| --- | --- |
| Ctrl+F7 | Re-apply now |
| Ctrl+F8 | Dump the audio graph to `UE4SS.log` |
| Ctrl+F9 | Restore the game's own levels |
| Ctrl+R | Reload the mod after editing `main.lua` |

### Console commands

Open the UE4SS console (enable it with `ConsoleEnabled = 1` in
`UE4SS-settings.ini`) and use:

| Command | Action |
| --- | --- |
| `lac_apply` | Re-apply |
| `lac_reset` | Back to the game's levels |
| `lac_set <relpath> <multiplier>` | Change one submix live |
| `lac_verify` | Check the values still hold |
| `lac_dump` | Dump the audio graph |
| `lac_param <relpath>` | Print every property on an object |
| `lac_forget` | Discard stored authored values and re-capture |

`lac_set` is the fast way to tune by ear, no reload needed:

```
lac_set Submixes/SS_Music 0.45
lac_set Submixes/SS_Crowds 0.50
```

Those are not saved. Put the values you settle on into `main.lua`.

## Tuning

Two dials, in the `CONFIG` table at the top of
`Mods\LoudAndClear\Scripts\main.lua`.

### Dialogue level

```lua
class_boost = 1.7,
```

A plain linear multiplier on the dialogue sound classes. `1.0` is untouched,
`2.0` is twice as loud. This is the dial for "I still cannot hear them".

Pushing it far will eventually feed `SE_Main_MixModeCompressor` on the main bus
and start pumping the rest of the mix, so if high values sound harsh rather than
louder, take some of it from the duck table instead.

### Separation

```lua
duck = {
    ["Submixes/SS_Music"]                          = 0.60,  -- -4.44 dB
    ["Submixes/SS_Crowds"]                         = 0.65,  -- -3.74 dB
    ["Submixes/SS_HighSpeedAirflow"]               = 0.65,  -- -3.74 dB
    ["Submixes/SS_NonLocalPlayerEngineAndExhaust"] = 0.70,  -- -3.10 dB
    ["Submixes/SS_LocalPlayerEngine"]              = 0.75,  -- -2.50 dB
    ["Submixes/SS_LocalPlayerExhaust"]             = 0.75,  -- -2.50 dB
    ["Submixes/SS_Ambience"]                       = 0.80,  -- -1.94 dB
}
```

Multipliers relative to the game's authored level, converted to dB internally.
There is 60 dB of range, so these can go much deeper. Engines below about 0.50
costs the racing noticeable weight, which is a real trade rather than a free win.

Add any submix from `Audio/Mixing/Submixes/`. Gain on a parent is inherited by
its children, so name parents, not both.

### After editing

```powershell
.\tools\install.ps1 -ModOnly
```

Then Ctrl+R in game. With `EnableAutoReloadingLuaMods = 1` it often reloads on
save by itself, but the watcher is inconsistent, so do not rely on it.

## How it works

Volume in this game is reachable at several stages and **only two of them do
anything useful**. Both are used, for different jobs.

**Sound class volume, for boosting.** `FSoundClassProperties::Volume` is a plain
float with no unity ceiling, applied to `SC_Voice` and `SC_Characters_Vox`. It
also reads back, so the mod writes it, reads it, and logs `verified` rather than
assuming the write landed.

**Control buses, for ducking.** Each submix has a `CB_Submix*` control bus wired
to its `OutputVolumeModulation` destination, driven through
`UAudioModulationStatics::SetGlobalBusMixValue`. Values are in decibels, so
multipliers convert with `20*log10`.

### Why boosting goes through sound classes and not buses

The buses run through `MP_Volume`, a `SoundModulationParameterVolume`. Dumping
its real properties shows one range field:

```
[SoundModulationParameterVolume] FloatProperty MinVolume = -60.0
```

No `MaxVolume`, because 0 dB is both unity and the ceiling for that parameter
type: it maps `[-60, 0]` dB onto `[0, 1]` normalised and clamps. A request of
+3.52 dB or +6.02 dB normalises above 1.0 and comes back as unity. So a bus
boost is silently discarded, while a bus cut has the full 60 dB available.

This is arithmetic inside the parameter, not an access restriction, so a native
DLL would hit the same clamp. Sound class volume sidesteps it by being a
different stage entirely.

### Stages that do not work

Writing submix `OutputVolume` via `SetSubmixOutputVolume` accomplishes nothing
here. The call succeeds, but the property reads back as `nil` on all 62
submixes and nothing changes audibly, because the modulation destination drives
the gain instead. `also_write_submix` is off by default for that reason.

### Routing that matters

Gain on a parent is inherited, so targeting a parent and its children compounds
the change:

```
SC_Voice      -> SC_Commentary, SC_DiegeticVoice, SC_NonDiegeticVoice, SC_Voice_Cinematic
SC_Characters -> SC_Characters_Foley, SC_Characters_Vox
SC_Main       -> SC_Music, SC_SFX, SC_Voice, SC_UI, SC_Cinematic, SC_FinishLine

SS_DiegeticVoice, SS_NonDiegeticVoice -> SS_Voice -> SS_Main
SS_Characters_Vox -> SS_Characters -> SS_SFX
```

`SC_Voice` covers the four dialogue children. `SC_Characters_Vox` is named
directly because its parent also carries foley that should not be lifted.

### baseline.txt

The authored volumes are captured before the first write and saved to
`%LOCALAPPDATA%\StarWarsGalacticRacer\Saved\LoudAndClear-baseline.txt`.

This exists because a hot reload hands the mod a fresh Lua state. Without the
file it would read the already-boosted value back as the authored one and
multiply again, walking 1.7 to 2.9 to 4.9 across three reloads. Saving the first
capture makes re-applying idempotent.

It lives in the save directory rather than next to the script because the mod
folder is under Program Files, which is not writable without elevation.

Run `lac_forget` to discard it and re-capture. Worth doing after a game patch,
which can change the authored values and leave the file stale.

## Surviving game updates

Nothing makes AOB scanning immune to patches. But the layers differ a lot in how
they fail, and the dangerous one has been fixed.

**The mod's Lua is durable.** It resolves assets by path name, guards every
reflection call, and logs when something is missing. A content reorganisation
makes it stop working, not crash.

**The signatures used to be actively dangerous.** Three of the four files in
`UE4SS_Signatures` shipped like this:

```lua
local ImageBase = MatchAddress - 0x238D414   -- assume anchor sits at this RVA
return ImageBase + 0xAB747C8                 -- then a hardcoded absolute RVA
```

Those RVAs are valid for exactly one build. The anchor is a distinctive sequence
occurring exactly once, so after a patch it will very likely **still match**,
UE4SS reports a successful scan, and the engine gets a wrong pointer. That
crashes rather than erroring.

`Signatures/` replaces them with patterns that find the same targets by content
and resolve relatively, the way `GUObjectArray.lua` already did. Verified
equivalent on the reference build:

| Signature | Matches | Resolves to | Old hardcoded value |
| --- | --- | --- | --- |
| `GMalloc` | 3 (all agree) | `0xAB747C8` | `0xAB747C8` |
| `FName_ToString` | 1 | `0x3752404` | `0x3752404` |
| `FName_Constructor` | 1 | `0x3C7DB26` | `0x3C7DB26` |
| `GUObjectArray` | 1 | `0xAC5E910` | already relative |

`GMalloc` matching three sites is a feature, not a problem: UE4SS dedupes by
resolved value, so three independent sites agreeing means two can disappear and
it still works.

`install.ps1` deploys these and quarantines any foreign game-specific overrides
it finds, keeping the originals as `.hardcoded-bak`.

### After an update, before launching

```powershell
.\tools\check-after-update.ps1          # exe fingerprint, foreign overrides, settings
python tools\check-signatures.py        # do the patterns still resolve cleanly
```

`check-signatures.py` reads the patterns straight out of `Signatures/*.lua`,
scans the installed exe, and reports what UE4SS would accept. Exit code 1 means
do not launch.

If a pattern stops matching, UE4SS fails its scan and refuses to start, which is
the safe failure. Recovery options, in order: get a UE4SS build matching the new
engine version, or delete the affected file so the generic scanner tries
instead, or remove the mod with `uninstall.ps1 -All`.

Also run `lac_forget` in game after a patch. A rebalanced mix changes the
authored volumes, and a stale `baseline.txt` would apply the boost to the wrong
base.

### What else gets reverted

Steam updates generally leave extra files alone, since `dwmapi.dll` and `ue4ss/`
are not in the game manifest. Vortex is the likelier culprit: redeploying it can
restore foreign signature overrides and reset `UE4SS-settings.ini`, turning hot
reload back off. `check-after-update.ps1` checks for both.

## Troubleshooting

### Dialogue level does not change

Check `UE4SS.log` for the apply summary:

```
applied: 7/7 control buses, 0/0 submix volumes, 2/2 class volumes
class SC_Voice  1.000 -> 1.700  (x1.70, verified)
```

`verified` means the write landed and read back. If a class reports that the
value did not stick, or `0/2 class volumes`, the names or paths are wrong, and
Ctrl+F8 will show what is actually loaded.

Sound class volume is sampled when a voice starts, so a line already playing
when you reload will not change. Trigger a new one.

### UE4SS fails to start

```
[PS] Failed to find GMalloc
[PS] Failed to find FName::ToString: found 2 unique values
Fatal Error: PS scan timed out
```

The build is too old for this engine version. `EngineVersionOverride` will not
fix it, because the problem is a scanner that does not know the newer layouts.

Packaging date is not a reliable signal. A Vortex or Nexus package rebuilt in
2026 for another game can still contain a 2024 DLL, so check the DLL itself.

### UE4SS starts then dies on a signature file

```
Fatal Error: [SWZC StaticConstructObject] cannot read adjacent SWZeroCompany.exe
```

Game-specific AOB overrides left in `ue4ss/UE4SS_Signatures/` from another
game's package. They hard-reject when their own exe is absent. Move them out of
that folder and the generic scanner takes over.

## Game audio architecture

Reference notes, so this does not have to be rediscovered.

**Engine.** Unreal Engine, project codename `Griffin`, shipping exe
`Griffin\Binaries\Win64\SWGR-Win64-Shipping.exe`. Version string is stripped
(`Auto-381121`), but CEF3 128.4.13 / Chromium 128, IoStore TOC version 8,
`NNERuntimeORT` and PCG put it at UE 5.6 or newer.

**No anticheat.** No EasyAntiCheat, no BattlEye. EOS SDK for online, PlayFab for
multiplayer, Sentry for crash reporting, so an injected DLL may surface in the
developer's crash telemetry.

**Native Unreal audio, no middleware.** No Wwise, no FMOD. The exe confirms
`AudioModulation`, `SoundControlBus` and `MetasoundEngine`.

**Mix topology.** 61 sound classes in `/Game/Griffin/Audio/Mixing/Classes/`, 62
submixes in `Submixes/`, and a full Audio Modulation layer: one `CB_Submix*` bus
per submix, settings buses (`CB_Settings_DialogueVolume` and Main, Music, Sfx, UI
siblings) all bound to `MP_Volume`, and gameplay mixes including `CBM_InRaceVO`,
`CBM_PreRaceVO_Ducking` and `CBM_Snapshot_Conversation`.

`Griffin/Plugins/FuseMixingControl` is a MIDI control surface for the audio
team's dev builds and is not part of the runtime settings path.

**Paks are unencrypted.** Encryption key GUID is zero, container flags are
`Compressed | Indexed`, so FModel opens `Griffin\Content\Paks` with no AES key.

**In-game settings.** The options menu has a speech slider (`DA_SpeechVolume`),
stored as `DialogueVolume` under `[/Script/Griffin.GfnUserSettingsPC]` in
`%LOCALAPPDATA%\StarWarsGalacticRacer\Saved\Config\Windows\GameUserSettings.ini`.
It maxes at 1.0. `AudioDynamicRange` there is also worth trying before modding:
`TV` or `Midnight` compress the mix and may be enough on their own.

## Caveats

- Multiplayer uses EOS and PlayFab. An injected DLL is a terms of service
  question regardless of there being no anticheat. Treat this as single-player.
- Every reflection call is `pcall` guarded, so a wrong signature logs instead of
  crashing, but this writes to live audio objects in a running game.
