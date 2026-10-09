--[[
    Loud and Clear
    UE4SS Lua mod for STAR WARS: Galactic Racer (UE project "Griffin")

    Makes dialogue intelligible over the race mix, using the two gain stages in
    this game that actually do something:

      Sound class volume, for boosting. FSoundClassProperties::Volume is a plain
      float with no unity ceiling, and it reads back, so writes are verified
      rather than assumed.

      Control buses, for ducking. Each submix's gain comes from its
      OutputVolumeModulation destination, driven by a CB_Submix* bus. Values are
      in decibels.

    A bus cannot boost. MP_Volume is a SoundModulationParameterVolume whose only
    range field is MinVolume = -60.0: 0 dB is unity and the ceiling, so it maps
    [-60, 0] dB onto [0, 1] normalised and clamps. Positive requests come back as
    unity. Hence boosting via sound class, ducking via bus.

    Writing submix OutputVolume directly does nothing here. The call succeeds but
    the property reads back as nil on all 62 submixes and nothing changes
    audibly, because the modulation destination drives the gain instead. That
    path used to be in this file and has been removed.

    Keys:    Ctrl+F7 apply    Ctrl+F8 dump audio graph    Ctrl+F9 reset
    Console: lac_apply | lac_reset | lac_set <relpath> <mult> | lac_verify
             lac_dump | lac_param <relpath> | lac_forget
--]]

local UEHelpers = require("UEHelpers")

local CONTENT = "/Game/Griffin/Audio/Mixing/"
local TAG = "[LoudAndClear] "

----------------------------------------------------------------------
-- configuration
----------------------------------------------------------------------

local CONFIG = {
    -- Linear multiplier on the dialogue sound classes. 1.0 leaves them alone.
    -- This is the dial for "I still cannot hear them". Pushing it far feeds
    -- SE_Main_MixModeCompressor on the main bus and starts pumping the rest of
    -- the mix, so if high values sound harsh rather than louder, take some of it
    -- from the duck table instead.
    class_boost = 1.7,

    -- Parents only. Class volume multiplies down the hierarchy:
    --   SC_Voice      -> SC_Commentary, SC_DiegeticVoice, SC_NonDiegeticVoice,
    --                    SC_Voice_Cinematic
    --   SC_Characters -> SC_Characters_Foley, SC_Characters_Vox
    -- so SC_Voice covers the four dialogue children, and SC_Characters_Vox is
    -- named directly because its parent also carries foley.
    voice_classes = {
        "Classes/SC_Voice",
        "Classes/SC_Characters_Vox",
    },

    -- Multipliers on what competes with speech, relative to the authored level.
    -- Converted to dB internally. 60 dB of range is available, so these can go
    -- much deeper; engines below about 0.50 costs noticeable weight.
    duck = {
        ["Submixes/SS_Music"]                          = 0.60,  -- -4.44 dB
        ["Submixes/SS_Crowds"]                         = 0.65,  -- -3.74 dB
        ["Submixes/SS_HighSpeedAirflow"]               = 0.65,  -- -3.74 dB
        ["Submixes/SS_NonLocalPlayerEngineAndExhaust"] = 0.70,  -- -3.10 dB
        ["Submixes/SS_LocalPlayerEngine"]              = 0.75,  -- -2.50 dB
        ["Submixes/SS_LocalPlayerExhaust"]             = 0.75,  -- -2.50 dB
        ["Submixes/SS_Ambience"]                       = 0.80,  -- -1.94 dB
    },

    -- Display order for the panel. Only these appear as sliders; anything else
    -- in duck above still applies, it just has no row.
    duck_order = {
        "Submixes/SS_Music",
        "Submixes/SS_Crowds",
        "Submixes/SS_HighSpeedAirflow",
        "Submixes/SS_NonLocalPlayerEngineAndExhaust",
        "Submixes/SS_LocalPlayerEngine",
        "Submixes/SS_LocalPlayerExhaust",
        "Submixes/SS_Ambience",
    },

    -- Opens the in-game mix panel. Avoids INS, which the Galactic FOV Panel mod
    -- uses, so both can be installed together.
    panel_key = Key.HOME,

    -- ON, but on probation. Read this before trusting it in a long session.
    --
    -- The panel froze the game during cutscenes, on open and on close. A dump
    -- taken at a freeze put the main thread in UObject::ProcessContextOpcode,
    -- the engine's handler for the blueprint Context opcode, with RSP below its
    -- own stack base: a stack overflow from unbounded recursion inside the
    -- Blueprint VM.
    --
    -- Six hypotheses were implemented and tested before that dump was resolved,
    -- and every one of them was about a native code path: a nested
    -- ExecuteInGameThread, close ordering, per-toggle widget teardown, repaint
    -- call volume, a template conflict with another mod, and the input-mode
    -- calls. They all failed because they were all in the wrong layer.
    --
    -- The fix is in Panel.lua: the panel used to borrow one of the game's own
    -- widget blueprints to get a WidgetTree, which left a live blueprint
    -- instance ticking on screen. It now builds a bare /Script/UMG.UserWidget
    -- and its tree by hand, and touches no blueprint at all.
    --
    -- Belt and braces, since the fix is reasoned rather than reproduced: the
    -- panel also refuses to open during a cutscene and closes itself if one
    -- starts. lac_cutscene reports whether that detection works here.
    --
    -- The mix itself has never been implicated and runs for days untouched.
    -- Set false if you want it gone entirely, panel and timer both.
    panel_enabled = true,

    -- Whether the panel takes exclusive UI input and shows the cursor.
    --
    -- TRUE BY DEFAULT, because the sliders need a cursor. Slider values are read
    -- by polling GetValue and nothing moves a slider from the keyboard, so
    -- without this the nine sliders cannot be touched and the panel is five
    -- working buttons around decoration. It shipped that way by accident after
    -- being turned off while chasing the cutscene crash.
    --
    -- It was tested as the sixth hypothesis for that crash and cleared: the
    -- crash recurred with these calls removed entirely, and the dump later put
    -- the fault in the Blueprint VM, a different layer again.
    --
    -- This also decides whether the panel widget is focusable at all. It must
    -- not be when we are not taking input, or Slate can leave gamepad focus on a
    -- closed panel. See the note in Panel.create.
    --
    -- Set false for a read-only panel that never touches input focus. Values
    -- then change through the console commands instead.
    panel_grabs_input = true,

    -- Whether the panel refuses to open during a cutscene, and closes itself if
    -- one starts while it is open.
    --
    -- OFF, because it cannot tell a cutscene from scenery. The paddock runs an
    -- ambient idle animation through a LevelSequencePlayer with LoopCount 0,
    -- which is indistinguishable from a cutscene by every property tried, so
    -- the guard blocked the panel for the whole of that area. Two attempts at a
    -- discriminator failed: any playing sequence, then any non-looping one.
    --
    -- It was containment for a crash whose actual cause has since been removed.
    -- The panel no longer borrows a game blueprint for its widget tree, and the
    -- rebuilt host survived eight opens inside a real cutscene. Keeping a guard
    -- that reliably breaks a hub area, to mitigate a risk that was fixed
    -- properly somewhere else, is the wrong trade.
    --
    -- Set true if you would rather have it. Ctrl+F10 reports what it can see.
    cutscene_guard = false,

    -- Submix relpath -> the bus that drives its gain. A lookup table, not a
    -- target list: entries here are only acted on if they appear in duck above,
    -- or are passed to lac_set. Gain on a parent is inherited by its children,
    -- so pick parents.
    bus_for = {
        ["Submixes/SS_Music"]                          = "Modulation/Submixes/CB_SubmixMusic",
        ["Submixes/SS_Crowds"]                         = "Modulation/Submixes/CB_SubmixCrowds",
        ["Submixes/SS_HighSpeedAirflow"]               = "Modulation/Submixes/CB_SubmixHighSpeedAirflow",
        ["Submixes/SS_NonLocalPlayerEngineAndExhaust"] = "Modulation/Submixes/CB_SubmixNonLocalPlayerEngineAndExhaust",
        ["Submixes/SS_LocalPlayerEngine"]              = "Modulation/Submixes/CB_SubmixLocalPlayerEngine",
        ["Submixes/SS_LocalPlayerExhaust"]             = "Modulation/Submixes/CB_SubmixLocalPlayerExhaust",
        ["Submixes/SS_Ambience"]                       = "Modulation/Submixes/CB_SubmixAmbience",
        ["Submixes/SS_SFX"]                            = "Modulation/Submixes/CB_SubmixSFX",
        ["Submixes/SS_Vehicles"]                       = "Modulation/Submixes/CB_SubmixVehicles",
        ["Submixes/SS_World"]                          = "Modulation/Submixes/CB_SubmixWorld",
        ["Submixes/SS_Passbys"]                        = "Modulation/Submixes/CB_SubmixPassbys",
        ["Submixes/SS_Impacts"]                        = "Modulation/Submixes/CB_SubmixImpacts",
        ["Submixes/SS_UI"]                             = "Modulation/Submixes/CB_SubmixUI",
        ["Submixes/SS_Voice"]                          = "Modulation/Submixes/CB_SubmixVoice",
        ["Submixes/SS_Commentary"]                     = "Modulation/Submixes/CB_SubmixCommentary",
    },

    -- The volume these sound classes ship at, and how far a captured value may
    -- stray from it before the mod refuses to believe it.
    --
    -- Capturing only happens when there is no stored baseline. If the mod has
    -- already applied in this process and the stored file then goes missing, the
    -- next capture reads this mod's own output back as the authored value and
    -- multiplies it again. That is not hypothetical: moving the baseline file
    -- aside while the game was running, then triggering a hot reload, took
    -- SC_Voice to 2.890 and left a baseline claiming 1.700 was authored.
    --
    -- Every one of this game's 61 sound classes reads 1.0, on two separate
    -- builds. So a capture that is not 1.0 is far more likely to be our own
    -- output than a real change. Refuse it loudly rather than compounding. If a
    -- patch genuinely rebalances the mix, the log says so and this gets updated.
    -- EXPERIMENTAL. Sound classes to make louder, as a multiplier.
    --
    -- The only way anything gets louder in this game. Ducking is per submix
    -- because a control bus has 60 dB of cut; boosting a submix is impossible,
    -- since the bus parameter has MinVolume = -60 and no MaxVolume, so 0 dB is
    -- unity and the ceiling at once and a positive request comes back as unity.
    --
    -- Sound class volume has no such ceiling, which is how dialogue reaches
    -- 1.7x. An earlier version of this offered one lumped SC_SFX slider,
    -- because the README's class tree lists 14 classes and none of them covered
    -- engines or ambience. Ctrl+F11 on a live race showed the game actually
    -- uses 30, including SC_Vehicles, SC_VehicleInAir, SC_Ambience,
    -- SC_Crashing and SC_Overtakes. So these get a slider each.
    --
    -- SC_SFX is deliberately not in this list. Gain on a parent is inherited,
    -- and it is very likely the parent of these, so boosting both would
    -- multiply. Ctrl+F11 lists every class in use if you want to add others.
    --
    -- 1.0 is off. Ctrl+PageUp and Ctrl+PageDown nudge the whole set at once.
    --
    -- Headroom warning: dialogue is already at 1.7x. Pushing this up as well
    -- makes the mix hot and the limiter audible. boost_ceiling is where it
    -- stops.
    boost = {
        ["Classes/SC_Vehicles"]     = 1.0,
        ["Classes/SC_VehicleInAir"] = 1.0,
        ["Classes/SC_Ambience"]     = 1.0,
        ["Classes/SC_Crashing"]     = 1.0,
        ["Classes/SC_Overtakes"]    = 1.0,
    },
    boost_order = {
        "Classes/SC_Vehicles",
        "Classes/SC_VehicleInAir",
        "Classes/SC_Ambience",
        "Classes/SC_Crashing",
        "Classes/SC_Overtakes",
    },
    boost_step = 0.05,
    boost_ceiling = 2.0,

    -- Toggling Compare plays one real game sound through every channel the panel
    -- adjusts, all at once, so the two mixes can be compared when the game
    -- itself is quiet. Samples are found at runtime by the submix they send to,
    -- never by asset path: a path is a thing a patch can move, and matching by
    -- submix guarantees the sample demonstrates the slider beside it.
    --
    -- They are spawned rather than fired and forgotten, so a looping engine bed
    -- can be stopped again. Toggling Compare again, or closing the panel, stops
    -- them. Set test_sounds = false to turn it off.
    test_sounds = true,
    test_min_seconds = 0.4,

    -- What a Compare toggle plays, together. Sound classes, not submixes:
    -- SoundSubmixObject is set on two sounds in the entire game, so matching on
    -- it found nothing. These names are measured from a live race with
    -- Ctrl+F11, not taken from the class tree in the README, which lists only
    -- about half of what the game actually uses.
    -- Which asset to pick within a class, best first. Matched as a
    -- case-insensitive substring of the asset name. Anything matching nothing
    -- here is still eligible, it just sorts last, so a class with no entry
    -- falls back to simply taking the longest asset.
    --
    -- The engine ladder is Idle, Low, Med, High, TopSpeed, so TopSpeed is the
    -- flat-out sound. Some bikes abbreviate Engine to Eng and Exhaust to Exh.
    test_prefer = {
        ["SC_Vehicles"] = {
            "Engine_TopSpeed", "Eng_TopSpeed",
            "Engine_High", "Eng_High",
            "Exhaust_TopSpeed", "Exh_TopSpeed",
            "Engine_", "Eng_",
        },
        ["SC_VehicleInAir"] = { "TopSpeed", "High", "Airflow" },
        ["SC_Ambience"]     = { "Loop" },
        ["SC_Characters"]   = { "Crowd", "Loop" },
        ["SC_Music"]        = { "Loop", "Race" },
    },

    test_classes = {
        "SC_Vehicles",          -- engines and exhaust
        "SC_VehicleInAir",      -- airflow
        "SC_Ambience",
        "SC_Characters",        -- crowds and world characters
        "SC_Characters_Vox",    -- dialogue
        -- There is no plain SC_Music in this game. The live class report
        -- lists SC_Music_Cinematics, SC_Music_Menus and SC_Music_Paddock,
        -- which is why the set kept coming back one short.
        "SC_Music_Menus",
        "SC_Music_Paddock",
        "SC_Music_Cinematics",
        "SC_Overtakes",
    },

    expected_class_volume = 1.0,
    baseline_tolerance = 0.01,

    apply_on_start = true,

    -- Off by default, and it should stay off outside of investigation.
    --
    -- The dump sweeps every loaded SoundSubmix, SoundClass and SoundControlBus,
    -- then walks class hierarchies property by property. That is by far the
    -- largest surface this mod touches, several hundred objects of reflection
    -- per launch, against a reflection layer that has no way to know an object
    -- was collected between being listed and being read.
    --
    -- It earned its keep while working out the audio routing. Keeping it on in
    -- normal use is unnecessary risk for information already written down in the
    -- README. Ctrl+F8 and lac_dump still run it on demand.
    dump_on_start = false,

    -- How often to read the class volumes back and check they still hold. Only
    -- re-applies what actually moved. Set to 0 for a single pass at startup.
    verify_seconds = 30,

    verbose = true,
}

