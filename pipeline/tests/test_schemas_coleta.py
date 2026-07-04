from __future__ import annotations

import asyncio
from datetime import date

import pytest
from pydantic import ValidationError

from pipeline.scraper.circuit_breaker import CircuitBreaker, CircuitState
from pipeline.scraper.rate_limiter import RateLimiter
from pipeline.scraper.schemas.coleta import (
    CotacaoColeta,
    CotacaoNormalizada,
    HEADER_LIXO,
    ResultadoMotor,
)


# #####################################################################
# CotacaoColeta — Validação de Schema
# #####################################################################


class TestCotacaoColetaValid:
    def test_dado_valido_mais_simples(self):
        c = CotacaoColeta(
            produto_original="Tomate Italiano",
            uf="SP",
            municipio="Sao Paulo",
            ano=2025,
            mes=6,
            fonte="CEAGESP",
            preco_bruto=45.0,
        )
        assert c.produto_original == "Tomate Italiano"
        assert c.preco_bruto == 45.0
        assert c.fator_kg == 1.0
        assert c.data_coleta == date.today().isoformat()

    def test_dado_valido_com_fator_kg(self):
        c = CotacaoColeta(
            produto_original="Batata",
            uf="MG",
            municipio="Contagem",
            ano=2025,
            mes=3,
            fonte="CEASA-MG",
            preco_bruto=120.0,
            fator_kg=25.0,
        )
        assert c.preco_bruto / c.fator_kg == 4.8

    def test_preco_um_centavo_valido(self):
        c = CotacaoColeta(
            produto_original="Cebola",
            uf="PR",
            municipio="Curitiba",
            ano=2025,
            mes=1,
            fonte="CEASA-PR",
            preco_bruto=0.01,
        )
        assert c.preco_bruto == 0.01

    def test_uf_br_aceito(self):
        c = CotacaoColeta(
            produto_original="Arroz",
            uf="BR",
            municipio="Nacional",
            ano=2025,
            mes=1,
            fonte="CONAB-ProHort",
            preco_bruto=50.0,
        )
        assert c.uf == "BR"

    def test_data_coleta_personalizada(self):
        c = CotacaoColeta(
            produto_original="Alface",
            uf="SP",
            municipio="Sao Paulo",
            ano=2025,
            mes=1,
            fonte="CEAGESP",
            preco_bruto=10.0,
            data_coleta="2025-01-15",
        )
        assert c.data_coleta == "2025-01-15"


class TestCotacaoColetaRejeicao:
    @pytest.mark.parametrize("lixo", sorted(HEADER_LIXO))
    def test_rejeita_header_lixo(self, lixo):
        with pytest.raises(ValidationError, match="header_lixo"):
            CotacaoColeta(
                produto_original=lixo,
                uf="SP",
                municipio="Sao Paulo",
                ano=2025,
                mes=1,
                fonte="CEAGESP",
                preco_bruto=10.0,
            )

    @pytest.mark.parametrize(
        "produto,razao",
        [
            ("", "curto"),
            ("ab", "curto"),
            ("12345", "apenas_numeros"),
            ("999", "apenas_numeros"),
            ("  ", "curto"),
            ("email@teste.com", "email"),
            ("suporte@ceasa.mg.gov.br", "email"),
            ("página 1", "numero_pagina"),
            ("Pagina 2", "numero_pagina"),
            ("PÁGINA 10", "numero_pagina"),
        ],
    )
    def test_rejeita_padroes_lixo(self, produto, razao):
        with pytest.raises(ValidationError):
            CotacaoColeta(
                produto_original=produto,
                uf="SP",
                municipio="Sao Paulo",
                ano=2025,
                mes=1,
                fonte="CEAGESP",
                preco_bruto=10.0,
            )

    @pytest.mark.parametrize("preco", [0.0, -1.0, -0.01])
    def test_rejeita_preco_nao_positivo(self, preco):
        with pytest.raises(ValidationError):
            CotacaoColeta(
                produto_original="Tomate",
                uf="SP",
                municipio="Sao Paulo",
                ano=2025,
                mes=1,
                fonte="CEAGESP",
                preco_bruto=preco,
            )

    @pytest.mark.parametrize(
        "preco,razao",
        [
            (10_001, ">10k"),
            (99_999.99, ">10k"),
            (1_000_000, ">10k"),
        ],
    )
    def test_rejeita_preco_fora_limite(self, preco, razao):
        with pytest.raises(ValidationError, match="10k"):
            CotacaoColeta(
                produto_original="Tomate",
                uf="SP",
                municipio="Sao Paulo",
                ano=2025,
                mes=1,
                fonte="CEAGESP",
                preco_bruto=preco,
            )

    @pytest.mark.parametrize(
        "uf",
        [
            "SPO",
            "S",
            "",
            "sp",
            "sao paulo",
            "12",
        ],
    )
    def test_rejeita_uf_invalida(self, uf):
        with pytest.raises(ValidationError):
            CotacaoColeta(
                produto_original="Tomate",
                uf=uf,
                municipio="Sao Paulo",
                ano=2025,
                mes=1,
                fonte="CEAGESP",
                preco_bruto=10.0,
            )

    @pytest.mark.parametrize("ano", [1999, 2101, 0, -1])
    def test_rejeita_ano_fora_range(self, ano):
        with pytest.raises(ValidationError):
            CotacaoColeta(
                produto_original="Tomate",
                uf="SP",
                municipio="Sao Paulo",
                ano=ano,
                mes=1,
                fonte="CEAGESP",
                preco_bruto=10.0,
            )

    @pytest.mark.parametrize("mes", [0, 13, -1])
    def test_rejeita_mes_fora_range(self, mes):
        with pytest.raises(ValidationError):
            CotacaoColeta(
                produto_original="Tomate",
                uf="SP",
                municipio="Sao Paulo",
                ano=2025,
                mes=mes,
                fonte="CEAGESP",
                preco_bruto=10.0,
            )

    @pytest.mark.parametrize(
        "fonte",
        [
            "",
            "   ",
        ],
    )
    def test_rejeita_fonte_vazia(self, fonte):
        with pytest.raises(ValidationError):
            CotacaoColeta(
                produto_original="Tomate",
                uf="SP",
                municipio="Sao Paulo",
                ano=2025,
                mes=1,
                fonte=fonte,
                preco_bruto=10.0,
            )

    def test_rejeita_ano_mes_zero_com_ceasa_generico(self):
        with pytest.raises(ValidationError):
            CotacaoColeta(
                produto_original="Tomate",
                uf="SP",
                municipio="Sao Paulo",
                ano=0,
                mes=0,
                fonte="CEASA",
                preco_bruto=10.0,
            )


