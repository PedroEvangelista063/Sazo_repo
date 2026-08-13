"""
Pipeline inteligente de ingestão CONAB → PostgreSQL (Arquitetura Medalhão).
==============================================================

Este script implementa o **Cômodo 1 (GARAGEM)** da planta baixa do projeto "QUERO
COMPRAR". Responsabilidades:

1.  Ler múltiplos arquivos ``LISTA*.txt`` em paralelo via Polars lazy.
2.  Aplicar o **Motor Semântico (Regex)** para categorizar cada produto em
    ``ALIMENTO_VAREJO`` (B2C), ``MAQUINARIO_FERRAMENTA``, ``INSUMO_AGRICOLA``,
    ``SERVICO_LOGISTICA`` ou ``MATERIA_PRIMA_B2B``.
3.  Separar **B2C (ALIMENTO_VAREJO)** — único dado que chega ao app consumidor —
    de **B2B** (tratores, insumos químicos, serviços), que é registrado apenas
    para auditoria.
4.  Carregar apenas B2C no PostgreSQL via ``COPY`` / ``execute_values`` (nunca
    INSERT linha por linha).

Regra da Sala de Estar:
    TRATOR, ZINCO, TRANSPORTE e BORRACHA NATURAL são categoricamente proibidos
    de chegar ao banco de dados do aplicativo B2C final. O filtro
    ``categoria_b2c = 'ALIMENTO_VAREJO'`` é a última barreira antes do mart.

Dependências:
    pip install polars psycopg2-binary python-dotenv
"""

from __future__ import annotations

import io
import logging
import os
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import ClassVar, NoReturn

import polars as pl
import psycopg2
from dotenv import load_dotenv
from psycopg2.extras import execute_values

load_dotenv()

logger = logging.getLogger("ingestao_conab_inteligente")

# ──────────────────────────────────────────────────────────────────────
# Constantes de ambiente
# ──────────────────────────────────────────────────────────────────────

DATABASE_URL: str = os.environ.get(
    "DATABASE_URL",
    "postgresql://postgres:postgres@localhost:5432/quero_comprar",
)

LOCAL_DATA_DIR: str = os.path.join(
    os.path.dirname(__file__),
    "..",
    "dados_sazonliza_dados_bruto",
)

COPY_BATCH_SIZE: int = 50_000

# ──────────────────────────────────────────────────────────────────────
# Resultado
# ──────────────────────────────────────────────────────────────────────


@dataclass
class ResultadoCarga:
    arquivo: str
    linhas_lidas: int = 0
    linhas_b2c: int = 0
    linhas_b2b: int = 0
    linhas_inseridas: int = 0
    duracao_seg: float = 0.0
    categorias_encontradas: set[str] = field(default_factory=set)


# ══════════════════════════════════════════════════════════════════════
# MOTOR SEMÂNTICO — O coração da Garagem
# ══════════════════════════════════════════════════════════════════════
#
# Por que Regex ê a ferramenta certa aqui:
#   - Os dados CONAB não têm ontologia, taxonomia ou ID de categoria.
#   - O padrão é sempre o **inicio da string**: "TRATOR 150 16X16 ..."
#   - Regex linear é O(n) — para os ~50k produtos/mês da CONAB, executa
#     em milissegundos sobre um DataFrame Polarizado.
#   - Se a CONAB um dia adicionar coluna de categoria, trocamos a origem.
#
# Regra da Sala de Estar:
#   ALIMENTO_VAREJO é a única categoria que atravessa o filtro da
#   Materialized View. Todo o resto é trator ou insumo — não pertence
#   ao app de supermercado.


