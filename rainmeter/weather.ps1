# weather.ps1: fetches the forecast for weather.json's location and writes it to -Out as Open-Meteo-style JSON
# (the format wx.lua reads). Tries Open-Meteo first; if it doesn't answer, uses MET Norway (api.met.no) and
# converts it. Neither needs an API key. Adds "fetched" (unix time) and "source". On failure the old file
# is left alone. Run by the skin (wx.lua) every refresh_minutes.
param(
  [Parameter(Mandatory)] [string]$Config,
  [Parameter(Mandatory)] [string]$Out,
  [string]$Lat, [string]$Lon,     # the settings page's location (WxCityLat/WxCityLon); weather.json's when not given
  [switch]$SkipOpenMeteo          # for testing the MET Norway fallback
)
$ErrorActionPreference = 'Stop'
$loc = Get-Content $Config -Raw | ConvertFrom-Json
$lat = if ($Lat) { $Lat } else { [string]$loc.latitude }; $lon = if ($Lon) { $Lon } else { [string]$loc.longitude }
$tag = "$lat,$lon"      # what the skin asked for ("auto,auto": where this PC is), saved as the cache's "loc"
$place = ""          # the place's name: only for "auto" (otherwise the skin shows the setting's)
$now = [DateTimeOffset]::Now.ToUnixTimeSeconds()
$utf8 = New-Object System.Text.UTF8Encoding $false

