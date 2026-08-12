# summary.md — /query_DBA (Kit de Monitoramento do Banco Local)

> 📦 **Repositório (2026-08-07):** `PedroEvangelista063/Sazo_repo` — renomeado de `Quero_Comprar_ext` (a URL antiga redireciona).

## Propósito

Kit de queries e scripts **read-only** para o DBA monitorar o PostgreSQL local (`localhost:5432/quero_comprar`). Validadas contra o banco real em 2026-08-06 — seguras para rodar a qualquer momento.

## Regras de Ouro

1. **Read-Only**: nenhum `INSERT`/`UPDATE`/`DELETE`/`DROP` — todas as queries são de leitura.
2. **Sem Secrets**: nenhuma senha versionada; o script `conectar_dba.sh` lê as credenciais de `backend/.env` (gitignored).
3. **Janela Temporal**: a janela canônica é 2024-01 a 2026-12.
4. **DDL via Migrations**: para alterações, usar as migrations de `database/` — nunca SQL avulso em produção.

## Estrutura

| Arquivo                                                                                               | O que responde                                                                         |
| ----------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| `01_health_visao_geral.sql`                                                                           | 🩺 Banco saudável? Contagens por camada (raw → staging → mart → ops) + período coberto |
| `02_cargas_etl.sql`                                                                                   | 🚚 Cargas ETL acontecendo? Últimas coletas, status, erros                              |
| `03_qualidade_dados.sql`                                                                              | 🔍 Gaps por produto/localidade, órfãos, duplicatas, produtos sem coleta                |
| `04_sazonalidade.sql`                                                                                 | 🟢🟡🔴 Distribuição de status, forecast, transparência de dados históricos             |
| `05_audit_observabilidade.sql`                                                                        | 🕵️ Auditoria: mudanças de status, quarentena, erros DDL                                |
| `06_performance_conexoes.sql`                                                                         | ⚡ Conexões ativas, locks, queries pesadas em execução                                 |
| ~~`07_migrations.sql`~~ — removido em `8f7ea7de` (dependia de `supabase_migrations`, legado Supabase) | Versão/estado da MV: validar via `04_sazonalidade.sql` ou a query de V23 acima         |
| `08_mapa_fluxos.sql`                                                                                  | 🗺️ Mapa regional, fluxos de abastecimento e relatório por UF                           |
| `09_volatilidade_forecast.sql`                                                                        | 📊 Limiares Z-Score ±1σ, baselines, confiança e tipo de dado                           |
| `conectar_dba.sh`                                                                                     | 🔌 Conexão segura (lê `backend/.env`, não expõe senha)                                 |
| `LEIA_ME.md`                                                                                          | 📖 Esquema medalhão, tabelas-chave e dicas de uso                                      |

## Uso

```bash
./conectar_dba.sh "SELECT version();"          # query direta
./conectar_dba.sh -f 01_health_visao_geral.sql # arquivo inteiro
```

## Mudanças Recentes (2026-08-12)

- **Migration 80 (V23) APLICADA** em LOCAL e AIVEN (2026-08-12) — piso 2023+ ativo (0 âncoras `ano_referencia < 2023`; `min(ano_referencia)` set–dez 2026 = 2023; MV 177.485).
- ⚠️ **Marcador antigo do V23 quebrado**: `position('YEAR FROM CURRENT_DATE' in definition)` retorna 0 mesmo com V23 aplicada (deparser normaliza para `EXTRACT(year FROM CURRENT_DATE)` — case-sensitive). **Validar por funcional**: `SELECT count(*) ... WHERE tipo_dado='FALLBACK_DIMENSAO' AND ano_referencia < 2023` → 0. Ver `docs/runbook_migration_80_local.md` §5.

## Mudanças Recentes (2026-08-11)

O kit foi validado contra o banco em 2026-08-06 e **continua válido para monitorar o estado atual**. Estado real validado em 2026-08-11 (LOCAL e REMOTO/Aiven idênticos):

- **MV `mart.vw_api_produtos_sazonalidade` aplicada = V22** (Deep Fallback da migration `78` — definição contém `DEEP_FALLBACK`/`PROJECAO_HISTORICA`) com **177.485 linhas** (pós quality-gate 76).
- **Migration 79 aplicada** — `fn_br_nacional_sazonalidade` com `p_limit`/`p_offset` (paginação push-down, FASE 78) e referenciando `FALLBACK_DIMENSAO` (inclui projeção, P1-1) em local + remoto.
- **Migration 80 (V23, janela 2023+) COMMITADA mas NÃO aplicada** — a definição real da MV NÃO contém o piso `YEAR FROM CURRENT_DATE` (`AND h.ano >= EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER - 3`). Aplicação pendente: rodar o DDL + `REFRESH MATERIALIZED VIEW` via psql (padrão da FASE 78: DDL só, refresh posterior).
- **Quality gates antes do fallback**: `74` (12 meses), `75` (restaura `sazonalidade_baseline`) e `76` (completude de série, MV V21 — 358 produtos).

**Para validar o estado atual com o kit:**

```bash
bash conectar_dba.sh -f 01_health_visao_geral.sql  # contagens por camada (esperado MV 177.485)
bash conectar_dba.sh -f 04_sazonalidade.sql        # distribuição de status + tipo_dado
bash conectar_dba.sh -f 03_qualidade_dados.sql     # órfãos/duplicatas pós-expurgo

# Checar se a migration 80 (V23) já foi aplicada (esperado: 0 → pendente):
bash conectar_dba.sh "SELECT position('YEAR FROM CURRENT_DATE' in definition) AS v23_piso FROM pg_matviews WHERE matviewname='vw_api_produtos_sazonalidade'"
```

## Números de Referência (2026-08-06)

| Camada  | Tabela                        | Registros |
| ------- | ----------------------------- | --------- |
| RAW     | `raw.coleta_bruta`            | 20        |
| RAW     | `raw.controle_carga`          | 5         |
| STAGING | `staging.fact_precos_mensais` | 266.773   |
| STAGING | `staging.dim_produto`         | 2.869     |
| STAGING | `staging.dim_localidade`      | 623       |
| MART    | `mart.sazonalidade_produto`   | 364.383   |
| OPS     | `ops.audit_logs`              | 318.620   |
| OPS     | `ops.quarentena_coleta`       | 9         |

> ⚠️ Números pré-expurgo (migration 71 removeu ~627 produtos sem preço de `dim_produto`) e pré-quality-gate 76. Pós-expurgo + V21: MV com **177.485 linhas / 358 produtos**; após o Deep Fallback (V22/V23) a grade de meses futuros volta preenchida (ex.: 9.055 linhas FALLBACK projetadas em m9-12). Contagens atuais em `database/summary.md`.

## Mapa Rápido

- `README.md` — índice + instruções rápidas
- `LEIA_ME.md` — guia do banco medalhão (RAW/STAGING/MART/OPS + tabelas-chave)
- `conectar_dba.sh` — conexão via `backend/.env` (sem expor senha)
- Queries 01-09 organizadas por tema de monitoramento (health, ETL, qualidade, sazonalidade, audit, performance, migrations, fluxos, volatilidade)
