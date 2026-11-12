local ADDON, ns = ...

local view = { sort = "weight", ascending = false, filter = "", wait = 0, dirty = true, rows = {}, position = {} }
ns.view = view

-- Offsets are multiples of 5 so each lands on a whole pixel at 1.2 pixels per unit (1440p, default scale).
local WIDTH, HEIGHT = 780, 630
local LEFT = 15
local ROW_HEIGHT = 20
local WHITE, GOLD, RED, GREY = { 1, 1, 1 }, { 1, 0.82, 0 }, { 1, 0.125, 0.125 }, { 0.5, 0.5, 0.5 }
local LEVEL_COLOR = { [0] = WHITE, GOLD, RED }
local LEVEL_WORD = { [0] = "Light", "Noticeable", "Heavy" }
local ALERT = "|TInterface\\DialogFrame\\DialogIcon-AlertNew-16:16:16|t"

local COLUMNS = {
    { key = "name", label = "Addon", width = 180, left = true,
        tip = "Every addon loaded now. Hover a row for all its figures; right-click it to disable it." },
    { key = "average", label = "Average ms", width = 75,
        tip = "Processor time the game's profiler charges to this addon in each frame, averaged since login, reload or Reset. At 60 fps a whole frame is 16.7 ms." },
    { key = "combat", label = "Combat ms", width = 75,
        tip = "The same, counting only time in combat." },
    { key = "peak", label = "Peak ms", width = 65,
        tip = "Its worst single frame since tracking began, loading screens left out. >100 means a frame ran over 100 ms and the exact figure is not known." },
    { key = "spikes", label = "Hitches", width = 60,
        tip = "Frames in which this addon's own work ran over 50 ms. Each one is a hitch you can feel. Loading screens are left out." },
    { key = "memory", label = "Memory MB", width = 75,
        tip = "Memory charged to the addon at the last scan. Held memory alone does not lower your frame rate; making new memory fast (in the row's tooltip) can." },
    { key = "load", label = "Load ms", width = 60,
        tip = "Time from the addon before it finishing to this one finishing at the last login or reload: its files and saved settings. ~ marks an estimate for an addon loaded on demand." },
    { key = "weight", label = "Why", width = 140, left = true,
        tip = "The measure furthest past its mark. Worst rows first, frame-rate problems above memory and loading; blank means nothing stands out. The alert icon marks a heavy addon." },
}
ns.COLUMNS = COLUMNS

local function PeakLevel(ms)
    return ms and (ms >= 100 and 2 or ms >= 50 and 1) or 0
end

-- Two decimals below 10 so the decimal points of a column line up.
local function CellMs(ms)
    if not ms then
        return "-"
    elseif ms < 10 then
        return ("%.2f"):format(ms)
    elseif ms < 100 then
        return ("%.1f"):format(ms)
    end
    return ("%d"):format(ms + 0.5)
end

-- Each returns the cell's text, its level (0 to 2) and the number behind it.
local CELLS = {
    now = function(rec)
        return CellMs(rec.recent), ns.Level(rec.recent, ns.LIMITS.cpu), rec.recent
    end,
    average = function(rec)
        local ms = ns.Average(rec)
        return CellMs(ms), ns.Level(ms, ns.LIMITS.cpu), ms
    end,
    combat = function(rec)
        local ms = ns.CombatAverage(rec)
        return CellMs(ms), ns.Level(ms, ns.LIMITS.cpu), ms
    end,
    peak = function(rec)
        local exact, band = ns.Peak(rec)
        if exact then
            return ("%.1f"):format(exact), PeakLevel(exact), exact
        elseif band then
            return (">%d"):format(band), PeakLevel(band), band
        end
        return "-", 0, nil
    end,
    spikes = function(rec)
        local count = ns.Over(rec, ns.SPIKE_BUCKET)
        return count and tostring(count) or "-", (ns.SpikeLevel(rec)), count
    end,
    memory = function(rec)
        local kb = rec.mem
        if not kb then
            return "-", 0, nil
        end
        local mb = kb / 1024
        return mb > 0 and mb < 0.05 and "<0.1" or ("%.1f"):format(mb), ns.Level(kb, ns.LIMITS.memory), kb
    end,
    growth = function(rec)
        return ns.FormatRate(rec.growth), ns.Level(rec.growth, ns.LIMITS.growth), rec.growth
    end,
    load = function(rec)
        if rec.loadKind == "before" or not rec.loadMs then
            return "-", 0, nil
        end
        local text = ("%d"):format(rec.loadMs + 0.5)
        if rec.loadKind ~= "startup" then
            text = "~" .. text
        end
        return text, ns.Level(ns.LoadTypical(rec), ns.LIMITS.load), rec.loadMs
    end,
    weight = function(rec)
        local text, level = ns.ShortReason(rec)
        return text or "", level, rec.rank
    end,
}
ns.CELLS = CELLS

