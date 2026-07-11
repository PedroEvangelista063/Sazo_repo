# summary.md — /utilities

## Propósito
Ferramentas CLI autônomas para diagnóstico, auditoria, validação E2E e verificação de health-check. Scripts descartáveis e de uso único — sem lógica compartilhada com o pipeline principal.

## Stack
Python 3.13+, asyncpg, httpx, argparse (ou entrada via env vars).

## Regras de Ouro
1. **Autônomo**: cada script deve funcionar isoladamente. Sem imports cruzados entre scripts de /utilities.
2. **Diagnóstico, não Produção**: esses scripts NUNCA são chamados pelo pipeline ou pela API. Exclusivamente para uso manual em CLI.
3. **Sem Side Effects Permanentes**: scripts de `_check_*`, `validate_*`, `audit_*` devem ser read-only por padrão. Qualquer escrita deve ser explícita via flag `--apply`.

## Mapa Rápido
- `_check_db.py` — verifica conexão e estado do banco
- `_check_pos_scraping.py` — valida dados pós-coleta
- `audit_full.py` — auditoria completa (cobertura, consistência)
- `validate_e2e.py` — teste end-to-end (insere dado fake, verifica fluxo)
- `teste_apication/` — testes de aplicação (seasonality, baseline)

## Validação de Forecast
- `database/scripts/validar_forecast.py` — script de validação do modelo forecast (matriz densidade, gaps 2026, sem regressão, confiança baseline, MV)
- Executado manualmente em CLI após recálculo do baseline
- Exit 0 se OK, 1 se falha
