param(
    [switch]$NoPause,
    [switch]$SkipReleaseManager
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$repoRoot = $PSScriptRoot
$toolRoot = 'C:\ForlanBuildTools'
$flutterVersion = '3.24.5'
$rustVersion = '1.99.0'
$llvmVersion = '15.0.6'
$vcpkgCommit = '9e593bb18ea69cc5095e012465dcd675a822ed0d'
$hbbCommonCommit = '94ec710894ecd548b4fe174ef781eca5c1a318c0'

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Komut başarısız oldu (kod $LASTEXITCODE): $FilePath $($Arguments -join ' ')"
    }
}

function Download-File {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $partial = "$Destination.$([guid]::NewGuid().ToString('N')).download"
    try {
        Write-Host "İndiriliyor: $Uri" -ForegroundColor DarkCyan
        Invoke-WebRequest -Uri $Uri -OutFile $partial -UseBasicParsing
        Move-Item -LiteralPath $partial -Destination $Destination -Force
    } finally {
        if (Test-Path -LiteralPath $partial -PathType Leaf) {
            Remove-Item -LiteralPath $partial -Force
        }
    }
}

function Refresh-Path {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$toolRoot\bin;$toolRoot\Python311;$toolRoot\Python311\Scripts;$toolRoot\LLVM-$llvmVersion\bin;$toolRoot\flutter\bin;$toolRoot\vcpkg;$env:USERPROFILE\.cargo\bin;$env:ProgramFiles\Git\cmd;$machinePath;$userPath"
    $env:LIBCLANG_PATH = Join-Path $toolRoot "LLVM-$llvmVersion\bin"
}

function Remove-PartialToolDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $root = [System.IO.Path]::GetFullPath($toolRoot).TrimEnd('\') + '\'
    $target = [System.IO.Path]::GetFullPath($Path)
    if (-not $target.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Araç dizini kurulum klasörünün dışında; silme yapılmadı: $target"
    }
    if (Test-Path -LiteralPath $target) {
        Remove-Item -LiteralPath $target -Recurse -Force
    }
}

function Require-Winget {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        return
    }

    Write-Host 'Windows Package Manager bulunamadı; App Installer kuruluyor...' -ForegroundColor Yellow
    $bundle = Join-Path $env:TEMP 'Microsoft.DesktopAppInstaller.msixbundle'
    Download-File 'https://aka.ms/getwinget' $bundle
    Add-AppxPackage -Path $bundle
    Refresh-Path
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw 'App Installer kuruldu ancak winget bulunamadı. Windows App Installer için yeniden başlatma gerekebilir; yeniden başlatıp betiği tekrar çalıştırın.'
    }
}

function Install-WingetPackage {
    param([Parameter(Mandatory = $true)][string]$Id)

    Write-Host "Gerekli araç kontrol ediliyor: $Id" -ForegroundColor Cyan
    & winget install --id $Id --exact --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "winget paketi kurulamadı: $Id (çıkış kodu: $LASTEXITCODE)"
    }
    Refresh-Path
}

