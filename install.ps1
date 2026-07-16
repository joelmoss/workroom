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

# Resolve the release tag to install for the given channel. Mirrors install.sh's routing (NOT tag
# classification, which lives in internal/channel + ReleaseChannel + channel-helper.sh):
#   stable  -> GitHub's "Latest" (excludes prereleases)
#   pre     -> newest release that isn't the nightly/appcast pseudo-release (GitHub lists newest
#              first and hides drafts, so this is the newest stable-or-prerelease)
#   nightly -> the fixed rolling "nightly" release
function Resolve-Tag($Channel) {
    switch ($Channel) {
        "stable" { return (Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest").tag_name }
        "nightly" { return "nightly" }
        "pre" {
            $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases?per_page=100"
            foreach ($r in $releases) {
                if ($r.tag_name -ne "nightly" -and $r.tag_name -ne "appcast") { return $r.tag_name }
            }
            return $null
        }
    }
}

$Arch = Get-Arch

$Channel = if ($env:WORKROOM_CHANNEL) { $env:WORKROOM_CHANNEL } else { "stable" }
if ($Channel -notin @("stable", "pre", "nightly")) {
    Write-Error "invalid WORKROOM_CHANNEL '$Channel' (want stable, pre, or nightly)"
    exit 1
}

if ($env:VERSION) {
    # An explicit VERSION pins an exact release and overrides the channel.
    $Version = $env:VERSION
    if (-not $Version.StartsWith("v")) {
        $Version = "v$Version"
    }
    $Tag = $Version
    $Archive = "workroom_$($Version.TrimStart('v'))_windows_${Arch}.zip"
} else {
    Write-Host "Resolving the $Channel channel..."
    $Tag = Resolve-Tag $Channel
    if (-not $Tag) {
        Write-Error "could not resolve a $Channel release"
        exit 1
    }
    if ($Channel -eq "nightly") {
        # Nightly assets are version-independent (fixed rolling release).
        $Archive = "workroom_nightly_windows_${Arch}.zip"
    } else {
        $Archive = "workroom_$($Tag.TrimStart('v'))_windows_${Arch}.zip"
    }
}

$Url = "https://github.com/$Repo/releases/download/$Tag/$Archive"

Write-Host "Installing workroom ($Channel channel, windows/$Arch)..."

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

    # Nightly installs under a distinct command name so it coexists with a main `workroom` (issue
    # #91); the nightly archive's binary is already baked to the nightly channel by CI. The archive
    # always contains `workroom.exe`; only the installed name differs.
    $DestName = if ($Channel -eq "nightly") { "workroom-nightly.exe" } else { "workroom.exe" }
    Copy-Item -Path (Join-Path $TmpDir $Binary) -Destination (Join-Path $InstallDir $DestName) -Force

    # Add to user PATH if not already present
    $UserPath = [Environment]::GetEnvironmentVariable("Path", "User").TrimEnd(';')
    if ($UserPath -notlike "*$InstallDir*") {
        [Environment]::SetEnvironmentVariable("Path", "$UserPath;$InstallDir", "User")
        $env:Path = "$env:Path;$InstallDir"
        Write-Host ""
        Write-Host "Added $InstallDir to your PATH."
        Write-Host "Restart your terminal for PATH changes to take effect."
    }

    Write-Host "Installed $DestName to $InstallDir\$DestName"

    # Remember the `pre` channel so a later `workroom update` stays on it instead of reverting to
    # stable (reuses the CLI's sticky channel logic). Stable is the default (nothing to persist);
    # nightly is baked into the workroom-nightly binary, so it neither needs nor accepts a switch.
    if ($Channel -eq "pre") {
        try { & (Join-Path $InstallDir $DestName) update --channel pre *> $null } catch { }
    }

    # Verify installation
    & (Join-Path $InstallDir $DestName) version
} finally {
    if (Test-Path $TmpDir) {
        Remove-Item -Recurse -Force $TmpDir
    }
}