-- Tiles ------------------------------------------------------------------------------------
-- One answer each: the heaviest addon on frame rate, on stutters, on memory and on loading.

local function FrameTile(summary)
    local tile = { label = "Frame rate" }
    if not ns.ProfilerEnabled() then
        tile.name, tile.grey, tile.value = "No figures", true, "The addon profiler is off"
        return tile
    end
    local rec = summary.top.cpu
    if not rec then
        tile.name, tile.grey = summary.application and "Nothing stands out" or "Measuring...", true
        return tile
    end
    local ms, combat = ns.JudgedTime(rec)
    tile.name, tile.level = rec.title, ns.Level(ms, ns.LIMITS.cpu)
    tile.value = combat and ("%s ms a frame in combat"):format(ns.FormatMs(ms)) or ("%s ms of every frame"):format(ns.FormatMs(ms))
    if tile.level == 0 then
        tile.grey, tile.detail = true, "Nothing stands out"
    elseif rec.carries then
        tile.detail = ("Includes other %s addons' work"):format(rec.carries)
    elseif summary.cpuBound == false then
        tile.detail = "Little to gain: the graphics card is the limit"
    else
        local cost = ns.FpsCost(ms, summary.fps)
        if cost and cost >= 0.5 then
            tile.detail = summary.cpuBound and ("Up to +%d fps without it"):format(cost + 0.5)
                or ("Up to +%d fps if the processor is the limit"):format(cost + 0.5)
        end
    end
    return tile
end

local function StutterTile(summary)
    local tile = { label = "Stutters" }
    local stutters, mark = summary.stutters, ns.db.stutterMs
    local total = stutters.total or 0
    if not ns.db.stutter then
        tile.name, tile.grey, tile.value = "Not watched", true, "Turn it on in Settings"
    elseif total == 0 then
        tile.name, tile.grey, tile.value = "No stutters", true, ("No frame over %d ms"):format(mark)
    else
        local worst
        for _, rec in ipairs(ns.list) do
            if rec.stutters > 0 and (not worst or rec.stutters > worst.stutters) then
                worst = rec
            end
        end
        if worst then
            tile.name, tile.level = worst.title, 2
            tile.value = ("took most of %d of %d stutters"):format(worst.stutters, total)
            tile.detail = ("%d frame%s over %d ms in all"):format(total, total == 1 and "" or "s", mark)
        else
            tile.name = "Not one addon"
            tile.value = ("%d frame%s over %d ms"):format(total, total == 1 and "" or "s", mark)
            tile.detail = ("%d from addons together, %d charged to none"):format(stutters.addons or 0, (stutters.game or 0) + (stutters.unknown or 0))
        end
    end
    return tile
end

local function MemoryTile(summary)
    local tile = { label = "Memory" }
    local rec = summary.top.memory
    if not summary.memory then
        tile.name, tile.grey = "Measuring...", true
    elseif not rec then
        tile.name, tile.grey = "Nothing stands out", true
    else
        tile.name, tile.level = rec.title, ns.Level(rec.mem, ns.LIMITS.memory)
        tile.value = ("%s held"):format(ns.FormatMemory(rec.mem))
        if tile.level == 0 then
            tile.grey, tile.detail = true, ("Nothing stands out. %s in all"):format(ns.FormatMemory(summary.memory))
        else
            tile.detail = ("All addons: %s"):format(ns.FormatMemory(summary.memory))
        end
    end
    return tile
end

