<#
.SYNOPSIS
    Self-test for PC Toolkit that does not require administrator permissions.

.DESCRIPTION
    Verifies that the scripts parse, that every text has a Swedish translation for the Sparkollen
    theme, runs a diagnosis without elevation in both themes, validates the JSON and HTML
    reports, performs a Repair.ps1 dry run (-WhatIf -AutomaticOnly), tests the
    local fix page (ReportServer.ps1 -DryRun), and checks that repairs are refused when a
    report indicates a failing drive.
    No system changes are made. Test reports are removed afterwards unless -KeepReports is used.

.PARAMETER KeepReports
    Keep the generated report folders for manual inspection.

.PARAMETER ReuseReport
    Use the latest existing report instead of running a new diagnosis (faster).

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-Toolkit.ps1 -KeepReports
#>
[CmdletBinding()]
param(
    [switch]$KeepReports,
    [switch]$ReuseReport
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$reportsRoot = Join-Path (Split-Path -Parent $root) 'Reports'
$powershell = Join-Path $PSHOME 'powershell.exe'
if (-not (Test-Path -LiteralPath $powershell)) { $powershell = 'powershell.exe' }
$results = New-Object System.Collections.Generic.List[object]
$createdFolders = New-Object System.Collections.Generic.List[string]
$existingFolders = @(Get-ChildItem -LiteralPath $reportsRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object FullName)

function Add-Result([string]$Name, [bool]$Passed, [string]$Details = '') {
    $results.Add([pscustomobject]@{ Test = $Name; Passed = $Passed; Details = $Details })
    $status = if ($Passed) { 'PASS' } else { 'FAIL' }
    Write-Host ("  [{0}] {1}" -f $status, $Name) -ForegroundColor $(if ($Passed) { 'Green' } else { 'Red' }) -NoNewline
    if ($Details) { Write-Host " - $Details" -ForegroundColor DarkGray } else { Write-Host '' }
}
function Invoke-ToolkitScript([string]$Script, [string[]]$Arguments) {
    $output = & $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root $Script) @Arguments 2>&1 | Out-String
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}

Write-Host "`nPC Toolkit self-test (no administrator permissions needed)`n" -ForegroundColor Cyan

Write-Host 'Syntax'
$langRoot = Join-Path $root 'lang\sv'
foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter '*.ps1') + @(Get-ChildItem -LiteralPath $langRoot -Filter '*.psd1')) {
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $nonAscii = @($bytes | Where-Object { $_ -gt 127 }).Count -gt 0
    $details = @()
    if ($errors.Count) { $details += "$($errors.Count) parse error(s), first on line $($errors[0].Extent.StartLineNumber): $($errors[0].Message)" }
    if ($nonAscii -and -not $hasBom) { $details += 'contains non-ASCII characters but has no UTF-8 BOM' }
    Add-Result "Parse $($file.Name)" (-not $details.Count) ($details -join '; ')
}
foreach ($launcher in Get-ChildItem -LiteralPath (Split-Path -Parent $root) -Filter '*.cmd') {
    $targets = @([regex]::Matches((Get-Content -LiteralPath $launcher.FullName -Raw), '%~dp0([^"]+\.ps1)') | ForEach-Object { $_.Groups[1].Value })
    $missing = @($targets | Where-Object { -not (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $root) $_)) })
    Add-Result "Launcher $($launcher.Name)" ($targets.Count -and -not $missing.Count) $(if ($missing.Count) { "missing: $($missing -join ', ')" } else { $targets -join ', ' })
}
$themeFiles = @('report-fix.js', 'themes\sparkollen.css', 'themes\sparkollen-symbols.svg')
$missingThemeFiles = @($themeFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $root $_)) })
Add-Result 'Report and theme files exist' (-not $missingThemeFiles.Count) ($missingThemeFiles -join ', ')

