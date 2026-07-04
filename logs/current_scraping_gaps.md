# Relatório de Gap Analysis — SmartCrawler2026

**Gerado em:** 2026-07-03 14:30:22
**Versão alvo:** v1.0.0-rc1

## [MÉTRICAS GLOBAIS]

| Métrica | Valor |
|---------|-------|
| Fontes ativas monitoradas | 12 |
| Fontes com dados nos últimos 7d | 8 |
| Fontes com 0 cotações | 1 |
| Fontes em silêncio total | 3 |
| Taxa de sucesso por fonte | 66.7% |

| Volume bruto estimado (último batch) | 2,847 |
| Registros retidos no staging | 1,932 |
| Taxa de conversão (bruto → staging) | 67.86% |
| Total itens descartados (log) | 915 |
| Total histórico na fact_precos_mensais | 84,221 |

| Produtos ALIMENTO_VAREJO na dim | 187 |
| Nunca coletados (zero dados) | 23 |
| Órfãos sem atualização nos últimos 30d | 41 |
| Data da coleta mais recente | 2026-07-03 11:19:14 |

## [ALERTA DE FONTES]

### Fontes com problemas (últimos 7 dias)

| Fonte | Adapter | Categoria | UF | Status | Qtd Linhas | Última Coleta |
|-------|---------|-----------|----|--------|------------|----------------|
| CEAGESP (SP-Sao Paulo) | PlaywrightStealthAdapter | b_stealth | SP | SILENCIO | 0 | N/A |
| CEPEA Banco de Dados (SP-Piracicaba) | LegacyPostbackAdapter | c_postback | SP | SILENCIO | 0 | N/A |
| CEASA ES (ES-Vitoria) | AgenticHtmlAdapter | d_agentic | ES | SILENCIO | 0 | N/A |
| CEASA MS Boletins (MS-Campo Grande) | AgenticHtmlAdapter | d_agentic | MS | ZERO | 0 | 2026-07-03 08:35:30 |

### ⚠️ Atenção especial: fontes em silêncio total

- **CEAGESP (SP-Sao Paulo)** — adapter `PlaywrightStealthAdapter` (cat. b_stealth)
  - 68+ snapshots de falha em `logs/scraping_failures/` — CEAGESP mudou o layout ou ativou WAF mais agressivo.
- **CEPEA Banco de Dados (SP-Piracicaba)** — adapter `LegacyPostbackAdapter` (cat. c_postback)
  - ASP.NET WebForms — provável mudança nos parâmetros `__VIEWSTATE` ou `__EVENTVALIDATION`.
- **CEASA ES (ES-Vitoria)** — adapter `AgenticHtmlAdapter` (cat. d_agentic)
  - Resposta < 1KB — servidor pode estar retornando página de erro ou redirecionamento.

**Ação sugerida:** Priorizar revisão do adapter CEAGESP (maior volume perdido). Depurar manualmente a URL `https://ceagesp.gov.br/cotacoes/` para identificar a mudança estrutural.

### ⚠️ Fontes retornando 0 cotações

- **CEASA MS Boletins (MS-Campo Grande)** — adapter executou mas retornou 0 linhas
  - Fonte baseada em galeria de PDFs — o parser de links de PDF pode estar com o seletor desatualizado para 2026.

## [OPORTUNIDADES DE ALIAS]

| # | Produto Original | Ocorrências | Best Match | Score | Sugestão para aliases.json |
|---|------------------|-------------|------------|-------|---------------------------|
| 1 | FLORES COMESTIVEIS | 60x | — | 0.0 | — |
| 2 | AÇAFRÃO CURCUMA bj 300 g | 8x | — | 0.0 | — |
| 3 | AÇAFRÃO CURCUMA cx 20 kg | 8x | — | 0.0 | — |
| 4 | ATIPICOS kg | 8x | — | 0.0 | — |
| 5 | KINKAN cx 2 kg | 8x | — | 0.0 | — |
| 6 | MAÇA BELGOLDEM cx 18 kg | 8x | maçã | 65.3 | `{"maca belgoldem": "maçã"}` |
| 7 | PIMENTÃO COLORIDO EXTRA AA cx 12 kg | 8x | pimentão | 67.1 | `{"pimentao colorido extra aa": "pimentão"}` |
| 8 | QUEIJO kg | 8x | — | 0.0 | — |
| 9 | RADITE mc 400 g | 8x | — | 0.0 | — |
| 10 | FORRAGEM | 4x | — | 0.0 | — |
| 11 | FLORES kg | 3x | — | 0.0 | — |
| 12 | MAÇA GRAND SMITH TP 80 A 100 cx 18 kg | 3x | maçã | 61.8 | `{"maca grand smith": "maçã"}` |
| 13 | Noticia do site rs | 2x | — | 0.0 | — |

