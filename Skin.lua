-- ============================================================================
--  Skin.lua  --  brain for the Win98 Date/Time skin  (v4.1)
--
--  The .ini stays pure layout.  Everything this script computes is pushed out
--  as a Rainmeter variable, and the meters that display it are grouped, so a
--  change repaints only the group it belongs to.
--
--  Responsibilities
--    clock      hand angles and the digital time field (12 h / 24 h)
--    calendar   browsable month grid, click a day to select it
--    usage log  records when this computer was on, and when it was on *and
--               unlocked*, and charts the selected day as one 3D block per
--               hour -- its height the unlocked minutes of that hour -- across
--               a fixed window of the day (07:00 to 21:00 by default)
--
--  How the usage log works
--    Rainmeter keeps ticking while the workstation is locked, so two facts are
--    enough to reconstruct a day without any helper process:
--        1. this script ran at second T   ->  the machine was on at T
--        2. LogonUI.exe is running        ->  the lock screen is up
--    A tick that arrives more than GAP_SECONDS after the previous one means the
--    machine was off, asleep, or Rainmeter was not running in between, so the
--    interval is closed at the last tick that was actually observed.  Anything
--    else is one continuous interval tagged U (unlocked) or L (locked).
--    Intervals are appended to a small text journal so the record survives a
--    skin refresh, a reboot, and the switch to a new day.
--
--  Performance
--    Per second: three angle variables, one time string, one measure read.
--    set() silently drops writes that would not change anything, so a quiet
--    second costs one or two bangs and no repaint at all.  The heavier work
--    (usage panel, time zone, calendar grid) runs on the minute, or when the
--    user does something, and then repaints one meter group instead of the
--    whole skin.
--
--  Hand angles are emitted as whole degrees on purpose: that keeps
--  locale-dependent decimal separators out of the shape options.
-- ============================================================================

--  ---- tunables --------------------------------------------------------------
--  Not exposed as skin variables: changing them changes behaviour, not looks.

local GAP_SECONDS   = 90     -- longer tick gap than this => machine was away
local FLUSH_SECONDS = 120    -- how often the still-open interval is written out
local SEED_SECONDS  = 600    -- start the session at the Windows sign-in time if
                             -- the skin started within this long of signing in
local MAX_HOURS     = 24     -- hour slots provisioned in [MeterUseBar]: four
                             -- Bar<n>* shape variables per hour, plus BarNow
local DEPTH         = 5      -- isometric depth of a block, in px: how far its
                             -- top and side recede up and to the right.  The
                             -- floor band in [MeterUseTrough] is drawn 5 rows
                             -- deep to match, so change the two together
local HEADROOM      = 3      -- rows kept clear above a full 60-minute block,
                             -- so its top never touches the field's bezel
local BAR_GAP       = 5      -- px between neighbouring blocks; narrowed
                             -- automatically when the window is too wide for
                             -- the faces to stay legible at this spacing
local MIN_BLOCK     = 4      -- px: a few unlocked minutes still deserve a
                             -- visible block, not a rounding to nothing
local RULE_ROWS     = 8      -- rows the hour ruler occupies at the foot of the
                             -- graph; the interior is BarH + this
-- An interval that was still running when it was last written out may be picked
-- up again this long afterwards. It covers a skin refresh, which is otherwise
-- indistinguishable from the machine having been away for the same stretch.
local RESUME_SECONDS = FLUSH_SECONDS + GAP_SECONDS
local EPOCH_1601    = 11644473600  -- seconds from 1601-01-01 to the Unix epoch
local MIN_UNLOCK    = 30     -- closed unlocked stretches shorter than this are
                             -- noise, not use: LogonUI.exe restarts by itself
                             -- while the lock screen's display sleeps, and for
                             -- the second or two it is gone the probe reads as
                             -- unlocked.  Dropped for display only; the journal
                             -- on disk keeps every interval as observed.
local EMPTY_SHAPE   = 'Rectangle 0,0,1,1 | Fill Color 0,0,0,0 | StrokeWidth 0'
local EMPTY_PATH    = '0,0 | LineTo 0,0 | ClosePath 1'  -- a path with no area

local MONTHS = { 'January', 'February', 'March', 'April', 'May', 'June',
                 'July', 'August', 'September', 'October', 'November', 'December' }

-- Day-name headers.  Index 1 is whichever day WeekStart selects.
local DAYNAMES = {
    [1] = { 'M', 'T', 'W', 'Th', 'F', 'Sa', 'Su' },   -- WeekStart=1, Monday first
    [0] = { 'S', 'M', 'T', 'W', 'T', 'F', 'S' },      -- WeekStart=0, Sunday first
}

