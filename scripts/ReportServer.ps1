<#
.SYNOPSIS
    Serves the diagnostic report on this computer only (127.0.0.1) so repairs can be chosen and started from the browser.

.DESCRIPTION
    Started by Diagnose.ps1 after a check. The page address contains a random secret, every
    request that changes something must repeat it in a header, and only repair options offered
    by the report are accepted. Stops when the user clicks Finish in the report, when the
    window is closed, or after a period without activity.

.PARAMETER ReportFolder
    Folder containing diagnostic-report.json and diagnostic-report.html.

.PARAMETER DryRun
    Start repairs with -WhatIf so nothing is changed (for testing).

.PARAMETER NoBrowser
    Do not open the report in the web browser.

.PARAMETER Port
    Port to listen on. 0 picks a free port.

.PARAMETER Token
    Secret used in the address. Generated when empty.

.PARAMETER IdleMinutes
    Stop after this many minutes without requests while no repair is running.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ReportFolder,
    [switch]$DryRun,
    [switch]$NoBrowser,
    [int]$Port = 0,
    [string]$Token,
    [int]$IdleMinutes = 30
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

$jsonPath = Join-Path $ReportFolder 'diagnostic-report.json'
$data = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
Set-ToolkitTheme $(if ($data.Meta.Theme) { $data.Meta.Theme } else { 'Sparkollen' })
# Theme versions of the report the dropdown may switch between: theme name -> file name in the report folder.
$themePages = @{}
if ($data.Meta.ThemeReports) {
    foreach ($property in $data.Meta.ThemeReports.PSObject.Properties) {
        if ($script:Themes -contains $property.Name -and "$($property.Value)" -match '^diagnostic-report(-[a-z]+)?\.html$') { $themePages[$property.Name] = "$($property.Value)" }
    }
}
$allowedOptions = @(Get-RepairOptions $data | ForEach-Object { $_.Id })
$isAdmin = Test-IsAdmin
$driveBlocked = [bool]$data.Drives.DriveProblem -or -not [bool]$data.Drives.CheckCompleted

if (-not $Token) {
    $bytes = New-Object byte[] 24
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $Token = -join ($bytes | ForEach-Object { $_.ToString('x2') })
}
if ($Token -notmatch '^[A-Za-z0-9]{16,}$') { throw (T 'The token must be at least 16 letters or digits.') }
if ($Port -eq 0) {
    $probe = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, 0)
    $probe.Start(); $Port = $probe.LocalEndpoint.Port; $probe.Stop()
}
$origin = "http://127.0.0.1:$Port"
$baseUrl = "$origin/$Token/"

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($baseUrl)
$listener.Start()

$script:repair = $null
$script:lastRequest = Get-Date
$script:stopRequested = $false

function Send-Response($Context, [int]$Status, [string]$Body, [string]$ContentType = 'application/json; charset=utf-8') {
    $response = $Context.Response
    $response.StatusCode = $Status
    $response.ContentType = $ContentType
    $response.Headers['Cache-Control'] = 'no-store'
    $response.Headers['X-Content-Type-Options'] = 'nosniff'
    $response.Headers['X-Frame-Options'] = 'DENY'
    $response.Headers['Referrer-Policy'] = 'no-referrer'
    $response.Headers['Content-Security-Policy'] = "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; img-src data:; form-action 'none'; frame-ancestors 'none'"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $response.ContentLength64 = $bytes.Length
    try { $response.OutputStream.Write($bytes, 0, $bytes.Length) } finally { $response.Close() }
}
function Send-Json($Context, [int]$Status, $Object) { Send-Response $Context $Status ($Object | ConvertTo-Json -Depth 5 -Compress) }

function Read-SharedText([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return '' }
    $stream = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try { (New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)).ReadToEnd() } finally { $stream.Dispose() }
}

