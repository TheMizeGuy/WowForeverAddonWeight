-- Plays three sessions of an invented addon setup through the real addon under the fake client
-- (tests/wow.lua) and writes, as JSON, exactly what the window shows: every widget's text and colour
-- as the addon's own code set it, the rows in order, the tooltip lines of one row.
-- Run from the repository root: luajit tests/render/dump.lua <out.json>

local wow = dofile("tests/wow.lua")
local OUT = arg[1] or ".cache/addon-weight-render/dump.json"

local FPS = 72
local APPLICATION_MS = 1000 / FPS       -- processor-bound: the whole frame is work
local DAY = 86400

-- Invented addons. cpu/combat: ms a frame out of and in combat; mem: KB held; grow: KB/s made between
-- collections; peak0: the profiler's peak while loading; peak: a worse frame in the session (or nil);
-- hitch: seconds into the session at which it alone ran a frame over 50 ms (ms); stutter: its share of
-- the session's long frames. load: ms per session (three logins). kb: Lua heap added while loading.
local ADDONS = {
    { name = "RaidGridDeluxe", title = "Raid Grid Deluxe", version = "4.2.1", load = { 118, 104, 109 }, kb = 4210,
      cpu = 2.19, combat = 3.2, encounter = 3.9, mem = 14.6 * 1024, grow = 18, peak0 = 38, peak = 31.4,
      hitch = { { 1210, 58 } }, over5 = 5.6, over10 = 0.7 },
    { name = "AuctionLedger", title = "Auction Ledger", version = "11.0.3", load = { 212, 236, 224 }, kb = 61200,
      cpu = 0.11, combat = 0.06, mem = 240.3 * 1024, grow = 6, peak0 = 214, peak = 9.6 },
    { name = "QuestlineIndex", title = "Questline Index", version = "7.1.0", load = { 1342, 1271, 1318 }, kb = 38900,
      cpu = 0.27, combat = 0.24, mem = 91.8 * 1024, grow = 9, peak0 = 412, peak = 12.3 },
    { name = "GuideCompanion", title = "Guide Companion", version = "3.8.2", load = { 391, 427, 404 }, kb = 9300,
      cpu = 0.31, combat = 0.12, mem = 37.4 * 1024, grow = 11, peak0 = 96, peak = 7.8 },
    { name = "DamageTally", title = "Damage Tally", version = "2.0.6", load = { 61, 58, 66 }, kb = 2210,
      cpu = 0.33, combat = 0.86, mem = 21.2 * 1024, grow = 24, peak0 = 12, peak = nil,
      hitch = { { 640, 62 }, { 1490, 71 } }, stutter = { 380, 905, 1333 } },
    { name = "NameplateStyles", title = "Nameplate Styles", version = "1.9.4", load = { 74, 69, 72 }, kb = 1830,
      cpu = 0.24, combat = 0.41, mem = 6.8 * 1024, grow = 14, peak0 = 9, peak = nil,
      hitch = { { 455, 54 }, { 1012, 74 }, { 1544, 61 } } },
    { name = "SatchelSorter", title = "Satchel Sorter", version = "5.3", load = { 47, 52, 49 }, kb = 1120,
      cpu = 0.06, combat = 0.02, mem = 8.9 * 1024, grow = 2, peak0 = 1.2, peak = 6.8 },
    { name = "ChatTidy", title = "Chat Tidy", version = "1.4.2", load = { 22, 19, 21 }, kb = 540,
      cpu = 0.04, combat = 0.05, mem = 3.1 * 1024, grow = 3, peak0 = 2.1, peak = 3.4 },
    { name = "MinimapTray", title = "Minimap Tray", version = "2.2", load = { 14, 17, 15 }, kb = 310,
      cpu = 0.03, combat = 0.03, mem = 1.2 * 1024, grow = 0.4, peak0 = 0.8, peak = nil },
    { name = "LootNotes", title = "Loot Notes", version = "1.0.8", load = { 31, 28, 33 }, kb = 760,
      cpu = 0.02, combat = 0.04, mem = 4.4 * 1024, grow = 1, peak0 = 1.6, peak = 2.2 },
    { name = "HotbarLayouts", title = "Hotbar Layouts", version = "3.0.1", load = { 38, 41, 36 }, kb = 980,
      cpu = 0.14, combat = 0.19, mem = 5.6 * 1024, grow = 4, peak0 = 4.2, peak = 5.1 },
    { name = "CooldownDigits", title = "Cooldown Digits", version = "6.4", load = { 26, 24, 27 }, kb = 610,
      cpu = 0.09, combat = 0.17, mem = 2.3 * 1024, grow = 5, peak0 = 1.1, peak = 2.9 },
    { name = "TooltipInfo", title = "Tooltip Info", version = "2.7.0", load = { 33, 30, 35 }, kb = 1450,
      cpu = 0.05, combat = 0.02, mem = 11.7 * 1024, grow = 7, peak0 = 3.3, peak = nil },
    { name = "CoordinateReadout", title = "Coordinate Readout", version = "1.3", load = { 9, 8, 9 }, kb = 120,
      cpu = 0.01, combat = 0.01, mem = 0.4 * 1024, grow = 0.1, peak0 = 0.4, peak = nil },
    { name = "GearCompare", title = "Gear Compare", version = "4.0.2", load = { 57, 54, 59 }, kb = 2050,
      cpu = 0.02, combat = 0.01, mem = 13.9 * 1024, grow = 1, peak0 = 6.2, peak = 8.7 },
    { name = "ThreatGlance", title = "Threat Glance", version = "2.1.5", load = { 29, 31, 28 }, kb = 690,
      cpu = 0.05, combat = 0.22, mem = 2.8 * 1024, grow = 6, peak0 = 1.9, peak = 4.6 },
    { name = "UnitFrameColors", title = "Unit Frame Colors", version = "1.6", load = { 12, 11, 13 }, kb = 210,
      cpu = 0.03, combat = 0.06, mem = 0.7 * 1024, grow = 0.5, peak0 = 0.6, peak = nil },
    { name = "VendorSweep", title = "Vendor Sweep", version = "3.2", load = { 11, 12, 10 }, kb = 180,
      cpu = 0.004, combat = 0.002, mem = 0.3 * 1024, grow = 0, peak0 = 0.5, peak = 1.4 },
    { name = "GroupFinderNotes", title = "Group Finder Notes", version = "1.2.3", load = { 24, 22, 25 }, kb = 820,
      cpu = 0.02, combat = 0.01, mem = 3.6 * 1024, grow = 1, peak0 = 1.8, peak = nil },
    { name = "BuffNudge", title = "Buff Nudge", version = "2.5.1", load = { 19, 21, 18 }, kb = 450,
      cpu = 0.07, combat = 0.13, mem = 1.9 * 1024, grow = 3, peak0 = 0.9, peak = 2.4 },
    { name = "CraftQueue", title = "Craft Queue", version = "1.8", load = { 44, 47, 42 }, kb = 1660,
      cpu = 0.01, combat = 0.01, mem = 9.2 * 1024, grow = 0.5, peak0 = 5.4, peak = nil },
    { name = "CastBarPlus", title = "Cast Bar Plus", version = "2.0", load = { 16, 15, 17 }, kb = 380,
      cpu = 0.08, combat = 0.15, mem = 1.4 * 1024, grow = 2, peak0 = 0.7, peak = 1.9 },
    { name = "SoundAlerts", title = "Sound Alerts", version = "1.1.4", load = { 13, 14, 12 }, kb = 260,
      cpu = 0.02, combat = 0.04, mem = 0.9 * 1024, grow = 0.3, peak0 = 0.5, peak = nil },
    { name = "CombatTextLite", title = "Combat Text Lite", version = "3.3", load = { 21, 23, 20 }, kb = 520,
      cpu = 0.06, combat = 0.18, mem = 2.6 * 1024, grow = 4, peak0 = 1.3, peak = 3.1 },
    { name = "MacroBook", title = "Macro Book", version = "1.5.2", load = { 17, 16, 18 }, kb = 340,
      cpu = 0.003, combat = 0.001, mem = 1.1 * 1024, grow = 0, peak0 = 0.9, peak = nil },
    { name = "ObjectivePins", title = "Objective Pins", version = "2.9", load = { 36, 39, 34 }, kb = 1010,
      cpu = 0.12, combat = 0.07, mem = 7.3 * 1024, grow = 5, peak0 = 3.7, peak = 6.2 },
    -- Loaded in the first two sessions only: removed before the third (kept by the setting).
    { name = "MailSorter", title = "Mail Sorter", version = "2.3", load = { 288, 301 }, kb = 7400,
      cpu = 0.05, combat = 0.03, mem = 66.2 * 1024, grow = 2, peak0 = 64, peak = nil, last = 2 },
    -- Installed in all three, loaded in the first two: not loaded in the third.
    { name = "TalentNotes", title = "Talent Notes", version = "1.4", load = { 316, 297 }, kb = 3300,
      cpu = 0.02, combat = 0.01, mem = 12.5 * 1024, grow = 1, peak0 = 41, peak = nil, last = 2, staysInstalled = true },
}