local function LoadTile(summary)
    local tile = { label = "Loading" }
    local rec = summary.top.load
    local kind = summary.reload and "reload" or "login"
    if not summary.totalMs then
        tile.name, tile.grey = "Still loading...", true
    elseif not rec then
        tile.name, tile.grey = "Nothing stands out", true
    else
        tile.name, tile.level = rec.title, ns.Level(ns.LoadTypical(rec), ns.LIMITS.load)
        tile.value = ("%s at the last %s"):format(ns.FormatDuration(rec.loadMs), kind)
        if tile.level == 0 then
            tile.grey, tile.detail = true, ("Nothing stands out. %s in all"):format(ns.FormatDuration(summary.addonMs))
        else
            tile.detail = ("All addons: %s of a %s %s"):format(ns.FormatDuration(summary.addonMs), ns.FormatDuration(summary.totalMs), kind)
        end
    end
    return tile
end

function ns.Tiles()
    local summary = ns.Summary()
    return { FrameTile(summary), StutterTile(summary), MemoryTile(summary), LoadTile(summary) }
end

function ns.ContextLine()
    local summary = ns.Summary()
    local measured = ("Measured over %s."):format(ns.FormatClock(summary.tracked))
    if not ns.ProfilerEnabled() then
        return ("%.0f fps. The addon profiler is off, so there are no frame times. %s"):format(summary.fps, measured)
    elseif summary.application and summary.application > 0 then
        local bound = summary.cpuBound == nil and "" or summary.cpuBound and ", limited by the processor" or ", limited by the graphics card"
        return ("%.0f fps%s. Addons are charged %.0f%% of each frame's work. %s"):format(summary.fps, bound,
            100 * summary.overall / summary.application, measured)
    end
    return "Measuring. The first figures arrive within a few seconds."
end

-- Tooltip ----------------------------------------------------------------------------------

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
        local share = ns.Share(rec)
        Add("Right now", share and ("%s ms a frame (%.1f%% of the frame's work)"):format(ns.FormatMs(rec.recent), share * 100)
            or ns.FormatMs(rec.recent) .. " ms a frame", ns.Level(rec.recent, limits.cpu))
        local average = ns.Average(rec)
        Add("Average", ns.FormatMs(average) .. " ms a frame", ns.Level(average, limits.cpu))
        local combat = ns.CombatAverage(rec)
        if combat then
            Add("In combat", ns.FormatMs(combat) .. " ms a frame", ns.Level(combat, limits.cpu))
        end
        if rec.encounter and rec.encounter > 0 then
            Add("Last boss fight", ns.FormatMs(rec.encounter) .. " ms a frame", ns.Level(rec.encounter, limits.cpu))
        end
        local peak, band = ns.Peak(rec)
        if peak then
            Add("Worst frame", ns.FormatMs(peak) .. " ms", PeakLevel(peak))
        elseif band then
            Add("Worst frame", ("over %d ms"):format(band), PeakLevel(band))
        end
        if rec.over[1] then
            local level = (ns.SpikeLevel(rec))
            Add("Frames over 5 / 10 / 50 / 100 ms", ("%d / %d / %d / %d"):format(ns.Over(rec, 2), ns.Over(rec, 3), ns.Over(rec, 4), ns.Over(rec, 5)), level)
            local rate, count = ns.SpikeRate(rec)
            if count > 0 then
                Add("Hitches an hour", ("%d"):format(rate + 0.5), level)
            end
        end
        local cost = ns.FpsCost(rec.recent, GetFramerate())
        if cost and cost >= 0.5 then
            local bound = IsCpuBound and IsCpuBound()
            if bound == false then
                Add("Turning it off", "little to gain: the graphics card is the limit")
            elseif bound then
                Add("Turning it off", ("up to +%d fps"):format(cost + 0.5))
            else
                Add("Turning it off", ("up to +%d fps, if the processor is the limit"):format(cost + 0.5))
            end
        end
    end
    if rec.stutters > 0 then
        Add("Stutters it took most of", tostring(rec.stutters), 2)
    end
    if rec.mem then
        local text = ns.FormatMemory(rec.mem)
        if rec.memPeak and rec.memPeak > rec.mem * 1.05 then
            text = ("%s (peak %s)"):format(text, ns.FormatMemory(rec.memPeak))
        end
        Add("Memory", text, ns.Level(rec.mem, limits.memory))
        if rec.growth then
            Add("New memory", ("at least %s, cleared by the game in small pauses"):format(ns.FormatRate(rec.growth)), ns.Level(rec.growth, limits.growth))
        end
    end
    Add("Load", LoadText(rec), ns.Level(ns.LoadTypical(rec), limits.load))
    if rec.loadPeak and rec.loadPeak >= 1 then
        Add("Longest burst of work while loading", ns.FormatDuration(rec.loadPeak), ns.Level(rec.loadPeak, limits.burst))
    end
    if rec.loadKB and rec.loadKB >= 1 then
        Add("Lua memory added while it loaded", ns.FormatMemory(rec.loadKB))
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
    local folder = rec.name ~= rec.title and rec.name or nil
    if version and version ~= "" then
        GameTooltip:AddLine(folder and ("%s, version %s"):format(folder, version) or "Version " .. version, 0.5, 0.5, 0.5)
    elseif folder then
        GameTooltip:AddLine(folder, 0.5, 0.5, 0.5)
    end
    local reasons = ns.Reasons(rec)
    local color = LEVEL_COLOR[rec.level or 0]
    if #reasons > 0 then
        GameTooltip:AddLine(LEVEL_WORD[rec.level] .. ": " .. table.concat(reasons, "; ") .. ".", color[1], color[2], color[3], true)
    else
        GameTooltip:AddLine("Nothing the game's profiler charges to it stands out.", 1, 1, 1, true)
    end
    if rec.carries then
        GameTooltip:AddLine(("It loaded %s first, so the profiler charges it with the event and setup work of every %s addon. Its figures include theirs."):format(rec.carries, rec.carries), 1, 0.82, 0, true)
    end
    GameTooltip:AddLine(" ")
    for _, line in ipairs(ns.RowTooltipLines(rec)) do
        local c = LEVEL_COLOR[line[3] or 0]
        GameTooltip:AddDoubleLine(line[1], line[2], 1, 0.82, 0, c[1], c[2], c[3])
    end
    if rec.name ~= ADDON then
        GameTooltip:AddLine(" ")
        GameTooltip_AddInstructionLine(GameTooltip, "Right-click to disable it and reload.")
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
    local text = ("Disable %s for this character and reload the interface?\n\nTurn it back on from the game menu's AddOns list."):format(title)
    if rec.carries then
        text = text .. ("\n\nIt carries the shared %s work of other addons: that cost will move to the next one, not go away."):format(rec.carries)
    end
    StaticPopup_ShowGenericConfirmation(text, function()
        C_AddOns.DisableAddOn(rec.name, UnitGUID("player"))
        ReloadUI()
    end)