function Get-RepairStatus {
    if (-not $script:repair) { return [ordered]@{ State = 'idle' } }
    $log = @((Read-SharedText $script:repair.ProgressPath) -split "`r?`n" | Where-Object { $_ -ne '' } | Select-Object -Last 400)
    $status = [ordered]@{
        State = 'running'
        ElapsedSeconds = [int]((Get-Date) - $script:repair.StartedAt).TotalSeconds
        Log = $log
    }
    if ($script:repair.Process.HasExited) {
        $status.State = 'done'
        $resultText = Read-SharedText $script:repair.ResultPath
        $status.Result = if ($resultText) { $resultText | ConvertFrom-Json } else {
            [ordered]@{ Stopped = (T 'The repair step ended unexpectedly. See repair-log in the report folder.'); Completed = @(); Skipped = @(); Manual = @(); RestartRecommended = $false }
        }
    }
    $status
}

function Start-Repair($Context, $Body) {
    if ($driveBlocked) { return Send-Json $Context 409 @{ Error = (T 'Repairs are blocked because drive health is uncertain. Back up important files first.') } }
    if (-not $isAdmin -and -not $DryRun) { return Send-Json $Context 403 @{ Error = (T 'PC Toolkit does not have administrator permission. Close it, start it again and click Yes when Windows asks.') } }
    if ($script:repair -and -not $script:repair.Process.HasExited) { return Send-Json $Context 409 @{ Error = (T 'A repair is already running.') } }
    $requested = @()
    $repairTheme = $script:ToolkitTheme
    try {
        $parsed = $Body | ConvertFrom-Json
        $requested = @($parsed.Options | ForEach-Object { "$_" })
        if ($parsed.Theme) {
            if ($script:Themes -cnotcontains "$($parsed.Theme)") { return Send-Json $Context 400 @{ Error = (T 'Invalid selection.') } }
            $repairTheme = "$($parsed.Theme)"
        }
    } catch { }
    $requested = @($requested | Select-Object -Unique)
    $invalid = @($requested | Where-Object { $allowedOptions -notcontains $_ })
    if (-not $requested.Count -or $invalid.Count) { return Send-Json $Context 400 @{ Error = (T 'Invalid selection.') } }

    $stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $selectionPath = Join-Path $ReportFolder "repair-selection_$stamp.json"
    $progressPath = Join-Path $ReportFolder "repair-progress_$stamp.txt"
    $resultPath = Join-Path $ReportFolder "repair-result_$stamp.json"
    @{ Options = $requested } | ConvertTo-Json | Set-Content -LiteralPath $selectionPath -Encoding UTF8
    Set-Content -LiteralPath $progressPath -Value '' -Encoding UTF8
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $PSScriptRoot 'Repair.ps1')`"",
        '-ReportPath', "`"$jsonPath`"", '-SelectionPath', "`"$selectionPath`"",
        '-ProgressPath', "`"$progressPath`"", '-ResultPath', "`"$resultPath`"", '-Theme', $repairTheme)
    if ($DryRun) { $arguments += '-WhatIf', '-NoElevation' }
    $process = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList ($arguments -join ' ') -WindowStyle Hidden -PassThru
    $script:repair = @{ Process = $process; ProgressPath = $progressPath; ResultPath = $resultPath; StartedAt = Get-Date }
    Write-Host (T '{0} Repairs started from the report ({1} selected).' (Get-Date -Format 'HH:mm') $requested.Count) -ForegroundColor Cyan
    Send-Json $Context 202 @{ State = 'running' }
}

