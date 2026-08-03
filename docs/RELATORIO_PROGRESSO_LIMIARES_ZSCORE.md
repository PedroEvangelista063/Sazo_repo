# Relatório de Progresso — Limiares Dinâmicos Z-Score + Resiliência

**Data:** 2026-08-03
**Escopo:** Pausa controlada do progresso para registro do estado atual (nada foi perdido).

---

## 1. Contexto Geral

O Supabase (projeto `kxsqrcccaaxplpktmutl`) está **fora do ar** (pooler retorna
`EAUTHQUERY: authentication query failed` / `57P03: the database system is not
accepting connections` — provável hibernação de plano free). Todo o trabalho foi
direcionado ao **banco local**:

```
postgresql://postgres:SUA_SENHA_LOCAL@localhost:5432/quero_comprar
(PostgreSQL 18.4)
```

---

## 2. Trabalhos Já Concluídos

### 2.1 Arquitetura HA (3 fases) — CONCLUÍDA

Implementada e verificada (backend sobe com nuvem fora do ar):

| Fase | Entregável                                                                                                                                                                          | Status |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| 1    | `utilities/supabase_keep_alive.py` — ping `SELECT 1` a cada 300s, com instruções cron/systemd/Windows                                                                               | ✅     |
| 2    | Circuit breaker no `backend/app/db/session.py` — failover automático `primary → fallback` (DATABASE_URL_PRIMARY / DATABASE_URL_FALLBACK), com cooldown de 60s e retomada automática | ✅     |
| 3    | Bootstrap do banco local em `backend/app/db/bootstrap.py` — detecta schema vazio e aplica `database/backups/backup_schema_latest.sql` via psql                                      | ✅     |

Evidências de verificação:

- `pytest backend/tests -q` → **20 passed**
- Boot real com nuvem fora: `/health` → `{"status":"ok","db_mode":"fallback"}`
- Log: `[FAILOVER] Nuvem inacessível. Redirecionando tráfego para Banco Local...`
- Log: `[BOOTSTRAP] Banco local já possui schema — bootstrap ignorado.`

### 2.2 Keep-Alive via GitHub Actions — CONCLUÍDA

O keep-alive deixou de rodar localmente (a pedido do usuário) e passou para CI:

- `utilities/github_supabase_ping.py` — ping único (`SELECT 1`), exit 0/1
- `.github/workflows/supabase_keep_alive.yml` — agendado `0 */12 * * *` + `workflow_dispatch`
- Necessário criar o secret `SUPABASE_DATABASE_URL` no GitHub (copiar o pooler URL do `backend/.env`)

---

## 3. Trabalho EM ANDAMENTO — Migração 65 (Limiares Z-Score)

### 3.1 Objetivo

Migrar de **threshold estático** (percentuais fixos ±15%/±25%) para **threshold
dinâmico** baseado no desvio padrão histórico (Z=1) de cada produto:

- **FASE 1:** μ e σ dos últimos 24 meses de `staging.fact_precos_mensais` por
  (id_produto, id_localidade); piso de segurança CV mínimo de 10%
- **FASE 2:** nova função `fn_status_cor_zscore` — VERMELHO se
  `preco_exibido > preco_referencia + σ`; VERDE se `< preco_referencia - σ`; senão AMARELO
- **FASE 3:** colunas `desvio_padrao_historico`, `limite_superior`, `limite_inferior`
  nas tabelas mart + MV `vw_api_produtos_sazonalidade`; recálculo de todas as cores
- **FASE 4:** refresh da MV + query de prova (Arroz ≈ 8% vs Tomate ≈ 35%)

### 3.2 Arquivo da Migração

```
database/65_limiares_cores_dinamicos_zscore.sql   (~743 linhas, BEGIN/COMMIT único, idempotente)
```

Conteúdo (escrito e revisado por sub-agente + orquestrador):

