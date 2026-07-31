"""
Ghost DBA Agent — Observabilidade + Auto-Reparo para o Quero Comprar PostgreSQL.

Subsistemas:
    1. LLMUrlRouter — Resgate de URLs CONAB quando o endpoint muda (404/403)
    2. SelfHealDB — Reparo automático de DDL quebrado (VIEW / FUNCTION / TRIGGER)
    3. AsyncIOSelfHealer — Loop principal assíncrono com webhook de notificação

Uso:
    python -m pipeline.ghost_dba_agent              # daemon (polling a cada 300s)
    python -m pipeline.ghost_dba_agent --once       # ciclo único (para cron)
    python -m pipeline.ghost_dba_agent --db-url "postgresql://..."

Dependências adicionais (pip install):
    asyncpg  httpx  beautifulsoup4  python-dotenv
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import re
import signal
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, NoReturn, Protocol, runtime_checkable

try:
    import asyncpg
except ImportError:
    msg = "asyncpg não instalado. Rode: pip install asyncpg"
    raise ImportError(msg)

import httpx
from bs4 import BeautifulSoup
from dotenv import load_dotenv, set_key

from database.utils.snapshot_helper import verificar_staleness

load_dotenv()

# ──────────────────────────────────────────────────────────────────────
# Logging estruturado (JSON)
# ──────────────────────────────────────────────────────────────────────


class JSONFormatter(logging.Formatter):
    """Formata logs como JSON para consumo via sistema de observabilidade."""

    def format(self, record: logging.LogRecord) -> str:
        entry: dict[str, Any] = {
            "ts": self.formatTime(record, "%Y-%m-%dT%H:%M:%S"),
            "lvl": record.levelname,
            "logger": record.name,
            "msg": record.getMessage(),
        }
        if record.exc_info and record.exc_info[0]:
            entry["exception"] = self.formatException(record.exc_info)
        return json.dumps(entry, ensure_ascii=False)


logger = logging.getLogger("ghost_dba")


# ──────────────────────────────────────────────────────────────────────
# Config — lê de ops.config_agente com fallback para env vars e padrões
# ──────────────────────────────────────────────────────────────────────


@dataclass
class AgentConfig:
    polling_interval_seg: int = 300
    max_tentativas: int = 3
    llm_api_url: str = "http://localhost:11434/v1"
    llm_api_key: str = ""
    llm_model: str = "llama3"
    webhook_url: str = ""
    webhook_tipo: str = ""
    db_url: str = ""

    @classmethod
    def from_db_row(cls, row: dict[str, Any] | None) -> AgentConfig:
        cfg = cls()
        if row is None:
            return cfg._apply_env()
        for k, v in row.items():
            if hasattr(cfg, k):
                setattr(cfg, k, v)
        return cfg._apply_env()

    def _apply_env(self) -> AgentConfig:
        overrides: dict[str, str] = {
            "polling_interval_seg": os.environ.get("GHOST_DBA_POLL_INTERVAL", ""),
            "max_tentativas": os.environ.get("GHOST_DBA_MAX_TENTATIVAS", ""),
            "llm_api_url": os.environ.get("GHOST_DBA_LLM_URL", ""),
            "llm_api_key": os.environ.get("GHOST_DBA_LLM_KEY", ""),
            "llm_model": os.environ.get("GHOST_DBA_LLM_MODEL", ""),
            "webhook_url": os.environ.get("GHOST_DBA_WEBHOOK_URL", ""),
            "webhook_tipo": os.environ.get("GHOST_DBA_WEBHOOK_TIPO", ""),
            "db_url": os.environ.get("DATABASE_URL", ""),
        }
        for attr, val in overrides.items():
            if not val:
                continue
            current = getattr(self, attr)
            if isinstance(current, int):
                try:
                    setattr(self, attr, int(val))
                except ValueError:
                    logger.warning("Valor inválido para %s: %s", attr, val)
            else:
                setattr(self, attr, val)
        return self


async def carregar_config(pool: asyncpg.Pool) -> AgentConfig:
    """Carrega config da tabela ops.config_agente com fallback para env vars."""
    try:
        async with pool.acquire() as conn:
            row = await conn.fetchrow("SELECT chave, valor FROM ops.config_agente")
            if row:
                raw: dict[str, Any] = (
                    json.loads(row["valor"]) if isinstance(row["valor"], str) else {}
                )
                return AgentConfig.from_db_row(raw)
    except Exception:
        logger.warning("Falha ao ler ops.config_agente, usando env/defaults")
    return AgentConfig.from_db_row(None)


# ──────────────────────────────────────────────────────────────────────
# Interface abstrata para cliente LLM (swapável: OpenAI, Ollama, etc.)
# ──────────────────────────────────────────────────────────────────────


@runtime_checkable
class LLMClient(Protocol):
    async def ask(
        self,
        system_prompt: str,
        user_prompt: str,
        temperature: float = 0.1,
    ) -> str: ...


@dataclass
class OpenAICompatibleClient:
    """Cliente LLM compatível com OpenAI Chat Completion API.

    Funciona com OpenAI, Ollama (localhost:11434/v1), OpenCode API, etc.
    """

    api_url: str
    api_key: str
    model: str = "gpt-4o-mini"
    _client: httpx.AsyncClient = field(
        default_factory=lambda: httpx.AsyncClient(timeout=httpx.Timeout(90.0))
    )

    async def ask(
        self,
        system_prompt: str,
        user_prompt: str,
        temperature: float = 0.1,
    ) -> str:
        body: dict[str, Any] = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_prompt},
            ],
            "temperature": temperature,
        }
        headers: dict[str, str] = {}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
        resp = await self._client.post(
            f"{self.api_url.rstrip('/')}/chat/completions",
            json=body,
            headers=headers,
        )
        resp.raise_for_status()
        data = resp.json()
        return data["choices"][0]["message"]["content"]

    async def close(self) -> None:
        await self._client.aclose()


# ──────────────────────────────────────────────────────────────────────
# 1. LLMUrlRouter — Resgate de URLs CONAB
# ──────────────────────────────────────────────────────────────────────


def _limpar_html(html: str) -> str:
    """Remove <style>/<script>, extrai texto + links âncora para minimizar tokens."""
    soup = BeautifulSoup(html, "html.parser")
    for tag in soup(["style", "script"]):
        tag.decompose()
    linhas: list[str] = []
    for a in soup.find_all("a"):
        href = a.get("href", "")
        texto = a.get_text(strip=True)
        if texto or href:
            linhas.append(f"{texto} -> {href}" if href else texto)
    for texto in soup.find_all(string=True):
        if texto.parent.name != "a":
            t = texto.strip()
            if t:
                linhas.append(t)
    return "\n".join(linhas)


CONAB_ROOT = "https://portaldeinformacoes.conab.gov.br/downloads/arquivos/"
CONAB_URLS: dict[str, str] = {
    "uf": "https://portaldeinformacoes.conab.gov.br/downloads/arquivos/PrecosMensalUF.txt",
    "prohort": "https://portaldeinformacoes.conab.gov.br/downloads/arquivos/ProhortMensal.txt",
}


class LLMUrlRouter:
    """Resgata URLs CONAB quando o endpoint muda (HTTP 404/403)."""

    def __init__(self, llm: LLMClient) -> None:
        self._llm = llm
        self._urls: dict[str, str] = dict(CONAB_URLS)

    async def verificar_e_resgatar(self, chave: str, url: str) -> str:
        """Verifica URL. Se 200 → retorna. Se 404/403 → chama LLM para resgatar.

        Returns:
            URL válida (original ou resgatada).
        """
        async with httpx.AsyncClient(timeout=httpx.Timeout(30.0), follow_redirects=True) as client:
            try:
                resp = await client.get(url)
                if resp.status_code == 200:
                    return url
                if resp.status_code not in (403, 404):
                    resp.raise_for_status()
            except httpx.HTTPStatusError as exc:
                if exc.response.status_code not in (403, 404):
                    raise
            except Exception:
                logger.exception("Falha ao verificar URL: %s", url)
                return url

        logger.warning("URL quebrada (%s): %s — iniciando resgate via LLM", chave, url)
        nova = await self._resgatar_url(chave)
        if nova:
            self._urls[chave] = nova
            return nova
        return url

    async def _resgatar_url(self, chave: str) -> str | None:
        """Busca root page, limpa HTML, envia ao LLM, parseia JSON de resposta."""
        async with httpx.AsyncClient(timeout=httpx.Timeout(30.0)) as client:
            try:
                resp = await client.get(CONAB_ROOT)
                resp.raise_for_status()
            except Exception:
                logger.exception("Falha ao buscar página raiz CONAB: %s", CONAB_ROOT)
                return None

        html_limpo = _limpar_html(resp.text)
        logger.info("HTML limpo: %d caracteres para LLM", len(html_limpo))

        system = "Você é um assistente que analisa HTML de portal de dados e retorna JSON com URLs de arquivos. Responda APENAS com o JSON, sem explicações."
        prompt = (
            f"O link antigo para '{chave}' quebrou.\n\n"
            "Analise este HTML e retorne APENAS o novo link direto no formato JSON "
            '{"new_url_uf": "...", "new_url_municipio": "..."}\n\n'
            f"HTML:\n{html_limpo}"
        )

        try:
            resposta = await self._llm.ask(system, prompt, temperature=0.0)
            logger.info("Resposta LLM resgate URL: %s", resposta[:300])
        except Exception:
            logger.exception("Falha na chamada LLM para resgate de URL")
            return None

        match = re.search(
            r'\{"new_url_u[fm]":\s*"[^"]+",?\s*"new_url_m[uo][a-z]+":\s*"[^"]+"\}', resposta
        )
        if not match:
            logger.error("Resposta LLM não contém JSON válido: %s", resposta[:500])
            return None

        try:
            dados: dict[str, str] = json.loads(match.group())
        except json.JSONDecodeError as exc:
            logger.error("JSON inválido na resposta LLM: %s", exc)
            return None

        for k, v in dados.items():
            if v and v.startswith("http"):
                chave_dest = "uf" if "uf" in k else "municipio"
                self._urls[chave_dest] = v
                logger.info("URL atualizada: %s -> %s", chave_dest, v)

        # Persistir no .env
        env_path = _descobrir_env_path()
        if env_path:
            try:
                for k, v in dados.items():
                    env_key = f"CONAB_URL_{k.upper()}"
                    set_key(str(env_path), env_key, v)
                logger.info("URLs salvas em %s", env_path)
            except Exception:
                logger.exception("Falha ao escrever .env")

        return dados.get(f"new_url_{chave}")

    def obter_urls(self) -> dict[str, str]:
        return dict(self._urls)


def _descobrir_env_path() -> Path | None:
    """Tenta localizar o arquivo .env no projeto."""
    for cand in [Path(".env"), Path("../.env"), Path(__file__).parent.parent / ".env"]:
        if cand.exists():
            return cand
    return None


# ──────────────────────────────────────────────────────────────────────
# 2. Filtro de Segurança — Regex rigoroso para SQL
# ──────────────────────────────────────────────────────────────────────

TIPO_OBJETO_CREATE: dict[str, str] = {
    "VIEW": "CREATE OR REPLACE VIEW",
    "FUNCTION": "CREATE OR REPLACE FUNCTION",
    "TRIGGER": "CREATE OR REPLACE TRIGGER",
}

SQL_BLOCK_RE = re.compile(r"```(?:sql)?\s*\n(.*?)```", re.DOTALL | re.IGNORECASE)

BLACKLIST_KEYWORDS: list[re.Pattern[str]] = [
    re.compile(r"\bDROP\s+TABLE\b", re.IGNORECASE),
    re.compile(r"\bDELETE\s+FROM\b", re.IGNORECASE),
    re.compile(r"\bTRUNCATE\b", re.IGNORECASE),
    re.compile(r"\bALTER\s+ROLE\b", re.IGNORECASE),
    re.compile(r"\bGRANT\b", re.IGNORECASE),
    re.compile(r"\bALTER\s+TABLE\b", re.IGNORECASE),
    re.compile(r"\bDROP\s+VIEW\b", re.IGNORECASE),
    re.compile(r"\bDROP\s+FUNCTION\b", re.IGNORECASE),
    re.compile(r"\bDROP\s+TRIGGER\b", re.IGNORECASE),
    re.compile(r"\bINSERT\s+INTO\b", re.IGNORECASE),
    re.compile(r"\bUPDATE\b", re.IGNORECASE),
]


@dataclass
class FiltroResultado:
    aprovado: bool
    sql: str | None
    tipo: str | None
    nome_objeto: str | None
    motivo: str | None


def _extrair_nome_objeto(sql: str, tipo: str) -> str | None:
    """Extrai esquema.nome do CREATE OR REPLACE."""
    prefixo = TIPO_OBJETO_CREATE.get(tipo, "")
    if not prefixo:
        return None
    pattern = re.escape(prefixo) + r"\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+(?:\.\w+)?)"
    match = re.search(pattern, sql, re.IGNORECASE)
    if match:
        return match.group(1)
    return None


def filtrar_sql_llm(resposta_llm: str, tipo_esperado: str | None = None) -> FiltroResultado:
    """Aplica pipeline de segurança na resposta da LLM.

    1. Extrai blocos entre ```sql ... ```
    2. Verifica prefixo CREATE OR REPLACE VIEW / FUNCTION / TRIGGER
    3. Varre blacklist de keywords perigosas
    4. Retorna resultado com SQL aprovado ou motivo de bloqueio
    """
    blocos = SQL_BLOCK_RE.findall(resposta_llm)
    if not blocos:
        blocos = [
            linha
            for linha in resposta_llm.split("\n")
            if any(linha.strip().upper().startswith(p.upper()) for p in TIPO_OBJETO_CREATE.values())
        ]
    if not blocos:
        for linha in resposta_llm.split("\n"):
            bloco = linha.strip()
            if re.search(r"CREATE\s+OR\s+REPLACE\s+(VIEW|FUNCTION|TRIGGER)", bloco, re.IGNORECASE):
                blocos.append(bloco)
    if not blocos:
        return FiltroResultado(
            aprovado=False,
            sql=None,
            tipo=None,
            nome_objeto=None,
            motivo="Nenhum bloco SQL encontrado na resposta",
        )

    bloco = blocos[0].strip()

    tipo_detectado: str | None = None
    for tipo, prefixo in TIPO_OBJETO_CREATE.items():
        if bloco.upper().startswith(prefixo.upper()):
            tipo_detectado = tipo
            break
    if tipo_detectado is None:
        return FiltroResultado(
            aprovado=False,
            sql=None,
            tipo=None,
            nome_objeto=None,
            motivo="Bloco SQL não começa com CREATE OR REPLACE VIEW/FUNCTION/TRIGGER",
        )

    if tipo_esperado and tipo_detectado != tipo_esperado:
        return FiltroResultado(
            aprovado=False,
            sql=None,
            tipo=tipo_detectado,
            nome_objeto=None,
            motivo=f"Tipo esperado {tipo_esperado}, recebido {tipo_detectado}",
        )

    nome = _extrair_nome_objeto(bloco, tipo_detectado)

    for pat in BLACKLIST_KEYWORDS:
        if pat.search(bloco):
            motivo = f"Keyword bloqueada encontrada: {pat.pattern}"
            return FiltroResultado(
                aprovado=False, sql=bloco, tipo=tipo_detectado, nome_objeto=nome, motivo=motivo
            )

    return FiltroResultado(
        aprovado=True, sql=bloco, tipo=tipo_detectado, nome_objeto=nome, motivo=None
    )


# ──────────────────────────────────────────────────────────────────────
# 3. SelfHealDB — Sandbox + Execução do reparo
# ──────────────────────────────────────────────────────────────────────


@dataclass
class ErroDDL:
    id: int
    data_erro: Any
    esquema: str
    objeto: str
    tipo_objeto: str
    mensagem_erro: str
    contexto_extra: dict[str, Any] | None
    tentativas_ia: int
    max_tentativas: int


async def _buscar_ddl_atual(conn: asyncpg.Connection, esquema: str, objeto: str, tipo: str) -> str:
    """Obtém a DDL atual do objeto via information_schema / pg_class."""
    partes: list[str] = []
    try:
        if tipo == "VIEW":
            row = await conn.fetchrow(
                "SELECT pg_catalog.pg_get_viewdef(c.oid) AS view_definition "
                "FROM pg_catalog.pg_class c "
                "JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace "
                "WHERE n.nspname = $1 AND c.relname = $2 AND c.relkind = 'v'",
                esquema,
                objeto,
            )
            if row:
                cols = await conn.fetch(
                    "SELECT column_name, data_type, is_nullable "
                    "FROM information_schema.columns "
                    "WHERE table_schema = $1 AND table_name = $2 "
                    "ORDER BY ordinal_position",
                    esquema,
                    objeto,
                )
                col_defs = [f"  {c['column_name']} {c['data_type']}" for c in cols]
                partes.append(f"-- Colunas atuais de {esquema}.{objeto}:")
                partes.extend(col_defs)
                partes.append(f"-- Definição atual:\n{row['view_definition']}")

        elif tipo == "FUNCTION":
            row = await conn.fetchrow(
                "SELECT pg_catalog.pg_get_functiondef(p.oid) AS func_def "
                "FROM pg_catalog.pg_proc p "
                "JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace "
                "WHERE n.nspname = $1 AND p.proname = $2",
                esquema,
                objeto,
            )
            if row:
                partes.append(f"-- DDL atual de {esquema}.{objeto}:\n{row['func_def']}")

        elif tipo == "TRIGGER":
            row = await conn.fetchrow(
                "SELECT pg_catalog.pg_get_triggerdef(t.oid) AS trig_def "
                "FROM pg_catalog.pg_trigger t "
                "JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid "
                "JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace "
                "WHERE n.nspname = $1 AND c.relname = $2",
                esquema,
                objeto,
            )
            if row:
                partes.append(f"-- Trigger atual em {esquema}.{objeto}:\n{row['trig_def']}")

    except Exception as exc:
        logger.warning("Falha ao buscar DDL de %s.%s: %s", esquema, objeto, exc)
        partes.append(f"-- Não foi possível obter DDL atual: {exc}")

    return "\n".join(partes) if partes else "-- Nenhuma DDL encontrada"


async def _testar_sandbox(
    conn: asyncpg.Connection,
    sql: str,
    tipo: str,
    nome_objeto: str,
) -> tuple[bool, str]:
    """Executa SQL em transação com teste de validação.

    VIEW:      CREATE OR REPLACE → SELECT * FROM obj LIMIT 1
    FUNCTION:  CREATE OR REPLACE → SELECT obj() (tentativa, falha tolerada)
    TRIGGER:   CREATE OR REPLACE → apenas validação sintática
    """
    try:
        await conn.execute("BEGIN")
        status = await conn.execute(sql)
        logger.info("Sandbox CREATE executado: %s", status)

        if tipo == "VIEW":
            await conn.fetch(f"SELECT * FROM {nome_objeto} LIMIT 1")
            logger.info("Sandbox SELECT VIEW OK: %s", nome_objeto)

        elif tipo == "FUNCTION":
            try:
                await conn.fetch(f"SELECT {nome_objeto}() LIMIT 1")
                logger.info("Sandbox SELECT FUNCTION OK: %s", nome_objeto)
            except asyncpg.PostgresError:
                logger.info(
                    "Sandbox FUNCTION sem argumentos falhou (esperado), CREATE é válido: %s",
                    nome_objeto,
                )

        await conn.execute("COMMIT")
        return True, ""

    except asyncpg.PostgresError as exc:
        await conn.execute("ROLLBACK")
        return False, str(exc)
    except Exception as exc:
        try:
            await conn.execute("ROLLBACK")
        except Exception:
            pass
        return False, str(exc)


async def _registrar_auditoria(
    conn: asyncpg.Connection,
    erro_id: int,
    esquema: str,
    objeto: str,
    status: str,
    sql_gerado: str | None,
    resposta_llm: str | None,
    motivo_bloqueio: str | None = None,
    mensagem_erro: str | None = None,
) -> None:
    """Registra no log de auditoria ops.audit_llm_queries."""
    try:
        await conn.execute(
            """
            INSERT INTO ops.audit_llm_queries
                (erro_id, esquema, objeto, status, sql_gerado, resposta_llm,
                 motivo_bloqueio, mensagem_erro, data_criacao)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, NOW())
            """,
            erro_id,
            esquema,
            objeto,
            status,
            sql_gerado,
            resposta_llm,
            motivo_bloqueio,
            mensagem_erro,
        )
    except Exception as exc:
        logger.error("Falha ao registrar auditoria para erro %d: %s", erro_id, exc)


async def _chamar_llm_reparo(llm: LLMClient, erro: ErroDDL, ddl_atual: str) -> str:
    """Monta prompt com contexto do erro e chama LLM para gerar SQL de reparo."""
    contexto = erro.contexto_extra or {}
    novas_colunas = json.dumps(contexto, ensure_ascii=False, indent=2) if contexto else "N/A"

    system = (
        "Você é um DBA especializado em PostgreSQL. Gere APENAS comandos "
        "CREATE OR REPLACE VIEW / FUNCTION / TRIGGER para corrigir o erro abaixo. "
        "NÃO inclua DROP TABLE, DELETE, TRUNCATE, ALTER ROLE, GRANT, ALTER TABLE, "
        "DROP VIEW, DROP FUNCTION, DROP TRIGGER, INSERT INTO ou UPDATE. "
        "Responda APENAS com o bloco SQL entre ```sql e ```. "
        "Nunca inclua explicações fora do bloco de código."
    )
    user = (
        f"Erro no objeto {erro.esquema}.{erro.objeto} (tipo: {erro.tipo_objeto}):\n\n"
        f"Mensagem de erro:\n{erro.mensagem_erro}\n\n"
        f"DDL atual:\n{ddl_atual}\n\n"
        f"Contexto extra (novas colunas, mudanças):\n{novas_colunas}\n\n"
        "Gere o comando CREATE OR REPLACE para corrigir o problema."
    )
    return await llm.ask(system, user, temperature=0.1)


async def _processar_erro(
    conn: asyncpg.Connection,
    pool: asyncpg.Pool,
    erro: ErroDDL,
    llm: LLMClient,
    webhook: WebhookDispatcher,
    config: AgentConfig,
) -> None:
    """Processa um único erro DDL: contexto → LLM → filtro → sandbox → auditoria."""
    logger.info(
        "Processando erro %d: %s.%s (%s)", erro.id, erro.esquema, erro.objeto, erro.tipo_objeto
    )

    ddl_atual = await _buscar_ddl_atual(conn, erro.esquema, erro.objeto, erro.tipo_objeto)
    logger.info("DDL atual obtida para %s.%s (%d chars)", erro.esquema, erro.objeto, len(ddl_atual))

    resposta_llm: str | None = None
    sql_gerado: str | None = None
    status: str = "falha"
    motivo_bloqueio: str | None = None
    mensagem_erro_sandbox: str | None = None

    try:
        resposta_llm = await _chamar_llm_reparo(llm, erro, ddl_atual)
    except Exception as exc:
        mensagem_erro_sandbox = f"Falha na chamada LLM: {exc}"
        logger.exception("LLM falhou para erro %d", erro.id)
        await _registrar_auditoria(
            conn,
            erro.id,
            erro.esquema,
            erro.objeto,
            status,
            None,
            None,
            motivo_bloqueio=mensagem_erro_sandbox,
        )
        await _notificar_erro_reparo(webhook, erro, f"Falha LLM: {exc}", config)
        return

    filtro = filtrar_sql_llm(resposta_llm, tipo_esperado=erro.tipo_objeto)

    if not filtro.aprovado:
        status = "bloqueado"
        sql_gerado = filtro.sql
        motivo_bloqueio = filtro.motivo
        logger.warning("SQL bloqueado para erro %d: %s", erro.id, motivo_bloqueio)
        await _registrar_auditoria(
            conn,
            erro.id,
            erro.esquema,
            erro.objeto,
            status,
            sql_gerado,
            resposta_llm,
            motivo_bloqueio=motivo_bloqueio,
        )
        await _notificar_erro_reparo(webhook, erro, f"SQL bloqueado: {motivo_bloqueio}", config)
        return

    sql_gerado = filtro.sql
    assert filtro.nome_objeto is not None

    sucesso, mensagem_erro_sandbox = await _testar_sandbox(
        conn,
        sql_gerado,
        erro.tipo_objeto,
        filtro.nome_objeto,
    )

    if sucesso:
        status = "sucesso"
        logger.info("REPARO SUCESSO: erro %d - %s.%s", erro.id, erro.esquema, erro.objeto)

        try:
            await conn.execute(
                "SELECT ops.fn_resolver_erro($1, $2, $3, $4)",
                erro.id,
                status,
                sql_gerado,
                resposta_llm,
            )
        except Exception as exc:
            logger.error("Falha ao chamar fn_resolver_erro para %d: %s", erro.id, exc)

        await _registrar_auditoria(
            conn, erro.id, erro.esquema, erro.objeto, status, sql_gerado, resposta_llm
        )
        await _notificar_sucesso(webhook, erro)

    else:
        status = "falha"
        logger.warning("Sandbox falhou para erro %d: %s", erro.id, mensagem_erro_sandbox)
        novas_tentativas = erro.tentativas_ia + 1

        if novas_tentativas >= erro.max_tentativas:
            status = "falha_permanente"
            logger.error(
                "Erro %d esgotou tentativas (%d/%d)", erro.id, novas_tentativas, erro.max_tentativas
            )

        await _registrar_auditoria(
            conn,
            erro.id,
            erro.esquema,
            erro.objeto,
            status,
            sql_gerado,
            resposta_llm,
            mensagem_erro=mensagem_erro_sandbox,
        )

        try:
            await conn.execute(
                "SELECT ops.fn_resolver_erro($1, $2, $3, $4)",
                erro.id,
                status,
                sql_gerado,
                resposta_llm,
            )
        except Exception as exc:
            logger.error("Falha ao chamar fn_resolver_erro para %d: %s", erro.id, exc)

        if status == "falha_permanente":
            await _notificar_falha_permanente(webhook, erro, config)


# ──────────────────────────────────────────────────────────────────────
# 4. Webhook Dispatcher — Notificações assíncronas (Discord / Telegram)
# ──────────────────────────────────────────────────────────────────────


class WebhookDispatcher:
    """Dispatcher de webhooks para Discord e Telegram.

    Usa httpx.AsyncClient para disparo não-bloqueante.
    """

    def __init__(self, webhook_url: str = "", webhook_tipo: str = "") -> None:
        self._url = webhook_url
        self._tipo = webhook_tipo.lower() if webhook_tipo else self._detectar_tipo(webhook_url)
        self._client = httpx.AsyncClient(timeout=httpx.Timeout(10.0))

    @staticmethod
    def _detectar_tipo(url: str) -> str:
        if "discord.com/api/webhooks" in url:
            return "discord"
        if "api.telegram.org/bot" in url:
            return "telegram"
        return "generic"

    async def enviar(self, mensagem: str, cor: str = "green") -> None:
        if not self._url:
            logger.debug("Webhook não configurado, mensagem ignorada: %s", mensagem[:80])
            return
        try:
            if self._tipo == "discord":
                payload: dict[str, Any] = {"content": mensagem}
                if cor == "red":
                    payload["embeds"] = [{"color": 0xFF0000, "description": mensagem}]
                elif cor == "green":
                    payload["embeds"] = [{"color": 0x00FF00, "description": mensagem}]
                resp = await self._client.post(self._url, json=payload)
                resp.raise_for_status()

            elif self._tipo == "telegram":
                resp = await self._client.post(self._url, json={"text": mensagem})
                resp.raise_for_status()

            else:
                resp = await self._client.post(self._url, json={"text": mensagem})
                resp.raise_for_status()

            logger.info("Webhook %s enviado com sucesso (%s)", self._tipo, cor)

        except Exception:
            logger.exception("Falha ao enviar webhook %s", self._tipo)

    async def fechar(self) -> None:
        await self._client.aclose()


def _formatar_motivo(erro: ErroDDL) -> str:
    """Formata motivo legível para webhook."""
    return f"{erro.esquema}.{erro.objeto} — {erro.mensagem_erro[:100]}"


async def _notificar_sucesso(webhook: WebhookDispatcher, erro: ErroDDL) -> None:
    msg = f"🟢 [Self-Healing] View {erro.esquema}.{erro.objeto} reparada. Motivo: {_formatar_motivo(erro)}. Commit realizado."
    logger.info(msg)
    await webhook.enviar(msg, cor="green")


async def _notificar_falha_permanente(
    webhook: WebhookDispatcher, erro: ErroDDL, config: AgentConfig
) -> None:
    msg = f"🔴 [Self-Healing] Falha ao reparar {erro.esquema}.{erro.objeto} após {erro.max_tentativas} tentativas. Intervenção humana necessária."
    logger.error(msg)
    await webhook.enviar(msg, cor="red")


async def _notificar_erro_reparo(
    webhook: WebhookDispatcher, erro: ErroDDL, motivo: str, config: AgentConfig
) -> None:
    msg = f"🟡 [Self-Healing] Erro ao processar {erro.esquema}.{erro.objeto}: {motivo}"
    logger.warning(msg)
    await webhook.enviar(msg, cor="red")


# ──────────────────────────────────────────────────────────────────────
# 5. AsyncIOSelfHealer — Loop principal do daemon
# ──────────────────────────────────────────────────────────────────────


class AsyncIOSelfHealer:
    """Daemon assíncrono de auto-reparo.

    Faz polling de ops.controle_erros_ddl, processa cada erro não resolvido
    e dispara webhooks de notificação.

    Modos:
        - Daemon contínuo (padrão)
        - Ciclo único (--once para cron)
    """

    def __init__(self, config: AgentConfig) -> None:
        self.config = config
        self.shutdown_event = asyncio.Event()
        self._pool: asyncpg.Pool | None = None
        self._llm: OpenAICompatibleClient | None = None
        self._webhook: WebhookDispatcher = WebhookDispatcher(
            config.webhook_url, config.webhook_tipo
        )
        self._url_router: LLMUrlRouter | None = None

    async def _init_pool(self) -> asyncpg.Pool:
        if self._pool is None:
            self._pool = await asyncpg.create_pool(
                self.config.db_url,
                min_size=1,
                max_size=4,
                command_timeout=30,
            )
        return self._pool

    async def _init_llm(self) -> OpenAICompatibleClient:
        if self._llm is None:
            self._llm = OpenAICompatibleClient(
                api_url=self.config.llm_api_url,
                api_key=self.config.llm_api_key,
                model=self.config.llm_model,
            )
        return self._llm

    def _init_url_router(self) -> LLMUrlRouter:
        if self._url_router is None:
            self._url_router = LLMUrlRouter(self._llm)  # type: ignore[arg-type]
        return self._url_router

    def handle_signal(self) -> None:
        """Callback para SIGINT/SIGTERM — sinaliza shutdown."""
        logger.info("Sinal de parada recebido, encerrando...")
        self.shutdown_event.set()

    async def poll_errors(self) -> int:
        """Poll errors from ops.controle_erros_ddl and process them.

        Returns:
            Número de erros processados neste ciclo.
        """
        pool = await self._init_pool()
        llm = await self._init_llm()
        erros: list[ErroDDL] = []

        async with pool.acquire() as conn:
            try:
                rows = await conn.fetch(
                    "SELECT id, data_erro, esquema, objeto, tipo_objeto, "
                    "       mensagem_erro, contexto_extra, tentativas_ia, max_tentativas "
                    "FROM ops.controle_erros_ddl "
                    "WHERE NOT resolvido_por_ia "
                    "ORDER BY data_erro "
                    "LIMIT 5"
                )
            except Exception as exc:
                logger.exception("Falha ao consultar ops.controle_erros_ddl: %s", exc)
                return 0

            for row in rows:
                erros.append(
                    ErroDDL(
                        id=row["id"],
                        data_erro=row["data_erro"],
                        esquema=row["esquema"],
                        objeto=row["objeto"],
                        tipo_objeto=row["tipo_objeto"],
                        mensagem_erro=row["mensagem_erro"],
                        contexto_extra=json.loads(row["contexto_extra"])
                        if isinstance(row["contexto_extra"], str)
                        else row["contexto_extra"],
                        tentativas_ia=row["tentativas_ia"],
                        max_tentativas=row["max_tentativas"],
                    )
                )

        try:
            stale = verificar_staleness()
            if stale:
                logger.warning("[GHOST] Fontes stale detectadas: %s", stale)
        except (json.JSONDecodeError, OSError, KeyError):
            logger.debug("verificar_staleness nao disponivel (sem checkpoint ainda)")

        if not erros:
            logger.debug("Nenhum erro pendente encontrado")
            return 0

        logger.info("Processando %d erro(s) pendente(s)", len(erros))

        for erro in erros:
            async with pool.acquire() as conn:
                await _processar_erro(conn, pool, erro, llm, self._webhook, self.config)

        return len(erros)

    async def run_once(self) -> None:
        """Executa um único ciclo de polling e processamento."""
        logger.info("Modo --once: executando ciclo único")
        try:
            await self.poll_errors()
        except Exception:
            logger.exception("Erro fatal no ciclo único")
            raise
        finally:
            await self._cleanup()

    async def run_daemon(self) -> None:
        """Loop principal do daemon com graceful shutdown."""
        loop = asyncio.get_event_loop()
        for sig in (signal.SIGINT, signal.SIGTERM):
            try:
                loop.add_signal_handler(sig, self.handle_signal)
            except NotImplementedError:
                logger.warning("Signal handler não suportado nesta plataforma")
                break

        logger.info(
            "Ghost DBA Agent iniciado (polling a cada %ds)",
            self.config.polling_interval_seg,
        )

        while not self.shutdown_event.is_set():
            try:
                qtd = await self.poll_errors()
                if qtd:
                    logger.info("Ciclo concluído: %d erro(s) processados", qtd)
            except Exception:
                logger.exception("Erro no ciclo de polling")

            try:
                await asyncio.wait_for(
                    self.shutdown_event.wait(),
                    timeout=self.config.polling_interval_seg,
                )
            except asyncio.TimeoutError:
                continue

        logger.info("Daemon encerrado graciosamente")
        await self._cleanup()

    async def _cleanup(self) -> None:
        """Libera recursos: pool, cliente LLM, webhook."""
        if self._llm:
            await self._llm.close()
        if self._pool:
            await self._pool.close()
        await self._webhook.fechar()
        logger.info("Recursos liberados")


# ──────────────────────────────────────────────────────────────────────
# 6. Main — Entry point com argparse
# ──────────────────────────────────────────────────────────────────────


def _configurar_logging() -> None:
    """Configura logging global com formato JSON."""
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JSONFormatter())
    root = logging.getLogger()
    root.setLevel(logging.INFO)
    root.handlers.clear()
    root.addHandler(handler)
    # Silenciar bibliotecas muito verbosas
    for lib in ("httpx", "asyncio", "bs4"):
        logging.getLogger(lib).setLevel(logging.WARNING)


async def _inicializar(args: argparse.Namespace) -> AsyncIOSelfHealer:
    """Inicializa config, pool e healer."""
    pool = await asyncpg.create_pool(
        args.db_url
        or os.environ.get(
            "DATABASE_URL", "postgresql://postgres:postgres@localhost:5432/quero_comprar"
        ),
        min_size=1,
        max_size=2,
        command_timeout=15,
    )
    try:
        config = await carregar_config(pool)
    finally:
        await pool.close()

    if args.db_url:
        config.db_url = args.db_url
    if not config.db_url:
        config.db_url = os.environ.get(
            "DATABASE_URL", "postgresql://postgres:postgres@localhost:5432/quero_comprar"
        )

    logger.info(
        "Config: poll=%ds max_tent=%d llm=%s model=%s",
        config.polling_interval_seg,
        config.max_tentativas,
        config.llm_api_url,
        config.llm_model,
    )

    return AsyncIOSelfHealer(config)


def main() -> NoReturn:
    """Entry point: configura logging, parseia args, inicia o agente."""
    _configurar_logging()

    parser = argparse.ArgumentParser(
        description="Ghost DBA Agent — Observabilidade e Auto-Reparo PostgreSQL",
    )
    parser.add_argument(
        "--once",
        action="store_true",
        help="Executa um único ciclo de polling e encerra (ideal para cron)",
    )
    parser.add_argument(
        "--db-url",
        type=str,
        default=None,
        help="String de conexão PostgreSQL (sobrescreve DATABASE_URL)",
    )
    args = parser.parse_args()

    try:
        healer = asyncio.run(_inicializar(args))

        if args.once:
            asyncio.run(healer.run_once())
        else:
            asyncio.run(healer.run_daemon())

        sys.exit(0)

    except Exception:
        logger.exception("Falha crítica no Ghost DBA Agent")
        sys.exit(1)


if __name__ == "__main__":
    main()
