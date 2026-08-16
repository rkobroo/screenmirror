# Unblocks MirrorLink files downloaded from the web.
#
# Windows flags downloaded files with a hidden "Mark of the Web" (Zone.Identifier).
# SmartScreen / Smart App Control then refuse to run the unsigned EXE. This script
# removes that flag from the release zip and everything inside it.
#
# Usage:
#   Right-click the script -> Run with PowerShell
#   OR  powershell -ExecutionPolicy Bypass -File .\Unblock-MirrorLink.ps1
#
# You can also do it by hand:
#   Right-click MirrorLink-Windows.zip -> Properties -> check "Unblock" -> OK,
#   then re-extract the archive.

$ErrorActionPreference = 'Stop'

$targets = @()
if (Test-Path '.\MirrorLink-Windows.zip') {
    $targets += Get-Item '.\MirrorLink-Windows.zip'
}
if (Test-Path '.\MirrorLink') {
    $targets += Get-ChildItem -Path '.\MirrorLink' -Recurse -File
}
if (Test-Path '.\mirrorlink_windows.exe') {
    $targets += Get-Item '.\mirrorlink_windows.exe'
}

if ($targets.Count -eq 0) {
    Write-Host 'No MirrorLink files found in this folder.'
    Write-Host 'Put this script next to the downloaded MirrorLink-Windows.zip and run it again.'
    exit 1
}

foreach ($file in $targets) {
    try {
        Unblock-File -LiteralPath $file.FullName
        Write-Host "Unblocked $($file.Name)"
    } catch {
        Write-Warning "Could not unblock $($file.FullName): $($_.Exception.Message)"
    }
}

Write-Host ''
Write-Host 'Done. Delete the old extract, re-extract the zip, and unpin/repin MirrorLink from the taskbar.'

# Also clear the Zone.Identifier on any running-install folder the user may have made.
$installDir = Join-Path $env:LOCALAPPDATA 'Programs\MirrorLink'
if (Test-Path $installDir) {
    Get-ChildItem -Path $installDir -Recurse -File -ErrorAction SilentlyContinue |
        ForEach-Object { Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue }
    Write-Host "Unblocked files under $installDir"
}
