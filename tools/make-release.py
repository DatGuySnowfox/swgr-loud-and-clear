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
DEFAULT_VERSION = "1.2.0"

MOD_README = """\
LOUD AND CLEAR
Dialogue you can actually hear.

A UE4SS Lua mod for STAR WARS: Galactic Racer. It boosts the dialogue sound
classes and ducks the music, crowds, airflow and engines that bury them.


ABOUT THE PANEL FREEZE, IF YOU READ ABOUT IT
--------------------------------------------
Earlier versions could freeze the game if the mix panel was open during a
cutscene. That is fixed in this one, and there is a second guard behind the fix.

What it was: the panel used to borrow one of the game's own widget blueprints
just to get a widget tree, then swap the tree's root out. That left a live
blueprint instance on screen running its own graph every frame against a tree it
no longer recognised. A memory dump taken at a freeze put the game's main thread
in the engine's blueprint bytecode interpreter with its stack pointer below its
own stack base, which is runaway recursion.

The panel now builds its own widget from engine classes only and touches no
blueprint at all. It has been tested with the panel deliberately opened and
closed eight times during a cutscene, which is what used to kill it.

There is also an optional cutscene guard, and in 1.2.1 it ships OFF. It keeps
the panel shut while a cutscene plays, which sounds sensible, but it counts any
playing level sequence as a cutscene and this game runs ambient idle animations
through the same system. In the paddock one of those plays constantly, so in
1.2.0 the panel could not be opened there at all, and the refusal is only
logged once so HOME looked like a dead key. That is what 1.2.1 fixes.

The crash it was written to contain was already fixed properly, by rebuilding
the panel host, and that fix was tested with this guard deliberately off through
eight opens inside a real cutscene. If you would rather have the guard anyway,
set this in the CONFIG block at the top of Scripts\\main.lua:

    cutscene_guard = true,

And to remove the panel and its timer entirely, keeping the mix:

    panel_enabled = false,

The mix itself has never been involved in any of this. It applies once on launch
and has run for days untouched.


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

   The folder contains enabled.txt, which is all UE4SS needs in order to
   load it. You do not have to edit mods.txt.

3. Launch the game. It applies itself a few seconds in, every launch.


UNINSTALLING
------------
Delete the LoudAndClear folder. Volume levels are the game's own again next
launch. Nothing else is touched. If you had also added a line to mods.txt by
hand, remove that too.


TUNING
------
Press HOME in game for the mix panel: nine sliders, voice level and each
competing channel, with a dB readout on every one. Changes apply as you drag,
so you hear them while you listen. Save keeps them for next launch.

Drag the sliders with the mouse and click the buttons. The panel takes the
cursor while it is open and hands it back when you close it.

For a read-only panel that never touches input focus, set this in CONFIG and
change values with the console commands instead:

    panel_grabs_input = false,

You can also edit the CONFIG block at the top of Scripts\\main.lua directly:

  class_boost   how much louder dialogue gets. 1.0 is untouched, 2.0 is twice
                as loud. Default 1.7.

  duck          how far each competing submix drops, as a multiplier of its
                normal level. Lower is quieter.

If you have the UE4SS console turned on, you can tune while the game runs:

  lac_set Submixes/SS_Music 0.45
  lac_reset

Those take effect immediately but are not saved, so put values you settle on
into main.lua.

Keys:     Ctrl+F7 re-apply, Ctrl+F8 dump the audio graph, Ctrl+F9 restore,
          Ctrl+F10 report whether a cutscene is detected
Commands: lac_apply, lac_reset, lac_set, lac_verify, lac_dump, lac_param,
          lac_forget, lac_cutscene


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

HOME does nothing during a cutscene. That is the guard described above, and the
log says so.

If the panel stops responding and will not close, restart the game. Deferred
work in UE4SS can stall, and when it does the panel cannot be closed from
in-game. If that happens to you, this helps and takes one line:

    ue4ss\\UE4SS-settings.ini
    DefaultExecuteInGameThreadMethod = ProcessEvent    (instead of EngineTick)


REPORTING A PROBLEM
-------------------
https://github.com/DatGuySnowfox/swgr-loud-and-clear/issues

Attach ue4ss\\UE4SS.log. If the game crashed outright, UE4SS usually writes its
own dump next to that log as crash_<date>.dmp, around 50 MB, and that is far
more useful than a description. No need for any extra tooling.


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
    ap.add_argument("--with-signatures", action="store_true",
                    help="also bundle the UE4SS AOB signatures "
                         "(off by default: they are UE4SS config, not mod files)")
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

        # Signatures are off by default. They are UE4SS configuration rather than
        # mod files, and bundling them invites someone to overwrite a working
        # UE4SS setup they did not need to touch. They live in the repo for
        # anyone who hits the scan failure described in the README.
        if args.with_signatures:
            for name in sorted(os.listdir(sig_src)):
                if name.endswith(".lua"):
                    rel = os.path.join("optional - UE4SS signatures", name)
                    z.write(os.path.join(sig_src, name), rel)
                    written.append(rel)
            z.writestr("optional - UE4SS signatures/README.txt",
                       SIG_README.replace("\n", "\r\n"))
            written.append("optional - UE4SS signatures/README.txt")

        z.writestr("README.txt", MOD_README.replace("\n", "\r\n"))
        written.append("README.txt")

    print("wrote %s  (%.0f KB)" % (out, os.path.getsize(out) / 1024))
    for rel in written:
        print("   " + rel.replace("\\", "/"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
