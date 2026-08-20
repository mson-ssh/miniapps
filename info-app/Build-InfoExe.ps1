# =========================================================================
# Compiles Info.ps1 into info.exe using the PS2EXE module.
# Run this on Windows, from this folder: .\Build-InfoExe.ps1
# =========================================================================

if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host "Installing ps2exe module (one-time)..." -ForegroundColor Cyan
    Install-Module -Name ps2exe -Scope CurrentUser -Force
}

Import-Module ps2exe

# Windows' own stock "information" icon (blue circle, white "i") - the same
# one MessageBox uses - so nothing needs to ship as a binary image asset.
Add-Type -AssemblyName System.Drawing
$iconPath = "$PSScriptRoot\info.ico"
$iconStream = [System.IO.File]::Create($iconPath)
[System.Drawing.SystemIcons]::Information.Save($iconStream)
$iconStream.Close()

Invoke-ps2exe `
    -inputFile "$PSScriptRoot\Info.ps1" `
    -outputFile "$PSScriptRoot\info.exe" `
    -noConsole `
    -iconFile $iconPath `
    -title "System Information" `
    -company "Minh Son AZ" `
    -version "1.0.0.0"

Write-Host "Built: $PSScriptRoot\info.exe" -ForegroundColor Green
