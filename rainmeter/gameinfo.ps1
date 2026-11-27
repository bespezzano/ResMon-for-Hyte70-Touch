# gameinfo.ps1: looks up the running game for the gaming page and writes <Out>\info.txt (KEY=value lines).
# Steam games (matched by install folder): name, playtime and last-two-weeks playtime from Steam's local
# config, banner and logo from Steam's local library cache. Other games: name from the exe's version info.
# A game that isn't in this PC's Steam library gets its banner from the Steam store (looked up by name, exact
# matches only, cached in %LOCALAPPDATA%\ResMon\art); everything else is read from disk. Run by the skin
# (game.lua) when a game is detected.
param(
  [Parameter(Mandatory)] [string]$Exe,
  [Parameter(Mandatory)] [string]$Out,
  [string]$Hero = '952x330',
  [string]$Logo = '440x200',
  [string]$Art = ''   # folder with your own pictures for games (see the end of this script)
)
$ErrorActionPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Drawing
New-Item -ItemType Directory -Force $Out | Out-Null

function Format-Hours([double]$min) {
  if ($min -le 0) { return '0 h' }
  $h = $min / 60
  if ($h -lt 10) { return ('{0:0.0} h' -f $h) }
  return ('{0:N0} h' -f [math]::Round($h))
}
function Clean([string]$s) { ($s -replace '[™®©]', '').Trim() }

# Crops (cover) or fits (contain, anchored bottom-left) an image into an exact WxH PNG. With -Whole, a cover image
# is shown uncropped and centred over a dimmed, cropped copy of itself (for art with a title that mustn't be cut).
function Save-Image([string]$src, [string]$dst, [string]$size, [bool]$cover, [switch]$Whole) {
  $w, $h = $size -split 'x' | ForEach-Object { [int]$_ }
  $img = [System.Drawing.Image]::FromFile($src)
  try {
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = 'HighQualityBicubic'; $g.SmoothingMode = 'HighQuality'; $g.PixelOffsetMode = 'HighQuality'
    $g.Clear([System.Drawing.Color]::Transparent)
    if ($cover) {
      $s = [math]::Max($w / $img.Width, $h / $img.Height)
      $dw = $img.Width * $s; $dh = $img.Height * $s
      # rounded corners (radius ~5.5 % of the height, matching the frame drawn in the design)
      $r = [math]::Max(2, [int]($h * 0.055)) * 2
      $path = New-Object System.Drawing.Drawing2D.GraphicsPath
      $path.AddArc(0, 0, $r, $r, 180, 90); $path.AddArc($w - $r - 1, 0, $r, $r, 270, 90)
      $path.AddArc($w - $r - 1, $h - $r - 1, $r, $r, 0, 90); $path.AddArc(0, $h - $r - 1, $r, $r, 90, 90); $path.CloseFigure()
      $tex = New-Object System.Drawing.Bitmap $w, $h
      $tg = [System.Drawing.Graphics]::FromImage($tex); $tg.InterpolationMode = 'HighQualityBicubic'; $tg.PixelOffsetMode = 'HighQuality'
      $tg.DrawImage($img, [single](($w - $dw) / 2), [single](($h - $dh) / 2), [single]$dw, [single]$dh)
      if ($Whole) {
        $tg.FillRectangle((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(170, 8, 10, 18))), 0, 0, $w, $h)
        $fs = [math]::Min($w / $img.Width, $h / $img.Height); $fw = $img.Width * $fs; $fh = $img.Height * $fs
        $tg.DrawImage($img, [single](($w - $fw) / 2), [single](($h - $fh) / 2), [single]$fw, [single]$fh)
      }
      $tg.Dispose()
      $g.SmoothingMode = 'AntiAlias'
      $g.FillPath((New-Object System.Drawing.TextureBrush $tex), $path); $tex.Dispose()
    } else {
      $s = [math]::Min($w / $img.Width, $h / $img.Height)
      $dw = $img.Width * $s; $dh = $img.Height * $s
      $g.DrawImage($img, [single]0, [single]($h - $dh), [single]$dw, [single]$dh)
    }
    $g.Dispose(); $bmp.Save($dst, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    return $true
  } finally { $img.Dispose() }
}

