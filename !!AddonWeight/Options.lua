local _, ns = ...

local category
local settings = {}

local CONTROLS = {
    {
        key = "background",
        label = "Keep measuring with the window closed",
        tooltip = "The averages and the combat column need this: a few reads of the client's own profiler every 60 frames. Off, processor time is only measured while the window is open.",
    },
    {
        key = "memory",
        label = "Measure memory with the window closed",
        tooltip = "A memory scan stops the game for as long as it takes. Where one takes under 10 ms it runs once a minute, never in combat. Where it takes longer it runs only while a loading screen is up. Off, memory is only measured when you open the window.",
    },
    {
        key = "stutter",
        label = "Watch for stutters",
        tooltip = "Notes every frame longer than the mark below and which addon, if any, took most of it. The window and the report list them.",
    },
    {
        key = "stutterMs",
        slider = { ns.STUTTER_MIN, ns.STUTTER_MAX, ns.STUTTER_STEP },
        label = "A stutter is a frame longer than",
        tooltip = "At 60 frames per second a frame lasts 17 ms. 100 ms is a stutter most people see. Changing this starts the stutter list over.",
    },
    {
        key = "stutterChat",
        label = "Say each stutter in chat",
        tooltip = "One chat line per stutter with its length and its cause, the moment it happens.",
    },
    {
        key = "loginLine",
        label = "Say the load time in chat after loading",
        tooltip = "One line after each login or reload: how long your addons took to load and which was slowest.",
    },
    {
        key = "keepRemoved",
        label = "Keep the figures of addons you remove",
        tooltip = "The All time tab keeps what every addon cost across sessions. Off, an addon you delete from your AddOns folder leaves that list at the next login. On, it stays, marked as removed, until you right-click it and forget it.",
    },
}

local function MsLabel(value)
    return ("%d ms"):format(value)
end

function ns.RegisterSettings(db)
    if category or not (Settings and Settings.RegisterVerticalLayoutCategory and Settings.RegisterAddOnSetting
        and Settings.CreateCheckbox and Settings.CreateSlider and Settings.CreateSliderOptions
        and Settings.RegisterAddOnCategory) then
        return
    end
    category = Settings.RegisterVerticalLayoutCategory(ns.TITLE)
    for _, control in ipairs(CONTROLS) do
        local variable = "ADDONWEIGHT_" .. control.key:upper()
        local varType = control.slider and Settings.VarType.Number or Settings.VarType.Boolean
        local setting = Settings.RegisterAddOnSetting(category, variable, control.key, db, varType, control.label, ns.DEFAULTS[control.key])
        setting:SetValueChangedCallback(function()
            ns.OptionChanged(control.key)
        end)
        if control.slider then
            local options = Settings.CreateSliderOptions(control.slider[1], control.slider[2], control.slider[3])
            if options.SetLabelFormatter and MinimalSliderWithSteppersMixin and MinimalSliderWithSteppersMixin.Label then
                options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, MsLabel)
            end
            Settings.CreateSlider(category, setting, options, control.tooltip)
        else
            Settings.CreateCheckbox(category, setting, control.tooltip)
        end
        settings[control.key] = setting
    end
    Settings.RegisterAddOnCategory(category)
end

function ns.OpenOptions()
    if not category or InCombatLockdown() or not pcall(Settings.OpenToCategory, category:GetID()) then
        ns.Say("The settings page cannot open right now. /weight help lists the commands.")
    end
end

local function Top()
    ns.SampleCPU(true, true)
    local rows = ns.Rows("weight")
    local shown = 0
    for _, rec in ipairs(rows) do
        if rec.level > 0 and shown < 5 then
            shown = shown + 1
            ns.Say(("%s%s|r: %s."):format(rec.level == 2 and "|cffff5a4d" or "|cffffd200", rec.title, table.concat(ns.Reasons(rec), "; ")))
        end
    end
    if shown == 0 then
        ns.Say(("%d addons loaded and none stands out so far."):format(#rows))
    end
end

local COMMANDS = {
    [""] = function()
        ns.Toggle()
    end,
    report = function()
        ns.ShowReport()
    end,
    reset = function()
        ns.Reset()
        ns.Say("Averages, spike counts and the stutter list start over from now.")
    end,
    top = Top,
    status = function()
        for _, line in ipairs(ns.Status()) do
            ns.Say(line)
        end
    end,
    config = function()
        ns.OpenOptions()
    end,
    help = function()
        ns.Say("/weight opens the window (/weight all on its All time tab). /weight top names the heaviest addons in chat. /weight report gives every table as text to copy. /weight reset starts the session's averages over. /weight forget clears everything saved. /weight config opens the settings. /weight status is for troubleshooting.")
    end,
    copy = function()
        ns.ShowReport()
    end,
    session = function()
        ns.Toggle("session")
    end,
    all = function()
        ns.Toggle("all")
    end,
    forget = function()
        ns.AskForgetAll()
    end,
}
COMMANDS.settings, COMMANDS.options = COMMANDS.config, COMMANDS.config

SLASH_ADDONWEIGHT1 = "/weight"
SLASH_ADDONWEIGHT2 = "/addonweight"
SlashCmdList.ADDONWEIGHT = function(message)
    local word = (message or ""):lower():match("^%s*(%S*)")
    local command = COMMANDS[word]
    if not ns.db then
        return
    end
    if command then
        command()
    else
        COMMANDS.help()
    end
end

function AddonWeight_OnAddonCompartmentClick()
    ns.Toggle()
end