| Seção    | O que faz                                                                                             |
| -------- | ----------------------------------------------------------------------------------------------------- |
| FASE 1   | `staging.fn_estatisticas_volatilidade_24m()` — AVG/STDDEV/COUNT 24m + `desvio_efetivo` (CV floor 10%) |
| FASE 2   | `staging.fn_status_cor_zscore(preco, ref, desvio)` — regra ±1σ                                        |
| FASE 3.1 | `ALTER TABLE mart.sazonalidade_produto ADD COLUMN` (3 colunas)                                        |
| FASE 3.2 | `UPDATE` completo das 364.383 linhas com a nova regra                                                 |
| FASE 3.3 | `sp_calcular_sazonalidade()` reescrita com regra dinâmica                                             |
| FASE 3.4 | `vw_anchor_sazonalidade` recriada (DROP + CREATE) com status dinâmico                                 |
| FASE 3.5 | MV `vw_api_produtos_sazonalidade` V18 (3 ramos, 35 colunas) + índices                                 |

### 3.3 Histórico de Aplicação (importante)

| Tentativa         | Resultado                                                                                                                                     |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| 1ª                | ❌ Erro `cannot change name of view column status_cor...` (CREATE OR REPLACE VIEW não pode reordenar colunas). **Rollback limpo verificado.** |
| 2ª                | ❌ Falha por timeout do tool após ~5min; o backend continuou processando `CREATE MATERIALIZED VIEW`. **Rollback limpo verificado.**           |
| 3ª (nohup)        | ❌ MV materializando por **50+ minutos** a 98% CPU. **Causa raiz encontrada e corrigida** (ver abaixo). Rollback limpo.                       |
| 4ª (pós-correção) | ✅ **SUCESSO em ~30 segundos** — ver log abaixo.                                                                                              |

**Log da 4ª aplicação (psql `-v ON_ERROR_STOP=1`):**

```
BEGIN
CREATE FUNCTION          -- fn_estatisticas_volatilidade_24m (FASE 1)
CREATE FUNCTION          -- fn_status_cor_zscore (FASE 2)
ALTER TABLE              -- +3 colunas em mart.sazonalidade_produto (FASE 3.1)
UPDATE 364383            -- recalculo de todas as cores (FASE 3.2)
CREATE PROCEDURE         -- sp_calcular_sazonalidade dinâmico (FASE 3.3)
DROP MATERIALIZED VIEW   -- MV antiga V17
DROP VIEW                -- vw_anchor_sazonalidade
CREATE VIEW              -- vw_anchor_sazonalidade 18 cols (FASE 3.4)
CREATE MATERIALIZED VIEW -- vw_api_produtos_sazonalidade V18, 280.314 linhas
CREATE INDEX ×7          -- índices recriados
GRANT                    -- role_api_reader
COMMIT                   -- transação confirmada
```

### 3.4 Causa Raiz do Tempo Excessivo — CORRIGIDA

`EXPLAIN` confirmou **O(N²)**: as duas `LEFT JOIN LATERAL` dentro do
`vw_anchor_sazonalidade` liam a CTE `real` (~364k linhas) **sem índice**, uma
varredura completa por tupla:

```
CTE Scan on "real" r    <- full 364k-row CTE scan PER TUPLE
```

A migração 63 original só "funcionou" porque a MV V17 foi criada `WITH NO DATA` e
refrescada separadamente.

**Correção aplicada** (pelo mesmo sub-agente, validada com EXPLAIN):

- As LATERALs agora leem **direto da tabela base** `mart.sazonalidade_produto`
  (replicando o filtro inline), permitindo ao planner usar o índice
  `uq_sazonalidade(id_produto, id_localidade, ano, mes)`.
- Novo EXPLAIN confirma: `Index Scan using uq_sazonalidade_data_ref` em ambos os
  LATERALs — **sem mais CTE Scan por tupla**.
- A CTE `real` permanece apenas para a lista DISTINCT (passagem única, barata).

### 3.5 Estado Atual (após conclusão)

- ✅ Migração 65 **aplicada com sucesso** no banco local (4ª tentativa, ~30s)
- ✅ `staging.fn_status_cor_zscore(numeric,numeric,numeric)` presente
- ✅ `staging.fn_estatisticas_volatilidade_24m()` presente
- ✅ 3 colunas novas na base: `desvio_padrao_historico`, `limite_superior`, `limite_inferior`
- ✅ MV `vw_api_produtos_sazonalidade` V18 — **35 colunas** (32 + 3 novas), 280.314 linhas
  (verificação via `pg_catalog`; `information_schema.columns` retorna 0 para materialized views — quirk conhecido)