function Find-Python311 {
    $candidates = @(
        (Join-Path $toolRoot 'Python311\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python311\python.exe'),
        (Join-Path $env:ProgramFiles 'Python311\python.exe')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    $launcher = Get-Command py -ErrorAction SilentlyContinue
    if ($launcher) {
        try {
            $detected = & $launcher.Source -3.11 -c 'import sys; print(sys.executable)' 2>$null
            if ($LASTEXITCODE -eq 0 -and $detected -and (Test-Path -LiteralPath $detected -PathType Leaf)) {
                return $detected
            }
        } catch {
            # The launcher writes an error when 3.11 is absent; installation continues below.
        }
    }
    return $null
}

function Ensure-Python {
    $pythonExe = Find-Python311
    if (-not $pythonExe) {
        Write-Host 'Python 3.11 kuruluyor...' -ForegroundColor Yellow
        & winget install --id Python.Python.3.11 --exact --silent --scope machine --accept-package-agreements --accept-source-agreements --override "/quiet InstallAllUsers=1 TargetDir=$toolRoot\Python311 Include_pip=1 PrependPath=0"
        if ($LASTEXITCODE -ne 0) {
            throw "Python 3.11 kurulamadı (çıkış kodu: $LASTEXITCODE)."
        }
        $pythonExe = Find-Python311
    }
    if (-not $pythonExe) {
        throw 'Python 3.11 kurulumu tamamlandı ancak python.exe bulunamadı.'
    }

    New-Item -ItemType Directory -Path (Join-Path $toolRoot 'bin') -Force | Out-Null
    $python3Shim = Join-Path $toolRoot 'bin\python3.cmd'
    $pip3Shim = Join-Path $toolRoot 'bin\pip3.cmd'
    [System.IO.File]::WriteAllText($python3Shim, "@echo off`r`n`"$pythonExe`" %*`r`n", [System.Text.Encoding]::ASCII)
    [System.IO.File]::WriteAllText($pip3Shim, "@echo off`r`n`"$pythonExe`" -m pip %*`r`n", [System.Text.Encoding]::ASCII)
    Refresh-Path

    & $pythonExe -m pip --version *> $null
    if ($LASTEXITCODE -ne 0) {
        Invoke-Checked $pythonExe @('-m', 'ensurepip', '--upgrade')
    }
}

function Ensure-VisualStudio {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $installation = $null
    if (Test-Path -LiteralPath $vswhere -PathType Leaf) {
        $installation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    }
    $windowsSdk = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Include'
    $hasWindowsSdk = Test-Path -LiteralPath $windowsSdk -PathType Container
    $hasCmake = $installation -and (Test-Path -LiteralPath (Join-Path $installation 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe') -PathType Leaf)
    if ($installation -and $hasWindowsSdk -and $hasCmake) {
        Write-Host "C++ derleme araçları bulundu: $installation" -ForegroundColor Green
        return
    }

    $installer = Join-Path $env:TEMP 'vs_BuildTools.exe'
    Download-File 'https://aka.ms/vs/17/release/vs_BuildTools.exe' $installer
    Write-Host 'Visual Studio C++ Build Tools kuruluyor. Bu adım uzun sürebilir...' -ForegroundColor Yellow
    $arguments = @(
        '--quiet', '--wait', '--norestart', '--nocache',
        '--installPath', "$toolRoot\VS2022",
        '--add', 'Microsoft.VisualStudio.Workload.NativeDesktop',
        '--includeRecommended',
        '--add', 'Microsoft.VisualStudio.Component.VC.CMake.Project',
        '--add', 'Microsoft.VisualStudio.Component.Windows11SDK.26100'
    )
    $process = Start-Process -FilePath $installer -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010 -and $process.ExitCode -ne 1641) {
        throw "Visual Studio Build Tools kurulumu başarısız oldu (kod: $($process.ExitCode))."
    }
    if ($process.ExitCode -eq 3010 -or $process.ExitCode -eq 1641) {
        Write-Host 'Visual Studio Windows yeniden başlatması önerdi; build yine de denenecek.' -ForegroundColor Yellow
    }
}

function Ensure-Rust {
    $rustup = Join-Path $env:USERPROFILE '.cargo\bin\rustup.exe'
    if (-not (Test-Path -LiteralPath $rustup -PathType Leaf)) {
        $rustupInstaller = Join-Path $env:TEMP 'rustup-init.exe'
        Download-File 'https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe' $rustupInstaller
        Write-Host 'Rust MSVC araç zinciri kuruluyor...' -ForegroundColor Yellow
        $process = Start-Process -FilePath $rustupInstaller -ArgumentList @('-y', '--default-host', 'x86_64-pc-windows-msvc', '--default-toolchain', $rustVersion, '--profile', 'minimal') -Wait -PassThru
        if ($process.ExitCode -ne 0) {
            throw "Rust kurulumu başarısız oldu (kod: $($process.ExitCode))."
        }
    }

    Refresh-Path
    Invoke-Checked $rustup @('toolchain', 'install', $rustVersion, '--profile', 'minimal', '--component', 'rustfmt')
    Invoke-Checked $rustup @('default', $rustVersion)
}

function Ensure-Git {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Git\cmd\git.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd\git.exe')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $env:Path = "$(Split-Path -Parent $candidate);$env:Path"
            break
        }
    }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Install-WingetPackage 'Git.Git'
    }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'Git kurulumu tamamlandı ancak git komutu bulunamadı.'
    }
}