-- The meter's own figures: about one profiler read a frame.
local SELF = { cpu = 0.01, combat = 0.01, mem = 0.62 * 1024 }

-- Three logins, each a walk through the open world with a few fights. Seconds.
local SESSIONS = {
    { start = 1794096000 + 19 * 3600 + 7 * 60, seconds = 2460, fights = { 300, 820, 1380, 1900 } },          -- 2026-11-08
    { start = 1794096000 + 2 * DAY + 20 * 3600 + 41 * 60, seconds = 2130, fights = { 260, 990, 1610 } },     -- 2026-11-10
    { start = 1794096000 + 4 * DAY + 18 * 3600 + 3 * 60, seconds = 1692,                                      -- 2026-11-12
      fights = { 180, 560, 870, 1180, 1420 } },
}
local FIGHT_SECONDS = 72

-- A small deterministic jitter so figures are not round.
local seed = 1440
local function Jitter(scale)
    seed = (seed * 1103515245 + 12345) % 2147483648
    return 1 + scale * ((seed / 2147483648) * 2 - 1)
end

local function InFight(session, t)
    for _, start in ipairs(session.fights) do
        if t >= start and t < start + FIGHT_SECONDS then
            return true
        end
    end
    return false
end

local function Loaded(addon, index)
    return not addon.last or index <= addon.last
