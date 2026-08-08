from functools import lru_cache

from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    database_url: str = "postgresql://role_api_reader:senha@localhost:5432/quero_comprar"
    database_url_api: str = ""
    database_url_etl: str = ""
    # ── Failover / Alta Disponibilidade ──────────────────────────────
    # PRIMARY: banco remoto (Aiven — única fonte da verdade).
    # STANDBY: banco local (sandbox/snapshot) via `database_url_local_backup`.
    # Se PRIMARY vazio, usa `database_url`. Sem Supabase.
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
    ]
    pool_min_size: int = 2
    pool_max_size: int = 10
    api_v1_prefix: str = "/api/v1"
    rate_limit_per_minute: int = 60
    request_timeout_seconds: float = 29.0
    internal_api_key: str = ""
    debug: bool = False

    model_config = {
        "env_file": "backend/.env",
        "env_file_encoding": "utf-8",
        "extra": "ignore",
    }


@lru_cache
def get_settings() -> Settings:
    return Settings()
