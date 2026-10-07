# SWGR Dialogue Mix

A UE4SS Lua mod that makes dialogue intelligible in STAR WARS: Galactic Racer by
ducking the submixes that mask speech, rather than by boosting speech itself.

## Install

```powershell
cd C:\temp\GIT\swgr-dialogue-mix
.\tools\install.ps1
```

The installer needs a UE4SS archive. It defaults to the Star Wars Zero Company
build in `~\Downloads`, which is a UE 5.6-configured 2026-09 build and the right
vintage for this game. Override with `-UE4SSZip <path>`.

Then launch the game and press:

| Key | Action |
| --- | --- |
| Ctrl+F8 | dump the live audio graph to `UE4SS.log` |
| Ctrl+F7 | apply the mix changes |
| Ctrl+F9 | restore authored levels |

Console commands are also registered: `dmx_dump`, `dmx_apply`, `dmx_reset`, and
`dmx_set Submixes/SS_Music 0.5` for live tuning without a restart.

To remove: `.\tools\uninstall.ps1 -All`.

## Tuning

Edit the `CONFIG` table at the top of
`Mods\DialogueMix\Scripts\main.lua`. Multipliers are relative to each submix's
authored `OutputVolume`, captured before the mod touches anything, so `1.0`
always means "as shipped".

```lua
duck = {
    ["Submixes/SS_Music"]                          = 0.60,
    ["Submixes/SS_Crowds"]                         = 0.65,
    ["Submixes/SS_HighSpeedAirflow"]               = 0.65,
    ["Submixes/SS_NonLocalPlayerEngineAndExhaust"] = 0.70,
    ["Submixes/SS_LocalPlayerEngine"]              = 0.75,
    ["Submixes/SS_LocalPlayerExhaust"]             = 0.75,
    ["Submixes/SS_Ambience"]                       = 0.80,
},
```

`dialogue_boost` defaults to `1.0`, meaning the voice submixes are left alone.
Raise it only if ducking is not enough, and expect diminishing returns: the game
runs `SE_Main_MixModeCompressor` on the main bus, so pushing voice above its
authored level feeds that compressor and drags the rest of the mix down
unevenly. Ducking the maskers buys the same intelligibility with no clipping and
no pumping.

Run Ctrl+F8 first and read the dump. It prints every loaded submix with its
parent, so you can see the real routing before trusting any multiplier. There
are six voice submixes and the parent chain decides which one is worth touching.

## Game audio architecture

Reconnaissance notes, so this does not have to be rediscovered.

**Engine.** Unreal Engine, project codename `Griffin`, shipping exe
`Griffin\Binaries\Win64\SWGR-Win64-Shipping.exe`. The version string is stripped
(`Auto-381121`), but CEF3 128.4.13 / Chromium 128, IoStore TOC version 8,
`NNERuntimeORT` and PCG put it at UE 5.6 or newer. UE4SS covers 5.4 through 5.8.

**No anticheat.** No EasyAntiCheat, no BattlEye. EOS SDK for online, PlayFab for
multiplayer sessions, Sentry for crash reporting. Worth knowing that an injected
DLL may surface in the developer's crash telemetry.

**Native Unreal audio, no middleware.** No Wwise, no FMOD. The exe confirms
`AudioModulation`, `SoundControlBus` and `MetasoundEngine`. This is what makes
the whole approach viable: everything is reachable through UObject reflection.

**Mix topology.** 61 SoundClasses in `/Game/Griffin/Audio/Mixing/Classes/`, 62
submixes in `Submixes/`, and a full Audio Modulation control bus layer:

- Voice classes: `SC_Voice`, `SC_Voice_Cinematic`, `SC_Characters_Vox`,
  `SC_DiegeticVoice`, `SC_NonDiegeticVoice`, `SC_Commentary`, `SC_Cinematic`
- Matching submixes under `Submixes/` with an `SS_` prefix
- Settings buses: `CB_Settings_DialogueVolume` plus Main, Music, Sfx and UI
  siblings, all bound to parameter `MP_Volume`, collected in `CBM_Settings`
- Per-submix buses: `CB_Submix*`, one per submix
- Gameplay ducking already exists: `CBM_InRaceVO`, `CBM_PreRaceVO_Ducking`,
  `CBM_Snapshot_Conversation`, `CBM_CrashReationVO_DuckCrashing`,
  `CB_KillInConversation`

`Griffin/Plugins/FuseMixingControl` is a MIDI control surface for the audio
team's dev builds (`BP_MIDIMixingControl`). It is not part of the runtime
settings path and does not interfere.

**Why the submix stage and not the control bus.** The in-game speech slider
drives `CB_Settings_DialogueVolume` through `MP_Volume`. Audio Modulation
parameters normalise to 0..1, so values above the slider maximum are likely to
be normalised away. `SetSubmixOutputVolume` and `USoundClass::Properties.Volume`
are separate, unclamped stages, which is why the mod works there.

**Paks are unencrypted.** Encryption key GUID is zero and container flags are
`Compressed | Indexed` with no `Encrypted` bit, so FModel opens
`Griffin\Content\Paks` with no AES key if you want to inspect the assets
directly.

## UE4SS version requirement

**This needs a UE4SS build with UE 5.6 support.** Older builds fail before any
Lua runs, with a signature scan that cannot find the engine internals:

```
UE4SS - v3.0.1 Beta
[PS] Failed to find GMalloc
[PS] Failed to find FName::ToString: found 2 unique values
[PS] Failed to find FUObjectHashTables::Get()
[PS] Failed to find GNatives
Fatal Error: PS scan timed out
```

If the log looks like that, the build is too old. `EngineVersionOverride` in
`UE4SS-settings.ini` does not help, because the problem is the scanner not
knowing the newer engine layouts, not a misreported version. Get a current
release from https://github.com/UE4SS-RE/RE-UE4SS/releases.

Packaging date is not a reliable signal here. A build repackaged in 2026 for a
different game can still contain a 2024-era DLL. Check the DLL, not the zip.

## Persistence

The mod does not fight the game for these values, and probably does not need to.

`SetSubmixOutputVolume` writes the base `OutputVolume`. The game's settings
sliders and `CBM_*` snapshots drive `OutputVolumeModulation`, a separate
modulation destination on the same submix. Both symbols exist in the exe as
distinct fields, and they are combined at mix time rather than overwriting one
another, so a control bus push should not clear our write.

Rather than assume that, the mod verifies it. Every `verify_seconds` it reads
the values back and re-applies only what actually moved, logging any drift. If
the log stays quiet across a few sessions, set `verify_seconds = 0` and the mod
becomes a single pass at startup. `dmx_verify` runs the check on demand.

True persistence without UE4SS at all would mean a pak that replaces the submix
assets outright. That is not a short path here: the exe contains no `~mods` or
`LogicMods` mount point in either ASCII or UTF-16, so there is no supported drop
folder, and cooking replacement assets would need a matching UE 5.6 editor.

## Caveats

- Multiplayer is present and uses EOS and PlayFab. An injected DLL is a terms of
  service question regardless of there being no anticheat. Consider this a
  single-player tool.
- `SetSubmixOutputVolume` is called through a guarded `pcall`. The reflected
  signature is what matters, not the assumption about it, so verify against the
  Ctrl+F8 dump before relying on any of this.
