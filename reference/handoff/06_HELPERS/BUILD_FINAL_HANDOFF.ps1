param(
    [string]$SchemaPath = "",
    [string]$LegacyMigrationsDirectory = "",
    [string]$OutputZip = ""
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($SchemaPath)) {
    $Candidates = @(
        "$env:USERPROFILE\Desktop\ML_AUTOMACOES_PROD_FINAL_LUNA\backup_pre_prod_final_2026-09-18\schema.sql",
        "$env:USERPROFILE\Desktop\backup_pre_prod_final_2026-09-18\schema.sql"
    )
    foreach ($c in $Candidates) {
        if (Test-Path $c) { $SchemaPath = $c; break }
    }
}

if (-not [string]::IsNullOrWhiteSpace($SchemaPath)) {
    if (-not (Test-Path $SchemaPath)) { throw "SchemaPath não existe: $SchemaPath" }
    $schemaDest = Join-Path $Root "05_USER_ADDITIONS\current_schema\staging_schema.sql"
    Copy-Item $SchemaPath $schemaDest -Force
    Write-Host "OK schema -> $schemaDest"
} else {
    Write-Warning "schema.sql não foi encontrado automaticamente. O ZIP ainda pode ser criado, mas a auditoria fica mais forte com o schema real."
}

if (-not [string]::IsNullOrWhiteSpace($LegacyMigrationsDirectory)) {
    if (-not (Test-Path $LegacyMigrationsDirectory)) { throw "LegacyMigrationsDirectory não existe: $LegacyMigrationsDirectory" }
    $dest = Join-Path $Root "05_USER_ADDITIONS\exact_migrations_001_042_if_available"
    Get-ChildItem $LegacyMigrationsDirectory -File -Filter "*.sql" |
        Where-Object { $_.Name -match '^(00[1-9]|0[1-3][0-9]|04[0-2])' } |
        ForEach-Object { Copy-Item $_.FullName (Join-Path $dest $_.Name) -Force }
    Write-Host "OK migrations 001-042 encontradas foram copiadas."
}

# Bloqueios óbvios: não compactar secrets/dumps de dados por engano.
$Forbidden = Get-ChildItem $Root -Recurse -File | Where-Object {
    $_.Name -match '^(\.env|data\.sql|.*service.?role.*|.*secret.*|.*token.*|.*credentials?.*)$' -and $_.Name -ne '.env.example'
}
if ($Forbidden) {
    Write-Host "Arquivos potencialmente sensíveis encontrados:" -ForegroundColor Red
    $Forbidden | ForEach-Object { Write-Host " - $($_.FullName)" -ForegroundColor Red }
    throw "Remova/revise arquivos sensíveis antes de gerar o handoff."
}

if ([string]::IsNullOrWhiteSpace($OutputZip)) {
    $OutputZip = Join-Path (Split-Path -Parent $Root) "ML_CLAUDE_MASTER_HANDOFF_FINAL.zip"
}

if (Test-Path $OutputZip) { Remove-Item $OutputZip -Force }
Compress-Archive -Path (Join-Path $Root '*') -DestinationPath $OutputZip -CompressionLevel Optimal
Write-Host "ZIP criado: $OutputZip" -ForegroundColor Green
