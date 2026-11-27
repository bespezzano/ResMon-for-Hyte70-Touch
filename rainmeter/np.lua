-- np.lua: now playing. On the music page it starts nowplaying.ps1 (measure mNPHelper), keeps its heartbeat file
-- fresh, reads its np.txt every second and turns it into NP_* variables; the playback position is counted
-- here between updates. Pages with only a small now-playing strip use light mode (see Initialize).
-- Buttons call Press(); volume comes from the Win7Audio plugin (measure mVol).
-- Segoe Fluent Icons glyphs Play E768, Pause E769, Volume E767, Mute E74F, as UTF-8 bytes (Lua 5.1 has no \u)
local G = { play = '\238\157\168', pause = '\238\157\169', vol = '\238\157\167', mute = '\238\157\143' }

local function set(k, v) SKIN:Bang('!SetVariable', k, v or '') end

local function clock(s)
  s = math.max(0, math.floor(s + 0.5))
  local h, m = math.floor(s / 3600), math.floor(s % 3600 / 60)
  if h > 0 then return string.format('%d:%02d:%02d', h, m, s % 60) end
  return string.format('%d:%02d', m, s % 60)
end

function Initialize()
  INFO = SELF:GetOption('Info')
  HEART = SELF:GetOption('Heartbeat')
  np, raw, started, pressed, seen = {}, '', 0, nil, {}
  HISTDIR = SELF:GetOption('History')
  ROWS = tonumber(SELF:GetOption('HistoryRows', '6'))
  -- light mode (pages with a small now-playing strip): no PowerShell helper; title and status come from
  -- npwatch.exe's status file and the cover from its history thumbnails
  LIGHT = SELF:GetOption('Light', '0') == '1'
  STATUSFILE = SELF:GetOption('Status')
  IDLEHIDE = SELF:GetOption('IdleHide')
  IDLEART = SELF:GetOption('IdleArt')   -- cover shown while nothing plays, or for a track without artwork
end

-- "Recently played": npwatch.exe keeps <History>\history.txt ("<unix time>\t<title>\t<artist>\t<thumbnail>",
-- newest first). The track playing now is left out, so the list shows what came before it.
local function ago(t)
  local s = os.time() - t
  if s < 90 then return 'just now' end
  if s < 3600 then return math.floor(s / 60 + 0.5) .. ' min ago' end
  if s < 86400 then return math.floor(s / 3600 + 0.5) .. ' h ago' end
  if s < 172800 then return 'yesterday' end
  return math.floor(s / 86400) .. ' days ago'
end

