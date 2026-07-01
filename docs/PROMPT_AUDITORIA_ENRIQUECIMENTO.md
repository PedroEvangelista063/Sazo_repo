# PROMPT_AUDITORIA_ENRIQUECIMENTO

## Escopo Geral

Auditar e enriquecer todo o projeto `quero_comprar_vg` — backend, frontend, pipeline, database, docs.
Cada etapa deve ser executada e validada antes de prosseguir.

---

## Etapa 1 — Limpeza de Artefatos

**O quê**: Remover lixo de build/cache do repositório.

- [ ] Deletar `__pycache__` recursivamente em `backend/`, `pipeline/`
- [ ] Deletar `.pytest_cache/`, `.ruff_cache/`, `.coverage`
- [ ] Verificar `.gitignore` — `__pycache__/`, `.ruff_cache/`, `.pytest_cache/`, `.coverage`, `.env` estão listados?
- [ ] Verificar se `.env` contém senhas hardcoded (deve ser .gitignored e usar `.env.example`)

## Etapa 2 — Backend Python (FastAPI)

**O quê**: Lint, tipo, segurança, cobertura.

- [ ] `ruff check backend/` — erros e avisos
- [ ] `ruff format --check backend/` — formatação
- [ ] Verificar se há `print()` ou `senha` hardcoded
- [ ] Testar `backend/` com `pytest` (se houver testes no backend)
- [ ] Verificar se `requirements.txt` tem deps não usadas ou faltantes

## Etapa 3 — Frontend TypeScript (React)

**O quê**: TypeScript strict, bundle, unused exports.

- [ ] `npm run lint` (tsc --noEmit) — erros de tipo
- [ ] `npm run build` — compilação completa
- [ ] Verificar imports não utilizados
- [ ] Verificar se `tsconfig.json` tem `noUnusedLocals` e `noUnusedParameters` (já tem)

## Etapa 4 — Pipeline Python

**O quê**: Qualidade dos dados, testes, cobertura.

- [ ] `ruff check pipeline/` — erros e avisos
- [ ] Executar `pytest utilities/teste_apication/pipeline/` — 42/43 passam?
- [ ] Verificar cobertura atual (2% — baixíssima, onde focar)
- [ ] Verificar se há `print()` ou `senha` hardcoded nos scripts de pipeline

## Etapa 5 — Database

**O quê**: Migrations, índices, segurança.

- [ ] Listar migrations e verificar se alguma está pendente
- [ ] Verificar se `GRANT` e permissões estão documentados
- [ ] Verificar se há dados sensíveis em schemas `public`

## Etapa 6 — Infra e Segurança

**O quê**: CORS, env vars, Docker, deploy.

- [ ] Verificar `CORS` no backend — origens permitidas usam env var?
- [ ] Verificar se `rate limiting` está configurado
- [ ] Verificar `.env.example` vs `.env` — estão sincronizados?
- [ ] Verificar `Dockerfile` ou `docker-compose` se existirem

## Etapa 7 — Documentação

**O quê**: Docs atualizadas, consistentes, sem erros.

- [ ] `docs/README.md` — instruções de setup ainda funcionam?
- [ ] `docs/AGENTS.md` — regras da casa condizem com o código atual?
- [ ] `docs/quero_comprar_plano_tecnico.md` — arquitetura reflete o código?
- [ ] `docs/SUMMARY.md` — índice cobre todos os módulos?
- [ ] `utilities/PROMPT_AUDITORIA_ENRIQUECIMENTO.md` — este documento está completo?

---

## Formato de Resposta por Etapa

```
## Etapa N — <nome>
**Status**: ✅ Completa | ❌ Falhou | ⏳ Parcial
**Issues**:
- <issue 1>
- <issue 2>
**Ações tomadas**:
- <ação 1>
- <ação 2>
**Continuar?** [s/N]
```