# #####################################################################
# CotacaoNormalizada
# #####################################################################


class TestCotacaoNormalizada:
    def test_herda_todas_validacoes(self):
        with pytest.raises(ValidationError):
            CotacaoNormalizada(
                produto_original="",
                uf="SP",
                municipio="Sao Paulo",
                ano=2025,
                mes=1,
                fonte="CEAGESP",
                preco_bruto=10.0,
                produto_normalizado="Tomate",
            )

    def test_com_campos_opcionais_none(self):
        c = CotacaoNormalizada(
            produto_original="Tomate Italiano",
            uf="SP",
            municipio="Sao Paulo",
            ano=2025,
            mes=6,
            fonte="CEAGESP",
            preco_bruto=45.0,
            produto_normalizado="TOMATE",
        )
        assert c.categoria_b2c is None
        assert c.preco_medio is None
        assert c.preco_min is None
        assert c.preco_max is None

    def test_com_campos_opcionais_preenchidos(self):
        c = CotacaoNormalizada(
            produto_original="Tomate Italiano",
            uf="SP",
            municipio="Sao Paulo",
            ano=2025,
            mes=6,
            fonte="CEAGESP",
            preco_bruto=45.0,
            produto_normalizado="TOMATE",
            categoria_b2c="HORTIFRUTI",
            preco_medio=50.0,
            preco_min=40.0,
            preco_max=60.0,
        )
        assert c.categoria_b2c == "HORTIFRUTI"
        assert c.preco_medio == 50.0

    def test_rejeita_produto_normalizado_vazio(self):
        with pytest.raises(ValidationError):
            CotacaoNormalizada(
                produto_original="Tomate Italiano",
                uf="SP",
                municipio="Sao Paulo",
                ano=2025,
                mes=6,
                fonte="CEAGESP",
                preco_bruto=45.0,
                produto_normalizado="",
            )


# #####################################################################
# ResultadoMotor
# #####################################################################


class TestResultadoMotor:
    def test_resultado_sucesso_vazio(self):
        r = ResultadoMotor(
            motor="CEAGESP",
            fonte="CEAGESP",
            uf="SP",
            municipio="Sao Paulo",
        )
        assert r.status == "sucesso"
        assert r.cotacoes == []
        assert r.erro == ""

    def test_resultado_falha(self):
        r = ResultadoMotor(
            motor="CEASA-MG",
            fonte="CEASA-MG",
            uf="MG",
            municipio="Contagem",
            status="falha",
            erro="Connection refused",
            tempo_s=5.3,
        )
        assert r.status == "falha"
        assert "refused" in r.erro

    def test_resultado_circuit_open(self):
        r = ResultadoMotor(
            motor="CEASA-GO",
            fonte="CEASA-GO",
            uf="GO",
            municipio="Goiania",
            status="circuit_open",
            erro="Circuit breaker OPEN",
        )
        assert r.status == "circuit_open"

    def test_rejeita_status_invalido(self):
        with pytest.raises(ValidationError):
            ResultadoMotor(
                motor="CEAGESP",
                fonte="CEAGESP",
                uf="SP",
                municipio="Sao Paulo",
                status="desconhecido",
            )