local function history()
  if HISTDIR == '' then return end
  local f = io.open(HISTDIR .. '\\history.txt', 'r')
  local items = {}
  if f then
    for line in f:lines() do
      local t, title, artist, thumb = line:match('^(%d+)\t([^\t]*)\t([^\t]*)\t?([^\t]*)')
      if t then items[#items + 1] = { t = tonumber(t), title = title, artist = artist, thumb = thumb } end
    end
    f:close()
  end
  local cur = (np.STATUS or 'None') ~= 'None' and ((np.NP_TITLE or '') .. '\t' .. (np.NP_ARTIST or '')) or nil
  local n = 0
  for _, it in ipairs(items) do
    if n >= ROWS then break end
    if not (n == 0 and cur and it.title .. '\t' .. it.artist == cur) then
      n = n + 1
      set('NP_H' .. n .. '_TITLE', it.title)
      set('NP_H' .. n .. '_ARTIST', it.artist)
      set('NP_H' .. n .. '_AGO', ago(it.t))
      set('NP_H' .. n .. '_ART', it.thumb ~= '' and (HISTDIR .. '\\' .. it.thumb) or '')
    end
  end
  for k = n + 1, ROWS do
    for _, s in ipairs({ 'TITLE', 'ARTIST', 'AGO', 'ART' }) do set('NP_H' .. k .. '_' .. s, '') end
  end
  if n == 0 and ROWS > 0 then set('NP_H1_ARTIST', 'Tracks you play show up here') end
  -- light mode: the current track's cover is its history thumbnail (saved 5 s into the track)
  if LIGHT then
    local thumb = ''
    for _, it in ipairs(items) do
      if cur and it.title .. '\t' .. it.artist == cur then thumb = it.thumb ~= '' and (HISTDIR .. '\\' .. it.thumb) or ''; break end
    end
    set('NP_THUMB', thumb)
  end
end

local function startHelper()
  started = os.time()
  SKIN:Bang('!CommandMeasure', 'mNPHelper', 'Run')   -- exits at once if it's already running
end

local function read()
  local f = io.open(LIGHT and STATUSFILE or INFO, 'r')
  if not f then return end
  local s = f:read('*a'); f:close()
  if s == raw then return end
  raw = s
  np = {}
  if LIGHT then
    -- npwatch.exe's status line: <status>\t<album>\t<title>\t<artist>\t<music 1|0>
    local st, album, title, artist, music = s:match('^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t\n]*)\t?([01]?)')
    np = { STATUS = st or 'None', NP_ALBUM = album, NP_TITLE = title, NP_ARTIST = artist, MUSIC = music }
  else
    for line in s:gmatch('[^\n]+') do
      local k, v = line:match('^([%w_]+)=(.*)$')
      if k then np[k] = v end
    end
  end
  -- Chrome shows Windows one media entry for all its tabs: close YouTube Music and it falls back to a paused
  -- video in some other tab. A paused item that isn't music and hasn't played while this page was open is
  -- left out.
  local key = (np.NP_TITLE or '') .. '|' .. (np.NP_ARTIST or '')
  local isMusic = (np.NP_ALBUM or '') ~= '' or np.MUSIC == '1'
  if np.STATUS == 'Playing' then seen[key] = true end
  if np.STATUS ~= 'Playing' and not isMusic and not seen[key] then np = { STATUS = 'None' } end
  local none = (np.STATUS or 'None') == 'None' or (np.NP_TITLE or '') == ''
  set('NP_TITLE', none and 'Nothing playing' or np.NP_TITLE)
  set('NP_ARTIST', none and 'Play something in YouTube Music, Spotify or any player' or np.NP_ARTIST)
  set('NP_ALBUM', none and '' or np.NP_ALBUM)
  set('NP_SOURCE', none and '' or np.NP_SOURCE)
  local art = not none and np.NP_ART or ''
  set('NP_ART', art ~= '' and art or IDLEART)
  pressed = nil
end

function Update()
  local now = os.time()
  if not LIGHT then
    local f = io.open(HEART, 'w'); if f then f:write(now); f:close() end
    if now - started >= 30 then startHelper() end
  end
  read()
  history()

  local status = pressed or np.STATUS or 'None'
  local dur = tonumber(np.DUR) or 0
  local pos = tonumber(np.POS) or 0
  if status == 'Playing' and not pressed then pos = pos + math.max(0, now - (tonumber(np.POSAT) or now)) end
  if dur > 0 then pos = math.min(pos, dur) end
  set('NP_POS', dur > 0 and clock(pos) or '')
  set('NP_DUR', dur > 0 and clock(dur) or '')
  set('NP_PROGRESS', dur > 0 and string.format('%.2f', 100 * pos / dur) or '0')
  set('NP_PLAYICON', status == 'Playing' and G.pause or G.play)

  -- IdleHide: meter groups (data-group ... data-show="playing") shown only while something is playing or paused
  local idle = (np.STATUS or 'None') == 'None' or (np.NP_TITLE or '') == ''
  if IDLEHIDE ~= '' and idle ~= WASIDLE then
    WASIDLE = idle
    for grp in IDLEHIDE:gmatch('[^,]+') do SKIN:Bang(idle and '!HideMeterGroup' or '!ShowMeterGroup', grp) end
    SKIN:Bang('!Redraw')
  end

  local vol = SKIN:GetMeasure('mVol')
  if vol then
    local v = vol:GetValue()
    set('NP_DEVICE', vol:GetStringValue())
    set('NP_VOL', v < 0 and 'Muted' or string.format('%d%%', v))
    set('NP_VOLPCT', v < 0 and '0' or tostring(v))
    set('NP_VOLICON', v < 0 and G.mute or G.vol)
  end
  return pos
end

-- buttons: media keys go to whatever Windows considers the current player
function Press(what)
  if what == 'PlayPause' then
    SKIN:Bang('!CommandMeasure', 'mMediaKey', 'PlayPause')
    pressed = ((pressed or np.STATUS) == 'Playing') and 'Paused' or 'Playing'   -- flip the icon now
  elseif what == 'Next' or what == 'Prev' then
    SKIN:Bang('!CommandMeasure', 'mMediaKey', what .. 'Track')     -- MediaKey's commands: NextTrack, PrevTrack
  elseif what == 'VolUp' or what == 'VolDown' then
    -- step to the next multiple of 5 (18 -> 20 -> 25, 18 -> 15 -> 10)
    local v = math.max(0, SKIN:GetMeasure('mVol'):GetValue())
    local t = what == 'VolUp' and math.floor(v / 5) * 5 + 5 or math.ceil(v / 5) * 5 - 5
    SKIN:Bang('!CommandMeasure', 'mVol', 'SetVolume ' .. math.max(0, math.min(100, t)))
  elseif what == 'Mute' then SKIN:Bang('!CommandMeasure', 'mVol', 'ToggleMute') end
  Update(); SKIN:Bang('!UpdateMeter', '*'); SKIN:Bang('!Redraw')
end
