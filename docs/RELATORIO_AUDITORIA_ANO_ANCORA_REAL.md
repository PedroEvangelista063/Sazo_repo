# Relatório de Auditoria — Refatoração Dado Histórico Real (Ano Âncora Real)

- **Data da auditoria:** 2026-08-03
- **Escopo:** Validação da implementação da "REFATORAÇÃO ARQUITETURAL DE DADO E PRODUTO: TRANSIÇÃO DE FORECAST PREDITIVO PARA BASE HISTÓRICA CONCRETA COM TRANSPARÊNCIA TEMPORAL (ANO ÂNCORA REAL)" (plano transcrito pelo usuário).
- **Natureza:** auditoria somente-leitura — nenhum artefato foi alterado; nenhuma implementação foi executada.
- **Método:** verificação de evidência direta (arquivos, linhas, contagens), execução de testes autônomos (backend pytest + frontend vitest) e confronto com os relatórios existentes em `docs/`.

## Resumo Executivo

A refatoração **está majoritariamente implementada e validada**, com cobertura real e funcional para o caminho principal (grade sazonal, cards de produto e pipeline de dados). **Existe um escopo inteiro que ficou de fora**: a camada do **Mapa Regional / regiões** (`vw_mapa_regional_completo` → schema de Mapa → endpoint `/api/v1/regioes` → `BrasilMap.tsx`/`RegiaoPanel.tsx`), que não recebeu as colunas de transparência temporal nem o ícone `(i)`.

De forma geral, os dois relatórios em `docs/` são **confiáveis**: todas as claims de código/arquivo/commit/teste foram confirmadas por evidência direta. As pendências reais restantes são de **validação em ambiente** (banco local com credenciais e Supabase remoto, que está DOWN por `hot standby`).

| Fase                       | Veredito                                                          |
| -------------------------- | ----------------------------------------------------------------- |
| Fase 1 — Banco/Mart/Views  | ✅ **Concluída** (núcleo) / ⚠️ desvio `vw_mapa_regional_completo` |
| Fase 2 — Schemas/Endpoints | ⚠️ **Parcial** (sazonalidade ✅; mapa/regiões ❌)                 |
| Fase 3 — Frontend          | ⚠️ **Parcial** (grade/cards ✅; mapa/polos ❌)                    |
| Fase 4 — Cleanup/Cache     | ✅ **Concluída**                                                  |

---

## FASE 1 — Modelagem e Restruturação de Banco de Dados

O plano citava como exemplo `database/60_refatoracao_dado_real_historico.sql`; a migração efetivamente usada foi **`database/63_dado_historico_real_transparencia.sql`** (32.782 B; `database/60_completar_fluxos_acai_castanha_melao.sql` é outro arquivo, para fluxos). O desvio de número é **cosmético e já conhecido**.

