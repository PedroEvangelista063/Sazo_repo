# Plano de Correção e Implementação Sênior — Resolução dos Gaps na Grade Sazonal

Corrigir a lacuna de informações na view do frontend **Grade Sazonal** (`SazonalidadeNacional.tsx`), onde dados de meses e produtos eram sumariamente descartados pela trava estrita de agregação SQL `HAVING COUNT(DISTINCT upm.uf) >= 3` e por lacunas de cobertura.

A solução eleva a resiliência da arquitetura em 3 níveis:

1. **Banco de Dados (SQL)**: Parametrização e flexibilização da função `mart.fn_br_nacional_sazonalidade` para aceitar limite mínimo flexível de UFs (padrão `min_ufs = 1`), eliminando a perda cega de produtos/meses válidos.
2. **Backend (FastAPI)**: Suporte ao parâmetro `min_ufs` na rota `GET /api/v1/sazonalidade/br-sazonalidade` preservando concorrência e cache de alta performance.
3. **Frontend (React/UI)**: Melhoria de UX em `SazonalidadeNacional.tsx` para apresentar tooltips explicativas em células com baixa cobertura e dados com estimativa/forecast.

---

## User Review Required

> [!IMPORTANT]
> A alteração no banco de dados mudará o comportamento padrão de `mart.fn_br_nacional_sazonalidade`. Produtos com dados em apenas 1 ou 2 UFs passarão a ser exibidos na Grade Sazonal Nacional em vez de serem omitidos.
> No frontend, essas células serão diferenciadas visualmente via tooltip e indicador de transparência para não comprometer a confiabilidade da informação.

> [!NOTE]
> Esta alteração não requer re-ingestão de dados nem REFRESH demorado da Materialized View, agindo diretamente sobre a função de consulta rápida.

---

## Open Questions

> [!TIP]
> Deseja que a ordenação da Grade Sazonal priorize produtos com maior cobertura nacional (`total_ufs DESC`) ou permaneça em ordem alfabética (`produto ASC`)?

---

## Proposed Changes

### Banco de Dados (PostgreSQL / Supabase Migration)

---

#### [NEW] [000016_fix_grade_sazonal_min_ufs.sql](file:///home/pedroeduardo/projetos/sazo_brasil/supabase/migrations/000016_fix_grade_sazonal_min_ufs.sql)

- Criar migration SQL parametrizando `mart.fn_br_nacional_sazonalidade(p_ano, p_categoria, p_min_ufs DEFAULT 1)`.
- Alterar a cláusula `HAVING COUNT(DISTINCT upm.uf) >= p_min_ufs`.
- Atualizar permissões de `GRANT EXECUTE` para as roles do banco.

#### [MODIFY] [31_remove_year_filter_mv.sql](file:///home/pedroeduardo/projetos/sazo_brasil/database/31_remove_year_filter_mv.sql)

- Atualizar a definição de referência da função `mart.fn_br_nacional_sazonalidade` para manter o repositório sincronizado.

---

### Backend (FastAPI B2C)

---

#### [MODIFY] [responses.py](file:///home/pedroeduardo/projetos/sazo_brasil/backend/app/schemas/responses.py)

- Atualizar o schema `SazonalidadeNacionalItem` e `SazonalidadeNacionalResponse` se novos campos de metadados forem expostos.

#### [MODIFY] [produtos.py](file:///home/pedroeduardo/projetos/sazo_brasil/backend/app/api/v1/endpoints/produtos.py)

- Atualizar a rota `GET /api/v1/sazonalidade/br-sazonalidade` para receber o query param opcional `min_ufs: int = Query(1, ge=1, le=27)`.
- Atualizar a chamada à função SQL `mart.fn_br_nacional_sazonalidade($1, $2, $3)` e compor a chave de cache MD5 considerando `min_ufs`.

---

### Frontend (React / Tailwind UI)

---

#### [MODIFY] [domain.ts](file:///home/pedroeduardo/projetos/sazo_brasil/frontend/src/types/domain.ts)

- Atualizar os tipos `SazonalidadeNacionalItem` e `MesSazonalidade` se aplicável.

#### [MODIFY] [useHortifruti.ts](file:///home/pedroeduardo/projetos/sazo_brasil/frontend/src/hooks/useHortifruti.ts)

- Passar o parâmetro `min_ufs` na requisição `api.get('/sazonalidade/br-sazonalidade', ...)` se necessário.

#### [MODIFY] [SazonalidadeNacional.tsx](file:///home/pedroeduardo/projetos/sazo_brasil/frontend/src/components/SazonalidadeNacional.tsx)

- Atualizar a renderização das células:
  - Células sem dados (`!mesData`): adicionar tooltip "Sem dados coletados para este mês".
  - Células com baixa cobertura (`total_ufs < 3`): exibir indicador sutil e tooltip "Cobertura parcial (X UFs)".

---

## Verification Plan

### Automated Tests

- Executar testes de endpoint do backend com pytest:
  ```bash
  npm run db:test:remote
  ```
- Executar suíte de testes unitários do frontend com Vitest:
  ```bash
  cd frontend && npx vitest run
  ```

### Manual Verification

- Acessar o ambiente de desenvolvimento local (`npm run dev:all`).
- Navegar para a view **Grade Sazonal** na interface.
- Verificar que produtos que antes exibiam lacunas por terem poucas UFs agora apresentam preenchimento correto e tooltips informativos de transparência.
