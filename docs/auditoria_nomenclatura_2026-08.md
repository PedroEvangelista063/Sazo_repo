# 🏷️ Auditoria de Nomenclatura do Banco — Relatório de Viabilidade

**Repositório:** `quero_comprar_vg` · **Banco:** PostgreSQL 16 local (schema medalhão) · **Data:** 2026-08-11 · **Modo:** Análise + Proposta (nada foi alterado)

---

## 1. Sumário Executivo

| Métrica                                  | Valor                                                                                      |
| ---------------------------------------- | ------------------------------------------------------------------------------------------ |
| Objetos inventariados (relations)        | **35** (34 tabelas/views + 1 MV)                                                           |
| Funções / procedures catalogadas         | **35** (mart 7 · staging 27 · ops 1)                                                       |
| Sequências (auto-renomeiam com a tabela) | 19                                                                                         |
| Índices (auto-renomeiam com a tabela)    | 69                                                                                         |
| **Candidatos a renomear**                | **31** (16 Fase 1 ✅ + 15 Fase 2 ⚠️)                                                       |
| **Objetos congelados** 🔴                | **7** (MV, `mv_refresh_log`, 3 roles, `fact_precos_mensais`, `sp_executar_carga_completa`) |
| Objetos sem `COMMENT ON`                 | **18/35 (51%)**                                                                            |
| `RENAME TO` existentes no histórico      | **Zero** (esta será a 1ª refatoração de nome)                                              |
| Estimativa de esforço total              | **11–15 h** (Fase 1: 2–3 h · Fase 2: 6–8 h · Fase 3: 3–4 h)                                |

### Discrepâncias entre o prompt e o catálogo real (importantes antes de planejar)

1. **`mart.sazonalidade_baseline_24_25` e `_25_26` NÃO existem** — foram consolidadas em `mart.sazonalidade_baseline` (migration `75_restaura_sazonalidade_baseline.sql:49`), que **não tem coluna `ciclo` nem `ano`** (dimensão temporal = `mes` 1–12). O problema de "ano no nome" já foi resolvido; não há o que renomear.
2. **`fn_regioes_listar`, `fn_resumo_regiao` e `rls_auto_enable` não existem nos 5 schemas** — não estão no catálogo local (só citados em docs). O endpoint `GET /regioes` lê `config/regions.json` (`regioes.py:17`), não chama SP.
3. **As procedures `sp_*` vivem em `staging`, não `mart`** — `sp_calcular_sazonalidade`, `sp_calcular_forecast_2026_v13`, `sp_executar_carga_completa`, etc.
4. **Existe duplicata legada**: `sp_calcular_forecast_2026` **e** `sp_calcular_forecast_2026_v13` (ambas em staging) — candidatas a consolidação, não apenas rename.
5. **Terceira role descoberta**: além de `role_etl_writer`/`role_api_reader`, existe **`api_readonly`** (`backend/migrations/012_security_rls_readonly.sql`) — total de 58 arquivos .sql com ~191 linhas de GRANT. **Nunca renomear roles**.
6. **`sp_executar_carga_completa` existe sim** (migration `63:52`, GRANT `63:136`) e é chamada por **6 pipelines**: `scraper/persistence.py:86`, `ingestao_conab.py:1138`, `ingestao_conab_inteligente.py:417`, `load_parquet_to_db.py:300`, `run_bulk_historical_fill.py:847`, `run_scraper_historico.py:326`.

---

## 2. Tabela de Mapeamento Completa

### 🔴 CONGELADOS — não tocar (rename causa crash)

| Objeto                                                 | Motivo                                                    | Referências                                                           |
| ------------------------------------------------------ | --------------------------------------------------------- | --------------------------------------------------------------------- |
| `mart.vw_api_produtos_sazonalidade` (MV)               | REFRESH no startup; 4 refs backend + 7 índices da MV      | `main.py:109`; `produtos.py:351,528,1011,1034`; `ufs.py:12`           |
| `audit.mv_refresh_log`                                 | Criada em runtime; lida no startup e no hot path          | `bootstrap.py:56`; `main.py:115,119`; `produtos.py:151`               |
| `role_etl_writer` / `role_api_reader` / `api_readonly` | Grants em dezenas de objetos; rename = revogação em massa | 58 arquivos .sql, ~191 linhas                                         |
| `staging.fact_precos_mensais`                          | >20 migrations; procedure de carga; vw_mapa               | `relatorio_conab.py:51`; `load_parquet_to_db.py`; `ingestao_conab.py` |
| `staging.sp_executar_carga_completa`                   | Chamada por 6 pipelines em produção                       | 6 call-sites pipeline                                                 |

