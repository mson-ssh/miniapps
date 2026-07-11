# ================================================================================
#                    MINIAZ HARDWARE INFORMATION SCRIPT (PS1)
#                    Compatible with Windows 10 / Windows 11
# ================================================================================
# Purpose:
# - Extract clean hardware specs: Model, Serial, CPU, RAM, Disk, GPU, Display.
# - Output report to Desktop\info.txt.
# - Compatible with WinRAR SFX silent pipeline without hanging process trees.
# ================================================================================

param(
    [switch]$Silent
)

# ----------------------------- CONFIGURATION ------------------------------------
$DesktopPath = [Environment]::GetFolderPath("Desktop")
$LogFile     = "$DesktopPath\info.txt"

# ----------------------------- SILENT MODE --------------------------------------
if (-not $Silent) {
    $argList = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Silent"
    Start-Process -FilePath "powershell.exe" -ArgumentList $argList -WindowStyle Hidden -Wait
    exit $LASTEXITCODE
}

# ----------------------------- ADMIN CHECK --------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    # If called from SFX with Admin rights, this will never trigger
    exit 10
}

# Suppress notifications
try {
    $notifPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings"
    if (-not (Test-Path $notifPath)) { New-Item -Path $notifPath -Force | Out-Null }
    New-ItemProperty -Path $notifPath -Name "NOC_GLOBAL_SETTING_ALLOW_NOTIFICATION_SOUND" -Value 0 -PropertyType DWord -Force | Out-Null
} catch {}

# ----------------------------- GATHER HARDWARE INFO -----------------------------
$computer = Get-CimInstance Win32_ComputerSystem
$bios     = Get-CimInstance Win32_BIOS
$cpu      = Get-CimInstance Win32_Processor | Select-Object -First 1
$ram      = Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum
$disks    = Get-CimInstance Win32_DiskDrive | Where-Object { $_.MediaType -eq 'Fixed hard disk media' }
$gpus     = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notlike '*Basic*' -and $_.Name -notlike '*Standard*' }

$ramGB    = [math]::Round($ram.Sum / 1GB, 2)
$currentTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

# Display Resolution & Refresh Rate
try {
    $videoController = Get-CimInstance Win32_VideoController | Where-Object { $_.CurrentHorizontalResolution -and $_.CurrentVerticalResolution } | Select-Object -First 1
    if ($videoController) {
        $screenRes   = "$($videoController.CurrentHorizontalResolution)x$($videoController.CurrentVerticalResolution)"
        $refreshRate = if ($videoController.CurrentRefreshRate) { "$($videoController.CurrentRefreshRate) Hz" } else { "N/A" }
    } else {
        $screenRes = "N/A"; $refreshRate = "N/A"
    }
} catch {
    $screenRes = "N/A"; $refreshRate = "N/A"
}

# ----------------------------- BUILD REPORT -------------------------------------
$report = @(
    "================================================================"
    "                   MINIAZ SYSTEM INFORMATION"
    "================================================================"
    "HOSTNAME       : $($computer.Name)"
    "Model          : $($computer.Model)"
    "Serial         : $($bios.SerialNumber)"
    "CPU            : $($cpu.Name)"
    "RAM            : $ramGB GB"
)

foreach ($disk in $disks) {
    if ($disk.Size) {
        $diskGB = [math]::Round($disk.Size / 1GB, 2)
        $report += "Storage        : $($disk.Model) - $diskGB GB"
    }
}

foreach ($gpu in $gpus) {
    $report += "Graphics Card  : $($gpu.Name)"
}

$report += @(
    "Resolution     : $screenRes"
    "Refresh Rate   : $refreshRate"
    "DATE AND TIME  : $currentTime"
    "================================================================"
    "[PROCESS] COMPLETED SUCCESSFULLY"
)

# Write to file with UTF8 encoding
$report | Out-File -FilePath $LogFile -Encoding UTF8 -Force

# ----------------------------- SAFE OPEN IN SILENT MODE -------------------------
# Launch Notepad decoupled from the current process tree so SFX can finish immediately
Start-Process -FilePath "notepad.exe" -ArgumentList "`"$LogFile`"" -WindowStyle Normal

exit 0