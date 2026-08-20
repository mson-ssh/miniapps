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

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = "Fill"
$grid.ReadOnly = $true
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.AllowUserToResizeRows = $false
$grid.AllowUserToResizeColumns = $false
$grid.RowHeadersVisible = $false
$grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$grid.BackgroundColor = [System.Drawing.Color]::White
$grid.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$grid.CellBorderStyle = [System.Windows.Forms.DataGridViewCellBorderStyle]::Single
$grid.GridColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
$grid.EnableHeadersVisualStyles = $false
$grid.ColumnHeadersHeightSizeMode = [System.Windows.Forms.DataGridViewColumnHeadersHeightSizeMode]::AutoSize
$grid.AutoSizeRowsMode = [System.Windows.Forms.DataGridViewAutoSizeRowsMode]::AllCells
$grid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(240, 240, 240)
$grid.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$grid.DefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$grid.DefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(4)
$grid.DefaultCellStyle.WrapMode = [System.Windows.Forms.DataGridViewTriState]::True

[void]$grid.Columns.Add("Property", "Property")
[void]$grid.Columns.Add("Value", "Value")
$grid.Columns["Property"].Width = 160
$grid.Columns["Property"].DefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$grid.Columns["Value"].AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill

foreach ($row in $rows) {
    [void]$grid.Rows.Add($row.Label, $row.Value)
}

$form.Controls.Add($grid)
[void]$form.ShowDialog()
