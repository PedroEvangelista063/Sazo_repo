# 🧾 Tech Debt — Frontend (V82 / Semáforo Sensível CV-Z)

> **Data:** 13/08/2026
> **Contexto:** Laudo de Prontidão Frontend (auditoria estática + mocks de cenários extremos) — aprovado para receber os dados da Migration 82. Os 6 pontos abaixo **não bloqueiam** a janela de Freeze; foram registrados para tratamento na próxima sprint.
> **Branch:** `fix/ui-resilience` (PR #6)

---

## Resumo

O frontend está **100% apto** a renderizar os dados reais da nuvem sem bugs visuais (73 testes / 11 arquivos verdes; ErrorBoundary com zero tela branca; No Gray/No Null confirmado). As melhorias abaixo são **não bloqueantes** e ficam para a próxima sprint, após a janela de Freeze da infraestrutura.

---

## 📋 Itens de Tech Debt

### 1. Contrato API — `metadado_transparencia` (JSONB) não chega ao frontend

|                   |                                                                                                                                                                                                                                                                                                                                                |
| ----------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Severidade**    | 🟡 Média                                                                                                                                                                                                                                                                                                                                       |
| **Arquivo(s)**    | `frontend/src/types/domain.ts:22-26`, `backend/app/schemas/responses.py:108,190,252`, `backend/app/api/produtos.py` (`_compor_mensagem_transparencia`)                                                                                                                                                                                         |
| **Problema**      | O mock do Cenário 2 usou `metadado_transparencia` (JSON estruturado com `fonte`, `mensagem_transparencia`, e no futuro `contam_unidade`/`unidade_inferida`) — mas esse campo **não existe** no tipo `ProdutoVarejo` nem no contrato da API. O backend compõe `mensagem_transparencia` como **string** no servidor, lendo o JSONB internamente. |
| **Impacto**       | Se a Migration 82 precisar expor o aviso estruturado de série contaminada (`contam_unidade`, `unidade_inferida`), o contrato da API precisará evoluir (novo campo ou objeto serializado).                                                                                                                                                      |
| **Ação sugerida** | Definir evolução do contrato: expor `metadado_transparencia` como objeto tipado no schema Pydantic + tipo TS correspondente; decidir se o frontend renderiza o aviso estruturado ou continua consumindo a string composta.                                                                                                                     |

### 2. Chips de filtro sem CINZA (mascara "sem dado")

|                   |                                                                                                                                                                                                                                   |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Severidade**    | 🟡 Média                                                                                                                                                                                                                          |
| **Arquivo(s)**    | `frontend/src/pages/SupermercadoView.tsx:376`                                                                                                                                                                                     |
| **Problema**      | O loop de chips é fixo nas 3 cores ativas (`🟢 Barato` / `🟡 Normal` / `🔴 Caro`) — não há chip CINZA. Produtos com `status_cor` nulo/desconhecido caem no fallback AMARELO do `ProductCard`, **mascarando** o estado "sem dado". |
| **Impacto**       | O usuário não consegue filtrar/identificar produtos sem cotação; o fallback AMARELO pode ser interpretado como "preço normal" quando na verdade é ausência de dado.                                                               |
| **Ação sugerida** | Adicionar chip CINZA (ex: `⚪ Sem dados (N)`) quando `contadores.CINZA > 0`; mapear fallback do `ProductCard` para CINZA quando `status_cor` for nulo/vazio (decisão de produto: manter "nunca cinza" ou tornar transparente).    |

### 3. Touch targets abaixo de 48px

|                   |                                                                                                                                                                                                |
| ----------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Severidade**    | 🟢 Baixa                                                                                                                                                                                       |
| **Arquivo(s)**    | `frontend/src/components/layout/TopAppBar.tsx:40,54,89`, `frontend/src/components/GradeSazonalAcordeao.tsx:81`                                                                                 |
| **Problema**      | 4 alvos de toque abaixo da diretriz de 48px: botão calendário (`min-h-11` = 44px), botão tema (`min-h-11` = 44px), limpar busca [X] (`h-10` = 40px) e header do acordeão (`px-4 py-3` ≈ 44px). |
| **Impacto**       | Dificuldade de toque para o público 21-72 anos (diretriz do projeto); risco de toque acidental em telas pequenas.                                                                              |
| **Ação sugerida** | Promover para `h-12`/`min-h-12` (48px) os botões do TopAppBar; adicionar altura explícita ao header do acordeão.                                                                               |

### 4. Fontes descritivas do semáforo abaixo de 16px

|                   |                                                                                                                                                                                                                          |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Severidade**    | 🟢 Baixa                                                                                                                                                                                                                 |
| **Arquivo(s)**    | `frontend/src/components/ProductCard.tsx:127,149`                                                                                                                                                                        |
| **Problema**      | O badge de status do card usa `text-xs` (12px) e o subtítulo de projeção também `text-xs` (12px) — abaixo do mínimo de 16px das fontes descritivas do semáforo. (Nome do produto `text-lg` e abas `text-base` estão OK.) |
| **Impacto**       | Legibilidade reduzida para o público-alvo; texto do semáforo é a informação primária do produto.                                                                                                                         |
| **Ação sugerida** | Subir badge de status para `text-sm`/`text-base` com ajuste de padding; avaliar subtítulo de projeção para `text-sm`.                                                                                                    |

### 5. `DataTransparencyInfo` órfão

|                   |                                                                                                                                                                                                                                                |
| ----------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Severidade**    | 🟢 Baixa                                                                                                                                                                                                                                       |
| **Arquivo(s)**    | `frontend/src/components/DataTransparencyInfo.tsx` (só importado pelo próprio teste)                                                                                                                                                           |
| **Problema**      | Componente de tooltip de transparência existe e está testado, mas **não está conectado a nenhum consumer** — `ProductCard`, `SazonalidadeNacional`, `GradeSazonalAcordeao` e `SupermercadoView` não o importam.                                |
| **Impacto**       | Código morto de alto valor: a infraestrutura para explicar a proveniência do dado existe, mas o usuário não a alcança.                                                                                                                         |
| **Ação sugerida** | Decidir o padrão de exposição (tooltip no card vs. subtítulo direto — o fix atual do Cenário 2 usou subtítulo com `line-clamp-2` por a11y mobile) e conectar o componente onde fizer sentido; ou remover se o padrão definitivo for subtítulo. |

### 6. Grade sazonal não exibe `mensagem_transparencia`

|                   |                                                                                                                                                                         |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Severidade**    | 🟢 Baixa                                                                                                                                                                |
| **Arquivo(s)**    | `frontend/src/components/SazonalidadeNacional.tsx` (badge de `ano_referencia` em `:96`; `yearBadge` `:53-56`)                                                           |
| **Problema**      | A grade sazonal lê apenas `ano_referencia` para o badge de ano — **não lê** `mensagem_transparencia`. Teste documenta a remoção do ícone (i) da célula.                 |
| **Impacto**       | Na visão de grade, o usuário não vê o motivo da projeção/baixa confiabilidade — só vê o badge de ano âncora.                                                            |
| **Ação sugerida** | Definir como expor a mensagem na grade (tooltip por célula via `DataTransparencyInfo`, ou linha de legenda consolidada no rodapé) respeitando o mobile-first e o toque. |

---

## ✅ O que já está resolvido (não é tech debt)

- **No Gray / No Null** — fallbacks ativos em `ProductCard:102` (`?? AMARELO`), grade `:108-113` (`?? 'Sem Cotação'`), `TabelaView:176` (`?? CINZA`)
- **Cenário 2 (transparência)** — `ProductCard` agora exibe o conteúdo **real** de `mensagem_transparencia` com `line-clamp-2` + `title` (commit `1a13f7d9`)
- **ErrorBoundary global** — zero tela branca (M1)
- **Mocks de cenários extremos** — `frontend/src/test/mock_cenarios_extremos.test.tsx` (7 testes, patrimônio da suíte)
- **Claymorphism, Carregar Mais (lote 20), abas ícone+texto, busca+chips com contadores, haptics** — aprovados no laudo

---

### Referência

- Laudo de prontidão: auditoria estática + mocks (13/08/2026)
- Relatório de auditoria E2E: `docs/RELATORIO_AUDITORIA_E2E_2026-08-13.md`
- Branch: `fix/ui-resilience` → PR #6
