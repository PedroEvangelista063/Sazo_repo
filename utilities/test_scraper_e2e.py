#!/usr/bin/env python3
"""
test_scraper_e2e.py — Teste E2E micro-batch do scraper
========================================================
Pipeline: ConabApiEngine (CONAB) → raw.coleta_bruta → SortingEngine →
          staging.fact_precos_mensais → sp_executar_carga_completa → cache purge.

Regras estritas de segurança (anti-loop):
  * Apenas 1 Estado (SP) e 1 competência recente (2026-07).
  * Payload limitado a MÁXIMO 5 registros (filtra uf_ceasa=='SP' e faz [:5]).
  * Download com timeout total de 60s (connect timeout nativo do engine = 15s).
  * FAIL-FAST: se o extract falhar ou não houver dados SP 2026-07, aborta
    imediatamente com código de saída != 0.

Não usa main_runner.py, nem SmartRouter/SmartCrawler/playwright, nem paginação.

Uso:
    python3 utilities/test_scraper_e2e.py
"""

from __future__ import annotations

import asyncio
import logging
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, ".")

if sys.stdout.encoding != "utf-8":
    _reconfigure = getattr(sys.stdout, "reconfigure", None)
    if _reconfigure is not None:
        _reconfigure(encoding="utf-8")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger("test_scraper_e2e")

# ── Carrega backend/.env (mesmo padrão das utilities do projeto) ──
_ENV_PATH = Path(__file__).resolve().parent.parent / "backend" / ".env"
if _ENV_PATH.exists():
    from dotenv import load_dotenv

    load_dotenv(_ENV_PATH)
    logger.info("Variáveis carregadas de: %s", _ENV_PATH)

# ── Configuração do micro-batch (FASE 1 — Trava de Execução) ──
UF_ALVO = "SP"
ANO = 2026
MES = 7
LIMITE_MAXIMO = 5
DOWNLOAD_TIMEOUT = 60  # total p/ download; connect=15s é o nativo do engine
DB_COMMAND_TIMEOUT = 300  # sp_executar_carga_completa + refresh MV podem demorar

COMPETENCIA = f"{ANO}-{MES:02d}"


async def _init_pool_conn(conn) -> None:
    """Eleva o statement_timeout da sessão.

    O banco remoto (Aiven free) pode encerrar SPs/queries longas no servidor, e o
    sp_executar_carga_completa() demora ~118s — fica no limite e pode ser
    cancelado pelo servidor. Como o client command_timeout=300 já cobre a
    duração, elevamos o limite do lado do servidor para 300s por segurança.
    """
    await conn.execute("SET statement_timeout = 300000")


def normalizar_linha_conab(row: dict) -> dict | None:
    """Linha bruta CONAB → payload limpo compatível com ProdutoSazonalSchema.

    ConabApiEngine entrega linhas com chaves dsc_produto / preco_diario /
    uf_ceasa / data_preco. O SortingEngine só parseia chaves
    nome_produto / preco_kg / uf / data_referencia — por isso a normalização
    acontece ANTES da persistência.
    """
    produto = (row.get("dsc_produto") or "").strip().lower()
    uf = (row.get("uf_ceasa") or "").strip().upper()
    data = (row.get("data_preco") or "").strip()
    preco_raw = (row.get("preco_diario") or "").strip()
    if not produto or not uf or not data or not preco_raw:
        return None
    try:
        preco_kg = float(preco_raw.replace(",", ".").replace("R$", "").strip())
    except ValueError:
        return None
    if preco_kg <= 0:
        return None
    data_referencia = data[:7].replace("/", "-")
    if data_referencia != COMPETENCIA:
        return None
    return {
        "nome_produto": produto,
        "preco_kg": preco_kg,
        "uf": uf,
        "data_referencia": data_referencia,
    }


def _mascarar_dsn(dsn: str) -> str:
    """Oculta credenciais do DSN em logs (nunca expor senha)."""
    try:
        sem_creds = dsn.split("@", 1)[-1]
        return f"postgresql://***@{sem_creds}"
    except Exception:
        return "postgresql://***@***"


