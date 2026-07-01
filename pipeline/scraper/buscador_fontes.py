from __future__ import annotations

import asyncio
import json
import logging
from dataclasses import dataclass, field
from pathlib import Path

import httpx

logger = logging.getLogger(__name__)

PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
CONFIG_PATH = PROJECT_ROOT / "pipeline" / "scraper" / "config_termos_busca.json"
REPORT_PATH = PROJECT_ROOT / "logs" / "fontes_descobertas.json"

BROWSER_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/125.0.0.0 Safari/537.36"
    ),
    "Accept-Language": "pt-BR,pt;q=0.9",
}

# Mapa de fontes governamentais conhecidas por UF
FONTES_CONHECIDAS: dict[str, list[dict]] = {
    "SP": [
        {"nome": "CEAGESP", "url": "https://ceagesp.gov.br/cotacoes/", "tipo": "ceasa"},
        {"nome": "IEA", "url": "https://iea.agricultura.sp.gov.br/", "tipo": "instituto"},
        {"nome": "SAA-SP", "url": "https://www.agricultura.sp.gov.br/", "tipo": "secretaria"},
    ],
    "MG": [
        {"nome": "CEASA-MG", "url": "https://www.ceasa.mg.gov.br/cotacoes", "tipo": "ceasa"},
        {"nome": "EMATER-MG", "url": "https://www.emater.mg.gov.br/", "tipo": "emater"},
        {"nome": "SEAPA-MG", "url": "https://www.agricultura.mg.gov.br/", "tipo": "secretaria"},
    ],
    "GO": [
        {"nome": "CEASA-GO", "url": "https://www.ceasa.go.gov.br/cotacao", "tipo": "ceasa"},
    ],
    "PR": [
        {"nome": "SEAB-PR", "url": "https://www.agricultura.pr.gov.br/", "tipo": "secretaria"},
        {"nome": "DERAL", "url": "https://www.agricultura.pr.gov.br/deral", "tipo": "deral"},
        {"nome": "CEASA-PR", "url": "https://www.ceasa.pr.gov.br/cotacao", "tipo": "ceasa"},
    ],
    "SC": [
        {"nome": "EPAGRI", "url": "https://www.epagri.sc.gov.br/", "tipo": "epagri"},
        {"nome": "CEASA-SC", "url": "https://www.ceasa.sc.gov.br/", "tipo": "ceasa"},
    ],
    "RS": [
        {"nome": "EMATER-RS", "url": "https://www.emater.tche.br/", "tipo": "emater"},
        {"nome": "CEASA-RS", "url": "https://www.ceasa.rs.gov.br/cotacao", "tipo": "ceasa"},
    ],
    "DF": [
        {"nome": "CEASA-DF", "url": "https://www.ceasa.df.gov.br/", "tipo": "ceasa"},
    ],
    "BA": [
        {"nome": "CEASA-BA", "url": "https://www.ceasa.ba.gov.br/", "tipo": "ceasa"},
    ],
    "CE": [
        {"nome": "CEASA-CE", "url": "https://www.ceasa.ce.gov.br/cotacao", "tipo": "ceasa"},
    ],
}


@dataclass
class FonteDescoberta:
    nome: str
    url: str
    tipo: str
    uf: str
    municipio: str = ""
    status: str = "pendente"
    status_code: int = 0
    conteudo_tem_tabela: bool = False
    erro: str = ""


@dataclass
class RelatorioDescoberta:
    fontes: list[FonteDescoberta] = field(default_factory=list)
    total_encontradas: int = 0
    total_acessiveis: int = 0
    total_com_tabela: int = 0

    def para_dict(self) -> dict:
        return {
            "total_encontradas": self.total_encontradas,
            "total_acessiveis": self.total_acessiveis,
            "total_com_tabela": self.total_com_tabela,
            "fontes": [
                {
                    "nome": f.nome,
                    "url": f.url,
                    "tipo": f.tipo,
                    "uf": f.uf,
                    "status": f.status,
                    "status_code": f.status_code,
                    "tem_tabela": f.conteudo_tem_tabela,
                    "erro": f.erro,
                }
                for f in self.fontes
            ],
        }


def carregar_config() -> dict:
    if not CONFIG_PATH.exists():
        logger.warning("Config nao encontrado em %s", CONFIG_PATH)
        return {}
    return json.loads(CONFIG_PATH.read_text(encoding="utf-8"))


