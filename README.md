# Addon Weight (WoW Forever)

Shows how heavy each of your other addons is, so you can find the one that costs you frames, memory
or loading time. For the WoW Forever client (interface 16001). `/weight` opens the window.

## The window

Four tiles across the top each name one addon and one number:

| Tile | Names | Says |
|---|---|---|
| Frame rate | the addon that takes the most processor time per frame | its ms per frame (in combat, when that is higher) and what turning it off could be worth in fps |
| Stutters | the addon that took most of the most long frames | how many of the stutters seen were its doing |
| Memory | the addon that holds the most memory | how much, and the total for all addons |
| Loading | the addon that took longest to load | how long, and the total against the whole login |

A tile turns grey and says "Nothing stands out" when its heaviest addon is under the mark. A line
above the tiles gives your frame rate, what limits it (processor or graphics card, when the client
says), the share of each frame's work charged to addons, and how long the figures cover.

Below is one row per loaded addon:

| Column | What it is | Where it comes from |
|---|---|---|
| Average ms | processor time per frame since login, reload or Reset | the mean of the client profiler's 60-frame averages (`C_AddOnProfiler`, always on, no setting needed), one sample every 60 frames |
| Combat ms | the same, only while in combat | the in-combat samples |
| Peak ms | its worst single frame since tracking began, loading screens left out | the profiler's peak when it rose in that time; otherwise `>100` style, from the profiler's counters |
| Hitches | frames in which it alone ran over 50 ms, loading screens left out | the profiler's counters |
| Memory MB | what it holds | `GetAddOnMemoryUsage` |
| Load ms | its files and saved settings at the last login or reload | the time between its `ADDON_LOADED` and the one before; `~` marks an estimate |
| Why | the measure furthest past its mark, in words; blank when nothing stands out | the marks below |

The list opens sorted by "Why": heavy addons first, and at the same level those that cost frames
above those that cost memory or loading time. A heavy addon has an alert icon after its name. Click a
header to sort by that column; rows do not move while the mouse is over the list. Hover a row for
everything measured about that addon, including "Right now" and how fast it makes new memory.
Right-click a row to disable that addon for this character and reload (it asks first).

**Reset** starts the session's averages, hitch counts and stutter list over: press it right before
the fight or the place you want measured. **Copy Text** gives every table as text.

## Two tabs: this session and all time

The tabs under the window switch what the tiles and the list show.

- **This session** is everything since the last login, reload or Reset.
- **All time** is what each addon cost over every session, kept in the saved settings
  (`AddonWeightDB`): frame time averaged over all samples, hitches per hour measured, its worst frame,
  the stutters it took most of, its memory when last measured, and the middle one of its last five
  load times. The session under way is included as it goes, so a `/reload`, a logout or a Reset
  loses nothing. Addons that are installed but not loaded this session stay in the list, greyed and
  marked "(not loaded)".

**Removed addons.** When you delete an addon from your AddOns folder, its saved figures go at the
next login. Turn on "Keep the figures of addons you remove" in the settings to keep them instead:
they stay in the All time list, greyed and marked "(removed)", until you right-click the row and
forget it. `/weight forget` clears everything saved, after asking.

## Commands

| Command | Does |
|---|---|
| `/weight` | opens or closes the window (`/addonweight` too; also in the addon compartment) |
| `/weight all`, `/weight session` | opens the window on that tab |
| `/weight top` | names the addons that stand out, in chat |
| `/weight report` | the table as text to copy |
| `/weight reset` | starts the session's averages, hitch counts and stutter list over (all-time figures keep what was measured) |
| `/weight forget` | clears every saved figure, after asking |
| `/weight config` | the settings page (Esc > Options > AddOns > Addon Weight) |
| `/weight status` | what the meter itself is doing, for troubleshooting |

Settings: keep measuring with the window closed (on), measure memory with the window closed (on),
watch for stutters (on) and the frame length that counts as one (100 ms), say each stutter in chat
(off), say the load time in chat after loading (off), keep the figures of addons you remove (off).

## The marks

