-- Consultas de operação. `make check` roda todas.
-- São as perguntas que pegam falha SILENCIOSA, que é a categoria que mata um
-- produto de uptime.

\echo '── 1. atraso do agendamento (o canário de toda falha silenciosa) ──'
SELECT count(*) AS atrasadas,
       COALESCE(max(now() - next_check_at)::text, '-') AS pior_atraso
  FROM url_schedules
 WHERE next_check_at < now() - interval '60 seconds'
   AND next_check_at <> 'infinity';

\echo '── 2. lease órfão (o reaper parou?) ──'
SELECT count(*) AS leases_vencidos
  FROM url_schedules WHERE lease_expires_at < now() - interval '5 minutes';

\echo '── 3. resultados zumbi nas últimas 24h (corrida API/Worker frequente?) ──'
SELECT date_trunc('hour', checked_at) AS hora, count(*) AS zumbis
  FROM url_history
 WHERE applied = false AND checked_at > now() - interval '24 hours'
 GROUP BY 1 ORDER BY 1;

\echo '── 4. URL ativa sem linha de agenda ──'
SELECT u.id, u.name
  FROM urls u LEFT JOIN url_schedules s ON s.url_id = u.id
 WHERE u.deleted_at IS NULL AND u.paused = false AND u.suspended_reason IS NULL
   AND s.url_id IS NULL;

\echo '── 5. instâncias cegas agora (o que o app vê como brake_engaged) ──'
SELECT instance_id, region_code, engaged_since, controls_failing, controls_total
  FROM worker_blindness
 WHERE engaged AND updated_at > now() - interval '60 seconds';

\echo '── 6. divergência entre estado e última amostra aplicada ──'
SELECT u.id, u.current_status, h.status AS ultimo_observado
  FROM urls u JOIN LATERAL (
       SELECT status FROM url_history
        WHERE url_id = u.id AND applied ORDER BY checked_at DESC LIMIT 1) h ON true
 WHERE u.current_status <> h.status AND u.deleted_at IS NULL;

\echo '── 7. DINHEIRO: compras pendentes de acknowledge (revertidas em 3 dias) ──'
SELECT team_id, ack_state, ack_attempts, updated_at
  FROM subscriptions WHERE ack_state IN ('pending','failed');

\echo '── 8. RTDN não processado ──'
SELECT count(*) AS pendentes, min(received_at) AS mais_antigo
  FROM billing_webhook_events WHERE processed_at IS NULL;

\echo '── 9. bloat na tabela quente ──'
SELECT relname, n_live_tup, n_dead_tup,
       round(100.0*n_dead_tup/NULLIF(n_live_tup,0),1) AS pct_morto, last_autovacuum
  FROM pg_stat_user_tables WHERE relname = 'url_schedules';

\echo '── 10. tamanho por objeto ──'
SELECT relname, pg_size_pretty(pg_total_relation_size(oid)) AS tamanho
  FROM pg_class
 WHERE relnamespace = 'public'::regnamespace AND relkind IN ('r','p')
 ORDER BY pg_total_relation_size(oid) DESC LIMIT 10;