class MotorCategorizacao:
    """Motor baseado em Expressões Regulares para classificar produtos CONAB.

    As regex são avaliadas na ordem de definição do dicionário. A
    **primeira** correspondência ganha (short-circuit via ``pl.when().then()``).
    Se nada corresponder, o fallback é ``MATERIA_PRIMA_B2B``.
    """

    REGRAS: ClassVar[dict[str, str]] = {
        # ── Caixa 1: Maquinário e ferramentas agrcolas ──────────────
        # Captura tratores, implementos, EPIs e ferramentas.
        # Ex: "TRATOR 150 16X16 JOHN DEERE", "BOTA DE SEGURANÇA"
        # Oleos nao-comestiveis (diesel, lubrificante, hidraulico, etc.)
        # precisam ser capturados ANTES de ALIMENTO_VAREJO.
        "MAQUINARIO_FERRAMENTA": (
            r"(?i)^(TRATOR|ESCARIFICADOR|ESCADA|PAQUIMETRO|"
            r"BOTA|LUVAS|TRAPICHO|COLHEDEIRA|PULVERIZADOR|"
            r"SEMEADEIRA|ADUBADEIRA|ARADO|GRADE|"
            r"OLEO DIESEL|OLEO LUBRIFICANTE|"
            r"OLEO HIDRAULICO|OLEO SINTETICO|OLEO QUEIMADO)\b"
        ),
        # ── Caixa 2: Insumos agrícolas (fertilizantes, defensivos) ──
        # Fórmulas N-P-K como "00-18-18", nomes comerciais e genéricos.
        # Ex: "ZINCO QUELATIZADO", "00-18-18", "SENCOR 500 SC"
        # OLEO MINERAL e OLEO VEGETA sao insumos, NAO alimentos de varejo.
        # NOTA: OLEO VEGETA\b nao captura OLEO VEGETAL (sem word boundary
        # entre A e L). OLEO VEGETAL é ALIMENTO_VAREJO (Caixa 4).
        "INSUMO_AGRICOLA": (
            r"(?i)^(00-\d{2}-\d{2}|ZINCO|FLUMYZIN|NATIVO|SENCOR|"
            r"SEMENTE|NEMAT|FLUIL|NHT|OLEO VEGETA|OLEO MINERAL|PARA BROCA|"
            r"UREIA|SULFATO|CLORETO|FERTIL|FOSFATO|"
            r"FUNGICIDA|HERBICIDA|INSETICIDA|ACARICIDA|"
            r"GLIFOSATO|ATRAZINA|MANCOZEB)\b"
        ),
        # ── Caixa 3: Serviços de logística e transporte ────────────
        # Preços por hora/serviço, não por kg.
        # Ex: "TRANSPORTE INTERNO", "PASSAGEM AEREA"
        "SERVICO_LOGISTICA": (
            r"(?i)^(TRANSPORTE|PASSAGEM|PATIO|TRATAMENTO|"
            r"FRETE|ALUGUEL|HORA|DIARIA|SERVICO)\b"
        ),
        # ── Caixa 4: ALIMENTO_VAREJO — O Ouro (único que vai pro App) ─
        # Alimentos de consumo doméstico direto. Produtos de açougue,
        # hortifruti, padaria e mercearia básica.
        # Ex: "CARNE BOVINA", "PAO FRANCES", "TOMATE SALADA"
        #
        # SEGURANÇA DE ÓLEOS:
        #   - Óleo DIESEL/LUBRIFICANTE/HIDRAULICO/SINTETICO/QUEIMADO
        #     são capturados pela Caixa 1 (MAQUINARIO_FERRAMENTA).
        #   - Óleo MINERAL é capturado pela Caixa 2 (INSUMO_AGRICOLA).
        #   - Aqui entram APENAS óleos comestı́veis explı́citos:
        #     "OLEO DE SOJA", "OLEO VEGETAL", etc.
        #   - Qualquer produto que começe com "OLEO" e não esteja
        #     nas listas acima cai como MATERIA_PRIMA_B2B (seguro).
        "ALIMENTO_VAREJO": (
            r"(?i)^(CARNE|PAO|FLOCOS DE MILHO|ERVA MATE|TOMATE|"
            r"FRANGO|ARROZ|FEIJAO|BATATA|CENOURA|CEBOLA|ALFACE|"
            r"REPOLHO|ABOBRINHA|PIMENTAO|LARANJA|BANANA|MACA|"
            r"MAMAO|UVA|MELANCIA|GOIABA|ABACATE|ACEROLA|"
            r"LEITE|QUEIJO|IOGURTE|MANTEIGA|OVOS|FARINHA|"
            r"MILHO|TRIGO|SOJA|CAFE|ACUCAR|"
            r"OLEO DE (SOJA|GIRASSOL|BABACU|COPAIBA|MURUMURU|"
            r"PEQUI|ALGOD[ÃA]O|MILHO|CANOLA|DEND[EÊ]|COCO|"
            r"LINHA[ÇC]A|ABACATE|PALMA|AMENDOIM|GERGELIM)|"
            r"OLEO VEGETAL|AZEITE|"
            r"SAL|MACARR[AÃ]O|BISCOITO|CHOCOLATE|ACHOCOLATADO)\b"
        ),
        # ── Fallback: tudo que não se encaixa acima ─────────────────
        # Ex: "BORRACHA NATURAL", "CELULOSE", "ALGODAO"
        # Nenhuma regex aqui — o fallback é implicito no Motor.
    }

    @classmethod
    def aplicar(cls, df: pl.DataFrame, coluna: str = "produto") -> pl.DataFrame:
        """Aplica as regras de categorização e adiciona ``categoria_b2c``.

        A ordem de avaliação é a do dicionário ``REGRAS``:
        ``MAQUINARIO_FERRAMENTA`` → ``INSUMO_AGRICOLA`` → ``SERVICO_LOGISTICA``
        → ``ALIMENTO_VAREJO``. O fallback é ``MATERIA_PRIMA_B2B``.

        Args:
            df: DataFrame com pelo menos a coluna ``coluna``.
            coluna: Nome da coluna com o nome do produto (default: ``"produto"``).

        Returns:
            DataFrame com a coluna extra ``categoria_b2c``.
        """
        expr = pl.lit("MATERIA_PRIMA_B2B")
        for categoria, pattern in cls.REGRAS.items():
            expr = (
                pl.when(pl.col(coluna).str.contains(pattern))
                .then(pl.lit(categoria))
                .otherwise(expr)
            )

        return df.with_columns(expr.alias("categoria_b2c"))