function Ensure-Submodule {
    $commonManifest = Join-Path $repoRoot 'libs\hbb_common\Cargo.toml'
    if (Test-Path -LiteralPath $commonManifest -PathType Leaf) {
        return
    }

    $commonPath = Join-Path $repoRoot 'libs\hbb_common'
    if (Test-Path -LiteralPath (Join-Path $repoRoot '.git')) {
        Write-Host 'hbb_common alt modülü indiriliyor...' -ForegroundColor Yellow
        Invoke-Checked 'git' @('-c', 'core.longpaths=true', '-C', $repoRoot, 'submodule', 'update', '--init', '--recursive', '--', 'libs/hbb_common')
    } else {
        Write-Host 'Git metadata bulunamadı; hbb_common kaynakları indiriliyor...' -ForegroundColor Yellow
        $commonGit = Join-Path $commonPath '.git'
        if ((Test-Path -LiteralPath $commonPath) -and
            -not (Test-Path -LiteralPath $commonGit) -and
            (Get-ChildItem -LiteralPath $commonPath -Force | Select-Object -First 1)) {
            throw "Alt modül klasörü dolu ancak Cargo.toml yok; içeriğe dokunmadım: $commonPath"
        }
        if (-not (Test-Path -LiteralPath $commonGit)) {
            Invoke-Checked 'git' @('-c', 'core.longpaths=true', 'init', $commonPath)
            Invoke-Checked 'git' @('-C', $commonPath, 'remote', 'add', 'origin', 'https://github.com/rustdesk/hbb_common.git')
        }
        Invoke-Checked 'git' @('-C', $commonPath, 'fetch', '--depth', '1', 'origin', $hbbCommonCommit)
        Invoke-Checked 'git' @('-C', $commonPath, 'checkout', '--detach', $hbbCommonCommit)
    }

    if (-not (Test-Path -LiteralPath $commonManifest -PathType Leaf)) {
        throw "hbb_common kaynakları indirilemedi: $commonManifest"
    }
}

function Ensure-Flutter {
    $flutterRoot = Join-Path $toolRoot 'flutter'
    $flutterBat = Join-Path $flutterRoot 'bin\flutter.bat'
    if (-not (Test-Path -LiteralPath $flutterBat -PathType Leaf)) {
        if (Test-Path -LiteralPath $flutterRoot) {
            Remove-PartialToolDirectory $flutterRoot
        }
        Write-Host "Flutter $flutterVersion indiriliyor..." -ForegroundColor Yellow
        Invoke-Checked 'git' @('-c', 'core.longpaths=true', 'clone', '--depth', '1', '--branch', $flutterVersion, 'https://github.com/flutter/flutter.git', $flutterRoot)
    }

    $env:Path = "$flutterRoot\bin;$env:Path"
    $patch = Join-Path $repoRoot '.github\patches\flutter_3.24.4_dropdown_menu_enableFilter.diff'
    Push-Location -LiteralPath $flutterRoot
    try {
        $oldEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $canApply = $false
        try {
            & git apply --check $patch 2>$null
            $canApply = $LASTEXITCODE -eq 0
        } catch {}
        if ($canApply) {
            Invoke-Checked 'git' @('apply', $patch)
        } else {
            $alreadyApplied = $false
            try {
                & git apply --reverse --check $patch 2>$null
                $alreadyApplied = $LASTEXITCODE -eq 0
            } catch {}
            if (-not $alreadyApplied) {
                throw 'Flutter kaynak yaması uygulanamıyor; SDK sürümü depo ile eşleşmiyor.'
            }
        }
        $ErrorActionPreference = $oldEap
    } finally {
        Pop-Location
    }

    Invoke-Checked $flutterBat @('precache', '--windows')
    Install-RustDeskFlutterEngine $flutterRoot
}

