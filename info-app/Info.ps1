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
# Standalone - this file has no dependency on Setup.ps1 and does not read it.
$computer = Get-CimInstance Win32_ComputerSystem
$bios     = Get-CimInstance Win32_BIOS
$os       = Get-CimInstance Win32_OperatingSystem
$cpu      = Get-CimInstance Win32_Processor | Select-Object -First 1
$disks    = Get-CimInstance Win32_DiskDrive | Where-Object { $_.MediaType -eq 'Fixed hard disk media' }
$gpus     = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notlike '*Basic*' -and $_.Name -notlike '*Standard*' }

$currentTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

# OS edition + activation status ("Windows 11 Home Single Language" plus a
# green/orange dot drawn in the grid below). LicenseStatus 1 means the
# Windows license is activated - the same signal `slmgr /xpr` reports, read
# via WMI instead of shelling out to slmgr.vbs.
$osName = $os.Caption -replace '^Microsoft\s+', ''
$osActivated = $false
try {
    $lic = Get-CimInstance -Query "SELECT LicenseStatus FROM SoftwareLicensingProduct WHERE ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" -ErrorAction Stop
    $osActivated = @($lic | Where-Object { $_.LicenseStatus -eq 1 }).Count -gt 0
}
catch { $osActivated = $false }

# RAM: total + type + speed on one line, then one line per physical stick -
# "SLOT N: ..." for a real removable module (always shown, even for a
# single stick), "ONBOARD N: ..." when the SMBIOS form factor says it's
# soldered. Prefers the accurate raw-SMBIOS parse; falls back to
# Win32_PhysicalMemory (can't tell "Row of chips" apart from a normal
# module, so everything reads as "SLOT N" there) only if the raw table
# couldn't be read at all.
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
        $type = if ($memTypeMap.ContainsKey($mod.TypeCode)) { $memTypeMap[$mod.TypeCode] } else { "" }
        $label = if ($mod.Soldered) { "ONBOARD" } else { "SLOT" }
        $detail = (("${capGB}GB $type $speed").Trim() -replace '\s{2,}', ' ')
        $ramLines.Add("$label $($i + 1): $detail - $mfr")
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
        $type = if ($mem.SMBIOSMemoryType -and $memTypeMap.ContainsKey([int]$mem.SMBIOSMemoryType)) { $memTypeMap[[int]$mem.SMBIOSMemoryType] } else { "" }
        $detail = (("${capGB}GB $type $speed").Trim() -replace '\s{2,}', ' ')
        $ramLines.Add("SLOT $($i + 1): $detail - $mfr")
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

# Physical disk: model + nominal marketing capacity (1TB/512GB/250GB...),
# not the raw computed size - that's always a bit under the marketed
# number (binary GiB vs decimal GB: a "256GB" SSD reports ~238 GiB) -
# snapped to the nearest size from a lookup list of real SSD/HDD capacities.
function Get-NominalDiskSize {
    param([double]$Bytes)
    $decimalGB = $Bytes / 1000000000
    $standardSizesGB = @(32, 60, 64, 90, 120, 125, 128, 160, 180, 200, 240, 250, 256, 320, 400, 480, 500, 512, 640, 750, 960, 1000, 1024, 1500, 2000, 3000, 4000, 5000, 6000, 8000, 10000, 12000, 16000, 20000)
    $closest = $standardSizesGB | Sort-Object { [Math]::Abs($_ - $decimalGB) } | Select-Object -First 1
    if ($closest -ge 1000) { return "$([math]::Round($closest / 1000, 1))TB" }
    return "${closest}GB"
}

$storageLines = [System.Collections.Generic.List[string]]::new()
foreach ($disk in ($disks | Where-Object { $_.Size })) {
    $storageLines.Add("$($disk.Model) - $(Get-NominalDiskSize -Bytes $disk.Size)")
}

