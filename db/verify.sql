-- Confere que o schema aplicou inteiro. `make verify`.
--
-- Isto é um PORTÃO: invariante quebrada vira RAISE EXCEPTION e o psql sai 3.
-- A versão anterior só imprimia `ok = f` e saía 0 — ON_ERROR_STOP só dispara em
-- erro SQL de verdade, não em consulta que devolve false. Um portão que não
-- reprova é um relatório.
--
-- Roda como o superusuário do container (`make verify`): a checagem de senha lê
-- pg_authid, que exige superusuário.
--
-- Espera o bootstrap completo: 001→011, roles-pw, river, 012, seed.

-- pg_get_expr() renderiza limite de partição no fuso da SESSÃO. Sem isto, a
-- invariante de meia-noite UTC passaria a depender de quem está rodando.
SET timezone = 'UTC';

\echo '── contagens ──'
SELECT 'tabelas'   AS objeto, count(*)::text AS valor
  FROM information_schema.tables WHERE table_schema = 'public'
UNION ALL SELECT 'planos',    count(*)::text FROM plans
UNION ALL SELECT 'produtos',  count(*)::text FROM plan_products
UNION ALL SELECT 'regioes',   count(*)::text FROM regions
UNION ALL SELECT 'flags',     count(*)::text FROM system_flags
UNION ALL SELECT 'particoes', count(*)::text FROM pg_class
  WHERE relkind = 'r' AND relname ~ '^url_history_[0-9]{8}$'
UNION ALL SELECT 'papeis',    count(*)::text FROM pg_roles
  WHERE rolname IN ('monitor_migrate','monitor_api','monitor_worker')
-- subconsulta em pg_namespace, e não 'river'::regnamespace: o cast ERRA se o
-- schema não existir, e esta consulta roda ANTES da guarda lá embaixo — daria
-- um "schema river does not exist" cru no lugar da mensagem com o HINT
UNION ALL SELECT 'tabelas river', count(*)::text FROM pg_class
  WHERE relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'river')
    AND relkind IN ('r','p')
UNION ALL SELECT 'timezone',  current_setting('TimeZone');

\echo '── invariantes (quebrou => psql sai 3) ──'
DO $verify$
DECLARE
    falhas TEXT;