function Install-RustDeskFlutterEngine {
    param([Parameter(Mandatory = $true)][string]$FlutterRoot)

    $engineDirectory = Join-Path $FlutterRoot 'bin\cache\artifacts\engine\windows-x64-release'
    $marker = Join-Path $engineDirectory '.forlan-engine-ready'
    if (Test-Path -LiteralPath $marker -PathType Leaf) {
        return
    }

    $archive = Join-Path $env:TEMP 'forlan-windows-x64-release.zip'
    $staging = Join-Path $env:TEMP "forlan-windows-x64-release-$([guid]::NewGuid().ToString('N'))"
    Download-File 'https://github.com/rustdesk/engine/releases/download/main/windows-x64-release.zip' $archive
    Expand-Archive -LiteralPath $archive -DestinationPath $staging -Force
    New-Item -ItemType Directory -Path $engineDirectory -Force | Out-Null
    Get-ChildItem -LiteralPath $staging | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $engineDirectory -Recurse -Force
    }
    Set-Content -LiteralPath $marker -Value 'RustDesk Flutter engine' -Encoding ASCII
    $tempRoot = [System.IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    $resolvedStaging = [System.IO.Path]::GetFullPath($staging)
    if ($resolvedStaging.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedStaging -Recurse -Force
        Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
    }
}

function Ensure-Llvm {
    $llvmRoot = Join-Path $toolRoot "LLVM-$llvmVersion"
    $clang = Join-Path $llvmRoot 'bin\clang.exe'
    if (Test-Path -LiteralPath $clang -PathType Leaf) {
        return
    }

    $installer = Join-Path $env:TEMP "LLVM-$llvmVersion-win64.exe"
    Download-File "https://github.com/llvm/llvm-project/releases/download/llvmorg-$llvmVersion/LLVM-$llvmVersion-win64.exe" $installer
    Write-Host "LLVM $llvmVersion kuruluyor..." -ForegroundColor Yellow
    $process = Start-Process -FilePath $installer -ArgumentList @('/S', "/D=$llvmRoot") -Wait -PassThru
    if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $clang -PathType Leaf)) {
        throw "LLVM $llvmVersion kurulumu başarısız oldu."
    }
}

function Ensure-Vcpkg {
    $vcpkgRoot = Join-Path $toolRoot 'vcpkg'
    $vcpkgExe = Join-Path $vcpkgRoot 'vcpkg.exe'
    if (-not (Test-Path -LiteralPath $vcpkgExe -PathType Leaf)) {
        if (-not (Test-Path -LiteralPath (Join-Path $vcpkgRoot '.git'))) {
            if (Test-Path -LiteralPath $vcpkgRoot) {
                Remove-PartialToolDirectory $vcpkgRoot
            }
            Write-Host 'vcpkg indiriliyor...' -ForegroundColor Yellow
            Invoke-Checked 'git' @('-c', 'core.longpaths=true', 'clone', 'https://github.com/microsoft/vcpkg.git', $vcpkgRoot)
        }
    }

    Push-Location -LiteralPath $vcpkgRoot
    try {
        Invoke-Checked 'git' @('fetch', '--depth', '1', 'origin', $vcpkgCommit)
        Invoke-Checked 'git' @('checkout', '--detach', $vcpkgCommit)
        Invoke-Checked '.\bootstrap-vcpkg.bat' @('-disableMetrics')
    } finally {
        Pop-Location
    }

    $env:VCPKG_ROOT = $vcpkgRoot
    $env:VCPKG_DEFAULT_TRIPLET = 'x64-windows-static'
    $env:VCPKG_DEFAULT_HOST_TRIPLET = 'x64-windows-static'
    Push-Location -LiteralPath $repoRoot
    try {
        Invoke-Checked $vcpkgExe @('install', '--triplet', 'x64-windows-static', "--x-install-root=$vcpkgRoot\installed")
    } finally {
        Pop-Location
    }
}