--  ---- state -----------------------------------------------------------------

local pushed  = {}   -- variable name -> last value pushed, to skip no-op writes
local dirty   = {}   -- meter group -> needs !UpdateMeterGroup
local handles = {}   -- measure name -> measure object, resolved on first use

local bar     = {}   -- usage bar geometry, read from the skin variables
local use24   = true -- owned here, so a click cannot be lost between measures

local viewYear,  viewMonth            -- nil, nil = follow the real date
local selYear,   selMonth,  selDay    -- nil = follow today

local journalPath                     -- nil = nowhere writable, memory only
local usage       = {}                -- ['YYYY-MM-DD'] = { {s=, e=, locked=} }
local usageRev    = 0                 -- bumped whenever an interval is stored
local live                            -- the interval currently being observed
local nextFlush   = 0
local nextMinute  = 0
local gridKey     = ''
local ready       = false             -- measures have been read at least once

--  ============================================================================
--  Variables and repainting
--  ============================================================================

-- Push a value to the skin, but only if it actually changed.  Passing a group
-- marks that group for repainting; variables read by per-second meters (the
-- clock) need no group, because those meters update on their own.
local function set(name, value, group)
    if pushed[name] == value then return false end
    pushed[name] = value
    SKIN:Bang('!SetVariable', name, value)
    if group then dirty[group] = true end
    return true
end

-- Update the meter groups that changed, and redraw once if any did.
local function flush()
    local repaint = false
    for group in pairs(dirty) do
        SKIN:Bang('!UpdateMeterGroup', group)
        dirty[group] = nil
        repaint = true
    end
    if repaint then SKIN:Bang('!Redraw') end
end

-- Hidden= options all over the skin are formulas on #Page#, so a page switch is
-- the one case that has to touch every meter.
local function repaintAll()
    for group in pairs(dirty) do dirty[group] = nil end
    SKIN:Bang('!UpdateMeter', '*')
    SKIN:Bang('!Redraw')
end

local function variable(name, default)
    return SKIN:GetVariable(name, default) or default
end

local function number(name, default)
    return tonumber(SKIN:GetVariable(name, '')) or default
end

-- Measure objects are cached: Update() reads the lock state every second.
local function measure(name)
    local m = handles[name]
    if m == nil then
        m = SKIN:GetMeasure(name) or false
        handles[name] = m
    end
    return m or nil
end

--  ============================================================================
--  Small helpers
--  ============================================================================

local function weekStart()
    return variable('WeekStart', '1') == '0' and 0 or 1
end

local function dayKey(ts)
    return os.date('%Y-%m-%d', ts)
end

local function keyOf(year, month, day)
    return string.format('%04d-%02d-%02d', year, month, day)
end

local function midnight(ts)
    local t = os.date('*t', ts)
    return os.time{ year = t.year, month = t.month, day = t.day,
                    hour = 0, min = 0, sec = 0 }
end

-- Never midnight + 86400: the day a clock goes forward is 23 hours long, and
-- the day it goes back is 25.  Letting mktime normalise day + 1 gets both right.
local function nextMidnight(ts)
    local t = os.date('*t', ts)
    return os.time{ year = t.year, month = t.month, day = t.day + 1,
                    hour = 0, min = 0, sec = 0 }
end

local function daysInMonth(year, month)
    if month == 2 then
        if (year % 4 == 0 and year % 100 ~= 0) or year % 400 == 0 then
            return 29
        end
        return 28
    end
    local lengths = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    return lengths[month]
end

-- 0 = Monday .. 6 = Sunday shifted by WeekStart: the column of the 1st.
local function firstColumn(year, month, ws)
    local first = os.date('*t', os.time{ year = year, month = month,
                                         day = 1, hour = 12 })
    return (first.wday - 1 - ws) % 7   -- wday is 1 = Sunday .. 7 = Saturday
end

local function clock24(ts)
    return os.date('%H:%M', ts)
end

-- 0 -> "0m", 754 -> "12m", 22320 -> "6h 12m"
local function duration(seconds)
    seconds = math.floor(seconds)
    if seconds < 0 then seconds = 0 end
    local hours   = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    if hours > 0 then return string.format('%d h %02d m', hours, minutes) end
    return string.format('%d m', minutes)
end

local function longDate(ts)
    local t = os.date('*t', ts)
    return string.format('%s %d %s', os.date('%a', ts), t.day,
                         MONTHS[t.month]:sub(1, 3))
