local ADDON, ns = ...

-- GetTimePreciseSec cannot be reset by another addon; debugprofilestop can (debugprofilestart).
local Clock
if GetTimePreciseSec then
    Clock = function()
        return GetTimePreciseSec() * 1000
    end
else
    Clock = debugprofilestop
end
local T0 = Clock()
local HEAP0 = collectgarbage("count")

local max, min, floor, exp = math.max, math.min, math.floor, math.exp

ns.NAME = ADDON
ns.TITLE = "Addon Weight"
ns.Clock = Clock
ns.addons = {}
ns.list = {}
ns.stutters = {}
ns.STUTTER_KEEP = 50
ns.HISTORY_KEEP = 5

ns.DEFAULTS = {
    background = true,
    memory = true,
    stutter = true,
    stutterMs = 100,
    stutterChat = false,
    loginLine = false,
}
ns.STUTTER_MIN, ns.STUTTER_MAX, ns.STUTTER_STEP = 40, 500, 10

-- { noticeable, heavy } per measure.
ns.LIMITS = {
    cpu = { 0.5, 1.0 },          -- ms per frame, averaged
    growth = { 50, 250 },        -- KB per second
    memory = { 51200, 204800 },  -- KB
    load = { 150, 500 },         -- ms, files and saved settings
    burst = { 250, 1000 },       -- ms in one go while loading
}
-- Frames the addon alone ran over 50 ms: { seen at least, an hour at least }.
ns.SPIKES = { noticeable = { 2, 6 }, heavy = { 5, 60 } }

ns.BUCKETS = { 1, 5, 10, 50, 100, 500, 1000 }
local SPIKE_BUCKET = 4
ns.SPIKE_BUCKET = SPIKE_BUCKET
local BUCKET_METRICS = {
    "CountTimeOver1Ms", "CountTimeOver5Ms", "CountTimeOver10Ms", "CountTimeOver50Ms",
    "CountTimeOver100Ms", "CountTimeOver500Ms", "CountTimeOver1000Ms",
}

-- The profiler's "recent" figure covers 60 frames, so one sample every 60 frames misses none.
local SAMPLE_FRAMES = 60
local COMBAT_MIN_SAMPLES = 10
local MEMORY_INTERVAL_SHOWN, MEMORY_INTERVAL_HIDDEN, MEMORY_INTERVAL_SLOW = 5, 60, 15
local MEMORY_SLOW_MS = 10
local FIRST_MEMORY_DELAY = 2
local MEMORY_SETTLE_MS = 60000
local GROWTH_MEMORY_SECONDS = 120
local QUIET_AFTER_LOADING_MS = 3000
local STARTUP_TIMEOUT_MS = 10000
local LOADING_LIMIT_MS = 120000
local PAUSED_FRAME_SECONDS = 5
local LEAK_MIN_KB, LEAK_MIN_SECONDS = 20480, 600
local BLAME_SLACK = 1.1

local db
local frame = CreateFrame("Frame")
ns.frame = frame

local startup = { phase = "files", mark = T0, markFrames = 0, frames = 0, heapMark = HEAP0, loads = 0, t = { start = T0 } }
ns.startup = startup
ns.loading = true
ns.loadingSince = T0
ns.quietUntil = 0
ns.frameMs = 0
ns.frameStamp = T0
ns.frameCount = 0
ns.trackedSince = T0
ns.memory = { scans = 0 }
ns.cpu = { samples = 0 }
ns.heap = { rise = 0 }
ns.blame = { first = 0, second = 0 }

-- The fallback clock can be restarted by another addon: every kept time moves back with it.
local lastClock = T0

local function Reanchor(jump)
    T0 = T0 + jump
    for key, at in pairs(startup.t) do
        startup.t[key] = at + jump
    end
    startup.mark = startup.mark + jump
    ns.frameStamp = ns.frameStamp + jump
    ns.quietUntil = ns.quietUntil + jump
    ns.trackedSince = ns.trackedSince + jump
    ns.loadingSince = ns.loadingSince + jump
    local memory = ns.memory
    if memory.at then
        memory.at = memory.at + jump
    end
    for _, rec in ipairs(ns.list) do
        if rec.memSeenAt then
            rec.memSeenAt = rec.memSeenAt + jump
        end
        if rec.memFirstAt then
            rec.memFirstAt = rec.memFirstAt + jump
        end
        if rec.baseAt then
            rec.baseAt = rec.baseAt + jump
        end
    end
end

local function Now()
    local now = Clock()
    if now < lastClock then
        Reanchor(now - lastClock)
    end
    lastClock = now
    return now
end

local function Clean(text)
    if type(text) ~= "string" then
        return nil
    end
    text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""):gsub("|A.-|a", "")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    return text ~= "" and text or nil
end
ns.Clean = Clean