| Measure | Noticeable | Heavy | Costs |
|---|---|---|---|
| Frame time, average (or in combat, after about ten seconds of it) | 0.5 ms a frame | 1 ms a frame | frames |
| Hitches (frames it ran over 50 ms) | 2 seen and 6 an hour | 5 seen and 60 an hour | frames |
| New memory | 50 KB/s | 250 KB/s | frames |
| Memory held | 50 MB | 200 MB | memory |
| Load time (the middle one of the last five logins, once there are three) | 150 ms | 500 ms | loading |
| Longest burst of work while loading | 250 ms | 1 s | loading |

At 60 frames per second a frame is 16.7 ms, so 1 ms is 6% of it; at 144 it is 14%. An addon whose
memory grew by 20 MB or more over ten minutes or more, by at least half of what it held a minute
after loading, is marked Noticeable (never Heavy for that alone: addons that cache data do it too).

## What the numbers can and cannot tell you

- **Frame time is what the client's profiler charges to the addon.** It charges the addon that
  created the frame the work runs on. Ace3 keeps one event frame and one setup frame for every addon
  that uses it, so the first addon to load Ace3 is charged with the event and setup work of all of
  them; the meter marks that addon ("It loaded Ace3 first") and warns before you disable it that the
  cost will move, not go away. Work that starts in Blizzard's own code (hooks, tooltip additions) or
  from a mouse click on an addon's button is charged to no addon. So an addon can look heavier or
  lighter than it is, and a stutter "not charged to any addon" can still be addon code.
- **"Up to +N fps"** is a ceiling. If the graphics card or a frame cap sets your frame rate, lighter
  addons will not raise it; the meter says "Little to gain" when the client reports the graphics
  card as the limit.
- **Load time** is the time between two `ADDON_LOADED` events. It holds the addon's files and its
  saved settings, plus whatever other addons did in reaction to the previous addon finishing (an
  addon's own load handler, an Ace3 addon's `OnInitialize`), so small figures are rough. Work an
  addon does at login is in no addon's Load figure; the tooltip line "Longest burst of work while
  loading" (the profiler's peak when loading finished) is the hint for that, and it counts toward the
  verdict. An addon that loads on demand is an estimate, marked `~`, and is neither judged nor in the
  totals. Addons that loaded before the meter (a folder name sorting before `!!AddonWeight`) are not
  timed.
- **Memory includes garbage not yet cleaned up**, and held memory alone rarely costs frames.
  Measuring it stops the game for as long as the scan takes, and with many large addons that is
  long enough to feel (version 1.0.0 scanned on a timer and hitched for exactly that reason). So the
  meter times every scan and never scans in combat. A scan under 10 ms repeats once a minute with
  the window closed and every 5 seconds with it open. A longer one, or one whose cost is not known
  yet, runs only while a loading screen is up and when you open the window (at most every 15
  seconds), never on a timer: the same rule Blizzard's AddOn list follows. The Memory tile then says
  how old its reading is; close and reopen the window for a fresh one. `/weight status` and the
  Memory column's tooltip say what a scan costs on your setup. The "new memory" rate is taken from
  rises between scans, so it is a floor. The whole interface's rate in the report comes from the Lua
  heap itself, frame by frame.
- **Stutters** are whole frames over the mark, loading screens and the three seconds after one left
  out. Blame comes from what the profiler says each addon took in that frame: one addon if it took at
  least half, addons together if they all did, otherwise no addon (the game itself, the graphics
  card, the disk, or addon code the profiler cannot see). The frame after the meter's own memory
  scan is never counted.
- The meter lists itself. With the window closed it reads the profiler twice per addon every 60
  frames and the Lua heap size once a frame, and adds the session's figures to the saved ones at
  logout, at a Reset and while the All time tab is open.

## Other tools

Blizzard's AddOn list already shows a processor share and memory per addon in its tooltips. Numy's
Addon Profiler, Laggy Addon Detector and AddonAudit also read the client's profiler on Forever.
Addon Weight adds load times, the stutter log with a cause, the combat average, the Ace3 carrier
warning, one reason per addon and figures kept across sessions.

## Install

