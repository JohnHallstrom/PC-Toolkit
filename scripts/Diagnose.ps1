<#
.SYNOPSIS
    Collects diagnostic information about a slow Windows computer. Makes no system changes.

.DESCRIPTION
    Saves a readable HTML report and a JSON report for Repair.ps1 in Reports\<computer>_<date>.

.PARAMETER SkipUpdateCheck
    Do not search Windows Update for available updates.

.PARAMETER NoElevation
    Do not request administrator permissions. Some checks may be incomplete.

.PARAMETER Quiet
    Do not open the report or start the local report server when finished.

.PARAMETER DryRunRepairs
    Fixes chosen in the browser are only simulated (Repair.ps1 -WhatIf). For testing.

.PARAMETER NoBrowser
    Start the report server without opening the web browser.

.PARAMETER Theme
    Sparkollen (default): Swedish texts and a dog-sport themed report. Neutral: plain English report.
#>
[CmdletBinding()]
param(
    [switch]$SkipUpdateCheck,
    [switch]$NoElevation,
    [switch]$Quiet,
    [switch]$DryRunRepairs,
    [switch]$NoBrowser,
    [ValidateSet('Sparkollen', 'Neutral')][string]$Theme = 'Sparkollen'
)

$WhatIfPreference = $false
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'Common.ps1')
Set-ToolkitTheme $Theme
$sparkollen = $script:ToolkitTheme -eq 'Sparkollen'

if (-not (Test-IsAdmin) -and -not $NoElevation) {
    try {
        Write-Host (T 'Restarting with administrator permissions...')
        Start-AsAdmin -ScriptPath $PSCommandPath -Parameters $PSBoundParameters
        return
    } catch {
        Write-Warning (T 'Administrator permission was not granted. Some checks may be incomplete.')
    }
}

$isAdmin = Test-IsAdmin
$startedAt = Get-Date
$script:findings = New-Object System.Collections.Generic.List[object]
$script:scriptErrors = New-Object System.Collections.Generic.List[string]
$script:report = [ordered]@{}
$script:report.Drives = [ordered]@{ DriveProblem = $false; CheckCompleted = $false; Physical = @(); LogEvents = @(); SmartWarnings = 0 }
$script:systemEvents = @()

function Add-Finding {
    param(
        [string]$Id,
        [ValidateSet('Critical', 'Warning', 'Info', 'OK')][string]$Severity,
        [string]$Category,
        [string]$Title,
        [string]$Details = '',
        [string]$Recommendation = '',
        [ValidateSet('Automatic', 'Ask', 'Manual', '')][string]$Action = ''
    )
    $script:findings.Add([pscustomobject]@{
        Id = $Id
        Severity = $Severity
        Category = $Category
        Title = $Title
        Details = $Details
        Recommendation = $Recommendation
        Action = $Action
    })
}

function Invoke-Check([string]$Name, [scriptblock]$Code) {
    $script:stepNumber++
    Write-Host ("[{0,2}/11] {1}..." -f $script:stepNumber, $Name) -ForegroundColor Cyan
    try { & $Code } catch {
        $script:scriptErrors.Add((Join-T @($Name, $_.Exception.Message) ': '))
        Write-Warning (T "Could not complete '{0}': {1}" $Name $_.Exception.Message)
    }
}

function Get-EventData($Event) {
    $data = @{}
    foreach ($item in ([xml]$Event.ToXml()).Event.EventData.Data) { $data[$item.Name] = $item.'#text' }
    $data
}

$script:stepNumber = 0
Write-Section (T 'PC Toolkit {0} - Diagnosis of {1}' $script:ToolkitVersion $env:COMPUTERNAME)
if (-not $isAdmin) { Write-Warning (T 'Running without administrator permissions; drive health and some logs may be unavailable.') }
Write-Host (T 'Tip: run this when the computer feels slow, for example just after startup.') -ForegroundColor DarkGray

Invoke-Check (T 'System information') {
    $os = Get-CimInstance Win32_OperatingSystem
    $computer = Get-CimInstance Win32_ComputerSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $bios = Get-CimInstance Win32_BIOS
    $windowsVersion = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    $uptime = (Get-Date) - $os.LastBootUpTime
    $fastStartup = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction SilentlyContinue).HiberbootEnabled -eq 1
    $hibernation = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction SilentlyContinue).HibernateEnabled -eq 1
    $rebootPending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')

    $script:report.System = [ordered]@{
        ComputerName = $env:COMPUTERNAME
        Manufacturer = $computer.Manufacturer
        Model = $computer.Model
        Windows = $os.Caption
        Version = $windowsVersion.DisplayVersion
        Build = "$($os.BuildNumber).$($windowsVersion.UBR)"
        Processor = "$($cpu.Name)".Trim()
        Cores = $cpu.NumberOfCores
        Threads = $cpu.NumberOfLogicalProcessors
        MemoryGB = [math]::Round($computer.TotalPhysicalMemory / 1GB, 1)
        BiosVersion = $bios.SMBIOSBIOSVersion
        BiosDate = $(if ($bios.ReleaseDate) { $bios.ReleaseDate.ToString('yyyy-MM-dd') })
        LastBoot = $os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm')
        UptimeDays = [math]::Round($uptime.TotalDays, 1)
        FastStartup = [bool]($fastStartup -and $hibernation)
        RebootPending = [bool]$rebootPending
    }
    if ($uptime.TotalDays -gt 7) {
        Add-Finding -Id 'UPTIME_LONG' -Severity Warning -Category System -Title (T 'The computer has not restarted for {0} days' ([int]$uptime.TotalDays)) `
            -Details (T 'Last restart: {0}.' $script:report.System.LastBoot) `
            -Recommendation (T 'Restart the computer (choose Restart, not Shut down).') -Action Ask
    }
    if ($rebootPending) {
        Add-Finding -Id 'REBOOT_PENDING' -Severity Warning -Category System -Title (T 'A restart is pending to finish updates') `
            -Recommendation (T 'Restart the computer.') -Action Ask
    }
}

Invoke-Check (T 'Physical drives and drive health') {
    $systemLetter = $env:SystemDrive.Substring(0, 1)
    $systemDiskNumber = $null
    try { $systemDiskNumber = "$((Get-Partition -DriveLetter $systemLetter -ErrorAction Stop).DiskNumber)" } catch {}
    $physicalDrives = @()
    foreach ($drive in @(Get-PhysicalDisk -ErrorAction Stop)) {
        $reliability = $null
        try { $reliability = $drive | Get-StorageReliabilityCounter -ErrorAction Stop } catch {}
        $mediaType = ConvertTo-MediaType $drive.MediaType
        $busType = ConvertTo-BusType $drive.BusType
        if ($mediaType -eq 'Unknown' -and $busType -eq 'NVMe') { $mediaType = 'SSD' }
        $physicalDrives += [pscustomobject]@{
            Number = "$($drive.DeviceId)"
            Name = $drive.FriendlyName
            MediaType = $mediaType
            BusType = $busType
            SizeGB = [math]::Round($drive.Size / 1GB, 0)
            Health = ConvertTo-HealthStatus $drive.HealthStatus
            IsSystemDrive = ("$($drive.DeviceId)" -eq $systemDiskNumber)
            WearPercent = $(if ($reliability -and $null -ne $reliability.Wear) { [int]$reliability.Wear })
            TemperatureC = $(if ($reliability -and $reliability.Temperature -gt 0) { [int]$reliability.Temperature })
            UncorrectableReadErrors = $(if ($reliability) { $reliability.ReadErrorsUncorrected })
            UncorrectableWriteErrors = $(if ($reliability) { $reliability.WriteErrorsUncorrected })
            PowerOnHours = $(if ($reliability) { $reliability.PowerOnHours })
        }
    }
    $smartWarnings = @(Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction SilentlyContinue |
        Where-Object PredictFailure)
    $systemEvents = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2, 3; StartTime = (Get-Date).AddDays(-30) } `
        -MaxEvents 5000 -ErrorAction SilentlyContinue)
    $script:systemEvents = $systemEvents
    $driveEvents = @($systemEvents | Where-Object {
        ($_.ProviderName -eq 'disk' -and $_.Id -in 7, 11, 51, 52, 153) -or
        ($_.ProviderName -match '^(stornvme|storahci|iaStor\w*|nvme\w*)$' -and $_.Id -in 9, 11, 129) -or
        ($_.ProviderName -match 'Ntfs' -and $_.Id -eq 55)
    })
    $badBlocks = @($driveEvents | Where-Object { $_.ProviderName -eq 'disk' -and $_.Id -eq 7 }).Count
    $driveProblem = $false
    $problemDetails = @()
    foreach ($drive in $physicalDrives) {
        if ($drive.Health -notin 'Healthy', 'Unknown', '') {
            $driveProblem = $true
            $problemDetails += T "{0} reports health '{1}'." $drive.Name $drive.Health
        }
        if ($drive.UncorrectableReadErrors -gt 0 -or $drive.UncorrectableWriteErrors -gt 0) {
            $driveProblem = $true
            $problemDetails += T '{0} has uncorrectable read or write errors.' $drive.Name
        }
        if ($drive.WearPercent -ge 90) {
            $driveProblem = $true
            $problemDetails += T '{0} reports {1}% wear.' $drive.Name $drive.WearPercent
        } elseif ($drive.WearPercent -ge 70) {
            Add-Finding -Id 'DRIVE_WEAR' -Severity Warning -Category Drive -Title (T '{0} reports {1}% wear' $drive.Name $drive.WearPercent) `
                -Recommendation (T 'Plan to replace the drive and keep a current backup.') -Action Manual
        }
        if ($drive.TemperatureC -ge 70) {
            Add-Finding -Id 'DRIVE_HOT' -Severity Warning -Category Drive -Title (T '{0} is hot ({1} C)' $drive.Name $drive.TemperatureC) `
                -Recommendation (T 'Check the computer airflow. NVMe drives may need a heatsink.') -Action Manual
        }
    }
    if ($smartWarnings.Count) {
        $driveProblem = $true
        $problemDetails += T 'SMART predicts that a drive may fail soon.'
    }
    if ($badBlocks) {
        $driveProblem = $true
        $problemDetails += T 'The system log contains {0} bad-block events (disk event 7).' $badBlocks
    }
    if ($driveEvents.Count -ge 10) {
        $driveProblem = $true
        $problemDetails += T 'The system log contains {0} drive-related errors or warnings in the last 30 days.' $driveEvents.Count
    }
    if ($driveProblem) {
        Add-Finding -Id 'DRIVE_FAILING' -Severity Critical -Category Drive -Title (T 'A drive may be failing') `
            -Details (Join-T $problemDetails ' ') `
            -Recommendation (T 'BACK UP IMPORTANT FILES NOW (Documents, Pictures, Desktop, game saves). Do not run intensive repairs first. Replace the drive, ideally by cloning it to a new SSD.') `
            -Action Manual
    } elseif ($driveEvents.Count) {
        Add-Finding -Id 'DRIVE_WARNINGS' -Severity Warning -Category Drive -Title (T '{0} drive-related log events in the last 30 days' $driveEvents.Count) `
            -Details (($driveEvents | Group-Object ProviderName, Id | ForEach-Object { "$($_.Name): $($_.Count)" }) -join '; ') `
            -Recommendation (T 'Check the drive with CrystalDiskInfo and keep a current backup.') -Action Manual
    }
    $systemDrive = $physicalDrives | Where-Object IsSystemDrive | Select-Object -First 1
    if ($systemDrive -and $systemDrive.MediaType -eq 'HDD') {
        Add-Finding -Id 'SYSTEM_DRIVE_HDD' -Severity Critical -Category Drive -Title (T 'Windows is installed on a mechanical hard drive (HDD)') `
            -Details (T '{0} ({1} GB). This is a common cause of slow startup and app loading.' $systemDrive.Name $systemDrive.SizeGB) `
            -Recommendation (T 'Clone Windows to an SSD. This is often the single biggest performance improvement.') -Action Manual
    } elseif ($systemDrive -and $systemDrive.MediaType -eq 'SSD' -and -not $driveProblem) {
        Add-Finding -Id 'SYSTEM_DRIVE_OK' -Severity OK -Category Drive -Title (T 'Windows is on a healthy {0} SSD' $systemDrive.BusType)
    } elseif (-not $systemDrive) {
        Add-Finding -Id 'SYSTEM_DRIVE_UNKNOWN' -Severity Info -Category Drive -Title (T 'Could not identify the type of the Windows drive') `
            -Recommendation (T 'Check the drive with CrystalDiskInfo.') -Action Manual
    }
    $script:report.Drives = [ordered]@{
        DriveProblem = $driveProblem
        CheckCompleted = $true
        Physical = $physicalDrives
        LogEvents = @($driveEvents | Group-Object ProviderName, Id | ForEach-Object {
            [pscustomobject]@{ SourceAndId = $_.Name; Count = $_.Count; Latest = $_.Group[0].TimeCreated.ToString('yyyy-MM-dd HH:mm') }
        })
        SmartWarnings = $smartWarnings.Count
    }
}

