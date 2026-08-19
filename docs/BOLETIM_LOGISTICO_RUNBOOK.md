# Runbook — Promoção para Produção: Pipeline de Boletins Logísticos CONAB

Guia de deploy **zero-downtime** do pipeline de fluxos de abastecimento
(scraper → extração → carga → validação) e da feature **Fluxos / Boletins
CONAB** (endpoint `GET /api/v1/fluxos/boletins` + frontend).

> ⚠️ **Fronteira de ambiente:** o pipeline carrega em `staging.fact_fluxo_logistico`
> **no banco de destino** definido por `DATABASE_URL_ETL`/`DATABASE_URL_LOCAL_BACKUP`.
> No projeto, o **banco LOCAL (localhost) é o primário para testes**; o Aiven é o
> remoto. A migração 84/85 precisa existir **no banco que o pipeline vai gravar**.

---

## 1. Pré-requisitos

| Item                 | Detalhe                                                                                                                                                    |
| -------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| PostgreSQL 16+       | Tabela `staging.fact_fluxo_logistico` + view `staging.vw_fluxo_logistico_boletins` (migrations 84/85).                                                     |
| Roles                | `role_etl_writer` (carga via loader) e `role_api_reader` (SELECT only, já concedido nas migrations).                                                       |
| Schema `staging`     | Existente no banco de destino (GRANT USAGE para `role_api_reader` já consta na 85).                                                                        |
| `.env` do backend    | `DATABASE_URL_ETL` (banco da carga), `DATABASE_URL_LOCAL_BACKUP` (standby local), `DATABASE_URL_API` (leitura da API), `INTERNAL_API_KEY` (hook ETL-done). |
| Espaço em disco      | Diretório staging ~**40 MB** (19 PDFs ≈ 36 MB + JSONs extraídos).                                                                                          |
| Python               | Repo venv `.venv/bin/python` com `polars`, `psycopg2-binary`, `pymupdf`, `pdfplumber`.                                                                     |
| Permissão de escrita | Usuário que roda o script precisa gravar em `pipeline/data/conab_boletins_staging/`.                                                                       |

---

## 2. Passo a passo

### Passo 1 — Aplicar migrations 84 e 85 (asyncpg runner)

Usar o **mesmo padrão** de `.opencode/plans/apply_migrations.py` (asyncio +
`asyncpg`, conexão única, `CREATE IF NOT EXISTS` / `CREATE OR REPLACE`, verificação
via `information_schema`). Exemplo genérico:

```python
"""Aplica migrations 84/85 dos boletins CONAB — padrão asyncpg do repo."""
import asyncio
from pathlib import Path

import asyncpg

DSN = "postgresql://postgres:postgres_dev_local@localhost:5432/quero_comprar"
RAIZ = Path(__file__).resolve().parents[2]

async def main() -> None:
    conn = await asyncpg.connect(DSN)
    try:
        for sql_file in ("database/84_fact_fluxo_logistico_boletins.sql",
                         "database/85_vw_fluxo_logistico_boletins.sql"):
            print(f"--- {sql_file} ---")
            await conn.execute((RAIZ / sql_file).read_text(encoding="utf-8"))
            print("OK")
        ok = await conn.fetch(
            "SELECT table_name FROM information_schema.tables "
            "WHERE table_schema='staging' AND table_name='fact_fluxo_logistico'"
        )
        v = await conn.fetch(
            "SELECT table_name FROM information_schema.views "
            "WHERE table_schema='staging' AND table_name='vw_fluxo_logistico_boletins'"
        )
        print(f"Tabela: {bool(ok)} | View: {bool(v)}")
    finally:
        await conn.close()

asyncio.run(main())
```

Idempotente: a 84 usa `CREATE TABLE IF NOT EXISTS` + `CREATE INDEX IF NOT EXISTS` e
a 85 usa `CREATE OR REPLACE VIEW`. Pode ser executada mais de uma vez.

### Passo 2 — Rodar o pipeline completo

```bash
cd /caminho/do/repo
# banco local (padrão do projeto):
./ops/run_boletim_pipeline.sh
# ou apontando para outro destino (ex.: banco remoto de produção):
DATABASE_URL_ETL="postgresql://role_etl_writer:...@host:5432/db" ./ops/run_boletim_pipeline.sh
```

O script é **idempotente**: reexecutar não duplica dados (UPSERT por `dedup_hash`,
`ON CONFLICT DO UPDATE`). Ao final gera `relatorio_validacao.json/.md` no staging.

### Passo 3 — Verificar a view com a role de leitura (SET ROLE)

```bash
PGPASSWORD=... psql -h localhost -U postgres -d quero_comprar <<'SQL'
SET ROLE role_api_reader;
SELECT count(*) FROM staging.vw_fluxo_logistico_boletins;            -- esperado: 788
SELECT count(DISTINCT dedup_hash) FROM staging.fact_fluxo_logistico; -- via API reader = 788
RESET ROLE;
SQL
```

Se a consulta falhar com "permission denied for schema staging", faltou o
`GRANT USAGE ON SCHEMA staging TO role_api_reader` (está na migration 85).

### Passo 4 — Deploy do backend

O endpoint `fluxos_boletins` já está registrado em `backend/app/main.py`
(`include_router(fluxos_boletins_router, prefix=api_v1_prefix)`). O router lê a
view via `role_api_reader`; a view é criada **antes** do deploy — então não há
janela de erro 500.

