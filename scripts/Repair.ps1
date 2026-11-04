<#
.SYNOPSIS
    Performs safe repairs based on a Diagnose.ps1 report.

.DESCRIPTION
    Normally started from the "Fix problems" section of the report in the web browser.
    Stops when the report indicates a potentially failing drive, creates a restore point
    first, and only performs repairs offered by Get-RepairOptions in Common.ps1.

.PARAMETER ReportPath
    Path to diagnostic-report.json. Defaults to the latest report.

.PARAMETER SelectionPath
    JSON file with the option IDs chosen in the report ({ "Options": [ ... ] }). No questions are asked.

.PARAMETER ProgressPath
    Text file that receives all progress output (read live by the report page).

.PARAMETER ResultPath
    JSON file that receives the result summary when finished.

.PARAMETER AutomaticOnly
    Run only the recommended automatic actions; do not ask questions.

.PARAMETER IgnoreDriveWarning
    Continue despite a drive warning. Use only after important files have been backed up.

.PARAMETER NoElevation
    Do not request administrator permissions. Most repairs require elevation.

.EXAMPLE
    .\Repair.ps1 -WhatIf
    Dry run in the console: show planned actions without changing the system.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ReportPath,
    [string]$SelectionPath,
    [string]$ProgressPath,
    [string]$ResultPath,
    [switch]$AutomaticOnly,
    [switch]$IgnoreDriveWarning,
    [switch]$NoElevation
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'Common.ps1')
$script:shouldProcess = $PSCmdlet
$dryRun = [bool]$WhatIfPreference
$interactive = -not $AutomaticOnly -and -not $SelectionPath

if (((-not (Test-IsAdmin)) -and -not $dryRun -and -not $NoElevation) -or
    $PSVersionTable.PSEdition -eq 'Core') {
    try {
        Write-Host 'Restarting in Windows PowerShell with administrator permissions...'
        Start-AsAdmin -ScriptPath $PSCommandPath -Parameters $PSBoundParameters
    } catch {
        Write-Host 'Repairs require administrator permissions. Exiting.' -ForegroundColor Red
        if ($interactive) { Read-Host 'Press Enter to close' }
    }
    return
}

# When started from the report page, mirror everything written to the console into a progress file.
if ($ProgressPath) {
    $script:progressBuffer = ''
    function Add-ProgressLine([string]$Text) {
        [System.IO.File]::AppendAllText($ProgressPath, $Text + "`r`n", [System.Text.Encoding]::UTF8)
    }
    function Write-Host {
        param([Parameter(Position = 0, ValueFromRemainingArguments = $true)]$Object, [switch]$NoNewline,
            $ForegroundColor, $BackgroundColor, $Separator = ' ')
        $text = (@($Object) | ForEach-Object { "$_" }) -join $Separator
        if ($NoNewline) { $script:progressBuffer += $text }
        else { Add-ProgressLine ($script:progressBuffer + $text); $script:progressBuffer = '' }
        $splat = @{ Object = $text; NoNewline = $NoNewline }
        if ($ForegroundColor) { $splat.ForegroundColor = $ForegroundColor }
        Microsoft.PowerShell.Utility\Write-Host @splat
    }
    function Write-Warning {
        param([Parameter(Position = 0)][string]$Message)
        Add-ProgressLine "WARNING: $Message"
        Microsoft.PowerShell.Utility\Write-Warning $Message
    }
}

function Test-ApprovedAction([string]$Target, [string]$Action) {
    $approved = $script:shouldProcess.ShouldProcess($Target, $Action)
    if (-not $approved -and $dryRun) { Write-Host "  [dry run] Would: $Action ($Target)" -ForegroundColor Magenta }
    $approved
}
function Invoke-WithoutWhatIf([scriptblock]$Code) {
    $WhatIfPreference = $false
    & $Code
}
function Add-Completed([string]$Text) {
    $script:completed.Add($Text)
    Write-Host "  [done] $Text" -ForegroundColor Green
}
# Decides whether an option runs: the browser selection wins; otherwise automatic defaults run and the rest is asked.
function Use-Option([string]$Id, [string]$Question = '', [bool]$DefaultAnswer = $false) {
    $option = $script:options | Where-Object Id -eq $Id | Select-Object -First 1
    if (-not $option) { return $false }
    if ($null -ne $script:selection) { return $script:selection -contains $Id }
    if ($option.Automatic -and $option.Default) { return $true }
    if (-not $interactive -or -not $Question) { return $false }
    Read-YesNo $Question $DefaultAnswer
}

