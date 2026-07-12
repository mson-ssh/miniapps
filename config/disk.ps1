# ================================================================================
#                    MINIAZ AUTO DISK PARTITION SCRIPT (PS1)
#                    Compatible with Windows 10 / Windows 11
# ================================================================================
# Purpose:
# - Automatically detect SSD capacity (200-300GB, 400-600GB, 800-1100GB).
# - Safety Interlock: Automatically CANCEL and exit if disk capacity > 1TB (1100GB).
# - Safely rename C: to "OS" (No formatting, zero risk of data loss).
# - Precision .1GB sizing (50.1GB, 200.1GB, 400.1GB) to display crisp round numbers in This PC.
# - 256GB/500GB -> Only C and D. | 1TB -> C, D, and E.
# - 100% Silent execution compatible with WinRAR SFX deployment.
# ================================================================================

param(
    [switch]$Silent
)

# ----------------------------- CONFIGURATION ------------------------------------
$LabelC = "OS"
$LabelD = "LOCAL I"
$LabelE = "LOCAL II"


# Precision Partitioning Rules (.1GB padding counteracts NTFS formatting overhead)
$Config256GB = @{ SizeD = 50.1GB;  SizeE = 0GB;     HasE = $false }
$Config500GB = @{ SizeD = 200.1GB; SizeE = 0GB;     HasE = $false }
$Config1TB   = @{ SizeD = 400.1GB; SizeE = 200.1GB; HasE = $true  }

# ----------------------------- SILENT MODE --------------------------------------
if (-not $Silent) {
    $argList = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Silent"
    Start-Process -FilePath "powershell.exe" -ArgumentList $argList -WindowStyle Hidden -Wait
    exit $LASTEXITCODE
}

# ----------------------------- INITIALIZATION -----------------------------------


# ----------------------------- ADMIN CHECK --------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    exit 10
}

try {
    # ------------------------- STEP 1: SAFE RELABEL C: --------------------------
    Set-Volume -DriveLetter C -NewFileSystemLabel $LabelC -ErrorAction Stop

    # ------------------------- STEP 2: DETECT SSD SIZE & SAFETY CHECK -----------
    $osPartition = Get-Partition -DriveLetter C -ErrorAction Stop
    $osDisk      = Get-Disk -Number $osPartition.DiskNumber -ErrorAction Stop
    
    $totalGB = [Math]::Round($osDisk.Size / 1GB, 1)

    # SAFETY INTERLOCK: Cancel if disk is larger than 1TB (1100 GB threshold)
    if ($totalGB -gt 1100) {
        exit 0
    }

    $plan = $null
    $planName = ""

    if ($totalGB -ge 200 -and $totalGB -le 300) {
        $plan = $Config256GB; $planName = "256GB SSD Class (C: Remaining, D: 50.1GB)"
    } elseif ($totalGB -ge 400 -and $totalGB -le 600) {
        $plan = $Config500GB; $planName = "500GB SSD Class (C: Remaining, D: 200.1GB)"
    } elseif ($totalGB -ge 800 -and $totalGB -le 1100) {
        $plan = $Config1TB;   $planName = "1TB SSD Class (C: Remaining, D: 400.1GB, E: 200.1GB)"
    } else {
        exit 0
    }


    # Check if disk already has partitions D or E to prevent accidental re-partitioning
    $existingD = Get-Partition -DriveLetter D -ErrorAction SilentlyContinue
    $existingE = Get-Partition -DriveLetter E -ErrorAction SilentlyContinue
    if ($existingD -or $existingE) {
        exit 0
    }

    # ------------------------- STEP 3: SHRINK DRIVE C: --------------------------
    $totalShrink = $plan.SizeD + $plan.SizeE
    $currentCSize = $osPartition.Size
    $targetCSize  = $currentCSize - $totalShrink

    if ($targetCSize -le 30GB) {
        exit 1
    }

    Resize-Partition -DriveLetter C -Size $targetCSize -ErrorAction Stop

    # ------------------------- STEP 4: CREATE DRIVE D: --------------------------
    if ($plan.HasE) {
        # For 1TB: We create D with exact size $plan.SizeD (400.1GB) so E gets the remaining 200.1GB
        $partD = New-Partition -DiskNumber $osDisk.Number -Size $plan.SizeD -AssignDriveLetter -ErrorAction Stop
    } else {
        # For 256GB / 500GB: D is the final partition, use UseMaximumSize to consume 100% of the shrunk space (50.1GB / 200.1GB)
        $partD = New-Partition -DiskNumber $osDisk.Number -UseMaximumSize -AssignDriveLetter -ErrorAction Stop
    }
    
    Start-Sleep -Seconds 3
    $formattedD = $false
    for ($i = 0; $i -lt 5; $i++) {
        try {
            $partD = Get-Partition -DiskNumber $osDisk.Number -PartitionNumber $partD.PartitionNumber
            if ($partD.DriveLetter) {
                Format-Volume -DriveLetter $partD.DriveLetter -FileSystem NTFS -NewFileSystemLabel $LabelD -Quick -Confirm:$false -ErrorAction Stop | Out-Null
            } else {
                Format-Volume -Partition $partD -FileSystem NTFS -NewFileSystemLabel $LabelD -Quick -Confirm:$false -ErrorAction Stop | Out-Null
            }
            $formattedD = $true
            break
        } catch { Start-Sleep -Seconds 3 }
    }
    if (-not $formattedD) { throw "Failed to format D" }

    if ($partD.DriveLetter -ne 'D') {
        Set-Partition -DiskNumber $osDisk.Number -PartitionNumber $partD.PartitionNumber -NewDriveLetter D -ErrorAction SilentlyContinue
    }

    # ------------------------- STEP 5: CREATE DRIVE E: (1TB ONLY) ---------------
    if ($plan.HasE) {
        $partE = New-Partition -DiskNumber $osDisk.Number -UseMaximumSize -AssignDriveLetter -ErrorAction Stop
        
        Start-Sleep -Seconds 3
        $formattedE = $false
        for ($i = 0; $i -lt 5; $i++) {
            try {
                $partE = Get-Partition -DiskNumber $osDisk.Number -PartitionNumber $partE.PartitionNumber
                if ($partE.DriveLetter) {
                    Format-Volume -DriveLetter $partE.DriveLetter -FileSystem NTFS -NewFileSystemLabel $LabelE -Quick -Confirm:$false -ErrorAction Stop | Out-Null
                } else {
                    Format-Volume -Partition $partE -FileSystem NTFS -NewFileSystemLabel $LabelE -Quick -Confirm:$false -ErrorAction Stop | Out-Null
                }
                $formattedE = $true
                break
            } catch { Start-Sleep -Seconds 3 }
        }
        if (-not $formattedE) { throw "Failed to format E" }

        if ($partE.DriveLetter -ne 'E') {
            Set-Partition -DiskNumber $osDisk.Number -PartitionNumber $partE.PartitionNumber -NewDriveLetter E -ErrorAction SilentlyContinue
        }
    }

    exit 0

} catch {
    exit 1
}
