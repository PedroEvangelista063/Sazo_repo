# summary.md — /config

## Propósito
Centralização de JSONs de roteamento, matriz de fontes e configurações do ecossistema. Nada de código aqui — apenas dados de configuração.

## Stack
JSON puro, sem schema validation runtime (consumido via `json.load()` no pipeline).

## Regras de Ouro
1. **Configuration Over Code**: toda fonte, URL, adaptador e UF fica em JSON. O código apenas lê e executa.
2. **Janela Temporal Hardcoded**: `_metadata.janela_temporal` deve ser `"2024-01 a 2026-12"` — reflete a restrição do Pomar.
3. **Sem Secrets**: senhas e tokens vão em `.env`, não aqui. URLs públicas apenas.

## Mapa Rápido
- `sources_matrix.json` — matriz oficial de 24+ fontes em 4 categorias (core, agregadores, ceasas_diretas, perifericos)
- `sources.json` — legado (fase anterior), manter para compatibilidade
- `sources_map.json` — mapeamento produto → fontes regionais (CONAB + CEASAs)

## Conexões com o Forecast
- O baseline histórico (2024-2025) é calculado em Python, não via config — mas a janela temporal da config define o escopo dos anos analisados.
- Nenhuma config nova foi necessária para o forecast: `calcular_baseline.py` e `projetar_2026.py` usam os mesmos sources da matrix.
