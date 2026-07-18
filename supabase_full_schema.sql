


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "mart";


ALTER SCHEMA "mart" OWNER TO "postgres";


CREATE SCHEMA IF NOT EXISTS "ops";


ALTER SCHEMA "ops" OWNER TO "postgres";


CREATE SCHEMA IF NOT EXISTS "raw";


ALTER SCHEMA "raw" OWNER TO "postgres";


CREATE SCHEMA IF NOT EXISTS "staging";


ALTER SCHEMA "staging" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "staging"."_gerar_batch_id"() RETURNS "uuid"
    LANGUAGE "sql"
    AS $$
    SELECT gen_random_uuid();
$$;


ALTER FUNCTION "staging"."_gerar_batch_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "staging"."_parse_conab_price"("p_texto" "text") RETURNS numeric
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
BEGIN
    IF p_texto IS NULL OR trim(p_texto) = '' THEN
        RETURN NULL;
    END IF;
    RETURN NULLIF(replace(trim(p_texto), ',', '.'), '')::NUMERIC(14,4);
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$;


ALTER FUNCTION "staging"."_parse_conab_price"("p_texto" "text") OWNER TO "postgres";


CREATE PROCEDURE "staging"."sp_calcular_sazonalidade"(IN "p_ano_alvo" smallint DEFAULT NULL::smallint, IN "p_mes_alvo" smallint DEFAULT NULL::smallint)
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_ano   SMALLINT;
    v_mes   SMALLINT;
    v_inicio TIMESTAMPTZ;
    v_fim    TIMESTAMPTZ;
    v_total  INTEGER;
BEGIN
    v_inicio := clock_timestamp();

    IF p_ano_alvo IS NULL OR p_mes_alvo IS NULL THEN
        SELECT MAX(ano), MAX(mes) INTO v_ano, v_mes
        FROM staging.fact_precos_mensais;
    ELSE
        v_ano := p_ano_alvo;
        v_mes := p_mes_alvo;
    END IF;

    RAISE NOTICE '[sp_calcular_sazonalidade] Alvo: %-%', v_ano, v_mes;

    INSERT INTO mart.sazonalidade_produto (
        id_produto, id_localidade, ano, mes,
        preco_medio, media_movel_12m, indice_sazonalidade,
        status_cor, fonte, calculado_em
    )
    WITH precos_12m AS (
        SELECT
            f.id_produto,
            f.id_localidade,
            f.ano,
            f.mes,
            f.preco_medio,
            AVG(f.preco_medio) OVER (
                PARTITION BY f.id_produto, f.id_localidade
                ORDER BY f.ano, f.mes
                ROWS BETWEEN 11 PRECEDING AND CURRENT ROW
            ) AS media_movel_12m,
            COUNT(*) OVER (
                PARTITION BY f.id_produto, f.id_localidade
                ORDER BY f.ano, f.mes
                ROWS BETWEEN 11 PRECEDING AND CURRENT ROW
            ) AS meses_no_window
        FROM staging.fact_precos_mensais f
        WHERE (f.ano < v_ano OR (f.ano = v_ano AND f.mes <= v_mes))
    )
    SELECT
        p.id_produto,
        p.id_localidade,
        p.ano,
        p.mes,
        p.preco_medio,
        p.media_movel_12m,
        CASE
            WHEN p.media_movel_12m IS NOT NULL AND p.media_movel_12m > 0
            THEN ROUND(p.preco_medio / p.media_movel_12m, 4)
            ELSE NULL
        END AS indice_sazonalidade,
        CASE
            WHEN p.meses_no_window < 6 THEN 'INSUFICIENTE'
            WHEN p.media_movel_12m IS NULL OR p.media_movel_12m = 0 THEN 'INSUFICIENTE'
            WHEN (p.preco_medio / p.media_movel_12m) < 0.85 THEN 'VERDE'
            WHEN (p.preco_medio / p.media_movel_12m) > 1.15 THEN 'VERMELHO'
            ELSE 'AMARELO'
        END AS status_cor,
        'municipio' AS fonte,
        NOW() AS calculado_em
    FROM precos_12m p
    WHERE p.ano = v_ano AND p.mes = v_mes
        AND p.preco_medio IS NOT NULL
    ON CONFLICT (id_produto, id_localidade, ano, mes)
    DO UPDATE SET
        preco_medio         = EXCLUDED.preco_medio,
        media_movel_12m     = EXCLUDED.media_movel_12m,
        indice_sazonalidade = EXCLUDED.indice_sazonalidade,
        status_cor          = EXCLUDED.status_cor,
        calculado_em        = NOW();

    GET DIAGNOSTICS v_total = ROW_COUNT;
    v_fim := clock_timestamp();

    RAISE NOTICE '[sp_calcular_sazonalidade] Concluído: % linhas em % seg',
        v_total, ROUND(EXTRACT(EPOCH FROM v_fim - v_inicio)::NUMERIC, 2);
