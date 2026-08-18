# 📖 LEIA_ME — Guia do Banco Local (para o DBA)

## 1. O que é este banco

O Sazo Brasil usa um **PostgreSQL local** em `localhost:5432/quero_comprar` como fonte primária de desenvolvimento (o remoto Aiven/Supabase é fallback). Aqui ficam **os dados reais de sazonalidade** de hortifrúti — coletados do CONAB e CEASAs.

## 2. Arquitetura Medalhão

O banco é organizado em 4 camadas (como uma casa):

| Camada                       | Schemas   | Papel                                         | Quem escreve                            |
| ---------------------------- | --------- | --------------------------------------------- | --------------------------------------- |
| 🚗 **RAW** (cru)             | `raw`     | Landing Zone: dados crus sem validação        | Pipeline (scrapers)                     |
| 🔧 **STAGING** (limpo)       | `staging` | Dados limpos, tipados, com dimensões e UPSERT | Pipeline (SortingEngine)                |
| 👑 **MART** (ouro)           | `mart`    | Sazonalidade pronta para consumo              | Pipeline (`sp_executar_carga_completa`) |
| 🔍 **OPS** (observabilidade) | `ops`     | Auditoria, quarentena, erros DDL              | Triggers + pipeline                     |

> **Regra de ouro:** a API lê **somente** o `mart` (views materializadas e funções `fn_*`). Nunca `raw` nem `staging`.

## 3. Tabelas-chave

### RAW — onde os dados chegam

- **`raw.coleta_bruta`** — payloads crus recebidos dos scrapers (JSONB). `processado = FALSE` indica coleta não processada (alerta).
- **`raw.controle_carga`** — log de execuções do pipeline: tipo, status, linhas lidas/inseridas, erro.
- **`raw.precos_uf` / `raw.precos_municipio`** — cargas históricas de PreçosMensalUF/Município.

### STAGING — dados limpos

- **`staging.dim_produto`** — produtos (2.869 registros). **`staging.dim_localidade`** — UFs e municípios (623).
- **`staging.fact_precos_mensais`** — **fato principal**: preço médio por produto × localidade × mês (~266 mil registros).
- **`staging.precos_rejeitados`** — linhas que falharam na carga (quarentena interna).

### MART — consumo

- **`mart.sazonalidade_produto`** — **tabela central**: status semáforo por produto × local × mês (~364 mil). Colunas de transparência: `is_forecast`, `tipo_dado`, `ano_referencia`, `baseline_confianca`, `tendencia_futura` + limiares Z-Score (`desvio_padrao_historico`, `limite_superior`, `limite_inferior` — migration 65).
- **`mart.dim_produto_canonico`** — MDM: unifica variantes de nome ("Batata Doce" = "Batata-Doce") sob um mestre.
- **`mart.vw_api_produtos_sazonalidade`** — **Materialized View** que a API consulta. Se estiver vazia/desatualizada, o app não mostra dados.
- **`mart.sazonalidade_baseline_24_25` / `25_26`** — moda do status_cor por produto/local/mês (fallback e primária).
- **`mart.vw_anchor_sazonalidade`** — dado exibido por **ano de referência** (N → N-1 → N-2): coração da transparência temporal.
- **`mart.vw_mapa_regional_completo`** — mapa regional consolidado (produtos × fluxos × tipo de preço por UF).

### Views e Funções de apoio (arquivos 08 e 09)

- **`staging.vw_fluxos_regionais`** — visão amigável dos fluxos de abastecimento (165-166) com `descricao_tipo` (🟢 Envia / 🔴 Recebe / 🟡 Produção local) e `regiao_destino_nome`.
- **`staging.dim_fluxo_abastecimento`** — dimensão crua dos fluxos (origem/destino, meses, tipo, ano_referencia).
- **`staging.fn_relatorio_mapa_regional(p_uf)`** — relatório consolidado por UF; `NULL` = nacional.
- **`staging.fn_estatisticas_volatilidade_24m()`** — AVG/STDDEV por produto/local nos últimos 24 meses reais (base do semáforo ±1σ).
- **`staging.fn_status_cor_zscore(preco, referencia, desvio)`** — semáforo dinâmico (VERDE/AMARELO/VERMELHO).
- **`staging.confianca_baseline`** — score 0-100 de confiabilidade por produto/localidade (meses reais vs interpolados).
- **`staging.precos_rejeitados`** — anomalias barradas pelo trigger `trg_valida_anomalia_preco` (com `razao`).

### OPS — observabilidade

- **`ops.audit_logs`** — toda mudança de status (semáforo) registrada com trigger (~318 mil).
- **`ops.vw_ultimas_mudancas_status`** — view pronta com nomes de produto/UF/município (migration 000014) — dispensa joins manuais.
- **`ops.quarentena_coleta`** — payloads rejeitados com motivo (parse_failed, b2c_filter, validation_error).
- **`ops.controle_erros_ddl`** — falhas de execução de migrations.

## 4. Sinais de alerta (checklist do DBA)

| Sintoma                       | Query para verificar                                                                   |
| ----------------------------- | -------------------------------------------------------------------------------------- |
| App sem dados                 | `01_health_visao_geral.sql` (1.1) — MV vazia?                                          |
| Coletas paradas               | `02_cargas_etl.sql` (2.3/2.4) — sem coleta recente? `processado = FALSE`?              |
| Carga com erro                | `02_cargas_etl.sql` (2.1/2.5) — status `falha`? quarentena crescendo?                  |
| Dados desatualizados          | `01_health_visao_geral.sql` (1.4) — último mês real antigo?                            |
| Semáforo distorcido           | `04_sazonalidade.sql` (4.1) — mar de AMARELO?                                          |
| Mudanças estranhas            | `05_audit_observabilidade.sql` (5.1b — view pronta) — picos de reclassificação?        |
| Banco lento                   | `06_performance_conexoes.sql` (6.2/6.3) — queries longas? locks?                       |
| Migrations pendentes          | `07_migrations.sql` (7.1) — versões faltando?                                          |
| Semáforo "grudado" no AMARELO | `09_volatilidade_forecast.sql` (9.4) — % sem estatística de desvio (limiar degenerado) |
| Fluxos do mapa errados        | `08_mapa_fluxos.sql` (8.4/8.5) — contagem por tipo vs `config/flows.json`              |
| Mapa regional sem dados       | `08_mapa_fluxos.sql` (8.1/8.2) — UF sem tipo_preco real?                               |
| RLS quebrado                  | `07_migrations.sql` (7.8/7.9) — políticas e RLS ativo por tabela                       |

## 5. Dicas de uso

```bash
# Conectar e ver tudo de uma vez
./conectar_dba.sh -f 01_health_visao_geral.sql

# Monitorar a última carga ETL
./conectar_dba.sh -f 02_cargas_etl.sql

# Flag importante: dados reais vs forecast
#   is_forecast = TRUE  → projeção (badge 📊 Estimativa no app)
#   is_forecast = FALSE → dado real coletado
```

## 6. Segurança e boas práticas

- 🔒 **Nunca** commitar senha em arquivos versionados — credenciais ficam em `backend/.env` (gitignored).
- 📖 Todas as queries desta pasta são **read-only** — seguras para rodar.
- 🧪 Para executar alterações (DDL), use as migrations de `database/` — nunca SQL avulso em produção.
- 📊 A janela temporal canônica é **2024-01 a 2026-12**.

---

**Banco local: `localhost:5432/quero_comprar` · PostgreSQL 16/17 · Roles: `postgres` (DBA), `role_api_reader`, `role_etl_writer`**
