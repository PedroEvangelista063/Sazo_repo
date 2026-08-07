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

| Arquivo                        | O que responde                                                                         |
| ------------------------------ | -------------------------------------------------------------------------------------- |
| `01_health_visao_geral.sql`    | 🩺 Banco saudável? Contagens por camada (raw → staging → mart → ops) + período coberto |
| `02_cargas_etl.sql`            | 🚚 Cargas ETL acontecendo? Últimas coletas, status, erros                              |
| `03_qualidade_dados.sql`       | 🔍 Gaps por produto/localidade, órfãos, duplicatas, produtos sem coleta                |
| `04_sazonalidade.sql`          | 🟢🟡🔴 Distribuição de status, forecast, transparência de dados históricos             |
| `05_audit_observabilidade.sql` | 🕵️ Auditoria: mudanças de status, quarentena, erros DDL                                |
| `06_performance_conexoes.sql`  | ⚡ Conexões ativas, locks, queries pesadas em execução                                 |
| `07_migrations.sql`            | 📜 Migrations aplicadas, objetos por schema, funções/views materializadas              |
| `08_mapa_fluxos.sql`           | 🗺️ Mapa regional, fluxos de abastecimento e relatório por UF                           |
| `09_volatilidade_forecast.sql` | 📊 Limiares Z-Score ±1σ, baselines, confiança e tipo de dado                           |
| `conectar_dba.sh`              | 🔌 Conexão segura (lê `backend/.env`, não expõe senha)                                 |
| `LEIA_ME.md`                   | 📖 Esquema medalhão, tabelas-chave e dicas de uso                                      |

## Uso

```bash
./conectar_dba.sh "SELECT version();"          # query direta
./conectar_dba.sh -f 01_health_visao_geral.sql # arquivo inteiro
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

> ⚠️ Baseline pré-expurgo da migration 71 (que remove ~627 produtos sem preço da `dim_produto`) — ver `database/summary.md` para o pós-expurgo.

## Mapa Rápido

- `README.md` — índice + instruções rápidas
- `LEIA_ME.md` — guia do banco medalhão (RAW/STAGING/MART/OPS + tabelas-chave)
- `conectar_dba.sh` — conexão via `backend/.env` (sem expor senha)
- Queries 01-09 organizadas por tema de monitoramento (health, ETL, qualidade, sazonalidade, audit, performance, migrations, fluxos, volatilidade)