BEGIN
    -- Pré-condições, para dar mensagem clara em vez de erro no meio do VALUES
    IF (SELECT count(*) FROM pg_roles
         WHERE rolname IN ('monitor_migrate','monitor_api','monitor_worker')) <> 3 THEN
        RAISE EXCEPTION 'papéis ausentes: a 011 não rodou';
    END IF;
    IF to_regclass('river.river_job') IS NULL THEN
        RAISE EXCEPTION 'schema river ausente'
          USING HINT = 'rode `make river` antes de `make migrate-up` — ou apenas `make migrate`';
    END IF;

    SELECT string_agg(nome, E'\n  ' ORDER BY nome) INTO falhas FROM (VALUES

      -- ── estrutura ────────────────────────────────────────────────────────
      ('incidente aberto único',
       EXISTS (SELECT 1 FROM pg_indexes
                WHERE indexname='idx_incidents_open' AND indexdef LIKE '%UNIQUE%')),
      ('índice do claim é parcial',
       EXISTS (SELECT 1 FROM pg_indexes
                WHERE indexname='idx_schedules_due' AND indexdef LIKE '%WHERE%')),
      ('dedup de notificação por usuário',
       EXISTS (SELECT 1 FROM pg_indexes WHERE indexname='idx_notifications_dedup_incident')),
      ('trigger de suspended_reason',
       EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='trg_guard_suspended_reason')),
      -- count(*) FILTER, e não bool_and: bool_and sobre ZERO linha devolve NULL,
      -- e NULL imprimia em branco e passava por bom na versão antiga
      ('funções de partição são SECURITY DEFINER',
       (SELECT count(*) FILTER (WHERE prosecdef) = 2 FROM pg_proc
         WHERE proname IN ('create_history_partition','drop_history_partition'))),
      ('teams.plan NÃO existe (fonte única em subscriptions)',
       NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema='public' AND table_name='teams' AND column_name='plan')),
      ('url_schedules tem fillfactor 70',
       (SELECT COALESCE(bool_or(reloptions::text LIKE '%fillfactor=70%'), false)
          FROM pg_class WHERE relname='url_schedules'
           AND relnamespace='public'::regnamespace)),

      -- ── GRANT por coluna: é a alegação central do schema ──────────────────
      ('api NÃO escreve urls.current_status',
       NOT has_column_privilege('monitor_api','public.urls','current_status','UPDATE')),
      ('api NÃO escreve urls.unknown_reason',
       NOT has_column_privilege('monitor_api','public.urls','unknown_reason','UPDATE')),
      ('api NÃO escreve urls.last_checked_at',
       NOT has_column_privilege('monitor_api','public.urls','last_checked_at','UPDATE')),
      ('api escreve urls.name',
       has_column_privilege('monitor_api','public.urls','name','UPDATE')),
      ('worker NÃO escreve urls.name',
       NOT has_column_privilege('monitor_worker','public.urls','name','UPDATE')),
      ('worker NÃO escreve urls.paused',
       NOT has_column_privilege('monitor_worker','public.urls','paused','UPDATE')),
      ('worker escreve urls.current_status',
       has_column_privilege('monitor_worker','public.urls','current_status','UPDATE')),
      ('os dois escrevem urls.suspended_reason (quem arbitra é o trigger)',
       has_column_privilege('monitor_api','public.urls','suspended_reason','UPDATE')
       AND has_column_privilege('monitor_worker','public.urls','suspended_reason','UPDATE')),
      -- has_column_privilege devolve true se o privilégio existe no NÍVEL DA
      -- TABELA: é por isso que ele é a sonda certa para pegar um UPDATE amplo
      -- reintroduzido em teams
      ('api NÃO escreve teams.created_at (UPDATE de teams é por coluna)',
       NOT has_column_privilege('monitor_api','public.teams','created_at','UPDATE')),
      ('api NÃO escreve teams.owner_user_id',
       NOT has_column_privilege('monitor_api','public.teams','owner_user_id','UPDATE')),
      ('api escreve teams.name',
       has_column_privilege('monitor_api','public.teams','name','UPDATE')),
      ('worker só escreve teams.dashboard_version',
       has_column_privilege('monitor_worker','public.teams','dashboard_version','UPDATE')
       AND NOT has_column_privilege('monitor_worker','public.teams','name','UPDATE')),
      ('api NÃO insere em url_history',
       NOT has_table_privilege('monitor_api','public.url_history','INSERT')),
      ('worker insere e apaga url_history (caminho quente + purge_url_history)',
       has_table_privilege('monitor_worker','public.url_history','INSERT')
       AND has_table_privilege('monitor_worker','public.url_history','DELETE')),
      ('worker apaga o que os jobs cleanup/stale_devices apagam',
       has_table_privilege('monitor_worker','public.idempotency_keys','DELETE')
       AND has_table_privilege('monitor_worker','public.rate_events','DELETE')
       AND has_table_privilege('monitor_worker','public.invites','DELETE')
       AND has_table_privilege('monitor_worker','public.refresh_tokens','DELETE')
       AND has_table_privilege('monitor_worker','public.devices','DELETE')),
      ('nenhum serviço cria objeto no schema public',
       NOT has_schema_privilege('monitor_api','public','CREATE')
       AND NOT has_schema_privilege('monitor_worker','public','CREATE')),
      ('worker executa as funções de partição',
       has_function_privilege('monitor_worker','public.create_history_partition(date)','EXECUTE')
       AND has_function_privilege('monitor_worker','public.drop_history_partition(date)','EXECUTE')),
      -- as DUAS funções, individualmente: antes só create_ era checada, e
      -- drop_history_partition é a que apaga dado
      ('api NÃO executa as funções de partição',
       NOT has_function_privilege('monitor_api','public.create_history_partition(date)','EXECUTE')
       AND NOT has_function_privilege('monitor_api','public.drop_history_partition(date)','EXECUTE')),
      -- COALESCE com acldefault() é o ponto: função recém-criada tem proacl
      -- NULL, e NULL significa "os privilégios padrão", que INCLUEM EXECUTE
      -- para PUBLIC. Sem o COALESCE, aclexplode(NULL) não devolve linha, o
      -- NOT EXISTS dava true e a invariante passava exatamente no estado que
      -- ela existe para pegar: alguém remover os REVOKE da 011.
      ('PUBLIC não executa as funções de partição',
       NOT EXISTS (SELECT 1
                     FROM pg_proc p,
                          aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
                    WHERE p.proname IN ('create_history_partition','drop_history_partition')
                      AND p.pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
                      AND a.grantee = 0
                      AND a.privilege_type = 'EXECUTE')),

      -- ── papéis ───────────────────────────────────────────────────────────
      ('os três papéis logam e não têm superpoder',
       (SELECT count(*) = 3 FROM pg_roles
         WHERE rolname IN ('monitor_migrate','monitor_api','monitor_worker')
           AND rolcanlogin AND NOT rolsuper AND NOT rolcreatedb
           AND NOT rolcreaterole AND NOT rolbypassrls)),
      ('os três papéis nascem em UTC (ALTER ROLE ... SET timezone)',
       (SELECT count(*) = 3 FROM pg_roles
         WHERE rolname IN ('monitor_migrate','monitor_api','monitor_worker')
           AND EXISTS (SELECT 1 FROM unnest(rolconfig) c WHERE lower(c) = 'timezone=utc'))),
      ('os três papéis têm senha (make roles-pw rodou)',
       (SELECT count(*) = 3 FROM pg_authid
         WHERE rolname IN ('monitor_migrate','monitor_api','monitor_worker')
           AND rolpassword IS NOT NULL)),

      -- ── river ────────────────────────────────────────────────────────────
      ('os dois usam o schema river',
       has_schema_privilege('monitor_api','river','USAGE')
       AND has_schema_privilege('monitor_worker','river','USAGE')),
      ('api enfileira em river_job, e SÓ isso',
       has_table_privilege('monitor_api','river.river_job','SELECT')
       AND has_table_privilege('monitor_api','river.river_job','INSERT')
       AND NOT has_table_privilege('monitor_api','river.river_job','UPDATE')
       AND NOT has_table_privilege('monitor_api','river.river_job','DELETE')),
      -- pega o upgrade de River que cria tabela nova sem privilégio.
      -- Os quatro privilégios em chamadas SEPARADAS, e não
      -- 'SELECT,INSERT,UPDATE,DELETE' numa só: com lista, has_table_privilege
      -- devolve true se QUALQUER um dos listados existir. Uma tabela só com
      -- SELECT passaria, e a invariante estaria mentindo.
      ('worker consome TODA tabela do schema river',
       (SELECT COALESCE(bool_and(
                    has_table_privilege('monitor_worker', c.oid, 'SELECT')
                AND has_table_privilege('monitor_worker', c.oid, 'INSERT')
                AND has_table_privilege('monitor_worker', c.oid, 'UPDATE')
                AND has_table_privilege('monitor_worker', c.oid, 'DELETE')), false)
          FROM pg_class c
         WHERE c.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'river')
           AND c.relkind IN ('r','p'))),

      -- ── semente e partições ──────────────────────────────────────────────
      ('plans: grátis 5 urls / 300s / 30d',
       EXISTS (SELECT 1 FROM plans WHERE code='free' AND max_urls=5
                 AND min_interval_seconds=300 AND retention_days=30)),
      ('plans: pago 50 urls / 60s / 90d',
       EXISTS (SELECT 1 FROM plans WHERE code='pro' AND max_urls=50
                 AND min_interval_seconds=60 AND retention_days=90)),
      ('plan_products: pro mensal E anual, ativos',
       (SELECT count(*) = 2 FROM plan_products
         WHERE plan_code='pro' AND period IN ('monthly','annual') AND active)),
      ('regions tem sa-east habilitada',
       EXISTS (SELECT 1 FROM regions WHERE code='sa-east' AND enabled)),
      ('system_flags com as três chaves de operação',
       (SELECT count(*) = 3 FROM system_flags
         WHERE key IN ('checks_enabled','blocked_target_hosts','min_app_version'))),
      ('schema_migrations = 12 e limpa (fonte do check de boot)',
       (SELECT version = 12 AND NOT dirty FROM schema_migrations)),
      ('api e worker só leem schema_migrations',
       has_table_privilege('monitor_api','public.schema_migrations','SELECT')
       AND has_table_privilege('monitor_worker','public.schema_migrations','SELECT')
       AND NOT has_table_privilege('monitor_api','public.schema_migrations','UPDATE')
       AND NOT has_table_privilege('monitor_worker','public.schema_migrations','UPDATE')),
      ('4 partições de url_history (hoje + 3)',
       (SELECT count(*) >= 4 FROM pg_class
         WHERE relkind='r' AND relname ~ '^url_history_[0-9]{8}$')),
      ('toda partição nasce e morre à meia-noite UTC',
       (SELECT COALESCE(bool_and(pg_get_expr(c.relpartbound, c.oid) LIKE '%00:00:00+00%'), false)
          FROM pg_class c
         WHERE c.relispartition AND c.relname ~ '^url_history_[0-9]{8}$'))

    ) AS t(nome, ok)
     -- IS DISTINCT FROM true pega false E NULL. Era o NULL que escapava antes.
     WHERE ok IS DISTINCT FROM true;

    IF falhas IS NOT NULL THEN
        RAISE EXCEPTION E'verify: invariante(s) quebrada(s):\n  %', falhas;
    END IF;
END $verify$;
-- \echo e não RAISE NOTICE: o Makefile roda com --client-min-messages=warning e
-- engoliria o NOTICE. E com ON_ERROR_STOP=1 esta linha só é alcançada se o
-- bloco acima não abortou, então ela é uma afirmação, não um otimismo.
\echo 'ok: todas as invariantes'

\echo '── amostra do seed ──'
SELECT u.id, u.name, u.current_status, u.unknown_reason, u.paused,
       s.next_check_at
  FROM urls u LEFT JOIN url_schedules s ON s.url_id = u.id
 ORDER BY u.id LIMIT 20;
