# =========================================================================
# Compiles Info.ps1 into info.exe using the PS2EXE module.
# Run this on Windows, from this folder: .\Build-InfoExe.ps1
# =========================================================================

if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host "Installing ps2exe module (one-time)..." -ForegroundColor Cyan
    Install-Module -Name ps2exe -Scope CurrentUser -Force
}

Import-Module ps2exe

# Downloads the minimalist "i" PNG (2831x2831, transparent, from Wikimedia
# Commons) and converts it to .ico. Downscaled to 256 with high-quality
# bicubic + anti-aliasing rather than used at full size: ICO doesn't handle
# arbitrarily large frames well, and shrinking from a much bigger source
# still looks sharp - the opposite of upscaling a small one.
Add-Type -AssemblyName System.Drawing
$iconUrl = "https://upload.wikimedia.org/wikipedia/commons/4/43/Minimalist_info_Icon.png"
$pngPath = "$PSScriptRoot\info-icon.png"
$iconPath = "$PSScriptRoot\info.ico"

Invoke-WebRequest -Uri $iconUrl -OutFile $pngPath -UseBasicParsing

$source = [System.Drawing.Bitmap]::FromFile($pngPath)
try {
    $size = 256
    $resized = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($resized)
    try {
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.DrawImage($source, 0, 0, $size, $size)
    }
    finally { $g.Dispose() }

    $hIcon = $resized.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($hIcon)
    $iconStream = [System.IO.File]::Create($iconPath)
    try { $icon.Save($iconStream) } finally { $iconStream.Close() }
    $icon.Dispose()
    $resized.Dispose()
}
finally {
    $source.Dispose()
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
