-- A small fake of the WoW client, enough to load the addon under LuaJIT and drive it through a
-- login, frames, the client's addon profiler, memory scans and the window.
-- Usage: local wow = dofile("tests/wow.lua"); local ns = wow.Start({ addons = { ... } })

local wow = {}

local ADDON = "!!AddonWeight"
local ADDON_DIR = (os.getenv("ADDON_DIR") or ADDON) .. "/"
wow.ADDON = ADDON

local realCollectGarbage = collectgarbage

wow.METRIC = {
    SessionAverageTime = 0, RecentAverageTime = 1, EncounterAverageTime = 2, LastTime = 3, PeakTime = 4,
    CountTimeOver1Ms = 5, CountTimeOver5Ms = 6, CountTimeOver10Ms = 7, CountTimeOver50Ms = 8,
    CountTimeOver100Ms = 9, CountTimeOver500Ms = 10, CountTimeOver1000Ms = 11,
}

local function NoOp() end

-- Widgets ----------------------------------------------------------------------------------
-- Scripts, events, shown state and text are kept; any other method is a no-op.

local widget = {}
widget.__index = function(_, key)
    local method = rawget(widget, key)
    if method then
        return method
    end
    -- An unknown method is a no-op; an unknown field (lower case, as the addon names its own) is nil.
    if type(key) == "string" and key:find("^%u") then
        return NoOp
    end
    return nil
end

