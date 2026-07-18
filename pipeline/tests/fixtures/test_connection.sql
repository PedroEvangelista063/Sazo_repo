SET session_replication_role = replica;

--
-- PostgreSQL database dump
--

-- \restrict UxP9JHGAa9dsrelEEnrhZ9ElOKU8bIf43T5QrOBLfFnIHQ4UdAzTnlRoseDmDmI

-- Dumped from database version 17.6
-- Dumped by pg_dump version 17.6

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Data for Name: audit_log_entries; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--



--
-- Data for Name: custom_oauth_providers; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--



--
-- Data for Name: flow_state; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--



--
-- Data for Name: users; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--



--
-- Data for Name: identities; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--



--
-- Data for Name: instances; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--



--
-- Data for Name: oauth_clients; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--



--
-- Data for Name: sessions; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--



--
-- Data for Name: mfa_amr_claims; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--



--
-- Data for Name: mfa_factors; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--



--
-- Data for Name: mfa_challenges; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--



--
-- Data for Name: oauth_authorizations; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--



--
-- Data for Name: oauth_client_states; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--



--
-- Data for Name: oauth_consents; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--



--
-- Data for Name: one_time_tokens; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--



--
-- Data for Name: refresh_tokens; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--



--
-- Data for Name: sso_providers; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--



--
-- Data for Name: saml_providers; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--



--
-- Data for Name: saml_relay_states; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--



--
-- Data for Name: sso_domains; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--



--
-- Data for Name: webauthn_challenges; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--



--
-- Data for Name: webauthn_credentials; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--



--
-- Data for Name: sazonalidade_baseline_24_25; Type: TABLE DATA; Schema: mart; Owner: postgres
--



--
-- Data for Name: sazonalidade_baseline_25_26; Type: TABLE DATA; Schema: mart; Owner: postgres
--



--
-- Data for Name: sazonalidade_produto; Type: TABLE DATA; Schema: mart; Owner: postgres
--



--
-- Data for Name: audit_llm_queries; Type: TABLE DATA; Schema: ops; Owner: postgres
--



--
-- Data for Name: config_agente; Type: TABLE DATA; Schema: ops; Owner: postgres
--



--
-- Data for Name: controle_erros_ddl; Type: TABLE DATA; Schema: ops; Owner: postgres
--



--
-- Data for Name: quarentena_coleta; Type: TABLE DATA; Schema: ops; Owner: postgres
--



--
-- Data for Name: coleta_bruta; Type: TABLE DATA; Schema: raw; Owner: postgres
--



--
-- Data for Name: controle_carga; Type: TABLE DATA; Schema: raw; Owner: postgres
--



--
-- Data for Name: precos_municipio; Type: TABLE DATA; Schema: raw; Owner: postgres
--



--
-- Data for Name: precos_uf; Type: TABLE DATA; Schema: raw; Owner: postgres
--



--
-- Data for Name: baseline_2025_interpolado; Type: TABLE DATA; Schema: staging; Owner: postgres
--



--
-- Data for Name: confianca_baseline; Type: TABLE DATA; Schema: staging; Owner: postgres
--



--
-- Data for Name: dim_categoria; Type: TABLE DATA; Schema: staging; Owner: postgres
--



--
-- Data for Name: dim_conab_produto_mapping; Type: TABLE DATA; Schema: staging; Owner: postgres
--



--
-- Data for Name: dim_localidade; Type: TABLE DATA; Schema: staging; Owner: postgres
--



--
-- Data for Name: dim_produto; Type: TABLE DATA; Schema: staging; Owner: postgres
--



--
-- Data for Name: fact_precos_mensais; Type: TABLE DATA; Schema: staging; Owner: postgres
--



--
-- Data for Name: fato_cotacao_regional; Type: TABLE DATA; Schema: staging; Owner: postgres
--



--
-- Data for Name: precos_rejeitados; Type: TABLE DATA; Schema: staging; Owner: postgres
--



--
-- Data for Name: buckets; Type: TABLE DATA; Schema: storage; Owner: supabase_storage_admin
--



--
-- Data for Name: buckets_analytics; Type: TABLE DATA; Schema: storage; Owner: supabase_storage_admin
--



--
-- Data for Name: buckets_vectors; Type: TABLE DATA; Schema: storage; Owner: supabase_storage_admin
--



--
-- Data for Name: objects; Type: TABLE DATA; Schema: storage; Owner: supabase_storage_admin
--



--
-- Data for Name: s3_multipart_uploads; Type: TABLE DATA; Schema: storage; Owner: supabase_storage_admin
--



