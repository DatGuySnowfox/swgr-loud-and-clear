--[[
    In-game mix panel, built as native UMG widgets at runtime.

    No ImGui and no C++. A host widget is created from one of the game's own
    blueprints, which gives a usable WidgetTree, then the tree is populated with
    StaticConstructObject on engine UMG classes.

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
}

local function decibels(multiplier)
    if multiplier <= 0 then return "-inf" end
    return string.format("%+.1f dB", 20 * math.log(multiplier, 10))
end

function Panel.create(controller, model, order)
    local library = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    assert(library and library:IsValid(), "WidgetBlueprintLibrary unavailable")

    -- Any of the game's widget blueprints works as a host. This one is small and
    -- always cooked; its own contents are replaced by our tree.
    local template = StaticFindObject(
        "/Game/Griffin/UI/Widgets/Global/WBP_SectionSubLabel.WBP_SectionSubLabel_C")
    assert(template and template:IsValid(), "Load into gameplay before opening the panel")

    local self = { sliders = {}, values = {}, buttons = {}, width = 470, height = 40 }

    self.widget = library:Create(controller, template, controller)
    assert(self.widget and self.widget:IsValid(), "Could not create the panel widget")
    local tree = self.widget.WidgetTree
    assert(tree and tree:IsValid(), "Widget tree unavailable")

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
    local function slider_row(key, caption, minimum, maximum, step, readout)
        local head = make("HorizontalBox")
        head:AddChildToHorizontalBox(label(caption, 15, TEXT))
            :SetSize({ SizeRule = 1, Value = 1 })
        local value = label("", 15, CYAN)
        value:SetJustification(2)
        head:AddChildToHorizontalBox(value):SetSize({ SizeRule = 1, Value = 1 })
        add(head, 22, 2)

        local control = make("Slider")
        control:SetMinValue(minimum)
        control:SetMaxValue(maximum)
        control:SetStepSize(step)
        control:SetSliderBarColor(BAR)
        control:SetSliderHandleColor(key == "class_boost" and AMBER or CYAN_DIM)
        add(control, 20, 12)

        self.sliders[key] = control
        self.values[key] = { widget = value, format = readout }
    end

    add(label("DIALOGUE", 13, MUTED), 18, 4)
    slider_row("class_boost", "Voice level", 1.0, 3.0, 0.05,
               function(v) return string.format("%.2fx", v) end)

    add(label("DUCK WHAT COMPETES WITH IT", 13, MUTED), 18, 4)
    for _, relpath in ipairs(order) do
        slider_row(relpath, DISPLAY[relpath] or relpath, 0.15, 1.0, 0.01, decibels)
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
    button("bypass", "Bypass", mode_row)
    button("close", "Close", mode_row)
    add(mode_row, 32, 4)

    add(label("Bypass compares against the game's own mix.", 12, MUTED), 17, 1)
    add(label("Saved values load automatically next launch.", 12, MUTED), 17, 0)

    slot:SetSize({ X = self.width, Y = self.height })
    self.widget.bIsFocusable = true
    self.widget:AddToViewport(9000)

    return setmetatable(self, { __index = Panel })
end

-- Pulls slider positions into the model and returns the list of keys that moved.
-- Only those get re-applied: re-applying all nine every tick while dragging
-- would be ninety reflection calls a second for no reason.
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
            local v = math.floor(control:GetValue() * 100 + 0.5) / 100
            if math.abs(v - (model.duck[relpath] or 1.0)) > 0.0001 then
                model.duck[relpath] = v
                changed[#changed + 1] = relpath
            end
        end
    end
    return changed
end

function Panel:write(model, order)
    self.sliders.class_boost:SetValue(model.class_boost)
    for _, relpath in ipairs(order) do
        if self.sliders[relpath] then
            self.sliders[relpath]:SetValue(model.duck[relpath] or 1.0)
        end
    end
end

function Panel:update(model, order, dirty)
    local entry = self.values.class_boost
    entry.widget:SetText(FText(entry.format(model.class_boost)))
    for _, relpath in ipairs(order) do
        local slot = self.values[relpath]
        if slot then
            slot.widget:SetText(FText(slot.format(model.duck[relpath] or 1.0)))
        end
    end

    if model.bypassed then
        self.status:SetText(FText("Bypassed, hearing the game's own mix"))
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

        -- Bypass is a toggle, so its own label carries the state.
        if button.id == "bypass" then
            button.caption:SetText(FText(model.bypassed and "Bypass: ON" or "Bypass: off"))
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