-- The values above, captured before load_settings() overwrites them. "Mod
-- defaults" has to mean the shipped mix, and once a settings file has been read
-- CONFIG no longer knows what that was.
local DEFAULTS = { class_boost = CONFIG.class_boost, duck = {}, boost = {} }
for relpath, value in pairs(CONFIG.duck) do DEFAULTS.duck[relpath] = value end
for relpath, value in pairs(CONFIG.boost) do DEFAULTS.boost[relpath] = value end

----------------------------------------------------------------------
-- plumbing
----------------------------------------------------------------------

local function log(fmt, ...)
    local msg
    if select("#", ...) > 0 then
        local ok, formatted = pcall(string.format, fmt, ...)
        msg = ok and formatted or tostring(fmt)
    else
        msg = tostring(fmt)
    end
    print(TAG .. msg .. "\n")
end

local function vlog(...)
    if CONFIG.verbose then log(...) end
end

-- UE4SS object wrappers can be nil, or valid-looking but dead. Never trust one
-- without asking, and never let IsValid itself throw into the caller.
local function valid(obj)
    if not obj then return false end
    local ok, result = pcall(function() return obj:IsValid() end)
    return ok and result == true
end

local function full_name(obj)
    local ok, name = pcall(function() return obj:GetFullName() end)
    return ok and name or "<unreadable>"
end

-- "Submixes/SS_Voice" -> /Game/Griffin/Audio/Mixing/Submixes/SS_Voice.SS_Voice
local function resolve(relpath)
    local short = relpath:match("([^/]+)$")
    local path = CONTENT .. relpath .. "." .. short
    local ok, obj = pcall(StaticFindObject, path)
    if ok and valid(obj) then return obj, path end
    return nil, path
end

local function read_float(obj, property)
    local ok, value = pcall(function() return obj[property] end)
    if ok and type(value) == "number" then return value end
    return nil
end

----------------------------------------------------------------------
-- baseline persistence
----------------------------------------------------------------------

-- relpath -> authored sound class Volume, captured before the first write.
--
-- This has to outlive the Lua state. A hot reload, or a restart, hands the mod a
-- fresh empty table while the classes are still boosted, so re-capturing from
-- the live value would treat an already-boosted volume as authored and multiply
-- it again: 1.7 to 2.9 to 4.9 across three reloads.
local class_baseline = {}