function Ensure-Bridge {
    $generatedFiles = @(
        (Join-Path $repoRoot 'src\bridge_generated.rs'),
        (Join-Path $repoRoot 'src\bridge_generated.io.rs'),
        (Join-Path $repoRoot 'flutter\lib\generated_bridge.dart'),
        (Join-Path $repoRoot 'flutter\lib\generated_bridge.freezed.dart')
    )
    if (-not ($generatedFiles | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })) {
        return
    }

    Write-Host 'Flutter-Rust köprü kodu oluşturuluyor...' -ForegroundColor Yellow
    $cargo = Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe'
    $cargoExpand = Join-Path $env:USERPROFILE '.cargo\bin\cargo-expand.exe'
    $codegen = Join-Path $env:USERPROFILE '.cargo\bin\flutter_rust_bridge_codegen.exe'
    if (-not (Test-Path -LiteralPath $cargoExpand -PathType Leaf)) {
        Invoke-Checked $cargo @('install', 'cargo-expand', '--version', '1.0.95', '--locked')
    }
    if (-not (Test-Path -LiteralPath $codegen -PathType Leaf)) {
        Invoke-Checked $cargo @('install', 'flutter_rust_bridge_codegen', '--version', '1.80.1', '--features', 'uuid', '--locked')
    }

    $flutterBat = Join-Path $toolRoot 'flutter\bin\flutter.bat'
    Push-Location -LiteralPath (Join-Path $repoRoot 'flutter')
    try {
        Invoke-Checked $flutterBat @('pub', 'get')
    } finally {
        Pop-Location
    }

    Push-Location -LiteralPath $repoRoot
    $previousRustLog = $env:RUST_LOG
    try {
        $env:RUST_LOG = 'info'
        Invoke-Checked $codegen @('--rust-input', '.\src\flutter_ffi.rs', '--dart-output', '.\flutter\lib\generated_bridge.dart', '--llvm-path', (Join-Path $toolRoot "LLVM-$llvmVersion"))
    } finally {
        $env:RUST_LOG = $previousRustLog
        Pop-Location
    }

    foreach ($path in $generatedFiles) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Flutter-Rust köprü dosyası oluşturulamadı: $path"
        }
    }
}

$transcriptStarted = $false
try {
if ($env:OS -ne 'Windows_NT') {
    throw 'Bu betik Windows üzerinde çalıştırılmalıdır.'
}
$hostArchitecture = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
if ($hostArchitecture -ne 'AMD64') {
    throw 'Bu tek tık kurulum Windows x64 içindir.'
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Derleme araçlarını kurmak ve Flutter symlink izinleri için yönetici izni isteniyor...' -ForegroundColor Yellow
    $powershell = (Get-Process -Id $PID).Path
    $elevatedArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($NoPause) {
        $elevatedArguments += '-NoPause'
    }
    if ($SkipReleaseManager) {
        $elevatedArguments += '-SkipReleaseManager'
    }
    $elevated = Start-Process -FilePath $powershell -Verb RunAs -ArgumentList $elevatedArguments -Wait -PassThru
    exit $elevated.ExitCode
}

try {
    Start-Transcript -Path (Join-Path $repoRoot 'build-portable.log') -Append | Out-Null
    $transcriptStarted = $true
} catch {
    Write-Host "Derleme çıktısı günlüğe yönlendirilemedi: $($_.Exception.Message)" -ForegroundColor Yellow
}

$requiredFiles = @(
    (Join-Path $repoRoot 'build.py'),
    (Join-Path $repoRoot 'Cargo.toml'),
    (Join-Path $repoRoot 'flutter\windows\CMakeLists.txt'),
    (Join-Path $repoRoot 'libs\portable\requirements.txt'),
    (Join-Path $repoRoot '.github\patches\flutter_3.24.4_dropdown_menu_enableFilter.diff')
)
foreach ($path in $requiredFiles) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Depo dosyası bulunamadı: $path"
    }
}

