# 🗄️ QUERY DBA — Kit de Monitoramento do Banco Local

> **Para o gestor de banco de dados acompanhar tudo o que acontece no PostgreSQL local** (`localhost:5432/quero_comprar`).
> Queries validadas contra o banco real em 2026-08-06 — read-only, seguras para rodar a qualquer momento.

## 📌 Índice

| #   | Arquivo                                                        | O que responde                                                                                |
| --- | -------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| 1   | [`01_health_visao_geral.sql`](01_health_visao_geral.sql)       | 🩺 O banco está saudável? Contagens por camada (raw → staging → mart → ops) + período coberto |
| 2   | [`02_cargas_etl.sql`](02_cargas_etl.sql)                       | 🚚 As cargas ETL estão acontecendo? Últimas coletas, status, erros                            |
| 3   | [`03_qualidade_dados.sql`](03_qualidade_dados.sql)             | 🔍 Gaps por produto/localidade, órfãos, duplicatas, produtos sem coleta                       |
| 4   | [`04_sazonalidade.sql`](04_sazonalidade.sql)                   | 🟢🟡🔴 Distribuição de status, forecast, transparência de dados históricos                    |
| 5   | [`05_audit_observabilidade.sql`](05_audit_observabilidade.sql) | 🕵️ Auditoria: mudanças de status, quarentena, erros DDL                                       |
| 6   | [`06_performance_conexoes.sql`](06_performance_conexoes.sql)   | ⚡ Conexões ativas, locks, queries pesadas em execução                                        |
| 7   | [`07_migrations.sql`](07_migrations.sql)                       | 📜 Migrations aplicadas, objetos por schema, funções/views materializadas                     |
| 8   | [`08_mapa_fluxos.sql`](08_mapa_fluxos.sql)                     | 🗺️ Mapa regional, fluxos de abastecimento e relatório por UF                                  |
| 9   | [`09_volatilidade_forecast.sql`](09_volatilidade_forecast.sql) | 📊 Limiares Z-Score ±1σ, baselines, confiança e tipo de dado                                  |
| 10  | [`conectar_dba.sh`](conectar_dba.sh)                           | 🔌 Script de conexão segura (lê `backend/.env`, não expõe senha)                              |
| 11  | [`LEIA_ME.md`](LEIA_ME.md)                                     | 📖 Explicação do esquema medalhão, tabelas-chave e dicas de uso                               |

---

## 🚀 Como usar (rápido)

```bash
# 1. Conexão direta via script (lê DATABASE_URL_PRIMARY do backend/.env)
./conectar_dba.sh "SELECT version();"

# 2. Rodar um arquivo de queries inteiro
./conectar_dba.sh -f 01_health_visao_geral.sql

# 3. Manual
psql -h localhost -U postgres -d quero_comprar
```

> ⚠️ **Segurança:** nenhuma senha está versionada nesta pasta. O script `conectar_dba.sh` lê as credenciais de `backend/.env` (gitignored). Todas as queries são **read-only** — nenhum `INSERT`/`UPDATE`/`DELETE`/`DROP`.

---

## 🗺️ Mapa do Banco (resumo)

```
RAW (carga crua)          STAGING (limpo)           MART (consumo)
raw.coleta_bruta ─────▶   staging.dim_produto ──▶   mart.sazonalidade_produto
raw.controle_carga        staging.dim_localidade    mart.dim_produto_canonico
raw.precos_uf             staging.fact_precos_mensais   mart.sazonalidade_baseline_*
raw.precos_municipio      staging.precos_rejeitados     mart.vw_api_produtos_sazonalidade (MV)
                          staging.confianca_baseline    mart.vw_anchor_sazonalidade
                          staging.dim_fluxo_abastecimento  mart.vw_mapa_regional_completo

OPS (observabilidade)
ops.audit_logs · ops.vw_ultimas_mudancas_status · ops.quarentena_coleta · ops.controle_erros_ddl · ops.config_agente

Views/Funções úteis (08/09):
staging.vw_fluxos_regionais · staging.fn_relatorio_mapa_regional(p_uf) ·
staging.fn_estatisticas_volatilidade_24m() · staging.fn_status_cor_zscore(preco, ref, desvio)
```

**Números de referência (2026-08-06):**

| Camada  | Tabela                              | Registros |
| ------- | ----------------------------------- | --------- |
| RAW     | `raw.coleta_bruta`                  | 20        |
| RAW     | `raw.controle_carga`                | 5         |
| STAGING | `staging.fact_precos_mensais`       | 266.773   |
| STAGING | `staging.dim_produto`               | 2.869     |
| STAGING | `staging.dim_localidade`            | 623       |
| MART    | `mart.sazonalidade_produto`         | 364.383   |
| OPS     | `ops.audit_logs`                    | 318.620   |
| OPS     | `ops.quarentena_coleta`             | 9         |
| MV      | `mart.vw_api_produtos_sazonalidade` | —         |

---

## 📁 Estrutura da pasta

```
query_DBA/
├── README.md                 ← você está aqui (índice)
├── LEIA_ME.md                ← esquema medalhão + tabelas-chave + dicas
├── conectar_dba.sh           ← conexão segura via backend/.env
├── 01_health_visao_geral.sql
├── 02_cargas_etl.sql
├── 03_qualidade_dados.sql
├── 04_sazonalidade.sql
├── 05_audit_observabilidade.sql
├── 06_performance_conexoes.sql
├── 07_migrations.sql
├── 08_mapa_fluxos.sql
└── 09_volatilidade_forecast.sql
```

---

**Feito para o DBA do Quero Comprar — dados abertos, transparência total.** 🥑