Invoke-Check (T 'Free disk space and game libraries') {
    $volumes = @()
    foreach ($volume in @(Get-Volume -ErrorAction Stop | Where-Object {
        $_.DriveLetter -and "$($_.DriveType)" -in 'Fixed', '3' -and $_.Size -gt 0
    })) {
        $diskNumber = $null
        try { $diskNumber = "$((Get-Partition -DriveLetter $volume.DriveLetter -ErrorAction Stop).DiskNumber)" } catch {}
        $physicalDrive = $script:report.Drives.Physical | Where-Object Number -eq $diskNumber | Select-Object -First 1
        $volumes += [pscustomobject]@{
            Drive = "$($volume.DriveLetter):"
            Label = $volume.FileSystemLabel
            SizeGB = [math]::Round($volume.Size / 1GB, 1)
            FreeGB = [math]::Round($volume.SizeRemaining / 1GB, 1)
            FreePercent = [math]::Round(100 * $volume.SizeRemaining / $volume.Size, 0)
            MediaType = $(if ($physicalDrive) { $physicalDrive.MediaType } else { 'Unknown' })
            PhysicalDrive = $(if ($physicalDrive) { $physicalDrive.Name })
        }
    }
    $script:report.Volumes = $volumes
    $systemVolume = $volumes | Where-Object Drive -eq $env:SystemDrive | Select-Object -First 1
    if ($systemVolume) {
        $details = T '{0} GB free of {1} GB ({2}%).' $systemVolume.FreeGB $systemVolume.SizeGB $systemVolume.FreePercent
        if ($systemVolume.FreePercent -lt 10 -or $systemVolume.FreeGB -lt 15) {
            Add-Finding -Id 'LOW_SYSTEM_SPACE' -Severity Critical -Category Drive -Title (T 'Almost no space left on {0}' $systemVolume.Drive) `
                -Details $details -Recommendation (T 'Clean temporary files and move or uninstall large games or apps.') -Action Automatic
        } elseif ($systemVolume.FreePercent -lt 20 -or $systemVolume.FreeGB -lt 30) {
            Add-Finding -Id 'LOW_SYSTEM_SPACE' -Severity Warning -Category Drive -Title (T 'Low free space on {0}' $systemVolume.Drive) `
                -Details $details -Recommendation (T 'Clean temporary files and consider moving games to another drive.') -Action Automatic
        } else {
            Add-Finding -Id 'SYSTEM_SPACE_OK' -Severity OK -Category Drive -Title (T 'Plenty of free space on {0}' $systemVolume.Drive) -Details $details
        }
    }
    foreach ($volume in $volumes | Where-Object { $_.Drive -ne $env:SystemDrive -and $_.FreePercent -lt 5 }) {
        Add-Finding -Id 'LOW_OTHER_SPACE' -Severity Info -Category Drive -Title (T 'Almost no space left on {0}' $volume.Drive) `
            -Details (T '{0} GB free of {1} GB.' $volume.FreeGB $volume.SizeGB) -Recommendation (T 'Review games and files on this drive.') -Action Manual
    }
    $gameLibraries = @()
    $steamPath = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    if (-not $steamPath) { $steamPath = (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -ErrorAction SilentlyContinue).InstallPath }
    if ($steamPath) {
        $libraryFile = Join-Path $steamPath 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $libraryFile) {
            $gameLibraries += Select-String -LiteralPath $libraryFile -Pattern '"path"\s+"([^"]+)"' | ForEach-Object {
                [pscustomobject]@{ Platform = 'Steam'; Path = ($_.Matches[0].Groups[1].Value -replace '\\\\', '\') }
            }
        }
    }
    $script:report.GameLibraries = @($gameLibraries | ForEach-Object {
        $letter = if ($_.Path -match '^([A-Za-z]:)') { $Matches[1].ToUpper() } else { '' }
        $volume = $volumes | Where-Object Drive -eq $letter | Select-Object -First 1
        [pscustomobject]@{ Platform = $_.Platform; Path = $_.Path; MediaType = $(if ($volume) { $volume.MediaType } else { 'Unknown' }) }
    })
    $gamesOnHdd = @($script:report.GameLibraries | Where-Object MediaType -eq 'HDD')
    if ($gamesOnHdd.Count) {
        Add-Finding -Id 'GAMES_ON_HDD' -Severity Warning -Category Drive -Title (T 'Some Steam libraries are on a mechanical hard drive') `
            -Details (($gamesOnHdd | ForEach-Object Path) -join '; ') `
            -Recommendation (T 'Move frequently played games to an SSD (Steam: Settings > Storage > Move).') -Action Manual
    }
}

Invoke-Check (T 'Memory (RAM)') {
    $os = Get-CimInstance Win32_OperatingSystem
    $computer = Get-CimInstance Win32_ComputerSystem
    $modules = @(Get-CimInstance Win32_PhysicalMemory)
    $totalGB = [math]::Round(($modules | Measure-Object Capacity -Sum).Sum / 1GB, 0)
    $usedPercent = [math]::Round(100 * (1 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize), 0)
    $memoryTypeCode = ($modules | Select-Object -First 1).SMBIOSMemoryType
    $memoryType = switch ($memoryTypeCode) { 24 { 'DDR3' } 26 { 'DDR4' } 34 { 'DDR5' } default { "Unknown ($memoryTypeCode)" } }
    $configuredSpeed = ($modules | Measure-Object ConfiguredClockSpeed -Maximum).Maximum
    $moduleMaxSpeed = ($modules | Measure-Object Speed -Maximum).Maximum
    $pageFiles = @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)
    $isLaptop = $computer.PCSystemType -eq 2
    $script:report.Memory = [ordered]@{
        TotalGB = $totalGB
        UsedPercent = $usedPercent
        Type = $memoryType
        ConfiguredMHz = $configuredSpeed
        ModuleMaxMHz = $moduleMaxSpeed
        ModuleCount = $modules.Count
        Modules = @($modules | ForEach-Object {
            [pscustomobject]@{ Location = $_.DeviceLocator; GB = [math]::Round($_.Capacity / 1GB, 0); MHz = $_.ConfiguredClockSpeed; Manufacturer = $_.Manufacturer; PartNumber = "$($_.PartNumber)".Trim() }
        })
        AutomaticPageFile = [bool]$computer.AutomaticManagedPagefile
        PageFiles = @($pageFiles | ForEach-Object { [pscustomobject]@{ Path = $_.Name; SizeMB = $_.AllocatedBaseSize } })
        IsLaptop = $isLaptop
    }
    if ($totalGB -lt 8) {
        Add-Finding -Id 'LOW_RAM' -Severity Critical -Category Memory -Title (T 'Only {0} GB of RAM' $totalGB) -Recommendation (T 'Upgrade to at least 16 GB.') -Action Manual
    } elseif ($totalGB -lt 16) {
        Add-Finding -Id 'LOW_RAM' -Severity Warning -Category Memory -Title (T '{0} GB of RAM is limited for a gaming PC' $totalGB) -Recommendation (T 'Consider upgrading to 16–32 GB.') -Action Manual
    }
    if ($usedPercent -ge 85) {
        Add-Finding -Id 'HIGH_RAM_USE' -Severity Warning -Category Memory -Title (T '{0}% of memory is currently in use' $usedPercent) `
            -Recommendation (T 'Review the processes using the most memory and disable unnecessary startup apps.') -Action Ask
    }
    if (-not $isLaptop -and (($memoryType -eq 'DDR4' -and $configuredSpeed -le 2400) -or ($memoryType -eq 'DDR5' -and $configuredSpeed -le 4800))) {
        Add-Finding -Id 'XMP_OFF' -Severity Warning -Category Memory -Title (T 'Memory is running at its base speed ({0} MHz {1})' $configuredSpeed $memoryType) `
            -Details (T 'Gaming PCs often support faster memory, which may need to be enabled in BIOS (XMP/EXPO/DOCP).') `
            -Recommendation (T 'Check the rated memory speed, then enable the matching XMP/EXPO/DOCP profile in BIOS.') -Action Manual
    }
    if (-not $isLaptop -and $modules.Count -eq 1) {
        Add-Finding -Id 'SINGLE_CHANNEL_RAM' -Severity Info -Category Memory -Title (T 'Only one memory module is installed') `
            -Recommendation (T 'Two matched modules can provide higher memory bandwidth.') -Action Manual
    }
    if ($pageFiles.Count -eq 0 -and -not $computer.AutomaticManagedPagefile) {
        Add-Finding -Id 'PAGE_FILE_OFF' -Severity Warning -Category Memory -Title (T 'The Windows page file appears to be disabled') `
            -Recommendation (T 'Let Windows manage the page file automatically.') -Action Ask
    }
}

Invoke-Check (T 'Current CPU and disk activity (10 seconds)') {
    $previousCpu = @{}
    Get-Process | ForEach-Object { if ($_.CPU) { $previousCpu[$_.Id] = $_.CPU } }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $samples = @()
    for ($i = 0; $i -lt 10; $i++) {
        $disk = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'" -ErrorAction SilentlyContinue
        $cpu = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction SilentlyContinue
        if ($disk -and $cpu) { $samples += [pscustomobject]@{ Disk = [math]::Max(0, 100 - [int]$disk.PercentIdleTime); CPU = [int]$cpu.PercentProcessorTime } }
        Start-Sleep -Milliseconds 900
    }
    $seconds = $timer.Elapsed.TotalSeconds
    $processes = @(Get-Process | Where-Object { $_.Id -ne 0 -and $_.Name -ne 'Idle' })
    $topCpu = @($processes | ForEach-Object {
        $previous = $previousCpu[$_.Id]
        if ($null -ne $previous -and $_.CPU) {
            [pscustomobject]@{ Process = $_.Name; CPUPercent = [math]::Round(100 * ($_.CPU - $previous) / $seconds / [Environment]::ProcessorCount, 1); MemoryMB = [math]::Round($_.WorkingSet64 / 1MB, 0) }
        }
    } | Sort-Object CPUPercent -Descending | Select-Object -First 10)
    $topMemory = @($processes | Group-Object Name | ForEach-Object {
        [pscustomobject]@{ Process = $_.Name; Instances = $_.Count; MemoryMB = [math]::Round(($_.Group | Measure-Object WorkingSet64 -Sum).Sum / 1MB, 0) }
    } | Sort-Object MemoryMB -Descending | Select-Object -First 10)
    $diskAverage = if ($samples.Count) { [math]::Round(($samples | Measure-Object Disk -Average).Average, 0) } else { $null }
    $cpuAverage = if ($samples.Count) { [math]::Round(($samples | Measure-Object CPU -Average).Average, 0) } else { $null }
    $script:report.Activity = [ordered]@{ DiskActivePercent = $diskAverage; CPUPercent = $cpuAverage; ProcessCount = $processes.Count; TopCPU = $topCpu; TopMemory = $topMemory }
    if ($diskAverage -ge 80) {
        Add-Finding -Id 'HIGH_DISK_ACTIVITY' -Severity Warning -Category Performance -Title (T 'The disk was active {0}% of the sample period' $diskAverage) `
            -Details (T 'If no large task was running, this may indicate a slow drive or heavy background activity.') `
            -Recommendation (T 'In Task Manager, check which processes are using the disk.') -Action Manual
    }
    if ($cpuAverage -ge 70) {
        Add-Finding -Id 'HIGH_CPU_ACTIVITY' -Severity Warning -Category Performance -Title (T 'CPU usage averaged {0}% during the sample' $cpuAverage) `
            -Details (T 'Top CPU processes: {0}' (($topCpu | Select-Object -First 3 | ForEach-Object { "$($_.Process) ($($_.CPUPercent)%)" }) -join ', ')) `
            -Recommendation (T 'Review the processes above. Unknown processes using high CPU may need investigation.') -Action Manual
    }
}

