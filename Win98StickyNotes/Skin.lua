-- ============================================================================
--  Skin.lua  --  brain for the Win98 Sticky Note skin  (v3.0)
--
--  Same bargain as the Resource Meter: the .ini stays pure layout, everything
--  this script computes is pushed out as a Rainmeter variable, and the meters
--  that display it are grouped, so a change repaints the group and not the
--  skin.
--
--  Responsibilities
--    notes      read Notes.txt, wrap it to the note's column, and hand the
--               rows that fit to the twelve row meters
--    editing    a click on the text hands the sheet to the NoteEdit plugin,
--               and re-reads the file when it hands it back
--    checklist  a line that opens with [ ] or [x] is an item: it gets a
--               checkbox, and clicking it flips the marker and writes the
--               file back
--    scrolling  a Win98 scrollbar: the arrows step a row, the trough pages
--               towards the pointer, the wheel steps a row anywhere over
--               the skin
--    paper      six colours, picked from the flyout, remembered in the .ini
--    status     the two panels at the foot -- when the note was started, and
--               how many rows it runs to
--
--  How editing works, and why it works that way
--    Rainmeter has no keyboard of its own, and the plugin it ships for one,
--    InputText, is a prompt: it gives its text back on Enter and throws it
--    away on a click anywhere else, which is the opposite of a sticky note.
--    So the keyboard is NoteEdit, the plugin in @Plugin beside this script,
--    and it owns the whole of an edit: it reads Notes.txt into a real edit
--    box laid over the sheet, writes it back as you type, and writes it again
--    and closes when you click anywhere else.  Enter is a new line.
--
--    That leaves this script two jobs.  openSheet() says which line is at the
--    top of the view, so the box opens showing what the sheet was showing,
--    and Closed() re-reads the file once the box has gone.  In between it
--    keeps its hands off: the file is the plugin's until Closed().
--
--    What the box holds is the file itself, brackets and all, not a
--    prettied-up version of it.  That is deliberate: it shows the checkbox
--    syntax to anyone who wonders where the boxes come from, and it means
--    every edit the file format allows is reachable from the note -- type
--    "[ ] " in front of a line to make it an item, take it off to make it
--    prose again, change the indent, empty the line to delete it.
--
--  How the text is laid out
--    Rainmeter can wrap a string itself, but a string it wrapped is one meter
--    and one opaque block: there is no line left to hang a checkbox off, to
--    strike through, to scroll by, or to put an input box over.  So the script
--    wraps, and to wrap it has to know how wide a string is -- which Rainmeter
--    will not tell it.  Hence WIDTH below: advance widths for the skin's font,
--    added up a character at a time.  It is a table by eye and not a font
--    query, so SLACK is held back from every line and the row meters are
--    clipped to the column: a line it measures short ends in an ellipsis
--    instead of running into the scrollbar.
--
--  Characters
--    The note is UTF-8, and this script is not a Unicode script, so Rainmeter
--    would take any byte over 127 handed to it for the ANSI code page.  Two
--    things follow.  Measuring and wrapping step a character at a time rather
--    than a byte at a time, so a row is never cut through the middle of one.
--    And display() spells every character past ASCII as a Rainmeter character
--    reference, [\xHHHH], which is plain ASCII on the way in and the right
--    character on the way out, whatever the code page.
--
--    A note from before the skin was UTF-8 was written in Windows-1252, and is
--    not valid UTF-8.  Such a file is read as 1252 throughout -- the same way,
--    and with the same table, as the NoteEdit plugin reads it -- until its
--    first edit writes it back as UTF-8.
--
--  How a checkbox is drawn
--    Backwards, like the sibling's bars.  All twelve ticks are in the .ini,
--    always, in the twelve places a tick can appear; what this script pushes
--    is each one's colour -- ink for a done item, transparent for the rest.
--    The boxes get a meter apiece only because each has to be hideable.
--    None of them takes the mouse: one rectangle over the paper does that for
--    the lot, and Click() below works out from the x whether it landed in the
--    margin (flip the box) or on the text (edit the line).
--
--  Where a click lands, and the one thing to get right about it
--    $MOUSEX$ and $MOUSEY$ are relative to the METER carrying the action, not
--    to the skin.  [MeterPaper] does not sit at the skin's origin -- it sits
--    at (Pad + PaperX, Pad + PaperY) -- so a click arriving here is short by
--    the paper's own offset, and nothing in the numbers says so: they are
--    small positive pixel counts either way, and a wrong one still picks a
--    row, just not the row under the pointer.
--
--    So the conversion is done once, in fromPaper() and fromTrough(), out of
--    the same PaperX/PaperY/TroughY the .ini positions those two meters with.
--    Read from one place, they cannot drift apart.  And note what drops out
--    of the arithmetic: the meter's own X already contains Pad, so Pad
--    cancels, and this script never needs to know the skin has a margin at
--    all.  Every coordinate below is measured from the corner of the window,
--    which is where the layout figures in the .ini are measured from too.
--
--  Performance
--    Per tick: one small file read, and a string compare against the bytes
--    already parsed.  Nothing re-parses unless the file changed, and set()
--    silently drops writes that would not change anything, so a note nobody
--    is touching costs no bangs and no repaint at all.  Wrapping, rendering
--    and writing happen on an edit, a scroll or a click -- never on a timer.
--
--  Coordinates are emitted as whole pixels on purpose: that keeps
--  locale-dependent decimal separators out of the shape options.
-- ============================================================================

