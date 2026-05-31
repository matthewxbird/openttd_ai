# Runs the pure-module unit test suite (tests/run_all.nut) using a Squirrel
# interpreter built inside Docker. No compiler / sq.exe needed on the host.
#
#   ./tools/run_tests.ps1            # build image if missing, run tests
#   ./tools/run_tests.ps1 -Rebuild   # force-rebuild the image first
#
param([switch]$Rebuild)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot\..").Path

$haveImage = (docker images -q mvb-sq) -ne $null -and (docker images -q mvb-sq) -ne ''
if ($Rebuild -or -not $haveImage) {
    Write-Host "Building mvb-sq image..."
    docker build -t mvb-sq -f "$repo\tools\squirrel.Dockerfile" $repo
}

docker run --rm -v "${repo}:/work" mvb-sq tests/run_all.nut
exit $LASTEXITCODE
