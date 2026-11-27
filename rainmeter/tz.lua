-- tz.lua: the second clock's UTC offset right now (variable AltTZ), for the city in AltCity (settings.inc).
-- Zones (from build_skin.py, via Windows' time zone data): "City@unix:offset,unix:offset;City@..." - each city's
-- offset from each moment on, so daylight saving is right. Default: the offset for a city that isn't listed.
function Initialize()
  ZONES = {}
  for city, list in SELF:GetOption('Zones'):gmatch('([^@;]+)@([^;]+)') do
    local t = {}
    for at, off in list:gmatch('(%-?%d+):(%-?[%d%.]+)') do t[#t + 1] = { tonumber(at), tonumber(off) } end
    ZONES[city] = t
  end
  DEFAULT = tonumber(SELF:GetOption('Default', '0')) or 0
end

function Update()
  local list, off = ZONES[SKIN:GetVariable('AltCity')], DEFAULT
  if list then
    local now = os.time()
    off = list[1][2]
    for _, e in ipairs(list) do if now >= e[1] then off = e[2] end end
  end
  if off ~= LAST then LAST = off; SKIN:Bang('!SetVariable', 'AltTZ', off) end
  return off
end
