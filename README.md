# Loud and Clear

A UE4SS Lua mod for STAR WARS: Galactic Racer that makes dialogue intelligible
during races. It boosts the dialogue sound classes and ducks the music, crowds,
airflow and engines that bury them.

Defaults: dialogue at **1.7x**, maskers cut by **1.9 to 4.4 dB**. Both tunable,
live, without restarting the game.

## Install

Needs a UE4SS build with UE 5.6 support. See
[UE4SS fails to start](#ue4ss-fails-to-start) if yours is older, because that was
the single biggest time sink in building this.

```powershell
git clone https://github.com/DatGuySnowfox/swgr-loud-and-clear
cd swgr-loud-and-clear
.\tools\install.ps1
```

The installer finds the game under Steam, deploys UE4SS if it is not already
there, copies the mod, registers it in `mods.txt` and `mods.json`, and installs
the AOB signatures from `Signatures/`.

| Flag | Effect |
| --- | --- |
| `-ModOnly` | Refresh just the Lua and signatures. Use after editing config. |
| `-Force` | Replace an existing UE4SS deployment, backing the old one up. |
| `-GamePath <dir>` | Non-default install location. |
| `-UE4SSZip <file>` | Point at a specific UE4SS archive. |

Remove with `.\tools\uninstall.ps1`, or `-All` to take UE4SS out too.

## Using it

It applies itself a few seconds after the audio graph comes up, every launch.
Nothing to press for the normal behaviour.

| Key | Action |
| --- | --- |
| Ctrl+F7 | Re-apply now |
| Ctrl+F8 | Dump the audio graph to `UE4SS.log` |
| Ctrl+F9 | Restore the game's own levels |
| Ctrl+R | Reload the mod after editing `main.lua` |

Console commands, with the console enabled via `ConsoleEnabled = 1` in
`UE4SS-settings.ini`:

| Command | Action |
| --- | --- |
| `lac_apply` / `lac_reset` | Apply, or restore the game's levels |
| `lac_set <relpath> <mult>` | Change one submix live |
| `lac_verify` | Read the class volumes back and check they hold |
| `lac_dump` | Dump the audio graph |
| `lac_param <relpath>` | Print every property on an object |
| `lac_forget` | Discard stored authored volumes and re-capture |

`lac_set` is the fast way to tune by ear, no reload needed:

```
lac_set Submixes/SS_Music 0.45
lac_set Submixes/SS_Vehicles 0.55
```

It reaches anything in `CONFIG.bus_for`. Changes are not saved, so put values you
settle on into `main.lua`.

## Tuning

Both dials are in the `CONFIG` table at the top of
`Mods\LoudAndClear\Scripts\main.lua`.

**Dialogue level.** `class_boost`, a linear multiplier on the dialogue sound
classes. `1.0` is untouched, `2.0` is twice as loud. This is the dial for "I
still cannot hear them". Pushing it far feeds the compressor on the game's main
bus and starts pumping the rest of the mix, so if high values sound harsh rather
than louder, take some of it from the duck table instead.

**Separation.** The `duck` table, as multipliers of each submix's authored level,
converted to dB internally:

| Submix | Multiplier | dB |
| --- | --- | --- |
| `SS_Music` | 0.60 | -4.44 |
| `SS_Crowds` | 0.65 | -3.74 |
| `SS_HighSpeedAirflow` | 0.65 | -3.74 |
| `SS_NonLocalPlayerEngineAndExhaust` | 0.70 | -3.10 |
| `SS_LocalPlayerEngine` | 0.75 | -2.50 |
| `SS_LocalPlayerExhaust` | 0.75 | -2.50 |
| `SS_Ambience` | 0.80 | -1.94 |

There is 60 dB of range, so these can go much deeper. Engines below about 0.50
costs the racing noticeable weight, which is a real trade rather than a free win.

After editing, run `.\tools\install.ps1 -ModOnly` then Ctrl+R in game.
`EnableAutoReloadingLuaMods = 1` often reloads on save by itself, but the watcher
is inconsistent, so do not rely on it.

## How it works

Volume is reachable at several stages here and only two of them do anything.

**Sound class volume, for boosting.** `FSoundClassProperties::Volume` is a plain
float with no unity ceiling, applied to `SC_Voice` and `SC_Characters_Vox`. It
reads back, so the mod writes it, reads it, and logs `verified` rather than
assuming the write landed.

**Control buses, for ducking.** Each submix's gain comes from its
`OutputVolumeModulation` destination, driven by a `CB_Submix*` bus through
`UAudioModulationStatics::SetGlobalBusMixValue`. Values are in decibels, so
multipliers convert with `20*log10`.

### Why a bus cannot boost

The buses run through `MP_Volume`, a `SoundModulationParameterVolume`. Dumping
its real properties shows exactly one range field:

```
[SoundModulationParameterVolume] FloatProperty MinVolume = -60.0
```

No `MaxVolume`, because 0 dB is both unity and the ceiling for that parameter
type: it maps `[-60, 0]` dB onto `[0, 1]` normalised and clamps. A request of
+3.52 dB or +6.02 dB normalises above 1.0 and comes back as unity, so a bus boost
is silently discarded while a bus cut has the full 60 dB available. This is
arithmetic inside the parameter, not an access restriction, so a native DLL would
hit the same clamp.

### The stage that does nothing

Writing submix `OutputVolume` via `SetSubmixOutputVolume` accomplishes nothing.
The call succeeds, but the property reads back as `nil` on all 62 submixes and
nothing changes audibly, because the modulation destination drives the gain
instead. That path was in the mod originally and has been removed.

### Routing

Gain on a parent is inherited, so targeting a parent and its children compounds
the change. Target parents only:

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

A hot reload or a restart hands the mod a fresh Lua state while the classes are
still boosted. Without the file it would read the boosted value back as the
authored one and multiply again, walking 1.7 to 2.9 to 4.9 across three reloads.
Saving the first capture makes re-applying idempotent.

It lives in the save directory because the mod folder is under Program Files,
which is not writable without elevation.

Run `lac_forget` to discard it and re-capture. Worth doing after a game patch,
which can change the authored values and leave the file stale.

## After a game update

Nothing makes AOB scanning immune to patches, but the layers fail differently.

The mod's own Lua is durable: it resolves assets by name, guards every reflection
call, and logs what is missing. A content reorganisation makes it stop working,
not crash.

The signatures are the fragile layer, and three of the four files that UE4SS
packages commonly ship are actively dangerous:

```lua
local ImageBase = MatchAddress - 0x238D414   -- assume anchor sits at this RVA
return ImageBase + 0xAB747C8                 -- then a hardcoded absolute RVA
```

Those RVAs are valid for exactly one build. The anchor is a distinctive sequence
occurring exactly once, so after a patch it will very likely **still match**,
UE4SS reports a successful scan, and the engine gets a wrong pointer. That
crashes rather than erroring.

`Signatures/` replaces them with patterns that find the same targets by content
and resolve relatively. Verified equivalent on the reference build:

| Signature | Matches | Resolves to | Old hardcoded value |
| --- | --- | --- | --- |
| `GMalloc` | 3, all agreeing | `0xAB747C8` | `0xAB747C8` |
| `FName_ToString` | 1 | `0x3752404` | `0x3752404` |
| `FName_Constructor` | 1 | `0x3C7DB26` | `0x3C7DB26` |
| `GUObjectArray` | 1 | `0xAC5E910` | already relative |

`GMalloc` matching three sites is a feature: UE4SS dedupes by resolved value, so
three agreeing sites means two can disappear and it still works.

### This has now been tested by a real patch

Steam build `25801363` (2026-10-08) changed the executable from 488,290,328 to
490,551,832 bytes. The content-based patterns found all four targets. The
address-based files would not have:

| Signature | Old files would give | Actually is | Result |
| --- | --- | --- | --- |
| `FName_ToString` | `0x3752404` | `0x3752AF4` | wrong by `0x6F0` |
| `FName_Constructor` | `0x3C7DB26` | `0x3C7E216` | wrong by `0x6F0` |
| `GMalloc` | `0xAB747C8` | `0xAB747C8` | correct |

Note what makes this the bad case rather than an obvious one: the anchor did not
move, so the old files would have computed the correct image base, then jumped
0x6F0 bytes short of both functions into the middle of other code. UE4SS would
have reported a successful scan and crashed.

The mod's own asset paths and all seven ducked submixes survived the patch
untouched.

Before launching after a patch:

```powershell
.\tools\check-after-update.ps1       # exe fingerprint, foreign overrides, settings
python tools\check-signatures.py     # do the patterns still resolve cleanly
```

`check-signatures.py` reads the patterns out of `Signatures/*.lua`, scans the
installed exe, and reports what UE4SS would accept. Exit code 1 means do not
launch. Reference fingerprints are in `tools/known-build.json`.

If a pattern stops matching, UE4SS fails its scan and refuses to start, which is
the safe failure. Recovery, in order: get a UE4SS build matching the new engine
version, delete the affected file so the generic scanner tries instead, or remove
the mod with `uninstall.ps1 -All`.

Steam updates generally leave `dwmapi.dll` and `ue4ss/` alone, since they are not
in the game manifest. Vortex is the likelier culprit: redeploying it can restore
foreign signature overrides and reset `UE4SS-settings.ini`.

## Troubleshooting

Everything is logged to `ue4ss\UE4SS.log`. A healthy launch:

```
PS scan successful
Starting Lua mod 'LoudAndClear'
restored 2 authored class volumes
audio graph is up after 6s, applying
class SC_Voice  1.000 -> 1.700  (x1.70, verified)
applied: 7/7 buses ducked, 2/2 class volumes boosted
```

**Dialogue level does not change** but the log says `verified`: class volume is
sampled when a voice starts, so a line already playing when you reload will not
change. Trigger a new one.

**`0/2 class volumes`, or a line saying the value did not stick:** the names or
paths are wrong. Ctrl+F8 shows what is actually loaded.

<a id="ue4ss-fails-to-start"></a>

**UE4SS fails to start**, with no `LoudAndClear` lines at all:

```
[PS] Failed to find GMalloc
[PS] Failed to find FName::ToString: found 2 unique values
Fatal Error: PS scan timed out
```

The build is too old for this engine version. `EngineVersionOverride` will not
help, because the problem is a scanner that does not know the newer layouts.
Packaging date is not a reliable signal: a Vortex or Nexus package rebuilt in
2026 for another game can still contain a 2024 DLL, so check the DLL itself.

**UE4SS starts then dies naming another game's executable:**

```
Fatal Error: [SWZC StaticConstructObject] cannot read adjacent SWZeroCompany.exe
```

Game-specific AOB overrides left in `ue4ss/UE4SS_Signatures/` from another game's
package. They hard-reject when their own exe is absent. Move them out of that
folder; `install.ps1` quarantines them automatically.

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
per submix, settings buses (`CB_Settings_DialogueVolume` plus Main, Music, Sfx
and UI siblings) all bound to `MP_Volume`, and gameplay mixes including
`CBM_InRaceVO`, `CBM_PreRaceVO_Ducking` and `CBM_Snapshot_Conversation`.

`Griffin/Plugins/FuseMixingControl` is a MIDI control surface for the audio
team's dev builds, not part of the runtime settings path.

**Paks are unencrypted.** Encryption key GUID is zero, container flags are
`Compressed | Indexed`, so FModel opens `Griffin\Content\Paks` with no AES key.

**In-game settings.** The options menu has a speech slider (`DA_SpeechVolume`),
stored as `DialogueVolume` under `[/Script/Griffin.GfnUserSettingsPC]` in
`%LOCALAPPDATA%\StarWarsGalacticRacer\Saved\Config\Windows\GameUserSettings.ini`,
capped at 1.0. `AudioDynamicRange` in the same file selects between the
`CBM_DynamicRange*` mixes, and `TV` or `Midnight` compress the mix.

## Caveats

- **Tested in game, but not through full races.** The game pushes its own mix
  changes during a race (`CBM_InRaceVO`, `CBM_PreRaceVO_Ducking`,
  `CBM_Snapshot_Conversation` and others), and how those interact with these
  settings is unverified. `lac_verify` after a few races is the way to find out:
  it reports whether the class volumes still hold.
- **No guarantee of fixes after a game update.** UE4SS finds the engine by
  scanning for byte patterns and a patch can move them. That is why this is open
  source, and why `check-signatures.py` and `check-after-update.ps1` exist: so
  the next person can tell what broke and fix it without starting over.
- Multiplayer uses EOS and PlayFab. An injected DLL is a terms of service
  question regardless of there being no anticheat. Treat this as single-player.
- Every reflection call is `pcall` guarded, so a wrong signature logs instead of
  crashing, but this writes to live audio objects in a running game.