- ✅ `vw_anchor_sazonalidade` — 18 colunas
- ✅ Distribuição de cores na MV: AMARELO=230.374, VERDE=23.617, VERMELHO=26.323
- ✅ **FASE 4 concluída** — query de prova executada (ver seção 3.6)

---

## 3.6 FASE 4 — Query de Prova (ESTÁVEIS vs VOLÁTEIS)

**Métrica:** banda 1σ = `desvio_padrao_historico` (24m, piso CV 10%) ÷ `preco_referencia`.
Quanto menor a banda, menor a variação necessária para acender VERMELHO.

### Resultado agregado (REAL_ATUAL, todos os níveis)

```
 produto        | banda_media | banda_mediana | cor+15% | cor+25% | cor+40%
----------------+-------------+---------------+---------+---------+--------
 LEITE DE VACA  | 11.5%       | 10.2%         | VERMELHO| VERMELHO| VERMELHO
 ARROZ          | 17.5%       | 11.1%         | AMARELO | VERMELHO| VERMELHO
 BANANA         | 21.4%       | 13.1%         | AMARELO | VERMELHO| VERMELHO
 FEIJAO         | 23.7%       | 18.3%         | AMARELO | VERMELHO| VERMELHO
 CEBOLA         | 33.4%       | 32.2%         | AMARELO | AMARELO | VERMELHO
 TOMATE         | 35.4%       | 34.0%         | AMARELO | AMARELO | VERMELHO
```

### Interpretação

- **Tomate (volátil):** precisa de **~34–35%** de variação para VERMELHO — alinhado ao
  objetivo (~35%).
- **Arroz (estável):** acende VERMELHO com **~11–17%** (mediana 11,1%). O valor teórico
  ~8% é elevado pelo piso de segurança CV 10% (parte da especificação FASE 1).
- **Mesma variação, resultados diferentes:** com **+25%**, Leite/Arroz/Banana/Feijão
  ficam VERMELHO, mas **Tomate e Cebola permanecem AMARELO** — o limiar agora respeita
  a volatilidade histórica de cada produto.
- A função zscore usa comparação estrita `>`/`<`; no limite exato (preço = ref ± σ) o
  resultado é AMARELO (correto).

### Exemplo de linhas reais (Arroz/SP, MV com novas colunas)

```
 produto | uf | municipio | ano | mes | preco_referencia | desvio_padrao | limite_inferior | limite_superior | status_cor
---------+----+-----------+-----+-----+------------------+---------------+-----------------+-----------------+-----------
 ARROZ   | SP | SP (UF)   | 2026| 6   |           4.3727 |        0.4383 |          3.9344 |          4.8110 | AMARELO
```

---

## 4. Próximos Passos

1. ✅ **Reaplicada** `database/65_limiares_cores_dinamicos_zscore.sql` no banco local
   (sucesso na 4ª tentativa após correção do plano O(N²))
2. ✅ Verificado: função zscore presente, 3 colunas na base, MV V18 com 35 colunas
3. ✅ **FASE 4:** query de prova executada — Arroz VERMELHO com ~11–17% de variação;
   Tomate (volátil) só com ~34–35% (ver seção 3.6)
4. ✅ Log final da migração + output da query de prova registrados (acima)
5. ⏳ **Pendente:** quando o Supabase voltar ao ar, replicar a migração 65 no banco
   remoto (`scripts/deploy_v13_prod.sh` segue o padrão `psql -v ON_ERROR_STOP=1 -f`)
   e rodar `CALL staging.sp_executar_carga_completa()` para repopular a MV remota
6. ⏳ **Pendente:** atualizar `database/backups/backup_schema_latest.sql` (dump do schema)
   para refletir o novo schema da migração 65 — **somente via rotina de sync**, nunca
   edição manual

---

## 5. Referências

- Migração em análise: `database/65_limiares_cores_dinamicos_zscore.sql`
- Log da última tentativa: `/tmp/opencode/mig65.log`
- Relatório de exploração completo: `/home/pedroeduardo/.local/share/opencode/tool-output/tool_fc7cbb7bf001nXpF9QoUTFelfK`
- Base da migração 63 (MV V17): `database/63_dado_historico_real_transparencia.sql`
