import os
from functools import lru_cache
from typing import Literal
from urllib.parse import urlsplit

from pydantic_settings import BaseSettings


def _resolver_env_file(app_env: str) -> str:
    """Resolve o arquivo ``.env`` ativo para o ambiente (``APP_ENV``).

    Fronteira invisível entre o servidor físico (homologação) e a nuvem
    (Aiven/produção): o ``APP_ENV`` do processo decide qual arquivo carregar.

    Ordem de preferência (o primeiro que existir em disco vence — evita a
    ambiguidade de precedência entre múltiplos ``env_file`` do pydantic-settings):

      1. ``<base>.<app_env>``   (ex.: ``backend/.env.production``)
      2. ``<base>.staging``     (fallback explícito de desenvolvimento)
      3. ``<base>``             (``backend/.env`` legado)

    ``ENV_FILE_BASE`` permite sobrescrever a base em cenários de teste/CI.
    """
    base = os.getenv("ENV_FILE_BASE", "backend/.env")
    for candidate in (f"{base}.{app_env}", f"{base}.staging", base):
        if os.path.exists(candidate):
            return candidate
    return base


class Settings(BaseSettings):
    # ── Ambiente (staging | production) ─────────────────────────────────
    # Lida do OS environment ANTES do arquivo .env (o APP_ENV decide qual
    # arquivo carregar — o valor dentro do arquivo é apenas informativo).
    app_env: Literal["staging", "production"] = "staging"

    database_url: str = ""
    database_url_api: str = ""
    database_url_etl: str = ""
    # ── Failover / Alta Disponibilidade ──────────────────────────────
    # PRIMARY: banco remoto (Aiven — única fonte da verdade em produção).
    # STANDBY: banco local (sandbox/snapshot) via `database_url_local_backup`.
    # Se PRIMARY vazio, usa `database_url`.
    database_url_primary: str = ""
    database_url_local_backup: str = ""
    # Caminho (relativo à raiz do repo) do dump de schema usado no bootstrap local.
    bootstrap_schema_path: str = "database/backups/backup_schema_latest.sql"
    redis_url: str = ""
    cache_ttl_seconds: int = 3600
    cors_origins: list[str] = [
        "http://localhost:3000",
        "http://localhost:5173",
        "http://localhost:5174",
        "http://127.0.0.1:5173",
        "http://127.0.0.1:5174",
        "https://sazo-repo.vercel.app",
    ]
    # Pool — None = autotuning por ambiente (ver effective_pool_*).
    #   staging:    pool folgado (máx. 30) para testes de carga no físico.
    #   production: pool estrito (máx. 8) — Aiven free/basic limita conexões.
    pool_min_size: int | None = None
    pool_max_size: int | None = None
    api_v1_prefix: str = "/api/v1"
    rate_limit_per_minute: int = 60
    request_timeout_seconds: float = 29.0
    internal_api_key: str = ""
    debug: bool = False

    def __init__(self, **values: object) -> None:
        # 1) Lê APP_ENV do OS environment (fonte da verdade da fronteira).
        # 2) Normaliza para os valores suportados (tolerante a "dev"/"prod").
        # 3) Carrega o .env correspondente via _env_file (init kwarg vence o
        #    valor dentro do arquivo — APP_ENV do processo sempre prevalece).
        app_env = os.getenv("APP_ENV") or str(values.get("app_env", "staging")) or "staging"
        if app_env not in ("staging", "production"):
            app_env = "staging"
        values.setdefault("app_env", app_env)
        super().__init__(_env_file=_resolver_env_file(app_env), **values)

    # ── Rótulos para o banner de startup e logs ─────────────────────────
    @property
    def environment_label(self) -> str:
        """Rótulo do ambiente configurado (usado no log de inicialização)."""
        return "PRODUCTION" if self.app_env == "production" else "STAGING"

    @property
    def database_target_label(self) -> str:
        """Rótulo do DESTINO do banco PRIMARY configurado (FÍSICO/AIVEN).

        Deriva do hostname real da URL primária — não depende apenas do
        ``APP_ENV``, para que o banner nunca minta quando o .env legado
        (sem arquivo por ambiente) aponta para a nuvem.
        """
        url = self.database_url_primary or self.database_url
        host = (urlsplit(url).hostname or "").lower()
        if host in ("localhost", "127.0.0.1", "::1", ""):
            return "FÍSICO (local)"
        return "AIVEN (nuvem)"

    # ── Pool dinâmico por ambiente ───────────────────────────────────────
    @property
    def effective_pool_min_size(self) -> int:
        if self.pool_min_size is not None:
            return max(1, self.pool_min_size)
        return 4 if self.app_env == "staging" else 2

    @property
    def effective_pool_max_size(self) -> int:
        cap = 50 if self.app_env == "staging" else 10
        if self.pool_max_size is not None:
            return min(cap, max(self.effective_pool_min_size, self.pool_max_size))
        return 30 if self.app_env == "staging" else 8

    model_config = {
        "env_file_encoding": "utf-8",
        "extra": "ignore",
    }


@lru_cache
def get_settings() -> Settings:
    return Settings()
