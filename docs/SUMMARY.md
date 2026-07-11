# summary.md — /docs

## Propósito
Fonte única da verdade (Single Source of Truth). Diagramas, prompts mestres, históricos de backfill, relatórios de auditoria, documentação arquitetural e registro do modelo forecast.

## Stack
Markdown, Mermaid (diagramas), PNG (diagramas exportados).

## Regras de Ouro
1. **Fonte Única**: qualquer decisão arquitetural relevante DEVE estar documentada aqui. Se não está em /docs, não aconteceu.
2. **Prompts Mestres**: `PROMPT_AUDITORIA_ENRIQUECIMENTO.md` contém o prompt de engenharia reversa. `plano_micro_motores.md` contém o plano dos micro-motores.
3. **Histórico**: `HISTORICO_MELHORIAS_BACKFILL.md` rastreia todas as mudanças no pipeline de backfill.
4. **Diagramas**: `dw-ceasa.png`, `dw-ceasa-full.png` — modelos dimensionais. `fase2_arquitetura_autocura.md` — arquitetura de auto-cura.

## Conteúdo
- `PROMPT_AUDITORIA_ENRIQUECIMENTO.md` — prompt mestre de auditoria
- `plano_micro_motores.md` — plano original dos micro-motores
- `fase2_arquitetura_autocura.md` — arquitetura de auto-cura e fallback
- `HISTORICO_MELHORIAS_BACKFILL.md` — changelog de backfill
- `quero_comprar_plano_tecnico.md` — plano técnico geral
- `AUDITORIA_BANCO_FRONTEND.md` — auditoria banco + frontend
- `scripts/` — scripts de diagnóstico e exportação
- `README.md` — visão geral do projeto

## Forecast Baseline (adicionado Fase 26)
- `database/26_forecast_baseline.sql` — migration que cria `mart.sazonalidade_baseline` (moda status_cor 2024-2025), adiciona `is_forecast` à `sazonalidade_produto`, recria MV V13 com `is_forecast` e `id_localidade`
- `database/scripts/calcular_baseline.py` — lê dados reais 2024-2025, calcula moda + confiança, popula baseline (~16k combinações)
- `database/scripts/projetar_2026.py` — para cada mês futuro de 2026 sem dado real, insere forecast com `is_forecast=true` (~11.6k linhas)
- `database/scripts/backfill_2024.py` — backfill dos 12 meses de 2024 no mart (420 linhas)
- `database/scripts/validar_forecast.py` — validação automatizada (matriz densidade, gaps, regressão, confiança, MV)
- `pipeline/scraper/persistence.py` — `executar_ciclo_medalhao` agora recalcula baseline + forecast + MV refresh após cada carga
- `frontend/src/components/ProductCard.tsx` — badge `📊 Estimativa` com tooltip de confiança para dados forecast
- `backend/app/schemas/responses.py` — `is_forecast: bool` e `confianca_baseline: float | None` no schema da API
