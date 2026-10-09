--[[
    In-game mix panel, built as native UMG widgets at runtime.

    No ImGui, no C++, and deliberately no blueprint. The host is a bare
    /Script/UMG.UserWidget with a WidgetTree constructed by hand, and every
    widget in it comes from /Script/UMG. Nothing here loads or instantiates a
    class from /Game, which is what the first version did and what took the game
    down. See the note on Panel.create.

    Sliders apply live, so a change is audible while dragging rather than after
    pressing something. That is the whole point of having a panel here: mix
    values are judged by ear, and a console round trip breaks that loop.
--]]

local Panel = {}

-- UMG colours are linear, so sRGB values from a palette need converting or
-- everything comes out washed out.
local function colour(r, g, b, a)
    local function channel(x)
        x = x / 255
        return x <= 0.04045 and x / 12.92 or ((x + 0.055) / 1.055) ^ 2.4
    end
    return { R = channel(r), G = channel(g), B = channel(b), A = a or 1 }
end

local PANEL_BG   = colour(16, 20, 30, 0.96)
local ROW_BG     = colour(26, 32, 46, 0.9)
local AMBER      = colour(255, 186, 73)
local CYAN       = colour(178, 232, 248)
local CYAN_DIM   = colour(122, 196, 222)
local TEXT       = colour(236, 242, 250)
local MUTED      = colour(132, 150, 176)
local DISABLED   = colour(90, 100, 118)
local BAR        = colour(44, 58, 80)

local function tint(label, c)
    pcall(function() label:SetColorAndOpacity({ SpecifiedColor = c, ColorUseRule = 0 }) end)
end

-- Short, human labels. The asset names are precise but unreadable in a UI.
local DISPLAY = {
    ["Submixes/SS_Music"]                          = "Music",
    ["Submixes/SS_Crowds"]                         = "Crowds",
    ["Submixes/SS_HighSpeedAirflow"]               = "Airflow",
    ["Submixes/SS_NonLocalPlayerEngineAndExhaust"] = "Rival engines",
    ["Submixes/SS_LocalPlayerEngine"]              = "Your engine",
    ["Submixes/SS_LocalPlayerExhaust"]             = "Your exhaust",
    ["Submixes/SS_Ambience"]                       = "Ambience",

    -- Boost channels. Sound classes, not submixes.
    ["Classes/SC_Music_Race"]                      = "Music",
    ["Classes/SC_Characters"]                      = "Crowds",
    ["Classes/SC_HighSpeedAirflow"]                = "Airflow",
    ["Classes/SC_NonLocalPlayerEngineAndExhaust"]  = "Rival engines",
    ["Classes/SC_LocalPlayerEngine"]               = "Your engine",
    ["Classes/SC_LocalPlayerExhaust"]              = "Your exhaust",
    ["Classes/SC_Ambience"]                        = "Ambience",
}

local function decibels(multiplier)
    if multiplier <= 0 then return "-inf" end
    return string.format("%+.1f dB", 20 * math.log(multiplier, 10))
end

