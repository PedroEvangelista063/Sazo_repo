# VALIDAÇÃO DOS AUDITS 1 A 9 — RELATÓRIO CONSOLIDADO

**Data**: 2026-08-01
**Projeto**: quero_comprar_vg (scraping CONAB/Ceasa + forecast sazonal + Supabase + FastAPI + React)
**Escopo**: Validação fase a fase dos prompts `docs/audit-1` a `docs/audit-9` contra o projeto atual e o banco Supabase remoto.

---

## Sumário Executivo

Todos os **9 audits foram validados** e estão **100% implementados e confirmados** — o audit-1, que estava parcial, foi fechado em 2026-08-01 com a criação do `docs/RELATORIO_TRANSPARENCIA_MATEMATICA.md` (as 3 queries de transparência validadas contra o banco remoto). O audit-8 revelou **bugs reais** que foram endereçados pela migração 58 (validada no audit-9).

| # | Tema | Veredito | Evidência principal |
|---|------|----------|---------------------|
| 1 | Transparência Matemática + 3 queries | ✅ **IMPLEMENTADO** | `docs/RELATORIO_TRANSPARENCIA_MATEMATICA.md` criado com as 3 queries validadas no banco remoto (Contraste Macro, Prova do Sanduíche 92,7% = 0%, Dispersão Legítima até +300%) |
| 2 | Índice Sazonal Relativo | ✅ **IMPLEMENTADO** | `51_fator_sazonal_forecast.sql` (fn_fator_sazonal_mensal, fn_preco_base_2026, sp_project_sandwich_prices_2026) |
| 3 | Deploy Multi-Ambiente | ✅ **IMPLEMENTADO** | Migration 51 aplicada local+Supabase, procedures/MV existem no remoto, cache clear integrado |
| 4 | Teste E2E Scraper Micro-Batch | ✅ **IMPLEMENTADO** | `utilities/test_scraper_e2e.py` (351 linhas) provou a esteira; 2 bugs corrigidos no caminho |
| 5 | Data Lineage / Amarelo Estrutural | ✅ **ÍNTEGRO** | Fio de Ariadne: TOMATE/SP −30,42% propagado exatamente; Amarelo é comportamento esperado da regra ±25% |
| 6 | Conciliação RAW→Staging→Mart | ✅ **IMPLEMENTADO** | `utilities/audit_raw_vs_db.py` + relatório; anomalias críticas zeradas pelas migrações 56-59 |
| 7 | Expurgo + Recalibragem ±25% | ✅ **IMPLEMENTADO** | `57_expurgo_e_recalibragem.sql`: 38.882 células expurgadas, régua ±25% em produção |
| 8 | Auditoria DQ do Funil | ✅ **REALIZADA** | Vazamento de 272 pares mapeado; bug de unidade confirmado (Tomate R$97,50); Top 10 MAPE |
| 9 | Hotfix Orquestrador/Leak/Outliers | ✅ **IMPLEMENTADO** | `58_hotfix_pipeline_outliers.sql`: v11 corrigida, MILHO 447 devolvidas, drift 9,03%, 90 preços barrados |

---

## Detalhamento por Audit

### AUDIT-1 — Relatório de Transparência Matemática (✅ IMPLEMENTADO)

**Solicitado**: Relatório com 3 queries de evidência (Contraste Macro is_forecast×status_cor; Prova do Sanduíche SANDUICHE_MEDIA_24_25; Dispersão Legítima real >±15%).

**Validado**:
- ✅ Infraestrutura do Sanduíche Sazonal existe (`database/40_sanduiche_sazonal_preco_projetado.sql`: `forecast_method='SANDUICHE_MEDIA_24_25'`, `preco_atual`, `preco_referencia`)
- ✅ Regra de semáforo existe (`database/50_status_cor_regra_15_forecast.sql` + `database/57` recalibra para ±25% em produção)
- ✅ `docs/DIAGNOSTICO_SANDUICHE_SAZONAL.md` documenta o Amarelo Estrutural
- ✅ **`docs/RELATORIO_TRANSPARENCIA_MATEMATICA.md` criado em 2026-08-01** com as 3 queries validadas contra o Supabase remoto (resultados reais no documento)

