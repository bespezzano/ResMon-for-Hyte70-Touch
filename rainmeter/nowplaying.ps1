# nowplaying.ps1: reads what's playing from Windows' media controls (any app that shows in the volume flyout:
# YouTube Music in Chrome/Edge, Spotify, ...) and writes it to <Out>\np.txt (KEY=value lines), plus the album
# art as a PNG sized for the music page. Started by the skin (np.lua) when the music page loads; one instance
# at a time, and it exits by itself ~15 s after the page stops touching the heartbeat file.
param(
  [Parameter(Mandatory)] [string]$Out,
  [Parameter(Mandatory)] [string]$Heartbeat,
  [string]$Art = '733x733',
  [string]$Bg = '#04060B'
)
$ErrorActionPreference = 'SilentlyContinue'
$mutex = New-Object System.Threading.Mutex($false, 'Local\ResMonNowPlaying')
if (-not $mutex.WaitOne(0)) { exit 0 }

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
  $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
function Await($op, [Type]$t) { $task = $asTask.MakeGenericMethod($t).Invoke($null, @($op)); [void]$task.Wait(5000); $task.Result }
[void][Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
[void][Windows.Storage.Streams.IRandomAccessStreamWithContentType, Windows.Storage.Streams, ContentType = WindowsRuntime]
$TMgr = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]
$TProps = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties]
$TStream = [Windows.Storage.Streams.IRandomAccessStreamWithContentType]
[void][Windows.Storage.Streams.IInputStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
$AsStream = [System.IO.WindowsRuntimeStreamExtensions].GetMethod('AsStreamForRead', [Type[]]@([Windows.Storage.Streams.IInputStream]))
$mgr = Await ($TMgr::RequestAsync()) $TMgr
New-Item -ItemType Directory -Force $Out | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding $false
$aw, $ah = $Art -split 'x' | ForEach-Object { [int]$_ }
$bgc = [System.Drawing.ColorTranslator]::FromHtml($Bg)

function Get-Source([string]$id) {
  if ($id -match 'cinhimbnkkaeohfgghhklpknlkffjgod') { return 'YouTube Music' }
  if ($id -match 'spotify') { return 'Spotify' }
  if ($id -match '^chrome') { return 'Chrome' }
  if ($id -match 'msedge') { return 'Edge' }
  if ($id -match 'firefox') { return 'Firefox' }
  return ($id -replace '\.exe$', '' -replace '^.*[\\!]', '')
}

# Music in a browser tab reaches Windows as just "Chrome" (or Edge, Firefox): the media controls don't say which
# site. The browser's window titles do (the active tab's title, e.g. "YouTube Music" or "Song - YouTube"), so the
# site is taken from them; a window whose title also has the track's name wins. If the music tab isn't the active
# tab in its window, the browser's name stays.
Add-Type @"
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Text;
public static class ResMonTitles {
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  public static string[] Of(int[] pids) {
    var set = new HashSet<uint>(); foreach (var p in pids) set.Add((uint)p);
    var r = new List<string>();
    EnumWindows((h, l) => {
      uint pid;
      if (IsWindowVisible(h) && GetWindowThreadProcessId(h, out pid) != 0 && set.Contains(pid)) {
        var sb = new StringBuilder(512);
        if (GetWindowText(h, sb, 512) > 0) r.Add(sb.ToString());
      }
      return true;
    }, IntPtr.Zero);
    return r.ToArray();
  }
}
"@
$Browsers = @{ Chrome = 'chrome'; Edge = 'msedge'; Firefox = 'firefox' }
$Sites = 'YouTube Music', 'YouTube', 'Spotify', 'SoundCloud', 'Apple Music', 'Deezer', 'TIDAL', 'Bandcamp', 'Twitch'
function Get-Site([string]$browser, [string]$track) {
  $ids = @(Get-Process $Browsers[$browser] -ErrorAction SilentlyContinue | ForEach-Object Id)
  if (-not $ids) { return $browser }
  $titles = @([ResMonTitles]::Of([int[]]$ids))
  if ($track) { $titles = @($titles | Where-Object { $_.Contains($track) }) + @($titles | Where-Object { -not $_.Contains($track) }) }
  foreach ($t in $titles) {
    foreach ($site in $Sites) { if ($t -match "(^|\W)$([regex]::Escape($site))(\W|$)") { return $site } }
  }
  return $browser
}

# album art, cropped square: darker at the top (for the header), fading out to transparent at the bottom
function Read-Thumb($thumbRef) {
  $ras = Await ($thumbRef.OpenReadAsync()) $TStream
  if (-not $ras) { return $null }
  $ns = $AsStream.Invoke($null, @($ras))      # PowerShell 5.1 can't pick this overload by itself
  $ms = New-Object System.IO.MemoryStream; $ns.CopyTo($ms); $ns.Dispose()
  if ($ms.Length -eq 0) { return $null }
  return $ms
}

# Browsers hand Windows only a small thumbnail (120 px for YouTube Music). So the cover is looked up in Apple's
# public iTunes catalogue instead, at 1000 px. With an album, the artist has to match (and the album counts too);
# without one (a YouTube video, say), the artist and the title both have to match exactly, so a video that isn't
# a song keeps its own thumbnail. Extras like "(Official Video)" or "- Remastered 2009" are left out of the title.
$hiRes = @{}
function Get-HiResArt([string]$title, [string]$artist, [string]$album) {
  $key = "$artist|$album|$title"
  if ($hiRes.ContainsKey($key)) { return $hiRes[$key] }
  $hiRes[$key] = $null
  try {
    $artist = $artist -replace ' - Topic$', ''
    $title = ($title -replace "^$([regex]::Escape($artist))\s+-\s+", '' -replace '\s*[\(\[][^\)\]]*[\)\]]', '' `
                     -replace '\s+-\s+[^-]*(remaster|version|edit|mix|live)[^-]*$', '').Trim()
    $term = [uri]::EscapeDataString($artist + ' ' + $title)
    $r = Invoke-RestMethod "https://itunes.apple.com/search?term=$term&entity=song&limit=15" -TimeoutSec 6
    $norm = { param($x) ($x.ToLower() -replace '[^a-z0-9]+', ' ').Trim() }
    $a = & $norm $artist; $al = & $norm $album; $t = & $norm $title
    $best = $null; $bestScore = 0
    foreach ($x in $r.results) {
      $s = 0
      $xa = & $norm $x.artistName; $xc = & $norm $x.collectionName; $xt = & $norm $x.trackName
      if ($xa -eq $a) { $s += 4 } elseif ($a -and ($xa.Contains($a) -or $a.Contains($xa))) { $s += 2 }
      if ($al -and $xc -eq $al) { $s += 3 } elseif ($al -and $xc -and ($xc.StartsWith($al) -or $al.StartsWith($xc))) { $s += 2 }
      if ($xt -eq $t) { $s += 1 }
      if ($s -gt $bestScore) { $best = $x; $bestScore = $s }
    }
    $need = if ($al) { 4 } else { 5 }          # without an album: artist (4) and title (1) both exact
    if ($best -and $bestScore -ge $need) {
      $url = $best.artworkUrl100 -replace '/\d+x\d+bb\.', '/1000x1000bb.'
      $bytes = (New-Object System.Net.WebClient).DownloadData($url)
      $hiRes[$key] = New-Object System.IO.MemoryStream (, $bytes)
    }
  } catch { }
  return $hiRes[$key]
}

function Save-Art($ms, [string]$path) {
  if (-not $ms) { return $false }
  $ms.Position = 0
  $img = [System.Drawing.Image]::FromStream($ms)
  $bmp = New-Object System.Drawing.Bitmap $aw, $ah
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.InterpolationMode = 'HighQualityBicubic'; $g.PixelOffsetMode = 'HighQuality'
  $s = [math]::Max($aw / $img.Width, $ah / $img.Height); $dw = $img.Width * $s; $dh = $img.Height * $s
  $g.DrawImage($img, [single](($aw - $dw) / 2), [single](($ah - $dh) / 2), [single]$dw, [single]$dh)
  $top = [int]($ah * 0.16)
  $r1 = New-Object System.Drawing.Rectangle 0, 0, $aw, $top
  $b1 = New-Object System.Drawing.Drawing2D.LinearGradientBrush $r1, ([System.Drawing.Color]::FromArgb(200, $bgc)), ([System.Drawing.Color]::FromArgb(0, $bgc)), 90
  $g.FillRectangle($b1, 0, 0, $aw, $top)
  $g.Dispose()
  # the bottom fades out to transparent from 50 % down, gone at 83.6 % (920 of 1100: the top of music.html's player
  # panel, which shows below). Drawn in 2 px bands, each with its own opacity.
  $out = New-Object System.Drawing.Bitmap $aw, $ah
  $go = [System.Drawing.Graphics]::FromImage($out)
  $f0 = [int]($ah * 0.5); $f1 = [int]($ah * 0.836)
  $go.DrawImage($bmp, (New-Object System.Drawing.Rectangle 0, 0, $aw, $f0), 0, 0, $aw, $f0, [System.Drawing.GraphicsUnit]::Pixel)
  for ($y = $f0; $y -lt $f1; $y += 2) {
    $t = ($y - $f0) / ($f1 - $f0); $a = 1 - $t * $t * (3 - 2 * $t)       # smooth step down to 0
    $cm = New-Object System.Drawing.Imaging.ColorMatrix; $cm.Matrix33 = [single]$a
    $ia = New-Object System.Drawing.Imaging.ImageAttributes; $ia.SetColorMatrix($cm)
    $h = [math]::Min(2, $f1 - $y)
    $go.DrawImage($bmp, (New-Object System.Drawing.Rectangle 0, $y, $aw, $h), 0, $y, $aw, $h, [System.Drawing.GraphicsUnit]::Pixel, $ia)
    $ia.Dispose()
  }
  $go.Dispose(); $out.Save($path, [System.Drawing.Imaging.ImageFormat]::Png); $out.Dispose(); $bmp.Dispose(); $img.Dispose()
  return $true
}

function Save-NewArt($ms) {
  $script:n++; $new = Join-Path $Out "art_$($script:n).png"
  if (-not (Save-Art $ms $new)) { return }
  Get-ChildItem $Out -Filter 'art_*.png' | Where-Object FullName -ne $new | Remove-Item -Force
  $script:artPath = $new
}

# Chrome reports one media session for all its tabs, and between tracks it can briefly show another tab
# (a paused video) or the old picture with the new title. So a new playing track is shown at once, a paused
# one only once it has been reported for ~1.5 s (and never right after something was playing), and the old
# cover is cleared straight away. Art: the 1000 px lookup at once (again when an album turns up); the player's thumbnail only if that
# doesn't work out, read a few times from 2.5 s on (by then it belongs to the new track).
$last = ''; $shown = $null; $shownKey = $null; $candKey = $null; $candCount = 0; $playingAt = [DateTime]::MinValue
$artPath = ''; $hiTried = ''; $hiOk = $false; $thumbAt = [DateTime]::MaxValue; $thumbTries = 0; $n = 0
$site = ''; $siteKey = $null; $siteAt = [DateTime]::MinValue
while ($true) {
  $hb = Get-Item $Heartbeat
  if (-not $hb -or ((Get-Date) - $hb.LastWriteTime).TotalSeconds -gt 15) { break }
  $now = Get-Date

  # the session that's playing (the current one if several), else the current one
  $sessions = @($mgr.GetSessions())
  $cur = $mgr.GetCurrentSession()
  $play = @($sessions | Where-Object { $_.GetPlaybackInfo().PlaybackStatus -eq 'Playing' })
  $s = if ($play.Count -gt 0) { if ($cur -and ($play | Where-Object { $_.SourceAppUserModelId -eq $cur.SourceAppUserModelId })) { $cur } else { $play[0] } } else { $cur }

  $info = [ordered]@{ STATUS = 'None'; NP_TITLE = ''; NP_ARTIST = ''; NP_ALBUM = ''; NP_SOURCE = ''; NP_ART = ''; POS = '0'; POSAT = '0'; DUR = '0' }
  $p = $null
  if ($s) {
    $p = Await ($s.TryGetMediaPropertiesAsync()) $TProps
    $tl = $s.GetTimelineProperties()
    $info.STATUS = [string]$s.GetPlaybackInfo().PlaybackStatus
    $info.NP_TITLE = [string]$p.Title; $info.NP_ARTIST = [string]$p.Artist; $info.NP_ALBUM = [string]$p.AlbumTitle
    $info.NP_SOURCE = Get-Source $s.SourceAppUserModelId
    $info.POS = '{0:0.0}' -f $tl.Position.TotalSeconds
    $info.POSAT = [string]$tl.LastUpdatedTime.ToUnixTimeSeconds()
    $info.DUR = '{0:0}' -f $tl.EndTime.TotalSeconds
  }
  $key = "$($info.NP_TITLE)|$($info.NP_ARTIST)"
  # a browser: which site (window titles; looked at again every 5 s)
  if ($Browsers.ContainsKey($info.NP_SOURCE)) {
    if ($key -ne $siteKey -or $now -ge $siteAt) { $site = Get-Site $info.NP_SOURCE $info.NP_TITLE; $siteKey = $key; $siteAt = $now.AddSeconds(5) }
    $info.NP_SOURCE = $site
  }

  if ($key -ne $shownKey) {
    if ($key -eq $candKey) { $candCount++ } else { $candKey = $key; $candCount = 1 }
    # a track that's playing is real: show it at once. The brief flips to another tab are always paused
    # ones, so only those have to stay put for ~1.5 s (and can't replace something that was just playing)
    $justPlaying = ($now - $playingAt).TotalSeconds -lt 4
    if ($null -eq $shownKey -or $info.STATUS -eq 'Playing' -or ($candCount -ge 3 -and -not $justPlaying)) {
      $shownKey = $key; $artPath = ''; $hiTried = ''; $hiOk = $false
      $thumbAt = $now.AddSeconds(2.5); $thumbTries = 3
      Get-ChildItem $Out -Filter 'art_*.png' | Remove-Item -Force
    }
  }
  if ($key -eq $shownKey) {
    $shown = $info
    if ($info.STATUS -eq 'Playing') { $playingAt = $now }
    if ($info.NP_TITLE -and $info.NP_ARTIST -and $hiTried -ne "$key|$($info.NP_ALBUM)") {
      $hiTried = "$key|$($info.NP_ALBUM)"
      $hi = Get-HiResArt $info.NP_TITLE $info.NP_ARTIST $info.NP_ALBUM
      if ($hi) { Save-NewArt $hi; $hiOk = $true }
    }
    if (-not $hiOk -and $thumbTries -gt 0 -and $now -ge $thumbAt -and $p -and $p.Thumbnail) {
      $thumbTries--; $thumbAt = $now.AddSeconds(1)
      Save-NewArt (Read-Thumb $p.Thumbnail)
    }
  }
  if ($shown) {
    $shown.NP_ART = $artPath
    $text = ($shown.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value -replace '[\r\n]+', ' ')" }) -join "`n"
    if ($text -ne $last) {
      $last = $text
      [IO.File]::WriteAllText("$Out\np.tmp", $text + "`n", $utf8)
      Move-Item "$Out\np.tmp" "$Out\np.txt" -Force
    }
  }
  Start-Sleep -Milliseconds 500
}
$mutex.ReleaseMutex()