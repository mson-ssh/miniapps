# =========================================================================
# Compiles Info.ps1 into info.exe using the PS2EXE module.
# Run this on Windows, from this folder: .\Build-InfoExe.ps1
# =========================================================================

if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host "Installing ps2exe module (one-time)..." -ForegroundColor Cyan
    Install-Module -Name ps2exe -Scope CurrentUser -Force
}

Import-Module ps2exe

# Writes Windows' own "Information" stock icon out as a multi-size .ico.
# Mirrors New-InfoIcon in Setup.ps1 - kept in sync by hand. Nothing is
# downloaded, and every size is extracted natively so the icon stays sharp
# at whatever size Explorer, the taskbar or the Desktop asks for.
Add-Type -AssemblyName System.Drawing
$iconPath = "$PSScriptRoot\info.ico"

if (-not ("MiniAppStockIcon" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class MiniAppStockIcon {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct SHSTOCKICONINFO {
        public uint cbSize;
        public IntPtr hIcon;
        public int iSysImageIndex;
        public int iIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string szPath;
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern int SHGetStockIconInfo(uint siid, uint uFlags, ref SHSTOCKICONINFO psii);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int PrivateExtractIcons(string szFileName, int nIconIndex,
        int cxIcon, int cyIcon, IntPtr[] phicon, int[] piconid, int nIcons, uint flags);
    [DllImport("user32.dll")]
    public static extern bool DestroyIcon(IntPtr hIcon);
}
'@
}

$sii = New-Object MiniAppStockIcon+SHSTOCKICONINFO
$sii.cbSize = [uint32][Runtime.InteropServices.Marshal]::SizeOf([type]'MiniAppStockIcon+SHSTOCKICONINFO')
$hr = [MiniAppStockIcon]::SHGetStockIconInfo(79, 0, [ref]$sii)   # 79 = SIID_INFO
if ($hr -ne 0) { throw "SHGetStockIconInfo failed (HRESULT $hr)" }

$frames = New-Object System.Collections.Generic.List[object]
foreach ($size in @(256, 128, 64, 48, 32, 16)) {
    $hIcons = New-Object IntPtr[] 1
    $iconIds = New-Object int[] 1
    if ([MiniAppStockIcon]::PrivateExtractIcons($sii.szPath, $sii.iIcon, $size, $size, $hIcons, $iconIds, 1, 0) -le 0) { continue }
    if ($hIcons[0] -eq [IntPtr]::Zero) { continue }
    try {
        $icon = [System.Drawing.Icon]::FromHandle($hIcons[0])
        $bmp = $icon.ToBitmap()
        $ms = New-Object System.IO.MemoryStream
        try {
            $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
            [void]$frames.Add([pscustomobject]@{ Size = $size; Data = $ms.ToArray() })
        }
        finally { $ms.Dispose() }
        $bmp.Dispose(); $icon.Dispose()
    }
    finally { [void][MiniAppStockIcon]::DestroyIcon($hIcons[0]) }
}
if ($frames.Count -eq 0) { throw "Could not extract the Windows Information icon" }

$fs = [System.IO.File]::Create($iconPath)
$bw = New-Object System.IO.BinaryWriter($fs)
try {
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$frames.Count)
    $offset = 6 + (16 * $frames.Count)
    foreach ($f in $frames) {
        $dim = if ($f.Size -ge 256) { 0 } else { $f.Size }   # 256 stored as 0
        $bw.Write([byte]$dim); $bw.Write([byte]$dim)
        $bw.Write([byte]0); $bw.Write([byte]0)
        $bw.Write([uint16]1); $bw.Write([uint16]32)
        $bw.Write([uint32]$f.Data.Length); $bw.Write([uint32]$offset)
        $offset += $f.Data.Length
    }
    foreach ($f in $frames) { $bw.Write($f.Data) }
    $bw.Flush()
}
finally { $bw.Dispose(); $fs.Dispose() }

Write-Host "Icon: $($frames.Count) sizes from $($sii.szPath)" -ForegroundColor Gray

Invoke-ps2exe `
    -inputFile "$PSScriptRoot\Info.ps1" `
    -outputFile "$PSScriptRoot\info.exe" `
    -noConsole `
    -iconFile $iconPath `
    -title "System Information" `
    -company "Minh Son AZ" `
    -version "1.0.0.0"

Write-Host "Built: $PSScriptRoot\info.exe" -ForegroundColor Green