**Impacto estimado:** Cada entrada adicionada no `aliases.json` recupera em média 153 itens por execução.

### Top 15 produtos descartados pelo Normalizer

| Produto Original | Ocorrências | Best Match | Score | Já possui alias? |
|------------------|-------------|------------|-------|-------------------|
| FLORES COMESTIVEIS | 60x | — | 0.0 | ❌ |
| 2017 download | 476x | — | 0.0 | ❌ |
| 2018 download | 474x | — | 0.0 | ❌ |
| 2023 download | 400x | — | 0.0 | ❌ |
| 2020 download | 372x | — | 0.0 | ❌ |
| 2015 download | 288x | — | 0.0 | ❌ |
| 2022 download | 250x | — | 0.0 | ❌ |
| 2021 download | 242x | — | 0.0 | ❌ |
| 2016 download | 242x | — | 0.0 | ❌ |
| 2019 download | 224x | — | 0.0 | ❌ |
| 24 download | 40x | — | 0.0 | ❌ |
| AÇAFRÃO CURCUMA bj 300 g | 8x | — | 0.0 | ❌ |
| AÇAFRÃO CURCUMA cx 20 kg | 8x | — | 0.0 | ❌ |
| ATIPICOS kg | 8x | — | 0.0 | ❌ |
| KINKAN cx 2 kg | 8x | — | 0.0 | ❌ |

**Nota:** Os itens `201X download` e `24 download` são artefatos do parser CEAGESP — o HTML contém links de download de boletins anuais que o normalizador tenta interpretar como produtos. A correção deve ser no adapter CEAGESP, não no normalizador.

## [PRODUTOS ÓRFÃOS]

### Top 10 produtos ALIMENTO_VAREJO sem atualização nos últimos 30 dias

| ID | Produto | Última Atualização | Último Período |
|----|---------|-------------------|----------------|
| 112 | CARNE MOIDA | NUNCA | N/A |
| 87 | ERVA MATE CHIMARRAO | NUNCA | N/A |
| 145 | PAO FRANCES | NUNCA | N/A |
| 38 | FLOCOS DE MILHO | NUNCA | N/A |
| 201 | FRANGO CONGELADO | 2026-05-15 | 202605 |
| 73 | ARROZ PARBOILIZADO | 2026-05-10 | 202605 |
| 29 | FEIJAO PRETO | 2026-05-08 | 202604 |
| 156 | REPOLHO ROXO | 2026-04-20 | 202604 |
| 44 | COUVE-FLOR | 2026-04-15 | 202604 |
| 91 | BATATA DOCE ROSADA | 2026-04-02 | 202604 |

### Nunca coletados (existem na dim_produto mas sem nenhum registro na fact)

**Total:** 23 produtos — são itens cadastrados que o scraper nunca conseguiu mapear para nenhuma cotação real. Inclui itens como `CARNE MOIDA`, `ERVA MATE CHIMARRAO`, `PAO FRANCES`, `FLOCOS DE MILHO` — que existem na tabela CONAB mas não são cobertos por nenhuma CEASA ou fonte hortifrúti regional.

**Ação sugerida:** Verificar se esses produtos têm fontes mapeadas em `config/sources_map.json` ou se são itens órfãos da importação CONAB que não existem no mundo real do varejo hortifrúti.

---

*Relatório gerado automaticamente por `report_engine_gaps.py`*
*Pipeline: quero_comprar_vg | SmartCrawler2026*
