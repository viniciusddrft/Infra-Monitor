-- A remoção das tabelas é da CLI do River:
--   river migrate-down --database-url "$DATABASE_URL" --schema river
DROP SCHEMA IF EXISTS river CASCADE;