Invoke-Check (T 'Startup apps, scheduled tasks, and services') {
    $entries = @(Get-StartupEntries)
    $enabledEntries = @($entries | Where-Object Enabled)
    $scheduledTasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        "$($_.State)" -ne 'Disabled' -and $_.TaskPath -notlike '\Microsoft\*'
    } | ForEach-Object {
        [pscustomobject]@{
            Name = $_.TaskName
            Folder = $_.TaskPath
            Triggers = (@($_.Triggers | ForEach-Object { $_.CimClass.CimClassName -replace '^MSFT_Task', '' -replace 'Trigger$', '' }) -join ', ')
            Runs = (@($_.Actions | ForEach-Object { $_.Execute }) -join '; ')
        }
    })
    $thirdPartyServices = @(Get-CimInstance Win32_Service -Filter "StartMode='Auto'" -ErrorAction SilentlyContinue | Where-Object {
        $_.PathName -and $_.PathName -notmatch '\\Windows\\(System32|SysWOW64|servicing|Microsoft\.NET)\\' -and $_.PathName -notmatch 'Windows Defender|Microsoft\\|Microsoft Update'
    } | ForEach-Object { [pscustomobject]@{ Name = $_.Name; DisplayName = $_.DisplayName; Status = $_.State } })
    $script:report.Startup = [ordered]@{
        EnabledCount = $enabledEntries.Count
        Entries = @($entries | Select-Object Name, Enabled, Suggestion, Scope, Command)
        ScheduledTasks = $scheduledTasks
        ThirdPartyServices = $thirdPartyServices
    }
    $canDisable = @($enabledEntries | Where-Object Suggestion -eq 'Can be disabled')
    if ($enabledEntries.Count -ge 8 -or $canDisable.Count -ge 3) {
        Add-Finding -Id 'MANY_STARTUP_APPS' -Severity Warning -Category Startup -Title (T '{0} apps start with Windows' $enabledEntries.Count) `
            -Details (T 'Likely candidates to disable: {0}' $(if ($canDisable) { $canDisable.Name -join ', ' } else { T 'None identified' })) `
            -Recommendation (T 'Disable apps that are not needed immediately after sign-in. They still work when opened manually.') -Action Ask
    } elseif ($canDisable.Count) {
        Add-Finding -Id 'STARTUP_APPS' -Severity Info -Category Startup -Title (T '{0} startup apps may be optional' $canDisable.Count) `
            -Details ($canDisable.Name -join ', ') -Action Ask
    }
}

Invoke-Check (T 'Windows startup times') {
    $logName = 'Microsoft-Windows-Diagnostics-Performance/Operational'
    $starts = @(Get-WinEvent -FilterHashtable @{ LogName = $logName; Id = 100 } -MaxEvents 5 -ErrorAction SilentlyContinue | ForEach-Object {
        $eventData = Get-EventData $_
        [pscustomobject]@{
            Date = $_.TimeCreated.ToString('yyyy-MM-dd HH:mm')
            TotalSeconds = [math]::Round([double]$eventData['BootTime'] / 1000, 0)
            ToDesktopSeconds = [math]::Round([double]$eventData['MainPathBootTime'] / 1000, 0)
            PostLoginSeconds = [math]::Round([double]$eventData['BootPostBootTime'] / 1000, 0)
        }
    })
    $slowdowns = @(Get-WinEvent -FilterHashtable @{ LogName = $logName; Id = 101..110; StartTime = (Get-Date).AddDays(-60) } -ErrorAction SilentlyContinue | ForEach-Object {
        $eventData = Get-EventData $_
        $name = if ($eventData['FriendlyName']) { $eventData['FriendlyName'] } elseif ($eventData['Name']) { $eventData['Name'] } else { $eventData['FileName'] }
        [pscustomobject]@{ Name = $name; DelayMilliseconds = [double]$eventData['DegradationTime'] }
    } | Where-Object Name | Group-Object Name | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Count = $_.Count; AverageDelaySeconds = [math]::Round(($_.Group | Measure-Object DelayMilliseconds -Average).Average / 1000, 1) }
    } | Sort-Object AverageDelaySeconds -Descending | Select-Object -First 10)
    $script:report.Boot = [ordered]@{ RecentStarts = $starts; Slowdowns = $slowdowns }
    if ($starts.Count) {
        $average = [math]::Round(($starts | Measure-Object TotalSeconds -Average).Average, 0)
        $script:report.Boot.AverageSeconds = $average
        if ($average -ge 90) {
            $severity = if ($average -ge 180) { 'Critical' } else { 'Warning' }
            Add-Finding -Id 'SLOW_STARTUP' -Severity $severity -Category Startup -Title (T 'Startup takes an average of {0} seconds' $average) `
                -Details (T 'Largest recorded delays: {0}' $(if ($slowdowns) { (($slowdowns | Select-Object -First 5 | ForEach-Object { "$($_.Name) (+$($_.AverageDelaySeconds)s)" }) -join ', ') } else { T 'Unknown' })) `
                -Recommendation (T 'Review the startup apps and delays listed in the report.') -Action Ask
        } else {
            Add-Finding -Id 'STARTUP_OK' -Severity OK -Category Startup -Title (T 'Startup takes an average of {0} seconds' $average)
        }
    }
}

Invoke-Check (T 'Installed apps and security') {
    $programs = @(Get-InstalledPrograms)
    $unwanted = @(Get-UnwantedPrograms $programs)
    $script:report.Programs = [ordered]@{
        Count = $programs.Count
        Unwanted = @($unwanted | Select-Object Name, Publisher, Reason)
        All = @($programs | Select-Object Name, Version, Publisher, SizeMB)
    }
    if ($unwanted.Count) {
        Add-Finding -Id 'UNWANTED_APPS' -Severity Warning -Category Apps -Title (T '{0} potentially unwanted apps found' $unwanted.Count) `
            -Details ($unwanted.Name -join ', ') -Recommendation (T 'Review and uninstall apps you do not want.') -Action Ask
    }
    $antivirus = @(Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction SilentlyContinue | ForEach-Object {
        [pscustomobject]@{ Name = $_.displayName; Active = [bool]($_.productState -band 0x1000); Updated = -not [bool]($_.productState -band 0x10) }
    })
    $defender = $null
    try { $defender = Get-MpComputerStatus -ErrorAction Stop } catch {}
    $defenderActive = [bool]($defender -and $defender.AntivirusEnabled -and "$($defender.AMRunningMode)" -in 'Normal', '')
    $script:report.Security = [ordered]@{
        Antivirus = $antivirus
        DefenderActive = $defenderActive
        DefenderRealtime = $(if ($defender) { $defender.RealTimeProtectionEnabled })
        SignatureAgeDays = $(if ($defender) { $defender.AntivirusSignatureAge })
        LastQuickScan = $(if ($defender -and $defender.QuickScanEndTime) { $defender.QuickScanEndTime.ToString('yyyy-MM-dd') })
    }
    $activeAntivirus = @($antivirus | Where-Object Active)
    if ($activeAntivirus.Count -ge 2) {
        Add-Finding -Id 'MULTIPLE_ANTIVIRUS' -Severity Warning -Category Security -Title (T 'Multiple antivirus products appear active') `
            -Details ($activeAntivirus.Name -join ', ') -Recommendation (T 'Keep one antivirus product; Microsoft Defender is sufficient for most people.') -Action Ask
    }
    if ($activeAntivirus.Count -eq 0 -and -not $defenderActive) {
        Add-Finding -Id 'NO_ANTIVIRUS' -Severity Critical -Category Security -Title (T 'No active antivirus product was detected') `
            -Recommendation (T 'Enable Microsoft Defender or another trusted antivirus product.') -Action Manual
    }
    if ($defender -and $defender.AntivirusSignatureAge -gt 7) {
        Add-Finding -Id 'DEFENDER_SIGNATURES_OLD' -Severity Warning -Category Security -Title (T 'Defender definitions are {0} days old' $defender.AntivirusSignatureAge) -Action Automatic
    }
}

