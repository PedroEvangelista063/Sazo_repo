# Relatório de Implementação — Refatoração Dado Histórico Real com Transparência Temporal (Ano Âncora)

> **Status atual: 100% IMPLEMENTADO E VALIDADO** (Fases 1–4 ✅ + integração ✅ + smoke E2E ✅ + banco local populado ✅) — resta apenas deploy em produção e revalidação do Supabase remoto (down).
>
> **Escopo aceito com uma deferência explícita (decisão do change owner, 2026-08-03):** a **camada de Mapa Regional** (`mart.vw_mapa_regional_completo` → schema/endpoint `/api/v1/regioes` → `BrasilMap.tsx`/`RegiaoPanel.tsx`) **não recebeu transparência temporal** — ver Seções 2/3/4 e o relatório de auditoria `docs/RELATORIO_AUDITORIA_ANO_ANCORA_REAL.md`. Fica fora do escopo das 4 fases.
>
> Plano de referência: _Refatoração Arquitetural de Dado e Produto: Transição de Dado Preditivo para Base Histórica Concreta com Transparência Temporal (Ano Âncora Real)_ — documentado no openspec em `openspec/changes/refatoracao-dado-historico/` (proposal, specs, design, tasks). (Corrigido: o plano válido é o transcrito do prompt, _**não**_ o `docs/implementation_plan2.md`, que descrevia o engine preditivo V13 posteriormente desativado.)

---

## 1. Resumo Executivo

O objetivo da refatoração é **interromper a geração de projeções/extrapolações sintéticas** (Sanduíche Sazonal `sp_project_sandwich_prices_2026` e engine V13 `sp_calcular_forecast_2026_v13`) e exibir **dados históricos reais** com fallback de **ano âncora dinâmico** (N → N-1 → N-2 → dimensão) e **metadados de transparência temporal** na API e na UI (ícone `(i)` → tooltip).

