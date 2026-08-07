#!/usr/bin/env python3
"""
storage.py — Upload de artefatos de backup/drenagem para Object Storage.

Compatível com QUALQUER storage S3-compatible via boto3:
  - AWS S3           (sem endpoint — usa o endpoint padrão da região)
  - Cloudflare R2    (S3_ENDPOINT_URL=https://<ACCOUNT_ID>.r2.cloudflarestorage.com)
  - MinIO / outros   (S3_ENDPOINT_URL=http://<host>:9000)
  - Webhook fallback (DRAIN_WEBHOOK_URL) — POST do arquivo quando não há bucket.

NUNCA hardcode credenciais: tudo vem de variáveis de ambiente, lidas do
ambiente OU do backend/.env como fallback (convenção do projeto).

Variáveis de ambiente:
  OBJECT_STORAGE_BUCKET (ou BUCKET_NAME)   bucket obrigatório no modo S3
  S3_ENDPOINT_URL (ou OBJECT_STORAGE_ENDPOINT_URL)  opcional (vazio = AWS)
  S3_REGION                                 (padrão: us-east-1)
  AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN
                                           lidas automaticamente pelo boto3
  OBJECT_STORAGE_PREFIX                     prefixo opcional de "pasta"
  DRAIN_WEBHOOK_URL                         modo webhook (fallback)

USO (CLI — chamada pelo backup bash e para testes):
  python3 ops/storage.py check                  # 0 = configurado, 2 = não
  python3 ops/storage.py upload <arquivo>       # 0 = upload OK (HTTP 200)
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

_PROJ = Path(__file__).resolve().parent.parent
_ENV_FILE = _PROJ / "backend" / ".env"

# Chaves aceitas (canônica + alias)
_BUCKET_KEYS = ("OBJECT_STORAGE_BUCKET", "BUCKET_NAME")
_ENDPOINT_KEYS = ("S3_ENDPOINT_URL", "OBJECT_STORAGE_ENDPOINT_URL")


class StorageError(RuntimeError):
    """Falha de configuração ou de upload de armazenamento."""


# ── Resolução de ambiente (env > backend/.env) ──────────────────────────────
def load_env_fallback() -> None:
    """Carrega variáveis de storage ausentes a partir do backend/.env."""
    if not _ENV_FILE.is_file():
        return
    wanted = (
        _BUCKET_KEYS
        + _ENDPOINT_KEYS
        + (
            "S3_REGION",
            "OBJECT_STORAGE_PREFIX",
            "DRAIN_WEBHOOK_URL",
            "AWS_ACCESS_KEY_ID",
            "AWS_SECRET_ACCESS_KEY",
            "AWS_SESSION_TOKEN",
        )
    )
    for key in wanted:
        if key in os.environ:
            continue
        pattern = re.compile(rf"^\s*(?:export\s+)?{re.escape(key)}=(.*)$")
        with _ENV_FILE.open(encoding="utf-8") as fh:
            for line in fh:
                match = pattern.match(line)
                if match:
                    os.environ[key] = match.group(1).strip().strip('"').strip("'")
                    break


def _first_env(*keys: str) -> str | None:
    for key in keys:
        value = os.environ.get(key)
        if value:
            return value
    return None


def storage_mode() -> str | None:
    """'s3', 'webhook' ou None (nenhum storage configurado — modo local)."""
    if _first_env(*_BUCKET_KEYS):
        return "s3"
    if os.environ.get("DRAIN_WEBHOOK_URL"):
        return "webhook"
    return None


# ── Upload ───────────────────────────────────────────────────────────────────
def _s3_client():
    import boto3  # import lento: só carrega quando há bucket configurado

    region = os.environ.get("S3_REGION") or "us-east-1"
    endpoint = _first_env(*_ENDPOINT_KEYS) or None
    # boto3 lê AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN
    # automaticamente do ambiente — nada de credencial no código.
    return boto3.client("s3", endpoint_url=endpoint, region_name=region)


def _upload_s3(path: Path) -> str:
    bucket = _first_env(*_BUCKET_KEYS)
    if not bucket:
        raise StorageError("bucket não configurado (OBJECT_STORAGE_BUCKET/BUCKET_NAME)")
    prefix = (os.environ.get("OBJECT_STORAGE_PREFIX") or "").strip("/")
    key = f"{prefix}/{path.name}" if prefix else path.name
    client = _s3_client()
    with path.open("rb") as fh:
        response = client.put_object(Bucket=bucket, Key=key, Body=fh)
    status = int(response["ResponseMetadata"]["HTTPStatusCode"])
    if status != 200:
        raise StorageError(f"put_object respondeu HTTP {status} para {key}")
    return key


def _upload_webhook(path: Path) -> str:
    import requests  # requests já é dependência do pipeline

    url = os.environ["DRAIN_WEBHOOK_URL"]
    with path.open("rb") as fh:
        response = requests.post(
            url,
            data=fh,
            headers={"Content-Type": "application/octet-stream"},
            timeout=120,
        )
    if response.status_code != 200:
        raise StorageError(f"webhook respondeu HTTP {response.status_code} para {path.name}")
    return path.name


def upload_file(path: str | Path) -> str:
    """Faz upload de um arquivo para o storage configurado; retorna a chave do objeto.

    Levanta StorageError em caso de falha (nenhum arquivo é enviado parcialmente).
    """
    file_path = Path(path)
    if not file_path.is_file():
        raise StorageError(f"arquivo não encontrado: {file_path}")

    load_env_fallback()
    mode = storage_mode()
    if mode == "s3":
        return _upload_s3(file_path)
    if mode == "webhook":
        return _upload_webhook(file_path)
    raise StorageError(
        "storage não configurado: defina OBJECT_STORAGE_BUCKET (S3-compatible) ou DRAIN_WEBHOOK_URL"
    )


# ── CLI ──────────────────────────────────────────────────────────────────────
def _cli() -> int:
    load_env_fallback()
    parser = argparse.ArgumentParser(description="Upload S3-compatible de artefatos de backup.")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("check", help="Verifica se um storage está configurado (0=sim, 2=não)")
    up = sub.add_parser("upload", help="Faz upload de um arquivo")
    up.add_argument("file", help="Caminho do arquivo a enviar")

    args = parser.parse_args()

    if args.command == "check":
        mode = storage_mode()
        if mode:
            print(f"[STORAGE] modo: {mode}")
            return 0
        print("[STORAGE] nenhum storage configurado — modo local (sem upload)")
        return 2

    try:
        key = upload_file(args.file)
    except StorageError as exc:
        print(f"[STORAGE] ERRO: {exc}", file=sys.stderr)
        return 1
    print(f"[STORAGE] upload OK → {key}")
    return 0


if __name__ == "__main__":
    sys.exit(_cli())
