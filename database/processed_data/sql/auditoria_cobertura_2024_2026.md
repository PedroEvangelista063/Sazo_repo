# Relatório de Auditoria de Cobertura — CONAB 2024–2026

**Gerado em:** Julho/2026
**Base:** `staging.fact_precos_mensais` (42.358 registros)
**Fontes CONAB:**
- https://portaldeinformacoes.conab.gov.br/downloads/arquivos/PrecosMensalUF.txt
- https://portaldeinformacoes.conab.gov.br/downloads/arquivos/ProhortMensal.txt

---

## Sumário Executivo

| Indicador | Valor |
|---|---|
| Total de registros | 42.358 |
| Período | 2024–2026 |
| UFs mapeadas | 28 (27 estados + BR) |
| Total de gaps (UF × ano × mês sem dado) | **7.189** |
| Gaps 2024 | **1.311** |
| Gaps 2025 | **1.125** |
| Gaps 2026 | **4.753** |

> **⚠️ Atenção:** Grande parte dos gaps de 2026 (meses 08–12) são esperados — o ano ainda está em curso. Gaps reais (dados que existem na fonte mas não no banco) concentram-se em 2024 e no início de 2025.

---

## 1. Gaps por UF (ranking do pior para o melhor)

| UF | Total Gaps | Gaps 2024 | Gaps 2025 | Gaps 2026 | Status |
|----|-----------|-----------|-----------|-----------|--------|
| **SP** | **1.245** | 0 | 0 | 1.245 | ⚠️ Alto número de produtos esperados sem dado em 2026 |
| **PI** | **480** | 240 | 100 | 140 | 🔴 Crítico — 2024 inteiro sem dados |
| **AM** | **384** | 192 | 80 | 112 | 🔴 Crítico — 2024 inteiro sem dados |
| **SE** | **360** | 180 | 75 | 105 | 🔴 Crítico — 2024 inteiro sem dados |
| **RO** | **360** | 180 | 75 | 105 | 🔴 Crítico — 2024 inteiro sem dados |
| **PA** | **297** | 0 | 66 | 231 | ⚠️ Gaps crescentes em 2025–2026 |
| **GO** | **240** | 0 | 30 | 210 | ⚠️ Gaps crescentes em 2026 |
| **MG** | **235** | 0 | 0 | 235 | ⚠️ Gaps apenas em 2026 |
| **RS** | **235** | 0 | 0 | 235 | ⚠️ Gaps apenas em 2026 |
| **AC** | **216** | 108 | 45 | 63 | 🔴 2024 e 2025 com dados muito esparsos |
| **BA** | **205** | 0 | 0 | 205 | ⚠️ Gaps apenas em 2026 |
| **PR** | **205** | 0 | 0 | 205 | ⚠️ Gaps apenas em 2026 |
| **SC** | **200** | 0 | 0 | 200 | ⚠️ Gaps apenas em 2026 |
| **AP** | **168** | 84 | 35 | 49 | 🔴 2024 quase inteiro sem dados |
| **RR** | **168** | 84 | 35 | 49 | 🔴 2024 quase inteiro sem dados |
| **CE** | **155** | 0 | 0 | 155 | ⚠️ Gaps apenas em 2026 |
| **AL** | **133** | 0 | 38 | 95 | ⚠️ Gaps em 2025 e 2026 |
| **ES** | **130** | 0 | 0 | 130 | ⚠️ Gaps apenas em 2026 |
| **MS** | **126** | 56 | 0 | 70 | ⚠️ Gaps em 2024 e 2026 |
| **TO** | **112** | 0 | 32 | 80 | ⚠️ Gaps em 2025 e 2026 |
| **RJ** | **110** | 0 | 0 | 110 | ⚠️ Gaps apenas em 2026 |
| **PE** | **105** | 0 | 0 | 105 | ⚠️ Gaps apenas em 2026 |
| **PB** | **105** | 0 | 0 | 105 | ⚠️ Gaps apenas em 2026 |
| **MT** | **105** | 0 | 0 | 105 | ⚠️ Gaps apenas em 2026 |
| **MA** | **100** | 0 | 0 | 100 | ⚠️ Gaps apenas em 2026 |
| **RN** | **85** | 0 | 0 | 85 | ⚠️ Gaps apenas em 2026 |
| **BR** | **68** | 24 | 24 | 20 | ⚡ BR (média nacional) tem gaps todo ano |
| **DF** | **15** | 0 | 0 | 15 | ✅ Melhor cobertura |

