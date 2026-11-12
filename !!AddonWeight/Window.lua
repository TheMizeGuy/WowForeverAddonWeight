local ADDON, ns = ...

local view = { sort = "weight", ascending = false, filter = "", wait = 0, dirty = true, rows = {}, position = {} }
ns.view = view

local ROW_HEIGHT = 20
local LEVEL_COLOR = { [0] = { 1, 1, 1 }, { 1, 0.82, 0 }, { 1, 0.35, 0.3 } }
local QUIET_COLOR = { 0.5, 0.5, 0.5 }
local LEVEL_WORD = { [0] = "Light", "Noticeable", "Heavy" }
local LABEL = "|cffffd200%s|r  %s"

local COLUMNS = {
    { key = "name", label = "Addon", width = 168, left = true,
        tip = "Every addon that is loaded right now. Hover a row for everything measured about it; right-click to disable it and reload." },
    { key = "now", label = "Now", width = 52,
        tip = "Milliseconds of each frame this addon's code took, averaged over the last 60 frames. At 60 frames per second a whole frame is 16.7 ms." },
    { key = "average", label = "Average", width = 60,
        tip = "The same, averaged since tracking began (login, reload or Reset)." },
    { key = "combat", label = "Combat", width = 58,
        tip = "The same, averaged over the time you were in combat." },
    { key = "peak", label = "Peak", width = 52,
        tip = "The longest this addon held up a single frame since loading finished, in ms." },
    { key = "spikes", label = "Spikes", width = 50,
        tip = "Frames this addon alone held up for more than 50 ms: stutters you can see." },
    { key = "memory", label = "Memory", width = 72,
        tip = "Memory the addon holds right now." },
    { key = "growth", label = "Garbage", width = 72,
        tip = "How fast the addon makes new memory. A high rate makes the game stop to clean up more often, which shows as small hitches." },
    { key = "load", label = "Load", width = 64,
        tip = "How long the addon took to load at the last login or reload: its files and its saved settings. A ~ marks an estimate for an addon loaded on demand." },
    { key = "weight", label = "Verdict", width = 76,
        tip = "The worst of the other columns: Noticeable or Heavy once a measure passes its mark." },
}
ns.COLUMNS = COLUMNS

local function PeakLevel(ms)
    return ms and (ms >= 100 and 2 or ms >= 50 and 1) or 0
end

-- Each returns the cell's text, its level (0 to 2) and the number behind it.
local CELLS = {
    now = function(rec)
        return ns.FormatMs(rec.recent), ns.Level(rec.recent, ns.LIMITS.cpu), rec.recent
    end,
    average = function(rec)
        local ms = ns.Average(rec)
        return ns.FormatMs(ms), ns.Level(ms, ns.LIMITS.cpu), ms
    end,
    combat = function(rec)
        local ms = ns.CombatAverage(rec)
        return ns.FormatMs(ms), ns.Level(ms, ns.LIMITS.cpu), ms
    end,
    peak = function(rec)
        local ms = ns.Peak(rec)
        return ns.FormatMs(ms), PeakLevel(ms), ms
    end,
    spikes = function(rec)
        local count = ns.Over(rec, 4)
        return count and tostring(count) or "-", ns.Level(count, ns.LIMITS.spike), count
    end,
    memory = function(rec)
        return ns.FormatMemory(rec.mem), ns.Level(rec.mem, ns.LIMITS.memory), rec.mem
    end,
    growth = function(rec)
        return ns.FormatRate(rec.growth), ns.Level(rec.growth, ns.LIMITS.growth), rec.growth
    end,
    load = function(rec)
        if rec.loadKind == "before" or not rec.loadMs then
            return "-", 0, nil
        end
        local text = ns.FormatDuration(rec.loadMs)
        if rec.loadKind ~= "startup" then
            text = "~" .. text
        end
        return text, ns.Level(rec.loadMs, ns.LIMITS.load), rec.loadMs
    end,
    weight = function(rec)
        return LEVEL_WORD[rec.level or 0], rec.level or 0, rec.score
    end,
}
ns.CELLS = CELLS

-- Tooltip ----------------------------------------------------------------------------------

local function Pair(left, right, level)
    local color = LEVEL_COLOR[level or 0]
    GameTooltip:AddDoubleLine(left, right, 1, 0.82, 0, color[1], color[2], color[3])
end