# Windows hides the path of a game that runs as administrator from Get-Process (.Path is empty), but still gives
# it to QueryFullProcessImageName with limited query rights.
Add-Type -Namespace ResMon -Name Proc -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern System.IntPtr OpenProcess(uint access, bool inherit, int pid);
[DllImport("kernel32.dll")] public static extern bool CloseHandle(System.IntPtr h);
[DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern bool QueryFullProcessImageName(System.IntPtr h, int flags, System.Text.StringBuilder name, ref int size);
'@
function Get-ExePath($p) {
  if ($p.Path) { return $p.Path }
  $h = [ResMon.Proc]::OpenProcess(0x1000, $false, $p.Id)
  if ($h -eq [IntPtr]::Zero) { return $null }
  try { $sb = New-Object System.Text.StringBuilder 1024; $n = 1024
        if ([ResMon.Proc]::QueryFullProcessImageName($h, 0, $sb, [ref]$n)) { return $sb.ToString() } }
  finally { [void][ResMon.Proc]::CloseHandle($h) }
  return $null
}

# Artwork from the Steam store for a game that isn't in this PC's Steam library (bought elsewhere, or a standalone
# install): the store's search finds it by name, and only an exact name match is used. Like a Steam library game
# it gets the store's banner (library_hero) with the game's logo on top; the banners are drawn for a logo to sit
# on and often show nothing recognisable alone. When the store has no logo, the header image (which has the title
# in it) is used instead. Downloads are kept in %LOCALAPPDATA%\ResMon\art, so each game is fetched once.
# Returns @{ Hero; Logo; Whole } (Whole: show the hero uncropped), or $null.
function Get-StoreArt([string]$name) {
  $cache = Join-Path $env:LOCALAPPDATA 'ResMon\art'
  New-Item -ItemType Directory -Force $cache | Out-Null
  $norm = { param($s) ($s.ToLower() -replace '[^a-z0-9]', '') }
  $key = & $norm $name
  if (-not $key) { return $null }
  function Get-File([string[]]$urls, [string]$dst) {
    if (Test-Path $dst) { return $dst }
    foreach ($u in $urls) {
      try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 15 $u -OutFile $dst; if ((Get-Item $dst).Length -gt 1000) { return $dst } } catch { }
    }
    Remove-Item $dst -Force -ErrorAction SilentlyContinue; return $null
  }
  # the app id: from an earlier download, or the store's search
  $hit = Get-ChildItem $cache -Filter "$key-*" | Select-Object -First 1
  if ($hit) { $id = ($hit.BaseName -split '-')[1] }
  else {
    $r = Invoke-RestMethod -TimeoutSec 10 ('https://store.steampowered.com/api/storesearch/?cc=US&l=english&term=' + [uri]::EscapeDataString($name))
    $item = $r.items | Where-Object { (& $norm $_.name) -eq $key } | Select-Object -First 1
    if (-not $item) { return $null }
    $id = $item.id
  }
  $cdn = "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/$id"
  $logo = $null
  if (-not (Test-Path "$cache\$key-$id.nologo")) {
    $logo = Get-File @("$cdn/logo_2x.png", "$cdn/logo.png") "$cache\$key-$id-logo.png"
    if (-not $logo) { New-Item -ItemType File "$cache\$key-$id.nologo" | Out-Null }
  }
  if ($logo) {
    $hero = Get-File @("$cdn/library_hero.jpg") "$cache\$key-$id.jpg"
    if ($hero) { return @{ Hero = $hero; Logo = $logo; Whole = $false } }
  }
  $urls = @("$cdn/header_2x.jpg")
  try { $d = Invoke-RestMethod -TimeoutSec 10 "https://store.steampowered.com/api/appdetails?appids=$id&filters=basic"
        if ($d."$id".data.header_image) { $urls += $d."$id".data.header_image } } catch { }
  $hdr = Get-File $urls "$cache\$key-$id-header.jpg"
  if ($hdr) { return @{ Hero = $hdr; Logo = $null; Whole = $true } }
  $hero = Get-File @("$cdn/library_hero.jpg") "$cache\$key-$id.jpg"
  if ($hero) { return @{ Hero = $hero; Logo = $null; Whole = $false } }
  return $null
}

