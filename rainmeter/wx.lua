-- wx.lua: turns the forecast JSON (Open-Meteo format, written by weather.ps1) into WX_* skin variables.
-- Icon numbers index the sprite frames: same order as WX_ORDER in build_skin.py / wx-icons.js.
local ICON = { ['clear-day'] = 0, ['clear-night'] = 1, ['partly-day'] = 2, ['partly-night'] = 3, cloudy = 4,
               fog = 5, drizzle = 6, rain = 7, snow = 8, thunder = 9 }
local COND = { [0] = 'Clear', [1] = 'Mostly clear', [2] = 'Partly cloudy', [3] = 'Overcast', [45] = 'Fog',
               [48] = 'Freezing fog', [51] = 'Light drizzle', [53] = 'Drizzle', [55] = 'Heavy drizzle',
               [56] = 'Freezing drizzle', [57] = 'Freezing drizzle', [61] = 'Light rain', [63] = 'Rain',
               [65] = 'Heavy rain', [66] = 'Freezing rain', [67] = 'Freezing rain', [71] = 'Light snow',
               [73] = 'Snow', [75] = 'Heavy snow', [77] = 'Snow grains', [80] = 'Light showers', [81] = 'Showers',
               [82] = 'Heavy showers', [85] = 'Snow showers', [86] = 'Heavy snow showers', [95] = 'Thunderstorm',
               [96] = 'Thunderstorm, hail', [99] = 'Thunderstorm, hail' }

local function icon(code, isDay)
  local d = (isDay == nil) or (isDay == 1)
  if code == nil then return ICON.cloudy end
  if code <= 0 then return d and ICON['clear-day'] or ICON['clear-night'] end
  if code <= 2 then return d and ICON['partly-day'] or ICON['partly-night'] end
  if code == 3 then return ICON.cloudy end
  if code == 45 or code == 48 then return ICON.fog end
  if code >= 51 and code <= 57 then return ICON.drizzle end
  if (code >= 61 and code <= 67) or (code >= 80 and code <= 82) then return ICON.rain end
  if (code >= 71 and code <= 77) or code == 85 or code == 86 then return ICON.snow end
  if code >= 95 then return ICON.thunder end
  return ICON.cloudy
end