# #####################################################################
# CircuitBreaker
# #####################################################################


class TestCircuitBreaker:
    def test_inicia_fechado(self):
        cb = CircuitBreaker(nome="teste")
        assert not cb.esta_aberto
        assert cb._state == CircuitState.CLOSED

    def test_abre_apos_n_falhas(self):
        cb = CircuitBreaker(nome="teste", failure_threshold=3, window_s=60)
        for _ in range(3):
            cb.registrar_falha()
        assert cb.esta_aberto
        assert cb._state == CircuitState.OPEN

    def test_nao_abre_antes_do_threshold(self):
        cb = CircuitBreaker(nome="teste", failure_threshold=5, window_s=60)
        for _ in range(4):
            cb.registrar_falha()
        assert not cb.esta_aberto

    def test_meia_abertura_apos_timeout(self, monkeypatch):
        import time
        cb = CircuitBreaker(nome="teste", failure_threshold=3, recovery_timeout_s=0.01)
        for _ in range(3):
            cb.registrar_falha()
        assert cb.esta_aberto
        time.sleep(0.02)
        assert not cb.esta_aberto
        assert cb._state == CircuitState.HALF_OPEN

    def test_fecha_apos_sucesso_em_half_open(self, monkeypatch):
        import time
        cb = CircuitBreaker(nome="teste", failure_threshold=3, recovery_timeout_s=0.01)
        for _ in range(3):
            cb.registrar_falha()
        assert cb.esta_aberto
        time.sleep(0.02)
        assert not cb.esta_aberto
        cb.registrar_sucesso()
        assert cb._state == CircuitState.CLOSED
        assert len(cb._failures) == 0

    def test_reset_manual(self):
        cb = CircuitBreaker(nome="teste", failure_threshold=3)
        for _ in range(3):
            cb.registrar_falha()
        assert cb.esta_aberto
        cb.reset()
        assert not cb.esta_aberto
        assert cb._state == CircuitState.CLOSED

    def test_janela_deslizante_ignora_falhas_antigas(self, monkeypatch):
        import time
        cb = CircuitBreaker(nome="teste", failure_threshold=3, window_s=0.01)
        for _ in range(2):
            cb.registrar_falha()
        time.sleep(0.02)
        for _ in range(2):
            cb.registrar_falha()
        assert len(cb._failures) == 2
        assert not cb.esta_aberto

    def test_status_dict(self):
        cb = CircuitBreaker(nome="teste", failure_threshold=5)
        cb.registrar_falha()
        status = cb.status_dict()
        assert status["nome"] == "teste"
        assert status["state"] == "CLOSED"
        assert status["failures_window"] == 1
        assert status["threshold"] == 5


# #####################################################################
# RateLimiter
# #####################################################################


class TestRateLimiter:
    def test_mesmo_dominio_mesmo_semaforo(self):
        rl = RateLimiter()
        s1 = rl.para_dominio("https://www.ceagesp.gov.br/cotacoes")
        s2 = rl.para_dominio("https://www.ceagesp.gov.br/outra-pagina")
        assert s1 is s2

    def test_dominios_diferentes_semaforos(self):
        rl = RateLimiter()
        s1 = rl.para_dominio("https://www.ceagesp.gov.br")
        s2 = rl.para_dominio("https://www.ceasa.mg.gov.br")
        assert s1 is not s2

    def test_max_concorrencia_padrao(self):
        rl = RateLimiter(max_concorrencia_por_dominio=5)
        sem = rl.para_dominio("https://exemplo.com")
        assert sem._value == 5  # type: ignore[attr-defined]

    def test_extrai_dominio_sem_protocolo(self):
        rl = RateLimiter()
        s1 = rl.para_dominio("ceagesp.gov.br/cotacoes")
        s2 = rl.para_dominio("ceagesp.gov.br")
        assert s1 is s2

    def test_status_dict(self):
        rl = RateLimiter()
        rl.para_dominio("https://www.ceagesp.gov.br")
        rl.para_dominio("https://www.ceasa.mg.gov.br")
        status = rl.status()
        assert "ceagesp.gov.br" in status or "ceagesp" in status
        assert len(status) == 2