Write-Host "`nTranslations (Sparkollen theme)"
# Keys are the English texts. Every T '...' in the scripts and every t('...') in the fix panel must have a Swedish
# text with the same {n} placeholders, and the same key must not be translated differently in two files.
function Get-PlaceholderSet([string]$Text) { (@([regex]::Matches($Text, '\{(\d+)[^}]*\}') | ForEach-Object { $_.Groups[1].Value }) | Sort-Object -Unique) -join ',' }
$tables = @{}
foreach ($file in Get-ChildItem -LiteralPath $langRoot -Filter '*.psd1') { $tables[$file.BaseName] = Import-PowerShellDataFile -LiteralPath $file.FullName }
$merged = @{}; $conflicts = @(); $placeholderErrors = @()
foreach ($name in $tables.Keys) {
    foreach ($key in $tables[$name].Keys) {
        $value = $tables[$name][$key]
        if ($merged.ContainsKey($key) -and $merged[$key] -cne $value) { $conflicts += "'$key' ($name)" }
        $merged[$key] = $value
        if ((Get-PlaceholderSet $key) -ne (Get-PlaceholderSet $value)) { $placeholderErrors += "'$key' ($name)" }
    }
}
Add-Result 'Swedish texts are consistent between files' (-not $conflicts.Count) ($conflicts -join '; ')
Add-Result 'Swedish texts keep the {n} placeholders' (-not $placeholderErrors.Count) ($placeholderErrors -join '; ')
$usedKeys = New-Object System.Collections.Generic.HashSet[string]
foreach ($file in Get-ChildItem -LiteralPath $root -Filter '*.ps1' | Where-Object Name -ne 'Test-Toolkit.ps1') {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
    $calls = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'T' }, $true)
    foreach ($call in $calls) {
        $argument = $call.CommandElements[1]
        if ($argument -is [System.Management.Automation.Language.StringConstantExpressionAst]) { [void]$usedKeys.Add($argument.Value) }
    }
}
$untranslated = @($usedKeys | Where-Object { -not $merged.ContainsKey($_) } | Sort-Object)
Add-Result 'All script texts have a Swedish translation' (-not $untranslated.Count) "$($usedKeys.Count) text(s)$(if ($untranslated.Count) { '; missing: ' + ($untranslated -join ' | ') })"
$fixScript = [System.IO.File]::ReadAllText((Join-Path $root 'report-fix.js'))
$fixKeys = @([regex]::Matches($fixScript, "\bt\('((?:[^'\\]|\\.)*)'") | ForEach-Object { $_.Groups[1].Value.Replace('\"', '"') } | Sort-Object -Unique)
$fixTable = if ($tables.ContainsKey('Fix')) { $tables['Fix'] } else { @{} }
$untranslatedFix = @($fixKeys | Where-Object { -not $fixTable.ContainsKey($_) -or $_ -match '\\' })
Add-Result 'All fix panel texts are in lang\sv\Fix.psd1' (-not $untranslatedFix.Count) "$($fixKeys.Count) text(s)$(if ($untranslatedFix.Count) { '; missing: ' + ($untranslatedFix -join ' | ') })"

Write-Host "`nDiagnosis"
$reportPath = $null
if ($ReuseReport) {
    $reportPath = Get-ChildItem -LiteralPath $reportsRoot -Filter 'diagnostic-report.json' -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $reportPath) {
    Write-Host '  Running Diagnose.ps1 -NoElevation -Quiet -SkipUpdateCheck (a few minutes)...' -ForegroundColor DarkGray
    $started = Get-Date
    $run = Invoke-ToolkitScript 'Diagnose.ps1' @('-NoElevation', '-Quiet', '-SkipUpdateCheck')
    $reportPath = Get-ChildItem -LiteralPath $reportsRoot -Filter 'diagnostic-report.json' -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $started.AddSeconds(-5) } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    Add-Result 'Diagnose.ps1 produced a JSON report' ([bool]$reportPath) "$([math]::Round(((Get-Date) - $started).TotalSeconds)) s"
    if (-not $reportPath) { Write-Host $run.Output -ForegroundColor DarkGray }
}

