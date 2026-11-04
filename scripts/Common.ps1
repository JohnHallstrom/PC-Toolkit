$script:ToolkitVersion = '1.2'
$script:ToolkitRoot = Split-Path -Parent $PSScriptRoot
$script:ReportsRoot = Join-Path $script:ToolkitRoot 'Reports'
$script:Themes = @('Sparkollen', 'Neutral')
$script:ToolkitTheme = 'Neutral'
$script:Strings = @{}
$script:MissingStrings = New-Object System.Collections.Generic.HashSet[string]

# Sparkollen = Swedish dog-sport theme (default), Neutral = plain English. Translations live in lang\sv\*.psd1,
# keyed by the English text (with {0} placeholders), so a missing translation falls back to English.
function Set-ToolkitTheme([string]$Theme) {
    if ($script:Themes -notcontains $Theme) { $Theme = 'Sparkollen' }
    $script:ToolkitTheme = $Theme
    $script:Strings = @{}
    if ($Theme -eq 'Sparkollen') {
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'lang\sv') -Filter '*.psd1' -ErrorAction SilentlyContinue) {
            $table = Import-PowerShellDataFile -LiteralPath $file.FullName
            foreach ($key in $table.Keys) { $script:Strings[$key] = $table[$key] }
        }
    }
}

function Get-StringTable([string]$Name) {
    $path = Join-Path $PSScriptRoot "lang\sv\$Name.psd1"
    if ($script:ToolkitTheme -eq 'Sparkollen' -and (Test-Path -LiteralPath $path)) { Import-PowerShellDataFile -LiteralPath $path } else { @{} }
}

# Translates English text for the active theme. Extra arguments fill {0}, {1}, ...
function T([string]$Text) {
    $template = $Text
    if ($script:ToolkitTheme -eq 'Sparkollen' -and $Text) {
        if ($script:Strings.ContainsKey($Text)) { $template = $script:Strings[$Text] } else { [void]$script:MissingStrings.Add($Text) }
    }
    if ($args.Count) { $template -f $args } else { $template }
}

# Translates a display value (status, health, category...) when a translation exists; other values are shown as-is.
function Tv($Value) {
    $text = "$Value"
    if ($script:ToolkitTheme -eq 'Sparkollen' -and $script:Strings.ContainsKey($text)) { $script:Strings[$text] } else { $text }
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Start-AsAdmin {
    param([string]$ScriptPath, $Parameters)
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$ScriptPath`"")
    foreach ($key in $Parameters.Keys) {
        $value = $Parameters[$key]
        if ($value -is [System.Management.Automation.SwitchParameter] -or $value -is [bool]) {
            if ([bool]$value) { $arguments += "-$key" }
        } else {
            $arguments += "-$key"
            $arguments += "`"$value`""
        }
    }
    Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList ($arguments -join ' ') -Verb RunAs -ErrorAction Stop
}

function Write-Section([string]$Text) {
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkCyan
    Write-Host " $Text" -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor DarkCyan
}

function Read-YesNo {
    param([string]$Question, [bool]$Default = $false)
    $yes = T 'y'; $no = T 'n'
    $hint = if ($Default) { "[$($yes.ToUpper())/$no]" } else { "[$yes/$($no.ToUpper())]" }
    while ($true) {
        $answer = Read-Host "$Question $hint"
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        switch ($answer.Trim().ToLowerInvariant()) {
            { $_ -in 'y', 'yes', 'j', 'ja' } { return $true }
            { $_ -in 'n', 'no', 'nej' } { return $false }
            default { Write-Host (T 'Please answer y (yes) or n (no).') -ForegroundColor Yellow }
        }
    }
}

function ConvertTo-MediaType($Value) {
    switch ("$Value") {
        '3' { 'HDD' } '4' { 'SSD' } '5' { 'SCM' }
        '0' { 'Unknown' } 'Unspecified' { 'Unknown' } '' { 'Unknown' }
        default { "$Value" }
    }
}

function ConvertTo-BusType($Value) {
    switch ("$Value") {
        '17' { 'NVMe' } '11' { 'SATA' } '7' { 'USB' } '8' { 'RAID' }
        '10' { 'SAS' } '3' { 'ATA' }
        default { "$Value" }
    }
}

function ConvertTo-HealthStatus($Value) {
    switch ("$Value") {
        '0' { 'Healthy' } '1' { 'Warning' } '2' { 'Unhealthy' } '5' { 'Unknown' }
        default { "$Value" }
    }
}

function Get-FolderSizeGB([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -ErrorAction SilentlyContinue)) { return 0 }
    $bytes = (Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    [math]::Round(([double]$bytes / 1GB), 2)
}

