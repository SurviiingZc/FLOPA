$ErrorActionPreference = 'Stop'
$taskBase = 'C:\Users\Cheng\Documents\FLOPA\experiment_execution_20261018'
$taskSshArgs = @('-o', 'BatchMode=yes', '-o', 'ClearAllForwardings=yes')
$taskSourceHost = 'zhangcheng@10.2.255.13'
$taskTargetHost = 'zhangcheng@10.1.33.33'
$taskRemoteRoot = '/data/workspaces/zhangcheng/flash_attention/paper_test/experiments/20261018'
$taskPython = '/home/zhangcheng/miniconda3/envs/dfot/bin/python'
$taskEmit = '/home/zhangcheng/DiT-FA/scripts/emit_ready_replays.py'
$taskJobs = @{}
$taskDone = @{}

function Read-RemoteJson([string]$taskHost, [string]$taskCommand) {
    $taskText = & ssh @taskSshArgs $taskHost $taskCommand
    if ($LASTEXITCODE -ne 0) {
        throw "SSH failed: $taskHost"
    }
    return (($taskText -join "`n") | ConvertFrom-Json)
}

for ($taskRound = 0; $taskRound -lt 10080; $taskRound++) {
    try {
        $taskReady = Read-RemoteJson $taskSourceHost "$taskPython $taskEmit"
        foreach ($taskName in @($taskJobs.Keys)) {
            $taskCommand = "python3 $taskRemoteRoot/src/submit_replay.py"
            $taskCommand += " --name $taskName --status"
            $taskStatus = Read-RemoteJson $taskTargetHost $taskCommand
            if ($taskStatus.state -eq 'pass') {
                $taskDone[$taskName] = $taskStatus
                $taskJobs.Remove($taskName)
                Write-Output "COMPLETE $taskName cycles=$($taskStatus.cycles)"
            } elseif ($taskStatus.state -eq 'failed') {
                throw "RTL replay failed: $taskName; inspect remote job logs"
            }
        }
        foreach ($taskModel in @('pixart', 'wan')) {
            $taskModelBusy = @($taskJobs.Keys | Where-Object {
                $_.StartsWith($taskModel + '_n')
            }).Count -gt 0
            if ($taskModelBusy -or $taskReady.failed_models -contains $taskModel) {
                continue
            }
            $taskPoints = @($taskReady.points | Where-Object {
                $_.model -eq $taskModel
            } | Sort-Object { [int]$_.manifest.nq })
            foreach ($taskPoint in $taskPoints) {
                $taskN = [int]$taskPoint.manifest.nq
                if ($taskN -notin @(1024, 2304, 4096, 9216, 16384)) {
                    throw 'Unexpected native replay length'
                }
                $taskName = $taskModel + '_n' + $taskN
                if ($taskDone.ContainsKey($taskName)) {
                    continue
                }
                $taskSource = [string]$taskPoint.directory
                $taskPrefix = '/10T/zhangcheng/flopa_evaluation_20261018/qualification/'
                if (!$taskSource.StartsWith($taskPrefix) -or
                        $taskSource -notmatch '^[A-Za-z0-9_./]+$' -or
                        $taskSource -match '/\.\.?/') {
                    throw 'Unexpected qualified input path'
                }
                $taskTarget = "$taskRemoteRoot/inputs/$taskName"
                & ssh @taskSshArgs $taskTargetHost "mkdir -p $taskTarget"
                if ($LASTEXITCODE -ne 0) {
                    throw 'Cannot create replay input directory'
                }
                foreach ($taskFile in @('q.bin', 'k.bin', 'v.bin', 'o.bin',
                        'replay_manifest.json', 'qualification.json')) {
                    $taskFrom = "${taskSourceHost}:$taskSource/$taskFile"
                    $taskTo = "${taskTargetHost}:$taskTarget/"
                    & scp -3 @taskSshArgs $taskFrom $taskTo
                    if ($LASTEXITCODE -ne 0) {
                        throw "Input transfer failed: $taskFile"
                    }
                }
                $taskCommand = "python3 $taskRemoteRoot/src/submit_replay.py --name $taskName"
                $taskSubmitted = Read-RemoteJson $taskTargetHost $taskCommand
                $taskJobs[$taskName] = $taskSubmitted
                Write-Output "SUBMITTED $taskName"
                break
            }
        }
        $taskState = @{
            updated = (Get-Date).ToString('o')
            running = $taskJobs
            completed = $taskDone
            numerical_failures = $taskReady.failed_models
            scope = 'one-shot experiment process queue; no scheduled task'
        }
        $taskState | ConvertTo-Json -Depth 20 | Set-Content -Encoding UTF8 `
            -LiteralPath "$taskBase\replay_controller_state.json"
        $taskFinishedModels = @($taskReady.failed_models).Count
        foreach ($taskModel in @('pixart', 'wan')) {
            $taskCount = @($taskDone.Keys | Where-Object {
                $_.StartsWith($taskModel + '_n')
            }).Count
            if ($taskCount -eq 5) {
                $taskFinishedModels++
            }
        }
        if ($taskFinishedModels -eq 2 -and $taskJobs.Count -eq 0) {
            Write-Output 'REPLAY_CONTROLLER_FINISHED'
            exit 0
        }
    } catch {
        Write-Output ((Get-Date).ToString('o') + ' ' + $_.Exception.Message)
        if ($_.Exception.Message.StartsWith('RTL replay failed')) {
            exit 2
        }
    }
    Start-Sleep -Seconds 60
}
throw 'Replay queue reached the seven-day limit'