$script:completed = New-Object System.Collections.Generic.List[string]
$script:manual = New-Object System.Collections.Generic.List[string]
$script:skipped = New-Object System.Collections.Generic.List[string]
$script:restartNeeded = $false
$script:stopReason = ''
$script:selection = $null

function Find-LatestReport {
    Get-ChildItem -LiteralPath $script:ReportsRoot -Filter 'diagnostic-report.json' -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
}
function Test-Finding([string]$Id) { Test-ReportFinding $script:data $Id }

Write-Section "PC Toolkit $script:ToolkitVersion - Repairs for $env:COMPUTERNAME"
if ($dryRun) { Write-Host 'DRY RUN: no system changes will be made.' -ForegroundColor Magenta }
if (-not $ReportPath) { $ReportPath = Find-LatestReport }
if (-not $SelectionPath -and (-not $ReportPath -or -not (Test-Path -LiteralPath $ReportPath) -or
    ((Get-Date) - (Get-Item -LiteralPath $ReportPath).LastWriteTime).TotalDays -gt 3)) {
    Write-Host 'No recent diagnosis report found. Running the diagnosis first...' -ForegroundColor Yellow
    Invoke-WithoutWhatIf { & (Join-Path $PSScriptRoot 'Diagnose.ps1') -Quiet -NoElevation }
    $ReportPath = Find-LatestReport
}
if (-not $ReportPath -or -not (Test-Path -LiteralPath $ReportPath)) {
    Write-Host 'No diagnosis report was found. Exiting.' -ForegroundColor Red
    if ($interactive) { Read-Host 'Press Enter to close' }
    return
}

$script:data = Get-Content -LiteralPath $ReportPath -Raw -Encoding UTF8 | ConvertFrom-Json
$script:options = @(Get-RepairOptions $script:data)
if ($SelectionPath) {
    $script:selection = @((Get-Content -LiteralPath $SelectionPath -Raw -Encoding UTF8 | ConvertFrom-Json).Options | ForEach-Object { "$_" })
}
$reportFolder = Split-Path -Parent $ReportPath
Write-Host "Using report from $($script:data.Meta.Date)"
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
$transcriptPath = Join-Path $reportFolder "repair-log_$stamp.txt"
Invoke-WithoutWhatIf { Start-Transcript -LiteralPath $transcriptPath -Append | Out-Null }