Invoke-Check (T 'Power settings, TRIM, and temporary files') {
    $powerText = (powercfg /getactivescheme) -join ' '
    $powerGuid = $null
    $powerName = $null
    if ($powerText -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\s*\(([^)]+)\)') {
        $powerGuid = $Matches[1]; $powerName = $Matches[2]
    }
    $trimEnabled = $null
    $trimText = (fsutil behavior query DisableDeleteNotify 2>$null) -join ' '
    if ($trimText -match 'NTFS DisableDeleteNotify\s*=\s*(\d)') { $trimEnabled = $Matches[1] -eq '0' }
    $storagePolicy = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy' -ErrorAction SilentlyContinue
    $storageSense = $storagePolicy.'01' -eq 1
    $script:report.Settings = [ordered]@{
        PowerPlan = $powerName
        PowerPlanGuid = $powerGuid
        TrimEnabled = $trimEnabled
        StorageSense = $storageSense
        FastStartup = $script:report.System.FastStartup
    }
    if ($powerGuid -eq 'a1841308-3540-4fab-bc81-f71556f20b4a') {
        Add-Finding -Id 'POWER_SAVER' -Severity Warning -Category Settings -Title (T 'The active power plan is Power Saver') `
            -Recommendation (T 'Switch to Balanced.') -Action Automatic
    }
    $hasSsd = @($script:report.Drives.Physical | Where-Object MediaType -eq 'SSD').Count -gt 0
    if ($trimEnabled -eq $false -and $hasSsd) {
        Add-Finding -Id 'TRIM_DISABLED' -Severity Warning -Category Settings -Title (T 'TRIM is disabled for SSDs') `
            -Recommendation (T 'Enable TRIM to maintain SSD performance.') -Action Automatic
    }
    if (-not $storageSense) {
        Add-Finding -Id 'STORAGE_SENSE_DISABLED' -Severity Info -Category Settings -Title (T 'Storage Sense is disabled') `
            -Recommendation (T 'Enable it to let Windows clean up temporary files automatically.') -Action Automatic
    }
    $cleanable = @(Get-CleanableFolders | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Path = $_.Path; SizeGB = Get-FolderSizeGB $_.Path }
    })
    $recycleBinSize = Get-FolderSizeGB "${env:SystemDrive}\`$Recycle.Bin"
    $hibernationFile = Get-Item -LiteralPath "$env:SystemDrive\hiberfil.sys" -Force -ErrorAction SilentlyContinue
    $script:report.Cleanable = [ordered]@{
        Folders = $cleanable
        RecycleBinGB = $recycleBinSize
        HibernationFileGB = $(if ($hibernationFile) { [math]::Round($hibernationFile.Length / 1GB, 1) } else { 0 })
        DownloadsGB = Get-FolderSizeGB (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads')
    }
    $cleanableTotal = ($cleanable | Measure-Object SizeGB -Sum).Sum
    if ($cleanableTotal -ge 2) {
        Add-Finding -Id 'CLEANABLE_FILES' -Severity Info -Category Drive -Title (T 'About {0} GB of temporary files and cache can be cleaned' ([math]::Round($cleanableTotal, 1))) -Action Automatic
    }
}

Invoke-Check (T 'Windows errors and reliability') {
    $since = (Get-Date).AddDays(-7)
    $systemErrors = @($script:systemEvents | Where-Object { $_.Level -le 2 -and $_.TimeCreated -ge $since })
    $appErrors = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Level = 1, 2; StartTime = $since } -MaxEvents 3000 -ErrorAction SilentlyContinue)
    $allErrors = @($systemErrors) + @($appErrors)
    $topErrors = @($allErrors | Group-Object ProviderName, Id | Sort-Object Count -Descending | Select-Object -First 12 | ForEach-Object {
        $message = "$($_.Group[0].Message)" -replace '\s+', ' '
        [pscustomobject]@{ SourceAndId = $_.Name; Count = $_.Count; Example = $(if ($message.Length -gt 200) { $message.Substring(0, 200) + '...' } else { $message }) }
    })
    $crashes = @($appErrors | Where-Object { $_.ProviderName -eq 'Application Error' -and $_.Id -eq 1000 } |
        ForEach-Object { "$($_.Properties[0].Value)" } | Group-Object | Sort-Object Count -Descending |
        Select-Object -First 8 | ForEach-Object { [pscustomobject]@{ Program = $_.Name; Crashes = $_.Count } })
    $wheaEvents = @($script:systemEvents | Where-Object ProviderName -eq 'Microsoft-Windows-WHEA-Logger')
    $hardwareErrors = @($wheaEvents | Where-Object { $_.Level -le 2 }).Count
    $correctedHardwareErrors = $wheaEvents.Count - $hardwareErrors
    $unexpectedShutdowns = @($script:systemEvents | Where-Object { $_.ProviderName -eq 'Microsoft-Windows-Kernel-Power' -and $_.Id -eq 41 }).Count
    $stability = $null
    try {
        $stability = Get-CimInstance Win32_ReliabilityStabilityMetrics -ErrorAction Stop |
            Sort-Object TimeGenerated -Descending | Select-Object -First 1 -ExpandProperty SystemStabilityIndex
        if ($null -ne $stability) { $stability = [math]::Round($stability, 1) }
    } catch {}
    $script:report.Errors = [ordered]@{
        StabilityIndex = $stability
        ErrorCount7Days = $allErrors.Count
        MostCommon = $topErrors
        ApplicationCrashes = $crashes
        HardwareErrors30Days = $hardwareErrors
        CorrectedHardwareErrors30Days = $correctedHardwareErrors
        UnexpectedShutdowns30Days = $unexpectedShutdowns
    }
    if ($null -ne $stability -and $stability -lt 5) {
        Add-Finding -Id 'LOW_STABILITY' -Severity Warning -Category Windows -Title (T 'Windows reliability index is {0} out of 10' $stability) `
            -Details (T 'Review Reliability Monitor (perfmon /rel) for more information.') `
            -Recommendation (T 'Check and repair Windows system files with DISM and SFC.') -Action Automatic
    }
    if ($hardwareErrors -gt 0) {
        Add-Finding -Id 'HARDWARE_ERRORS' -Severity Warning -Category Hardware -Title (T '{0} uncorrected hardware errors in the last 30 days' $hardwareErrors) `
            -Details (T 'Possible causes include unstable overclocking/XMP, overheating, or failing hardware.') `
            -Recommendation (T 'Check temperatures with HWiNFO and temporarily disable overclocking.') -Action Manual
    } elseif ($correctedHardwareErrors -ge 100) {
        Add-Finding -Id 'CORRECTED_HARDWARE_ERRORS' -Severity Info -Category Hardware -Title (T '{0} corrected hardware events in the last 30 days' $correctedHardwareErrors) `
            -Details (T 'These are often harmless (for example, corrected PCIe errors), but a high count may warrant investigation.') `
            -Recommendation (T 'If the computer has problems, check BIOS/chipset updates and make sure expansion cards and NVMe drives are seated correctly.') -Action Manual
    }
    if ($unexpectedShutdowns -ge 3) {
        Add-Finding -Id 'UNEXPECTED_SHUTDOWNS' -Severity Warning -Category Hardware -Title (T '{0} unexpected shutdowns in the last 30 days' $unexpectedShutdowns) `
            -Details (T 'Possible causes include overheating, the power supply, unstable overclocking, or forced shutdowns.') `
            -Recommendation (T 'Check temperatures and dust buildup.') -Action Manual
    }
}

Invoke-Check (T 'Graphics driver and Windows Update') {
    $graphics = @(Get-CimInstance Win32_VideoController | ForEach-Object {
        [pscustomobject]@{
            Name = $_.Name
            DriverVersion = $_.DriverVersion
            DriverDate = $(if ($_.DriverDate) { $_.DriverDate.ToString('yyyy-MM-dd') })
            AgeMonths = $(if ($_.DriverDate) { [int](((Get-Date) - $_.DriverDate).TotalDays / 30) })
        }
    })
    foreach ($card in $graphics) {
        if ($card.Name -match 'Microsoft Basic Display') {
            Add-Finding -Id 'BASIC_DISPLAY_DRIVER' -Severity Critical -Category Drivers -Title (T 'The graphics card driver is missing') `
                -Recommendation (T 'Install the graphics driver from NVIDIA, AMD, or Intel.') -Action Manual
        } elseif ($card.Name -match 'NVIDIA|Radeon|Arc' -and $card.AgeMonths -ge 12) {
            Add-Finding -Id 'OLD_GRAPHICS_DRIVER' -Severity Info -Category Drivers -Title (T 'The graphics driver is {0} months old' $card.AgeMonths) `
                -Details $card.Name -Recommendation (T 'Check for an update using the vendor app or official website.') -Action Manual
        }
    }
    $latestHotfix = Get-HotFix -ErrorAction SilentlyContinue | Where-Object InstalledOn |
        Sort-Object InstalledOn -Descending | Select-Object -First 1
    $pendingUpdates = $null
    if (-not $SkipUpdateCheck) {
        Write-Host ('        ' + (T 'Checking for Windows updates (up to 4 minutes)...')) -ForegroundColor DarkGray
        $job = Start-Job -ScriptBlock {
            $session = New-Object -ComObject Microsoft.Update.Session
            $result = $session.CreateUpdateSearcher().Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
            @($result.Updates | ForEach-Object { $_.Title })
        }
        if (Wait-Job $job -Timeout 240) { $pendingUpdates = @(Receive-Job $job -ErrorAction SilentlyContinue) }
        else { $script:scriptErrors.Add((T 'The Windows Update search timed out.')) }
        Remove-Job $job -Force -ErrorAction SilentlyContinue
    }
    $script:report.Updates = [ordered]@{
        GraphicsCards = $graphics
        LatestUpdate = $(if ($latestHotfix) { $latestHotfix.InstalledOn.ToString('yyyy-MM-dd') })
        PendingUpdates = $pendingUpdates
    }
    if ($pendingUpdates -and $pendingUpdates.Count) {
        Add-Finding -Id 'UPDATES_PENDING' -Severity Info -Category Windows -Title (T '{0} Windows updates are available' $pendingUpdates.Count) `
            -Details ($pendingUpdates -join '; ') -Recommendation (T 'Install them through Windows Update.') -Action Automatic
    }
    if ($latestHotfix -and ((Get-Date) - $latestHotfix.InstalledOn).TotalDays -gt 60) {
        Add-Finding -Id 'WINDOWS_UPDATE_OLD' -Severity Warning -Category Windows -Title (T 'No Windows update has been installed since {0}' $latestHotfix.InstalledOn.ToString('yyyy-MM-dd')) `
            -Details (T 'Windows Update may be stuck.') -Recommendation (T 'Run Windows Update; if it fails, repair Windows with DISM and SFC.') -Action Automatic
    }
}

Add-Finding -Id 'CHECK_TEMPERATURES' -Severity Info -Category Hardware -Title (T 'Check temperatures and dust') `
    -Details (T 'PowerShell cannot reliably read CPU and GPU temperatures on all systems.') `
    -Recommendation (T 'Use HWiNFO sensors while gaming. If temperatures are high, check fans, airflow, and dust.') -Action Manual

$severityOrder = @{ Critical = 0; Warning = 1; Info = 2; OK = 3 }
$findings = @($script:findings | Sort-Object { $severityOrder[$_.Severity] }, Category)

# Trial score in the style of an IGP judge's protocol: three phases with 100 points each.
$script:trialPhases = [ordered]@{
    A = @{ Name = 'Tracking'; Covers = 'Drive, memory and performance'; Categories = @('Drive', 'Memory', 'Performance') }
    B = @{ Name = 'Obedience'; Covers = 'Windows, startup and settings'; Categories = @('System', 'Startup', 'Settings', 'Windows', 'Drivers') }
    C = @{ Name = 'Protection'; Covers = 'Security, apps and hardware'; Categories = @('Security', 'Apps', 'Hardware') }
}
function Get-TrialGrade([int]$Points, [int]$Max) {
    $limits = if ($Max -eq 300) { @(286, 270, 240, 220) } else { @(96, 90, 80, 70) }
    if ($Points -ge $limits[0]) { 'Excellent' } elseif ($Points -ge $limits[1]) { 'Very good' } elseif ($Points -ge $limits[2]) { 'Good' } elseif ($Points -ge $limits[3]) { 'Sufficient' } else { 'Insufficient' }
}
function Get-TrialScore($Findings) {
    $deduction = @{ Critical = 30; Warning = 10; Info = 3; OK = 0 }
    $phases = [ordered]@{}
    $total = 0
    foreach ($key in $script:trialPhases.Keys) {
        $points = 100
        foreach ($finding in @($Findings | Where-Object { $_.Category -in $script:trialPhases[$key].Categories -and $_.Id -ne 'CHECK_TEMPERATURES' })) {
            $points -= $deduction[$finding.Severity]
        }
        $points = [math]::Max(0, $points)
        $total += $points
        $phases[$key] = [ordered]@{ Points = $points; Grade = Get-TrialGrade $points 100 }
    }
    [ordered]@{ Total = $total; Grade = Get-TrialGrade $total 300; Phases = $phases }
}

$folderName = "{0}_{1}" -f $env:COMPUTERNAME, $startedAt.ToString('yyyy-MM-dd_HHmm')
$score = Get-TrialScore $findings
$previousReport = Get-ChildItem -LiteralPath $script:ReportsRoot -Directory -Filter "$($env:COMPUTERNAME)_*" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -lt $folderName -and (Test-Path -LiteralPath (Join-Path $_.FullName 'diagnostic-report.json')) } |
    Sort-Object Name -Descending | Select-Object -First 1
if ($previousReport) {
    try {
        $previousMeta = (Get-Content -LiteralPath (Join-Path $previousReport.FullName 'diagnostic-report.json') -Raw | ConvertFrom-Json).Meta
        if ($previousMeta.Score) { $score.Previous = [ordered]@{ Total = [int]$previousMeta.Score.Total; Date = $previousMeta.Date } }
    } catch {}
}
$runTheme = $script:ToolkitTheme
$themeReports = [ordered]@{}
foreach ($themeName in @($runTheme) + @($script:Themes | Where-Object { $_ -ne $runTheme })) {
    $themeReports[$themeName] = if ($themeName -eq $runTheme) { 'diagnostic-report.html' } else { "diagnostic-report-$($themeName.ToLowerInvariant()).html" }
}
$script:report.Meta = [ordered]@{
    Version = $script:ToolkitVersion
    Date = $startedAt.ToString('yyyy-MM-dd HH:mm')
    RanAsAdmin = $isAdmin
    DurationSeconds = [math]::Round(((Get-Date) - $startedAt).TotalSeconds, 0)
    Theme = $runTheme
    ThemeReports = $themeReports
    Score = $score
    ScriptErrors = @($script:scriptErrors)
    MissingTranslations = @()
}
$script:report.Findings = $findings
foreach ($finding in $findings) {
    $texts = [ordered]@{}
    foreach ($themeName in $script:Themes) {
        $texts[$themeName] = [ordered]@{
            Title = ConvertTo-ThemeText $finding.Title $themeName
            Details = ConvertTo-ThemeText $finding.Details $themeName
            Recommendation = ConvertTo-ThemeText $finding.Recommendation $themeName
        }
    }
    $finding | Add-Member -NotePropertyName Texts -NotePropertyValue $texts -Force
}
$outputFolder = Join-Path $script:ReportsRoot $folderName
New-Item -ItemType Directory -Path $outputFolder -Force | Out-Null
$jsonPath = Join-Path $outputFolder 'diagnostic-report.json'
$htmlPath = Join-Path $outputFolder 'diagnostic-report.html'
$script:report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

function ConvertTo-SafeHtml([string]$Text) { [System.Net.WebUtility]::HtmlEncode("$Text") }

$script:labelOverrides = @{
    CPUPercent = 'CPU usage (%)'; DiskActivePercent = 'Disk busy (%)'; ProcessCount = 'Running processes'
    TopCPU = 'Top processes by CPU'; TopMemory = 'Top processes by memory'
    UptimeDays = 'Uptime (days)'; MemoryGB = 'Memory (GB)'; BiosVersion = 'BIOS version'; BiosDate = 'BIOS date'
    DriveProblem = 'Drive problem detected'; CheckCompleted = 'Drive check completed'; SmartWarnings = 'SMART warnings'
    Physical = 'Physical drives'; LogEvents = 'Drive log events (30 days)'; IsSystemDrive = 'System drive'
    TemperatureC = "Temperature ($([char]0xB0)C)"; PowerOnHours = 'Power-on hours'; IsLaptop = 'Laptop'
    Modules = 'Memory modules'; PageFiles = 'Page files'; AutomaticPageFile = 'Page file managed by Windows'
    EnabledCount = 'Enabled startup apps'; Entries = 'Startup apps'; ScheduledTasks = 'Scheduled tasks at sign-in'
    ThirdPartyServices = 'Third-party services'; RecentStarts = 'Recent boots'; Slowdowns = 'Boot slowdowns'
    All = 'All installed programs'; Unwanted = 'Possibly unwanted programs'
    SignatureAgeDays = 'Virus definitions age (days)'; DefenderRealtime = 'Defender real-time protection'
    PowerPlanGuid = 'Power plan ID'; TrimEnabled = 'TRIM enabled'
    RecycleBinGB = 'Recycle Bin (GB)'; HibernationFileGB = 'Hibernation file (GB)'; DownloadsGB = 'Downloads folder (GB)'
    ErrorCount7Days = 'Errors (last 7 days)'; MostCommon = 'Most common errors'; ApplicationCrashes = 'Application crashes'
    HardwareErrors30Days = 'Hardware errors (30 days)'; CorrectedHardwareErrors30Days = 'Corrected hardware errors (30 days)'
    UnexpectedShutdowns30Days = 'Unexpected shutdowns (30 days)'; SourceAndId = 'Source / event ID'
    GraphicsCards = 'Graphics cards'; AgeMonths = 'Age (months)'; ToDesktopSeconds = 'To desktop (s)'; PostLoginSeconds = 'After sign-in (s)'
}
$sectionTitles = [ordered]@{
    System = 'System'; Drives = 'Drive health'; Volumes = 'Disk space'; GameLibraries = 'Game libraries'
    Memory = 'Memory (RAM)'; Activity = 'Activity during the check'; Startup = 'Startup apps and background services'
    Boot = 'Boot performance'; Programs = 'Installed programs'; Security = 'Security'; Settings = 'Settings'
    Cleanable = 'Space that can be freed'; Errors = 'Errors and stability'; Updates = 'Drivers and updates'
}

function ConvertTo-Label([string]$Name) { T (ConvertTo-EnglishLabel $Name) }
function ConvertTo-EnglishLabel([string]$Name) {
    if ($script:labelOverrides.ContainsKey($Name)) { return $script:labelOverrides[$Name] }
    $unit = ''
    foreach ($pair in @(@('Percent', '%'), @('GB', 'GB'), @('MB', 'MB'), @('MHz', 'MHz'), @('Seconds', 's'))) {
        if ($Name.Length -gt $pair[0].Length -and $Name.EndsWith($pair[0], [StringComparison]::Ordinal)) {
            $Name = $Name.Substring(0, $Name.Length - $pair[0].Length)
            $unit = " ($($pair[1]))"
            break
        }
    }
    $words = @((($Name -creplace '([a-z0-9])([A-Z])', '$1 $2') -creplace '([A-Z]+)([A-Z][a-z])', '$1 $2') -split ' ')
    for ($i = 1; $i -lt $words.Count; $i++) {
        if ($words[$i] -cmatch '^[A-Z][a-z]') { $words[$i] = $words[$i].ToLowerInvariant() }
    }
    ($words -join ' ') + $unit
}
function Test-IsNumber($Value) { $Value -is [System.ValueType] -and $Value -isnot [bool] -and $Value -isnot [datetime] }
function New-Pill([string]$Text, [string]$Class) { "<span class=""pill $Class"">$(ConvertTo-SafeHtml (Tv $Text))</span>" }
function Format-Cell([string]$Column, $Value) {
    if ($null -eq $Value -or "$Value" -eq '') { return '<span class="muted">&ndash;</span>' }
    if ($Value -is [array]) { return ConvertTo-SafeHtml (@($Value | ForEach-Object { ConvertTo-ThemeText $_ }) -join ', ') }
    switch ($Column) {
        'Suggestion' {
            $class = switch -Wildcard ($Value) { 'Keep' { 'good' } 'Can be disabled' { 'warn' } 'Optional' { 'info' } default { 'muted' } }
            return New-Pill $Value $class
        }
        'Enabled' { return $(if ($Value) { New-Pill 'Enabled' 'info' } else { New-Pill 'Disabled' 'muted' }) }
        'Health' { return New-Pill $Value $(if ($Value -eq 'Healthy') { 'good' } elseif ($Value -eq 'Unknown') { 'muted' } else { 'bad' }) }
        'MediaType' { return New-Pill $Value $(if ($Value -eq 'HDD') { 'warn' } else { 'muted' }) }
        'Status' { return New-Pill $Value $(if ($Value -eq 'Running') { 'good' } else { 'muted' }) }
        'Scope' { return ConvertTo-SafeHtml (Tv $Value) }
    }
    if ($Value -is [bool]) { return $(if ($Value) { T 'Yes' } else { T 'No' }) }
    ConvertTo-SafeHtml (ConvertTo-ThemeText $Value)
}
function ConvertTo-HtmlTable($Data) {
    $rows = @($Data | Where-Object { $null -ne $_ } | ForEach-Object {
        if ($_ -is [string] -or $_ -is [System.ValueType]) { [pscustomobject]@{ Value = $_ } }
        elseif ($_ -is [System.Collections.IDictionary]) { [pscustomobject]$_ }
        else { $_ }
    })
    if (-not $rows.Count) { return "<p class=""empty"">$(T 'Nothing to show.')</p>" }
    $columns = @($rows[0].PSObject.Properties.Name)
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('<div class="table-wrap"><table><thead><tr>')
    foreach ($column in $columns) { [void]$builder.Append("<th>$(ConvertTo-SafeHtml (ConvertTo-Label $column))</th>") }
    [void]$builder.Append('</tr></thead><tbody>')
    foreach ($row in $rows) {
        [void]$builder.Append('<tr>')
        foreach ($column in $columns) {
            $value = $row.$column
            $class = if (Test-IsNumber $value) { ' class="num"' } else { '' }
            [void]$builder.Append("<td$class>$(Format-Cell $column $value)</td>")
        }
        [void]$builder.Append('</tr>')
    }
    [void]$builder.Append('</tbody></table></div>')
    $builder.ToString()
}
function ConvertTo-Collapsible([string]$Title, $Items, [int]$OpenLimit = 10) {
    $count = @($Items | Where-Object { $null -ne $_ }).Count
    $open = if ($count -gt 0 -and $count -le $OpenLimit) { ' open' } else { '' }
    $filter = if ($count -gt 15) { "<input class=""filter"" type=""search"" placeholder=""$(T 'Filter...')"">" } else { '' }
    "<details class=""sub""$open><summary>$(ConvertTo-SafeHtml $Title) <span class=""count"">$count</span></summary>$filter$(ConvertTo-HtmlTable $Items)</details>"
}
function ConvertTo-KeyValueHtml($Pairs) {
    if (-not $Pairs.Count) { return '' }
    $items = foreach ($key in $Pairs.Keys) {
        "<div><dt>$(ConvertTo-SafeHtml (ConvertTo-Label $key))</dt><dd>$(Format-Cell $key $Pairs[$key])</dd></div>"
    }
    "<dl class=""kv"">$($items -join '')</dl>"
}
function ConvertTo-VolumeHtml($Volumes) {
    $items = foreach ($volume in @($Volumes | Where-Object { $null -ne $_ })) {
        $freePercent = [double]$volume.FreePercent
        $class = if ($freePercent -lt 10) { 'bad' } elseif ($freePercent -lt 20) { 'warn' } else { 'good' }
        $used = [math]::Max(0, [math]::Min(100, 100 - $freePercent))
        $label = if ($volume.Label) { ConvertTo-SafeHtml $volume.Label } else { '' }
        @"
<div class="volume"><div class="vol-head"><strong>$(ConvertTo-SafeHtml $volume.Drive)</strong> <span>$label</span> $(Format-Cell 'MediaType' $volume.MediaType)
<span class="vol-free">$(T '{0} GB free of {1} GB ({2} % free)' $volume.FreeGB $volume.SizeGB $freePercent)</span></div>
<div class="bar"><div class="fill $class" style="width:$used%"></div></div>
<div class="hint">$(ConvertTo-SafeHtml $volume.PhysicalDrive)</div></div>
"@
    }
    if (-not $items) { return "<p class=""empty"">$(T 'Nothing to show.')</p>" }
    $items -join "`n"
}
function ConvertTo-SectionBody($Value) {
    if ($Value -is [System.Collections.IDictionary]) {
        $scalars = [ordered]@{}
        $blocks = @()
        foreach ($property in $Value.Keys) {
            $item = $Value[$property]
            if ($item -is [array] -or $item -is [System.Collections.IList]) {
                $blocks += ConvertTo-Collapsible (ConvertTo-Label $property) $item
            } elseif ($item -is [System.Collections.IDictionary]) {
                $blocks += "<h3>$(ConvertTo-SafeHtml (ConvertTo-Label $property))</h3>" + (ConvertTo-KeyValueHtml $item)
            } else {
                $scalars[$property] = $item
            }
        }
        return (ConvertTo-KeyValueHtml $scalars) + ($blocks -join "`n")
    }
    ConvertTo-HtmlTable $Value
}
function New-Stat([string]$Label, $Value, [string]$Hint) {
    if ($null -eq $Value -or "$Value".Trim() -eq '') { $Value = 'Unknown' }
    $hintHtml = if ($Hint) { "<div class=""hint"">$(ConvertTo-SafeHtml $Hint)</div>" } else { '' }
    "<div class=""card stat""><div class=""label"">$(ConvertTo-SafeHtml $Label)</div><div class=""value"">$(ConvertTo-SafeHtml $Value)</div>$hintHtml</div>"
}