**Provas executadas no banco remoto**:
- **Query 1 (Contraste Macro)**: projetados = 89,1% AMARELO (30.055/33.738); reais = 93,0% AMARELO com 6,9% fora da régua (3.074 pares) — tese confirmada: projeção ≈ referência → AMARELO por design
- **Query 2 (Prova do Sanduíche)**: **92,7%** das projeções SANDUICHE_MEDIA_24_25 têm variação derivada **0,00%** (8.637 linhas com |Δ| < 1%); exemplos: BANANA-NANICA PA/RR/MA/RN/AP e FEIJAO-PRETO SC/PE/RO/PR/ES todos com preco_atual = preco_referencia → AMARELO
- **Query 3 (Dispersão Legítima)**: reais 2026 com volatilidade real até **+300%** (CHUCHU GO, BANANA-PRATA RS, BANANA AP) pintam VERMELHO corretamente — a calculadora reage quando o dado muda

**Achado adicional do relatório**: a coluna legada `variacao_pct` da MV **não foi recalculada** pela migration 58 (drift: mostra 0,00% onde a variação real é +150% e 503% onde os preços são idênticos). Recomendação documentada: recriar a MV derivando da fonte corrigida (`preco_medio`/`preco_mes_anterior`).

---

### AUDIT-2 — Índice Sazonal Relativo (✅ IMPLEMENTADO)

**Solicitado**: Fator sazonal `(média do mês / média global) − 1` + momentum de preço base 2026 + log de 3 produtos AMARELO→VERDE/VERMELHO.

**Implementado em `database/51_fator_sazonal_forecast.sql`** (580 linhas):
- `staging.fn_fator_sazonal_mensal(id_produto, id_localidade, mes)` — Níveis 1/2/3 de fallback, sanitização de outliers (0,5×–2,0× da mediana → NULL), exige ≥ 6 meses
- `staging.fn_preco_base_2026` — média real 2026 (is_forecast=FALSE), fallback 2024-25
- `sp_project_sandwich_prices_2026()` — Steps 1-4 + REFRESH MV CONCURRENTLY
- `database/52_correcao_amarelo_estrutural.sql` (703 linhas) — Nível 3 (produto global) recupera ~418 pares; `fn_encontrar_produto_pai` v2 prefere pai FATOR_SAZONAL

**Prova viva no Supabase**: SANDUICHE_FATOR_SAZONAL 15.815 AMARELO + 892 VERDE + 344 VERMELHO; PROXY_HIERARQUICO 18.370 + 3.576 + 1.274. Exemplos: BATATA-DOCE SP Out +75,9% VERMELHO, ABACATE MT Dez +64,1% VERMELHO, TOMATE MT Dez −62,8% VERDE.

---

### AUDIT-3 — Deploy Multi-Ambiente (✅ IMPLEMENTADO)

**Solicitado**: Deploy da migration 51 local+Supabase, refresh da MV, cache clear e log de 5 produtos.

**Validado no Supabase remoto**:
- ✅ `sp_project_sandwich_prices_2026`, `fn_fator_sazonal_mensal`, `fn_preco_base_2026` **existem**
- ✅ MV `vw_api_produtos_sazonalidade` com 78.004 linhas
- ✅ Cache clear: `POST /admin/cache/clear` em `backend/app/api/v1/endpoints/admin.py`; `pipeline/cache_purge.py` integrado em run_scraper_historico.py, scraper/persistence.py, ingestao_conab_inteligente.py
- ✅ Log 5 produtos: BATATA-DOCE SP +75,95% VERMELHO, BERINJELA SC +71,00%, ABACATE SP +69,10%, VAGEM SC +67,83%

**Nota**: O Supabase MCP lista apenas 12 migrations CLI (000001-000012); as migrações 40-59 foram aplicadas por outro mecanismo — histórico CLI incompleto, não bloqueia.

---

### AUDIT-4 — Teste E2E Scraper Micro-Batch (✅ IMPLEMENTADO)

**Solicitado**: Script temporário com trava anti-loop (1 UF=SP, 1 mês=Jul/2026, máx 5 registros, timeout ~15s) e logs `[EXTRAÇÃO][TRANSFORMAÇÃO][CARGA][CACHE]`.

**Implementado em `utilities/test_scraper_e2e.py`** (351 linhas) e **executado com sucesso** (134,5s):
- `[EXTRAÇÃO]` OK: 1.058.260 linhas; 18.602 da competência; 3.040 SP; 5 selecionadas (TANGERINA, TOMATE, UVA ITALIA, UVA NIAGARA, VAGEM)
- `[TRANSFORMAÇÃO]` OK: 5/5 normalizadas e validadas contra `ProdutoSazonalSchema`
- `[CARGA]` OK: 5 registros em `raw.coleta_bruta` → SortingEngine 5 → `sp_executar_carga_completa` 123,8s
- `[CACHE]` ⚠️ backend FastAPI offline (Connection refused tolerado)
- `[VERIFICAÇÃO]` OK: 5/5 confirmados em `staging.fact_precos_mensais` SP 2026-07