# ---- "auto": this PC's location from Windows' location service (Settings > Privacy > Location; Wi-Fi based, so
# it knows the suburb), rounded to about 1 km. Its name comes from OpenStreetMap (Nominatim), looked up only when
# the place changes and kept in %LOCALAPPDATA%\ResMon\place.json. Without a location (the service is off or
# doesn't answer), the last place found is used, or weather.json's.
if ($lat -eq 'auto') {
  $mem = Join-Path $env:LOCALAPPDATA 'ResMon\place.json'
  $last = $null; try { $last = Get-Content $mem -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
  $here = $null
  try {
    Add-Type -AssemblyName System.Device
    $w = New-Object System.Device.Location.GeoCoordinateWatcher
    if ($w.TryStart($false, [TimeSpan]::FromSeconds(10))) {
      for ($i = 0; $i -lt 20 -and $w.Position.Location.IsUnknown; $i++) { Start-Sleep -Milliseconds 500 }
      $c = $w.Position.Location
      if (-not $c.IsUnknown) {
        $ic = [Globalization.CultureInfo]::InvariantCulture
        $here = @{ lat = [math]::Round($c.Latitude, 2).ToString($ic); lon = [math]::Round($c.Longitude, 2).ToString($ic) }
      }
    }
    $w.Stop()
  } catch { }
  if ($here) {
    $name = if ($last -and $last.lat -eq $here.lat -and $last.lon -eq $here.lon) { $last.name } else { $null }
    if (-not $name) {
      try {
        $n = Invoke-RestMethod "https://nominatim.openstreetmap.org/reverse?lat=$($here.lat)&lon=$($here.lon)&format=jsonv2&zoom=14&accept-language=en" `
             -Headers @{ 'User-Agent' = 'ResMon-screen/1.0 (desktop weather widget)' } -TimeoutSec 10
        $a = $n.address
        $name = @($a.suburb, $a.town, $a.village, $a.city, $a.municipality, $n.name) | Where-Object { $_ } | Select-Object -First 1
      } catch { }
      if ($name) {
        New-Item -ItemType Directory -Force (Split-Path $mem) | Out-Null
        [IO.File]::WriteAllText($mem, (@{ lat = $here.lat; lon = $here.lon; name = $name } | ConvertTo-Json -Compress), $utf8)
      } elseif ($last) { $name = $last.name }
    }
    $lat, $lon, $place = $here.lat, $here.lon, $name
  } elseif ($last) { $lat, $lon, $place = $last.lat, $last.lon, $last.name }
  else { $lat, $lon, $place = [string]$loc.latitude, [string]$loc.longitude, $loc.name }
}

# the cache also says which location it's for ("loc": "lat,lon" as asked, so wx.lua fetches at once after a change)
# and its name ("place")
function Save([string]$json) {
  $json = '{"loc":"' + $tag + '","place":"' + ($place -replace '["\\]', '') + '",' + $json.TrimStart().Substring(1)
  [IO.File]::WriteAllText("$Out.tmp", $json, $utf8)
  Move-Item "$Out.tmp" $Out -Force
}

# ---- 1. Open-Meteo
if (-not $SkipOpenMeteo) { try {
  $url = "https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon" +
         "&current=temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,weather_code,is_day,uv_index" +
         "&hourly=temperature_2m,weather_code,precipitation_probability,is_day,uv_index" +
         "&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset,uv_index_max" +
         "&timezone=auto&forecast_days=6"
  $r = Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 8
  $body = $r.Content.Trim()
  if ($body -match '"current"' -and $body -match '"daily"' -and $body -match '"hourly"') {
    Save ('{"fetched":' + $now + ',"source":"Open-Meteo",' + $body.Substring(1))
    exit 0
  }
} catch { } }

# ---- 2. MET Norway, converted to the same shape
$ua = @{ 'User-Agent' = 'ResMon-screen/1.0 (desktop weather widget)' }
try {
  $met = Invoke-RestMethod "https://api.met.no/weatherapi/locationforecast/2.0/complete?lat=$lat&lon=$lon" -Headers $ua -TimeoutSec 20
} catch { exit 1 }

# MET symbol codes -> WMO weather codes (what the icons and condition text use)
function Get-Wmo([string]$sym) {
  $s = ($sym -replace '_(day|night|polartwilight)$', '')
  switch -regex ($s) {
    'thunder' { return 95 }
    '^clearsky$' { return 0 }
    '^fair$' { return 1 }
    '^partlycloudy$' { return 2 }
    '^cloudy$' { return 3 }
    '^fog$' { return 45 }
    'sleet' { return 66 }
    '^lightsnow' { return 71 }
    '^heavysnow' { return 75 }
    'snowshowers$' { return 85 }
    'snow' { return 73 }
    '^lightrainshowers$' { return 80 }
    '^heavyrainshowers$' { return 82 }
    'rainshowers$' { return 81 }
    '^lightrain$' { return 61 }
    '^heavyrain$' { return 65 }
    'rain' { return 63 }
    default { return 3 }
  }
}

$tz = [TimeZoneInfo]::Local
$ts = $met.properties.timeseries
$cur = $ts[0].data
$det = $cur.instant.details
$sym = if ($cur.next_1_hours) { $cur.next_1_hours.summary.symbol_code } else { $cur.next_6_hours.summary.symbol_code }

# sunrise/sunset for today (MET's sunrise API), also used for day/night when the symbol doesn't say
$today = [DateTime]::Now.Date
$off = $tz.GetUtcOffset($today); $offs = '{0}{1:hh\:mm}' -f ($(if ($off -lt 0) { '-' } else { '+' })), $off
$rise = $null; $set = $null
try {
  $sun = Invoke-RestMethod ("https://api.met.no/weatherapi/sunrise/3.0/sun?lat=$lat&lon=$lon&date={0:yyyy-MM-dd}&offset=$offs" -f $today) -Headers $ua -TimeoutSec 15
  $rise = $sun.properties.sunrise.time; $set = $sun.properties.sunset.time
} catch { }
$isDay = 1
if ($sym -match '_night$') { $isDay = 0 } elseif ($sym -match '_day$') { $isDay = 1 }
elseif ($rise -and $set) { $n = [DateTimeOffset]::Now; $isDay = [int]($n -ge [DateTimeOffset]::Parse($rise) -and $n -lt [DateTimeOffset]::Parse($set)) }

# daily: high/low from every forecast step that day (local time), symbol from around midday
$days = [ordered]@{}
foreach ($e in $ts) {
  $t = [DateTimeOffset]::Parse($e.time).ToLocalTime()
  $k = $t.ToString('yyyy-MM-dd')
  if (-not $days.Contains($k)) { $days[$k] = @{ temps = New-Object System.Collections.Generic.List[double]; sym = $null; symHour = 99; uv = 0.0 } }
  $d = $days[$k]
  $u = $e.data.instant.details.ultraviolet_index_clear_sky
  if ($null -ne $u -and [double]$u -gt $d.uv) { $d.uv = [double]$u }
  $d.temps.Add([double]$e.data.instant.details.air_temperature)
  $s6 = $e.data.next_6_hours
  if ($s6) {
    $d.temps.Add([double]$s6.details.air_temperature_max); $d.temps.Add([double]$s6.details.air_temperature_min)
    $dist = [math]::Abs($t.Hour - 12)
    if ($dist -lt $d.symHour) { $d.sym = $s6.summary.symbol_code; $d.symHour = $dist }
  }
  if (-not $d.sym -and $e.data.next_1_hours) { $d.sym = $e.data.next_1_hours.summary.symbol_code }
}
$keys = @($days.Keys | Select-Object -First 6)
$daily = [ordered]@{
  time = $keys
  weather_code = @($keys | ForEach-Object { Get-Wmo $days[$_].sym })
  temperature_2m_max = @($keys | ForEach-Object { [math]::Round(($days[$_].temps | Measure-Object -Maximum).Maximum, 1) })
  temperature_2m_min = @($keys | ForEach-Object { [math]::Round(($days[$_].temps | Measure-Object -Minimum).Minimum, 1) })
  precipitation_probability_max = @($keys | ForEach-Object { $null })   # not forecast by MET for this region
  sunrise = @($(if ($rise) { $rise.Substring(0, 16) } else { $null }))
  sunset = @($(if ($set) { $set.Substring(0, 16) } else { $null }))
  uv_index_max = @($keys | ForEach-Object { [math]::Round($days[$_].uv, 1) })   # clear-sky UV (MET gives no cloud-adjusted UV)
}
# hourly: the next 30 one-hour steps, in local time like Open-Meteo's
$hrs = @($ts | Where-Object { $_.data.next_1_hours } | Select-Object -First 30)
$hourly = [ordered]@{
  time = @($hrs | ForEach-Object { [DateTimeOffset]::Parse($_.time).ToLocalTime().ToString('yyyy-MM-ddTHH:mm') })
  temperature_2m = @($hrs | ForEach-Object { $_.data.instant.details.air_temperature })
  weather_code = @($hrs | ForEach-Object { Get-Wmo $_.data.next_1_hours.summary.symbol_code })
  precipitation_probability = @($hrs | ForEach-Object { $_.data.next_1_hours.details.probability_of_precipitation })
  is_day = @($hrs | ForEach-Object {
    $c = $_.data.next_1_hours.summary.symbol_code
    if ($c -match '_night$') { 0 } elseif ($c -match '_day$') { 1 }
    elseif ($rise -and $set) {   # symbols like "cloudy" don't say: compare the time of day with today's sunrise/sunset
      $tod = [DateTimeOffset]::Parse($_.time).ToLocalTime().TimeOfDay
      [int]($tod -ge [DateTimeOffset]::Parse($rise).TimeOfDay -and $tod -lt [DateTimeOffset]::Parse($set).TimeOfDay)
    } else { 1 } })
  uv_index = @($hrs | ForEach-Object { $_.data.instant.details.ultraviolet_index_clear_sky })
}
$feels = if ($null -ne $det.apparent_air_temperature) { $det.apparent_air_temperature } else { $det.air_temperature }
$wx = [ordered]@{
  fetched = $now; source = 'MET Norway'
  current = [ordered]@{
    temperature_2m = $det.air_temperature; apparent_temperature = $feels
    relative_humidity_2m = $det.relative_humidity; wind_speed_10m = [math]::Round($det.wind_speed * 3.6, 1)
    weather_code = (Get-Wmo $sym); is_day = $isDay; uv_index = $det.ultraviolet_index_clear_sky
  }
  hourly = $hourly
  daily = $daily
}
Save ($wx | ConvertTo-Json -Depth 4 -Compress)
exit 0
