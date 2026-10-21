[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('Auto', 'Patch', 'Minor', 'Major', 'Manual')]
    [string]$VersionMode = 'Auto',
    [string]$ManualVersion,
    [string]$NotesFile,
    [switch]$SkipGeneratedNotes
)

$ErrorActionPreference = 'Stop'
$repository = 'NaerielElara/ForlanDestek'
$repoRoot = $PSScriptRoot
. (Join-Path $repoRoot 'release-manager\git-repository.ps1')

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Komut başarısız oldu (kod $LASTEXITCODE): $FilePath $($Arguments -join ' ')"
    }
}

function Read-AppVersion {
    param([Parameter(Mandatory = $true)][string]$Text)

    $match = [regex]::Match($Text, '(?m)^version\s*=\s*"(?<version>\d+\.\d+\.\d+)"\s*$')
    if (-not $match.Success) {
        throw 'Cargo.toml içinden uygulama sürümü okunamadı.'
    }
    return $match.Groups['version'].Value
}

function Write-Utf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

$cargoPath = Join-Path $repoRoot 'Cargo.toml'
$cargoLockPath = Join-Path $repoRoot 'Cargo.lock'
$pubspecPath = Join-Path $repoRoot 'flutter\pubspec.yaml'
$cargoText = Get-Content -LiteralPath $cargoPath -Raw
$lockText = Get-Content -LiteralPath $cargoLockPath -Raw
$pubspecText = Get-Content -LiteralPath $pubspecPath -Raw
$sourceVersion = Read-AppVersion $cargoText

$pubspecMatch = [regex]::Match($pubspecText, '(?m)^version:\s*(?<version>\d+\.\d+\.\d+)\+(?<build>\d+)\s*$')
if (-not $pubspecMatch.Success -or $pubspecMatch.Groups['version'].Value -ne $sourceVersion) {
    throw "Cargo.toml ve flutter/pubspec.yaml sürümleri eşleşmiyor. Beklenen: $sourceVersion"
}
$sourceBuildNumber = [int]$pubspecMatch.Groups['build'].Value

$lockPattern = '(?m)^(?<prefix>\[\[package\]\]\r?\nname = "rustdesk"\r?\nversion = ")(?<version>[^"]+)'
$lockMatch = [regex]::Match($lockText, $lockPattern)
if (-not $lockMatch.Success -or $lockMatch.Groups['version'].Value -ne $sourceVersion) {
    throw "Cargo.lock içindeki rustdesk sürümü Cargo.toml ile eşleşmiyor. Beklenen: $sourceVersion"
}

$git = Get-Command git -ErrorAction SilentlyContinue
if ($null -eq $git) {
    throw 'Git bulunamadı. Git kurulumunu ve PATH ayarını kontrol edin.'
}
Initialize-ForlanGitRepository -RepositoryRoot $repoRoot -GitPath $git.Source

$branch = (& $git.Source -C $repoRoot branch --show-current).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($branch)) {
    throw 'Yayın için etkin Git dalı bulunamadı.'
}
$upstream = & $git.Source -C $repoRoot rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null
if ($LASTEXITCODE -ne 0 -or ($upstream | Out-String).Trim() -ne "origin/$branch") {
    throw "Etkin dal origin/$branch dalını izlemeli. Git upstream ayarını kontrol edin."
}
$originUrl = (& $git.Source -C $repoRoot remote get-url origin).Trim()
if ($LASTEXITCODE -ne 0 -or $originUrl -notmatch '(?i)github\.com[:/]NaerielElara/ForlanDestek(?:\.git)?$') {
    throw "origin uzak deposu beklenen GitHub deposu değil: $originUrl"
}

