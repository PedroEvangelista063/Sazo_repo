#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "╔══════════════════════════════════════════════════╗"
echo "║       ORGANISMO AUTÔNOMO — SETUP                ║"
echo "║       Scraping Heavy Worker                     ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# ── 1. Instalar dependências Python ──
echo "[1/4] Instalando dependências Python..."
pip install -r "$PROJECT_ROOT/pipeline/requirements.txt"

# ── 2. Baixar binários furtivos ──
echo "[2/4] Baixando binários furtivos..."

echo "  → patchright install chromium"
patchright install chromium

echo "  → camoufox fetch"
camoufox fetch

echo "  → seleniumbase install chromedriver"
seleniumbase install chromedriver

# ── 3. Baixar modelo NLP ──
echo "[3/4] Baixando modelo SpaCy pt_core_news_lg (~500 MB)..."
python -m spacy download pt_core_news_lg

# ── 4. Conclusão ──
echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║       ✅ SETUP CONCLUÍDO COM SUCESSO             ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "Para subir o FlareSolverr (necessário para desafios Cloudflare):"
echo "────────────────────────────────────────────────────"
echo "docker run -d \\"
echo "  --name=flaresolverr \\"
echo "  -p 8191:8191 \\"
echo "  -e LOG_LEVEL=info \\"
echo "  --restart=unless-stopped \\"
echo "  ghcr.io/flaresolverr/flaresolverr:latest"
echo "────────────────────────────────────────────────────"
echo ""
echo "Organismo pronto para ser inicializado!"
