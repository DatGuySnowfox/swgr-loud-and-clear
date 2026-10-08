# Changelog

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