$statusLines = & $git.Source -C $repoRoot status --porcelain --untracked-files=all
if ($LASTEXITCODE -ne 0) {
    throw 'Git çalışma ağacının durumu okunamadı.'
}
$dirtyFiles = @($statusLines | Where-Object {
    $path = $_.Substring(3).Trim().Trim('"').Replace('\', '/')
    $path -notmatch '(^|/)dist/' -and
        $path -notmatch '(^|/)(build-portable|build-rust|bridge-codegen|bridge-tools)\.log$'
})
if ($dirtyFiles.Count -gt 0) {
    Write-Host "Release ile birlikte commit edilip GitHub’a gönderilecek kaynak değişiklikleri:" -ForegroundColor Yellow
    $dirtyFiles | ForEach-Object { Write-Host $_ }
}

$gh = Get-Command gh -ErrorAction SilentlyContinue
if ($null -eq $gh) {
    throw 'GitHub CLI (gh) bulunamadı. GitHub CLI kurup bir kez gh auth login çalıştırın.'
}
Invoke-NativeCommand $gh.Source @('auth', 'status', '--hostname', 'github.com')

$remoteRefspec = '+refs/heads/{0}:refs/remotes/origin/{0}' -f $branch
Invoke-NativeCommand $git.Source @('-C', $repoRoot, 'fetch', '--quiet', 'origin', $remoteRefspec)
$revisionCounts = (& $git.Source -C $repoRoot rev-list --left-right --count "origin/$branch...HEAD") -split '\s+'
if ($LASTEXITCODE -ne 0 -or $revisionCounts.Count -ne 2) {
    throw 'Yerel dalın GitHub dalıyla durumu belirlenemedi.'
}
$commitsBehind = [int]$revisionCounts[0]
$commitsAhead = [int]$revisionCounts[1]
if ($commitsBehind -gt 0) {
    throw ('GitHub deposundaki {0} dalı bu bilgisayardaki kaynaklardan daha yeni. Release öncesinde Araçlar sekmesindeki kaynak çekme düğmesine basıp tekrar deneyin.' -f $branch)
}
if ($commitsAhead -gt 0) {
    if ($WhatIfPreference) {
        Write-Host 'Ön kontrolde yerel commitlerin push adımı atlandı.' -ForegroundColor DarkCyan
    } else {
        Write-Host "Daha önce oluşturulmuş yerel commitler release sırasında GitHub’a gönderilecek." -ForegroundColor Cyan
    }
}

if ($commitsAhead -eq 0) {
    $baseCommit = (& $git.Source -C $repoRoot rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($baseCommit)) {
        throw 'Yayınlanacak Git commit bilgisi okunamadı.'
    }
    $remoteBaseCommit = & $gh.Source api "repos/$repository/commits/$baseCommit" --jq '.sha'
    if ($LASTEXITCODE -ne 0 -or $remoteBaseCommit.Trim() -ne $baseCommit) {
        throw 'Kaynak commit GitHub deposunda bulunamadı.'
    }
}

$latestJson = & $gh.Source release view --repo $repository --json tagName
if ($LASTEXITCODE -ne 0) {
    throw 'GitHub üzerindeki en son release okunamadı.'
}
$latestRelease = $latestJson | ConvertFrom-Json
$latestTag = [string]$latestRelease.tagName
if ($latestTag -notmatch '^\d+\.\d+\.\d+$') {
    throw "En son GitHub release etiketi beklenen biçimde değil: $latestTag"
}
$latestVersion = [Version]::Parse($latestTag)
$currentVersion = [Version]::Parse($sourceVersion)
$versionComparison = $currentVersion.CompareTo($latestVersion)

if ($versionComparison -lt 0) {
    throw "Kaynak sürüm ($sourceVersion), GitHub'daki son sürümden ($latestTag) eski. Önce kaynağı güncelleyin."
}

if ($VersionMode -eq 'Manual') {
    if ($ManualVersion -notmatch '^\d+\.\d+\.\d+$') {
        throw 'Elle sürüm seçimi için 1.2.3 biçiminde bir sürüm girin.'
    }
    $manualVersionValue = [Version]::Parse($ManualVersion)
    if ($manualVersionValue -le $latestVersion -or $manualVersionValue -lt $currentVersion) {
        throw "Elle girilen sürüm son yayından ($latestTag) büyük ve kaynak sürümle ($sourceVersion) aynı veya daha yeni olmalı."
    }
    $releaseVersion = $manualVersionValue.ToString(3)
} elseif ($versionComparison -gt 0) {
    $releaseVersion = $sourceVersion
    Write-Host "Yayımlanmamış sürüm bulundu; $releaseVersion kullanılacak." -ForegroundColor Cyan
} else {
    switch ($VersionMode) {
        'Patch' { $releaseVersion = '{0}.{1}.{2}' -f $currentVersion.Major, $currentVersion.Minor, ($currentVersion.Build + 1) }
        'Major' { $releaseVersion = '{0}.0.0' -f ($currentVersion.Major + 1) }
        default { $releaseVersion = '{0}.{1}.0' -f $currentVersion.Major, ($currentVersion.Minor + 1) }
    }
}
$releaseBuildNumber = if ($releaseVersion -eq $sourceVersion) { $sourceBuildNumber } else { $sourceBuildNumber + 1 }
Write-Host "Release sürümü: $sourceVersion -> $releaseVersion (Flutter build $releaseBuildNumber)" -ForegroundColor Cyan

$releaseNotesPath = Join-Path $repoRoot "release-notes\$releaseVersion.md"
$manualNotes = ''
if ($NotesFile) {
    if (-not (Test-Path -LiteralPath $NotesFile -PathType Leaf)) {
        throw "Yayın notu dosyası bulunamadı: $NotesFile"
    }
    $manualNotes = [System.IO.File]::ReadAllText($NotesFile, [System.Text.Encoding]::UTF8).Trim()
} elseif (Test-Path -LiteralPath $releaseNotesPath -PathType Leaf) {
    $manualNotes = [System.IO.File]::ReadAllText($releaseNotesPath, [System.Text.Encoding]::UTF8).Trim()
}
if ($SkipGeneratedNotes -and [string]::IsNullOrWhiteSpace($manualNotes)) {
    throw 'Otomatik notlar kapalı; yayınlamak için özel yayın notu yazın.'
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $existingReleaseOutput = @(& $gh.Source release view $releaseVersion --repo $repository --json tagName 2>&1)
    $existingReleaseExitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $previousErrorActionPreference
}
if ($existingReleaseExitCode -eq 0) {
    throw "$releaseVersion sürümü için GitHub Release zaten var."
}
$existingReleaseError = ($existingReleaseOutput | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
if ($existingReleaseError -notmatch '(?i)(release not found|HTTP\s+404|status\s+404)') {
    throw "GitHub Release durumu kontrol edilemedi: $existingReleaseError"
}
$remoteTag = & $git.Source -C $repoRoot ls-remote --tags "https://github.com/$repository.git" "refs/tags/$releaseVersion" "refs/tags/$releaseVersion^{}"
if ($LASTEXITCODE -ne 0) {
    throw 'GitHub sürüm etiketi kontrol edilemedi.'
}
if ($remoteTag) {
    throw "$releaseVersion etiketi GitHub deposunda zaten var ancak Release bulunamadı. Etiketi kontrol edip sonra yeniden deneyin."
}

if (-not $PSCmdlet.ShouldProcess("Forlan Destek $releaseVersion", 'Sürümü güncelle, build al ve GitHub Release yayımla')) {
    return
}

$versionChanged = $releaseVersion -ne $sourceVersion
if ($versionChanged) {
    $cargoPattern = '(?m)^version\s*=\s*"\d+\.\d+\.\d+"\s*$'
    $updatedCargo = [regex]::Replace($cargoText, $cargoPattern, "version = `"$releaseVersion`"", 1)
    if ($updatedCargo -eq $cargoText) {
        throw 'Cargo.toml sürümü güncellenemedi.'
    }
    $updatedLock = [regex]::Replace(
        $lockText,
        $lockPattern,
        ('${prefix}' + $releaseVersion),
        1
    )
    if ($updatedLock -eq $lockText) {
        throw 'Cargo.lock sürümü güncellenemedi.'
    }
    $updatedPubspec = [regex]::Replace(
        $pubspecText,
        '(?m)^version:\s*\d+\.\d+\.\d+\+\d+\s*$',
        "version: $releaseVersion+$releaseBuildNumber",
        1
    )
    if ($updatedPubspec -eq $pubspecText) {
        throw 'Flutter build sürümü güncellenemedi.'
    }

    Write-Utf8File $cargoPath $updatedCargo
    Write-Utf8File $cargoLockPath $updatedLock
    Write-Utf8File $pubspecPath $updatedPubspec
}

$versionCommitCreated = $false
$releasePushCompleted = $false
try {
    $buildScript = Join-Path $repoRoot 'build-portable.ps1'
    $powershell = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if ($null -eq $powershell) {
        throw 'Windows PowerShell bulunamadı; portable build başlatılamadı.'
    }
    & $powershell.Source -NoLogo -NoProfile -ExecutionPolicy Bypass -File $buildScript -NoPause -SkipReleaseManager
    if ($LASTEXITCODE -ne 0) {
        throw "Portable build başarısız oldu (kod $LASTEXITCODE)."
    }

    $artifactPath = Join-Path $repoRoot "dist\ForlanDestek-$releaseVersion-portable.exe"
    if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf) -or
        (Get-Item -LiteralPath $artifactPath).Length -eq 0) {
        throw "Sürüme ait portable dosya bulunamadı veya boş: $artifactPath"
    }

    $releaseChanges = @((& $git.Source -C $repoRoot status --porcelain --untracked-files=all) | Where-Object {
        $path = $_.Substring(3).Trim().Trim('"').Replace('\', '/')
        $path -notmatch '(^|/)dist/' -and
            $path -notmatch '(^|/)(build-portable|build-rust|bridge-codegen|bridge-tools)\.log$'
    })
    if ($LASTEXITCODE -ne 0) {
        throw 'Release kaynak değişikliklerinin durumu okunamadı.'
    }
    if ($releaseChanges.Count -gt 0) {
        Invoke-NativeCommand $git.Source @(
            '-C', $repoRoot, 'add', '--all', '--', '.',
            ':(exclude)dist', ':(exclude)dist/**',
            ':(exclude)build-portable.log', ':(exclude)build-rust.log',
            ':(exclude)bridge-codegen.log', ':(exclude)bridge-tools.log'
        )
        $stagedPaths = @(& $git.Source -C $repoRoot diff --cached --name-only)
        if ($LASTEXITCODE -ne 0) {
            throw 'Release commit edilecek kaynak dosyaları belirlenemedi.'
        }
        $generatedStagedPaths = @($stagedPaths | Where-Object {
            $path = $_.Replace('\', '/')
            $path -match '(^|/)dist(/|$)' -or
                $path -match '(^|/)(build-portable|build-rust|bridge-codegen|bridge-tools)\.log$'
        })
        if ($generatedStagedPaths.Count -gt 0) {
            throw "Release çıktısı veya günlüğü Git index'inde staged durumda. Önce bunları unstaged yapın:`n$($generatedStagedPaths -join "`n")"
        }
        $stagedChanges = $stagedPaths
        if ($stagedChanges.Count -gt 0) {
            Set-ForlanGitCommitIdentity -GitPath $git.Source -RepositoryRoot $repoRoot -GitHubCliPath $gh.Source
            Write-Host "Kaynak değişiklikleri $releaseVersion release commitine ekleniyor..." -ForegroundColor Cyan
            Invoke-NativeCommand $git.Source @('-C', $repoRoot, 'commit', '-m', "Release Forlan Destek $releaseVersion")
            $versionCommitCreated = $true
            Invoke-NativeCommand $gh.Source @('auth', 'setup-git', '--hostname', 'github.com')
            Invoke-NativeCommand $git.Source @('-C', $repoRoot, 'push', 'origin', $branch)
            $releasePushCompleted = $true
        }
    }

    if ($commitsAhead -gt 0 -and -not $releasePushCompleted) {
        Invoke-NativeCommand $gh.Source @('auth', 'setup-git', '--hostname', 'github.com')
        Invoke-NativeCommand $git.Source @('-C', $repoRoot, 'push', 'origin', $branch)
        $releasePushCompleted = $true
    }

    $releaseCommit = (& $git.Source -C $repoRoot rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($releaseCommit)) {
        throw 'Release kaynak commit bilgisi okunamadı.'
    }
    $remoteReleaseCommit = & $gh.Source api "repos/$repository/commits/$releaseCommit" --jq '.sha'
    if ($LASTEXITCODE -ne 0 -or $remoteReleaseCommit.Trim() -ne $releaseCommit) {
        throw 'Sürüm commit GitHub deposuna gönderilemedi. Git push sonucunu kontrol edin.'
    }

    $releaseArguments = @(
        'release', 'create', $releaseVersion, $artifactPath,
        '--repo', $repository,
        '--title', "Forlan Destek $releaseVersion",
        '--target', $releaseCommit,
        '--latest'
    )
    if (-not $SkipGeneratedNotes) {
        $releaseArguments += @('--generate-notes', '--notes-start-tag', $latestTag)
    }
    if (-not [string]::IsNullOrWhiteSpace($manualNotes)) {
        $releaseArguments += @('--notes', $manualNotes)
    }
    Invoke-NativeCommand $gh.Source $releaseArguments

    $releaseJson = & $gh.Source release view $releaseVersion --repo $repository --json tagName,isDraft,isPrerelease,assets,url
    if ($LASTEXITCODE -ne 0) {
        throw 'Release oluşturuldu ancak GitHub üzerindeki sonuç doğrulanamadı.'
    }
    $release = $releaseJson | ConvertFrom-Json
    $assetName = Split-Path -Leaf $artifactPath
    if ($release.tagName -ne $releaseVersion -or $release.isDraft -or $release.isPrerelease -or
        -not ($release.assets | Where-Object { $_.name -eq $assetName })) {
        throw 'Release oluşturuldu ancak etiket, yayın durumu veya portable dosya doğrulanamadı.'
    }

    Write-Host "Release hazır: $($release.url)" -ForegroundColor Green
    Write-Host "Yüklenen dosya: $assetName" -ForegroundColor Green
} catch {
    if ($versionChanged -and -not $versionCommitCreated) {
        & $git.Source -C $repoRoot reset -- Cargo.toml Cargo.lock flutter/pubspec.yaml *> $null
        Write-Utf8File $cargoPath $cargoText
        Write-Utf8File $cargoLockPath $lockText
        Write-Utf8File $pubspecPath $pubspecText
    }
    throw
}
