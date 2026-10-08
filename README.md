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
| **HOME** | **Open or close the mix panel** |
| Ctrl+F7 | Re-apply now |
| Ctrl+F8 | Dump the audio graph to `UE4SS.log` |
| Ctrl+F9 | Restore the game's own levels |
| Ctrl+F10 | Report whether a cutscene is detected, to `UE4SS.log` |
| Ctrl+R | Reload the mod after editing `main.lua` |

### The panel

Press `HOME` in game. You get nine sliders: voice level at the top, then the
seven channels that compete with it, each showing its live value in dB.

**Everything applies as you drag.** That is the only reason a panel beats the
console here: a mix is judged by ear, and a console round trip breaks that loop.
Only the sliders that moved are re-applied, so dragging does not push all nine
values at the engine ten times a second.

| Button | What it does |
| --- | --- |
| **Save** | Keeps the current values for future launches. Greyed out when there is nothing unsaved. |
| **Undo** | Back to the last saved values, discarding changes since. Greyed out when there is nothing to undo. |
| **Mod defaults** | Back to the values the mod ships with (1.7x voice, the dB cuts in the table above). Still needs Save to persist. |
| **Bypass** | A toggle. On means you hear the game's own unmodified mix. |
| **Close** | Closes the panel. `HOME` does the same. |

Mouse works, or arrow keys to move between buttons and Enter to activate.

**Use Bypass to decide whether a change is actually better.** Toggling between
your mix and the game's is the fastest way to tell, and far more reliable than
trying to remember what the previous value sounded like. Dragging any slider
lifts Bypass, since touching a slider means you want to hear your own mix again.

#### How to tune it

1. Open the panel somewhere with dialogue playing, paused or in a menu. The
   panel takes UI input focus, so the game will not take driving input while it
   is open.
2. Raise **Voice level** until speech is clearly audible. If it starts sounding
   harsh rather than louder, you are driving the compressor on the game's main
   bus; back it off and take the rest from the channels below.
3. Pull down whichever channel is actually masking the dialogue. Music and
   crowds are the usual culprits, airflow and engines during a race.
4. Hit **Bypass** twice to check you have improved things rather than just made
   them louder.
5. **Save**.

Engines below about 0.50 costs the racing noticeable weight, which is a real
trade rather than a free win.

#### Known issue: the panel could hang the game, and the fix is on probation

**The panel froze the game during cutscenes**, on close and also on open,
intermittently. The cause is identified and a fix is in, but the fix is reasoned
from a dump rather than proven by reproducing and then not reproducing a rare,
intermittent crash. Treat it as on probation.

**What the crash was.** A full-memory dump taken live at the freeze shows the
game's main thread with `RSP` at `0x400C90`, below its own stack base of
`0x401000`. That is a stack overflow, so the thread was recursing with no stop
condition. It was never a deadlock. `RIP` was
`SWGR-Win64-Shipping.exe+0x15FD1`, inside the function beginning at `+0x15F92`.

That function is `UObject::ProcessContextOpcode`, the engine's handler for the
Blueprint `Context` opcode, which is what runs when a Blueprint node dereferences
its target pin. Read out of the shipping binary rather than guessed at:

- It takes `(UObject*, FFrame&, void*, bool)` and clears `FFrame+0x30`,
  `MostRecentProperty`, as its first act.
- It zeroes a stack local, then inlines `FFrame::Step` into it: load a byte from
  `FFrame+0x20`, advance that pointer, call through a 256-entry table. The table
  is `GNatives`. Every slot in it reads as the same address on disk, which is
  the static initialiser to `execUndefined` before the runtime registrar
  overwrites it.
- It then tests bit 30 of the returned object's flags, `Unreachable`, and when
  the object is live advances the code pointer by 13 and steps again. Thirteen
  is `sizeof(CodeSkipSizeType)` plus `sizeof(FProperty*)` plus the opcode byte.
- It has exactly two direct callers in the image, matching the only two the
  engine has: `execContext` and `execContextFailSilent`.

Its prologue reserves `0x5D8` bytes, so a few hundred nested Blueprint calls are
enough to run the stack out. Reproduce the lookup with
`python tools/resolve-address.py <exe> 140015FD1`.

**What that ruled out.** The recursion is Blueprint bytecode. It is not Slate
layout, not input routing, and not Lua. Six hypotheses were implemented and
tested before the dump was resolved, and each one was about a native path:

