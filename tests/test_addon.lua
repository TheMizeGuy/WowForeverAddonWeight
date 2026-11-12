local wow = dofile("tests/wow.lua")
local T = dofile("tests/t.lua")

local SELF = wow.ADDON

local function Near(actual, expected, tolerance, message)
    tolerance = tolerance or 1e-6
    if not (type(actual) == "number" and math.abs(actual - expected) <= tolerance) then
        error((message and message .. ": " or "") .. "expected about " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local function Three()
    return {
        { name = "Alpha", load = 100, kb = 1000, version = "2.1" },
        { name = "Bravo", title = "|cff00ff00Bravo|r Bags", load = 300, kb = 5000 },
        { name = "Charlie", load = 20 },
    }
end

local function Window()
    return _G.AddonWeightFrame
end

local function Open()
    wow.Slash("")
    return Window()
end

local function Row(name)
    for _, row in ipairs(Window().scrollBox.rows or {}) do
        if row.shown and row.rec and row.rec.name == name then
            return row
        end
    end
end

local function Order()
    local names = {}
    for _, row in ipairs(Window().scrollBox.rows or {}) do
        if row.shown and row.rec then
            names[#names + 1] = row.rec.name
        end
    end
    return table.concat(names, ",")
end

local function Header(key)
    for _, header in ipairs(Window().headers) do
        if header.column.key == key then
            return header
        end
    end
end

-- A long frame and the ordinary one after it, which is when the addon settles the blame.
local function Stutter(seconds, between)
    wow.Frame(seconds)
    if between then
        between()
    end
    wow.Frame()
end

-- Loading ----------------------------------------------------------------------------------

T.test("each addon's load time is the time between its ADDON_LOADED and the one before", function()
    local ns = wow.Start({ addons = Three() })
    T.eq(ns.addons.Alpha.loadMs, 100)
    T.eq(ns.addons.Bravo.loadMs, 300)
    T.eq(ns.addons.Charlie.loadMs, 20)
    T.eq(ns.addons[SELF].loadMs, 2, "the meter's own files, from their first line")
    T.eq(ns.addons.Alpha.loadKind, "startup")
    T.eq(ns.addons.Alpha.loadKB, 1000)
    T.eq(ns.addons.Bravo.order, 3)
end)

T.test("titles lose their colour codes and textures", function()
    local ns = wow.Start({ addons = { { name = "Fancy", title = "|cffff0000Fancy|r |TInterface\\Icons\\x:16|t Bars " } } })
    T.eq(ns.addons.Fancy.title, "Fancy  Bars")
    T.eq(ns.Clean("|cff112233|r"), nil)
end)

T.test("an addon loaded before the meter is listed but not timed", function()
    local addons = Three()
    addons[#addons + 1] = { name = "Early", before = true }
    local ns = wow.Start({ addons = addons })
    local early = ns.addons.Early
    T.eq(early.loadKind, "before")
    T.eq(early.loadMs, nil)
    T.eq(ns.startup.counted, 4, "the meter and the three it timed")
    T.eq(ns.startup.addonMs, 422)
    local text = ns.CELLS.load(early)
    T.eq(text, "-")
    T.eq(ns.db.history.Early, nil)
end)

T.test("an addon loaded on demand during login is timed from the login event and marked as an estimate", function()
    local addons = Three()
    addons[#addons + 1] = { name = "Data", lod = true }
    local ns = wow.Start({ addons = addons, duringLogin = function() wow.LoadAddon("Data", 120) end })
    local data = ns.addons.Data
    T.eq(data.loadKind, "login")
    T.eq(data.loadMs, 120)
    T.eq((ns.CELLS.load(data)), "~120 ms")
    T.eq(ns.db.history.Data, nil, "estimates stay out of the saved history")
    T.eq(ns.startup.counted, 5)
end)

T.test("an addon that loads on demand but came up among the files is an estimate too", function()
    local ns = wow.Start({ addons = { { name = "Parent", load = 50 }, { name = "Shard", lod = true } }, stopAt = "files" })
    wow.LoadAddon("Shard", 80)
    wow.Finish()
    T.eq(ns.addons.Shard.loadKind, "login")
    T.eq(ns.addons.Shard.loadMs, 80)
    T.eq(ns.addons.Parent.loadKind, "startup")
    T.eq(ns.db.history.Shard, nil)
    T.same(ns.db.history.Parent, { 50 })
end)

T.test("a percent sign in an addon's title survives the confirmation popup", function()
    wow.Start({ addons = { { name = "Pct", title = "100% Bars" } } })
    wow.Slash("")
    for _, row in ipairs(_G.AddonWeightFrame.scrollBox.rows) do
        if row.rec and row.rec.name == "Pct" then
            row:Click("RightButton")
        end
    end
    T.eq(wow.popup.text:format(), "Disable 100% Bars and reload the interface?\n\nTurn it back on from the game menu's AddOns list.")
end)

T.test("an addon loaded on demand in the session is estimated from the last frame", function()
    local addons = Three()
    addons[#addons + 1] = { name = "Late", lod = true }
    local ns = wow.Start({ addons = addons })
    wow.Run(4, 20)
    T.eq(ns.addons.Late.loaded, nil)
    wow.LoadAddon("Late", 400)
    local late = ns.addons.Late
    T.eq(late.loadKind, "demand")
    Near(late.loadMs, 350, 1, "400 ms since the last frame, less an ordinary 50 ms frame")
    T.ok(late.loadAt > 4)
    wow.Frame()
    Open()
    T.ok(Row("Late"), "it joins the list")
    T.eq((ns.CELLS.load(late)):sub(1, 1), "~")
end)

T.test("Blizzard's own on-demand modules are timed apart and stay out of the list", function()
    local ns = wow.Start({ addons = Three(), stopAt = "files" })
    wow.LoadAddon("Blizzard_Foo", 70)
    wow.Finish()
    T.eq(ns.startup.blizzardMs, 70)
    T.eq(ns.startup.addonMs, 422)
    for _, rec in ipairs(ns.Rows("name")) do
        T.ok(rec.name ~= "Blizzard_Foo")
    end
end)

T.test("a secure addon in the addon list is never queried or listed", function()
    local addons = Three()
    addons[#addons + 1] = { name = "Guarded", security = "SECURE", load = 5 }
    local ns = wow.Start({ addons = addons, setup = function() wow.refused.Guarded = true end })
    Open()
    wow.Run(70)
    T.eq(ns.cpu.failed, nil)
    T.eq(Row("Guarded"), nil)
    T.eq(ns.addons.Guarded.cpuOk, nil, "not even probed")
end)

T.test("the totals: addons' load time, time until the screen lifts, login or reload", function()
    local ns = wow.Start({ addons = Three() })
    T.eq(ns.startup.addonMs, 422)
    T.eq(ns.startup.counted, 4)
    T.eq(ns.startup.totalMs, 2 + 420 + 50 + 200 + 300)
    T.eq(ns.startup.reload, false)
    T.eq(ns.startup.slowest.name, "Bravo")
    ns = wow.Reload({ addons = Three() })
    T.eq(ns.startup.reload, true)
    T.ok(ns.SummaryLines()[3]:find("at the last reload", 1, true))
end)

T.test("startup ends by itself when the client never says the loading screen lifted", function()
    local ns = wow.Start({ addons = Three(), stopAt = "world" })
    wow.Run(9)
    T.eq(ns.startup.done, nil)
    wow.Run(2)
    T.eq(ns.startup.done, true)
    T.ok(ns.startup.totalMs > 10000)
end)

T.test("a loading screen that lifts before the world event still ends startup", function()
    local ns = wow.Start({ addons = Three(), stopAt = "login" })
    wow.Fire("LOADING_SCREEN_DISABLED")
    wow.Pass(100)
    wow.Fire("PLAYER_ENTERING_WORLD", true, false)
    wow.Frame()
    T.eq(ns.startup.done, true)
    T.eq(ns.startup.totalMs, ns.startup.t.world - ns.startup.t.start)
end)

T.test("nothing is sampled or judged a stutter before startup ends", function()
    local ns = wow.Start({ addons = Three(), stopAt = "world" })
    wow.Frame(2)
    wow.Frame(2)
    T.eq(ns.cpu.samples, 0)
    T.eq(#ns.stutters, 0)
    T.eq(wow.scans, 0)
end)

T.test("the last five load times of each addon are kept across reloads, and uninstalled addons forgotten", function()
    local ns
    for run = 1, 7 do
        local addons = Three()
        addons[1].load = 100 * run
        if run == 7 then
            table.remove(addons, 3)
        end
        ns = wow.Start({ addons = addons, keepDB = run > 1, reload = run > 1 })
    end
    T.same(ns.db.history.Alpha, { 300, 400, 500, 600, 700 })
    local average, runs = ns.LoadAverage(ns.addons.Alpha)
    T.eq(average, 500)
    T.eq(runs, 5)
    T.eq(ns.db.history.Charlie, nil)
    T.eq(#ns.db.logins, 5)
    T.eq(ns.db.logins[5].reload, true)
    T.eq(ns.db.logins[5].addons, 3)
end)

T.test("another addon restarting the debug timer does not disturb the load times", function()
    local ns = wow.Start({ addons = Three(), stopAt = "files", setup = function() end })
    T.eq(ns.addons.Charlie.loadMs, 20)
    ns = wow.Start({ stopAt = "files" })
    wow.Install("Zeta")
    wow.Pass(40)
    debugprofilestart()
    wow.Pass(60)
    wow.loaded.Zeta = true
    wow.Fire("ADDON_LOADED", "Zeta", false)
    T.eq(ns.addons.Zeta.loadMs, 100)
end)

T.test("without GetTimePreciseSec the debug timer is the clock", function()
    wow.hasPreciseClock = false
    local ns = wow.Start({ addons = Three(), setup = function() wow.hasPreciseClock = false end })
    wow.hasPreciseClock = true
    T.eq(ns.addons.Bravo.loadMs, 300)
    T.ok(ns.Status()[1]:find("debugprofilestop", 1, true))
end)

T.test("a second ADDON_LOADED for the same addon changes nothing", function()
    local ns = wow.Start({ addons = Three() })
    local loads = ns.startup.loads
    wow.Pass(500)
    wow.Fire("ADDON_LOADED", "Alpha", false)
    T.eq(ns.addons.Alpha.loadMs, 100)
    T.eq(ns.startup.loads, loads)
    wow.Fire("ADDON_LOADED", nil)
end)

T.test("the load line in chat is off unless asked for", function()
    wow.Start({ addons = Three() })
    T.eq(wow.Printed("addons loaded in"), false)
    _G.AddonWeightDB.loginLine = true
    wow.Reload({ addons = Three() })
    local line = wow.Printed("addons loaded in")
    T.ok(line and line:find("422 ms", 1, true) and line:find("Bravo Bags (300 ms)", 1, true), tostring(line))
end)

-- Processor time ---------------------------------------------------------------------------

T.test("closed, the profiler is read every two seconds; never with background measuring off", function()
    local ns = wow.Start({ addons = Three() })
    wow.Metric("Alpha", "RecentAverageTime", 0.5)
    local before = ns.cpu.samples
    wow.Run(10)
    T.eq(ns.cpu.samples - before, 5)
    T.eq(ns.addons.Alpha.session, nil, "the cheap sample reads one figure per addon")
    ns.db.background = false
    before = ns.cpu.samples
    wow.Run(10)
    T.eq(ns.cpu.samples, before)
end)

T.test("open, the profiler is read every second, in full", function()
    local ns = wow.Start({ addons = Three() })
    wow.Metric("Alpha", "SessionAverageTime", 0.7)
    Open()
    local before = ns.cpu.samples
    wow.Run(10)
    T.eq(ns.cpu.samples - before, 10)
    T.eq(ns.addons.Alpha.session, 0.7)
    Open()
    T.eq(ns.watching, false)
end)

T.test("the average is the mean of the samples, the combat average of those taken in combat", function()
    local ns = wow.Start({ addons = Three() })
    local alpha = ns.addons.Alpha
    wow.Metric("Alpha", "RecentAverageTime", 1)
    wow.Run(8)
    T.eq(ns.CombatAverage(alpha), nil)
    wow.combat = true
    wow.Metric("Alpha", "RecentAverageTime", 3)
    wow.Run(8)
    Near(ns.Average(alpha), 2)
    Near(ns.CombatAverage(alpha), 3)
    T.eq(alpha.recent, 3)
end)

T.test("with no samples yet the average falls back on the client's session average", function()
    local ns = wow.Start({ addons = Three() })
    local alpha = ns.addons.Alpha
    T.eq(ns.Average(alpha), nil)
    alpha.session = 0.4
    T.eq(ns.Average(alpha), 0.4)
end)

T.test("spikes that happened while loading are set aside; Reset sets the rest aside too", function()
    local ns = wow.Start({ addons = Three(), stopAt = "files" })
    wow.Metric("Alpha", "CountTimeOver50Ms", 2)
    wow.Finish()
    Open()
    local alpha = ns.addons.Alpha
    T.eq(ns.Over(alpha, 4), 0)
    wow.Metric("Alpha", "CountTimeOver50Ms", 5)
    wow.Run(2)
    T.eq(ns.Over(alpha, 4), 3)
    T.eq((ns.CELLS.spikes(alpha)), "3")
    ns.Reset()
    T.eq(ns.Over(alpha, 4), 0)
end)

T.test("the peak shows only once a frame beats what loading left, and again after a Reset", function()
    local ns = wow.Start({ addons = Three(), stopAt = "files" })
    wow.Metric("Alpha", "PeakTime", 900)
    wow.Finish()
    Open()
    local alpha = ns.addons.Alpha
    T.eq(alpha.loadPeak, 900)
    local peak, earlier = ns.Peak(alpha)
    T.eq(peak, nil)
    T.eq(earlier, 900)
    wow.Metric("Alpha", "PeakTime", 950)
    wow.Run(2)
    T.eq(ns.Peak(alpha), 950)
    ns.Reset()
    T.eq(ns.Peak(alpha), nil)
    T.eq(alpha.loadPeak, 900, "what loading took is not rewritten by a Reset")
    wow.Metric("Alpha", "PeakTime", 990)
    wow.Run(2)
    T.eq(ns.Peak(alpha), 990)
end)

T.test("with the profiler off there are no processor figures, and everything else still works", function()
    local ns = wow.Start({ addons = Three(), setup = function() wow.profilerEnabled = false end })
    wow.memoryLive.Alpha = 4096
    Open()
    wow.Run(6)
    T.eq(ns.cpu.samples, 0)
    T.eq(ns.addons.Alpha.recent, nil)
    T.ok(ns.SummaryLines()[1]:find("profiler is off", 1, true))
    T.eq(Row("Alpha").cells.memory.text, "4.0 MB")
    T.eq(Row("Alpha").cells.now.text, "-")
    T.ok(table.concat(ns.Report(), "\n"):find("profiler is off", 1, true))
end)

T.test("a client without the profiler namespace loads and runs", function()
    wow.hasProfiler = false
    local ok, err = pcall(function()
        local ns = wow.Start({ addons = Three(), setup = function() wow.hasProfiler = false end })
        Open()
        wow.Run(6)
        Stutter(0.3)
        T.eq(ns.stutters[1].cause, "unknown")
        T.ok(ns.Status()[1]:find("profiler off", 1, true))
    end)
    wow.hasProfiler = true
    T.ok(ok, tostring(err))
end)

T.test("an addon the profiler refuses is skipped; the others are still read", function()
    local ns = wow.Start({ addons = Three(), setup = function() wow.refused.Bravo = true end })
    wow.Metric("Alpha", "RecentAverageTime", 0.6)
    wow.memoryLive.Alpha, wow.memoryLive.Bravo = 2048, 2048
    Open()
    wow.Run(6)
    T.eq(ns.cpu.failed, nil)
    T.eq(ns.addons.Bravo.cpuOk, false)
    T.eq(ns.addons.Bravo.recent, nil)
    T.eq(ns.addons.Bravo.mem, nil)
    T.eq(ns.addons.Alpha.recent, 0.6)
    T.eq(ns.addons.Alpha.mem, 2048)
    T.ok(Row("Bravo"), "still listed, with its load time")
end)

T.test("a profiler that starts raising errors is given up on without an error reaching the game", function()
    local ns = wow.Start({ addons = Three() })
    wow.Run(4)
    wow.profilerBroken = true
    wow.Run(4)
    T.eq(ns.cpu.failed, true)
    T.eq(ns.ProfilerEnabled(), false)
    Stutter(0.3)
    T.eq(ns.stutters[1].cause, "unknown")
    T.ok(ns.Status()[1]:find("failed", 1, true))
end)

-- Memory -----------------------------------------------------------------------------------

T.test("closed, memory is scanned two seconds after loading, then once a minute, never in combat", function()
    wow.Start({ addons = Three() })
    T.eq(wow.scans, 0)
    wow.Run(1.5)
    T.eq(wow.scans, 0)
    wow.Run(1)
    T.eq(wow.scans, 1)
    wow.Run(60)
    T.eq(wow.scans, 2)
    wow.combat = true
    wow.Run(150)
    T.eq(wow.scans, 2)
    wow.combat = false
    wow.Frame()
    T.eq(wow.scans, 3)
end)

T.test("open, memory is scanned at once and every five seconds; a slow scan spaces them out", function()
    local ns = wow.Start({ addons = Three() })
    wow.Run(10)
    local before = wow.scans
    Open()
    T.eq(wow.scans, before + 1)
    wow.Run(10)
    T.eq(wow.scans, before + 3)
    wow.scanCost = 12
    wow.Run(5)
    T.eq(ns.memory.slow, true)
    before = wow.scans
    wow.Run(30)
    T.eq(wow.scans, before + 2)
    T.ok(ns.Status()[1]:find("spaced out", 1, true))
end)

T.test("reopening the window within five seconds of a scan does not scan again", function()
    wow.Start({ addons = Three() })
    wow.Run(3)
    local before = wow.scans
    Open()
    Open()
    Open()
    T.eq(wow.scans, before)
end)

T.test("with memory measuring off nothing is scanned until the window opens", function()
    local ns = wow.Start({ addons = Three() })
    ns.db.memory = false
    ns = wow.Reload({ addons = Three() })
    wow.Run(130)
    T.eq(wow.scans, 0)
    T.ok(ns.SummaryLines()[2]:find("measuring", 1, true))
    Open()
    T.eq(wow.scans, 1)
end)

T.test("the garbage rate follows rises in memory and ignores an interval in which it fell", function()
    local ns = wow.Start({ addons = Three() })
    local alpha = ns.addons.Alpha
    wow.memoryLive.Alpha = 1000
    wow.Run(3)
    T.eq(alpha.mem, 1000)
    T.eq(alpha.growth, nil)
    wow.memoryLive.Alpha = 1600
    wow.Run(60)
    Near(alpha.growth, 10, 0.01)
    wow.memoryLive.Alpha = 900
    wow.Run(60)
    Near(alpha.growth, 10, 0.01, "the collector ran: the rate stands")
    T.eq(alpha.mem, 900)
    wow.memoryLive.Alpha = 2100
    wow.Run(60)
    Near(alpha.growth, 14, 0.01)
    T.eq(alpha.memPeak, 2100)
    Near(ns.memory.growth, 14, 0.01)
    T.eq(ns.memory.total, 2100)
end)

T.test("memory that grew a lot and never came back is called out", function()
    local ns = wow.Start({ addons = Three() })
    local alpha = ns.addons.Alpha
    wow.memoryLive.Alpha = 10240
    wow.Run(3)
    wow.memoryLive.Alpha = 10240 + 20480
    wow.Run(300)
    T.eq(ns.Leak(alpha), nil, "not within ten minutes")
    wow.Run(400)
    local grown = ns.Leak(alpha)
    T.eq(grown, 20480)
    T.eq(ns.Judge(alpha), 2)
    T.ok(table.concat(ns.Reasons(alpha), "; "):find("grew 20.0 MB", 1, true))
    wow.memoryLive.Alpha = 12000
    wow.Run(60)
    T.eq(ns.Leak(alpha), nil)
end)

-- Stutters ---------------------------------------------------------------------------------

T.test("a long frame is blamed on the addon that took most of it", function()
    local ns = wow.Start({ addons = Three() })
    wow.Run(4)
    wow.Metric("Alpha", "LastTime", 180)
    wow.Metric("Bravo", "LastTime", 4)
    wow.Overall("LastTime", 190)
    wow.combat = true
    Stutter(0.25)
    local stutter = ns.stutters[1]
    T.eq(stutter.cause, "addon")
    T.eq(stutter.name, "Alpha")
    T.eq(stutter.ms, 250)
    T.eq(stutter.combat, true)
    T.eq(ns.addons.Alpha.stutters, 1)
    T.eq(ns.blame.first, 1)
    T.eq(ns.stutters.total, 1)
    local text = ns.DescribeStutter(stutter)
    T.ok(text:find("a 250 ms frame in combat: Alpha took 180 ms of it", 1, true), text)
end)

T.test("the profiler's figures for the long frame may only arrive a frame later", function()
    local ns = wow.Start({ addons = Three() })
    wow.Run(4)
    Stutter(0.25, function()
        wow.Metric("Bravo", "LastTime", 200)
        wow.Overall("LastTime", 205)
    end)
    T.eq(ns.stutters[1].cause, "addon")
    T.eq(ns.stutters[1].name, "Bravo")
    T.eq(ns.stutters[1].title, "Bravo Bags")
    T.eq(ns.blame.second, 1)
    T.eq(ns.blame.first, 0)
end)

T.test("a long frame is put down to addons together, or to the game itself", function()
    local ns = wow.Start({ addons = Three() })
    wow.Run(4)
    wow.Metric("Alpha", "LastTime", 60)
    wow.Metric("Bravo", "LastTime", 50)
    wow.Overall("LastTime", 160)
    Stutter(0.25)
    T.eq(ns.stutters[1].cause, "addons")
    T.eq(ns.stutters[1].name, nil)
    wow.Metric("Alpha", "LastTime", 3)
    wow.Metric("Bravo", "LastTime", 1)
    wow.Overall("LastTime", 6)
    Stutter(0.25)
    T.eq(ns.stutters[2].cause, "game")
    T.ok(ns.DescribeStutter(ns.stutters[2]):find("not from addons (they took 6.00 ms)", 1, true))
    T.eq(ns.addons.Alpha.stutters, 0)
    T.eq(ns.stutters.addons, 1)
    T.eq(ns.stutters.game, 1)
    T.eq(ns.SummaryLines()[4], "|cffffd200Stutters|r  2 frames over 100 ms: 1 from several addons together, 1 not from addons.")
end)

T.test("two long frames in a row are two stutters", function()
    local ns = wow.Start({ addons = Three() })
    wow.Run(4)
    wow.Metric("Alpha", "LastTime", 300)
    wow.Frame(0.4)
    wow.Frame(0.4)
    wow.Frame()
    T.eq(#ns.stutters, 2)
    T.eq(ns.addons.Alpha.stutters, 2)
end)

T.test("loading screens, the seconds after one, paused frames and the switch keep stutters out", function()
    local ns = wow.Start({ addons = Three() })
    Stutter(0.3)
    T.eq(#ns.stutters, 0, "the first three seconds after loading")
    wow.Run(4)
    wow.Fire("LOADING_SCREEN_ENABLED")
    Stutter(0.8)
    wow.Fire("LOADING_SCREEN_DISABLED")
    Stutter(0.3)
    T.eq(#ns.stutters, 0, "a loading screen and the seconds after it")
    wow.Run(4)
    Stutter(6)
    T.eq(#ns.stutters, 0, "a frame of six seconds is the game paused, not a stutter")
    ns.db.stutter = false
    Stutter(0.3)
    T.eq(#ns.stutters, 0)
    T.ok(ns.SummaryLines()[4]:find("not watched", 1, true))
    ns.db.stutter = true
    Stutter(0.3)
    T.eq(#ns.stutters, 1)
end)

T.test("the stutter mark is the setting", function()
    local ns = wow.Start({ addons = Three() })
    wow.Run(4)
    ns.db.stutterMs = 300
    Stutter(0.25)
    T.eq(#ns.stutters, 0)
    Stutter(0.35)
    T.eq(#ns.stutters, 1)
end)

T.test("the stutter list keeps the last fifty and the count of all; chat lines only when asked", function()
    local ns = wow.Start({ addons = Three() })
    wow.Run(4)
    wow.Metric("Alpha", "LastTime", 150)
    for _ = 1, 60 do
        Stutter(0.2)
    end
    T.eq(#ns.stutters, 50)
    T.eq(ns.stutters.total, 60)
    T.eq(ns.addons.Alpha.stutters, 60)
    T.eq(ns.SummaryLines()[4], "|cffffd200Stutters|r  60 frames over 100 ms: 60 from one addon (most often Alpha).")
    T.eq(wow.Printed("ms frame"), false)
    ns.db.stutterChat = true
    Stutter(0.2)
    T.ok(wow.Printed("a 200 ms frame: Alpha took 150 ms of it"))
end)

T.test("an ordinary frame's length is learned from ordinary frames only", function()
    local ns = wow.Start({ addons = Three() })
    wow.Run(6, 50)
    Near(ns.frameMs, 20, 0.5)
    Stutter(0.5)
    Near(ns.frameMs, 20, 0.5)
end)

-- Verdicts ---------------------------------------------------------------------------------

T.test("each measure has a noticeable mark and a heavy mark", function()
    local ns = wow.Start({ addons = Three() })
    local limits = ns.LIMITS
    T.eq(ns.Level(0.29, limits.cpu), 0)
    T.eq(ns.Level(0.3, limits.cpu), 1)
    T.eq(ns.Level(0.99, limits.cpu), 1)
    T.eq(ns.Level(1.0, limits.cpu), 2)
    T.eq(ns.Level(nil, limits.cpu), 0)
    T.eq(ns.Level(20480, limits.memory), 1)
    T.eq(ns.Level(76800, limits.memory), 2)
    T.eq(ns.Level(499, limits.load), 1)
    T.eq(ns.Level(500, limits.load), 2)
    T.eq(ns.Level(1, limits.spike), 1)
    T.eq(ns.Level(250, limits.growth), 2)
end)

T.test("an addon is as heavy as its worst measure, and says why, worst first", function()
    local ns = wow.Start({ addons = Three() })
    local alpha, bravo, charlie = ns.addons.Alpha, ns.addons.Bravo, ns.addons.Charlie
    wow.Metric("Alpha", "RecentAverageTime", 0.4)
    wow.memoryLive.Alpha = 100 * 1024
    wow.Run(4)
    T.eq(ns.Judge(alpha), 2)
    T.eq(alpha.worst, "memory")
    T.same(ns.Reasons(alpha), { "holds 100.0 MB", "0.40 ms of every frame" })
    T.eq(ns.Judge(bravo), 1)
    T.same(ns.Reasons(bravo), { "300 ms to load" })
    T.eq(ns.Judge(charlie), 0)
    T.same(ns.Reasons(charlie), {})
end)

T.test("an addon heavier in combat than on average is judged by its combat figure", function()
    local ns = wow.Start({ addons = Three() })
    local alpha = ns.addons.Alpha
    wow.Metric("Alpha", "RecentAverageTime", 0.05)
    wow.Run(60)
    wow.combat = true
    wow.Metric("Alpha", "RecentAverageTime", 1.2)
    wow.Run(4)
    T.ok(ns.Average(alpha) < 0.3)
    T.eq(ns.Judge(alpha), 2)
    T.same(ns.Reasons(alpha), { "1.20 ms of every frame in combat" })
end)

T.test("an addon that held the loading screen in one long go is heavy even with quick files", function()
    local ns = wow.Start({ addons = Three(), stopAt = "files" })
    wow.Metric("Charlie", "PeakTime", 1200)
    wow.Finish()
    local charlie = ns.addons.Charlie
    T.eq(ns.Judge(charlie), 2)
    T.same(ns.Reasons(charlie), { "held the loading screen for 1.2 s in one go" })
end)

T.test("spikes and garbage make an addon noticeable", function()
    local ns = wow.Start({ addons = Three() })
    local alpha = ns.addons.Alpha
    Open()
    wow.Metric("Alpha", "CountTimeOver50Ms", 1)
    wow.Run(2)
    T.eq(ns.Judge(alpha), 1)
    T.same(ns.Reasons(alpha), { "held 1 frame for over 50 ms" })
    alpha.growth = 300
    T.eq(ns.Judge(alpha), 2)
    T.eq(ns.Reasons(alpha)[1], "makes 300 KB/s of garbage")
end)

-- Rows -------------------------------------------------------------------------------------

T.test("rows: loaded addons only, heaviest first by default, by name on request, filtered by title or folder", function()
    local addons = Three()
    addons[#addons + 1] = { name = "Unloaded", lod = true }
    local ns = wow.Start({ addons = addons })
    wow.Metric("Charlie", "RecentAverageTime", 2)
    wow.Run(4)
    local rows = ns.Rows("weight")
    T.eq(#rows, 4)
    T.eq(rows[1].name, "Charlie")
    T.eq(rows[2].name, "Bravo")
    rows = ns.Rows("name", true)
    T.eq(rows[1].name, SELF)
    T.eq(rows[2].name, "Alpha")
    T.eq(rows[3].name, "Bravo")
    T.eq(#ns.Rows("weight", false, "BAGS"), 1, "by title")
    T.eq(ns.Rows("weight", false, "bRAv")[1].name, "Bravo", "by folder name")
    T.eq(#ns.Rows("weight", false, "[x"), 0, "the filter is plain text, never a pattern")
end)

T.test("every sort works on addons with nothing measured yet, both ways", function()
    local ns = wow.Start({ addons = Three(), setup = function() wow.profilerEnabled = false end })
    for key in pairs(ns.SORTS) do
        T.eq(#ns.Rows(key, false), 4, key)
        T.eq(#ns.Rows(key, true), 4, key)
    end
    T.eq(#ns.Rows("nonsense"), 4)
end)

T.test("the summary names the heaviest on frames, memory and loading, never the meter itself", function()
    local ns = wow.Start({ addons = Three(), ownMs = 900 })
    wow.Metric(SELF, "RecentAverageTime", 5)
    wow.Metric("Alpha", "RecentAverageTime", 0.2)
    wow.memoryLive[SELF], wow.memoryLive.Charlie = 99999, 500
    wow.Run(4)
    local summary = ns.Summary()
    T.eq(summary.top.cpu.name, "Alpha")
    T.eq(summary.top.memory.name, "Charlie")
    T.eq(summary.top.load.name, "Bravo")
    T.eq(summary.loaded, 4)
    T.eq(ns.SummaryLines()[5], "|cffffd200Heaviest|r  on frames Alpha, on memory Charlie, on loading Bravo Bags.")
    T.ok(ns.SummaryLines().status:find("This meter itself: 5.00 ms a frame", 1, true))
end)

T.test("the frames line gives the addons' share and says what limits the frame rate", function()
    local ns = wow.Start({ addons = Three() })
    wow.Overall("RecentAverageTime", 2)
    wow.Application("RecentAverageTime", 10)
    wow.Run(4)
    T.ok(ns.SummaryLines()[1]:find("60 fps, 10.0 ms each; addons take 2.00 ms of that (20%).", 1, true), ns.SummaryLines()[1])
    wow.cpuBound = false
    T.ok(ns.SummaryLines()[1]:find("(20%). Limited by the graphics card.", 1, true))
    wow.cpuBound = true
    T.ok(ns.SummaryLines()[1]:find("(20%). Limited by the processor.", 1, true))
end)

T.test("what an addon is worth in frames per second", function()
    local ns = wow.Start({ addons = Three() })
    Near(ns.FpsCost({ recent = 1000 / 60 / 2 }, 60), 60)
    T.eq(ns.FpsCost({ recent = 0 }, 60), nil)
    T.eq(ns.FpsCost({ recent = 20 }, 60), nil, "more than a whole frame: no honest figure")
    T.eq(ns.FpsCost({}, 60), nil)
end)

-- Window -----------------------------------------------------------------------------------

T.test("/weight opens and closes the window; Escape can close it", function()
    local ns = wow.Start({ addons = Three() })
    local window = Open()
    T.eq(window:IsShown(), true)
    T.eq(ns.watching, true)
    T.eq(_G.UISpecialFrames[1], "AddonWeightFrame")
    Open()
    T.eq(window:IsShown(), false)
    T.eq(ns.watching, false)
    _G.AddonWeight_OnAddonCompartmentClick()
    T.eq(window:IsShown(), true)
end)

T.test("a row shows the addon's figures, and marks estimates and gaps", function()
    local addons = Three()
    addons[#addons + 1] = { name = "Early", before = true }
    local ns = wow.Start({ addons = addons })
    wow.Metric("Alpha", "RecentAverageTime", 1.25)
    wow.memoryLive.Alpha = 30 * 1024
    Open()
    wow.Run(2)
    local cells = Row("Alpha").cells
    T.eq(cells.name.text, "Alpha")
    T.eq(cells.now.text, "1.25")
    T.eq(cells.average.text, "1.25")
    T.eq(cells.combat.text, "-")
    T.eq(cells.memory.text, "30.0 MB")
    T.eq(cells.load.text, "100 ms")
    T.eq(cells.weight.text, "Heavy")
    T.same(cells.now.color, { 1, 0.35, 0.3 })
    T.same(cells.memory.color, { 1, 0.82, 0 })
    T.same(cells.load.color, { 1, 1, 1 })
    T.same(cells.combat.color, { 0.5, 0.5, 0.5 })
    T.eq(Row("Early").cells.load.text, "-")
    T.eq(Row("Bravo").cells.name.text, "Bravo Bags")
    T.eq(Row("Bravo").cells.weight.text, "Noticeable")
    T.eq(Row("Charlie").cells.weight.text, "Light")
end)

T.test("the list is sorted by the clicked column, and the other way on a second click", function()
    local ns = wow.Start({ addons = Three() })
    wow.Metric("Alpha", "RecentAverageTime", 2)
    wow.Metric("Bravo", "RecentAverageTime", 1)
    Open()
    wow.Run(2)
    Header("now"):Click()
    wow.Frame()
    T.eq(Order(), "Alpha,Bravo,!!AddonWeight,Charlie")
    Header("now"):Click()
    wow.Frame()
    T.eq(Order(), "!!AddonWeight,Charlie,Bravo,Alpha")
    Header("name"):Click()
    wow.Frame()
    T.eq(Order(), "!!AddonWeight,Alpha,Bravo,Charlie")
    T.eq(ns.db.window.sort, "name")
    T.eq(ns.db.window.ascending, true)
end)

T.test("rows do not move under the mouse: figures update in place until it leaves", function()
    wow.Start({ addons = Three() })
    wow.Metric("Alpha", "RecentAverageTime", 2)
    wow.Metric("Bravo", "RecentAverageTime", 1)
    Open()
    Header("now"):Click()
    wow.Run(2)
    T.eq(Order(), "Alpha,Bravo,!!AddonWeight,Charlie")
    Window().scrollBox.mouseOver = true
    wow.Metric("Bravo", "RecentAverageTime", 3)
    wow.Run(2)
    T.eq(Order(), "Alpha,Bravo,!!AddonWeight,Charlie")
    T.eq(Row("Bravo").cells.now.text, "3.00")
    Window().scrollBox.mouseOver = false
    wow.Run(2)
    T.eq(Order(), "Bravo,Alpha,!!AddonWeight,Charlie")
end)

T.test("a header click re-sorts even with the mouse over the list", function()
    wow.Start({ addons = Three() })
    Open()
    wow.Run(2)
    Window().scrollBox.mouseOver = true
    Header("load"):Click()
    wow.Frame()
    T.eq(Order(), "Bravo,Alpha,Charlie,!!AddonWeight")
end)

T.test("an unchanged order refreshes the rows in place instead of rebuilding the list", function()
    wow.Start({ addons = Three() })
    wow.Metric("Alpha", "RecentAverageTime", 2)
    Open()
    wow.Run(3)
    local sets = wow.providerSets
    wow.Metric("Alpha", "RecentAverageTime", 2.5)
    wow.Run(5)
    T.eq(wow.providerSets, sets)
    T.eq(Row("Alpha").cells.now.text, "2.50")
end)

T.test("the search box narrows the list, and says when nothing matches", function()
    wow.Start({ addons = Three() })
    local window = Open()
    wow.Run(2)
    window.search:SetText("bags")
    wow.Frame()
    T.eq(Order(), "Bravo")
    T.eq(window.empty:IsShown(), false)
    window.search:SetText("zzz")
    wow.Frame()
    T.eq(Order(), "")
    T.eq(window.empty:IsShown(), true)
    window.search:SetText("")
    wow.Frame()
    T.eq(#Order() > 10, true)
end)

T.test("a bar behind the sorted column shows each addon against the largest", function()
    wow.Start({ addons = Three() })
    wow.memoryLive.Alpha, wow.memoryLive.Bravo = 4000, 1000
    Open()
    Header("memory"):Click()
    wow.Run(6)
    local alpha, bravo, charlie = Row("Alpha"), Row("Bravo"), Row("Charlie")
    T.eq(alpha.bar:IsShown(), true)
    T.eq(alpha.bar.width, 68)
    T.eq(bravo.bar.width, 17)
    T.eq(charlie.bar:IsShown(), false)
    Header("weight"):Click()
    wow.Frame()
    T.eq(Row("Alpha").bar:IsShown(), false)
end)

T.test("a row's tooltip tells everything measured about the addon", function()
    local ns = wow.Start({ addons = Three() })
    wow.Metric("Alpha", "RecentAverageTime", 1000 / 60 / 2)
    wow.Metric("Alpha", "EncounterAverageTime", 0.9)
    wow.memoryLive.Alpha = 30 * 1024
    Open()
    wow.Run(2)
    wow.Metric("Alpha", "CountTimeOver10Ms", 7)
    wow.Metric("Alpha", "CountTimeOver50Ms", 2)
    wow.Run(2)
    local row = Row("Alpha")
    row.scripts.OnEnter(row)
    T.eq(wow.tooltip[1], "Alpha")
    T.eq(wow.tooltip[2], "Alpha, version 2.1")
    T.ok(wow.Tooltip("Heavy: "), "the verdict line")
    T.ok(wow.Tooltip("Now: 8.33 ms a frame (50.0% of a frame)"))
    T.ok(wow.Tooltip("Last boss fight: 0.90 ms a frame"))
    T.ok(wow.Tooltip("Frames held over 5 / 10 / 50 / 100 ms: 0 / 7 / 2 / 0"))
    T.ok(wow.Tooltip("Worth right now: up to 60 fps"))
    T.ok(wow.Tooltip("Memory: 30.0 MB"))
    T.ok(wow.Tooltip("Load: 100 ms"))
    T.ok(wow.Tooltip("Memory taken while loading: 1000 KB"))
    T.ok(wow.Tooltip("Right-click to disable"))
    T.eq(ns.view.hover, row)
    row.scripts.OnLeave(row)
    T.eq(ns.view.hover, nil)
    local own = Row(SELF)
    own.scripts.OnEnter(own)
    T.eq(wow.Tooltip("Right-click"), false)
    T.ok(wow.Tooltip("Light: nothing about it stands out."))
end)

T.test("the tooltip words the load time by how it was measured", function()
    local addons = Three()
    addons[#addons + 1] = { name = "Early", before = true }
    addons[#addons + 1] = { name = "Data", lod = true }
    local ns
    for run = 1, 2 do
        ns = wow.Start({ addons = addons, keepDB = run > 1, duringLogin = function() wow.LoadAddon("Data", 120) end })
    end
    local function Load(name)
        for _, line in ipairs(ns.RowTooltipLines(ns.addons[name])) do
            if line[1] == "Load" then
                return line[2]
            end
        end
    end
    T.eq(Load("Early"), "loaded before this meter, not timed")
    T.eq(Load("Data"), "about 120 ms, loaded on demand during login")
    T.eq(Load("Alpha"), "100 ms (average of the last 2: 100 ms)")
end)

T.test("a right-click asks before disabling an addon and reloading; never in combat, never the meter", function()
    wow.Start({ addons = Three() })
    Open()
    wow.Run(2)
    Row("Bravo"):Click("RightButton")
    T.ok(wow.popup and wow.popup.text:find("Disable Bravo Bags and reload", 1, true))
    T.eq(#wow.disabled, 0)
    wow.popup.accept()
    T.same(wow.disabled, { "Bravo" })
    T.eq(wow.reloaded, true)
    wow.popup = nil
    Row(SELF):Click("RightButton")
    T.eq(wow.popup, nil)
    wow.combat = true
    Row("Alpha"):Click("RightButton")
    T.eq(wow.popup, nil)
    T.ok(wow.Printed("Not while you are in combat."))
end)

T.test("the window comes back with its saved sort and place", function()
    local ns = wow.Start({ addons = Three() })
    Open()
    Header("memory"):Click()
    Header("memory"):Click()
    local window = Window()
    window.point = { "TOPLEFT", _G.UIParent, "TOPLEFT", 120, -80 }
    window.scripts.OnDragStop(window)
    T.same(ns.db.window.point, { "TOPLEFT", 120, -80 })
    ns = wow.Reload({ addons = Three() })
    Open()
    T.eq(ns.view.sort, "memory")
    T.eq(ns.view.ascending, true)
    T.eq(Window().point[1], "TOPLEFT")
    T.eq(Window().point[4], 120)
    ns.db.window.sort, ns.db.window.point = "gone", { 1, 2 }
    ns = wow.Reload({ addons = Three() })
    Open()
    T.eq(ns.view.sort, "weight")
    T.eq(Window().point[1], "CENTER")
end)

T.test("the Reset button starts the averages and the stutter list over", function()
    local ns = wow.Start({ addons = Three() })
    wow.Metric("Alpha", "RecentAverageTime", 2)
    wow.Run(6)
    wow.Metric("Alpha", "LastTime", 150)
    Stutter(0.2)
    T.eq(ns.stutters.total, 1)
    wow.Metric("Alpha", "RecentAverageTime", 0.5)
    ns.Reset()
    T.eq(ns.stutters.total, nil)
    T.eq(#ns.stutters, 0)
    T.eq(ns.addons.Alpha.stutters, 0)
    Near(ns.Average(ns.addons.Alpha), 0.5)
    T.ok(ns.Summary().tracked < 1)
end)

T.test("the report holds the whole table and the stutters as text", function()
    local ns = wow.Start({ addons = Three() })
    wow.Metric("Alpha", "RecentAverageTime", 1.5)
    wow.Overall("RecentAverageTime", 2)
    wow.Application("RecentAverageTime", 10)
    wow.memoryLive.Alpha = 2048
    wow.Run(4)
    wow.Metric("Alpha", "LastTime", 150)
    Stutter(0.2)
    local text = table.concat(ns.Report(), "\n")
    T.ok(text:find("Addon Weight 1.0.0, client 1.60.1.70888", 1, true), text)
    T.ok(text:find("addons take 2.00 ms of it (20%)", 1, true))
    T.ok(text:find("Loading (login): 4 addons took 422 ms", 1, true))
    T.ok(text:find("HEAVY: 1.50 ms of every frame", 1, true))
    T.ok(text:find("Bravo Bags", 1, true))
    T.ok(text:find("Frames over 100 ms: 1 (one addon 1,", 1, true))
    T.ok(text:find("a 200 ms frame: Alpha took 150 ms of it", 1, true))
    ns.ShowReport()
    T.eq(_G.AddonWeightReportFrame:IsShown(), true)
    T.eq(_G.AddonWeightReportFrame.box.text, table.concat(ns.Report(), "\n"))
end)

-- Commands and settings ----------------------------------------------------------------------

T.test("/weight top names the addons that stand out, or says none does", function()
    wow.Start({ addons = { { name = "Tiny", load = 5 } } })
    wow.Slash("top")
    T.ok(wow.Printed("2 addons loaded and none stands out so far."))
    wow.Start({ addons = Three() })
    wow.Slash("TOP")
    T.ok(wow.Printed("Bravo Bags|r: 300 ms to load."))
    T.eq(wow.Printed("Charlie"), false)
end)

T.test("the other commands: reset, status, report, config, help for anything else", function()
    local ns = wow.Start({ addons = Three() })
    wow.Slash("reset")
    T.ok(wow.Printed("start over from now"))
    wow.Slash("status")
    T.ok(wow.Printed("profiler on; clock GetTimePreciseSec"))
    T.ok(wow.Printed("startup done: 4 loads timed"))
    wow.Slash("report")
    T.eq(_G.AddonWeightReportFrame:IsShown(), true)
    wow.Slash("config")
    T.eq(wow.openedCategory, 77)
    wow.Slash("what")
    T.ok(wow.Printed("/weight opens the window."))
    T.eq(_G.SLASH_ADDONWEIGHT1, "/weight")
    T.eq(_G.SLASH_ADDONWEIGHT2, "/addonweight")
    wow.openedCategory = nil
    wow.combat = true
    wow.Slash("settings")
    T.eq(wow.openedCategory, nil)
    T.ok(wow.Printed("The settings page cannot open right now."))
    T.eq(ns.TITLE, "Addon Weight")
end)

T.test("every setting has a control on the settings page", function()
    local ns = wow.Start({ addons = Three() })
    local controls = {}
    for _, setting in ipairs(wow.settings) do
        controls[setting.key] = setting
    end
    for key, default in pairs(ns.DEFAULTS) do
        T.ok(controls[key], "no control for " .. key)
        T.eq(controls[key].default, default, key)
        T.eq(controls[key].varType, type(default), key)
    end
    T.eq(#wow.sliders, 1)
    T.eq(wow.sliders[1].options.low, 40)
    T.eq(wow.sliders[1].options.high, 500)
    T.eq(wow.sliders[1].options.formatter(120), "120 ms")
    T.eq(wow.registeredCategory.name, "Addon Weight")
    controls.stutter:SetValue(false)
    T.eq(ns.db.stutter, false)
end)

T.test("saved settings of the wrong kind are repaired and the stutter mark kept in range", function()
    wow.Start({ addons = Three() })
    _G.AddonWeightDB = { background = "yes", stutterMs = 5, history = 3, logins = "x", window = false, memory = false }
    local ns = wow.Reload({ addons = Three() })
    T.eq(ns.db.background, true)
    T.eq(ns.db.stutterMs, 40)
    T.eq(ns.db.memory, false)
    T.eq(type(ns.db.history), "table")
    T.eq(#ns.db.logins, 1)
    T.eq(type(ns.db.window), "table")
    _G.AddonWeightDB = "broken"
    ns = wow.Reload({ addons = Three() })
    T.eq(ns.db.stutterMs, 100)
end)

T.test("figures are worded for reading", function()
    local ns = wow.Start({})
    T.eq(ns.FormatMs(nil), "-")
    T.eq(ns.FormatMs(0.004), "0")
    T.eq(ns.FormatMs(0.456), "0.46")
    T.eq(ns.FormatMs(12.34), "12.3")
    T.eq(ns.FormatMs(123.6), "124")
    T.eq(ns.FormatDuration(0.4), "<1 ms")
    T.eq(ns.FormatDuration(999), "999 ms")
    T.eq(ns.FormatDuration(1234), "1.2 s")
    T.eq(ns.FormatMemory(nil), "-")
    T.eq(ns.FormatMemory(512.4), "512 KB")
    T.eq(ns.FormatMemory(1536), "1.5 MB")
    T.eq(ns.FormatRate(0.2), "0")
    T.eq(ns.FormatRate(120), "120 KB/s")
    T.eq(ns.FormatRate(2048), "2.0 MB/s")
    T.eq(ns.FormatClock(75), "1:15")
    T.eq(ns.FormatClock(3725), "1:02:05")
end)

T.done()
