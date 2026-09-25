-- ============================================================================
--  Skin.lua  --  brain for the Win98 Weather skin  (v1.2)
--
--  The .ini stays pure layout.  Everything this script computes is pushed out
--  as a Rainmeter variable, and the meters that display it are grouped, so a
--  change repaints only the group it belongs to.
--
--  Responsibilities
--    location   IP geolocation, or ManualLat / ManualLon if those are set:
--               copy the coordinates into #Lat#/#Lon# and enable
--               MeasureWeatherRaw so it downloads from the right place. After
--               that Rainmeter's own UpdateRate on that measure keeps it
--               refreshing itself, and this script only steps in if the
--               coordinates change or nothing arrived at all.
--    panel      current temperature, condition label, location, today's
--               high/low, and the condition icon
--
--  The icon
--    One 32x32 PNG per condition in the Icons folder beside this script, from
--    a Win98-era icon set.  The script only picks the file and writes its
--    path into #IconFile#; [MeterIconWeather] does the drawing.
--
--  Performance
--    set() silently drops writes that would not change anything, so once the
--    panel is showing a steady forecast an Update() costs a handful of measure
--    reads, no bangs and no repaint at all.
-- ============================================================================

local pushed       = {}    -- last value pushed for each skin variable
local dirty        = {}    -- meter groups waiting for a repaint
local handles      = {}    -- cached measure objects
local coordsPushed = nil    -- the coordinates the forecast measure is using
local kickAt       = nil    -- tick at which to force a download, if needed
local kickForce    = false
local ticks        = 0

-- settings, read once in Initialize(): none of them can change without a
-- refresh, and a refresh runs Initialize() again
local manualLat, manualLon, manualLabel, degrees, iconDir

--  ============================================================================
--  Variables and repainting
--  ============================================================================

local function set(name, value, group)
    if pushed[name] == value then return false end
    pushed[name] = value
    SKIN:Bang('!SetVariable', name, value)
    if group then dirty[group] = true end
    return true
end

local function flush()
    local repaint = false
    for group in pairs(dirty) do
        SKIN:Bang('!UpdateMeterGroup', group)
        dirty[group] = nil
        repaint = true
    end
    if repaint then SKIN:Bang('!Redraw') end
end

local function measure(name)
    local m = handles[name]
    if m == nil then
        m = SKIN:GetMeasure(name) or false
        handles[name] = m
    end
    return m or nil
end

local function measureString(name)
    local m = measure(name)
    return m and m:GetStringValue() or ''
end

local function variable(name)
    local v = SKIN:GetVariable(name, '')
    return v or ''
end

--  ============================================================================
--  Conditions -- WMO weather codes, as used by Open-Meteo
--  ============================================================================

local CONDITIONS = {
    [0]  = 'Clear',
    [1]  = 'Mainly Clear', [2] = 'Partly Cloudy', [3] = 'Overcast',
    [45] = 'Fog', [48] = 'Fog',
    [51] = 'Light Drizzle', [53] = 'Drizzle', [55] = 'Dense Drizzle',
    [56] = 'Freezing Drizzle', [57] = 'Freezing Drizzle',
    [61] = 'Light Rain', [63] = 'Rain', [65] = 'Heavy Rain',
    [66] = 'Freezing Rain', [67] = 'Freezing Rain',
    [71] = 'Light Snow', [73] = 'Snow', [75] = 'Heavy Snow', [77] = 'Snow Grains',
    [80] = 'Rain Showers', [81] = 'Rain Showers', [82] = 'Violent Showers',
    [85] = 'Snow Showers', [86] = 'Snow Showers',
    [95] = 'Thunderstorm', [96] = 'Thunderstorm, Hail', [99] = 'Thunderstorm, Hail',
}

local function conditionLabel(code)
    return code and CONDITIONS[code] or 'Unknown'
end

-- the file in Icons, without its extension. Clear and partly cloudy have a
-- night face; the rest look the same after dark. The set draws fog exactly as
-- overcast, so fog falls through to that. Drizzle and the lightest rain get
-- the scattered showers, and a storm with hail gets the alert.
local function iconFor(code, day)
    if code == 0 then return day and 'weather-clear' or 'weather-clear-night' end
    if code == 1 or code == 2 then
        return day and 'weather-few-clouds' or 'weather-few-clouds-night'
    end
    if (code >= 51 and code <= 57) or code == 61 or code == 80 then
        return 'weather-showers-scattered'
    end
    if (code >= 63 and code <= 67) or code == 81 or code == 82 then return 'weather-showers' end
    if (code >= 71 and code <= 77) or code == 85 or code == 86 then return 'weather-snow' end
    if code == 96 or code == 99 then return 'weather-severe-alert' end
    if code >= 95 then return 'weather-storm' end
    return 'weather-overcast'
