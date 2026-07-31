-- Confere que o schema aplicou inteiro. `make verify`.

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
UNION ALL SELECT 'timezone',  current_setting('TimeZone');

\echo '── invariantes que o banco tem que garantir ──'
SELECT 'incidente aberto único' AS invariante,
       EXISTS (SELECT 1 FROM pg_indexes
                WHERE indexname = 'idx_incidents_open' AND indexdef LIKE '%UNIQUE%') AS ok
UNION ALL
SELECT 'índice do claim é parcial',
       EXISTS (SELECT 1 FROM pg_indexes
                WHERE indexname = 'idx_schedules_due' AND indexdef LIKE '%WHERE%')
UNION ALL
SELECT 'dedup de notificação por usuário',
       EXISTS (SELECT 1 FROM pg_indexes
                WHERE indexname = 'idx_notifications_dedup_incident')
UNION ALL
SELECT 'trigger de suspended_reason',
       EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_guard_suspended_reason')
UNION ALL
SELECT 'funções de partição são SECURITY DEFINER',
       (SELECT bool_and(prosecdef) FROM pg_proc
         WHERE proname IN ('create_history_partition','drop_history_partition'))
UNION ALL
SELECT 'teams.plan NÃO existe (fonte única em subscriptions)',
       NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_name = 'teams' AND column_name = 'plan')
UNION ALL
SELECT 'url_schedules tem fillfactor 70',
       (SELECT reloptions::text LIKE '%fillfactor=70%' FROM pg_class
         WHERE relname = 'url_schedules');

\echo '── amostra do seed ──'
SELECT u.id, u.name, u.current_status, u.unknown_reason, u.paused,
       s.next_check_at
  FROM urls u LEFT JOIN url_schedules s ON s.url_id = u.id
 ORDER BY u.id LIMIT 20;