# ══════════════════════════════════════════════════════════════════════
# FUNÇÕES DE TRANSFORMAÇÃO
# ══════════════════════════════════════════════════════════════════════


def _sanitizar_preco(series: pl.Series) -> pl.Series:
    """Converte string ``'2,27'`` para ``Float64`` (null se inválido).

    A CONAB usa vírgula como separador decimal (padrão brasileiro).
    PostgreSQL e o resto do mundo usam ponto. Esta função faz a ponte.
    """
    return series.str.strip_chars().str.replace(",", ".").cast(pl.Float64, strict=False)


def _sanitizar_texto(series: pl.Series) -> pl.Series:
    """Strip padding e uppercase — normalização mínima para match de regex."""
    return series.str.strip_chars().str.to_uppercase()


COLUNAS_COM_HEADER: list[str] = [
    "produto",
    "classificao_produto",
    "id_produto",
    "uf",
    "regiao",
    "ano",
    "mes",
    "dsc_nivel_comercializacao",
    "valor_produto_kg",
]


def _detecta_header(primeira_linha: str) -> bool:
    """Detecta se a primeira linha do arquivo é um cabeçalho.

    Cabeçalho sempre começa com ``produto`` (case-insensitive).
    Dados reais começam com nome de produto (ex: ``BOTA``, ``00-18-18``, ``TRATOR``).
    """
    primeira_col = primeira_linha.split(";")[0].strip().lower()
    return primeira_col == "produto"


