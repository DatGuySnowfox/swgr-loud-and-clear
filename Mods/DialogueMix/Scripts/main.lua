--[[
    SWGR Dialogue Mix
    UE4SS Lua mod for STAR WARS: Galactic Racer (UE project "Griffin")

    Purpose: make dialogue intelligible over the race mix.

    Two levers, both applied at the submix stage:
      1. Duck the submixes that mask speech (music, crowds, airflow, engines).
      2. Optionally boost the voice submixes.

    Lever 1 is the one to reach for. The game runs SE_Main_MixModeCompressor on
    the main bus, so pushing voice above its authored level feeds the compressor
    and drags the rest of the mix down unevenly. Pulling the maskers down buys
    the same intelligibility with no clipping and no pumping.

    Multipliers are relative to each submix's authored OutputVolume, captured on
    first apply, so 1.0 always means "as the sound designers shipped it".

    Keys:    Ctrl+F7 apply    Ctrl+F8 dump audio graph    Ctrl+F9 reset
    Console: dmx_apply | dmx_dump | dmx_reset | dmx_set <relpath> <multiplier>
--]]

local UEHelpers = require("UEHelpers")

local CONTENT = "/Game/Griffin/Audio/Mixing/"
local TAG = "[DialogueMix] "

----------------------------------------------------------------------
-- configuration
----------------------------------------------------------------------