if ($reportPath) {
    $data = $null
    try { $data = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    Add-Result 'JSON report is valid' ($null -ne $data)
    if ($data) {
        $expected = 'System', 'Drives', 'Volumes', 'Memory', 'Startup', 'Programs', 'Security', 'Settings', 'Cleanable', 'Errors', 'Meta', 'Findings'
        $missing = @($expected | Where-Object { $data.PSObject.Properties.Name -notcontains $_ })
        Add-Result 'JSON report has all expected sections' (-not $missing.Count) $(if ($missing.Count) { "missing: $($missing -join ', ')" })
        $badFindings = @($data.Findings | Where-Object { -not $_.Id -or $_.Severity -notin 'Critical', 'Warning', 'Info', 'OK' -or -not $_.Title })
        Add-Result 'Findings have Id, Severity and Title' (-not $badFindings.Count) "$(@($data.Findings).Count) finding(s)"
        Add-Result 'Drive check completed' ([bool]$data.Drives.CheckCompleted) $(if (-not $data.Drives.CheckCompleted) { 'Repair.ps1 will refuse to run without -IgnoreDriveWarning' })
        $scriptErrors = @($data.Meta.ScriptErrors | Where-Object { $_ })
        Add-Result 'All checks ran without script errors' (-not $scriptErrors.Count) ($scriptErrors -join ' | ')
    }
    $htmlPath = Join-Path (Split-Path -Parent $reportPath) 'diagnostic-report.html'
    $html = if (Test-Path -LiteralPath $htmlPath) { Get-Content -LiteralPath $htmlPath -Raw -Encoding UTF8 } else { '' }
    Add-Result 'HTML report is complete' ($html -match '<section id="findings">' -and $html -match 'id="pctk-data"' -and $html -match '</html>\s*$') "$([math]::Round($html.Length / 1KB)) KB"
    if ($data) {
        $missingTexts = @($data.Meta.MissingTranslations | Where-Object { $_ })
        Add-Result 'Report uses the Sparkollen theme by default' ($data.Meta.Theme -eq 'Sparkollen' -and $html -match '<body class="sparkollen">' -and $html -match '<html lang="sv"') "theme: $($data.Meta.Theme)"
        Add-Result 'Report has no untranslated texts' (-not $missingTexts.Count) ($missingTexts -join ' | ')
        $phases = @('A', 'B', 'C' | Where-Object { $null -ne $data.Meta.Score.Phases.$_.Points })
        Add-Result 'Judge''s protocol has a score' ($data.Meta.Score.Total -ge 0 -and $data.Meta.Score.Total -le 300 -and $phases.Count -eq 3 -and $data.Meta.Score.Grade) "$($data.Meta.Score.Total) of 300, $($data.Meta.Score.Grade)"
    }
}

if (-not $ReuseReport) {
    Write-Host '  Running Diagnose.ps1 -Theme Neutral (a few minutes)...' -ForegroundColor DarkGray
    $started = Get-Date
    $run = Invoke-ToolkitScript 'Diagnose.ps1' @('-NoElevation', '-Quiet', '-SkipUpdateCheck', '-Theme', 'Neutral')
    $neutralPath = Get-ChildItem -LiteralPath $reportsRoot -Filter 'diagnostic-report.json' -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $started.AddSeconds(-5) } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    $neutralHtml = if ($neutralPath) { Get-Content -LiteralPath (Join-Path (Split-Path -Parent $neutralPath) 'diagnostic-report.html') -Raw -Encoding UTF8 } else { '' }
    Add-Result 'Neutral theme gives a plain English report' ($neutralHtml -match '<html lang="en"' -and $neutralHtml -match '<title>PC Toolkit report - ' -and $neutralHtml -notmatch 'class="sparkollen"' -and $run.Output -match 'Summary of findings') "$([math]::Round(((Get-Date) - $started).TotalSeconds)) s"
}

Write-Host "`nRepair dry run"
if ($reportPath -and $data -and $data.Drives.CheckCompleted -and -not $data.Drives.DriveProblem) {
    $run = Invoke-ToolkitScript 'Repair.ps1' @('-WhatIf', '-AutomaticOnly', '-NoElevation', '-Theme', 'Neutral', '-ReportPath', $reportPath)
    $whatIfLines = @($run.Output -split "`r?`n" | Where-Object { $_ -match '^What if:' })
    $doneLines = @($run.Output -split "`r?`n" | Where-Object { $_ -match '\[done\]' })
    Add-Result 'Repair.ps1 -WhatIf lists planned actions' ($whatIfLines.Count -gt 0) "$($whatIfLines.Count) planned action(s)"
    Add-Result 'Repair.ps1 -WhatIf changed nothing' (-not $doneLines.Count) ($doneLines -join ' | ')
    Add-Result 'Repair.ps1 -WhatIf finished without errors' ($run.Output -notmatch '(?m)^\s*(Exception|.*: The term .* is not recognized)') ''
    $whatIfLines | ForEach-Object { Write-Host "         $_" -ForegroundColor DarkGray }
} else {
    Add-Result 'Repair.ps1 -WhatIf dry run' $false 'skipped because no usable report with a completed, healthy drive check exists'
}