--
-- Data for Name: s3_multipart_uploads_parts; Type: TABLE DATA; Schema: storage; Owner: supabase_storage_admin
--



--
-- Data for Name: vector_indexes; Type: TABLE DATA; Schema: storage; Owner: supabase_storage_admin
--



--
-- Name: refresh_tokens_id_seq; Type: SEQUENCE SET; Schema: auth; Owner: supabase_auth_admin
--

SELECT pg_catalog.setval('"auth"."refresh_tokens_id_seq"', 1, false);


--
-- Name: sazonalidade_produto_id_sazonalidade_seq; Type: SEQUENCE SET; Schema: mart; Owner: postgres
--

SELECT pg_catalog.setval('"mart"."sazonalidade_produto_id_sazonalidade_seq"', 1, false);


--
-- Name: audit_llm_queries_id_seq; Type: SEQUENCE SET; Schema: ops; Owner: postgres
--

SELECT pg_catalog.setval('"ops"."audit_llm_queries_id_seq"', 1, false);


--
-- Name: config_agente_id_seq; Type: SEQUENCE SET; Schema: ops; Owner: postgres
--

SELECT pg_catalog.setval('"ops"."config_agente_id_seq"', 1, false);


--
-- Name: controle_erros_ddl_id_seq; Type: SEQUENCE SET; Schema: ops; Owner: postgres
--

SELECT pg_catalog.setval('"ops"."controle_erros_ddl_id_seq"', 1, false);


--
-- Name: controle_carga_id_seq; Type: SEQUENCE SET; Schema: raw; Owner: postgres
--

SELECT pg_catalog.setval('"raw"."controle_carga_id_seq"', 1, false);


--
-- Name: precos_municipio_id_seq; Type: SEQUENCE SET; Schema: raw; Owner: postgres
--

SELECT pg_catalog.setval('"raw"."precos_municipio_id_seq"', 1, false);


--
-- Name: precos_uf_id_seq; Type: SEQUENCE SET; Schema: raw; Owner: postgres
--

SELECT pg_catalog.setval('"raw"."precos_uf_id_seq"', 1, false);


--
-- Name: baseline_2025_interpolado_id_seq; Type: SEQUENCE SET; Schema: staging; Owner: postgres
--

SELECT pg_catalog.setval('"staging"."baseline_2025_interpolado_id_seq"', 1, false);


--
-- Name: confianca_baseline_id_seq; Type: SEQUENCE SET; Schema: staging; Owner: postgres
--

SELECT pg_catalog.setval('"staging"."confianca_baseline_id_seq"', 1, false);


--
-- Name: dim_categoria_id_categoria_seq; Type: SEQUENCE SET; Schema: staging; Owner: postgres
--

SELECT pg_catalog.setval('"staging"."dim_categoria_id_categoria_seq"', 1, false);


--
-- Name: dim_conab_produto_mapping_id_mapping_seq; Type: SEQUENCE SET; Schema: staging; Owner: postgres
--

SELECT pg_catalog.setval('"staging"."dim_conab_produto_mapping_id_mapping_seq"', 1, false);


--
-- Name: dim_localidade_id_localidade_seq; Type: SEQUENCE SET; Schema: staging; Owner: postgres
--

SELECT pg_catalog.setval('"staging"."dim_localidade_id_localidade_seq"', 1, false);


--
-- Name: dim_produto_id_produto_seq; Type: SEQUENCE SET; Schema: staging; Owner: postgres
--

SELECT pg_catalog.setval('"staging"."dim_produto_id_produto_seq"', 1, false);


--
-- Name: fact_precos_mensais_id_fato_seq; Type: SEQUENCE SET; Schema: staging; Owner: postgres
--

SELECT pg_catalog.setval('"staging"."fact_precos_mensais_id_fato_seq"', 1, false);


--
-- Name: fato_cotacao_regional_id_seq; Type: SEQUENCE SET; Schema: staging; Owner: postgres
--

SELECT pg_catalog.setval('"staging"."fato_cotacao_regional_id_seq"', 1, false);


--
-- Name: precos_rejeitados_id_rejeitado_seq; Type: SEQUENCE SET; Schema: staging; Owner: postgres
--

SELECT pg_catalog.setval('"staging"."precos_rejeitados_id_rejeitado_seq"', 1, false);


--
-- PostgreSQL database dump complete
--

-- \unrestrict UxP9JHGAa9dsrelEEnrhZ9ElOKU8bIf43T5QrOBLfFnIHQ4UdAzTnlRoseDmDmI

RESET ALL;