end

local function BuildRow(row)
    row.cells = {}
    row.bar = row:CreateTexture(nil, "BORDER")
    row.bar:SetColorTexture(1, 1, 1, 0.1)
    row.bar:SetHeight(15)
    local x = 0
    for _, column in ipairs(COLUMNS) do
        local cell = row:CreateFontString(nil, "ARTWORK", column.left and "GameFontHighlight" or "Number14FontWhite")
        cell:SetJustifyH(column.left and "LEFT" or "RIGHT")
        cell:SetWordWrap(false)
        cell:SetSize(column.width - 16, ROW_HEIGHT)
        cell:SetPoint("LEFT", row, "LEFT", x + 8, 0)
        row.cells[column.key] = cell
        x = x + column.width
    end
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
    local stripe = row:GetNormalTexture()
    if stripe then
        stripe:SetAtlas((view.position[rec] or 1) % 2 == 1 and "auctionhouse-rowstripe-1" or "auctionhouse-rowstripe-2")
    end
    row.cells.name:SetText(rec.level == 2 and rec.title .. " " .. ALERT or rec.title)
    local barShown = false
    for _, column in ipairs(COLUMNS) do
        if column.key ~= "name" then
            local cell = row.cells[column.key]
            local text, level, value = CELLS[column.key](rec)
            cell:SetText(text)
            local color = level > 0 and LEVEL_COLOR[level] or (not value or value <= 0) and GREY or WHITE
            cell:SetTextColor(color[1], color[2], color[3])
            if column.key == view.sort and not column.left and value and value > 0 and (view.max or 0) > 0 then
                row.bar:ClearAllPoints()
                row.bar:SetPoint("RIGHT", cell, "RIGHT", 3, 0)
                row.bar:SetWidth(math.max(1, (column.width - 10) * math.min(1, value / view.max)))
                barShown = true
            end
        end
    end
    row.bar:SetShown(barShown)
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