local function LoadText(rec)
    if rec.loadKind == "before" then
        return "loaded before this meter, not timed"
    elseif not rec.loadMs then
        return "-"
    end
    local text = ns.FormatDuration(rec.loadMs)
    if rec.loadKind == "login" then
        return "about " .. text .. ", loaded on demand during login"
    elseif rec.loadKind == "demand" then
        return ("about %s, loaded on demand %s into the session"):format(text, ns.FormatClock(rec.loadAt or 0))
    end
    local average, runs = ns.LoadAverage(rec)
    if average and runs > 1 then
        text = ("%s (average of the last %d: %s)"):format(text, runs, ns.FormatDuration(average))
    end
    return text
end

function ns.RowTooltipLines(rec)
    local lines = {}
    local function Add(left, right, level)
        lines[#lines + 1] = { left, right, level }
    end
    local limits = ns.LIMITS
    if rec.recent then
        local fps = GetFramerate()
        local share = fps and fps > 0 and rec.recent / (1000 / fps) * 100 or 0
        Add("Now", ("%s ms a frame (%.1f%% of a frame)"):format(ns.FormatMs(rec.recent), share), ns.Level(rec.recent, limits.cpu))
        local average = ns.Average(rec)
        Add("Average", ns.FormatMs(average) .. " ms a frame", ns.Level(average, limits.cpu))
        local combat = ns.CombatAverage(rec)
        if combat then
            Add("In combat", ns.FormatMs(combat) .. " ms a frame", ns.Level(combat, limits.cpu))
        end
        if rec.encounter and rec.encounter > 0 then
            Add("Last boss fight", ns.FormatMs(rec.encounter) .. " ms a frame", ns.Level(rec.encounter, limits.cpu))
        end
        local peak, during = ns.Peak(rec)
        if peak then
            Add("Worst frame", ns.FormatMs(peak) .. " ms", PeakLevel(peak))
        elseif during and during > 0 then
            Add("Worst frame", ("none over the earlier %s ms"):format(ns.FormatMs(during)))
        end
        if rec.over[1] then
            Add("Frames held over 5 / 10 / 50 / 100 ms", ("%d / %d / %d / %d"):format(ns.Over(rec, 2), ns.Over(rec, 3), ns.Over(rec, 4), ns.Over(rec, 5)),
                ns.Level(ns.Over(rec, 4), limits.spike))
        end
        local cost = ns.FpsCost(rec, fps)
        if cost and cost >= 0.5 then
            Add("Worth right now", ("up to %.0f fps"):format(cost))
        end
    end
    if rec.stutters > 0 then
        Add("Stutters it caused", tostring(rec.stutters), 2)
    end
    if rec.mem then
        local text = ns.FormatMemory(rec.mem)
        if rec.memPeak and rec.memPeak > rec.mem * 1.05 then
            text = ("%s (peak %s)"):format(text, ns.FormatMemory(rec.memPeak))
        end
        Add("Memory", text, ns.Level(rec.mem, limits.memory))
        if rec.growth then
            Add("Garbage", ns.FormatRate(rec.growth), ns.Level(rec.growth, limits.growth))
        end
    end
    Add("Load", LoadText(rec), rec.loadKind ~= "before" and ns.Level(rec.loadMs, limits.load) or 0)
    if rec.loadPeak and rec.loadPeak >= 1 then
        Add("Longest it held the loading screen", ns.FormatDuration(rec.loadPeak), ns.Level(rec.loadPeak, limits.login))
    end
    if rec.loadKB and rec.loadKB >= 1 then
        Add("Memory taken while loading", ns.FormatMemory(rec.loadKB))
    end
    return lines
end

local function ShowRowTooltip(row)
    local rec = row.rec
    if not rec then
        return
    end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:SetText(rec.title, 1, 1, 1)
    local version = C_AddOns.GetAddOnMetadata(rec.name, "Version")
    GameTooltip:AddLine(version and version ~= "" and ("%s, version %s"):format(rec.name, version) or rec.name, 0.6, 0.6, 0.6)
    local reasons = ns.Reasons(rec)
    local color = LEVEL_COLOR[rec.level or 0]
    if #reasons > 0 then
        GameTooltip:AddLine(LEVEL_WORD[rec.level] .. ": " .. table.concat(reasons, "; ") .. ".", color[1], color[2], color[3], true)
    else
        GameTooltip:AddLine("Light: nothing about it stands out.", 0.6, 1, 0.6, true)
    end
    GameTooltip:AddLine(" ")
    for _, line in ipairs(ns.RowTooltipLines(rec)) do
        Pair(line[1], line[2], line[3])
    end
    if rec.name ~= ADDON then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Right-click to disable this addon and reload.", 0.6, 0.6, 0.6)
    end
    GameTooltip:Show()
end

-- Rows -------------------------------------------------------------------------------------

local function AskDisable(rec)
    if rec.name == ADDON then
        return
    end
    if InCombatLockdown() then
        ns.Say("Not while you are in combat.")
        return
    end
    -- The popup formats its text again, so a percent sign in a title must be doubled.
    local title = rec.title:gsub("%%", "%%%%")
    StaticPopup_ShowGenericConfirmation(("Disable %s and reload the interface?\n\nTurn it back on from the game menu's AddOns list."):format(title), function()
        C_AddOns.DisableAddOn(rec.name)
        ReloadUI()
    end)
end

local function BuildRow(row)
    row.cells = {}
    row.stripe = row:CreateTexture(nil, "BACKGROUND")
    row.stripe:SetAllPoints()
    row.stripe:SetColorTexture(1, 1, 1, 0.03)
    row.bar = row:CreateTexture(nil, "BORDER")
    row.bar:SetColorTexture(1, 1, 1, 0.1)
    row.bar:SetHeight(ROW_HEIGHT - 4)
    local x = 6
    for _, column in ipairs(COLUMNS) do
        local cell = row:CreateFontString(nil, "ARTWORK", column.left and "GameFontHighlight" or "GameFontHighlightSmall")
        cell:SetJustifyH(column.left and "LEFT" or "RIGHT")
        cell:SetWordWrap(false)
        cell:SetSize(column.width - 6, ROW_HEIGHT)
        cell:SetPoint("LEFT", row, "LEFT", x + (column.left and 0 or 6), 0)
        row.cells[column.key] = cell
        x = x + column.width
    end
    row:RegisterForClicks("RightButtonUp")
    row:SetScript("OnEnter", function(self)
        view.hover = self
        ShowRowTooltip(self)
    end)
    row:SetScript("OnLeave", function(self)
        if view.hover == self then
            view.hover = nil
        end
        GameTooltip:Hide()
    end)
    row:SetScript("OnClick", function(self)
        if self.rec then
            AskDisable(self.rec)
        end
    end)
end

local function InitRow(row, rec)
    if not row.cells then
        BuildRow(row)
    end
    row.rec = rec
    row.stripe:SetShown((view.position[rec] or 0) % 2 == 0)
    local name = row.cells.name
    name:SetText(rec.title)
    local nameColor = LEVEL_COLOR[rec.level or 0]
    name:SetTextColor(nameColor[1], nameColor[2], nameColor[3])
    local barShown = false
    for _, column in ipairs(COLUMNS) do
        if not column.left then
            local cell = row.cells[column.key]
            local text, level, value = CELLS[column.key](rec)
            cell:SetText(text)
            local color = level > 0 and LEVEL_COLOR[level] or (not value or value <= 0 or text == "0") and QUIET_COLOR or LEVEL_COLOR[0]
            cell:SetTextColor(color[1], color[2], color[3])
            if column.key == view.sort and column.key ~= "weight" and value and value > 0 and (view.max or 0) > 0 then
                row.bar:ClearAllPoints()
                row.bar:SetPoint("RIGHT", cell, "RIGHT", 2, 0)
                row.bar:SetWidth(math.max(1, (column.width - 4) * math.min(1, value / view.max)))
                barShown = true
            end
        end
    end
    row.bar:SetShown(barShown)
end

-- Summary ----------------------------------------------------------------------------------

function ns.SummaryLines()
    local summary = ns.Summary()
    local lines = {}
    if summary.application and summary.application > 0 then
        local bound = summary.cpuBound == nil and "" or summary.cpuBound and ". Limited by the processor"
            or ". Limited by the graphics card"
        lines[1] = LABEL:format("Frames", ("%.0f fps, %s ms each; addons take %s ms of that (%.0f%%)%s."):format(summary.fps,
            ns.FormatMs(summary.application), ns.FormatMs(summary.overall), 100 * summary.overall / summary.application, bound))
    elseif ns.ProfilerEnabled() then
        lines[1] = LABEL:format("Frames", ("%.0f fps; measuring..."):format(summary.fps))
    else
        lines[1] = LABEL:format("Frames", ("%.0f fps. The client's addon profiler is off, so there are no processor figures."):format(summary.fps))
    end
    if summary.memory then
        lines[2] = LABEL:format("Memory", ("%d addons hold %s, growing %s."):format(summary.loaded, ns.FormatMemory(summary.memory), ns.FormatRate(summary.growth)))
    else
        lines[2] = LABEL:format("Memory", "measuring...")
    end
    if summary.totalMs then
        lines[3] = LABEL:format("Loading", ("%d addons took %s to load at the last %s; the game was ready after %s."):format(
            summary.counted or 0, ns.FormatDuration(summary.addonMs), summary.reload and "reload" or "login", ns.FormatDuration(summary.totalMs)))
    else
        lines[3] = LABEL:format("Loading", "still loading...")
    end
    local stutters = summary.stutters
    if not ns.db.stutter then
        lines[4] = LABEL:format("Stutters", "not watched (see the settings).")
    elseif (stutters.total or 0) == 0 then
        lines[4] = LABEL:format("Stutters", ("no frame over %d ms."):format(ns.db.stutterMs))
    else
        local worst
        for _, rec in ipairs(ns.list) do
            if rec.stutters > 0 and (not worst or rec.stutters > worst.stutters) then
                worst = rec
            end
        end
        local causes = {}
        if (stutters.addon or 0) > 0 then
            causes[#causes + 1] = ("%d from one addon%s"):format(stutters.addon, worst and (" (most often %s)"):format(worst.title) or "")
        end
        if (stutters.addons or 0) > 0 then
            causes[#causes + 1] = ("%d from several addons together"):format(stutters.addons)
        end
        if (stutters.game or 0) > 0 then
            causes[#causes + 1] = ("%d not from addons"):format(stutters.game)
        end
        if (stutters.unknown or 0) > 0 then
            causes[#causes + 1] = ("%d of unknown cause"):format(stutters.unknown)
        end
        lines[4] = LABEL:format("Stutters", ("%d frame%s over %d ms: %s."):format(stutters.total, stutters.total == 1 and "" or "s",
            ns.db.stutterMs, table.concat(causes, ", ")))
    end
    local top, parts = summary.top, {}
    if top.cpu then
        parts[#parts + 1] = "on frames " .. top.cpu.title
    end
    if top.memory then
        parts[#parts + 1] = "on memory " .. top.memory.title
    end
    if top.load then
        parts[#parts + 1] = "on loading " .. top.load.title
    end
    lines[5] = #parts > 0 and LABEL:format("Heaviest", table.concat(parts, ", ") .. ".") or ""
    local own = summary.own
    lines.status = ("Tracking for %s.%s"):format(ns.FormatClock(summary.tracked),
        own and own.recent and (" This meter itself: %s ms a frame, %s."):format(ns.FormatMs(own.recent), ns.FormatMemory(own.mem)) or "")
    return lines
end

-- Window -----------------------------------------------------------------------------------

local window, report

local function SameOrder(a, b)
    if #a ~= #b then
        return false
    end
    for i = 1, #a do
        if a[i] ~= b[i] then
            return false
        end
    end
    return true
end

local function Update()
    if not window then
        return
    end
    local frozen = not view.dirty and window.scrollBox:IsMouseOver()
    local rows = frozen and view.rows or ns.Rows(view.sort, view.ascending, view.filter)
    if frozen then
        for _, rec in ipairs(rows) do
            ns.Judge(rec)
        end
    end
    local cell = CELLS[view.sort]
    view.max = 0
    for i, rec in ipairs(rows) do
        view.position[rec] = i
        if cell then
            local _, _, value = cell(rec)
            if value and value > view.max then
                view.max = value
            end
        end
    end
    if frozen or (not view.dirty and SameOrder(rows, view.rows)) then
        window.scrollBox:ForEachFrame(function(row)
            if row.rec then
                InitRow(row, row.rec)
            end
        end)
    else
        view.rows = rows
        window.scrollBox:SetDataProvider(CreateDataProvider(rows), ScrollBoxConstants.RetainScrollPosition)
    end
    local lines = ns.SummaryLines()
    for i, fontString in ipairs(window.lines) do
        fontString:SetText(lines[i] or "")
    end
    window.status:SetText(lines.status)
    window.empty:SetShown(#rows == 0)
    for _, header in ipairs(window.headers) do
        local sorted = header.column.key == view.sort
        header.arrow:SetShown(sorted)
        if sorted then
            if view.ascending then
                header.arrow:SetTexCoord(0, 0.5625, 1, 0)
            else
                header.arrow:SetTexCoord(0, 0.5625, 0, 1)
            end
        end
    end
    if view.hover and view.hover:IsShown() and view.hover.rec then
        ShowRowTooltip(view.hover)
    end
    view.dirty = false
end

function ns.Refresh(elapsed)
    view.wait = view.wait - elapsed
    if view.wait <= 0 or view.dirty then
        view.wait = 1
        Update()
    end
end

local function SortBy(key)
    if view.sort == key then
        view.ascending = not view.ascending
    else
        view.sort, view.ascending = key, key == "name"
    end
    ns.db.window.sort, ns.db.window.ascending = view.sort, view.ascending
    view.dirty = true
end

local function SavePosition(frame)
    local point, _, _, x, y = frame:GetPoint(1)
    if point then
        ns.db.window.point = { point, x, y }
    end
end

local function Panel(name, title, width, height)
    local frame = CreateFrame("Frame", name, UIParent, "DefaultPanelTemplate")
    frame:SetSize(width, height)
    frame:SetFrameStrata("HIGH")
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:Hide()
    if frame.TitleContainer and frame.TitleContainer.TitleText then
        frame.TitleContainer.TitleText:SetText(title)
    end
    CreateFrame("Button", nil, frame, "UIPanelCloseButtonDefaultAnchors")
    tinsert(UISpecialFrames, name)
    return frame
end

local function Button(parent, text, width, onClick)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(width, 22)
    button:SetText(text)
    button:SetScript("OnClick", onClick)
    return button
end

local function BuildWindow()
    local width = 12 + 6
    for _, column in ipairs(COLUMNS) do
        width = width + column.width
    end
    width = width + 30
    window = Panel("AddonWeightFrame", ns.TITLE, width, 560)
    window:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition(self)
    end)
    local saved = ns.db.window.point
    if type(saved) == "table" and type(saved[1]) == "string" and type(saved[2]) == "number" and type(saved[3]) == "number" then
        window:SetPoint(saved[1], UIParent, saved[1], saved[2], saved[3])
    else
        window:SetPoint("CENTER")
    end

    window.lines = {}
    for i = 1, 5 do
        local line = window:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        line:SetJustifyH("LEFT")
        line:SetWordWrap(false)
        line:SetPoint("TOPLEFT", 14, -14 - i * 17)
        line:SetPoint("RIGHT", window, "RIGHT", i == 1 and -180 or -14, 0)
        window.lines[i] = line
    end

    local search = CreateFrame("EditBox", nil, window, "SearchBoxTemplate")
    search:SetSize(150, 20)
    search:SetPoint("TOPRIGHT", -14, -28)
    search:HookScript("OnTextChanged", function(self)
        local text = self:GetText() or ""
        if text ~= view.filter then
            view.filter, view.dirty = text, true
        end
    end)
    window.search = search

    window.headers = {}
    local x = 12 + 6
    for _, column in ipairs(COLUMNS) do
        local header = CreateFrame("Button", nil, window)
        header.column = column
        header:SetSize(column.width, 20)
        header:SetPoint("TOPLEFT", x, -122)
        local label = header:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        label:SetText(column.label)
        if column.left then
            label:SetPoint("LEFT", 0, 0)
        else
            label:SetPoint("RIGHT", 0, 0)
        end
        header.arrow = header:CreateTexture(nil, "ARTWORK")
        header.arrow:SetTexture("Interface\\Buttons\\UI-SortArrow")
        header.arrow:SetSize(9, 8)
        header.arrow:SetPoint("RIGHT", label, "LEFT", -2, 0)
        header.arrow:Hide()
        header:SetHighlightTexture("Interface\\PaperDollInfoFrame\\UI-Character-Tab-Highlight", "ADD")
        header:SetScript("OnClick", function()
            SortBy(column.key)
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        end)
        header:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(column.label, 1, 1, 1)
            GameTooltip:AddLine(column.tip, 1, 0.82, 0, true)
            GameTooltip:Show()
        end)
        header:SetScript("OnLeave", GameTooltip_Hide)
        window.headers[#window.headers + 1] = header
        x = x + column.width
    end

    local inset = CreateFrame("Frame", nil, window, "InsetFrameTemplate")
    inset:SetPoint("TOPLEFT", 10, -144)
    inset:SetPoint("BOTTOMRIGHT", -8, 34)
    local scrollBox = CreateFrame("Frame", nil, window, "WowScrollBoxList")
    scrollBox:SetPoint("TOPLEFT", inset, "TOPLEFT", 2, -3)
    scrollBox:SetPoint("BOTTOMRIGHT", inset, "BOTTOMRIGHT", -22, 3)
    local scrollBar = CreateFrame("EventFrame", nil, window, "MinimalScrollBar")
    scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 6, -2)
    scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 6, 2)
    local list = CreateScrollBoxListLinearView()
    list:SetElementExtent(ROW_HEIGHT)
    list:SetElementInitializer("AddonWeightRowTemplate", InitRow)
    ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, list)
    window.scrollBox = scrollBox

    window.empty = window:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    window.empty:SetPoint("CENTER", inset)
    window.empty:SetText("No addon matches.")
    window.empty:Hide()

    local reset = Button(window, "Reset", 80, function()
        ns.Reset()
        view.dirty = true
    end)
    reset:SetPoint("BOTTOMLEFT", 10, 7)
    reset:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Start the averages, spike counts and stutter list over. Useful right before the fight or the place you want measured.", 1, 0.82, 0, 1, true)
        GameTooltip:Show()
    end)
    reset:SetScript("OnLeave", GameTooltip_Hide)
    local copy = Button(window, "Report", 80, function()
        ns.ShowReport()
    end)
    copy:SetPoint("LEFT", reset, "RIGHT", 6, 0)
    copy:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Everything in this window as text you can copy.", 1, 0.82, 0, 1, true)
        GameTooltip:Show()
    end)
    copy:SetScript("OnLeave", GameTooltip_Hide)
    local options = Button(window, "Settings", 80, function()
        ns.OpenOptions()
    end)
    options:SetPoint("BOTTOMRIGHT", -8, 7)
    window.status = window:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    window.status:SetPoint("LEFT", copy, "RIGHT", 10, 0)
    window.status:SetPoint("RIGHT", options, "LEFT", -10, 0)
    window.status:SetJustifyH("LEFT")
    window.status:SetWordWrap(false)

    window:SetScript("OnShow", function()
        ns.Watch(true)
        view.dirty, view.wait = true, 1
        Update()
        PlaySound(SOUNDKIT.IG_CHARACTER_INFO_OPEN)
    end)
    window:SetScript("OnHide", function()
        view.hover = nil
        ns.Watch(false)
        PlaySound(SOUNDKIT.IG_CHARACTER_INFO_CLOSE)
    end)
end

function ns.Toggle()
    if not ns.db then
        return
    end
    if not window then
        local sort = ns.db.window.sort
        if type(sort) == "string" and ns.SORTS[sort] then
            view.sort, view.ascending = sort, ns.db.window.ascending == true
        end
        BuildWindow()
    end
    window:SetShown(not window:IsShown())
end

function ns.ShowReport()
    if not report then
        report = Panel("AddonWeightReportFrame", ns.TITLE .. " report", 700, 460)
        report:SetFrameStrata("DIALOG")
        report:SetPoint("CENTER")
        report:SetScript("OnDragStop", report.StopMovingOrSizing)
        local scroll = CreateFrame("ScrollFrame", nil, report, "InputScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 16, -34)
        scroll:SetPoint("BOTTOMRIGHT", -32, 34)
        if scroll.CharCount then
            scroll.CharCount:Hide()
        end
        local box = scroll.EditBox
        box:SetFontObject("ChatFontNormal")
        box:SetWidth(640)
        box:SetScript("OnEscapePressed", function()
            report:Hide()
        end)
        report.box = box
        local hint = report:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
        hint:SetPoint("BOTTOMLEFT", 16, 12)
        hint:SetText("Ctrl+C copies the selected text.")
    end
    report.box:SetText(table.concat(ns.Report(), "\n"))
    report:Show()
    report.box:SetFocus()
    report.box:HighlightText()
end
