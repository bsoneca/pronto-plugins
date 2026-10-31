$ErrorActionPreference = "Stop"
$Version = if ($env:SAYT_VERSION) { $env:SAYT_VERSION } else { "v0.44.1" }
if (-not ($Version.StartsWith("v")) -and $Version -ne "latest") {
    $Version = "v$Version"
}
$env:SAYT_VERSION = $Version
$CacheDir = if ($env:LOCALAPPDATA) {
    Join-Path $env:LOCALAPPDATA "sayt"
} elseif ($env:XDG_CACHE_HOME) {
    Join-Path $env:XDG_CACHE_HOME "sayt"
} else {
    Join-Path $env:HOME ".cache/sayt"
}

$DownloadBase = if ($env:SAYT_RELEASE_BASE) { $env:SAYT_RELEASE_BASE.TrimEnd('/') } else { $null }
$ChildBase = $DownloadBase
if ($env:SAYT_INSECURE -and $ChildBase) {
    if ($ChildBase.StartsWith("https://")) {
        $ChildBase = "http://" + $ChildBase.Substring(8)
    }
    $ChildBase = $ChildBase -replace ":8443/", ":8080/"
}

if ($IsWindows -or $env:OS -eq "Windows_NT") {
    $OsName = "windows"
} elseif ($IsLinux) {
    $OsName = "linux"
} elseif ($IsMacOS) {
    $OsName = "macos"
} else {
    Write-Error "Unsupported OS"
    exit 1
}

if ($OsName -eq "windows") {
    if ($env:PROCESSOR_ARCHITECTURE -eq "AMD64") {
        $BinName = "sayt-windows-x64.exe"
    } elseif ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") {
        $BinName = "sayt-windows-arm64.exe"
    } else {
        Write-Error "Unsupported architecture: $env:PROCESSOR_ARCHITECTURE"
        exit 1
    }
} else {
    $Arch = (uname -m)
    if ($OsName -eq "linux") {
        if ($Arch -eq "x86_64") {
            $BinName = "sayt-linux-x64"
        } elseif ($Arch -eq "aarch64") {
            $BinName = "sayt-linux-arm64"
        } elseif ($Arch -eq "armv7l") {
            $BinName = "sayt-linux-armv7"
        } else {
            Write-Error "Unsupported architecture: $Arch"
            exit 1
        }
    } elseif ($OsName -eq "macos") {
        if ($Arch -eq "x86_64") {
            $BinName = "sayt-macos-x64"
        } elseif ($Arch -eq "arm64") {
            $BinName = "sayt-macos-arm64"
        } else {
            Write-Error "Unsupported architecture: $Arch"
            exit 1
        }
    }
}

$VersionedCacheDir = Join-Path $CacheDir $Version
$Binary = Join-Path $VersionedCacheDir $BinName
$SaytLink = if ($OsName -eq "windows") { Join-Path $CacheDir "sayt.exe" } else { Join-Path $CacheDir "sayt" }

if (-not (Test-Path $Binary)) {
    New-Item -ItemType Directory -Path $VersionedCacheDir -Force | Out-Null
    Write-Host "Downloading sayt $Version ($BinName)..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    if ($DownloadBase) {
        $Url = "$DownloadBase/$BinName"
    } elseif ($Version -eq "latest") {
        $Url = "https://github.com/bonisoft3/sayt/releases/latest/download/$BinName"
    } else {
        $Url = "https://github.com/bonisoft3/sayt/releases/download/$Version/$BinName"
    }
    # Stage to a temp path; only a successful download lands at $Binary.
    $TmpBinary = "$Binary.part.$PID"
    $InvokeParams = @{
        Uri = $Url
        OutFile = $TmpBinary
        UseBasicParsing = $true
    }
    if ($env:SAYT_INSECURE -and $PSVersionTable.PSVersion.Major -ge 7) {
        $InvokeParams.SkipCertificateCheck = $true
    }
    try {
        Invoke-WebRequest @InvokeParams
    } catch {
        Remove-Item -Path $TmpBinary -Force -ErrorAction SilentlyContinue
        throw
    }

    if ($OsName -ne "windows") {
        chmod +x $TmpBinary
    }
    Move-Item -Path $TmpBinary -Destination $Binary -Force

    Copy-Item -Path $Binary -Destination $SaytLink -Force
}

if ($ChildBase) {
    $env:SAYT_RELEASE_BASE = $ChildBase
}

& $Binary @args
exit $LASTEXITCODE