function Invoke-Request($Context) {
    $request = $Context.Request
    if (-not $request.Url.AbsolutePath.StartsWith("/$Token/", [StringComparison]::Ordinal) -and $request.Url.AbsolutePath -cne "/$Token") {
        return Send-Json $Context 404 @{ Error = (T 'Not found') }
    }
    $path =  $request.Url.AbsolutePath.Substring($Token.Length + 1).Trim('/')
    if ($request.Headers['Host'] -ne "127.0.0.1:$Port") { return Send-Json $Context 403 @{ Error = (T 'Forbidden') } }

    if ($request.HttpMethod -eq 'GET') {
        $pageFile = $null
        if ($path -eq '') { $pageFile = 'diagnostic-report.html' }
        elseif ($themePages.Values -ccontains $path) { $pageFile = $path }
        if ($pageFile) {
            $page = [System.IO.File]::ReadAllText((Join-Path $ReportFolder $pageFile), [System.Text.Encoding]::UTF8)
            $config = "<script>window.PCTK={token:'$Token',dryRun:$("$([bool]$DryRun)".ToLower()),admin:$("$isAdmin".ToLower())};</script>"
            return Send-Response $Context 200 $page.Replace('</head>', "$config</head>") 'text/html; charset=utf-8'
        }
        switch ($path) {
            'status' { return Send-Json $Context 200 (Get-RepairStatus) }
            default { return Send-Json $Context 404 @{ Error = (T 'Not found') } }
        }
    }
    if ($request.HttpMethod -ne 'POST') { return Send-Json $Context 405 @{ Error = (T 'Method not allowed') } }
    $requestOrigin = $request.Headers['Origin']
    if ($request.Headers['X-PCTK-Token'] -ne $Token -or ($requestOrigin -and $requestOrigin -ne $origin)) {
        return Send-Json $Context 403 @{ Error = (T 'Forbidden') }
    }
    if ($request.ContentLength64 -gt 65536) { return Send-Json $Context 413 @{ Error = (T 'Too large') } }
    $body = (New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)).ReadToEnd()
    $running = $script:repair -and -not $script:repair.Process.HasExited
    switch ($path) {
        'repair' { return Start-Repair $Context $body }
        'restart' {
            if ($running) { return Send-Json $Context 409 @{ Error = (T 'Wait until the repairs have finished.') } }
            if (-not $DryRun) { & shutdown.exe /r /t 30 /c (T 'PC Toolkit: the computer restarts in 30 seconds. Save your work.') }
            Write-Host (T '{0} Restart requested from the report.' (Get-Date -Format 'HH:mm')) -ForegroundColor Yellow
            $script:stopRequested = $true
            return Send-Json $Context 200 @{ Seconds = 30; DryRun = [bool]$DryRun }
        }
        'open-folder' {
            Start-Process -FilePath "$env:SystemRoot\explorer.exe" -ArgumentList "`"$ReportFolder`""
            return Send-Json $Context 200 @{ Ok = $true }
        }
        'shutdown' {
            if ($running) { return Send-Json $Context 409 @{ Error = (T 'Wait until the repairs have finished.') } }
            $script:stopRequested = $true
            return Send-Json $Context 200 @{ Ok = $true }
        }
        default { return Send-Json $Context 404 @{ Error = (T 'Not found') } }
    }
}

Write-Host ''
if ($NoBrowser) { Write-Host (T 'Open the address below in a web browser on this computer.') -ForegroundColor Green }
else { Write-Host (T 'The report is opening in your web browser.') -ForegroundColor Green }
Write-Host (T 'Choose what to fix there and click "Fix selected".')
Write-Host (T 'Keep this window open while you use the report. It closes when you click "Finish" in the report.') -ForegroundColor Yellow
if ($DryRun) { Write-Host (T 'DRY RUN: repairs started from the report will not change anything.') -ForegroundColor Magenta }
Write-Host (T 'Address (only works on this computer): {0}' $baseUrl) -ForegroundColor DarkGray
if (-not $NoBrowser) {
    # Opening through Explorer starts the browser as the signed-in user instead of as administrator.
    Start-Process -FilePath "$env:SystemRoot\explorer.exe" -ArgumentList $baseUrl
}

try {
    while (-not $script:stopRequested) {
        $pending = $listener.GetContextAsync()
        while (-not $pending.Wait(1000)) {
            $busy = $script:repair -and -not $script:repair.Process.HasExited
            if (-not $busy -and ((Get-Date) - $script:lastRequest).TotalMinutes -ge $IdleMinutes) {
                Write-Host (T 'No activity from the report for a while; closing.') -ForegroundColor DarkGray
                return
            }
        }
        $script:lastRequest = Get-Date
        try { Invoke-Request $pending.Result } catch {
            try { Send-Json $pending.Result 500 @{ Error = $_.Exception.Message } } catch { }
        }
    }
    Start-Sleep -Milliseconds 300
} finally {
    $listener.Stop()
    $listener.Close()
    Write-Host (T 'PC Toolkit has finished. This window can be closed.') -ForegroundColor Green
}
