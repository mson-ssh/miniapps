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
$computer   = Get-CimInstance Win32_ComputerSystem
$bios       = Get-CimInstance Win32_BIOS
$cpu        = Get-CimInstance Win32_Processor | Select-Object -First 1
$ramModules = @(Get-CimInstance Win32_PhysicalMemory | Where-Object { $_.Capacity })
$disks      = Get-CimInstance Win32_DiskDrive | Where-Object { $_.MediaType -eq 'Fixed hard disk media' }
$gpus       = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notlike '*Basic*' -and $_.Name -notlike '*Standard*' }

$currentTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

# RAM: total + type + speed on one line, then one "Slot N: manufacturer,
# capacity, bus speed" line per physical stick. Soldered/onboard RAM often
# isn't enumerated per-stick by WMI - $ramModules is just empty then, so
# the loop below naturally adds no slot lines and only the summary shows.
# Rounded to the nearest whole GB: TotalPhysicalMemory reports slightly
# under the nominal size (memory reserved for hardware), e.g. 15.75 for a
# 16GB stick - real RAM only ever comes in whole-GB sizes.
$ramTotalGB = [math]::Round($computer.TotalPhysicalMemory / 1GB, 0)
$memTypeMap = @{
    20 = "DDR"; 21 = "DDR2"; 22 = "DDR2 FB-DIMM"; 24 = "DDR3"
    26 = "DDR4"; 27 = "LPDDR"; 28 = "LPDDR2"; 29 = "LPDDR3"; 30 = "LPDDR4"
    34 = "DDR5"; 35 = "LPDDR5"
}
$firstModule = $ramModules | Select-Object -First 1
$ramType = if ($firstModule -and $memTypeMap.ContainsKey([int]$firstModule.SMBIOSMemoryType)) {
    $memTypeMap[[int]$firstModule.SMBIOSMemoryType]
} else { "" }
$ramSpeed = if ($firstModule -and $firstModule.Speed) { "$($firstModule.Speed)MHz" } else { "" }

$ramLines = [System.Collections.Generic.List[string]]::new()
$ramLines.Add((("$ramTotalGB GB $ramType $ramSpeed").Trim() -replace '\s{2,}', ' '))
for ($i = 0; $i -lt $ramModules.Count; $i++) {
    $mem = $ramModules[$i]
    $capGB = [math]::Round($mem.Capacity / 1GB, 0)
    $mfr = if ($mem.Manufacturer) { $mem.Manufacturer.Trim() } else { "Unknown" }
    $speed = if ($mem.Speed) { "$($mem.Speed)MHz" } else { "N/A" }
    $ramLines.Add("Slot $($i + 1): $mfr, ${capGB}GB, $speed")
}
$ramText = $ramLines -join "`r`n"

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

# Split into iGPU (Intel/AMD integrated) vs GPU (NVIDIA - always discrete -
# plus Intel Arc and AMD's own discrete Radeon lines). AMD makes both, so
# its integrated parts ("AMD Radeon(TM) Graphics", "Radeon Vega 8", no model
# number) are told apart from discrete ones by the RX/R5/R7/R9 model number.
$igpuNames = @()
$dgpuNames = @()
foreach ($gpu in $gpus) {
    $name = $gpu.Name
    if (-not $name) { continue }
    $isDiscrete =
        if ($name -match 'Intel') { $name -match 'Arc' }
        elseif ($name -match 'NVIDIA') { $true }
        elseif ($name -match 'AMD|Radeon') { $name -match '\bRX\s?\d|\bR[579]\s?\d{2}|Radeon Pro|Radeon VII|Radeon Instinct' }
        else { $true }   # unknown vendor: assume discrete rather than hide it

    if ($isDiscrete) { $dgpuNames += $name } else { $igpuNames += $name }
}

$gpuLines = @()
if ($igpuNames.Count -gt 0) { $gpuLines += "iGPU: " + ($igpuNames -join ', ') }
if ($dgpuNames.Count -gt 0) { $gpuLines += "GPU: " + ($dgpuNames -join ', ') }
$gpuText = $gpuLines -join "`r`n"
if (-not $gpuText) { $gpuText = "N/A" }

$rows = @(
    @{ Label = "Hostname";      Value = "$($computer.Name)" }
    @{ Label = "Model";         Value = "$($computer.Model)" }
    @{ Label = "Serial";        Value = "$($bios.SerialNumber)" }
    @{ Label = "CPU";           Value = "$($cpu.Name)" }
    @{ Label = "RAM";           Value = $ramText }
    @{ Label = "Storage";       Value = $storageText }
    @{ Label = "Graphics Card"; Value = $gpuText }
    @{ Label = "Resolution";    Value = $screenRes }
    @{ Label = "Refresh Rate";  Value = $refreshRate }
    @{ Label = "Date and Time"; Value = $currentTime }
)

# ----------------------------- BUILD WINDOW --------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "System Information"
$form.Size = New-Object System.Drawing.Size(600, 560)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.BackColor = [System.Drawing.Color]::White
$form.Font = New-Object System.Drawing.Font("Segoe UI", 12)

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
$grid.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$grid.DefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI", 12)
$grid.DefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(4)
$grid.DefaultCellStyle.WrapMode = [System.Windows.Forms.DataGridViewTriState]::True

[void]$grid.Columns.Add("Property", "Property")
[void]$grid.Columns.Add("Value", "Value")
$grid.Columns["Property"].Width = 180
$grid.Columns["Property"].DefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$grid.Columns["Value"].AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill

foreach ($row in $rows) {
    [void]$grid.Rows.Add($row.Label, $row.Value)
}

$form.Controls.Add($grid)
[void]$form.ShowDialog()