function Write-HtmlReport([string]$RenderTheme, [string]$Path) {
    Set-ToolkitTheme $RenderTheme
    $sparkollen = $RenderTheme -eq 'Sparkollen'

    # Overview cards
    $system = $script:report.System
    $memory = $script:report.Memory
    $stats = @()
    if ($system) {
        $stats += New-Stat 'Windows' ($system.Windows -replace '^Microsoft\s+', '') (T 'Version {0}, build {1}' $system.Version $system.Build)
        $stats += New-Stat (T 'Processor') ($system.Processor -replace '\((R|TM)\)', '' -replace '\s+', ' ') (T '{0} cores / {1} threads' $system.Cores $system.Threads)
        $stats += New-Stat (T 'Uptime') (T '{0} days' $system.UptimeDays) (T 'Last boot {0}' $system.LastBoot)
    }
    if ($memory) {
        $stats += New-Stat (T 'Memory') "$($memory.TotalGB) GB $($memory.Type)" (T '{0} % in use, {1} module(s) at {2} MHz' $memory.UsedPercent $memory.ModuleCount $memory.ConfiguredMHz)
    }
    $graphicsCards = @($script:report.Updates.GraphicsCards | Where-Object { $_ })
    if ($graphicsCards.Count) {
        $mainGpu = $graphicsCards | Sort-Object { if ($_.Name -match 'Intel|Microsoft Basic') { 1 } else { 0 } } | Select-Object -First 1
        $stats += New-Stat (T 'Graphics') $mainGpu.Name (T 'Driver {0} ({1} months old)' $mainGpu.DriverVersion $mainGpu.AgeMonths)
    }
    $systemDrive = @($script:report.Drives.Physical | Where-Object IsSystemDrive) | Select-Object -First 1
    if ($systemDrive) {
        $stats += New-Stat (T 'System drive') "$($systemDrive.MediaType) ($($systemDrive.BusType))" (T '{0}, health: {1}' $systemDrive.Name (Tv $systemDrive.Health))
    }
    if ($script:report.Startup) {
        $stats += New-Stat (T 'Startup apps') (T '{0} enabled' $script:report.Startup.EnabledCount) (T '{0} third-party services' (@($script:report.Startup.ThirdPartyServices).Count))
    }
    if ($script:report.Errors) {
        $stats += New-Stat (T 'Stability index') "$($script:report.Errors.StabilityIndex) / 10" (T '{0} errors in the last 7 days' $script:report.Errors.ErrorCount7Days)
    }

    # Verdict
    $counts = @{}
    foreach ($severity in 'Critical', 'Warning', 'Info', 'OK') {
        $counts[$severity] = @($findings | Where-Object Severity -eq $severity).Count
    }
    $problems = @($findings | Where-Object { $_.Severity -in 'Critical', 'Warning' })
    $autoCount = @($problems | Where-Object Action -eq 'Automatic').Count
    $askCount = @($problems | Where-Object Action -eq 'Ask').Count
    $manualCount = @($problems | Where-Object Action -eq 'Manual').Count
    $planParts = @()
    if ($autoCount + $askCount) { $planParts += T '{0} can be fixed under Fix problems below' ($autoCount + $askCount) }
    if ($manualCount) { $planParts += T '{0} need manual action' $manualCount }
    $planText = if ($planParts.Count) { T 'Of the {0} issue(s): {1}.' $problems.Count (Join-T $planParts ', ') } else { '' }
    $driveProblem = [bool]$script:report.Drives.DriveProblem
    if ($driveProblem) {
        $verdictClass = 'bad'; $verdictTitle = T 'A drive may be failing'
        $verdictText = T 'Back up important files now. Do not run cleanup, defragmentation or chkdsk until the drive has been checked.'
    } elseif ($counts.Critical) {
        $verdictClass = 'bad'; $verdictTitle = T 'Needs attention'
        $verdictText = $planText
    } elseif ($counts.Warning) {
        $verdictClass = 'warn'; $verdictTitle = T 'Some issues found'
        $verdictText = $planText
    } else {
        $verdictClass = 'good'; $verdictTitle = T 'Looks healthy'
        $verdictText = T 'No significant problems were found.'
    }
    $driveBlocked = $driveProblem -or -not [bool]$script:report.Drives.CheckCompleted
    $verdictButton = if ($driveBlocked -or -not $problems.Count) { '' } else { "<a class=""cta"" href=""#fix"">$(T 'Fix problems') &rarr;</a>" }

    $gradeClasses = @{ Excellent = 'good'; 'Very good' = 'good'; Good = 'info'; Sufficient = 'warn'; Insufficient = 'bad' }
    if ($sparkollen) {
        $verdictTitle = if ($driveProblem) { T 'Vet visit needed - back up now' } else {
            switch ($score.Grade) {
                'Excellent' { T 'Excellent work! The computer is in top form.' }
                'Very good' { T 'Very good! Just a few small things to practise.' }
                'Good' { T 'Good work - a few things to train on.' }
                'Sufficient' { T 'Passed, but it needs more training.' }
                default { T 'Not passed this time - time for a training session.' }
            }
        }
        $phaseHtml = foreach ($key in $script:trialPhases.Keys) {
            $phase = $script:trialPhases[$key]
            $phaseScore = $score.Phases[$key]
            $points = if ($driveProblem) { '&ndash;' } else { $phaseScore.Points }
            $stamp = if ($driveProblem) { '' } else { "<span class=""stamp $($gradeClasses[$phaseScore.Grade])"">$(T $phaseScore.Grade)</span>" }
            $fillWidth = if ($driveProblem) { 0 } else { $phaseScore.Points }
            @"
<div class="phase"><div class="ph-letter">$key</div><div class="ph-body"><div class="ph-name">$(T $phase.Name)</div><div class="hint">$(T $phase.Covers)</div>
<div class="bar"><div class="fill $($gradeClasses[$phaseScore.Grade])" style="width:$fillWidth%"></div></div></div>
<div class="ph-score"><b>$points</b><span>/ 100</span>$stamp</div></div>
"@
        }
        if ($driveProblem) {
            $totalHtml = "<div class=""total vet""><b>!</b><span>$(T 'No points until the drive has been checked')</span></div>"
        } else {
            $previousHtml = ''
            if ($score.Previous) {
                $difference = $score.Total - $score.Previous.Total
                $differenceText = if ($difference -gt 0) { "+$difference" } elseif ($difference -lt 0) { "$difference" } else { '&plusmn;0' }
                $differenceClass = if ($difference -gt 0) { 'up' } elseif ($difference -lt 0) { 'down' } else { '' }
                $previousHtml = "<small class=""prev"">$(T 'Last time ({0}): {1} points' (ConvertTo-SafeHtml $score.Previous.Date) $score.Previous.Total) <b class=""$differenceClass"">$differenceText</b></small>"
            }
            $totalHtml = "<div class=""total""><div class=""kicker"">$(T 'Total')</div><b>$($score.Total)</b><span>$(T 'of 300 points')</span><span class=""stamp big $($gradeClasses[$score.Grade])"">$(T $score.Grade)</span>$previousHtml</div>"
        }
        $verdictHtml = @"
<div class="verdict protocol $verdictClass"><div class="proto-head"><div class="proto-text"><div class="kicker">$(T 'Judge''s protocol')</div><h2>$(ConvertTo-SafeHtml $verdictTitle)</h2>
<p>$(ConvertTo-SafeHtml $verdictText)</p><p class="tally">$(T '{0} critical, {1} warnings, {2} tips, {3} OK' $counts.Critical $counts.Warning $counts.Info $counts.OK)</p>$verdictButton</div>$totalHtml</div>
<div class="phases">$($phaseHtml -join "`n")</div></div>
"@
    } else {
        $verdictHtml = @"
<div class="verdict $verdictClass"><div><h2>$verdictTitle</h2><p>$(ConvertTo-SafeHtml $verdictText)</p>$verdictButton</div>
<div class="counts"><div class="count-box critical"><b>$($counts.Critical)</b>Critical</div><div class="count-box warning"><b>$($counts.Warning)</b>Warnings</div><div class="count-box info"><b>$($counts.Info)</b>Info</div><div class="count-box ok"><b>$($counts.OK)</b>OK</div></div></div>
"@
    }

    # Findings
    $actionLabels = @{ Automatic = @((T 'Fix available below'), 'good'); Ask = @((T 'You choose below'), 'info'); Manual = @((T 'Manual action'), 'warn') }
    $severityOrder = @{ Critical = 0; Warning = 1; Info = 2; OK = 3 }
    function ConvertTo-FindingHtml($Finding) {
        $class = $Finding.Severity.ToLowerInvariant()
        $tags = @(New-Pill $Finding.Category 'muted')
        if ($Finding.Action -and $actionLabels.ContainsKey($Finding.Action)) {
            $tags += New-Pill $actionLabels[$Finding.Action][0] $actionLabels[$Finding.Action][1]
        }
        @"
<div class="finding $class"><div class="sev">$(Tv $Finding.Severity)</div><div class="f-body">
<div class="f-title">$(ConvertTo-SafeHtml (ConvertTo-ThemeText $Finding.Title))</div>
$(if ($Finding.Details) { "<div class=""f-details"">$(ConvertTo-SafeHtml (ConvertTo-ThemeText $Finding.Details))</div>" })
$(if ($Finding.Recommendation) { "<div class=""f-rec"">&rarr; $(ConvertTo-SafeHtml (ConvertTo-ThemeText $Finding.Recommendation))</div>" })
<div class="tags">$($tags -join ' ')</div></div></div>
"@
    }
    $sortedFindings = @($findings | Sort-Object { $severityOrder[$_.Severity] })
    $problemFindings = @($sortedFindings | Where-Object Severity -ne 'OK')
    if ($sparkollen) {
        $phaseDogs = @{ A = 'dog-tracker'; C = 'dog-guard' }
        $findingHtml = @()
        foreach ($key in $script:trialPhases.Keys) {
            $phase = $script:trialPhases[$key]
            $phaseFindings = @($problemFindings | Where-Object { $_.Category -in $phase.Categories })
            $dog = if ($phaseDogs[$key]) { "<svg class=""dog-mini"" aria-hidden=""true""><use href=""#$($phaseDogs[$key])""/></svg>" } else { '' }
            $findingHtml += "<h3 class=""phase-head""><span class=""ph-letter"">$key</span>$(T $phase.Name)<span class=""hint"">$(T $phase.Covers)</span>$dog</h3>"
            $findingHtml += if ($phaseFindings.Count) { $phaseFindings | ForEach-Object { ConvertTo-FindingHtml $_ } } else { "<p class=""clean"">$(T 'Clean track - nothing found here.')</p>" }
        }
        $knownCategories = @($script:trialPhases.Values | ForEach-Object { $_.Categories })
        $findingHtml += @($problemFindings | Where-Object { $_.Category -notin $knownCategories } | ForEach-Object { ConvertTo-FindingHtml $_ })
    } else {
        $findingHtml = @($problemFindings | ForEach-Object { ConvertTo-FindingHtml $_ })
    }
    $okFindings = @($sortedFindings | Where-Object Severity -eq 'OK')
    if ($okFindings.Count) {
        $findingHtml += "<details class=""sub""><summary>$(T 'Checks that passed') <span class=""count"">$($okFindings.Count)</span></summary><div class=""pad"">$(($okFindings | ForEach-Object { ConvertTo-FindingHtml $_ }) -join "`n")</div></details>"
    }
    if (-not $findingHtml.Count) { $findingHtml = @("<p class=""empty"">$(T 'No findings.')</p>") }

    # Detail sections
    $sections = @()
    $navLinks = @("<a href=""#findings"">$(T 'Findings')</a>")
    $sectionKeys = @($sectionTitles.Keys) + @($script:report.Keys | Where-Object { $_ -notin $sectionTitles.Keys -and $_ -notin 'Meta', 'Findings' })
    foreach ($key in $sectionKeys) {
        if (-not $script:report.Contains($key)) { continue }
        $title = if ($sectionTitles.Contains($key)) { T $sectionTitles[$key] } else { ConvertTo-Label $key }
        $body = if ($key -eq 'Volumes') { ConvertTo-VolumeHtml $script:report[$key] } else { ConvertTo-SectionBody $script:report[$key] }
        $anchor = $key.ToLowerInvariant()
        $navLinks += "<a href=""#$anchor"">$(ConvertTo-SafeHtml $title)</a>"
        $sections += "<section id=""$anchor""><h2>$(ConvertTo-SafeHtml $title)</h2><div class=""card"">$body</div></section>"
    }
    if ($script:scriptErrors.Count) {
        $navLinks += "<a href=""#script-errors"">$(T 'Incomplete checks')</a>"
        $sections += "<section id=""script-errors""><h2>$(T 'Checks that could not be completed')</h2><div class=""card""><ul>" +
            (($script:scriptErrors | ForEach-Object { "<li>$(ConvertTo-SafeHtml (ConvertTo-ThemeText $_))</li>" }) -join '') + '</ul></div></section>'
    }

    $navLinks = @($navLinks[0], "<a href=""#fix"">$(T 'Fix problems')</a>") + @($navLinks | Select-Object -Skip 1)
    $driveMessage = if ($driveProblem) {
        T 'A drive may be failing, so PC Toolkit will not change anything. Back up important files now and have the drive checked.'
    } else {
        T 'The drive health check could not be completed, so PC Toolkit will not change anything. Ask whoever is helping you.'
    }
    $fixData = [ordered]@{
        options      = @(Get-RepairOptions (Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json))
        driveBlocked = $driveBlocked
        driveMessage = $driveMessage
        theme        = $script:ToolkitTheme
        strings      = Get-StringTable 'Fix'
    }
    $fixJson = ($fixData | ConvertTo-Json -Depth 4 -Compress).Replace('<', '\u003c').Replace('>', '\u003e').Replace('&', '\u0026')
    $fixScript = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'report-fix.js'))

    $adminChip = if ($isAdmin) { "<span class=""chip"">$(T 'Ran as administrator')</span>" } else { "<span class=""chip alert"">$(T 'Not run as administrator &ndash; some data may be missing')</span>" }
    $driveBanner = if ($driveProblem) { "<div class=""banner"">$(T 'A drive may be failing. Back up important files before doing anything else.')</div>" } else { '' }
    $modelText = ''
    if ($system) {
        $modelName = "$($system.Model)".Trim()
        if ($system.Manufacturer -and $modelName -notlike "$($system.Manufacturer)*") { $modelName = "$($system.Manufacturer) $modelName" }
        $modelText = ConvertTo-SafeHtml $modelName.Trim()
    }

    $themeOptions = foreach ($themeName in $themeReports.Keys) {
        $selected = if ($themeName -eq $script:ToolkitTheme) { ' selected' } else { '' }
        "<option value=""$($themeReports[$themeName])""$selected>$(ConvertTo-SafeHtml (Get-ThemeDisplayName $themeName))</option>"
    }
    $themePicker = "<label class=""theme-pick""><span>$(T 'Theme')</span><select id=""theme-select"" onchange=""switchTheme(this.value)"">$($themeOptions -join '')</select></label>"
    $chips = "<span class=""chip"">$($script:report.Meta.Date)</span><span class=""chip"">PC Toolkit $script:ToolkitVersion</span><span class=""chip"">$(T 'Check took {0} s' $script:report.Meta.DurationSeconds)</span>$adminChip$themePicker"
    $heading = T 'PC health report: {0}' (ConvertTo-SafeHtml $env:COMPUTERNAME)
    if ($sparkollen) {
        $themeFolder = Join-Path $PSScriptRoot 'themes'
        $themeCss = [IO.File]::ReadAllText((Join-Path $themeFolder 'sparkollen.css'))
        $svgDefs = [IO.File]::ReadAllText((Join-Path $themeFolder 'sparkollen-symbols.svg'))
        $bodyClass = ' class="sparkollen"'
        $trackPath = 'M0,41.3 L20,43.1 L40,44.6 L60,45.7 L80,46.5 L100,46.9 L120,47 L140,46.6 L160,45.8 L180,44.6 L200,43.2 L220,41.4 L240,39.4 L260,37.3 L280,35 L300,32.7 L320,30.5 L340,28.4 L360,26.4 L380,24.7 L400,23.2 L420,22.1 L440,21.4 L460,21 L480,21.1 L500,21.5 L520,22.4 L540,23.6 L560,25.1 L580,26.9 L600,28.9 L620,31 L640,33.3 L660,35.6 L680,37.8 L700,39.9 L720,41.9 L740,43.6 L760,45 L780,46 L800,46.7 L820,47 L840,46.9 L860,46.4 L880,45.5 L900,44.2 L920,42.7 L940,40.9 L960,38.8 L980,36.6 L1000,34.4'
        # Paw prints follow the track curve (y = 34 + 13 sin(...)) in the 60 px high track band, alternating left and right foot.
        $paws = for ($i = 0; $i -lt 10; $i++) {
            $percent = 4 + $i * 7
            $y = 34 + 13 * [math]::Sin($percent * 10 / 1000 * 2 * [math]::PI * 1.4 + 0.6)
            $bottom = [math]::Round(56 + 60 - $y - 7 + $(if ($i % 2) { 5 } else { -5 }))
            "<svg class=""paw"" aria-hidden=""true"" style=""left:$percent%;bottom:${bottom}px""><use href=""#paw""/></svg>"
        }
        $heroHtml = @"
<header class="hero">
<svg class="forest" aria-hidden="true" style="color:#163327;fill:currentColor"><use href="#forest-back"/></svg>
<svg class="track" viewBox="0 0 1000 60" preserveAspectRatio="none" aria-hidden="true"><path d="$trackPath" fill="none" stroke="#ff922b" stroke-width="2.5" stroke-dasharray="7 8" stroke-linecap="round" vector-effect="non-scaling-stroke" opacity=".75"/></svg>
$($paws -join '')
<div class="pack" aria-hidden="true"><svg class="dog-tracker" width="96" height="72"><use href="#dog-tracker"/></svg><svg class="dog-guard" width="124" height="92"><use href="#dog-guard"/></svg><svg class="dog-sitter" width="108" height="80"><use href="#dog-sitter"/></svg></div>
<svg class="forest front" aria-hidden="true" style="color:#0d1e16;fill:currentColor"><use href="#forest-front"/></svg>
<div class="wrap"><div class="brand"><svg><use href="#paw"/></svg>$(T 'PC Toolkit')</div>
<h1>$heading</h1>
<div class="sub">$modelText</div>
<div class="meta">$chips</div>
</div></header>
"@
    } else {
        $themeCss = ''; $svgDefs = ''; $bodyClass = ''
        $heroHtml = @"
<header class="hero"><div class="wrap">
<h1>$heading</h1>
<div class="sub">$modelText</div>
<div class="meta">$chips</div>
</div></header>
"@
    }

    $html = @"
<!DOCTYPE html><html lang="$(if ($sparkollen) { 'sv' } else { 'en' })"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>$(T 'PC Toolkit report - {0}' (ConvertTo-SafeHtml $env:COMPUTERNAME))</title>
<style>
:root{color-scheme:dark;--bg:#14171c;--card:#1d2128;--text:#e6e9ef;--muted:#98a2b3;--border:#2c323c;--crit:#f03e3e;--warn:#f59f00;--info:#339af0;--ok:#40c057;--shadow:0 1px 3px rgba(0,0,0,.35)}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:15px/1.5 "Segoe UI",system-ui,-apple-system,Arial,sans-serif}
.wrap{max-width:1180px;margin:0 auto;padding:0 20px}
header.hero{background:linear-gradient(135deg,#1e3a8a,#3b5bdb 60%,#7048e8);color:#fff;padding:30px 0 76px}
.hero h1{margin:0;font-size:28px;font-weight:600}.hero .sub{opacity:.85;margin-top:2px}
.meta{margin-top:14px;display:flex;flex-wrap:wrap;gap:8px}
.chip{background:rgba(255,255,255,.16);border-radius:999px;padding:3px 12px;font-size:13px}.chip.alert{background:#ffd43b;color:#5c3c00}
.theme-pick{margin-left:auto;display:inline-flex;align-items:center;gap:8px;font-size:13px}
.theme-pick select{font:inherit;font-size:13px;padding:3px 10px;border-radius:999px;border:1px solid rgba(255,255,255,.35);background:rgba(0,0,0,.25);color:#fff;cursor:pointer}
.theme-pick select:hover,.theme-pick select:focus{border-color:#fff}.theme-pick option{background:var(--card);color:var(--text)}
.verdict{margin-top:-50px;background:var(--card);border-radius:14px;box-shadow:0 4px 18px rgba(0,0,0,.45);padding:22px 26px;display:flex;gap:22px;align-items:center;flex-wrap:wrap;border-left:8px solid var(--ok)}
.verdict.bad{border-left-color:var(--crit)}.verdict.warn{border-left-color:var(--warn)}
.verdict h2{margin:0;font-size:23px}.verdict p{margin:4px 0 0;color:var(--muted);max-width:560px}
a.cta{display:inline-block;margin-top:12px;background:#3b5bdb;color:#fff;text-decoration:none;font-weight:600;padding:8px 18px;border-radius:8px}a.cta:hover{background:#4c6ef5}
.fix-card{border-color:#3b5bdb}
.fix-group{margin-bottom:18px}.fix-head{display:flex;align-items:center;gap:10px;flex-wrap:wrap}.fix-head h3{margin:0;margin-right:auto}
.fix-group>.hint{margin:2px 0 8px}
label.opt{display:flex;gap:12px;align-items:flex-start;padding:7px 12px;border:1px solid var(--border);border-radius:8px;margin-bottom:5px;cursor:pointer;background:var(--bg)}
label.opt:hover{border-color:var(--info)}label.opt input{width:18px;height:18px;margin:2px 0 0;flex:none;accent-color:#4c6ef5}
.opt-body{flex:1;min-width:0}.opt-title{font-weight:600}.opt-desc{font-size:13px;color:var(--muted);word-break:break-word}.mono{font-family:Consolas,monospace;font-size:12px}
.opt-time{flex:none;font-size:12px;color:var(--muted);white-space:nowrap}
.fix-bar{display:flex;gap:12px;align-items:center;flex-wrap:wrap;margin-top:16px;padding-top:14px;border-top:1px solid var(--border)}.grow{flex:1}
button.primary{background:#3b5bdb;border-color:#3b5bdb;color:#fff;font-size:15px;font-weight:600;padding:9px 20px}button.primary:hover{background:#4c6ef5}
button:disabled{opacity:.5;cursor:not-allowed}
button.link{border:0;background:none;color:var(--info);padding:2px 4px}button.link:hover{text-decoration:underline}
.note{padding:12px 16px;border-radius:8px;margin-bottom:14px;border:1px solid}.note.info{background:#172d45;color:#a5d8ff;border-color:#244a6e}
.note.warn{background:#3d2e14;color:#ffc078;border-color:#5c4419}.note.bad{background:#401d1d;color:#ffa8a8;border-color:#6b2a2a;font-weight:600}.note.good{background:#1f3a28;color:#8ce99a;border-color:#2b5a37}
.progress-head{display:flex;align-items:center;gap:12px;font-size:18px}
.spinner{width:22px;height:22px;border:3px solid var(--border);border-top-color:#4c6ef5;border-radius:50%;animation:spin 1s linear infinite;flex:none}@keyframes spin{to{transform:rotate(360deg)}}
.icon{width:28px;height:28px;border-radius:50%;display:inline-flex;align-items:center;justify-content:center;font-weight:700;color:#fff;flex:none}.icon.good{background:var(--ok)}.icon.bad{background:var(--crit)}
pre.log{background:#0d0f13;border:1px solid var(--border);border-radius:8px;padding:12px;max-height:340px;overflow:auto;font:12px/1.45 Consolas,monospace;white-space:pre-wrap;margin:10px 0 0}
details.sub pre.log{margin:0;border:0;border-radius:0}
.res{margin-top:14px}.res h3{margin:0 0 4px}.res ul{margin:0;padding-left:22px}.res.good h3{color:var(--ok)}.res.warn h3{color:var(--warn)}.res.info h3{color:var(--info)}
.counts{display:flex;gap:10px;margin-left:auto;flex-wrap:wrap}
.count-box{text-align:center;min-width:78px;padding:8px 10px;border-radius:10px;background:var(--bg);font-size:12px;color:var(--muted);text-transform:uppercase;letter-spacing:.04em}
.count-box b{display:block;font-size:26px;line-height:1.15;color:var(--text)}
.count-box.critical b{color:var(--crit)}.count-box.warning b{color:var(--warn)}.count-box.info b{color:var(--info)}.count-box.ok b{color:var(--ok)}
.banner{background:#401d1d;color:#ffa8a8;border:1px solid #6b2a2a;padding:14px 18px;border-radius:10px;font-weight:600;margin-top:16px}
nav.toc{display:flex;flex-wrap:wrap;gap:6px;margin:20px 0 4px;align-items:center}
nav.toc a{font-size:13px;padding:4px 11px;border-radius:999px;background:var(--card);border:1px solid var(--border);color:var(--text);text-decoration:none}
nav.toc a:hover{border-color:var(--info);color:var(--info)}
.toolbar{margin-left:auto;display:flex;gap:6px}
button{font:inherit;font-size:13px;padding:4px 12px;border-radius:8px;border:1px solid var(--border);background:var(--card);color:var(--text);cursor:pointer}
button:hover{border-color:var(--info)}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(250px,1fr));gap:14px;margin-top:20px}
.card{background:var(--card);border-radius:12px;box-shadow:var(--shadow);padding:16px 18px;border:1px solid var(--border)}
.stat .label{font-size:12px;text-transform:uppercase;letter-spacing:.05em;color:var(--muted)}
.stat .value{font-size:17px;font-weight:600;margin-top:2px}
.hint{font-size:13px;color:var(--muted)}
section{margin-top:30px;scroll-margin-top:12px}section>h2{font-size:20px;margin:0 0 10px}
h3{font-size:15px;margin:16px 0 6px}
.finding{display:flex;gap:14px;background:var(--card);border:1px solid var(--border);border-left:5px solid var(--sev);border-radius:10px;padding:14px 16px;margin-bottom:10px;box-shadow:var(--shadow)}
.finding.critical{--sev:var(--crit)}.finding.warning{--sev:var(--warn)}.finding.info{--sev:var(--info)}.finding.ok{--sev:var(--ok)}
.sev{flex:none;font-size:11px;font-weight:700;text-transform:uppercase;letter-spacing:.04em;color:#fff;background:var(--sev);border-radius:6px;padding:3px 8px;height:fit-content;min-width:74px;text-align:center}
.f-body{flex:1;min-width:0}.f-title{font-weight:600}.f-details{color:var(--muted);margin-top:2px;font-size:14px;word-break:break-word}.f-rec{margin-top:6px}
.tags{margin-top:8px;display:flex;gap:6px;flex-wrap:wrap}
.pill{display:inline-block;font-size:12px;line-height:1.6;padding:0 9px;border-radius:999px;background:var(--bg);border:1px solid var(--border);white-space:nowrap;font-weight:500}
.pill.good{background:#1f3a28;color:#8ce99a;border-color:#2b5a37}.pill.warn{background:#3d2e14;color:#ffc078;border-color:#5c4419}
.pill.bad{background:#401d1d;color:#ffa8a8;border-color:#6b2a2a}.pill.info{background:#172d45;color:#a5d8ff;border-color:#244a6e}.pill.muted{color:var(--muted)}
.muted{color:var(--muted)}
.volume{margin-bottom:16px}.volume:last-child{margin-bottom:0}.vol-head{display:flex;gap:8px;align-items:baseline;flex-wrap:wrap}.vol-free{margin-left:auto;color:var(--muted);font-size:14px}
.bar{height:14px;background:var(--bg);border-radius:999px;overflow:hidden;margin:6px 0 2px;border:1px solid var(--border)}
.fill{height:100%;border-radius:999px}.fill.good{background:linear-gradient(90deg,#4dabf7,#1c7ed6)}.fill.warn{background:linear-gradient(90deg,#ffc078,#f08c00)}.fill.bad{background:linear-gradient(90deg,#ff8787,#d63939)}
dl.kv{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:0 28px;margin:0}
dl.kv div{display:flex;justify-content:space-between;gap:12px;padding:7px 0;border-bottom:1px dashed var(--border)}
dt{color:var(--muted)}dd{margin:0;font-weight:600;text-align:right;word-break:break-word}
details.sub{margin-top:14px;border:1px solid var(--border);border-radius:10px;overflow:hidden}
details.sub>summary{cursor:pointer;padding:9px 14px;font-weight:600;background:var(--bg);list-style:none;display:flex;align-items:center;gap:8px}
details.sub>summary::-webkit-details-marker{display:none}
details.sub>summary::before{content:"\25B8";color:var(--muted);transition:transform .15s}details.sub[open]>summary::before{transform:rotate(90deg)}
.count{font-size:12px;background:var(--card);border:1px solid var(--border);border-radius:999px;padding:0 8px;color:var(--muted);font-weight:500}
.pad{padding:12px}
.table-wrap{overflow-x:auto}
table{width:100%;border-collapse:collapse;font-size:14px}
th{text-align:left;font-size:12px;text-transform:uppercase;letter-spacing:.04em;color:var(--muted);padding:8px 12px;border-bottom:2px solid var(--border);white-space:nowrap}
td{padding:7px 12px;border-bottom:1px solid var(--border);vertical-align:top;overflow-wrap:anywhere;min-width:7em}
tbody tr:last-child td{border-bottom:0}tbody tr:hover{background:var(--bg)}
td.num{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap;min-width:0}
.filter{margin:10px 12px 4px;padding:6px 10px;border:1px solid var(--border);border-radius:8px;width:280px;max-width:90%;background:var(--card);color:var(--text);font:inherit;font-size:14px}
.empty{color:var(--muted);font-style:italic;padding:8px 12px;margin:0}
footer{margin:40px 0 30px;color:var(--muted);font-size:13px;text-align:center}
@media (max-width:640px){.counts{margin-left:0}.verdict{padding:18px}.hero h1{font-size:23px}}
@media print{:root{--bg:#fff;--card:#fff;--text:#000;--muted:#555;--border:#ccc}body{background:#fff;color:#000}header.hero{background:none;color:#000;padding:0 0 16px}.chip{border:1px solid #bbb}
.verdict{margin-top:0;box-shadow:none;border:1px solid #ccc}nav.toc,.filter,#fix,a.cta,.theme-pick{display:none}.card,.finding{box-shadow:none;break-inside:avoid}section{break-inside:avoid-page}}
$themeCss
</style></head><body$bodyClass>
$svgDefs
$heroHtml
<main class="wrap">
$verdictHtml
$driveBanner
<div class="grid">$($stats -join "`n")</div>
<nav class="toc">$($navLinks -join '')<span class="toolbar"><button type="button" onclick="setAll(true)">$(T 'Expand all')</button><button type="button" onclick="setAll(false)">$(T 'Collapse all')</button></span></nav>
<section id="findings"><h2>$(T 'Findings')</h2>
$($findingHtml -join "`n")
</section>
<section id="fix"><h2>$(T 'Fix problems')</h2><div class="card fix-card" id="fix-panel"><noscript>$(T 'Turn on JavaScript to choose fixes.')</noscript></div></section>
$($sections -join "`n")
<footer>$(T 'Generated by PC Toolkit {0} on {1}. The same data is available in diagnostic-report.json.' $script:ToolkitVersion $script:report.Meta.Date)</footer>
</main>
<script>
function setAll(open){document.querySelectorAll('details').forEach(function(d){d.open=open})}
function switchTheme(file){var base=window.PCTK?'/'+window.PCTK.token+'/':'';location.href=base+file+location.hash}
window.addEventListener('beforeprint',function(){setAll(true)});
document.querySelectorAll('.filter').forEach(function(input){input.addEventListener('input',function(){
var q=input.value.toLowerCase();input.parentNode.querySelectorAll('tbody tr').forEach(function(r){r.style.display=r.textContent.toLowerCase().indexOf(q)>-1?'':'none'})})});
</script>
<script type="application/json" id="pctk-data">$fixJson</script>
<script>
$fixScript
</script>
</body></html>
"@
    Set-Content -LiteralPath $Path -Value $html -Encoding UTF8
}

foreach ($themeName in $themeReports.Keys) { Write-HtmlReport $themeName (Join-Path $outputFolder $themeReports[$themeName]) }
Set-ToolkitTheme $runTheme
$sparkollen = $runTheme -eq 'Sparkollen'
$driveProblem = [bool]$script:report.Drives.DriveProblem

Write-Section (T 'Summary of findings')
$colors = @{ Critical = 'Red'; Warning = 'Yellow'; Info = 'Cyan'; OK = 'Green' }
foreach ($finding in $findings) {
    Write-Host ("  {0,-12} " -f (Tv $finding.Severity)) -ForegroundColor $colors[$finding.Severity] -NoNewline
    Write-Host $finding.Title
}
if ($sparkollen -and -not $driveProblem) {
    Write-Host ("`n  " + (T 'Judge''s protocol: {0} of 300 points - {1}' $score.Total (T $score.Grade))) -ForegroundColor Green
}
if ($driveProblem) {
    Write-Host ("`n  " + (T '!!! A DRIVE MAY BE FAILING. BACK UP IMPORTANT FILES NOW !!!')) -ForegroundColor Red
}
if ($script:MissingStrings.Count) {
    $script:report.Meta.MissingTranslations = @($script:MissingStrings | Sort-Object)
    $script:report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
}
Write-Host ("`n" + (T 'Reports saved to: {0}' $outputFolder)) -ForegroundColor Green
if (-not $Quiet) {
    $serverArgs = @{ ReportFolder = $outputFolder }
    if ($DryRunRepairs) { $serverArgs.DryRun = $true }
    if ($NoBrowser) { $serverArgs.NoBrowser = $true }
    try {
        & (Join-Path $PSScriptRoot 'ReportServer.ps1') @serverArgs
    } catch {
        Write-Warning (T 'Could not start the fix page: {0}' $_.Exception.Message)
        Write-Host (T 'Opening the read-only report instead. Fixes can also be run with scripts\Repair.ps1.')
        Invoke-Item -LiteralPath $htmlPath
        Read-Host (T 'Press Enter to close')
    }
}
