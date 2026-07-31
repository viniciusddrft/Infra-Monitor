-- 012: fila do caminho frio (River)
--
-- As tabelas do River NÃO são criadas aqui: quem cria é a CLI da própria
-- biblioteca, num schema separado. O Makefile roda antes desta migration:
--
--   go run github.com/riverqueue/river/cmd/river migrate-up \
--        --database-url "$DATABASE_URL" --schema river
--
-- Este arquivo só concede os privilégios, porque eles dependem de objetos que
-- a CLI já criou.

CREATE SCHEMA IF NOT EXISTS river;

GRANT USAGE ON SCHEMA river TO monitor_worker, monitor_api;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA river TO monitor_worker;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA river TO monitor_worker, monitor_api;

-- A API só enfileira. Precisa de SELECT também: o insert com UniqueOpts
-- consulta antes de inserir, e sem ele o producer quebra em runtime.
DO $$ BEGIN
    IF to_regclass('river.river_job') IS NOT NULL THEN
        EXECUTE 'GRANT SELECT, INSERT ON river.river_job TO monitor_api';
    ELSE
        RAISE WARNING 'river.river_job não existe: rode `river migrate-up --schema river` antes desta migration';
    END IF;
END $$;

-- Os GRANT são qualificados pelo schema de propósito: sem qualificação, o
-- nome resolve por search_path e concede — ou falha — no objeto errado.
