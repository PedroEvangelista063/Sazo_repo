#!/usr/bin/env python3
"""
drain_logs.py — Sistema de Drenagem de Logs (Log Draining) com upload em nuvem.

Exporta o conteúdo de tabelas operacionais para CSV, faz UPLOAD imediato para
Object Storage S3-compatible (AWS S3 / Cloudflare R2 / MinIO / webhook) e,
SOMENTE após confirmar o upload, remove o arquivo temporário do disco e
executa TRUNCATE nas mesmas tabelas para liberar disco na nuvem (Aiven).

Tabelas drenadas por padrão (lixo operacional — nunca config/estado):
  - ops.audit_logs           (auditoria de mudança de status_cor — 300k+ linhas)
  - ops.quarentena_coleta    (payloads rejeitados pela esteira de triagem)
  - ops.audit_llm_queries    (log de queries do agente LLM)
  - ops.*_backup             (backups antigos de staging: *_expurgado_backup etc.)
  - sobrescreva/estenda com --tables

⚠️ PROTOCOLO DE ACIONAMENTO:
  - LOCAL (manual): somente comando explícito "Drenar Logs" — nada automático.
  - NUVEM: automação SOMENTE via Cron Job nativo do Render (render.yaml,
    schedule "0 2 * * *") — PROIBIDO cron no GitHub Actions ou background
    process travando o Uvicorn. O Render garante single-run; o advisory lock
    do PostgreSQL abaixo é a defesa extra contra concorrência manual+cron.

🔒 Lock anti-concorrência: pg_try_advisory_lock() na conexão — se outra
   instância estiver rodando, o script encerra com exit 3 sem tocar no banco.
   O lock é liberado automaticamente quando a conexão fecha (até em crash).

USO:
  python3 ops/drain_logs.py                       # exporta + upload + TRUNCATE
  python3 ops/drain_logs.py --dry-run             # exporta somente (ensaio)
  python3 ops/drain_logs.py --db-url "postgresql://..."   # override DSN
  python3 ops/drain_logs.py --tables ops.audit_logs,raw.controle_carga
  python3 ops/drain_logs.py --no-lock             # ignora advisory lock (teste)

DSN: env DATABASE_URL (override) > backend/.env (DATABASE_URL > PRIMARY > ETL).
Storage: ops/storage.py — OBJECT_STORAGE_BUCKET (+ S3_ENDPOINT_URL p/ R2/MinIO).
Dependências: psycopg2-binary, boto3, requests (ops/requirements.txt).
Saída: database/logs_locais/<schema>_<tabela>_<timestamp>.csv + manifest JSON.
Exit: 0 = OK; 1 = erro de conexão; 2 = falha parcial (sem TRUNCATE); 3 = lock ocupado.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import re
import sys
import time
from pathlib import Path

import psycopg2
import storage

_CONNECT_TIMEOUT_SECONDS = 30
_PROJ = Path(__file__).resolve().parent.parent
_ENV_FILE = _PROJ / "backend" / ".env"
_DEFAULT_LOG_DIR = _PROJ / "database" / "logs_locais"

# Chave do advisory lock (bigint) — impede 2 drenagens simultâneas no MESMO banco.
_ADVISORY_LOCK_KEY = 829_120_001

_DEFAULT_TABLES = (
    "ops.audit_logs",
    "ops.quarentena_coleta",
    "ops.audit_llm_queries",
)
# Padrão de tabelas de backup antigas (expurgos/rollback) dentro do schema ops.
# Nota: pg_tables.tablename NÃO traz o prefixo do schema — o filtro de schema é
# feito na cláusula WHERE (schemaname = 'ops'); o LIKE casa só o nome da tabela.
_BACKUP_TABLES_PATTERN = "%\\_backup"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("drain_logs")


# ── Resolução de DSN ─────────────────────────────────────────────────────────
def _strip_quotes(value: str) -> str:
    """Remove aspas/que aspas simples de um valor lido do .env."""
    return value.strip().strip('"').strip("'")


def _read_env_url(keys: tuple[str, ...]) -> str | None:
    """Lê a primeira chave presente em backend/.env (parse stdlib, sem dotenv)."""
    if not _ENV_FILE.is_file():
        return None
    for key in keys:
        pattern = re.compile(rf"^\s*(?:export\s+)?{re.escape(key)}=(.*)$")
        with _ENV_FILE.open(encoding="utf-8") as fh:
            for line in fh:
                match = pattern.match(line)
                if match:
                    url = _strip_quotes(match.group(1))
                    if url:
                        return url
    return None


def _resolve_dsn(cli_url: str | None) -> str:
    """Resolve a DSN: --db-url > env DATABASE_URL > backend/.env."""
    url = (
        cli_url
        or os.environ.get("DATABASE_URL")
        or _read_env_url(("DATABASE_URL", "DATABASE_URL_PRIMARY", "DATABASE_URL_ETL"))
    )
    if not url:
        raise SystemExit(
            "[DRAIN] Nenhuma DATABASE_URL encontrada. Exporte DATABASE_URL, "
            "use --db-url ou configure backend/.env."
        )
    return url


def _ensure_ssl(dsn: str) -> str:
    """Adiciona sslmode=require para hosts remotos que não o declaram (ex: Aiven)."""
    if "sslmode" in dsn:
        return dsn
    if "localhost" in dsn or "127.0.0.1" in dsn:
        return dsn
    sep = "&" if "?" in dsn else "?"
    return f"{dsn}{sep}sslmode=require"


def _host_of(dsn: str) -> str:
    """Extrai o host da URL (sem credenciais) para log/manifest."""
    match = re.search(r"//[^@]*@([^:/?]+)", dsn)
    if match:
        return match.group(1)
    # DSN sem credenciais (ex: socket unix via parâmetro host=)
    socket_match = re.search(r"(?:\?|&)host=([^&]+)", dsn)
    return socket_match.group(1) if socket_match else "desconhecido"


def _is_local_host(dsn: str, host: str) -> bool:
    """True se o alvo parece ser o banco local (localhost/socket unix)."""
    return (
        host in ("localhost", "127.0.0.1")
        or "localhost" in dsn
        or "127.0.0.1" in dsn
        or host.startswith("/")
    )


# ── Lock anti-concorrência ───────────────────────────────────────────────────
def _acquire_lock(conn) -> bool:
    """Tenta advisory lock de sessão; False = outra instância em execução."""
    with conn.cursor() as cur:
        cur.execute("SELECT pg_try_advisory_lock(%s)", (_ADVISORY_LOCK_KEY,))
        acquired = bool(cur.fetchone()[0])
    if not acquired:
        logger.error(
            "[DRAIN] 🔒 Lock anti-concorrência ocupado (outra drenagem em execução). "
            "Encerrando sem tocar no banco (exit 3)."
        )
    else:
        logger.info("[DRAIN] 🔒 Advisory lock adquirido (liberado ao fechar a conexão).")
    return acquired


# ── Tabelas alvo ─────────────────────────────────────────────────────────────
def _split_tables(cli_tables: str | None) -> list[str]:
    if not cli_tables:
        return []
    return [t.strip() for t in cli_tables.split(",") if t.strip()]


def _discover_backup_tables(conn) -> list[str]:
    """Descobre tabelas ops.*_backup existentes (backups antigos de staging)."""
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT schemaname || '.' || tablename
            FROM pg_tables
            WHERE schemaname = 'ops' AND tablename LIKE %s
            ORDER BY tablename
            """,
            (_BACKUP_TABLES_PATTERN,),
        )
        return [row[0] for row in cur.fetchall()]


