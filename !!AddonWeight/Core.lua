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

local max, min, floor = math.max, math.min, math.floor

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
    cpu = { 0.3, 1.0 },         -- ms per frame, averaged
    spike = { 1, 10 },          -- frames the addon alone held for over 50 ms
    memory = { 20480, 76800 },  -- KB
    growth = { 50, 250 },       -- KB per second
    load = { 150, 500 },        -- ms
    login = { 250, 1000 },      -- ms in one frame while loading
}

ns.BUCKETS = { 1, 5, 10, 50, 100, 500, 1000 }
local SPIKE_BUCKET = 4
local BUCKET_METRICS = {
    "CountTimeOver1Ms", "CountTimeOver5Ms", "CountTimeOver10Ms", "CountTimeOver50Ms",
    "CountTimeOver100Ms", "CountTimeOver500Ms", "CountTimeOver1000Ms",
}

local CPU_INTERVAL_SHOWN, CPU_INTERVAL_HIDDEN = 1, 2
local MEMORY_INTERVAL_SHOWN, MEMORY_INTERVAL_HIDDEN, MEMORY_INTERVAL_SLOW = 5, 60, 15
local MEMORY_SLOW_MS = 10
local FIRST_MEMORY_DELAY = 2
local QUIET_AFTER_LOADING_MS = 3000
local STARTUP_TIMEOUT_MS = 10000
local PAUSED_FRAME_SECONDS = 5
local LEAK_MIN_KB, LEAK_MIN_SECONDS = 20480, 600

local db
local frame = CreateFrame("Frame")
ns.frame = frame

local startup = { phase = "files", mark = T0, heapMark = HEAP0, loads = 0, t = { start = T0 } }
ns.startup = startup
ns.loading = true
ns.quietUntil = 0
ns.frameMs = 0
ns.frameStamp = T0
ns.trackedSince = T0
ns.memory = { scans = 0 }
ns.cpu = { samples = 0 }
ns.blame = { first = 0, second = 0 }

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
            sum = 0, n = 0, combatSum = 0, combatN = 0, alloc = 0, stutters = 0,
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
    if type(db.logins) ~= "table" then
        db.logins = {}
    end
    if type(db.window) ~= "table" then
        db.window = {}
    end
    db.schema = 1
    ns.db = db
end

local function OnAddonLoaded(name)
    local now = Clock()
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
    if startup.phase == "files" then
        -- An addon that loads on demand was asked for from another's code, whose time is in the gap too.
        local demanded = not rec.blizzard and C_AddOns.IsAddOnLoadOnDemand(name)
        rec.loadMs, rec.loadKind = max(0, now - startup.mark), demanded and "login" or "startup"
        rec.loadKB = max(0, heap - startup.heapMark)
        startup.t.files = now
    elseif startup.phase == "login" then
        rec.loadMs, rec.loadKind = max(0, now - startup.mark), "login"
    else
        -- Only the last frame boundary is known: what remains after an ordinary frame is the load.
        rec.loadMs, rec.loadKind = max(0, now - ns.frameStamp - ns.frameMs), "demand"
        rec.loadAt = (now - T0) / 1000
    end
    if name == ADDON then
        LoadDatabase()
        ns.Roster()
        if ns.RegisterSettings then
            ns.RegisterSettings(db)
        end
    elseif startup.phase == "session" and not rec.blizzard and rec.index == nil then
        ns.Roster()
    end
    startup.mark = Clock()
    startup.heapMark = collectgarbage("count")
end

local function History(name)
    local runs = db.history[name]
    if type(runs) ~= "table" then
        runs = {}
        db.history[name] = runs
    end
    return runs
end

