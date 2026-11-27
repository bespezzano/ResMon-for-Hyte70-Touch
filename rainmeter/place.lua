-- place.lua: puts ResMon on the HYTE Y70 screen by itself, wherever that screen sits among the monitors.
-- Every page (ResMon\Screen) and the backdrop (ResMon\Backdrop) run it when they load. It finds the Y70 by its shape:
-- a screen 3.3 to 4 times taller than wide (1st gen 1100x3840: 3.49; Touch Infinite 688x2560 / 682x2560: 3.72 / 3.75),
-- which no ordinary monitor is. Failing that, the tallest portrait monitor. If the skin isn't at that screen's corner,
-- it moves there and sets how it sits: the pages in the normal layer and fixed in place; the backdrop at the bottom,
-- fixed and click-through. Nothing happens when it's already in place, so a page change costs nothing.
-- Options: Role (page | backdrop).
-- Rainmeter works in Windows' scaled pixels (it isn't DPI-aware), so the monitors' sizes here are scaled too; their
-- shape is the same at any scaling.

local function num(v) return tonumber(SKIN:GetVariable(v) or '') end

-- the monitors: Rainmeter's SCREENAREAX@n ... variables, n = 1, 2, ...
local function monitors()
  local list = {}
  for n = 1, 16 do
    local x, y, w, h = num('SCREENAREAX@' .. n), num('SCREENAREAY@' .. n), num('SCREENAREAWIDTH@' .. n), num('SCREENAREAHEIGHT@' .. n)
    if not (x and y and w and h) or w <= 0 then break end
    list[#list + 1] = { n = n, x = x, y = y, w = w, h = h, r = h / w }
  end
  return list
end

-- the Y70: the right shape, else the tallest portrait monitor; nil if there's no portrait monitor
local function y70()
  local best
  for _, m in ipairs(monitors()) do
    if m.r >= 3.3 and m.r <= 4 then return m end
    if m.r > 1.2 and (not best or m.r > best.r) then best = m end
  end
  return best
end

function Initialize()
  local m = y70()
  if not m then
    print('ResMon: no portrait screen found, so the skin stays where it is')
    return
  end
  local cfg = SKIN:GetVariable('CURRENTCONFIG')
  local role = SELF:GetOption('Role', 'page')
  -- the screen size the page was built for (option Size, WxH): a different one needs a build for that screen
  if role == 'page' then
    local sw, sh = SELF:GetOption('Size', ''):match('^(%d+)x(%d+)$')
    sw, sh = tonumber(sw), tonumber(sh)
    if sw and sh and (math.abs(sw - m.w) > 2 or math.abs(sh - m.h) > 2) then
      print(string.format('ResMon: this build is %dx%d but the screen is %dx%d: rebuild it for this screen (installed from a package: load ResMon\\Start, which picks the build)', sw, sh, m.w, m.h))
    end
  end
  if num('CURRENTCONFIGX') == m.x and num('CURRENTCONFIGY') == m.y then return end
  SKIN:Bang('!Draggable', '0', cfg)
  SKIN:Bang('!KeepOnScreen', '0', cfg)
  SKIN:Bang('!SnapEdges', '0', cfg)
  if role == 'backdrop' then
    SKIN:Bang('!ClickThrough', '1', cfg)
    SKIN:Bang('!ZPos', '-1', cfg)            -- "bottom": always underneath the pages
  else
    SKIN:Bang('!ZPos', '0', cfg)             -- "normal"
  end
  SKIN:Bang('!Move', tostring(m.x), tostring(m.y), cfg)
  print(string.format('ResMon: %s moved to screen %d (%dx%d at %d,%d)', cfg, m.n, m.w, m.h, m.x, m.y))
end

function Update() return 0 end
