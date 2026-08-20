# =========================================================================
# Compiles Info.ps1 into info.exe using the PS2EXE module.
# Run this on Windows, from this folder: .\Build-InfoExe.ps1
# =========================================================================

if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host "Installing ps2exe module (one-time)..." -ForegroundColor Cyan
    Install-Module -Name ps2exe -Scope CurrentUser -Force
}

Import-Module ps2exe

# Drawn directly instead of using SystemIcons.Information: that stock icon
# is a small, low-resolution bitmap that looks blurry/dated once Explorer
# or the taskbar scale it up. 256x256 with anti-aliasing looks sharp instead.
Add-Type -AssemblyName System.Drawing
$iconPath = "$PSScriptRoot\info.ico"
$size = 256
$bmp = New-Object System.Drawing.Bitmap($size, $size)
$g = [System.Drawing.Graphics]::FromImage($bmp)
try {
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $g.Clear([System.Drawing.Color]::Transparent)

    $blueBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(0, 120, 212))
    $g.FillEllipse($blueBrush, 4, 4, $size - 8, $size - 8)

    $font = New-Object System.Drawing.Font("Segoe UI", 150, [System.Drawing.FontStyle]::Bold)
    $textSize = $g.MeasureString("i", $font)
    $x = ($size - $textSize.Width) / 2
    $y = ($size - $textSize.Height) / 2
    $g.DrawString("i", $font, [System.Drawing.Brushes]::White, $x, $y)

    $hIcon = $bmp.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($hIcon)
    $iconStream = [System.IO.File]::Create($iconPath)
    try { $icon.Save($iconStream) } finally { $iconStream.Close() }
    $icon.Dispose()
}
finally {
    $g.Dispose()
    $bmp.Dispose()
}

Invoke-ps2exe `
    -inputFile "$PSScriptRoot\Info.ps1" `
    -outputFile "$PSScriptRoot\info.exe" `
    -noConsole `
    -iconFile $iconPath `
    -title "System Information" `
    -company "Minh Son AZ" `
    -version "1.0.0.0"

Write-Host "Built: $PSScriptRoot\info.exe" -ForegroundColor Green
