-- ============================================================================
--  Skin.lua  --  brain for the Win98 Resource Meter skin  (v1.2)
--
--  The .ini stays pure layout.  Everything this script computes is pushed out
--  as a Rainmeter variable, and the meters that display it are grouped, so a
--  change repaints only the group it belongs to.
--
--  Responsibilities
--    gauges     CPU and physical-memory usage, each as a Win98 progress bar:
--               a run of blocks in a sunken trough, and an info line -- the
--               percentage, plus used-of-total gigabytes where the measure
--               knows its ceiling
--
--  How a bar is drawn
--    Backwards.  Every block -- ink outline and fill -- is static, in the
--    .ini: the bar is painted full.  This script pushes one field-coloured
--    rectangle per bar that covers the tail the measure has not earned, so
--    a bar is always whole outlined blocks, for the price of one moving
--    shape.
--
--  Performance
--    Per second: two relative measure reads.  The cover moves in whole
--    blocks and the label in whole percents, and set() silently drops
--    writes that would not change anything, so a steady load costs no
--    bangs and no repaint at all.
--
--  Coordinates are emitted as whole pixels on purpose: that keeps
--  locale-dependent decimal separators out of the shape options.
-- ============================================================================

--  ---- tunables --------------------------------------------------------------
--  Not exposed as skin variables: changing them changes behaviour, not looks.

local BLOCK  = 8             -- px: width of one block of a bar
local GAP    = 2             -- px of field between neighbouring blocks
local MARGIN = 2             -- px of field kept visible between the block run
                             -- and the trough's bezel, each side.  The static
                             -- blocks in the .ini are laid out from the same
                             -- three figures, so change them together

--  ---- state -----------------------------------------------------------------

local pushed  = {}           -- last value pushed for each skin variable
local dirty   = {}           -- meter groups waiting for a repaint
local handles = {}           -- cached measure objects

local bars    = {}           -- layout of the two bars, read once at load

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

-- Measure objects are cached: Update() reads both gauges every second.
local function measure(name)
    local m = handles[name]
    if m == nil then
        m = SKIN:GetMeasure(name) or false
        handles[name] = m
    end
    return m or nil
end

--  ============================================================================
--  Rendering: gauges
--  ============================================================================

local EMPTY_SHAPE = 'Rectangle 0,0,1,1 | Fill Color 0,0,0,0 | StrokeWidth 0'

local function rectangle(x, y, w, h, colour)
    return string.format('Rectangle %d,%d,%d,%d | Fill Color %s | StrokeWidth 0',
                         x, y, w, h, colour)
end

-- One bar: its measure's share of the whole, as blocks and as an info line.
-- The blocks are already painted, all of them; what this pushes is the cover
-- that erases the unearned tail, from the gap after the last kept block to
-- the far edge of the field.
local function renderBar(bar, colour)
    local m = measure(bar.measure)
    local rel = m and m:GetRelativeValue() or 0
    if rel < 0 then rel = 0 end
    if rel > 1 then rel = 1 end

    local blocks = math.floor(rel * bar.slots + 0.5)
    if blocks < bar.slots then
        local from = bar.x - MARGIN                     -- nothing kept: cover
        if blocks > 0 then                              -- the margin too
            from = bar.x + blocks * (BLOCK + GAP) - GAP
        end
        local to = bar.x + bar.w + MARGIN               -- first px past the field
        set(bar.name .. 'Cover',
            rectangle(from, bar.y, to - from, bar.h, colour), 'Gauges')
    else
        set(bar.name .. 'Cover', EMPTY_SHAPE, 'Gauges')
    end

    local info = string.format('%d %%', math.floor(rel * 100 + 0.5))
    if bar.bytes then
        -- the memory measure knows its ceiling; say it in gigabytes, in the
        -- wide-spaced manner of the sibling's totals line
        local total = m and m:GetMaxValue() or 0
        if total > 0 then
            local gb = 1024 * 1024 * 1024
            info = string.format('%s      %.1f of %.1f GB',
                                 info, m:GetValue() / gb, total / gb)
        end
    end
    set(bar.name .. 'Info', info, 'Gauges')
end

--  ============================================================================
--  Rainmeter entry points
--  ============================================================================

function Initialize()
    local x = number('BarX', 31)
    local w = number('BarW', 318)
    local h = number('BarH', 16)
    -- how many whole blocks the bar's width holds; the trailing block needs
    -- no gap after it, so one gap's width is given back before dividing
    local slots = math.floor((w + GAP) / (BLOCK + GAP))
    if slots < 1 then slots = 1 end

    bars = {
        { name = 'Cpu', measure = 'MeasureCpu', x = x, w = w, h = h,
          slots = slots, y = number('CpuY', 58) },
        { name = 'Ram', measure = 'MeasureRam', x = x, w = w, h = h,
          slots = slots, y = number('RamY', 124), bytes = true },
    }
end

function Update()
    local colour = SKIN:GetVariable('FieldBg', '247,243,233')
    for _, bar in ipairs(bars) do
        renderBar(bar, colour)
    end
    flush()
    return ''
end