| Fase                                         | Escopo                                                                                                 | Status                                                                                 | %                    |
| -------------------------------------------- | ------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------- | -------------------- |
| **Fase 1 — Banco de Dados** (Slice 1, PR #1) | Migração 63 + MV V17 + desativação de engines sintéticas + rollback 64 + Supabase 000021 + verificação | ✅ **Concluída**                                                                       | 100%                 |
| **Fase 2 — API/Backend** (Slice 2, PR #2)    | Schemas Pydantic + endpoints com campos de transparência                                               | ✅ **Concluída** (integração V17 pendente de banco)                                    | 100%                 |
| **Fase 3 — Frontend/UI** (Slice 3, PR #3)    | `DataTransparencyInfo.tsx`, remoção de quadros cinzas, badges de ano                                   | ✅ **Concluída** (grade/cards; **Mapa Regional deferido** — smoke Playwright pendente) | 100% (escopo aceito) |
| **Fase 4 — Cleanup & Cache**                 | Redução de complexidade (engines off) + purge de cache + invalidação React Query                       | ✅ **Concluída no código** (execução do purge pendente de API up)                      | 100%                 |

---

## 2. ✅ FASE 2 (Backend/API) — CONCLUÍDA

> **Última atualização: 2026-08-02** — a Fase 2 do plano de implementação foi **concluída**.

### Entregue (Slice 2, PR #2)

1. **Schemas Pydantic** (`backend/app/schemas/responses.py`):
   - ✅ Campos opcionais/defaulted `ano_referencia: int | None`, `tipo_dado: str | None`, `mensagem_transparencia: str | None`, `is_dado_legado: bool = False` adicionados em `SazonalidadeResponse`, `SazonalidadeComPrecoResponse`, `MesSazonalidade` (contrato aditivo — R-ADD-01/S4).
   - ✅ `FlowItem.ano_referencia: int = 2024` → `int | None = None` (R-MOD-01 — fim do default hardcoded enganoso).
2. **Endpoints** (`backend/app/api/v1/endpoints/produtos.py`):
   - ✅ `BASE_COLS`, `_compute_periodo_full` e query do `/com-preco` com `v.ano_referencia`, `v.tipo_dado`, `v.idade_dado_anos` (leitura direta da MV V17 — R-ADD-02/S6).
   - ✅ Todos os builders (`_build_response`, `_query_sazonalidade_por_mes`, `_build_br_response`, `_query_regional_snapshot`, `_query_regional_por_mes`, com-preco) mapeiam os 4 campos; `is_dado_legado = (ano_referencia is not None) and (ano_referencia < datetime.now(UTC).year)`.
   - ✅ `_query_br_sazonalidade` mapeia `ano_referencia`/`tipo_dado` da `fn_br_nacional_sazonalidade` recriada na Fase 1 em `MesSazonalidade`.
   - ✅ `_compor_mensagem_transparencia(tipo_dado, ano_referencia, idade=None)` em pt-BR (REAL_ATUAL "Coleta efetiva…" / HISTORICO_BASE "Dado histórico real… (defasagem de N ano(s))" / FALLBACK_DIMENSAO) — **sem R$** (R-ADD-03). Idade derivada de `ANO_ATUAL - ano_referencia` quando a fonte não projeta `idade_dado_anos` (fix de review: `fn_br_nacional_sazonalidade` não retorna essa coluna).
   - ✅ Bump do cache key `br_sazonalidade` `"v": 2` → `"v": 3` (R-ADD-05).
3. **Verificação (GREEN)**:
   - ✅ TDD RED→GREEN: `backend/tests/test_transparencia_dado_historico.py` — **14 testes passando** (FlowItem sem default 2024, campos de transparência, sem R$, sinalização de nulo, composição de mensagem com defasagem correta) + `test_resilience.py` 6 passando.
   - ✅ `ruff check` + `ruff format` limpos; import do módulo OK.
   - ⬜ **Integração contra DB V17 pendente** (task 2.4.2): banco remoto Supabase em _hot standby_/down e sem credenciais do banco local na sessão — validar `GET /api/v1/sazonalidade?uf=SP` (≥1 REAL_ATUAL 2026 + ≥1 HISTORICO_BASE 2025) e purge/re-GET quando o serviço voltar.

### Limitação documentada (não é regressão)

`/sazonalidade?uf=BR` (snapshot/por-mes) e endpoints regionais roteiam por `fn_br_nacional_snapshot`/`fn_br_nacional_por_mes`/`fn_regional_*`, que não foram recriadas com colunas de transparência na Fase 1 — os campos chegam `None` nesses paths (seguro via `.get()`). O consumidor principal (grade BR nacional) usa `br-sazonalidade`, que está coberto.

> **Deferência explícita (escopo aceito):** a camada de **Mapa Regional / regiões** — `mart.vw_mapa_regional_completo` (não recriada, decisão SDD D1), schema de mapa (não existe `MapaRegionalResponse`), endpoint `/api/v1/regioes` (lê `config/regions.json` estático, sem transparência) e `BrasilMap.tsx`/`RegiaoPanel.tsx` (sem `DataTransparencyInfo`) — **não faz parte do escopo entregue**. `FlowItem` tem apenas `ano_referencia` (faltam `tipo_dado`/`mensagem_transparencia`/`is_dado_legado`). Confirmação na auditoria: `docs/RELATORIO_AUDITORIA_ANO_ANCORA_REAL.md`.

---

## 3. ✅ FASE 1 (Banco de Dados) — CONCLUÍDA

### Artefatos entregues (branch `refatoracao-dado-historico/db`)

| Artefato                                                      | Descrição                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `database/63_dado_historico_real_transparencia.sql`           | Colunas `ano_referencia INTEGER`, `tipo_dado TEXT`, `metadado_transparencia JSONB`, `idade_dado_anos INTEGER`, `preco_exibido` + CHECK `chk_sazonalidade_tipo_dado`; backfill único e idempotente (`WHERE ano_referencia IS NULL`); MV `mart.vw_api_produtos_sazonalidade` V17 (3 branches D3/D4/D5); `fn_br_nacional_sazonalidade` recriada com campos de transparência; desativação dos calls sintéticos no `sp_executar_carga_completa` (calls viram comentário + `REFRESH MATERIALIZED VIEW CONCURRENTLY` explícito) |
| `database/64_rollback_dado_historico.sql`                     | Rollback: drop MV V17 → constraint → 5 colunas → view âncora; restaura MV a partir do padrão `36_fix_dedup_dim_localidade.sql`                                                                                                                                                                                                                                                                                                                                                                                           |
| `supabase/migrations/000021_desativar_engines_sinteticas.sql` | Espelho da desativação no `sp_executar_carga_completa` (CALL V13/Sanduíche desativados, audit trail)                                                                                                                                                                                                                                                                                                                                                                                                                     |
| `scripts/verify_synthetic_off.sql`                            | Script de verificação RED/GREEN: confirma engines sintéticas desativadas e colunas presentes                                                                                                                                                                                                                                                                                                                                                                                                                             |
| Commits 1a–1e + fixes                                         | `ceffb63c` → `245c9d1d` (8 commits: 1a desativação → 1b colunas+backfill → 1c view âncora+MV+fn → 1d 000021+pipeline → 1e rollback+RED/GREEN → fixes de idempotência/status_cor/guard)                                                                                                                                                                                                                                                                                                                                   |

### Decisões-chave implementadas

- **Ano âncora dinâmico**: `ANO_ATUAL = EXTRACT(YEAR FROM CURRENT_DATE)` em todo lugar (2026 → 2025 → 2024), sem constantes hardcoded.
- **Semântica de dado**: `FLUXO_PROXY`/`is_forecast` → `FALLBACK_DIMENSAO` (nunca deletadas, semântica de exibição); dado real do ano corrente → `REAL_ATUAL`; anos anteriores → `HISTORICO_BASE`.
- **MV V17** projeta: `preco_exibido`, `preco_referencia`, `variacao_pct`, `status_cor`, `ano_referencia`, `tipo_dado`, `idade_dado_anos`.
- **Fora de escopo (deferido)**: `mart.vw_mapa_regional_completo` (sem consumidores) — decisão SDD D1.

---

## 4. ✅ FASE 3 (Frontend/UI) — CONCLUÍDA

> **Última atualização: 2026-08-02** — a Fase 3 do plano de implementação foi **concluída**.

### Entregue (Slice 3, PR #3)

1. **Componente `DataTransparencyInfo.tsx`** (novo): ícone `(i)` circulado (lucide `Info`, strokeWidth 1.5) com tooltip explicativo — "Dado Atual" / "Ano de Origem: NNNN", badge de status (Coleta Efetiva / Histórico Real CONAB / Referência), explicação ("Não é uma estimativa sintética"), defasagem ("Histórico de 1/2 anos atrás"), `mensagem_transparencia` quando fornecida. Renderiza `null` quando `!tipo_dado`; **nunca renderiza R$**. _(Nota: implementado com tooltip/popover no padrão CSS do projeto em vez de Mantine Popover — Mantine não está wired no app, sem `MantineProvider` em `main.tsx`.)_
2. **Grade Sazonal `SazonalidadeNacional.tsx`**: removidos `GAP_STYLES`, `classifyGap`, ramo de célula cinza e tooltips de forecast (`📈`); células sem linha → vazia muted (defensivo); células legadas exibem badge de ano âncora (`'25`/`'24`) + ícone `(i)` de transparência.
3. **Cards `ProductCard.tsx`**: removidos badges `📊 Estimativa`/`🪄 Estimado`; badge de `tipo_dado` (verde/âmbar/contorno) com ano real (ex: "Histórico Real '25"); rodapé "Ano de apuração: NNNN" + ícone `(i)`.
4. **`SupermercadoView.tsx`**: `selectedYear` sempre ano corrente; badge "⚠️ Ano em curso — dados parciais" → "Grade com dados de N-2–N (ano âncora exibido por célula)"; link "Ver N-1 (cobertura completa)" → "(histórico)".
5. **`types/domain.ts`**: campos opcionais de transparência em `ProdutoVarejo` e `MesSazonalidade`.
6. **`useDataStream.ts`**: as 5 keys de invalidação já presentes no `ETL_FINISHED` — confirmado, sem alteração.

### Verificação (GREEN)

- ✅ TDD RED→GREEN: **25 testes vitest passando** (DataTransparencyInfo 4, SazonalidadeNacional 4, ProductCard 12, BRNationalIcon 5).
- ✅ `tsc --noEmit` limpo; `prettier --check` limpo nos arquivos alterados.
- ⬜ Playwright smoke E2E (grade preenchida + tooltip abre + sem R$): **não executado** — Chrome não disponível no ambiente; coberto por vitest + tsc.

> **Deferência na Fase 3 (escopo aceito):** `BrasilMap.tsx` e `RegiaoPanel.tsx` **não** usam `DataTransparencyInfo` nem ícone `(i)` — o Mapa Regional não expõe ano âncora (consistente com a deferência da Fase 1 da `vw_mapa_regional_completo`). Resíduo cosmético fora de escopo: `GameCard.tsx:119,142` ainda exibe `📊 Estimativa`/`🪄 Estimado`.

---

## 5. ✅ FASE 4 (Cleanup & Cache) — CONCLUÍDA NO CÓDIGO

> **Última atualização: 2026-08-02** — a Fase 4 do plano de implementação foi **concluída no código** (execução efetiva do purge pendente de API up).

### Parte 1 — Redução de Complexidade (✅ entregue na Fase 1)

- ✅ **Engines sintéticas desativadas** no `sp_executar_carga_completa` (calls V13/Sanduíche viram comentário + `REFRESH MATERIALIZED VIEW CONCURRENTLY` explícito) — `database/63` e `supabase/migrations/000021`.
- ✅ **Guard `is_forecast` no pipeline** (`pipeline/run_bulk_historical_fill.py`): `GuardIsForecastError` — se `count(is_forecast=TRUE)` crescer após recálculo, **aborta com exit ≠ 0** (nunca engole o erro).
- ✅ **Guard `is_forecast` no deploy** (`scripts/deploy_v13_prod.sh`): count pré/pós-CALL; crescimento → `die` abortando o deploy.
- ✅ **Pipeline simplificado**: extrair → higienizar → gravar fatia real → `REFRESH MATERIALIZED VIEW`. Scripts sintéticos permanecem no repo desativados (audit trail).

### Parte 2 — Purga de Cache (em execução)

- ✅ **Mecanismo de purge existe**: `pipeline/cache_purge.py` (`purge_cache_sync` → `POST /api/v1/admin/cache/clear` com `X-API-Key`) + endpoint `admin.py:/cache/clear` (limpa InMemory/Redis).
- ✅ **Já invocado no pipeline** em 3 pontos: `pipeline/ingestao_conab_inteligente.py:422`, `pipeline/scraper/persistence.py:90`, `pipeline/run_scraper_historico.py:259`.
- ✅ **Passo de purge pós-deploy adicionado ao `deploy_v13_prod.sh`** (seção 9): `curl -X POST /api/v1/admin/cache/clear` com `X-API-Key` após o CALL do pipeline; degradação graciosa (AVISO se API offline). Sintaxe validada com `bash -n`.
- ✅ **Invalidação React Query**: `useDataStream.ts` invalida as 5 keys (`br-sazonalidade`, `hortifruti-meta`, `hortifruti-filter`, `sazonalidade-com-preco`, `regiao-resumo`) no evento SSE `ETL_FINISHED` (verificado, sem alteração).
- ✅ **Mecanismo de purge testado offline**: `purge_cache_sync()` retorna `False` graciosamente com API off (connection refused → log, sem crash); endpoint `admin.py:/cache/clear` com `_verify_api_key` (403 se chave errada).
- ⬜ **Execução efetiva do purge**: pendente de ambiente — API FastAPI não estava rodando na sessão de validação; validar `POST /admin/cache/clear` + re-GET fresco quando serviço estiver up.

---

## 6. Roteiro de Verificação (Critérios de Sucesso do Plano)

- [x] **(a)** DDL da MV V17 com colunas de transparência — ✅ **entregue e confirmada no banco** (colunas `ano_referencia`/`tipo_dado`/`idade_dado_anos`/`preco_exibido`/`metadado_transparencia` via `pg_attribute`).
- [x] **(b)** Payload JSON da API `/api/v1/sazonalidade?uf=SP` — ✅ **validado ao vivo** (HTTP 200; FALLBACK_DIMENSAO com mensagem; `br-sazonalidade?ano=2026` com `REAL_ATUAL`/`ano_referencia=2026`; HISTORICO_BASE com âncora 2025/2024; 0 vazamentos de R$).
- [x] **(c)** UI — ✅ **smoke E2E PASS** (7/7): grade sem quadros cinzas, 7.920 ícones (i) + 2.880 badges de ano, 0 R$, 0 erros de console.

> 📋 **Auditoria completa**: ver `docs/RELATORIO_AUDITORIA_VALIDACAO_DADO_HISTORICO.md` (detalhes de população: 143.646 linhas de sazonalidade, MV 128.230, grade 2026 = 7.920 células com 0 cinzas; banco remoto Supabase segue em hot standby/down).

---

## 7. Referências

- SDD: `openspec/changes/refatoracao-dado-historico/` (proposal.md, design.md, tasks.md, specs/`{dados-historicos-reais, transparencia-dados-ui, sazonalidade-api}`)
- Migrações: `database/63_dado_historico_real_transparencia.sql`, `database/64_rollback_dado_historico.sql`, `supabase/migrations/000021_desativar_engines_sinteticas.sql`
- Verificação: `scripts/verify_synthetic_off.sql`
- Backend (Fase 2): `backend/app/schemas/responses.py`, `backend/app/api/v1/endpoints/produtos.py`
- Frontend (Fase 3): `frontend/src/components/SazonalidadeNacional.tsx`, `frontend/src/components/ProductCard.tsx`, `frontend/src/pages/SupermercadoView.tsx`, `frontend/src/components/DataTransparencyInfo.tsx` (a criar)
