# SWGR Dialogue Mix

A UE4SS Lua mod that makes dialogue intelligible in STAR WARS: Galactic Racer by
ducking the submixes that mask speech, rather than by boosting speech itself.

## Try these before installing anything

The mod is the third thing to reach for, not the first.

**1. Change the dynamic range preset.** Options > Audio. The game ships four
dynamic range mixes (`CBM_DynamicRangeHeadphones`, `CBM_DynamicRangeMidnight`,
`CBM_DynamicRangeTV`, `CBM_DynamicRangeSoundSystem`) and the default is
`HomeCinema`, which is the widest. `TV` or `Midnight` compress the mix, which is
exactly the problem being solved here. On a racing game where engines and crowds
are what bury the voices, this alone may be enough.

**2. Push the speech slider past its maximum.** With the game closed, edit:

```
%LOCALAPPDATA%\StarWarsGalacticRacer\Saved\Config\Windows\GameUserSettings.ini
```

Under `[/Script/Griffin.GfnUserSettingsPC]`, change `DialogueVolume=1.000000` to
`2.000000`. The game may clamp it on load and rewrite the file, in which case
this does not work, but it costs nothing to find out.

If neither helps, install the mod.

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

## Caveats

- Multiplayer is present and uses EOS and PlayFab. An injected DLL is a terms of
  service question regardless of there being no anticheat. Consider this a
  single-player tool.
- The game reasserts its own mix when settings change or a control bus mix
  snapshot is pushed, so the mod re-applies on a 10 second timer. Expect the
  first second or two of a snapshot transition to use the game's levels.
- `SetSubmixOutputVolume` is called through a guarded `pcall`. The reflected
  signature is what matters, not the assumption about it, so verify against the
  Ctrl+F8 dump before relying on any of this.