local function ShowTiles()
    for i, tile in ipairs(ns.Tiles()) do
        local widget = window.tiles[i]
        widget.label:SetText(tile.label)
        widget.name:SetText(tile.level == 2 and ALERT .. " " .. tile.name or tile.name)
        local nameColor = tile.grey and GREY or WHITE
        widget.name:SetTextColor(nameColor[1], nameColor[2], nameColor[3])
        widget.value:SetText(tile.value or "")
        local valueColor = LEVEL_COLOR[tile.level or 0]
        widget.value:SetTextColor(valueColor[1], valueColor[2], valueColor[3])
        widget.detail:SetText(tile.detail or "")
    end
    window.context:SetText(ns.ContextLine())
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
    ShowTiles()
    if #rows == 0 then
        window.empty:SetText(view.filter ~= "" and ("No addon matches \"%s\"."):format(view.filter) or "No other addons are loaded.")
    end
    window.empty:SetShown(#rows == 0)
    for _, header in ipairs(window.headers) do
        local sorted = header.column.key == view.sort
        header.arrow:SetShown(sorted)
        if sorted then
            if view.ascending then
                header.arrow:SetTexCoord(0, 1, 1, 0)
            else
                header.arrow:SetTexCoord(0, 1, 0, 1)
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

local function Snap(frame, value)
    if PixelUtil and PixelUtil.GetNearestPixelSize then
        return PixelUtil.GetNearestPixelSize(value, frame:GetEffectiveScale())
    end
    return value
end

local function SavePosition(frame)
    local point, _, relativePoint, x, y = frame:GetPoint(1)
    if point and x and y then
        x, y = Snap(frame, x), Snap(frame, y)
        ns.db.window.point = { point, relativePoint or point, x, y }
        frame:ClearAllPoints()
        frame:SetPoint(point, UIParent, relativePoint or point, x, y)
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

local function Button(parent, text, tip, onClick)
    local button = CreateFrame("Button", nil, parent, "SharedButtonSmallTemplate")
    button:SetSize(80, 22)
    button:SetText(text)
    button:SetScript("OnClick", onClick)
    if tip then
        button:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(tip, 1, 0.82, 0, 1, true)
            GameTooltip:Show()
        end)
        button:SetScript("OnLeave", GameTooltip_Hide)
    end
    return button
end

local function BuildTiles()
    window.tiles = {}
    for i = 1, 4 do
        local x = LEFT + (i - 1) * 185
        local tile = {}
        local function Line(font, y)
            local line = window:CreateFontString(nil, "ARTWORK", font)
            line:SetJustifyH("LEFT")
            line:SetWordWrap(false)
            line:SetSize(180, 15)
            line:SetPoint("TOPLEFT", x, y)
            return line
        end
        tile.label = Line("GameFontNormal", -60)
        tile.name = Line("GameFontHighlightMedium", -75)
        tile.value = Line("GameFontHighlight", -95)
        tile.detail = Line("GameFontDisableSmall", -110)
        window.tiles[i] = tile
    end
    local divider = window:CreateTexture(nil, "ARTWORK")
    divider:SetAtlas("Options_HorizontalDivider", true)
    divider:SetPoint("TOPLEFT", LEFT, -128)
    divider:SetPoint("TOPRIGHT", -LEFT, -128)
end

