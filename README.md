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

### Ducking is the only lever

`dialogue_boost` is pinned at `1.0` and cannot usefully be raised. The gain
buses run through `MP_Volume`, a `SoundModulationParameterVolume`, and dumping
its real properties shows exactly one range field:

```
[SoundModulationParameterVolume] FloatProperty MinVolume = -60.0
```

There is no `MaxVolume`, because for that parameter type **0 dB is both unity
and the ceiling**. It maps `[-60, 0]` dB onto `[0, 1]` normalised and clamps, so
a request of +3.52 dB (x1.5) or +6.02 dB (x2.0) normalises above 1.0 and comes
back as unity. Positive multipliers were silently doing nothing, which is why
x1.5 and x2.0 sounded identical. `bus_value_for` now clamps at 0 dB and says so
once rather than logging a gain the engine discards.

Ducking runs the other way and has the full 60 dB to work in, so all of the
intelligibility comes from the `duck` table. That happens to be the approach
worth taking anyway: the game runs `SE_Main_MixModeCompressor` on the main bus,
so lifting voice would feed that compressor and pump the rest of the mix.

Current depths, for reference when tuning:

| Submix | Multiplier | dB |
| --- | --- | --- |
| `SS_Music` | 0.60 | -4.44 |
| `SS_Crowds` | 0.65 | -3.74 |
| `SS_HighSpeedAirflow` | 0.65 | -3.74 |
| `SS_NonLocalPlayerEngineAndExhaust` | 0.70 | -3.10 |
| `SS_LocalPlayerEngine` | 0.75 | -2.50 |
| `SS_LocalPlayerExhaust` | 0.75 | -2.50 |
| `SS_Ambience` | 0.80 | -1.94 |

Run Ctrl+F8 and read the dump before trusting any multiplier. It prints every
loaded submix with its parent, every control bus with its parameter, and the
full property list of `CB_SubmixVoice` and `MP_Volume`. `dmx_param <relpath>`
does the same for any object on demand.

Gain on a parent submix is inherited by its children, so target parents only.
The routing that matters:

```
SS_DiegeticVoice    -> SS_Voice
SS_NonDiegeticVoice -> SS_Voice
SS_Voice            -> SS_Main
SS_Characters_Vox   -> SS_Characters   (separate branch)
```

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

## Hot reload

Lua mods reload without restarting the game. In `UE4SS-settings.ini`:

```ini
EnableHotReloadSystem = 1      ; Ctrl+R reloads all mods
HotReloadKey = R
EnableAutoReloadingLuaMods = 1 ; reload automatically on file save
```

Vortex-packaged UE4SS ships with both set to `0`, so turn them on. Note that
Vortex may revert its managed files on redeploy.

With auto-reload on, editing `main.lua` in the deployed
`ue4ss\Mods\DialogueMix\Scripts\` folder applies on save. Keep the repo copy in
step with `.\tools\install.ps1 -ModOnly`, or edit the repo and run that to push
the change over.

### Why baseline.txt exists

A reload hands the mod a fresh Lua state, so in-memory state is lost. That is a
problem for the authored submix volumes specifically: the submixes are still
ducked at reload time, so re-capturing from the live value would treat an
already-reduced volume as "authored" and multiply it again. `SS_Music` at 0.60
would walk down to 0.36, then 0.216, across three reloads.

So the first capture is written to `baseline.txt` next to the script and read
back on load. Re-applying then becomes idempotent, which also makes the startup
pass safe to run repeatedly.

Run `dmx_forget` to discard it and re-capture, which resets the submixes to
their stored values first. Worth doing after a game patch, since a patch can
change the authored volumes and make the stored file stale.

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
