# Install the lmm-api-rs client/server binary. This script never changes the
# lmm-api backend-selection link or shim.
[CmdletBinding()]
param(
    [string]$Version = "0.1.6",
    [string]$InstallDir = "",
    [ValidateSet("auto", "cargo", "release")]
    [string]$Method = "auto",
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

if (-not $PSBoundParameters.ContainsKey("Version") -and $env:LMM_API_RS_VERSION) {
    $Version = $env:LMM_API_RS_VERSION
}
if (-not $PSBoundParameters.ContainsKey("InstallDir")) {
    if ($env:LMM_API_RS_INSTALL_DIR) {
        $InstallDir = $env:LMM_API_RS_INSTALL_DIR
    } else {
        $InstallDir = Join-Path $env:LOCALAPPDATA "Programs\lmm-api\bin"
    }
}
if (-not $PSBoundParameters.ContainsKey("Method") -and $env:LMM_API_RS_INSTALL_METHOD) {
    $Method = $env:LMM_API_RS_INSTALL_METHOD
}
$Repository = if ($env:LMM_API_RS_REPOSITORY) {
    $env:LMM_API_RS_REPOSITORY
} else {
    "https://github.com/LIghtJUNction/api.lmm.best"
}

if ($Version -notmatch '^[0-9A-Za-z.-]+$') {
    throw "Invalid version: $Version"
}
if ($Method -notin @("auto", "cargo", "release")) {
    throw "Invalid installation method: $Method"
}
if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    throw "Install directory is empty"
}

function Test-Command([string]$Name) {
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-ReleasePlatform {
    $architecture = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture
    switch ($architecture) {
        "X64" { return "windows-amd64" }
        "Arm64" { return "windows-arm64" }
        default { throw "Unsupported Windows architecture: $architecture" }
    }
}

function Get-SelectedMethod {
    if ($Method -ne "auto") {
        return $Method
    }
    if (Test-Command "cargo") {
        return "cargo"
    }
    return "release"
}

function Assert-SafeInstallDirectory([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Refusing to install through unsafe directory: $Path"
        }
    } else {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Invoke-Download([string]$Uri, [string]$Destination) {
    if (-not $Uri.StartsWith("https://", [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing non-HTTPS download: $Uri"
    }
    Invoke-WebRequest -Uri $Uri -OutFile $Destination -MaximumRedirection 5 -UseBasicParsing
}

function Assert-Checksum([string]$Archive, [string]$ChecksumFile, [string]$ArchiveName) {
    $line = Get-Content -LiteralPath $ChecksumFile |
        Where-Object { $_ -match "^([0-9A-Fa-f]{64})\s+\*?$([regex]::Escape($ArchiveName))$" } |
        Select-Object -First 1
    if (-not $line -or $line -notmatch '^([0-9A-Fa-f]{64})') {
        throw "Release checksum file did not contain $ArchiveName"
    }
    $expected = $Matches[1].ToLowerInvariant()
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Archive).Hash.ToLowerInvariant()
    if ($actual -ne $expected) {
        throw "Release checksum mismatch"
    }
}

function Assert-SigstoreIfAvailable([string]$Archive, [string]$Bundle) {
    if (Test-Command "cosign") {
        & cosign verify-blob `
            --bundle $Bundle `
            --certificate-identity-regexp '^https://github.com/LIghtJUNction/api\.lmm\.best/\.github/workflows/release-rust\.yml@refs/tags/cli-v[0-9A-Za-z.-]+$' `
            --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' `
            $Archive | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Sigstore verification failed"
        }
    } else {
        Write-Warning "cosign is unavailable; SHA-256 verified, Sigstore verification skipped"
    }
}

function New-TemporaryDirectory {
    $root = [IO.Path]::GetTempPath()
    for ($attempt = 0; $attempt -lt 8; $attempt++) {
        $path = Join-Path $root ("lmm-api-rs-install-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Path $path -ErrorAction Stop | Out-Null
            return $path
        } catch [System.IO.IOException] {
            continue
        }
    }
    throw "Could not create a temporary installation directory"
}

function Install-FromCargo {
    if (-not (Test-Command "cargo")) {
        throw "cargo is unavailable"
    }
    $temporary = New-TemporaryDirectory
    try {
        & cargo install --locked --git $Repository --tag "cli-v$Version" --root (Join-Path $temporary "root") lmm-api-rs
        if ($LASTEXITCODE -ne 0) {
            throw "cargo install failed"
        }
        $source = Join-Path $temporary "root\bin\lmm-api-rs.exe"
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "cargo did not produce lmm-api-rs.exe"
        }
        Assert-SafeInstallDirectory $InstallDir
        Copy-Item -LiteralPath $source -Destination (Join-Path $InstallDir "lmm-api-rs.exe") -Force
    } finally {
        Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Install-FromRelease {
    $platform = Get-ReleasePlatform
    $artifact = "lmm-api-rs-$Version-$platform"
    $archiveName = "$artifact.tar.gz"
    $base = "$Repository/releases/download/cli-v$Version"
    $temporary = New-TemporaryDirectory
    try {
        $archive = Join-Path $temporary $archiveName
        $checksum = "$archive.sha256"
        $bundle = "$archive.sigstore.json"
        Invoke-Download "$base/$archiveName" $archive
        Invoke-Download "$base/$archiveName.sha256" $checksum
        Invoke-Download "$base/$archiveName.sigstore.json" $bundle
        Assert-Checksum $archive $checksum $archiveName
        Assert-SigstoreIfAvailable $archive $bundle

        $listing = & tar -tzf $archive
        if ($LASTEXITCODE -ne 0) {
            throw "Could not inspect release archive"
        }
        foreach ($entry in $listing) {
            if (-not $entry.StartsWith("$artifact/", [StringComparison]::Ordinal) -or
                $entry -match '(^|/)\.\.($|/)' -or $entry.StartsWith('/')) {
                throw "Unsafe release archive entry: $entry"
            }
        }
        & tar -xzf $archive -C $temporary
        if ($LASTEXITCODE -ne 0) {
            throw "Could not extract release archive"
        }
        $source = Join-Path $temporary "$artifact\lmm-api-rs.exe"
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "Release binary is missing"
        }
        Assert-SafeInstallDirectory $InstallDir
        Copy-Item -LiteralPath $source -Destination (Join-Path $InstallDir "lmm-api-rs.exe") -Force
    } finally {
        Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$selected = Get-SelectedMethod
if ($DryRun) {
    switch ($selected) {
        "cargo" { Write-Output "cargo install --locked --git $Repository --tag cli-v$Version lmm-api-rs" }
        "release" { Write-Output "download and verify lmm-api-rs-$Version-$(Get-ReleasePlatform).tar.gz" }
    }
    Write-Output "lmm-api link or shim: unchanged"
    exit 0
}

switch ($selected) {
    "cargo" { Install-FromCargo }
    "release" { Install-FromRelease }
}

$binary = Join-Path $InstallDir "lmm-api-rs.exe"
if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) {
    throw "lmm-api-rs installation completed but the binary was not found"
}
Write-Output "Installed lmm-api-rs: $binary"
Write-Output "The lmm-api backend-selection link or shim was not changed."
& $binary doctor
if ($LASTEXITCODE -ne 0) {
    throw "lmm-api-rs doctor failed"
}