function Get-CleanableFolders {
    @(
        [pscustomobject]@{ Name = (T 'User temporary files'); Path = $env:TEMP }
        [pscustomobject]@{ Name = (T 'Windows temporary files'); Path = "$env:SystemRoot\Temp" }
        [pscustomobject]@{ Name = (T 'Windows Update download cache'); Path = "$env:SystemRoot\SoftwareDistribution\Download" }
        [pscustomobject]@{ Name = (T 'Delivery Optimization cache'); Path = "$env:SystemRoot\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache" }
    )
}

$script:StartupCanDisable = @(
    'Steam', 'EpicGames', 'EADesktop', 'EA Desktop', 'Origin', 'Battle\.net', 'Ubisoft', 'Uplay', 'GalaxyClient', 'GOG',
    'Riot', 'Discord', 'Spotify', 'Teams', 'Skype', 'Zoom', 'Opera', 'EdgeAutoLaunch', 'ChromeAutoLaunch',
    'Adobe', 'Acrobat', 'CCleaner', 'uTorrent', 'BitTorrent', 'qBittorrent', 'Overwolf', 'Medal', 'Outplayed',
    'Dropbox', 'Messenger', 'WhatsApp', 'CurseForge', 'Wallpaper', 'iTunesHelper', 'Cortana'
)
$script:StartupOptional = @(
    'OneDrive', 'iCUE', 'Corsair', 'Razer', 'Synapse', 'SteelSeries', 'GHub', 'LGHUB', 'Logitech', 'Armoury',
    'NZXT', 'SignalRgb', 'OpenRGB', '\bMSI\b', 'Afterburner', 'RTSS', 'Lian Li', 'Elgato', 'Wooting', 'HyperX', 'Google Drive'
)
$script:StartupKeep = @(
    'SecurityHealth', 'Windows Defender', 'Realtek', 'RtkAud', 'RTHDVCPL', 'NVIDIA', 'NvBackend', '\bAMD\b', 'Radeon',
    '\bIntel\b', 'IGCC', 'Synaptics', 'ETDCtrl', 'Bluetooth', 'Waves'
)

function Get-StartupSuggestion([string]$Text) {
    foreach ($pattern in $script:StartupKeep) {
        if ($Text -match $pattern) { return 'Keep' }
    }
    foreach ($pattern in $script:StartupCanDisable) {
        if ($Text -match $pattern) { return 'Can be disabled' }
    }
    foreach ($pattern in $script:StartupOptional) {
        if ($Text -match $pattern) { return 'Optional' }
    }
    'Unknown (look up the app before changing it)'
}

function Get-StartupEntries {
    $base = 'Software\Microsoft\Windows\CurrentVersion'
    $sources = @(
        @{ Kind = 'Registry'; Path = "HKCU:\$base\Run"; Approved = "HKEY_CURRENT_USER\$base\Explorer\StartupApproved\Run"; Scope = 'Current user' }
        @{ Kind = 'Registry'; Path = "HKLM:\$base\Run"; Approved = "HKEY_LOCAL_MACHINE\$base\Explorer\StartupApproved\Run"; Scope = 'All users' }
        @{ Kind = 'Registry'; Path = "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"; Approved = "HKEY_LOCAL_MACHINE\$base\Explorer\StartupApproved\Run32"; Scope = 'All users' }
        @{ Kind = 'Folder'; Path = [Environment]::GetFolderPath('Startup'); Approved = "HKEY_CURRENT_USER\$base\Explorer\StartupApproved\StartupFolder"; Scope = 'Current user' }
        @{ Kind = 'Folder'; Path = [Environment]::GetFolderPath('CommonStartup'); Approved = "HKEY_LOCAL_MACHINE\$base\Explorer\StartupApproved\StartupFolder"; Scope = 'All users' }
    )

    foreach ($source in $sources) {
        if (-not $source.Path -or -not (Test-Path -LiteralPath $source.Path -ErrorAction SilentlyContinue)) { continue }
        $entries = @()
        if ($source.Kind -eq 'Registry') {
            $key = Get-Item -LiteralPath $source.Path
            foreach ($name in $key.GetValueNames()) {
                if (-not [string]::IsNullOrEmpty($name)) {
                    $entries += [pscustomobject]@{ Name = $name; Command = "$($key.GetValue($name))" }
                }
            }
        } else {
            Get-ChildItem -LiteralPath $source.Path -File -Force -ErrorAction SilentlyContinue |
                Where-Object Name -ne 'desktop.ini' |
                ForEach-Object { $entries += [pscustomobject]@{ Name = $_.Name; Command = $_.FullName } }
        }

        foreach ($entry in $entries) {
            $enabled = $true
            $approved = [Microsoft.Win32.Registry]::GetValue($source.Approved, $entry.Name, $null)
            if ($approved -is [byte[]] -and $approved.Length -gt 0 -and ($approved[0] -band 1)) { $enabled = $false }
            [pscustomobject]@{
                Name = $entry.Name
                Enabled = $enabled
                Suggestion = Get-StartupSuggestion "$($entry.Name) $($entry.Command)"
                Scope = $source.Scope
                Command = $entry.Command
                ApprovedRegistryKey = $source.Approved
            }
        }
    }
}

