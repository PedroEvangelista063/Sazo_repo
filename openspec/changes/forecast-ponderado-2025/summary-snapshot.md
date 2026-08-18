# Summary.md Snapshot — 2026-07-17 (atualizado)

> Captura automática dos 6 summary.md do projeto + progresso da migração Supabase.

---

## SUPABASE MIGRATION — Progresso (2026-07-17)

### Fase 0: Backup Local ✅

- `backup_quero_comprar_pre_migracao.dump` (2.48 MB)
- `backup_quero_comprar_ddl.sql` (23.69 MB)

### Fase 1: Projeto Supabase ✅

- Projeto: **Sazo Brasil** (ref: kxsqrcccaaxplpktmutl)
- Host: db.kxsqrcccaaxplpktmutl.supabase.co
- PostgreSQL 17.6.1.127, região us-east-1

### Fase 2: Schema Migration ✅

- 12 migrações aplicadas via `supabase db push --linked`
- 21 tabelas criadas (raw: 4, staging: 9, mart: 3, ops: 4)
- 3 functions, 2 procedures, 1 MV
- Roles: role_etl_writer, role_api_reader

### Fase 3: Data Migration (em andamento)

- **Restaurados:** dim_produto (857), dim_localidade (850), dim_categoria (11), fact_precos_mensais (39.358), precos_rejeitados (87)
- **Pendentes:** sazonalidade_produto (~62K), baselines (56K), raw._, ops._
- **Schema fixes:** colunas NOT NULL removidas, colunas extras adicionadas
- **Comando que funciona:** `npx supabase db query --linked --file "arquivo.sql"`
- **DNS:** `db.kxsqrcccaaxplpktmutl.supabase.co` não resolve nesta máquina - usar CLI

### Connection Options Recomendadas

- Direct (5432): para tudo (ETL, migrações, CLI)
- Transaction Pooler (6543): apenas FastAPI com `statement_cache_size=0`
- User pooler: `postgres.{project_ref}`

---

## CONFIG/summary.md

Centralização de JSONs de roteamento, matriz de fontes, regiões e configurações.

**Arquivos principais:**

- `sources_matrix.json` — matriz oficial de 24+ fontes em 4 categorias
- `sources.json` — legado, manter para compatibilidade
- `sources_map.json` — mapeamento produto → fontes regionais (CONAB + CEASAs)
- `regions.json` — 5 regiões brasileiras com UFs e polos CEASA
- `flows.json` — **104 fluxos de abastecimento entre UFs (v2.0)**. Todas as 27 UFs como origem E destino. Estrutura: `{id, item, categoria, origem_uf, origem_polo, destino_uf, destino_regiao_id, meses, sazonalidade, preco_referencial, cor_indicadora, tipo("exportado"/"importado"), ano_referencia}`. Consumido por `BrasilMap.tsx`.

**Conexões com Forecast:** baseline calculado 100% em PostgreSQL via `sp_calcular_forecast_2026()`. Janela temporal: 2024-2026.

---

## DATABASE/summary.md

DDLs, migrações e schemas do PostgreSQL. Arquitetura Medalhão: `raw` → `staging` → `mart`.

**Stack:** PostgreSQL 16+, PL/pgSQL, asyncpg, gen_random_uuid()

**Volumes Atuais:**

| Camada  | Tabela                              | Registros                              |
| ------- | ----------------------------------- | -------------------------------------- |
| RAW     | `raw.coleta_bruta`                  | 15                                     |
| STAGING | `staging.fact_precos_mensais`       | 27.545                                 |
| STAGING | `staging.dim_produto`               | 831                                    |
| STAGING | `staging.dim_localidade`            | 850                                    |
| MART    | `mart.sazonalidade_produto`         | 65.830 (30.964 real + 34.866 forecast) |
| MART    | `mart.sazonalidade_baseline_24_25`  | 23.449 (moda 2024-2025, fallback)      |
| MART    | `mart.sazonalidade_baseline_25_26`  | 32.581 (moda 2025-2026, primária)      |
| MV      | `mart.vw_api_produtos_sazonalidade` | 54.479                                 |