def ler_arquivo_local(caminho: str | Path) -> pl.DataFrame:
    """Lê um arquivo ``LISTA*.txt`` e retorna DataFrame semi-bruto.

    Layout esperado (separador ``;``):
        ``produto;classificao_produto;id_produto;uf;regiao;ano;mes;dsc_nivel_comercializacao;valor_produto_kg``

    Layout alternativo (com ``municipio``):
        ``produto;classificao_produto;id_produto;municipio;codigo_ibge;uf;regiao;ano;mes;dsc_nivel_comercializacao;valor_produto_kg``

    Args:
        caminho: Caminho para o arquivo ``.txt``.

    Returns:
        DataFrame com colunas normalizadas. A coluna ``valor_produto_kg`` é
        mantida como string (a conversão para Float64 ocorre depois).
    """
    raw = Path(caminho).read_text(encoding="utf-8")
    linhas = raw.splitlines()
    if not linhas:
        return pl.DataFrame()

    tem_header = _detecta_header(linhas[0])
    if not tem_header:
        colunas = COLUNAS_COM_HEADER[:]
        if len(linhas[0].split(";")) > len(colunas):
            colunas = [
                "produto",
                "classificao_produto",
                "id_produto",
                "municipio",
                "codigo_ibge",
                "uf",
                "regiao",
                "ano",
                "mes",
                "dsc_nivel_comercializacao",
                "valor_produto_kg",
            ]
        df = pl.read_csv(
            io.StringIO(raw),
            separator=";",
            has_header=False,
            new_columns=colunas[: len(linhas[0].split(";"))],
            infer_schema_length=0,
            ignore_errors=True,
            truncate_ragged_lines=True,
        )
    else:
        df = pl.read_csv(
            io.StringIO(raw),
            separator=";",
            infer_schema_length=0,
            ignore_errors=True,
            truncate_ragged_lines=True,
        )
    # Normaliza nomes de colunas: espaços → underscore, lowercase
    df = df.rename({c: c.strip().lower().replace(" ", "_").replace("-", "_") for c in df.columns})
    # Strip todas as colunas string
    for c in df.columns:
        if df[c].dtype == pl.Utf8:
            df = df.with_columns(_sanitizar_texto(pl.col(c)).alias(c))
    return df


# ══════════════════════════════════════════════════════════════════════
# CARREGADOR POSTGRESQL
# ══════════════════════════════════════════════════════════════════════