--  ---- tunables --------------------------------------------------------------
--  Not exposed as skin variables: changing them changes behaviour, not looks.

local FILE      = 'Notes.txt' -- what to read if the skin names nothing
local TAB       = 4           -- spaces a tab stands in for, before measuring
local SLACK     = 6           -- px held back from the column on every line,
                              -- to cover the width table being a pixel out.
                              -- Generous on purpose: a line measured short
                              -- gets an ellipsis, and an ellipsis on ordinary
                              -- text looks like a fault
local MIN_ROOM  = 24          -- px: a line indented past this much of the
                              -- column keeps its words and loses its indent
local STRIKE_DY = 6           -- px below a row's top where the line through
                              -- a done item sits
local THUMB_MIN = 11          -- px: the thumb never gets shorter than the
                              -- arrow buttons it runs between
local PAGE_KEEP = 1           -- rows a page-click leaves on screen, the way
                              -- Windows pages by a screenful less a line
local DATE      = '%d %b %Y'  -- how the first run stamps Created
local SWATCHES  = 2           -- how many papers the swatch button cycles
local GROUP     = 'Note'      -- the meter group holding everything that
                              -- changes as the note is read and scrolled
local PAPER     = 'Paper'     -- and the one holding everything that changes
                              -- when the paper colour does

--  ---- advance widths --------------------------------------------------------
--  Microsoft Sans Serif at 8 pt, in pixels, by eye.  Anything not listed is
--  DEFAULT wide, which is the width of a digit -- and so is every character
--  past ASCII, which is near enough for Latin and Cyrillic letters.  Keyed by
--  code point.  Scaled at load by FontSize / 8, so a bigger font still wraps
--  in the right place.

local DEFAULT = 6
local WIDTH   = {}

local function widths(px, chars)
    for i = 1, #chars do WIDTH[chars:byte(i)] = px end
end

widths(2,  "il|'!.,:;")
widths(3,  'fjrtI()[]{}/\\-`"')
widths(4,  '*^')
widths(5,  'acegsvxyzJ')
widths(6,  'bdhknopqu0123456789?+=<>~_FL$#')
widths(7,  'ABEKPSVXYZ')
widths(8,  'CDGHNOQRTUw&')
widths(9,  'm%')
widths(10, 'MW@')
WIDTH[32] = 4                 -- the space

--  ---- state -----------------------------------------------------------------

local pushed = {}             -- last value pushed for each skin variable
local dirty  = {}             -- meter groups waiting for a repaint

local note   = {}             -- the .ini's layout figures, read once at load
local ink    = {}             -- the text colours, read once at load
local path                    -- the note file, in full
local ini                     -- this skin's own .ini, for the two settings
                              -- that have to outlive a refresh
local filename = FILE         -- the note file on its own, for the status panel
local scale  = 1              -- WIDTH is 8 pt; this carries the other sizes

local source = false          -- the bytes last parsed.  false is "not read
                              -- yet", which nil -- "no such file" -- must not
                              -- be mistaken for
local eol    = '\n'           -- the line ending the file arrived with
local legacy = false          -- the file is Windows-1252, not UTF-8
local BOM    = '\239\187\191' -- the UTF-8 byte-order mark
local bom    = ''             -- and whether the file starts with one
local raw    = {}             -- the file's lines, exactly as they came in
local items  = {}             -- logical lines: text, checkbox state, and which
                              -- line of raw each came from
