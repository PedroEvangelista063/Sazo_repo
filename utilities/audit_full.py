import asyncio
import os
import sys
from pathlib import Path

sys.path.insert(0, ".")
os.environ["PYTHONIOENCODING"] = "utf-8"

# Carrega backend/.env se existir (não sobrescreve variáveis já definidas)
try:
    from dotenv import load_dotenv

    for env_path in (
        Path(__file__).resolve().parents[1] / "backend" / ".env",
        Path(__file__).resolve().parents[1] / ".env",
    ):
        if env_path.exists():
            load_dotenv(env_path)
except ImportError:
    pass

import asyncpg

DB_URL = (
    os.environ.get("DATABASE_URL")
    or os.environ.get("DATABASE_URL_ETL")
    or os.environ.get("DATABASE_URL_API")
    or "postgresql://postgres:postgres@localhost:5432/quero_comprar"
)


async def run():
    conn = await asyncpg.connect(DB_URL)

    print("=" * 65)
    print("AUDITORIA COMPLETA: DB -> API -> FRONTEND")
    print("=" * 65)

    # CHECK 0: Coverage por mes/ano
    print("\n[0] COBERTURA MENSAL NA fact_precos_mensais")
    rows = await conn.fetch("""
        SELECT ano, mes, COUNT(*) as total, COUNT(DISTINCT id_produto) as produtos,
               COUNT(DISTINCT id_localidade) as localidades
        FROM staging.fact_precos_mensais
        GROUP BY ano, mes ORDER BY ano DESC, mes DESC
        LIMIT 30
    """)
    for r in rows:
        print(
            f"  {r['ano']:04d}/{r['mes']:02d}: {r['total']:5d} registros | {r['produtos']:3d} produtos | {r['localidades']:3d} locais"
        )

    # CHECK 1: Produtos B2B na MV
    print("\n[1.1] PRODUTOS B2B NA MV (deve ser 0)")
    try:
        r = await conn.fetchval(
            "SELECT COUNT(*) FROM mart.vw_api_produtos_sazonalidade WHERE categoria_b2c != 'ALIMENTO_VAREJO'"
        )
        print(f"  B2B vazados: {r} {'OK' if r == 0 else 'CRITICO'}")
    except asyncpg.UndefinedTableError as e:
        print(f"  MV nao existe: {e}")

    # CHECK 2: INSUFICIENTE na MV
    print("\n[1.2] INSUFICIENTE NA MV (deve ser 0)")
    try:
        r = await conn.fetchval(
            "SELECT COUNT(*) FROM mart.vw_api_produtos_sazonalidade WHERE status_cor = 'INSUFICIENTE'"
        )
        print(f"  INSUFICIENTE vazados: {r} {'OK' if r == 0 else 'CRITICO'}")
    except asyncpg.UndefinedTableError as e:
        print(f"  (tabela nao existe: {e})")

    # CHECK 3: Distribuicao do semaforo
    print("\n[1.3] DISTRIBUICAO DO SEMAFORO")
    try:
        rows = await conn.fetch("""
            SELECT status_cor, COUNT(*) as total,
                   ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) as pct
            FROM mart.vw_api_produtos_sazonalidade
            GROUP BY status_cor ORDER BY status_cor
        """)
        for r in rows:
            print(f"  {r['status_cor']}: {r['total']} ({r['pct']:.1f}%)")
        total = sum(r["total"] for r in rows)
        print(f"  Total na MV: {total}")
    except asyncpg.UndefinedTableError as e:
        print(f"  (tabela nao existe: {e})")

    # CHECK 4: Campos obrigatorios
    print("\n[1.4] CAMPOS OBRIGATORIOS (todos devem ser 0)")
    try:
        r = await conn.fetchrow("""
            SELECT
                COUNT(*) FILTER (WHERE produto IS NULL OR produto = '') AS nome_nulo,
                COUNT(*) FILTER (WHERE uf IS NULL OR LENGTH(uf) != 2) AS uf_invalida,
                COUNT(*) FILTER (WHERE status_cor IS NULL) AS status_nulo,
                COUNT(*) FILTER (WHERE ano IS NULL OR ano < 2020 OR ano > 2030) AS ano_invalido,
                COUNT(*) FILTER (WHERE mes IS NULL OR mes < 1 OR mes > 12) AS mes_invalido
            FROM mart.vw_api_produtos_sazonalidade
        """)
        for k, v in r.items():
            print(f"  {k}: {v} {'OK' if v == 0 else 'PROBLEMA'}")
    except asyncpg.UndefinedTableError as e:
        print(f"  (tabela nao existe: {e})")

    # CHECK 5: Precos invalidos na fact
    print("\n[1.5] PRECO_INVALIDOS (deve ser 0)")
    r = await conn.fetchval(
        "SELECT COUNT(*) FROM staging.fact_precos_mensais WHERE preco_medio <= 0 OR preco_medio IS NULL"
    )
    print(f"  Precos <= 0: {r} {'OK' if r == 0 else 'PROBLEMA'}")

    # CHECK 6: Precos rejeitados
    print("\n[1.6] PRECOS REJEITADOS (anomalias > 500%)")
    try:
        rows = await conn.fetch("""
            SELECT p.nome_produto, l.uf, pr.razao, pr.rejeitado_em
            FROM staging.precos_rejeitados pr
            JOIN staging.dim_produto p ON p.id_produto = pr.id_produto
            JOIN staging.dim_localidade l ON l.id_localidade = pr.id_localidade
            ORDER BY pr.rejeitado_em DESC LIMIT 5
        """)
        for r in rows:
            nome = r["nome_produto"].encode("ascii", "replace").decode("ascii")
            print(f"  {nome[:25]:<25} {r['uf']:<3} razao={r['razao']} {r['rejeitado_em']}")
    except UnicodeEncodeError as e:
        print(f"  (encoding error no nome do produto: {e})")

    # CHECK 7: Freshness
    print("\n[1.7] FRESHNESS DOS DADOS")
    try:
        r = await conn.fetchrow("""
            SELECT
                MAX(ano || '-' || LPAD(mes::TEXT, 2, '0')) AS data_mais_recente,
                MIN(ano || '-' || LPAD(mes::TEXT, 2, '0')) AS data_mais_antiga,
                COUNT(DISTINCT ano || '-' || mes) AS periodos_distintos,
                COUNT(*) AS total_registros
            FROM mart.vw_api_produtos_sazonalidade
        """)
        print(f"  Mais recente: {r['data_mais_recente']}")
        print(f"  Mais antiga:  {r['data_mais_antiga']}")
        print(f"  Periodos:     {r['periodos_distintos']}")
        print(f"  Total:        {r['total_registros']}")
    except asyncpg.UndefinedTableError as e:
        print(f"  (tabela nao existe: {e})")

    # CHECK 8: Fallback proportion
    print("\n[1.8] PROPORCAO DE FALLBACK")
    try:
        rows = await conn.fetch("""
            SELECT usou_fallback_12m, COUNT(*) as total,
                   ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) as pct
            FROM mart.vw_api_produtos_sazonalidade
            GROUP BY usou_fallback_12m
        """)
        for r in rows:
            print(f"  usou_fallback_12m={r['usou_fallback_12m']}: {r['total']} ({r['pct']:.1f}%)")
    except asyncpg.UndefinedTableError as e:
        print(f"  (tabela nao existe: {e})")

    # CHECK 9: Baseline 2025 coverage (tabela por produto/localidade, sem coluna ano)
    print("\n[1.9] COBERTURA BASELINE 2025 (baseline_2025_interpolado)")
    try:
        r = await conn.fetchrow("""
            SELECT COUNT(*) as total,
                   COUNT(DISTINCT id_produto) as produtos,
                   COUNT(DISTINCT id_localidade) as localidades
            FROM staging.baseline_2025_interpolado
        """)
        print(
            f"  total: {r['total']} | produtos: {r['produtos']} | localidades: {r['localidades']}"
        )
    except asyncpg.UndefinedTableError as e:
        print(f"  (tabela nao existe: {e})")

    # CHECK 10: Controle de carga
    print("\n[1.10] ULTIMOS BATCHES DE CARGA")
    try:
        rows = await conn.fetch("""
            SELECT arquivo, status, linhas_lidas, linhas_inseridas, iniciado_em
            FROM raw.controle_carga ORDER BY iniciado_em DESC LIMIT 5
        """)
        for r in rows:
            print(
                f"  {r['arquivo'][:30]:<30} {r['status']:<10} lidas={r['linhas_lidas']} inseridas={r['linhas_inseridas']} {r['iniciado_em']}"
            )
    except asyncpg.UndefinedTableError:
        print("  (raw.controle_carga vazia ou nao existe)")

    # CHECK 11: Ultimos registros carregados
    print("\n[1.11] ULTIMOS REGISTROS INSERIDOS (full pipeline)")
    rows = await conn.fetch("""
        SELECT fp.ano, fp.mes, p.nome_produto, l.uf, fp.preco_medio, fp.batch_id, fp.loaded_at
        FROM staging.fact_precos_mensais fp
        JOIN staging.dim_produto p ON p.id_produto = fp.id_produto
        JOIN staging.dim_localidade l ON l.id_localidade = fp.id_localidade
        ORDER BY fp.loaded_at DESC LIMIT 5
    """)
    for r in rows:
        print(
            f"  {r['nome_produto'][:25]:<25} {r['uf']:<3} {r['ano']:04d}/{r['mes']:02d} R$ {r['preco_medio']:.2f} batch={str(r['batch_id'])[:8]}"
        )

    await conn.close()
    print("\n" + "=" * 65)
    print("AUDITORIA CONCLUIDA")
    print("=" * 65)


asyncio.run(run())