| #   | Claim do plano                                                         | Veredito                 | Evidência                                                                                                                                                                                                                                                                                                                                                                                                                      |
| --- | ---------------------------------------------------------------------- | ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1.1 | Inativar/substituir `sp_project_sandwich_prices_2026`                  | ✅ Confirmado            | `63:108-118` — sanduíche sazonal DESATIVADO; verificado por guard `SELECT EXISTS (... proname = 'sp_project_sandwich_prices_2026')`; não há mais `CALL`. Procedure mantida apenas como audit trail (`63:33-34`). V13 também: `63:105` `-- CALL staging.sp_calcular_forecast_2026_v13(); -- desativado`.                                                                                                                        |
| 1.2 | Fallback de Ano Âncora (2026 → 2025 → 2024 → dimensão)                 | ✅ Confirmado (dinâmico) | `63:281-292` — LATERAL âncora `r.ano BETWEEN EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER - 2 AND ... ORDER BY r.ano DESC LIMIT 1`; `63:277-278` rotula `REAL_ATUAL` (ano corrente) vs `HISTORICO_BASE`; prioridade 4 = `FALLBACK_DIMENSAO` no branch C da MV (`63:505-547`, `NOT EXISTS` em 551-556). Usa `CURRENT_DATE` (auto-ajustável para 2027), equivalente funcional ao 2026/2025/2024 hardcoded.                           |
| 1.3 | Colunas `ano_referencia` (INT) e `metadado_transparencia` (JSONB/TEXT) | ✅ Confirmado            | `63:149` — `ADD COLUMN IF NOT EXISTS metadado_transparencia JSONB`; populado no backfill `63:197-206` (`jsonb_build_object('fonte_dado', ..., 'procedencia', ..., 'calculado_em', ...)`); também na view âncora `63:310-315` e na MV `63:398/433`.                                                                                                                                                                             |
| 1.4 | Recriar MV `vw_api_produtos_sazonalidade` com as 7+ colunas            | ✅ Confirmado            | `63:357-568` — `DROP MATERIALIZED VIEW ... CASCADE` + `CREATE MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade` (3 branches UNION ALL) projetando `preco_exibido` (394), `preco_referencia` (379), `variacao_pct` (388/424), `status_cor` (384/420), `ano_referencia` (395/430), `tipo_dado` (396/431), `idade_dado_anos` (397/432), `metadado_transparencia` (398/433).                                                    |
| 1.5 | Recriar `mart.vw_mapa_regional_completo` com colunas de transparência  | ❌ **Desvio**            | `database/63` — **0 ocorrências** de `vw_mapa_regional_completo`. A view existe apenas na origem `database/46_mapa_regional_completo.sql:29`, **sem** colunas de transparência. Desvio **consciente e documentado**: decisão SDD D1 — "Fora de escopo (deferido): `mart.vw_mapa_regional_completo` (sem consumidores)" (`docs/RELATORIO_IMPLEMENTACAO_DADO_HISTORICO.md:65`, `openspec/.../design.md:7`, `proposal.md:14,21`). |
| 1.6 | Regra de cores ±25% comparando `preco_exibido` vs referência           | ✅ Confirmado            | `63:306-309` — `WHEN preco_exibido < preco_referencia * 0.75 THEN 'VERDE' / WHEN preco_exibido > preco_referencia * 1.25 THEN 'VERMELHO' / ELSE 'AMARELO'`; referência = AVG 12m real (`63:294`); `63:252-254` "semáforo ±25% inline, idêntico à fórmula 57:88".                                                                                                                                                               |

**Observação 1.6b:** `variacao_pct` na MV = `s.variacao_mom_pct` (`63:424`) — semântica de variação mês-a-mês (MoM) preservada, **não** redefinida como "âncora vs referência". Isso está alinhado ao design (`design.md:425`) e às specs, mas difere da redação literal do plano ("comparação de cor entre `preco_exibido` do mês e a referência"). Recomendo confirmar a semântica pretendida para `variacao_pct` com o change owner (D4/espec).

---

## FASE 2 — Schemas Pydantic e Endpoints

| #   | subs do plano                                                                                      | Veredito                  | Evidência                                                                                                                                                                                                                                                                                                                                                                                    |
| --- | -------------------------------------------------------------------------------------------------- | ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 2.1 | Schemas de Sazonalidade com `ano_referencia`/`tipo_dado`/`mensagem_transparencia`/`is_dado_legado` | ✅ Confirmado             | `backend/app/schemas/responses.py` — `SazonalidadeResponse` (101-109), `SazonalidadeComPrecoResponse` (183-191), `MesSazonalidade` (245-253): todos com `ano_referencia: int \| None`, `tipo_dado: str \| None`, `mensagem_transparencia: str \| None`, `is_dado_legado: bool = False`.                                                                                                      |
| 2.2 | Schema `MapaRegionalResponse` com os 4 campos (plano)                                              | ❌ **Não existe**         | Procura por `MapaRegional` em `backend/` → **0 resultados**. Schemas regionais atuais: `PoloInfo` (208), `RegiaoInfo` (218), `RegioesResponse` (229) — sem qualquer campo de transparência. Nota: o nome `MapaRegionalResponse` era exemplo do plano; o que importa é a ausência de transparência nos schemas regionais.                                                                     |
| 2.3 | Cards com os 4 campos                                                                              | ⚠️ Parcial                | Não existe classe `ProdutoCard`/`CardProduto` no backend; o card da UI usa `ProdutoVarejo` (`frontend/src/types/domain.ts:3,23-26`) que **tem** os 4 campos ✅. Porém `FlowItem` (`responses.py:280-313`) tem **apenas** `ano_referencia` (308-311) — faltam `tipo_dado`/`mensagem_transparencia`/`is_dado_legado`. `FlowItem` alimenta o mapa/polos de fluxo (exatamente a lacuna do mapa). |
| 2.4 | Endpoints de sazonalidade consumindo a MV sem cálculos pesados                                     | ✅ Confirmado             | Endpoints com `BASE_COLS`, `_compute_periodo_full`, `_compor_mensagem_transparencia` (ex: `backend/app/api/v1/endpoints/produtos.py:24`, `:231`, `:237/:414/:872`); read direto da MV.                                                                                                                                                                                                       |
| 2.5 | Endpoint `/api/v1/regioes` consumindo campos da MV                                                 | ❌ **Desvio (não tocou)** | `backend/app/api/v1/endpoints/regioes.py:15-26` — lê `config/regions.json` (estático), `RegiaoInfo(**r)` e retorna `RegioesResponse`; **nenhuma consulta ao banco** e nenhum campo de transparência.                                                                                                                                                                                         |