local BASELINE_FILE = (function()
    -- The mod folder is under Program Files, which is not writable without
    -- elevation, so a write next to the script fails. The game's own save
    -- directory is writable.
    local localappdata = os.getenv("LOCALAPPDATA")
    if localappdata then
        return localappdata .. "/StarWarsGalacticRacer/Saved/LoudAndClear-baseline.txt"
    end
    return "LoudAndClear-baseline.txt"
end)()

local function save_baseline()
    local handle = io.open(BASELINE_FILE, "w")
    if not handle then
        log("could not write %s, baseline will not survive a reload", BASELINE_FILE)
        return false
    end
    handle:write("# authored sound class volumes captured before this mod ran\n")
    handle:write("# delete this file, or run lac_forget, to re-capture\n")
    for relpath, value in pairs(class_baseline) do
        handle:write(string.format("class:%s=%.6f\n", relpath, value))
    end
    handle:close()
    return true
end

local function load_baseline()
    local handle = io.open(BASELINE_FILE, "r")
    if not handle then return 0 end
    local count = 0
    for line in handle:lines() do
        if not line:match("^%s*#") then
            -- Only class: entries are used. Older files also carried submix:
            -- lines from a gain stage that turned out to be inert; they are
            -- ignored rather than treated as an error.
            local relpath, value = line:match("^class:([^=]+)=(.+)$")
            local number = tonumber(value)
            if relpath and number then
                class_baseline[relpath] = number
                count = count + 1
            end
        end
    end
    handle:close()
    if count > 0 then
        log("restored %d authored class volumes from %s", count, BASELINE_FILE)
    end
    return count
end

----------------------------------------------------------------------
-- user settings
----------------------------------------------------------------------

-- Values the panel saves, layered over the CONFIG defaults. Kept separate from
-- the baseline file: one records what the game authored, the other what the user
-- chose, and conflating them is how the compounding bug got its chance.

local SETTINGS_FILE = (function()
    local localappdata = os.getenv("LOCALAPPDATA")
    if localappdata then
        return localappdata .. "/StarWarsGalacticRacer/Saved/LoudAndClear-settings.txt"
    end
    return "LoudAndClear-settings.txt"
end)()

local function load_settings()
    local handle = io.open(SETTINGS_FILE, "r")
    if not handle then return 0 end
    local count = 0
    for line in handle:lines() do
        if not line:match("^%s*#") then
            local key, value = line:match("^([^=]+)=(.+)$")
            local number = tonumber(value)
            if key and number then
                if key == "class_boost" then
                    CONFIG.class_boost = number
                    count = count + 1
                else
                    local relpath = key:match("^duck:(.+)$")
                    -- Only accept keys we already know, so a stale file cannot
                    -- introduce a submix this build no longer has.
                    if relpath and CONFIG.duck[relpath] ~= nil then
                        CONFIG.duck[relpath] = number
                        count = count + 1
                    end
                    local boosted = key:match("^boost:(.+)$")
                    if boosted and CONFIG.boost[boosted] ~= nil then
                        CONFIG.boost[boosted] = number
                        count = count + 1
                    end
                end
            end
        end
    end
    handle:close()
    if count > 0 then log("loaded %d saved settings", count) end
    return count
end

local function save_settings()
    local handle = io.open(SETTINGS_FILE, "w")
    if not handle then
        log("could not write %s", SETTINGS_FILE)
        return false
    end
    handle:write("# Loud and Clear, written by the in-game panel\n")
    handle:write(string.format("class_boost=%.4f\n", CONFIG.class_boost))
    for _, relpath in ipairs(CONFIG.duck_order) do
        if CONFIG.duck[relpath] then
            handle:write(string.format("duck:%s=%.4f\n", relpath, CONFIG.duck[relpath]))
        end
    end
    for _, relpath in ipairs(CONFIG.boost_order) do
        if CONFIG.boost[relpath] then
            handle:write(string.format("boost:%s=%.4f\n", relpath, CONFIG.boost[relpath]))
        end
    end
    handle:close()
    return true
end

----------------------------------------------------------------------
-- world
----------------------------------------------------------------------

local function world_context()
    local ok, world = pcall(UEHelpers.GetWorldContextObject)
    if ok and valid(world) then return world end
    local ok2, fallback = pcall(UEHelpers.GetWorld)
    if ok2 and valid(fallback) then return fallback end
    return nil
end

----------------------------------------------------------------------
-- audio modulation
----------------------------------------------------------------------

local modulation_statics_cache = nil

local function modulation_statics()
    if valid(modulation_statics_cache) then return modulation_statics_cache end
    for _, path in ipairs({
        "/Script/AudioModulation.Default__AudioModulationStatics",
        "/Script/AudioModulation.Default__SoundModulationStatics",
    }) do
        local ok, obj = pcall(StaticFindObject, path)
        if ok and valid(obj) then
            modulation_statics_cache = obj
            return obj
        end
    end
    return nil
end

-- Enumerates every property on an object, walking up the class hierarchy.
-- Guessing field names returned nothing useful, so ask reflection instead. This
-- is what established that MP_Volume has no MaxVolume.
local function dump_properties(obj, label)
    if not valid(obj) then
        log("%s: <invalid>", label)
        return
    end

    local class_name = "<unknown>"
    pcall(function() class_name = obj:GetClass():GetFName():ToString() end)
    log("-- %s (%s) --", label, class_name)

    local class = nil
    pcall(function() class = obj:GetClass() end)

    while valid(class) do
        local struct_name = "<?>"
        pcall(function() struct_name = class:GetFName():ToString() end)

        pcall(function()
            class:ForEachProperty(function(property)
                local name, ptype = "<?>", "<?>"
                pcall(function() name = property:GetFName():ToString() end)
                pcall(function() ptype = property:GetClass():GetFName():ToString() end)

                local rendered = "<unreadable>"
                local ok, value = pcall(function() return obj[name] end)
                if ok then
                    local kind = type(value)
                    if kind == "number" or kind == "boolean" or kind == "string" then
                        rendered = tostring(value)
                    elseif kind == "userdata" then
                        rendered = valid(value) and full_name(value) or "<userdata>"
                    else
                        rendered = "<" .. kind .. ">"
                    end
                end

                log("    [%s] %s %s = %s", struct_name, ptype, name, rendered)
            end)
        end)

        local parent = nil
        pcall(function() parent = class:GetSuperStruct() end)
        class = parent
    end
end