Copy the `!!AddonWeight` folder into `World of Warcraft\_forever_\Interface\AddOns`. The folder name
starts with `!!` on purpose: addons load in name order, and the meter has to load first to time the
others. A new addon shows up after logging out to the character list.

## Development

- `bash tests/run.sh` must end `ALL PASSED`: Lua 5.1 syntax, the XML, the TOC file list, an audit
  that every client API, template and font the addon names exists in the Forever UI source for the
  build (`tests/audit_globals.py`, reading `.cache/wow-ui-source-forever` and the build's global
  strings; `--fetch` downloads them), and the LuaJIT suite (`tests/test_addon.lua`) that runs the
  whole addon under a fake client (`tests/wow.lua`: a login, frames, the profiler, memory scans, the
  window).
- `scripts/deploy.sh [ssh-host] [addons-dir]` copies the folder to a Windows client over ssh and
  checks every file's SHA-256 on the other side.
- Files: `Core.lua` (measuring; no UI), `Window.lua` (the window and the text report), `Options.lua`
  (settings page, commands), `Templates.xml` (the list's row template).
- The window uses Blizzard's own table kit: `ColumnDisplayButtonShortTemplate` headers, the auction
  house's row stripes, highlight and sort arrow, `Number14FontWhite` digits, the AddOn list's alert
  icon and divider; offsets are multiples of 5 units so they land on whole pixels at 1.2 pixels per
  unit (1440p at the default UI scale).

## In game: what to check

The first rows settle things the source cannot: paste `/weight status` after doing them.

| Check | How | Expected |
|---|---|---|
| The meter loads first | `/weight status` | "startup done: N loads timed" with N near your addon count, "0 of them after a drawn frame" |
| The loading screen's end is seen | `/weight status` after a `/reload` | no "(the client never said the loading screen lifted)"; the Loading tile's total near what you felt |
| The profiler is on | `/weight status` | "profiler on" |
| Which reading carries the blame | `/weight status` after a few stutters blamed on an addon | counts for "the stutter's own frame" and "the frame after" |
| A memory scan's cost | `/weight status` | "last took N ms"; at 10 or more the meter only scans behind loading screens and on opening the window |
| The scan alone | `/run local t=debugprofilestop() UpdateAddOnMemoryUsage() print(debugprofilestop()-t)` | the same figure, straight from the client |
| Who the client charges for it | `/dump AddOnPerformance:AddOnHasPerformanceWarning("!!AddonWeight")` | false |
| The meter does not hitch | play with the window closed, then open | no regular pause; the meter's own row stays near 0 hitches |
| Figures survive | `/reload`, then the All time tab | the same addons with their averages; "2 sessions" in the line above the tiles |
| The tabs draw right | `/weight`, click each tab | two tabs under the window, the selected one raised, not covering the buttons |
| The window draws right | `/weight` | tiles, striped rows, headers with a sort arrow, the alert icon on heavy rows, nothing overlapping |
| The sort arrow fits the narrow headers | `/run for i,h in ipairs(AddonWeightFrame.headers) do print(i, h.arrow:GetWidth(), h.Text:GetLeft()-h:GetLeft()-3-h.arrow:GetWidth()) end` | the last number 2 or more on every line |
| The report opens at its top | `/weight report`, then `/dump AddonWeightReportFrame.scroll:GetVerticalScroll()` | 0 |
| The row stripes show | `/dump C_Texture.GetAtlasInfo("auctionhouse-rowstripe-1")` | a table, and alternating stripes in the list |
| Load times | `/reload`, then sort by Load ms | the big addons (quest database, guides) at the top |
| Frame time | sort by Average ms, stand still, then fight | figures move; Combat ms fills in |
| Stutter blame | open the world map or a big addon window for the first time | the Stutters tile names that addon, or says the frame was charged to none |
| Loading screens are left out | take a portal or enter an instance | no new hitches or stutters from the loading screen |
| The Ace3 carrier | hover the rows of your Ace3 addons | one says "It loaded Ace3 first" |
| Disable | right-click a row | a confirmation; accepting disables the addon for this character and reloads |
| No errors | play a session with BugSack | no Lua error from Addon Weight |