function Disable-StartupEntry($Entry) {
    $data = [byte[]](@(3, 0, 0, 0) + [BitConverter]::GetBytes([DateTime]::Now.ToFileTime()))
    [Microsoft.Win32.Registry]::SetValue(
        $Entry.ApprovedRegistryKey, $Entry.Name, $data, [Microsoft.Win32.RegistryValueKind]::Binary
    )
}

$script:UnwantedPatterns = @(
    @{ Pattern = 'McAfee'; Reason = 'Bundled antivirus that may slow the computer; Microsoft Defender is sufficient for most people.' }
    @{ Pattern = 'Norton|Symantec'; Reason = 'Bundled antivirus that may slow the computer; Microsoft Defender is sufficient for most people.' }
    @{ Pattern = '^Avast|^AVG |^Avira|TotalAV|Total AV|Bullguard|Panda Dome'; Reason = 'Additional antivirus software. Microsoft Defender is sufficient for most people.' }
    @{ Pattern = 'CCleaner'; Reason = 'A cleaner that runs in the background without providing a meaningful speed benefit.' }
    @{ Pattern = 'Driver Booster|Advanced SystemCare|IObit|DriverPack|Driver Easy|PC HelpSoft|Auslogics|Glary|Wise Care|PC Optimizer|Restoro|Reimage|Fortect|Outbyte|Driver Support'; Reason = 'System “optimizer” software that often causes more problems than it solves.' }
    @{ Pattern = 'WildTangent'; Reason = 'Bundled promotional games.' }
    @{ Pattern = 'Wave Browser|WebDiscover|OneLaunch|Shift Browser|Segurazo|ByteFence|PC App Store|Web Companion'; Reason = 'Potentially unwanted software or adware.' }
)

function Get-InstalledPrograms {
    $paths = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and -not $_.SystemComponent -and -not $_.ParentKeyName } |
        ForEach-Object {
            [pscustomobject]@{
                Name = "$($_.DisplayName)".Trim()
                Version = $_.DisplayVersion
                Publisher = $_.Publisher
                SizeMB = $(if ($_.EstimatedSize) { [math]::Round($_.EstimatedSize / 1024, 0) } else { $null })
                UninstallCommand = $_.UninstallString
                QuietUninstallCommand = $_.QuietUninstallString
            }
        } | Sort-Object Name -Unique
}

function Get-UnwantedPrograms($Programs) {
    foreach ($program in $Programs) {
        foreach ($pattern in $script:UnwantedPatterns) {
            if ($program.Name -match $pattern.Pattern) {
                [pscustomobject]@{
                    Name = $program.Name
                    Publisher = $program.Publisher
                    Reason = (T $pattern.Reason)
                    UninstallCommand = $program.UninstallCommand
                }
                break
            }
        }
    }
}

function Test-ReportFinding($Data, [string]$Id) { @($Data.Findings | ForEach-Object { $_.Id }) -contains $Id }

