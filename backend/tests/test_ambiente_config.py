"""
RED/GREEN — Dual-Environment (FASE 2).

Cobre:
  - APP_ENV decide o arquivo .env carregado (backend/.env.<ambiente>).
  - Pool de conexões autotunado por ambiente (staging folgado / production estrito).
  - Rótulos do banner de startup (AMBIENTE e destino do banco).
  - Valores explícitos de POOL_* têm precedência sobre o autotuning.

Sem dependência de banco: apenas Settings + resolução de env file.
"""

from __future__ import annotations

from backend.app.core.config import Settings, _resolver_env_file


def test_app_env_default_e_staging(monkeypatch) -> None:
    """Sem APP_ENV, o ambiente padrão é staging (homologação física)."""
    monkeypatch.delenv("APP_ENV", raising=False)
    s = Settings()
    assert s.app_env == "staging"
    assert s.environment_label == "STAGING"


def test_app_env_production(monkeypatch) -> None:
    """APP_ENV=production ativa o ambiente de nuvem e rótulo PRODUCTION."""
    monkeypatch.setenv("APP_ENV", "production")
    s = Settings()
    assert s.app_env == "production"
    assert s.environment_label == "PRODUCTION"


def test_app_env_tolerante_a_valores_informais(monkeypatch) -> None:
    """APP_ENV com valor inesperado (ex.: 'dev') cai em staging sem crash."""
    monkeypatch.setenv("APP_ENV", "dev")
    s = Settings()
    assert s.app_env == "staging"


def test_pool_autotunado_por_ambiente(monkeypatch, tmp_path) -> None:
    """staging = pool folgado p/ testes de carga; production = estrito (Aiven).

    Isola dos env files reais (backend/.env.staging define POOL_* explícito) via
    ENV_FILE_BASE apontando para um diretório vazio.
    """
    monkeypatch.delenv("POOL_MIN_SIZE", raising=False)
    monkeypatch.delenv("POOL_MAX_SIZE", raising=False)
    monkeypatch.setenv("ENV_FILE_BASE", str(tmp_path / "sem_arquivos"))

    monkeypatch.setenv("APP_ENV", "staging")
    s_staging = Settings()
    assert s_staging.pool_min_size is None  # autotuning ativo
    assert s_staging.effective_pool_max_size >= 20
    assert s_staging.effective_pool_min_size >= 1

    monkeypatch.setenv("APP_ENV", "production")
    s_prod = Settings()
    assert s_prod.effective_pool_max_size <= 10
    assert s_prod.effective_pool_max_size < s_staging.effective_pool_max_size


def test_pool_explicito_tem_precedencia(monkeypatch) -> None:
    """POOL_* explícito vence o autotuning (mas respeita o teto por ambiente)."""
    monkeypatch.setenv("APP_ENV", "production")
    s = Settings(pool_min_size=5, pool_max_size=50)
    assert s.effective_pool_min_size == 5
    # production: teto rígido de 10 (Aiven free/basic não comporta 50)
    assert s.effective_pool_max_size == 10


def test_resolver_env_file_por_ambiente(monkeypatch, tmp_path) -> None:
    """_resolver_env_file escolhe <base>.<app_env> quando existe."""
    monkeypatch.setenv("ENV_FILE_BASE", str(tmp_path / "env"))
    (tmp_path / "env.production").write_text("APP_ENV=production\n", encoding="utf-8")
    (tmp_path / "env.staging").write_text("APP_ENV=staging\n", encoding="utf-8")

    assert _resolver_env_file("production") == str(tmp_path / "env.production")
    assert _resolver_env_file("staging") == str(tmp_path / "env.staging")


def test_resolver_env_file_fallback_para_base(monkeypatch, tmp_path) -> None:
    """Sem arquivo por ambiente, cai no <base> legado."""
    monkeypatch.setenv("ENV_FILE_BASE", str(tmp_path / "env"))
    (tmp_path / "env").write_text("", encoding="utf-8")
    assert _resolver_env_file("production") == str(tmp_path / "env")


def test_database_target_label_local_vs_nuvem(monkeypatch) -> None:
    """Rótulo do destino reflete o hostname real da URL primária."""
    monkeypatch.setenv("APP_ENV", "staging")
    s_local = Settings(database_url_primary="postgresql://postgres:x@localhost:5432/quero_comprar")
    assert "FÍSICO" in s_local.database_target_label

    monkeypatch.setenv("APP_ENV", "production")
    s_nuvem = Settings(
        database_url_primary="postgresql://avnadmin:x@qc-proj.aivencloud.com:26536/defaultdb"
    )
    assert "AIVEN" in s_nuvem.database_target_label
