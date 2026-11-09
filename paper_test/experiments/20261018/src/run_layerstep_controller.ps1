$ErrorActionPreference = 'Stop'
$taskBase = 'C:\Users\Cheng\Documents\FLOPA\experiment_execution_20261018'
$taskSshArgs = @('-o', 'BatchMode=yes', '-o', 'ClearAllForwardings=yes')
$taskSourceHost = 'zhangcheng@10.2.255.13'
$taskTargetHost = 'zhangcheng@10.1.33.33'
$taskRoot = '/data/workspaces/zhangcheng/flash_attention/paper_test/experiments/20261018'
$taskEmit = '/home/zhangcheng/miniconda3/envs/dfot/bin/python'
$taskEmit += ' /home/zhangcheng/DiT-FA/scripts/emit_layerstep_replays.py'
$taskJobs = @{}
$taskDone = @{}
$taskPublished = @{}
$taskStatePath = "$taskBase\layerstep_controller_state.json"
if (Test-Path -LiteralPath $taskStatePath) {
    $taskPrevious = Get-Content -LiteralPath $taskStatePath -Raw | ConvertFrom-Json
    foreach ($taskProperty in $taskPrevious.running.PSObject.Properties) {
        $taskJobs[$taskProperty.Name] = $taskProperty.Value
    }
    foreach ($taskProperty in $taskPrevious.completed.PSObject.Properties) {
        $taskDone[$taskProperty.Name] = $taskProperty.Value
    }
    foreach ($taskProperty in $taskPrevious.published.PSObject.Properties) {
        $taskPublished[$taskProperty.Name] = $taskProperty.Value
    }
}
function Read-LayerJson([string]$taskHost, [string]$taskCommand) {
    $taskText = & ssh @taskSshArgs $taskHost $taskCommand
    if ($LASTEXITCODE -ne 0) { throw 'Layerstep SSH failed' }
    return (($taskText -join "`n") | ConvertFrom-Json)
}
for ($taskRound = 0; $taskRound -lt 10080; $taskRound++) {
    $taskReady = Read-LayerJson $taskSourceHost $taskEmit
    foreach ($taskName in @($taskJobs.Keys)) {
        $taskCommand = "python3 $taskRoot/src/submit_replay.py --name $taskName --status"
        $taskStatus = Read-LayerJson $taskTargetHost $taskCommand
        if ($taskStatus.state -eq 'pass') {
            $taskDone[$taskName] = $taskStatus
            $taskJobs.Remove($taskName)
            Write-Output "COMPLETE $taskName cycles=$($taskStatus.cycles)"
        } elseif ($taskStatus.state -eq 'failed') {
            throw "Layerstep RTL replay failed: $taskName"
        }
    }
    foreach ($taskPoint in $taskReady.points) {
        if ($taskJobs.Count -ge 8) { break }
        $taskName = [string]$taskPoint.name
        if ($taskName -notmatch '^(pixart|wan)_n(1024|4096)_l[0-2][0-9]_s15$') {
            throw 'Unexpected layerstep job name'
        }
        if ($taskDone.ContainsKey($taskName) -or $taskJobs.ContainsKey($taskName)) { continue }
        $taskModelBusy = @($taskJobs.Keys | Where-Object {
            $_.StartsWith([string]$taskPoint.model + '_')
        }).Count
        if ($taskModelBusy -ge 4) { continue }
        $taskSource = [string]$taskPoint.directory
        if (!$taskSource.StartsWith('/10T/zhangcheng/flopa_evaluation_20261018/qualification/') -or
                $taskSource -notmatch '^[A-Za-z0-9_./]+$' -or $taskSource -match '/\.\.?/') {
            throw 'Unexpected layerstep source path'
        }
        & ssh @taskSshArgs $taskTargetHost "mkdir -p $taskRoot/inputs/$taskName"
        if ($LASTEXITCODE -ne 0) { throw 'Layerstep directory failed' }
        foreach ($taskFile in @('q.bin', 'k.bin', 'v.bin', 'o.bin',
                'qualification.json', 'replay_manifest.json')) {
            & scp -3 @taskSshArgs "${taskSourceHost}:$taskSource/$taskFile" `
                "${taskTargetHost}:$taskRoot/inputs/$taskName/"
            if ($LASTEXITCODE -ne 0) { throw 'Layerstep vector transfer failed' }
        }
        $taskCommand = "python3 $taskRoot/src/submit_replay.py --name $taskName"
        $taskJobs[$taskName] = Read-LayerJson $taskTargetHost $taskCommand
        Write-Output "SUBMITTED $taskName"
    }
    foreach ($taskCase in @('pixart_n1024', 'wan_n1024', 'pixart_n4096', 'wan_n4096')) {
        $taskModel, $taskNText = $taskCase -split '_n'
        $taskN = [int]$taskNText
        $taskRequired = if ($taskModel -eq 'pixart') { 28 } else { 30 }
        $taskLayerResults = @($taskDone.Keys | Where-Object { $_.StartsWith($taskCase + '_') })
        if ($taskLayerResults.Count -eq $taskRequired -and !$taskPublished[$taskCase]) {
            [long]$taskCycles = 0
            foreach ($taskName in $taskLayerResults) { $taskCycles += $taskDone[$taskName].cycles }
            $taskReport = @{
                status = 'pass_all_layers'; model = $taskModel; layers = $taskRequired
                n = $taskN; step_index = 15; branch = 'conditional'
                cycles = $taskCycles; latency_ms = $taskCycles * 1.6e-6
                scope = 'sum of actual full-head RTL jobs, one per layer; no full denoiser claim'
                jobs = $taskLayerResults
            }
            $taskSuffix = if ($taskN -eq 1024) { '' } else { "_n$taskN" }
            $taskFile = "$taskBase\layerstep_$taskModel$taskSuffix.json"
            [IO.File]::WriteAllText($taskFile, ($taskReport | ConvertTo-Json -Depth 20),
                [Text.UTF8Encoding]::new($false))
            & scp @taskSshArgs $taskFile "${taskTargetHost}:$taskRoot/results/"
            if ($LASTEXITCODE -ne 0) { throw 'Layerstep aggregate transfer failed' }
            $taskPublished[$taskCase] = $true
        }
    }
    $taskState = @{ running = $taskJobs; completed = $taskDone; published = $taskPublished }
    [IO.File]::WriteAllText("$taskBase\layerstep_controller_state.json",
        ($taskState | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
    & ssh @taskSshArgs $taskTargetHost "python3 $taskRoot/src/update_readme_checklist.py" |
        Out-Null
    if ($taskDone.Count -eq 116) { exit 0 }
    Start-Sleep -Seconds 60
}
throw 'Layerstep replay queue exceeded seven days'