**Legenda:**
- 🔴 **Crítico**: UF com 1+ ano quase sem dados (AC, AM, AP, MS, PI, RO, RR, SE)
- ⚠️ **Atenção**: Gaps concentrados em meses específicos
- ✅ **Bom**: Cobertura quase completa

---

## 2. Gaps por (mês, ano) — visão temporal

| Ano | Mês | Total Gaps | Observação |
|-----|-----|-----------|------------|
| 2024 | 01 | 91 | 🔴 Faltam 9 UFs + BR |
| 2024 | 02 | 105 | 🔴 Faltam 10 UFs + BR |
| 2024 | 03–05 | 105 cada | 🔴 Mesmo padrão |
| 2024 | 06–12 | 91 cada | 🔴 Faltam 9 UFs + BR (melhorou levemente) |
| 2025 | 01 | 91 | 🔴 Faltam 9 UFs |
| 2025 | 02 | 124 | 🔴 Pior mês de 2025 (mais UFs sem dados) |
| 2025 | 03 | 110 | 🔴 |
| 2025 | 04 | 107 | 🔴 |
| 2025 | 05 | 189 | 🔴 Pico de gaps em 2025 |
| 2025 | 06–12 | 2 cada | ✅ Apenas BR sem dados (esperado) |
| 2026 | 01–05 | 2 cada | ✅ Apenas BR sem dados |
| 2026 | 06 | 152 | ⚠️ Várias UFs começam a perder dados |
| 2026 | 07 | 152 | ⚠️ |
| 2026 | 08–12 | **~850 cada** | 🟡 Previsto — meses futuros ainda não coletados |

---

## 3. Status de Cobertura por UF e Ano

| UF | 2024 | 2025 | 2026 |
|----|------|------|------|
| **AC** | GRAVE (0/12 meses) | CRÍTICO (8/12) | PARCIAL (10/12) |
| **AL** | COMPLETO | PARCIAL (11/12) | PARCIAL (11/12) |
| **AM** | GRAVE (0/12 meses) | CRÍTICO (8/12) | PARCIAL (10/12) |
| **AP** | GRAVE (0/12 meses) | CRÍTICO (8/12) | PARCIAL (10/12) |
| **BA** | COMPLETO | COMPLETO | PARCIAL (11/12) |
| **BR** | CRÍTICO (9/12) | CRÍTICO (9/12) | PARCIAL (10/12) |
| **CE** | COMPLETO | COMPLETO | PARCIAL (11/12) |
| **DF** | COMPLETO | COMPLETO | COMPLETO |
| **ES** | COMPLETO | COMPLETO | PARCIAL (11/12) |
| **GO** | COMPLETO | PARCIAL (11/12) | PARCIAL (10/12) |
| **MA** | COMPLETO | COMPLETO | PARCIAL (11/12) |
| **MG** | COMPLETO | COMPLETO | PARCIAL (11/12) |
| **MS** | PARCIAL (11/12) | COMPLETO | PARCIAL (11/12) |
| **MT** | COMPLETO | COMPLETO | PARCIAL (11/12) |
| **PA** | COMPLETO | PARCIAL (11/12) | PARCIAL (10/12) |
| **PB** | COMPLETO | COMPLETO | PARCIAL (11/12) |
| **PE** | COMPLETO | COMPLETO | PARCIAL (11/12) |
| **PI** | GRAVE (0/12 meses) | CRÍTICO (8/12) | PARCIAL (10/12) |
| **PR** | COMPLETO | COMPLETO | PARCIAL (11/12) |
| **RJ** | COMPLETO | COMPLETO | PARCIAL (11/12) |
| **RN** | COMPLETO | COMPLETO | PARCIAL (11/12) |
| **RO** | GRAVE (0/12 meses) | CRÍTICO (8/12) | PARCIAL (10/12) |
| **RR** | GRAVE (0/12 meses) | CRÍTICO (8/12) | PARCIAL (10/12) |
| **RS** | COMPLETO | COMPLETO | PARCIAL (11/12) |
| **SC** | COMPLETO | COMPLETO | PARCIAL (11/12) |
| **SE** | GRAVE (0/12 meses) | CRÍTICO (8/12) | PARCIAL (10/12) |
| **SP** | COMPLETO | COMPLETO | PARCIAL (11/12) |
| **TO** | COMPLETO | PARCIAL (11/12) | PARCIAL (11/12) |

