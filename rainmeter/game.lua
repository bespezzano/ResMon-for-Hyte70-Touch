-- game.lua: switches to the gaming page while a game runs, and back afterwards. Runs on every page.
-- A "game" is the program HWiNFO's PresentMon sensor follows (the focused app) when it isn't on the ignore
-- list and, for EnterSeconds, is installed in a game library folder or fills its monitor with GPU load at or
-- above the threshold (see newGame). Games found this way go into known-games.txt and switch at once after that. When no game has been focused for
-- ExitSeconds, the screen returns to the page you were on. Swiping away from an automatically opened gaming
-- page dismisses it for that game until the game ends. Settings come from autoswitch.json (via the builder).
local function readState()
  local s = { ret = '', auto = '0', game = '', dismissed = '', last = '', closed = '', closedat = '0' }
  local f = io.open(STATE, 'r')
  if f then
    for line in f:lines() do local k, v = line:match('^(%w+)=(.*)$'); if k then s[k] = v end end
    f:close()
  end
  return s
end

local function writeState(s)
  -- 'last' (the page you swiped from) is kept unless s sets it
  if s.last == nil then s.last = readState().last end
  local f = io.open(STATE, 'w')
  if f then
    for _, k in ipairs({ 'ret', 'auto', 'game', 'dismissed', 'last', 'closed', 'closedat' }) do f:write(k .. '=' .. (s[k] or '') .. '\n') end
    f:close()
  end
end