function Panel.create(controller, model, order, focusable, pair)
    -- Why the host is built this way rather than borrowed.
    --
    -- The first version created one of the game's own widget blueprints,
    -- WBP_SectionSubLabel_C, purely because a blueprint widget comes with a
    -- usable WidgetTree, and then replaced that tree's RootWidget. The cost was
    -- a live instance of a game blueprint class sitting on screen, running its
    -- PreConstruct, Construct and per-frame Tick against a tree it no longer
    -- recognised.
    --
    -- A full-memory dump taken at one of the freezes put the main thread in
    -- UObject::ProcessContextOpcode, the engine's handler for the blueprint
    -- Context opcode, with RSP below its own stack base: a stack overflow from
    -- unbounded recursion inside the Blueprint VM. That borrowed host was the
    -- mod's only contact with blueprint code, so it is gone.
    --
    -- Everything below comes from /Script/UMG. Nothing touches /Game.
    local user_widget_class = StaticFindObject("/Script/UMG.UserWidget")
    assert(user_widget_class and user_widget_class:IsValid(),
        "UMG.UserWidget unavailable")
    local widget_tree_class = StaticFindObject("/Script/UMG.WidgetTree")
    assert(widget_tree_class and widget_tree_class:IsValid(),
        "UMG.WidgetTree unavailable")

    local self = { sliders = {}, values = {}, buttons = {}, scale = {},
                   width = 470, height = 40, pair = pair or {} }

    -- Outered to the controller so UUserWidget::GetWorld resolves through it.
    -- A widget built this way never runs Initialize(), which is the thing that
    -- would normally clone a tree from the generated class, so the tree is
    -- supplied directly instead.
    self.widget = StaticConstructObject(user_widget_class, controller)
    assert(self.widget and self.widget:IsValid(),
        "Could not construct the host widget")

    local tree = StaticConstructObject(widget_tree_class, self.widget)
    assert(tree and tree:IsValid(), "Could not construct the widget tree")
    self.widget.WidgetTree = tree

    -- Sets Player, which AddToViewport needs to find a screen to attach to.
    local owned = pcall(function() self.widget:SetOwningPlayer(controller) end)
    if not owned then
        pcall(function() self.widget.Player = controller.Player end)
    end

    local function make(kind)
        local class = StaticFindObject("/Script/UMG." .. kind)
        assert(class and class:IsValid(), "UMG class unavailable: " .. kind)
        local widget = StaticConstructObject(class, tree)
        assert(widget and widget:IsValid(), "Could not construct " .. kind)
        return widget
    end

    local function label(text, size, c)
        local item = make("TextBlock")
        pcall(function() item.Font.Size = size end)
        item:SetText(FText(text))
        item:SetAutoWrapText(false)
        tint(item, c or TEXT)
        return item
    end

    local canvas = make("CanvasPanel")
    tree.RootWidget = canvas

    self.frame = make("Border")
    self.frame:SetBrushColor(PANEL_BG)
    self.frame:SetPadding({ Left = 20, Top = 18, Right = 20, Bottom = 18 })
    self.frame:SetRenderTransformPivot({ X = 1, Y = 0 })

    local slot = canvas:AddChildToCanvas(self.frame)
    slot:SetAnchors({ Minimum = { X = 1, Y = 0 }, Maximum = { X = 1, Y = 0 } })
    slot:SetAlignment({ X = 1, Y = 0 })
    slot:SetPosition({ X = -24, Y = 24 })

    local column = make("VerticalBox")
    self.frame:AddChild(column)

    local function add(item, height, gap)
        gap = gap or 6
        local box = make("SizeBox")
        box:SetHeightOverride(height)
        box:AddChild(item)
        column:AddChildToVerticalBox(box):SetPadding(
            { Left = 0, Top = 0, Right = 0, Bottom = gap })
        self.height = self.height + height + gap
    end

    -- Header
    add(label("LOUD AND CLEAR", 24, AMBER), 32, 2)
    add(label("Dialogue mix  /  changes apply as you drag", 13, MUTED), 20, 10)
    local rule = make("Border"); rule:SetBrushColor(BAR); add(rule, 2, 14)

    -- A labelled slider row: caption on the left, live readout on the right,
    -- slider underneath. Returns nothing; everything is stashed on self.
    local function slider_row(key, caption, minimum, maximum, step, readout, normalised)
        local head = make("HorizontalBox")
        head:AddChildToHorizontalBox(label(caption, 15, TEXT))
            :SetSize({ SizeRule = 1, Value = 1 })
        local value = label("", 15, CYAN)
        value:SetJustification(2)
        head:AddChildToHorizontalBox(value):SetSize({ SizeRule = 1, Value = 1 })
        add(head, 22, 2)

        -- What a probe on these reported, kept because it explains the shape
        -- of the code above. SetMinValue and SetMaxValue do take: a 1.0 to 3.0
        -- slider read back MinValue=1.0 MaxValue=3.0. But Value stayed at
        -- 0.0000, outside its own range, because SetMinValue does not drag the
        -- current value up with it. Panel:write calls SetValue on open, which
        -- is what rescues the duck and voice sliders. MouseUsesStep was false
        -- throughout, so StepSize never affected dragging.
        local control = make("Slider")
        if normalised then
            -- Left on the default 0..1. self.scale carries the real range and
            -- read/write/update convert. See the note on this file's history:
            -- a slider configured with SetMinValue(1.0)/SetMaxValue(2.0) only
            -- travelled 0.01, and this sidesteps whatever caused that.
            self.scale[key] = { lo = minimum, hi = maximum }
            control:SetStepSize(step / (maximum - minimum))
        else
            control:SetMinValue(minimum)
            control:SetMaxValue(maximum)
            control:SetStepSize(step)
        end
        control:SetSliderBarColor(BAR)
        control:SetSliderHandleColor(key == "class_boost" and AMBER or CYAN_DIM)
        add(control, 20, 12)

        self.sliders[key] = control
        self.values[key] = { widget = value, format = readout }
    end

    add(label("DIALOGUE", 13, MUTED), 18, 4)
    slider_row("class_boost", "Voice level", 1.0, 3.0, 0.05,
               function(v) return string.format("%.2fx", v) end)

    -- One slider per channel. Left of centre cuts through the submix bus,
    -- right of centre raises through the paired sound class, because neither
    -- stage can do both directions. Normalised, so the control keeps its native
    -- 0..1 range and the mapping happens in Lua.
    add(label("THE MIX AROUND IT", 13, MUTED), 18, 4)
    for _, relpath in ipairs(order) do
        slider_row(relpath, DISPLAY[relpath] or relpath,
                   0.15, 2.0, 0.01, decibels, true)
    end

    local rule2 = make("Border"); rule2:SetBrushColor(BAR); add(rule2, 2, 12)

    self.status = label("", 13, MUTED)
    add(self.status, 18, 8)

    local function button(id, text, parent)
        local control = make("Button")
        local caption = label(text, 14, TEXT)
        caption:SetJustification(1)
        local content = control:AddChild(caption)
        content:SetPadding({ Left = 6, Top = 4, Right = 6, Bottom = 4 })
        content:SetHorizontalAlignment(1)
        content:SetVerticalAlignment(2)
        self.buttons[#self.buttons + 1] = { id = id, control = control, caption = caption }
        local cell = parent:AddChildToHorizontalBox(control)
        cell:SetSize({ SizeRule = 1, Value = 1 })
        cell:SetPadding({ Left = 3, Top = 0, Right = 3, Bottom = 0 })
    end

    -- Two rows, grouped by what they touch. Top row changes the values, bottom
    -- row changes the mode. Four in a line read as four variations of "go back".
    local values_row = make("HorizontalBox")
    button("save", "Save", values_row)
    button("undo", "Undo", values_row)
    button("defaults", "Mod defaults", values_row)
    add(values_row, 32, 5)

    local mode_row = make("HorizontalBox")
    button("test", "Play test", mode_row)
    button("bypass", "Compare", mode_row)
    button("close", "Close", mode_row)
    add(mode_row, 32, 4)

    add(label("Play test, then drag. Replay it to hear a raise.", 12, MUTED), 17, 1)
    add(label("Saved values load automatically next launch.", 12, MUTED), 17, 0)

    slot:SetSize({ X = self.width, Y = self.height })

    -- Focusable only when we actually take input, never otherwise.
    --
    -- This was unconditionally true, and closing the panel only collapses it
    -- rather than removing it, so a focusable widget sat in the viewport at
    -- Z 9000 for the rest of the session. Slate drives gamepad navigation by
    -- focus, so once focus had landed here the controller had nowhere to send
    -- input, with no panel on screen to explain it. Mouse and keyboard were
    -- unaffected, which is why it read as random.
    self.widget.bIsFocusable = focusable and true or false
    self.widget:AddToViewport(9000)

    return setmetatable(self, { __index = Panel })
end

-- Pulls slider positions into the model and returns the list of keys that moved.
-- Only those get re-applied: re-applying all nine every tick while dragging
-- would be ninety reflection calls a second for no reason.
-- A channel's single value: the cut if one is applied, otherwise the boost.
-- Both are never non-neutral at once, because read() clears the other side.
function Panel:level(model, relpath)
    local duck = model.duck[relpath] or 1.0
    if duck < 1.0 then return duck end
    local class = self.pair[relpath]
    if class and model.boost then return model.boost[class] or 1.0 end
    return 1.0
end

function Panel:read(model, order)
    local changed = {}

    local boost = math.floor(self.sliders.class_boost:GetValue() * 100 + 0.5) / 100
    if math.abs(boost - model.class_boost) > 0.0001 then
        model.class_boost = boost
        changed[#changed + 1] = "class_boost"
    end

    for _, relpath in ipairs(order) do
        local control = self.sliders[relpath]
        if control then
            local raw = control:GetValue()
            local scale = self.scale[relpath]
            if scale then raw = scale.lo + raw * (scale.hi - scale.lo) end
            local v = math.floor(raw * 100 + 0.5) / 100

            -- One slider, two stages. Whichever side of unity it is on takes
            -- the value and the other is returned to neutral, so they can never
            -- both be acting at once.
            local class = self.pair[relpath]
            local want_duck = (v < 1.0) and v or 1.0
            local want_boost = (v > 1.0) and v or 1.0

            if math.abs(want_duck - (model.duck[relpath] or 1.0)) > 0.0001 then
                model.duck[relpath] = want_duck
                changed[#changed + 1] = relpath
            end
            if class and model.boost
               and math.abs(want_boost - (model.boost[class] or 1.0)) > 0.0001 then
                model.boost[class] = want_boost
                changed[#changed + 1] = class
            end
        end
    end

    return changed
end

function Panel:write(model, order)
    self.sliders.class_boost:SetValue(model.class_boost)
    for _, relpath in ipairs(order) do
        if self.sliders[relpath] then
            local target = self:level(model, relpath)
            local scale = self.scale[relpath]
            if scale and scale.hi > scale.lo then
                target = (target - scale.lo) / (scale.hi - scale.lo)
            end
            self.sliders[relpath]:SetValue(target)
        end
    end
end

-- Skips the whole update when nothing visible has changed.
--
-- This used to repaint every tick: roughly forty-five UFunction calls ten times
-- a second, every one of them through UE4SS's global ProcessEvent hook, for a
-- panel that mostly sits still. A hang dump showed the game's main thread had
-- overflowed its stack, and that call volume is the largest thing this mod puts
-- through that hook, so it should not be paid when there is nothing to redraw.
--
-- Hover is deliberately not part of the signature. Detecting it costs one call
-- per button, which is the thing being avoided; the caller polls it at a lower
-- rate instead.
function Panel:unchanged(model, order, dirty)
    local parts = { string.format("%.4f", model.class_boost),
                    tostring(model.selection), tostring(dirty),
                    tostring(model.bypassed) }
    for _, relpath in ipairs(order) do
        parts[#parts + 1] = string.format("%.4f", self:level(model, relpath))
    end
    local signature = table.concat(parts, "|")
    if signature == self.signature then return true end
    self.signature = signature
    return false
end

function Panel:update(model, order, dirty)
    local entry = self.values.class_boost
    entry.widget:SetText(FText(entry.format(model.class_boost)))
    for _, relpath in ipairs(order) do
        local slot = self.values[relpath]
        if slot then
            slot.widget:SetText(FText(slot.format(self:level(model, relpath))))
        end
    end

    if model.bypassed then
        self.status:SetText(FText("Comparing: you are hearing the game's own mix"))
        tint(self.status, CYAN)
    else
        self.status:SetText(FText(dirty and "Unsaved changes" or "Saved"))
        tint(self.status, dirty and AMBER or MUTED)
    end

    for index, button in ipairs(self.buttons) do
        -- Save and Undo only mean something while there are unsaved changes.
        local enabled = true
        if button.id == "save" or button.id == "undo" then enabled = dirty end
        button.control:SetIsEnabled(enabled)

        -- The label says which mix you are hearing, not on or off. With two
        -- mixes in play, "on" does not say which one is playing.
        if button.id == "bypass" then
            button.caption:SetText(FText(
                model.bypassed and "Compare: game mix" or "Compare: your mix"))
        end

        -- Says what pressing it will do. Restarting the samples is also how a
        -- boost becomes audible, so this is the button people will press most.
        if button.id == "test" then
            local playing = false
            pcall(function() playing = samples_playing() end)
            button.caption:SetText(FText(playing and "Stop test" or "Play test"))
        end

        local active = index == model.selection or button.control:IsHovered()
        local background = ROW_BG
        if not enabled then
            background = colour(22, 26, 36, 0.8)
        elseif button.id == "bypass" and model.bypassed then
            background = CYAN            -- latched, so it reads as on at a glance
        elseif active then
            background = button.id == "save" and AMBER or CYAN_DIM
        end
        button.control:SetBackgroundColor(background)

        local dark = colour(12, 16, 24)
        local caption = TEXT
        if not enabled then caption = DISABLED
        elseif button.id == "bypass" and model.bypassed then caption = dark
        elseif active then caption = dark end
        tint(button.caption, caption)
    end
end

-- Keeps the panel inside the viewport at any resolution or DPI scale.
function Panel:resize(controller)
    local layout = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
    if not (layout and layout:IsValid()) then return end
    local viewport = layout:GetViewportSize(controller)
    local dpi = layout:GetViewportScale(controller)
    if dpi <= 0 or viewport.X <= 0 or viewport.Y <= 0 then return end
    local scale = math.max(0.4, math.min(1.0,
        (viewport.X / dpi - 48) / self.width,
        (viewport.Y / dpi - 48) / self.height))
    self.frame:SetRenderScale({ X = scale, Y = scale })
end

-- ESlateVisibility: 0 Visible, 1 Collapsed, 2 Hidden.
--
-- Hiding rather than destroying exists because the game terminates at the exact
-- moment the panel is torn down. Four occurrences, the last one instant: the log
-- records "panel closed" and the process is gone, with no catchable exception
-- and no dump, which is what a fail-fast looks like.
--
-- Building about forty UMG widgets with StaticConstructObject and then tearing
-- them down on every close is the riskiest thing this mod does. Built once and
-- reused, that happens a single time per session instead of on every toggle.
function Panel:show()
    pcall(function() self.widget:SetVisibility(0) end)
end

function Panel:hide()
    pcall(function() self.widget:SetVisibility(1) end)
end

-- Only for a level change, where the widgets genuinely cannot be kept.
function Panel:destroy()
    pcall(function() self.widget:RemoveFromParent() end)
end

return Panel
