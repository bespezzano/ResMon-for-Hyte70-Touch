# Builds the ResMon Rainmeter skin from the designs and installs it on the HYTE screen (the portrait monitor).
#   powershell -ExecutionPolicy Bypass -File install-skin.ps1
# Every design listed in pages.txt (or -Pages) becomes a page; swipe left/right to change page. Run it again after
# changing a design, pages.txt or the builder.
param(
    [string[]]$Pages,
    [string]$Size    # e.g. 682x2560: build for another screen size than this PC's Y70 (to test other Y70 models)
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$rmExe = 'C:\Program Files\Rainmeter\Rainmeter.exe'
$rmIni = "$env:APPDATA\Rainmeter\Rainmeter.ini"
$skinPath = ((Get-Content $rmIni | Select-String '^SkinPath=(.*)$' | Select-Object -First 1).Matches.Groups[1].Value)
if (-not $skinPath) { $skinPath = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Rainmeter\Skins\' }
$config = 'ResMon\Screen'

$lines = Get-Content "$root\pages.txt" | Where-Object { $_.Trim() -and -not $_.StartsWith('#') } | ForEach-Object { $_.Trim() }
if (-not $Pages) { $Pages = $lines | Where-Object { $_ -notmatch '^default\s*=' } }
# default=<design>: the page shown after installing and when Rainmeter starts (otherwise the first page)
$default = ($lines | Where-Object { $_ -match '^default\s*=' } | Select-Object -First 1) -replace '^default\s*=\s*', ''
if (-not $default -or $Pages -notcontains $default) { $default = $Pages[0] }

# Rainmeter is DPI-unaware, so it uses the same logical (scaled) coordinates as this DPI-unaware script
Add-Type -AssemblyName System.Windows.Forms
$t = [System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.Bounds.Height -gt $_.Bounds.Width } | Select-Object -First 1
if (-not $t) { $t = [System.Windows.Forms.Screen]::AllScreens | Where-Object { -not $_.Primary } | Select-Object -First 1 }

$designs = $Pages | ForEach-Object { "$root\screens\$_" }
$out = & python -I "$root\rainmeter\build_skin.py" @designs --size $(if ($Size) { $Size } else { "$($t.Bounds.Width)x$($t.Bounds.Height)" }) --default "$root\screens\$default"
if ($LASTEXITCODE) { throw 'Skin build failed' }
$out | Where-Object { $_ -notlike 'PAGES=*' } | Write-Host
$names = (($out | Where-Object { $_ -like 'PAGES=*' }) -replace '^PAGES=', '').Split(',')
$first = $names[[array]::IndexOf(@($Pages), $default)]

$running = [bool](Get-Process Rainmeter -ErrorAction SilentlyContinue)
# unload ResMon skins (also the older single-page ResMon\PortraitDark), then replace the files
if ($running) {
    Get-ChildItem (Join-Path $skinPath 'ResMon') -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { & $rmExe !DeactivateConfig "ResMon\$($_.Name)" }
    Start-Sleep 1
}
$dest = Join-Path $skinPath 'ResMon'
Get-Process npwatch -ErrorAction SilentlyContinue | Stop-Process -Force   # the music watcher locks its .exe
if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item "$root\rainmeter\ResMon\Screen" (Join-Path $dest 'Screen') -Recurse
Copy-Item "$root\rainmeter\ResMon\@Resources" (Join-Path $dest '@Resources') -Recurse   # shared scripts (place.lua)
# the page background, in its own config underneath the pages (stays loaded while pages change)
if (Test-Path "$root\rainmeter\ResMon\Backdrop") { Copy-Item "$root\rainmeter\ResMon\Backdrop" (Join-Path $dest 'Backdrop') -Recurse }

if (-not $running) { Start-Process $rmExe; Start-Sleep 4 }
& $rmExe !RefreshApp; Start-Sleep 3

# load the backdrop and the first page; each puts itself on the Y70 screen (rainmeter/place.lua)
if (Test-Path (Join-Path $dest 'Backdrop')) { & $rmExe !ActivateConfig 'ResMon\Backdrop' 'Backdrop.ini'; Start-Sleep 1 }
& $rmExe !ActivateConfig $config "$first.ini"; Start-Sleep 2
Write-Host "Rainmeter skin $config ($($Pages.Count) pages) built for $(if ($Size) { $Size } else { "$($t.DeviceName), $($t.Bounds.Width)x$($t.Bounds.Height)" })"
