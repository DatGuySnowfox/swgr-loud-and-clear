"""Package the mod for upload, without any UE4SS binaries.

    python tools/make-release.py
    python tools/make-release.py --version 1.1.0

Produces dist/LoudAndClear-<version>.zip containing the mod folder at the archive
root, so it drops straight into ue4ss\\Mods, plus the AOB signatures as a clearly
separated optional extra.

The signatures are included because a stock UE4SS build may not locate this
game's engine internals on its own, and the ones some packages ship hardcode
addresses valid for a single build. These find their targets by content, so if a
game patch moves things they fail to match and UE4SS refuses to start, which is
the safe outcome rather than resolving to a wrong address.

No UE4SS.dll, no dwmapi.dll, nothing licensed by anyone else.
"""
import argparse
import os
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_VERSION = "1.0.1"

MOD_README = """\
LOUD AND CLEAR
Dialogue you can actually hear.

A UE4SS Lua mod for STAR WARS: Galactic Racer. It boosts the dialogue sound
classes and ducks the music, crowds, airflow and engines that bury them.


REQUIREMENTS
------------
UE4SS with Unreal Engine 5.6 support. This matters. Older builds fail before any
of this loads, with a signature scan that cannot find the engine internals.

Packaging date is not a reliable signal: a package rebuilt recently for a
different game can still contain a two year old DLL. Check the DLL itself.


INSTALLING
----------
1. Install UE4SS into:
       STAR WARS Galactic Racer\\Griffin\\Binaries\\Win64

   You should end up with dwmapi.dll and a "ue4ss" folder sitting next to
   SWGR-Win64-Shipping.exe.

2. Copy the "LoudAndClear" folder from this archive into:
       ...\\Griffin\\Binaries\\Win64\\ue4ss\\Mods

3. Add this line to ue4ss\\Mods\\mods.txt:
       LoudAndClear : 1

4. Launch the game. It applies itself a few seconds in, every launch.


UNINSTALLING
------------
Delete the LoudAndClear folder and remove its line from mods.txt. Volume levels
are the game's own again next launch. Nothing else is touched.


TUNING
------
Open Scripts\\main.lua and edit the CONFIG block at the top.

  class_boost   how much louder dialogue gets. 1.0 is untouched, 2.0 is twice
                as loud. Default 1.7.

  duck          how far each competing submix drops, as a multiplier of its
                normal level. Lower is quieter.

You can also tune while the game runs, using the UE4SS console:

  lac_set Submixes/SS_Music 0.45
  lac_set Submixes/SS_Vehicles 0.55
  lac_reset

Those take effect immediately but are not saved, so put values you settle on
into main.lua.

Keys:     Ctrl+F7 re-apply, Ctrl+F8 dump the audio graph, Ctrl+F9 restore
Commands: lac_apply, lac_reset, lac_set, lac_verify, lac_dump, lac_param,
          lac_forget


PLEASE NOTE
-----------
Tested in game, but not through full races. The game pushes its own mix changes
during a race, and how those interact with these settings is unverified.
Feedback from actual racing is welcome.

I can't guarantee fixes if a game update breaks this. That is why it is open
source.

Treat this as single player. There is no anticheat, but an injected DLL is a
terms of service question regardless.


TROUBLESHOOTING
---------------
Everything is logged to ue4ss\\UE4SS.log. A healthy launch looks like:

    PS scan successful
    Starting Lua mod 'LoudAndClear'
    audio graph is up after 6s, applying
    class SC_Voice  1.000 -> 1.700  (x1.70, verified)
    applied: 7/7 buses ducked, 2/2 class volumes boosted

No LoudAndClear lines at all, with "PS scan timed out" or "Failed to find
GMalloc" above them, means the UE4SS build is too old for this game.

A fatal error naming another game's executable means that package left
game-specific signature files behind. See the optional folder in this archive.

Dialogue unchanged but the log says "verified": sound class volume is sampled
when a line starts, so a line already playing will not change. Trigger a new one.


SOURCE
------
https://github.com/DatGuySnowfox/swgr-loud-and-clear

The repo has the full notes on this game's audio layout, which stages respond
and which do not, and tools to check whether a game update broke anything.
"""

SIG_README = """\
OPTIONAL: UE4SS AOB SIGNATURES
==============================

You probably do not need these. Try the mod on its own first.

Use them if UE4SS fails to start on this game, with a log like:

    [PS] Failed to find GMalloc
    [PS] Failed to find FName::ToString: found 2 unique values
    Fatal Error: PS scan timed out

UE4SS locates the engine by scanning the executable for byte patterns. Some
builds cannot find this game's internals on their own.


INSTALLING
----------
Copy the four .lua files into:

    ...\\Griffin\\Binaries\\Win64\\ue4ss\\UE4SS_Signatures

Replace what is there, keeping a backup. If UE4SS was already working for you,
back the originals up first so you can go back.


WHY THESE RATHER THAN WHAT CAME WITH YOUR UE4SS
-----------------------------------------------
Some packages ship signature files that look like this:

    local ImageBase = MatchAddress - 0x238D414
    return ImageBase + 0xAB747C8

That derives the image base from one anchor and then jumps to a hardcoded
address, which is valid for exactly one build of the game. The anchor is a
distinctive sequence that occurs once, so after a game patch it will very likely
still match. UE4SS then reports a successful scan and hands the engine a wrong
pointer, which crashes rather than failing cleanly.

The files here find their targets by content and resolve relatively, so a patch
that moves code does not silently produce a wrong address. If a pattern stops
matching, UE4SS fails its scan and refuses to start, which is the safe outcome.


ALSO WORTH CHECKING
-------------------
If UE4SS starts and then dies with an error naming a different game's
executable, for example:

    Fatal Error: [SWZC StaticConstructObject] cannot read adjacent
    SWZeroCompany.exe

then that folder contains signature overrides from another game's package. They
hard-reject when their own executable is absent. Move them out of the folder.
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", default=DEFAULT_VERSION)
    ap.add_argument("--outdir", default=os.path.join(ROOT, "dist"))
    args = ap.parse_args()

    os.makedirs(args.outdir, exist_ok=True)
    out = os.path.join(args.outdir, "LoudAndClear-%s.zip" % args.version)

    mod_src = os.path.join(ROOT, "Mods", "LoudAndClear")
    sig_src = os.path.join(ROOT, "Signatures")
    if not os.path.isdir(mod_src):
        print("mod source missing: %s" % mod_src)
        return 2

    written = []
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for folder, _dirs, files in os.walk(mod_src):
            for name in sorted(files):
                # baseline.txt is runtime state, never ship it: it would hand a
                # new user someone else's captured volumes.
                if name == "baseline.txt":
                    continue
                full = os.path.join(folder, name)
                rel = os.path.relpath(full, os.path.dirname(mod_src))
                z.write(full, rel)
                written.append(rel)

        for name in sorted(os.listdir(sig_src)):
            if name.endswith(".lua"):
                rel = os.path.join("optional - UE4SS signatures", name)
                z.write(os.path.join(sig_src, name), rel)
                written.append(rel)

        z.writestr("README.txt", MOD_README.replace("\n", "\r\n"))
        z.writestr("optional - UE4SS signatures/README.txt",
                   SIG_README.replace("\n", "\r\n"))
        written += ["README.txt", "optional - UE4SS signatures/README.txt"]

    print("wrote %s  (%.0f KB)" % (out, os.path.getsize(out) / 1024))
    for rel in written:
        print("   " + rel.replace("\\", "/"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
