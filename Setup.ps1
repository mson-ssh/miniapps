# Configure TLS 1.2 to prevent GitHub downloads from being blocked
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# =========================================================================
# MINIAZ SETUP SCRIPT
# =========================================================================
$ProgressPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
# GLOBAL FUNCTIONS
# =========================================================================

# =========================================================================
# AUTO-ELEVATE TO ADMINISTRATOR (UAC PROMPT)
# =========================================================================
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    if ($PSCommandPath) {
        Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    }
    else {
        $tempScript = "$env:TEMP\Setup_elevated.ps1"
        Invoke-WebRequest -Uri "https://raw.githubusercontent.com/mson-ssh/miniapps/main/Setup.ps1" -OutFile $tempScript -UseBasicParsing
        Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$tempScript`""
    }
    exit
}

function Install-NecessaryApps {
    param([string]$Method = 'Installer')
    Write-Host "`n[System] Initializing parallel processes (App Installation, Config, Disk)..." -ForegroundColor Cyan
    
    function Test-IsInstalled {
        param([string]$pattern)
        if (-not $pattern) { return $false }
        $paths = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
        )
        $installed = Get-ItemProperty $paths -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match $pattern }
        return [bool]$installed
    }
    
    # 1. Run Config.ps1 and disk.ps1 from GitHub silently in parallel
    Write-Host "`n[System] Initiating Config and Disk Setup in background..." -ForegroundColor Magenta
    $configJob = Start-Job -ScriptBlock { & ([scriptblock]::Create((irm "https://raw.githubusercontent.com/mson-ssh/miniapps/main/config/Config.ps1"))) -Silent }
    $diskJob = Start-Job -ScriptBlock { & ([scriptblock]::Create((irm "https://raw.githubusercontent.com/mson-ssh/miniapps/main/config/disk.ps1"))) -Silent }
    Write-Host "-> Background processes Config.ps1 and disk.ps1 activated!" -ForegroundColor Gray

    # 2. Check and install Winget silently (Used for Fallback)
    $wingetCheck = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $wingetCheck) {
        Write-Host "-> Winget not found. Starting silent Winget initialization..." -ForegroundColor Yellow
        $tempDir = "$env:TEMP\winget-init"
        if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir | Out-Null }
        
        $desktopAppInstallerUrl = "https://github.com/microsoft/winget-cli/releases/latest/download/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle"
        $uiXamlUrl = "https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.8.6/Microsoft.UI.Xaml.2.8.x64.appx"
        $vclibsUrl = "https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx"
        
        try {
            Invoke-WebRequest -Uri $vclibsUrl -OutFile "$tempDir\VCLibs.appx" -UseBasicParsing
            Invoke-WebRequest -Uri $uiXamlUrl -OutFile "$tempDir\UiXaml.appx" -UseBasicParsing
            Invoke-WebRequest -Uri $desktopAppInstallerUrl -OutFile "$tempDir\Winget.msixbundle" -UseBasicParsing
            
            Add-AppxPackage -Path "$tempDir\VCLibs.appx" -ErrorAction SilentlyContinue
            Add-AppxPackage -Path "$tempDir\UiXaml.appx" -ErrorAction SilentlyContinue
            Add-AppxPackage -Path "$tempDir\Winget.msixbundle" -ErrorAction SilentlyContinue
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            & winget settings --enable BypassCertificatePinningForMicrosoftStore --accept-source-agreements | Out-Null
            & winget source update --quiet | Out-Null
        }
        catch { }
    }
    else {
        & winget settings --enable BypassCertificatePinningForMicrosoftStore --accept-source-agreements | Out-Null
        & winget source update --quiet | Out-Null
    }

    # 3. Install applications utilizing Direct Links from R2 Cloudflare
    $parallelApps = @(
        @{ Name = "EVKey"; Url = "https://pub-50d6cf4af6964541b0621bbc9bc26690.r2.dev/EVKey.exe"; WingetId = ""; Args = "-s"; MatchName = "" },
        @{ Name = "Chrome"; Url = "https://pub-50d6cf4af6964541b0621bbc9bc26690.r2.dev/chrome.exe"; WingetId = "Google.Chrome"; Args = "/silent /install"; MatchName = "Google Chrome" },
        @{ Name = "Klite"; Url = "https://pub-50d6cf4af6964541b0621bbc9bc26690.r2.dev/klite.exe"; WingetId = "CodecGuide.K-LiteCodecPack.Mega"; Args = "/verysilent /norestart /suppressmsgboxes"; MatchName = "K-Lite Codec Pack" },
        @{ Name = "Telegram"; Url = "https://pub-50d6cf4af6964541b0621bbc9bc26690.r2.dev/tele.exe"; WingetId = "Telegram.TelegramDesktop"; Args = "/VERYSILENT /NORESTART /SUPPRESSMSGBOXES"; MatchName = "Telegram Desktop" },
        @{ Name = "Ultraview"; Url = "https://pub-50d6cf4af6964541b0621bbc9bc26690.r2.dev/ultrav.exe"; WingetId = "DucFabulous.UltraViewer"; Args = "/VERYSILENT /NORESTART /SUPPRESSMSGBOXES"; MatchName = "UltraViewer" },
        @{ Name = "WinRAR"; Url = "https://pub-50d6cf4af6964541b0621bbc9bc26690.r2.dev/winrar.exe"; WingetId = "RARLab.WinRAR"; Args = "/S"; MatchName = "WinRAR" },
        @{ Name = "Zalo"; Url = "https://pub-50d6cf4af6964541b0621bbc9bc26690.r2.dev/zalo.exe"; WingetId = "VNGCorp.Zalo"; Args = "/S"; MatchName = "Zalo" },
        @{ Name = "Zoom"; Url = "https://pub-50d6cf4af6964541b0621bbc9bc26690.r2.dev/zoom.exe"; WingetId = "Zoom.Zoom"; Args = "/silent"; MatchName = "Zoom" },
        @{ Name = "Office 2024"; Url = "https://pub-50d6cf4af6964541b0621bbc9bc26690.r2.dev/OfficeSetup.exe"; WingetId = ""; Args = ""; MatchName = "Microsoft Office|Microsoft 365" }
    )

    $sequentialApps = @(
        @{ Name = "VCRedist x64"; Url = "https://pub-50d6cf4af6964541b0621bbc9bc26690.r2.dev/VC_redist.x64.exe"; WingetId = "Microsoft.VCRedist.2015+.x64"; Args = "/install /quiet /norestart"; MatchName = "Microsoft Visual C\+\+.*x64" },
        @{ Name = "VCRedist x86"; Url = "https://pub-50d6cf4af6964541b0621bbc9bc26690.r2.dev/VC_redist.x86.exe"; WingetId = "Microsoft.VCRedist.2015+.x86"; Args = "/install /quiet /norestart"; MatchName = "Microsoft Visual C\+\+.*x86" }
    )

    Write-Host "`n[Start] Downloading and installing $($parallelApps.Count) primary applications in parallel..." -ForegroundColor Cyan
    $jobs = @()
    $appStates = @{}
    foreach ($app in $parallelApps) {
        if ($app.MatchName -and (Test-IsInstalled $app.MatchName)) {
            $appStates[$app.Name] = "Already Installed"
            continue
        }
        if ($app.Name -eq "EVKey" -and (Test-Path "C:\EVKey")) {
            $appStates[$app.Name] = "Already Installed"
            continue
        }
        $appStates[$app.Name] = "Downloading"
        $job = Start-Job -ScriptBlock {
            param($Name, $Url, $WingetId, $ArgsStr, $Method)
            $ProgressPreference = 'SilentlyContinue'
            $tempDir = "$env:TEMP\MiniAZ_Apps"
            if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }
            $fileName = $Url.Split('/')[-1]
            $tempExe = "$tempDir\$fileName"
            
            $success = $false
            if ($Method -eq 'Winget' -and $WingetId) {
                Write-Output "STATE:$Name:Installing"
                $proc = Start-Process winget -ArgumentList "install --id $WingetId --exact --silent --disable-interactivity --accept-package-agreements --accept-source-agreements" -PassThru -NoNewWindow
                try {
                    $proc | Wait-Process -Timeout 300 -ErrorAction Stop
                    if ($null -eq $proc.ExitCode -or $proc.ExitCode -eq 0) { $success = $true; Write-Output "STATE:$Name:Done" }
                } catch {
                    $proc | Stop-Process -Force -ErrorAction SilentlyContinue
                }
            } else {
                try {
                    $maxRetries = 3; $retry = 0; $downloaded = $false
                    Write-Output "STATE:$Name:Downloading"
                    while ($retry -lt $maxRetries -and -not $downloaded) {
                        try {
                            Invoke-WebRequest -Uri $Url -OutFile $tempExe -UseBasicParsing -TimeoutSec 300 -ErrorAction Stop
                            $downloaded = $true
                        }
                        catch {
                            $retry++
                            if ($retry -lt $maxRetries) { Start-Sleep -Seconds 2 }
                        }
                    }
                    if (-not $downloaded) { throw "Download failed" }

                    Write-Output "STATE:$Name:Installing"
                    
                    if ($Name -eq "EVKey") {
                        Start-Process -FilePath $tempExe -ArgumentList $ArgsStr -WindowStyle Hidden
                        Start-Sleep -Seconds 3
                        $success = $true
                        Write-Output "STATE:$Name:Done"
                    } else {
                        if ([string]::IsNullOrWhiteSpace($ArgsStr)) {
                            $proc = Start-Process -FilePath $tempExe -PassThru
                        } else {
                            $proc = Start-Process -FilePath $tempExe -ArgumentList $ArgsStr -PassThru
                        }
                            
                        try {
                            $proc | Wait-Process -Timeout 180 -ErrorAction Stop
                            if ($null -eq $proc.ExitCode -or $proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) { 
                                $success = $true 
                                Write-Output "STATE:$Name:Done"
                            }
                            else {
                                Write-Output "STATE:$Name:Error"
                            }
                        }
                        catch {
                            $proc | Stop-Process -Force -ErrorAction SilentlyContinue
                            Write-Output "STATE:$Name:Error"
                        }
                    }
                }
                catch { 
                    Write-Output "STATE:$Name:Error"
                }
            }
            if (-not $success) { Write-Output "STATE:$Name:Error" }
        } -ArgumentList $app.Name, $app.Url, $app.WingetId, $app.Args, $Method
        $jobs += $job
    }

    $sequentialAppsToRun = @()
    foreach ($app in $sequentialApps) {
        if ($app.MatchName -and (Test-IsInstalled $app.MatchName)) {
            $appStates[$app.Name] = "Already Installed"
        } else {
            $appStates[$app.Name] = "Waiting"
            $sequentialAppsToRun += $app
        }
    }
    
    if ($sequentialAppsToRun.Count -gt 0) {
        $seqJob = Start-Job -ScriptBlock {
            param($Apps, $Method)
            $ProgressPreference = 'SilentlyContinue'
            foreach ($app in $Apps) {
                $Name = $app.Name; $Url = $app.Url; $WingetId = $app.WingetId; $ArgsStr = $app.Args
                $fileName = $Url.Split('/')[-1]
                $tempExe = "$env:TEMP\MiniAZ_Apps\$fileName"
                
                $success = $false
                if ($Method -eq 'Winget' -and $WingetId) {
                    Write-Output "STATE:$Name:Installing"
                    $proc = Start-Process winget -ArgumentList "install --id $WingetId --exact --silent --disable-interactivity --accept-package-agreements --accept-source-agreements" -PassThru -NoNewWindow
                    try {
                        $proc | Wait-Process -Timeout 300 -ErrorAction Stop
                        if ($null -eq $proc.ExitCode -or $proc.ExitCode -eq 0) { $success = $true; Write-Output "STATE:$Name:Done" }
                    } catch {
                        $proc | Stop-Process -Force -ErrorAction SilentlyContinue
                    }
                } else {
                    try {
                        $maxRetries = 3; $retry = 0; $downloaded = $false
                        Write-Output "STATE:$Name:Downloading"
                        while ($retry -lt $maxRetries -and -not $downloaded) {
                            try {
                                Invoke-WebRequest -Uri $Url -OutFile $tempExe -UseBasicParsing -TimeoutSec 300 -ErrorAction Stop
                                $downloaded = $true
                            } catch {
                                $retry++
                                if ($retry -lt $maxRetries) { Start-Sleep -Seconds 2 }
                            }
                        }
                        if (-not $downloaded) { throw "Download failed" }

                        Write-Output "STATE:$Name:Installing"
                        if ([string]::IsNullOrWhiteSpace($ArgsStr)) {
                            $proc = Start-Process -FilePath $tempExe -PassThru
                        } else {
                            $proc = Start-Process -FilePath $tempExe -ArgumentList $ArgsStr -PassThru
                        }
                        try {
                            $proc | Wait-Process -Timeout 180 -ErrorAction Stop
                            if ($null -eq $proc.ExitCode -or $proc.ExitCode -eq 0 -or $proc.ExitCode -eq -1978335201) { $success = $true; Write-Output "STATE:$Name:Done" }
                        } catch {
                            $proc | Stop-Process -Force -ErrorAction SilentlyContinue
                        }
                    } catch { 
                        Write-Output "STATE:$Name:Error"
                    }
                }
                if (-not $success) { Write-Output "STATE:$Name:Error" }
            }
        } -ArgumentList (,$sequentialAppsToRun), $Method
        $jobs += $seqJob
    }
    
    $allApps = $parallelApps + $sequentialApps

    # 4. Display background processes visually (Dynamic status table)
    Write-Host "`n[Progress] Processing parallel applications..." -ForegroundColor Cyan
    
    $startTop = [Console]::CursorTop
    foreach ($app in $allApps) {
        Write-Host ("   [+] {0} - {1}" -f $app.Name.PadRight(12), $appStates[$app.Name]) -ForegroundColor Yellow
    }

    while ($jobs.State -contains 'Running') {
        $newData = $false
        foreach ($job in $jobs) {
            if ($job.HasMoreData) {
                $outputs = Receive-Job -Job $job
                foreach ($out in $outputs) {
                    if ($out -match "^STATE:(.+?):(.+)$") {
                        $appName = $matches[1]
                        $appState = $matches[2]
                        
                        if ($appState -eq "Downloading") { $appStates[$appName] = "Downloading" }
                        elseif ($appState -eq "Installing") { $appStates[$appName] = "Installing" }
                        elseif ($appState -eq "Done") { $appStates[$appName] = "Done" }
                        elseif ($appState -eq "Error") { $appStates[$appName] = "Failed" }
                        elseif ($appState -eq "Winget") { $appStates[$appName] = "Winget Fallback" }
                        $newData = $true
                    }
                }
            }
        }
        
        if ($newData) {
            [Console]::SetCursorPosition(0, $startTop)
            foreach ($app in $allApps) {
                $line = "   [+] {0} - {1}" -f $app.Name.PadRight(12), $appStates[$app.Name]
                Write-Host $line.PadRight(80) -ForegroundColor Yellow
            }
        }
        Start-Sleep -Milliseconds 200
    }
    
    # Process any final outputs
    if ($jobs.Count -gt 0) {
        $outputs = Receive-Job -Job $jobs
        if ($outputs) {
            foreach ($out in $outputs) {
                if ($out -match "^STATE:(.+?):(.+)$") {
                    $appName = $matches[1]
                    $appState = $matches[2]
                    
                    if ($appState -eq "Downloading") { $appStates[$appName] = "Downloading" }
                    elseif ($appState -eq "Installing") { $appStates[$appName] = "Installing" }
                    elseif ($appState -eq "Done") { $appStates[$appName] = "Done" }
                    elseif ($appState -eq "Error") { $appStates[$appName] = "Failed" }
                    elseif ($appState -eq "Winget") { $appStates[$appName] = "Winget Fallback" }
                }
            }
            [Console]::SetCursorPosition(0, $startTop)
            foreach ($app in $allApps) {
                $line = "   [+] {0} - {1}" -f $app.Name.PadRight(12), $appStates[$app.Name]
                Write-Host $line.PadRight(80) -ForegroundColor Yellow
            }
        }
        Remove-Job $jobs | Out-Null
    }
    Wait-Job $configJob, $diskJob | Out-Null
    Remove-Job $configJob, $diskJob | Out-Null
    Write-Host "`n[Completed] The entire installation and setup process has finished!" -ForegroundColor Green
}

