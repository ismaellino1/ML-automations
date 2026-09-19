$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot

Write-Host "== Verificação do handoff =="

$required = @(
    "00_START_HERE\00_MASTER_PROMPT_CLAUDE.md",
    "00_START_HERE\01_PRODUCT_VISION_AND_DOMAIN_REQUIREMENTS.md",
    "00_START_HERE\02_CURRENT_STATE_AND_TRUST_ORDER.md",
    "01_CURRENT_IMPLEMENTATION\ML_AUTOMACOES_PROD_FINAL_LUNA\supabase\migrations\043_prod_job_queue.sql",
    "01_CURRENT_IMPLEMENTATION\v3_reference\01_CORE_UNIVERSAL_V3_CANONICAL.json"
)
foreach ($r in $required) {
    $p = Join-Path $Root $r
    if (-not (Test-Path $p)) { throw "Faltando: $r" }
    Write-Host "OK $r"
}

$schema = Join-Path $Root "05_USER_ADDITIONS\current_schema\staging_schema.sql"
if (Test-Path $schema) { Write-Host "OK staging_schema.sql incluído" -ForegroundColor Green }
else { Write-Warning "staging_schema.sql ainda não incluído" }

$secrets = Get-ChildItem $Root -Recurse -File | Where-Object {
    $_.Name -match '^(\.env|data\.sql|.*service.?role.*|.*secret.*|.*token.*|.*credentials?.*)$' -and $_.Name -ne '.env.example'
}
if ($secrets) {
    Write-Host "REVISAR possíveis secrets:" -ForegroundColor Red
    $secrets | ForEach-Object { Write-Host $_.FullName -ForegroundColor Red }
} else {
    Write-Host "OK nenhum arquivo óbvio de secret/data dump encontrado." -ForegroundColor Green
}