**Zero-downtime:** com múltiplos workers do uvicorn/gunicorn, faça _graceful
restart_ (ex.: `kill -HUP <pid_master>` em gunicorn, ou `uvicorn --reload` em dev
/staging). O processo novo só passa a atender requests quando já está _up_
(liveness ok). Não há migração destrutiva — a tabela é **aditiva**.

### Passo 5 — Build do frontend + deploy PWA

```bash
cd frontend
npm run build        # gera dist/ com service worker (Vite PWA)
# publicar dist/ no host estático (configurar cache no SW; toggle client-side)
```

O toggle **Fluxos / Boletins** e os filtros são **client-side** — o deploy do
frontend não depende de rollback do servidor. Null safety (`.?.`/`??`) cobre os
meses sem dados (status CINZA).

### Passo 6 — Smoke test do endpoint

```bash
curl -s "http://localhost:8000/api/v1/fluxos/boletins?limit=5" | python3 -m json.tool
# esperado: data[] com rota, total=788, limit, offset
curl -s "http://localhost:8000/api/v1/fluxos/boletins?produto=milho&ano_referencia=2026&mes_referencia=7&limit=5"
# filtro → total > 0
curl -s "http://localhost:8000/api/v1/fluxos/boletins?ano_referencia=2026&mes_referencia=8"
# mês futuro (sem dados) → data=[], total=0  (quality gate: NUNCA fallback)
curl -s -o /dev/null -w '%{http_code}\n' "http://localhost:8000/api/v1/fluxos/boletins?mes_referencia=13"
# 422 (validação Pydantic na borda)
```

Hook ETL-done (opcional): `POST /api/v1/_internal/etl-done` com header
`X-API-Key: $INTERNAL_API_KEY` e body `{}` → `{"status":"ok","event":"ETL_FINISHED"}`.

---

## 3. Agendamento (cron mensal)

A CONAB publica o Boletim Logístico tipicamente **~dia 25 do mês seguinte**.
Agendar após a publicação:

```cron
# todo dia 25, 06:00 (após a publicação do boletim do mês anterior)
0 6 25 * * cd /caminho/do/repo && ./ops/run_boletim_pipeline.sh >> logs/boletim.log 2>&1
```

O pipeline é idempotente — se o boletim ainda não saiu, o mês permanece ausente
(status CINZA) e a reexecução no próximo ciclo completa o mês quando o PDF existir.

---

## 4. Plano de rollback

| Camada   | Ação                                                                                      | Risco                                                                                                                 |
| -------- | ----------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| Banco    | `DROP VIEW staging.vw_fluxo_logistico_boletins; DROP TABLE staging.fact_fluxo_logistico;` | Seguro: a tabela é **aditiva** e não há FKs/consumidores quebrados; as migrations 84/85 não tocam tabelas existentes. |
| API      | Remover `app.include_router(fluxos_boletins_router, ...)` de `main.py` e redeploy         | Desliga o endpoint sem remover dados.                                                                                 |
| Frontend | Ocultar o toggle Fluxos/Boletins                                                          | Client-side; sem rollback de servidor.                                                                                |

Nenhum rollback destrói dados de outras features (a tabela é dedicada à feature).

---

## 5. Quality Gate (regra fundamental)

- **Nenhum mês é preenchido com fallback.** Meses sem registro real na extração
  permanecem ausentes (NULL) → o frontend exibe **CINZA**, nunca dados de 2023.
- O limite de âncora histórica é **Ano Atual - 1**. Qualquer nova view/projeção
  de dados (BR ou UF) NÃO pode usar `FALLBACK_DIMENSAO` para meses futuros.
- No frontend, aplicar null safety (`?.`, `??`) em `ano_referencia`,
  `tipo_dado`, `mensagem_transparencia` — campos chegam nulos em meses CINZA.

---

## 6. Troubleshooting

| Sintoma                                                                  | Causa                                                      | Ação                                                                                                                                                                                                       |
| ------------------------------------------------------------------------ | ---------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `429/403` do `www.gov.br` ao rodar o scraper                             | Rate limit / WAF do gov.br                                 | Retry com backoff já está no engine; subir o intervalo ou rodar fora do horário de pico; os PDFs já baixados não são re-baixados (idempotente).                                                            |
| PDF "escaneado" (pouco texto)                                            | `taxa_texto < 5%`                                          | O selector `pipeline/pdf_extractor/selector.py` roteia para **OCR** (`ocr_engine`); conferir em `resumo_extracao.json` (`motor_usado`). Nesta base todos os 19 boletins usaram `pymupdf` (taxa 0.56–0.77). |
| `UndefinedTable: relation "staging.fact_fluxo_logistico" does not exist` | DSN aponta para banco sem migration 84                     | Aplicar migrations 84/85 no banco de destino ou corrigir `DATABASE_URL_ETL`.                                                                                                                               |
| Erro de autenticação (`password authentication failed`)                  | Senha do DSN local é `postgres_dev_local` (não `postgres`) | Usar `postgresql://postgres:postgres_dev_local@localhost:5432/quero_comprar` ou exportar `DATABASE_URL_ETL` correto.                                                                                       |
| Hook `_internal/etl-done` retorna 404                                    | URL sem o prefixo `/api/v1`                                | Usar `POST {API_BASE}/api/v1/_internal/etl-done` (o router interno é registrado sob `api_v1_prefix`).                                                                                                      |
| `duplicados_descartados` alto (~2.757)                                   | Mesma rota repetida em várias páginas do boletim           | Esperado: dedup por `dedup_hash = md5(produto                                                                                                                                                              | origem_uf | destino_uf | ano | mes)` antes da carga. |