# Single source of truth for what the repair step can do, used by both the report (checkboxes) and Repair.ps1.
# Automatic = runs without asking in console mode when Default is true.
function Get-RepairOptions($Data) {
    $options = New-Object System.Collections.Generic.List[object]
    function Add-Option([string]$Id, [string]$Group, [string]$Title, [string]$Description, [bool]$Default, [string]$Duration = '', [bool]$Automatic = $false, [string]$Tag = '') {
        $options.Add([pscustomobject]@{ Id = $Id; Group = $Group; Title = $Title; Description = $Description; Default = $Default; Duration = $Duration; Automatic = $Automatic; Tag = $Tag })
    }
    $cleanableGB = [math]::Round((@($Data.Cleanable.Folders) | Where-Object { $_ } | Measure-Object SizeGB -Sum).Sum, 1)
    $sizeText = if ($cleanableGB -gt 0) { ' ' + (T 'About {0} GB found.' $cleanableGB) } else { '' }
    Add-Option 'cleanup' 'recommended' (T 'Clean temporary files and caches') ((T 'Removes temporary files older than one day, the Windows Update download cache and superseded Windows components.') + $sizeText) $true '2-10 min' $true
    if (Test-ReportFinding $Data 'STORAGE_SENSE_DISABLED') {
        Add-Option 'storage-sense' 'recommended' (T 'Turn on Storage Sense') (T 'Windows then cleans temporary files automatically in the future.') $true (T 'Seconds') $true
    }
    if (Test-ReportFinding $Data 'POWER_SAVER') {
        Add-Option 'power-plan' 'recommended' (T 'Switch power plan to Balanced') (T 'Power Saver limits processor speed.') $true (T 'Seconds') $true
    }
    if (Test-ReportFinding $Data 'TRIM_DISABLED') {
        Add-Option 'trim-enable' 'recommended' (T 'Turn on TRIM for SSDs') (T 'Keeps SSDs fast over time.') $true (T 'Seconds') $true
    }
    if (@($Data.Volumes | Where-Object { $_ -and $_.MediaType -eq 'SSD' }).Count) {
        Add-Option 'retrim' 'recommended' (T 'Optimize SSDs (TRIM)') (T 'Tells the SSD which space is free. Safe and quick.') $true '1 min' $true
    }
    if ($Data.Security.DefenderActive) {
        Add-Option 'quick-scan' 'recommended' (T 'Update Microsoft Defender and run a quick virus scan') (T 'Checks the most common places for malware.') $true '5-15 min' $true
    }
    $repairRecommended = (Test-ReportFinding $Data 'LOW_STABILITY') -or (Test-ReportFinding $Data 'WINDOWS_UPDATE_OLD')
    $repairGroup = if ($repairRecommended) { 'recommended' } else { 'extra' }
    $repairText = if ($repairRecommended) { T 'The check found signs that Windows files may be damaged. Repairs them with DISM and SFC.' } else { T 'No signs of damaged Windows files were found, but you can check anyway with DISM and SFC.' }
    Add-Option 'windows-repair' $repairGroup (T 'Repair Windows system files') $repairText $repairRecommended '15-40 min' $true
    if ((Test-ReportFinding $Data 'UPDATES_PENDING') -or (Test-ReportFinding $Data 'WINDOWS_UPDATE_OLD')) {
        Add-Option 'windows-update' 'recommended' (T 'Start Windows Update') (T 'Searches for and installs updates in the background. Restart afterwards.') $true (T 'Runs in background') $true
    }
    if (Test-ReportFinding $Data 'PAGE_FILE_OFF') {
        Add-Option 'page-file' 'recommended' (T 'Let Windows manage the page file') (T 'A disabled page file can cause crashes and slowdowns in games. Takes effect after a restart.') $true (T 'Seconds')
    }
    foreach ($entry in @($Data.Startup.Entries | Where-Object { $_ -and $_.Enabled })) {
        Add-Option "startup:$($entry.Name)" 'startup' $entry.Name $entry.Command ($entry.Suggestion -eq 'Can be disabled') '' $false $entry.Suggestion
    }
    foreach ($program in @($Data.Programs.Unwanted | Where-Object { $_ })) {
        Add-Option "uninstall:$($program.Name)" 'programs' (T 'Uninstall {0}' $program.Name) $program.Reason $true (T 'Follow the uninstaller')
    }
    if ($Data.Cleanable.RecycleBinGB -ge 0.1) {
        Add-Option 'recycle-bin' 'extra' (T 'Empty the Recycle Bin') (T 'Contains about {0} GB. Deleted files cannot be restored afterwards.' $Data.Cleanable.RecycleBinGB) $false (T 'Seconds')
    }
    if ((Test-ReportFinding $Data 'LOW_SYSTEM_SPACE') -and $Data.Cleanable.HibernationFileGB -ge 4) {
        Add-Option 'hibernation' 'extra' (T 'Turn off hibernation') (T 'Frees {0} GB. Also turns off Fast Startup.' $Data.Cleanable.HibernationFileGB) $false (T 'Seconds')
    }
    if ($Data.Security.DefenderActive) {
        Add-Option 'full-scan' 'extra' (T 'Run a full virus scan') (T 'Scans every file. The computer can be used meanwhile but may be slower.') $false (T '1-3 hours')
    }
    foreach ($volume in @($Data.Volumes | Where-Object { $_ -and $_.MediaType -eq 'HDD' })) {
        Add-Option "defrag:$($volume.Drive)" 'extra' (T 'Defragment {0}' $volume.Drive) (T 'Can speed up a mechanical hard drive. Do not use the computer meanwhile.') $false (T '30 min - several hours')
    }
    $options
}
