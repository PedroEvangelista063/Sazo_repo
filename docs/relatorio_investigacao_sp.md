# Relatório de Investigação — Cobertura SP

## 1. Instruções

Execute as 4 queries do arquivo `database/processed_data/sql/03_investigacao_sp.sql` no banco de dados e preencha os resultados abaixo.

```bash
# Exemplo de execução via psql
psql -h localhost -U user -d quero_comprar_vg -f database/processed_data/sql/03_investigacao_sp.sql
```

Ou via Python/asyncpg diretamente.

---

## 2. Resultados

### Query 1 — Contagem total de registros SP por mês

| Mês | Total Registros | Produtos Distintos | Fontes |
|-----|----------------|-------------------|--------|
| 2025-01 | | | |
| 2025-02 | | | |
| 2025-03 | | | |
| 2025-04 | | | |
| 2025-05 | | | |
| 2025-06 | | | |
| 2025-07 | | | |
| 2025-08 | | | |
| 2025-09 | | | |
| 2025-10 | | | |
| 2025-11 | | | |
| 2025-12 | | | |
| 2026-01 | | | |
| 2026-02 | | | |
| 2026-03 | | | |
| 2026-04 | | | |
| 2026-05 | | | |
| 2026-06 | | | |
| 2026-07 | | | |
| 2026-08 | | | |
| 2026-09 | | | |
| 2026-10 | | | |
| 2026-11 | | | |
| 2026-12 | | | |

### Query 2 — Produtos com preço por mês

| Mês | Produtos Distintos |
|-----|-------------------|
| 2025-01 | |
| 2025-02 | |
| ... | |

### Query 3 — Fontes que contribuíram por mês

| Mês | Fontes |
|-----|--------|
| 2025-01 | |
| ... | |

### Query 4 — Meses sem dados (gaps)

| Mês | Gap? | Motivo |
|-----|------|--------|
| ... | | |

---

## 3. Análise: Bug vs Cobertura Parcial CONAB

- **Bug**: Se meses com CEAGESP ativa estão vazios, é bug no parser ou no scraper.
- **Cobertura parcial CONAB**: Se meses sem CEAGESP têm dados via ProHort/Precosiagroweb, é cobertura parcial esperada — CONAB não tem a granularidade CEAGESP.
- **Meses futuros (jul-dez/2026)**: Ignorar na análise — são meses à frente que naturalmente não têm dados.

## 4. Decisão

| Critério | Conclusão |
|----------|-----------|
| Gaps reais (jan-jun/2026) | |
| Meses futuros (jul-dez/2026) | Ignorados — fora da janela de coleta |
| Bug confirmado? | |
| Ação necessária | |