New-Item -ItemType Directory -Path $toolRoot -Force | Out-Null
Require-Winget
Ensure-Git
Ensure-Python
Ensure-VisualStudio
Ensure-Rust
Ensure-Llvm
Ensure-Flutter
Ensure-Submodule
Ensure-Vcpkg
Refresh-Path
Ensure-Bridge

$serverPublicKeyPath = Join-Path $repoRoot 'deploy\forlan-server\id_ed25519.pub'
if (-not (Test-Path -LiteralPath $serverPublicKeyPath -PathType Leaf)) {
    throw "Sunucu genel anahtarı bulunamadı: $serverPublicKeyPath. Önce Forlan sunucusunu kurun."
}
$serverPublicKey = (Get-Content -LiteralPath $serverPublicKeyPath -Raw).Trim()
try {
    $serverPublicKeyBytes = [Convert]::FromBase64String($serverPublicKey)
} catch {
    throw "Sunucu genel anahtarı Base64 biçiminde değil: $serverPublicKeyPath"
}
if ($serverPublicKeyBytes.Length -ne 32) {
    throw "Sunucu genel anahtarı 32 bayt olmalı: $serverPublicKeyPath"
}
$env:FORLAN_ID_SERVER = '95.70.196.174'
$env:FORLAN_RELAY_SERVER = '95.70.196.174:21117'
$env:FORLAN_SERVER_PUBLIC_KEY = $serverPublicKey

