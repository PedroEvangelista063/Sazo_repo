# Plano de Implementação: Arquitetura de Micro-Motores

## 1. Diagnóstico do Estado Atual

### Problemas Identificados

| Problema | Localização | Impacto |
|----------|-------------|---------|
| Dispatcher genérico usa `BaseAdapter.fetch()` sem schema | `pipeline/scraper/dispatcher.py` | Qualquer lixo HTML vira `CotacaoRegional` |
| `CotacaoRegional` é dataclass sem validação | `pipeline/scraper/adapters/base.py:48` | Campos vazios, strings truncadas, floats NaN passam batido |
| Sem Pydantic no pipeline de coleta | Só existe em `backend/app/schemas/` | Dados sujos chegam ao banco, normalizer vira gargalo |
| Circuit breaker inexistente | `dispatcher.py:137` — semáforo único | CEASA-MG falhando trava semáforo compartilhado |
| WAF saturation sem rate-limit por domínio | `smart_router.py` | Múltiplas URLs do mesmo domínio disparam WAFs |

## 2. Arquitetura-Alvo

```
                           ┌──────────────────┐
                           │   Task Queue      │
                           │  (URL + Regra)    │
                           └────────┬─────────┘
                                    │
                           ┌────────▼─────────┐
                           │   MicroDispatcher │
                           │  (Router L3)     │
                           └──┬──────┬──────┬──┘
                              │      │      │
                    ┌─────────▼┐ ┌──▼───┐ ┌▼─────────┐
                    │MicroMotor│ │Motor │ │ Motor     │
                    │ CEASA-SP │ │CONAB │ │ CEPEA     │
                    │          │ │      │ │           │
                    │ Semaphore│ │Semaph│ │ Semaphore │
                    │ Pydantic │ │Pydant│ │ Pydantic  │
                    │ CBreaker │ │CBreak│ │ CBreaker  │
                    └────┬─────┘ └──┬───┘ └─────┬─────┘
                         │          │            │
                    ┌────▼──────────▼────────────▼──┐
                    │      Pydantic Guard (Sink)     │
                    │  Rejeita: header, footer, lixo │
                    └───────────────┬────────────────┘
                                    │
                           ┌────────▼─────────┐
                           │     PostgreSQL    │
                           │  (Apenas dados    │
                           │   validados)      │
                           └──────────────────┘
```

### Camadas

- **MicroDispatcher** (`dispatcher_v2.py`): Router que mapeia URL → MicroMotor. Sem stateful.
- **MicroMotor** (`motores/`): Classe abstrata com `fetch() -> PydanticModel`. Cada motor = 1 domínio.
- **PydanticGuard** (`schemas/coleta/`): Schema estrito por categoria de site.
- **CircuitBreaker** (`circuit_breaker.py`): Decorator/context manager com sliding window.
- **RateLimiter** (`rate_limiter.py`): Semáforo por domínio (não global).

## 3. Plano de Implementação (6 Fases)

### Fase 1: Pydantic Schemas de Coleta (Foundation)

**Arquivos a criar:**
- `pipeline/scraper/schemas/__init__.py`
- `pipeline/scraper/schemas/coleta.py` — schemas base

**Arquivos a modificar:**
- Nenhum (camada nova, sem breaking change)

**Conteúdo de `coleta.py`:**
```python
from pydantic import BaseModel, Field, field_validator
from datetime import date
import re

class CotacaoColeta(BaseModel):
    produto_original: str = Field(..., min_length=1, max_length=200)
    uf: str = Field(..., pattern=r'^[A-Z]{2}$')
    municipio: str = Field(..., min_length=1)
    ano: int = Field(..., ge=2000, le=2100)
    mes: int = Field(..., ge=1, le=12)
    fonte: str = Field(..., min_length=1)
    preco_bruto: float = Field(..., gt=0)
    fator_kg: float = Field(default=1.0, gt=0)
    data_coleta: str = Field(default_factory=lambda: date.today().isoformat())

    @field_validator('preco_bruto')
    @classmethod
    def rejeitar_fora_limite(cls, v):
        if v > 10_000:  # preço bruto >10k é lixo (header/footer)
            raise ValueError(f'preco_bruto {v} fora do limite realista')
        return v

class CotacaoNormalizada(CotacaoColeta):
    produto_normalizado: str = Field(..., min_length=1)
    categoria_b2c: str | None = None
    preco_medio: float | None = None
    preco_min: float | None = None
    preco_max: float | None = None

class ResultadoMotor(BaseModel):
    motor: str
    fonte: str
    uf: str
    municipio: str
    cotacoes: list[CotacaoColeta]
    status: str = 'sucesso'
    erro: str = ''
    tempo_s: float = 0.0
```

**Critério de aceite:**
- `CotacaoColeta` rejeita strings vazias, UF != 2 chars, ano < 2000, preco_bruto <= 0
- `field_validator` de `preco_bruto` bloqueia valores >10k (header/footer leakage)
- `pytest pipeline/tests/test_schemas_coleta.py` passa

### Fase 2: Circuit Breaker + Rate Limiter

**Arquivos a criar:**
- `pipeline/scraper/circuit_breaker.py`
- `pipeline/scraper/rate_limiter.py`

