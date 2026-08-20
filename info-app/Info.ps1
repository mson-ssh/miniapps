# =========================================================================
# MINIAZ SYSTEM INFORMATION APP
# =========================================================================
# Standalone, isolated prototype for the "info.exe" feature - a GUI window
# showing the same hardware specs Setup.ps1's Get-HardwareInfo writes to
# Desktop\info.txt, presented in a window instead of a text file.
#
# This file is NOT wired into Setup.ps1 or config/ in any way. Run it
# directly to preview the GUI, or compile it with Build-InfoExe.ps1 once
# the layout/content looks right. See README.md in this folder.
# =========================================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ----------------------------- COLLECT DATA --------------------------------
# Same CIM queries as Setup.ps1's Get-HardwareInfo, kept in sync by hand -
# this file has no dependency on Setup.ps1 and does not read it.
$computer = Get-CimInstance Win32_ComputerSystem
$bios     = Get-CimInstance Win32_BIOS
$cpu      = Get-CimInstance Win32_Processor | Select-Object -First 1
$ram      = Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum
$disks    = Get-CimInstance Win32_DiskDrive | Where-Object { $_.MediaType -eq 'Fixed hard disk media' }
$gpus     = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notlike '*Basic*' -and $_.Name -notlike '*Standard*' }

$ramGB = [math]::Round($ram.Sum / 1GB, 2)
$currentTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

try {
    $videoController = Get-CimInstance Win32_VideoController | Where-Object { $_.CurrentHorizontalResolution -and $_.CurrentVerticalResolution } | Select-Object -First 1
    if ($videoController) {
        $screenRes = "$($videoController.CurrentHorizontalResolution)x$($videoController.CurrentVerticalResolution)"
        $refreshRate = if ($videoController.CurrentRefreshRate) { "$($videoController.CurrentRefreshRate) Hz" } else { "N/A" }
    }
    else { $screenRes = "N/A"; $refreshRate = "N/A" }
}
catch { $screenRes = "N/A"; $refreshRate = "N/A" }

$storageText = ($disks | Where-Object { $_.Size } | ForEach-Object {
    "$($_.Model) - $([math]::Round($_.Size / 1GB, 2)) GB"
}) -join "`r`n"
if (-not $storageText) { $storageText = "N/A" }

$gpuText = ($gpus | ForEach-Object { $_.Name }) -join "`r`n"
if (-not $gpuText) { $gpuText = "N/A" }

$rows = @(
    @{ Label = "Hostname";      Value = "$($computer.Name)" }
    @{ Label = "Model";         Value = "$($computer.Model)" }
    @{ Label = "Serial";        Value = "$($bios.SerialNumber)" }
    @{ Label = "CPU";           Value = "$($cpu.Name)" }
    @{ Label = "RAM";           Value = "$ramGB GB" }
    @{ Label = "Storage";       Value = $storageText }
    @{ Label = "Graphics Card"; Value = $gpuText }
    @{ Label = "Resolution";    Value = $screenRes }
    @{ Label = "Refresh Rate";  Value = $refreshRate }
    @{ Label = "Date and Time"; Value = $currentTime }
)

# ----------------------------- BUILD WINDOW --------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "MiniAZ System Information"
$form.Size = New-Object System.Drawing.Size(560, 520)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.BackColor = [System.Drawing.Color]::White
$form.Font = New-Object System.Drawing.Font("Segoe UI", 10)

$panel = New-Object System.Windows.Forms.TableLayoutPanel
$panel.Dock = "Fill"
$panel.ColumnCount = 2
$panel.AutoScroll = $true
$panel.Padding = New-Object System.Windows.Forms.Padding(20)
[void]$panel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 32)))
[void]$panel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 68)))

$boldFont = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)

foreach ($row in $rows) {
    $lblKey = New-Object System.Windows.Forms.Label
    $lblKey.Text = $row.Label
    $lblKey.Font = $boldFont
    $lblKey.AutoSize = $true
    $lblKey.Margin = New-Object System.Windows.Forms.Padding(0, 6, 12, 6)

    $lblVal = New-Object System.Windows.Forms.Label
    $lblVal.Text = $row.Value
    $lblVal.AutoSize = $true
    $lblVal.MaximumSize = New-Object System.Drawing.Size(340, 0)
    $lblVal.Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 6)

    [void]$panel.Controls.Add($lblKey)
    [void]$panel.Controls.Add($lblVal)
}

$form.Controls.Add($panel)
[void]$form.ShowDialog()