$versionLine = Get-Content -LiteralPath (Join-Path $repoRoot 'Cargo.toml') | Where-Object { $_ -match '^version\s*=' } | Select-Object -First 1
if ($versionLine -notmatch '"([^"]+)"') {
    throw 'Cargo.toml içinden uygulama sürümü okunamadı.'
}
$version = $Matches[1]
$officialArtifact = Join-Path $repoRoot "ForlanDestek-$version-Portable.exe"
$outputDirectory = Join-Path $repoRoot 'dist'
$portableArtifact = Join-Path $outputDirectory "ForlanDestek-$version-portable.exe"
$windowsBuildDirectory = Join-Path $repoRoot 'flutter\build\windows\x64'
$cmakeCache = Join-Path $windowsBuildDirectory 'CMakeCache.txt'
if ((Test-Path -LiteralPath $cmakeCache -PathType Leaf) -and
    (Select-String -LiteralPath $cmakeCache -Pattern 'TARGET_FILE_DIR:rustdesk' -Quiet)) {
    $expectedBuildDirectory = [System.IO.Path]::GetFullPath((Join-Path $repoRoot 'flutter\build\windows\x64'))
    $actualBuildDirectory = [System.IO.Path]::GetFullPath($windowsBuildDirectory)
    if (-not $actualBuildDirectory.Equals($expectedBuildDirectory, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Windows build dizini beklenenden farklı: $actualBuildDirectory"
    }
    Write-Host 'Eski RustDesk CMake önbelleği temizleniyor...' -ForegroundColor Yellow
    Remove-Item -LiteralPath $actualBuildDirectory -Recurse -Force
}

Push-Location -LiteralPath $repoRoot
try {
    Write-Host 'Flutter Windows portable build başlatılıyor...' -ForegroundColor Cyan
    if (Test-Path -LiteralPath $officialArtifact -PathType Leaf) {
        Remove-Item -LiteralPath $officialArtifact -Force
    }
    Invoke-Checked 'python3' @((Join-Path $repoRoot 'build.py'), '--portable', '--flutter', '--hwcodec', '--vram')

    if (-not (Test-Path -LiteralPath $officialArtifact -PathType Leaf)) {
        throw "Build tamamlandı ancak portable çıktı bulunamadı: $officialArtifact"
    }

    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    Copy-Item -LiteralPath $officialArtifact -Destination $portableArtifact -Force
    Remove-Item -LiteralPath $officialArtifact -Force
    Write-Host "Portable build hazır: $portableArtifact" -ForegroundColor Green

    if (-not $SkipReleaseManager) {
        $managerSource = Join-Path $repoRoot 'release-manager\ForlanReleaseManager.cs'
        $managerIcon = Join-Path $repoRoot 'res\icon.ico'
        $managerPath = Join-Path $outputDirectory 'ForlanReleaseManager.exe'
        $temporaryManagerPath = Join-Path $outputDirectory "ForlanReleaseManager-$([guid]::NewGuid().ToString('N')).exe"
        if (-not (Test-Path -LiteralPath $managerSource -PathType Leaf)) {
            throw "Release yöneticisi kaynağı bulunamadı: $managerSource"
        }
        if (-not (Test-Path -LiteralPath $managerIcon -PathType Leaf)) {
            throw "Release yöneticisi simgesi bulunamadı: $managerIcon"
        }
        try {
            Write-Host 'Küçük release yönetim uygulaması hazırlanıyor...' -ForegroundColor Cyan
            $managerCompilerParameters = New-Object System.CodeDom.Compiler.CompilerParameters
            $managerCompilerParameters.GenerateExecutable = $true
            $managerCompilerParameters.GenerateInMemory = $false
            $managerCompilerParameters.OutputAssembly = $temporaryManagerPath
            $managerCompilerParameters.CompilerOptions = "/target:winexe /win32icon:`"$managerIcon`""
            foreach ($assembly in @('System.dll', 'System.Core.dll', 'System.Drawing.dll', 'System.Windows.Forms.dll')) {
                [void]$managerCompilerParameters.ReferencedAssemblies.Add($assembly)
            }
            Add-Type -Path $managerSource -CompilerParameters $managerCompilerParameters
            Move-Item -LiteralPath $temporaryManagerPath -Destination $managerPath -Force
            Write-Host "Yayın yöneticisi hazır: $managerPath" -ForegroundColor Green
        }
        finally {
            if (Test-Path -LiteralPath $temporaryManagerPath -PathType Leaf) {
                Remove-Item -LiteralPath $temporaryManagerPath -Force
            }
        }
    }
}
finally {
    Pop-Location
}
if ($transcriptStarted) {
    try { Stop-Transcript | Out-Null } catch {}
}
}
catch {
    if ($transcriptStarted) {
        try { Stop-Transcript | Out-Null } catch {}
    }
    $logPath = Join-Path $repoRoot 'build-portable.log'
    $message = @(
        ''
        ('[{0}] BUILD FAILED' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
        ('Error: {0}' -f $_.Exception.Message)
        ('Location: {0}' -f $_.InvocationInfo.PositionMessage)
        $_.ScriptStackTrace
    ) -join [Environment]::NewLine

    Write-Host ''
    Write-Host 'Portable build başarısız oldu.' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    if ($_.InvocationInfo.PositionMessage) {
        Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor DarkRed
    }
    try {
        [System.IO.File]::AppendAllText($logPath, $message + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($true)))
        Write-Host "Ayrıntılar kaydedildi: $logPath" -ForegroundColor Yellow
    } catch {
        Write-Host "Hata günlüğü yazılamadı: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    Write-Host ''
    if (-not $NoPause) {
        Read-Host 'Bu pencereyi kapatmak için Enter tuşuna basın' | Out-Null
    }
    exit 1
}
