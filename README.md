# 🗺️ Sazo Brasil — Inteligência Sazonal de Hortifrúti

> **Sazo Brasil** é uma aplicação web progressiva (PWA) desenvolvida para transformar a decisão de compra de alimentos hortigranjeiros no Brasil através de análises visuais de sazonalidade e fluxos de abastecimento inter-regionais.

---

## 🌟 Destaques do Produto

- **🗺️ Pivot Mapa Regional Interativo**: Navegação geográfica tátil cobrindo as 27 UFs e 5 regiões do Brasil, integrando vetores animantes de recebimento e envio de alimentos.
- **🔍 Busca Inteligente Glassmorphism**: Pesquisa fuzzy de produtos com tolerância a acentuação e digitação, apresentando resultados em modais flutuantes com agrupamento por estado.
- **🟢 Semáforo Visual de Preços (Zero R$)**: A interface adota a regra de negócio B2C de nunca exibir valores monetários em R$, utilizando apenas uma classificação visual de oportunidade (_Barato_, _Normal_, _Caro_).
- **🎨 Design System Claymorphism & Dark Mode**: Experiência visual tátil com sombras tridimensionais, suporte completo a mobile-first (320px) e transições fluidas via Framer Motion.
- **⚡ Arquitetura Offline-First PWA**: Service Workers otimizados para carregamento instantâneo e resiliência sem conexão à rede.

---

## 🛠️ Tecnologias Utilizadas

### Frontend

- **Core**: React 19, TypeScript, Vite PWA (Workbox)
- **Estilização & UI**: TailwindCSS 3, shadcn/ui, Claymorphism Design System
- **Animações**: Framer Motion, Motion Primitives
- **Gerenciamento de Estado**: Zustand 5, TanStack Query v5

### Backend & Banco de Dados

- **API**: FastAPI (Python 3.13+), Asyncpg, Pydantic v2
- **Banco de Dados**: PostgreSQL 16 (Views Materializadas, RLS Security Layer)
- **Resiliência**: Dual-Environment (Active Cloud Remote / Standby Local Fallback)

---

## 🏗️ Arquitetura

```
┌─────────────────────────────────────────────────────┐
│                    Frontend (PWA)                     │
│  React 19 · Zustand · TanStack Query · Framer Motion │
│  TailwindCSS · shadcn/ui · Workbox Service Worker    │
└──────────────────────┬──────────────────────────────┘
                       │ HTTPS (CORS)
┌──────────────────────▼──────────────────────────────┐
│                  Backend (API)                        │
│  FastAPI · Pydantic v2 · Rate Limit · Timeout        │
│  Security Headers · CORS hardened                     │
└──────────────────────┬──────────────────────────────┘
                       │ asyncpg (SSL)
┌──────────────────────▼──────────────────────────────┐
│              PostgreSQL 16 (Aiven)                    │
│  Materialized Views · RLS · role_api_reader           │
│  Dual-Environment: Cloud (Primary) / Local (Fallback) │
└─────────────────────────────────────────────────────┘
```

---

## 🔒 Segurança

- **RLS (Row Level Security)**: `role_api_reader` com permissões mínimas (SELECT-only em `mart`)
- **Security Headers**: X-Content-Type-Options, X-Frame-Options, Referrer-Policy, Permissions-Policy
- **CORS Hardened**: Métodos restritos (GET/POST/OPTIONS), origens whitelistadas
- **Rate Limiting**: 60 req/min por IP com janela deslizante
- **Statement Timeout**: 29s no nível da sessão PostgreSQL
- **Zero R$ expostos**: Interface B2C que nunca exibe valores monetários

---

## 📊 Dados

- **Fonte**: CONAB (Companhia Nacional de Abastecimento) + Ceasas regionais
- **Cobertura**: 27 UFs brasileiras, ~350 produtos hortifrúti
- **Janela Temporal**: 2024-01 a 2026-12
- **Atualização**: Pipeline ETL automatizado com refresh de Materialized Views

---

## 📸 Interface

A aplicação apresenta três modos de visualização:

1. **🗺️ Mapa**: Navegação regional com vetores de fluxo de abastecimento
2. **📄 Cards**: Grade de produtos com semáforo visual de sazonalidade
3. **📊 Tabela**: Grade sazonal completa com percentuais de cobertura

---

## 📄 Licença

Propriedade intelectual. Código-fonte disponibilizado exclusivamente para fins de portfólio e demonstração de capacidades técnicas.

---

> _Desenvolvido com ❤️._
