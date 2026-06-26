# Fase 2 — Relatório Arquitetural: Observability, Self-Healing DB & FastAPI

## Idempotência no Ghost DBA Agent

O conceito de **idempotência** é a espinha dorsal do Agente de Autocura. Cada operação de reparo é projetada para poder ser executada múltiplas vezes sem efeitos colaterais:

1. **Erros são fila, não evento único.** A tabela `ops.controle_erros_ddl` armazena cada erro com `resolvido_por_ia = FALSE`. O agente faz polling e tenta reparo. Se falhar, incrementa `tentativas_ia` e tenta novamente no próximo ciclo — sem corromper estado.

2. **`CREATE OR REPLACE` é inerentemente idempotente.** O LLM só pode gerar comandos que começam com `CREATE OR REPLACE VIEW`, `CREATE OR REPLACE FUNCTION`, ou `CREATE OR REPLACE TRIGGER`. Rodar o mesmo `CREATE OR REPLACE` duas vezes produz o mesmo resultado — não há "duplicação" de objetos.

3. **Transação com rollback.** O sandbox `BEGIN → EXECUTE → TEST → COMMIT/ROLLBACK` garante que, se o SQL falhar, o banco volta exatamente ao estado anterior. Nenhuma mudança parcial persiste.

4. **Auditoria imutável.** `ops.audit_llm_queries` é append-only. Cada tentativa (sucesso ou falha) vira uma linha. O comando `ops.fn_resolver_erro()` atualiza o erro original com `tentativas_ia + 1`, mas a auditoria nunca perde histórico.

5. **Cache com TTL + invalidação explícita.** O cache in-memory da FastAPI expira em 24h por padrão. Se o Ghost DBA reparar uma view, ele chama `/_internal/cache-clear` para forçar refresh. Se o cache for limpo duas vezes, é apenas um cache miss — zero impacto.

## Plano de Testes Local (Executar no DBeaver)

### Teste 1: Quebrar a Materialized View
Objetivo: Ver o agente detectar e reparar automaticamente.

```sql
-- 1. Simular mudança de coluna (CONAB renomeou preco_medio → valor_medio)
ALTER TABLE staging.fact_precos_mensais RENAME COLUMN preco_medio TO valor_medio;

-- 2. Tentar refresh da MV (vai falhar)
REFRESH MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade;

-- 3. Ver erro registrado
SELECT * FROM ops.controle_erros_ddl ORDER BY data_erro DESC LIMIT 3;
```

Resultado esperado: O agente detecta o erro, consulta `information_schema.columns`, envia para o LLM, recebe um `CREATE OR REPLACE VIEW` corrigido, testa em sandbox, executa COMMIT.

```sql
-- 4. Verificar auditoria
SELECT * FROM ops.audit_llm_queries ORDER BY executado_em DESC LIMIT 5;
```

### Teste 2: Quebrar a Trigger de Anomalia
Objetivo: Ver o agente reparar uma função PL/pgSQL.

```sql
-- 1. Renomear coluna usada pela trigger
ALTER TABLE staging.fact_precos_mensais RENAME COLUMN id_produto TO produto_id;

-- 2. Inserir linha (trigger falha silenciosamente, mas o erro vai para a tabela)
-- (O pipeline Python capturaria via try/except e logaria)
```

### Teste 3: CONAB URL 404 (Simulado)
Objetivo: Ver o roteador LLM em ação sem depender da CONAB real.

1. Editar `.env` apontando `CONAB_URL_UF` para um URL 404 qualquer:
   ```
   CONAB_URL_UF=https://httpbin.org/status/404
   ```
2. Executar: `python -m pipeline.ingestao_conab`
3. Observar logs: o script detecta 404, aciona o LLMUrlRouter, tenta resgate.

Para testar sem LLM real, configurar:
```
LLM_API_ENDPOINT=http://localhost:9999/null
```
O agente logará falha na chamada LLM sem travar o pipeline.

### Teste 4: Cache Invalidation
Objetivo: Verificar que o endpoint de cache-clear funciona.

```bash
curl -X GET http://localhost:8000/api/v1/_internal/cache-clear
# Resposta esperada: {"success": true, "message": "Cache liberado com sucesso"}
```

### Teste 5: Forçar Limite de Tentativas
Objetivo: Ver o agente desistir após N tentativas.

1. Configurar `max_tentativas_ia = 1` na tabela `ops.config_agente`
2. Quebrar a MV com uma mudança que o LLM não consegue reparar (ex: apagar uma coluna inteira do schema staging e esperar que o LLM sugira `SELECT 1 as coluna_falsa`)
3. Rodar agente com `--once`
4. Verificar: erro marcado como `resolvido_por_ia = FALSE` com `tentativas_ia = 1`, webhook 🔴 disparado
5. Verificar na auditoria o SQL bloqueado ou falho

## Teste Integrado Completo

```bash
# Terminal 1: FastAPI
cd backend
uvicorn app.main:app --reload --port 8000

# Terminal 2: Ghost DBA Agent (modo daemon)
cd pipeline
python ghost_dba_agent.py --db-url "postgresql://role_etl_writer:senha@localhost:5432/quero_comprar"

# Terminal 3: Pipeline CONAB
cd pipeline
python -m pipeline.ingestao_conab
```

1. Rodar pipeline CONAB → dados entram
2. No DBeaver: alterar nome de coluna na `fact_precos_mensais`
3. Rodar pipeline CONAB novamente → erro registrado em `ops.controle_erros_ddl`
4. Ghost DBA detecta (polling 5min ou `--once`) → repara → COMMIT → cache clear
5. Verificar: `GET /api/v1/sazonalidade?uf=TO` retorna dados corretos