---

## FASE 3 — Frontend e Transparência (React / UI)

| #   | subs do plano                                                                                                   | Veredito                | Evidência                                                                                                                                                                                                                                                                                                                                                      |
| --- | --------------------------------------------------------------------------------------------------------------- | ----------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 3.1 | Componente `DataTransparencyInfo.tsx` (ícone (i) circulado + tooltip: ano âncora, badge, explicação, defasagem) | ✅ Confirmado           | `frontend/src/components/DataTransparencyInfo.tsx` existe (103 linhas).                                                                                                                                                                                                                                                                                        |
| 3.2 | Grade Sazonal (plan) preenchida sem quadros cinzas + badge `'25`/`'24` + ícone (i)                              | ✅ Confirmado           | Arquivo real é `frontend/src/components/SazonalidadeNacional.tsx` (não existe `GradeSazonal.tsx`). `:5` importa `DataTransparencyInfo`; `:56` "Badge de ano âncora: '26 (atual) / '25 / '24"; `:104-106` calcula `isLegado`; `:133-134` badge; `:137-142` `<DataTransparencyInfo ...>`; **sem** `GAP_STYLES`/`classifyGap` (quadros cinzas removidos).         |
| 3.3 | Cards de produtos com preço + data/ano no rodapé, sem badges sintéticos                                         | ✅ Confirmado           | `frontend/src/components/ProductCard.tsx` usa `DataTransparencyInfo`, sem 📊/🪄/Estimado. `SupermercadoView.tsx:476` badge "Grade com dados de {Y-2}–{Y}". `types/domain.ts` campos opcionais.                                                                                                                                                                 |
| 3.4 | Mapa Regional (`BrasilMap.tsx` / `RegiaoPanel.tsx`) com ícone (i) em rotas/polos                                | ❌ **Não concretizado** | `frontend/src/components/BrasilMap.tsx` (+1-4): imports `useState, motion, cn, FlowItem` — **sem** `DataTransparencyInfo`, `ano_referencia`, `tipo_dado` (445 linhas). `RegiaoPanel.tsx` (+1-6): imports `motion, Badge, lucide (X/MapPin/...)` — **sem** `DataTransparencyInfo`. O mapa mostra cores de região, dots de UF e arcos; **não expõe ano âncora**. |

---

## FASE 4 — Cleanup e Desempenho

| #   | subs do plano                                      | Veredito      | Evidência                                                                                                                                                                                                                                                                                                                          |
| --- | -------------------------------------------------- | ------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 4.1 | Inativar scripts sintéticos do pipeline            | ✅ Confirmado | `pipeline/run_bulk_historical_fill.py:56,854,859` `GuardIsForecastError` (aborta em vez de engolir erro quando `is_forecast`). Deploy `scripts/deploy_v13_si.sh` guard `is_forecast` pré/pós-CALL `:183-201` com `die`.                                                                                                            |
| 4.2 | Purge de cache API                                 | ✅ Confirmado | `pipeline/cache_purge.py:36 def purge_cache_sync`; `admin.py:152-153 /cache/clear` + `:24 _verify_api_key`; callers `persistence.py:92`, `run_scraper_historico.py:260`, `ingestao_conab_inteligente.py:423`; deploy seção 9 `PURGE_URL :243-245`. Validação ao vivo no relatório anterior: `POST /api/v1/admin/cache/clear` → ok. |
| 4.3 | Invalidação React Query (5 keys em `ETL_FINISHED`) | ✅ Confirmado | `frontend/src/hooks/useDataStream.ts:48` invalida `br-sazonalidade`, `hortifruti-meta`, `hortifruti-filter`, `sazonalidade-com-preco`, `regiao-resumo`.                                                                                                                                                                            |

