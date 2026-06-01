# Parallel match benchmark. Each OpenTTD match is single-threaded (one core),
# so we run many seeds AT ONCE across the machine's cores instead of serially.
# Reports per-seed standings and, for 1v1, an overall win-rate.
#
#   ./tools/run_bench.ps1 -Seeds 1,2,3,4,5 -Years 12
#   ./tools/run_bench.ps1 -Seeds (1..10) -Years 15 -Opponent C:\path\AI -OpponentName "AAAHogEx"
#   ./tools/run_bench.ps1 -Seeds (1..8) -Parallel 8
#
param(
    [int[]]$Seeds = @(1,2,3,4,5),
    [int]$Years = 12,
    [string]$Opponent = "",
    [string]$OpponentName = "",
    [int]$Parallel = 0,        # 0 = auto (cores - 4, capped at seed count)
    [switch]$Rebuild
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot\..").Path
$ticks = [int]((($Years + 1)) * 74 * 365)

if ($Parallel -le 0) {
    $Parallel = [Math]::Min($Seeds.Count, [Math]::Max(1, [Environment]::ProcessorCount - 4))
}

# Build image if missing.
if ($Rebuild -or [string]::IsNullOrEmpty((docker images -q mvb-ottd))) {
    Write-Host "Building mvb-ottd image..."
    docker build -t mvb-ottd -f "$repo\tools\openttd.Dockerfile" $repo | Out-Null
}

# Base config (+ opponent for 1v1).
$cfgBase = Get-Content (Join-Path $repo "tools\match\openttd.cfg") -Raw
if ($Opponent -ne "") {
    if ($OpponentName -eq "") { throw "-Opponent requires -OpponentName." }
    $cfgBase = $cfgBase -replace '(?m)^max_no_competitors = .*$', 'max_no_competitors = 2'
    $cfgBase = $cfgBase -replace '(?m)^"MvB AI" =\s*$', "`"MvB AI`" =`n`"$OpponentName`" ="
}

$work = Join-Path $env:TEMP ("mvb_bench_" + [Guid]::NewGuid().ToString("N").Substring(0,8))
New-Item -ItemType Directory -Force -Path $work | Out-Null

# One self-contained job per seed: writes its own cfg, runs its own container,
# captures stderr (the -d script log) to its own file.
$jobScript = {
    param($seed, $repo, $cfgBase, $ticks, $work, $opponent)
    $cfg = Join-Path $work "cfg_$seed.cfg"
    [System.IO.File]::WriteAllText($cfg, ($cfgBase -replace "`r`n","`n"))
    $name = "mvb_bench_$seed"
    $mounts = @(
        "-v","${repo}\info.nut:/opt/openttd/ai/MvB_AI/info.nut:ro",
        "-v","${repo}\main.nut:/opt/openttd/ai/MvB_AI/main.nut:ro",
        "-v","${repo}\src:/opt/openttd/ai/MvB_AI/src:ro",
        "-v","${repo}\tools\match\game\MvBObserver:/opt/openttd/game/MvBObserver:ro",
        "-v","${cfg}:/cfg/openttd.cfg:ro"
    )
    if ($opponent -ne "") { $mounts += @("-v","${opponent}:/opt/openttd/ai/Opponent:ro") }
    $run = "cp /cfg/openttd.cfg /tmp/o.cfg && cd /opt/openttd && ./openttd -v null:ticks=$ticks -s null -m null -d script=3 -g -G $seed -c /tmp/o.cfg 2>&1"
    $log = & docker run --rm --name $name @mounts mvb-ottd sh -c $run
    Set-Content -Path (Join-Path $work "log_$seed.txt") -Value $log -Encoding utf8
}

Write-Host "Running $($Seeds.Count) match(es), $Years game-years each, $Parallel in parallel..."
$jobs = @()
foreach ($s in $Seeds) {
    while (@(Get-Job -State Running).Count -ge $Parallel) { Start-Sleep -Milliseconds 500 }
    $jobs += Start-Job -ScriptBlock $jobScript -ArgumentList $s,$repo,$cfgBase,$ticks,$work,$Opponent
}
Wait-Job -Job $jobs | Out-Null
Receive-Job -Job $jobs | Out-Null
Remove-Job -Job $jobs

# Parse each seed's log: last [OBSERVE] reading per company.
$wins = 0; $decided = 0
foreach ($s in $Seeds) {
    $logFile = Join-Path $work "log_$s.txt"
    if (-not (Test-Path $logFile)) { Write-Host "seed ${s}: NO LOG"; continue }
    $byCo = @{}
    foreach ($line in (Get-Content $logFile)) {
        if ($line -match '\[OBSERVE\] year=(\d+) company=(\d+) value=(-?\d+) cash=(-?\d+) name=(.*)$') {
            $byCo[$Matches[2]] = [pscustomobject]@{ Value=[long]$Matches[3]; Cash=[long]$Matches[4]; Name=$Matches[5].Trim() }
        }
    }
    if ($byCo.Count -eq 0) { Write-Host "seed ${s}: no standings (build/parse fail)"; continue }
    $rank = $byCo.Values | Sort-Object Value -Descending
    $mvb = $rank | Where-Object { $_.Name -like "MvB*" } | Select-Object -First 1
    $place = if ($mvb) { ([array]::IndexOf(@($rank), $mvb)) + 1 } else { 0 }
    $summary = ($rank | ForEach-Object { "{0}={1:N0}" -f $_.Name, $_.Value }) -join "  "
    if ($Opponent -ne "") {
        $decided++
        if ($place -eq 1) { $wins++ ; $tag = "WIN" } else { $tag = "LOSS(#$place)" }
        Write-Host ("seed {0,-3} {1,-10} | {2}" -f $s, $tag, $summary)
    } else {
        Write-Host ("seed {0,-3} value={1,12:N0} | {2}" -f $s, $(if($mvb){$mvb.Value}else{0}), $summary)
    }
}

if ($Opponent -ne "" -and $decided -gt 0) {
    Write-Host ""
    Write-Host ("WIN-RATE vs {0}: {1}/{2} = {3:P0}" -f $OpponentName, $wins, $decided, ($wins / $decided))
}
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