local rows   = {}             -- items wrapped into rows, all of them
local top    = 1              -- index in rows of the topmost visible row
local thumb  = { y = 0, h = 0 }

local papers  = {}            -- the two papers, read from the .ini
local colour  = 1             -- which one the note is on
local created = ''            -- the date in the left status panel

local editing = false         -- whether the sheet is open for editing
local unsaved = false         -- whether the plugin is holding typing it could
                              -- not write: see Closed()


-- Something the panel has to say instead of the position -- that a write was
-- refused, say.  Held for a few ticks so it can be read before the position
-- takes the panel back.
local notice, noticeFor = nil, 0
local function say(text)
    notice, noticeFor = text, 4
end

--  ============================================================================
--  Variables and repainting
--  ============================================================================

-- Push a value to the skin, but only if it actually changed.  Passing a group
-- marks that group for repainting.
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

local function number(name, default)
    return tonumber(SKIN:GetVariable(name, '')) or default
end

--  ============================================================================
--  Shapes
--  ============================================================================

local EMPTY_SHAPE = 'Rectangle 0,0,1,1 | Fill Color 0,0,0,0 | StrokeWidth 0'
local CLEAR       = '0,0,0,0'

local function rectangle(x, y, w, h, colr)
    return string.format('Rectangle %d,%d,%d,%d | Fill Color %s | StrokeWidth 0',
                         x, y, w, h, colr)
end

-- The thumb's two numbers go into shape options the .ini does arithmetic on,
-- so they leave here as whole pixels and nothing else.
local function whole(n)
    return string.format('%d', n)
end

--  ============================================================================
--  Text
--  ============================================================================

local function expand(s)
    return (s:gsub('\t', string.rep(' ', TAB)))
end

-- Windows-1252's 0x80..0x9F, the one block where it is not Latin-1.  The
-- five bytes 1252 leaves undefined are absent, and so stand for themselves.
local CP1252 = {
    [0x80] = 0x20AC, [0x82] = 0x201A, [0x83] = 0x0192, [0x84] = 0x201E,
    [0x85] = 0x2026, [0x86] = 0x2020, [0x87] = 0x2021, [0x88] = 0x02C6,
    [0x89] = 0x2030, [0x8A] = 0x0160, [0x8B] = 0x2039, [0x8C] = 0x0152,
    [0x8E] = 0x017D, [0x91] = 0x2018, [0x92] = 0x2019, [0x93] = 0x201C,
    [0x94] = 0x201D, [0x95] = 0x2022, [0x96] = 0x2013, [0x97] = 0x2014,
    [0x98] = 0x02DC, [0x99] = 0x2122, [0x9A] = 0x0161, [0x9B] = 0x203A,
    [0x9C] = 0x0153, [0x9E] = 0x017E, [0x9F] = 0x0178,
}

-- The UTF-8 character that starts at byte i of s: its code point and the
-- byte after it, or nil if what starts there is not UTF-8.
local function utf8At(s, i)
    local c = s:byte(i)
    if c < 0x80 then return c, i + 1 end
    local n, cp
    if     c >= 0xC2 and c <= 0xDF then n, cp = 1, c - 0xC0
    elseif c >= 0xE0 and c <= 0xEF then n, cp = 2, c - 0xE0
    elseif c >= 0xF0 and c <= 0xF4 then n, cp = 3, c - 0xF0
    else return nil end
    for k = i + 1, i + n do
        local b = s:byte(k)
        if not b or b < 0x80 or b > 0xBF then return nil end
        cp = cp * 64 + (b - 0x80)
    end
    return cp, i + n + 1
end

local function isUtf8(s)
    if not s:find('[\128-\255]') then return true end
    local i = 1
    while i <= #s do
        local _, after = utf8At(s, i)
        if not after then return false end
        i = after
    end
    return true
end

-- Every character of s, as (first byte, last byte, code point).  The file was
-- checked as a whole when it was parsed, so a stray invalid byte in a UTF-8
-- note can only be damage, and reads as the replacement character.
local function chars(s)
    local i = 1
    return function()
        if i > #s then return nil end
        local from, cp, after = i, nil, nil
        if legacy then
            cp, after = s:byte(i), i + 1
            cp = CP1252[cp] or cp
        else
            cp, after = utf8At(s, i)
            if not cp then cp, after = 0xFFFD, i + 1 end
        end
        i = after
        return from, after - 1, cp
    end
end

