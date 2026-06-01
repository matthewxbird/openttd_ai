# Runs an unattended, headless OpenTTD match and scores it by final company
# value. No GUI: uses the null video/sound drivers (-v null:ticks=N) so the
# sim runs at max speed and auto-exits after N ticks. The MvBObserver
# GameScript logs each company's value yearly; we parse the last reading.
#
#   ./tools/run_match.ps1                       # MvB AI solo, ~30 game-years
#   ./tools/run_match.ps1 -Years 50
#   ./tools/run_match.ps1 -Opponent C:\path\to\OtherAI -OpponentName "Other AI"
#   ./tools/run_match.ps1 -Seed 12345 -Keep     # fixed seed, keep the raw log
#
# Requires the mvb-ottd image:  docker build -t mvb-ottd -f tools/openttd.Dockerfile .
#
param(
    [int]$Years = 30,
    [int]$Seed  = 0,
    [int]$MapSize = 0,         # log2 of map dimension (7=128 8=256 9=512 10=1024); 0 = leave cfg default
    [string]$Opponent = "",
    [string]$OpponentName = "",
    [switch]$Keep,
    [switch]$Rebuild,
    [switch]$Verbose
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot\..").Path

# ~74 ticks/day * ~365 days/year. Add a year of warm-up.
$ticks = [int]((($Years + 1)) * 74 * 365)

# Build the image if needed.
$haveImage = (docker images -q mvb-ottd)
if ($Rebuild -or [string]::IsNullOrEmpty($haveImage)) {
    Write-Host "Building mvb-ottd image..."
    docker build -t mvb-ottd -f "$repo\tools\openttd.Dockerfile" $repo
}

# Build the run config from the template. For a 1v1 we add the opponent to
# [ai_players] and bump the competitor count; done here (not via in-container
# sed) to avoid shell-quoting pain.
$cfgText = Get-Content (Join-Path $repo "tools\match\openttd.cfg") -Raw
if ($MapSize -gt 0) {
    $cfgText = $cfgText -replace '(?m)^map_x = .*$', "map_x = $MapSize"
    $cfgText = $cfgText -replace '(?m)^map_y = .*$', "map_y = $MapSize"
}
if ($Opponent -ne "") {
    if ($OpponentName -eq "") { throw "-Opponent requires -OpponentName (the AI's in-game GetName)." }
    $cfgText = $cfgText -replace '(?m)^max_no_competitors = .*$', 'max_no_competitors = 2'
    $cfgText = $cfgText -replace '(?m)^"MvB AI" =\s*$', "`"MvB AI`" =`n`"$OpponentName`" ="
}
$tmpCfg = Join-Path $env:TEMP "mvb_match.cfg"
# OpenTTD rewrites its cfg; LF line endings keep it clean inside Linux.
[System.IO.File]::WriteAllText($tmpCfg, ($cfgText -replace "`r`n", "`n"))

# Mount ONLY the AI's real files - mounting the whole repo makes OpenTTD's
# recursive scanner choke on nested info.nut files under tools/ and tests/.
$mounts = @(
    "-v", "${repo}\info.nut:/opt/openttd/ai/MvB_AI/info.nut:ro",
    "-v", "${repo}\main.nut:/opt/openttd/ai/MvB_AI/main.nut:ro",
    "-v", "${repo}\src:/opt/openttd/ai/MvB_AI/src:ro",
    "-v", "${repo}\tools\match\game\MvBObserver:/opt/openttd/game/MvBObserver:ro",
    "-v", "${tmpCfg}:/cfg/openttd.cfg:ro"
)
if ($Opponent -ne "") {
    $mounts += @("-v", "${Opponent}:/opt/openttd/ai/Opponent:ro")
}

$seedArg = if ($Seed -ne 0) { "-G $Seed" } else { "" }
# script=3 captures GS [OBSERVE] (Warning) + AI warnings/errors (route condemns
# etc.); -Verbose bumps to 4 for full AI Info diagnostics.
$dbg = if ($Verbose) { "4" } else { "3" }
$run = "cp /cfg/openttd.cfg /tmp/o.cfg && cd /opt/openttd && ./openttd -v null:ticks=$ticks -s null -m null -d script=$dbg -g $seedArg -c /tmp/o.cfg 2>&1"

Write-Host "Running headless match: $Years game-years ($ticks ticks)$(if($Seed){" seed=$Seed"})..."
$log = & docker run --rm @mounts mvb-ottd sh -c $run

$rawPath = Join-Path $repo "tools\match\last_match.log"
$log | Out-File -FilePath $rawPath -Encoding utf8

# Parse the LAST [OBSERVE] reading per company.
$byCompany = @{}
foreach ($line in $log) {
    if ($line -match '\[OBSERVE\] year=(\d+) company=(\d+) value=(-?\d+) cash=(-?\d+) name=(.*)$') {
        $byCompany[$Matches[2]] = [pscustomobject]@{
            Company = [int]$Matches[2]
            Year    = [int]$Matches[1]
            Value   = [long]$Matches[3]
            Cash    = [long]$Matches[4]
            Name    = $Matches[5].Trim()
        }
    }
}

if ($byCompany.Count -eq 0) {
    Write-Host "No [OBSERVE] readings found. Check the script log:"
    $log | Select-String -Pattern 'error|died|Failed|OBSERVE' | Select-Object -Last 20 | ForEach-Object { $_.Line }
    exit 1
}

$standings = $byCompany.Values | Sort-Object -Property Value -Descending
Write-Host ""
Write-Host "==== FINAL STANDINGS (by company value) ===="
$rank = 1
foreach ($s in $standings) {
    "{0}. {1,-20} value={2,12:N0} cash={3,12:N0} (year {4})" -f $rank, $s.Name, $s.Value, $s.Cash, $s.Year | Write-Host
    $rank++
}

$mvb = $standings | Where-Object { $_.Name -like "MvB*" } | Select-Object -First 1
if ($mvb) {
    $place = ([array]::IndexOf(@($standings), $mvb)) + 1
    $verdict = if ($place -eq 1) { "WON" } else { "placed #$place" }
    Write-Host ""
    Write-Host "MvB AI $verdict (value $([string]::Format('{0:N0}', $mvb.Value)))."
}

if (-not $Keep) { Remove-Item $rawPath -ErrorAction SilentlyContinue }
else { Write-Host "Raw log: $rawPath" }
