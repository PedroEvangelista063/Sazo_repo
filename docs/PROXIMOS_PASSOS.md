# Próximos Passos — Quero Comprar

**Atualizado em:** 2026-07-20
**Contexto:** API conectada ao Supabase Pooler, mas endpoints retornam vazios por dados incompletos e bugs em views.

---

## 🔴 Prioridade 1 — Destravar Endpoints da API

### 1.1 Corrigir `mart.vw_categorias`

A view atual usa `p.categoria_b2c = 'ALIMENTO_VAREJO'` hardcoded no JOIN, e todos os 857 produtos têm `categoria_b2c IS NULL`.

**O que fazer:**
- Remover o `AND p.categoria_b2c = 'ALIMENTO_VAREJO'` da view, ou
- Mudar para `AND p.categoria_b2c = c.nome_categoria` se a lógica for filtrar B2C vs B2B

```sql
CREATE OR REPLACE VIEW mart.vw_categorias AS
SELECT
    c.id_categoria,
    c.nome_categoria,
    c.descricao,
    COUNT(DISTINCT p.id_produto) AS total_produtos
FROM staging.dim_categoria c
LEFT JOIN staging.dim_produto p ON p.id_categoria = c.id_categoria
GROUP BY c.id_categoria, c.nome_categoria, c.descricao
ORDER BY c.nome_categoria;
```

### 1.2 Popular `staging.dim_produto.categoria_b2c`

Os 857 produtos em `dim_produto` no Supabase têm `categoria_b2c = NULL`. O motor de classificação B2C (regex) roda no pipeline Python, mas nunca foi executado contra os dados do Supabase.

**Alternativas:**
- **(Rápida)** Copiar `categoria_b2c` do banco local via `pg_dump --column-inserts` da tabela `dim_produto` inteira
- **(Correta)** Executar o pipeline de classificação (`process_to_files.py` ou `ingestao_conab.py`) apontando para o Supabase

### 1.3 Criar tabelas de dimensão faltantes

| Tabela | Origem | Prioridade |
|--------|--------|------------|
| `staging.dim_localidade` | `pg_dump --data-only --table=staging.dim_localidade` | 🔴 Alta (desbloqueia `vw_municipios`) |
| `staging.dim_uf` | `pg_dump --data-only --table=staging.dim_uf` | 🔴 Alta (desbloqueia `GET /ufs`) |
| `staging.dim_regiao` | `pg_dump --data-only --table=staging.dim_regiao` | 🟡 Média |
| `staging.dim_municipio` | `pg_dump --data-only --table=staging.dim_municipio` | 🟡 Média |

**Procedimento para cada uma:**
1. `pg_dump -U postgres -d quero_comprar --data-only --table=staging.{tabela} --column-inserts > {tabela}.sql`
2. Verificar tamanho (se > 2MB, chunkear)
3. `npx supabase db query --linked -f {tabela}.sql`

### 1.4 Refresh MV pós-sync

Após popular dados, refresh da MV principal:

```sql
REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;
```

---

## 🟡 Prioridade 2 — Homologação e Testes

### 2.1 Testar todos os endpoints da API

Após corrigir dados, testar cada endpoint manualmente:

```bash
# Lista completa de endpoints
GET  /health
GET  /api/v1/sazonalidade?page=1&per_page=10
GET  /api/v1/sazonalidade/{uf}/{municipio}?page=1&per_page=10
GET  /api/v1/sazonalidade/br-sazonalidade?page=1&per_page=10
GET  /api/v1/sazonalidade/com-preco?page=1&per_page=10
GET  /api/v1/categorias
GET  /api/v1/municipios?uf=PR
GET  /api/v1/regioes
GET  /api/v1/ufs
GET  /api/v1/fluxos
```

### 2.2 Verificar `precos_rejeitados`

Supabase tem 92 registros vs local 87. Investigar os 5 extras que vieram do pipeline rodando contra o Supabase. Se forem legítimos (dados rejeitados pelo pipeline), manter. Se forem duplicatas, limpar.

---

## 🟢 Prioridade 3 — Pipeline e Deploy

### 3.1 Pipeline CI/CD

- Configurar GitHub Actions para:
  - Aplicar migrations no Supabase via `npx supabase db push --linked`
  - Rodar auditoria pós-deploy
- Ou manter manual com `npx supabase db query --linked -f database/NN_*.sql`

### 3.2 Publicar schemas no Dashboard Supabase

Schemas `raw`, `staging`, `mart`, `ops` ainda não publicados no dashboard.

### 3.3 Deploy do FastAPI no Render

- Confirmar que o `statement_cache_size=0` está configurado
- Connection strings via env vars do Render (não commitar no `.env`)
- Health check: `GET /health`

---

## 🔵 Prioridade 4 — Melhorias Contínuas

### 4.1 Cache Redis

- `redis_url` configurado como vazio no Settings — cache usa InMemoryCache
- Se o Redis estiver disponível no Render (ou Upstash), conectar para cache compartilhado entre instâncias

### 4.2 Rate limiting

- `RateLimitMiddleware` ativo com 60 req/min — verificar se valores são adequados para produção

### 4.3 Remover tabelas staging obsoletas após migração

- `dim_municipio` vs `dim_localidade` — decidir qual mantém
- `dim_regiao` — verificar se tem dados locais consistentes

### 4.4 Cobertura de testes

- Testes de integração da API contra o Supabase (pooler)
- Testes unitários das queries de endpoints
- Teste de auditoria automatizado (`backend/tests/audit_supabase.py`)

---

## 🚨 Problemas Conhecidos (arquivados)

| Problema | Status | Observação |
|----------|--------|------------|
| DNS não resolve `db.*.supabase.co` | ✅ Contornado | Usar Pooler ou `--linked` |
| `pg_dump v17` bug com `--on-conflict-do-nothing` | ✅ Workaround | Regex adiciona `ON CONFLICT DO NOTHING` manualmente |
| `asyncpg` + PgBouncer prepared statements | ✅ Corrigido | `statement_cache_size=0` |
| `*` na senha quebra URL | ✅ Corrigido | URL-encode `%2A` |
| `Start-Process` + uvicorn loop infinito | ✅ Documentado | Usar `subprocess.Popen` com timeout |

---

## Referências

- `docs/sync_supabase_fase4_concluida.md` — Relatório detalhado da Fase 4
- `docs/plano_sync_supabase.md` — Plano original de sync (desatualizado após Fase 4)
- `backend/app/db/session.py` — Pool config com `statement_cache_size=0`
- `database/34_mart_vw_categorias_municipios.sql` — Migration com bug do `categoria_b2c`