local function Record(name)
    local rec = ns.addons[name]
    if not rec then
        rec = {
            name = name, title = name, blizzard = name:find("^Blizzard_") ~= nil,
            sum = 0, n = 0, combatSum = 0, combatN = 0, stutters = 0,
            over = {}, base = {},
        }
        ns.addons[name] = rec
        ns.list[#ns.list + 1] = rec
    end
    return rec
end
ns.Record = Record

function ns.Roster()
    for index = 1, C_AddOns.GetNumAddOns() do
        local name, title, _, _, _, security = C_AddOns.GetAddOnInfo(index)
        if name then
            local rec = Record(name)
            rec.index, rec.installed, rec.blizzard = index, true, security == "SECURE"
            rec.title = Clean(title) or name
            rec.lod = C_AddOns.IsAddOnLoadOnDemand(name) and true or false
            if not rec.loaded then
                local _, loaded = C_AddOns.IsAddOnLoaded(name)
                if loaded then
                    rec.loaded, rec.loadKind = true, "before"
                end
            end
        end
    end
end

local function Tracked(rec)
    return rec.loaded and rec.installed and not rec.blizzard
end

function ns.Say(text)
    print("|cffffd200" .. ns.TITLE .. ":|r " .. text)
end

-- Formatting -------------------------------------------------------------------------------

function ns.FormatMs(ms)
    if not ms then
        return "-"
    elseif ms < 0.005 then
        return "0"
    elseif ms < 10 then
        return ("%.2f"):format(ms)
    elseif ms < 100 then
        return ("%.1f"):format(ms)
    end
    return ("%d"):format(ms + 0.5)
end

function ns.FormatDuration(ms)
    if not ms then
        return "-"
    elseif ms < 1 then
        return "<1 ms"
    elseif ms < 1000 then
        return ("%d ms"):format(ms + 0.5)
    end
    return ("%.1f s"):format(ms / 1000)
end

function ns.FormatMemory(kb)
    if not kb then
        return "-"
    elseif kb < 1024 then
        return ("%d KB"):format(kb + 0.5)
    end
    return ("%.1f MB"):format(kb / 1024)
end

function ns.FormatRate(kbPerSecond)
    if not kbPerSecond then
        return "-"
    elseif kbPerSecond < 0.5 then
        return "0"
    elseif kbPerSecond < 1024 then
        return ("%d KB/s"):format(kbPerSecond + 0.5)
    end
    return ("%.1f MB/s"):format(kbPerSecond / 1024)
end

function ns.FormatClock(seconds)
    seconds = floor(seconds)
    if seconds >= 3600 then
        return ("%d:%02d:%02d"):format(seconds / 3600, seconds % 3600 / 60, seconds % 60)
    end
    return ("%d:%02d"):format(seconds / 60, seconds % 60)
end

-- Cuts and pads by characters, never inside a UTF-8 sequence.
function ns.Fit(text, width)
    local out, count = {}, 0
    for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if count == width then
            break
        end
        count = count + 1
        out[count] = char
    end
    return table.concat(out) .. (" "):rep(width - count)
end

-- Loading ----------------------------------------------------------------------------------

local function LoadDatabase()
    if type(AddonWeightDB) ~= "table" then
        AddonWeightDB = {}
    end
    db = AddonWeightDB
    for key, value in pairs(ns.DEFAULTS) do
        if type(db[key]) ~= type(value) then
            db[key] = value
        end
    end
    db.stutterMs = max(ns.STUTTER_MIN, min(ns.STUTTER_MAX, db.stutterMs))
    if type(db.history) ~= "table" then
        db.history = {}
    end
    for name, runs in pairs(db.history) do
        local kept = {}
        if type(runs) == "table" then
            for _, ms in ipairs(runs) do
                if type(ms) == "number" then
                    kept[#kept + 1] = ms
                end
            end
        end
        db.history[name] = #kept > 0 and kept or nil
    end
    if type(db.logins) ~= "table" then
        db.logins = {}
    end
    if type(db.window) ~= "table" then
        db.window = {}
    end
    db.schema = 1
    ns.db = db
    ns.stutterMark = db.stutterMs
end

local function Mark()
    startup.mark = Clock()
    startup.markFrames = startup.frames
    startup.heapMark = collectgarbage("count")
end

-- Ace3 keeps one event frame and one setup frame for every addon that uses it, and the client's
-- profiler charges a frame's work to the addon that created the frame.
local function NoteCarrier(rec)
    if ns.carrier ~= nil or not (_G.AceEvent30Frame or _G.AceAddon30Frame) then
        return
    end
    if rec.blizzard then
        -- A module of Blizzard's that one of Ace3's users asked for: that user's own load comes next.
        return
    elseif rec.name == ADDON then
        ns.carrier = false
    else
        ns.carrier, rec.carries = rec, "Ace3"
    end
end

local function OnAddonLoaded(name)
    local now = Now()
    local heap = collectgarbage("count")
    if type(name) ~= "string" then
        return
    end
    local rec = Record(name)
    if rec.loaded and rec.loadKind ~= "before" then
        return
    end
    startup.loads = startup.loads + 1
    rec.loaded, rec.order = true, startup.loads
    local sameFrame = startup.frames == startup.markFrames
    if startup.phase == "files" then
        -- An addon that loads on demand was asked for from another's code, whose time is in the gap too.
        local demanded = not rec.blizzard and C_AddOns.IsAddOnLoadOnDemand(name)
        rec.loadMs, rec.loadKind = max(0, now - startup.mark), demanded and "login" or "startup"
        rec.loadKB = max(0, heap - startup.heapMark)
        startup.t.files = now
        if not sameFrame then
            startup.split = (startup.split or 0) + 1
        end
    elseif startup.phase == "login" then
        -- Frames drawn since the mark belong to the loading screen, not to this addon.
        rec.loadMs, rec.loadKind = max(0, now - (sameFrame and startup.mark or ns.frameStamp)), "login"
    else
        -- After an earlier load in this frame the mark is exact; otherwise only the last frame
        -- boundary is known, and what remains after an ordinary frame is the load.
        local from = startup.mark > ns.frameStamp and startup.mark or ns.frameStamp + ns.frameMs
        rec.loadMs, rec.loadKind = max(0, now - from), "demand"
        rec.loadAt = (now - T0) / 1000
        rec.baseAfter = ns.frameCount + 2
        if not rec.blizzard then
            ns.unbased = ns.unbased or {}
            ns.unbased[#ns.unbased + 1] = rec
        end
        ns.loadedThisFrame = true
    end
    NoteCarrier(rec)
    if name == ADDON then
        LoadDatabase()
        ns.Roster()
        if ns.RegisterSettings then
            ns.RegisterSettings(db)
        end
    elseif startup.phase == "session" and not rec.blizzard and rec.index == nil then
        ns.Roster()
    end
    Mark()
end

local function History(name)
    local runs = db.history[name]
    if type(runs) ~= "table" then
        runs = {}
        db.history[name] = runs
    end
    return runs
end

local function FinishStartup(now, timedOut)
    local t = startup.t
    startup.done, startup.phase = true, "session"
    startup.timedOut, startup.unlifted = timedOut or nil, timedOut or nil
    if timedOut then
        -- The client never said the screen lifted: it may still be up.
        t.ready = t.firstFrame or now
        ns.loading, ns.loadingSince = true, now
    else
        t.ready = max(t.screen, t.world or t.screen)
        ns.loading = false
    end
    ns.quietUntil = now + QUIET_AFTER_LOADING_MS
    ns.trackedSince = now
    ns.Roster()

    local addonMs, blizzardMs, counted, estimated, slowest = 0, 0, 0, 0, nil
    for _, rec in ipairs(ns.list) do
        if rec.loadKind == "startup" then
            if rec.blizzard then
                blizzardMs = blizzardMs + rec.loadMs
            elseif rec.installed then
                addonMs = addonMs + rec.loadMs
                counted = counted + 1
                if not slowest or rec.loadMs > slowest.loadMs then
                    slowest = rec
                end
                if db then
                    local runs = History(rec.name)
                    runs[#runs + 1] = floor(rec.loadMs * 10 + 0.5) / 10
                    while #runs > ns.HISTORY_KEEP do
                        table.remove(runs, 1)
                    end
                end
            end
        elseif rec.loadKind == "login" and rec.installed and not rec.blizzard then
            estimated = estimated + 1
        end
    end
    startup.addonMs, startup.blizzardMs, startup.counted, startup.slowest = addonMs, blizzardMs, counted, slowest
    startup.estimated = estimated
    startup.totalMs = t.ready - T0
    if db then
        for name in pairs(db.history) do
            local rec = ns.addons[name]
            if not (rec and rec.installed) then
                db.history[name] = nil
            end
        end
        local logins = db.logins
        startup.login = {
            at = time(), reload = startup.reload and true or false,
            addonMs = floor(addonMs + 0.5), totalMs = floor(startup.totalMs + 0.5), addons = counted,
        }
        logins[#logins + 1] = startup.login
        while #logins > ns.HISTORY_KEEP do
            table.remove(logins, 1)
        end
    end
    ns.settle = "startup"
    ns.memory.next = FIRST_MEMORY_DELAY
    if db and db.loginLine and slowest then
        ns.Say(("%d addons loaded in %s; slowest %s (%s). /weight"):format(
            counted, ns.FormatDuration(addonMs), slowest.title, ns.FormatDuration(slowest.loadMs)))
    end
end

function ns.LoadAverage(rec)
    local runs = db and db.history[rec.name]
    if not runs or #runs == 0 then
        return nil, 0
    end
    local total = 0
    for _, ms in ipairs(runs) do
        total = total + ms
    end
    return total / #runs, #runs
end

-- The load time to judge by: the middle one of the saved runs once there are three, so one cold
-- login does not decide it. Estimates are not judged.
function ns.LoadTypical(rec)
    if rec.loadKind ~= "startup" then
        return nil
    end
    local runs = db and db.history[rec.name]
    if not runs or #runs < 3 then
        return rec.loadMs
    end
    local sorted = {}
    for i, ms in ipairs(runs) do
        sorted[i] = ms
    end
    table.sort(sorted)
    return sorted[floor((#sorted + 1) / 2)]
end

-- Processor time ---------------------------------------------------------------------------

local profiler = C_AddOnProfiler
local Metric = Enum and Enum.AddOnProfilerMetric

local function ClearFigures()
    for _, rec in ipairs(ns.list) do
        rec.recent, rec.session = nil, nil
        for i in ipairs(rec.over) do
            rec.over[i] = nil
        end
    end
    ns.cpu.overall, ns.cpu.application = nil, nil
end

function ns.ProfilerEnabled()
    if ns.cpu.failed or not (profiler and Metric and profiler.GetAddOnMetric) then
        return false
    end
    return profiler.IsEnabled == nil or profiler.IsEnabled() == true
end

local function ReadBuckets(rec, into)
    for i, key in ipairs(BUCKET_METRICS) do
        into[i] = profiler.GetAddOnMetric(rec.name, Metric[key]) or 0
    end
end

-- The client refuses some addons (its own secure ones); asked once per addon, under pcall.
local function Profiled(rec)
    if rec.cpuOk == nil then
        rec.cpuOk = pcall(profiler.GetAddOnMetric, rec.name, Metric.RecentAverageTime)
    end
    return rec.cpuOk
end

local function Guarded(fn, ...)
    if not ns.ProfilerEnabled() then
        return false
    end
    local ok, err = pcall(fn, ...)
    if not ok then
        ns.cpu.failed, ns.cpu.error = true, tostring(err)
        ClearFigures()
    end
    return ok
end

local function SetBase(rec, peak)
    ReadBuckets(rec, rec.base)
    rec.peakBase, rec.peakSeen, rec.based = peak, nil, true
    rec.baseAt = Clock()
end

-- Spike counts and the peak are counted from here on: what loading added to them is set aside.
function ns.Baseline(atStartup)
    return Guarded(function()
        for _, rec in ipairs(ns.list) do
            if Tracked(rec) and Profiled(rec) then
                SetBase(rec, profiler.GetAddOnMetric(rec.name, Metric.PeakTime) or 0)
                if atStartup then
                    rec.loadPeak = rec.peakBase
                end
            end
        end
    end)
end

-- A loading screen in the session: what the counters gain behind it is no stutter anyone saw.
local function Hold()
    ns.holding = Guarded(function()
        for _, rec in ipairs(ns.list) do
            if Tracked(rec) and Profiled(rec) and rec.based then
                rec.hold = rec.hold or {}
                ReadBuckets(rec, rec.hold)
                rec.holdPeak = profiler.GetAddOnMetric(rec.name, Metric.PeakTime) or 0
            end
        end
    end)
end

local function Release()
    ns.holding = nil
    Guarded(function()
        for _, rec in ipairs(ns.list) do
            local hold = rec.hold
            if hold and hold[1] and rec.based and Tracked(rec) then
                for i, key in ipairs(BUCKET_METRICS) do
                    local count = profiler.GetAddOnMetric(rec.name, Metric[key]) or 0
                    rec.base[i] = (rec.base[i] or 0) + max(0, count - hold[i])
                end
                local peak = profiler.GetAddOnMetric(rec.name, Metric.PeakTime) or 0
                if peak > (rec.holdPeak or 0) then
                    rec.peakBase = peak
                end
                hold[1] = nil
            end
        end
    end)
end

-- Addons loaded on demand get their baseline two frames on, so their own loading frame is not a
-- hitch, and never behind a loading screen.
local function BasePending()
    local left
    for _, rec in ipairs(ns.unbased) do
        if not rec.based and Tracked(rec) then
            if rec.baseAfter <= ns.frameCount and Profiled(rec) then
                SetBase(rec, profiler.GetAddOnMetric(rec.name, Metric.PeakTime) or 0)
            elseif rec.cpuOk ~= false then
                left = left or {}
                left[#left + 1] = rec
            end
        end
    end
    ns.unbased = left
end

local function Settle()
    if ns.settle == "startup" then
        ns.holding = nil
        ns.Baseline(true)
    else
        Release()
    end
    ns.settle = nil
end

-- `full` also reads the figures only the window and the report show; `displayOnly` reads without
-- adding to the averages, which count one sample per 60 frames and nothing else.
local function SampleCPU(full, displayOnly)
    local cpu = ns.cpu
    local combat = InCombatLockdown() and true or false
    local behindScreen = ns.loading or ns.holding or ns.settle
    for _, rec in ipairs(ns.list) do
        if Tracked(rec) and Profiled(rec) then
            local peak = profiler.GetAddOnMetric(rec.name, Metric.PeakTime) or 0
            if not rec.based and not behindScreen and (rec.baseAfter or 0) <= ns.frameCount then
                SetBase(rec, peak)
            end
            if rec.based then
                local recent = profiler.GetAddOnMetric(rec.name, Metric.RecentAverageTime) or 0
                rec.recent = recent
                if not displayOnly then
                    rec.sum, rec.n = rec.sum + recent, rec.n + 1
                    if combat then
                        rec.combatSum, rec.combatN = rec.combatSum + recent, rec.combatN + 1
                    end
                end
                rec.peak = peak
                if not behindScreen and peak > rec.peakBase and peak > (rec.peakSeen or 0) then
                    rec.peakSeen = peak
                end
                if full then
                    rec.session = profiler.GetAddOnMetric(rec.name, Metric.SessionAverageTime) or 0
                    rec.encounter = profiler.GetAddOnMetric(rec.name, Metric.EncounterAverageTime) or 0
                    ReadBuckets(rec, rec.over)
                end
            end
        end
    end
    cpu.overall = profiler.GetOverallMetric(Metric.RecentAverageTime) or 0
    cpu.application = profiler.GetApplicationMetric(Metric.RecentAverageTime) or 0
    if not displayOnly then
        cpu.samples = cpu.samples + 1
        cpu.sum = (cpu.sum or 0) + cpu.overall
    end
end

function ns.SampleCPU(full, displayOnly)
    if not ns.ProfilerEnabled() then
        ClearFigures()
        return false
    end
    return Guarded(SampleCPU, full, displayOnly)
end

-- Before the first sample the client's own average since login stands in; after a Reset that
-- figure is about the wrong stretch of time.
function ns.Average(rec)
    if rec.n > 0 then
        return rec.sum / rec.n
    elseif ns.wasReset then
        return rec.recent
    end
    return rec.session
end

function ns.CombatAverage(rec)
    return rec.combatN > 0 and rec.combatSum / rec.combatN or nil
end

function ns.Over(rec, bucket)
    local now = rec.over[bucket]
    if not now then
        return nil
    end
    return max(0, now - (rec.base[bucket] or 0))
end

-- The worst frame since tracking began, loading left out: the exact figure when the client's
-- peak rose in that time, else the highest mark a counter passed ("over 100 ms").
function ns.Peak(rec)
    local band
    for i = #ns.BUCKETS, SPIKE_BUCKET, -1 do
        local count = ns.Over(rec, i)
        if count and count > 0 then
            band = ns.BUCKETS[i]
            break
        end
    end
    local exact = rec.peakSeen
    if exact and (not band or exact >= band) then
        return exact, nil
    end
    return nil, band
end

function ns.FormatPeak(rec)
    local exact, band = ns.Peak(rec)
    if exact then
        return ns.FormatMs(exact), exact
    elseif band then
        return (">%d"):format(band), band
    end
    return "-", nil
end

function ns.TrackedSeconds()
    return max(0, (Clock() - ns.trackedSince) / 1000)
end

-- Frames the addon alone ran over 50 ms, and how many that is an hour (never over less than a
-- minute, so the first one is not a rate of thousands).
function ns.SpikeRate(rec)
    local count = ns.Over(rec, SPIKE_BUCKET)
    if not count then
        return nil
    end
    local since = max(ns.trackedSince, rec.baseAt or 0)
    return count / max((Clock() - since) / 3600000, 1 / 60), count
end

function ns.SpikeLevel(rec)
    local rate, count = ns.SpikeRate(rec)
    if not rate or count == 0 then
        return 0, 0
    end
    local marks = ns.SPIKES
    if count >= marks.heavy[1] and rate >= marks.heavy[2] then
        return 2, 1 + min(1, rate / (marks.heavy[2] * 10))
    elseif count >= marks.noticeable[1] and rate >= marks.noticeable[2] then
        return 1, 0.5 + 0.49 * min(1, (rate - marks.noticeable[2]) / (marks.heavy[2] - marks.noticeable[2]))
    end
    return 0, min(0.4, 0.2 * count)
end

-- The addon's share of the game's frame work, as Blizzard's AddOn list counts it.
function ns.Share(rec)
    local cpu = ns.cpu
    if not (rec.recent and cpu.application and cpu.overall) then
        return nil
    end
    local total = cpu.application - cpu.overall + rec.recent
    if total <= 0 then
        return nil
    end
    return rec.recent / total
end

-- Memory -----------------------------------------------------------------------------------

function ns.SampleMemory()
    local memory = ns.memory
    local started = Clock()
    UpdateAddOnMemoryUsage()
    local now = Clock()
    memory.cost = now - started
    memory.slow = memory.cost >= MEMORY_SLOW_MS
    ns.skipFrame = true
    local seconds = memory.at and (now - memory.at) / 1000 or nil
    local total, growth = 0, 0
    for _, rec in ipairs(ns.list) do
        if Tracked(rec) and rec.memOk == nil then
            rec.memOk = pcall(GetAddOnMemoryUsage, rec.name)
        end
        if Tracked(rec) and rec.memOk then
            local kb = GetAddOnMemoryUsage(rec.name) or 0
            if rec.mem and seconds and seconds >= 1 then
                -- A fall means the collector ran in between: that interval says nothing about the rate.
                local delta = kb - rec.mem
                if delta >= 0 then
                    local rate = delta / seconds
                    local keep = exp(-seconds / GROWTH_MEMORY_SECONDS)
                    rec.growth = rec.growth and (rec.growth * keep + rate * (1 - keep)) or rate
                end
            end
            growth = growth + (rec.growth or 0)
            -- Growth is measured against a reading taken once the addon has settled in.
            rec.memSeenAt = rec.memSeenAt or now
            if not rec.memFirst and now - rec.memSeenAt >= MEMORY_SETTLE_MS then
                rec.memFirst, rec.memFirstAt = kb, now
            end
            rec.mem = kb
            rec.memPeak = max(rec.memPeak or 0, kb)
            total = total + kb
        end
    end
    memory.total, memory.growth, memory.at = total, growth, now
    memory.heap = collectgarbage("count")
    memory.scans = memory.scans + 1
end

-- Net growth since the settled reading, once it is both large and most of what the addon held.
function ns.Leak(rec)
    if not (rec.mem and rec.memFirst) then
        return nil
    end
    local grown = rec.mem - rec.memFirst
    local seconds = (ns.memory.at - rec.memFirstAt) / 1000
    if grown >= LEAK_MIN_KB and seconds >= LEAK_MIN_SECONDS and grown >= rec.memFirst * 0.5 then
        return grown, seconds
    end
    return nil
end

-- Stutters ---------------------------------------------------------------------------------

local pending

local function ClearStutters()
    pending = nil
    for key in pairs(ns.stutters) do
        ns.stutters[key] = nil
    end
    for _, rec in ipairs(ns.list) do
        rec.stutters = 0
    end
end

local function ReadBlame()
    local top = profiler.GetTopKAddOnsForMetric(Metric.LastTime, 3)
    local overall = profiler.GetOverallMetric(Metric.LastTime) or 0
    local first = type(top) == "table" and top[1] or nil
    if first and type(first.addOnName) == "string" and type(first.metricValue) == "number" then
        return first.addOnName, first.metricValue, overall
    end
    return nil, 0, overall
end

-- One reading of what addons took in the client's last frame. A reading with a figure longer than
-- the stutter itself describes another frame and is left out whole.
local function Blame(stutter)
    if not ns.ProfilerEnabled() then
        return
    end
    local ok, name, ms, overall = pcall(ReadBlame)
    if not ok then
        return
    end
    stutter.readings = stutter.readings + 1
    local limit = stutter.ms * BLAME_SLACK
    if ms > limit or overall > limit then
        return
    end
    if name and ms > (stutter.addonMs or 0) then
        stutter.name, stutter.addonMs, stutter.reading = name, min(ms, stutter.ms), stutter.readings
    end
    stutter.overallMs = max(stutter.overallMs or 0, min(max(overall, ms), stutter.ms))
end

local function FinishStutter(readAgain)
    local stutter = pending
    pending = nil
    if readAgain then
        Blame(stutter)
    end
    local half = stutter.ms * 0.5
    if stutter.readings == 0 then
        stutter.cause = "unknown"
    elseif stutter.name and stutter.addonMs >= half then
        stutter.cause = "addon"
        local rec = ns.addons[stutter.name]
        if rec then
            rec.stutters = rec.stutters + 1
            stutter.title = rec.title
        end
        if stutter.reading == 1 then
            ns.blame.first = ns.blame.first + 1
        else
            ns.blame.second = ns.blame.second + 1
        end
    elseif (stutter.overallMs or 0) >= half then
        stutter.cause, stutter.name = "addons", nil
    else
        stutter.cause, stutter.name = "game", nil
    end
    stutter.readings, stutter.reading = nil, nil
    local list = ns.stutters
    list[#list + 1] = stutter
    list.total = (list.total or 0) + 1
    list[stutter.cause] = (list[stutter.cause] or 0) + 1
    while #list > ns.STUTTER_KEEP do
        table.remove(list, 1)
    end
    if db and db.stutterChat then
        ns.Say(ns.DescribeStutter(stutter))
    end
end

function ns.DescribeStutter(stutter)
    local what
    if stutter.cause == "addon" then
        what = ("%s took %s ms of it"):format(stutter.title or stutter.name, ns.FormatMs(stutter.addonMs))
    elseif stutter.cause == "addons" then
        what = ("addons together took %s ms of it"):format(ns.FormatMs(stutter.overallMs))
    elseif stutter.cause == "game" then
        what = ("not charged to any addon (they took %s ms)"):format(ns.FormatMs(stutter.overallMs or 0))
    else
        what = "cause unknown, the client's addon profiler is off"
    end
    return ("%s  a %d ms frame%s: %s"):format(date("%H:%M:%S", stutter.at), stutter.ms + 0.5,
        stutter.combat and " in combat" or "", what)
end

-- Frames -----------------------------------------------------------------------------------

local sampleFrames, memoryWait = 0, 0
local heapLast

local function ScannedLately(now)
    return ns.memory.at ~= nil and now - ns.memory.at < MEMORY_INTERVAL_SHOWN * 1000
end

local function OnUpdate(_, elapsed)
    local now = Now()
    if not startup.done then
        startup.frames = startup.frames + 1
        if startup.sawWorld then
            startup.t.firstFrame = startup.t.firstFrame or now
            if startup.t.screen then
                FinishStartup(now, false)
            elseif now - startup.t.world >= STARTUP_TIMEOUT_MS then
                FinishStartup(now, true)
            end
        end
        ns.frameStamp = Clock()
        return
    end
    ns.frameCount = ns.frameCount + 1
    if ns.loading and now - ns.loadingSince >= LOADING_LIMIT_MS then
        -- Given up on: a screen lifting later is some other screen, not the login's.
        ns.loading, startup.timedOut = false, nil
        ns.quietUntil = now + QUIET_AFTER_LOADING_MS
    end
    local quiet = ns.loading or now < ns.quietUntil
    if ns.settle and not quiet then
        Settle()
    end
    if ns.unbased and not quiet and not ns.holding and not ns.settle then
        Guarded(BasePending)
    end
    if ns.stutterMark ~= db.stutterMs then
        ClearStutters()
        ns.stutterMark = db.stutterMs
    end

    local ms = elapsed * 1000
    local long = ms >= db.stutterMs
    local skip = ns.skipFrame
    ns.skipFrame = nil
    if pending then
        -- The next frame's reading can still hold the stutter's work, unless that frame has its own.
        FinishStutter(not long and not skip and not ns.loading and not ns.loadedThisFrame)
    end
    ns.loadedThisFrame = nil
    if not quiet and not skip and elapsed < PAUSED_FRAME_SECONDS then
        if not long then
            ns.frameMs = ns.frameMs > 0 and ns.frameMs * 0.95 + ms * 0.05 or ms
        elseif db.stutter then
            pending = { at = time(), ms = ms, combat = InCombatLockdown() and true or false, readings = 0 }
            Blame(pending)
        end
    end

    local heap = collectgarbage("count")
    if heapLast and heap > heapLast then
        ns.heap.rise = ns.heap.rise + heap - heapLast
    end
    heapLast = heap

    local shown = ns.watching
    if quiet then
        sampleFrames = 0
    elseif shown or db.background then
        sampleFrames = sampleFrames + 1
        if sampleFrames >= SAMPLE_FRAMES then
            sampleFrames = 0
            ns.SampleCPU(shown)
        end
    end
    local memory = ns.memory
    if memory.next then
        memory.next = memory.next - elapsed
        if memory.next <= 0 and not InCombatLockdown() then
            memory.next = nil
            if (shown or db.memory) and not ScannedLately(now) then
                memoryWait = 0
                ns.SampleMemory()
            end
        end
    elseif shown or db.memory then
        memoryWait = memoryWait + elapsed
        local interval = shown and (memory.slow and MEMORY_INTERVAL_SLOW or MEMORY_INTERVAL_SHOWN) or MEMORY_INTERVAL_HIDDEN
        if memoryWait >= interval and not InCombatLockdown() then
            memoryWait = 0
            ns.SampleMemory()
        end
    end
    if shown and ns.Refresh then
        ns.Refresh(elapsed)
    end
    ns.frameStamp = Clock()
    lastClock = ns.frameStamp
end
ns.OnUpdate = OnUpdate

function ns.Watch(shown)
    ns.watching = shown and true or false
    if shown and startup.done then
        ns.SampleCPU(true, true)
        if not InCombatLockdown() and not ScannedLately(Clock()) then
            memoryWait = 0
            ns.SampleMemory()
        end
    end
end

function ns.Reset()
    local now = Clock()
    for _, rec in ipairs(ns.list) do
        rec.sum, rec.n, rec.combatSum, rec.combatN = 0, 0, 0, 0
        -- The next scan a minute or more after the addon's first becomes the reading to grow from.
        rec.memFirst, rec.memFirstAt = nil, nil
        rec.memPeak = rec.mem
        rec.growth = nil
    end
    ns.memory.growth = nil
    ns.wasReset = true
    local cpu = ns.cpu
    cpu.samples, cpu.sum = 0, nil
    ClearStutters()
    ns.heap.rise = 0
    ns.trackedSince = now
    sampleFrames = 0
    if startup.done and ns.settle ~= "startup" then
        ns.Baseline(false)
        if ns.holding then
            Hold()
        end
        ns.SampleCPU(true, true)
    end
end

-- Verdicts ---------------------------------------------------------------------------------

local function Norm(value, limit)
    if not value or value <= 0 then
        return 0
    end
    local noticeable, heavy = limit[1], limit[2]
    if value < noticeable then
        return 0.5 * value / noticeable
    end
    return 0.5 + 0.5 * (value - noticeable) / (heavy - noticeable)
end

local function LevelOf(score)
    return score >= 1 and 2 or score >= 0.5 and 1 or 0
end

function ns.Level(value, limit)
    return LevelOf(Norm(value, limit))
end

-- The frame time to judge by: the average, or the combat average once there is enough of it.
function ns.JudgedTime(rec)
    local average = ns.Average(rec) or rec.recent or 0
    if rec.combatN >= COMBAT_MIN_SAMPLES then
        local combat = rec.combatSum / rec.combatN
        if combat > average then
            return combat, true
        end
    end
    return average, false
end

local FRAME_PARTS = { "cpu", "spike", "growth" }
local OTHER_PARTS = { "memory", "load", "leak" }
local KIND = { memory = "memory", leak = "memory", load = "loading" }

-- An addon is as heavy as its worst measure. Measures that cost frames (time, spikes, garbage)
-- rank above those that cost memory or loading time at the same level.
function ns.Judge(rec)
    local limits = ns.LIMITS
    local parts = rec.parts or {}
    rec.parts = parts
    parts.cpu = Norm((ns.JudgedTime(rec)), limits.cpu)
    local _, spike = ns.SpikeLevel(rec)
    parts.spike = spike
    parts.growth = Norm(rec.growth, limits.growth)
    parts.memory = Norm(rec.mem, limits.memory)
    parts.load = max(Norm(ns.LoadTypical(rec), limits.load), Norm(rec.loadPeak, limits.burst))
    parts.leak = ns.Leak(rec) and 0.5 or 0
    local frames, other, worst = 0, 0, nil
    for _, key in ipairs(FRAME_PARTS) do
        frames = max(frames, parts[key])
    end
    for _, key in ipairs(OTHER_PARTS) do
        if parts[key] > other then
            other, worst = parts[key], key
        end
    end
    local score = max(frames, other)
    rec.score, rec.level = score, LevelOf(score)
    if rec.level == 0 then
        rec.kind = nil
    elseif LevelOf(frames) == rec.level then
        rec.kind = "frames"
    else
        rec.kind = KIND[worst]
    end
    rec.rank = rec.level * 100 + (rec.kind == "frames" and 50 or 0) + min(score, 4) * 10
    return rec.level
end

local REASONS = {
    cpu = function(rec)
        local ms, combat = ns.JudgedTime(rec)
        return ("%s ms of every frame%s"):format(ns.FormatMs(ms), combat and " in combat" or "")
    end,
    spike = function(rec)
        local rate, count = ns.SpikeRate(rec)
        return ("ran over 50 ms in %d frames (%d an hour)"):format(count, rate + 0.5)
    end,
    growth = function(rec)
        return ("makes at least %s of new memory"):format(ns.FormatRate(rec.growth))
    end,
    memory = function(rec)
        return ("holds %s"):format(ns.FormatMemory(rec.mem))
    end,
    load = function(rec)
        local limits = ns.LIMITS
        local typical = ns.LoadTypical(rec)
        if Norm(typical, limits.load) >= Norm(rec.loadPeak, limits.burst) then
            return ("%s to load"):format(ns.FormatDuration(typical))
        end
        return ("ran %s in one go while loading"):format(ns.FormatDuration(rec.loadPeak))
    end,
    leak = function(rec)
        local grown, seconds = ns.Leak(rec)
        return ("holds %s more than %s ago (addons that cache data do this too)"):format(ns.FormatMemory(grown), ns.FormatClock(seconds))
    end,
}
local REASON_ORDER = { "cpu", "spike", "growth", "memory", "load", "leak" }

local SHORT = {
    cpu = function(rec)
        local ms, combat = ns.JudgedTime(rec)
        return ("%s ms %s"):format(ns.FormatMs(ms), combat and "in combat" or "a frame")
    end,
    spike = function(rec)
        local _, count = ns.SpikeRate(rec)
        return ("%d hitches"):format(count)
    end,
    growth = function(rec)
        return ("%s new memory"):format(ns.FormatRate(rec.growth))
    end,
    memory = function(rec)
        return ("%s held"):format(ns.FormatMemory(rec.mem))
    end,
    load = function(rec)
        local limits = ns.LIMITS
        local typical = ns.LoadTypical(rec)
        if Norm(typical, limits.load) >= Norm(rec.loadPeak, limits.burst) then
            return ("%s to load"):format(ns.FormatDuration(typical))
        end
        return ("%s burst at login"):format(ns.FormatDuration(rec.loadPeak))
    end,
    leak = function(rec)
        return ("kept %s it grew"):format(ns.FormatMemory((ns.Leak(rec))))
    end,
}

-- The measure furthest past its mark in a few words, and its level; nil for a light addon.
function ns.ShortReason(rec)
    ns.Judge(rec)
    local worst, score = nil, 0.5
    for _, key in ipairs(REASON_ORDER) do
        if rec.parts[key] >= score and (not worst or rec.parts[key] > score) then
            worst, score = key, rec.parts[key]
        end
    end
    if not worst then
        return nil, 0
    end
    return SHORT[worst](rec), LevelOf(score)
end

-- The measures at or over "noticeable", worst first, in words.
function ns.Reasons(rec)
    ns.Judge(rec)
    local keys = {}
    for _, key in ipairs(REASON_ORDER) do
        if rec.parts[key] >= 0.5 then
            keys[#keys + 1] = key
        end
    end
    table.sort(keys, function(a, b)
        return rec.parts[a] > rec.parts[b]
    end)
    local out = {}
    for i, key in ipairs(keys) do
        out[i] = REASONS[key](rec)
    end
    return out
end

-- Rows and totals --------------------------------------------------------------------------

local function PeakValue(rec)
    local exact, band = ns.Peak(rec)
    return exact or band or -1
end

local SORTS = {
    name = function(rec) return rec.title:lower() end,
    weight = function(rec) return rec.rank or 0 end,
    now = function(rec) return rec.recent or -1 end,
    average = function(rec) return ns.Average(rec) or -1 end,
    combat = function(rec) return ns.CombatAverage(rec) or -1 end,
    peak = PeakValue,
    spikes = function(rec) return ns.Over(rec, SPIKE_BUCKET) or -1 end,
    memory = function(rec) return rec.mem or -1 end,
    growth = function(rec) return rec.growth or -1 end,
    load = function(rec) return rec.loadKind ~= "before" and rec.loadMs or -1 end,
}
ns.SORTS = SORTS

function ns.Rows(sort, ascending, filter)
    local key = SORTS[sort] or SORTS.weight
    filter = filter and filter ~= "" and filter:lower() or nil
    local rows = {}
    for _, rec in ipairs(ns.list) do
        if Tracked(rec) then
            ns.Judge(rec)
            if not filter or rec.title:lower():find(filter, 1, true) or rec.name:lower():find(filter, 1, true) then
                rows[#rows + 1] = rec
            end
        end
    end
    table.sort(rows, function(a, b)
        local x, y = key(a), key(b)
        if x == y then
            return a.name < b.name
        end
        if ascending then
            return x < y
        end
        return x > y
    end)
    return rows
end

function ns.Summary()
    local cpu, memory = ns.cpu, ns.memory
    local tracked = ns.TrackedSeconds()
    local summary = {
        fps = GetFramerate(),
        overall = cpu.overall, application = cpu.application,
        memory = memory.total, heap = memory.heap, growth = memory.growth,
        addonMs = startup.addonMs, blizzardMs = startup.blizzardMs, totalMs = startup.totalMs,
        counted = startup.counted, estimated = startup.estimated, reload = startup.reload,
        tracked = tracked,
        stutters = ns.stutters,
        carrier = ns.carrier or nil,
        top = {},
    }
    if cpu.samples > 0 and cpu.sum then
        summary.overallAverage = cpu.sum / cpu.samples
    end
    if tracked >= 10 then
        summary.heapRate = ns.heap.rise / tracked
    end
    if IsCpuBound then
        summary.cpuBound = IsCpuBound()
    end
    local loaded = 0
    local best = { cpu = 0, memory = 0, load = 0 }
    for _, rec in ipairs(ns.list) do
        if Tracked(rec) then
            loaded = loaded + 1
            if rec.name ~= ADDON then
                local judged = (ns.JudgedTime(rec))
                if judged > best.cpu then
                    best.cpu, summary.top.cpu = judged, rec
                end
                if (rec.mem or 0) > best.memory then
                    best.memory, summary.top.memory = rec.mem, rec
                end
                local typical = ns.LoadTypical(rec)
                if typical and typical > best.load then
                    best.load, summary.top.load = typical, rec
                end
            end
        end
    end
    summary.loaded = loaded
    summary.own = ns.addons[ADDON]
    return summary
end

-- What an addon taking `ms` of every frame costs in frames per second. Only a ceiling: a
-- frame rate held down by the graphics card or a frame cap does not rise.
function ns.FpsCost(ms, fps)
    if not ms or ms <= 0 or not fps or fps <= 0 then
        return nil
    end
    local frame = 1000 / fps
    if ms >= frame then
        return nil
    end
    return 1000 / (frame - ms) - fps
end

-- Report -----------------------------------------------------------------------------------

function ns.Report()
    if startup.done then
        ns.SampleCPU(true, true)
    end
    local summary = ns.Summary()
    local lines = {}
    local function Add(text, ...)
        lines[#lines + 1] = select("#", ...) > 0 and text:format(...) or text
    end
    local version, build = GetBuildInfo()
    Add("%s %s, client %s.%s, %s", ns.TITLE, C_AddOns.GetAddOnMetadata(ADDON, "Version") or "?", tostring(version), tostring(build), date("%Y-%m-%d %H:%M"))
    Add("Tracking for %s. %d addons loaded.", ns.FormatClock(summary.tracked), summary.loaded)
    if not ns.ProfilerEnabled() then
        Add("Frames: %.0f fps. The client's addon profiler is off, so there are no processor figures.", summary.fps)
    elseif summary.application and summary.application > 0 then
        Add("Frames: %.0f fps, %s ms of work per frame; addons are charged %s ms of it (%.0f%%)%s.", summary.fps, ns.FormatMs(summary.application),
            ns.FormatMs(summary.overall), 100 * summary.overall / summary.application,
            summary.cpuBound == nil and "" or summary.cpuBound and "; the processor is the limit" or "; the graphics card is the limit")
    else
        Add("Frames: %.0f fps.", summary.fps)
    end
    if summary.memory then
        Add("Memory: addons hold %s (all of the interface's Lua: %s).%s", ns.FormatMemory(summary.memory), ns.FormatMemory(summary.heap),
            summary.heapRate and (" The whole interface makes about %s of garbage."):format(ns.FormatRate(summary.heapRate)) or "")
    end
    if summary.totalMs then
        Add("Loading (%s): %d addons took %s%s; ready %s after the first addon began.", summary.reload and "reload" or "login", summary.counted or 0,
            ns.FormatDuration(summary.addonMs),
            (summary.estimated or 0) > 0 and (", %d more loaded on demand"):format(summary.estimated) or "", ns.FormatDuration(summary.totalMs))
    end
    if summary.carrier then
        Add("%s loaded Ace3 first: the profiler charges it with the event and setup work of every Ace3 addon.", summary.carrier.title)
    end
    Add("")
    Add("%s %7s %7s %7s %7s %6s %9s %9s %8s  %s", ns.Fit("Addon", 28), "now", "avg", "combat", "peak", ">50ms", "memory", "garbage", "load", "verdict")
    for _, rec in ipairs(ns.Rows("weight")) do
        local load = rec.loadKind ~= "before" and ns.FormatDuration(rec.loadMs) or "-"
        if rec.loadKind == "login" or rec.loadKind == "demand" then
            load = "~" .. load
        end
        Add("%s %7s %7s %7s %7s %6s %9s %9s %8s  %s", ns.Fit(rec.title, 28), ns.FormatMs(rec.recent), ns.FormatMs(ns.Average(rec)),
            ns.FormatMs(ns.CombatAverage(rec)), (ns.FormatPeak(rec)), tostring(ns.Over(rec, SPIKE_BUCKET) or "-"),
            ns.FormatMemory(rec.mem), ns.FormatRate(rec.growth), load,
            rec.level == 2 and "HEAVY: " .. table.concat(ns.Reasons(rec), "; ") or rec.level == 1 and "noticeable: " .. table.concat(ns.Reasons(rec), "; ") or "light")
    end
    Add("")
    Add("Times are ms per frame as the client's profiler charges them. now = the last 60 frames, avg = since tracking began, peak = worst frame since then (loading screens left out).")
    local stutters = ns.stutters
    if (stutters.total or 0) > 0 then
        Add("")
        Add("Frames over %d ms: %d (one addon %d, addons together %d, no addon %d, unknown %d). The last %d:", db.stutterMs, stutters.total,
            stutters.addon or 0, stutters.addons or 0, stutters.game or 0, stutters.unknown or 0, #stutters)
        for _, stutter in ipairs(stutters) do
            Add("  " .. ns.DescribeStutter(stutter))
        end
    elseif db.stutter then
        Add("")
        Add("No frame over %d ms on record.", db.stutterMs)
    end
    return lines
end

function ns.Status()
    local memory, cpu = ns.memory, ns.cpu
    local own = ns.addons[ADDON]
    local lines = {
        ("profiler %s; clock %s; %d processor samples, %d memory scans (last took %s ms%s)"):format(
            ns.ProfilerEnabled() and "on" or cpu.failed and "failed: " .. tostring(cpu.error) or "off",
            GetTimePreciseSec and "GetTimePreciseSec" or "debugprofilestop", cpu.samples, memory.scans,
            ns.FormatMs(memory.cost), memory.slow and ", so scans are spaced out" or ""),
        ("startup %s%s: %d loads timed, %d of them after a drawn frame; %d frames drawn while loading"):format(
            startup.done and "done" or startup.phase, startup.unlifted and " (the client never said the loading screen lifted)" or "",
            startup.loads, startup.split or 0, startup.frames),
        ("stutters blamed on an addon from the reading on the stutter's own frame %d times, from the frame after %d times"):format(
            ns.blame.first, ns.blame.second),
    }
    if ns.carrier then
        lines[#lines + 1] = ("Ace3 was loaded first by %s"):format(ns.carrier.title)
    end
    if own and own.recent then
        lines[#lines + 1] = ("this meter itself: %s ms per frame now, %s on average, %s"):format(
            ns.FormatMs(own.recent), ns.FormatMs(ns.Average(own)), ns.FormatMemory(own.mem))
    end
    return lines
end

-- Events -----------------------------------------------------------------------------------

local handlers = {}

handlers.ADDON_LOADED = OnAddonLoaded

function handlers.PLAYER_LOGIN()
    startup.t.login = Now()
    if startup.phase == "files" then
        startup.phase = "login"
    end
    if not db then
        LoadDatabase()
    end
    ns.Roster()
    Mark()
end

function handlers.PLAYER_ENTERING_WORLD(_, reloading)
    if not startup.done and not startup.sawWorld then
        startup.sawWorld, startup.reload = true, reloading and true or false
        startup.t.world = Now()
        Mark()
    end
end

function handlers.LOADING_SCREEN_ENABLED()
    if startup.done and not ns.loading then
        ns.loading, ns.loadingSince = true, Now()
        if not ns.holding and ns.settle ~= "startup" then
            Hold()
        end
        if ns.holding then
            ns.settle = ns.settle or "screen"
        end
    end
end

function handlers.LOADING_SCREEN_DISABLED()
    local now = Now()
    if not startup.done then
        startup.t.screen = now
        return
    end
    ns.loading = false
    ns.quietUntil = now + QUIET_AFTER_LOADING_MS
    if startup.timedOut then
        -- The first word from the client that the login screen lifted: that was when the game was ready.
        startup.timedOut, startup.unlifted = nil, nil
        startup.t.screen, startup.t.ready = now, now
        startup.totalMs = now - T0
        if startup.login then
            startup.login.totalMs = floor(startup.totalMs + 0.5)
        end
        ns.trackedSince = now
    end
end

frame:SetScript("OnEvent", function(_, event, ...)
    handlers[event](...)
end)
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("LOADING_SCREEN_ENABLED")
frame:RegisterEvent("LOADING_SCREEN_DISABLED")
frame:SetScript("OnUpdate", OnUpdate)
