param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Pull', 'CommitPush')]
    [string]$Action,
    [string]$CommitMessage
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$git = Get-Command git -ErrorAction SilentlyContinue
if ($null -eq $git) {
    throw 'Git bulunamadı. Git kurulumu ve PATH ayarını kontrol edin.'
}
. (Join-Path $PSScriptRoot 'git-repository.ps1')
Initialize-ForlanGitRepository -RepositoryRoot $repoRoot -GitPath $git.Source

function Invoke-Git {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    & $git.Source -C $repoRoot @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Git komutu başarısız oldu (kod $LASTEXITCODE): git $($Arguments -join ' ')"
    }
}

$gitRoot = & $git.Source -C $repoRoot rev-parse --show-toplevel
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($gitRoot | Out-String))) {
    throw 'Kaynak klasörü için Git bağlantısı hazırlanamadı.'
}
$normalizedRoot = [System.IO.Path]::GetFullPath($repoRoot).TrimEnd('\')
$normalizedGitRoot = [System.IO.Path]::GetFullPath(($gitRoot | Out-String).Trim()).TrimEnd('\')
if (-not $normalizedRoot.Equals($normalizedGitRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Kaynak klasörü Git deposunun kökü değil: $normalizedGitRoot"
}
$repository = 'NaerielElara/ForlanDestek'
$originUrl = (& $git.Source -C $repoRoot remote get-url origin).Trim()
if ($LASTEXITCODE -ne 0 -or $originUrl -notmatch ("(?i)github\.com[:/]" + [regex]::Escape($repository) + '(?:\.git)?$')) {
    throw "origin uzak deposu beklenen GitHub deposu değil: $originUrl"
}
$branch = (& $git.Source -C $repoRoot branch --show-current).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($branch)) {
    throw 'Etkin Git dalı bulunamadı.'
}
$upstream = & $git.Source -C $repoRoot rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null
if ($LASTEXITCODE -ne 0 -or ($upstream | Out-String).Trim() -ne "origin/$branch") {
    throw "Etkin dal origin/$branch dalını izlemeli. Git upstream ayarını kontrol edin."
}

if ($Action -eq 'Pull') {
    Write-Host 'GitHub üzerindeki kaynaklar fast-forward yöntemiyle alınıyor...' -ForegroundColor Cyan
    Invoke-Git @('pull', '--ff-only')
    Write-Host 'Kaynak kod güncellendi.' -ForegroundColor Green
    return
}

if ([string]::IsNullOrWhiteSpace($CommitMessage)) {
    throw 'Commit mesajı boş olamaz.'
}
$statusLines = & $git.Source -C $repoRoot status --short --untracked-files=all
if ($LASTEXITCODE -ne 0) {
    throw 'Git çalışma ağacının durumu okunamadı.'
}
if (-not $statusLines) {
    throw 'Commit edilecek kaynak değişikliği yok.'
}
$gh = Get-Command gh -ErrorAction SilentlyContinue
if ($null -eq $gh) {
    throw 'GitHub CLI (gh) bulunamadı. GitHub CLI kurup bir kez gh auth login çalıştırın.'
}
& $gh.Source auth status --hostname github.com
if ($LASTEXITCODE -ne 0) {
    throw 'GitHub CLI oturumu açık değil. Önce GitHub / Git girişini ayarlayın.'
}
& $gh.Source auth setup-git --hostname github.com
if ($LASTEXITCODE -ne 0) {
    throw 'GitHub CLI, Git kimlik doğrulamasını ayarlayamadı.'
}
Set-ForlanGitCommitIdentity -GitPath $git.Source -RepositoryRoot $repoRoot -GitHubCliPath $gh.Source
Write-Host 'Commit edilecek dosyalar:' -ForegroundColor Cyan
$statusLines | ForEach-Object { Write-Host $_ }
Invoke-Git @('add', '-A')
Invoke-Git @('commit', '-m', $CommitMessage)
Invoke-Git @('push', 'origin', $branch)
Write-Host "Kaynak değişiklikleri GitHub'a gönderildi." -ForegroundColor Green
