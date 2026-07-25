# Melhorias no Sistema de Agentes OpenCode

> **Data:** 2026-07-25
> **Propósito:** Documentar todas as melhorias implementadas no ecossistema OpenCode — roteamento, agentes, plugins, otimização de tokens e roteamento multi-modelo

---

## Sumário

1. [Visão Geral](#1-visão-geral)
2. [Roteamento de Agentes](#2-roteamento-de-agentes)
3. [Instalação do opencode-history-search](#3-instalação-do-opencode-history-search)
4. [Instalação de Agentes via agentget](#4-instalação-de-agentes-via-agentget)
5. [Otimização de Tokens](#5-otimização-de-tokens)
   - [5.1 Desativação de Auto-Spawning](#51-desativação-de-auto-spawning)
   - [5.2 Limite de Saída de Ferramentas](#52-limite-de-saída-de-ferramentas)
   - [5.3 Compaction Pruning](#53-compaction-pruning)
   - [5.4 Dynamic Context Pruning (DCP)](#54-dynamic-context-pruning-dcp)
   - [5.5 Snippet Mínimo Token-Saver](#55-snippet-mínimo-token-saver)
   - [5.6 Popular Picks](#56-popular-picks)
6. [Roteamento Multi-Agente e Multi-Modelo](#6-roteamento-multi-agente-e-multi-modelo)
7. [Arquivos de Configuração Modificados/Criados](#7-arquivos-de-configuração-modificadoscriados)
8. [Status da Configuração](#8-status-da-configuração)
9. [Como Usar](#9-como-usar)
   - [Sub-Agentes via @mention](#91-sub-agentes-via-mention)
   - [Sub-Agentes via task (orquestrador)](#92-sub-agentes-via-task-orquestrador)
   - [Busca no Histórico](#93-busca-no-histórico)
   - [Revisão de Código Especializada](#94-revisão-de-código-especializada)
10. [Apêndice A: Stack Tecnológico do Projeto](#10-apêndice-a-stack-tecnológico-do-projeto)
11. [Apêndice B: Como Verificar](#11-apêndice-b-como-verificar)

---

## 1. Visão Geral

Foram implementadas quatro grandes frentes de melhoria no ecossistema OpenCode deste projeto:

1. **Roteamento de Agentes** — Tabela no `AGENTS.md` que mapeia gatilhos a agentes especializados, permitindo que o orquestrador delegue tarefas ao agente mais adequado.
2. **opencode-history-search** — Plugin/tool que permite buscar no histórico de conversas do OpenCode com keyword, regex ou fuzzy search.
3. **agentget** — Gerenciador de pacotes de agentes de IA que instalou 67 agentes especializados do repositório `affaan-m/everything-claude-code`.
4. **Otimização de Tokens** — Conjunto de configurações e plugins para reduzir consumo de tokens, economizar contexto e baixar custos: `subagent_depth`, `tool_output`, `compaction.prune`, DCP, e roteamento multi-modelo.

As alterações foram aplicadas em:
- `~/.config/opencode/opencode.json` — Configurações globais
- `~/.config/opencode/AGENTS.md` — Documentação e referência no prompt do orquestrador
- `~/.config/opencode/agents/` — Sub-agentes customizados e otimizados
- `~/.opencode/tool/` — Plugins instalados (history-search)
- `.agents/agents/` — Agentes do agentget (canonical)
- `docs/MELHORIAS_SISTEMA_AGENTES.md` — Este documento

---

## 2. Roteamento de Agentes

### 2.1 Tabela de Roteamento Principal

A tabela de roteamento foi adicionada ao arquivo `~/.config/opencode/AGENTS.md` na seção `<!-- gentle-ai:agent-routing -->`.

| Gatilho | Agente | Notas |
|---|---|---|
| Buscando por código, arquivos, símbolos, padrões | `finder` | Pesquisa rápida somente leitura via glob/grep |
| Exploração minuciosa da base de código | `explore` | Análise profunda, média/muito minuciosa |
| Após escrever ou modificar qualquer código | `lint`, `tester`, `security-auditor` | Lint, verificação de tipo, teste, auditoria de segurança |
| Após concluir um marco (feature/fix/refactor) | `git-helper` | Blame, log, diff, operações de branch |
| Gerando mensagens de commit a partir de diffs do git | `git-helper` | Usa `git diff --cached` |
| Executando comandos de shell, testes, compilações | `general` | Tarefas de shell em múltiplas etapas |
| Buscando URLs ou realizando buscas web | `general` | Usa ferramentas webfetch/websearch |
| Analisando arquivos de log (JSONL, structlog, stderr) | `summarizer` | Compactar saídas longas |
| Convertendo formatos de dados, validando esquemas | `general` | — |
| Testando endpoints HTTP, verificando saúde do serviço | `general` | — |
| Escrevendo ou executando testes | `tester` | Executar testes e analisar falhas |
| Consultas SQL contra SQLite ou Postgres | `general` | — |
| Consultando documentação oficial de libs/frameworks/APIs | `docs-researcher` | Nunca alucina |
| Síntese multi-fontes, questões de design, comparações | `deep-researcher` | 2-4 em paralelo. NÃO para: consultas simples de API (→ `docs-researcher`), fetch único (→ `general`), busca só de código (→ `finder`) |
| Vulnerabilidades de segurança, exposição de segredos, CVEs | `security-auditor` | Somente leitura |

### 2.2 Revisores Especializados (via agentget)

| Gatilho | Agente |
|---|---|
| Revisão de código geral (todas as linguagens) | `code-reviewer` |
| Revisão Python | `python-reviewer` |
| Revisão TypeScript | `typescript-reviewer` |
| Revisão React | `react-reviewer` |
| Revisão FastAPI | `fastapi-reviewer` |
| Revisão Banco de Dados / SQL | `database-reviewer` |
| Revisão de Segurança | `security-reviewer` |
| Arquitetura e Design | `code-architect` |
| Exploração de código | `code-explorer` |
| TDD e Testes | `tdd-guide` |
| Limpeza e Refatoração | `refactor-cleaner` |
| Planejamento de Implementação | `planner` |

### 2.3 Prioridade de Roteamento

1. Se a tarefa corresponde a um gatilho da tabela, delegar ao agente especificado
2. Para trabalho multi-etapas, delegar cada etapa distinta ao agente correspondente
3. Se nenhum gatilho corresponder, usar regras gerais de delegação do orquestrador
4. Para fases do SDD, usar sub-agentes SDD (`sdd-*`)

---

## 3. Instalação do opencode-history-search

### 3.1 O que é

Plugin do OpenCode que permite buscar no histórico de conversas com suporte a:
- **Keyword Search** — Correspondência exata
- **Regex Search** — Padrões de expressão regular
- **Fuzzy Search** — Tolerante a erros de digitação
- **Multi-Term AND Search** — Sessões que contêm todos os termos
- **Date Filtering** — Filtro por data
- **Role Filtering** — Apenas mensagens do `user` ou `assistant`
- **File Modification Tracking** — Que sessões modificaram arquivos específicos
- **Global Search** — Busca em todos os projetos

### 3.2 Instalação

```bash
# Instalação automática (já executada)
npx opencode-history-search

# Isso copiou os arquivos para:
#   ~/.opencode/tool/history-search.ts
#   ~/.opencode/tool/history-search.txt
```

### 3.3 Configuração

Adicionado ao `~/.config/opencode/opencode.json` como plugin:

```json
{
  "plugin": [
    "opencode-history-search"
  ]
}
```

### 3.4 Parâmetros

| Parâmetro | Tipo | Descrição |
|---|---|---|
| `query` | string | Termo de busca. Obrigatório (a menos que `filePath` seja fornecido) |
| `searchAllProjects` | boolean | Buscar em todos os projetos (`true`) ou apenas no repositório atual (`false`, padrão) |
| `filePath` | string | Rastrear quais sessões modificaram um arquivo específico |
| `mode` | `keyword` / `fuzzy` | Modo de busca (padrão: `keyword`) |
| `regex` | boolean | Tratar query como regex |
| `caseSensitive` | boolean | Busca case-sensitive |
| `fuzzyThreshold` | number | Limiar fuzzy 0.0–1.0 (padrão: 0.4) |
| `date` | string | Filtro: `"today"`, `"last 7 days"`, `"YYYY-MM-DD"`, etc |
| `limit` | number | Máximo de resultados (padrão: 50) |
| `role` | `user` / `assistant` | Filtrar por papel na conversa |

---

## 4. Instalação de Agentes via agentget

### 4.1 Sobre agentget

[agentget.sh](https://agentget.sh/) — The AI Agents Package Manager. Instala agentes, skills, instructions e rules de repositórios GitHub em múltiplas ferramentas de IA simultaneamente (OpenCode, Cursor, Windsurf, Gemini CLI, etc).

### 4.2 Instalação Realizada

```bash
npx agentget add affaan-m/everything-claude-code
```

Isso instalou **67 agentes** em três diretórios:

| Diretório | Propósito |
|---|---|
| `.agents/agents/` | Canonical — lido por OpenCode, Cursor, Gemini CLI, etc |
| `~/.config/opencode/agents/` | OpenCode global |
| `~/.gemini/agents/` | Gemini CLI |

### 4.3 Agentes Instalados Relevantes para o Projeto

Baseado no stack do projeto (React 19, TypeScript, Python/FastAPI, PostgreSQL/Supabase, TailwindCSS, Three.js, Mantine UI):

| Agente | Tags | Uso |
|---|---|---|
| `code-reviewer` | General | Revisão de código multi-linguagem |
| `code-architect` | Architecture | Design de arquitetura e planejamento |
| `code-explorer` | Exploration | Exploração profunda de código |
| `python-reviewer` | Python | Revisão de código Python (PEP 8, type hints) |
| `fastapi-reviewer` | FastAPI | Revisão de endpoints FastAPI |
| `typescript-reviewer` | TypeScript | Revisão de código TypeScript |
| `react-reviewer` | React | Revisão de componentes React |
| `database-reviewer` | SQL | Revisão de queries e schema PostgreSQL |
| `security-reviewer` | Security | Auditoria de vulnerabilidades |
| `tdd-guide` | Testing | Guia de TDD e testes |
| `refactor-cleaner` | Refactor | Limpeza de código morto |
| `planner` | Planning | Planejamento de implementação |
| `react-build-resolver` | Build | Resolução de erros de build React |
| `performance-optimizer` | Performance | Otimização de performance |

---

## 5. Otimização de Tokens

### 5.1 Desativação de Auto-Spawning

#### O que é

Por padrão, sub-agentes no OpenCode podem lançar seus próprios sub-agentes, criando uma árvore de execução que consome muitos tokens. A configuração `subagent_depth` controla essa profundidade.

#### Configuração

```json
{
  "subagent_depth": 1
}
```

#### Valores

| Valor | Efeito |
|---|---|
| `0` | Impede completamente que agentes lancem sub-agentes |
| `1` (padrão) | Agentes primários podem lançar sub-agentes, mas sub-agentes NÃO podem lançar outros sub-agentes |
| `2` | Permite um nível adicional de aninhamento |

#### Como funciona no gentle-orchestrator

O `gentle-orchestrator` já tem permissão `task: { "*": "deny", ... }` — ele permite apenas sub-agentes específicos. Combinado com `subagent_depth: 1`, isso garante que:

- O orquestrador pode delegar para qualquer sub-agente na lista de permitidos
- Sub-agentes como `tester`, `lint`, `finder`, etc. NÃO podem lançar outros sub-agentes
- Cada sub-agente executa em isolamento com contexto fresco

---

### 5.2 Limite de Saída de Ferramentas

#### O que é

Controla quanto da saída de ferramentas (bash, grep, read, etc.) é retornado ao contexto. Quando o limite é excedido, o conteúdo completo é salvo em disco e apenas um preview é retornado.

#### Configuração

```json
{
  "tool_output": {
    "max_lines": 500,
    "max_bytes": 8192
  }
}
```

#### Padrões vs Configurado

| Parâmetro | Padrão | Configurado | Economia |
|---|---|---|---|
| `max_lines` | 2000 linhas | **500 linhas** | ~75% menos linhas |
| `max_bytes` | 51200 bytes (50KB) | **8192 bytes (8KB)** | ~84% menos bytes |

#### Impacto

- Reduz drasticamente o tamanho do contexto enviado ao LLM
- Conteúdo truncado ainda é acessível via leitura do arquivo em disco
- Ideal para comandos verbosos como `npm install`, `git diff`, etc.

---

### 5.3 Compaction Pruning

#### O que é

O OpenCode já faz compactação automática de contexto quando o contexto fica cheio. A opção `prune: true` estende isso removendo saídas obsoletas de ferramentas durante a compactação.

#### Configuração

```json
{
  "compaction": {
    "auto": true,
    "prune": true,
    "reserved": 10000
  }
}
```

#### Parâmetros

| Parâmetro | Descrição | Configurado |
|---|---|---|
| `auto` | Compactar automaticamente quando o contexto estiver cheio | `true` |
| `prune` | Remover saídas antigas de ferramentas durante compactação | `true` |
| `reserved` | Buffer de tokens para evitar overflow durante compactação | `10000` |

---

### 5.4 Dynamic Context Pruning (DCP)

#### O que é

Plugin comunitário que reduz o uso de tokens gerenciando inteligentemente o contexto da conversa. Em sessões longas, pode reduzir o consumo em **50–70%**.

#### Como funciona

1. O plugin expõe uma ferramenta `compress` ao modelo
2. O modelo decide quando comprimir e quais mensagens alvo
3. Conteúdo obsoleto é substituído por resumos técnicos
4. O histórico da sessão NÃO é modificado — apenas substituído antes de enviar ao LLM

#### Instalação

Adicionado automaticamente ao array `plugin` no `opencode.json`:

```json
{
  "plugin": [
    "opencode-history-search",
    "@tarquinen/opencode-dcp@latest"
  ]
}
```

Para instalação manual via CLI:

```bash
opencode plugin @tarquinen/opencode-dcp@latest --global
```

#### Configuração (dcp.jsonc)

Crie `~/.config/opencode/dcp.jsonc`:

```jsonc
{
  "$schema": "https://raw.githubusercontent.com/Opencode-DCP/opencode-dynamic-context-pruning/master/dcp.schema.json",
  "enabled": true,
  "autoUpdate": true,
  "pruneNotification": "minimal",
  "compress": {
    "maxContextLimit": 100000,
    "minContextLimit": 50000,
    "nudgeFrequency": 5
  }
}
```

#### Comandos DCP

| Comando | Descrição |
|---|---|
| `/dcp stats` | Mostrar estatísticas de economia |
| `/dcp compress` | Forçar compressão manual |
| `/dcp sweep` | Limpar ferramentas protegidas |

---

### 5.5 Snippet Mínimo Token-Saver

Para aplicar rapidamente as otimizações mais impactantes:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "subagent_depth": 1,
  "tool_output": {
    "max_bytes": 8192
  },
  "compaction": {
    "prune": true
  },
  "plugin": [
    "@tarquinen/opencode-dcp@latest"
  ]
}
```

Este snippet:
- ✅ Previne auto-spawning descontrolado
- ✅ Reduz saída de ferramentas em ~84%
- ✅ Ativa pruning durante compactação
- ✅ Adiciona DCP para 50–70% de redução extra

---

### 5.6 Popular Picks

Plugins comunitários recomendados para economia de tokens:

| Plugin | Redução | Descrição | Instalação |
|---|---|---|---|
| **DCP** (`@tarquinen/opencode-dcp`) | 50–70% | Dynamic Context Pruning — remove contexto obsoleto | `opencode plugin @tarquinen/opencode-dcp@latest --global` |
| **OpenSlimedit** (`openslimedit`) | 11–45% | Comprime descrições de ferramentas e saída de leitura de arquivos | Adicionar ao array `plugin` |
| **opencode-snip** (`opencode-snip`) | 60–90% | Filtra saída bash removendo ruído (requer binário `snip`) | `npm i -g snip` + adicionar plugin |

**Nota:** Todos os três podem rodar juntos — eles atuam em camadas diferentes de desperdício de tokens e não conflitam entre si.

---

## 6. Roteamento Multi-Agente e Multi-Modelo

### 6.1 O que é

Encaminhar tarefas baratas/simples para modelos mais baratos/rápidos, e tarefas profundas para modelos mais fortes, economizando tokens e custos.

### 6.2 Agentes CHEAP (modelo barato/rápido)

Foram criados sub-agentes otimizados para modelos menores:

| Agente | Descrição | Uso Típico |
|---|---|---|
| `finder-cheap` | Busca de código ultra-rápida | Globs, grep, localizar arquivos |
| `lint-cheap` | Lint e type checking | ESLint, TypeScript, Ruff |
| `summarizer` | Compressão de logs e saídas longas | Ideal para modelo rápido |

### 6.3 Agentes DEEP (modelo forte/caro)

| Agente | Descrição | Uso Típico |
|---|---|---|
| `deep-researcher` | Síntese multi-fontes | Decisões de design, pesquisas |
| `code-architect` | Design de arquitetura | Planejamento de sistemas |
| `code-reviewer` | Revisão de código | Análise profunda de qualidade |

### 6.4 Como configurar modelos específicos

No `opencode.json`, atribua modelos diferentes por agente:

```json
{
  "agent": {
    "finder-cheap": {
      "model": "provider/cheap-fast-model"
    },
    "lint-cheap": {
      "model": "provider/cheap-fast-model"
    },
    "summarizer": {
      "model": "provider/cheap-fast-model"
    },
    "deep-researcher": {
      "model": "provider/strong-model"
    },
    "code-reviewer": {
      "model": "provider/strong-model"
    },
    "code-architect": {
      "model": "provider/strong-model"
    }
  }
}
```

### 6.5 Estratégia de Roteamento

```
Tarefa recebida
  ├── Simples/rápida (globs, grep, lint, testes rápidos)
  │   └── finder-cheap / lint-cheap / general
  │
  ├── Média (exploração, testes completos, revisão simples)
  │   └── explore / tester / git-helper
  │
  └── Complexa (arquitetura, pesquisa, revisão profunda)
      └── deep-researcher / code-architect / code-reviewer
```

---

## 7. Arquivos de Configuração Modificados/Criados

### 7.1 Modificados

| Arquivo | O que mudou |
|---|---|
| `~/.config/opencode/opencode.json` | Adicionados: `plugin: ["opencode-history-search", "@tarquinen/opencode-dcp@latest"]`, `subagent_depth: 1`, `tool_output { max_lines: 500, max_bytes: 8192 }`, `compaction { auto: true, prune: true, reserved: 10000 }`, permissões de `task` para 22+ sub-agentes |
| `~/.config/opencode/AGENTS.md` | Adicionadas seções `<!-- gentle-ai:agent-routing -->` e `<!-- gentle-ai:token-optimization -->` com tabela de roteamento completa e referência de otimização |

### 7.2 Criados — Sub-Agentes Customizados

| Arquivo | Descrição |
|---|---|
| `~/.config/opencode/agents/finder.md` | Busca rápida de código (glob/grep) — somente leitura |
| `~/.config/opencode/agents/finder-cheap.md` | Versão CHEAP do finder — para modelos rápidos/baratos |
| `~/.config/opencode/agents/lint.md` | Lint e type checking (ESLint, TypeScript, Ruff, Prettier) |
| `~/.config/opencode/agents/lint-cheap.md` | Versão CHEAP do lint — para modelos rápidos/baratos |
| `~/.config/opencode/agents/tester.md` | Execução de testes (vitest, pytest) e análise de falhas |
| `~/.config/opencode/agents/security-auditor.md` | Auditoria de segurança (npm audit, pip audit) |
| `~/.config/opencode/agents/git-helper.md` | Operações Git (blame, log, diff, commit messages) |
| `~/.config/opencode/agents/summarizer.md` | Sumarização de logs e saídas longas |
| `~/.config/opencode/agents/docs-researcher.md` | Consulta de documentação oficial de bibliotecas |
| `~/.config/opencode/agents/deep-researcher.md` | Síntese multi-fontes para decisões de design |

### 7.3 Instalados via agentget

| Localização | Conteúdo |
|---|---|
| `~/.config/opencode/agents/` | 75+ arquivos `.md` (67 agentget + 10 customizados) |
| `.agents/agents/` | 67 arquivos `.md` do agentget (canonical) |
| `~/.opencode/tool/` | `history-search.ts` + `history-search.txt` |

---

## 8. Status da Configuração

| Configuração | Valor | Status |
|---|---|---|
| `subagent_depth` | `1` | ✅ Ativo |
| `tool_output.max_lines` | `500` | ✅ Ativo |
| `tool_output.max_bytes` | `8192` (8KB) | ✅ Ativo |
| `compaction.auto` | `true` | ✅ Ativo |
| `compaction.prune` | `true` | ✅ Ativo |
| `compaction.reserved` | `10000` | ✅ Ativo |
| `opencode-history-search` | Plugin | ✅ Adicionado |
| `@tarquinen/opencode-dcp` | Plugin | ✅ Adicionado (requer restart) |
| `finder` | Sub-agente | ✅ Criado |
| `finder-cheap` | Sub-agente | ✅ Criado (multi-modelo) |
| `lint` | Sub-agente | ✅ Criado |
| `lint-cheap` | Sub-agente | ✅ Criado (multi-modelo) |
| `tester` | Sub-agente | ✅ Criado |
| `security-auditor` | Sub-agente | ✅ Criado |
| `git-helper` | Sub-agente | ✅ Criado |
| `summarizer` | Sub-agente | ✅ Criado |
| `docs-researcher` | Sub-agente | ✅ Criado |
| `deep-researcher` | Sub-agente | ✅ Criado |
| 67 agentes affaan-m/everything-claude-code | `agentget` | ✅ Instalados |

---

## 9. Como Usar

### 9.1 Sub-Agentes via @mention

Digite `@` seguido do nome do agente no OpenCode:

```
@finder localize a função de cálculo de frete
@lint verifique os arquivos que modifiquei
@tester execute os testes do frontend
@docs-researcher como usar o TanStack Query v5 com SSR
@deep-researcher compare Zustand com Redux para este projeto
@git-helper gere uma mensagem de commit para as mudanças atuais
@code-reviewer revise o código novo
@security-auditor verifique segredos vazados
```

### 9.2 Sub-Agentes via task (orquestrador)

O orquestrador (`gentle-orchestrator`) delega automaticamente baseado no gatilho detectado. Exemplos de delegações automáticas:

```
# O orquestrador vê "preciso encontrar onde fica X" → delega para @finder
# O orquestrador vê "execute os testes" → delega para @tester
# O orquestrador vê "revise a segurança" → delega para @security-auditor
# O orquestrador vê "como funciona a API do Next.js" → delega para @docs-researcher
```

### 9.3 Busca no Histórico

Pergunte ao OpenCode em linguagem natural:

```
"Search my history for 'storage' in this repo"
"Search across all my projects for auth code"
"Find sessions where you modified src/storage.ts"
"Search for 'storag' using fuzzy mode"
"What did we work on yesterday?"
```

### 9.4 Revisão de Código Especializada

```
@code-reviewer revise as mudanças no diretório src/
@python-reviewer revise meu código Python
@database-reviewer verifique esta migration SQL
@security-reviewer audite as credenciais no código
@react-reviewer revise meus componentes React
@tdd-guide me ajude a escrever testes primeiro
```

---

## 10. Apêndice A: Stack Tecnológico do Projeto

Para referência, os agentes foram selecionados com base neste stack:

| Camada | Tecnologias |
|---|---|
| Frontend | React 19, TypeScript, Vite, TailwindCSS, Mantine UI 9 |
| Estado/Data | Zustand, TanStack Query 5, TanStack Table |
| 3D/Visual | Three.js, React Three Fiber, Recharts, Framer Motion |
| Backend | Python, FastAPI, Uvicorn, Pydantic, httpx |
| Dados | Polars, BeautifulSoup4, asyncpg |
| Database | Supabase (PostgreSQL) |
| Testes | Vitest (FE), pytest (BE) |
| Ferramentas | ESLint, Prettier, Husky, lint-staged |

---

## 11. Apêndice B: Como Verificar

### Verificar configuração ativa

```bash
opencode debug config
```

### Verificar plugins carregados

No OpenCode: `Ctrl+P` → **View Status** → System

### Verificar economia do DCP

```
/dcp stats
```

### Verificar agentes instalados

```bash
ls ~/.config/opencode/agents/ | head -30
ls .agents/agents/ | head -10
```

---

## 12. Hierarquia de Agentes — Quem Chamar e Quando

### 12.1 O Agente Principal (SEMPRE ESCOLHA ESTE)

**`gentle-orchestrator`** é o **único agente primário** do sistema. Todo o ecossistema foi projetado em torno dele:

```
┌──────────────────────────────────────────────────────────┐
│                    gentle-orchestrator                    │
│                   (PRIMARY — mode: primary)               │
│                                                          │
│  • Único agente que você precisa selecionar              │
│  • Coordenador inteligente — nunca executa trabalho      │
│  • Decide automaticamente qual sub-agente delegar        │
│  • Síntese dos resultados para você                      │
│  • Default configurado em `default_agent`                │
└──────────────────────────────────────────────────────────┘
```

**Regra de ouro:** você fala com o `gentle-orchestrator`. O orquestrador fala com os sub-agentes. Você **nunca** precisa saber qual sub-agente específico usar — o orquestrador detecta o gatilho e delega automaticamente.

### 12.2 Pirâmide Hierárquica

```
                         YOU
                          │
                          ▼
                ┌──────────────────┐
                │gentle-orchestrator│  ← ÚNICO contato humano
                │  (PRIMARY Agent)  │
                └────────┬─────────┘
          ┌──────────────┼──────────────────┐
          ▼              ▼                  ▼
   ┌────────────┐ ┌────────────┐  ┌────────────────┐
   │OPERACIONAIS│ │   SDD     │  │   REVISÃO      │
   │            │ │ WORKFLOW  │  │   (Review/4R)   │
   ├────────────┤ ├───────────┤  ├────────────────┤
   │finder      │ │sdd-init   │  │review-risk     │
   │explore     │ │sdd-propose│  │review-readability│
   │general     │ │sdd-spec   │  │review-reliability│
   │tester      │ │sdd-design │  │review-resilience │
   │lint        │ │sdd-tasks  │  │review-refuter   │
   │git-helper  │ │sdd-apply  │  │jd-judge-a      │
   │summarizer  │ │sdd-verify │  │jd-judge-b      │
   │docs-research│ │sdd-archive│  │jd-fix-agent    │
   │deep-research│ │sdd-onboard│  │                │
   │security-aud│ └───────────┘  └────────────────┘
   └────────────┘
        │
        ▼
   ┌────────────────────────────────────────┐
   │ AGENTGET REVIEWERS (via task indireta) │
   │                                        │
   │ code-reviewer        python-reviewer   │
   │ typescript-reviewer  react-reviewer    │
   │ fastapi-reviewer     database-reviewer │
   │ security-reviewer    code-architect    │
   │ code-explorer        tdd-guide         │
   │ refactor-cleaner     planner           │
   └────────────────────────────────────────┘
```

### 12.3 Como a Delegação Funciona

```
Você diz:                              O orquestrador:
──────────────────────────────────────────────────────────────────
"preciso achar onde fica X"          → delega para @finder
"como funciona o componente Y"       → delega para @explore
"execute os testes"                  → delega para @tester
"rode o linter nos meus arquivos"    → delega para @lint
"documentação da API do Supabase"    → delega para @docs-researcher
"quero implementar feature Z com SDD"→ ativa SDD workflow (sdd-*)
"revise a segurança do código"       → delega para @security-auditor
"compare abordagens para cache"      → delega para @deep-researcher
"me mostre o git log desse arquivo"  → delega para @git-helper
```

Você **não precisa** decorar gatilhos. O orquestrador infere automaticamente.

### 12.4 Quando Usar @mention Direta

Embora o orquestrador delegue automaticamente, você pode **chamar agentes diretamente** via `@nome` quando quiser pular o orquestrador. Isso é útil para tarefas pontuais:

| Cenário | Comando @mention | Alternativa (orquestrador) |
|---|---|---|
| Busca rápida de código | `@finder ache a função calculateTotal` | "me ajude a achar calculateTotal" |
| Rodar testes | `@tester execute vitest src/components/` | "rode os testes dos componentes" |
| Ver tipo e lint | `@lint verifique src/` | "verifique o código que escrevi" |
| Pesquisa técnica | `@deep-researcher como implementar WebSocket no FastAPI` | "pesquise sobre WebSocket no FastAPI" |
| Documentação de lib | `@docs-researcher TanStack Query v5 mutations` | "como usar mutations no TanStack Query" |
| Revisão especializada | `@database-reviewer revise esta migration` | "revise minha migration SQL" |
| Diagnóstico de build | `@general compile o projeto e me mostre os erros` | "compile o projeto" |

### 12.5 Qual Agente Escolher (Tabela de Decisão)

```
PERGUNTA                          → AGENTE CERTO
─────────────────────────────────────────────────────────────
"Preciso fazer uma tarefa         → gentle-orchestrator
 complexa com várias etapas"        (sempre — ele coordena)

"Quero uma busca rápida"          → @finder
"Quero explorar o códigobase"     → @explore
"Quero executar um comando"       → @general
"Quero rodar testes"              → @tester
"Quero verificar lint/typecheck"  → @lint
"Quero uma pesquisa profunda"     → @deep-researcher
"Quero documentação oficial"      → @docs-researcher
"Quero auditoria de segurança"    → @security-auditor
"Quero revisão de código"         → @code-reviewer (ou o especializado)
```

**Quando estiver em dúvida, sempre use o `gentle-orchestrator`.** Ele é o ponto central e sabe exatamente para quem delegar.

### 12.6 Fluxo de Decisão para o Usuário

```
Sua tarefa:
├── É uma conversa/pedido simples?
│   └── ✅ Fale diretamente com gentle-orchestrator
│
├── É uma busca rápida de código?
│   └── ✅ @finder (ou deixe o orquestrador decidir)
│
├── É um comando de terminal/teste?
│   └── ✅ @tester / @general / @lint
│
├── É pesquisa técnica ou documentação?
│   └── ✅ @deep-researcher / @docs-researcher
│
├── É revisão especializada de código?
│   └── ✅ @code-reviewer / @typescript-reviewer / etc.
│
├── É um desenvolvimento estruturado (SDD)?
│   └── ✅ Use /sdd-new — o orquestrador gerencia todo o ciclo
│
└── É qualquer outra coisa?
    └── ✅ gentle-orchestrator (ele resolve)
```

### 12.7 Resumo

| Papel | Agente | Como acessar |
|---|---|---|
| **Coordenador principal** 🔑 | `gentle-orchestrator` | **Sempre escolha este.** Default automático. |
| Operacional geral (comandos) | `general` | @general ou delegado pelo orchestrator |
| Busca de código | `finder` | @finder ou delegado pelo orchestrator |
| Exploração de código | `explore` | @explore ou delegado pelo orchestrator |
| Testes | `tester` | @tester ou delegado pelo orchestrator |
| Lint/typecheck | `lint` | @lint ou delegado pelo orchestrator |
| Pesquisa técnica | `deep-researcher` | @deep-researcher ou delegado |
| Docs oficiais | `docs-researcher` | @docs-researcher ou delegado |
| Auditoria de segurança | `security-auditor` | @security-auditor ou delegado |
| SDD fases | `sdd-*` | Automático via /sdd-* comandos |
| Revisão 4R | `review-*` | Automático no ciclo de review |
| Revisão agentget | `code-reviewer` e similares | Automático ou @mention |

**Conclusão:** Você só precisa de UM agente: **`gentle-orchestrator`**. Toda a inteligência de roteamento está embutida nele. Os sub-agentes existem para que ele delegue trabalho especializado sem poluir seu contexto. Relaxe e deixe o orquestrador fazer o trabalho pesado de coordenação.

---

*Documento unificado em 2026-07-25 pelo gentle-orchestrator*
