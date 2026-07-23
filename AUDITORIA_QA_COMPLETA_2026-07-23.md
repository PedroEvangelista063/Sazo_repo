# Auditoria QA Senior — Relatório Completo

**Projeto:** `quero_comprar_vg`
**Data:** 23/07/2026
**Auditor:** OpenCode (QA Engineer Senior)
**Branch:** `hound/pr-2-daemon-engine` (base: `main`)
**Ambiente:** Linux Mint XFCE 22.3

---

## Índice

1. [Resumo Executivo](#1-resumo-executivo)
2. [Estrutura Macro do Projeto](#2-estrutura-macro-do-projeto)
3. [Pastas Órfãs e Arquivos Soltos na Raiz](#3-pastas-órfãs-e-arquivos-soltos-na-raiz)
4. [Configurações Incorretas ou Incompletas](#4-configurações-incorretas-ou-incompletas)
5. [Rastros de Windows](#5-rastros-de-windows)
6. [Instalações Incompletas — Agents e Skills](#6-instalações-incompletas--agents-e-skills)
7. [SDD (OpenSpec) e Skills](#7-sdd-openspec-e-skills)
8. [Problemas de Segurança](#8-problemas-de-segurança)
9. [Arquivos Temporários e Lixo Técnico](#9-arquivos-temporários-e-lixo-técnico)
10. [Relatório de Melhorias para OpenCode](#10-relatório-de-melhorias-para-opencode)
11. [Recomendações de Organização — Linux Mint XFCE 22.3](#11-recomendações-de-organização--linux-mint-xfce-223)
12. [Plano de Ação Priorizado](#12-plano-de-ação-priorizado)

---

## 1. Resumo Executivo

| Indicador | Status |
|-----------|--------|
| **Saúde geral do projeto** | 🟡 **Moderada** — Código funcional, mas com acúmulo técnico significativo |
| **Estrutura de diretórios** | 🟢 Boa — Monorepo bem segmentado (backend, frontend, pipeline, database) |
| **Configurações de ferramentas** | 🟡 Regular — Várias configs soltas, algumas incompletas |
| **Segurança** | 🔴 **Crítica** — Token GitHub exposto em plaintext |
| **Rastros de Windows** | 🟡 Médio — Paths absolutos em arquivos de configuração |
| **Agents/Skills** | 🟡 Regular — Duplicatas, locks órfãos, skill desatualizada |
| **Lixo técnico** | 🔴 **Alto** — 7.3 GB de IDE embarcada, dezenas de arquivos temporários |
| **Organização geral** | 🟡 Pode melhorar — Mista entre Linux e Windows, caches e logs misturados |

### Problemas Críticos (resolver imediatamente)

1. **🔴 Token GitHub exposto** em `opencode.jsonc` e `.mcp.json`
2. **🔴 AGENT_SUPORTT/** — 7.3 GB de IDE externa dentro do projeto, sem `.gitignore`
3. **🔴 .env e backend/.env trackeados no git** — credenciais versionadas
4. **🟡 Ícones PWA ausentes** — `vite.config.ts` referencia arquivos que não existem

---

## 2. Estrutura Macro do Projeto

```
quero_comprar_vg/                        # Raiz — monorepo
├── backend/                             # FastAPI (Python)
├── frontend/                            # React 19 + Vite PWA
├── pipeline/                            # ETL, scrapers, ML forecast
├── database/                            # Migrações SQL + backups
├── supabase/                            # Config + 12 migrations
├── config/                              # JSON de fontes, regiões, fluxos
├── docs/                                # Documentação + reports
├── scripts/                             # Restore e sync tools
├── openspec/                            # SDD artifacts
├── utilities/                           # Scripts de diagnóstico
├── tests/                               # Testes Python (untracked)
│
├── .agents/                             # Skills Supabase (OpenCode)
├── .claude/                             # Skills Supabase (duplicata)
├── .config/opencode/                    # Config principal de agents
├── .opencode/                           # Runtime OpenCode (node_modules)
├── .mimocode/                           # Runtime MiMoCode
├── AGENT_SUPORTT/                       # ⚠️ 7.3 GB IDE externa
│
├── node_modules/                        # Root (ferramentas CLI)
├── package.json / tsconfig.json         # Root config
├── opencode.jsonc / .mcp.json           # MCP servers
├── pyproject.toml                       # Python config
└── skills-lock.json                     # Skill registry lock
```

**Avaliação:** A separação em módulos (backend, frontend, pipeline, database) é excelente. O problema está na **camada de ferramentas/agents** — múltiplos diretórios concorrentes (`.agents/`, `.claude/`, `.config/opencode/`, `.opencode/`, `.mimocode/`, `AGENT_SUPORTT/`) criam confusão e duplicação.

---

## 3. Pastas Órfãs e Arquivos Soltos na Raiz

### 3.1 Pastas Órfãs (vazias ou sem propósito claro)

| Pasta | Problema | Ação |
|-------|----------|------|
| `.hound_cache/` | Vazia | Remover |
| `frontend/public/assets/images/produtos/` | Vazia | Remover ou criar `.gitkeep` se planejada |
| `frontend/public/images/produtos/` | Vazia | Remover ou criar `.gitkeep` |
| `pipeline/scraper/site_maps/` | Só `.gitkeep` | Avaliar se ainda é necessária |
| `.test_cache_norm/`, `_norm2/`, `_notok/`, `_dedup/`, `_phases/` | Artefatos de teste vazios | Remover |
| `.git/refs/tags/` | Vazia (sem tags) | Normal — sem ação |

### 3.2 Arquivos Soltos na Raiz

| Arquivo | Problema | Ação |
|---------|----------|------|
| `api_stderr.log` (200B) | Log runtime | Adicionar ao `.gitignore` |
| `api_stdout.log` (1KB) | Log runtime | Adicionar ao `.gitignore` |
| `uvicorn_stderr.log` (16KB) | Log runtime | Adicionar ao `.gitignore` |
| `.coverage` (binário) | Cobertura Python | Adicionar ao `.gitignore` |

### 3.3 Duplicação de Skills

```
.agents/skills/supabase/          # Idêntico
.claude/skills/supabase/          # Idêntico (duplicata)
.agents/skills/supabase-postgres-best-practices/   # Idêntico
.claude/skills/supabase-postgres-best-practices/   # Idêntico (duplicata)
```

**Ação:** Remover `.claude/` se não for mais usado, ou criar symlink. Manter apenas em `.agents/`.

---

## 4. Configurações Incorretas ou Incompletas

### 4.1 `pyproject.toml` — Test Path Inválido

```toml
[tool.pytest.ini_options]
testpaths = "utilities/teste_apication/pipeline"   # ❌ Não existe
```

O diretório correto seria `tests/` ou `utilities/teste_apication/`. Isso faz o `pytest` falhar ao tentar descobrir testes automaticamente.

### 4.2 Frontend — Ícones PWA Ausentes

O `vite.config.ts` usa `vite-plugin-pwa` e define no manifest:
- `icons/icon-192x192.png`
- `icons/icon-512x512.png`
- `icons/icon-192x192-maskable.png`
- `icons/icon-512x512-maskable.png`

Nenhum destes arquivos existe em `frontend/public/`. Apenas `favicon.svg` e `br-map.svg` estão presentes.

**Impacto:** O PWA instala mas sem ícones adequados. Aparência quebrada no celular.

### 4.3 `.opencode/.gitignore` — Arquivos Trackados Apesar do Ignore

O `.opencode/.gitignore` lista `package.json`, `package-lock.json` e `node_modules` como ignorados, mas estes arquivos estão no disco e parecem ter sido commitados antes da regra.

### 4.4 Root `package.json` — Sem `name` ou `version`

```json
{
  "private": true,
  "scripts": { ... }
}
```

Funcional, mas quebra ferramentas que esperam `name`. Adicionar:
```json
"name": "quero-comprar-vg",
"version": "0.1.0"
```

### 4.5 Sem `Makefile` ou `Taskfile`

Não há um arquivo de task runner na raiz. Os comandos estão espalhados entre `package.json`, `pyproject.toml` e `scripts/`. Um `Makefile` simplificaria:
- `make dev` — sobe backend + frontend
- `make test` — roda todos os testes
- `make lint` — ruff + prettier
- `make clean` — limpa caches e artefatos

---

## 5. Rastros de Windows

### 5.1 Paths Absolutos Windows em Arquivos

| Arquivo | Path Windows | Risco |
|---------|-------------|-------|
| `.atl/skill-registry.md` | `C:\Users\inven\.agents\skills\...` (múltiplas ocorrências) | Baixo — só documentação |
| `.atl/skill-registry.md` | `D:\D\PROJETOS EM ANDAMENTO\quero_comprar_vg\.claude\skills\...` | Baixo |
| `.codex/config.toml` | `D:\D\PROJETOS EM ANDAMENTO\Extrator_Pdf\.codex\engram-instructions.md` | Baixo — config de outra ferramenta |
| `AGENT_SUPORTT/.codex/config.toml` | `C:\\Users\\inven/.codex/engram-instructions.md` | Baixo — dentro da IDE externa |
| `database/processed_data/summary.json` | `D:\D\PROJETOS EM ANDAMENTO\quero_comprar_vg\...` | Baixo — metadado |
| `AGENT_SUPORTT/.cache/puppeteer/` | `vk_swiftshader_icd.json` com `\\vk_swiftshader.dll` | Baixo — dentro da IDE externa |

### 5.2 Scripts PowerShell

- `scripts/setup_organism.ps1` — Script PowerShell legado
- Vários `.ps1` dentro de `AGENT_SUPORTT/` e `node_modules/`

### 5.3 Linhas `CRLF`?

**Não foram encontradas** linhas CRLF em arquivos de código do projeto. Apenas em `node_modules/` (normal). ✅

### 5.4 `Thumbs.db` ou `desktop.ini`?

**Nenhum encontrado.** ✅

**Ação:** Não crítico, mas o `.atl/skill-registry.md` idealmente deveria ser regenerado no Linux para remover referências Windows.

---

## 6. Instalações Incompletas — Agents e Skills

### 6.1 `AGENT_SUPORTT/.agents/` — Lock Órfão

```
AGENT_SUPORTT/.agents/
  .skill-lock.json          # ✅ Existe
  skills/                   # ❌ VAZIO (0 skills instaladas)
```

O `.skill-lock.json` referencia duas skills que **nunca foram baixadas**:
- `microsoft-foundry` (fonte: `microsoft/azure-skills`)
- `find-skills` (fonte: `vercel-labs/skills`)

**Status:** Instalação interrompida ou migração incompleta.

### 6.2 Skill `supabase` — Desatualizada

| Skill | Local | Atual |
|-------|-------|-------|
| `supabase` | v0.1.2 | v0.1.5 (3 patches atrás, publicado 2026-07-10) |

O `CHANGELOG.md` mostra que há atualizações, mas o `skills-lock.json` ainda aponta para o hash antigo.

### 6.3 `.claude/` vs `.agents/` — Duplicata

Conteúdo 100% idêntico. O OpenCode usa `.agents/`; o `.claude/` é legado do Claude Code. Em Linux, apenas `.agents/` é relevante.

---

## 7. SDD (OpenSpec) e Skills

### 7.1 Ciclo SDD Instalado

O projeto tem um pipeline SDD completo com 11 sub-agentes:

```
sdd-init → sdd-explore → sdd-design → sdd-spec → sdd-propose
→ sdd-tasks → sdd-apply → sdd-verify → sdd-archive
+ sdd-onboard (guia), gentle-orchestrator (coordena)
```

**Slash commands disponíveis:** `sdd-new`, `sdd-init`, `sdd-explore`, `sdd-ff`, `sdd-apply`, `sdd-verify`, `sdd-archive`, `sdd-continue`, `sdd-status`, `sdd-onboard`, `skill-creator`, `skill-registry`.

### 7.2 OpenSpec Changes Ativos

| Change | Status |
|--------|--------|
| `forecast-ponderado-2025/` | ✅ Completo (proposal, spec, design, tasks, verify, archive) |
| `hound-master-fetch-integration/` | 🔄 Em progresso (proposal, design, tasks) |
| `filtro-regional-mapa/` | 📁 Diretório vazio |

### 7.3 Skill Lock

`skills-lock.json` na raiz registra corretamente as skills `supabase` e `supabase-postgres-best-practices`. O `.atl/skill-registry.md` (auto-gerado) contém o índice completo.

**Avaliação:** O ecossistema SDD está maduro e bem configurado. O problema não está no SDD em si, mas na **duplicação e arquivos órfãos ao redor dele**.

---

## 8. Problemas de Segurança

### 🔴 CRÍTICO: Token GitHub em Plaintext

**Arquivos afetados:**
- `opencode.jsonc` — `"GITHUB_PERSONAL_ACCESS_TOKEN": "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"`
- `.mcp.json` — mesmo token

**Risco:** Qualquer pessoa com acesso ao repositório pode usar este token para:
- Acessar repositórios privados do GitHub
- Fazer push, criar issues, ler dados
- O token está em uma branch com untracked files que pode ser commitada

**Ação IMEDIATA:**
1. Rotacionar o token no GitHub (revogar imediatamente)
2. Remover dos arquivos de configuração
3. Usar variável de ambiente `${GITHUB_TOKEN}` nos MCP configs

### 🔴 CRÍTICO: `.env` e `backend/.env` Trackeados no Git

`git ls-files` mostra que `.env` e `backend/.env` estão no índice do git. Mesmo com `.gitignore`, arquivos já trackeados continuam sendo versionados.

**Ação:**
```bash
git rm --cached .env backend/.env
echo ".env" >> .gitignore
git commit -m "chore: remove .env files from tracking"
```

---

## 9. Arquivos Temporários e Lixo Técnico

### 9.1 Scripts `_tmp_*` em `scripts/sync/`

12 arquivos com prefixo `_tmp_` — claramente temporários de desenvolvimento:
- `_tmp_add_v15_cols.sql`, `_tmp_check_cols.py`, `_tmp_cols.py`, `_tmp_cols2.py`, `_tmp_dump_data.py`, `_tmp_fix_dim_produto.sql`, `_tmp_fix_schema.py`, `_tmp_fn_sazonalidade.sql`, `_tmp_func31.sql`, `_tmp_gen_sync.py`, `_tmp_indices.sql`, `_tmp_mv31.sql`

**Tamanho:** ~32 KB no total.
**Ação:** Mover para `docs/archive/` ou remover após validar se ainda são necessários.

### 9.2 Logs de Scraping em `utilities/logs/scraping_failures/`

70 arquivos `.html` + `.json` (14 MB) — páginas HTML inteiras de erro do CEAGESP capturadas em 29/06/2026.

**Ação:** Mover para armazenamento externo ou comprimir. Não deveriam estar no repositório.

### 9.3 Arquivos de Log na Raiz

`api_stderr.log`, `api_stdout.log`, `uvicorn_stderr.log` — logs do servidor que vazaram para a raiz.

**Ação:** Adicionar ao `.gitignore` e deletar.

### 9.4 `.test_cache_*` Diretórios

7 diretórios vazios ou quase vazios com nomes sugestivos de testes de cache:
`.test_cache_corrupt/`, `.test_cache_err/`, `.test_cache_hit/`, `.test_cache_norm/`, `.test_cache_norm2/`, `.test_cache_notok/`, `.test_dedup/`, `.test_phases/`

**Ação:** Remover — são artefatos de desenvolvimento.

### 9.5 Pipeline Hound Module (Untracked)

`pipeline/scraper/hound/` — novo módulo do motor de busca (untracked). Código novo e intencional, então **não é lixo**. Mas precisa ser revisado antes do commit.

---

## 10. Relatório de Melhorias para OpenCode

### 10.1 Acessibilidade do OpenCode ao Projeto

Atualmente o OpenCode consegue acessar o projeto, mas há **ruído excessivo** devido a:

**Problema 1: Diretórios concorrentes de agentes**
```
.agents/          # Skills oficiais (OpenCode)
.claude/          # ⚠️ Duplicata do .agents/
.config/opencode/ # Config principal de agents (opencode.json + skills)
.opencode/        # Runtime plugin + node_modules
.mimocode/        # Runtime de outro IDE
AGENT_SUPORTT/    # ⚠️ 7.3 GB IDE externa
```

**Recomendação:** Unificar o ecossistema de agents:
- Manter apenas `.agents/` para skills (remover `.claude/`)
- Manter `.config/opencode/` como config de agents (já é o padrão)
- Manter `.opencode/` como runtime (necessário para plugins)
- Remover `.mimocode/` e `AGENT_SUPORTT/` do projeto (ou adicionar ao `.gitignore`)

**Problema 2: Múltiplos arquivos de config MCP**
```
opencode.jsonc   # Config MCP no projeto
.mcp.json        # Config MCP alternativa (duplicata)
```

**Recomendação:** Usar apenas um. Ambos parecem ter o mesmo propósito. Definir qual é o oficial e remover o outro.

**Problema 3: `docs/` confuso com configs de agente**
- `docs/AGENTS.md` — Regras do projeto (útil)
- `.config/opencode/AGENTS.md` — Persona do OpenCode (útil)
Os dois têm o mesmo nome mas propósitos diferentes. Renomear `docs/AGENTS.md` para `docs/PROJECT_RULES.md` evitaria confusão.

### 10.2 Otimizações para o OpenCode neste Projeto

1. **Criar `AGENTS.md` na raiz** com um resumo curto do projeto (tech stack, estrutura de diretórios, comandos principais) — o OpenCode lê este arquivo automaticamente se existir na raiz.

2. **Adicionar `make` commands** com target `dev`, `test`, `lint`, `clean` para o OpenCode poder executar tarefas com um comando simples.

3. **Limpar o `.atl/skill-registry.md`** das referências Windows — o auto-registro do OpenCode pode se confundir com paths de outra máquina.

4. **Review de `pyproject.toml`** — O `testpaths` inválido pode fazer o OpenCode falhar ao tentar rodar testes.

5. **GitHub MCP** — Trocar o token hardcoded por `${GITHUB_TOKEN}` environment variable para não expor secrets.

---

## 11. Recomendações de Organização — Linux Mint XFCE 22.3

### 11.1 Estrutura de Diretórios (Estado Atual vs. Recomendado)

O projeto atualmente está em um disco montado:
```
/media/pedroeduardo/E41687D11687A362/D/PROJETOS EM ANDAMENTO/quero_comprar_vg/
```

**Recomendação de organização para Linux:**

#### Opção A: Manter no local atual (se o disco é externo/HD)

A estrutura atual é funcional. Apenas **limpar o que não pertence**:

```
/media/pedroeduardo/E41687D11687A362/D/PROJETOS EM ANDAMENTO/quero_comprar_vg/
├── backend/          # ✅ OK
├── frontend/         # ✅ OK
├── pipeline/         # ✅ OK
├── database/         # ✅ OK
├── supabase/         # ✅ OK
├── config/           # ✅ OK
├── docs/             # ✅ OK (limpar archive/ se desatualizado)
├── openspec/         # ✅ OK
├── scripts/          # ⚠️ Limpar _tmp_*
├── utilities/        # ⚠️ Limpar logs de scraping
├── tests/            # ✅ OK
│
├── .agents/          # ✅ Manter
├── .config/opencode/ # ✅ Manter
├── .opencode/        # ✅ Manter (necessário para plugins OpenCode)
│
├── .claude/          # ❌ Remover (duplicata)
├── .mimocode/        # ⚠️ Remover ou gitignorar (IDE concorrente não usada)
├── AGENT_SUPORTT/    # ❌ Remover (7.3 GB de IDE externa)
```

#### Opção B: Migrar para `~/projects/` (padrão Linux)

Mover o projeto para `~/projects/quero_comprar_vg` para:
- Paths mais curtos e sem caracteres especiais
- Sem dependência de disco montado
- Permissões padrão do usuário
- Snapshots e backups mais fáceis

```
~/projects/quero_comprar_vg/
```

### 11.2 Configuração Recomendada de `.gitignore` para Linux

```gitignore
# === OS ===
Thumbs.db
desktop.ini
.DS_Store

# === IDE External (NÃO pertencem ao projeto) ===
AGENT_SUPORTT/
.mimocode/
.claude/

# === Logs ===
*.log
api_*.log
uvicorn_*.log

# === Coverage ===
.coverage
.coverage.*

# === Test artifacts ===
.test_cache_*

# === Python ===
__pycache__/
*.py[cod]
.ruff_cache/
.pytest_cache/

# === Node ===
node_modules/

# === Env ===
.env
backend/.env
```

### 11.3 Script de Limpeza Inicial (`make clean`)

Criar um target `make clean` que:
```makefile
clean:
	rm -rf .test_cache_*/ .hound_cache/ .ruff_cache/ .pytest_cache/
	rm -f api_*.log uvicorn_*.log .coverage
	rm -rf utilities/logs/scraping_failures/
	find . -type d -empty -not -path './node_modules/*' -not -path './.git/*' -delete
```

---

## 12. Plano de Ação Priorizado

### 🔴 Fase 1 — Imediata (segurança e integridade)

| # | Ação | Esforço | Impacto |
|---|------|---------|---------|
| 1 | Revogar token GitHub e substituir por env var | 10 min | 🔴 Crítico |
| 2 | `git rm --cached .env backend/.env` | 5 min | 🔴 Crítico |
| 3 | Adicionar `AGENT_SUPORTT/` ao `.gitignore` | 2 min | 🔴 Crítico |
| 4 | Remover ou mover `AGENT_SUPORTT/` para fora do projeto | 30 min | 🔴 Crítico (recupera 7.3 GB) |

### 🟡 Fase 2 — Curto Prazo (configurações e limpeza)

| # | Ação | Esforço | Impacto |
|---|------|---------|---------|
| 5 | Corrigir `testpaths` no `pyproject.toml` | 2 min | 🟡 Médio |
| 6 | Gerar ícones PWA e colocar em `frontend/public/` | 15 min | 🟡 Médio |
| 7 | Remover `_tmp_*` de `scripts/sync/` (após validar) | 10 min | 🟡 Médio |
| 8 | Remover `.claude/` (duplicata) | 2 min | 🟢 Baixo |
| 9 | Limpar `utilities/logs/scraping_failures/` | 5 min | 🟢 Baixo |
| 10 | Remover `.test_cache_*` vazios | 2 min | 🟢 Baixo |
| 11 | Adicionar `*.log` ao `.gitignore` | 2 min | 🟢 Baixo |

### 🟢 Fase 3 — Médio Prazo (organização)

| # | Ação | Esforço | Impacto |
|---|------|---------|---------|
| 12 | Criar `Makefile` com targets principais | 20 min | 🟡 Médio |
| 13 | Adicionar `name`/`version` ao `package.json` raiz | 2 min | 🟢 Baixo |
| 14 | Regenerar `.atl/skill-registry.md` no Linux | 5 min | 🟢 Baixo |
| 15 | Atualizar skill `supabase` para v0.1.5 | 10 min | 🟢 Baixo |
| 16 | Renomear `docs/AGENTS.md` → `docs/PROJECT_RULES.md` | 2 min | 🟢 Baixo |
| 17 | Consolidar `opencode.jsonc` e `.mcp.json` em um só | 10 min | 🟢 Baixo |
| 18 | Decidir: migrar projeto para `~/projects/` ou manter no HD externo | — | — |

---

## Apêndice A: Inventário de Arquivos por Categoria

| Categoria | Quantidade | Tamanho |
|-----------|-----------|---------|
| Código fonte (backend + frontend + pipeline) | ~200 arquivos | ~50 MB |
| Migrações e SQL | ~50 arquivos | ~5 MB |
| Documentação | ~25 arquivos | ~500 KB |
| Configurações | ~30 arquivos | ~200 KB |
| Scripts temporários (`_tmp_*`) | 12 arquivos | 32 KB |
| Logs de scraping | 70 arquivos | 14 MB |
| IDE externa (`AGENT_SUPORTT/`) | Milhares | **7.3 GB** |
| Runtime agents (`.opencode/`, `.mimocode/`) | ~500 arquivos | ~116 MB |
| Cache e artefatos de teste | ~10 diretórios | ~5 MB |

---

## Apêndice B: Comandos de Limpeza Rápida

```bash
# Revogar token (FAÇA ISSO NO GITHUB PRIMEIRO)
# Depois:
git rm --cached .env backend/.env
git rm --cached opencode.jsonc .mcp.json  # editar antes para remover o token

# Remover lixo técnico
rm -rf .test_cache_* .hound_cache/
rm -f api_stderr.log api_stdout.log uvicorn_stderr.log .coverage
rm -f utilities/logs/scraping_failures/*.html utilities/logs/scraping_failures/*.json

# Remover duplicatas
rm -rf .mimocode/
rm -rf .claude/

# Remover scripts temporários (após validar)
rm scripts/sync/_tmp_*

# Adicionar ao .gitignore
echo -e "\n# IDE externa\nAGENT_SUPORTT/\n\n# Logs\n*.log\n\n# Coverage\n.coverage" >> .gitignore
```

---

*Relatório gerado por OpenCode em 23/07/2026. Auditoria completa do projeto `quero_comprar_vg` para Linux Mint XFCE 22.3.*
