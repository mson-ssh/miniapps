# Thiet lap giao thuc bao mat TLS 1.2 de tai file tu GitHub kho khong bi chan
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# =========================================================================
# GLOBAL FUNCTIONS
# =========================================================================

function Install-NecessaryApps {
    Write-Host "`n[He thong] Dang khoi dong cac tien trinh chay song song (Cai dat App, Config, Disk)..." -ForegroundColor Cyan
    
    # 1. Chay ngam song song Config.ps1 va disk.ps1 tu GitHub
    $configJob = Start-Job -ScriptBlock { irm https://raw.githubusercontent.com/mson-ssh/miniapps/main/config/Config.ps1 | iex }
    $diskJob = Start-Job -ScriptBlock { irm https://raw.githubusercontent.com/mson-ssh/miniapps/main/config/disk.ps1 | iex }
    Write-Host "-> Da kich hoat ngam tien trinh Config.ps1 va disk.ps1!" -ForegroundColor Gray

    # 2. Kiem tra va cai dat Winget ngam (Dung de Fallback)
    $wingetCheck = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $wingetCheck) {
        Write-Host "-> Chua co Winget. Bat dau tu dong thiet lap ngam Winget..." -ForegroundColor Yellow
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
        } catch { }
    } else {
        & winget settings --enable BypassCertificatePinningForMicrosoftStore --accept-source-agreements | Out-Null
        & winget source update --quiet | Out-Null
    }

    # 3. Cai dat cac phan mem uu tien tai Direct Link tu R2 Cloudflare
    $parallelApps = @(
        @{ Name="EVKey"; Url="https://pub-50d6cf4af6964541b0621bbc9bc26690.r2.dev/EVKey.exe"; WingetId=""; Args="-s" },
        @{ Name="Chrome"; Url="https://pub-50d6cf4af6964541b0621bbc9bc26690.r2.dev/chrome.exe"; WingetId="Google.Chrome"; Args="/silent /install" },
        @{ Name="Klite"; Url="https://pub-50d6cf4af6964541b0621bbc9bc26690.r2.dev/klite.exe"; WingetId="CodecGuide.K-LiteCodecPack.Mega"; Args="/verysilent /norestart /suppressmsgboxes" },
        @{ Name="Telegram"; Url="https://pub-50d6cf4af6964541b0621bbc9bc26690.r2.dev/tele.exe"; WingetId="Telegram.TelegramDesktop"; Args="/VERYSILENT /NORESTART /SUPPRESSMSGBOXES" },
        @{ Name="Ultraview"; Url="https://pub-50d6cf4af6964541b0621bbc9bc26690.r2.dev/ultrav.exe"; WingetId="DucFabulous.UltraViewer"; Args="/S" },
        @{ Name="WinRAR"; Url="https://pub-50d6cf4af6964541b0621bbc9bc26690.r2.dev/winrar.exe"; WingetId="RARLab.WinRAR"; Args="/S" },
        @{ Name="Zalo"; Url="https://pub-50d6cf4af6964541b0621bbc9bc26690.r2.dev/zalo.exe"; WingetId="VNGCorp.Zalo"; Args="/S" },
        @{ Name="Zoom"; Url="https://pub-50d6cf4af6964541b0621bbc9bc26690.r2.dev/zoom.exe"; WingetId="Zoom.Zoom"; Args="/silent" }
    )

    $sequentialApps = @(
        @{ Name="VCRedist x64"; Url="https://pub-50d6cf4af6964541b0621bbc9bc26690.r2.dev/VC_redist.x64.exe"; WingetId="Microsoft.VCRedist.2015+.x64"; Args="/install /quiet /norestart" },
        @{ Name="VCRedist x86"; Url="https://pub-50d6cf4af6964541b0621bbc9bc26690.r2.dev/VC_redist.x86.exe"; WingetId="Microsoft.VCRedist.2015+.x86"; Args="/install /quiet /norestart" }
    )

    Write-Host "`n[Bat dau] Tai va cai dat song song $($parallelApps.Count) phan mem chinh..." -ForegroundColor Cyan
    $jobs = @()
    foreach ($app in $parallelApps) {
        $job = Start-Job -ScriptBlock {
            param($Name, $Url, $WingetId, $ArgsStr)
            $tempDir = "$env:TEMP\MiniAZ_Apps"
            if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }
            $tempExe = "$tempDir\$Name.exe"
            
            $success = $false
            try {
                Invoke-WebRequest -Uri $Url -OutFile $tempExe -UseBasicParsing -ErrorAction Stop
                Write-Output "STATE:$Name:Installing"
                $proc = Start-Process -FilePath $tempExe -ArgumentList $ArgsStr -Wait -PassThru -NoNewWindow
                if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) { 
                    $success = $true 
                    Write-Output "STATE:$Name:Done"
                } else {
                    Write-Output "STATE:$Name:Error"
                }
            } catch { 
                Write-Output "STATE:$Name:Error"
            }

            if (-not $success -and $WingetId) {
                Write-Output "STATE:$Name:Winget"
                $proc = Start-Process winget -ArgumentList "install --id $WingetId --exact --silent --disable-interactivity --accept-package-agreements --accept-source-agreements" -Wait -PassThru -NoNewWindow
                if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq -1978335201) { Write-Output "STATE:$Name:Done" } else { Write-Output "STATE:$Name:Error" }
            }
        } -ArgumentList $app.Name, $app.Url, $app.WingetId, $app.Args
        $jobs += $job
    }

    # 4. Hien thi truc quan tien trinh chay ngam (Bang trang thai dong)
    Write-Host "`n[Tien Trinh] Dang xu ly cac ung dung song song..." -ForegroundColor Cyan
    
    $appStates = @{}
    foreach ($app in $parallelApps) {
        $appStates[$app.Name] = "Downloading"
    }

    $startTop = [Console]::CursorTop
    foreach ($app in $parallelApps) {
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
                        if ($appState -eq "Installing") { $appStates[$appName] += " - Installing" }
                        elseif ($appState -eq "Done") { $appStates[$appName] += " - Done!" }
                        elseif ($appState -eq "Error") { $appStates[$appName] += " - Failed!" }
                        elseif ($appState -eq "Winget") { $appStates[$appName] += " - Winget Fallback" }
                        $newData = $true
                    }
                }
            }
        }
        
        if ($newData) {
            [Console]::SetCursorPosition(0, $startTop)
            foreach ($app in $parallelApps) {
                $line = "   [+] {0} - {1}" -f $app.Name.PadRight(12), $appStates[$app.Name]
                Write-Host $line.PadRight(80) -ForegroundColor Yellow
            }
        }
        Start-Sleep -Milliseconds 200
    }
    
    # Nhan not du lieu cuoi cung (neu co)
    $outputs = Receive-Job -Job $jobs
    if ($outputs) {
        foreach ($out in $outputs) {
            if ($out -match "^STATE:(.+?):(.+)$") {
                $appName = $matches[1]
                $appState = $matches[2]
                if ($appState -eq "Installing") { $appStates[$appName] += " - Installing" }
                elseif ($appState -eq "Done") { $appStates[$appName] += " - Done!" }
                elseif ($appState -eq "Error") { $appStates[$appName] += " - Failed!" }
                elseif ($appState -eq "Winget") { $appStates[$appName] += " - Winget Fallback" }
            }
        }
        [Console]::SetCursorPosition(0, $startTop)
        foreach ($app in $parallelApps) {
            $line = "   [+] {0} - {1}" -f $app.Name.PadRight(12), $appStates[$app.Name]
            Write-Host $line.PadRight(80) -ForegroundColor Yellow
        }
    }
    Remove-Job $jobs | Out-Null
    Wait-Job $configJob, $diskJob | Out-Null
    Remove-Job $configJob, $diskJob | Out-Null

    Write-Host "`n[Bat dau] Cai dat tuan tu cac phan mem nen tang (VC Redist)..." -ForegroundColor Cyan
    foreach ($app in $sequentialApps) {
        Write-Host "-> Dang cai dat: $($app.Name)" -ForegroundColor Yellow
        $tempExe = "$env:TEMP\MiniAZ_Apps\$($app.Name).exe"
        $success = $false
        try {
            Invoke-WebRequest -Uri $app.Url -OutFile $tempExe -UseBasicParsing -ErrorAction Stop
            $proc = Start-Process -FilePath $tempExe -ArgumentList $app.Args -Wait -PassThru -NoNewWindow
            if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010 -or $proc.ExitCode -eq 1638) { 
                $success = $true 
                Write-Host "   [OK] Cài dat thanh cong: $($app.Name)" -ForegroundColor Green
            }
        } catch { }

        if (-not $success) {
            Write-Host "   [Loi] Chuyen sang cai qua Winget cho $($app.Name)..." -ForegroundColor Blue
            $proc = Start-Process winget -ArgumentList "install --id $($app.WingetId) --exact --silent --disable-interactivity --accept-package-agreements --accept-source-agreements" -Wait -PassThru -NoNewWindow
            if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq -1978335201) { Write-Host "   [OK] Cài dat thanh cong qua Winget: $($app.Name)" -ForegroundColor Green }
        }
    }

    Write-Host "`n[Hoan tat] Toan bo qua trinh cai dat va thiet lap ket thuc!" -ForegroundColor Green
}