END;
$$;


ALTER PROCEDURE "staging"."sp_calcular_sazonalidade"(IN "p_ano_alvo" smallint, IN "p_mes_alvo" smallint) OWNER TO "postgres";


COMMENT ON PROCEDURE "staging"."sp_calcular_sazonalidade"(IN "p_ano_alvo" smallint, IN "p_mes_alvo" smallint) IS 'Calcula média móvel 12m e classifica semáforo por produto+localidade';



CREATE PROCEDURE "staging"."sp_executar_carga_completa"()
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_inicio TIMESTAMPTZ;
    v_fim    TIMESTAMPTZ;
    v_ultimo_ano  SMALLINT;
    v_ultimo_mes  SMALLINT;
    v_total_fato  INTEGER;
    v_total_saz   INTEGER;
BEGIN
    v_inicio := clock_timestamp();
    RAISE NOTICE '[sp_executar_carga_completa] Iniciando...';

    ANALYZE staging.fact_precos_mensais;

    SELECT MAX(ano), MAX(mes) INTO v_ultimo_ano, v_ultimo_mes
    FROM staging.fact_precos_mensais;

    CALL staging.sp_calcular_sazonalidade(v_ultimo_ano, v_ultimo_mes);

    REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;

    v_fim := clock_timestamp();
    RAISE NOTICE '[sp_executar_carga_completa] Concluído em % seg',
        ROUND(EXTRACT(EPOCH FROM v_fim - v_inicio)::NUMERIC, 2);
END;
$$;


ALTER PROCEDURE "staging"."sp_executar_carga_completa"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "staging"."trg_valida_anomalia_preco"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_media_historica NUMERIC(14,4);
    v_dados_brutos    JSONB;
BEGIN
    SELECT AVG(preco_medio) INTO v_media_historica
    FROM staging.fact_precos_mensais
    WHERE id_produto    = NEW.id_produto
      AND id_localidade = NEW.id_localidade
      AND NOT (ano = NEW.ano AND mes = NEW.mes);

    IF v_media_historica IS NULL THEN
        RETURN NEW;
    END IF;

    IF NEW.preco_medio > (v_media_historica * 5.0) THEN
        v_dados_brutos := jsonb_build_object(
            'produto_id',   NEW.id_produto,
            'localidade_id', NEW.id_localidade,
            'ano',          NEW.ano,
            'mes',          NEW.mes,
            'preco_enviado', NEW.preco_medio,
            'media_historica', v_media_historica
        );

        INSERT INTO staging.precos_rejeitados (
            id_produto, id_localidade, ano, mes,
            preco_medio, preco_medio_historico, razao,
            dados_brutos, batch_id
        ) VALUES (
            NEW.id_produto, NEW.id_localidade, NEW.ano, NEW.mes,
            NEW.preco_medio, v_media_historica,
            'Preço excede 500% da média histórica — possível erro de digitação',
            v_dados_brutos, NEW.batch_id
        );

        RETURN NULL;
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION "staging"."trg_valida_anomalia_preco"() OWNER TO "postgres";


COMMENT ON FUNCTION "staging"."trg_valida_anomalia_preco"() IS 'Desvia para quarentena preços >500% da média histórica do mesmo produto+localidade';


SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "mart"."sazonalidade_baseline_24_25" (
    "id_produto" integer NOT NULL,
    "id_localidade" integer NOT NULL,
    "mes" integer NOT NULL,
    "status_cor_mode" "text" NOT NULL,
    "confianca" numeric(5,2),
    "fonte" "text" DEFAULT 'BASELINE_24_25'::"text",
    "atualizado_em" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "mart"."sazonalidade_baseline_24_25" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "mart"."sazonalidade_baseline_25_26" (
    "id_produto" integer NOT NULL,
    "id_localidade" integer NOT NULL,
    "mes" integer NOT NULL,
    "status_cor_mode" "text" NOT NULL,
    "confianca" numeric(5,2),
    "fonte" "text" DEFAULT 'BASELINE_25_26'::"text",
    "atualizado_em" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "mart"."sazonalidade_baseline_25_26" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "mart"."sazonalidade_produto" (
    "id_sazonalidade" bigint NOT NULL,
    "id_produto" integer NOT NULL,
    "id_localidade" integer NOT NULL,
    "ano" smallint NOT NULL,
    "mes" smallint NOT NULL,
    "preco_medio" numeric(14,4) NOT NULL,
    "media_movel_12m" numeric(14,4),
    "indice_sazonalidade" numeric(8,4),
    "status_cor" "text" NOT NULL,
    "fonte" "text" DEFAULT 'municipio'::"text" NOT NULL,
    "calculado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "is_forecast" boolean DEFAULT false,
    "tendencia_futura" "text",
    "baseline_confianca" numeric(5,2) DEFAULT 0,
    "forecast_method" "text",
    CONSTRAINT "chk_forecast_method" CHECK ((("forecast_method" IS NULL) OR ("forecast_method" = ANY (ARRAY['gamma_forecast_baseline'::"text", 'alpha_baseline_25_26'::"text", 'beta_media_disponivel'::"text", 'beta_weighted_25_24'::"text"])))),
    CONSTRAINT "sazonalidade_produto_fonte_check" CHECK (("fonte" = ANY (ARRAY['municipio'::"text", 'uf'::"text"]))),
    CONSTRAINT "sazonalidade_produto_forecast_method_check" CHECK ((("forecast_method" IS NULL) OR ("forecast_method" = ANY (ARRAY['gamma_forecast_baseline'::"text", 'alpha_baseline_25_26'::"text", 'beta_media_disponivel'::"text", 'beta_weighted_25_24'::"text"])))),
    CONSTRAINT "sazonalidade_produto_mes_check" CHECK ((("mes" >= 1) AND ("mes" <= 12))),
    CONSTRAINT "sazonalidade_produto_status_cor_check" CHECK (("status_cor" = ANY (ARRAY['VERDE'::"text", 'AMARELO'::"text", 'VERMELHO'::"text", 'INSUFICIENTE'::"text"])))
);


ALTER TABLE "mart"."sazonalidade_produto" OWNER TO "postgres";


COMMENT ON COLUMN "mart"."sazonalidade_produto"."is_forecast" IS 'TRUE = projeção, FALSE = dado real';



COMMENT ON COLUMN "mart"."sazonalidade_produto"."baseline_confianca" IS 'Confiança efetiva (0-100)';



COMMENT ON COLUMN "mart"."sazonalidade_produto"."forecast_method" IS 'Método de geração: NULL=dado real';



CREATE SEQUENCE IF NOT EXISTS "mart"."sazonalidade_produto_id_sazonalidade_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "mart"."sazonalidade_produto_id_sazonalidade_seq" OWNER TO "postgres";


ALTER SEQUENCE "mart"."sazonalidade_produto_id_sazonalidade_seq" OWNED BY "mart"."sazonalidade_produto"."id_sazonalidade";



CREATE TABLE IF NOT EXISTS "staging"."dim_localidade" (
    "id_localidade" integer NOT NULL,
    "uf" character(2) NOT NULL,
    "municipio_id" "text",
    "municipio_nome" "text",
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "staging"."dim_localidade" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "staging"."dim_produto" (
    "id_produto" integer NOT NULL,
    "nome_produto" "text" NOT NULL,
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "staging"."dim_produto" OWNER TO "postgres";


CREATE MATERIALIZED VIEW "mart"."vw_api_produtos_sazonalidade" AS
 SELECT "s"."id_sazonalidade",
    "p"."nome_produto" AS "produto",
    "l"."uf",
    "l"."municipio_nome" AS "municipio",
    "l"."municipio_id",
    "s"."ano",
    "s"."mes",
    "s"."preco_medio",
    "s"."media_movel_12m",
    "s"."indice_sazonalidade",
    "s"."status_cor",
    "s"."fonte",
    "s"."calculado_em"
   FROM (("mart"."sazonalidade_produto" "s"
     JOIN "staging"."dim_produto" "p" ON (("p"."id_produto" = "s"."id_produto")))
     JOIN "staging"."dim_localidade" "l" ON (("l"."id_localidade" = "s"."id_localidade")))
  WHERE ("s"."status_cor" <> 'INSUFICIENTE'::"text")
  ORDER BY "s"."ano" DESC, "s"."mes" DESC, "p"."nome_produto"
  WITH NO DATA;


ALTER MATERIALIZED VIEW "mart"."vw_api_produtos_sazonalidade" OWNER TO "postgres";


COMMENT ON MATERIALIZED VIEW "mart"."vw_api_produtos_sazonalidade" IS 'View única para a API consultar — contém produto, localidade e status do semáforo';



CREATE TABLE IF NOT EXISTS "ops"."audit_llm_queries" (
    "id" integer NOT NULL,
    "query_text" "text" NOT NULL,
    "response" "jsonb",
    "executado_em" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "ops"."audit_llm_queries" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "ops"."audit_llm_queries_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "ops"."audit_llm_queries_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "ops"."audit_llm_queries_id_seq" OWNED BY "ops"."audit_llm_queries"."id";



CREATE TABLE IF NOT EXISTS "ops"."config_agente" (
    "id" integer NOT NULL,
    "chave" "text" NOT NULL,
    "valor" "jsonb" NOT NULL,
    "descricao" "text",
    "atualizado_em" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "ops"."config_agente" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "ops"."config_agente_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "ops"."config_agente_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "ops"."config_agente_id_seq" OWNED BY "ops"."config_agente"."id";



CREATE TABLE IF NOT EXISTS "ops"."controle_erros_ddl" (
    "id" integer NOT NULL,
    "script" "text" NOT NULL,
    "erro" "text" NOT NULL,
    "executado_em" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "ops"."controle_erros_ddl" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "ops"."controle_erros_ddl_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "ops"."controle_erros_ddl_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "ops"."controle_erros_ddl_id_seq" OWNED BY "ops"."controle_erros_ddl"."id";



CREATE TABLE IF NOT EXISTS "ops"."quarentena_coleta" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "raw_id" "uuid" NOT NULL,
    "motivo_falha" "text" NOT NULL,
    "data_rejeicao" timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


ALTER TABLE "ops"."quarentena_coleta" OWNER TO "postgres";


COMMENT ON TABLE "ops"."quarentena_coleta" IS 'Registro de itens rejeitados pela esteira de triagem';



CREATE TABLE IF NOT EXISTS "raw"."coleta_bruta" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "fonte_id" character varying(128) NOT NULL,
    "payload_bruto" "jsonb" NOT NULL,
    "data_coleta" timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    "competencia_alvo" character varying(7) NOT NULL,
    "processado" boolean DEFAULT false NOT NULL
);


ALTER TABLE "raw"."coleta_bruta" OWNER TO "postgres";


COMMENT ON TABLE "raw"."coleta_bruta" IS 'Landing Zone ELT — dados brutos sem validação';



COMMENT ON COLUMN "raw"."coleta_bruta"."id" IS 'UUID gerado pelo banco (gen_random_uuid)';



COMMENT ON COLUMN "raw"."coleta_bruta"."fonte_id" IS 'Identificador do micro-motor extrator';



COMMENT ON COLUMN "raw"."coleta_bruta"."payload_bruto" IS 'HTML inteiro, JSON interceptado ou texto puro — sem parsing';



COMMENT ON COLUMN "raw"."coleta_bruta"."competencia_alvo" IS 'Formato YYYY-MM — restrito a 2024-01 até 2026-12';



CREATE TABLE IF NOT EXISTS "raw"."controle_carga" (
    "id" bigint NOT NULL,
    "batch_id" "uuid" NOT NULL,
    "arquivo" "text" NOT NULL,
    "linhas_lidas" integer DEFAULT 0 NOT NULL,
    "linhas_inseridas" integer DEFAULT 0 NOT NULL,
    "linhas_rejeitadas" integer DEFAULT 0 NOT NULL,
    "duracao_seg" numeric(10,2),
    "status" "text" DEFAULT 'em_andamento'::"text" NOT NULL,
    "iniciado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "concluido_em" timestamp with time zone,
    CONSTRAINT "controle_carga_status_check" CHECK (("status" = ANY (ARRAY['em_andamento'::"text", 'sucesso'::"text", 'falha'::"text"])))
);


ALTER TABLE "raw"."controle_carga" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "raw"."controle_carga_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "raw"."controle_carga_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "raw"."controle_carga_id_seq" OWNED BY "raw"."controle_carga"."id";



CREATE TABLE IF NOT EXISTS "raw"."precos_municipio" (
    "id" bigint NOT NULL,
    "produto" "text",
    "municipio_id" "text",
    "municipio_nome" "text",
    "uf" character(2),
    "ano" smallint,
    "mes" smallint,
    "preco_medio" "text",
    "_arquivo" "text" DEFAULT 'PrecosMensalMunicipio'::"text" NOT NULL,
    "_loaded_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "_batch_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL
);


ALTER TABLE "raw"."precos_municipio" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "raw"."precos_municipio_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "raw"."precos_municipio_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "raw"."precos_municipio_id_seq" OWNED BY "raw"."precos_municipio"."id";



CREATE TABLE IF NOT EXISTS "raw"."precos_uf" (
    "id" bigint NOT NULL,
    "produto" "text",
    "uf" character(2),
    "ano" smallint,
    "mes" smallint,
    "preco_medio" "text",
    "_arquivo" "text" DEFAULT 'PrecosMensalUF'::"text" NOT NULL,
    "_loaded_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "_batch_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL
);


ALTER TABLE "raw"."precos_uf" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "raw"."precos_uf_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "raw"."precos_uf_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "raw"."precos_uf_id_seq" OWNED BY "raw"."precos_uf"."id";



CREATE TABLE IF NOT EXISTS "staging"."baseline_2025_interpolado" (
    "id" integer NOT NULL,
    "id_produto" integer NOT NULL,
    "id_localidade" integer NOT NULL,
    "ano" smallint NOT NULL,
    "mes" smallint NOT NULL,
    "preco_medio" numeric(14,4),
    "is_interpolado" boolean DEFAULT false,
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "staging"."baseline_2025_interpolado" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "staging"."baseline_2025_interpolado_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "staging"."baseline_2025_interpolado_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "staging"."baseline_2025_interpolado_id_seq" OWNED BY "staging"."baseline_2025_interpolado"."id";



CREATE TABLE IF NOT EXISTS "staging"."confianca_baseline" (
    "id" integer NOT NULL,
    "id_produto" integer NOT NULL,
    "id_localidade" integer NOT NULL,
    "mes" integer NOT NULL,
    "confianca" numeric(5,2),
    "calculado_em" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "staging"."confianca_baseline" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "staging"."confianca_baseline_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "staging"."confianca_baseline_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "staging"."confianca_baseline_id_seq" OWNED BY "staging"."confianca_baseline"."id";



CREATE TABLE IF NOT EXISTS "staging"."dim_categoria" (
    "id_categoria" integer NOT NULL,
    "nome_categoria" "text" NOT NULL,
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "staging"."dim_categoria" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "staging"."dim_categoria_id_categoria_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "staging"."dim_categoria_id_categoria_seq" OWNER TO "postgres";


ALTER SEQUENCE "staging"."dim_categoria_id_categoria_seq" OWNED BY "staging"."dim_categoria"."id_categoria";



CREATE TABLE IF NOT EXISTS "staging"."dim_conab_produto_mapping" (
    "id_mapping" integer NOT NULL,
    "produto_conab" "text" NOT NULL,
    "produto_normalizado" "text" NOT NULL,
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "staging"."dim_conab_produto_mapping" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "staging"."dim_conab_produto_mapping_id_mapping_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "staging"."dim_conab_produto_mapping_id_mapping_seq" OWNER TO "postgres";


ALTER SEQUENCE "staging"."dim_conab_produto_mapping_id_mapping_seq" OWNED BY "staging"."dim_conab_produto_mapping"."id_mapping";



CREATE SEQUENCE IF NOT EXISTS "staging"."dim_localidade_id_localidade_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "staging"."dim_localidade_id_localidade_seq" OWNER TO "postgres";


ALTER SEQUENCE "staging"."dim_localidade_id_localidade_seq" OWNED BY "staging"."dim_localidade"."id_localidade";



CREATE SEQUENCE IF NOT EXISTS "staging"."dim_produto_id_produto_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "staging"."dim_produto_id_produto_seq" OWNER TO "postgres";


ALTER SEQUENCE "staging"."dim_produto_id_produto_seq" OWNED BY "staging"."dim_produto"."id_produto";



CREATE TABLE IF NOT EXISTS "staging"."fact_precos_mensais" (
    "id_fato" bigint NOT NULL,
    "id_produto" integer NOT NULL,
    "id_localidade" integer NOT NULL,
    "ano" smallint NOT NULL,
    "mes" smallint NOT NULL,
    "preco_medio" numeric(14,4) NOT NULL,
    "batch_id" "uuid" NOT NULL,
    "loaded_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "fact_precos_mensais_mes_check" CHECK ((("mes" >= 1) AND ("mes" <= 12))),
    CONSTRAINT "fact_precos_mensais_preco_medio_check" CHECK (("preco_medio" > (0)::numeric))
);


ALTER TABLE "staging"."fact_precos_mensais" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "staging"."fact_precos_mensais_id_fato_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "staging"."fact_precos_mensais_id_fato_seq" OWNER TO "postgres";


ALTER SEQUENCE "staging"."fact_precos_mensais_id_fato_seq" OWNED BY "staging"."fact_precos_mensais"."id_fato";



CREATE TABLE IF NOT EXISTS "staging"."fato_cotacao_regional" (
    "id" integer NOT NULL,
    "id_produto" integer NOT NULL,
    "uf" character(2) NOT NULL,
    "ano" smallint NOT NULL,
    "mes" smallint NOT NULL,
    "preco_medio" numeric(14,4),
    "fonte" "text",
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "staging"."fato_cotacao_regional" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "staging"."fato_cotacao_regional_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "staging"."fato_cotacao_regional_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "staging"."fato_cotacao_regional_id_seq" OWNED BY "staging"."fato_cotacao_regional"."id";



CREATE TABLE IF NOT EXISTS "staging"."precos_rejeitados" (
    "id_rejeitado" bigint NOT NULL,
    "id_produto" integer,
    "id_localidade" integer,
    "ano" smallint,
    "mes" smallint,
    "preco_medio" numeric(14,4),
    "preco_medio_historico" numeric(14,4),
    "razao" "text" NOT NULL,
    "dados_brutos" "jsonb",
    "rejeitado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "batch_id" "uuid"
);


ALTER TABLE "staging"."precos_rejeitados" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "staging"."precos_rejeitados_id_rejeitado_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "staging"."precos_rejeitados_id_rejeitado_seq" OWNER TO "postgres";


ALTER SEQUENCE "staging"."precos_rejeitados_id_rejeitado_seq" OWNED BY "staging"."precos_rejeitados"."id_rejeitado";



ALTER TABLE ONLY "mart"."sazonalidade_produto" ALTER COLUMN "id_sazonalidade" SET DEFAULT "nextval"('"mart"."sazonalidade_produto_id_sazonalidade_seq"'::"regclass");



ALTER TABLE ONLY "ops"."audit_llm_queries" ALTER COLUMN "id" SET DEFAULT "nextval"('"ops"."audit_llm_queries_id_seq"'::"regclass");



ALTER TABLE ONLY "ops"."config_agente" ALTER COLUMN "id" SET DEFAULT "nextval"('"ops"."config_agente_id_seq"'::"regclass");



ALTER TABLE ONLY "ops"."controle_erros_ddl" ALTER COLUMN "id" SET DEFAULT "nextval"('"ops"."controle_erros_ddl_id_seq"'::"regclass");



ALTER TABLE ONLY "raw"."controle_carga" ALTER COLUMN "id" SET DEFAULT "nextval"('"raw"."controle_carga_id_seq"'::"regclass");



ALTER TABLE ONLY "raw"."precos_municipio" ALTER COLUMN "id" SET DEFAULT "nextval"('"raw"."precos_municipio_id_seq"'::"regclass");



ALTER TABLE ONLY "raw"."precos_uf" ALTER COLUMN "id" SET DEFAULT "nextval"('"raw"."precos_uf_id_seq"'::"regclass");



ALTER TABLE ONLY "staging"."baseline_2025_interpolado" ALTER COLUMN "id" SET DEFAULT "nextval"('"staging"."baseline_2025_interpolado_id_seq"'::"regclass");



ALTER TABLE ONLY "staging"."confianca_baseline" ALTER COLUMN "id" SET DEFAULT "nextval"('"staging"."confianca_baseline_id_seq"'::"regclass");



ALTER TABLE ONLY "staging"."dim_categoria" ALTER COLUMN "id_categoria" SET DEFAULT "nextval"('"staging"."dim_categoria_id_categoria_seq"'::"regclass");



ALTER TABLE ONLY "staging"."dim_conab_produto_mapping" ALTER COLUMN "id_mapping" SET DEFAULT "nextval"('"staging"."dim_conab_produto_mapping_id_mapping_seq"'::"regclass");



ALTER TABLE ONLY "staging"."dim_localidade" ALTER COLUMN "id_localidade" SET DEFAULT "nextval"('"staging"."dim_localidade_id_localidade_seq"'::"regclass");



ALTER TABLE ONLY "staging"."dim_produto" ALTER COLUMN "id_produto" SET DEFAULT "nextval"('"staging"."dim_produto_id_produto_seq"'::"regclass");



ALTER TABLE ONLY "staging"."fact_precos_mensais" ALTER COLUMN "id_fato" SET DEFAULT "nextval"('"staging"."fact_precos_mensais_id_fato_seq"'::"regclass");



ALTER TABLE ONLY "staging"."fato_cotacao_regional" ALTER COLUMN "id" SET DEFAULT "nextval"('"staging"."fato_cotacao_regional_id_seq"'::"regclass");



ALTER TABLE ONLY "staging"."precos_rejeitados" ALTER COLUMN "id_rejeitado" SET DEFAULT "nextval"('"staging"."precos_rejeitados_id_rejeitado_seq"'::"regclass");



ALTER TABLE ONLY "mart"."sazonalidade_baseline_24_25"
    ADD CONSTRAINT "sazonalidade_baseline_24_25_pkey" PRIMARY KEY ("id_produto", "id_localidade", "mes");



ALTER TABLE ONLY "mart"."sazonalidade_baseline_25_26"
    ADD CONSTRAINT "sazonalidade_baseline_25_26_pkey" PRIMARY KEY ("id_produto", "id_localidade", "mes");



ALTER TABLE ONLY "mart"."sazonalidade_produto"
    ADD CONSTRAINT "sazonalidade_produto_pkey" PRIMARY KEY ("id_sazonalidade");



ALTER TABLE ONLY "mart"."sazonalidade_produto"
    ADD CONSTRAINT "uq_sazonalidade" UNIQUE ("id_produto", "id_localidade", "ano", "mes");



ALTER TABLE ONLY "ops"."audit_llm_queries"
    ADD CONSTRAINT "audit_llm_queries_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "ops"."config_agente"
    ADD CONSTRAINT "config_agente_chave_key" UNIQUE ("chave");



ALTER TABLE ONLY "ops"."config_agente"
    ADD CONSTRAINT "config_agente_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "ops"."controle_erros_ddl"
    ADD CONSTRAINT "controle_erros_ddl_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "ops"."quarentena_coleta"
    ADD CONSTRAINT "quarentena_coleta_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "raw"."coleta_bruta"
    ADD CONSTRAINT "coleta_bruta_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "raw"."controle_carga"
    ADD CONSTRAINT "controle_carga_batch_id_key" UNIQUE ("batch_id");



ALTER TABLE ONLY "raw"."controle_carga"
    ADD CONSTRAINT "controle_carga_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "raw"."precos_municipio"
    ADD CONSTRAINT "precos_municipio_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "raw"."precos_uf"
    ADD CONSTRAINT "precos_uf_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "staging"."baseline_2025_interpolado"
    ADD CONSTRAINT "baseline_2025_interpolado_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "staging"."confianca_baseline"
    ADD CONSTRAINT "confianca_baseline_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "staging"."dim_categoria"
    ADD CONSTRAINT "dim_categoria_nome_categoria_key" UNIQUE ("nome_categoria");



ALTER TABLE ONLY "staging"."dim_categoria"
    ADD CONSTRAINT "dim_categoria_pkey" PRIMARY KEY ("id_categoria");



ALTER TABLE ONLY "staging"."dim_conab_produto_mapping"
    ADD CONSTRAINT "dim_conab_produto_mapping_pkey" PRIMARY KEY ("id_mapping");



ALTER TABLE ONLY "staging"."dim_localidade"
    ADD CONSTRAINT "dim_localidade_pkey" PRIMARY KEY ("id_localidade");



ALTER TABLE ONLY "staging"."dim_produto"
    ADD CONSTRAINT "dim_produto_nome_produto_key" UNIQUE ("nome_produto");



ALTER TABLE ONLY "staging"."dim_produto"
    ADD CONSTRAINT "dim_produto_pkey" PRIMARY KEY ("id_produto");



ALTER TABLE ONLY "staging"."fact_precos_mensais"
    ADD CONSTRAINT "fact_precos_mensais_pkey" PRIMARY KEY ("id_fato");



ALTER TABLE ONLY "staging"."fato_cotacao_regional"
    ADD CONSTRAINT "fato_cotacao_regional_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "staging"."precos_rejeitados"
    ADD CONSTRAINT "precos_rejeitados_pkey" PRIMARY KEY ("id_rejeitado");



ALTER TABLE ONLY "staging"."dim_localidade"
    ADD CONSTRAINT "uq_dim_localidade" UNIQUE ("uf", "municipio_id");



ALTER TABLE ONLY "staging"."fact_precos_mensais"
    ADD CONSTRAINT "uq_fact_precos_mensais" UNIQUE ("id_produto", "id_localidade", "ano", "mes");



CREATE INDEX "idx_sazonalidade_api" ON "mart"."sazonalidade_produto" USING "btree" ("id_localidade", "id_produto", "ano", "mes");



CREATE INDEX "idx_sazonalidade_confianca" ON "mart"."sazonalidade_produto" USING "btree" ("baseline_confianca" DESC);



CREATE INDEX "idx_sazonalidade_forecast" ON "mart"."sazonalidade_produto" USING "btree" ("is_forecast") WHERE ("is_forecast" = true);



CREATE INDEX "idx_sazonalidade_mes" ON "mart"."sazonalidade_produto" USING "btree" ("ano", "mes");



CREATE INDEX "idx_sazonalidade_status" ON "mart"."sazonalidade_produto" USING "btree" ("status_cor") WHERE ("status_cor" = ANY (ARRAY['VERDE'::"text", 'VERMELHO'::"text"]));



CREATE INDEX "idx_vw_api_filtro" ON "mart"."vw_api_produtos_sazonalidade" USING "btree" ("uf", "municipio", "status_cor");



CREATE UNIQUE INDEX "idx_vw_api_unique" ON "mart"."vw_api_produtos_sazonalidade" USING "btree" ("id_sazonalidade");



CREATE INDEX "idx_quarentena_raw_id" ON "ops"."quarentena_coleta" USING "btree" ("raw_id");



CREATE INDEX "idx_coleta_bruta_competencia" ON "raw"."coleta_bruta" USING "btree" ("competencia_alvo");



CREATE INDEX "idx_coleta_bruta_processado" ON "raw"."coleta_bruta" USING "btree" ("processado") WHERE ("processado" = false);



CREATE INDEX "idx_fact_precos_busca" ON "staging"."fact_precos_mensais" USING "btree" ("id_produto", "id_localidade", "ano", "mes");



CREATE OR REPLACE TRIGGER "trg_valida_anomalia_preco" BEFORE INSERT ON "staging"."fact_precos_mensais" FOR EACH ROW WHEN (("new"."preco_medio" IS NOT NULL)) EXECUTE FUNCTION "staging"."trg_valida_anomalia_preco"();



ALTER TABLE ONLY "staging"."fact_precos_mensais"
    ADD CONSTRAINT "fact_precos_mensais_id_localidade_fkey" FOREIGN KEY ("id_localidade") REFERENCES "staging"."dim_localidade"("id_localidade");



ALTER TABLE ONLY "staging"."fact_precos_mensais"
    ADD CONSTRAINT "fact_precos_mensais_id_produto_fkey" FOREIGN KEY ("id_produto") REFERENCES "staging"."dim_produto"("id_produto");



GRANT USAGE ON SCHEMA "mart" TO "role_etl_writer";
GRANT USAGE ON SCHEMA "mart" TO "role_api_reader";
GRANT USAGE ON SCHEMA "mart" TO "anon";
GRANT USAGE ON SCHEMA "mart" TO "authenticated";
GRANT USAGE ON SCHEMA "mart" TO "service_role";



GRANT USAGE ON SCHEMA "ops" TO "anon";
GRANT USAGE ON SCHEMA "ops" TO "authenticated";
GRANT USAGE ON SCHEMA "ops" TO "service_role";



GRANT USAGE ON SCHEMA "raw" TO "role_etl_writer";
GRANT USAGE ON SCHEMA "raw" TO "anon";
GRANT USAGE ON SCHEMA "raw" TO "authenticated";
GRANT USAGE ON SCHEMA "raw" TO "service_role";



GRANT USAGE ON SCHEMA "staging" TO "role_etl_writer";
GRANT USAGE ON SCHEMA "staging" TO "anon";
GRANT USAGE ON SCHEMA "staging" TO "authenticated";
GRANT USAGE ON SCHEMA "staging" TO "service_role";



GRANT ALL ON FUNCTION "staging"."_gerar_batch_id"() TO "role_etl_writer";



GRANT ALL ON FUNCTION "staging"."_parse_conab_price"("p_texto" "text") TO "role_etl_writer";



GRANT ALL ON PROCEDURE "staging"."sp_calcular_sazonalidade"(IN "p_ano_alvo" smallint, IN "p_mes_alvo" smallint) TO "role_etl_writer";



GRANT ALL ON PROCEDURE "staging"."sp_executar_carga_completa"() TO "role_etl_writer";



GRANT ALL ON FUNCTION "staging"."trg_valida_anomalia_preco"() TO "role_etl_writer";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "mart"."sazonalidade_produto" TO "role_etl_writer";
GRANT SELECT ON TABLE "mart"."sazonalidade_produto" TO "role_api_reader";
GRANT SELECT ON TABLE "mart"."sazonalidade_produto" TO "anon";
GRANT SELECT ON TABLE "mart"."sazonalidade_produto" TO "authenticated";
GRANT ALL ON TABLE "mart"."sazonalidade_produto" TO "service_role";



GRANT USAGE ON SEQUENCE "mart"."sazonalidade_produto_id_sazonalidade_seq" TO "role_etl_writer";



GRANT ALL ON TABLE "staging"."dim_localidade" TO "role_etl_writer";
GRANT ALL ON TABLE "staging"."dim_localidade" TO "service_role";



GRANT ALL ON TABLE "staging"."dim_produto" TO "role_etl_writer";
GRANT ALL ON TABLE "staging"."dim_produto" TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "mart"."vw_api_produtos_sazonalidade" TO "role_etl_writer";
GRANT SELECT ON TABLE "mart"."vw_api_produtos_sazonalidade" TO "role_api_reader";
GRANT SELECT ON TABLE "mart"."vw_api_produtos_sazonalidade" TO "anon";
GRANT SELECT ON TABLE "mart"."vw_api_produtos_sazonalidade" TO "authenticated";
GRANT ALL ON TABLE "mart"."vw_api_produtos_sazonalidade" TO "service_role";



GRANT ALL ON TABLE "ops"."quarentena_coleta" TO "service_role";



GRANT ALL ON TABLE "raw"."coleta_bruta" TO "role_etl_writer";
GRANT ALL ON TABLE "raw"."coleta_bruta" TO "service_role";



GRANT ALL ON TABLE "raw"."controle_carga" TO "role_etl_writer";
GRANT ALL ON TABLE "raw"."controle_carga" TO "service_role";



GRANT USAGE ON SEQUENCE "raw"."controle_carga_id_seq" TO "role_etl_writer";



GRANT ALL ON TABLE "raw"."precos_municipio" TO "role_etl_writer";
GRANT ALL ON TABLE "raw"."precos_municipio" TO "service_role";



GRANT USAGE ON SEQUENCE "raw"."precos_municipio_id_seq" TO "role_etl_writer";



GRANT ALL ON TABLE "raw"."precos_uf" TO "role_etl_writer";
GRANT ALL ON TABLE "raw"."precos_uf" TO "service_role";



GRANT USAGE ON SEQUENCE "raw"."precos_uf_id_seq" TO "role_etl_writer";



GRANT USAGE ON SEQUENCE "staging"."dim_localidade_id_localidade_seq" TO "role_etl_writer";



GRANT USAGE ON SEQUENCE "staging"."dim_produto_id_produto_seq" TO "role_etl_writer";



GRANT ALL ON TABLE "staging"."fact_precos_mensais" TO "role_etl_writer";
GRANT ALL ON TABLE "staging"."fact_precos_mensais" TO "service_role";



GRANT USAGE ON SEQUENCE "staging"."fact_precos_mensais_id_fato_seq" TO "role_etl_writer";



GRANT ALL ON TABLE "staging"."precos_rejeitados" TO "role_etl_writer";
GRANT ALL ON TABLE "staging"."precos_rejeitados" TO "service_role";



GRANT USAGE ON SEQUENCE "staging"."precos_rejeitados_id_rejeitado_seq" TO "role_etl_writer";




