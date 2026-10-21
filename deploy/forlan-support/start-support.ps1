param()

$ErrorActionPreference = 'Stop'
$composeFile = Join-Path $PSScriptRoot 'compose.yaml'
$envFile = Join-Path $PSScriptRoot '.env'
$accessFile = Join-Path $PSScriptRoot 'admin-access.txt'
$caFile = Join-Path $PSScriptRoot 'support-ca.crt'
$utf8 = New-Object System.Text.UTF8Encoding($false)

function New-SupportSecret {
    $bytes = New-Object byte[] 48
    $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $generator.GetBytes($bytes) } finally { $generator.Dispose() }
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Protect-SupportFile([string]$Path) {
    $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    & icacls $Path /inheritance:r /grant:r "*${sid}:(F)" '*S-1-5-18:(F)' '*S-1-5-32-544:(F)' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Dosya izinleri ayarlanamadi: $Path" }
}

if (-not (Test-Path -LiteralPath $envFile)) {
    $adminPassword = New-SupportSecret
    $settings = @(
        'FORLAN_SUPPORT_HOST=95.70.196.174',
        "FORLAN_DB_PASSWORD=$(New-SupportSecret)",
        "FORLAN_JWT_SECRET=$(New-SupportSecret)",
        'FORLAN_BOOTSTRAP_ADMIN_USERNAME=forlanadmin',
        "FORLAN_BOOTSTRAP_ADMIN_PASSWORD=$adminPassword",
        'FORLAN_TOKEN_TTL_HOURS=12'
    )
    [System.IO.File]::WriteAllLines($envFile, $settings, $utf8)
    Protect-SupportFile $envFile
    $access = @(
        'Forlan Destek - Yerel yonetici paneli',
        'Adres: http://127.0.0.1:18080/admin/',
        'Kullanici adi: forlanadmin',
        "Parola: $adminPassword",
        '',
        'Bu dosya yonetici erisimi saglar. Paylasmayin; guvenli bir yerde saklayin.'
    )
    [System.IO.File]::WriteAllLines($accessFile, $access, $utf8)
    Protect-SupportFile $accessFile
}

Write-Host 'Forlan destek ve lisans sunucusu baslatiliyor...'
& docker compose --env-file $envFile -f $composeFile up -d --build --wait --wait-timeout 120
if ($LASTEXITCODE -ne 0) { throw 'Destek sunucusu baslatilamadi. Docker compose logs ile ayrintilari kontrol edin.' }

$health = Invoke-RestMethod -Uri 'http://127.0.0.1:18080/healthz' -TimeoutSec 10
if ($health.status -ne 'ok') { throw 'Destek API saglik kontrolu basarisiz.' }

& docker cp 'forlan-support-proxy:/data/caddy/pki/authorities/local/root.crt' $caFile
if ($LASTEXITCODE -ne 0) { throw 'Uygulama icin sunucu sertifikasi alinamadi.' }

$settings = [System.IO.File]::ReadAllLines($envFile)
$bootstrapUsername = $settings | Where-Object { $_.StartsWith('FORLAN_BOOTSTRAP_ADMIN_USERNAME=') }
$bootstrapPassword = $settings | Where-Object { $_.StartsWith('FORLAN_BOOTSTRAP_ADMIN_PASSWORD=') }
if ($bootstrapUsername -and $bootstrapPassword) {
    $body = @{
        username = $bootstrapUsername.Substring('FORLAN_BOOTSTRAP_ADMIN_USERNAME='.Length)
        password = $bootstrapPassword.Substring('FORLAN_BOOTSTRAP_ADMIN_PASSWORD='.Length)
    } | ConvertTo-Json
    $login = Invoke-RestMethod -Uri 'http://127.0.0.1:18080/api/auth/login' -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 10
    if ($login.account.role -ne 'admin') { throw 'Ilk yonetici hesabi dogrulanamadi.' }
    $remaining = $settings | Where-Object { -not $_.StartsWith('FORLAN_BOOTSTRAP_ADMIN_') }
    [System.IO.File]::WriteAllLines($envFile, $remaining, $utf8)
    & docker compose --env-file $envFile -f $composeFile up -d --no-deps --force-recreate --wait --wait-timeout 120 support-api
    if ($LASTEXITCODE -ne 0) { throw 'Destek API yeniden baslatilamadi.' }
}

Write-Host 'Yonetici paneli hazir: http://127.0.0.1:18080/admin/'
if (Test-Path -LiteralPath $accessFile) { Write-Host "Giris bilgileri: $accessFile" }
