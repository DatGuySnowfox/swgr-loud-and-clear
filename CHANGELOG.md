# Changelog

## 1.3.0 — 2026-10-08

### Fixed

- **The panel hang is identified and the cause is removed.** A full-memory dump
  taken live at a freeze put the game's main thread at `RSP 0x400C90`, below its
  own stack base of `0x401000`. That is a stack overflow from unbounded
  recursion, not a deadlock. `RIP` resolved to `UObject::ProcessContextOpcode`,
  the engine's handler for the Blueprint `Context` opcode, so the recursion was
  Blueprint bytecode.

  The panel's only contact with Blueprint code was its host. It constructed one
  of the game's own widget blueprints, `WBP_SectionSubLabel_C`, purely to get a
  usable `WidgetTree`, then replaced that tree's `RootWidget`. That left a live
  instance of a game Blueprint class on screen running its `PreConstruct`,
  `Construct` and per-frame `Tick` against a tree it no longer recognised.

  `Panel.lua` now builds a bare `/Script/UMG.UserWidget` and constructs its
  `WidgetTree` by hand. Nothing in the file references `/Game`.

  This is reasoned from the dump, not demonstrated by reproducing the crash and
  then failing to reproduce it, because it is rare and intermittent. The panel is
  back on by default but on probation.

- **The cutscene guard works now.** The 1.1.4 guard read
  `APlayerController::bCinematicMode`, which UE4SS cannot map because it is an
  engine bitfield bool, so it returned a `TrivialObject` and the comparison was
  never true. It now checks `UMovieSceneSequencePlayer::IsPlaying` across every
  live sequence player, which is a plain `BlueprintPure` bool. The panel refuses
  to open during a cutscene and closes itself if one starts while it is open.

### Added

- **Cutscene starts and ends are logged automatically** while the panel is
  enabled, so confirming the guard can see this game's cinematics needs nothing
  but playing and then reading `UE4SS.log`. Turn it off with
  `log_cutscene_state = false` once that is settled.

- **Ctrl+F10** writes the same report on demand, and `lac_cutscene` does it from
  the console. The console is off by default in UE4SS, so the key is the one that
  works without changing any settings.

- `cutscene_guard` in `CONFIG`, default true. With the guard on the panel is
  never open during a cutscene, which also means the host rebuild above never
  gets tested, because the crash needs the panel open during one. Setting it
  false is the only way to put the fix under the condition it was written for.

- `tools/resolve-address.py` resolves an address in the shipping executable to
  its enclosing function and disassembles it, reading the PE exception directory
  rather than disassembling the whole image. The exe is about 490 MB with roughly
  430 MB marked executable, so a full IDA auto-analysis pass takes hours to
  answer a one-address question; this takes a second. It also reports the
  prologue's stack reservation, which is what turned a stack overflow into a
  frame count.

## 1.2.0 — 2026-10-08

### Changed

- **The panel ships disabled.** It had crashed on open as well as on close, and
  with the input grab removed entirely, so there was no configuration left to
  recommend. The mix is unaffected and had run for days without a hang.

### Fixed

- Removed the input-mode and cursor calls behind `panel_grabs_input`, testing
  whether taking exclusive UI input was the trigger. It was not: the crash
  recurred with them gone.

## 1.1.8 — 2026-10-08

### Fixed

- **The panel repaints only when something visible changed.** It had been
  rebuilding every row ten times a second, roughly forty-five reflected
  UFunction calls per tick through UE4SS's hook, for a panel that mostly sits
  still. Call volume dropped from about 560 a second to about 230. The crash
  recurred, so call volume was not the cause, but the cost was not worth paying
  either way.

## 1.1.7 — 2026-10-08

### Fixed

- **The panel is built once and hidden on close**, rather than torn down and
  rebuilt on every toggle. Constructing and destroying forty-odd widgets per
  toggle was the largest object-lifetime churn the mod produced, and
  `RemoveFromParent` now happens only on a level change. The crash recurred.

- **The 10 Hz panel loop runs only while the panel is open.** It previously ran
  from startup for the whole session. Idle cost is now the 1 Hz verify loop
  alone.

## 1.1.5 — 2026-10-08

### Known issue

