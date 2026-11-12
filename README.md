# Addon Weight (WoW Forever)

Shows how heavy each of your other addons is, so you can find the one that costs you frames, memory
or loading time. For the WoW Forever client (interface 16001). `/weight` opens the window.

For every loaded addon it shows:

| Column | What it is | Where it comes from |
|---|---|---|
| Now | ms of each frame the addon's code took, over the last 60 frames | the client's own profiler (`C_AddOnProfiler`, always on, no setting needed) |
| Average | the same since login, reload or Reset | the mean of this addon's samples of "Now" |
| Combat | the same, only while you were in combat | as above, combat samples only |
| Peak | the longest it held up one frame since loading finished | the profiler's peak, less what loading left |
| Spikes | frames it alone held for over 50 ms | the profiler's counters, less what loading left |
| Memory | what it holds now | `GetAddOnMemoryUsage` |
| Garbage | how fast it makes new memory | rises between memory scans |
| Load | how long its files and saved settings took at the last login or reload | the time between its `ADDON_LOADED` and the one before |
| Verdict | Light, Noticeable or Heavy: its worst measure | the marks below |

Above the list: your frame rate and how much of each frame addons take, total addon memory, how long
the addons took to load and how long until the game was ready, the stutters seen (frames over 100 ms)
and whether an addon caused them, and the heaviest addon on frames, on memory and on loading.

Hover a row for everything measured about that addon. Right-click a row to disable that addon and
reload (it asks first). **Reset** starts the averages over, for measuring one fight or one place.
**Report** gives the whole table as text to copy.

## Commands

| Command | Does |
|---|---|
| `/weight` | opens or closes the window (`/addonweight` too; also in the addon compartment) |
| `/weight top` | names the addons that stand out, in chat |
| `/weight report` | the table as text to copy |
| `/weight reset` | starts averages, spike counts and the stutter list over |
| `/weight config` | the settings page (Esc > Options > AddOns > Addon Weight) |
| `/weight status` | what the meter itself is doing, for troubleshooting |

Settings: keep measuring with the window closed (on), measure memory with the window closed (on),
watch for stutters (on) and the length that counts as one (100 ms), say each stutter in chat (off),
say the load time in chat after loading (off).

## The marks

| Measure | Noticeable | Heavy |
|---|---|---|
| Frame time, average or in combat | 0.3 ms a frame | 1 ms a frame |
| Frames it held for over 50 ms | 1 | 10 |
| Memory | 20 MB | 75 MB |
| Garbage | 50 KB/s | 250 KB/s |
| Load time | 150 ms | 500 ms |
| Longest single hold of the loading screen | 250 ms | 1 s |

At 60 frames per second a frame is 16.7 ms, so 1 ms is 6% of it; at 144 it is 14%. An addon whose
memory grew by 20 MB or more over ten minutes or more, by at least half of what it first held, and
kept it, is called Heavy as well.

## What the numbers can and cannot tell you

- **Frame time is the client's own measurement.** It charges the addon whose code started the work.
  Work inside a library that several addons share (Ace3's event frame, for one) is charged to the
  addon that loaded that library first, and work started by a mouse click on an addon's button is
  not measured at all. So one addon can look heavier and another lighter than it is.
- **"Worth up to N fps"** in the tooltip is a ceiling. If the graphics card or a frame cap sets your
  frame rate (the first line says "Limited by the graphics card"), lighter addons will not raise it.
- **Load time** is the time between two `ADDON_LOADED` events. It holds the addon's files and its
  saved settings, plus whatever other addons did in reaction to the previous addon finishing, so
  small figures are rough. Work an addon does later, at login, is in no addon's Load figure; the
  tooltip line "Longest it held the loading screen" (the profiler's peak while loading) is the
  hint for that. An addon that loads on demand is an estimate, marked `~`. Addons that loaded
  before the meter (a folder name sorting before `!!AddonWeight`) are not timed.
- **Memory scans cost a little themselves**, so with the window closed there is one a minute and
  none in combat. The garbage rate is taken from rises between scans; with a minute between scans it
  is a floor, and it sharpens while the window is open (a scan every 5 seconds).
- **Stutters** are blamed from what each addon took in that one frame: one addon if it took at
  least half of it, addons together if they all did, otherwise the game itself (loading a zone,
  the graphics card, the disk). The meter's own memory scan can cause one; it shows under its own
  name.
- The meter lists itself. Its own cost with the window closed is a few profiler reads every two
  seconds.

## Other tools

Blizzard's AddOn list already shows a processor share and memory per addon in its tooltips. Numy's
Addon Profiler, Laggy Addon Detector and AddonAudit also read the client's profiler on Forever.
Addon Weight adds load times, the stutter log with a cause, the combat average and one verdict per
addon.

## Install

Copy the `!!AddonWeight` folder into `World of Warcraft\_forever_\Interface\AddOns`. The folder name
starts with `!!` on purpose: addons load in name order, and the meter has to load first to time the
others. A new addon shows up after logging out to the character list.

## Development

- `bash tests/run.sh` must end `ALL PASSED`: Lua 5.1 syntax, the XML, the TOC file list, an audit
  that every client API the addon names exists in the Forever UI source for the build
  (`tests/audit_globals.py`, reading `.cache/wow-ui-source-forever` and the build's global strings;
  `--fetch` downloads them), and the LuaJIT suite (`tests/test_addon.lua`) that runs the whole addon
  under a fake client (`tests/wow.lua`: a login, frames, the profiler, memory scans, the window).
- `scripts/deploy.sh [ssh-host] [addons-dir]` copies the folder to a Windows client over ssh and
  checks every file's SHA-256 on the other side.
- Files: `Core.lua` (measuring; no UI), `Window.lua` (the window and the report), `Options.lua`
  (settings page, commands), `Templates.xml` (the list's row template).

## In game: what to check

| Check | How | Expected |
|---|---|---|
| The meter loads first | `/weight status` | "startup done: N loads timed" with N near your addon count |
| The profiler is on | `/weight status` | "profiler on" |
| Load times | `/reload`, then `/weight` and sort by Load | the big addons (quest database, guides) at the top; the Loading line near what you felt |
| Frame time | sort by Now, stand still, then fight | figures move; the Frames line's share is believable |
| Stutter blame | open the world map or a big addon window for the first time | a stutter listed, with that addon named |
| What the blame reads | `/weight status` after a few stutters | which reading (the stutter's frame or the one after) is used on this client |
| Memory | leave the window open a minute | Memory and Garbage fill in; the meter's own line stays small |
| Disable | right-click a row | a confirmation; accepting disables the addon and reloads |
| No errors | play a session with BugSack | no Lua error from Addon Weight |
