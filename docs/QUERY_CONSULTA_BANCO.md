# 🔍 Consultas SQL — Quero Comprar VG

Conjunto de queries para diagnóstico de dados no Supabase remoto.
Use no **SQL Editor** do dashboard: https://supabase.com/dashboard/project/kxsqrcccaaxplpktmutl/sql/new

---

## 📌 Informações do Projeto

| Item                                     | Valor                                                 |
| ---------------------------------------- | ----------------------------------------------------- |
| Project ID                               | `kxsqrcccaaxplpktmutl`                                |
| Host                                     | `aws-1-us-east-1.pooler.supabase.com`                 |
| Portas                                   | `5432` (pooler transacional) / `6543` (pooler sessão) |
| PostgreSQL                               | `17`                                                  |
| Total registros no `fact_precos_mensais` | `42.358`                                              |
| Período                                  | `2024-01` a `2026-12`                                 |

---

## Sumário

- [1. GAP Detalhado por Produto](#1-gap-detalhado-por-produto)
- [2. Ranking de Produtos com Mais Gaps](#2-ranking-de-produtos-com-mais-gaps)
- [3. Localidades Órfãs](#3-localidades-%C3%B3rf%C3%A3s)
- [4. Produtos Órfãos](#4-produtos-%C3%B3rf%C3%A3os)
- [5. Resumo Executivo](#5-resumo-executivo)
- [6. Gaps Recentes (últimos 6 meses)](#6-gaps-recentes-%C3%BAltimos-6-meses)
- [7. Visão Geral de Produtos com Gaps](#7-vis%C3%A3o-geral-de-produtos-com-gaps)
- [8. Teste de Conexão (terminal)](#8-teste-de-conex%C3%A3o-terminal)

---

<!-- ================================================================== -->

## 1. GAP Detalhado por Produto

Mostra **produto + localidade + quais meses específicos estão faltando**.
Já filtra apenas produtos que têm dado **parcial** (exclui os 100% e os 0%).

```sql
WITH periodos AS (
    SELECT generate_series(2024, 2026) AS ano,
           generate_series(1, 12) AS mes
),
gaps_detalhados AS (
    SELECT
        p.id_produto,
        p.nome_produto,
        l.id_localidade,
        l.uf,
        l.municipio_nome,
        -- Meses faltantes
        COUNT(*) FILTER (WHERE f.id_fato IS NULL) AS meses_ausentes,
        string_agg(
            CASE WHEN f.id_fato IS NULL
                 THEN per.ano || '-' || LPAD(per.mes::TEXT, 2, '0')
                 ELSE NULL
            END,
            ', ' ORDER BY per.ano, per.mes
        ) AS quais_meses_faltam,
        -- Meses presentes
        COUNT(*) FILTER (WHERE f.id_fato IS NOT NULL) AS meses_presentes,
        -- Primeira e última coleta
        MIN(f.ano || '-' || LPAD(f.mes::TEXT, 2, '0')) FILTER (WHERE f.id_fato IS NOT NULL) AS primeira_coleta,
        MAX(f.ano || '-' || LPAD(f.mes::TEXT, 2, '0')) FILTER (WHERE f.id_fato IS NOT NULL) AS ultima_coleta,
        -- Sazonalidade do gap (por trimestre)
        COUNT(*) FILTER (WHERE f.id_fato IS NULL AND per.mes BETWEEN 1 AND 3) AS gaps_trim1,
        COUNT(*) FILTER (WHERE f.id_fato IS NULL AND per.mes BETWEEN 4 AND 6) AS gaps_trim2,
        COUNT(*) FILTER (WHERE f.id_fato IS NULL AND per.mes BETWEEN 7 AND 9) AS gaps_trim3,
        COUNT(*) FILTER (WHERE f.id_fato IS NULL AND per.mes BETWEEN 10 AND 12) AS gaps_trim4
    FROM staging.dim_produto p
    CROSS JOIN staging.dim_localidade l
    CROSS JOIN periodos per
    LEFT JOIN staging.fact_precos_mensais f
        ON f.id_produto = p.id_produto
        AND f.id_localidade = l.id_localidade
        AND f.ano = per.ano
        AND f.mes = per.mes
    GROUP BY p.id_produto, p.nome_produto, l.id_localidade, l.uf, l.municipio_nome
)
SELECT *
FROM gaps_detalhados
WHERE meses_ausentes > 0
  AND meses_presentes > 0  -- Só produtos que TEM algum dado (gaps parciais)
ORDER BY meses_ausentes DESC, nome_produto
LIMIT 100;
```

---

<!-- ================================================================== -->

## 2. Ranking de Produtos com Mais Gaps

Produtos ordenados por **taxa de ocupação** (menor = mais gaps).

```sql
SELECT
    p.nome_produto,
    COUNT(DISTINCT f.id_localidade) AS localidades_atingidas,
    COUNT(*) AS total_registros,
    COUNT(DISTINCT f.ano || '-' || LPAD(f.mes::TEXT, 2, '0')) AS meses_unicos,
    ROUND(
        COUNT(*)::NUMERIC /
        (COUNT(DISTINCT f.id_localidade) *
         COUNT(DISTINCT f.ano || '-' || LPAD(f.mes::TEXT, 2, '0'))), 3
    ) AS taxa_ocupacao,  -- 1.0 = 100% preenchido
    COALESCE(MIN(f.ano || '-' || LPAD(f.mes::TEXT, 2, '0')), 'NUNCA') AS primeira_coleta,
    COALESCE(MAX(f.ano || '-' || LPAD(f.mes::TEXT, 2, '0')), 'NUNCA') AS ultima_coleta
FROM staging.fact_precos_mensais f
JOIN staging.dim_produto p ON p.id_produto = f.id_produto
GROUP BY p.nome_produto
HAVING COUNT(*) > 1
ORDER BY taxa_ocupacao ASC
LIMIT 30;
```

---

<!-- ================================================================== -->

## 3. Localidades Órfãs

Localidades que **existem na dimensão mas NUNCA receberam dado**.
Ajuda a identificar erro de ETL/ELT.

```sql
SELECT
    l.id_localidade,
    l.uf,
    COALESCE(l.municipio_nome, '(agregado UF)') AS localidade,
    l.criado_em,
    CASE
        WHEN l.municipio_nome IS NULL OR l.municipio_nome = ''
             THEN 'Agregado UF — normal se não coletado'
        ELSE 'Município sem dado — POSSÍVEL ERRO DE ETL'
    END AS diagnostico
FROM staging.dim_localidade l
WHERE NOT EXISTS (
    SELECT 1 FROM staging.fact_precos_mensais f
    WHERE f.id_localidade = l.id_localidade
)
ORDER BY l.uf, l.municipio_nome;
```

---

<!-- ================================================================== -->

## 4. Produtos Órfãos

Produtos **cadastrados mas que NUNCA tiveram coleta**.
Classifica por tipo suspeito.

```sql
SELECT
    p.id_produto,
    p.nome_produto,
    p.criado_em,
    p.status_coleta,
    p.categoria_nec,
    CASE
        WHEN p.nome_produto ~* '^(Bacalhau|Camarão|Salmão|Merluza|Lagosta|Berbigão|Pescada|Corvina|Pargo|Robalo|Tainha|Anchova|Sardinha|Atum|Cavalinha|Dourado|Garoupa|Namorado|Olho de Boi|Peixe|Siri|Polvo|Lula|Mexilhão|Ostra|Vieira)'
             THEN 'Provável produto sem coleta (nicho/especialidade)'
        WHEN p.nome_produto ~* 'Importada|Importado'
             THEN 'Produto importado — coleta mais rara'
        WHEN p.nome_produto ~* '(Rosa|Cravo|Lírio|Orquídea|Girassol|Tulipa|Gladíolo|Crisântemo|Agapanto|Ficus|Astro|Margarida|Bromélia|Lavanda|Hortênsia|Palma|Samambaia|Jasmim|Lírio|Lotus|Musgo|Narciso|Papoula|Petúnia|Primavera|Begônia|Gardênia|Gérbera|Hera|Kalanchoe|Manacá|Onze Horas|Pau d\'água|Peixinho|Pingo de Ouro|Singônio|Violeta|Zamioculca|Antúrio|Bambu|Cacto|Comigo|Dinheiro em Penca|Espada de São Jorge|Hera|Lança|Lírio da Paz|Pata de Elefante|Pau Brasil|Pleomele|Ripsális|Singônio|Trevo|Zamioculca|Alecrim|Hortelã|Manjericão|Sálvia|Tomilho|Salsa|Cebolinha|Coentro)'
             THEN 'Planta ornamental ou erva — coleta esporádica'
        ELSE 'Suspeito — verificar se deveria ter coleta'
    END AS diagnostico
FROM staging.dim_produto p
WHERE NOT EXISTS (
    SELECT 1 FROM staging.fact_precos_mensais f
    WHERE f.id_produto = p.id_produto
)
ORDER BY diagnostico, p.nome_produto;
```

---

<!-- ================================================================== -->

## 5. Resumo Executivo

Visão geral de saúde do banco em uma única consulta.

```sql
SELECT
    'LOCALIDADES' AS secao,
    COUNT(*) FILTER (WHERE tem_dado = true)::TEXT || ' de ' || COUNT(*)::TEXT || ' com dado' AS info
FROM (
    SELECT EXISTS (SELECT 1 FROM staging.fact_precos_mensais f WHERE f.id_localidade = l.id_localidade) AS tem_dado
    FROM staging.dim_localidade l
) sub
UNION ALL
SELECT 'PRODUTOS',
    COUNT(*) FILTER (WHERE tem_dado = true)::TEXT || ' de ' || COUNT(*)::TEXT || ' com dado'
FROM (
    SELECT EXISTS (SELECT 1 FROM staging.fact_precos_mensais f WHERE f.id_produto = p.id_produto) AS tem_dado
    FROM staging.dim_produto p
) sub
UNION ALL
SELECT 'TOTAL REGISTROS', COUNT(*)::TEXT FROM staging.fact_precos_mensais
UNION ALL
SELECT 'PERÍODO', MIN(ano) || '-' || MAX(ano) FROM staging.fact_precos_mensais
UNION ALL
SELECT 'MÉDIA MESES/PRODUTO/LOCAL',
    ROUND(COUNT(*)::NUMERIC / (COUNT(DISTINCT id_produto) * COUNT(DISTINCT id_localidade)), 2)::TEXT
FROM staging.fact_precos_mensais;
```

---

<!-- ================================================================== -->

## 6. Gaps Recentes (últimos 6 meses)

Produtos que estão **sem dado nos meses mais recentes** — prioridade de coleta.

```sql
WITH ultimos_6_meses AS (
    SELECT ano, mes
    FROM (
        VALUES
            (2026, 7), (2026, 6), (2026, 5),
            (2026, 4), (2026, 3), (2026, 2)
    ) AS t(ano, mes)
)
SELECT
    p.nome_produto,
    l.uf,
    l.municipio_nome,
    string_agg(um.ano || '-' || LPAD(um.mes::TEXT, 2, '0'), ', ' ORDER BY um.ano, um.mes) AS meses_faltando
FROM staging.dim_produto p
CROSS JOIN staging.dim_localidade l
CROSS JOIN ultimos_6_meses um
LEFT JOIN staging.fact_precos_mensais f
    ON f.id_produto = p.id_produto
    AND f.id_localidade = l.id_localidade
    AND f.ano = um.ano
    AND f.mes = um.mes
WHERE f.id_fato IS NULL
  AND EXISTS (
      SELECT 1 FROM staging.fact_precos_mensais f2
      WHERE f2.id_produto = p.id_produto
        AND f2.id_localidade = l.id_localidade
  )
GROUP BY p.nome_produto, l.uf, l.municipio_nome
ORDER BY COUNT(*) DESC
LIMIT 30;
```

---

<!-- ================================================================== -->

## 7. Visão Geral de Produtos com Gaps

Lista produtos que têm **muitas localidades mas poucos meses** por localidade.

```sql
SELECT
    p.nome_produto,
    COUNT(DISTINCT f.id_localidade) AS qtd_localidades,
    COUNT(*) AS total_registros,
    ROUND(COUNT(*)::NUMERIC / NULLIF(COUNT(DISTINCT f.id_localidade), 0), 1) AS media_meses_por_local,
    CASE
        WHEN ROUND(COUNT(*)::NUMERIC / NULLIF(COUNT(DISTINCT f.id_localidade), 0), 1) <= 2 THEN 'GRAVE'
        WHEN ROUND(COUNT(*)::NUMERIC / NULLIF(COUNT(DISTINCT f.id_localidade), 0), 1) <= 6 THEN 'MEDIO'
        ELSE 'OK'
    END AS gap_level
FROM staging.fact_precos_mensais f
JOIN staging.dim_produto p ON p.id_produto = f.id_produto
GROUP BY p.nome_produto
HAVING COUNT(DISTINCT f.id_localidade) >= 5
ORDER BY media_meses_por_local ASC
LIMIT 50;
```

---

<!-- ================================================================== -->

## 8. Teste de Conexão (terminal)

Comandos para testar a conexão com o Supabase remoto pelo terminal Linux.

```bash
# A credencial NUNCA deve ser colada em arquivo versionado.
# Carregue a URL do backend/.env (gitignored) antes dos comandos:
export DATABASE_URL="$(grep -E '^DATABASE_URL_PRIMARY=' backend/.env | cut -d= -f2-)"

# Teste de rede
nc -zv aws-1-us-east-1.pooler.supabase.com 5432

# Conexão direta com psql
psql "$DATABASE_URL" -c "SELECT version();"

# Listar tabelas
psql "$DATABASE_URL" -c "\dt"

# Conexão via Python
python3 -c "
import asyncio, asyncpg, os
async def test():
    conn = await asyncpg.connect(os.environ['DATABASE_URL'])
    print('Conectado! Versao:', await conn.fetchval('SELECT version()'))
    await conn.close()
asyncio.run(test())
"

# Verificar migrations aplicadas
psql "$DATABASE_URL" -c "SELECT * FROM supabase_migrations.schema_migrations;"
```
