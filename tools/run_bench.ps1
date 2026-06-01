# Parallel match benchmark. Each OpenTTD match is single-threaded (one core),
# so we run many matches AT ONCE across the machine's cores instead of serially.
# Reports per-seed standings and, for 1v1, an overall win-rate.
#
# Map size matters: a strategy that wins on 256x256 can choke on 1024x1024
# (longer hauls, sparser industries) or on 128x128 (cramped, contested space).
# -MapSizes runs the whole seed sweep at each size (log2 of the dimension:
# 7=128, 8=256, 9=512, 10=1024) so we measure robustness across map scale.
#
#   ./tools/run_bench.ps1 -Seeds 1,2,3,4,5 -Years 12
#   ./tools/run_bench.ps1 -Seeds 1,2,3 -MapSizes 8,9,10
#   ./tools/run_bench.ps1 -Seeds (1..10) -Years 15 -Opponent C:\path\AI -OpponentName "AAAHogEx"
#   ./tools/run_bench.ps1 -Seeds (1..8) -Parallel 8
#
param(
    [int[]]$Seeds = @(1,2,3,4,5),
    [int]$Years = 12,
    [int[]]$MapSizes = @(8),    # log2 of map dimension: 7=128 8=256 9=512 10=1024
    [string]$Opponent = "",
    [string]$OpponentName = "",
    [int]$Parallel = 0,        # 0 = auto (cores - 4, capped at job count)
    [switch]$Rebuild
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot\..").Path
$ticks = [int]((($Years + 1)) * 74 * 365)

# All (size, seed) jobs we will run.
$jobsToRun = @()
foreach ($m in $MapSizes) { foreach ($s in $Seeds) { $jobsToRun += [pscustomobject]@{ Size=$m; Seed=$s } } }

if ($Parallel -le 0) {
    $Parallel = [Math]::Min($jobsToRun.Count, [Math]::Max(1, [Environment]::ProcessorCount - 4))
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

# One self-contained job per (size, seed): writes its own cfg (with the map
# dimension patched in), runs its own container, captures the -d script log.
$jobScript = {
    param($size, $seed, $repo, $cfgBase, $ticks, $work, $opponent)
    $cfgText = $cfgBase -replace '(?m)^map_x = .*$', "map_x = $size"
    $cfgText = $cfgText -replace '(?m)^map_y = .*$', "map_y = $size"
    $cfg = Join-Path $work "cfg_${size}_$seed.cfg"
    [System.IO.File]::WriteAllText($cfg, ($cfgText -replace "`r`n","`n"))
    $name = "mvb_bench_${size}_$seed"
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
    Set-Content -Path (Join-Path $work "log_${size}_$seed.txt") -Value $log -Encoding utf8
}

$dims = ($MapSizes | ForEach-Object { "$([Math]::Pow(2,$_))x$([Math]::Pow(2,$_))" }) -join ", "
Write-Host "Running $($jobsToRun.Count) match(es) [$($Seeds.Count) seed(s) x $($MapSizes.Count) size(s): $dims], $Years game-years each, $Parallel in parallel..."
$jobs = @()
foreach ($j in $jobsToRun) {
    while (@(Get-Job -State Running).Count -ge $Parallel) { Start-Sleep -Milliseconds 500 }
    $jobs += Start-Job -ScriptBlock $jobScript -ArgumentList $j.Size,$j.Seed,$repo,$cfgBase,$ticks,$work,$Opponent
}
Wait-Job -Job $jobs | Out-Null
Receive-Job -Job $jobs | Out-Null
Remove-Job -Job $jobs

# Parse + report, grouped by map size.
$grandWins = 0; $grandDecided = 0
$soloAll = @()
foreach ($m in $MapSizes) {
    $dim = [int][Math]::Pow(2,$m)
    Write-Host ""
    Write-Host ("==== map ${dim}x${dim} (2^$m) ====")
    $wins = 0; $decided = 0; $values = @()
    foreach ($s in $Seeds) {
        $logFile = Join-Path $work "log_${m}_$s.txt"
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
            $decided++; $grandDecided++
            if ($place -eq 1) { $wins++; $grandWins++; $tag = "WIN" } else { $tag = "LOSS(#$place)" }
            Write-Host ("seed {0,-3} {1,-10} | {2}" -f $s, $tag, $summary)
        } else {
            if ($mvb) { $values += $mvb.Value; $soloAll += $mvb.Value }
            Write-Host ("seed {0,-3} value={1,12:N0} | {2}" -f $s, $(if($mvb){$mvb.Value}else{0}), $summary)
        }
    }
    if ($Opponent -ne "" -and $decided -gt 0) {
        Write-Host ("  win-rate @ ${dim}: {0}/{1} = {2:P0}" -f $wins, $decided, ($wins/$decided))
    } elseif ($values.Count -gt 0) {
        $mean = ($values | Measure-Object -Average).Average
        Write-Host ("  mean value @ ${dim}: {0:N0}" -f $mean)
    }
}

Write-Host ""
if ($Opponent -ne "" -and $grandDecided -gt 0) {
    Write-Host ("OVERALL WIN-RATE vs {0}: {1}/{2} = {3:P0}" -f $OpponentName, $grandWins, $grandDecided, ($grandWins/$grandDecided))
} elseif ($soloAll.Count -gt 0) {
    $gmean = ($soloAll | Measure-Object -Average).Average
    Write-Host ("OVERALL mean value: {0:N0}  (n={1})" -f $gmean, $soloAll.Count)
}
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