end

local function Roster(index)
    local list = {}
    for _, addon in ipairs(ADDONS) do
        if Loaded(addon, index) then
            list[#list + 1] = { name = addon.name, title = addon.title, version = addon.version,
                load = addon.load[index], kb = addon.kb }
        elseif addon.staysInstalled then
            -- Installed, never asked for: the client lists it and does not load it.
            list[#list + 1] = { name = addon.name, title = addon.title, version = addon.version, lod = true }
        end
    end
    return list
end

local function Session(index)
    local session = SESSIONS[index]
    local roster = Roster(index)
    local ns = wow.Start({
        addons = roster, keepDB = index > 1, loginMs = 1680, worldMs = 2410, screenMs = 2860, ownMs = 2,
        setup = function()
            wow.wall = session.start
            wow.fps = FPS
            wow.cpuBound = true
            wow.scanCost = 3.1
            for _, addon in ipairs(ADDONS) do
                if Loaded(addon, index) then
                    wow.Metric(addon.name, "PeakTime", addon.peak0)
                    wow.memoryLive[addon.name] = addon.mem
                end
            end
            wow.memoryLive[wow.ADDON] = SELF.mem
        end,
    })
    if index == 1 then
        -- The player keeps the figures of addons they remove (Settings > "Keep the figures ...").
        ns.db.keepRemoved = true
    end
    local over = {}
    local sawtooth = {}
    local stutters = {}
    for _, addon in ipairs(ADDONS) do
        for _, at in ipairs(addon.stutter or {}) do
            stutters[at] = addon
        end
    end
    local gameStutters = { [710] = true, [1250] = true }
    for t = 1, session.seconds do
        local fight = InFight(session, t)
        wow.combat = fight
        local overall = 0
        for _, addon in ipairs(ADDONS) do
            if Loaded(addon, index) then
                local ms = (fight and addon.combat or addon.cpu) * Jitter(0.12)
                wow.Metric(addon.name, "RecentAverageTime", ms)
                overall = overall + ms
                -- Counters of frames over 1, 5 and 10 ms grow with the work it does.
                local o = over[addon.name] or { 0, 0, 0 }
                over[addon.name] = o
                o[1] = o[1] + FPS * math.min(1, ms / 1.2)
                o[2] = o[2] + (addon.over5 or 0) * (fight and 3 or 1)
                o[3] = o[3] + (addon.over10 or 0) * (fight and 3 or 1)
                wow.Metric(addon.name, "CountTimeOver1Ms", math.floor(o[1]))
                wow.Metric(addon.name, "CountTimeOver5Ms", math.floor(o[2]))
                wow.Metric(addon.name, "CountTimeOver10Ms", math.floor(o[3]))
                if addon.encounter and fight then
                    wow.Metric(addon.name, "EncounterAverageTime", addon.encounter)
                end
                -- Memory rises at its rate and the collector takes it back every few minutes.
                local saw = (sawtooth[addon.name] or 0) + addon.grow
                if t % 240 == 0 then
                    saw = 0
                end
                sawtooth[addon.name] = saw
                wow.memoryLive[addon.name] = addon.mem + saw
                if addon.peak and t == 600 + #addon.name * 17 then
                    wow.Metric(addon.name, "PeakTime", addon.peak)
                end
            end
        end
        wow.Metric(wow.ADDON, "RecentAverageTime", SELF.cpu)
        wow.Overall("RecentAverageTime", overall + SELF.cpu)
        wow.Application("RecentAverageTime", APPLICATION_MS * Jitter(0.03))
        wow.Overall("LastTime", overall)
        -- Hitches: one frame of the addon's own over 50 ms.
        for _, addon in ipairs(ADDONS) do
            for _, hitch in ipairs(Loaded(addon, index) and addon.hitch or {}) do
                if hitch[1] == t then
                    local values = wow.metrics[addon.name]
                    local counted = (values[wow.METRIC.CountTimeOver50Ms] or 0) + 1
                    wow.Metric(addon.name, "CountTimeOver50Ms", counted)
                    wow.Metric(addon.name, "PeakTime", math.max(values[wow.METRIC.PeakTime] or 0, hitch[2]))
                end
            end
        end
        local blamed = stutters[t]
        if blamed and Loaded(blamed, index) then
            -- A 180 ms frame, 141 ms of it the addon's.
            local values = wow.metrics[blamed.name]
            wow.Metric(blamed.name, "LastTime", 141)
            wow.Overall("LastTime", 149)
            wow.Metric(blamed.name, "CountTimeOver50Ms", (values[wow.METRIC.CountTimeOver50Ms] or 0) + 1)
            wow.Metric(blamed.name, "CountTimeOver100Ms", (values[wow.METRIC.CountTimeOver100Ms] or 0) + 1)
            wow.Metric(blamed.name, "PeakTime", math.max(values[wow.METRIC.PeakTime] or 0, 141))
            wow.Frame(0.18)
            wow.Metric(blamed.name, "LastTime", 0.4)
            wow.Overall("LastTime", 4.6)
            wow.Frame(1 / FPS)
        elseif gameStutters[t] then
            -- A long frame the profiler charges to no addon (the world loading around the player).
            wow.Overall("LastTime", 6.3)
            wow.Frame(0.24)
            wow.Frame(1 / FPS)
        end
        wow.Run(1, FPS)
    end
    wow.combat = false
    return ns
end

-- Capturing ---------------------------------------------------------------------------------

local function Copy(color)
    return color and { color[1], color[2], color[3] } or nil
end

local function Text(widget)
    return { text = widget.text or "", color = Copy(widget.color) }
end

local function Capture(ns, label)
    local window = _G.AddonWeightFrame
    local view = ns.view
    -- The window redraws once a second: redraw now, so the widgets and the cross-check read one moment.
    view.dirty = true
    ns.Refresh(0)
    local out = {
        label = label, scope = view.scope, sort = view.sort, ascending = view.ascending, max = view.max,
        title = window.TitleContainer.TitleText.text, context = window.context.text,
        selectedTab = window.selectedTab, tabs = {}, tiles = {}, headers = {}, rows = {},
        visibleExtent = nil,
    }
    for i, tab in ipairs(window.Tabs) do
        out.tabs[i] = tab.text
    end
    for i, tile in ipairs(window.tiles) do
        out.tiles[i] = { label = Text(tile.label), name = Text(tile.name), value = Text(tile.value), detail = Text(tile.detail) }
    end
    for i, header in ipairs(window.headers) do
        out.headers[i] = { key = header.column.key, text = header.text, width = header.column.width,
            left = header.column.left or false, arrow = header.arrow.shown }
    end
    for i, row in ipairs(window.scrollBox.rows) do
        if row.shown and row.rec then
            local rec = row.rec
            local cells = {}
            for _, column in ipairs(ns.COLUMNS) do
                local cell = row.cells[column.key]
                cells[column.key] = { text = cell.text or "", color = Copy(cell.color), width = cell.width }
            end
            local bar = row.bar
            out.rows[#out.rows + 1] = {
                name = rec.name, title = rec.title, stripe = row:GetNormalTexture().atlas, cells = cells,
                alert = row.alert.shown, bar = bar.shown and { width = bar.width } or false,
                level = rec.level, rank = rec.rank,
            }
        end
    end
    -- The same rows from the addon's cell functions, as a cross-check of the widgets.
    local cellFns = view.scope == "all" and ns.LIFE_CELLS or ns.CELLS
    for _, row in ipairs(out.rows) do
        local rec
        for _, r in ipairs(view.rows) do
            if r.name == row.name then
                rec = r
            end
        end
        for key, cell in pairs(row.cells) do
            if key ~= "name" then
                local text = cellFns[key](rec)
                assert(text == cell.text, ("%s %s: widget %q, cell function %q"):format(row.name, key, cell.text, text))
            end
        end
    end
    local tiles = ns.Tiles(view.scope)
    for i, tile in ipairs(tiles) do
        assert((tile.value or "") == out.tiles[i].value.text, "tile " .. i .. " value")
    end
    assert(ns.ContextLine(view.scope) == out.context, "context line: " .. tostring(ns.ContextLine(view.scope)) .. " vs " .. tostring(out.context))
    return out
end

-- The tooltip: the real OnEnter of the row, with GameTooltip's calls recorded.
local function HoverRow(ns, name)
    local lines = {}
    local tip = _G.GameTooltip
    tip.SetOwner = function(self, owner, anchor)
        lines = {}
        self.anchor = anchor
    end
    tip.SetText = function(self, text, r, g, b, a, wrap)
        lines[#lines + 1] = { kind = "header", text = text, color = { r, g, b }, wrap = wrap and true or false }
    end
    tip.AddLine = function(self, text, r, g, b, wrap)
        lines[#lines + 1] = { kind = "line", text = text, color = r and { r, g, b } or nil, wrap = wrap and true or false }
    end
    tip.AddDoubleLine = function(self, left, right, lr, lg, lb, rr, rg, rb)
        lines[#lines + 1] = { kind = "double", left = left, right = right, leftColor = { lr, lg, lb }, rightColor = { rr, rg, rb } }
    end
    _G.GameTooltip_AddInstructionLine = function(tooltip, text)
        -- Blizzard's: GameTooltip_AddColoredLine(tooltip, text, GREEN_FONT_COLOR, wrap defaulting to true)
        tooltip:AddLine(text, 0.098, 1.0, 0.098, true)
    end
    local window = _G.AddonWeightFrame
    for index, row in ipairs(window.scrollBox.rows) do
        if row.shown and row.rec and row.rec.name == name then
            row.scripts.OnEnter(row)
            local out = { row = index, anchor = tip.anchor, lines = lines }
            row.scripts.OnLeave(row)
            return out
        end
    end
    error("no row " .. name)
end

-- JSON ----------------------------------------------------------------------------------------

local function Encode(value, indent)
    indent = indent or ""
    local kind = type(value)
    if kind == "nil" then
        return "null"
    elseif kind == "boolean" then
        return tostring(value)
    elseif kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            return "null"
        end
        return value == math.floor(value) and ("%d"):format(value) or ("%.10g"):format(value)
    elseif kind == "string" then
        return '"' .. value:gsub('[%c"\\]', function(c)
            return ({ ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\t"] = "\\t" })[c] or ("\\u%04x"):format(c:byte())
        end) .. '"'
    end
    local inner = indent .. " "
    local n = 0
    for _ in pairs(value) do
        n = n + 1
    end
    if n == #value and n > 0 then
        local parts = {}
        for i, item in ipairs(value) do
            parts[i] = inner .. Encode(item, inner)
        end
        return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
    elseif n == 0 then
        return "{}"
    end
    local keys = {}
    for key in pairs(value) do
        keys[#keys + 1] = tostring(key)
    end
    table.sort(keys)
    local parts = {}
    for i, key in ipairs(keys) do
        parts[i] = inner .. Encode(key) .. ": " .. Encode(value[key] ~= nil and value[key] or value[tonumber(key)], inner)
    end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end

-- Run -----------------------------------------------------------------------------------------

local ns
for index = 1, #SESSIONS do
    if index > 1 then
        wow.Fire("PLAYER_LOGOUT")
    end
    ns = Session(index)
end

-- Open the window: this session, sorted by Why (the default).
wow.Slash("")
wow.Run(2, FPS)
local session = Capture(ns, "session")
-- The All time tab.
wow.Slash("all")
wow.Run(2, FPS)
local all = Capture(ns, "all")
-- Back to this session, sorted by name (one click on its header), so the heavy addon's row sits low
-- in the list and its tooltip opens over rows, not over the tiles and the headers.
wow.Slash("session")
for _, header in ipairs(_G.AddonWeightFrame.headers) do
    if header.column.key == "name" then
        header.scripts.OnClick(header)
    end
end
wow.Run(2, FPS)
local sorted = Capture(ns, "session-name")
local tooltip = HoverRow(ns, "RaidGridDeluxe")

local stutters = {}
for _, stutter in ipairs(ns.stutters) do
    stutters[#stutters + 1] = ns.DescribeStutter(stutter)
end
local doc = {
    build = (select(2, GetBuildInfo())), fps = FPS, addonVersion = ns.db and _G.C_AddOns.GetAddOnMetadata(wow.ADDON, "Version"),
    sessions = #SESSIONS, stutters = stutters, status = ns.Status(),
    views = { session = session, all = all, sorted = sorted }, tooltip = tooltip,
}
local handle = assert(io.open(OUT, "w"))
handle:write(Encode(doc), "\n")
handle:close()
io.write(("wrote %s: %d session rows, %d all-time rows, %d tooltip lines\n"):format(OUT, #session.rows, #all.rows, #tooltip.lines))