class CarregadorMedalhao:
    """Carrega dados B2C no esquema Medalhão do PostgreSQL.

    Fluxo:
        1. Sincroniza dimensões (``dim_produto``, ``dim_localidade``).
        2. Insere na tabela fato (``fact_precos_mensais``) via ``execute_values``.
        3. Aciona o ciclo medalhão (cálculo de sazonalidade + refresh MV).

    Nunca insere linha por linha. Nunca carrega B2B.
    """

    def __init__(self, database_url: str = DATABASE_URL) -> None:
        self._database_url = database_url

    def _conexao(self):
        conn = psycopg2.connect(self._database_url, options="-c timezone=UTC")
        conn.set_session(autocommit=False)
        return conn

    def _sincronizar_dimensoes(self, conn, df: pl.DataFrame) -> dict:
        """Garante que dimensões existam e retorna mapping ``{chave: id}``."""
        with conn.cursor() as cur:
            produtos = set(df["produto"].to_list())
            execute_values(
                cur,
                "INSERT INTO staging.dim_produto (nome_produto) VALUES %s ON CONFLICT DO NOTHING",
                [(p,) for p in produtos],
            )
            cur.execute("SELECT id_produto, nome_produto FROM staging.dim_produto")
            prod_map = {nome: pid for pid, nome in cur.fetchall()}

            localidades = set()
            for row in df.select(["uf"]).unique().iter_rows():
                localidades.add((row[0], "", ""))
            if "municipio_id" in df.columns:
                for row in df.select(["uf", "municipio_id", "municipio_nome"]).unique().iter_rows():
                    localidades.add(
                        (
                            row[0],
                            row[1] if row[1] else None,
                            row[2] if row[2] else None,
                        )
                    )

            execute_values(
                cur,
                "INSERT INTO staging.dim_localidade (uf, municipio_id, municipio_nome) "
                "VALUES %s ON CONFLICT (uf, municipio_id) DO NOTHING",
                [(uf, mid, mn) for uf, mid, mn in localidades],
            )
            cur.execute("SELECT id_localidade, uf, municipio_id FROM staging.dim_localidade")
            loc_map = {(row[1], row[2]): row[0] for row in cur.fetchall()}

        conn.commit()
        return {"produtos": prod_map, "localidades": loc_map}

    def _inserir_fato(self, conn, df: pl.DataFrame, mapping: dict, batch_id: str) -> int:
        """Insere dados na ``fact_precos_mensais`` via ``execute_values``."""
        prod_map = mapping["produtos"]
        loc_map = mapping["localidades"]

        rows: list[tuple] = []
        vistos: set[tuple] = set()

        municipio_field = "municipio_id" in df.columns

        # Colunas de unidade (Migration 82): presentes no ETL diário CONAB
        # (transform per-unidade) e ausentes nos demais caminhos — usa None.
        cols = df.columns
        unidade_idx = cols.index("unidade_canonica") if "unidade_canonica" in cols else None
        fator_idx = cols.index("fator_kg") if "fator_kg" in cols else None
        fluxo_idx = cols.index("fluxo_unidade") if "fluxo_unidade" in cols else None

        for row in df.iter_rows():
            produto = row[0]
            uf = row[1] if not municipio_field else row[3]
            ano = row[2] if not municipio_field else row[4]
            mes = row[3] if not municipio_field else row[5]
            preco = row[4] if not municipio_field else row[6]
            mun_id = None if not municipio_field else (row[1] if row[1] else None)

            unidade = row[unidade_idx] if unidade_idx is not None else None
            fator = row[fator_idx] if fator_idx is not None else None
            fluxo = row[fluxo_idx] if fluxo_idx is not None else None

            loc_key = (uf, None) if mun_id is None else (uf, mun_id)
            id_prod = prod_map.get(produto)
            id_loc = loc_map.get(loc_key)
            if id_prod is None or id_loc is None:
                continue

            # Chave de dedup inclui a unidade: kg e cx do mesmo (produto, UF,
            # ano, mes) coexistem como linhas distintas (Migration 82).
            chave = (id_prod, id_loc, ano, mes, unidade)
            if chave in vistos:
                continue
            vistos.add(chave)
            rows.append((id_prod, id_loc, ano, mes, preco, unidade, fator, fluxo, batch_id))

        if not rows:
            return 0

        sql = """
            INSERT INTO staging.fact_precos_mensais
                (id_produto, id_localidade, ano, mes, preco_medio,
                 unidade_canonica, fator_kg, fluxo_unidade, batch_id)
            VALUES %s
            ON CONFLICT (id_produto, id_localidade, ano, mes,
                         (COALESCE(unidade_canonica, 'kg')))
            DO UPDATE SET
                preco_medio = EXCLUDED.preco_medio,
                batch_id    = EXCLUDED.batch_id,
                loaded_at   = NOW()
        """
        total = 0
        with conn.cursor() as cur:
            for i in range(0, len(rows), COPY_BATCH_SIZE):
                batch = rows[i : i + COPY_BATCH_SIZE]
                execute_values(cur, sql, batch, page_size=COPY_BATCH_SIZE)
                total += len(batch)
        conn.commit()
        return total

    def _executar_ciclo_medalhao(self, conn) -> None:
        """Aciona SP de sazonalidade + refresh da Materialized View + purge cache."""
        with conn.cursor() as cur:
            cur.execute("CALL staging.sp_executar_carga_completa()")
        conn.commit()

        # Notifica backend para limpar cache
        try:
            from pipeline.cache_purge import purge_cache_sync
            purge_cache_sync()
        except Exception:
            logger.warning("Cache purge falhou (backend offline?) — continuando.")

    def _atualizar_categorias(self, conn, categorias: dict[str, str]) -> None:
        """Atualiza ``categoria_b2c`` na ``dim_produto`` para auditoria."""
        if not categorias:
            return
        with conn.cursor() as cur:
            for nome, cat in categorias.items():
                cur.execute(
                    "UPDATE staging.dim_produto SET categoria_b2c = %s "
                    "WHERE nome_produto = %s "
                    "AND categoria_b2c IS DISTINCT FROM %s",
                    (cat, nome, cat),
                )
        conn.commit()
        logger.info("Categorias atualizadas: %d produtos", len(categorias))

    def carregar(
        self,
        df_b2c: pl.DataFrame,
        categorias: dict[str, str] | None = None,
    ) -> int:
        """Carrega DataFrame B2C no medalhão.

        Args:
            df_b2c: DataFrame com colunas ``UF_COLUMNS`` (ou ``MUN_COLUMNS``).
            categorias: Dict ``{nome_produto: categoria}`` para atualizar
                        a dimensão (opcional).

        Returns:
            Número de linhas inseridas na fato.
        """
        batch_id = str(uuid.uuid4())
        conn = self._conexao()
        try:
            mapping = self._sincronizar_dimensoes(conn, df_b2c)
            inseridas = self._inserir_fato(conn, df_b2c, mapping, batch_id)
            self._executar_ciclo_medalhao(conn)

            if categorias:
                self._atualizar_categorias(conn, categorias)

            return inseridas
        except Exception:
            conn.rollback()
            logger.exception("Carga falhou — rollback executado")
            raise
        finally:
            conn.close()