function Show-SystemInfo {
    Write-Host "`n[System] Downloading and running system information script..." -ForegroundColor Cyan
    try {
        irm https://raw.githubusercontent.com/mson-ssh/miniapps/main/config/Get-info.ps1 | iex
        
        # Create Office shortcuts if they exist
        $officePaths = @(
            "C:\Program Files\Microsoft Office\root\Office16\WINWORD.EXE",
            "C:\Program Files\Microsoft Office\root\Office16\EXCEL.EXE",
            "C:\Program Files\Microsoft Office\root\Office16\POWERPNT.EXE",
            "C:\Program Files (x86)\Microsoft Office\root\Office16\WINWORD.EXE",
            "C:\Program Files (x86)\Microsoft Office\root\Office16\EXCEL.EXE",
            "C:\Program Files (x86)\Microsoft Office\root\Office16\POWERPNT.EXE"
        )
        $wshShell = New-Object -ComObject WScript.Shell
        $desktop = [Environment]::GetFolderPath('Desktop')
        foreach ($path in $officePaths) {
            if (Test-Path $path) {
                $name = (Get-Item $path).BaseName
                if ($name -eq "WINWORD") { $name = "Word" }
                elseif ($name -eq "EXCEL") { $name = "Excel" }
                elseif ($name -eq "POWERPNT") { $name = "PowerPoint" }
                
                $shortcutPath = Join-Path $desktop "$name.lnk"
                if (-not (Test-Path $shortcutPath)) {
                    $shortcut = $wshShell.CreateShortcut($shortcutPath)
                    $shortcut.TargetPath = $path
                    $shortcut.Save()
                }
            }
        }

        Write-Host "[OK] Executed successfully, exported file to Desktop, and created Office shortcuts (if found)!" -ForegroundColor Green
    }
    catch {
        Write-Host "[ERROR] Failed to run System Information tasks: $_" -ForegroundColor Red
    }
}

