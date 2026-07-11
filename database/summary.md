# summary.md — /database (Pomar e Triagem)

## Propósito
DDLs, migrações e schemas do banco PostgreSQL. Arquitetura Medalhão adaptada: `raw` (bronze) → `staging` (prata) → `mart` (ouro). A Landing Zone (`raw.coleta_bruta`) engole inserts na velocidade máxima — sem FKs, sem constraints de domínio.

## Stack
- PostgreSQL 16+, PL/pgSQL, asyncpg, gen_random_uuid()
- DDL idempotente (`CREATE TABLE IF NOT EXISTS`, `DO $$` blocks)

## Regras de Ouro
1. **Landing Zone sem Barreiras**: `raw.coleta_bruta` PROIBIDA de ter FKs, UNIQUE compostas ou CHECKs de domínio. Apenas UUID PK, JSONB, TIMESTAMP, VARCHAR.
2. **Idempotência**: todo script DDL deve ser reexecutável (`IF NOT EXISTS`, `OR REPLACE`).
3. **Quarentena**: rejeições vão para `ops.quarentena_coleta` com raw_id + motivo_falha — nada se perde.
4. **Staging com UPSERT**: `fact_precos_mensais` usa `ON CONFLICT` para atualizar preços sem duplicar.
5. **Dimensões**: `dim_produto` e `dim_localidade` com resolução via `ON CONFLICT DO UPDATE`.
6. **Janela Temporal**: toda view/function/query deve filtrar por ano/mês entre 2024-01 e 2026-12.
7. **Índices Essenciais**: `raw.coleta_bruta (processado) WHERE processado = FALSE` — sem indexação excessiva.
8. **Forecast é fallback condicional**: dados com `is_forecast = FALSE` (reais) NUNCA são sobrescritos por forecast. `ON CONFLICT DO NOTHING`.

## Novidades — Forecast Baseline (Fase 26)
- `mart.sazonalidade_baseline` — tabela de moda do `status_cor` por `(id_produto, id_localidade, mes)`, calculada sobre dados reais de 2024-2025. ~16k combinações únicas.
- `is_forecast BOOLEAN NOT NULL DEFAULT FALSE` — coluna adicionada a `mart.sazonalidade_produto` para distinguir dado real (FALSE) de projeção histórica (TRUE).
- MV V13 `vw_api_produtos_sazonalidade` — expõe `is_forecast`, `id_localidade` para JOIN com baseline. Ordena reais primeiro.
- O baseline é calculado em Python (não SP) porque envolve moda estatística sobre múltiplos anos.

## Scripts Python (database/scripts/)
- `backfill_2024.py` — insere dados de 2024 no mart replicando a lógica de classificação da SP V9
- `calcular_baseline.py` — lê dados reais 2024-2025, calcula moda do status_cor e confiança, popula `sazonalidade_baseline`
- `projetar_2026.py` — para cada mês futuro de 2026 sem dado real, insere forecast com `is_forecast=true`
- `validar_forecast.py` — validação automatizada (matriz densidade, gaps, sem regressão, confiança, MV)

## Mapa Rápido
- `01_ddl_medalhao.sql` — DDL fundacional (schemas, dim, fact, views, triggers, roles)
- `01_elt_landing_zone.sql` — Landing Zone ELT: `raw.coleta_bruta` + `ops.quarentena_coleta`
- `08_data_hygiene.sql` — rotinas de limpeza e VACUUM
- `10_zscore_classificacao_produtos.sql` — classificação estatística de preços
- `23_time_series_mart.sql` — materialização do mart de séries temporais
- `24_predictive_schema.sql` — schema preditivo (modelo ML)
- `25_fix_mv_missing_columns.sql` — hotfix: adiciona colunas faltantes na MV
- `26_forecast_baseline.sql` — DDL baseline + is_forecast + MV V13 + permissões