> Se um dia a MV for renomeada: alvo sugerido `mart.mv_precos_sazonais_b2c`, **apenas** junto com atualização de `main.py`, `produtos.py`, `ufs.py`, `load_parquet_to_db.py:217`, `audit_b2c_export.py:72` e migração de índices.

### ✅ FASE 1 — Seguros (só migrations históricas + docs; zero código vivo)

| Schema  | Tipo       | Nome Atual                              | Nome Proposto                          | Rationale                                                             | Ref. produção           |
| ------- | ---------- | --------------------------------------- | -------------------------------------- | --------------------------------------------------------------------- | ----------------------- |
| raw     | TABELA     | `precos_uf`                             | `preco_conab_uf`                       | Explicitam fonte CONAB e nível geográfico                             | nenhuma                 |
| raw     | TABELA     | `precos_municipio`                      | `preco_conab_municipio`                | idem                                                                  | nenhuma                 |
| staging | TABELA     | `dim_conab_produto_mapping`             | `dim_mapeamento_produto_conab`         | Ordem semântica (o que é → de onde vem)                               | nenhuma                 |
| mart    | TABELA     | `dim_produto_canonico`                  | `produto_canonico`                     | Schema já diz "dimensão"; nome mais curto                             | nenhuma (só migrations) |
| mart    | VIEW       | `vw_anchor_sazonalidade`                | `vw_ancora_preco_referencia`           | pt-BR; descreve o dado (pg_depend: nada depende dela além da própria) | nenhuma                 |
| mart    | VIEW       | `vw_mapa_regional_completo`             | `vw_abastecimento_regional_completo`   | "mapa regional" é genérico; MV não depende dela                       | nenhuma                 |
| staging | FUNÇÃO     | `_parse_conab_price(TEXT)`              | `normalizar_preco_conab(TEXT)`         | Remove underscore Python; ação clara; pt-BR                           | nenhuma                 |
| staging | FUNÇÃO     | `_gerar_batch_id()`                     | `gerar_id_lote()`                      | pt-BR, ação clara                                                     | nenhuma                 |
| staging | FUNÇÃO     | `fn_relatorio_mapa_regional(p_uf TEXT)` | `relatorio_abastecimento_por_uf(TEXT)` | Explica o que mostra                                                  | nenhuma                 |
| staging | FUNÇÃO     | `fn_relatorio_normalizacao()`           | `relatorio_normalizacao_produtos()`    | idem                                                                  | nenhuma                 |
| staging | FUNÇÃO     | `fn_consolidar_produtos_duplicados()`   | `consolidar_produtos_duplicados()`     | Verbos, sem prefixo `fn_`                                             | nenhuma                 |
| staging | FUNÇÃO     | `fn_consolidar_produtos_por_lista()`    | `consolidar_produtos_por_lista()`      | idem                                                                  | nenhuma                 |
| staging | FUNÇÃO     | `fn_injetar_dados_ufs_carentes()`       | `injetar_dados_ufs_carentes()`         | idem                                                                  | nenhuma                 |
| staging | FUNÇÃO     | `fn_calcular_status_cor_por_preco(...)` | `calcular_status_cor_por_preco(...)`   | idem                                                                  | nenhuma                 |
| staging | FUNÇÃO     | `fn_classificar_preco_anomalia(...)`    | `classificar_preco_anomalia(...)`      | idem                                                                  | nenhuma                 |
| staging | TRIGGER FN | `trg_valida_anomalia_preco()`           | `validar_anomalia_preco()`             | Trigger referencia função por OID — rename não quebra o trigger       | nenhuma                 |

### ⚠️ FASE 2 — Requer script/atualização de código