function Show-SystemInfo {
    Write-Host "`n[He thong] Dang tai va chay script lay thong tin he thong..." -ForegroundColor Cyan
    try {
        irm https://raw.githubusercontent.com/mson-ssh/miniapps/main/config/Get-info.ps1 | iex
        Write-Host "[OK] Da chay thanh cong va xuat file ra Desktop!" -ForegroundColor Green
    }
    catch {
        Write-Host "[LOI] Khong the tai script Get-info.ps1 tu GitHub: $_" -ForegroundColor Red
    }
}

function Show-Other {
    Write-Host "`n[Thong bao] Chuc nang nay dang duoc phat trien. Vui long quay lai sau!" -ForegroundColor Yellow
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
        "1. Install Necessary App",
        "2. Information",
        "3. Other",
        "4. Exit"
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
    $optionsCount = 4

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
        elseif ($key -eq 'Enter') {
            break
        }
        elseif ($key -eq 'Escape') {
            $selectedIndex = 3; break
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
        Install-NecessaryApps
    }
    elseif ($choice -eq 1) {
        Show-SystemInfo
    }
    elseif ($choice -eq 2) {
        Show-Other
    }
    elseif ($choice -eq 3) {
        Write-Host "Dang thoat chuong trinh. Chuc mot ngay tot lanh!" -ForegroundColor Green
        exit
    }

    Write-Host "`nNhan phim bat ky de quay lai Menu..." -ForegroundColor Gray
    [System.Console]::ReadKey($true) | Out-Null
}