-- one line per switch and per change of what's drawing frames (autoswitch.log next to known-games.txt,
-- so rebuilding the skin doesn't erase it; the last 200 lines are kept)
local function log(msg)
  local dir = KNOWNFILE:match('^(.*\\)') or STATE:match('^(.*\\)') or ''
  local path = dir .. 'autoswitch.log'
  local lines, f = {}, io.open(path, 'r')
  if f then for l in f:lines() do lines[#lines + 1] = l end; f:close() end
  lines[#lines + 1] = os.date('%Y-%m-%d %H:%M:%S ') .. msg
  f = io.open(path, 'w')
  if f then for i = math.max(1, #lines - 199), #lines do f:write(lines[i], '\n') end; f:close() end
end

function Initialize()
  THIS = SELF:GetOption('ThisPage')
  GAMEPAGE = SELF:GetOption('GamePage')
  STATE = SELF:GetOption('State')
  STARTFILE = (STATE:match('^(.*\\)') or '') .. 'rainmeter-start.txt'
  LOAD = tonumber(SELF:GetOption('GpuLoad', '50'))
  ENTER = tonumber(SELF:GetOption('EnterSeconds', '5'))
  EXIT = tonumber(SELF:GetOption('ExitSeconds', '30'))
  -- one exe per line, # comments (kept outside the skin, so rebuilds keep them; the settings page opens them)
  local function list(file)
    local t, f = {}, file ~= '' and io.open(file, 'r')
    if f then
      for line in f:lines() do
        local n = line:lower():match('^%s*([^#]-)%s*$')
        if n and n ~= '' then t[n] = true end
      end
      f:close()
    end
    return t
  end
  -- apps never treated as games (ignored-apps.txt)
  IGNORE = list(SELF:GetOption('IgnoreFile', ''))
  -- games seen before (known-games.txt) switch after 1 s
  KNOWNFILE = SELF:GetOption('Known')
  KNOWN = list(KNOWNFILE)
  INFOARGS = SELF:GetOption('InfoArgs')
  INFOFILE = SELF:GetOption('InfoFile')
  IDLEHERO = SELF:GetOption('IdleHero')   -- banner shown when there's no game (or no Steam artwork for it)
  IDLEANIM = SELF:GetOption('IdleAnim') == '1'   -- the idle banner has an animated controller ([idlePad])
  -- npwatch.exe also reports which known game is running, focused or not
  WATCHER = SELF:GetOption('Watcher')
  RUNFILE = SELF:GetOption('Running')
  WATCH = WATCHER ~= '' and ('"' .. WATCHER .. '" "' .. SELF:GetOption('Status') .. '" "' .. KNOWNFILE .. '" "' .. RUNFILE
                             .. '" "' .. SELF:GetOption('History') .. '" "' .. SELF:GetOption('Focus') .. '"') or ''
  FOCUSFILE = SELF:GetOption('Focus')
  -- install folders that only hold games (path fragments, lower case)
  FOLDERS = {}
  for d in SELF:GetOption('GameFolders', ''):gmatch('[^|]+') do FOLDERS[#FOLDERS + 1] = d:lower():gsub('/', '\\') end
  hot, cold, started = 0, 0, 0
  LOADEDAT = os.clock()
end

-- Changing page swaps this skin for another one. Doing that from a page's first update, while Rainmeter is still
-- loading it, has crashed Rainmeter (twice in a row: Home loaded and switched straight back to Gaming as a game
-- closed; Gaming switched to Home as Rainmeter started), so a page waits until it has been loaded for SETTLE
-- seconds before it switches. os.clock() is the time since Rainmeter started.
local SETTLE = 2
local function settled() return os.clock() - LOADEDAT >= SETTLE end

local function runningKnown()
  if RUNFILE == '' then return nil end
  local f = io.open(RUNFILE, 'r')
  if not f then return nil end
  local g = (f:read('*l') or ''):lower():match('^%s*(.-)%s*$'); f:close()
  return g ~= '' and g or nil
end

-- ---- game info panel (name, Steam playtime, artwork) on the gaming page
local function setInfo(k, v) SKIN:Bang('!SetVariable', k, v or '') end

-- the idle banner (and its animated controller, which is paused while a game's own banner shows)
local function idleHero(on)
  if on then setInfo('GAME_HERO', IDLEHERO) end
  if not IDLEANIM then return end
  if on then SKIN:Bang('!EnableMeasure', 'mIdleFrame'); SKIN:Bang('!ShowMeterGroup', 'IdleAnim')
  else SKIN:Bang('!DisableMeasure', 'mIdleFrame'); SKIN:Bang('!HideMeterGroup', 'IdleAnim') end
end

local function lookup(game)
  INFOFOR = game
  START = nil
  if not game then
    setInfo('GAME_NAME', 'No game running')
    for _, k in ipairs({ 'GAME_TOTAL', 'GAME_RECENT', 'GAME_SESSION', 'GAME_HERO', 'GAME_LOGO', 'GAME_SOURCE',
                         'GAME_ACH', 'GAME_ACH_NEXT' }) do setInfo(k) end
    idleHero(true)
    setInfo('GAME_ACH_PCT', '0')
    return
  end
  setInfo('GAME_NAME', game)
  SKIN:Bang('!SetOption', 'mGameInfo', 'Parameter', (INFOARGS:gsub('%%EXE%%', game)))
  SKIN:Bang('!UpdateMeasure', 'mGameInfo')
  SKIN:Bang('!CommandMeasure', 'mGameInfo', 'Run')
end

function InfoReady()
  local f = io.open(INFOFILE, 'r')
  if not f then return end
  for line in f:lines() do
    local k, v = line:match('^([%w_]+)=(.*)$')
    if k == 'GAME_START' then START = tonumber(v)
    elseif k == 'GAME_HERO' then if v == '' then idleHero(true) else setInfo(k, v); idleHero(false) end   -- no Steam artwork: idle banner
    elseif k then setInfo(k, v) end
  end
  f:close()
  SKIN:Bang('!UpdateMeter', '*'); SKIN:Bang('!Redraw')
end

local function sessionText()
  if not START then return '' end
  local s = math.max(0, os.time() - START)
  local h, m = math.floor(s / 3600), math.floor(s % 3600 / 60)
  return h > 0 and string.format('%dh %02dm', h, m) or string.format('%d min', m)
end

local function updateInfo(s, game)
  if INFOARGS == '' then return end
  -- the auto-detected game, or (if you swiped here yourself) whatever game is focused; keep the last one shown
  local cur = (s.auto == '1' and s.game ~= '' and s.game) or game or INFOFOR
  if cur ~= INFOFOR or INFOFOR == nil and not SHOWN then SHOWN = true; lookup(cur) end
  setInfo('GAME_SESSION', sessionText())
end

local function remember(game)
  if KNOWN[game] or KNOWNFILE == '' then return end
  KNOWN[game] = true
  local f = io.open(KNOWNFILE, 'a')
  if f then f:write(game .. '\n'); f:close() end
end

-- installers, uninstallers and runtime setups draw frames too (e.g. "monitorian installer.exe"), but aren't games
local NOT_GAME = { 'install', 'setup', 'unins', 'redist' }
local function notGame(p)
  for _, w in ipairs(NOT_GAME) do if p:find(w, 1, true) then return true end end
  return false
end

-- A game that has just closed is still reported for a moment (HWiNFO's PresentMon sensor and npwatch's running
-- game lag behind its process), so the page the gaming page went back to would switch straight back to it, two
-- page loads in a fraction of a second, which has crashed Rainmeter. For CLOSEDWAIT seconds after the gaming page
-- saw it close, that game doesn't switch pages.
local CLOSEDWAIT = 10
local function justClosed(s, g)
  return g ~= nil and g == s.closed and os.time() - (tonumber(s.closedat) or 0) < CLOSEDWAIT
end

-- Is a focused app that isn't a known game yet a game? Drawing frames isn't enough (video calls, players and
-- launchers do too), so it also has to be installed in a game library folder (Steam, Epic, GOG, Xbox, ...), or
-- fill its monitor (fullscreen or borderless) while the GPU is at least GpuLoad % busy. Returns the reason, or nil.
local function newGame(p, load)
  if FOCUSFILE == '' then return load >= LOAD and 'GPU load' or nil end   -- no watcher: GPU load alone
  local f = io.open(FOCUSFILE, 'r')
  if not f then return nil end
  local exe, full, path = (f:read('*l') or ''):match('^([^\t]*)\t([^\t]*)\t(.*)$'); f:close()
  if exe ~= p then return nil end
  for _, d in ipairs(FOLDERS) do if path:find(d, 1, true) then return 'in ' .. d end end
  if full == '1' and load >= LOAD then return 'fullscreen' end
  return nil
end

local function focusedGame()
  local p = SKIN:GetMeasure('m_FPSPROC'):GetStringValue():lower()
  raw = p
  if p == '' or IGNORE[p] or notGame(p) then return nil end
  return p
end

function Update()
  local now = os.time()
  -- Rainmeter reopens the page that was showing when it closed; the first page loaded after Rainmeter starts
  -- goes to the default page instead, unless a game had switched pages. Only once per Rainmeter run: the start
  -- time (now - os.clock(), the time since Rainmeter started) is remembered, so later page loads and swipes
  -- aren't affected.
  if not CHECKEDSTART and settled() then
    CHECKEDSTART = true
    local started = now - math.floor(os.clock())
    local f = io.open(STARTFILE, 'r')
    local seen = f and tonumber(f:read('*l') or '') or 0
    if f then f:close() end
    if math.abs(started - seen) > 10 then
      f = io.open(STARTFILE, 'w'); if f then f:write(started); f:close() end
      local def = SELF:GetOption('DefaultPage')
      if def ~= '' and def ~= THIS and os.clock() < 60 and readState().auto ~= '1' then
        log(THIS .. ' -> ' .. def .. ': Rainmeter started')
        SKIN:Bang('!ActivateConfig', SKIN:GetVariable('CURRENTCONFIG'), def .. '.ini')
        return 0
      end
    end
  end
  if WATCH ~= '' and now - started >= 30 then
    started = now
    SKIN:Bang('[' .. WATCH .. ']')   -- exits at once if it's already running
  end
  local game = focusedGame()
  local run = runningKnown()
  local load = SKIN:GetMeasure('v_GPULOAD'):GetValue()
  local s = readState()
  -- the game the gaming page shows when you came here yourself: a known game, or a focused app that passes the same
  -- checks as auto-switching (not just any app drawing frames, e.g. a launcher's or wallpaper app's settings window)
  if THIS == GAMEPAGE then updateInfo(s, (game and (KNOWN[game] or newGame(game, load)) and game) or run) end
  if not settled() then return hot end

  if THIS ~= GAMEPAGE then
    -- a dismissed game stays dismissed until it has been closed (or not focused) for EXIT seconds
    if s.dismissed ~= '' then
      if game == s.dismissed or run == s.dismissed then cold = 0 else cold = cold + 1 end
      if cold >= EXIT then s.dismissed = ''; writeState(s); cold = 0 end
    end
    -- a game that has only just closed is ignored for a few seconds (see justClosed)
    if justClosed(s, game) then game = nil end
    if justClosed(s, run) then run = nil end
    -- a known game that's running switches at once, focused or not; others must be focused and look like a game
    local how
    if run and run ~= s.dismissed then game, how = run, 'known game running'
    elseif game and KNOWN[game] then how = 'known game focused'
    elseif game then local why = newGame(game, load); how = why and ('new game focused, ' .. why) end
    local known = how and how:find('^known')
    if game and game ~= s.dismissed and how then hot = hot + 1 else hot = 0 end
    if hot >= (known and 1 or ENTER) then
      log(string.format('%s -> %s: %s (%s, GPU %d%%)', THIS, GAMEPAGE, game, how, load))
      remember(game)
      writeState({ ret = THIS, auto = '1', game = game, dismissed = '' })
      SKIN:Bang('!ActivateConfig', SKIN:GetVariable('CURRENTCONFIG'), GAMEPAGE .. '.ini')
    end
  elseif s.auto == '1' then
    -- back as soon as the game's process has ended (2 checks in a row), or after EXIT seconds with
    -- something else in focus. Other apps that show up in between don't take over as "the game".
    if RUNNING == nil and s.game ~= '' then
      RUNNING = SKIN:GetMeasure('mGameRunning')
      SKIN:Bang('!SetOption', 'mGameRunning', 'ProcessName', s.game)
      SKIN:Bang('!UpdateMeasure', 'mGameRunning')
      return hot
    end
    local alive = not RUNNING or RUNNING:GetValue() == 1
    if alive ~= LASTALIVE then LASTALIVE = alive; log(s.game .. (alive and ' process running' or ' process ended')) end
    if (game or '') ~= LASTFOCUS then LASTFOCUS = game or ''; log('drawing frames: ' .. (raw ~= '' and raw or 'nothing') .. (game and '' or ' (ignored)')) end
    if not alive then gone = (gone or 0) + 1 else gone = 0 end
    -- a known game stays on the gaming page while it runs, focused or not (it would switch straight back)
    if game == s.game or run == s.game then cold = 0 else cold = cold + 1 end
    if cold >= EXIT or (gone or 0) >= 2 then
      local ret = (s.ret ~= '' and s.ret) or GAMEPAGE
      local closed = (gone or 0) >= 2
      log(string.format('%s -> %s: %s', GAMEPAGE, ret, closed and (s.game .. ' closed') or (s.game .. ' not drawing frames for ' .. EXIT .. ' s')))
      writeState({ ret = '', auto = '0', game = '', dismissed = '',
                   closed = closed and s.game or '', closedat = closed and tostring(os.time()) or '0' })
      if ret ~= GAMEPAGE then SKIN:Bang('!ActivateConfig', SKIN:GetVariable('CURRENTCONFIG'), ret .. '.ini') end
    end
  else
    -- you came to the gaming page yourself (or came back after swiping away): when the known game that's
    -- running closes, go back to the page you swiped here from
    if run then SEEN, gone = run, 0
    elseif SEEN then
      gone = (gone or 0) + 1
      if gone >= 2 then
        local ret = (s.last ~= '' and s.last ~= GAMEPAGE) and s.last or nil
        log(string.format('%s -> %s: %s closed', GAMEPAGE, ret or '(stay)', SEEN))
        writeState({ ret = '', auto = '0', game = '', dismissed = '', closed = SEEN, closedat = tostring(os.time()) })
        SEEN = nil
        if ret then SKIN:Bang('!ActivateConfig', SKIN:GetVariable('CURRENTCONFIG'), ret .. '.ini') end
      end
    end
  end
  return hot
end

-- called by the swipe actions just before changing page
function Swiped()
  local s = readState()
  if THIS == GAMEPAGE and s.auto == '1' then
    writeState({ ret = '', auto = '0', game = '', dismissed = s.game, last = THIS })
    log('swiped away from ' .. GAMEPAGE .. '; ' .. s.game .. ' dismissed until it closes')
  else
    s.last = THIS
    writeState(s)
  end
end