| Schema  | Tipo    | Nome Atual                           | Nome Proposto                   | Rationale                           | O que quebra (ajustar)                                                                                                   |
| ------- | ------- | ------------------------------------ | ------------------------------- | ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| raw     | TABELA  | `coleta_bruta`                       | `entrada_scraper`               | Redundância com schema `raw`        | `admin.py:66,84`; `persistence.py:46`                                                                                    |
| raw     | TABELA  | `controle_carga`                     | `log_ingestao`                  | "controle" ambíguo → "log ingestão" | `ingestao_conab.py:1165`                                                                                                 |
| staging | TABELA  | `baseline_2025_interpolado`          | `baseline_sazonal_interpolado`  | Remove ano hardcoded                | `imputar_gaps_baseline.py:181`                                                                                           |
| staging | TABELA  | `confianca_baseline`                 | `qualidade_cobertura_sazonal`   | "confiança" subjetivo               | `data_healer.py:255`; **não renomear coluna `confianca`** (aliased no backend `produtos.py:319,523,1009` + contrato API) |
| staging | VIEW    | `vw_fluxos_regionais`                | `vw_abastecimento_logistico`    | Mais específico                     | `fluxos.py:28`                                                                                                           |
| staging | FUNÇÃO  | `fn_normalizar_nome_produto`         | `normalizar_nome_produto`       | Prefixo                             | 11 refs (outras funções/triggers)                                                                                        |
| staging | FUNÇÃO  | `fn_estatisticas_volatilidade_24m`   | `estatisticas_volatilidade_24m` | Prefixo                             | 9 refs                                                                                                                   |
| staging | FUNÇÃO  | `fn_status_cor_zscore`               | `calcular_semaforo_preco`       | "semáforo" = negócio; zscore = impl | 7 refs                                                                                                                   |
| staging | FUNÇÃO  | `fn_encontrar_produto_pai`           | `encontrar_produto_pai`         | Prefixo                             | 9 refs                                                                                                                   |
| staging | FUNÇÃO  | `fn_fator_sazonal_mensal`            | `fator_sazonal_mensal`          | Prefixo                             | usada pela cadeia sandwich (51/52/56)                                                                                    |
| staging | FUNÇÃO  | `fn_preco_base_2026`                 | `preco_base_ciclo(p_ano INT)`   | Ano hardcoded                       | usada pela cadeia sandwich                                                                                               |
| staging | FUNÇÃO  | `fn_sandwich_historical_price`       | `preco_sanduiche_historico`     | pt-BR                               | usada pela cadeia sandwich                                                                                               |
| staging | FUNÇÃO  | `fn_status_cor_regra_15` / `_25`     | `status_cor_regra_15` / `_25`   | Prefixo                             | usadas pela cadeia sandwich                                                                                              |
| staging | PROC    | `sp_calcular_sazonalidade`           | `recalcular_sazonalidade()`     | Sem `sp_`; verbo                    | **recriar `sp_executar_carga_completa`** que a chama                                                                     |
| mart    | TABELA  | `fator_kg_produto_uf`                | `fator_conversao_kg_produto_uf` | Autodocumentável                    | **recriar `sp_project_sandwich_prices_2026`** (`56:637,644`)                                                             |
| mart    | TABELA  | `sazonalidade_baseline_ponderada`    | (renomear colunas, ver §3)      | Colunas com ano hardcoded           | só migrations (62)                                                                                                       |
| mart    | FUNÇÕES | `fn_br_nacional_*` / `fn_regional_*` | **manter** (opcional: verbos)   | Baixo retorno × alto risco          | 15 call-sites em `produtos.py`                                                                                           |

### 🟠 FASE 3 — Limpeza (DROP, não rename)

| Objeto                                         | Motivo                                    | Prova                           |
| ---------------------------------------------- | ----------------------------------------- | ------------------------------- |
| `staging.fn_importar_fluxos_json`              | DEPRECATED oficial                        | `summary.md:109`                |
| `staging.fato_cotacao_regional`                | Sem uso real; auditoria loga "não existe" | `audit_hardcode_uf_gaps.py:359` |
| `test_show_timeout`, `test_show_timeout2`      | Órfãs de debug, **0 ocorrências no repo** | catálogo vivo                   |
| `sp_calcular_forecast_2026` (duplicata legada) | Duplicada com `_v13`                      | catálogo + migrations           |
| views de compatibilidade (Fase 1)              | Transitórias 30 dias                      | —                               |

### 🔵 MANTER (nomes já bons) + `COMMENT ON`

`staging.dim_produto`, `dim_localidade`, `dim_categoria`, `mart.sazonalidade_produto`, `mart.sazonalidade_baseline` (nomes padrão Star Schema), `ops.*` (audit/config/backup — nomes ok), `staging.status_fonte_produto` (**sem CREATE TABLE no repo** — renomear quebraria reexecução de migrations 43/47/71/72/74). Cobertura `COMMENT ON` deve ir a 100% em `mart.*` e `staging.*`.

