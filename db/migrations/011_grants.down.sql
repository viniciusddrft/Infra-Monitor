DROP TRIGGER IF EXISTS trg_guard_suspended_reason ON urls;
DROP FUNCTION IF EXISTS guard_suspended_reason();

-- DROP OWNED BY revoga TODO privilégio do papel neste banco: tabela, COLUNA,
-- sequência, schema (inclusive `river`) e o EXECUTE das funções de partição.
--
-- Enumerar REVOKE não resolvia e não resolve: a versão anterior revogava
-- tabelas, sequências e schema, mas esquecia o EXECUTE de
-- create_history_partition(date). O DROP ROLE abaixo então falhava com
-- "role cannot be dropped because some objects depend on it", e como o
-- Makefile roda com `set -e`, o `make migrate-down` abortava AQUI — já com o
-- schema river derrubado pela 012.down, deixando o banco meio desmontado.
-- E qualquer GRANT novo no futuro reabriria o mesmo buraco.
--
-- Apesar do nome, aqui isto só revoga: os papéis não são donos de objeto
-- nenhum, porque todo o DDL roda pelo superusuário.
--
-- Limite conhecido: DROP OWNED BY cobre o banco corrente mais objetos
-- compartilhados. Se estes papéis ganharem privilégio num segundo banco, o
-- DROP ROLE volta a falhar — não é o caso aqui.
DO $$
DECLARE r TEXT;
BEGIN
    FOREACH r IN ARRAY ARRAY['monitor_api','monitor_worker','monitor_migrate'] LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
            EXECUTE format('DROP OWNED BY %I', r);
        END IF;
    END LOOP;
END $$;

DROP ROLE IF EXISTS monitor_worker;
DROP ROLE IF EXISTS monitor_api;
DROP ROLE IF EXISTS monitor_migrate;