---

## Testes Autônomos (executados na auditoria)

| Suíte                 | Resultado                            | Comando                                                                                         |
| --------------------- | ------------------------------------ | ----------------------------------------------------------------------------------------------- |
| Backend transparência | ✅ **14 passed** (0.43s)             | `pytest backend/tests/test_transparencia_dado_historico.py` (via python3 sistema, pytest 9.1.1) |
| Frontend vitest       | ✅ **25 passed** (3.89s, 4 arquivos) | `vitest run` (node_modules presente)                                                            |

Notas de ambiente:

- O `.venv` da raiz **não** tem pytest nem fastapi; os 14 testes rodaram via python do sistema.
- Banco local `mart.sazonalidade_produto` **não verificável** nesta auditoria — `psql` pede senha (`fe_sendauth: no password supplied`). A contagem de linhas da MV e o check de `status_cor` (relativos ao commit `3e3d224b`) ficam **pendentes de confirmação com credenciais**.

---

## Conclusão por Alinhamento ao Plano

| Item                                                            | Status                               |
| --------------------------------------------------------------- | ------------------------------------ |
| Fase 1 core (desativação, fallback, metadados, MV sazonalidade) | ✅ Concluído                         |
| Fase 1 vw_mapa_regional_completo                                | ❌ Deferido (decisão D1 documentada) |
| Fase 2 schemas sazonalidade/cards                               | ✅ Concluído                         |
| Fase 2 schema/endpoint de mapa/regiões                          | ❌ Não implementado                  |
| Fase 3 grade + cards + tooltip                                  | ✅ Concluído                         |
| Fase 3 mapa/rotas/polos                                         | ❌ Não implementado                  |
| Fase 4 cleanup + cache                                          | ✅ Concluído                         |
| Testes                                                          | ✅ Passando (14 back + 25 front)     |

---

## Recomendações e Pendências

1. **Decidir o destino do Mapa Regional** (lacuna única e recorrente). Opções: (a) manter deferido e remover as referências do mapa da claim do plano, documentando como não-escopo; (b) implementar `vw_mapa_regional_completo` + schema + `/regioes` + `BrasilMap`/`RegiaoPanel` (novo change SDD). A sugestão é **consultar o dono do produto** sobre a prioridade do mapa, já que não há consumidores hoje (motivo do deferimento D1).
2. **Confirmar semântica de `variacao_pct`** (MoM vs âncora-vs-referência) contra a redação do plano (2.1/2.2).
3. **Reajustar os relatórios** para refletir explicitamente que a claim "Mapa Regional e painel de fluxos com ícone (e)" **não foi entregue** — hoje o `RELATORIO_IMPLEMENTACAO_DADO_HISTORICO.md` marca Fases 1-4 ✅ sem essa nota de extinção na Fase 3 (a limitação "campos chegando None" para regiões está em `line 44`).
4. **Validações pendentes de ambiente** (não são falhas de código): quando o Supabase voltar (caí por `hot standby`), validar as migrações `000021`+`63` no remoto; rodar `verify_synthetic_off.sql` no remoto; repetir `POST /cache/clear` vivo e a E2E com banco de produção; confirmar contagens da MV V17 e `status_cor` com credenciais.
5. **Resíduo cosmético opcional**: `frontend/src/components/GameCard.tsx:119,142` ainda exibe `📊 Estimativa` / `🪄 Estimado`. Está **fora do escopo** das claims (componente de game, não `ProductCard`), mas se a intenção da refatoração era banir toda badge sintética, resta esse resíduo visível na UI.

---

## Decisão

Nenhuma implementação foi executada. Este relatório é a base para decisão do usuário:

- Se aprovar o escopo **atual** (com mapa deferido), os relatórios existentes podem ser ajustados apenas para a transparente na Fase 3 e seguir com revisão de release/push.
- Se quiser o **plano completo (incluindo mapa)**, um novo `change` SDD deve ser planejado para fechar a lacuna de Mapa/regiões nas camadas MV → schema → endpoint → frontend.