function Run-Debloatware {
    Write-Host "`n[System] Launching Windows Debloatware utility (Silent Default Profile)..." -ForegroundColor Cyan
    try {
        & ([scriptblock]::Create((irm "https://debloat.raphi.re/"))) -RunDefaults -Silent
        Write-Host "`n[OK] Debloatware utility exited successfully!" -ForegroundColor Green
    }
    catch {
        Write-Host "`n[ERROR] Failed to run Debloatware utility: $_" -ForegroundColor Red
    }
}

# =========================================================================
# INTERACTIVE MENU UI
# =========================================================================

function Draw-Menu {
    param ($selectedIndex)
    
    Clear-Host
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "                        MINI-APPS                         " -ForegroundColor White -BackgroundColor DarkBlue
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host ""

    $options = @(
        "1. Install App with Installer",
        "2. Install App with Winget",
        "3. Information",
        "4. Debloatware Windows",
        "5. Exit"
    )

    for ($i = 0; $i -lt $options.Count; $i++) {
        if ($i -eq $selectedIndex) {
            Write-Host "  > $($options[$i]) " -ForegroundColor Black -BackgroundColor Cyan
        }
        else {
            Write-Host "    $($options[$i]) " -ForegroundColor White
        }
    }
    Write-Host ""
}

function Run-Menu {
    $selectedIndex = 0
    $optionsCount = 5

    while ($true) {
        Draw-Menu -selectedIndex $selectedIndex

        $keyInfo = [System.Console]::ReadKey($true)
        $key = $keyInfo.Key

        if ($key -eq 'UpArrow') {
            $selectedIndex--
            if ($selectedIndex -lt 0) { $selectedIndex = $optionsCount - 1 }
        }
        elseif ($key -eq 'DownArrow') {
            $selectedIndex++
            if ($selectedIndex -ge $optionsCount) { $selectedIndex = 0 }
        }
        elseif ($key -eq 'D1' -or $key -eq 'NumPad1') { $selectedIndex = 0; break }
        elseif ($key -eq 'D2' -or $key -eq 'NumPad2') { $selectedIndex = 1; break }
        elseif ($key -eq 'D3' -or $key -eq 'NumPad3') { $selectedIndex = 2; break }
        elseif ($key -eq 'D4' -or $key -eq 'NumPad4') { $selectedIndex = 3; break }
        elseif ($key -eq 'D5' -or $key -eq 'NumPad5') { $selectedIndex = 4; break }
        elseif ($key -eq 'Enter') {
            break
        }
        elseif ($key -eq 'Escape') {
            $selectedIndex = 4; break
        }
    }
    return $selectedIndex
}

# =========================================================================
# MAIN LOOP
# =========================================================================

while ($true) {
    $choice = Run-Menu
    
    Clear-Host
    if ($choice -eq 0) {
        Install-NecessaryApps -Method 'Installer'
    }
    elseif ($choice -eq 1) {
        Install-NecessaryApps -Method 'Winget'
    }
    elseif ($choice -eq 2) {
        Show-SystemInfo
    }
    elseif ($choice -eq 3) {
        Run-Debloatware
    }
    elseif ($choice -eq 4) {
        Write-Host "Exiting program. Have a great day!" -ForegroundColor Green
        exit
    }

    Write-Host "`nPress any key to return to Menu..." -ForegroundColor Gray
    [System.Console]::ReadKey($true) | Out-Null
}