-- Senhas dos papéis de serviço. `make roles-pw`, depois da 011.
--
-- Isto NÃO é uma migration: é bring-up. Mora fora de db/migrations/ de
-- propósito, por duas razões que a 011 explica em detalhe:
--
--   1. senha não é schema. Em produção ela vem do gestor de segredos, e uma
--      migration versionada é o lugar errado para carregar segredo;
--   2. definir senha por variável exige meta-comando do psql (`:'var'`), e o
--      harness de teste da API aplica db/migrations/ pelo golang-migrate, que
--      não executa meta-comando. Mantendo isto fora, a 011 continua SQL puro.
--
-- As variáveis chegam por `-v`, do Makefile, que as lê do .env. NUNCA use
-- crase (`\set pw \`echo $VAR\``): a crase roda um shell no processo cliente do
-- psql, que aqui vive dentro do container do Postgres, onde a variável não
-- existe — era exatamente esse o defeito.

-- Guarda: variável vazia é o que um .env faltando produz. Sem isto o
-- `ALTER ROLE ... PASSWORD ''` passaria, e um papel com senha vazia é pior que
-- um sem senha nenhuma — parece configurado.
SELECT length(:'migrate_pw') > 0
   AND length(:'api_pw')     > 0
   AND length(:'worker_pw')  > 0 AS pw_ok \gset

\if :pw_ok
\else
DO $senhas$ BEGIN
    RAISE EXCEPTION 'senhas dos papéis vazias'
      USING HINT = 'defina MONITOR_MIGRATE_PASSWORD, MONITOR_API_PASSWORD e MONITOR_WORKER_PASSWORD no .env; o make as repassa por -v';
END $senhas$;
\endif

-- Se alguém rodar este arquivo à mão sem passar -v, `:'api_pw'` fica literal
-- (o psql só interpola variável definida), vira erro de sintaxe e o
-- ON_ERROR_STOP=1 aborta. Os dois caminhos de falha são barulhentos.
ALTER ROLE monitor_migrate PASSWORD :'migrate_pw';
ALTER ROLE monitor_api     PASSWORD :'api_pw';
ALTER ROLE monitor_worker  PASSWORD :'worker_pw';

-- Pós-condição: papel sem verificador é papel que não loga, e descobrir isso no
-- boot do serviço é tarde.
DO $senhas$ BEGIN
    IF (SELECT count(*) FROM pg_authid
         WHERE rolname IN ('monitor_migrate','monitor_api','monitor_worker')
           AND rolpassword IS NOT NULL) <> 3 THEN
        RAISE EXCEPTION 'algum papel ficou sem senha depois do ALTER ROLE';
    END IF;
END $senhas$;

\echo 'senhas dos três papéis definidas a partir do .env'
