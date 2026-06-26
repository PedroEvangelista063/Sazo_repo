"""
Módulo de ingestão de dados da CONAB.

Faz download dos arquivos PrecosMensalUF.txt e PrecosMensalMunicipio.txt
com retry exponencial e streaming para não explodir memória.
"""

import time
import logging
from pathlib import Path

import httpx

logger = logging.getLogger(__name__)

CONAB_URLS: dict[str, str] = {
    "uf": "https://portaldeinformacoes.conab.gov.br/downloads/arquivos/PrecosMensalUF.txt",
    "prohort": "https://portaldeinformacoes.conab.gov.br/downloads/arquivos/ProhortMensal.txt",
}

RAW_DIR = Path(__file__).parent / "data" / "raw"


def download_file(
    url: str,
    dest: Path,
    retries: int = 3,
    timeout: int = 180,
) -> Path:
    """
    Baixa um arquivo via streaming com retry exponencial.

    Args:
        url: URL do arquivo a baixar.
        dest: Caminho de destino local.
        retries: Número máximo de tentativas.
        timeout: Timeout em segundos por tentativa.

    Returns:
        Path do arquivo salvo.

    Raises:
        httpx.HTTPError: Se todas as tentativas falharem.
    """
    dest.parent.mkdir(parents=True, exist_ok=True)

    for attempt in range(retries):
        try:
            logger.info("Baixando %s (tentativa %d/%d)...", url, attempt + 1, retries)
            with httpx.stream(
                "GET",
                url,
                timeout=timeout,
                follow_redirects=True,
                headers={"User-Agent": "QueroComprar/1.0 (dados publicos CONAB)"},
            ) as response:
                response.raise_for_status()
                bytes_written = 0
                with open(dest, "wb") as f:
                    for chunk in response.iter_bytes(chunk_size=65_536):
                        f.write(chunk)
                        bytes_written += len(chunk)
            logger.info("Download concluído: %s (%.1f MB)", dest.name, bytes_written / 1_048_576)
            return dest

        except (httpx.TimeoutException, httpx.HTTPStatusError) as exc:
            logger.warning("Tentativa %d falhou: %s", attempt + 1, exc)
            if attempt == retries - 1:
                raise
            wait = 2**attempt  # 1s, 2s, 4s
            logger.info("Aguardando %ds antes de tentar novamente...", wait)
            time.sleep(wait)

    raise RuntimeError("Unreachable")


def ingest_all(output_dir: Path = RAW_DIR) -> dict[str, Path]:
    """
    Baixa todos os arquivos CONAB para o diretório especificado.

    Returns:
        Dicionário {chave: caminho_arquivo} para cada fonte.
    """
    results: dict[str, Path] = {}
    for key, url in CONAB_URLS.items():
        dest = output_dir / f"conab_{key}.txt"
        results[key] = download_file(url, dest)
    return results


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    paths = ingest_all()
    for key, path in paths.items():
        print(f"{key}: {path} ({path.stat().st_size / 1_048_576:.1f} MB)")