local function width(s)
    local total = 0
    for _, _, cp in chars(s) do
        total = total + (WIDTH[cp] or DEFAULT)
    end
    return math.floor(total * scale + 0.5)
end

-- Where to cut s so that its head fits in room px: the last byte of the last
-- whole character that fits, and never less than the first character.
local function fit(s, room)
    local total, cut = 0, 0
    for _, last, cp in chars(s) do
        total = total + (WIDTH[cp] or DEFAULT)
        if cut > 0 and math.floor(total * scale + 0.5) > room then break end
        cut = last
    end
    return cut
end

-- A row's text as Rainmeter is to be handed it.  Past ASCII, every character
-- becomes a reference, [\xHHHH] -- see Characters, above.  So do [ and #,
-- which are ASCII but not safe: a row reading "[Name]" would be taken for a
-- section variable and "#Name#" for a skin variable.  A reference is resolved
-- after both, so what it stands for is never read again.
local function display(s)
    if not s:find('[%[#\128-\255]') then return s end
    local out = {}
    for from, last, cp in chars(s) do
        if cp < 0x80 and cp ~= 0x5B and cp ~= 0x23 then
            out[#out + 1] = s:sub(from, last)
        else
            out[#out + 1] = string.format('[\\x%04X]', cp)
        end
    end
    return table.concat(out)
end

-- The file's lines, split but not touched otherwise: an edit rewrites one of
-- these and joins them up again, so they have to survive the trip.  A file
-- that ends in a newline ends here in an empty line, which is what puts the
-- newline back.
local function lines(text)
    local out, from = {}, 1
    while true do
        local s, e = text:find('\r?\n', from)
        if not s then
            out[#out + 1] = text:sub(from)
            return out
        end
        out[#out + 1] = text:sub(from, s - 1)
        from = e + 1
    end
end

-- One logical line, greedily filled into as many rows as it takes.  Runs of
-- spaces inside it close up -- that is what wrapping is -- but its indent is
-- kept and repeated on every row, so a line that hangs off another still
-- looks like it does.  A word too wide for the column on its own is cut
-- rather than allowed to overhang.
local function wrap(text, indent, room)
    local out  = {}
    local hang = width(indent)
    if room - hang < MIN_ROOM then indent, hang = '', 0 end
    room = room - hang

    local function emit(s)
        out[#out + 1] = indent .. s
    end

    local line
    for word in text:gmatch('%S+') do
        if not line then
            line = word
        elseif width(line .. ' ' .. word) <= room then
            line = line .. ' ' .. word
        elseif width(word) > room then
            line = line .. ' ' .. word  -- no row will hold it whole, so let the
                                        -- cut below fill this one out rather
                                        -- than leave it half empty
        else
            emit(line)
            line = word
        end

        while width(line) > room do
            local cut = fit(line, room)
            if cut >= #line then break end  -- one character wider than the
                                            -- column: it has the row to itself
            emit(line:sub(1, cut))
            line = line:sub(cut + 1)
        end
        if line == '' then line = nil end
    end
    if line then emit(line) end

    if #out == 0 then out[1] = '' end   -- a blank line still owns a row
    return out
end

--  ============================================================================
--  The note file
--  ============================================================================

-- Bytes in, logical lines out.  A leading [ ] or [x] makes an item, and the
-- position of the byte between the brackets is kept, so flipping it later is
-- one substitution and no pattern matching.  Nothing in the file is treated
-- as a heading: the window is called Notes, and a line beginning # is a row
-- like any other.
local function parse(text)
    raw, items, bom, legacy = {}, {}, '', false

    if text == nil then                 -- no file: say so on the paper.  These
        items[1] = { text = filename .. ' is missing.', indent = '' }
        items[2] = { text = 'Click a line to start one.', indent = '' }
        return                          -- two items with no .line, so an edit
    end                                 -- on either appends instead

    eol    = text:find('\r\n', 1, true) and '\r\n' or '\n'
    legacy = not isUtf8(text)
    -- A UTF-8 byte-order mark is not part of the first line: kept in bom so
    -- rewrite() can put it back, and out of raw so "[ ]" is still found at
    -- the start of the line.
    bom    = (text:sub(1, 3) == BOM) and BOM or ''
    raw    = lines(text:sub(#bom + 1))

    for i = 1, #raw do
        local line = raw[i]
        local _, stop, lead, flag = line:find('^([ \t]*)%[([ xX])%]')
        if stop then
            items[#items + 1] = {
                text   = expand(line:sub(stop + 1)):match('^%s*(.-)%s*$'),
                indent = '',            -- the box sits out in the margin, so
                                        -- an item does not indent its own text
                todo   = true,
                done   = (flag ~= ' '),
                line   = i,
                mark   = #lead + 2,     -- the byte between the brackets
            }
        else
            local body = expand(line)
            local pre, rest = body:match('^( *)(.-) *$')
            items[#items + 1] = { text = rest, indent = pre, line = i }
        end
    end

    -- blank lines at the end of a file are not rows anyone wants to scroll to
    while #items > 0 and not items[#items].todo and items[#items].text == '' do
        items[#items] = nil
    end

end

-- Every item, wrapped, in one flat list: the row meters show a window onto it.
-- An item that wraps owns two or three rows; head marks the first of them,
-- which is the only one that gets a checkbox and the only one that can be
-- clicked to flip it.
local function layout()
    rows = {}
    for i = 1, #items do
        local item   = items[i]
        local pieces = wrap(item.text, item.indent, note.textW - SLACK)
        for j = 1, #pieces do
            rows[#rows + 1] = { text = pieces[j], item = i, head = (j == 1) }
        end
    end
end

-- How many words the note runs to.  Counted off the items rather than off the
-- file, which is what makes a checkbox marker not a word: parse() has already
-- taken [ ] and [x] off the front of an item, so what is counted here is only
-- what somebody actually wrote.  A word is a run of non-space, which is what a
-- word count is everywhere else.
local function words()
    local n = 0
    for i = 1, #items do
        for _ in items[i].text:gmatch('%S+') do n = n + 1 end
    end
    return n
end

-- Read the file, and re-parse it only if it is not the one already parsed.
local function reload()
    local text
    local f = io.open(path, 'rb')
    if f then
        text = f:read('*a')
        f:close()
    end
    if text == source then return false end

    source = text
    parse(text)
    layout()
    return true
end

-- Write raw back out and re-derive everything from what was written.  Going
-- back through parse() rather than patching items in place costs a re-wrap
-- per edit -- microseconds on a sticky note -- and buys the guarantee that
-- what is on screen is what is in the file, with no second copy of the rules
-- for keeping the two in step.
local function rewrite()
    -- One newline at the end and no more.  It goes on the text rather than
    -- into raw, so that a write which fails leaves raw exactly as the caller
    -- left it -- the caller's rollback is then a plain assignment, with no
    -- stray blank line to undo as well.  parse() puts the element back when
    -- the write succeeds, which is what keeps the terminator from doubling.
    local text = bom .. table.concat(raw, eol)
    if raw[#raw] ~= '' then text = text .. eol end

    local f = io.open(path, 'wb')
    if not f then return false end
    f:write(text)
    f:close()
    source = text        -- so the next tick does not read our own write as an
    parse(text)          -- edit and throw the wrapping away for nothing
    layout()
    return true
end

--  ============================================================================
--  Paper colour
--  ============================================================================

-- The sheet, its ruled lines, and the ring round the chosen swatch.  All in
-- the Paper group, which is only ever updated when one of them moves: the
-- field and the rules are big static meters and there is no reason to re-read
-- them while the note is merely being scrolled.
local function paint()
    set('NoteBg', papers[colour] or papers[1], PAPER)
end

--  ============================================================================
--  Rendering
--  ============================================================================

-- The item whose checkbox is drawn against this row, or nil if the row shows
-- no box at all.
--
-- Two things ask this and they have to give the same answer: render(), which
-- decides where a box appears, and the click that flips one.  When they were
-- allowed to decide separately the click was the more generous of the two --
-- it would flip an item from any of its rows, including the wrapped ones with
-- nothing but blank margin beside them, so a click on empty paper ticked
-- something a line or two up.  Asked here, there is only one rule and only one
-- place to change it.
local function boxOn(row)
    if not (row and row.head) then return nil end
    local item = items[row.item]
    if not (item and item.todo) then return nil end
    return item
end

-- The window of rows, the scrollbar that says where it is, and the row count.
-- Called after anything that could have moved something: an edit, a scroll,
-- a click.
--
-- The scrollable extent is one row longer than the note, always.  That last
-- blank row is not padding -- it is the line you click to add to the end, so
-- it has to be reachable, and a document you can type into does always have
-- one more line in it than it has lines.
local function render()
    local shown  = note.rows
    local extent = #rows + 1
    local last   = extent - shown + 1
    if last < 1   then last = 1 end
    if top > last then top = last end
    if top < 1    then top = 1 end

    for slot = 1, shown do
        local n    = tostring(slot)
        local row  = rows[top + slot - 1]
        local item = row and items[row.item]
        local box  = not editing and boxOn(row) or nil
        local done = (item and item.done) or false
        local text = row and row.text or ''
        local y    = note.firstY + (slot - 1) * note.pitch

        -- The margin goes blank for the duration of an edit.  The box covers
        -- the text column and nothing else, so a checkbox left in the margin
        -- would sit there pointing at a row that is no longer under it: the
        -- box holds the file's own lines, which do not line up with the
        -- wrapped rows the boxes were placed against.  Guarded here rather
        -- than cleared once when the box opens, because Update() comes round
        -- every other tick and would otherwise put them all back mid-edit.
        set('Row'    .. n, display(text), GROUP)
        set('RowInk' .. n, done and ink.faded or ink.text, GROUP)
        set('Box'    .. n, box and '0' or '1', GROUP)
        set('Tick'   .. n, (box and box.done) and ink.text or CLEAR, GROUP)

        if done and text ~= '' then
            local w = width(text)
            if w > note.textW then w = note.textW end
            set('Strike' .. n,
                rectangle(note.textX, y + STRIKE_DY, w, 1, ink.faded), GROUP)
        else
            set('Strike' .. n, EMPTY_SHAPE, GROUP)
        end
    end

    -- The thumb is as much of the trough as is on screen, where it is.  With
    -- nothing to scroll it fills the trough and both arrows go grey, which is
    -- how a Win98 scrollbar says there is nowhere to go.
    thumb.y, thumb.h = note.troughY, note.troughH
    if extent > shown then
        thumb.h = math.floor(note.troughH * shown / extent + 0.5)
        if thumb.h < THUMB_MIN then thumb.h = THUMB_MIN end
        thumb.y = note.troughY
                + math.floor((note.troughH - thumb.h) * (top - 1)
                             / (extent - shown) + 0.5)
    end
    set('ThumbY', whole(thumb.y), GROUP)
    set('ThumbH', whole(thumb.h), GROUP)
    set('UpInk',   (top > 1)    and ink.text or ink.faded, GROUP)
    set('DownInk', (top < last) and ink.text or ink.faded, GROUP)

    -- The right panel counts the note's words, and keeps counting while the
    -- sheet is open: the plugin writes the file as it is typed, and Update()
    -- re-reads it, so the count follows the typing a tick or two behind.
    -- Something that went wrong interrupts it, long enough to be read.
    if source == nil then
        set('Words', 'no file', GROUP)
    elseif noticeFor > 0 then
        noticeFor = noticeFor - 1
        set('Words', notice, GROUP)
    else
        local n = words()
        if n == 0 then
            set('Words', 'empty', GROUP)
        elseif n == 1 then
            set('Words', '1 word', GROUP)
        else
            set('Words', string.format('%d words', n), GROUP)
        end
    end
end

--  ============================================================================
--  The edit box
--  ============================================================================

local EDITOR = 'MeasureInput'

-- What the plugin says about the box: open, saved, unchanged, write-error,
-- read-error or no-window.  Nothing at all if the plugin is not there.
local function editorSays()
    local box = SKIN:GetMeasure(EDITOR)
    return box and box:GetStringValue() or ''
end

-- Hand the whole sheet to one edit box, sized to the paper.  The caret, the
-- selection, the deleting and the copying are all the Windows edit control's
-- own, and the caret lands where the click did.
--
-- The box is told which line of the file is at the top of the view, and how
-- many wrapped rows down into it, so it opens scrolled to what the sheet was
-- showing rather than to the top of the note.  Everything else about it --
-- where it sits, its size, its colours, the file -- is written once in the
-- .ini, where they are the sheet's own figures: SolidColor there is #NoteBg#,
-- the variable the paper is painted with, and the plugin reads it as it opens.
local function openSheet()
    editing = true
    render()        -- clears the margin: see render()
    flush()

    local line, down = 1, 0
    local row = rows[top]
    if row then
        line = items[row.item].line or 1
        while down < top - 1 and rows[top - down - 1].item == row.item do
            down = down + 1
        end
    end
    SKIN:Bang('!CommandMeasure', EDITOR, string.format('Open %d %d', line, down))

    -- Open is answered before the bang returns: either the box is up, or the
    -- plugin has already called Closed() to say why not.  Neither having
    -- happened means there is no plugin to answer -- NoteEdit.dll is not
    -- installed -- and the sheet has to come back now, or every checkbox
    -- stays hidden and every click waits on a Closed() that never comes.
    if editing and editorSays() ~= 'open' then
        editing = false
        say('no editor')
        render()
        flush()
    end
end

-- Finish the edit from this side: the same as a click outside the box.  For
-- a click on the skin itself, in case Windows did not already count it as
-- one -- the plugin answers with Closed(), which is what puts things back.
local function leave()
    SKIN:Bang('!CommandMeasure', EDITOR, 'Close')
end

--  ============================================================================
--  Rainmeter entry points
--  ============================================================================

function Initialize()
    -- All in frame coordinates -- measured from the corner of the window, the
    -- same origin the .ini's own figures are measured from.  Pad is not here
    -- and does not belong here: see fromPaper() for why it cancels.
    note = {
        rows    = number('Rows', 12),
        pitch   = number('RowPitch', 13),
        firstY  = number('Row1Y', 30),
        textX   = number('TextX', 22),
        textW   = number('TextW', 146),
        paperX  = number('PaperX', 8),      -- the corner [MeterPaper] reports
        paperY  = number('PaperY', 29),     -- its clicks from
        troughY = number('TroughY', 40),    -- and [MeterTrough]'s, which is
        troughH = number('TroughH', 136),   -- also the top of the trough
    }
    if note.rows < 1 then note.rows = 1 end

    scale     = number('FontSize', 8) / 8
    ink.text  = SKIN:GetVariable('Ink', '28,22,14')
    ink.faded = SKIN:GetVariable('Shadow', '116,105,88')
    filename  = SKIN:GetVariable('NoteFile', FILE)

    local here = SKIN:GetVariable('CURRENTPATH', '')
    path = here .. filename
    ini  = here .. SKIN:GetVariable('CURRENTFILE', 'Win98Notes.ini')

    -- The papers live in the .ini and nowhere else, so the swatch and the
    -- sheet it paints cannot disagree.
    for i = 1, SWATCHES do
        papers[i] = SKIN:GetVariable('Paper' .. i, '250,238,190')
    end
    colour = number('Colour', 1)
    if colour < 1 or colour > SWATCHES then colour = 1 end
    paint()

    -- First run stamps the note's birthday into the .ini and never touches it
    -- again; any date already there is shown as it stands.
    created = SKIN:GetVariable('Created', '')
    if created:match('^%s*$') then
        created = os.date(DATE):gsub('^0', '')
        SKIN:Bang('!WriteKeyValue', 'Variables', 'Created', created, ini)
    end
    set('Created', created, GROUP)
end

function Update()
    reload()
    render()
    flush()
    return ''
end

--  ---- called from the .ini --------------------------------------------------

-- While the sheet is open, the file is the plugin's.  A click on the skin
-- normally finishes the edit before it gets here -- clicking the skin takes
-- the focus from the box, and the box saves and closes on losing it -- but a
-- click that arrives with the sheet still open must not act on it: a toggle
-- would rewrite the file under text the box is about to write back, and a
-- scroll would move rows nobody can see.  So it finishes the edit instead,
-- and the next click does what this one would have.
local function busy()
    return editing
end

-- $MOUSEX$ and $MOUSEY$ arrive relative to the meter that took the click, so
-- a point from [MeterPaper] is short by the paper's own corner and a y from
-- [MeterTrough] is short by the trough's.  These two put them back, out of
-- the same variables the .ini positions those meters with.
--
-- Pad is deliberately absent.  The meter's X is (Pad + PaperX) and the click
-- comes in relative to that, so the margin round the window has already been
-- subtracted twice over by the time the number gets here -- once by
-- Rainmeter, once by the meter's own placement -- and adding PaperX back is
-- the whole of the conversion.  Nothing in this script has to know Pad
-- exists, and it should stay that way: the version that did know reached for
-- Pad here instead of PaperX, and every checkbox in the note answered three
-- rows above the pointer.
local function fromPaper(x, y)
    return (tonumber(x) or 0) + note.paperX,
           (tonumber(y) or 0) + note.paperY
end

local function fromTrough(y)
    return (tonumber(y) or 0) + note.troughY
end

-- The arrows and the wheel: a row at a time.
function Scroll(by)
    if busy() then return '' end
    -- Clamp here rather than in render(), so that a wheel already at the end
    -- of the note costs nothing at all.  A flick sends a burst of these, and
    -- each one that gets through is sixty-odd bangs and a repaint.
    local was    = top
    local extent = #rows + 1
    local last   = extent - note.rows + 1
    if last < 1 then last = 1 end

    top = top + (tonumber(by) or 0)
    if top > last then top = last end
    if top < 1    then top = 1 end
    if top == was then return '' end

    render()
    flush()
    return ''
end

-- A click in the trough: page towards it, or sit still if it landed on the
-- thumb.  thumb.y is a frame coordinate, so the pointer has to become one
-- before the two can be compared -- which is what went wrong here as well as
-- on the paper, and with the same result each time: every click read as being
-- above the thumb, so the trough would only ever page upwards.
function Page(y)
    if busy() then leave() return '' end
    y = fromTrough(y)
    if y >= thumb.y and y < thumb.y + thumb.h then return '' end

    local page = note.rows - PAGE_KEEP
    if page < 1 then page = 1 end
    return Scroll(y < thumb.y and -page or page)
end

-- Flip the checkbox on one of the twelve visible rows.  The file is where the
-- state lives, so it is written first: if the write fails nothing moves and
-- the panel says why until the next tick puts it back.
--
-- Rows with no box on them are not an error and not a miss -- prose has a
-- margin too, and so does the second row of an item that wrapped.  A click
-- there is simply a click on blank paper, and this says so by doing nothing.
local function toggle(slot)
    local item = boxOn(rows[top + slot - 1])
    if not item then return end

    local line   = item.line
    local before = raw[line]
    raw[line] = before:sub(1, item.mark - 1)
             .. (item.done and ' ' or 'x')
             .. before:sub(item.mark + 1)

    if not rewrite() then
        raw[line] = before
        say('read-only')
    end
end

-- Every click on the paper arrives here, as a point relative to the paper.
-- Left of the text column is the margin, where the checkboxes are: that flips
-- the row's checkbox.  Anywhere else on the paper opens the note for editing.
function Click(x, y)
    if busy() then leave() return '' end
    local fx, fy = fromPaper(x, y)

    -- Which of the twelve rows the point fell in.  The paper stands a pixel
    -- proud of the rows at the top and at the foot, so this can come out as 0
    -- or 13: those two slivers belong to the row they touch, which is what
    -- the clamp is for and all it is for.  It is not there to make a wild
    -- answer safe -- it did that once, and quietly.
    local slot = math.floor((fy - note.firstY) / note.pitch) + 1
    if slot < 1         then slot = 1 end
    if slot > note.rows then slot = note.rows end

    if fx < note.textX then
        if unsaved then say('not saved') else toggle(slot) end
        render()
        flush()
        return ''
    end

    openSheet()
    return ''
end

-- What the panel says after a box that did not end well.  Each says what
-- actually happened: a note that could not be read was never typed in, so it
-- is not "not saved".
local TROUBLE = {
    ['write-error'] = 'not saved',
    ['read-error']  = 'cannot read',
    ['no-window']   = 'no editor',
}

-- The box has closed -- a click somewhere else, Escape, the skin being
-- clicked -- and the plugin has already written the file.  Or it never
-- opened, and the plugin is saying why.  Either way: read the file back, put
-- the checkboxes back in the margin, and say so if something went wrong.
--
-- A refused write is the one that lingers.  The plugin keeps the typing it
-- could not save and shows it again the next time the sheet opens -- so it is
-- not lost, but it is not on disk either, and a checkbox ticked in the
-- meantime would be written to a file that the typing then overwrites.  So
-- the checkboxes wait (see Click) until a close says the typing is saved.
function Closed()
    editing = false
    local status = editorSays()
    if status == 'write-error' then
        unsaved = true
    elseif status == 'saved' or status == 'unchanged' then
        unsaved = false
    end
    if TROUBLE[status] then say(TROUBLE[status]) end
    reload()
    render()
    flush()
    return ''
end

-- The swatch button.  Two papers and one button, so a click swaps them:
-- there is no flyout to open, nothing to aim at and nothing to miss, which
-- is the only way a colour change is reliable every single time.  The choice
-- is written back into the skin's own .ini so it survives a refresh.
function NextPaper()
    if busy() then leave() return '' end
    colour = (colour % SWATCHES) + 1
    paint()
    SKIN:Bang('!WriteKeyValue', 'Variables', 'Colour', tostring(colour), ini)
    flush()
    return ''
end