---

## 3. Proposta de Renomeação de Colunas Críticas

> ⚠️ **Atenção chave**: colunas de `mart.sazonalidade_produto` selecionadas pela **MV** (`vw_api_produtos_sazonalidade` REFRESH) ou expostas no **schema Pydantic** exigem redefinição da MV + ajuste de contrato. Só devem ir para **Fase 3**, nunca Fase 1.

### `mart.sazonalidade_produto` (29 colunas)

| Atual                        | Proposto                | Motivo                                       | Risco                       |
| ---------------------------- | ----------------------- | -------------------------------------------- | --------------------------- |
| `preco_medio`                | `preco_calculado`       | Não é só média — algoritmo com LOCF/fallback | ⚠️ MV/API                   |
| `fonte` (`'municipio'/'uf'`) | `granularidade_preco`   | Descreve nível geográfico, não fonte         | ⚠️ MV expõe `fonte`         |
| `is_forecast`                | `e_projecao`            | pt-BR; boolean autodocumentado               | ⚠️ API expõe `is_forecast`  |
| `calculado_em`               | `ultima_atualizacao_em` | Mais claro para DBA                          | ⚠️ API expõe `calculado_em` |
| `indice_sazonalidade`        | `fator_sazonal`         | Conceito de negócio; "índice" genérico       | ✅ não exposto na MV        |
| `variacao_mom_pct`           | manter                  | Descritivo                                   | —                           |

### `staging.fact_precos_mensais` (12 colunas)

| Atual         | Proposto            | Motivo                                         | Risco                                           |
| ------------- | ------------------- | ---------------------------------------------- | ----------------------------------------------- |
| `preco_medio` | `preco_medio_conab` | Explicita a fonte                              | ⚠️ quebra `vw_mapa_regional_completo` (recriar) |
| `loaded_at`   | `carregado_em`      | pt-BR consistente                              | ⚠️ idem                                         |
| `_qualidade`  | `qualidade`         | Prefixo underscore = convenção Python, não SQL | ⚠️ idem                                         |
| `batch_id`    | manter              | Infra/meta — inglês ok                         | —                                               |

### `staging.dim_produto`

| Atual                        | Proposto                | Motivo           | Risco                                                                                |
| ---------------------------- | ----------------------- | ---------------- | ------------------------------------------------------------------------------------ |
| `classificao_produto` (typo) | `classificacao_produto` | Correção de typo | ⚠️⚠️ propagado na MV + `responses.py:260` (contrato API) — Fase 3 com alias Pydantic |

### `mart.sazonalidade_baseline`

| Atual             | Proposto                  | Motivo                                         | Risco                                |
| ----------------- | ------------------------- | ---------------------------------------------- | ------------------------------------ |
| `status_cor_mode` | `status_cor_predominante` | "mode" é estatístico; "predominante" é negócio | ✅ backend só referencia `confianca` |
| `confianca`       | manter                    | Aliased no backend                             | —                                    |

### `mart.sazonalidade_baseline_ponderada`

| Atual                                 | Proposto                                                 | Motivo                                  | Risco            |
| ------------------------------------- | -------------------------------------------------------- | --------------------------------------- | ---------------- |
| `status_cor_2024` / `status_cor_2025` | `status_cor_ciclo_anterior` / `status_cor_ciclo_recente` | Remove ano hardcoded (obsoleto em 2027) | ✅ só migrations |

---

## 4. Script SQL (Fase 1 — objetos ✅ Seguros)

Arquivo: `database/77_refatoracao_nomenclatura_dba_friendly.sql` (draft, ver o arquivo para o script completo).

**Requisitos atendidos:** transacional · idempotente (`IF EXISTS`/`NOT EXISTS`) · views de compat por objeto renomeado · `COMMENT ON` · `RAISE NOTICE` por renomeação · **não toca** MV, roles, `fact_precos_mensais` nem `sp_executar_carga_completa`.

> ⚠️ Nota de segurança: funções SQL renomeadas que forem **chamadas por outras funções SQL** criam dependência em `pg_depend` e o `ALTER FUNCTION` falhará com erro de dependência — se isso ocorrer para algum dos itens acima (ex.: `fn_calcular_status_cor_por_preco` chamada dentro de trigger), recrie o chamador na mesma transação. O script cobre os objetos órfãos; o BLOCO 4 protege contra sobrecarga.

