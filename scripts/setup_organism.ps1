#Requires -Version 7.0

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot

Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║       ORGANISMO AUTÔNOMO — SETUP                ║" -ForegroundColor Cyan
Write-Host "║       Scraping Heavy Worker                     ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# ── 1. Instalar dependências Python ──
Write-Host "[1/4] Instalando dependências Python..." -ForegroundColor Yellow
pip install -r "$ProjectRoot\pipeline\requirements.txt"
if ($LASTEXITCODE -ne 0) { throw "pip install falhou" }

# ── 2. Baixar binários furtivos ──
Write-Host "[2/4] Baixando binários furtivos..." -ForegroundColor Yellow

Write-Host "  → patchright install chromium" -ForegroundColor Gray
patchright install chromium
if ($LASTEXITCODE -ne 0) { throw "patchright install chromium falhou" }

Write-Host "  → camoufox fetch" -ForegroundColor Gray
camoufox fetch
if ($LASTEXITCODE -ne 0) { throw "camoufox fetch falhou" }

Write-Host "  → seleniumbase install chromedriver" -ForegroundColor Gray
seleniumbase install chromedriver
if ($LASTEXITCODE -ne 0) { throw "seleniumbase install chromedriver falhou" }

# ── 3. Baixar modelo NLP ──
Write-Host "[3/4] Baixando modelo SpaCy pt_core_news_lg (~500 MB)..." -ForegroundColor Yellow
python -m spacy download pt_core_news_lg
if ($LASTEXITCODE -ne 0) { throw "Spacy download falhou" }

# ── 4. Conclusão ──
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║       ✅ SETUP CONCLUÍDO COM SUCESSO             ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "Para subir o FlareSolverr (necessário para desafios Cloudflare):" -ForegroundColor White
Write-Host "────────────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "docker run -d \`" -ForegroundColor Cyan
Write-Host "  --name=flaresolverr \`" -ForegroundColor Cyan
Write-Host "  -p 8191:8191 \`" -ForegroundColor Cyan
Write-Host "  -e LOG_LEVEL=info \`" -ForegroundColor Cyan
Write-Host "  --restart=unless-stopped \`" -ForegroundColor Cyan
Write-Host "  ghcr.io/flaresolverr/flaresolverr:latest" -ForegroundColor Cyan
Write-Host "────────────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Organismo pronto para ser inicializado!" -ForegroundColor Green
