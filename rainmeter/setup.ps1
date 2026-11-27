# setup.ps1: first run of an installed ResMon package (run by the starter skin, ResMon\Start).
# Copies the package's starting files (settings, weather places, game lists) into ResMon's data folder,
# %APPDATA%\Rainmeter\ResMon, without replacing any that are already there: your settings survive updates.
param(
  [Parameter(Mandatory)] [string]$From,   # the package's starting files (ResMon\@Resources\defaults)
  [Parameter(Mandatory)] [string]$To      # ResMon's data folder
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $To | Out-Null
# your own game pictures (see gameinfo.ps1): <exe name>.jpg / .png and <exe name>-logo.png
New-Item -ItemType Directory -Force (Join-Path $To 'game-art') | Out-Null
Get-ChildItem $From -File | ForEach-Object {
  $dest = Join-Path $To $_.Name
  if (-not (Test-Path $dest)) { Copy-Item $_.FullName $dest }
}