def _resolve_tables(conn, cli_tables: str | None) -> list[str]:
    """Tabelas a drenar: padrão + backup tables descobertas + extensões via --tables."""
    tables = list(_DEFAULT_TABLES)
    tables.extend(_discover_backup_tables(conn))
    tables.extend(_split_tables(cli_tables))
    # Remove duplicatas preservando a ordem.
    return list(dict.fromkeys(tables))


# ── Exportação ───────────────────────────────────────────────────────────────
def _export_table(conn, schema_table: str, dest_dir: Path, stamp: str) -> dict:
    """Exporta a tabela para CSV local via COPY TO STDOUT (streaming, memória O(1))."""
    schema, _, table = schema_table.partition(".")
    qualified = f'"{schema}"."{table}"'

    with conn.cursor() as cur:
        cur.execute("SELECT to_regclass(%s)", (qualified,))
        if cur.fetchone()[0] is None:
            raise LookupError(f"tabela {schema_table} não existe no banco de origem")

        cur.execute(f"SELECT COUNT(*) FROM {qualified}")
        row_count = int(cur.fetchone()[0])

        file_name = f"{schema}_{table}_{stamp}.csv"
        file_path = dest_dir / file_name
        # COPY TO STDOUT com streaming — cabe até 300k+ linhas sem estourar RAM.
        with file_path.open("w", encoding="utf-8", newline="") as fh:
            cur.copy_expert(
                f"COPY (SELECT * FROM {qualified}) TO STDOUT WITH CSV HEADER",
                fh,
            )

    size_bytes = file_path.stat().st_size
    if size_bytes <= 0:
        raise OSError(f"arquivo {file_path} ficou vazio (0 bytes) — abortando")

    logger.info(
        "[DRAIN] exportada %s → %s (%s linhas, %.1f KB)",
        schema_table,
        file_path,
        row_count,
        size_bytes / 1024,
    )
    return {
        "tabela": schema_table,
        "arquivo": str(file_path.relative_to(_PROJ)),
        "linhas": row_count,
        "bytes": size_bytes,
    }