function wow.NewWidget(kind, name, parent, template)
    local self = setmetatable({ kind = kind, name = name, parent = parent, template = template, scripts = {}, events = {}, shown = true, children = {} }, widget)
    if parent and parent.children then
        parent.children[#parent.children + 1] = self
    end
    return self
end

function widget.SetScript(self, name, fn) self.scripts[name] = fn end
function widget.GetScript(self, name) return self.scripts[name] end
function widget.HookScript(self, name, fn)
    local old = self.scripts[name]
    self.scripts[name] = old and function(...) old(...) fn(...) end or fn
end
function widget.RegisterEvent(self, event)
    if wow.unknownEvents[event] then
        error("unknown event " .. event)
    end
    if not self.listed then
        self.listed = true
        wow.eventFrames[#wow.eventFrames + 1] = self
    end
    self.events[event] = true
end
function widget.UnregisterEvent(self, event) self.events[event] = nil end
function widget.IsShown(self) return self.shown end
function widget.IsVisible(self) return self.shown end
function widget.SetShown(self, shown)
    shown = shown and true or false
    if shown ~= self.shown then
        self.shown = shown
        local script = self.scripts[shown and "OnShow" or "OnHide"]
        if script then
            script(self)
        end
    end
end
function widget.Show(self) self:SetShown(true) end
function widget.Hide(self) self:SetShown(false) end
function widget.SetText(self, text, ...)
    self.text = text
    if self == _G.GameTooltip then
        wow.tooltip = { text }
    end
    local script = self.scripts.OnTextChanged
    if script then
        script(self, false)
    end
end
function widget.GetText(self) return self.text end
function widget.SetTextColor(self, r, g, b) self.color = { r, g, b } end
function widget.SetWidth(self, width) self.width = width end
function widget.GetWidth(self) return self.width or 0 end
function widget.SetPoint(self, ...) self.point = { ... } end
function widget.GetPoint(self)
    local p = self.point
    if p then
        return p[1], p[2], p[3], p[4], p[5]
    end
end
function widget.CreateFontString(self, name, layer, font)
    return wow.NewWidget("FontString", name, self, font)
end
function widget.CreateTexture(self, name, layer)
    return wow.NewWidget("Texture", name, self)
end
function widget.IsMouseOver(self) return self.mouseOver == true end
function widget.GetNormalTexture(self)
    local texture = rawget(self, "normalTexture")
    if not texture then
        texture = wow.NewWidget("Texture", nil, self)
        self.normalTexture = texture
    end
    return texture
end
function widget.SetAtlas(self, atlas) self.atlas = atlas end
function widget.SetCursorPosition(self, position) self.cursor = position end
function widget.SetVerticalScroll(self, offset) self.scroll = offset end
function widget.SetOwner(self, owner, anchor)
    self.owner = owner
    wow.tooltip = {}
end
function widget.AddLine(self, text)
    wow.tooltip[#wow.tooltip + 1] = text
end
function widget.AddDoubleLine(self, left, right)
    wow.tooltip[#wow.tooltip + 1] = left .. ": " .. right
end
function widget.Click(self, button)
    local script = self.scripts.OnClick
    if script then
        script(self, button or "LeftButton")
    end
end

-- The scroll box shows the first wow.visibleRows rows, as a list taller than its data would.
function widget.SetDataProvider(self, provider)
    self.provider = provider
    self.rows = self.rows or {}
    wow.providerSets = wow.providerSets + 1
    local shown = math.min(#provider.rows, wow.visibleRows)
    for i = 1, shown do
        local row = self.rows[i] or wow.NewWidget("Button", nil, self, "AddonWeightRowTemplate")
        self.rows[i] = row
        row.shown = true
        self.view.init(row, provider.rows[i])
    end
    for i = shown + 1, #self.rows do
        self.rows[i].shown = false
        self.rows[i].rec = nil
    end
end
function widget.ForEachFrame(self, fn)
    for _, row in ipairs(self.rows or {}) do
        if row.shown then
            fn(row)
        end
    end
end

local function CreateFrame(kind, name, parent, template)
    local frame = wow.NewWidget(kind, name, parent, template)
    if template == "DefaultPanelTemplate" then
        frame.TitleContainer = { TitleText = wow.NewWidget("FontString") }
        frame.shown = true
    elseif template == "PanelTabButtonTemplate" then
        parent.Tabs = rawget(parent, "Tabs") or {}
        parent.Tabs[#parent.Tabs + 1] = frame
    elseif template == "ColumnDisplayButtonShortTemplate" then
        frame.Text = wow.NewWidget("FontString", nil, frame)
    elseif template == "InputScrollFrameTemplate" then
        frame.EditBox = wow.NewWidget("EditBox", nil, frame)
        frame.CharCount = wow.NewWidget("FontString", nil, frame)
    end
    if name then
        _G[name] = frame
    end
    wow.frames[#wow.frames + 1] = frame
    return frame
end

local function NewSetting(category, variable, key, tbl, varType, name, default)
    if tbl[key] == nil then
        tbl[key] = default
    end
    local setting = { category = category, variable = variable, key = key, tbl = tbl, varType = varType, name = name, default = default }
    function setting:SetValueChangedCallback(callback) self.callback = callback end
    function setting:GetValue() return self.tbl[self.key] end
    function setting:SetValue(value)
        if type(value) ~= self.varType then
            error(("setting %s: expected a %s, got %s"):format(self.name, self.varType, type(value)))
        end
        self.tbl[self.key] = value
        if self.callback then
            self.callback(self, value)
        end
    end
    return setting
end

-- The client ----------------------------------------------------------------------------------

function wow.Reset(options)
    wow.clock = 100000      -- ms, what GetTimePreciseSec and debugprofilestop are read from
    wow.profileStart = 0
    wow.wall = 1794470400   -- time()
    wow.heap = 50000        -- KB, collectgarbage("count")
    wow.eventFrames, wow.frames = {}, {}
    wow.unknownEvents = {}
    wow.printed = {}
    wow.installed = {}      -- { name, title, lod, security, version } in addon-list order
    wow.loaded = {}         -- [name] = true
    wow.metrics = {}        -- [name][metric] = value
    wow.overall, wow.application = {}, {}
    wow.refused = {}        -- [name] = true: the profiler and memory calls raise for it
    wow.profilerEnabled = true
    wow.profilerBroken = false
    wow.hasProfiler = true
    wow.hasPreciseClock = true
    wow.memoryLive, wow.memorySeen = {}, {}
    wow.scanCost = 2        -- ms one UpdateAddOnMemoryUsage takes
    wow.scans = 0
    wow.metricReads = 0
    wow.fps = 60
    wow.cpuBound = nil
    wow.combat = false
    wow.visibleRows = 100
    wow.providerSets = 0
    wow.tooltip = {}
    wow.popup = nil
    wow.reloaded = false
    wow.disabled = {}
    wow.settings, wow.checkboxes, wow.sliders = {}, {}, {}
    wow.openedCategory = nil

    local G = _G
    if not options.keepDB then
        G.AddonWeightDB = nil
    end
    G.SlashCmdList = {}
    G.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do
            parts[#parts + 1] = tostring((select(i, ...)))
        end
        wow.printed[#wow.printed + 1] = table.concat(parts, " ")
    end
    G.collectgarbage = function(what, ...)
        if what == "count" then
            return wow.heap
        end
        return realCollectGarbage(what, ...)
    end
    G.GetTimePreciseSec = function() return wow.clock / 1000 end
    G.debugprofilestop = function() return wow.clock - wow.profileStart end
    G.debugprofilestart = function() wow.profileStart = wow.clock end
    G.time = function() return wow.wall end
    G.date = function(format, at) return os.date("!" .. format, at) end
    G.tinsert = table.insert
    G.CreateFrame = CreateFrame
    G.UIParent = wow.NewWidget("Frame", "UIParent")
    G.UISpecialFrames = {}
    G.GameTooltip = wow.NewWidget("GameTooltip", "GameTooltip")
    G.GameTooltip_Hide = function() G.GameTooltip:Hide() end
    G.GameTooltip_AddInstructionLine = function(tooltip, text) tooltip:AddLine(text) end
    G.GameTooltip_AddNormalLine = function(tooltip, text) tooltip:AddLine(text) end
    G.PanelTemplates_SetNumTabs = function(frame, count) frame.numTabs = count end
    G.PanelTemplates_SetTab = function(frame, id) frame.selectedTab = id end
    G.PixelUtil = { GetNearestPixelSize = function(value) return math.floor(value + 0.5) end }
    G.PlaySound = NoOp
    G.SOUNDKIT = setmetatable({}, { __index = function() return 1 end })
    G.InCombatLockdown = function() return wow.combat end
    G.GetFramerate = function() return wow.fps end
    G.IsCpuBound = function() return wow.cpuBound end
    G.GetBuildInfo = function() return "1.60.1", "70888", "Nov 10 2026", 16001 end
    G.UnitGUID = function() return "Player-1-0000ABCD" end
    G.AceEvent30Frame, G.AceAddon30Frame = nil, nil
    G.ReloadUI = function() wow.reloaded = true end
    G.StaticPopup_ShowGenericConfirmation = function(text, callback)
        wow.popup = { text = text, accept = callback }
    end
    G.Enum = { AddOnProfilerMetric = wow.METRIC }

    local function Entry(key)
        if type(key) == "number" then
            return wow.installed[key]
        end
        for _, entry in ipairs(wow.installed) do
            if entry.name == key then
                return entry
            end
        end
    end
    G.C_AddOns = {
        GetNumAddOns = function() return #wow.installed end,
        GetAddOnInfo = function(key)
            local entry = Entry(key)
            if not entry then
                return nil
            end
            return entry.name, entry.title or entry.name, "", true, "", entry.security or "INSECURE"
        end,
        IsAddOnLoaded = function(key)
            local entry = Entry(key)
            local loaded = entry ~= nil and wow.loaded[entry.name] == true
            return loaded, loaded
        end,
        IsAddOnLoadOnDemand = function(key)
            local entry = Entry(key)
            return entry ~= nil and entry.lod == true
        end,
        GetAddOnMetadata = function(key, field)
            local entry = Entry(key)
            return entry and field == "Version" and entry.version or nil
        end,
        DisableAddOn = function(name, character)
            wow.disabled[#wow.disabled + 1] = name
            wow.disabledFor = character
        end,
    }

    local function Read(name, metric)
        wow.metricReads = wow.metricReads + 1
        if wow.profilerBroken then
            error("profiler broke")
        end
        if wow.refused[name] then
            error("addon cannot be queried")
        end
        local values = wow.metrics[name]
        return values and values[metric] or 0
    end
    G.C_AddOnProfiler = {
        IsEnabled = function() return wow.profilerEnabled end,
        GetAddOnMetric = Read,
        GetOverallMetric = function(metric)
            if wow.profilerBroken then
                error("profiler broke")
            end
            return wow.overall[metric] or 0
        end,
        GetApplicationMetric = function(metric) return wow.application[metric] or 0 end,
        GetTopKAddOnsForMetric = function(metric, k)
            local out = {}
            for name, values in pairs(wow.metrics) do
                if wow.loaded[name] and (values[metric] or 0) > 0 then
                    out[#out + 1] = { addOnName = name, metricValue = values[metric] }
                end
            end
            table.sort(out, function(a, b) return a.metricValue > b.metricValue end)
            for i = #out, k + 1, -1 do
                out[i] = nil
            end
            return out
        end,
    }
    G.UpdateAddOnMemoryUsage = function()
        wow.scans = wow.scans + 1
        wow.clock = wow.clock + wow.scanCost
        for name, kb in pairs(wow.memoryLive) do
            wow.memorySeen[name] = kb
        end
    end
    G.GetAddOnMemoryUsage = function(name)
        if wow.refused[name] then
            error("secure addon")
        end
        return wow.memorySeen[name] or 0
    end

    G.CreateScrollBoxListLinearView = function()
        local view = {}
        function view:SetElementExtent(extent) self.extent = extent end
        function view:SetElementInitializer(template, init) self.template, self.init = template, init end
        return view
    end
    G.ScrollUtil = {
        InitScrollBoxListWithScrollBar = function(scrollBox, scrollBar, view)
            scrollBox.view, scrollBox.scrollBar = view, scrollBar
        end,
    }
    G.CreateDataProvider = function(rows) return { rows = rows } end
    G.ScrollBoxConstants = { RetainScrollPosition = true }
    G.MinimalSliderWithSteppersMixin = { Label = { Right = 2 } }
    G.Settings = {
        VarType = { Boolean = "boolean", String = "string", Number = "number" },
        RegisterVerticalLayoutCategory = function(name)
            wow.category = { name = name, GetID = function() return 77 end }
            return wow.category, { name = name }
        end,
        RegisterAddOnSetting = function(category, variable, key, tbl, varType, name, default)
            local setting = NewSetting(category, variable, key, tbl, varType, name, default)
            wow.settings[#wow.settings + 1] = setting
            return setting
        end,
        CreateCheckbox = function(category, setting, tooltip)
            wow.checkboxes[#wow.checkboxes + 1] = { setting = setting, tooltip = tooltip }
        end,
        CreateSliderOptions = function(low, high, step)
            return { low = low, high = high, step = step, SetLabelFormatter = function(self, where, fn) self.formatter = fn end }
        end,
        CreateSlider = function(category, setting, options, tooltip)
            wow.sliders[#wow.sliders + 1] = { setting = setting, options = options, tooltip = tooltip }
        end,
        RegisterAddOnCategory = function(category) wow.registeredCategory = category end,
        OpenToCategory = function(id)
            if wow.settingsRefuse then
                error("blocked")
            end
            wow.openedCategory = id
        end,
    }
    if not wow.hasProfiler then
        G.C_AddOnProfiler = nil
    end
    if not wow.hasPreciseClock then
        G.GetTimePreciseSec = nil
    end
end

function wow.Fire(event, ...)
    for _, frame in ipairs(wow.eventFrames) do
        if frame.events[event] and frame.scripts.OnEvent then
            frame.scripts.OnEvent(frame, event, ...)
        end
    end
end

function wow.Pass(ms)
    wow.clock = wow.clock + ms
    wow.wall = wow.wall + ms / 1000
end

-- One rendered frame that took `seconds`: time passes, then every OnUpdate runs with it.
function wow.Frame(seconds)
    seconds = seconds or 1 / 60
    wow.Pass(seconds * 1000)
    for _, frame in ipairs(wow.frames) do
        local script = frame.scripts.OnUpdate
        if script and frame.shown then
            script(frame, seconds)
        end
    end
end

-- `seconds` of ordinary frames, `fps` to the second. The default 64 has a frame length exact in
-- binary, so waits of whole seconds end on the frame they should; the profiler is sampled every
-- 60 frames, which at 64 a second is 16 samples in 15 seconds.
function wow.Run(seconds, fps)
    fps = fps or 64
    for _ = 1, math.floor(seconds * fps + 0.5) do
        wow.Frame(1 / fps)
    end
end

function wow.Install(entry)
    if type(entry) == "string" then
        entry = { name = entry }
    end
    wow.installed[#wow.installed + 1] = entry
    table.sort(wow.installed, function(a, b) return a.name:lower() < b.name:lower() end)
    return entry
end

-- The client loading one addon: its files run for `ms`, then ADDON_LOADED.
function wow.LoadAddon(name, ms, kb)
    wow.Pass(ms or 0)
    wow.heap = wow.heap + (kb or 0)
    wow.loaded[name] = true
    wow.Fire("ADDON_LOADED", name, false)
end

function wow.Metric(name, metric, value)
    wow.metrics[name] = wow.metrics[name] or {}
    wow.metrics[name][wow.METRIC[metric]] = value
end

function wow.Overall(metric, value) wow.overall[wow.METRIC[metric]] = value end
function wow.Application(metric, value) wow.application[wow.METRIC[metric]] = value end

-- Runs the addon's own files as the client does, in TOC order, then its ADDON_LOADED.
function wow.LoadSelf(ownMs)
    local ns = {}
    wow.ns = ns
    local toc = assert(io.open(ADDON_DIR .. ADDON .. ".toc")):read("*a")
    local first = true
    for file in toc:gmatch("\n([%w_]+%.lua)") do
        assert(loadfile(ADDON_DIR .. file))(ADDON, ns)
        if first then
            first = false
            wow.Pass(ownMs or 0)
        end
    end
    wow.loaded[ADDON] = true
    wow.Fire("ADDON_LOADED", ADDON, false)
    return ns
end

-- A whole login or reload. options:
--   addons   list of { name, title, load = ms, kb = KB, lod = true, security =, before = true }
--            (before: already loaded when this addon's files run)
--   setup    function run after the client is reset, before anything loads
--   keepDB   keep AddonWeightDB from the previous start, as a reload or relog does
--   reload   what PLAYER_ENTERING_WORLD says
--   stopAt   "files" | "login" | "world": stop before the later steps
--   loginMs, worldMs, screenMs: time before PLAYER_LOGIN, PLAYER_ENTERING_WORLD, the screen lifting
function wow.Start(options)
    options = options or {}
    wow.Reset(options)
    wow.Install({ name = ADDON, title = "Addon Weight", version = "1.1.1" })
    for _, addon in ipairs(options.addons or {}) do
        wow.Install(addon)
        if addon.before then
            wow.loaded[addon.name] = true
        end
    end
    if options.setup then
        options.setup()
        if not wow.hasProfiler then
            _G.C_AddOnProfiler = nil
        end
        if not wow.hasPreciseClock then
            _G.GetTimePreciseSec = nil
        end
    end
    local ns = wow.LoadSelf(options.ownMs or 2)
    for _, addon in ipairs(options.addons or {}) do
        if not addon.before and not addon.lod then
            wow.LoadAddon(addon.name, addon.load or 10, addon.kb or 100)
        end
    end
    if options.stopAt == "files" then
        return ns
    end
    wow.Finish(options)
    return ns
end

-- The rest of a login after the addons' files: PLAYER_LOGIN, the world, the screen lifting and
-- the first frame. Tests that stopped Start early call it themselves.
function wow.Finish(options)
    options = options or {}
    wow.Pass(options.loginMs or 50)
    wow.Fire("PLAYER_LOGIN")
    if options.stopAt == "login" then
        return
    end
    if options.duringLogin then
        options.duringLogin()
    end
    wow.Pass(options.worldMs or 200)
    wow.Fire("PLAYER_ENTERING_WORLD", not options.reload, options.reload and true or false)
    if options.stopAt == "world" then
        return
    end
    wow.Pass(options.screenMs or 300)
    wow.Fire("LOADING_SCREEN_DISABLED")
    wow.Frame()
end

function wow.Reload(options)
    if wow.ns then
        wow.Fire("PLAYER_LOGOUT")
    end
    options = options or {}
    options.keepDB, options.reload = true, true
    return wow.Start(options)
end

function wow.Slash(text)
    _G.SlashCmdList.ADDONWEIGHT(text or "")
end

function wow.Printed(needle)
    for _, line in ipairs(wow.printed) do
        if line:find(needle, 1, true) then
            return line
        end
    end
    return false
end

function wow.Tooltip(needle)
    for _, line in ipairs(wow.tooltip) do
        if type(line) == "string" and line:find(needle, 1, true) then
            return line
        end
    end
    return false
end

return wow