function Start-TestServer([string]$Folder) {
    $probe = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, 0)
    $probe.Start(); $port = $probe.LocalEndpoint.Port; $probe.Stop()
    $token = [guid]::NewGuid().ToString('N')
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $root 'ReportServer.ps1')`" -ReportFolder `"$Folder`" -DryRun -NoBrowser -Port $port -Token $token -IdleMinutes 5"
    $process = Start-Process -FilePath $powershell -ArgumentList $arguments -WindowStyle Hidden -PassThru
    $server = [pscustomobject]@{ Process = $process; Token = $token; Base = "http://127.0.0.1:$port/$token/"; Port = $port }
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 500
        if ((Invoke-Server GET "$($server.Base)status").Status -eq 200) { break }
    }
    $server
}
function Invoke-Server([string]$Method, [string]$Url, $Body = $null, [hashtable]$Headers = @{}) {
    try {
        $params = @{ UseBasicParsing = $true; Method = $Method; Uri = $Url; Headers = $Headers; TimeoutSec = 10 }
        if ($null -ne $Body) { $params.Body = ($Body | ConvertTo-Json -Compress); $params.ContentType = 'application/json' }
        $response = Invoke-WebRequest @params
        [pscustomobject]@{ Status = [int]$response.StatusCode; Content = $response.Content }
    } catch [System.Net.WebException] {
        $response = $_.Exception.Response
        if ($response) {
            [pscustomobject]@{ Status = [int]$response.StatusCode; Content = (New-Object System.IO.StreamReader($response.GetResponseStream())).ReadToEnd() }
        } else { [pscustomobject]@{ Status = 0; Content = $_.Exception.Message } }
    }
}
function Stop-TestServer($Server) {
    if ($Server.Process.HasExited) { return $true }
    [void](Invoke-Server POST "$($Server.Base)shutdown" @{} @{ 'X-PCTK-Token' = $Server.Token })
    $exited = $Server.Process.WaitForExit(10000)
    if (-not $exited) { Stop-Process -Id $Server.Process.Id -Force -ErrorAction SilentlyContinue }
    $exited
}
[System.Net.WebRequest]::DefaultWebProxy = $null

Write-Host "`nFix page (local report server, dry run)"
if ($reportPath -and $data -and $data.Drives.CheckCompleted -and -not $data.Drives.DriveProblem) {
    $server = Start-TestServer (Split-Path -Parent $reportPath)
    $auth = @{ 'X-PCTK-Token' = $server.Token }
    try {
        $page = Invoke-Server GET $server.Base
        Add-Result 'Server shows the report with the fix panel' ($page.Status -eq 200 -and $page.Content -match 'window\.PCTK=' -and $page.Content -match 'id="fix-panel"') "HTTP $($page.Status)"
        $wrong = Invoke-Server GET "http://127.0.0.1:$($server.Port)/$([guid]::NewGuid().ToString('N'))/"
        $upper = Invoke-Server GET ($server.Base.Replace($server.Token, $server.Token.ToUpperInvariant()))
        Add-Result 'Server rejects a wrong secret' ($wrong.Status -eq 404 -and $upper.Status -eq 404) "HTTP $($wrong.Status) / $($upper.Status)"
        $noHeader = Invoke-Server POST "$($server.Base)repair" @{ Options = @('cleanup') }
        Add-Result 'Server rejects changes without the secret header' ($noHeader.Status -eq 403) "HTTP $($noHeader.Status)"
        $invalid = Invoke-Server POST "$($server.Base)repair" @{ Options = @('not-a-real-option') } $auth
        Add-Result 'Server rejects unknown repair options' ($invalid.Status -eq 400) "HTTP $($invalid.Status)"

        $match = [regex]::Match($page.Content, '<script type="application/json" id="pctk-data">(.*?)</script>')
        $options = @(($match.Groups[1].Value | ConvertFrom-Json).options)
        $chosen = @($options | Where-Object Default | ForEach-Object Id)
        if (-not $chosen.Count) { $chosen = @($options | Select-Object -First 1 | ForEach-Object Id) }
        $start = Invoke-Server POST "$($server.Base)repair" @{ Options = $chosen } $auth
        Add-Result 'Server starts the selected repairs' ($start.Status -eq 202) "HTTP $($start.Status), $($chosen.Count) option(s)"
        $status = $null
        for ($i = 0; $i -lt 90 -and $start.Status -eq 202; $i++) {
            Start-Sleep -Seconds 2
            $status = (Invoke-Server GET "$($server.Base)status").Content | ConvertFrom-Json
            if ($status.State -eq 'done') { break }
        }
        $planned = @($status.Result.Planned | Where-Object { $_ })
        Add-Result 'Repairs from the fix page finish as a dry run' ($status.State -eq 'done' -and $status.Result.DryRun -and -not @($status.Result.Completed).Count -and $planned.Count) "$($planned.Count) simulated action(s)"
    } finally {
        Add-Result 'Finish closes the server' (Stop-TestServer $server) ''
    }
} else {
    Add-Result 'Fix page tests' $false 'skipped because no usable report with a completed, healthy drive check exists'
}

