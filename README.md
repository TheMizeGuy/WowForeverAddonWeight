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

**Reset** starts the averages, hitch counts and the stutter list over: press it right before the
fight or the place you want measured. **Copy Text** gives the whole table as text.

## Commands

| Command | Does |
|---|---|
| `/weight` | opens or closes the window (`/addonweight` too; also in the addon compartment) |
| `/weight top` | names the addons that stand out, in chat |
| `/weight report` | the table as text to copy |
| `/weight reset` | starts averages, hitch counts and the stutter list over |
| `/weight config` | the settings page (Esc > Options > AddOns > Addon Weight) |
| `/weight status` | what the meter itself is doing, for troubleshooting |

Settings: keep measuring with the window closed (on), measure memory with the window closed (on),
watch for stutters (on) and the frame length that counts as one (100 ms), say each stutter in chat
(off), say the load time in chat after loading (off).

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
- **Memory includes garbage not yet cleaned up**, and held memory alone rarely costs frames. A memory
  scan costs a little itself, so there is one a minute with the window closed, one every 5 seconds
  with it open, and none in combat. The "new memory" rate is taken from rises between scans, so it
  is a floor, and it sharpens while the window is open. The whole interface's rate in the report
  comes from the Lua heap itself, frame by frame.
- **Stutters** are whole frames over the mark, loading screens and the three seconds after one left
  out. Blame comes from what the profiler says each addon took in that frame: one addon if it took at
  least half, addons together if they all did, otherwise no addon (the game itself, the graphics
  card, the disk, or addon code the profiler cannot see). The frame after the meter's own memory
  scan is never counted.
- The meter lists itself. With the window closed it reads the profiler twice per addon every 60
  frames and the Lua heap size once a frame.

## Other tools

Blizzard's AddOn list already shows a processor share and memory per addon in its tooltips. Numy's
Addon Profiler, Laggy Addon Detector and AddonAudit also read the client's profiler on Forever.
Addon Weight adds load times, the stutter log with a cause, the combat average, the Ace3 carrier
warning and one reason per addon.

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
| A memory scan's cost | `/weight status` with the window open | "last took N ms"; under 10 is normal |
| The window draws right | `/weight` | tiles, striped rows, headers with a sort arrow, the alert icon on heavy rows, nothing overlapping |
| Load times | `/reload`, then sort by Load ms | the big addons (quest database, guides) at the top |
| Frame time | sort by Average ms, stand still, then fight | figures move; Combat ms fills in |
| Stutter blame | open the world map or a big addon window for the first time | the Stutters tile names that addon, or says the frame was charged to none |
| Loading screens are left out | take a portal or enter an instance | no new hitches or stutters from the loading screen |
| The Ace3 carrier | hover the rows of your Ace3 addons | one says "It loaded Ace3 first" |
| Disable | right-click a row | a confirmation; accepting disables the addon for this character and reloads |
| No errors | play a session with BugSack | no Lua error from Addon Weight |