# ── Upload + cleanup + truncate ──────────────────────────────────────────────
def _upload_all(infos: list[dict]) -> list[dict]:
    """Faz upload de cada CSV; devolve lista com a chave do objeto por tabela."""
    uploaded: list[dict] = []
    for info in infos:
        path = _PROJ / info["arquivo"]
        try:
            key = storage.upload_file(path)
        except storage.StorageError as exc:
            raise RuntimeError(f"upload de {path.name} falhou: {exc}") from exc
        info["objeto_storage"] = key
        uploaded.append(info)
        logger.info("[DRAIN] ☁ upload OK → %s (%s)", key, info["tabela"])
    return uploaded


def _remove_local_files(infos: list[dict], dest_dir: Path) -> None:
    """Remove os arquivos temporários do disco (Render ephemeral)."""
    for info in infos:
        (dest_dir / Path(info["arquivo"]).name).unlink(missing_ok=True)
    logger.info("[DRAIN] 🗑 arquivos temporários removidos do disco (DELETE_AFTER_UPLOAD).")


def _truncate_tables(conn, tables: list[str]) -> None:
    """TRUNCATE apenas das tabelas efetivamente drenadas (libera disco na nuvem)."""
    qualified = [f'"{s}"."{t}"' for s, _, t in (x.partition(".") for x in tables)]
    sql = f"TRUNCATE TABLE {', '.join(qualified)}"
    with conn.cursor() as cur:
        cur.execute(sql)
    conn.commit()
    logger.info("[DRAIN] TRUNCATE executado: %s", ", ".join(tables))


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Drenagem de logs: exporta CSV → upload S3 → TRUNCATE (sob demanda/Render cron).",
    )
    parser.add_argument("--db-url", help="DSN do banco (override do backend/.env)")
    parser.add_argument(
        "--tables",
        help="Tabelas adicionais separadas por vírgula (ex: ops.audit_logs,raw.controle_carga)",
    )
    parser.add_argument("--dest", help="Diretório local de saída (padrão: database/logs_locais/)")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Somente exporta — NÃO faz upload nem TRUNCATE (ensaio seguro)",
    )
    parser.add_argument(
        "--force-local",
        action="store_true",
        help="Permite TRUNCATE mesmo se o host parecer local (localhost)",
    )
    parser.add_argument(
        "--no-lock",
        action="store_true",
        help="Ignora o advisory lock anti-concorrência (apenas para testes)",
    )
    return parser.parse_args()


