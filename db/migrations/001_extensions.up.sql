-- 001: extensões
--
-- pgcrypto: gen_random_uuid() para lease_token e gen_random_bytes() para o
--           obfuscated_account_id do billing
-- pg_stat_statements: sem ela, "qual query está lenta" vira adivinhação

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