end

--  ============================================================================
--  Usage journal
--
--  File format, one interval per line, always inside a single day:
--      YYYY-MM-DD HH:MM:SS HH:MM:SS U           (U = unlocked, L = locked)
--      YYYY-MM-DD HH:MM:SS HH:MM:SS U open      still running when written
--  An "open" end time is a lower bound: the interval had not finished yet, so
--  the skin is allowed to pick it back up when it starts again shortly after.
--  Gaps between intervals are time the machine was off, asleep, or without
--  Rainmeter running.  Plain text on purpose: it is readable, greppable, and
--  trivial to delete if you would rather not keep the history.
--  ============================================================================

-- The journal lives outside the skin folder, because Documents is often
-- OneDrive-redirected and shielded by Controlled Folder Access on managed
-- machines, which denies writes there.  Candidates are tried in order; opening
-- for append is also the test for "does this directory exist and is it mine".
local function openJournalPath()
    local candidates = {}
    local appdata = os.getenv('LOCALAPPDATA')
    if appdata then
        candidates[1] = appdata .. '\\Win98DateTime\\Usage.log'
        candidates[2] = appdata .. '\\Win98DateTime.log'
    end
    candidates[#candidates + 1] = SKIN:MakePathAbsolute('Usage.log')

    for i = 1, #candidates do
        local file = io.open(candidates[i], 'a')
        if file then
            file:close()
            return candidates[i]
        end
    end
    return nil
end

-- Store one interval.  Intervals that continue the previous one (same lock
-- state, no real gap) are merged, so a skin refresh does not fragment the day.
local function store(key, from, to, locked)
    if to <= from then return end
    local day = usage[key]
    if not day then
        day = {}
        usage[key] = day
    end
    local last = day[#day]
    if last and last.locked == locked and from - last.e <= 1 then
        last.e = to
    else
        day[#day + 1] = { s = from, e = to, locked = locked }
    end
    usageRev = usageRev + 1
end

local function beginInterval(startedAt, locked, seenAt)
    live = {
        key    = dayKey(startedAt),
        ends   = nextMidnight(startedAt),       -- where this day stops
        s      = startedAt,
        locked = locked,
        seen   = seenAt or startedAt,
    }
end

local function endInterval(at)
    if not live then return end
    store(live.key, live.s, at, live.locked)
    live = nil
end

local function loadJournal()
    usage, usageRev = {}, usageRev + 1
    if not journalPath then return end
    local file = io.open(journalPath, 'r')
    if not file then return end

    for line in file:lines() do
        local y, mo, d, h1, m1, s1, h2, m2, s2, state, rest = line:match(
            '^(%d%d%d%d)%-(%d%d)%-(%d%d) (%d%d):(%d%d):(%d%d) (%d%d):(%d%d):(%d%d) ([UL])(.*)$')
        if y then
            local base = { year = tonumber(y), month = tonumber(mo),
                           day = tonumber(d) }
            local from = os.time{ year = base.year, month = base.month,
                                  day = base.day, hour = tonumber(h1),
                                  min = tonumber(m1), sec = tonumber(s1) }
            local to   = os.time{ year = base.year, month = base.month,
                                  day = base.day, hour = tonumber(h2),
                                  min = tonumber(m2), sec = tonumber(s2) }
            local key = y .. '-' .. mo .. '-' .. d
            store(key, from, to, state == 'L')
            -- Remember the tail that had not finished, so resumeSession() can
            -- tell a refresh apart from the machine having been away.
            local day = usage[key]
            if day and #day > 0 then
                day[#day].unfinished = (rest:find('open', 1, true) ~= nil) or nil
            end
        end
    end
    file:close()
end

-- Rewrites the whole journal: it is a few kilobytes, and a full rewrite is how
-- the history gets pruned and how the open interval keeps a provisional end.
local function saveJournal(now)
    if not journalPath then return end
    local file = io.open(journalPath, 'w')
    if not file then return end

    local cutoff = dayKey(now - (number('HistoryDays', 31) - 1) * 86400)
    local keys = {}
    for key in pairs(usage) do
        if key >= cutoff then keys[#keys + 1] = key end
    end
    table.sort(keys)

    local out = { '# Win98 Date/Time usage log -- delete this file to forget it.',
                  '# date       from     to       U = unlocked, L = locked' }
    local function line(key, from, to, locked, unfinished)
        out[#out + 1] = string.format('%s %s %s %s%s', key,
                                      os.date('%H:%M:%S', from),
                                      os.date('%H:%M:%S', to),
                                      locked and 'L' or 'U',
                                      unfinished and ' open' or '')
    end

    for i = 1, #keys do
        local key = keys[i]
        local day = usage[key]
        for j = 1, #day do line(key, day[j].s, day[j].e, day[j].locked) end
        if live and live.key == key then
            line(key, live.s, live.seen, live.locked, true)
        end
    end
    if live and not usage[live.key] then
        line(live.key, live.s, live.seen, live.locked, true)
    end

    file:write(table.concat(out, '\n'), '\n')
    file:close()
end

--  ---- observing the machine -------------------------------------------------

local function lockScreenUp()
    local m = measure('MeasureLockScreen')
    -- A Process measure reads 1 when LogonUI.exe is running, -1 when it is not.
    return m ~= nil and m:GetValue() > 0
end

-- Windows sign-in time, as a Unix timestamp, or nil when it looks implausible.
local function signInTime()
    local m = measure('MeasureLogon')
    if not m then return nil end
    local raw = m:GetValue()
    if not raw or raw <= EPOCH_1601 then return nil end
    return math.floor(raw - EPOCH_1601)
end

-- Called once, on the first update, when measure values are available.
local function resumeSession(now, locked)
    local key = dayKey(now)
    local day = usage[key]
    local last = day and day[#day]

    -- The journal says this interval had not finished, and it was written just
    -- now: a skin refresh or a short Rainmeter restart.  Pick it back up
    -- instead of starting a new one and leaving a hole in the day.
    if last and last.unfinished and now - last.e <= RESUME_SECONDS then
        table.remove(day, #day)
        if #day == 0 then usage[key] = nil end
        usageRev = usageRev + 1
        beginInterval(last.s, last.locked, now)
        return
    end

    -- Fresh start.  If Windows says the user signed in a moment ago, the skin
    -- came up with the session and the session really began at sign-in.
    local signedIn = signInTime()
    if signedIn and signedIn <= now and now - signedIn <= SEED_SECONDS
                and signedIn >= midnight(now) then
        beginInterval(signedIn, locked, now)
    else
        beginInterval(now, locked)
    end
end

-- One second of evidence about the machine.
local function observe(now, locked)
    if live then
        if now - live.seen > GAP_SECONDS then
            endInterval(live.seen)        -- off, asleep, or Rainmeter was down
        elseif now >= live.ends then
            endInterval(live.ends - 1)    -- midnight: close the day out
        elseif live.locked ~= locked then
            endInterval(now)              -- locked or unlocked just now
        end
    end
    if live then
        live.seen = now
    else
        beginInterval(now, locked)
    end
end

--  ---- reading a day back ----------------------------------------------------

-- Which day the panel is describing: the selected date, or today.
local function panelDay(today)
    if selDay then return keyOf(selYear, selMonth, selDay), false end
    return dayKey(today), true
end

-- Closed intervals for a day, plus the open one clipped to now.  Momentary
-- unlocks are filtered out here rather than at the journal, so the record stays
-- raw on disk and MIN_UNLOCK can change without rewriting history.  The open
-- interval is never filtered: it is still growing, and a session that has just
-- started must show up immediately.
local function intervalsFor(key, now)
    local out = {}
    local day = usage[key]
    if day then
        for i = 1, #day do
            local span = day[i]
            if span.locked or (span.e - span.s) >= MIN_UNLOCK then
                out[#out + 1] = { s = span.s, e = span.e, locked = span.locked }
            end
        end
    end
    if live and live.key == key and now >= live.s then
        out[#out + 1] = { s = live.s, e = now, locked = live.locked, open = true }
    end
    return out
end

--  ============================================================================
--  Rendering: usage panel
--  ============================================================================

local function rectangle(x, y, w, h, colour)
    return string.format('Rectangle %d,%d,%d,%d | Fill Color %s | StrokeWidth 0',
                         x, y, w, h, colour)
end

-- A closed polygon from a flat list of coordinates, as Rainmeter path DATA:
-- "x,y | LineTo x,y | ... | ClosePath 1".  A Path shape cannot be written
-- inline -- the Shape line must say "Path <OptionName>" and the geometry must
-- live in that named option of the meter -- so the meter declares one option
-- per face pointing at our variable, keeps the colour on its Shape line (it
-- never changes), and we push only the geometry.  Whole pixels for the same
-- reason as the hand angles: no decimal separators.
local function polygon(...)
    local pts = { ... }
    local out = { string.format('%d,%d', pts[1], pts[2]) }
    for i = 3, #pts - 1, 2 do
        out[#out + 1] = string.format('LineTo %d,%d', pts[i], pts[i + 1])
    end
    out[#out + 1] = 'ClosePath 1'
    return table.concat(out, ' | ')
end

-- The graph covers one window of the day (07:00 to 21:00 by default) and shows
-- unlocked time only, one block per hour, drawn in the fake 3D of a Win98-era
-- charting control: an outlined front face, a lit top and a shaded side both
-- receding DEPTH px up and to the right.  Each block is four shapes layered
-- inside an ink silhouette, so the silhouette is also the 1px outline around
-- and between the faces, and nothing has to stroke a diagonal.
--
-- The vertical scale is fixed: a full-height block is sixty minutes, which is
-- all an hour can hold, so the gridlines in [MeterUseTrough] are honest for
-- every day.  A few unlocked minutes still get MIN_BLOCK px rather than being
-- rounded away -- the point of a small block is to exist.
local function renderBar(intervals, from, to, today, now)
    local hours = math.floor((to - from) / 3600 + 0.5)
    if hours < 1 then hours = 1 end
    if hours > MAX_HOURS then hours = MAX_HOURS end

    -- Seconds of unlocked time inside each hour of the window.  Locked time
    -- and anything outside the window are skipped, not clamped: a 06:00
    -- session clamped instead of skipped would grow a false block against the
    -- left edge.
    local seconds = {}
    for i = 1, hours do seconds[i] = 0 end
    for i = 1, #intervals do
        local span = intervals[i]
        if not span.locked and span.e > from and span.s < to then
            local s = math.max(span.s, from)
            local e = math.min(span.e, math.min(to, from + hours * 3600))
            while s < e do
                local slot = math.floor((s - from) / 3600) + 1
                local edge = math.min(e, from + slot * 3600)
                seconds[slot] = seconds[slot] + edge - s
                s = edge
            end
        end
    end

    -- Lay the blocks out across the field: BAR_GAP between front faces, and
    -- the last block's depth hanging into the final gap's worth of margin, so
    -- the row ends flush with the field.  A window wider than the default may
    -- need a narrower gap to keep the faces at least a few pixels wide; any
    -- pixels left over centre the row.
    local gap  = BAR_GAP
    local face = math.floor((bar.w - DEPTH - (hours - 1) * gap) / hours)
    while face < 6 and gap > 1 do
        gap  = gap - 1
        face = math.floor((bar.w - DEPTH - (hours - 1) * gap) / hours)
    end
    local row  = hours * face + (hours - 1) * gap + DEPTH
    local x0   = bar.x + math.floor((bar.w - row) / 2)
    local base = bar.y + bar.h                -- the floor the blocks stand on
    local plot = bar.h - DEPTH - HEADROOM     -- px a 60-minute block gets

    local front = variable('UseInk', '170,78,28')

    for i = 1, MAX_HOURS do
        local secs = seconds[i] or 0
        if i > hours or secs <= 0 then
            set('Bar' .. i .. 'Out',   EMPTY_PATH,  'Session')
            set('Bar' .. i .. 'Front', EMPTY_SHAPE, 'Session')
            set('Bar' .. i .. 'Side',  EMPTY_PATH,  'Session')
            set('Bar' .. i .. 'Top',   EMPTY_PATH,  'Session')
        else
            local h = math.floor(secs / 3600 * plot + 0.5)
            if h < MIN_BLOCK then h = MIN_BLOCK end
            if h > plot then h = plot end
            local l = x0 + (i - 1) * (face + gap)
            local r = l + face                -- where the side face begins

            -- Silhouette first: the hexagonal outline of the whole block.
            -- The paths are geometry only; their fills are pinned on the
            -- Shape lines in [MeterUseBar].
            set('Bar' .. i .. 'Out',
                polygon(l, base,  l, base - h,  l + DEPTH, base - h - DEPTH,
                        r + DEPTH, base - h - DEPTH,  r + DEPTH, base - DEPTH,
                        r, base), 'Session')

            -- The faces sit 1px inside it, so the ink shows through as the
            -- outline and as the seams between them.
            set('Bar' .. i .. 'Front',
                h >= 3 and rectangle(l + 1, base - h + 1, face - 2, h - 2, front)
                        or EMPTY_SHAPE, 'Session')
            set('Bar' .. i .. 'Side',
                polygon(r, base - h + 1,  r + DEPTH - 1, base - h - DEPTH + 2,
                        r + DEPTH - 1, base - DEPTH,  r, base - 1), 'Session')
            set('Bar' .. i .. 'Top',
                polygon(l + 2, base - h,  r - 1, base - h,
                        r + DEPTH - 2, base - h - DEPTH + 1,
                        l + DEPTH + 1, base - h - DEPTH + 1), 'Session')
        end
    end

    -- The cursor spans the blocks plus the ruler rows.  It travels across the
    -- current hour's face and hops the gap on the hour, so it always points
    -- into the block it is filling.  Outside the window there is nowhere
    -- honest to put it -- clamping to an edge would claim a time that is not
    -- now -- so it is hidden until the window comes round.
    if today and now >= from and now <= to then
        local slot = math.floor((now - from) / 3600)
        if slot > hours - 1 then slot = hours - 1 end
        local frac = (now - from - slot * 3600) / 3600
        local at   = x0 + slot * (face + gap) + math.floor(frac * face + 0.5)
        if at > x0 + row - 1 then at = x0 + row - 1 end
        set('BarNow', rectangle(at, bar.y, 1, bar.h + RULE_ROWS,
                                variable('Ink', '28,22,14')), 'Session')
    else
        set('BarNow', EMPTY_SHAPE, 'Session')
    end
end

-- Start of the latest run of unlocked time.  Adjacent unlocked intervals are
-- one session; locked time or a gap where the machine was away ends it.  Time
-- spent locked at the end of the day is skipped over, so stepping away does not
-- erase the session you just had.
local function latestSession(intervals)
    local i = #intervals
    while i >= 1 and intervals[i].locked do i = i - 1 end
    if i < 1 then return nil end

    local start = intervals[i].s
    for j = i - 1, 1, -1 do
        local span = intervals[j]
        if span.locked or start - span.e > 2 then break end
        start = span.s
    end
    return start
end

local function renderPanel(now)
    local key, today = panelDay(now)
    local intervals  = intervalsFor(key, now)
    local dayStart   = today and midnight(now)
                             or os.time{ year = selYear, month = selMonth,
                                         day = selDay, hour = 0, min = 0, sec = 0 }
    -- The window is built from wall-clock hours on that date rather than by
    -- adding seconds to midnight, which would slip an hour on the two days a
    -- year the clocks change.
    local d = os.date('*t', dayStart)
    local windowFrom = os.time{ year = d.year, month = d.month, day = d.day,
                                hour = bar.from, min = 0, sec = 0 }
    local windowTo   = os.time{ year = d.year, month = d.month, day = d.day,
                                hour = bar.to, min = 0, sec = 0 }

    set('UseLegend', today and 'Computer use - today'
                            or ('Computer use - ' .. longDate(dayStart)), 'Session')

    if #intervals == 0 then
        set('UseTotals', 'Nothing recorded for this day', 'Session')
    else
        local unlocked, locked = 0, 0
        for i = 1, #intervals do
            local span = intervals[i]
            if span.locked then locked   = locked   + span.e - span.s
            else                unlocked = unlocked + span.e - span.s end
        end

        local sessionStart = latestSession(intervals)
        local since
        if not sessionStart then
            since = 'Locked all day'
        elseif today then
            since = 'On since ' .. clock24(sessionStart)
        else
            since = 'Last session from ' .. clock24(sessionStart)
        end
        set('UseTotals', string.format('%s      %s unlocked      %s locked',
                                       since, duration(unlocked),
                                       duration(locked)), 'Session')
    end

    renderBar(intervals, windowFrom, windowTo, today, now)
end

--  ============================================================================
--  Rendering: calendar grid
--  ============================================================================

-- Fills W0..W6 (day names), D0..D41 (six weeks), C0..C41 (per-day ink), the
-- highlight position, and the month/year fields.  Drawn for viewYear/viewMonth
-- when browsing, otherwise for the real month.
local function renderCalendar(t)
    local year  = viewYear  or t.year
    local month = viewMonth or t.month
    local ws    = weekStart()

    local names = DAYNAMES[ws]
    for i = 1, 7 do set('W' .. (i - 1), names[i], 'Calendar') end

    local ink    = variable('Ink', '28,22,14')
    local useInk = variable('UseInk', '170,78,28')
    local column = firstColumn(year, month, ws)
    local length = daysInMonth(year, month)

    -- The highlight marks the selected date, which is today unless a click
    -- moved it.
    local sy = selYear  or t.year
    local sm = selMonth or t.month
    local sd = selDay   or t.day
    local showSelection = (year == sy and month == sm)

    for i = 0, 41 do
        local day   = i - column + 1
        local label = ''
        local ilk   = ink
        if day >= 1 and day <= length then
            if usage[keyOf(year, month, day)] then ilk = useInk end
            -- The selected day is left blank here on purpose: MeterSelText
            -- draws it in light ink on top of the highlight block, so nothing
            -- has to overdraw.
            if not (showSelection and day == sd) then label = tostring(day) end
        end
        set('D' .. i, label, 'Calendar')
        set('C' .. i, ilk, 'Calendar')
    end

    if showSelection then
        local index = (sd - 1) + column
        set('SelCol', tostring(index % 7), 'Calendar')
        set('SelRow', tostring(math.floor(index / 7)), 'Calendar')
        set('Today', tostring(sd), 'Calendar')
        set('SelHide', '0', 'Calendar')
    else
        set('SelHide', '1', 'Calendar')
        set('Today', '', 'Calendar')
    end

    set('MonthName', MONTHS[month], 'Calendar')
    set('YearText', tostring(year), 'Calendar')
end

-- Everything the grid depends on, in one comparable string.
local function calendarKey(t)
    return table.concat({ t.year, t.month, t.day, weekStart(),
                          viewYear or 0, viewMonth or 0,
                          selYear or 0, selMonth or 0, selDay or 0,
                          usageRev }, '-')
end

--  ============================================================================
--  Rendering: clock and time zone
--  ============================================================================

local function degrees(value)
    return tostring(math.floor(value + 0.5))
end

local function renderClock(t, onDatePage)
    if onDatePage then
        set('AngleHour', degrees((t.hour % 12) * 30 + t.min * 0.5))
        set('AngleMin', degrees(t.min * 6 + t.sec * 0.1))
        if variable('HideSeconds', '0') ~= '1' then
            set('AngleSec', degrees(t.sec * 6))
        end
    end

    if use24 then
        set('TimeText', string.format('%02d:%02d:%02d', t.hour, t.min, t.sec))
    else
        local hour = t.hour % 12
        if hour == 0 then hour = 12 end
        set('TimeText', string.format('%d:%02d:%02d %s', hour, t.min, t.sec,
                                      t.hour < 12 and 'AM' or 'PM'))
    end
end

local function renderZone(t, now)
    local utc = os.date('!*t', now)
    utc.isdst = false
    local offset = os.difftime(now, os.time(utc))
    local sign = offset >= 0 and '+' or '-'
    offset = math.abs(offset)

    set('TZName', os.date('%Z', now) or '', 'TimeZone')
    set('TZOffset', string.format('UTC %s%02d:%02d', sign,
                                  math.floor(offset / 3600),
                                  math.floor((offset % 3600) / 60)), 'TimeZone')
    set('TZDst', t.isdst and 'Summer time (DST) in effect' or 'Standard time',
        'TimeZone')
end

--  ============================================================================
--  Commands, called from the .ini with !CommandMeasure
--  ============================================================================

-- Redraw everything that depends on the date, the selection, or the log.
local function refresh()
    local now = os.time()
    local t   = os.date('*t', now)
    gridKey = calendarKey(t)
    renderCalendar(t)
    renderPanel(now)
    flush()
end

-- Move the browsed month by n months.  Landing back on the real month re-latches
-- to it, so the grid keeps following the date without a click.
function Shift(n)
    local t = os.date('*t')
    local year  = viewYear or t.year
    local month = (viewMonth or t.month) + n
    while month > 12 do month, year = month - 12, year + 1 end
    while month < 1  do month, year = month + 12, year - 1 end
    if year == t.year and month == t.month then
        viewYear, viewMonth = nil, nil
    else
        viewYear, viewMonth = year, month
    end
    refresh()
end

-- Back to today, and drop the selection.
function Home()
    viewYear, viewMonth = nil, nil
    selYear, selMonth, selDay = nil, nil, nil
    refresh()
end

-- Month combo clicked: open or close the dropdown.  Reading the live variable
-- instead of a formula inside the bang keeps this deterministic even when a tab
-- switch closed the list behind our back.
function ToggleMonthList()
    set('MLHide', variable('MLHide', '1') == '1' and '0' or '1')
    set('MLBarOn', '0')
    SKIN:Bang('!UpdateMeterGroup', 'MonthList')
    SKIN:Bang('!Redraw')
end

-- Month dropdown row m (1..12) clicked: browse that month of the shown year.
function SetMonth(m)
    set('MLHide', '1')
    set('MLBarOn', '0')
    local t = os.date('*t')
    local year = viewYear or t.year
    if year == t.year and m == t.month then
        viewYear, viewMonth = nil, nil
    else
        viewYear, viewMonth = year, m
    end
    SKIN:Bang('!UpdateMeterGroup', 'MonthList')
    refresh()
end

-- Calendar cell i (0..41) clicked: select that date, so the usage panel
-- describes it.  Clicking today's cell goes back to following today.
function Select(i)
    local t     = os.date('*t')
    local year  = viewYear  or t.year
    local month = viewMonth or t.month
    local day   = i - firstColumn(year, month, weekStart()) + 1
    if day < 1 or day > daysInMonth(year, month) then return end

    if year == t.year and month == t.month and day == t.day then
        selYear, selMonth, selDay = nil, nil, nil
    else
        selYear, selMonth, selDay = year, month, day
    end
    refresh()
end

-- Tab switch.  Every Hidden= option in the skin is a formula on #Page#, so this
-- also brings the meters of the page being shown up to date before repainting.
function SetPage(n)
    local page = (n == 1) and '1' or '0'
    set('Page', page)
    set('MLHide', '1')
    set('MLBarOn', '0')

    local now = os.time()
    local t   = os.date('*t', now)
    renderClock(t, page == '0')
    set('UTCTime', os.date('!%H:%M:%S', now))
    renderCalendar(t)
    renderPanel(now)
    renderZone(t, now)
    repaintAll()
end

-- The time spinner.  The 12/24 hour choice lives in this script and nowhere
-- else: the click changes it, the field is redrawn from it immediately, and
-- only then is the preference mirrored back into the .ini so it survives a
-- refresh.  Nothing here depends on that write succeeding.
function SetHourFormat(hours)
    use24 = (hours ~= 12)
    local value = use24 and '1' or '0'
    set('Use24Hour', value)
    renderClock(os.date('*t'), variable('Page', '0') == '0')
    SKIN:Bang('!UpdateMeter', 'MeterTimeText')
    SKIN:Bang('!Redraw')
    SKIN:Bang('!WriteKeyValue', 'Variables', 'Use24Hour', value)
end

function ToggleHourFormat()
    SetHourFormat(use24 and 12 or 24)
end

--  ============================================================================
--  Lifecycle
--  ============================================================================

function Initialize()
    pushed, dirty, handles = {}, {}, {}
    viewYear, viewMonth = nil, nil
    selYear, selMonth, selDay = nil, nil, nil
    live, ready = nil, false
    gridKey, nextMinute, nextFlush = '', 0, 0

    use24 = variable('Use24Hour', '1') == '1'
    bar = { x = number('BarX', 29), y = number('BarY', 293),
            w = number('BarW', 322), h = number('BarH', 40),
            from = number('GraphFrom', 7), to = number('GraphTo', 21) }
    -- The window must be whole hours inside one day: [MeterUseBar] provisions
    -- one slot per hour up to MAX_HOURS, and the ruler is drawn per hour.
    bar.from, bar.to = math.floor(bar.from), math.floor(bar.to)
    if bar.from < 0 or bar.to > 24 or bar.to <= bar.from then
        bar.from, bar.to = 0, 24
    end

    journalPath = openJournalPath()
    if not journalPath then
        print('Win98DateTime: no writable location for the usage log, ' ..
              'this session will not be remembered.')
    end
    loadJournal()
end

function Update()
    local now = os.time()
    local t   = os.date('*t', now)
    local page = variable('Page', '0')

    renderClock(t, page == '0')
    if page == '1' then set('UTCTime', os.date('!%H:%M:%S', now)) end

    -- Watch the machine.  One measure read and a handful of comparisons.
    local locked = lockScreenUp()
    if not ready then
        ready = true
        resumeSession(now, locked)
        nextFlush = now + FLUSH_SECONDS
    end
    local revision = usageRev
    observe(now, locked)
    local logChanged = usageRev ~= revision

    -- Minute work: the usage panel, the time zone details, and the flush of the
    -- open interval to disk.  A lock or unlock is not made to wait for it.
    if now >= nextMinute or logChanged then
        nextMinute = now - (now % 60) + 60
        renderPanel(now)
        renderZone(t, now)
    end
    if logChanged or now >= nextFlush then
        nextFlush = now + FLUSH_SECONDS
        saveJournal(now)
    end

    -- The grid changes at midnight, when WeekStart is edited, when the user
    -- browses or selects, and when a day gets its first usage record.
    local key = calendarKey(t)
    if key ~= gridKey then
        gridKey = key
        renderCalendar(t)
    end

    flush()
    return 0
end
