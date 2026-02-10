$ErrorActionPreference = "Stop"

$Repo = "joelmoss/workroom"
$Binary = "workroom.exe"

function Get-Arch {
    switch ($env:PROCESSOR_ARCHITECTURE) {
        "AMD64" { return "amd64" }
        "ARM64" { return "arm64" }
        default {
            Write-Error "Unsupported architecture: $env:PROCESSOR_ARCHITECTURE"
            exit 1
        }
    }
}

function Get-LatestVersion {
    $response = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest"
    return $response.tag_name
}

$Arch = Get-Arch

if ($env:VERSION) {
    $Version = $env:VERSION
    if (-not $Version.StartsWith("v")) {
        $Version = "v$Version"
    }
} else {
    Write-Host "Fetching latest version..."
    $Version = Get-LatestVersion
    if (-not $Version) {
        Write-Error "Could not determine latest version"
        exit 1
    }
}

$VersionNum = $Version.TrimStart("v")
$Archive = "workroom_${VersionNum}_windows_${Arch}.zip"
$Url = "https://github.com/$Repo/releases/download/$Version/$Archive"

Write-Host "Installing workroom $Version (windows/$Arch)..."

$TmpDir = Join-Path $env:TEMP "workroom-install"
if (Test-Path $TmpDir) { Remove-Item -Recurse -Force $TmpDir }
New-Item -ItemType Directory -Path $TmpDir | Out-Null

$TmpFile = Join-Path $TmpDir $Archive

try {
    Write-Host "Downloading $Url..."
    Invoke-WebRequest -Uri $Url -OutFile $TmpFile -UseBasicParsing

    Expand-Archive -Path $TmpFile -DestinationPath $TmpDir -Force

    $InstallDir = Join-Path $env:LOCALAPPDATA "workroom"
    if (-not (Test-Path $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir | Out-Null
    }

    Copy-Item -Path (Join-Path $TmpDir $Binary) -Destination (Join-Path $InstallDir $Binary) -Force

    # Add to user PATH if not already present
    $UserPath = [Environment]::GetEnvironmentVariable("Path", "User").TrimEnd(';')
    if ($UserPath -notlike "*$InstallDir*") {
        [Environment]::SetEnvironmentVariable("Path", "$UserPath;$InstallDir", "User")
        $env:Path = "$env:Path;$InstallDir"
        Write-Host ""
        Write-Host "Added $InstallDir to your PATH."
        Write-Host "Restart your terminal for PATH changes to take effect."
    }

    Write-Host "Installed workroom to $InstallDir\$Binary"

    # Verify installation
    & (Join-Path $InstallDir $Binary) version
} finally {
    if (Test-Path $TmpDir) {
        Remove-Item -Recurse -Force $TmpDir
    }
}