| Hypothesis | Result |
| --- | --- |
| Nested `ExecuteInGameThread` | Real bug, fixed, crash recurred |
| Close ordering | Fixed, crash recurred |
| Per-toggle widget teardown | Build once and hide instead, crash recurred |
| Repaint call volume | Cut from 560/s to 230/s, crash recurred |
| Template conflict with another mod | That mod was not installed |
| Input mode and cursor calls | Removed entirely, crash recurred |
| Steam overlay interaction | Does not produce recursion through `GNatives` |

They failed because they were all looking in the wrong layer.

**The fix.** The panel's only contact with Blueprint code was its host. It used
to construct one of the game's own widget blueprints, `WBP_SectionSubLabel_C`,
purely because a Blueprint widget comes with a usable `WidgetTree`, then replaced
that tree's `RootWidget` with a canvas of its own. The cost was a live instance
of a game Blueprint class on screen, running its `PreConstruct`, `Construct` and
per-frame `Tick` against a tree it no longer recognised.

`Panel.lua` now builds a bare `/Script/UMG.UserWidget` and constructs its
`WidgetTree` by hand. Every widget in the panel comes from `/Script/UMG`, and
nothing in the file references `/Game` at all.

**And a second line of defence**, because one reasoned fix for an intermittent
crash is not the same as a proven one. The panel refuses to open while a cutscene
is playing, and closes itself if one starts while it is open. Detection is
`UMovieSceneSequencePlayer::IsPlaying` across every live sequence player.
`APlayerController::bCinematicMode` was tried first and is useless here: UE4SS
does not map engine bitfield bools, so reading it returns a `TrivialObject`
rather than `true` or `false`, and the original guard silently never fired.

That detection is a guess about how this game drives its cinematics, so verify
it rather than trusting it. Nothing needs running: while the panel is enabled,
the mod logs `cutscene started` and `cutscene ended` as they happen, so play
normally and then read `UE4SS.log`.

If no cutscene is ever reported while one is plainly on screen, the guard is
inert here and only the host rebuild is protecting you.

For an answer at a specific moment, **Ctrl+F10** writes the same report to the
log on demand, and `lac_cutscene` does it from the console for anyone who has one
turned on. Both print how many sequence players are live and whether any is
playing.

Set `log_cutscene_state = false` in `CONFIG` to stop the automatic logging once
the question is settled. It costs one object-array scan a second, and only while
`panel_enabled` is true.

**The guard is containment, not the fix**, and having it on means the fix never
gets exercised: the crash needs the panel open during a cutscene, and the guard
makes sure it never is. `cutscene_guard = false` in `CONFIG` turns the refusal
and the auto-close off, which is the only way to put the rebuilt host under the
condition it was written for. That is the condition that used to take the game
down, so save first.

Tracked at
[issue #1](https://github.com/DatGuySnowfox/swgr-loud-and-clear/issues/1). If it
recurs, a dump still helps, and there is now something specific to look for in
one: the committed part of the stack should be dense with repeated `FFrame`
structures, and `FFrame::Node` on each names the Blueprint function that is
recursing. Run
`procdump64.exe -h -e -ma -n 3 -w SWGR-Win64-Shipping.exe C:\temp\dumps` before
launching and attach what it captures.

To remove the panel and the 10 Hz timer behind it entirely, set
`panel_enabled = false` in `CONFIG` at the top of `main.lua`. The mix is
unaffected either way: it applies on launch, the console commands still work, and
the audio side alone has run for days without a hang.

#### Where settings go

Save writes to
`%LOCALAPPDATA%\StarWarsGalacticRacer\Saved\LoudAndClear-settings.txt`, which
loads over the `CONFIG` defaults on the next launch. That file is deliberately
separate from `baseline.txt`: one records what you chose, the other what the game
authored, and conflating them is how an earlier compounding bug got its chance.

Delete the settings file to go back to the shipped defaults permanently.

`panel_key` in `CONFIG` changes the binding. It defaults to `Key.HOME` rather
than `Key.INS` so it coexists with the Galactic FOV Panel mod.

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
| `lac_cutscene` | Same report as Ctrl+F10 |

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

`resolve-address.py` goes the other way: give it an address from a crash or a
dump and it names the enclosing function from the exe's exception directory, then
disassembles it. The game's section names are scrambled and the binary is about
490 MB, so this answers a one-address question in a second rather than waiting on
a full disassembler pass.

```powershell
python tools\resolve-address.py "<path to>\SWGR-Win64-Shipping.exe" 140015FD1
```

It also prints how much stack the function's prologue reserves, which is what
identified the panel hang as a stack overflow rather than a deadlock. Needs
`capstone` (`python -m pip install capstone`).

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