local function num(s, k) return tonumber(s:match('"' .. k .. '":(%-?[%d%.]+)')) end
local function arr(s, k)
  local a, t = s:match('"' .. k .. '":%[(.-)%]'), {}
  if a then for v in a:gmatch('[^,]+') do t[#t + 1] = (v:gsub('"', '')) end end
  return t
end
local function r(x) x = tonumber(x); if x == nil then return '--' end; return string.format('%d', math.floor(x + 0.5)) end
local function set(k, v) SKIN:Bang('!SetVariable', k, tostring(v)) end
-- temperatures: the forecast is in °C; the TempF setting shows them in °F
local function deg(x) x = tonumber(x); if x and TEMPF then x = x * 9 / 5 + 32 end; return x end
-- wind: the forecast is in km/h; the WindMph setting shows mph
local function speed(x) x = tonumber(x); if x and MPH then x = x / 1.609344 end; return x end

-- the light theme (settings: DarkTheme = 0): a colour with its lightness flipped (HSL: L -> 1 - L), as
-- build_skin.py and lc-live.js do for the rest of the page
local function themed(c)
  if tonumber(SKIN:GetVariable('DarkTheme')) ~= 0 then return c end
  local r, g, b = c:match('^(%d+),(%d+),(%d+)')
  r, g, b = r / 255, g / 255, b / 255
  local mx, mn = math.max(r, g, b), math.min(r, g, b)
  local l, h, s = (mx + mn) / 2, 0, 0
  if mx ~= mn then
    local d = mx - mn
    s = l > 0.5 and d / (2 - mx - mn) or d / (mx + mn)
    if mx == r then h = (g - b) / d + (g < b and 6 or 0) elseif mx == g then h = (b - r) / d + 2 else h = (r - g) / d + 4 end
    h = h / 6
  end
  l = 1 - l
  if s == 0 then r, g, b = l, l, l else
    local q = l < 0.5 and l * (1 + s) or l + s - l * s
    local p = 2 * l - q
    local function hue(t)
      t = t % 1
      if t < 1 / 6 then return p + (q - p) * 6 * t elseif t < 0.5 then return q
      elseif t < 2 / 3 then return p + (q - p) * (2 / 3 - t) * 6 else return p end
    end
    r, g, b = hue(h + 1 / 3), hue(h), hue(h - 1 / 3)
  end
  local out = string.format('%d,%d,%d', math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
  local a = c:match('^%d+,%d+,%d+,(%d+)$')
  return a and (out .. ',' .. a) or out
end

-- UV index bands (WHO): label and colour (Rainmeter r,g,b)
local function uvBand(u)
  if u == nil then return '--', '107,127,156' end
  u = math.floor(u + 0.5)
  if u <= 2 then return 'Low', '76,217,100' end
  if u <= 5 then return 'Moderate', '255,214,10' end
  if u <= 7 then return 'High', '255,159,10' end
  if u <= 10 then return 'Very high', '255,69,58' end
  return 'Extreme', '191,90,242'
end
local function setUV(prefix, u)
  local label, col = uvBand(u)
  set(prefix, r(u)); set(prefix .. '_LABEL', label); set(prefix .. '_COL', themed(col))
end

-- next 24 hours from the hourly block: HOURS columns HSTEP hours apart, and the UV peak
local HOURS, HSTEP = 8, 3
local function hourly(h)
  local t = arr(h, 'time')
  local temp, codes, pop, day, uv = arr(h, 'temperature_2m'), arr(h, 'weather_code'),
    arr(h, 'precipitation_probability'), arr(h, 'is_day'), arr(h, 'uv_index')
  -- the forecast's times are the location's local time (Open-Meteo gives its UTC offset; MET's are converted to ours)
  local now = OFFSET and os.date('!%Y-%m-%dT%H:00', os.time() + OFFSET) or os.date('%Y-%m-%dT%H:00')
  local start
  for i = 1, #t do if t[i] >= now then start = i; break end end
  for n = 1, HOURS do
    local i = start and (start + (n - 1) * HSTEP)
    local k = 'WX_H' .. n .. '_'
    if i and t[i] then
      set(k .. 'TIME', n == 1 and 'Now' or t[i]:match('T(%d%d:%d%d)'))
      local tt, pp = r(deg(temp[i])), r(pop[i])
      set(k .. 'TEMP', tt == '--' and tt or tt .. '°'); set(k .. 'POP', pp == '--' and '' or pp .. '%')
      set(k .. 'ICON', icon(tonumber(codes[i]), tonumber(day[i])))
    else
      set(k .. 'TIME', '--'); set(k .. 'TEMP', '--'); set(k .. 'POP', '--'); set(k .. 'ICON', ICON.cloudy)
    end
  end
  local peak, at = nil, nil
  for i = start or 1, math.min(#t, (start or 1) + 23) do
    local u = tonumber(uv[i])
    if start and u and (peak == nil or u > peak) then peak, at = u, t[i] end
  end
  setUV('WX_UV_PEAK', peak)
  set('WX_UV_PEAK_TIME', peak and peak >= 0.5 and at:match('T(%d%d:%d%d)') or '--')
end

local function apply(s)
  local cur, daily = s:match('"current":(%b{})'), s:match('"daily":(%b{})')
  if not cur or not daily then return false end
  OFFSET = num(s, 'utc_offset_seconds')
  local place = s:match('"place":"([^"]*)"')
  if place and place ~= '' then set('WX_PLACE', place) end
  local code, isDay = num(cur, 'weather_code'), num(cur, 'is_day')
  set('WX_TEMP', r(deg(num(cur, 'temperature_2m'))))
  set('WX_FEELS', r(deg(num(cur, 'apparent_temperature'))))
  set('WX_HUM', r(num(cur, 'relative_humidity_2m')))
  set('WX_WIND', r(speed(num(cur, 'wind_speed_10m'))))
  set('WX_ICON', icon(code, isDay))
  set('WX_COND', COND[code] or '')
  local uv = num(cur, 'uv_index')
  setUV('WX_UV', uv)
  set('WX_UV_POS', math.min(11, math.max(0, uv or 0)))   -- for the marker on the UV scale
  local h = s:match('"hourly":(%b{})')
  if h then hourly(h) end
  local t, codes = arr(daily, 'time'), arr(daily, 'weather_code')
  local hi, lo, pop = arr(daily, 'temperature_2m_max'), arr(daily, 'temperature_2m_min'), arr(daily, 'precipitation_probability_max')
  local rise, sets = arr(daily, 'sunrise'), arr(daily, 'sunset')
  set('WX_HIGH', r(deg(hi[1]))); set('WX_LOW', r(deg(lo[1]))); set('WX_POP', r(pop[1]))
  set('WX_SUNRISE', (rise[1] or ''):match('T(%d%d:%d%d)') or '--')
  set('WX_SUNSET', (sets[1] or ''):match('T(%d%d:%d%d)') or '--')
  for i = 1, 5 do
    local y, m, d = (t[i + 1] or ''):match('(%d+)-(%d+)-(%d+)')
    set('WX_D' .. i .. '_DAY', y and os.date('%a', os.time { year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }) or '--')
    set('WX_D' .. i .. '_HIGH', r(deg(hi[i + 1]))); set('WX_D' .. i .. '_LOW', r(deg(lo[i + 1]))); set('WX_D' .. i .. '_POP', r(pop[i + 1]))
    set('WX_D' .. i .. '_ICON', icon(tonumber(codes[i + 1]), 1))
  end
  SKIN:Bang('!UpdateMeter', '*'); SKIN:Bang('!Redraw')
  return true
end

-- weather.ps1 (measure mWxFetch) downloads the forecast into CACHE (Open-Meteo, or MET Norway when Open-Meteo
-- doesn't answer). The cache lives outside the skin folder, so rebuilds and reboots show the last forecast at once.
local function load()
  local f = io.open(CACHE, 'r')
  if not f then return end
  local s = f:read('*a'); f:close()
  -- a forecast for another location (the settings page changed it): don't show it, fetch now
  local here = (SKIN:GetVariable('WxCityLat') or '') .. ',' .. (SKIN:GetVariable('WxCityLon') or '')
  if here ~= ',' and s:match('"loc":"([^"]*)"') ~= here then FETCHED, LASTTRY = 0, 0; return end
  if apply(s) then FETCHED = tonumber(s:match('"fetched":(%d+)')) or 0 end
end

function Initialize()
  CACHE = SELF:GetOption('Cache')
  REFRESH = 60 * tonumber(SELF:GetOption('RefreshMinutes', '15'))
  FETCHED, LASTTRY = 0, 0
  TEMPF = SKIN:GetVariable('TempF') == '1'
  MPH = SKIN:GetVariable('WindMph') == '1'
  -- the place name on the weather page: the setting's, or (Automatic) the name found for where this PC is
  local city = SKIN:GetVariable('WxCity') or ''
  set('WX_PLACE', city == 'Automatic' and '--' or city)
  load()
end

-- called when weather.ps1 finishes
function Parse() load() end

function Update()
  local now = os.time()
  -- fetch when the cache is older than the refresh interval; after a failed attempt, wait 5 minutes
  if now - FETCHED >= REFRESH and now - LASTTRY >= 300 then
    LASTTRY = now
    SKIN:Bang('!CommandMeasure', 'mWxFetch', 'Run')
  end
  return now - FETCHED
end