# Partition: each drive letter's own total capacity (not free space), so
# "Disk C: 200GB" is the whole C: volume, matching what the customer sees
# in File Explorer - not tied to the physical disk names above. One line
# per drive letter, not joined together, so it stays readable with 3+ disks.
$volumes = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' } | Sort-Object DriveLetter)
if ($volumes.Count -gt 0) {
    $storageLines.Add("Partition:")
    foreach ($vol in $volumes) {
        $totalGB = [math]::Round($vol.Size / 1GB, 0)
        $storageLines.Add("Disk $($vol.DriveLetter): ${totalGB}GB")
    }
}

$storageText = $storageLines -join "`r`n"
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
    @{ Label = "OS";            Value = $osName }
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
$form.BackColor = [System.Drawing.Color]::FromArgb(240, 240, 242)
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
$grid.BackgroundColor = [System.Drawing.Color]::FromArgb(240, 240, 242)
# FixedSingle, not None: without it the table has lines between cells but no
# outer edge, so the top/left/right of the grid just bleed into the form.
$grid.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$grid.CellBorderStyle = [System.Windows.Forms.DataGridViewCellBorderStyle]::Single
$grid.GridColor = [System.Drawing.Color]::FromArgb(210, 210, 212)
$grid.EnableHeadersVisualStyles = $false
$grid.ColumnHeadersHeightSizeMode = [System.Windows.Forms.DataGridViewColumnHeadersHeightSizeMode]::AutoSize
$grid.AutoSizeRowsMode = [System.Windows.Forms.DataGridViewAutoSizeRowsMode]::AllCells
$grid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(228, 228, 231)
$grid.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
# Cell background just off pure white - the stark white/black contrast is
# what read as too bright, not the color count.
$grid.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 251)
$grid.DefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(32, 32, 34)
$grid.DefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI", 12)
$grid.DefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(4)
$grid.DefaultCellStyle.WrapMode = [System.Windows.Forms.DataGridViewTriState]::True
# Selection painted the same as a normal cell. This is a read-only report, so
# selection carries no meaning - and the default blue block covers the grid
# lines inside whichever row happens to be selected (row 0 always is, on open).
$grid.DefaultCellStyle.SelectionBackColor = $grid.DefaultCellStyle.BackColor
$grid.DefaultCellStyle.SelectionForeColor = $grid.DefaultCellStyle.ForeColor

[void]$grid.Columns.Add("Property", "Property")
[void]$grid.Columns.Add("Value", "Value")
$grid.Columns["Property"].Width = 180
$grid.Columns["Property"].DefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$grid.Columns["Value"].AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
# Rows stay in the fixed order they were added - clicking a header must not
# re-sort them (the highlighted CPU/RAM/Graphics Card rows would scatter).
$grid.Columns["Property"].SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::NotSortable
$grid.Columns["Value"].SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::NotSortable