try {
    if (($script:data.Drives.DriveProblem -or -not $script:data.Drives.CheckCompleted) -and -not $IgnoreDriveWarning) {
        $driveFinding = $script:data.Findings | Where-Object Id -eq 'DRIVE_FAILING' | Select-Object -First 1
        if ($script:data.Drives.DriveProblem) {
            $script:stopReason = 'A drive may be failing. No repairs were run.'
            Write-Host "`n!!! A DRIVE MAY BE FAILING !!!" -ForegroundColor Red
            Write-Host $driveFinding.Details -ForegroundColor Red
            Write-Host 'No repairs will run because intensive operations can make a failing drive stop working.' -ForegroundColor Yellow
            Write-Host '1. Back up important files (Documents, Pictures, Desktop, game saves) to an external drive or cloud storage now.' -ForegroundColor Yellow
            Write-Host '2. Replace the drive, ideally by cloning it to a new SSD.' -ForegroundColor Yellow
            Write-Host '3. Run diagnosis again. If the files are already backed up, use -IgnoreDriveWarning.' -ForegroundColor Yellow
            $script:manual.Add('BACK UP important files immediately and replace the potentially failing drive.')
        } else {
            $script:stopReason = 'The drive-health check did not complete. No repairs were run.'
            Write-Host "`nThe drive-health check did not complete successfully." -ForegroundColor Red
            Write-Host 'No repairs will run until drive health is known. Rerun diagnosis as administrator or use -IgnoreDriveWarning only after backing up important files.' -ForegroundColor Yellow
            $script:manual.Add('Rerun the check as administrator (click Yes when Windows asks) and confirm drive health before repairs.')
        }
        return
    }

    Write-Section 'Create a restore point'
    if (Test-ApprovedAction 'Computer' 'Create a system restore point') {
        Write-Host 'Creating a restore point so the changes can be undone...'
        $restorePointCreated = $false
        $restoreKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
        $oldFrequency = (Get-ItemProperty -Path $restoreKey -ErrorAction SilentlyContinue).SystemRestorePointCreationFrequency
        try {
            Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
            Set-ItemProperty -Path $restoreKey -Name SystemRestorePointCreationFrequency -Value 0 -Type DWord
            Checkpoint-Computer -Description 'PC Toolkit before repairs' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
            $restorePointCreated = $true
            Add-Completed 'Created a system restore point (PC Toolkit before repairs).'
        } catch {
            Write-Warning "Could not create a restore point: $($_.Exception.Message)"
        } finally {
            if ($null -eq $oldFrequency) {
                Remove-ItemProperty -Path $restoreKey -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue
            } else {
                Set-ItemProperty -Path $restoreKey -Name SystemRestorePointCreationFrequency -Value $oldFrequency -Type DWord
            }
        }
        if (-not $restorePointCreated) {
            $continue = if ($interactive) { Read-YesNo 'Continue without a restore point?' $false } else { $false }
            if (-not $continue) {
                $script:stopReason = 'A restore point could not be created, so nothing was changed.'
                $script:manual.Add('Turn on System Protection: search for "Create a restore point", select the Windows drive, click Configure and choose "Turn on system protection". Then try again.')
                return
            }
        }
    }

    Write-Section 'Recommended repairs'

    if ((Use-Option 'cleanup') -and (Test-ApprovedAction 'Temporary files and caches' 'Remove files older than one day')) {
        Write-Host 'Cleaning temporary files and caches...'
        $driveLetter = $env:SystemDrive.Substring(0, 1)
        $freeBefore = (Get-PSDrive -Name $driveLetter).Free
        foreach ($folder in @($env:TEMP, "$env:SystemRoot\Temp")) {
            if ($folder) {
                Get-ChildItem -LiteralPath $folder -Recurse -Force -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } |
                    Remove-Item -Force -ErrorAction SilentlyContinue
            }
        }
        $installerProcesses = Get-Process -Name TrustedInstaller, TiWorker -ErrorAction SilentlyContinue
        if (-not $script:data.System.RebootPending -and -not $installerProcesses) {
            Stop-Service -Name wuauserv, bits -Force -ErrorAction SilentlyContinue
            Get-ChildItem -LiteralPath "$env:SystemRoot\SoftwareDistribution\Download" -Force -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            Start-Service -Name bits, wuauserv -ErrorAction SilentlyContinue
        } else {
            $script:skipped.Add('Windows Update cache was not cleaned because an update is running or a restart is pending.')
        }
        if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) {
            Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue | Out-Null
        }
        Write-Host 'Removing superseded Windows component files (this may take several minutes)...'
        & dism.exe /Online /Cleanup-Image /StartComponentCleanup /Quiet | Out-Null
        $freeAfter = (Get-PSDrive -Name $driveLetter).Free
        Add-Completed ("Cleaned temporary files and caches; freed {0:N1} GB." -f ([math]::Max(0, $freeAfter - $freeBefore) / 1GB))
    }

    if ((Use-Option 'storage-sense') -and (Test-ApprovedAction 'Storage Sense' 'Enable automatic cleanup')) {
        $storageKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'
        if (-not (Test-Path $storageKey)) { New-Item -Path $storageKey -Force | Out-Null }
        Set-ItemProperty -Path $storageKey -Name '01' -Value 1 -Type DWord
        Add-Completed 'Turned on Storage Sense.'
    }
    if ((Use-Option 'power-plan') -and (Test-ApprovedAction 'Power plan' 'Switch to Balanced')) {
        & powercfg.exe /setactive SCHEME_BALANCED
        if ($LASTEXITCODE -eq 0) { Add-Completed 'Switched the power plan to Balanced.' }
        else { $script:manual.Add('Switch the power plan to Balanced in Control Panel > Power Options.') }
    }
    if ((Use-Option 'trim-enable') -and (Test-ApprovedAction 'TRIM' 'Enable TRIM for SSDs')) {
        & fsutil.exe behavior set DisableDeleteNotify 0 | Out-Null
        Add-Completed 'Turned on TRIM.'
    }
    if (Use-Option 'retrim') {
        foreach ($volume in @($script:data.Volumes | Where-Object MediaType -eq 'SSD')) {
            if (Test-ApprovedAction "Drive $($volume.Drive)" 'Run TRIM (ReTrim)') {
                try {
                    Optimize-Volume -DriveLetter $volume.Drive.Substring(0, 1) -ReTrim -ErrorAction Stop
                    Add-Completed "Optimized SSD $($volume.Drive) (TRIM)."
                } catch { Write-Warning "Could not run TRIM on $($volume.Drive): $($_.Exception.Message)" }
            }
        }
    }

    if ((Use-Option 'quick-scan') -and (Test-ApprovedAction 'Microsoft Defender' 'Update definitions and run a quick scan')) {
        Write-Host 'Updating Defender definitions and running a quick scan (5-15 minutes)...'
        try { Update-MpSignature -ErrorAction Stop } catch { Write-Warning "Could not update Defender definitions: $($_.Exception.Message)" }
        try {
            Start-MpScan -ScanType QuickScan -ErrorAction Stop
            $recentThreats = @(Get-MpThreatDetection -ErrorAction SilentlyContinue |
                Where-Object { $_.InitialDetectionTime -gt (Get-Date).AddHours(-2) })
            if ($recentThreats.Count) {
                Add-Completed "Quick scan finished; Defender reported $($recentThreats.Count) recent detection(s)."
                $script:manual.Add('Review Windows Security > Virus & threat protection > Protection history, and consider a full scan.')
            } else { Add-Completed 'Quick scan finished; no threats were found.' }
        } catch { Write-Warning "Defender quick scan failed: $($_.Exception.Message)" }
    } elseif (-not $script:data.Security.DefenderActive) {
        $script:skipped.Add('Defender scan skipped; run a scan using the active antivirus product.')
    }

    if ((Use-Option 'windows-repair' 'No clear signs of damaged Windows files were found. Run DISM and SFC anyway (15-40 minutes)?') -and
        (Test-ApprovedAction 'Windows system files' 'Repair with DISM and SFC')) {
        Write-Host 'Repairing the Windows image with DISM (10-30 minutes; the progress may stand still for a while)...'
        & dism.exe /Online /Cleanup-Image /RestoreHealth | Out-Null
        $dismExitCode = $LASTEXITCODE
        Write-Host 'Checking protected system files with SFC (5-15 minutes)...'
        & sfc.exe /scannow | Out-Null
        if ($dismExitCode -eq 0) {
            Add-Completed 'Checked and repaired Windows system files (DISM and SFC).'
            $script:restartNeeded = $true
        } else {
            Write-Warning "DISM failed with exit code $dismExitCode."
            $script:manual.Add("DISM could not repair Windows (exit code $dismExitCode). Consider an in-place repair install from Settings > System > Recovery. Back up files first.")
        }
    }

    if ((Use-Option 'windows-update') -and (Test-ApprovedAction 'Windows Update' 'Start update scan and installation')) {
        Start-Process -FilePath "$env:SystemRoot\System32\UsoClient.exe" -ArgumentList 'StartInteractiveScan' -WindowStyle Hidden -ErrorAction SilentlyContinue
        Start-Process 'ms-settings:windowsupdate' -ErrorAction SilentlyContinue
        Add-Completed 'Started Windows Update. Let it finish, then restart the computer.'
        $script:restartNeeded = $true
    }

    if ((Use-Option 'page-file' 'The page file appears disabled. Let Windows manage it automatically?' $true) -and
        (Test-ApprovedAction 'Page file' 'Enable automatic management')) {
        $computer = Get-CimInstance Win32_ComputerSystem
        Set-CimInstance -InputObject $computer -Property @{ AutomaticManagedPagefile = $true }
        Add-Completed 'Let Windows manage the page file; this takes effect after a restart.'
        $script:restartNeeded = $true
    }

    if (-not $AutomaticOnly) {
        Write-Section 'Startup apps'
        $startupEntries = @(Get-StartupEntries | Where-Object Enabled)
        $selected = @()
        if ($null -ne $script:selection) {
            $selected = @($startupEntries | Where-Object { $script:selection -contains "startup:$($_.Name)" })
        } elseif ($startupEntries.Count) {
            Write-Host 'Apps configured to start with Windows:'
            Write-Host 'Disabling startup does not uninstall an app; you can still open it normally.' -ForegroundColor DarkGray
            for ($index = 0; $index -lt $startupEntries.Count; $index++) {
                $entry = $startupEntries[$index]
                $color = switch ($entry.Suggestion) { 'Can be disabled' { 'Yellow' } 'Keep' { 'Green' } default { 'Gray' } }
                Write-Host ("  {0,2}. {1,-40} " -f ($index + 1), $entry.Name) -NoNewline
                Write-Host $entry.Suggestion -ForegroundColor $color
            }
            Write-Host 'Enter the numbers to disable (e.g. 1,3,5), A for all suggested candidates, or Enter for none.'
            $answer = Read-Host 'Selection'
            if ($answer -match '^\s*a\s*$') {
                $selected = @($startupEntries | Where-Object Suggestion -eq 'Can be disabled')
            } elseif ($answer) {
                foreach ($token in ($answer -split '[,\s;]+')) {
                    $number = 0
                    if ([int]::TryParse($token, [ref]$number) -and $number -ge 1 -and $number -le $startupEntries.Count) {
                        $selected += $startupEntries[$number - 1]
                    }
                }
            }
        }
        foreach ($entry in ($selected | Select-Object -Unique)) {
            if (Test-ApprovedAction $entry.Name 'Disable startup entry') {
                try {
                    Disable-StartupEntry $entry
                    Add-Completed "Stopped $($entry.Name) from starting with Windows."
                } catch { Write-Warning "Could not disable $($entry.Name): $($_.Exception.Message)" }
            }
        }
        if ($selected.Count) {
            $script:manual.Add('Some apps have their own "Start with Windows" setting. If an app comes back, turn that setting off in the app. Startup apps can be turned on again in Task Manager > Startup apps.')
        } else {
            Write-Host 'No startup apps selected.'
        }

        Write-Section 'Unwanted programs'
        $unwanted = @(Get-UnwantedPrograms (Get-InstalledPrograms))
        $anyUninstall = $false
        foreach ($program in $unwanted) {
            $id = "uninstall:$($program.Name)"
            if ($null -ne $script:selection) {
                if ($script:selection -notcontains $id) { continue }
            } else {
                Write-Host "`n$($program.Name) - $($program.Reason)" -ForegroundColor Yellow
                if (-not $interactive -or -not (Read-YesNo "Uninstall $($program.Name)?" $true)) { continue }
            }
            $anyUninstall = $true
            if (-not $program.UninstallCommand) {
                $script:manual.Add("Uninstall $($program.Name) from Settings > Apps > Installed apps (no uninstaller was found automatically).")
                continue
            }
            if (-not (Test-ApprovedAction $program.Name 'Uninstall')) { continue }
            Write-Host "Starting the uninstaller for $($program.Name). Follow the steps in its window..."
            try {
                $uninstall = $program.UninstallCommand
                if ($uninstall -match 'msiexec' -and $uninstall -match '(\{[0-9A-Fa-f\-]+\})') {
                    Start-Process -FilePath 'msiexec.exe' -ArgumentList "/x $($Matches[1])" -Wait
                } elseif ($uninstall -match '^\s*"([^"]+)"\s*(.*)$' -or $uninstall -match '^\s*(\S+\.exe)\s*(.*)$') {
                    if ($Matches[2]) { Start-Process -FilePath $Matches[1] -ArgumentList $Matches[2] -Wait }
                    else { Start-Process -FilePath $Matches[1] -Wait }
                } else {
                    Start-Process -FilePath 'cmd.exe' -ArgumentList "/c $uninstall" -Wait
                }
                Add-Completed "Ran the uninstaller for $($program.Name)."
                $script:restartNeeded = $true
            } catch { Write-Warning "Could not start the uninstaller: $($_.Exception.Message)" }
            if ($program.Name -match 'McAfee') {
                $script:manual.Add('If McAfee is still installed, use the official McAfee Consumer Product Removal tool (MCPR).')
            }
            if ($program.Name -match 'Norton') {
                $script:manual.Add('If Norton is still installed, use the official Norton Remove and Reinstall tool and choose Remove Only.')
            }
        }
        if (-not $anyUninstall) { Write-Host 'No programs selected for removal.' }

        Write-Section 'Extra actions'
        if ((Use-Option 'recycle-bin' "The Recycle Bin contains about $($script:data.Cleanable.RecycleBinGB) GB. Empty it?" $false) -and
            (Test-ApprovedAction 'Recycle Bin' 'Empty')) {
            Clear-RecycleBin -Force -ErrorAction SilentlyContinue
            Add-Completed 'Emptied the Recycle Bin.'
        }
        if ((Use-Option 'hibernation' "Turn off hibernation to free $($script:data.Cleanable.HibernationFileGB) GB? This also turns off Fast Startup." $false) -and
            (Test-ApprovedAction 'Hibernation' 'Disable (powercfg /hibernate off)')) {
            & powercfg.exe /hibernate off
            Add-Completed 'Turned off hibernation.'
        }
        if ((Use-Option 'full-scan' 'Run a full Defender scan now? This may take over an hour.' $false) -and
            (Test-ApprovedAction 'Microsoft Defender' 'Run a full scan')) {
            Write-Host 'Running a full virus scan. This can take 1-3 hours...'
            Start-MpScan -ScanType FullScan
            Add-Completed 'Ran a full virus scan. Results are in Windows Security > Protection history.'
        }
        foreach ($volume in @($script:data.Volumes | Where-Object MediaType -eq 'HDD')) {
            if ((Use-Option "defrag:$($volume.Drive)" "Defragment $($volume.Drive)? This can take a long time." $false) -and
                (Test-ApprovedAction "Drive $($volume.Drive)" 'Defragment')) {
                Write-Host "Defragmenting $($volume.Drive). This can take a long time..."
                Optimize-Volume -DriveLetter $volume.Drive.Substring(0, 1) -Defrag
                Add-Completed "Defragmented $($volume.Drive)."
            }
        }
    }

    foreach ($finding in @($script:data.Findings | Where-Object { $_.Action -eq 'Manual' -and $_.Recommendation })) {
        $script:manual.Add("$($finding.Title): $($finding.Recommendation)")
    }
    $script:reachedEnd = $true
} finally {
    $restartRecommended = -not $script:stopReason -and
        ($script:restartNeeded -or (Test-Finding 'UPTIME_LONG') -or (Test-Finding 'REBOOT_PENDING'))
    $manualList = @($script:manual | Select-Object -Unique)
    Write-Section 'Summary'
    if ($script:stopReason) { Write-Host $script:stopReason -ForegroundColor Red }
    Write-Host 'Completed:' -ForegroundColor Green
    if ($script:completed.Count) { $script:completed | ForEach-Object { Write-Host "  - $_" } } else { Write-Host '  (none)' }
    if ($script:skipped.Count) {
        Write-Host 'Skipped:' -ForegroundColor Yellow
        $script:skipped | ForEach-Object { Write-Host "  - $_" }
    }
    Write-Host 'Manual follow-up:' -ForegroundColor Cyan
    if ($manualList.Count) { $manualList | ForEach-Object { Write-Host "  - $_" } } else { Write-Host '  (none)' }
    $summary = @(
        "PC Toolkit $script:ToolkitVersion - repairs on $env:COMPUTERNAME - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
        $(if ($dryRun) { 'DRY RUN - no system changes were made.' })
        $(if ($script:stopReason) { "STOPPED: $($script:stopReason)" })
        "Diagnosis report: $ReportPath"
        ''
        'COMPLETED:'
        @($script:completed | ForEach-Object { "  - $_" })
        ''
        'SKIPPED:'
        @($script:skipped | ForEach-Object { "  - $_" })
        ''
        'MANUAL FOLLOW-UP:'
        @($manualList | ForEach-Object { "  - $_" })
    )
    $summaryPath = Join-Path $reportFolder "repair-summary_$stamp.txt"
    Invoke-WithoutWhatIf { Set-Content -LiteralPath $summaryPath -Value $summary -Encoding UTF8 }
    Write-Host "`nSummary and log saved in: $reportFolder" -ForegroundColor Green
    if ($ResultPath) {
        $result = [ordered]@{
            DryRun = $dryRun
            Stopped = $script:stopReason
            Completed = @($script:completed)
            Skipped = @($script:skipped)
            Manual = $manualList
            RestartRecommended = [bool]$restartRecommended
        }
        Invoke-WithoutWhatIf { $result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResultPath -Encoding UTF8 }
    }
    Invoke-WithoutWhatIf { try { Stop-Transcript | Out-Null } catch {} }
    # An early return (for example the drive safety stop) skips the code below; keep the window open so the message can be read.
    if (-not $script:reachedEnd -and $interactive) { Read-Host 'Press Enter to close' }
}

if ($restartRecommended -and $interactive) {
    if ((Read-YesNo 'A restart is recommended. Restart now? Save any open work first.' $false) -and
        (Test-ApprovedAction 'Computer' 'Restart')) {
        Restart-Computer -Force
        return
    }
    Write-Host 'Remember to restart the computer (choose Restart, not Shut down).' -ForegroundColor Yellow
}
if ($interactive) { Read-Host 'Press Enter to close' }
