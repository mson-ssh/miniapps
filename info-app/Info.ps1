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

# DSP0134 (SMBIOS spec) Memory Type codes, offset 0x12 of a Type 17
# structure - shared by both the accurate raw-SMBIOS path and the
# Win32_PhysicalMemory fallback (SMBIOSMemoryType uses the same numbering).
$memTypeMap = @{
    18 = "SDRAM"; 19 = "SGRAM"; 20 = "RDRAM"; 21 = "DDR"; 22 = "DDR2"
    23 = "DDR2 FB-DIMM"; 24 = "DDR3"; 25 = "FBD2"; 26 = "DDR4"
    27 = "LPDDR"; 28 = "LPDDR2"; 29 = "LPDDR3"; 30 = "LPDDR4"
    32 = "HBM"; 33 = "HBM2"; 34 = "DDR5"; 35 = "LPDDR5"
}

function Get-RamModulesFromSmbios {
    # Parses raw SMBIOS Type 17 (Memory Device) structures directly instead
    # of using Win32_PhysicalMemory, because:
    #  1. Win32_PhysicalMemory's FormFactor is a translated CIM enum that
    #     does not reliably expose SMBIOS 0x0B "Row of chips" - the actual
    #     signal for soldered/onboard RAM.
    #  2. Its Manufacturer/Speed can be blank on builds that still work
    #     fine when read straight from the SMBIOS string table.
    # Returns $null (not an empty array) when the raw table can't be read,
    # so the caller can fall back to Win32_PhysicalMemory instead of
    # reporting "no RAM found".
    try {
        $raw = Get-CimInstance -Namespace 'root\wmi' -ClassName 'MSSmBios_RawSMBiosTables' -ErrorAction Stop
        $data = [byte[]]$raw.SMBiosData
        if (-not $data -or $data.Length -lt 4) { return $null }

        $structs = New-Object System.Collections.Generic.List[object]
        $i = 0
        while ($i -lt ($data.Length - 4)) {
            $type = $data[$i]
            $length = $data[$i + 1]
            if ($length -lt 4 -or $type -eq 127) { break }   # malformed, or End-of-Table
            $stringsStart = $i + $length
            $p = $stringsStart
            while ($p -lt ($data.Length - 1)) {
                if ($data[$p] -eq 0 -and $data[$p + 1] -eq 0) { break }
                $p++
            }
            $stringsEnd = $p + 2
            $strings = New-Object System.Collections.Generic.List[string]
            $cur = New-Object System.Text.StringBuilder
            for ($k = $stringsStart; $k -lt ($stringsEnd - 2); $k++) {
                if ($data[$k] -eq 0) { [void]$strings.Add($cur.ToString()); [void]$cur.Clear() }
                else { [void]$cur.Append([char]$data[$k]) }
            }
            $body = New-Object byte[] $length
            [Array]::Copy($data, $i, $body, 0, $length)
            [void]$structs.Add([pscustomobject]@{ Type = $type; Body = $body; Strings = $strings })
            $i = $stringsEnd
        }

        $solderedFormFactors = @(0x05, 0x0B, 0x10)   # Chip, Row of chips, Die
        $modules = New-Object System.Collections.Generic.List[object]
        foreach ($s in ($structs | Where-Object { $_.Type -eq 17 })) {
            $b = $s.Body
            if ($b.Length -le 0x0D) { continue }
            $rawSize = [BitConverter]::ToUInt16($b, 0x0C)
            if ($rawSize -eq 0) { continue }   # empty slot, nothing installed

            $capacity =
                if ($rawSize -eq 0x7FFF -and $b.Length -gt 0x1F) { [int64]([BitConverter]::ToUInt32($b, 0x1C)) * 1MB }
                elseif ($rawSize -eq 0xFFFF) { 0 }
                else {
                    $unit = if ($rawSize -band 0x8000) { 1KB } else { 1MB }
                    [int64]($rawSize -band 0x7FFF) * $unit
                }
            if ($capacity -le 0) { continue }

            $ffCode = $b[0x0E]
            $mtCode = if ($b.Length -gt 0x12) { $b[0x12] } else { 0 }
            $speed  = if ($b.Length -gt 0x16) { [BitConverter]::ToUInt16($b, 0x15) } else { 0 }
            $mfrIdx = if ($b.Length -gt 0x17) { $b[0x17] } else { 0 }
            $mfr    = if ($mfrIdx -ge 1 -and $mfrIdx -le $s.Strings.Count) { $s.Strings[$mfrIdx - 1].Trim() } else { "" }

            [void]$modules.Add([pscustomobject]@{
                CapacityBytes = $capacity
                Manufacturer  = $mfr
                Speed         = $speed
                TypeCode      = [int]$mtCode
                Soldered      = ($solderedFormFactors -contains [int]$ffCode)
            })
        }
        return $modules
    }
    catch { return $null }
}

# ----------------------------- COLLECT DATA --------------------------------
# Same CIM queries as Setup.ps1's Get-HardwareInfo, kept in sync by hand -
# this file has no dependency on Setup.ps1 and does not read it.
$computer = Get-CimInstance Win32_ComputerSystem
$bios     = Get-CimInstance Win32_BIOS
$cpu      = Get-CimInstance Win32_Processor | Select-Object -First 1
$disks    = Get-CimInstance Win32_DiskDrive | Where-Object { $_.MediaType -eq 'Fixed hard disk media' }
$gpus     = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notlike '*Basic*' -and $_.Name -notlike '*Standard*' }

$currentTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

# RAM: total + type + speed on one line, then one line per physical stick -
# "Slot N: ..." for a real removable module, "Onboard N: ..." when the
# SMBIOS form factor says it's soldered. Prefers the accurate raw-SMBIOS
# parse; falls back to Win32_PhysicalMemory (can't tell "Row of chips"
# apart from a normal module, so everything reads as "Slot N" there) only
# if the raw table couldn't be read at all.
$ramLines = [System.Collections.Generic.List[string]]::new()
$smbiosModules = Get-RamModulesFromSmbios

if ($smbiosModules) {
    # One summary line per kind present, not one combined line - a hybrid
    # machine (some onboard + a SODIMM slot) has two different capacities
    # and possibly two different speeds, so lumping them together would
    # hide that. Onboard always listed first when both are present.
    $onboardMods = @($smbiosModules | Where-Object { $_.Soldered })
    $socketedMods = @($smbiosModules | Where-Object { -not $_.Soldered })
    foreach ($grp in @(
        @{ Label = "ONBOARD"; Mods = $onboardMods }
        @{ Label = "SODIMM";  Mods = $socketedMods }
    )) {
        if ($grp.Mods.Count -eq 0) { continue }
        $grpTotalGB = [math]::Round((($grp.Mods | Measure-Object -Property CapacityBytes -Sum).Sum) / 1GB, 0)
        $grpFirst = $grp.Mods | Select-Object -First 1
        $grpType = if ($memTypeMap.ContainsKey($grpFirst.TypeCode)) { $memTypeMap[$grpFirst.TypeCode] } else { "" }
        $grpSpeed = if ($grpFirst.Speed) { "$($grpFirst.Speed)MHz" } else { "" }
        $ramLines.Add((("$($grp.Label) ${grpTotalGB}GB $grpType $grpSpeed").Trim() -replace '\s{2,}', ' '))
    }

    for ($i = 0; $i -lt $smbiosModules.Count; $i++) {
        $mod = $smbiosModules[$i]
        $capGB = [math]::Round($mod.CapacityBytes / 1GB, 0)
        $mfr = if ($mod.Manufacturer) { $mod.Manufacturer } else { "Unknown" }
        $speed = if ($mod.Speed) { "$($mod.Speed)MHz" } else { "N/A" }
        $label = if ($mod.Soldered) { "Onboard $($i + 1)" } else { "Slot $($i + 1)" }
        $ramLines.Add("${label}: $mfr, ${capGB}GB, $speed")
    }
}
else {
    $ramModules = @(Get-CimInstance Win32_PhysicalMemory | Where-Object { $_.Capacity })
    $ramTotalGB = if ($ramModules.Count -gt 0) {
        [math]::Round((($ramModules | Measure-Object -Property Capacity -Sum).Sum) / 1GB, 0)
    } else {
        [math]::Round($computer.TotalPhysicalMemory / 1GB, 0)
    }
    $firstModule = $ramModules | Select-Object -First 1
    $ramType = if ($firstModule -and $memTypeMap.ContainsKey([int]$firstModule.SMBIOSMemoryType)) { $memTypeMap[[int]$firstModule.SMBIOSMemoryType] } else { "" }
    $ramSpeed = if ($firstModule -and $firstModule.Speed) { "$($firstModule.Speed)MHz" } else { "" }
    # No ONBOARD/SODIMM split here - Win32_PhysicalMemory's FormFactor can't
    # be trusted for that, this whole path only runs when raw SMBIOS failed.
    $ramLines.Add((("RAM ${ramTotalGB}GB $ramType $ramSpeed").Trim() -replace '\s{2,}', ' '))

    for ($i = 0; $i -lt $ramModules.Count; $i++) {
        $mem = $ramModules[$i]
        $capGB = [math]::Round($mem.Capacity / 1GB, 0)
        $mfr = if ($mem.Manufacturer) { $mem.Manufacturer.Trim() } else { "Unknown" }
        $speed = if ($mem.Speed) { "$($mem.Speed)MHz" } else { "N/A" }
        $ramLines.Add("Slot $($i + 1): $mfr, ${capGB}GB, $speed")
    }
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

# Highlight the specs a technician checks first: light blue background +
# bold value, so CPU/RAM/Graphics Card stand out from the rest of the table.
$highlightLabels = @("CPU", "RAM", "Graphics Card")
$highlightBackColor = [System.Drawing.Color]::FromArgb(225, 239, 254)
$highlightValueFont = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)

foreach ($row in $rows) {
    $rowIndex = $grid.Rows.Add($row.Label, $row.Value)
    if ($highlightLabels -contains $row.Label) {
        $grid.Rows[$rowIndex].DefaultCellStyle.BackColor = $highlightBackColor
        $grid.Rows[$rowIndex].Cells[1].Style.Font = $highlightValueFont
    }
}

$form.Controls.Add($grid)
[void]$form.ShowDialog()
