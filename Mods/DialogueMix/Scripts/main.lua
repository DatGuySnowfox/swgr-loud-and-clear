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
    dialogue_boost = 1.5,

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

    voice_submixes = {
        "Submixes/SS_Voice",
        "Submixes/SS_Voice_Cinematic",
        "Submixes/SS_Characters_Vox",
        "Submixes/SS_DiegeticVoice",
        "Submixes/SS_NonDiegeticVoice",
        "Submixes/SS_Commentary",
    },

    apply_on_start = true,

    -- How often to read our submix volumes back and check they still hold.
    -- This is a verification pass, not a blind rewrite: it only re-applies when
    -- a value has actually drifted, and logs when that happens.
    --
    -- The expectation is that it never does. SetSubmixOutputVolume writes the
    -- base OutputVolume, while the game's control buses drive the separate
    -- OutputVolumeModulation destination, so the two should not collide. If the
    -- log never reports drift over a few sessions, set this to 0 and the mod
    -- becomes a one-shot at startup.
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
-- relpath -> what we last wrote, so the verify pass can detect drift.
local expected = {}
local applied = false
local drift_reported = false

local function world_context()
    local ok, world = pcall(UEHelpers.GetWorldContextObject)
    if ok and valid(world) then return world end
    local ok2, fallback = pcall(UEHelpers.GetWorld)
    if ok2 and valid(fallback) then return fallback end
    return nil
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

local function apply()
    ExecuteInGameThread(function()
        local changed, attempted = 0, 0

        for relpath, multiplier in pairs(CONFIG.duck) do
            attempted = attempted + 1
            if set_submix_multiplier(relpath, multiplier) then changed = changed + 1 end
        end

        if CONFIG.dialogue_boost ~= 1.0 then
            for _, relpath in ipairs(CONFIG.voice_submixes) do
                attempted = attempted + 1
                if set_submix_multiplier(relpath, CONFIG.dialogue_boost) then changed = changed + 1 end
            end
        end

        applied = changed > 0
        log("applied %d/%d submix changes", changed, attempted)

        if changed == 0 then
            log("nothing applied. Run Ctrl+F8 to dump the audio graph and check")
            log("whether these submixes are loaded and what they are really called.")
        end
    end)
end

local function reset()
    ExecuteInGameThread(function()
        local restored = 0
        local world = world_context()
        for relpath, authored in pairs(baseline) do
            local submix = resolve(relpath)
            if submix and world then
                local ok = pcall(function() submix:SetSubmixOutputVolume(world, authored) end)
                if ok then restored = restored + 1 end
            end
        end
        applied = false
        expected = {}
        log("restored %d submixes to authored levels", restored)
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

    if drifted == 0 and not drift_reported then
        drift_reported = true
        log("verify: all %d submixes still hold their values.",
            (function() local n = 0 for _ in pairs(expected) do n = n + 1 end return n end)())
        log("verify: if this stays quiet, set verify_seconds = 0 to go one-shot.")
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
        local okb, buses = pcall(FindAllOf, "SoundControlBus")
        if okb and type(buses) == "table" then
            log("-- control buses (%d loaded) --", #buses)
            for _, bus in pairs(buses) do
                if valid(bus) then
                    local parameter = "<none>"
                    pcall(function()
                        local p = bus.Parameter
                        if valid(p) then parameter = full_name(p) end
                    end)
                    log("  %s  parameter=%s", full_name(bus), parameter)
                end
            end
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

RegisterConsoleCommandHandler("dmx_apply", function() apply() return true end)
RegisterConsoleCommandHandler("dmx_dump", function() dump() return true end)
RegisterConsoleCommandHandler("dmx_reset", function() reset() return true end)

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

if CONFIG.apply_on_start then
    -- Submix assets are not reachable until the audio device and the first world
    -- are up, so poll rather than firing once at script load.
    local waited = 0
    LoopAsync(1000, function()
        waited = waited + 1

        if not applied then
            if world_context() and resolve("Submixes/SS_Main") then
                log("audio graph is up after %ds, applying", waited)
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