def main() -> int:
    args = _parse_args()

    try:
        dsn = _ensure_ssl(_resolve_dsn(args.db_url))
    except SystemExit as exc:
        logger.error("%s", exc)
        return 1

    dest_dir = Path(args.dest) if args.dest else _DEFAULT_LOG_DIR
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d_%H%M")
    host = _host_of(dsn)
    is_local = _is_local_host(dsn, host)
    delete_after_upload = os.environ.get("DELETE_AFTER_UPLOAD", "").lower() in ("1", "true", "yes")

    storage.load_env_fallback()  # carrega credenciais do storage via backend/.env
    storage_mode = storage.storage_mode()

    logger.info(
        "[DRAIN] alvo=%s dest=%s dry_run=%s storage=%s", host, dest_dir, args.dry_run, storage_mode
    )
    if is_local:
        logger.warning(
            "[DRAIN] ⚠️ Host LOCAL detectado (%s). Drenar o banco local NÃO libera disco da nuvem.",
            host,
        )
    if not storage_mode:
        logger.warning(
            "[DRAIN] ⚠️ Nenhum storage configurado (OBJECT_STORAGE_BUCKET ou DRAIN_WEBHOOK_URL) — "
            "modo LOCAL: arquivos NÃO são enviados à nuvem e não serão removidos."
        )
    if delete_after_upload and not storage_mode:
        logger.warning(
            "[DRAIN] DELETE_AFTER_UPLOAD=1 sem storage configurado: remoção será ignorada (segurança)."
        )

    try:
        conn = psycopg2.connect(dsn, connect_timeout=_CONNECT_TIMEOUT_SECONDS)
    except psycopg2.Error as exc:  # conectividade externa é imprevisível
        logger.error("[DRAIN] Falha ao conectar: %s", exc)
        return 1

    started = time.monotonic()
    exported: list[dict] = []
    drained: list[str] = []
    failed: list[str] = []
    truncated = False
    truncate_error: str | None = None
    exit_code = 0

    try:
        # ── Lock anti-concorrência (FASE 3) ─────────────────────────────────
        if not args.no_lock and not _acquire_lock(conn):
            return 3

        tables = _resolve_tables(conn, args.tables)
        if not tables:
            logger.warning("[DRAIN] Nenhuma tabela para drenar. Nada a fazer.")
        else:
            logger.info("[DRAIN] tabelas alvo (%d): %s", len(tables), ", ".join(tables))

            # FASE A — exporta TODAS as tabelas para CSV local.
            for schema_table in tables:
                try:
                    info = _export_table(conn, schema_table, dest_dir, stamp)
                    exported.append(info)
                    drained.append(schema_table)
                except (OSError, LookupError, psycopg2.Error) as exc:
                    conn.rollback()  # sai do estado de transação abortada
                    failed.append(f"{schema_table} ({exc})")
                    logger.error("[DRAIN] falha na exportação de %s: %s", schema_table, exc)

            if failed:
                logger.error(
                    "[DRAIN] ABORTANDO: %d tabela(s) falharam na exportação (%s). "
                    "NENHUM upload nem TRUNCATE executado — nada foi perdido.",
                    len(failed),
                    "; ".join(failed),
                )
                exit_code = 2
            elif not args.dry_run and exported:
                # Guarda de segurança ANTES do upload: nunca truncar banco local
                # sem --force-local (evita escritas inúteis no bucket).
                if is_local and not args.force_local:
                    logger.error(
                        "[DRAIN] Host local (%s): TRUNCATE bloqueado por segurança. "
                        "Reexecute com --force-local se for intencional, ou aponte --db-url para a nuvem.",
                        host,
                    )
                    exit_code = 2
                else:
                    # FASE B — persistência dos dados ANTES do TRUNCATE:
                    #   • storage configurado → upload OBRIGATÓRIO (Render) e
                    #     TRUNCATE só após HTTP 200 confirmado;
                    #   • sem storage (modo LOCAL/BYOB) → os CSVs salvos no disco
                    #     local JÁ são a persistência (spec original: "após
                    #     confirmar que o arquivo local foi salvo com sucesso").
                    if storage_mode:
                        try:
                            _upload_all(exported)
                        except RuntimeError as exc:
                            logger.error(
                                "[DRAIN] ABORTANDO: %s. Arquivos locais mantidos em %s — "
                                "NENHUM TRUNCATE executado; o disco da nuvem NÃO foi liberado.",
                                exc,
                                dest_dir,
                            )
                            exit_code = 2
                    else:
                        logger.info(
                            "[DRAIN] Modo LOCAL (sem storage): CSVs locais são a persistência "
                            "antes do TRUNCATE."
                        )

                    if exit_code == 0:
                        # FASE C — remove temporários do disco (apenas com upload
                        # confirmado + DELETE_AFTER_UPLOAD).
                        if delete_after_upload and storage_mode:
                            _remove_local_files(exported, dest_dir)

                        # FASE D — TRUNCATE (apenas com persistência confirmada).
                        try:
                            _truncate_tables(conn, drained)
                            truncated = True
                        except psycopg2.Error as exc:
                            truncate_error = str(exc)
                            exit_code = 2
                            logger.error(
                                "[DRAIN] ERRO no TRUNCATE (%s). Os dados já estão preservados "
                                "em %s (CSVs/dump) — o disco da nuvem NÃO foi liberado.",
                                exc,
                                dest_dir,
                            )
            elif args.dry_run:
                logger.info("[DRAIN] --dry-run: upload e TRUNCATE pulados (ensaio).")
    finally:
        conn.close()  # fecha → libera o advisory lock (mesmo em crash)

    # FASE E — manifest de auditoria local (gravado mesmo em falha parcial).
    manifest = {
        "operacao": "drenagem_logs",
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
        "host": host,
        "storage": storage_mode,
        "dry_run": args.dry_run,
        "delete_after_upload": delete_after_upload,
        "truncate": truncated,
        "erro_truncate": truncate_error,
        "duracao_s": round(time.monotonic() - started, 2),
        "tabelas": exported,
        "falhas": failed,
    }
    manifest_path = dest_dir / f"manifest_{stamp}.json"
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    logger.info("[DRAIN] manifest salvo: %s", manifest_path)

    # Manifest também vai para o storage (melhor esforço — não é bloqueante).
    # Nunca em --dry-run (ensaio sem efeitos de nuvem); sobe sempre que houve
    # exportação (mesmo com exit 2), para o trilho de auditoria ficar no bucket.
    if storage_mode and not args.dry_run and exported:
        try:
            storage.upload_file(manifest_path)
        except storage.StorageError as exc:
            logger.warning("[DRAIN] manifest não enviado ao storage (não bloqueante): %s", exc)

    if exit_code == 0 and truncated:
        if storage_mode:
            logger.info(
                "[DRAIN] ✅ Concluído: %d tabela(s) exportada(s) + upload OK + TRUNCATE.",
                len(drained),
            )
        else:
            logger.info(
                "[DRAIN] ✅ Concluído: %d tabela(s) exportada(s) (persistência local) + TRUNCATE.",
                len(drained),
            )
    else:
        logger.info(
            "[DRAIN] Concluído: %d tabela(s) exportada(s) (exit=%d).", len(drained), exit_code
        )
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