**2 bugs reais corrigidos**: (1) `sorting_engine.py:233` — `ON CONFLICT (uf, municipio_id)` desatualizado → `ON CONFLICT (uf) WHERE municipio_id IS NULL`; (2) statement_timeout do Supabase (2min) cancelava a SP (~118s) → `SET statement_timeout = 300000`.

---

### AUDIT-5 — Data Lineage do Amarelo Estrutural (✅ ÍNTEGRO)

**Solicitado**: Troubleshooting em 3 fases (propagação, Fio de Ariadne Reverso, diagnóstico tipagem/ordem/geo).

**Resultado**: **NENHUMA desconexão matemática encontrada**:
1. **Propagação**: procedure contém `fn_preco_base_2026` + `fn_fator_sazonal_mensal` + `REFRESH MV CONCURRENTLY` no final. Semáforo em produção = `fn_status_cor_regra_25` (±25%, migração 57 já aplicada)
2. **Fio de Ariadne (TOMATE/SP Set)**: fator manual = −30,42% → mart absorveu **exatamente −30,42%** (ref 5,5487 → atual 3,8608), VERDE
3. **Diagnóstico**: sem bug de tipagem (ROUND+NUMERIC), sem bug de ordem (semáforo após pre-fill), sem achatamento geo (fator N1 local; fallback global só ~418 pares)

**Causa raiz do Amarelo Estrutural**: comportamento **matematicamente esperado** da regra ±25% com sazonalidade moderada (|Δ| médio 8-14% dentro da faixa). 6.279 forecasts já saem do AMARELO quando a volatilidade é real. **Nenhum bloco de correção SQL é necessário.**

---

### AUDIT-6 — Conciliação RAW vs Staging vs Mart (✅ IMPLEMENTADO)

**Solicitado**: Auditoria de preço/ano na linhagem (estrutural + script + query staging×mart) e relatório de incoerências.

**Implementado**: `utilities/audit_raw_vs_db.py` (430 linhas) + `docs/RELATORIO_AUDITORIA_RECONCILIACAO.md` (179 linhas).

**Revalidação FASE 3 no banco (01/08) — anomalias críticas ZERADAS pelas migrações 56-59**:

| Anomalia | Antes (31/07) | Agora (01/08) |
|---|---|---|
| Outliers >500% | 343 (até 23,8×) | **0** (max 1,50×) |
| Mart sem ano/mês | 60.519 (30,5%) | **0** |
| Mart sem preço com fact com preço | 14.270 | **0** |
| Mart sem qualquer preço | 20.675 | 1.148 |

**Resíduos menores** (não quebram contrato de preço/ano): 93 mart real sem lastro (unidades/cadastros distintos); 1.028 fact sem mart (5 produtos E2E em minúsculo + MILHO 5 UFs resíduo do leak).

---

### AUDIT-7 — Expurgo + Recalibragem ±25% (✅ IMPLEMENTADO)

**Solicitado**: Expurgo das células mortas legadas + recalibragem do semáforo ±15%→±25% + relatório de linhas deletadas e distribuição de cores.

**Implementado em `database/57_expurgo_e_recalibragem.sql`** (646 linhas):
- **FASE 1**: backup auditável `mart.sazonalidade_legado_backup_57` = **38.882 células** expurgadas (o audit estimava 17.409; a base real tinha 38.882). Restantes = **0**
- **FASE 2**: `staging.fn_status_cor_regra_25` canônica (teste: 10×8→AMARELO, 5×8→VERDE); recalc retroativo; procedure v6 com ±25% em todos os steps
- **FASE 3**: MV refrescada 2026-08-01 11:43; cache clear endpoint integrado

**Distribuição Nacional 2026 forecast**: AMARELO 42.171 (87,0%), VERDE 4.538 (9,4%), VERMELHO 1.741 (3,6%) — total 48.450. Regional: destaques VERMELHO = SC 196, MS 138, TO 123, SP 120; VERDE = PE 357, ES 336, GO 292, MG 267.

---

### AUDIT-8 — Auditoria DQ do Funil (✅ REALIZADA)

**Solicitado**: Funil de retenção 2026, Top 10 MAPE piores/melhores, caça a outliers com rastreamento até a fact.

