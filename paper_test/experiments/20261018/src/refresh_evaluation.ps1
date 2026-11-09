$ErrorActionPreference = 'Stop'
$taskBase = 'C:\Users\Cheng\Documents\FLOPA\experiment_execution_20261018'
$taskWork = "$taskBase\workbook_update_20261019"
$taskSsh = @('-o', 'BatchMode=yes', '-o', 'ClearAllForwardings=yes')
$taskRoot = '/data/workspaces/zhangcheng/flash_attention/paper_test/experiments/20261018'
$taskNode = 'C:\Users\Cheng\.cache\codex-runtimes\codex-primary-runtime\dependencies\node'
$taskNode += '\bin\node.exe'
$taskTarget = [IO.Path]::Combine('C:\Users\Cheng\Desktop',
    ([char]0x9879).ToString() + [char]0x76EE,
    ([char]0x6269).ToString() + [char]0x6563 + [char]0x6A21 + [char]0x578B,
    'flash_attention\ISCAS2027\paper\evaluation_data.xlsx')
$taskSource = & ssh @taskSsh 'zhangcheng@10.1.33.33' `
    "python3 $taskRoot/src/collect_publication_data.py"
if ($LASTEXITCODE -ne 0) { throw 'Publication data audit failed' }
$taskSourceObject = ($taskSource -join "`n") | ConvertFrom-Json
$taskSourceObject.PSObject.Properties.Remove('collected_utc')
$taskDiagnosticCommand = '/home/zhangcheng/miniconda3/envs/dfot/bin/python '
$taskDiagnosticCommand += '/home/zhangcheng/DiT-FA/scripts/emit_publication_diagnostics.py'
$taskDiagnostics = & ssh @taskSsh 'zhangcheng@10.2.255.13' $taskDiagnosticCommand
if ($LASTEXITCODE -ne 0) { throw 'Publication numerical diagnostic export failed' }
$taskFingerprintData = @{
    data = $taskSourceObject
    diagnostics = (($taskDiagnostics -join "`n") | ConvertFrom-Json)
} | ConvertTo-Json -Depth 60 -Compress
$taskHasher = [Security.Cryptography.SHA256]::Create()
$taskDigest = [BitConverter]::ToString($taskHasher.ComputeHash(
    [Text.Encoding]::UTF8.GetBytes($taskFingerprintData))).Replace('-', '')
$taskFingerprintFile = "$taskWork\published_fingerprint.txt"
if ((Test-Path -LiteralPath $taskFingerprintFile) -and
        [IO.File]::ReadAllText($taskFingerprintFile).Trim() -eq $taskDigest) { return }
[IO.File]::WriteAllText("$taskWork\publication_data.json", ($taskSource -join "`n"),
    [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText("$taskWork\diagnostics.json", ($taskDiagnostics -join "`n"),
    [Text.UTF8Encoding]::new($false))
$taskStarted = [DateTime]::UtcNow
$taskMessages = & $taskNode "$taskWork\update_evaluation.mjs" --stage-only
$taskMessages | Set-Content -Encoding UTF8 -LiteralPath "$taskWork\last_refresh.log"
$taskStaged = "$taskWork\outputs\flopa_20261019\evaluation_data.xlsx"
if (!(Test-Path -LiteralPath $taskStaged) -or
        (Get-Item -LiteralPath $taskStaged).LastWriteTimeUtc -lt $taskStarted -or
        !(($taskMessages -join "`n").Contains('"stagedOnly":true'))) {
    throw 'Workbook export did not produce a verified staged file'
}
try {
    Copy-Item -LiteralPath $taskStaged -Destination $taskTarget -ErrorAction Stop
} catch {
    $taskTransfer = "$taskWork\publication_transfer.xlsx"
    Copy-Item -LiteralPath $taskStaged -Destination $taskTransfer
    & 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -NoProfile `
        -ExecutionPolicy Bypass -File "$taskWork\publish_open_workbook.ps1" `
        -TargetPath $taskTarget -SourcePath $taskTransfer
    if ($LASTEXITCODE -ne 0) { throw 'Workbook is occupied; publication will retry later' }
}
[IO.File]::WriteAllText($taskFingerprintFile, $taskDigest)
Write-Output 'EVALUATION_WORKBOOK_UPDATED'
