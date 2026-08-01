-- 012: fila do caminho frio (River)
--
-- As tabelas do River NÃO são criadas aqui: quem cria é a CLI da própria
-- biblioteca, num schema separado. `make migrate` já ordena isso sozinho
-- (river → migrate-up → roles-pw); esta migration é a última.
--
-- Este arquivo só concede privilégios, porque eles dependem de objetos que a
-- CLI já criou.

-- Esta migration NÃO cria o schema river — e a ausência do `CREATE SCHEMA
-- IF NOT EXISTS` que existia aqui é a correção, não um esquecimento.
--
-- Com o schema criado vazio por esta linha, os GRANT abaixo viravam no-op
-- LEGAL: `GRANT ... ON ALL TABLES` sobre schema sem tabela não é erro, é uma
-- lista vazia. A migration "passava", o `make verify` não olhava river, e a
-- falha só aparecia semanas depois, no boot do worker, como
-- "permission denied for table river_job". A única checagem era um
-- RAISE WARNING — e aviso não é dependência.
DO $river012$
BEGIN
    IF to_regclass('river.river_job') IS NULL THEN
        RAISE EXCEPTION 'river.river_job não existe: a 012 concede privilégio sobre tabelas que a CLI do River cria'
          USING HINT = 'rode `make river` antes — ou apenas `make migrate`, que já ordena river → migrate-up → roles-pw';
    END IF;
END $river012$;

GRANT USAGE ON SCHEMA river TO monitor_worker, monitor_api;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA river TO monitor_worker;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA river TO monitor_worker, monitor_api;

-- A API só ENFILEIRA. Precisa de SELECT também: o insert com UniqueOpts
-- consulta antes de inserir, e sem ele o producer quebra em runtime.
GRANT SELECT, INSERT ON river.river_job TO monitor_api;

-- `ON ALL TABLES` é um retrato do instante, não uma política. Um `river
-- migrate-up` futuro cria tabela nova SEM privilégio nenhum, e o worker volta a
-- morrer em runtime pelo mesmo motivo. Isto cobre o próximo upgrade — e vale
-- enquanto a CLI do River rodar com o MESMO papel que executa esta migration
-- (hoje, o superusuário de DATABASE_URL_MIGRATE).
ALTER DEFAULT PRIVILEGES IN SCHEMA river
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO monitor_worker;
ALTER DEFAULT PRIVILEGES IN SCHEMA river
    GRANT USAGE, SELECT ON SEQUENCES TO monitor_worker, monitor_api;

-- Pós-condição. GRANT que não pegou é exatamente a falha que esta migration
-- existe para impedir — então ela se cobra.
DO $river012$
BEGIN
    IF NOT has_table_privilege('monitor_api','river.river_job','INSERT')
       OR NOT has_table_privilege('monitor_api','river.river_job','SELECT') THEN
        RAISE EXCEPTION 'monitor_api não consegue enfileirar em river.river_job depois da 012';
    END IF;
    IF NOT has_table_privilege('monitor_worker','river.river_job','UPDATE') THEN
        RAISE EXCEPTION 'monitor_worker não consegue consumir river.river_job depois da 012';
    END IF;
END $river012$;

-- Os GRANT são qualificados pelo schema de propósito: sem qualificação, o
-- nome resolve por search_path e concede — ou falha — no objeto errado.