---

## 5. Plano de Migração em 3 Fases

### Fase 1 — Semana 1 (2–3 h) — objetos ✅ Seguros

1. `pg_dump` completo (catálogo + dados) e snapshot `.dump` versionado.
2. Executar `77_refatoracao_nomenclatura_dba_friendly.sql` no banco local; validar `RAISE NOTICE` (16 renames).
3. Verificar: `\dt`, `\df`, `SELECT` nas views de compat, e **`REFRESH MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade`** (prova de que a MV não foi afetada).
4. Rodar `pytest` do backend (se existir) + smoke test `GET /health` e uma query da API.
5. Commit: `refactor(db): renomeia nomenclatura de objetos órfãos (raw/staging/mart)`.

### Fase 2 — Semanas 2–3 (6–8 h) — objetos ⚠️ Requer Script

1. Agendar **por objeto** com janela de deploy; ordem sugerida por menor acoplamento:
   a. `raw.coleta_bruta`/`raw.controle_carga` → atualizar `admin.py`, `persistence.py:46`, `ingestao_conab.py:1165`.
   b. `staging.baseline_2025_interpolado` → `imputar_gaps_baseline.py:181`.
   c. `staging.confianca_baseline` → `data_healer.py:255` (coluna `confianca` fica; só rename da tabela).
   d. `staging.vw_fluxos_regionais` → `fluxos.py:28`.
   e. Funções da cadeia sandwich (`fn_fator_sazonal_mensal`, `fn_preco_base_2026`, `fn_sandwich_historical_price`, `fn_status_cor_regra_*`) → recriar `sp_project_sandwich_prices_2026` na mesma transação.
   f. `mart.fator_kg_produto_uf` → idem (recriar sandwich).
   g. `sp_calcular_sazonalidade` → recriar `sp_executar_carga_completa` na mesma transação.
2. Atualizar docs: `database/summary.md`, `ANDAMENTO/`, `docs/PROJECT_RULES.md` (se citarem nomes).
3. Teste E2E: `CALL staging.sp_executar_carga_completa()` num banco de staging, depois API end-to-end.
4. Commits por objeto com `refactor(db): ...`.

### Fase 3 — Semana 4 (3–4 h) — limpeza

1. DROP das views de compat da Fase 1 (após 2026-09-30 e `rg` provar zero referências).
2. DROP dos legados: `fn_importar_fluxos_json`, `fato_cotacao_regional`, `test_show_timeout*`, `sp_calcular_forecast_2026` (duplicata).
3. Colunas ⚠️ (opcional, alta cautela): `preco_medio`/`fonte`/`is_forecast`/`calculado_em` em `sazonalidade_produto` + **redefinição da MV** em manutenção; typo `classificao_produto` com alias Pydantic em `responses.py:260`.
4. `COMMENT ON` em 100% de `mart.*` e `staging.*`; verificação final `rg` dos nomes antigos = zero no codebase.
5. Commit final + tag de versão de schema (ex.: `schema-v21`).

---

## Critério de Sucesso — checklist

1. ✅ `\dt mart.*` legível por analista sem doc extra
2. ✅ Relatório ad-hoc em < 15 min com `SELECT * FROM mart.<nome>`
3. ⬜ `COMMENT ON` em 100% de `mart.*` e `staging.*` (hoje: **51% sem comentário**)
4. ✅ Zero objetos com versão/ano hardcoded no nome (após Fases 1–2; `_2026`/`_24_25` restritos às colunas legadas até Fase 3)
5. ✅ Views descrevem **o que mostram**, não **como foram implementadas**
6. ✅ `\df staging.*` explica o papel de cada função

---

**Observações finais:** a auditoria confirmou que a arquitetura de nomenclatura está **melhor do que o prompt supunha** (os piores casos — `sazonalidade_baseline_24_25`/`_25_26` e `sp_calcular_forecast_2026_v13` no `mart` — já não existem ou não estão onde o prompt assumiu). O maior risco real não são os nomes, e sim a **cadeia de dependências** (MV ↔ `sazonalidade_produto`, sandwich ↔ `fator_kg_produto_uf`, `carga_completa` ↔ `sp_calcular_sazonalidade`) — todo rename de objeto com dependente vivo precisa recriar o dependente na **mesma transação**.
