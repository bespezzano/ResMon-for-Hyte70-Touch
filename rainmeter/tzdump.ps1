# tzdump.ps1: for each "City=Windows time zone id" argument, prints the zone's UTC offset (hours) now and every change
# over the next few years, from Windows' own time zone data, as JSON: {"City": [[unixSeconds, offsetHours], ...]}.
# build_skin.py runs it to give the second clock (tap the clock) the right offset whatever the daylight saving.
param([string]$Zones, [int]$Years = 3)   # "City=Zone id;City=Zone id;..."
$ErrorActionPreference = 'Stop'
$start = [DateTimeOffset]::UtcNow.AddDays(-1)
$out = [ordered]@{}
foreach ($z in ($Zones -split ';' | Where-Object { $_ })) {
  $city, $id = $z -split '=', 2
  try { $tz = [TimeZoneInfo]::FindSystemTimeZoneById($id) } catch { [Console]::Error.WriteLine("unknown time zone: $id"); continue }
  $t = $start
  $off = $tz.GetUtcOffset($t).TotalHours
  $list = @(, @($t.ToUnixTimeSeconds(), $off))
  $end = $start.AddYears($Years)
  while ($t -lt $end) {
    $n = $t.AddDays(1)
    $o = $tz.GetUtcOffset($n).TotalHours
    if ($o -ne $off) {
      # the change happened within this day: find the minute
      $lo = $t; $hi = $n
      while (($hi - $lo).TotalMinutes -gt 1) {
        $mid = $lo.AddTicks([long](($hi - $lo).Ticks / 2))
        if ($tz.GetUtcOffset($mid).TotalHours -eq $off) { $lo = $mid } else { $hi = $mid }
      }
      $list += , @($hi.ToUnixTimeSeconds(), $o)
      $off = $o
    }
    $t = $n
  }
  $out[$city] = $list
}
$out | ConvertTo-Json -Depth 4 -Compress