local function BuildHeaders()
    window.headers = {}
    local x = LEFT
    for _, column in ipairs(COLUMNS) do
        local header = CreateFrame("Button", nil, window, "ColumnDisplayButtonShortTemplate")
        header.column = column
        header:SetSize(column.width + 2, 19)
        header:SetPoint("TOPLEFT", x, -135)
        header:SetText(column.label)
        local text = header.Text or header:GetFontString()
        header.arrow = header:CreateTexture(nil, "OVERLAY")
        header.arrow:SetAtlas("auctionhouse-ui-sortarrow", true)
        if column.left then
            header.arrow:SetPoint("LEFT", text, "RIGHT", 3, 0)
        else
            text:ClearAllPoints()
            text:SetPoint("RIGHT", -10, 0)
            header.arrow:SetPoint("RIGHT", text, "LEFT", -3, 0)
        end
        header.arrow:Hide()
        header:SetScript("OnClick", function()
            SortBy(column.key)
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        end)
        header:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(column.label, 1, 1, 1)
            GameTooltip_AddNormalLine(GameTooltip, column.tip, true)
            GameTooltip:Show()
        end)
        header:SetScript("OnLeave", GameTooltip_Hide)
        window.headers[#window.headers + 1] = header
        x = x + column.width
    end
end

local function BuildWindow()
    window = Panel("AddonWeightFrame", ns.TITLE, WIDTH, HEIGHT)
    window:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition(self)
    end)
    local saved = ns.db.window.point
    if type(saved) == "table" and type(saved[1]) == "string" and type(saved[2]) == "string"
        and type(saved[3]) == "number" and type(saved[4]) == "number" then
        window:SetPoint(saved[1], UIParent, saved[2], saved[3], saved[4])
    else
        window:SetPoint("CENTER")
    end

    local search = CreateFrame("EditBox", nil, window, "SearchBoxTemplate")
    search:SetSize(160, 20)
    search:SetPoint("TOPRIGHT", -LEFT, -30)
    search:HookScript("OnTextChanged", function(self)
        local text = self:GetText() or ""
        if text ~= view.filter then
            view.filter, view.dirty = text, true
        end
    end)
    window.search = search

    window.context = window:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    window.context:SetJustifyH("LEFT")
    window.context:SetWordWrap(false)
    window.context:SetPoint("LEFT", window, "TOPLEFT", LEFT, -40)
    window.context:SetPoint("RIGHT", search, "LEFT", -20, 0)

    BuildTiles()
    BuildHeaders()

    local inset = CreateFrame("Frame", nil, window, "InsetFrameTemplate")
    inset:SetPoint("TOPLEFT", 9, -153)
    inset:SetPoint("BOTTOMRIGHT", -6, 26)
    local scrollBox = CreateFrame("Frame", nil, window, "WowScrollBoxList")
    scrollBox:SetPoint("TOPLEFT", LEFT, -160)
    scrollBox:SetPoint("BOTTOMRIGHT", -35, 30)
    local scrollBar = CreateFrame("EventFrame", nil, window, "MinimalScrollBar")
    scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 10, 0)
    scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 10, 0)
    local list = CreateScrollBoxListLinearView()
    list:SetElementExtent(ROW_HEIGHT)
    list:SetElementInitializer("AddonWeightRowTemplate", InitRow)
    ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, list)
    window.scrollBox = scrollBox

    window.empty = window:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    window.empty:SetPoint("CENTER", scrollBox)
    window.empty:Hide()

    local reset = Button(window, "Reset", "Start every average, hitch count and the stutter list over from now. Press it just before the fight or place you want to measure.", function()
        ns.Reset()
        view.dirty = true
    end)
    reset:SetPoint("BOTTOMLEFT", 4, 4)
    local copy = Button(window, "Copy Text", "Everything in this window as plain text you can copy and paste.", function()
        ns.ShowReport()
    end)
    copy:SetPoint("BOTTOMLEFT", reset, "BOTTOMRIGHT", 0, 0)
    local options = Button(window, "Settings", nil, function()
        ns.OpenOptions()
    end)
    options:SetPoint("BOTTOMRIGHT", -4, 4)

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
        report = Panel("AddonWeightReportFrame", ns.TITLE .. ": text", 900, 480)
        report:SetFrameStrata("DIALOG")
        report:SetPoint("CENTER")
        report:SetScript("OnDragStop", report.StopMovingOrSizing)
        local scroll = CreateFrame("ScrollFrame", nil, report, "InputScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 15, -35)
        scroll:SetPoint("BOTTOMRIGHT", -35, 35)
        if scroll.CharCount then
            scroll.CharCount:Hide()
        end
        local box = scroll.EditBox
        box:SetFontObject("ChatFontNormal")
        box:SetWidth(840)
        box:SetScript("OnEscapePressed", function()
            report:Hide()
        end)
        report.box, report.scroll = box, scroll
        local hint = report:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
        hint:SetPoint("BOTTOMLEFT", 15, 12)
        hint:SetText("Ctrl+C copies the selected text. Paste it anywhere.")
    end
    report.box:SetText(table.concat(ns.Report(), "\n"))
    -- The template scrolls to the cursor, which SetText leaves at the end.
    report.box:SetCursorPosition(0)
    report.scroll:SetVerticalScroll(0)
    report:Show()
    report.box:SetFocus()
    report.box:HighlightText()
end