- **The panel can hang the game**, including a few seconds after a clean close.
  Three occurrences, intermittent, cause not established. Tracked as
  [issue #1](https://github.com/DatGuySnowfox/swgr-loud-and-clear/issues/1).

  Workaround: `panel_enabled = false` in `CONFIG`, which also removes the 10 Hz
  loop behind the panel. The mix is unaffected and has run for a day without a
  hang.

  A 6.8 GB hang dump shows the main thread blocked and 34 of 154 threads
  carrying UE4SS frames, 32 parked in one identical wait. Suggestive, not proof,
  since idle workers look the same. The capture was of a stall the game recovered
  from, not the fatal hang.

### Fixed

- The cinematic guard added in 1.1.4 never worked. `pc.bCinematicMode` returns
  `TrivialObject: ...` rather than a boolean, because UE4SS does not map bitfield
  bools through plain indexing, so the comparison was never true and the panel
  opened during cutscenes regardless. Logging the value is what caught it.

- `tools/toggle-mod.ps1` only touched `mods.txt`, so toggling off did nothing:
  `enabled.txt` in the mod folder loads a mod on its own, and `mods.json` carries
  its own flag. It now handles all three and reports each with a verdict. This
  had already invalidated one A/B test.

## 1.1.3 — 2026-10-08

### Fixed

- **Removed a nested `ExecuteInGameThread`.** The panel calls apply and reset
  from inside its own game-thread callback, and both of those wrapped themselves
  in another `ExecuteInGameThread`. That asks the game thread to schedule work
  for the game thread while it is busy running ours, which is a deadlock waiting
  for the right timing, and a deadlock is what a freeze looks like. Split into
  `apply_now` / `reset_now` for callers already on the game thread, with thin
  wrappers for keybinds, console commands and the startup poll.

- **Restore input mode before removing the widget, not after.** The old order
  removed a focused widget and only then stopped routing input to the UI, which
  leaves the engine briefly resolving focus to a widget no longer in the
  hierarchy.

### Added

- `panel_grabs_input` and `panel_enabled` in `CONFIG`. The first drops the input
  mode and cursor calls entirely, leaving a keyboard-driven panel; the second
  removes the panel without touching the audio side.

- Step logging through panel open and close. A freeze leaves no crash dump and
  closing logged nothing at all, so there was no way to tell how far it got.

### Known issue

- Closing the panel froze the game once, opened during a cutscene. Cause not
  established. The changes above remove the two mechanisms most likely to be
  responsible and make the next occurrence diagnosable. Until then, open the
  panel paused or in a menu rather than mid-cutscene.

## 1.1.2 — 2026-10-08

### Changed

- **Reworked the panel buttons, which were ambiguous and one was mislabelled.**
  "Defaults" restored the *game's* mix rather than the mod's shipped values, and
  sat next to "Revert", so two of four buttons read as variations of "go back".

  Now five, in two rows grouped by what they touch. Values: **Save**, **Undo**
  (back to last saved), **Mod defaults** (the values the mod ships with). Mode:
  **Bypass**, **Close**.

- **Bypass is a toggle rather than a one-shot.** Switching between your mix and
  the game's is how you tell whether a change is an improvement or just louder,
  and that comparison is the whole job. The latched state shows on the button
  and in the status line. Dragging any slider lifts it, since touching a slider
  means wanting your own mix back.

### Fixed

- The startup poll undid Defaults a tick after it ran. One flag was answering
  two questions: whether the startup apply had happened, and whether our mix is
  in effect. Reset cleared it, so the poll re-applied everything. Split into
  `started` and `applied`, and the verify pass now returns early when not
  applied, since re-applying drift would have undone the choice more slowly.

### Documentation

- Panel instructions in the README and on the mod page: what each button does,
  a tuning walkthrough, and the two things worth knowing (pushing voice too far
  drives the main bus compressor; engines below about 0.50 costs the racing
  noticeable weight).

## 1.1.0 — 2026-10-08

### Added

- **An in-game mix panel, on `HOME`.** Nine live sliders, voice level and the
  seven duck channels, each with a dB readout, plus Save, Revert, Defaults and
  Close. Mouse or arrow keys and Enter.

  Everything applies as you drag. That is the point: mix values are judged by
  ear, and a console round trip breaks that loop. Only sliders that actually
  moved are re-applied, so dragging does not push all nine values at the engine
  ten times a second.

  It is native UMG built at runtime from Lua, not ImGui and not C++. A host
  widget is created from one of the game's own blueprints to get a usable
  `WidgetTree`, which is then populated with `StaticConstructObject` on engine
  UMG classes. The technique is borrowed from the Galactic FOV Panel mod, which
  proved it works in this game.

- **Saved settings.** The panel writes to its own settings file, layered over
  the `CONFIG` defaults at startup, so tuning survives a restart without editing
  Lua. Kept separate from `baseline.txt` on purpose: one records what you chose,
  the other what the game authored.

- **Level-transition handling**, which the mod never had.
  `RegisterLoadMapPreHook` closes the panel and bumps an epoch that in-flight
  work checks before touching anything, because widgets do not survive a map
  change and queued work must not run against the new world.

### Fixed

- A capture guard against compounding. If the stored baseline goes missing while
  the game is running, the next capture reads this mod's own output back as the
  authored value and multiplies it again. That happened: the baseline was moved
  aside with the game up, a reload followed, and `SC_Voice` went to 2.890 with a
  baseline claiming 1.700 was authored. Capture now checks the value against
  `expected_class_volume` and refuses loudly rather than compounding.

---

## 1.0.1 — 2026-10-08

**Compatible with the 8 October game patch (Steam build `25801363`).** No changes
to the mod were needed for it. The mod's target sound classes and all seven
ducked submixes survived the patch untouched.

That patch did move two of the addresses UE4SS uses to find the engine. The AOB
signatures in this repo followed them. The address-based ones that ship with some
UE4SS packages would not have:

| Signature | Those would give | Actually is | Result |
| --- | --- | --- | --- |
| `FName_ToString` | `0x3752404` | `0x3752AF4` | wrong by `0x6F0` |
| `FName_Constructor` | `0x3C7DB26` | `0x3C7E216` | wrong by `0x6F0` |
| `GMalloc` | `0xAB747C8` | `0xAB747C8` | correct |

The anchor those files key off did not move, so they would have computed a
correct image base and then jumped `0x6F0` bytes short of both functions, into
the middle of other code, while UE4SS reported a successful scan. If UE4SS
started crashing for you after this patch, that is why, and `Signatures/` is the
fix.

### Changed

- **The audio graph dump no longer runs on every launch.** It swept several
  hundred objects of reflection at startup, enumerating every loaded submix,
  sound class and control bus and then walking class hierarchies property by
  property. It existed to work out the audio routing, which is done and written
  up in the README. `Ctrl+F8` and `lac_dump` still run it on demand.

  This followed a crash whose dump faulted inside UE4SS's Lua runtime. That was
  not proven to be the cause, but the sweep was by far the largest surface the
  mod touched and had no business running in normal use.

- **The download no longer bundles the UE4SS AOB signatures.** They are UE4SS
  configuration rather than mod files, and shipping them invites overwriting a
  working UE4SS setup that never needed touching. They remain in the repo under
  `Signatures/` for anyone who hits the scan failure above. `make-release.py
  --with-signatures` puts them back in a build.

### Fixed

- `check-after-update.ps1` walked the 490 MB executable byte by byte in
  PowerShell, roughly 490 million iterations, to verify a single anchor. It now
  delegates to `check-signatures.py`: about two seconds, and it resolves all four
  signatures rather than only confirming an anchor still exists. An anchor that
  still matches on a changed binary is exactly the case that looks fine and is
  not.

---

## 1.0.0 — 2026-10-07

Initial release. Boosts the dialogue sound classes to 1.7x and ducks music,
crowds, airflow, engines and ambience by 1.9 to 4.4 dB.

### Notes from building it

Recorded because several were wrong turns worth not repeating.

Three gain stages were tried before one worked. **Submix `OutputVolume`** does
nothing in this game: the call succeeds, but the property reads back as `nil` on
all 62 submixes, because gain comes from the `OutputVolumeModulation` destination
instead. **Control buses** work, but only downwards: they run through
`MP_Volume`, a `SoundModulationParameterVolume` whose only range field is
`MinVolume = -60.0`, so 0 dB is unity *and* the ceiling and positive requests come
back as unity. That is why asking for 1.5x and 2.0x sounded identical. **Sound
class volume** is a plain float with no ceiling, and it reads back, so writes can
be verified rather than assumed.

Other things that bit: a drift check that read a `nil` property, skipped, and
then reported everything unchanged, so it could never fail; authored volumes held
only in memory, so a reload read the boosted value back as authored and
compounded 1.7 to 2.9 to 4.9; inherited gain applying three times when a parent
submix and both its children were targeted; and `lac_set` writing the inert stage,
so the live tuning command did nothing at all.