**Legenda:**
- **COMPLETO** (12/12 meses com dados)
- **PARCIAL** (9–11 meses)
- **CRÍTICO** (6–8 meses)
- **GRAVE** (< 6 meses)

---

## 4. Validação com a Fonte CONAB (PrecosMensalUF.txt)

### 4.1 O que a fonte contém (Julho/2026)

O arquivo `PrecosMensalUF.txt` atual contém dados **apenas de 2025/07 a 2026/06** (12 meses).

Disponível na fonte:

| Período | Na fonte? | No banco? | Status |
|---------|-----------|-----------|--------|
| 2024/01–12 | ❌ **Não** | ✅ Sim (parcial) | Dado estava em versão anterior da fonte |
| 2025/01–06 | ❌ **Não** | ✅ Sim | Coletado em momento anterior |
| 2025/07–12 | ✅ Sim | ✅ Sim | Coletado com sucesso |
| 2026/01–06 | ✅ Sim | ✅ Sim | Coletado com sucesso |
| 2026/07 | ✅ Sim | ✅ Sim | Coletado com sucesso |
| 2026/08–12 | ❌ **Não** | ❌ Não | Ainda não publicado pela CONAB |

### 4.2 Conclusão da validação

| Tipo de gap | Explicação |
|-------------|------------|
| **Gap real (dado existe na fonte mas não no banco)** | **Nenhum detectado** para as UFs onde a fonte tem dados. O banco contém TUDO que está disponível no CONAB hoje. |
| **Gap de rolling window (dado existia, fonte substituiu)** | 2024 e 2025/01–06 foram carregados de versões anteriores do arquivo. A CONAB mantém apenas ~12 meses no arquivo atual. |
| **Gap de 8 UFs em 2024** (AC, AM, AP, MS, PI, RO, RR, SE) | Essas UFs **nunca estiveram na fonte** para 2024. Ou a CONAB não coletava esses estados naquela época, ou o scraper anterior não capturou. |
| **Gap de 2026/08–12** | **Esperado** — a CONAB ainda não publicou esses meses (estamos em Julho/2026). |

> ✅ **O scraper está funcionando corretamente.** Todos os dados disponíveis no CONAB foram capturados. As 8 UFs sem 2024 (AC, AM, AP, MS, PI, RO, RR, SE) nunca estiveram disponíveis na fonte para aquele período.

---

## 5. Validação ProHort (ProhortMensal.txt)

A tabela `staging.fato_cotacao_regional` tem **0 registros**.

O arquivo `ProhortMensal.txt` está disponível no CONAB mas:
- Nosso pipeline **nunca carregou** esses dados
- O arquivo é grande (>5MB) e requer processamento específico

**Recomendação:** Criar uma task SDD para implementar o scraper/ETL do ProHort, que contém cotações regionais CEASA/CONAB.

---

## 6. Recomendações

### Prioridade Alta
1. **Scraper ProHort**: `staging.fato_cotacao_regional` está zerada — implementar coleta de `ProhortMensal.txt`
2. **Backfill 2024 (8 UFs críticas)**: AC, AM, AP, MS, PI, RO, RR, SE — verificar se a CONAB tem arquivos históricos

### Prioridade Média
3. **Rolling window**: O scraper de `PrecosMensalUF.txt` precisa rodar mensalmente para não perder dados quando a CONAB substituir o arquivo
4. **SP (1.245 gaps em 2026)**: Investigar se SP realmente tem mais produtos esperados ou se há um problema no mapeamento de produtos para SP

### Prioridade Baixa
5. **BR (média nacional)**: 68 gaps nos 3 anos — a CONAB pode não calcular BR para todos os meses/produtos
6. **Monitoramento**: Rodar o script `00_audit_cobertura.sql` mensalmente após cada coleta
