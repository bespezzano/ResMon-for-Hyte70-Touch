-- settings.lua: the settings page. Changes a setting (a variable from settings.inc), saves it to settings.inc
-- (every page reads it when it opens) and redraws, so the see-through settings show at once on this page.
-- Options: File (settings.inc), Toggles (the variables shown as on/off switches, comma separated).
-- the switches' track: on / off, in the dark theme and in the light one (settings: DarkTheme)
local ON, OFF = { [1] = '61,224,255,255', [0] = '0,163,194,255' }, { [1] = '58,74,98,255', [0] = '150,165,188,255' }

local function get(k) return tonumber(SKIN:GetVariable(k)) or 0 end

local function paint()
  local th = get('DarkTheme') == 0 and 0 or 1
  for k in TOGGLES:gmatch('[^,]+') do SKIN:Bang('!SetVariable', 'tgFill_' .. k, get(k) == 1 and ON[th] or OFF[th]) end
  SKIN:Bang('!UpdateMeter', '*'); SKIN:Bang('!Redraw')
end

local BACKDROP = 'ResMon\\Backdrop'   -- draws the page background underneath the pages (see build_skin.py)

local function put(k, v)
  SKIN:Bang('!SetVariable', k, v)
  SKIN:Bang('!WriteKeyValue', 'Variables', k, tostring(v), FILE)
  SKIN:Bang('!SetVariable', k, v, BACKDROP)
  SKIN:Bang('!UpdateMeter', '*', BACKDROP); SKIN:Bang('!Redraw', BACKDROP)
  paint()
end

function Initialize()
  FILE = SELF:GetOption('File')
  TOGGLES = SELF:GetOption('Toggles')
  -- Rainmeter reopens the page that was showing when it closed: if this is the first page loaded since Rainmeter
  -- started (the start time isn't the one game.lua's pages last noted in StartFile), go back to the swipe pages
  local f, now = SELF:GetOption('StartFile'), os.time()
  local started = now - math.floor(os.clock())
  local h = io.open(f, 'r'); local seen = h and tonumber(h:read('*l') or '') or 0; if h then h:close() end
  if math.abs(started - seen) > 10 then
    h = io.open(f, 'w'); if h then h:write(started); h:close() end
    Done()
    return
  end
  SKIN:Bang('!SetVariable', 'TempUnits', tempUnits())
  paint()
end

function Toggle(k)
  put(k, get(k) == 1 and 0 or 1)
  -- the theme: this page and the backdrop are drawn again in it (the other pages read it when they open)
  if k == 'DarkTheme' then SKIN:Bang('!Refresh', BACKDROP); SKIN:Bang('!Refresh') end
end

function Step(k, d, lo, hi) put(k, math.max(lo, math.min(hi, get(k) + d))) end

-- the temperature choice (TempUnits, not saved; Choices_TempUnits: Celsius | F weather | Fahrenheit) and the two
-- settings each stands for: TempF (weather) and SysTempF (CPU/GPU; -1, from settings saved before it existed,
-- follows TempF)
local TEMPS = { { 0, 0 }, { 1, 0 }, { 1, 1 } }
function tempUnits()
  local list = {}
  for c in SELF:GetOption('Choices_TempUnits'):gmatch('[^|]+') do list[#list + 1] = c end
  local w = get('TempF') == 1 and 1 or 0
  local sys = tonumber(SKIN:GetVariable('SysTempF') or '') or -1
  if sys < 0 then sys = w end
  for i, t in ipairs(TEMPS) do if t[1] == w and t[2] == sys then return list[i] or '' end end
  return list[1] or ''
end

-- a setting with named choices (option Choices_<k>: "A|B|C"): the next (d = 1) or previous (d = -1), wrapping round
function Cycle(k, d)
  local list = {}
  for c in SELF:GetOption('Choices_' .. k):gmatch('[^|]+') do list[#list + 1] = c end
  if #list == 0 then return end
  local cur, at = SKIN:GetVariable(k), 0
  for i, c in ipairs(list) do if c == cur then at = i end end
  local pick = list[(at - 1 + d) % #list + 1]
  if k == 'TempUnits' then
    local t = TEMPS[(at - 1 + d) % #list + 1]
    SKIN:Bang('!SetVariable', k, pick)
    put('TempF', t[1]); put('SysTempF', t[2])
    return
  end
  put(k, pick)
  -- a place (option Coords_<k>: "Name=lat,lon|..."): also save its coordinates as <k>Lat / <k>Lon
  for name, lat, lon in SELF:GetOption('Coords_' .. k):gmatch('([^|=]+)=([^,|]+),([^|]+)') do
    if name == pick then put(k .. 'Lat', lat); put(k .. 'Lon', lon) end
  end
end

function Done()
  local back = SKIN:GetVariable('SettingsReturn')
  if not back or back == '' then back = 'Home' end
  SKIN:Bang('!ActivateConfig', SKIN:GetVariable('CURRENTCONFIG'), back .. '.ini')
end

function Update() return 0 end