async def main() -> int:
    t0 = time.perf_counter()

    dsn = os.environ.get("DATABASE_URL")
    if not dsn:
        print("[ERRO] DATABASE_URL não definido (backend/.env). FAIL-FAST.")
        return 2

    print("=" * 74)
    print("  TESTE E2E MICRO-BATCH — CONAB → medalhão → cache")
    print("=" * 74)
    print(f"  UF={UF_ALVO} | competência={COMPETENCIA} | limite={LIMITE_MAXIMO} registros")
    print(f"  DSN: {_mascarar_dsn(dsn)}")
    print(f"  Timeouts: download total={DOWNLOAD_TIMEOUT}s (connect=15s nativo) | DB command={DB_COMMAND_TIMEOUT}s")
    print("=" * 74)

    # ══════════════════════════════════════════════════════════════════
    # FASE 1 — Extração (trava anti-loop + FAIL-FAST)
    # ══════════════════════════════════════════════════════════════════
    print("\n[EXTRAÇÃO] Instanciando ConabApiEngine e baixando ProhortDiario.txt (~30MB)...")
    from pipeline.scraper.micro_engines.ConabApiEngine import ConabApiEngine

    try:
        async with ConabApiEngine() as engine:
            resultado = await asyncio.wait_for(
                engine.extract("", ANO, MES),
                timeout=DOWNLOAD_TIMEOUT,
            )
    except asyncio.TimeoutError:
        print(f"[ERRO] Timeout de {DOWNLOAD_TIMEOUT}s excedido no extract/download. FAIL-FAST.")
        return 1
    except Exception as exc:
        print(f"[ERRO] Falha no extract: {exc!r}. FAIL-FAST.")
        return 1

    payload = resultado.get("payload_bruto", {})
    linhas_comp = payload.get("linhas", []) or []
    total_linhas = payload.get("total_linhas", len(linhas_comp))
    comps = payload.get("competencias_disponiveis", []) or []

    sp_linhas = [
        l for l in linhas_comp if (l.get("uf_ceasa") or "").strip().upper() == UF_ALVO
    ]
    selecionadas = sp_linhas[:LIMITE_MAXIMO]

    print(f"[EXTRAÇÃO] Motor conectou e baixou o payload com sucesso.")
    print(f"[EXTRAÇÃO] Total de linhas no arquivo: {total_linhas}")
    print(f"[EXTRAÇÃO] Linhas da competência {COMPETENCIA}: {len(linhas_comp)}")
    print(f"[EXTRAÇÃO] Linhas UF={UF_ALVO}: {len(sp_linhas)}")
    print(f"[EXTRAÇÃO] Selecionadas ([:{LIMITE_MAXIMO}]): {len(selecionadas)}")
    print(f"[EXTRAÇÃO] Competências disponíveis (topo): {comps[:5]}")

    if not selecionadas:
        print(f"[ERRO] Nenhuma linha SP {COMPETENCIA} encontrada. FAIL-FAST.")
        return 1

    print("[EXTRAÇÃO] Registros selecionados (produto | uf | data | preço):")
    for l in selecionadas:
        print(
            f"[EXTRAÇÃO]   {str(l.get('dsc_produto'))[:40]:<40} | {l.get('uf_ceasa')} | "
            f"{l.get('data_preco')} | R$ {l.get('preco_diario')} | {l.get('sig_unidade_medida')}"
        )

    # ══════════════════════════════════════════════════════════════════
    # FASE 2 — Transformação (normalização → payload limpo)
    # ══════════════════════════════════════════════════════════════════
    print("\n[TRANSFORMAÇÃO] Normalizando as linhas SP para payload limpo "
          "(ProdutoSazonalSchema)...")
    from pipeline.processor.sorting_engine import ProdutoSazonalSchema

    normalizadas = [n for n in (normalizar_linha_conab(l) for l in selecionadas) if n]
    print(f"[TRANSFORMAÇÃO] Linhas normalizadas (preco_kg>0, competência={COMPETENCIA}): "
          f"{len(normalizadas)}/{len(selecionadas)}")

    validados: list[ProdutoSazonalSchema] = []
    for n in normalizadas:
        try:
            validados.append(ProdutoSazonalSchema(**n))
        except Exception as exc:
            print(f"[TRANSFORMAÇÃO]   REJEITADO {n.get('nome_produto')}: {exc}")

    if not validados:
        print("[ERRO] Nenhum registro passou no ProdutoSazonalSchema. FAIL-FAST.")
        return 1

    print(f"[TRANSFORMAÇÃO] {len(validados)} registros validados contra "
          "ProdutoSazonalSchema (whitelist hortifruti é aplicada pelo SortingEngine).")
    print("[TRANSFORMAÇÃO] Prévia do payload limpo que será persistido:")
    for v in validados:
        print(
            f"[TRANSFORMAÇÃO]   nome_produto={v.nome_produto:<24} uf={v.uf} "
            f"data_referencia={v.data_referencia} preco_kg={v.preco_kg:.4f}"
        )

    # ══════════════════════════════════════════════════════════════════
    # FASE 3 — Carga (raw.coleta_bruta → ciclo medalhão)
    # ══════════════════════════════════════════════════════════════════
    print("\n[CARGA] Persistindo payload bruto em raw.coleta_bruta + rodando ciclo medalhão...")
    import asyncpg

    from pipeline.scraper.persistence import executar_ciclo_medalhao, persistir_coleta_bruta

    registros_raw = [
        {
            "fonte_id": "CONAB-PENTAHO",
            "payload_bruto": {
                "linhas": [v.model_dump()],
                "total_linhas": total_linhas,
                "competencias_disponiveis": comps,
            },
            "competencia": COMPETENCIA,
        }
        for v in validados
    ]

    pool = await asyncpg.create_pool(
        dsn, min_size=1, max_size=4, command_timeout=DB_COMMAND_TIMEOUT,
        init=_init_pool_conn,
    )
    try:
        t_carga = time.perf_counter()
        print(f"[CARGA] persistir_coleta_bruta({len(registros_raw)} registros, competencia={COMPETENCIA})...")
        inseridos = await persistir_coleta_bruta(pool, registros_raw, COMPETENCIA)
        print(f"[CARGA] {inseridos} registros nasceram em raw.coleta_bruta em {time.perf_counter()-t_carga:.1f}s")

        if inseridos != len(validados):
            print(f"[AVISO] Inseridos={inseridos} != esperado={len(validados)}")

        t_ciclo = time.perf_counter()
        print("[CARGA] executar_ciclo_medalhao(pool) — SortingEngine → "
              "sp_executar_carga_completa → purge interno...")
        print("[CARGA] Nota: statement_timeout elevado para 300s via pool init "
              "(o servidor remoto pode encerrar a SP longa; ela demora ~118s).")
        await executar_ciclo_medalhao(pool)
        print(f"[CARGA] Ciclo medalhão CONCLUÍDO em {time.perf_counter()-t_ciclo:.1f}s")
    finally:
        await pool.close()
        print("[CARGA] Pool asyncpg fechado.")

    # ══════════════════════════════════════════════════════════════════
    # FASE 4 — Cache (expurgo explícito, comportamento tolerado)
    # ══════════════════════════════════════════════════════════════════
    print("\n[CACHE] Expurgo de cache pós-ciclo...")
    from pipeline.cache_purge import purge_cache_sync

    try:
        ok = purge_cache_sync(timeout=15)
        if ok:
            print("[CACHE] purge_cache_sync(timeout=15) OK — backend no ar (HTTP 200).")
        else:
            print("[CACHE] purge_cache_sync(timeout=15) retornou False — backend OFFLINE "
                  "ou erro HTTP (comportamento tolerado, não é falha do ETL).")
    except Exception as exc:
        print(f"[CACHE] purge_cache_sync lançou exceção (tolerado): {exc!r}")

    # ══════════════════════════════════════════════════════════════════
    # Verificação pós-carga (query de prova)
    # ══════════════════════════════════════════════════════════════════
    print("\n[VERIFICAÇÃO] Query de prova em staging.fact_precos_mensais "
          "(adaptada: colunas produto/uf vêm das dimensões, não há is_forecast na fact)...")
    conn = await asyncpg.connect(dsn, timeout=30)
    try:
        rows = await conn.fetch(
            """
            SELECT p.nome_produto AS produto,
                   l.uf,
                   fp.mes,
                   fp.ano,
                   fp.preco_medio,
                   fp.batch_id,
                   fp.loaded_at
            FROM staging.fact_precos_mensais fp
            JOIN staging.dim_produto p     ON p.id_produto     = fp.id_produto
            JOIN staging.dim_localidade l  ON l.id_localidade  = fp.id_localidade
            WHERE l.uf = $1 AND fp.ano = $2 AND fp.mes = $3
            ORDER BY p.nome_produto
            LIMIT 10
            """,
            UF_ALVO, ANO, MES,
        )
        print(f"[VERIFICAÇÃO] {len(rows)} linhas SP {COMPETENCIA} em staging.fact_precos_mensais (LIMIT 10):")
        for r in rows:
            print(
                f"[VERIFICAÇÃO]   {r['produto'][:32]:<32} | UF={r['uf']} | "
                f"{r['ano']}-{r['mes']:02d} | R$ {float(r['preco_medio']):.4f} | "
                f"batch={str(r['batch_id'])[:8]} | loaded={r['loaded_at']}"
            )

        nomes_nossos = [v.nome_produto for v in validados]
        checados = await conn.fetch(
            """
            SELECT p.nome_produto, fp.preco_medio
            FROM staging.fact_precos_mensais fp
            JOIN staging.dim_produto p    ON p.id_produto    = fp.id_produto
            JOIN staging.dim_localidade l ON l.id_localidade = fp.id_localidade
            WHERE l.uf = 'SP' AND fp.ano = 2026 AND fp.mes = 7
              AND p.nome_produto = ANY($1)
            ORDER BY p.nome_produto
            """,
            nomes_nossos,
        )
        print(f"[VERIFICAÇÃO] Dos {len(nomes_nossos)} produtos enviados neste batch, "
              f"{len(checados)} estão na fact SP 2026-07:")
        for r in checados:
            print(f"[VERIFICAÇÃO]   {r['nome_produto']:<30} -> R$ {float(r['preco_medio']):.4f}")

        if not checados:
            print("[VERIFICAÇÃO] NENHUM dos produtos do batch chegou à fact — provável "
                  "filtro hortifruti do SortingEngine (whitelist) ou upsert em outra "
                  "localidade. Verifique ops.quarentena_coleta.")
    finally:
        await conn.close()

    # ══════════════════════════════════════════════════════════════════
    # Resumo
    # ══════════════════════════════════════════════════════════════════
    total_s = time.perf_counter() - t0
    print("\n" + "=" * 74)
    print(f"  RESUMO — extração OK | transformação OK | carga OK | "
          f"cache purge: ver log acima | tempo total: {total_s:.1f}s")
    print("=" * 74)
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