local CONFIG = {
    -- Multiplier on the voice submixes. 1.0 leaves them alone.
    -- Raise this only if ducking alone is not enough; see the note above.
    -- Pinned at 1.0, and it cannot usefully be raised.
    --
    -- The buses run through MP_Volume, a SoundModulationParameterVolume whose
    -- only range property is MinVolume = -60.0. For that parameter type 0 dB is
    -- unity and also the ceiling: it maps [-60, 0] dB onto [0, 1] normalised and
    -- clamps. A request of +3.52 dB (x1.5) or +6.02 dB (x2.0) both normalise
    -- above 1.0 and clamp back to unity, which is why raising this was
    -- inaudible. Verified by dumping the parameter's real properties.
    --
    -- Ducking is therefore the only lever, and it has the full 60 dB to work in.
    dialogue_boost = 1.0,

    -- Multipliers on everything that competes with speech.
    duck = {
        ["Submixes/SS_Music"]                          = 0.60,
        ["Submixes/SS_Crowds"]                         = 0.65,
        ["Submixes/SS_HighSpeedAirflow"]               = 0.65,
        ["Submixes/SS_NonLocalPlayerEngineAndExhaust"] = 0.70,
        ["Submixes/SS_LocalPlayerEngine"]              = 0.75,
        ["Submixes/SS_LocalPlayerExhaust"]             = 0.75,
        ["Submixes/SS_Ambience"]                       = 0.80,
    },

    -- Parents only. Each submix has its own bus, and a gain set on a parent is
    -- inherited by its children, so listing both compounds the boost. The dump
    -- gives the routing:
    --
    --   SS_DiegeticVoice    -> SS_Voice
    --   SS_NonDiegeticVoice -> SS_Voice
    --   SS_Voice            -> SS_Main
    --   SS_Characters_Vox   -> SS_Characters   (separate branch)
    --
    -- so SS_Voice covers the diegetic and non-diegetic children. Boosting all
    -- three gave diegetic dialogue roughly +10.5 dB instead of +3.5 dB.
    -- SS_Characters_Vox is on its own branch and still needs naming.
    voice_submixes = {
        "Submixes/SS_Voice",
        "Submixes/SS_Voice_Cinematic",
        "Submixes/SS_Characters_Vox",
        "Submixes/SS_Commentary",
    },

    -- Submix relpath -> the control bus that actually drives its gain.
    --
    -- Writing OutputVolume on these submixes is measurably inert: the value is
    -- accepted, reads back unchanged on every verify pass, and does nothing
    -- audible. Each submix has its own CB_Submix* bus wired to its
    -- OutputVolumeModulation destination, and an enabled modulation destination
    -- drives the value while the base is bypassed. The bus is the live stage.
    bus_for = {
        ["Submixes/SS_Music"]                          = "Modulation/Submixes/CB_SubmixMusic",
        ["Submixes/SS_Crowds"]                         = "Modulation/Submixes/CB_SubmixCrowds",
        ["Submixes/SS_HighSpeedAirflow"]               = "Modulation/Submixes/CB_SubmixHighSpeedAirflow",
        ["Submixes/SS_NonLocalPlayerEngineAndExhaust"] = "Modulation/Submixes/CB_SubmixNonLocalPlayerEngineAndExhaust",
        ["Submixes/SS_LocalPlayerEngine"]              = "Modulation/Submixes/CB_SubmixLocalPlayerEngine",
        ["Submixes/SS_LocalPlayerExhaust"]             = "Modulation/Submixes/CB_SubmixLocalPlayerExhaust",
        ["Submixes/SS_Ambience"]                       = "Modulation/Submixes/CB_SubmixAmbience",
        ["Submixes/SS_Voice"]                          = "Modulation/Submixes/CB_SubmixVoice",
        ["Submixes/SS_Voice_Cinematic"]                = "Modulation/Submixes/CB_SubmixVoiceCinematic",
        ["Submixes/SS_Characters_Vox"]                 = "Modulation/Submixes/CB_SubmixCharactersVox",
        ["Submixes/SS_Commentary"]                     = "Modulation/Submixes/CB_SubmixCommentary",
    },

    -- Writing the base OutputVolume is measurably useless here: it reads back as
    -- nil on all 62 submixes and never changed anything audible, because each
    -- submix's gain comes from its OutputVolumeModulation destination instead.
    -- Off by default so the log stops reporting writes that do nothing. Turn it
    -- on only when investigating a submix whose modulation is disabled.
    also_write_submix = false,

    -- Sound class volume: a separate gain stage from the modulation buses, and
    -- the one place a real boost is possible.
    --
    -- FSoundClassProperties::Volume is a plain float with no unity ceiling, so
    -- it is not subject to the 0 dB clamp that makes dialogue_boost useless. It
    -- also reads back: all 61 classes report Volume=1.0, where submix
    -- OutputVolume reported nil, so a write here can be verified rather than
    -- assumed.
    --
    -- Parents only again. Class volume multiplies down the hierarchy:
    --   SC_Voice      -> SC_Commentary, SC_DiegeticVoice, SC_NonDiegeticVoice,
    --                    SC_Voice_Cinematic
    --   SC_Characters -> SC_Characters_Foley, SC_Characters_Vox
    -- so SC_Voice covers the four dialogue children, and SC_Characters_Vox is
    -- named directly because its parent also carries foley we do not want lifted.
    class_boost = 1.7,
    voice_classes = {
        "Classes/SC_Voice",
        "Classes/SC_Characters_Vox",
    },

    apply_on_start = true,

    -- Dump the audio graph once on the first apply. The dump is where the
    -- modulation parameter ranges come from, and those decide what units the
    -- bus values are in, so it should not depend on remembering a keypress.
    dump_on_start = true,

    -- How often to read our values back and check they still hold. Only
    -- re-applies what actually moved.
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
local function object_path(relpath)
    local short = relpath:match("([^/]+)$")
    return CONTENT .. relpath .. "." .. short
end

local function resolve(relpath)
    local path = object_path(relpath)
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
-- state
----------------------------------------------------------------------

-- relpath -> authored OutputVolume, captured once, before we touch anything.
local baseline = {}
-- relpath -> authored sound class Volume. Declared up here, not next to the
-- class code, because the persistence below has to be able to see it: a hot
-- reload would otherwise read the already-boosted 2.0 back as "authored" and
-- multiply it again, reaching 4.0 and then 8.0 across reloads.
local class_baseline = {}
-- relpath -> what we last wrote, so the verify pass can detect drift.
local expected = {}
local applied = false
local drift_reported = false

----------------------------------------------------------------------
-- baseline persistence
----------------------------------------------------------------------

-- The authored volumes have to outlive this Lua state. A hot reload (Ctrl+R)
-- hands the mod a fresh, empty baseline table while the submixes are still
-- ducked, so re-capturing from the live value would treat an already-reduced
-- volume as "authored" and multiply it again. Three reloads at 0.60 would take
-- SS_Music to 0.216. Writing the first capture to disk stops that, and also
-- survives a game restart.

local BASELINE_FILE = (function()
    -- Prefer the script's own directory so this does not depend on the working
    -- directory, which UE4SS sets to the ue4ss folder.
    local ok, info = pcall(debug.getinfo, 1, "S")
    -- The mod folder lives under Program Files, which is not writable without
    -- elevation, so a write next to the script fails silently in a normal
    -- session. Prefer the game's own save directory, which is writable, and
    -- only fall back to paths near the script.
    local candidates = {}

    local localappdata = os.getenv("LOCALAPPDATA")
    if localappdata then
        candidates[#candidates + 1] =
            localappdata .. "/StarWarsGalacticRacer/Saved/DialogueMix-baseline.txt"
    end

    if ok and info and info.source then
        local dir = info.source:gsub("^@", ""):match("^(.*)[/\\][^/\\]+$")
        if dir then candidates[#candidates + 1] = dir .. "/baseline.txt" end
    end
    candidates[#candidates + 1] = "Mods/DialogueMix/baseline.txt"

    -- Pick the first one we can actually open for append, so a path is only
    -- chosen if writing to it will work later.
    for _, path in ipairs(candidates) do
        local handle = io.open(path, "a")
        if handle then
            handle:close()
            return path
        end
    end

    return candidates[1] or "DialogueMix-baseline.txt"
end)()

local function save_baseline()
    local handle = io.open(BASELINE_FILE, "w")
    if not handle then
        log("could not write %s, baseline will not survive a reload", BASELINE_FILE)
        return false
    end
    handle:write("# authored volumes captured before this mod ran\n")
    handle:write("# delete this file, or run dmx_forget, to re-capture\n")
    for relpath, value in pairs(baseline) do
        handle:write(string.format("submix:%s=%.6f\n", relpath, value))
    end
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
            local key, value = line:match("^([^=]+)=(.+)$")
            local number = tonumber(value)
            if key and number then
                local kind, relpath = key:match("^(%a+):(.+)$")
                if kind == "class" then
                    class_baseline[relpath] = number
                elseif kind == "submix" then
                    baseline[relpath] = number
                else
                    -- Unprefixed keys are from an earlier format; those only
                    -- ever held submix values.
                    baseline[key] = number
                end
                count = count + 1
            end
        end
    end
    handle:close()
    if count > 0 then
        log("restored %d authored volumes from %s", count, BASELINE_FILE)
    end
    return count
end

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

-- UAudioModulationStatics is where the bus controls live. Resolved lazily
-- because the module may not be loaded when this script first runs.
local modulation_statics_cache = nil

local function modulation_statics()
    if modulation_statics_cache and valid(modulation_statics_cache) then
        return modulation_statics_cache
    end
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
--
-- Guessing field names (UnitMin, MaxValue and friends) came back empty, which
-- left the important question open: whether this parameter clamps at 0 dB, and
-- therefore whether a positive boost does anything at all. Asking the reflection
-- system what the properties actually are answers that without having to judge
-- a couple of dB by ear.
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

-- Reports what a bus's modulation parameter looks like, so the unit space the
-- bus values live in is read off the game rather than assumed.
local function describe_parameter(bus)
    local parameter
    pcall(function() parameter = bus.Parameter end)
    if not valid(parameter) then return nil, "<no parameter>" end

    local class_name = "<unknown>"
    pcall(function() class_name = parameter:GetClass():GetFName():ToString() end)

    local fields = {}
    for _, name in ipairs({ "UnitMin", "UnitMax", "MinValue", "MaxValue", "DefaultValue" }) do
        local value = read_float(parameter, name)
        if value then fields[#fields + 1] = string.format("%s=%.3f", name, value) end
    end

    return class_name, table.concat(fields, " ")
end

-- Converts a linear gain multiplier into the value a bus expects.
-- A volume parameter is in decibels; anything else is treated as normalised.
local positive_gain_warned = false

local function bus_value_for(multiplier, class_name)
    if class_name and class_name:lower():find("volume") then
        if multiplier <= 0 then return -96.0 end
        local decibels = 20.0 * (math.log(multiplier, 10))

        -- A volume parameter treats 0 dB as unity and as its ceiling, so asking
        -- for more is silently clamped. Clamp here instead, and say so once, so
        -- the log stops reporting a gain that the audio engine is discarding.
        if decibels > 0 then
            if not positive_gain_warned then
                positive_gain_warned = true
                log("x%.2f wants %+.2f dB, but 0 dB is unity and the ceiling for", multiplier, decibels)
                log("this parameter. Clamping to 0 dB. Duck the maskers instead.")
            end
            return 0.0
        end

        return decibels
    end
    return multiplier
end

-- relpath -> what we last wrote to its bus, for the verify pass.
local bus_expected = {}

local function set_bus_multiplier(relpath, multiplier)
    local bus_rel = CONFIG.bus_for[relpath]
    if not bus_rel then return false end

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

    bus_expected[relpath] = value
    vlog("bus %s = %.3f (x%.2f, parameter %s %s)",
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
    local ok = pcall(function() statics:ClearGlobalBusMixValue(world, bus, 0.1) end)
    if ok then bus_expected[relpath] = nil end
    return ok
end

----------------------------------------------------------------------
-- the actual work
----------------------------------------------------------------------

-- Returns true if the submix volume was set.
local function set_submix_multiplier(relpath, multiplier)
    local submix, path = resolve(relpath)
    if not submix then
        vlog("skip %s (not loaded)", path)
        return false
    end

    if baseline[relpath] == nil then
        baseline[relpath] = read_float(submix, "OutputVolume") or 1.0
        -- Persist immediately: a crash or reload before the next save would
        -- otherwise lose the only record of the authored value.
        save_baseline()
    end

    local target = baseline[relpath] * multiplier
    local world = world_context()
    if not world then
        log("no world context yet, deferring %s", relpath)
        return false
    end

    -- SetSubmixOutputVolume is a USoundSubmix member taking (WorldContext, Volume).
    -- Guarded because the reflected signature is what matters, not our assumption
    -- about it, and a mismatch here would otherwise take the game down.
    local ok, err = pcall(function()
        submix:SetSubmixOutputVolume(world, target)
    end)

    if not ok then
        log("SetSubmixOutputVolume failed on %s: %s", relpath, tostring(err))
        return false
    end

    expected[relpath] = target
    vlog("%s  %.3f -> %.3f  (x%.2f)", relpath, baseline[relpath], target, multiplier)
    return true
end

-- Writes a sound class volume and reads it back to confirm it took.
-- This stage is readable, so unlike the submix write there is no need to infer
-- success from the absence of an error.
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
        -- Persist before the first write, so a reload cannot mistake the
        -- boosted value for the authored one.
        save_baseline()
    end

    local target = class_baseline[relpath] * multiplier

    local ok, err = pcall(function()
        class.Properties.Volume = target
    end)
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

-- Builds the full relpath -> multiplier map for one pass.
local function targets()
    local map = {}
    for relpath, multiplier in pairs(CONFIG.duck) do
        map[relpath] = multiplier
    end
    if CONFIG.dialogue_boost ~= 1.0 then
        for _, relpath in ipairs(CONFIG.voice_submixes) do
            map[relpath] = CONFIG.dialogue_boost
        end
    end
    return map
end

local function apply()
    -- Claim the work before going async. ExecuteInGameThread defers, so leaving
    -- this until the callback let the startup poll fire a second apply in the
    -- gap, which is why the first run applied everything twice.
    applied = true

    ExecuteInGameThread(function()
        local buses, attempted = 0, 0
        -- Counted separately. Sharing the bus counter made the summary read
        -- "0/7 submix volumes" when also_write_submix is off, which looks like
        -- seven failures rather than nothing attempted.
        local submixes, submix_attempted = 0, 0

        for relpath, multiplier in pairs(targets()) do
            attempted = attempted + 1
            if set_bus_multiplier(relpath, multiplier) then buses = buses + 1 end
            if CONFIG.also_write_submix then
                submix_attempted = submix_attempted + 1
                if set_submix_multiplier(relpath, multiplier) then submixes = submixes + 1 end
            end
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

        log("applied: %d/%d control buses, %d/%d submix volumes, %d/%d class volumes",
            buses, attempted, submixes, submix_attempted, classes, class_attempted)

        if buses == 0 then
            applied = false
            log("no control bus took a value. The buses are the stage that")
            log("actually affects audio here, so check the dump for their real names.")
        end
    end)
end

local function reset()
    ExecuteInGameThread(function()
        local cleared, restored = 0, 0
        local world = world_context()

        for relpath in pairs(CONFIG.bus_for) do
            if clear_bus(relpath) then cleared = cleared + 1 end
        end

        for relpath, authored in pairs(baseline) do
            local submix = resolve(relpath)
            if submix and world then
                local ok = pcall(function() submix:SetSubmixOutputVolume(world, authored) end)
                if ok then restored = restored + 1 end
            end
        end

        local classes = reset_classes()

        applied = false
        expected = {}
        bus_expected = {}
        log("reset: cleared %d bus overrides, restored %d submix and %d class volumes",
            cleared, restored, classes)
    end)
end

-- Reads our submix volumes back and re-applies only the ones that moved.
-- Returns the number that had drifted, which is the number we care about: if it
-- stays at zero across sessions, nothing in the game contests these writes and
-- the verify loop can be switched off entirely.
local function verify()
    local drifted = 0

    for relpath, want in pairs(expected) do
        local submix = resolve(relpath)
        if submix then
            local actual = read_float(submix, "OutputVolume")
            -- Float comparison needs slack; anything this close is our own value.
            if actual and math.abs(actual - want) > 0.0005 then
                drifted = drifted + 1
                log("drift on %s: expected %.3f, found %.3f. Re-applying.",
                    relpath, want, actual)
                local multiplier = CONFIG.duck[relpath] or CONFIG.dialogue_boost
                set_submix_multiplier(relpath, multiplier)
            end
        end
    end

    -- The meaningful check. Sound class volume is the stage that audibly works
    -- and the only one that reads back, so this is the one place drift can
    -- actually be measured rather than inferred.
    local checked = 0
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
                        log("drift on class %s: expected %.3f, found %.3f. Re-applying.",
                            relpath, want, actual)
                        set_class_multiplier(relpath, CONFIG.class_boost)
                    end
                end
            end
        end
    end

    if drifted == 0 and not drift_reported then
        drift_reported = true
        log("verify: %d class volumes still hold (measured, this stage reads back)",
            checked)
    elseif drifted > 0 then
        drift_reported = false
    end

    return drifted
end

----------------------------------------------------------------------
-- discovery
----------------------------------------------------------------------

-- Dumps what is actually loaded rather than what we expect to be loaded.
-- Use this to confirm the submix routing before trusting any multiplier: there
-- are six voice submixes and the parent chain decides which one is worth touching.
local function dump()
    ExecuteInGameThread(function()
        log("================ audio graph ================")

        local ok, submixes = pcall(FindAllOf, "SoundSubmix")
        if ok and type(submixes) == "table" then
            log("-- submixes (%d loaded) --", #submixes)
            for _, submix in pairs(submixes) do
                if valid(submix) then
                    local parent = "<root>"
                    pcall(function()
                        local p = submix.ParentSubmix
                        if valid(p) then parent = full_name(p) end
                    end)
                    log("  %s  OutputVolume=%s  DryLevel=%s  WetLevel=%s  parent=%s",
                        full_name(submix),
                        tostring(read_float(submix, "OutputVolume")),
                        tostring(read_float(submix, "DryLevel")),
                        tostring(read_float(submix, "WetLevel")),
                        parent)
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
                        full_name(class), tostring(volume), table.concat(children, ", "))
                end
            end
        end

        -- Control buses carry the settings sliders. Their live value lives inside
        -- the modulation system rather than on the object, so this prints the
        -- parameter each bus is bound to: that is what decides whether a value
        -- above the slider maximum survives or gets normalised away.
        -- The buses are the stage that actually moves audio here, so this is the
        -- important section: it reports each bus's parameter class and range,
        -- which is what decides the unit space SetGlobalBusMixValue expects.
        local okb, buses = pcall(FindAllOf, "SoundControlBus")
        if okb and type(buses) == "table" then
            log("-- control buses (%d loaded) --", #buses)
            for _, bus in pairs(buses) do
                if valid(bus) then
                    local class_name, ranges = describe_parameter(bus)
                    log("  %s  parameter=%s %s",
                        full_name(bus), tostring(class_name), ranges or "")
                end
            end
        else
            log("FindAllOf('SoundControlBus') returned nothing usable")
        end

        log("-- modulation statics --")
        local statics = modulation_statics()
        log("  AudioModulationStatics: %s",
            statics and full_name(statics) or "<NOT FOUND, buses cannot be driven>")

        -- The decisive section. Everything about whether a positive boost can
        -- work is in these two objects' real property lists.
        local voice_bus = resolve("Modulation/Submixes/CB_SubmixVoice")
        if voice_bus then
            dump_properties(voice_bus, "CB_SubmixVoice")
            local parameter
            pcall(function() parameter = voice_bus.Parameter end)
            dump_properties(parameter, "its modulation parameter")
        else
            log("  CB_SubmixVoice not resolvable, cannot inspect the parameter")
        end

        local mp_volume = resolve("Modulation/Parameters/MP_Volume")
        if mp_volume then dump_properties(mp_volume, "MP_Volume") end

        log("================ end ================")
    end)
end

----------------------------------------------------------------------
-- bindings
----------------------------------------------------------------------

RegisterKeyBindAsync(Key.F7, { ModifierKey.CONTROL }, function() apply() end)
RegisterKeyBindAsync(Key.F8, { ModifierKey.CONTROL }, function() dump() end)
RegisterKeyBindAsync(Key.F9, { ModifierKey.CONTROL }, function() reset() end)

RegisterConsoleCommandHandler("dmx_apply", function() apply() return true end)
RegisterConsoleCommandHandler("dmx_dump", function() dump() return true end)
RegisterConsoleCommandHandler("dmx_reset", function() reset() return true end)

-- Forgets the stored authored volumes so the next apply re-captures them.
-- Only correct to run when the submixes are at their authored levels, so it
-- resets them first.
RegisterConsoleCommandHandler("dmx_forget", function()
    reset()
    ExecuteInGameThread(function()
        baseline = {}
        class_baseline = {}
        expected = {}
        bus_expected = {}
        os.remove(BASELINE_FILE)
        log("forgot stored baseline. Next apply re-captures from live values.")
    end)
    return true
end)

-- dmx_param <relpath> dumps every property on any object, for when a value
-- needs reading off the game rather than assuming a field name.
RegisterConsoleCommandHandler("dmx_param", function(_, parameters)
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

RegisterConsoleCommandHandler("dmx_verify", function()
    ExecuteInGameThread(function()
        local drifted = verify()
        log("verify: %d of our submixes had drifted", drifted)
    end)
    return true
end)

RegisterConsoleCommandHandler("dmx_set", function(_, parameters)
    if #parameters < 2 then
        log("usage: dmx_set Submixes/SS_Music 0.5")
        return true
    end
    local relpath = parameters[1]
    local multiplier = tonumber(parameters[2])
    if not multiplier then
        log("'%s' is not a number", tostring(parameters[2]))
        return true
    end
    ExecuteInGameThread(function() set_submix_multiplier(relpath, multiplier) end)
    return true
end)

----------------------------------------------------------------------
-- startup
----------------------------------------------------------------------

log("loaded. Ctrl+F7 apply, Ctrl+F8 dump, Ctrl+F9 reset")

-- Before anything touches a submix, recover the authored volumes from a
-- previous session or a previous load of this script.
load_baseline()

if CONFIG.apply_on_start then
    -- Submix assets are not reachable until the audio device and the first world
    -- are up, so poll rather than firing once at script load.
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

        -- Applied. Either stop here, or settle into the verify cadence.
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
