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
  paint()
end

function Toggle(k)
  put(k, get(k) == 1 and 0 or 1)
  -- the theme: this page and the backdrop are drawn again in it (the other pages read it when they open)
  if k == 'DarkTheme' then SKIN:Bang('!Refresh', BACKDROP); SKIN:Bang('!Refresh') end
end

function Step(k, d, lo, hi) put(k, math.max(lo, math.min(hi, get(k) + d))) end

-- a setting with named choices (option Choices_<k>: "A|B|C"): the next (d = 1) or previous (d = -1), wrapping round
function Cycle(k, d)
  local list = {}
  for c in SELF:GetOption('Choices_' .. k):gmatch('[^|]+') do list[#list + 1] = c end
  if #list == 0 then return end
  local cur, at = SKIN:GetVariable(k), 0
  for i, c in ipairs(list) do if c == cur then at = i end end
  local pick = list[(at - 1 + d) % #list + 1]
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