def construir_urls_candidatas(config: dict) -> list[dict]:
    candidatas: list[dict] = []
    fontes_nomes = config.get("termos_base", {}).get("fontes_de_autoridade", [])
    ufs = config.get("ufs_prioritarias", ["SP", "MG", "GO", "PR", "SC", "RS", "DF", "BA", "CE"])

    padroes_url = [
        "https://www.{fonte}.{uf}.gov.br/cotacao",
        "https://www.{fonte}.{uf}.gov.br/precos",
        "https://{fonte}.{uf}.gov.br/cotacao",
        "https://www.{fonte}.{uf}.gov.br/",
    ]

    for uf in ufs:
        uf_lower = uf.lower()
        for nome in fontes_nomes:
            if nome in ("conab", "cepea", "embrapa", "ibge", "sampa"):
                continue
            for padrao in padroes_url:
                url = padrao.format(fonte=nome, uf=uf_lower)
                candidatas.append(
                    {
                        "nome": f"{nome.upper()}-{uf}",
                        "url": url,
                        "tipo": nome,
                        "uf": uf,
                    }
                )
    return candidatas


async def sondar_fonte(client: httpx.AsyncClient, fonte: dict) -> FonteDescoberta:
    resultado = FonteDescoberta(
        nome=fonte["nome"],
        url=fonte["url"],
        tipo=fonte["tipo"],
        uf=fonte.get("uf", ""),
    )
    try:
        r = await client.get(fonte["url"], timeout=15, follow_redirects=True)
        resultado.status_code = r.status_code
        if r.status_code < 400:
            resultado.status = "acessivel"
            texto = r.text.lower()
            resultado.conteudo_tem_tabela = any(
                marcador in texto
                for marcador in [
                    "<table",
                    "<tr>",
                    "<td",
                    "cotacao",
                    "preco",
                    "produto",
                    "hortifruti",
                ]
            )
        else:
            resultado.status = "falha_http"
    except httpx.TimeoutException:
        resultado.status = "timeout"
        resultado.erro = "timeout"
    except httpx.ConnectError:
        resultado.status = "inacessivel"
        resultado.erro = "conexao_recusada"
    except Exception as exc:
        resultado.status = "erro"
        resultado.erro = str(exc)[:100]
    return resultado


async def sondar_todas(candidatas: list[dict], max_concorrencia: int = 5) -> list[FonteDescoberta]:
    sem = asyncio.Semaphore(max_concorrencia)
    resultados: list[FonteDescoberta] = []

    async with httpx.AsyncClient(headers=BROWSER_HEADERS) as client:

        async def _sondar(f: dict) -> FonteDescoberta:
            async with sem:
                return await sondar_fonte(client, f)

        tasks = [_sondar(f) for f in candidatas]
        for coro in asyncio.as_completed(tasks):
            resultados.append(await coro)

    return resultados


def gerar_relatorio(resultados: list[FonteDescoberta]) -> RelatorioDescoberta:
    rel = RelatorioDescoberta(fontes=resultados)
    rel.total_encontradas = len(resultados)
    rel.total_acessiveis = sum(1 for r in resultados if r.status == "acessivel")
    rel.total_com_tabela = sum(1 for r in resultados if r.conteudo_tem_tabela)
    return rel


async def descobrir_fontes() -> RelatorioDescoberta:
    config = carregar_config()
    candidatas = construir_urls_candidatas(config)

    for uf, fontes in FONTES_CONHECIDAS.items():
        for f in fontes:
            if not any(c["url"] == f["url"] for c in candidatas):
                candidatas.append(f)

    logger.info("Sondando %d candidatas...", len(candidatas))
    resultados = await sondar_todas(candidatas, max_concorrencia=5)

    rel = gerar_relatorio(resultados)
    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    REPORT_PATH.write_text(
        json.dumps(rel.para_dict(), ensure_ascii=False, indent=2), encoding="utf-8"
    )

    logger.info(
        "Descoberta concluida: %d candidatas, %d acessiveis, %d com tabela",
        rel.total_encontradas,
        rel.total_acessiveis,
        rel.total_com_tabela,
    )
    return rel


def fontes_para_localidades(resultados: list[FonteDescoberta]) -> list[dict]:
    localidades: list[dict] = []
    for r in resultados:
        if r.status == "acessivel" and r.conteudo_tem_tabela:
            localidades.append(
                {
                    "uf": r.uf,
                    "municipio": r.municipio or r.uf,
                    "fonte": r.nome,
                }
            )
    return localidades


# ---- CLI ----
if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        datefmt="%H:%M:%S",
    )
    rel = asyncio.run(descobrir_fontes())
    dados = rel.para_dict()
    print(f"\nFontes descobertas: {dados['total_encontradas']}")
    print(f"  Acessiveis:   {dados['total_acessiveis']}")
    print(f"  Com tabela:   {dados['total_com_tabela']}")
    print(f"  Relatorio:    {REPORT_PATH}")
    print()
    for f in dados["fontes"]:
        icone = {True: "OK", False: "XX"}.get(f["tem_tabela"], "??")
        print(f"  [{icone}] {f['nome']:25s} {f['status']:15s} HTTP {f['status_code']}  {f['url']}")