-- Reports a bus's parameter class and any readable range fields, so the unit
-- space is read off the game rather than assumed.
local function describe_parameter(bus)
    local parameter
    pcall(function() parameter = bus.Parameter end)
    if not valid(parameter) then return nil, "<no parameter>" end

    local class_name = "<unknown>"
    pcall(function() class_name = parameter:GetClass():GetFName():ToString() end)

    local fields = {}
    for _, name in ipairs({ "MinVolume", "UnitMin", "UnitMax", "MinValue", "MaxValue" }) do
        local value = read_float(parameter, name)
        if value then fields[#fields + 1] = string.format("%s=%.3f", name, value) end
    end

    return class_name, table.concat(fields, " ")
end

local positive_gain_warned = false

-- Converts a linear gain multiplier into the value a bus expects.
local function bus_value_for(multiplier, class_name)
    if not (class_name and class_name:lower():find("volume")) then
        return multiplier
    end
    if multiplier <= 0 then return -96.0 end

    local decibels = 20.0 * math.log(multiplier, 10)

    -- 0 dB is unity and the ceiling for a volume parameter, so a positive
    -- request is discarded by the audio engine. Clamp here and say so once,
    -- rather than logging a gain that does not happen. Use class_boost to make
    -- dialogue louder.
    if decibels > 0 then
        if not positive_gain_warned then
            positive_gain_warned = true
            log("x%.2f wants %+.2f dB, but 0 dB is this parameter's ceiling.", multiplier, decibels)
            log("Clamping to 0 dB. Duck the maskers, or raise class_boost.")
        end
        return 0.0
    end

    return decibels
end

local function set_bus_multiplier(relpath, multiplier)
    local bus_rel = CONFIG.bus_for[relpath]
    if not bus_rel then
        log("no bus mapped for '%s'. Add it to CONFIG.bus_for.", relpath)
        return false
    end

    local bus = resolve(bus_rel)
    if not bus then
        vlog("bus not loaded: %s", bus_rel)
        return false
    end

    local statics = modulation_statics()
    if not statics then
        log("AudioModulationStatics not found, cannot drive buses")
        return false
    end

    local world = world_context()
    if not world then return false end

    local class_name, ranges = describe_parameter(bus)
    local value = bus_value_for(multiplier, class_name)

    local ok, err = pcall(function()
        statics:SetGlobalBusMixValue(world, bus, value, 0.1)
    end)
    if not ok then
        log("SetGlobalBusMixValue failed on %s: %s", bus_rel, tostring(err))
        return false
    end

    vlog("bus %s = %.3f dB (x%.2f, %s %s)",
        bus_rel:match("([^/]+)$"), value, multiplier, tostring(class_name), ranges)
    return true
end

local function clear_bus(relpath)
    local bus_rel = CONFIG.bus_for[relpath]
    if not bus_rel then return false end
    local bus = resolve(bus_rel)
    local statics = modulation_statics()
    local world = world_context()
    if not (bus and statics and world) then return false end
    return pcall(function() statics:ClearGlobalBusMixValue(world, bus, 0.1) end)
end

----------------------------------------------------------------------
-- sound class volume
----------------------------------------------------------------------

-- Writes a class volume and reads it back to confirm it took. This stage is
-- readable, so success is measured rather than inferred from a missing error.
local function set_class_multiplier(relpath, multiplier)
    local class = resolve(relpath)
    if not class then
        vlog("class not loaded: %s", relpath)
        return false
    end

    if class_baseline[relpath] == nil then
        local current
        pcall(function() current = class.Properties.Volume end)
        if type(current) ~= "number" then
            log("%s: Properties.Volume is not readable, skipping", relpath)
            return false
        end

        -- Only believe a capture that looks authored. See expected_class_volume.
        if math.abs(current - CONFIG.expected_class_volume) > CONFIG.baseline_tolerance then
            log("%s reads %.3f, but these classes ship at %.3f.",
                relpath, current, CONFIG.expected_class_volume)
            log("  Refusing to record that as the authored value. It is most")
            log("  likely this mod's own output from an earlier apply, and")
            log("  treating it as authored would compound the boost.")
            log("  Restart the game to recover, or set expected_class_volume")
            log("  in CONFIG if a patch really did rebalance the mix.")
            return false
        end

        class_baseline[relpath] = current
        -- Persist before writing, so a crash or reload cannot leave the boosted
        -- value as the only record of what was authored.
        save_baseline()
    end

    local target = class_baseline[relpath] * multiplier

    local ok, err = pcall(function() class.Properties.Volume = target end)
    if not ok then
        log("class volume write failed on %s: %s", relpath, tostring(err))
        return false
    end

    local readback
    pcall(function() readback = class.Properties.Volume end)
    if type(readback) ~= "number" then
        log("%s: wrote %.3f but cannot read it back", relpath, target)
        return false
    end
    if math.abs(readback - target) > 0.0005 then
        log("%s: wrote %.3f but it reads %.3f, the write did not stick",
            relpath, target, readback)
        return false
    end

    log("class %s  %.3f -> %.3f  (x%.2f, verified)",
        relpath:match("([^/]+)$"), class_baseline[relpath], readback, multiplier)
    return true
end

local function reset_classes()
    local restored = 0
    for relpath, authored in pairs(class_baseline) do
        local class = resolve(relpath)
        if class then
            local ok = pcall(function() class.Properties.Volume = authored end)
            if ok then restored = restored + 1 end
        end
    end
    return restored
end

----------------------------------------------------------------------
-- apply, reset, verify
----------------------------------------------------------------------

-- Two different questions, which used to share one flag.
--
--   started : has the one-time startup apply succeeded? Only the startup poll
--             cares, and nothing clears it afterwards.
--   applied : is our mix in effect right now? Reset clears it, and both the
--             verify pass and the startup poll must respect that.
--
-- Sharing them made Defaults useless: reset cleared the flag, the startup poll
-- saw "not applied" a tick later and re-applied the whole mix, so the button
-- appeared to do nothing and got pressed thirteen times in three seconds.
local started = false
local applied = false
local drift_reported = false

-- The work itself, which must already be on the game thread.
--
-- Split out because the panel calls these from inside its own
-- ExecuteInGameThread callback. Nesting ExecuteInGameThread means asking the
-- game thread to schedule work for the game thread while it is busy running
-- ours, which is a deadlock waiting for the right timing, and a deadlock is
-- exactly what a freeze looks like.
local function apply_now()
    local buses, bus_attempted = 0, 0
    for relpath, multiplier in pairs(CONFIG.duck) do
        bus_attempted = bus_attempted + 1
        if set_bus_multiplier(relpath, multiplier) then buses = buses + 1 end
    end

    local classes, class_attempted = 0, 0
    if CONFIG.class_boost ~= 1.0 then
        for _, relpath in ipairs(CONFIG.voice_classes) do
            class_attempted = class_attempted + 1
            if set_class_multiplier(relpath, CONFIG.class_boost) then
                classes = classes + 1
            end
        end
    end

    -- Same mechanism, different classes. Skipped entirely at 1.0 so the feature
    -- costs nothing until someone turns it up.
    for _, relpath in ipairs(CONFIG.boost_order) do
        local multiplier = CONFIG.boost[relpath]
        if multiplier and multiplier ~= 1.0 then
            class_attempted = class_attempted + 1
            if set_class_multiplier(relpath, multiplier) then
                classes = classes + 1
            end
        end
    end

    log("applied: %d/%d buses ducked, %d/%d class volumes boosted",
        buses, bus_attempted, classes, class_attempted)

    if buses > 0 or classes > 0 then
        -- Startup is satisfied. Retry only while nothing has ever landed.
        started = true
    end

    if buses == 0 and classes == 0 then
        applied = false
        log("nothing applied. Ctrl+F8 dumps the audio graph so you can check")
        log("whether these objects are loaded and what they are really called.")
    end
end

local function reset_now()
    local cleared = 0
    for relpath in pairs(CONFIG.duck) do
        if clear_bus(relpath) then cleared = cleared + 1 end
    end
    local classes = reset_classes()
    applied = false
    log("reset: cleared %d bus overrides, restored %d class volumes",
        cleared, classes)
end

-- Entry points for callers that are NOT on the game thread: keybinds, console
-- commands, the startup poll.
local function apply()
    -- Claim the work before going async. ExecuteInGameThread defers, so leaving
    -- this until the callback let the startup poll fire a second apply.
    applied = true
    ExecuteInGameThread(apply_now)
end

local function reset()
    ExecuteInGameThread(reset_now)
end

-- Reads the class volumes back and re-applies only what moved. This is the only
-- stage that can be measured: a bus override cannot be read back, because its
-- live value lives inside the modulation system rather than on the object.
local function verify()
    local drifted, checked = 0, 0

    -- Reset means the user asked for the game's own levels. Re-applying drift
    -- then would quietly undo that choice.
    if not applied then return 0 end

    if CONFIG.class_boost ~= 1.0 then
        for _, relpath in ipairs(CONFIG.voice_classes) do
            local authored = class_baseline[relpath]
            local class = resolve(relpath)
            if authored and class then
                local want = authored * CONFIG.class_boost
                local actual
                pcall(function() actual = class.Properties.Volume end)
                if type(actual) == "number" then
                    checked = checked + 1
                    if math.abs(actual - want) > 0.0005 then
                        drifted = drifted + 1
                        log("drift on %s: expected %.3f, found %.3f. Re-applying.",
                            relpath, want, actual)
                        set_class_multiplier(relpath, CONFIG.class_boost)
                    end
                end
            end
        end
    end

    for _, relpath in ipairs(CONFIG.boost_order) do
        local multiplier = CONFIG.boost[relpath]
        local authored = class_baseline[relpath]
        local class = authored and resolve(relpath)
        if multiplier and multiplier ~= 1.0 and authored and class then
            local want = authored * multiplier
            local actual
            pcall(function() actual = class.Properties.Volume end)
            if type(actual) == "number" then
                checked = checked + 1
                if math.abs(actual - want) > 0.0005 then
                    drifted = drifted + 1
                    log("drift on %s: expected %.3f, found %.3f. Re-applying.",
                        relpath, want, actual)
                    set_class_multiplier(relpath, multiplier)
                end
            end
        end
    end

    if drifted == 0 and not drift_reported then
        drift_reported = true
        log("verify: %d class volumes still hold (measured)", checked)
    elseif drifted > 0 then
        drift_reported = false
    end

    return drifted
end

----------------------------------------------------------------------
-- discovery
----------------------------------------------------------------------

-- Dumps what is actually loaded rather than what we expect to be loaded.
local function dump()
    ExecuteInGameThread(function()
        log("================ audio graph ================")

        -- Parent routing is the valuable part: gain on a parent is inherited, so
        -- the chain decides what is worth targeting.
        local ok, submixes = pcall(FindAllOf, "SoundSubmix")
        if ok and type(submixes) == "table" then
            log("-- submixes (%d loaded) --", #submixes)
            for _, submix in pairs(submixes) do
                if valid(submix) then
                    local parent = "<root>"
                    pcall(function()
                        local p = submix.ParentSubmix
                        if valid(p) then parent = p:GetFName():ToString() end
                    end)
                    log("  %s  parent=%s", submix:GetFName():ToString(), parent)
                end
            end
        else
            log("FindAllOf('SoundSubmix') returned nothing usable")
        end

        local okc, classes = pcall(FindAllOf, "SoundClass")
        if okc and type(classes) == "table" then
            log("-- sound classes (%d loaded) --", #classes)
            for _, class in pairs(classes) do
                if valid(class) then
                    local volume
                    pcall(function() volume = class.Properties.Volume end)
                    local children = {}
                    pcall(function()
                        local list = class.ChildClasses
                        if list and list.ForEach then
                            list:ForEach(function(_, element)
                                local child = element:get()
                                if valid(child) then
                                    children[#children + 1] = child:GetFName():ToString()
                                end
                            end)
                        end
                    end)
                    log("  %s  Volume=%s  children=[%s]",
                        class:GetFName():ToString(), tostring(volume),
                        table.concat(children, ", "))
                end
            end
        end

        local okb, buses = pcall(FindAllOf, "SoundControlBus")
        if okb and type(buses) == "table" then
            log("-- control buses (%d loaded) --", #buses)
            for _, bus in pairs(buses) do
                if valid(bus) then
                    local class_name, ranges = describe_parameter(bus)
                    log("  %s  parameter=%s %s",
                        bus:GetFName():ToString(), tostring(class_name), ranges or "")
                end
            end
        end

        local statics = modulation_statics()
        log("-- AudioModulationStatics: %s --",
            statics and "found" or "NOT FOUND, buses cannot be driven")

        -- Whether a positive boost can work at all is in these property lists.
        local voice_bus = resolve("Modulation/Submixes/CB_SubmixVoice")
        if voice_bus then
            local parameter
            pcall(function() parameter = voice_bus.Parameter end)
            dump_properties(parameter, "CB_SubmixVoice parameter")
        end

        log("================ end ================")
    end)
end

----------------------------------------------------------------------
-- in-game panel
----------------------------------------------------------------------

local Panel = (function()
    if not CONFIG.panel_enabled then return nil end
    local source = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
    local dir = source:match("^(.*)/[^/]+$")
    local ok, mod = pcall(dofile, dir .. "/Panel.lua")
    if ok and type(mod) == "table" then return mod end
    log("panel unavailable: %s", tostring(mod))
    return nil
end)()

local panel, panel_owner, cursor_before
-- The built panel survives a close. 'panel' means shown; 'panel_cached'
-- holds the widgets so they are constructed once per session.
local panel_cached
local saved = { class_boost = nil, duck = {} }
local model = { selection = 1, duck = {} }
local panel_events = {}
local panel_busy, panel_suspended = false, false
local epoch = 0

local function snapshot(into)
    into.class_boost = CONFIG.class_boost
    into.duck = {}
    for relpath, value in pairs(CONFIG.duck) do into.duck[relpath] = value end
    into.boost = {}
    for relpath, value in pairs(CONFIG.boost) do into.boost[relpath] = value end
end

local function is_dirty()
    if not saved.class_boost then return false end
    if math.abs(model.class_boost - saved.class_boost) > 0.0001 then return true end
    for relpath, value in pairs(model.duck) do
        if math.abs(value - (saved.duck[relpath] or value)) > 0.0001 then return true end
    end
    for relpath, value in pairs(model.boost or {}) do
        local was = (saved.boost and saved.boost[relpath]) or value
        if math.abs(value - was) > 0.0001 then return true end
    end
    return false
end

-- Pushes a single changed value straight at the audio engine, so dragging a
-- slider is audible immediately.
----------------------------------------------------------------------
-- test samples
----------------------------------------------------------------------

-- Everything the panel adjusts, sampled at once: the seven ducked submixes plus
-- dialogue. Matching is on the submix a sound sends to, because that is the
-- stage the sliders move. Matching by sound class, as the first version did,
-- demonstrates nothing about a submix slider.
local samples = nil
local sample_components = {}
-- Declared global so the LoadMap hook, which is installed further down, can
-- clear the cache. See forget_samples.
forget_samples = nil

local function test_targets()
    return CONFIG.test_classes
end

local function find_samples()
    if samples then return samples end
    samples = {}

    local wanted, lengths, ranks = {}, {}, {}
    for _, name in ipairs(test_targets()) do wanted[name] = true end

    -- Cues before waves: a SoundWave usually has no routing of its own, the cue
    -- that plays it carries it.
    local scanned, routed = 0, 0
    for _, kind in ipairs({ "SoundCue", "SoundWave" }) do
        local ok, sounds = pcall(FindAllOf, kind)
        if ok and sounds then
            for _, sound in ipairs(sounds) do
                if valid(sound) then
                    scanned = scanned + 1

                    local class_name
                    pcall(function()
                        local sc = sound.SoundClassObject
                        if valid(sc) then class_name = sc:GetFName():ToString() end
                    end)
                    if class_name then routed = routed + 1 end

                    if class_name and wanted[class_name] then
                        local duration
                        pcall(function() duration = sound.Duration end)
                        if type(duration) == "number"
                           and duration >= CONFIG.test_min_seconds then
                            local asset = (sound:GetFullName() or "")
                                :match("([^.]+)$") or ""
                            local lower = asset:lower()

                            -- Rank by the first preference it matches. Lower is
                            -- better; no match sorts last but stays eligible.
                            local rank = math.huge
                            local prefs = CONFIG.test_prefer[class_name]
                            if prefs then
                                for i, needle in ipairs(prefs) do
                                    if lower:find(needle:lower(), 1, true) then
                                        rank = i
                                        break
                                    end
                                end
                            end

                            local held = ranks[class_name] or math.huge
                            local better = rank < held
                                or (rank == held
                                    and duration > (lengths[class_name] or 0))
                            if better then
                                samples[class_name] = sound
                                ranks[class_name] = rank
                                lengths[class_name] = duration
                            end
                        end
                    end
                end
            end
        end
    end

    local found = 0
    for class_name, sound in pairs(samples) do
        found = found + 1
        local rank = ranks[class_name]
        local prefs = CONFIG.test_prefer[class_name]
        local why = "longest"
        if prefs and rank and rank ~= math.huge then
            why = "matched " .. prefs[rank]
        end
        log("  %-22s %-46s (%s)", class_name,
            (sound:GetFullName() or ""):match("([^.]+)$") or "?", why)
    end
    log("found %d of %d samples (%d sounds scanned, %d carried a class)",
        found, #test_targets(), scanned, routed)
    if found == 0 then
        log("  nothing matched. lac_sounds lists the submixes and classes the")
        log("  loaded sounds actually use, which is how to fix this.")
    end
    return samples
end

-- Dropping the cache makes the next toggle re-pick from whatever is loaded now.
function forget_samples()
    samples = nil
end

-- Stopped on the next toggle and on panel close, which is the whole reason
-- these are spawned rather than fired and forgotten.
local function stop_samples()
    local stopped = 0
    for _, component in ipairs(sample_components) do
        if valid(component) then
            if pcall(function() component:Stop() end) then stopped = stopped + 1 end
        end
    end
    sample_components = {}
    return stopped
end

-- Must already be on the game thread.
local function play_samples(why)
    if not CONFIG.test_sounds then return end

    stop_samples()

    local statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    if not valid(statics) then
        log("GameplayStatics unavailable, cannot play samples")
        return
    end

    local world
    pcall(function() world = UEHelpers.GetWorld() end)
    if not valid(world) then
        pcall(function() world = UEHelpers.GetPlayerController() end)
    end
    if not valid(world) then
        log("no world context, cannot play samples")
        return
    end

    local found = find_samples()
    local played = 0
    for _, class_name in ipairs(test_targets()) do
        local sound = found[class_name]
        if valid(sound) then
            -- SpawnSound2D hands back a component, so a looping engine bed can
            -- be stopped again. bAutoDestroy false keeps the handle valid.
            local ok, component = pcall(function()
                return statics:SpawnSound2D(world, sound, 1.0, 1.0, 0.0,
                                            nil, false, false)
            end)
            if ok and valid(component) then
                sample_components[#sample_components + 1] = component
                played = played + 1
            end
        end
    end

    if played > 0 then
        log("playing %d sample(s) together, %s. Toggle again or close to stop.",
            played, why)
    else
        log("no samples to play. They come from loaded sounds, so this works in")
        log("  a race and not in a menu.")
    end
end

local function apply_one(key)
    -- Touching a slider means the user wants our mix, so it re-engages the
    -- verify pass and lifts bypass rather than fighting them.
    applied = true
    model.bypassed = false

    if key == "class_boost" then
        CONFIG.class_boost = model.class_boost
        for _, relpath in ipairs(CONFIG.voice_classes) do
            set_class_multiplier(relpath, CONFIG.class_boost)
        end
    elseif CONFIG.boost[key] ~= nil then
        CONFIG.boost[key] = model.boost[key]
        set_class_multiplier(key, model.boost[key])
    else
        CONFIG.duck[key] = model.duck[key]
        set_bus_multiplier(key, model.duck[key])
    end
end

-- Closing froze the game once, with the panel opened during a cutscene. There
-- was no way to tell how far this got, because none of it logged and a freeze
-- leaves no crash dump. Each step now says so before attempting it, so the next
-- occurrence names the step instead of being a mystery.
local function close_panel()
    local old_panel, old_owner = panel, panel_owner
    panel, panel_owner = nil, nil

    -- Input mode first, then the widget.
    --
    -- The old order removed a focused widget and only then told the engine to
    -- stop routing input to the UI, which leaves Slate briefly resolving focus
    -- to a widget that is no longer in the hierarchy. That is a plausible way to
    -- spin, and it is the wrong order regardless: hand focus back before taking
    -- away the thing holding it.
    if CONFIG.panel_grabs_input and valid(old_owner) then
        vlog("close: restoring input mode")
        local ok, err = pcall(function()
            StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
                :SetInputMode_GameOnly(old_owner, false)
        end)
        if not ok then log("close: SetInputMode_GameOnly failed: %s", tostring(err)) end

        vlog("close: restoring cursor")
        pcall(function() old_owner.bShowMouseCursor = cursor_before end)
    end

    if old_panel and old_panel.widget and valid(old_panel.widget) then
        vlog("close: hiding widget")
        old_panel:hide()
    end

    -- Samples are started from the panel, so they end with it.
    local stopped = stop_samples()
    if stopped > 0 then vlog("close: stopped %d sample(s)", stopped) end

    log("panel closed")
end

-- Is a cutscene running right now?
--
-- Every freeze this mod has caused happened during one, so the panel stays shut
-- then even now that the blueprint host behind it is gone. Belt and braces: the
-- host was the identified cause, this is the containment if it turns out not to
-- have been the only one.
--
-- APlayerController::bCinematicMode was the first attempt and is useless from
-- Lua. UE4SS does not map engine bitfield bools, so reading it yields a
-- TrivialObject rather than true or false, and the old guard silently never
-- fired. UMovieSceneSequencePlayer::IsPlaying is a plain BlueprintPure bool and
-- reads back cleanly.
--
-- Confirmed working in this game: it reports true for the duration of a cutscene
-- and false either side, and the sequences it names are the real ones.
--
-- CALL THIS ONLY FROM A USER ACTION OR WHILE THE PANEL IS OPEN. Never on a
-- timer that runs through startup and level loads. FindAllOf walks the whole
-- object array, and a build that polled it once a second from mod load took an
-- access violation reading address 0 inside UE4SS.dll, on a UE4SS thread, while
-- the menu was loading. The object array is being rewritten during a load and
-- iterating it then is not safe. A Lua pcall is no protection, because the fault
-- is native. UE4SS's own handler caught that one and the game carried on after a
-- Fatal Error dialog, but surviving a null dereference is luck, not a design.
--
-- The panel tick is a safe caller because it already bails out while
-- panel_suspended is set, which the LoadMap hooks cover.
--
-- Still best effort. If some cinematic runs without a sequence player this
-- returns false and the panel opens anyway, and if an ambient looping sequence
-- counts as playing it could refuse when there is no cutscene.
local SEQUENCE_CLASSES = { "LevelSequencePlayer", "MovieSceneSequencePlayer" }
local refusal_logged = false

local function cutscene(report)
    local playing, seen = false, 0
    -- FindAllOf matches subclasses, so every LevelSequencePlayer also comes back
    -- under MovieSceneSequencePlayer. Without this the count was doubled and the
    -- log claimed six players where there were three.
    local counted = {}
    for _, name in ipairs(SEQUENCE_CLASSES) do
        pcall(function()
            local found = FindAllOf(name)
            if not found then return end
            for _, player in ipairs(found) do
                if valid(player) then
                    local id = player:GetFullName()
                    if not counted[id] then
                        counted[id] = true
                        seen = seen + 1
                        local ok, active = pcall(function() return player:IsPlaying() end)
                        if ok and active == true then
                            -- A looping sequence is scenery, not a cutscene.
                            -- This game leaves ambient animation players running
                            -- on a loop, and counting those blocked the panel
                            -- for a whole map.
                            local loops
                            pcall(function()
                                loops = player.PlaybackSettings.LoopCount.Value
                            end)
                            if loops == 0 then
                                playing = true
                                if report then report("  playing: %s", id) end
                            elseif report then
                                report("  ignored (loops=%s): %s", tostring(loops), id)
                            end
                        end
                    end
                end
            end
        end)
    end
    if report then
        report("  %d sequence player(s) visible, playing = %s", seen, tostring(playing))
        report("  a player only counts as a cutscene if LoopCount reads 0;")
        report("  anything looping, or unreadable, is ignored on purpose")
    end
    return playing, seen
end

-- Shared by the Ctrl+F10 bind and the lac_cutscene command, because the console
-- is not on by default and asking someone to turn it on to answer one question
-- is a worse deal than a key.
local function report_cutscene()
    log("cutscene check:")
    local playing, seen = cutscene(log)
    if seen == 0 then
        log("  no sequence players exist at all, so the guard is inert here")
    end
    log("  the panel would %s right now", playing and "refuse to open" or "open")
end

-- See the note above sweep_orphan_panels' call site. Only ever called from a
-- keypress, never from a timer or during a load.
local function sweep_orphan_panels()
    local removed = 0
    pcall(function()
        local widgets = FindAllOf("UserWidget")
        if not widgets then return end
        for _, widget in ipairs(widgets) do
            if valid(widget) then
                local class_name
                pcall(function()
                    class_name = widget:GetClass():GetFName():ToString()
                end)
                -- Bare engine UserWidget, not a WBP_*_C: ours.
                if class_name == "UserWidget" then
                    local in_viewport
                    pcall(function() in_viewport = widget:IsInViewport() end)
                    if in_viewport == true then
                        if pcall(function() widget:RemoveFromParent() end) then
                            removed = removed + 1
                        end
                    end
                end
            end
        end
    end)
    if removed > 0 then
        log("removed %d panel widget(s) left over from a previous load", removed)
    end
    return removed
end

local function open_panel()
    if not Panel then return false end
    local pc
    local ok = pcall(function() pc = UEHelpers.GetPlayerController() end)
    if not (ok and valid(pc)) then return false end

    snapshot(model)
    snapshot(saved)
    -- Nothing pre-selected. Selection used to be driven by the arrow keys and
    -- starting at 1 highlighted Save before the mouse had touched anything.
    -- With the cursor doing the work, hover is the only highlight that means
    -- something, and a click sets this to whatever was clicked.
    model.selection = 0
    model.bypassed = not applied

    -- Said once per cutscene, not once per keypress. The first version reported
    -- it on every press and logged 37 refusals in 18 seconds, which is what
    -- pressing a key that appears to do nothing actually looks like.
    local playing, seen = cutscene()
    if playing and not CONFIG.cutscene_guard then
        log("cutscene in progress, opening anyway (cutscene_guard = false)")
    elseif playing then
        if not refusal_logged then
            refusal_logged = true
            log("not opening during a cutscene. Press HOME again once it ends.")
            log("  Every freeze this mod has caused happened in one, so the panel")
            log("  stays shut until it ends. Ctrl+F10 reports what it can see.")
            log("  If no cutscene is playing, the guard is wrong: set")
            log("  cutscene_guard = false in CONFIG and tell me what Ctrl+F10 says.")
        else
            log("still refusing: a sequence is playing. Ctrl+F10 names it.")
        end
        return false
    end
    refusal_logged = false
    -- Not hardcoded to "false": with cutscene_guard off this line is reached
    -- while a cutscene is playing, and it claimed otherwise one line below
    -- "cutscene in progress, opening anyway", which read as a detection bug
    -- when it was only a wrong string.
    vlog("panel: cutscene = %s (%d sequence players)", tostring(playing), seen)

    if panel_cached and valid(panel_cached.widget) then
        vlog("panel: reusing widgets")
        panel = panel_cached
        panel:show()
    else
        -- About to build. If a previous load left one on screen, it is still
        -- there and invisible to this Lua state, so clear it before adding
        -- another on top.
        sweep_orphan_panels()
        vlog("panel: building widgets")
        local created, err = pcall(function()
            return Panel.create(pc, model, CONFIG.duck_order,
                                CONFIG.panel_grabs_input, CONFIG.boost_order)
        end)
        if not created then
            log("could not open the panel: %s", tostring(err))
            return false
        end
        panel = err
        panel_cached = panel
    end
    panel_owner = pc
    cursor_before = pc.bShowMouseCursor

    panel:write(model, CONFIG.duck_order)
    if CONFIG.panel_grabs_input then
        pcall(function()
            pc.bShowMouseCursor = true
            StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
                :SetInputMode_UIOnlyEx(pc, panel.widget, 0, false)
        end)
    end
    panel:resize(pc)
    panel:update(model, CONFIG.duck_order, false)
    log("panel open")
    return true
end

-- Loads a set of values into CONFIG, the model and the sliders, then applies.
local function adopt(source)
    CONFIG.class_boost = source.class_boost
    for relpath, value in pairs(source.duck) do CONFIG.duck[relpath] = value end
    if source.boost then
        for relpath, value in pairs(source.boost) do CONFIG.boost[relpath] = value end
    end
    snapshot(model)
    if panel then panel:write(model, CONFIG.duck_order) end
    applied = true
    apply_now()
end

local function panel_action(id)
    if id == "close" then
        close_panel()

    elseif id == "save" then
        save_settings()
        snapshot(saved)
        log("saved")

    -- Undo: back to the last saved values. Only meaningful while dirty, and the
    -- button is disabled when it is not.
    elseif id == "undo" then
        adopt(saved)
        log("unsaved changes discarded")

    -- Mod defaults: the values this mod ships with, not the game's.
    elseif id == "defaults" then
        adopt(DEFAULTS)
        log("back to the mod's default mix. Save to keep this.")

    -- Compare: a toggle, not a one-shot, so the game's own mix can be heard
    -- against this one by ear. That comparison is the entire job here. It was
    -- called Bypass until it also started playing a sample through every
    -- channel, at which point it stopped being an off switch and became an A/B
    -- test, and "Bypass: off" read as though it disabled the comparison.
    elseif id == "bypass" then
        model.bypassed = not model.bypassed
        if model.bypassed then
            reset_now()
            log("comparing: you are hearing the game's own mix")
        else
            applied = true
            apply_now()
            log("comparing: back to your mix")
        end
        -- After the switch, so the samples demonstrate whichever mix is now in
        -- effect rather than the one being left behind.
        play_samples(model.bypassed and "game's own mix" or "your mix")
    end
end

local function panel_process(event)
    if event == "toggle" then
        if panel then close_panel() else open_panel() end
        return
    end
    if not panel then return end
    if event == "next" or event == "previous" then
        local step = (event == "next") and 1 or -1
        model.selection = (model.selection - 1 + step) % #panel.buttons + 1
    elseif event == "activate" then
        local item = panel.buttons[model.selection]
        if item and item.control:GetIsEnabled() then panel_action(item.id) end
    elseif event == "click" then
        for index, item in ipairs(panel.buttons) do
            if item.control:IsHovered() and item.control:GetIsEnabled() then
                model.selection = index
                panel_action(item.id)
                break
            end
        end
    end
end

-- Keybind callbacks do not run on the game thread, so they only enqueue. The
-- loop below drains the queue where touching UObjects is safe.
local function queue(event)
    if panel_suspended then return end
    if event ~= "toggle" and not panel then return end
    if #panel_events < 16 then panel_events[#panel_events + 1] = event end
end

-- The panel's drain loop exists only while the panel is open.
--
-- It used to run at 10 Hz for the whole session. The early return inside it did
-- not help, because the callback is itself Lua: entering it at all takes the
-- Lua state lock, so the mod was acquiring that lock about eleven times a second
-- while doing nothing.
--
-- That matters here. A hang dump shows 32 threads blocked in WaitOnAddress,
-- which is what a C++ mutex blocks on, with UE4SS frames on their stacks. UE4SS
-- hooks ProcessEvent, so any game thread calling a UFunction passes through it,
-- and during a cutscene there are many. Constant lock traffic from this mod is
-- the one thing it contributes to that picture, so it should not be constant.
--
-- Open the panel and the loop starts. Close it and the loop ends. Idle cost goes
-- from about eleven Lua entries a second to the one from the verify loop.
local panel_loop_running = false
local tick = 0
local start_panel_loop
local panel_tick

if Panel then
    RegisterKeyBind(CONFIG.panel_key, function()
        queue("toggle")
        start_panel_loop()
    end)
    -- Left click only, and nothing else.
    --
    -- This used to bind the arrow keys and Enter as well, for keyboard
    -- navigation of the buttons. A UE4SS keybind cannot be unregistered, so
    -- those were permanent hooks on four gameplay keys and Enter, live whether
    -- the panel was open or not, driving a panel that the cursor handles anyway.
    --
    -- Left click stays because nothing binds UButton::OnClicked, so a click has
    -- to be noticed here and matched against whichever button is hovered.
    -- queue() drops it immediately when no panel is open.
    RegisterKeyBind(Key.LEFT_MOUSE_BUTTON, function() queue("click") end)

    -- Widgets do not survive a level change, and work already queued against the
    -- old world must not run against the new one. The epoch ticket discards it.
    pcall(function()
        RegisterLoadMapPreHook(function()
            panel_suspended = true
            epoch = epoch + 1
            panel_events = {}
            close_panel()
            -- Widgets belong to the old world and cannot be carried over, so
            -- this is the one place they are genuinely destroyed.
            if panel_cached then
                pcall(function() panel_cached:destroy() end)
                panel_cached = nil
            end
        end)
        RegisterLoadMapPostHook(function()
            panel_suspended = false
            -- Different area, different sounds loaded. Keeping the paddock's
            -- picks through a race is how you end up comparing grid-intro
            -- warmups against your race mix.
            forget_samples()
        end)
    end)

    start_panel_loop = function()
        if panel_loop_running then return end
        panel_loop_running = true
        LoopAsync(100, panel_tick)
    end
end

panel_tick = function()
        if panel_suspended or panel_busy then return false end

        -- Nothing open and nothing queued: stop the loop rather than idling.
        -- start_panel_loop brings it back when the key is pressed.
        if not panel and #panel_events == 0 then
            panel_loop_running = false
            return true
        end

        panel_busy = true
        local ticket = epoch
        local ok = pcall(ExecuteInGameThread, function()
            local fine, reason = pcall(function()
                if panel_suspended or ticket ~= epoch then return end

                if panel and not (valid(panel_owner) and valid(panel.widget)) then
                    close_panel(); panel_events = {}; return
                end

                if panel then
                    for _, key in ipairs(panel:read(model, CONFIG.duck_order)) do
                        apply_one(key)
                    end
                end

                local batch = panel_events
                panel_events = {}
                for _, event in ipairs(batch) do panel_process(event) end

                if panel then
                    -- Resize only needs checking when the viewport might have
                    -- changed, not ten times a second.
                    tick = tick + 1
                    if tick % 10 == 1 then panel:resize(panel_owner) end

                    -- A cutscene can start while the panel is already open, so
                    -- refusing to open during one is not enough on its own. Once
                    -- a second, because this walks the object array and the
                    -- panel is the thing being kept cheap.
                    if CONFIG.cutscene_guard and tick % 10 == 5 and cutscene() then
                        log("cutscene started, closing the panel")
                        close_panel(); panel_events = {}; return
                    end

                    -- Repaint only when something visible changed, plus a slow
                    -- poll so hover highlighting still responds.
                    local dirty = is_dirty()
                    if not panel:unchanged(model, CONFIG.duck_order, dirty)
                       or tick % 3 == 0 then
                        panel:update(model, CONFIG.duck_order, dirty)
                    end
                end
            end)
            panel_busy = false
            if not fine then
                log("panel error, closing: %s", tostring(reason))
                pcall(close_panel)
            end
        end)
        if not ok then panel_busy = false end
        return false
end

----------------------------------------------------------------------
-- bindings
----------------------------------------------------------------------

RegisterKeyBindAsync(Key.F7, { ModifierKey.CONTROL }, function() apply() end)
RegisterKeyBindAsync(Key.F8, { ModifierKey.CONTROL }, function() dump() end)
RegisterKeyBindAsync(Key.F9, { ModifierKey.CONTROL }, function() reset() end)

-- Press during a cutscene, then read the log. Same report as lac_cutscene, for
-- anyone who does not have the console turned on.
RegisterKeyBindAsync(Key.F10, { ModifierKey.CONTROL }, function() report_cutscene() end)

-- EXPERIMENTAL world boost, judged by ear.
--
-- Nudges CONFIG.boost's first entry, which is SC_SFX: engines, ambience,
-- impacts and world sound, all together, because there is no sound class that
-- separates them. Clamped at boost_ceiling because dialogue is already at 1.7x
-- and stacking boosts makes the limiter audible.
--
-- Not saved automatically. Save in the panel keeps it, or edit CONFIG.
local function nudge_boost(delta)
    local moved, at_limit = 0, 0
    local shown

    for _, relpath in ipairs(CONFIG.boost_order) do
        local current = CONFIG.boost[relpath] or 1.0
        local target = math.max(1.0,
            math.min(CONFIG.boost_ceiling, current + delta))
        target = math.floor(target * 100 + 0.5) / 100
        if math.abs(target - current) < 0.0001 then
            at_limit = at_limit + 1
        else
            CONFIG.boost[relpath] = target
            moved = moved + 1
            shown = target
        end
    end

    if moved == 0 then
        log("every boost is already at its %s", delta > 0 and "ceiling" or "floor")
        return
    end

    log("raised %d channel(s) to %.2fx (%+.1f dB)%s", moved, shown or 1.0,
        20 * math.log(shown or 1.0, 10),
        at_limit > 0 and string.format(", %d already at the limit", at_limit) or "")
    apply()
end

-- pcall because a UE4SS build that names these keys differently should not stop
-- the rest of the mod loading.
pcall(function()
    RegisterKeyBindAsync(Key.PAGE_UP, { ModifierKey.CONTROL },
        function() nudge_boost(CONFIG.boost_step) end)
    RegisterKeyBindAsync(Key.PAGE_DOWN, { ModifierKey.CONTROL },
        function() nudge_boost(-CONFIG.boost_step) end)
end)

RegisterConsoleCommandHandler("lac_apply", function() apply() return true end)
RegisterConsoleCommandHandler("lac_dump", function() dump() return true end)
RegisterConsoleCommandHandler("lac_reset", function() reset() return true end)

RegisterConsoleCommandHandler("lac_verify", function()
    ExecuteInGameThread(function()
        log("verify: %d values had drifted", verify())
    end)
    return true
end)

-- Live tuning, no reload needed. Drives the bus, which is the stage that
-- affects audio; an earlier version of this pointed at the inert submix write
-- and so did nothing at all.
RegisterConsoleCommandHandler("lac_set", function(_, parameters)
    if #parameters < 2 then
        log("usage: lac_set Submixes/SS_Music 0.5")
        return true
    end
    local relpath = parameters[1]
    local multiplier = tonumber(parameters[2])
    if not multiplier then
        log("'%s' is not a number", tostring(parameters[2]))
        return true
    end
    ExecuteInGameThread(function() set_bus_multiplier(relpath, multiplier) end)
    return true
end)

-- Run this during a cutscene. If it reports playing = false while one is
-- obviously on screen, the panel's cutscene guard cannot see this game's
-- cinematics and that needs knowing before trusting it.
-- lac_boost 1.25, or lac_boost with no argument to report the current value.
RegisterConsoleCommandHandler("lac_boost", function(_, parameters)
    local wanted = tonumber(parameters[1])
    if not wanted then
        log("boost levels, 1.0 to %.2f:", CONFIG.boost_ceiling)
        for _, relpath in ipairs(CONFIG.boost_order) do
            log("   %-28s %.2fx", relpath, CONFIG.boost[relpath] or 1.0)
        end
        log("lac_boost <mult> sets them all, or <class> <mult> sets one.")
        return true
    end

    -- Two forms: one argument sets every channel, two sets a named one.
    local named = tonumber(parameters[2])
    if named then
        local key = parameters[1]
        if CONFIG.boost[key] == nil then key = "Classes/" .. parameters[1] end
        if CONFIG.boost[key] == nil then
            log("no boost channel called %s", tostring(parameters[1]))
            return true
        end
        CONFIG.boost[key] = math.max(1.0, math.min(CONFIG.boost_ceiling, named))
        log("%s -> %.2fx", key, CONFIG.boost[key])
    else
        wanted = math.max(1.0, math.min(CONFIG.boost_ceiling, wanted))
        for _, relpath in ipairs(CONFIG.boost_order) do
            CONFIG.boost[relpath] = wanted
        end
        log("all boost channels -> %.2fx (%+.1f dB)",
            wanted, 20 * math.log(wanted, 10))
    end
    apply()
    return true
end)

-- What the loaded sounds actually route to, with counts. The README's class
-- tree says what exists; this says what is in play, which is what decides
-- whether a sample can be found.
local function report_sounds()
    local submixes, classes, total, routed = {}, {}, 0, 0
    for _, kind in ipairs({ "SoundCue", "SoundWave" }) do
        local ok, sounds = pcall(FindAllOf, kind)
        if ok and sounds then
            for _, sound in ipairs(sounds) do
                if valid(sound) then
                    total = total + 1
                    local any = false
                    pcall(function()
                        local sm = sound.SoundSubmixObject
                        if valid(sm) then
                            local n = sm:GetFName():ToString()
                            submixes[n] = (submixes[n] or 0) + 1
                            any = true
                        end
                    end)
                    pcall(function()
                        local sc = sound.SoundClassObject
                        if valid(sc) then
                            local n = sc:GetFName():ToString()
                            classes[n] = (classes[n] or 0) + 1
                            any = true
                        end
                    end)
                    if any then routed = routed + 1 end
                end
            end
        end
    end

    local function dump(label, tbl)
        local rows = {}
        for name, n in pairs(tbl) do rows[#rows + 1] = { name = name, n = n } end
        table.sort(rows, function(a, b) return a.n > b.n end)
        log("%s (%d distinct):", label, #rows)
        for i = 1, math.min(#rows, 40) do
            log("   %-34s %d", rows[i].name, rows[i].n)
        end
        if #rows == 0 then log("   none") end
    end

    log("%d sounds loaded, %d carry routing", total, routed)
    dump("submixes in use", submixes)
    dump("sound classes in use", classes)

    -- What could be chosen for each test class, so preferences can be set from
    -- what is loaded rather than from asset names guessed out of the pak index.
    local chosen = find_samples()
    for _, class_name in ipairs(CONFIG.test_classes) do
        local rows = {}
        for _, kind in ipairs({ "SoundCue", "SoundWave" }) do
            local ok, sounds = pcall(FindAllOf, kind)
            if ok and sounds then
                for _, sound in ipairs(sounds) do
                    if valid(sound) then
                        local name
                        pcall(function()
                            local sc = sound.SoundClassObject
                            if valid(sc) then name = sc:GetFName():ToString() end
                        end)
                        if name == class_name then
                            local d
                            pcall(function() d = sound.Duration end)
                            rows[#rows + 1] = {
                                asset = (sound:GetFullName() or ""):match("([^.]+)$") or "?",
                                d = type(d) == "number" and d or 0,
                            }
                        end
                    end
                end
            end
        end
        table.sort(rows, function(a, b) return a.d > b.d end)
        local picked = chosen[class_name]
        local picked_name = picked
            and ((picked:GetFullName() or ""):match("([^.]+)$") or "?") or nil
        log("%s: %d candidate(s)", class_name, #rows)
        for i = 1, math.min(#rows, 10) do
            log("   %s %-52s %.1fs",
                rows[i].asset == picked_name and "->" or "  ",
                rows[i].asset, rows[i].d)
        end
        if #rows == 0 then log("   none loaded here") end
    end
end

RegisterConsoleCommandHandler("lac_sounds", function()
    ExecuteInGameThread(report_sounds)
    return true
end)

-- No console by default, so the same report is on a key.
RegisterKeyBindAsync(Key.F11, { ModifierKey.CONTROL }, function()
    ExecuteInGameThread(report_sounds)
end)

RegisterConsoleCommandHandler("lac_cutscene", function()
    report_cutscene()
    return true
end)

RegisterConsoleCommandHandler("lac_param", function(_, parameters)
    local relpath = parameters[1] or "Modulation/Submixes/CB_SubmixVoice"
    ExecuteInGameThread(function()
        local obj = resolve(relpath)
        if not obj then
            log("could not resolve %s", relpath)
            return
        end
        dump_properties(obj, relpath)
        local parameter
        pcall(function() parameter = obj.Parameter end)
        if valid(parameter) then dump_properties(parameter, relpath .. " parameter") end
    end)
    return true
end)

-- Discards the stored authored volumes so the next apply re-captures them. Only
-- correct with the classes at their authored levels, so it resets first. Worth
-- running after a game patch, which can change the authored values.
RegisterConsoleCommandHandler("lac_forget", function()
    reset()
    ExecuteInGameThread(function()
        class_baseline = {}
        os.remove(BASELINE_FILE)
        log("forgot stored baseline. Next apply re-captures from live values.")
    end)
    return true
end)

----------------------------------------------------------------------
-- startup
----------------------------------------------------------------------

log("loaded. Ctrl+F7 apply, Ctrl+F8 dump, Ctrl+F9 reset")

-- Order matters. Settings layer the user's choices over the CONFIG defaults, so
-- they have to land before the first apply reads those values. The baseline is
-- what the game authored, and has to land before anything writes a class.
load_settings()
load_baseline()

if CONFIG.apply_on_start then
    -- Objects are not reachable until the audio device and the first world are
    -- up, so poll rather than firing once at script load.
    local waited = 0
    LoopAsync(1000, function()
        waited = waited + 1

        if not started then
            if world_context() and resolve("Submixes/SS_Main") then
                log("audio graph is up after %ds, applying", waited)
                if CONFIG.dump_on_start then dump() end
                apply()
            elseif waited % 15 == 0 then
                vlog("still waiting for the audio graph (%ds)", waited)
            end
            if waited > 300 then
                log("gave up waiting for the audio graph after 300s")
                return true
            end
            return false
        end

        if CONFIG.verify_seconds <= 0 then
            log("one-shot mode, verify loop exiting")
            return true
        end
        if waited % CONFIG.verify_seconds == 0 then
            ExecuteInGameThread(function() verify() end)
        end
        return false
    end)
end