$base = [IO.Path]::GetFileNameWithoutExtension($Exe)
$steam = (Get-ItemProperty HKCU:\Software\Valve\Steam).SteamPath
# A game that has only just started may not be readable yet (no exe path, so no version info and no Steam
# folder match): the skin looks it up a few seconds after launch. While its path is unknown and it started under
# a minute ago, look again every 5 seconds.
for ($try = 0; $try -lt 12; $try++) {
$proc = Get-Process -Name $base | Sort-Object StartTime | Select-Object -First 1
$exePath = if ($proc) { Get-ExePath $proc }
$info = [ordered]@{
  GAME_NAME = $base; GAME_TOTAL = '--'; GAME_RECENT = '--'; GAME_SOURCE = ''
  GAME_ACH = '--'; GAME_ACH_PCT = '0'; GAME_ACH_NEXT = ''
  GAME_HERO = ''; GAME_LOGO = ''; GAME_START = ''
}
if ($proc) {
  $info.GAME_START = [string][DateTimeOffset]::new($proc.StartTime).ToUnixTimeSeconds()
  $n = $null
  if ($exePath) {
    $vi = [Diagnostics.FileVersionInfo]::GetVersionInfo($exePath)
    $n = @($vi.ProductName, $vi.FileDescription) | Where-Object { $_ -and $_.Trim() } | Select-Object -First 1
    # a product name that's only the initials of the description ("KSA" / "Kitten Space Agency"): the full name
    $d = "$($vi.FileDescription)".Trim()
    $initials = -join ($d -split '\s+' | Where-Object { $_ } | ForEach-Object { $_[0] })
    if ($n -and $d -match '\s' -and $n.Trim() -eq $initials) { $n = $d }
  }
  # no version info: the exe's own file name, which keeps its capitals ("Heaven Does Not Respond")
  if (-not $n -and $exePath) { $n = [IO.Path]::GetFileNameWithoutExtension($exePath) }
  if ($n) { $info.GAME_NAME = Clean $n }
}

$appid = $null
if ($steam -and $exePath) {
  $steam = $steam -replace '/', '\'
  $libs = @($steam) + @(Select-String -Path "$steam\steamapps\libraryfolders.vdf" -Pattern '"path"\s+"([^"]+)"' |
    ForEach-Object { $_.Matches[0].Groups[1].Value -replace '\\\\', '\' })
  $path = $exePath.ToLower()
  foreach ($lib in ($libs | Select-Object -Unique)) {
    foreach ($m in Get-ChildItem "$lib\steamapps\appmanifest_*.acf") {
      $t = [IO.File]::ReadAllText($m.FullName, [Text.Encoding]::UTF8)
      if ($t -match '"installdir"\s+"([^"]+)"') {
        $dir = ("$lib\steamapps\common\" + $matches[1] + '\').ToLower()
        if ($path.StartsWith($dir)) {
          $appid = $m.BaseName -replace 'appmanifest_'
          if ($t -match '"name"\s+"([^"]+)"') { $info.GAME_NAME = Clean $matches[1] }
          break
        }
      }
    }
    if ($appid) { break }
  }
}
$young = if ($proc) { ((Get-Date) - $proc.StartTime).TotalSeconds -lt 60 } else { $try -lt 2 }
# once the exe's path is known there's nothing more to wait for (a game outside Steam gets its name from the exe)
if ($appid -or $exePath -or -not $young) { break }
Start-Sleep -Seconds 5
}

if ($appid) {
  $info.GAME_SOURCE = 'Steam'
  # playtime: the Steam account on this PC that played the game most recently
  $best = $null
  foreach ($cfg in Get-ChildItem "$steam\userdata\*\config\localconfig.vdf") {
    $t = [IO.File]::ReadAllText($cfg.FullName)
    $m = [regex]::Match($t, '"' + $appid + '"\s*\{((?:[^{}]|\{[^{}]*\})*)\}')
    if (-not $m.Success) { continue }
    $b = $m.Groups[1].Value
    $e = @{
      last = [long]([regex]::Match($b, '"LastPlayed"\s+"(\d+)"').Groups[1].Value + '0') / 10
      total = [double]([regex]::Match($b, '"Playtime"\s+"(\d+)"').Groups[1].Value + '0') / 10
      recent = [double]([regex]::Match($b, '"Playtime2wks"\s+"(\d+)"').Groups[1].Value + '0') / 10
    }
    $e.dir = $cfg.Directory.FullName
    if (-not $best -or $e.last -gt $best.last) { $best = $e }
  }
  if ($best) { $info.GAME_TOTAL = Format-Hours $best.total; $info.GAME_RECENT = Format-Hours $best.recent }

  # achievements: the Steam library's per-game cache (userdata\<id>\config\librarycache\<appid>.json)
  $info.GAME_ACH = '--'; $info.GAME_ACH_NEXT = ''
  if ($best) {
    $j = Get-Content "$($best.dir)\librarycache\$appid.json" -Raw | ConvertFrom-Json
    $a = $null; foreach ($entry in $j) { if ($entry[0] -eq 'achievements') { $a = $entry[1].data } }
    if ($a -and [int]$a.nTotal -gt 0) {
      $info.GAME_ACH = "$($a.nAchieved) / $($a.nTotal)"
      $info.GAME_ACH_PCT = [string][math]::Round(100 * [int]$a.nAchieved / [int]$a.nTotal, 1)
      # locked achievements come sorted by how many players have them: the first is the likeliest next one
      $next = $null; foreach ($x in $a.vecUnachieved) { if (-not $next -and -not $x.bHidden) { $next = $x } }
      if ([int]$a.nAchieved -ge [int]$a.nTotal) { $info.GAME_ACH_NEXT = 'All achievements unlocked' }
      elseif ($next) { $info.GAME_ACH_NEXT = 'Next: {0}  ({1:0}% of players have it)' -f (Clean $next.strName), [double]$next.flAchieved }
    } elseif ($a) { $info.GAME_ACH = 'None'; $info.GAME_ACH_NEXT = 'No Steam achievements in this game' }
  }

  # images: librarycache\<appid>\...\name (current Steam) or librarycache\<appid>_name (older Steam)
  $lc = "$steam\appcache\librarycache"
  function Find-Art([string[]]$names) {
    foreach ($n in $names) {
      $f = Get-ChildItem "$lc\$appid" -Recurse -Filter $n | Sort-Object Length -Descending | Select-Object -First 1
      if ($f) { return $f.FullName }
      if (Test-Path "$lc\${appid}_$n") { return "$lc\${appid}_$n" }
    }
  }
  Get-ChildItem $Out -Filter 'art_*.png' | Remove-Item -Force
  $hsrc = Find-Art @('library_hero.jpg', 'library_header.jpg', 'header.jpg', 'library_capsule.jpg')
  if ($hsrc -and (Save-Image $hsrc "$Out\art_${appid}_hero.png" $Hero $true)) { $info.GAME_HERO = "$Out\art_${appid}_hero.png" }
  $lsrc = Find-Art @('logo.png')
  if ($lsrc -and (Save-Image $lsrc "$Out\art_${appid}_logo.png" $Logo $false)) { $info.GAME_LOGO = "$Out\art_${appid}_logo.png" }
}

# not in this PC's Steam library, or no banner there: the Steam store's art, if the store has the game
# your own pictures win over everything: <Art>\<exe name>.jpg|.png (banner) and <exe name>-logo.png
$mine = if ($Art) { @('jpg', 'jpeg', 'png', 'bmp') | ForEach-Object { "$Art\$base.$_" } | Where-Object { Test-Path $_ } | Select-Object -First 1 }
if ($mine) {
  Get-ChildItem $Out -Filter 'art_*.png' | Remove-Item -Force
  $stem = "$Out\art_mine_" + ($base -replace '[^\w-]', '_')
  $info.GAME_HERO = ''; $info.GAME_LOGO = ''
  if (Save-Image $mine "${stem}_hero.png" $Hero $true) { $info.GAME_HERO = "${stem}_hero.png" }
  if ((Test-Path "$Art\$base-logo.png") -and (Save-Image "$Art\$base-logo.png" "${stem}_logo.png" $Logo $false)) { $info.GAME_LOGO = "${stem}_logo.png" }
}

if (-not $info.GAME_HERO -and $info.GAME_NAME) {
  # the full name first, then the exe's own product name if that's different
  # ($store, not $art: PowerShell names ignore case, and $Art is the folder parameter)
  $store = $null
  foreach ($nm in @($info.GAME_NAME, "$($vi.ProductName)".Trim()) | Where-Object { $_ } | Select-Object -Unique) {
    if (-not $store) { $store = Get-StoreArt $nm }
  }
  if ($store) {
    Get-ChildItem $Out -Filter 'art_*.png' | Remove-Item -Force
    $stem = "$Out\art_" + [IO.Path]::GetFileNameWithoutExtension($store.Hero)
    if (Save-Image $store.Hero "${stem}_hero.png" $Hero $true -Whole:$store.Whole) { $info.GAME_HERO = "${stem}_hero.png" }
    if ($store.Logo -and (Save-Image $store.Logo "${stem}_logo.png" $Logo $false)) { $info.GAME_LOGO = "${stem}_logo.png" }
  }
}

$lines = $info.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }
[IO.File]::WriteAllLines("$Out\info.tmp", [string[]]$lines, (New-Object System.Text.UTF8Encoding $false))
Move-Item "$Out\info.tmp" "$Out\info.txt" -Force