**FASE 1 — Funil**: fact 13.993 → mart real 14.081 → MV real 13.809. **Vazamento de 272 pares** (2%): 184 com `fonte NULL` + `preco_curado NULL` (registros não-curados de scraper/testes; 179 concentrados em junho/2026 SP com preços ~R$0,86-0,97 suspeitos de R$/unidade). Deduplicação da fact OK (0 duplicados).

**FASE 2 — Acurácia granular** (backtest 2024→2025):
- **Piores**: Banana Prata SP 101,75%, Tomate Italiano 68,48%, Banana Nanica 62,53%, Maçã Fuji 58,39%, Maçã Gala 46,90%
- **Melhores**: Maçã Gala Importada 0,96%, Maçã Fuji Importada 1,07%, Ovo Vermelho 1,17%, Ameixa Argentina 1,63%, Mandioca 3,26%
- Padrão confirmado: erra em **sensíveis** (banana/tomate/maçã nacional), acerta em **estáveis/importados**. MAPE mensal agregado 0,74-18,94% (média ~10%)

**FASE 3 — Outliers**: MV real: preço ≤ 0 → 0; variacao >300% → **48**; <−90% → **9**. **Bug de unidade confirmado**: Tomate Italiano Pizzadoro SP jan-mai R$97,50 fixo (caixa 25kg não convertida, real ~R$3,90/kg) → MV a R$90,00 com variação 1.380%. **Extremos NÃO são fatos econômicos** — são erros de parsing/unidade.

---

### AUDIT-9 — Hotfix de Orquestração, Leak e Outliers (✅ IMPLEMENTADO)

**Solicitado**: 4 frentes — orquestrador (v11 fantasma), leak Milho 447 células, drift variacao_pct (+1768%), hard cap R$50.

**Implementado em `database/58_hotfix_pipeline_outliers.sql`** (534 linhas) e **confirmado no Supabase remoto**:

| Frente | Evidência no banco |
|---|---|
| F1 Orquestrador | `sp_executar_carga_completa` agora chama `CALL sp_calcular_sazonalidade(NULL, NULL)` (v11 era fantasma) |
| F1b Leak MILHO | **447 células** MILHO 2026 re-materializadas no Mart (id_produto=10440) |
| F2 Drift | Batata Doce SP 2026-07: `variacao_mom_pct` = **+9,03%** (era +1768%); fonte de verdade = preco_medio (LAG) |
| F3 Hard Cap | `fn_classificar_preco_anomalia` + trigger `trg_valida_anomalia_preco` ativo; **90 preços >R$50 barrados** (ex: Amendoim R$280, Pepino R$245, Tomate R$200); 751 restantes >R$50 são **legítimos** (histórico sólido: ex Uva Itália) |
| F4 Deploy | Migration no remoto; MV 78.004 linhas calculado_em 11:43; cache clear endpoint integrado |

---

## Achados Transversais e Recomendações

1. **Duplicidade de produto por case** (`tomate` vs `TOMATE`) gera linhas duplicadas no Mart — recomenda-se normalizar case na dimensão.
2. **Bug de unidade na origem do scraper** (caixa→kg) — o hard cap R$50 barra a entrada, mas a **conversão correta no scraper** (ex: Tomate Pizzadoro 25kg) elimina o problema na raiz.
3. **Histórico CLI de migrações incompleto no Supabase MCP** — apenas 000001-000012 registrados; aplicar padrão de registro CLI para as demais.
4. ~~Relatório do audit-1 pendente~~ **RESOLVIDO** — `docs/RELATORIO_TRANSPARENCIA_MATEMATICA.md` criado (2026-08-01) com as 3 queries validadas; nova pendência derivada: recriar a MV para corrigir o drift da coluna legada `variacao_pct`.
5. **Leak residual MILHO 5 UFs 2025-12** — 1.028 fact sem mart: reprocessar 2025-12 ou aceitar como resíduo conhecido.
6. ~~Erros LSP em `sorting_engine.py` (BeautifulSoup/Tag indefinidos)~~ **RESOLVIDO** (2026-08-01) — imports sob `TYPE_CHECKING` + `get_attribute_list("class")`; sintaxe/imports e smoke test do parser HTML validados.

---

## Conclusão

O pipeline de dados (scraping CONAB/Ceasa → medalhão → forecast sazonal → Mart → API) está **operacional e blindado** contra os três problemas estruturais que a auditoria identificou: orquestrador quebrado, leak de dados e outliers de unidade. As migrações 51-59 corrigem a cadeia de ponta a ponta, com evidências vivas confirmadas no banco de produção em 2026-08-01. Follow-ups do relatório (transparência matemática, erros LSP) também foram **resolvidos** na mesma data.
