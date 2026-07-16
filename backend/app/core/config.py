from pydantic_settings import BaseSettings
from functools import lru_cache


class Settings(BaseSettings):
    database_url: str = "postgresql://role_api_reader:senha@localhost:5432/quero_comprar"
    database_url_api: str = ""
    database_url_etl: str = ""
    redis_url: str = ""
    cache_ttl_seconds: int = 86400
    cors_origins: list[str] = [
        "http://localhost:3000",
        "http://localhost:5173",
        "http://localhost:5174",
        "http://127.0.0.1:5173",
        "http://127.0.0.1:5174",
    ]
    pool_min_size: int = 10
    pool_max_size: int = 50
    api_v1_prefix: str = "/api/v1"
    rate_limit_per_minute: int = 60
    request_timeout_seconds: float = 29.0
    internal_api_key: str = ""
    debug: bool = False

    model_config = {"env_file": ".env", "env_file_encoding": "utf-8"}


@lru_cache
def get_settings() -> Settings:
    return Settings()