**Circuit Breaker (`circuit_breaker.py`):**
```
- Estados: CLOSED → OPEN (após N falhas consecutivas) → HALF_OPEN (após timeout)
- Sliding window: 5 falhas em 60s → OPEN por 120s
- Thread-safe (asyncio.Lock)
- OPEN retorna CircuitBreakerOpenError sem executar
```

**Rate Limiter (`rate_limiter.py`):**
```
- Dict[domínio, Semaphore] — lazy init
- Máx 3 requisições concorrentes por domínio
- Diferente do semáforo global atual: um por domínio
```

**Arquivos a modificar:**
- Nenhum (novos módulos, sem dependências existentes ainda)

### Fase 3: MicroMotor Abstract + Implementações

**Arquivos a criar:**
- `pipeline/scraper/motores/__init__.py`
- `pipeline/scraper/motores/base.py` — classe abstrata
- `pipeline/scraper/motores/ceagesp.py`
- `pipeline/scraper/motores/cepea.py`
- `pipeline/scraper/motores/conab.py`
- `pipeline/scraper/motores/ceasa_pr.py`
- `pipeline/scraper/motores/ceasa_generico.py`

**MicroMotor Base (`base.py`):**
```python
class MicroMotor(ABC):
    dominio: str = ''
    fonte: str = ''
    uf: str = ''
    municipio: str = ''

    def __init__(self):
        self._cb = CircuitBreaker(nome=self.__class__.__name__)
        self._rl = RateLimiter()
        self._schema: type[CotacaoColeta] = CotacaoColeta

    @abstractmethod
    async def fetch(self) -> ResultadoMotor: ...

    async def executar(self) -> ResultadoMotor:
        if self._cb.esta_aberto:
            return ResultadoMotor(... status='circuit_open')
        async with self._rl.para_dominio(self.dominio):
            try:
                return await self.fetch()
            except Exception as e:
                self._cb.registrar_falha()
                raise
```

**Cada motor implementa** `fetch()` usando seu próprio adapter (Playwright, httpx, etc) e valida cada cotação com `self._schema.model_validate()`.

### Fase 4: MicroDispatcher V2

**Arquivos a criar:**
- `pipeline/scraper/dispatcher_v2.py`

**Arquivos a modificar:**
- `pipeline/scraper/__init__.py` (expor novo dispatcher)

**Dispatcher V2:**
```python
REGISTRY: dict[str, type[MicroMotor]] = {
    'CEAGESP': CeagespMotor,
    'CEPEA': CepeaMotor,
    'CONAB-ProHort': ConabMotor,
    'CEASA-PR': CeasaPRMotor,
}

class MicroDispatcher:
    def registrar_motor(self, nome: str, motor_cls: type[MicroMotor]): ...
    async def executar(self, url: str, fonte: str) -> ResultadoMotor: ...
    async def executar_multiplos(self, alvos: list[dict]) -> list[ResultadoMotor]: ...
```

- `executar_multiplos` roda motores em paralelo, mas cada um com seu CB + RL
- Se um motor falha com circuit_open, os outros continuam normalmente

### Fase 5: Integração com Sink (PostgreSQL)

**Arquivos a modificar:**
- `pipeline/ingest.py` ou `pipeline/load.py` (sink atual)

**Mudanças:**
- Sink recebe `list[CotacaoColeta]` (já validado por Pydantic)
- Antes de INSERT, aplica `CotacaoNormalizada.model_validate()` como dupla verificação
- Rejeitados vão para `logs/rejected_coleta.log` com motivo

### Fase 6: Migração Gradual + Testes

**Estratégia de migração:**
1. Fase 1-2: Deploy sem mudança de comportamento (schemas + CB existem mas não são usados)
2. Fase 3: Criar motores em paralelo com adapters existentes — modo "shadow" (log-only)
3. Fase 4: Dispatcher V2 roda em paralelo com V1 — comparar outputs
4. Fase 5: Troca o sink, V1 desligado

**Testes:**
- `pipeline/tests/test_circuit_breaker.py` — 10 cenários
- `pipeline/tests/test_rate_limiter.py` — 5 cenários
- `pipeline/tests/test_motores/` — 1 arquivo por motor
- `pipeline/tests/test_dispatcher_v2.py` — routing + isolamento

## 4. Riscos e Mitigações

| Risco | Probabilidade | Mitigação |
|-------|--------------|-----------|
| Motor Playwright + Motor httpx no mesmo processo conflitam | Média | Separar event loops ou usar processo dedicado para Playwright (`concurrent.futures`) |
| Circuit breaker OPEN atrapalha debugging | Baixa | Log com alerta + endpoint `/admin/cb/reset` |
| Pydantic validation overhead em lote grande (10k+ cotações) | Baixa | Usar `model_validate(many=True)` ou chunking |
| Schema muda e motores legacy quebram | Média | Schema versionado (`CotacaoColetaV1`, `CotacaoColetaV2`) com `model_config(extra='forbid')` |

## 5. Métricas de Sucesso

- [ ] Cobertura de Pydantic schemas: 100% dos campos validados
- [ ] Circuit breaker isola falhas: 0 propagação entre motores
- [ ] WAF rate-limit: máximo 3 reqs concorrentes/domínio
- [ ] Dados rejeitados: >90% dos falsos positivos (header/footer) eliminados antes do DB
- [ ] Migração shadow: 0 diferenças entre V1 e V2 por 2 ciclos de coleta