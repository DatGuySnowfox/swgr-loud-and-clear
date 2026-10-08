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

local applied = false
local drift_reported = false

local function apply()
    -- Claim the work before going async. ExecuteInGameThread defers, so leaving
    -- this until the callback let the startup poll fire a second apply.
    applied = true

    ExecuteInGameThread(function()
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

        log("applied: %d/%d buses ducked, %d/%d class volumes boosted",
            buses, bus_attempted, classes, class_attempted)

        if buses == 0 and classes == 0 then
            applied = false
            log("nothing applied. Ctrl+F8 dumps the audio graph so you can check")
            log("whether these objects are loaded and what they are really called.")
        end
    end)
end

local function reset()
    ExecuteInGameThread(function()
        local cleared = 0
        for relpath in pairs(CONFIG.duck) do
            if clear_bus(relpath) then cleared = cleared + 1 end
        end
        local classes = reset_classes()
        applied = false
        log("reset: cleared %d bus overrides, restored %d class volumes",
            cleared, classes)
    end)
end

-- Reads the class volumes back and re-applies only what moved. This is the only
-- stage that can be measured: a bus override cannot be read back, because its
-- live value lives inside the modulation system rather than on the object.
local function verify()
    local drifted, checked = 0, 0

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
    local source = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
    local dir = source:match("^(.*)/[^/]+$")
    local ok, mod = pcall(dofile, dir .. "/Panel.lua")
    if ok and type(mod) == "table" then return mod end
    log("panel unavailable: %s", tostring(mod))
    return nil
end)()

local panel, panel_owner, cursor_before
local saved = { class_boost = nil, duck = {} }
local model = { selection = 1, duck = {} }
local panel_events = {}
local panel_busy, panel_suspended = false, false
local epoch = 0

local function snapshot(into)
    into.class_boost = CONFIG.class_boost
    into.duck = {}
    for relpath, value in pairs(CONFIG.duck) do into.duck[relpath] = value end
end

local function is_dirty()
    if not saved.class_boost then return false end
    if math.abs(model.class_boost - saved.class_boost) > 0.0001 then return true end
    for relpath, value in pairs(model.duck) do
        if math.abs(value - (saved.duck[relpath] or value)) > 0.0001 then return true end
    end
    return false
end

-- Pushes a single changed value straight at the audio engine, so dragging a
-- slider is audible immediately.
local function apply_one(key)
    if key == "class_boost" then
        CONFIG.class_boost = model.class_boost
        for _, relpath in ipairs(CONFIG.voice_classes) do
            set_class_multiplier(relpath, CONFIG.class_boost)
        end
    else
        CONFIG.duck[key] = model.duck[key]
        set_bus_multiplier(key, model.duck[key])
    end
end

local function close_panel()
    local old_panel, old_owner = panel, panel_owner
    panel, panel_owner = nil, nil
    if old_panel and old_panel.widget and valid(old_panel.widget) then
        pcall(function() old_panel.widget:RemoveFromParent() end)
    end
    if valid(old_owner) then
        pcall(function()
            old_owner.bShowMouseCursor = cursor_before
            StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
                :SetInputMode_GameOnly(old_owner, false)
        end)
    end
end

local function open_panel()
    if not Panel then return false end
    local pc
    local ok = pcall(function() pc = UEHelpers.GetPlayerController() end)
    if not (ok and valid(pc)) then return false end

    snapshot(model)
    snapshot(saved)
    model.selection = 1

    local created, err = pcall(function()
        return Panel.create(pc, model, CONFIG.duck_order)
    end)
    if not created then
        log("could not open the panel: %s", tostring(err))
        return false
    end
    panel = err
    panel_owner = pc
    cursor_before = pc.bShowMouseCursor

    panel:write(model, CONFIG.duck_order)
    pcall(function()
        pc.bShowMouseCursor = true
        StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
            :SetInputMode_UIOnlyEx(pc, panel.widget, 0, false)
    end)
    panel:resize(pc)
    panel:update(model, CONFIG.duck_order, false)
    log("panel open")
    return true
end

local function panel_action(id)
    if id == "close" then close_panel(); return end
    if id == "save" then
        save_settings()
        snapshot(saved)
        log("settings saved to %s", SETTINGS_FILE)
    elseif id == "revert" then
        CONFIG.class_boost = saved.class_boost
        for relpath, value in pairs(saved.duck) do CONFIG.duck[relpath] = value end
        snapshot(model)
        panel:write(model, CONFIG.duck_order)
        apply()
    elseif id == "defaults" then
        reset()
        log("restored the game's own levels. Save to keep this.")
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

if Panel then
    RegisterKeyBind(CONFIG.panel_key, function() queue("toggle") end)
    for key, event in pairs({
        [Key.UP_ARROW] = "previous", [Key.LEFT_ARROW] = "previous",
        [Key.DOWN_ARROW] = "next",   [Key.RIGHT_ARROW] = "next",
        [Key.RETURN] = "activate",   [Key.LEFT_MOUSE_BUTTON] = "click",
    }) do
        RegisterKeyBind(key, function() queue(event) end)
    end

    -- Widgets do not survive a level change, and work already queued against the
    -- old world must not run against the new one. The epoch ticket discards it.
    pcall(function()
        RegisterLoadMapPreHook(function()
            panel_suspended = true
            epoch = epoch + 1
            panel_events = {}
            close_panel()
        end)
        RegisterLoadMapPostHook(function() panel_suspended = false end)
    end)

    LoopAsync(100, function()
        if panel_suspended or panel_busy then return false end
        if not panel and #panel_events == 0 then return false end

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
                    panel:resize(panel_owner)
                    panel:update(model, CONFIG.duck_order, is_dirty())
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
    end)
end

----------------------------------------------------------------------
-- bindings
----------------------------------------------------------------------

RegisterKeyBindAsync(Key.F7, { ModifierKey.CONTROL }, function() apply() end)
RegisterKeyBindAsync(Key.F8, { ModifierKey.CONTROL }, function() dump() end)
RegisterKeyBindAsync(Key.F9, { ModifierKey.CONTROL }, function() reset() end)

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

        if not applied then
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