Write-Host "`nDrive safety stop"
$fakeFolder = Join-Path $reportsRoot ('_selftest_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $fakeFolder -Force | Out-Null
$createdFolders.Add($fakeFolder)
$fakeReport = [ordered]@{
    Drives = @{ DriveProblem = $true; CheckCompleted = $true; Physical = @(); LogEvents = @() }
    Volumes = @(); Security = @{ DefenderActive = $true }; Cleanable = @{}; System = @{}
    Meta = @{ Date = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Version = 'selftest' }
    Findings = @(@{ Id = 'DRIVE_FAILING'; Severity = 'Critical'; Title = 'Self-test: simulated failing drive'; Details = 'Simulated by Test-Toolkit.ps1'; Action = 'Manual' })
}
$fakeReportPath = Join-Path $fakeFolder 'diagnostic-report.json'
$fakeReport | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $fakeReportPath -Encoding UTF8
$run = Invoke-ToolkitScript 'Repair.ps1' @('-WhatIf', '-AutomaticOnly', '-NoElevation', '-Theme', 'Neutral', '-ReportPath', $fakeReportPath)
Add-Result 'Repair.ps1 stops on a failing drive' ($run.Output -match 'DRIVE MAY BE FAILING' -and $run.Output -notmatch 'What if:') ''
$run = Invoke-ToolkitScript 'Repair.ps1' @('-WhatIf', '-AutomaticOnly', '-NoElevation', '-Theme', 'Sparkollen', '-ReportPath', $fakeReportPath)
Add-Result 'Repair.ps1 stops on a failing drive (Sparkollen theme)' ($run.Output -match 'EN DISK KAN' -and $run.Output -notmatch 'What if:') ''
$server = Start-TestServer $fakeFolder
try {
    $blocked = Invoke-Server POST "$($server.Base)repair" @{ Options = @('cleanup') } @{ 'X-PCTK-Token' = $server.Token }
    Add-Result 'Fix page refuses repairs on a failing drive' ($blocked.Status -eq 409) "HTTP $($blocked.Status)"
} finally { [void](Stop-TestServer $server) }

if (-not $KeepReports) {
    Get-ChildItem -LiteralPath $reportsRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $existingFolders -notcontains $_.FullName } |
        ForEach-Object { $createdFolders.Add($_.FullName) }
}
foreach ($folder in ($createdFolders | Select-Object -Unique)) {
    Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
}
if (-not (Get-ChildItem -LiteralPath $reportsRoot -Force -ErrorAction SilentlyContinue)) {
    Remove-Item -LiteralPath $reportsRoot -Force -ErrorAction SilentlyContinue
}

$failed = @($results | Where-Object { -not $_.Passed })
Write-Host ''
if ($failed.Count) {
    Write-Host "$($failed.Count) of $($results.Count) tests FAILED." -ForegroundColor Red
} else {
    Write-Host "All $($results.Count) tests passed." -ForegroundColor Green
}
if ($KeepReports -and $reportPath) { Write-Host "Report kept: $(Split-Path -Parent $reportPath)" }
exit $failed.Count
