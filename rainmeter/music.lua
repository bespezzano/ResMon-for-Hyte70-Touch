-- music.lua: switches to the music page when music starts playing, and back when it stops. Runs on every page.
-- npwatch.exe (started from here) writes Windows' media status to a small file; this reads it every second.
-- "Music" means the player reports an album, is a music app, or a browser window shows YouTube Music, so
-- YouTube videos don't count (MusicOnly=0 counts anything).
-- Games come first: it never leaves the gaming page or switches while a game is active. After switching, it
-- goes back to the page you were on once nothing has played for ExitSeconds. Swiping away from an
-- automatically opened music page dismisses it until the music stops. Settings: autoswitch.json "music".
local function readKV(path, keys)
  local s = {}
  for _, k in ipairs(keys) do s[k] = '' end
  local f = io.open(path, 'r')
  if f then
    for line in f:lines() do local k, v = line:match('^(%w+)=(.*)$'); if k then s[k] = v end end
    f:close()
  end
  return s
end

local function readState() return readKV(STATE, { 'ret', 'auto', 'dismissed' }) end

local function writeState(s)
  local f = io.open(STATE, 'w')
  if f then
    for _, k in ipairs({ 'ret', 'auto', 'dismissed' }) do f:write(k .. '=' .. (s[k] or '') .. '\n') end
    f:close()
  end
end

local function log(msg)
  if LOG == '' then return end
  local lines, f = {}, io.open(LOG, 'r')
  if f then for l in f:lines() do lines[#lines + 1] = l end; f:close() end
  lines[#lines + 1] = os.date('%Y-%m-%d %H:%M:%S ') .. msg
  f = io.open(LOG, 'w')
  if f then for i = math.max(1, #lines - 199), #lines do f:write(lines[i], '\n') end; f:close() end
end

function Initialize()
  THIS = SELF:GetOption('ThisPage')
  MUSICPAGE = SELF:GetOption('MusicPage')
  GAMEPAGE = SELF:GetOption('GamePage')
  STATUSFILE = SELF:GetOption('Status')
  WATCHER = SELF:GetOption('Watcher')
  STATE = SELF:GetOption('State')
  GAMESTATE = SELF:GetOption('GameState')
  LOG = SELF:GetOption('Log')
  ENTER = tonumber(SELF:GetOption('EnterSeconds', '3'))
  EXIT = tonumber(SELF:GetOption('ExitSeconds', '30'))
  CLOSE = tonumber(SELF:GetOption('ClosedSeconds', '3'))
  MUSICONLY = SELF:GetOption('MusicOnly', '1') == '1'
  hot, quiet, started = 0, 0, 0
end

-- npwatch.exe: "<status>\t<album>\t<title>\t<artist>\t<music 1|0>"
-- returns: playing music?, its title, and whether the player is gone (closed, or Chrome fell back to a tab
-- that isn't music) rather than just paused
local function nowPlaying()
  local f = io.open(STATUSFILE, 'r')
  if not f then return false, '', true end
  local line = f:read('*l') or ''; f:close()
  local status, album, title, artist, music = line:match('^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t?([01]?)')
  local isMusic = (title or '') ~= '' and (not MUSICONLY or music == '1')
  local playing = status == 'Playing' and isMusic
  local gone = not isMusic or status == nil or status == 'None' or status == 'Closed' or status == 'Stopped'
  return playing, title or '', gone
end

local function go(page) SKIN:Bang('!ActivateConfig', SKIN:GetVariable('CURRENTCONFIG'), page .. '.ini') end

function Update()
  local now = os.time()
  if now - started >= 30 then
    -- (re)start the watcher as its own process, so it keeps running across page changes (a RunCommand
    -- measure's process is stopped when its page unloads). It exits at once if it's already running.
    started = now
    SKIN:Bang('["' .. WATCHER .. '" "' .. STATUSFILE .. '" "' .. SELF:GetOption('Known') .. '" "' .. SELF:GetOption('Running') .. '" "' .. SELF:GetOption('History') .. '" "' .. SELF:GetOption('Focus') .. '"]')
  end
  local playing, title, gone = nowPlaying()
  if playing then quiet, closed = 0, 0 else quiet = quiet + 1 end
  if gone then closed = (closed or 0) + 1 else closed = 0 end
  local s = readState()

  -- log every start/stop, so a switch that didn't happen can be explained from autoswitch.log
  if playing ~= LASTPLAYING then
    if LASTPLAYING ~= nil or playing then
      local why = ''
      if playing and THIS ~= MUSICPAGE then
        if THIS == GAMEPAGE then why = ' (on the gaming page: no switch)'
        elseif s.dismissed == '1' then why = ' (dismissed by a swipe: no switch until it stops for 5 s)' end
      end
      log((playing and 'music playing: "' .. title .. '"' or 'music stopped') .. ' [' .. THIS .. ']' .. why)
    end
    LASTPLAYING = playing
  end

  -- a swipe-away lasts until the music stops (5 s, so a pause and play brings the page back)
  if s.dismissed == '1' and quiet >= 5 then s.dismissed = ''; writeState(s) end

  if THIS ~= MUSICPAGE then
    if THIS == GAMEPAGE then hot = 0; return 0 end
    if s.auto == '1' then
      -- the music page was opened automatically, a game took over, and you swiped away from the gaming page
      s.auto, s.ret, s.dismissed = '0', '', '1'
      writeState(s)
    end
    local game = GAMESTATE ~= '' and readKV(GAMESTATE, { 'auto' }).auto == '1'
    if playing and game and hot == 0 and not GAMELOGGED then GAMELOGGED = true; log('music playing during a game: no switch') end
    if playing and not game and s.dismissed ~= '1' then hot = hot + 1 else hot = 0 end
    if hot >= ENTER then
      log(string.format('%s -> %s: playing "%s"', THIS, MUSICPAGE, title))
      writeState({ ret = THIS, auto = '1', dismissed = '' })
      go(MUSICPAGE)
    end
  elseif s.auto == '1' and (quiet >= EXIT or closed >= CLOSE) then
    -- paused: wait EXIT seconds (a short pause shouldn't bounce the page); player closed: CLOSE seconds
    local ret = s.ret ~= '' and s.ret or MUSICPAGE
    log(string.format('%s -> %s: %s', MUSICPAGE, ret,
      closed >= CLOSE and ('player closed for ' .. CLOSE .. ' s') or ('nothing playing for ' .. EXIT .. ' s')))
    writeState({ ret = '', auto = '0', dismissed = '' })
    if ret ~= MUSICPAGE then go(ret) end
  end
  return hot
end

-- called by the swipe actions just before changing page
function Swiped()
  local s = readState()
  if THIS == MUSICPAGE and s.auto == '1' then
    writeState({ ret = '', auto = '0', dismissed = '1' })
    log('swiped away from ' .. MUSICPAGE .. '; music dismissed until it stops')
  end
end