# OS row gets a status dot instead of plain text - green means Windows is
# activated, orange means it isn't. A DataGridView cell can't mix two colors
# in one string, so the dot is hand-drawn via CellPainting and the normal
# text painting is skipped (e.Handled) for just that one cell.
$osStatusColor = if ($osActivated) { [System.Drawing.Color]::FromArgb(46, 160, 67) } else { [System.Drawing.Color]::FromArgb(230, 126, 34) }
$grid.Add_CellPainting({
    param($gridSender, $e)
    if ($e.RowIndex -lt 0 -or $e.ColumnIndex -ne 1) { return }
    if ($gridSender.Rows[$e.RowIndex].Cells[0].Value -ne "OS") { return }

    # Drawn with TextRenderer, not Graphics.DrawString: DrawString's overloads
    # take RectangleF/PointF, and PowerShell will not widen an integer
    # Rectangle to RectangleF - it falls through to the PointF overload and
    # fails to bind. TextRenderer takes a plain Rectangle, and is also what
    # DataGridView itself uses, so this cell renders like every other one.
    try {
        $text = [string]$e.FormattedValue
        $font = $e.CellStyle.Font
        if (-not $font) { return }   # no usable font: let the grid paint it normally

        $e.PaintBackground($e.CellBounds, $true)
        $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

        $dotSize = 10
        $textX = $e.CellBounds.X + 6
        # Width measured from the cell's right edge: textX is an absolute
        # coordinate while CellBounds.Width is relative, so subtracting one
        # from the other would drop the whole Property-column offset.
        $textW = $e.CellBounds.Right - $textX - $dotSize - 10
        if ($textW -lt 1) { $textW = 1 }

        $flags = [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor
                 [System.Windows.Forms.TextFormatFlags]::Left -bor
                 [System.Windows.Forms.TextFormatFlags]::NoPrefix
        $textRect = New-Object System.Drawing.Rectangle($textX, $e.CellBounds.Y, $textW, $e.CellBounds.Height)
        [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $text, $font, $textRect, $e.CellStyle.ForeColor, $flags)

        # Dot sits right after the text, so its X depends on the rendered width.
        $textSize = [System.Windows.Forms.TextRenderer]::MeasureText($e.Graphics, $text, $font)
        $dotX = $textX + $textSize.Width + 2
        $dotY = $e.CellBounds.Y + [int](($e.CellBounds.Height - $dotSize) / 2)
        $dotBrush = New-Object System.Drawing.SolidBrush($osStatusColor)
        # Rectangle overload, not four loose numbers - an exact type match so
        # PowerShell never has to guess between the int and float versions.
        $dotRect = New-Object System.Drawing.Rectangle($dotX, $dotY, $dotSize, $dotSize)
        $e.Graphics.FillEllipse($dotBrush, $dotRect)
        $dotBrush.Dispose()

        $e.Handled = $true
    }
    catch {
        # Leave Handled false so the grid draws the row its normal way. Losing
        # the dot is acceptable; a stack of error dialogs on the customer's
        # screen is not - and this runs on every repaint, so it would repeat.
    }
})

# Highlight the specs a technician checks first: light blue background +
# bold value, so CPU/RAM/Graphics Card stand out from the rest of the table.
$highlightLabels = @("CPU", "RAM", "Graphics Card")
$highlightBackColor = [System.Drawing.Color]::FromArgb(225, 239, 254)
$highlightValueFont = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)

foreach ($row in $rows) {
    $rowIndex = $grid.Rows.Add($row.Label, $row.Value)
    if ($highlightLabels -contains $row.Label) {
        $grid.Rows[$rowIndex].DefaultCellStyle.BackColor = $highlightBackColor
        # Same colour when selected, matching the rule set on DefaultCellStyle -
        # a row-level BackColor does not carry over to SelectionBackColor.
        $grid.Rows[$rowIndex].DefaultCellStyle.SelectionBackColor = $highlightBackColor
        $grid.Rows[$rowIndex].DefaultCellStyle.SelectionForeColor = $grid.DefaultCellStyle.ForeColor
        $grid.Rows[$rowIndex].Cells[1].Style.Font = $highlightValueFont
    }
}

# Grow the window to fit the whole table so nothing needs scrolling. Row
# heights are only computed once the grid has a window handle, so this has to
# wait for Load rather than run right after the rows are added. Falls back to
# leaving the scrollbar alone if the table is taller than the screen.
$form.Add_Load({
    $grid.AutoResizeRows([System.Windows.Forms.DataGridViewAutoSizeRowsMode]::AllCells)

    $needed = $grid.ColumnHeadersHeight + 2   # +2 for the grid's own border
    foreach ($r in $grid.Rows) { $needed += $r.Height }

    $maxHeight = [int]([System.Windows.Forms.Screen]::FromControl($form).WorkingArea.Height * 0.92)
    if ($needed -le $maxHeight) {
        $grid.ScrollBars = [System.Windows.Forms.ScrollBars]::None
        $form.ClientSize = New-Object System.Drawing.Size($form.ClientSize.Width, $needed)
        # StartPosition centred the form at its original height, so re-centre
        # it now that the height has changed.
        $form.CenterToScreen()
    }
})

$form.Controls.Add($grid)
[void]$form.ShowDialog()
