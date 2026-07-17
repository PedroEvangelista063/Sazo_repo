-- ============================================================================
-- Migration 001: Create Schemas (Medalhão Architecture)
-- raw: dados brutos (bronze)
-- staging: dados limpos, tipados (silver)
-- mart: regras de negócio, visão API (gold)
-- ops: operações, quarentena
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS staging;
CREATE SCHEMA IF NOT EXISTS mart;
CREATE SCHEMA IF NOT EXISTS ops;