# ══════════════════════════════════════════════════════════════════════
# ORQUESTRADOR
# ══════════════════════════════════════════════════════════════════════


class IngestaoInteligente:
    """Orquestrador principal da Garagem.

    Fluxo:
        1. Descobre arquivos ``LISTA*.txt`` no diretório de dados.
        2. Para cada arquivo: lê → categoriza → separa B2C de B2B.
        3. Concatena todos os B2C em um único DataFrame e carrega.
        4. Atualiza categorias na dimensão para auditoria.

    Uso:
        >>> ingestao = IngestaoInteligente()
        >>> resultado = ingestao.executar()
        >>> print(f"{resultado.linhas_b2c} B2C inseridas")
    """

    def __init__(
        self,
        data_dir: str = LOCAL_DATA_DIR,
        database_url: str = DATABASE_URL,
    ) -> None:
        self._data_dir = Path(data_dir)
        self._carregador = CarregadorMedalhao(database_url)

    def _descobrir_arquivos(self) -> list[Path]:
        """Retorna lista ordenada de ``LISTA*.txt`` no diretório de dados."""
        if not self._data_dir.is_dir():
            logger.warning("Diretório não encontrado: %s", self._data_dir)
            return []
        arquivos = sorted(self._data_dir.glob("LISTA*.txt"))
        logger.info(
            "Descobertos %d arquivo(s) LISTA*.txt em %s",
            len(arquivos),
            self._data_dir,
        )
        return arquivos

    def _processar_arquivo(self, caminho: Path) -> tuple[pl.DataFrame | None, dict[str, str]]:
        """Lê, categoriza e separa um arquivo LISTA*.txt.

        Returns:
            Tupla ``(df_b2c, categorias)`` onde:
            - ``df_b2c``: DataFrame apenas com ALIMENTO_VAREJO pronto para load.
            - ``categorias``: Dict ``{nome_produto: categoria}``.
        """
        df = ler_arquivo_local(str(caminho))
        if df.height == 0:
            return None, {}

        # Normaliza colunas de municipio
        rename_mun = {}
        if "municipio" in df.columns and "municipio_nome" not in df.columns:
            rename_mun["municipio"] = "municipio_nome"
        if "codigo_ibge" in df.columns and "municipio_id" not in df.columns:
            rename_mun["codigo_ibge"] = "municipio_id"
        if rename_mun:
            df = df.rename(rename_mun)

        # Preserva nome original + combina com classificacao para unicidade
        df = df.with_columns(pl.col("produto").alias("_produto_original"))
        if "classificao_produto" in df.columns:
            df = df.with_columns(
                (pl.col("produto") + " - " + pl.col("classificao_produto")).alias("produto")
            )

        # Motor semântico
        df = MotorCategorizacao.aplicar(df)
        categorias = dict(df.select(["produto", "categoria_b2c"]).unique().iter_rows())

        # Converte preço (vírgula → ponto) e filtra inválidos
        preco_col = "preco_medio" if "preco_medio" in df.columns else "valor_produto_kg"
        if preco_col != "preco_medio":
            df = df.rename({preco_col: "preco_medio"})

        df = df.with_columns(
            _sanitizar_preco(pl.col("preco_medio")).alias("preco_medio"),
            pl.col("ano").cast(pl.Int32, strict=False),
            pl.col("mes").cast(pl.Int32, strict=False),
        )
        df = df.filter(
            pl.col("preco_medio").is_not_null()
            & (pl.col("preco_medio") > 0)
            & pl.col("produto").is_not_null()
            & (pl.col("uf").str.len_chars() == 2)
            & pl.col("ano").is_not_null()
            & pl.col("mes").is_not_null()
            & pl.col("mes").is_between(1, 12)
            & ~pl.col("produto").str.to_lowercase().str.contains("produto")
        )

        # ── Separa B2C de B2B ──────────────────────────────────────
        df_b2c = df.filter(pl.col("categoria_b2c") == "ALIMENTO_VAREJO")
        df_b2b = df.filter(pl.col("categoria_b2c") != "ALIMENTO_VAREJO")

        if df_b2c.height == 0:
            logger.info(
                "  %s: 0 B2C, %d B2B (ignorado)",
                caminho.name,
                df_b2b.height,
            )
            return None, categorias

        cols_out = [
            "produto",
            "municipio_id",
            "municipio_nome",
            "uf",
            "ano",
            "mes",
            "preco_medio",
            "categoria_b2c",
        ]
        for c in cols_out:
            if c not in df_b2c.columns:
                df_b2c = df_b2c.with_columns(pl.lit(None, dtype=pl.Utf8).alias(c))
        df_out = df_b2c.select(cols_out)

        logger.info(
            "  %s: %d B2C + %d B2B",
            caminho.name,
            df_out.height,
            df_b2b.height,
        )
        return df_out, categorias

    def executar(self) -> ResultadoCarga:
        """Executa o pipeline completo de ingestão inteligente.

        Returns:
            ``ResultadoCarga`` com estatísticas da execução.
        """
        inicio = time.perf_counter()
        logger.info("=" * 60)
        logger.info("INGESTÃO INTELIGENTE CONAB - INICIANDO")
        logger.info("=" * 60)

        arquivos = self._descobrir_arquivos()
        if not arquivos:
            return ResultadoCarga(arquivo="(nenhum)")

        todos_b2c: list[pl.DataFrame] = []
        todas_categorias: dict[str, str] = {}
        total_b2b = 0
        total_lidas = 0

        for f in arquivos:
            df_b2c, cats = self._processar_arquivo(f)
            todas_categorias.update(cats)
            total_lidas += df_b2c.height if df_b2c is not None else 0
            if df_b2c is not None:
                todos_b2c.append(df_b2c)

        if not todos_b2c:
            logger.warning("Nenhum dado B2C encontrado em %d arquivos", len(arquivos))
            return ResultadoCarga(arquivo="(sem B2C)")

        # Concatena todos os B2C em um único DataFrame
        df_final = pl.concat(todos_b2c)

        logger.info(
            "Total: %d B2C, %d B2B (excluídos do app)",
            df_final.height,
            total_b2b,
        )

        # Carrega no medalhão
        inseridas = self._carregador.carregar(df_final, todas_categorias)

        resultado = ResultadoCarga(
            arquivo=f"{len(arquivos)} arquivo(s)",
            linhas_lidas=total_lidas,
            linhas_b2c=df_final.height,
            linhas_b2b=total_b2b,
            linhas_inseridas=inseridas,
            duracao_seg=time.perf_counter() - inicio,
            categorias_encontradas=set(todas_categorias.values()),
        )

        logger.info("=" * 60)
        logger.info("RELATÓRIO FINAL")
        logger.info("  Arquivos processados: %d", len(arquivos))
        logger.info("  Linhas B2C carregadas: %d", resultado.linhas_b2c)
        logger.info("  Linhas B2B ignradas: %d", resultado.linhas_b2b)
        logger.info("  Linhas inseridas na fato: %d", resultado.linhas_inseridas)
        logger.info("  Categorias encontradas: %s", resultado.categorias_encontradas)
        logger.info("  Duração total: %.1f seg", resultado.duracao_seg)
        logger.info("=" * 60)

        return resultado


# ══════════════════════════════════════════════════════════════════════
# ENTRY POINT
# ══════════════════════════════════════════════════════════════════════


def main() -> NoReturn:
    """Entry point.

    Uso:
        python -m pipeline.ingestao_conab_inteligente
    """
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s | %(levelname)-8s | %(name)s | %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
        stream=sys.stdout,
    )
    try:
        ingestao = IngestaoInteligente()
        ingestao.executar()
        sys.exit(0)
    except Exception:
        logger.exception("Pipeline abortado — falha crítica")
        sys.exit(1)


if __name__ == "__main__":
    import sys

    main()