end

local function round(n)
    return math.floor(n + 0.5)
end

--  ============================================================================
--  Rainmeter entry points
--  ============================================================================

function Initialize()
    iconDir     = variable('CURRENTPATH') .. 'Icons\\'
    manualLat   = variable('ManualLat')
    manualLon   = variable('ManualLon')
    manualLabel = variable('ManualLocation')
    -- the degree sign as a Rainmeter character reference, resolved by the
    -- meter: strings from Lua reach the skin in the ANSI code page, so raw
    -- UTF-8 bytes would render as two characters
    degrees = variable('TempUnit') == 'fahrenheit' and '[\\x00B0]F' or '[\\x00B0]C'

    -- pinned to a place by hand: never ask ip-api.com anything
    if manualLat ~= '' and manualLon ~= '' then
        SKIN:Bang('!DisableMeasure', 'MeasureGeoIP')
    end
end

function Update()
    ticks = ticks + 1

    -- ---- location ----------------------------------------------------------
    local lat, lon = manualLat, manualLon
    if lat == '' or lon == '' then
        lat, lon = measureString('MeasureLat'), measureString('MeasureLon')
    end

    if lat ~= '' and lon ~= '' then
        local coords = lat .. ',' .. lon
        if coords ~= coordsPushed then
            local first = coordsPushed == nil
            coordsPushed = coords
            SKIN:Bang('!SetVariable', 'Lat', lat)
            SKIN:Bang('!SetVariable', 'Lon', lon)
            SKIN:Bang('!EnableMeasure', 'MeasureWeatherRaw')
            -- enabling is normally enough: the measure's download counter is
            -- still at zero, so it fetches on its next update -- by which time
            -- it has also re-read #Lat#/#Lon#.  Come back in a moment in case
            -- it did not, but not before then: a measure that was still
            -- disabled has the old URL, and forcing it now would fetch that.
            kickAt, kickForce = ticks + 3, not first
        end
    end

    -- ---- what to show ------------------------------------------------------
    local temp = tonumber(measureString('MeasureTempNow'))
    local code = tonumber(measureString('MeasureCodeNow'))
    local tmax = tonumber(measureString('MeasureTempMax'))
    local tmin = tonumber(measureString('MeasureTempMin'))
    local day  = measureString('MeasureIsDay') ~= '0'

    if temp then
        set('TempNow', round(temp) .. degrees, 'Weather')
        set('Condition', conditionLabel(code), 'Weather')
        if tmax and tmin then
            set('HighLowText', string.format('High %d%s   Low %d%s',
                                             round(tmax), degrees, round(tmin), degrees),
                'Weather')
        end
        set('IconFile', iconDir .. iconFor(code or 3, day) .. '.png', 'Weather')

        local label = manualLabel
        if label == '' then label = measureString('MeasureCity') end
        if label == '' and coordsPushed then label = coordsPushed:gsub(',', ', ') end
        if label ~= '' then set('LocationLabel', label, 'Weather') end

    elseif ticks > 20 and coordsPushed == nil then
        -- twenty seconds and the IP lookup has still not produced coordinates
        set('TempNow', '--', 'Weather')
        set('Condition', 'No location', 'Weather')
        set('HighLowText', 'Set ManualLat/Lon', 'Weather')
        set('LocationLabel', 'ip-api.com did not answer', 'Weather')

    elseif ticks > 60 then
        set('TempNow', '--', 'Weather')
        set('Condition', 'No forecast', 'Weather')
        set('HighLowText', 'Open-Meteo unreachable', 'Weather')
    end

    -- ---- retries -----------------------------------------------------------
    if kickAt and ticks >= kickAt then
        if kickForce or temp == nil then
            SKIN:Bang('!CommandMeasure', 'MeasureWeatherRaw', 'Update')
        end
        kickAt = nil
    end

    -- for as long as there is nothing at all to show, try again every two
    -- minutes rather than waiting out the measure's own cycle
    if temp == nil and ticks % 120 == 0 then
        if coordsPushed == nil then
            SKIN:Bang('!CommandMeasure', 'MeasureGeoIP', 'Update')
        else
            SKIN:Bang('!CommandMeasure', 'MeasureWeatherRaw', 'Update')
        end
    end

    flush()
    return ''
end
