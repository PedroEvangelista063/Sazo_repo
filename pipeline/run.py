"""
Orquestrador do pipeline completo (DEPRECATED — use ingestao_conab.py).

Este módulo é mantido apenas para referência histórica.
O pipeline antigo escrevia em tabelas `municipios` e `seasonality_index`
que não fazem parte do schema medalhão oficial e não são lidas pela API.

Substituído por: python -m pipeline.ingestao_conab

Diferenças:
  - Fontes: PrecosMensalUF.txt + ProhortMensal.txt
  - Destino: staging.dim_produto, staging.dim_localidade, staging.fact_precos_mensais
  - Pós-carga: CALL staging.sp_executar_carga_completa() + REFRESH MV
"""

import logging
import sys

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)-8s %(name)s — %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("pipeline.run")


def run() -> None:
    logger.warning("=" * 60)
    logger.warning("  run.py está DEPRECATED.")
    logger.warning("  Use: python -m pipeline.ingestao_conab")
    logger.warning("=" * 60)

    from pipeline.ingestao_conab import run as run_ingestao

    run_ingestao()


if __name__ == "__main__":
    try:
        run()
    except Exception as exc:
        logger.exception("Pipeline falhou: %s", exc)
        sys.exit(1)
