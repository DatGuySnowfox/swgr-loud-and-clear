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

    apply_on_start = true,

    -- Dump the audio graph once on the first apply. The dump is where the
    -- routing and the parameter ranges come from, so it should not depend on
    -- remembering a keypress.
    dump_on_start = true,

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

-- Before anything touches a class, recover the authored volumes.
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
