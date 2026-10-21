function Invoke-ForlanGit {
    param(
        [Parameter(Mandatory = $true)][string]$GitPath,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $GitPath -C $RepositoryRoot @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    $text = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "Git komutu başarısız oldu (kod $exitCode): git $($Arguments -join ' ')`n$text"
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $text }
}

function Initialize-ForlanGitRepository {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$GitPath
    )

    $RepositoryRoot = [System.IO.Path]::GetFullPath($RepositoryRoot)
    if (-not (Test-Path -LiteralPath (Join-Path $RepositoryRoot 'Cargo.toml') -PathType Leaf)) {
        throw "Forlan kaynak klasörü bulunamadı: $RepositoryRoot"
    }

    $repositoryUrl = 'https://github.com/NaerielElara/ForlanDestek.git'
    $probe = Invoke-ForlanGit $GitPath $RepositoryRoot @('rev-parse', '--show-toplevel') -AllowFailure
    $gitDirectory = Join-Path $RepositoryRoot '.git'
    $initializedHere = $false

    if ($probe.ExitCode -eq 0) {
        $gitRoot = [System.IO.Path]::GetFullPath($probe.Output.Trim()).TrimEnd('\')
        $normalizedRoot = $RepositoryRoot.TrimEnd('\')
        if (-not $gitRoot.Equals($normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Seçilen klasör Git deposunun kökü değil: $gitRoot"
        }
        $head = Invoke-ForlanGit $GitPath $RepositoryRoot @('rev-parse', '--verify', 'HEAD') -AllowFailure
        if ($head.ExitCode -ne 0) {
            $origin = Invoke-ForlanGit $GitPath $RepositoryRoot @('remote', 'get-url', 'origin') -AllowFailure
            if ($origin.ExitCode -eq 0 -and $origin.Output.Trim() -notmatch '(?i)github\.com[:/]NaerielElara/ForlanDestek(?:\.git)?$') {
                throw "Başlatılmış Git deposu farklı bir origin kullanıyor; değiştirilmedi: $($origin.Output.Trim())"
            }
            $initializedHere = $true
        }
    } else {
        if (Test-Path -LiteralPath $gitDirectory) {
            throw "Git metadata'sı var ancak okunamıyor; değiştirilmedi: $gitDirectory"
        }
        $null = Invoke-ForlanGit $GitPath $RepositoryRoot @('init', '--quiet')
        $initializedHere = $true
    }

    if (-not $initializedHere) {
        return
    }

    Write-Host 'GitHub kaynak bağlantısı otomatik hazırlanıyor; kaynak dosyaları korunacak...' -ForegroundColor Cyan
    $headInfo = Invoke-ForlanGit $GitPath $RepositoryRoot @('ls-remote', '--symref', $repositoryUrl, 'HEAD')
    $branchMatch = [regex]::Match($headInfo.Output, '(?m)^ref: refs/heads/(?<branch>[^\s]+)\s+HEAD\s*$')
    if (-not $branchMatch.Success) {
        throw 'GitHub deposunun varsayılan dalı belirlenemedi.'
    }
    $branch = $branchMatch.Groups['branch'].Value

    $origin = Invoke-ForlanGit $GitPath $RepositoryRoot @('remote', 'get-url', 'origin') -AllowFailure
    if ($origin.ExitCode -eq 0) {
        if ($origin.Output.Trim() -notmatch '(?i)github\.com[:/]NaerielElara/ForlanDestek(?:\.git)?$') {
            throw "origin uzak deposu beklenen GitHub deposu değil: $($origin.Output.Trim())"
        }
    } else {
        $null = Invoke-ForlanGit $GitPath $RepositoryRoot @('remote', 'add', 'origin', $repositoryUrl)
    }

    $null = Invoke-ForlanGit $GitPath $RepositoryRoot @('symbolic-ref', 'HEAD', "refs/heads/$branch")
    $refspec = '+refs/heads/{0}:refs/remotes/origin/{0}' -f $branch
    $null = Invoke-ForlanGit $GitPath $RepositoryRoot @('fetch', '--quiet', 'origin', $refspec)
    $null = Invoke-ForlanGit $GitPath $RepositoryRoot @('reset', '--mixed', "refs/remotes/origin/$branch")
    $null = Invoke-ForlanGit $GitPath $RepositoryRoot @('branch', '--set-upstream-to', "origin/$branch", $branch)
    $null = Invoke-ForlanGit $GitPath $RepositoryRoot @('config', 'core.longpaths', 'true')
    Write-Host "Git deposu hazırlandı: $branch. Kaynak dosyalarına dokunulmadı." -ForegroundColor Green
}

function Set-ForlanGitCommitIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$GitPath,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$GitHubCliPath
    )

    $name = Invoke-ForlanGit $GitPath $RepositoryRoot @('config', '--get', 'user.name') -AllowFailure
    $email = Invoke-ForlanGit $GitPath $RepositoryRoot @('config', '--get', 'user.email') -AllowFailure
    if ($name.ExitCode -eq 0 -and $email.ExitCode -eq 0 -and
        -not [string]::IsNullOrWhiteSpace($name.Output) -and
        -not [string]::IsNullOrWhiteSpace($email.Output)) {
        return
    }

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $githubIdentity = & $GitHubCliPath api user --jq '.login + "|" + (.id | tostring)'
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    $identityMatch = [regex]::Match(($githubIdentity | Out-String).Trim(), '^(?<login>[^|]+)\|(?<id>\d+)$')
    if ($exitCode -ne 0 -or -not $identityMatch.Success) {
        throw 'Git commit kimliği GitHub hesabından alınamadı.'
    }

    if ($name.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($name.Output)) {
        $null = Invoke-ForlanGit $GitPath $RepositoryRoot @('config', '--local', 'user.name', $identityMatch.Groups['login'].Value)
    }
    if ($email.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($email.Output)) {
        $noreplyEmail = '{0}+{1}@users.noreply.github.com' -f $identityMatch.Groups['id'].Value, $identityMatch.Groups['login'].Value
        $null = Invoke-ForlanGit $GitPath $RepositoryRoot @('config', '--local', 'user.email', $noreplyEmail)
    }
}
