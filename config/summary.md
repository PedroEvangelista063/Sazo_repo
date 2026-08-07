# summary.md — /config

## Propósito

Centralização de JSONs de roteamento, matriz de fontes, regiões e configurações do ecossistema. Nada de código aqui — apenas dados de configuração.

## Stack

JSON puro, sem schema validation runtime (consumido via `json.load()` no pipeline e FastAPI).

## Regras de Ouro

1. **Configuration Over Code**: toda fonte, URL, adaptador, UF e região fica em JSON. O código apenas lê e executa.
2. **Janela Temporal Hardcoded**: `_metadata.janela_temporal` deve ser `"2024-01 a 2026-12"` — reflete a restrição do Pomar.
3. **Sem Secrets**: senhas e tokens vão em `.env`, não aqui. URLs públicas apenas.

## Mapa Rápido

- `sources_matrix.json` — matriz oficial de 24+ fontes em 4 categorias (core, agregadores, ceasas_diretas, perifericos)
- `sources.json` — legado (fase anterior), manter para compatibilidade
- `sources_map.json` — mapeamento produto → fontes regionais (CONAB + CEASAs)
- `regions.json` — definição das 5 regiões brasileiras: Norte, Nordeste, Centro-Oeste, Sudeste, Sul. Cada região lista suas UFs e polos CEASA com nome, UF, fonte_id e prioridade. Consumido por `GET /api/v1/regioes` e usado no mapa interativo do frontend.
- `flows.json` — 166 fluxos de abastecimento entre UFs (v2.0). Todas as 27 UFs aparecem como origem E destino com dados reais de CEASA/CONAB. Estrutura: `{id, item, categoria, origem_uf, origem_polo, destino_uf, destino_regiao_id, meses, sazonalidade, preco_referencial, cor_indicadora, tipo("exportado"/"importado"/"autossuficiente"), ano_referencia}`. Consumido por `BrasilMap.tsx` para desenhar arcos de recebimento (azul) e envio (verde) por UF.
- `flows.json` — o tipo `autossuficiente` representa produção local (origem_uf == destino_uf, ex.: Carne Bovina TO→TO). Na UI, aparece como painel "Produção local" no `RegiaoPanel`, sem arco de Recebe/Envia.

## Mudanças Recentes (2026-08-07)

### Nenhuma mudança neste lote (FASE 1/2)

- Lote `08e87f6d` concentrado em `pipeline/`, `database/` e `query_DBA/` (malha fina de preço, bloqueio de órfãos, expurgo de fantasmas, kit DBA). /config inalterado — JSONs de roteamento seguem os mesmos.

## Root Config — `.gitignore`

### Mudanças (2026-07-30)

- **Documentado**: `.aider*` — padrão pré-existente, ignora artefatos do AI coding assistant aider (`.aider.chat.history.md`, `.aider.tags.cache.v4/`)
- **Adicionado**: `ion |*` e `backend/ion |*` — ignora artefatos de terminal criados por pipe redirection incorreto (ex: `uvicorn ... | tee log.txt` gerou arquivo `ion |` com 460KB)
- **Limpeza**: arquivo `backend/ion |` (460KB) deletado manualmente

### Regras de Ouro para `.gitignore`

1. **Nunca commitar secrets**: `.env*`, `backend/.env`, `frontend/.env` estão sempre no .gitignore
2. **IDE artifacts**: `.idea/`, `*.swp`, `*.swo` — sujo, mas protegido
3. **Build outputs**: `frontend/dist/`, `*.tsbuildinfo`, `*.pyc`, `__pycache__/`
4. **AI runtime**: `.atl/`, `.aider*`, `.claude/` — cada ferramenta tem seu padrão
5. **Artifacts de terminal**: `ion |*` — pipe mal-formado pode criar arquivos com nomes estranhos

- O baseline histórico (2024-2025) agora é calculado 100% em PostgreSQL via `sp_calcular_forecast_2026()` — não mais em Python.
- A janela temporal da config define o escopo dos anos analisados (2024-2026).
- Scripts Python legados (`calcular_baseline.py`, `projetar_2026.py`) permanecem em `database/scripts/` para uso standalone, mas não são mais chamados pelo pipeline.