**Forecast v2 (100% SQL, Jul/2026):**

- `sp_calcular_forecast_2026()` — Moda ponderada de duas baselines
- **Duas baselines permanentes:**
  - `baseline_25_26` — primária: moda sobre dados reais 2025-2026 (~19 meses). 32.581 linhas
  - `baseline_24_25` — fallback: moda sobre 2024-2025, confiança reduzida à metade. 23.449 linhas
- **CTE `baseline_ponderado`**: FULL JOIN + CASE weighting
  - primary (25_26) vence quando confianca >= 30
  - fallback (24_25 * 0.5) usado quando primary não existe ou confiança < 30
- **Método:** `beta_weighted_25_24` para TODAS as projeções
- **Colunas rastreabilidade:** `is_forecast`, `baseline_confianca`, `forecast_method`
- **Resultado:** 19.933 projeções Ago-Dez 2026 em 1.02s, 12.884 reais intactos

**Migrações Chave:** 27 (hotfix weighting), 28 (recalibração baseline), 29 (focus 2025-2026), 30 (engine preditiva v2 ponderado, 538 linhas), 32 (funções regionais)

---

## FRONTEND/summary.md

App React PWA (offline-first, mobile-first). Interface de cores para preços de hortifrúti.

**Stack:** React 19, Vite + PWA, TailwindCSS 3, shadcn/ui, Framer Motion, React Bits, Three.js, Zustand 5, TanStack Query v5

**3 Modos de Visualização:**

- **Cards** — grid de ProductCard com SpotlightCard + semáforo
- **Mapa Regional** — BrasilMap (27 dots SVG) + RegiaoPanel
- **Grade Sazonal** — SazonalidadeNacional grid

**Mapa Regional:**

- `BrasilMap.tsx` — 27 círculos SVG, duas camadas de interação (legenda região + dot UF)
- Arcos **azuis** (recebe de) e **verdes** (envia para) com animação path drawing
- `RegiaoPanel.tsx` — painel "Recebe de"/"Envia para" baseado em flows.json (104 fluxos)

**BRNationalIcon:** bandeira BR + 5 frutas orbitando, substitui dropdown nos modos Grade/Mapa

**Forecast Badge:** 📊 Estimativa com tooltip confiança

**Testes:** Vitest + React Testing Library

---

## BACKEND/summary.md

API HTTP assíncrona (FastAPI) que serve o frontend B2C. Consulta apenas views materializadas.

**Stack:** Python 3.13+, FastAPI, Pydantic v2, asyncpg, httpx

**Forecast:** `is_forecast: bool`, `confianca_baseline: float | None`, `tendencia_futura: str | None`

**Rotas:**

- `GET /api/v1/sazonalidade` — snapshot + filtro regional `?regiao=`
- `GET /api/v1/sazonalidade/{uf}/{municipio}` — por localidade
- `GET /api/v1/sazonalidade/historico/{ano}/{mes}` — série temporal
- `GET /api/v1/regioes` — 5 regiões com UFs e polos CEASA

---

## PIPELINE/summary.md

Pipeline de coleta ELT (Scrape Now, Parse Later). Micro-motores burros e focados.

**Stack:** Python 3.13+, Polars, Playwright, HTTPX, asyncio, curl-cffi, patchright

**Ciclo Medalhão (2 passos):**

1. SortingEngine — raw → staging
2. `sp_executar_carga_completa()` — pipeline completo em uma SP

**Forecast migrado para SQL** (SP `sp_calcular_forecast_2026()`). Scripts Python legados mantidos para uso standalone.

**Orquestrador:** `AutonomousOrchestrator.coletar_global(competencia)` — dispatch único para todas as UFs

---

## UTILITIES/summary.md

Ferramentas CLI autônomas para diagnóstico, auditoria, validação E2E.

**Scripts principais:**

- `_check_db.py` — verifica conexão e estado do banco
- `_check_pos_scraping.py` — valida dados pós-coleta
- `audit_full.py` — auditoria completa
- `validate_e2e.py` — teste end-to-end
- `database/scripts/validar_forecast.py` — validação do modelo forecast (matriz densidade, gaps, regressão, confiança, MV)
