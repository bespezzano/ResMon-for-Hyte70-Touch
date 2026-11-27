-- start.lua: the starter skin of a ResMon package (ResMon\Start). The package holds one build of the pages per
-- screen size (configs ResMon\<width>x<height>), because Rainmeter works in Windows' scaled pixels and the Y70
-- models and scaling settings give different sizes. Once setup.ps1 has copied the starting files, this finds the
-- Y70 (like place.lua: the screen 3.3 to 4 times taller than wide, else the tallest portrait monitor), loads the
-- backdrop and the build closest to that screen's size, unloads the other builds, and unloads itself.
-- Load ResMon\Start again after changing the screen's scaling.
-- Options: Builds (sizes, separated by |), Page (the page to open, e.g. Home).

local function num(v) return tonumber(SKIN:GetVariable(v) or '') end

local function y70()
  local best
  for n = 1, 16 do
    local x, y, w, h = num('SCREENAREAX@' .. n), num('SCREENAREAY@' .. n), num('SCREENAREAWIDTH@' .. n), num('SCREENAREAHEIGHT@' .. n)
    if not (x and y and w and h) or w <= 0 then break end
    local r = h / w
    if r >= 3.3 and r <= 4 then return { w = w, h = h, r = r } end
    if r > 1.2 and (not best or r > best.r) then best = { w = w, h = h, r = r } end
  end
  return best
end

local function say(text)
  print('ResMon: ' .. text)
  SKIN:Bang('!SetOption', 'Status', 'Text', text)
  SKIN:Bang('!UpdateMeter', 'Status'); SKIN:Bang('!Redraw')
end

-- the configs Rainmeter has loaded, from Rainmeter.ini ([config] sections with Active=n, n > 0)
function active()
  local on, f = {}, io.open(SKIN:GetVariable('SETTINGSPATH') .. 'Rainmeter.ini', 'rb')
  if not f then return on end
  local s = f:read('*a'):gsub('%z', ''); f:close()   -- UTF-16: drop the zero bytes of the ASCII letters
  local cur
  for line in s:gmatch('[^\r\n]+') do
    local sec = line:match('^%[(.+)%]$')
    if sec then cur = sec
    elseif cur then
      local n = line:match('^Active=(%d+)')
      if n and tonumber(n) > 0 then on[cur] = true end
    end
  end
  return on
end

function Initialize() end

-- called when setup.ps1 has finished
function Start()
  local builds = {}
  for b in SELF:GetOption('Builds', ''):gmatch('[^|]+') do
    local w, h = b:match('^(%d+)x(%d+)$')
    if w then builds[#builds + 1] = { name = b, w = tonumber(w), h = tonumber(h) } end
  end
  local m = y70()
  if not m then
    say('No HYTE Y70 screen found (no portrait monitor). Turn the screen on, then load ResMon\\Start again.')
    return
  end
  local pick, cost
  for _, b in ipairs(builds) do
    local c = math.abs(b.w - m.w) + math.abs(b.h - m.h)
    if not cost or c < cost then pick, cost = b, c end
  end
  if not pick then say('This package has no builds.'); return end
  if cost > 4 then
    print(string.format('ResMon: no build for %dx%d, using the closest, %s', m.w, m.h, pick.name))
  end
  SKIN:Bang('!ActivateConfig', 'ResMon\\Backdrop', 'Backdrop.ini')
  SKIN:Bang('!ActivateConfig', 'ResMon\\' .. pick.name, SELF:GetOption('Page', 'Home') .. '.ini')
  local on = active()
  for _, b in ipairs(builds) do
    if b ~= pick and on['ResMon\\' .. b.name] then SKIN:Bang('!DeactivateConfig', 'ResMon\\' .. b.name) end
  end
  print(string.format('ResMon: loaded the %s build for the %dx%d screen', pick.name, m.w, m.h))
  SKIN:Bang('!DeactivateConfig')
end

function Update() return 0 end