local function FinishStartup(now)
    startup.done, startup.phase = true, "session"
    startup.t.ready = max(startup.t.screen or now, startup.t.world or now)
    ns.loading = false
    ns.quietUntil = now + QUIET_AFTER_LOADING_MS
    ns.trackedSince = now
    ns.Roster()

    local addonMs, blizzardMs, counted, slowest = 0, 0, 0, nil
    for _, rec in ipairs(ns.list) do
        if rec.loadKind == "startup" or rec.loadKind == "login" then
            if rec.blizzard then
                blizzardMs = blizzardMs + rec.loadMs
            elseif rec.installed then
                addonMs = addonMs + rec.loadMs
                counted = counted + 1
                if not slowest or rec.loadMs > slowest.loadMs then
                    slowest = rec
                end
                if db and rec.loadKind == "startup" then
                    local runs = History(rec.name)
                    runs[#runs + 1] = floor(rec.loadMs * 10 + 0.5) / 10
                    while #runs > ns.HISTORY_KEEP do
                        table.remove(runs, 1)
                    end
                end
            end
        end
    end
    startup.addonMs, startup.blizzardMs, startup.counted, startup.slowest = addonMs, blizzardMs, counted, slowest
    startup.totalMs = startup.t.ready - T0
    if db then
        for name in pairs(db.history) do
            local rec = ns.addons[name]
            if not (rec and rec.installed) then
                db.history[name] = nil
            end
        end
        local logins = db.logins
        logins[#logins + 1] = {
            at = time(), reload = startup.reload and true or false,
            addonMs = floor(addonMs + 0.5), totalMs = floor(startup.totalMs + 0.5), addons = counted,
        }
        while #logins > ns.HISTORY_KEEP do
            table.remove(logins, 1)
        end
    end
    ns.Baseline(true)
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

-- Processor time ---------------------------------------------------------------------------

local profiler = C_AddOnProfiler
local Metric = Enum and Enum.AddOnProfilerMetric

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

-- Spike counters and the peak are counted from here on: what loading added to them is set aside.
function ns.Baseline(atStartup)
    if not ns.ProfilerEnabled() then
        return
    end
    local ok = pcall(function()
        for _, rec in ipairs(ns.list) do
            if Tracked(rec) and Profiled(rec) then
                ReadBuckets(rec, rec.base)
                rec.peakBase = profiler.GetAddOnMetric(rec.name, Metric.PeakTime) or 0
                if atStartup then
                    rec.loadPeak = rec.peakBase
                end
            end
        end
    end)
    if not ok then
        ns.cpu.failed = true
    end
end

local function SampleCPU(full)
    local cpu = ns.cpu
    local combat = InCombatLockdown() and true or false
    for _, rec in ipairs(ns.list) do
        if Tracked(rec) and Profiled(rec) then
            local recent = profiler.GetAddOnMetric(rec.name, Metric.RecentAverageTime) or 0
            rec.recent = recent
            rec.sum, rec.n = rec.sum + recent, rec.n + 1
            if combat then
                rec.combatSum, rec.combatN = rec.combatSum + recent, rec.combatN + 1
            end
            if full then
                rec.session = profiler.GetAddOnMetric(rec.name, Metric.SessionAverageTime) or 0
                rec.peak = profiler.GetAddOnMetric(rec.name, Metric.PeakTime) or 0
                rec.encounter = profiler.GetAddOnMetric(rec.name, Metric.EncounterAverageTime) or 0
                ReadBuckets(rec, rec.over)
            end
        end
    end
    cpu.overall = profiler.GetOverallMetric(Metric.RecentAverageTime) or 0
    cpu.application = profiler.GetApplicationMetric(Metric.RecentAverageTime) or 0
    cpu.samples = cpu.samples + 1
    cpu.sum = (cpu.sum or 0) + cpu.overall
    if combat then
        cpu.combatSum, cpu.combatN = (cpu.combatSum or 0) + cpu.overall, (cpu.combatN or 0) + 1
    end
end

function ns.SampleCPU(full)
    if not ns.ProfilerEnabled() then
        return false
    end
    local ok, err = pcall(SampleCPU, full)
    if not ok then
        ns.cpu.failed, ns.cpu.error = true, tostring(err)
    end
    return ok
end

function ns.Average(rec)
    return rec.n > 0 and rec.sum / rec.n or rec.session
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

-- The profiler's peak covers loading too; a peak no higher than the one set aside is not news.
function ns.Peak(rec)
    if not rec.peak then
        return nil
    end
    if rec.peakBase and rec.peak <= rec.peakBase then
        return nil, rec.peak
    end
    return rec.peak
end

-- Memory -----------------------------------------------------------------------------------

function ns.SampleMemory()
    local memory = ns.memory
    local started = Clock()
    UpdateAddOnMemoryUsage()
    local now = Clock()
    memory.cost = now - started
    memory.slow = memory.cost >= MEMORY_SLOW_MS
    local seconds = memory.at and (now - memory.at) / 1000 or nil
    local total, growth = 0, 0
    for _, rec in ipairs(ns.list) do
        if Tracked(rec) and rec.memOk == nil then
            rec.memOk = pcall(GetAddOnMemoryUsage, rec.name)
        end
        if Tracked(rec) and rec.memOk then
            local kb = GetAddOnMemoryUsage(rec.name) or 0
            if rec.mem and seconds and seconds > 0 then
                -- A fall means the collector ran in between: that interval says nothing about the rate.
                local delta = kb - rec.mem
                if delta >= 0 then
                    local rate = delta / seconds
                    rec.alloc = rec.alloc + delta
                    rec.growth = rec.growth and (rec.growth * 0.6 + rate * 0.4) or rate
                end
                growth = growth + (rec.growth or 0)
            end
            if not rec.memFirst then
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

-- Net growth since the first reading, once it is both large and most of what the addon holds.
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

local function ReadBlame()
    local top = profiler.GetTopKAddOnsForMetric(Metric.LastTime, 3)
    local overall = profiler.GetOverallMetric(Metric.LastTime) or 0
    local first = type(top) == "table" and top[1] or nil
    if first and type(first.addOnName) == "string" and type(first.metricValue) == "number" then
        return first.addOnName, first.metricValue, overall
    end
    return nil, 0, overall
end

local function Blame(stutter)
    if not ns.ProfilerEnabled() then
        return
    end
    local ok, name, ms, overall = pcall(ReadBlame)
    if not ok then
        return
    end
    if ms > (stutter.addonMs or -1) then
        stutter.name, stutter.addonMs, stutter.reading = name, ms, stutter.readings + 1
    end
    stutter.overallMs = max(stutter.overallMs or 0, overall)
    stutter.readings = stutter.readings + 1
end

local function FinishStutter()
    local stutter = pending
    pending = nil
    Blame(stutter)
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
    elseif (stutter.overallMs or 0) >= half then
        stutter.cause, stutter.name = "addons", nil
    else
        stutter.cause, stutter.name = "game", nil
    end
    if stutter.reading == 1 then
        ns.blame.first = ns.blame.first + 1
    elseif stutter.reading == 2 then
        ns.blame.second = ns.blame.second + 1
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
        what = ("not from addons (they took %s ms)"):format(ns.FormatMs(stutter.overallMs or 0))
    else
        what = "cause unknown, the client's addon profiler is off"
    end
    return ("%s  a %d ms frame%s: %s"):format(date("%H:%M:%S", stutter.at), stutter.ms + 0.5,
        stutter.combat and " in combat" or "", what)
end

-- Frames -----------------------------------------------------------------------------------

local cpuWait, memoryWait = 0, 0

local function OnUpdate(_, elapsed)
    local now = Clock()
    if not startup.done then
        if startup.sawWorld and (startup.t.screen or now - startup.t.world >= STARTUP_TIMEOUT_MS) then
            FinishStartup(now)
            ns.frameStamp = now
        end
        return
    end
    if pending then
        FinishStutter()
    end
    local ms = elapsed * 1000
    if db.stutter and ms >= db.stutterMs and elapsed < PAUSED_FRAME_SECONDS and not ns.loading and now >= ns.quietUntil then
        pending = { at = time(), ms = ms, combat = InCombatLockdown() and true or false, readings = 0 }
        Blame(pending)
    elseif elapsed < PAUSED_FRAME_SECONDS then
        ns.frameMs = ns.frameMs > 0 and ns.frameMs * 0.95 + ms * 0.05 or ms
    end
    ns.frameStamp = now

    local shown = ns.watching
    if shown or db.background then
        cpuWait = cpuWait + elapsed
        if cpuWait >= (shown and CPU_INTERVAL_SHOWN or CPU_INTERVAL_HIDDEN) then
            cpuWait = 0
            ns.SampleCPU(shown)
        end
    end
    local memory = ns.memory
    if memory.next then
        memory.next = memory.next - elapsed
        if memory.next <= 0 then
            memory.next = nil
            if shown or db.memory then
                memoryWait = 0
                ns.SampleMemory()
            end
        end
    elseif shown or db.memory then
        memoryWait = memoryWait + elapsed
        local interval = shown and (memory.slow and MEMORY_INTERVAL_SLOW or MEMORY_INTERVAL_SHOWN) or MEMORY_INTERVAL_HIDDEN
        if memoryWait >= interval and (shown or not InCombatLockdown()) then
            memoryWait = 0
            ns.SampleMemory()
        end
    end
    if shown and ns.Refresh then
        ns.Refresh(elapsed)
    end
end
ns.OnUpdate = OnUpdate

function ns.Watch(shown)
    ns.watching = shown and true or false
    if shown and startup.done then
        cpuWait = 0
        ns.SampleCPU(true)
        if not ns.memory.at or Clock() - ns.memory.at >= MEMORY_INTERVAL_SHOWN * 1000 then
            memoryWait = 0
            ns.SampleMemory()
        end
    end
end

function ns.Reset()
    local now = Clock()
    for _, rec in ipairs(ns.list) do
        rec.sum, rec.n, rec.combatSum, rec.combatN = 0, 0, 0, 0
        rec.alloc, rec.stutters = 0, 0
        rec.memFirst, rec.memFirstAt = rec.mem, rec.mem and now or nil
        rec.memPeak = rec.mem
    end
    local cpu = ns.cpu
    cpu.samples, cpu.sum, cpu.combatSum, cpu.combatN = 0, nil, nil, nil
    for key in pairs(ns.stutters) do
        ns.stutters[key] = nil
    end
    ns.trackedSince = now
    ns.Baseline(false)
    if startup.done then
        ns.SampleCPU(true)
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

function ns.Judge(rec)
    local limits = ns.LIMITS
    local parts = rec.parts or {}
    rec.parts = parts
    parts.cpu = Norm(max(ns.Average(rec) or rec.recent or 0, ns.CombatAverage(rec) or 0), limits.cpu)
    parts.spike = Norm(ns.Over(rec, SPIKE_BUCKET), limits.spike)
    parts.memory = Norm(rec.mem, limits.memory)
    parts.growth = Norm(rec.growth, limits.growth)
    parts.load = rec.loadKind ~= "before" and Norm(rec.loadMs, limits.load) or 0
    parts.login = Norm(rec.loadPeak, limits.login)
    local score, worst = 0, nil
    for key, value in pairs(parts) do
        if value > score then
            score, worst = value, key
        end
    end
    if ns.Leak(rec) then
        score = max(score, 1)
        worst = worst or "memory"
    end
    rec.score, rec.worst = score, worst
    rec.level = score >= 1 and 2 or score >= 0.5 and 1 or 0
    return rec.level
end

function ns.Level(value, limit)
    local score = Norm(value, limit)
    return score >= 1 and 2 or score >= 0.5 and 1 or 0
end

local REASONS = {
    cpu = function(rec)
        local combat = ns.CombatAverage(rec)
        local average = ns.Average(rec) or rec.recent or 0
        if combat and combat > average then
            return ("%s ms of every frame in combat"):format(ns.FormatMs(combat))
        end
        return ("%s ms of every frame"):format(ns.FormatMs(average))
    end,
    spike = function(rec)
        local count = ns.Over(rec, SPIKE_BUCKET)
        return ("held %d frame%s for over 50 ms"):format(count, count == 1 and "" or "s")
    end,
    memory = function(rec)
        return ("holds %s"):format(ns.FormatMemory(rec.mem))
    end,
    growth = function(rec)
        return ("makes %s of garbage"):format(ns.FormatRate(rec.growth))
    end,
    load = function(rec)
        return ("%s to load"):format(ns.FormatDuration(rec.loadMs))
    end,
    login = function(rec)
        return ("held the loading screen for %s in one go"):format(ns.FormatDuration(rec.loadPeak))
    end,
}
local REASON_ORDER = { "cpu", "spike", "memory", "growth", "load", "login" }

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
    local grown, seconds = ns.Leak(rec)
    if grown then
        out[#out + 1] = ("grew %s in %s and has not given it back"):format(ns.FormatMemory(grown), ns.FormatClock(seconds))
    end
    return out
end

-- Rows and totals --------------------------------------------------------------------------

local SORTS = {
    name = function(rec) return rec.title:lower() end,
    weight = function(rec) return rec.score or 0 end,
    now = function(rec) return rec.recent or -1 end,
    average = function(rec) return ns.Average(rec) or -1 end,
    combat = function(rec) return ns.CombatAverage(rec) or -1 end,
    peak = function(rec) return ns.Peak(rec) or -1 end,
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
    local summary = {
        fps = GetFramerate(),
        overall = cpu.overall, application = cpu.application,
        memory = memory.total, heap = memory.heap, growth = memory.growth,
        addonMs = startup.addonMs, blizzardMs = startup.blizzardMs, totalMs = startup.totalMs,
        counted = startup.counted, reload = startup.reload,
        tracked = (Clock() - ns.trackedSince) / 1000,
        stutters = ns.stutters,
        top = {},
    }
    if cpu.samples > 0 and cpu.sum then
        summary.overallAverage = cpu.sum / cpu.samples
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
                local average = ns.Average(rec) or rec.recent or 0
                if average > best.cpu then
                    best.cpu, summary.top.cpu = average, rec
                end
                if (rec.mem or 0) > best.memory then
                    best.memory, summary.top.memory = rec.mem, rec
                end
                if rec.loadKind ~= "before" and (rec.loadMs or 0) > best.load then
                    best.load, summary.top.load = rec.loadMs, rec
                end
            end
        end
    end
    summary.loaded = loaded
    summary.own = ns.addons[ADDON]
    return summary
end

-- What turning this addon off would be worth right now, in frames per second. Only a ceiling: a
-- frame rate held down by the graphics card or a frame cap does not rise.
function ns.FpsCost(rec, fps)
    local ms = rec.recent
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
        ns.SampleCPU(true)
    end
    local summary = ns.Summary()
    local lines = {}
    local function Add(text, ...)
        lines[#lines + 1] = select("#", ...) > 0 and text:format(...) or text
    end
    local version, build = GetBuildInfo()
    Add("%s %s, client %s.%s, %s", ns.TITLE, C_AddOns.GetAddOnMetadata(ADDON, "Version") or "?", tostring(version), tostring(build), date("%Y-%m-%d %H:%M"))
    Add("Tracking for %s. %d addons loaded.", ns.FormatClock(summary.tracked), summary.loaded)
    if summary.application and summary.application > 0 then
        Add("Frames: %.0f fps, %s ms per frame; addons take %s ms of it (%.0f%%)%s.", summary.fps, ns.FormatMs(summary.application),
            ns.FormatMs(summary.overall), 100 * summary.overall / summary.application,
            summary.cpuBound == nil and "" or summary.cpuBound and "; the processor is the limit" or "; the graphics card is the limit")
    elseif ns.ProfilerEnabled() then
        Add("Frames: %.0f fps.", summary.fps)
    else
        Add("Frames: %.0f fps. The client's addon profiler is off, so there are no processor figures.", summary.fps)
    end
    if summary.memory then
        Add("Memory: addons hold %s (all of the interface's Lua: %s), growing %s.", ns.FormatMemory(summary.memory), ns.FormatMemory(summary.heap), ns.FormatRate(summary.growth))
    end
    if summary.totalMs then
        Add("Loading (%s): %d addons took %s; ready %s after the first addon began.", summary.reload and "reload" or "login", summary.counted or 0,
            ns.FormatDuration(summary.addonMs), ns.FormatDuration(summary.totalMs))
    end
    Add("")
    Add("%-28s %7s %7s %7s %7s %6s %9s %9s %8s  %s", "Addon", "now", "avg", "combat", "peak", ">50ms", "memory", "garbage", "load", "verdict")
    for _, rec in ipairs(ns.Rows("weight")) do
        local load = rec.loadKind ~= "before" and ns.FormatDuration(rec.loadMs) or "-"
        if rec.loadKind == "login" or rec.loadKind == "demand" then
            load = "~" .. load
        end
        Add("%-28s %7s %7s %7s %7s %6s %9s %9s %8s  %s", rec.title:sub(1, 28), ns.FormatMs(rec.recent), ns.FormatMs(ns.Average(rec)),
            ns.FormatMs(ns.CombatAverage(rec)), ns.FormatMs(ns.Peak(rec)), tostring(ns.Over(rec, SPIKE_BUCKET) or "-"),
            ns.FormatMemory(rec.mem), ns.FormatRate(rec.growth), load,
            rec.level == 2 and "HEAVY: " .. table.concat(ns.Reasons(rec), "; ") or rec.level == 1 and "noticeable: " .. table.concat(ns.Reasons(rec), "; ") or "light")
    end
    Add("")
    Add("Times are ms per frame. now = the last 60 frames, avg = since tracking began, peak = worst single frame since loading.")
    local stutters = ns.stutters
    if (stutters.total or 0) > 0 then
        Add("")
        Add("Frames over %d ms: %d (one addon %d, addons together %d, not addons %d, unknown %d). The last %d:", db.stutterMs, stutters.total,
            stutters.addon or 0, stutters.addons or 0, stutters.game or 0, stutters.unknown or 0, #stutters)
        for _, stutter in ipairs(stutters) do
            Add("  " .. ns.DescribeStutter(stutter))
        end
    elseif db.stutter then
        Add("")
        Add("No frame over %d ms since tracking began.", db.stutterMs)
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
        ("startup %s: %d loads timed; stutter blame read on the stutter's frame %d times, the frame after %d times"):format(
            startup.done and "done" or startup.phase, startup.loads, ns.blame.first, ns.blame.second),
    }
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
    local now = Clock()
    startup.t.login = now
    if startup.phase == "files" then
        startup.phase = "login"
    end
    if not db then
        LoadDatabase()
    end
    ns.Roster()
    startup.mark = Clock()
end

function handlers.PLAYER_ENTERING_WORLD(_, reloading)
    if not startup.done and not startup.sawWorld then
        startup.sawWorld, startup.reload = true, reloading and true or false
        startup.t.world = Clock()
        startup.mark = startup.t.world
    end
end

function handlers.LOADING_SCREEN_ENABLED()
    ns.loading = true
end

function handlers.LOADING_SCREEN_DISABLED()
    local now = Clock()
    if startup.done then
        ns.loading = false
        ns.quietUntil = now + QUIET_AFTER_LOADING_MS
    else
        startup.t.screen = now
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
