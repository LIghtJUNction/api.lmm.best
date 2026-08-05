$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$cargo = if ($env:CARGO_EXE) {
    Get-Command $env:CARGO_EXE -ErrorAction SilentlyContinue
} else {
    Get-Command cargo -ErrorAction SilentlyContinue
}
if (-not $cargo) {
    $cargoPath = Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe'
    if (Test-Path -LiteralPath $cargoPath) {
        $cargo = Get-Command $cargoPath
    }
}
if (-not $cargo) {
    throw 'cargo.exe is required; install Rust with rustup or set CARGO_EXE.'
}

$bashCandidates = @()
if ($env:LMM_BASH) { $bashCandidates += $env:LMM_BASH }
try {
    $execPath = (& git --exec-path 2>$null).Trim()
    if ($execPath) {
        $gitRoot = (Resolve-Path (Join-Path $execPath '..\..\..')).Path
        $bashCandidates += Join-Path $gitRoot 'bin\bash.exe'
        $bashCandidates += Join-Path $gitRoot 'usr\bin\bash.exe'
    }
} catch {
    # Fall through to the standard PATH lookup.
}
$bashCandidates += (Get-Command bash -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue)
$bash = $bashCandidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) -and ((Resolve-Path $_).Path -notlike 'C:\Windows\System32\*') } | Select-Object -First 1
if (-not $bash) {
    throw 'Git Bash is required for the repository shell gates. Set LMM_BASH to the Git Bash executable.'
}

function Invoke-GitBash([string] $script) {
    & $bash -lc "cd '$($repoRoot -replace '\\','/')' && $script"
    if ($LASTEXITCODE -ne 0) { throw "Git Bash command failed with exit code $LASTEXITCODE`: $script" }
}

Push-Location (Join-Path $repoRoot 'apps\api-rust')
try {
    & $cargo.Source fmt --all -- --check
    if ($LASTEXITCODE -ne 0) { throw "cargo fmt failed with exit code $LASTEXITCODE" }
    & $cargo.Source metadata --locked --no-deps --format-version 1 *> $null
    if ($LASTEXITCODE -ne 0) { throw "cargo metadata failed with exit code $LASTEXITCODE" }
    & $cargo.Source test --locked -p lmm-api-rs --test migration_all_routes_contract
    if ($LASTEXITCODE -ne 0) { throw "migration route tests failed with exit code $LASTEXITCODE" }
} finally {
    Pop-Location
}

Invoke-GitBash 'bash apps/api-rust/scripts/check-go-route-manifest.sh'
Invoke-GitBash 'bash apps/api-rust/scripts/check-draft-route-coverage.sh'
Invoke-GitBash 'bash apps/api-rust/scripts/check-migration-plan.sh'
Write-Output 'Rust migration checks passed.'
