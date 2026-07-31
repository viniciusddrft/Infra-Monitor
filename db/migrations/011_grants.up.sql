-- 011: papéis, privilégios por coluna e o guarda de suspended_reason
--
-- Aqui a tabela de propriedade deixa de ser convenção. Se a API tentar
-- UPDATE urls SET current_status, o banco recusa.
--
-- As senhas vêm do ambiente; o Makefile as passa. Em produção, do gestor de
-- segredos — nunca deste arquivo.

\set migrate_pw `echo "${MONITOR_MIGRATE_PASSWORD:-migrate_dev}"`
\set api_pw     `echo "${MONITOR_API_PASSWORD:-api_dev}"`
\set worker_pw  `echo "${MONITOR_WORKER_PASSWORD:-worker_dev}"`

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'monitor_migrate') THEN
        CREATE ROLE monitor_migrate LOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'monitor_api') THEN
        CREATE ROLE monitor_api LOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'monitor_worker') THEN
        CREATE ROLE monitor_worker LOGIN;
    END IF;
END $$;

ALTER ROLE monitor_migrate PASSWORD :'migrate_pw';
ALTER ROLE monitor_api     PASSWORD :'api_pw';
ALTER ROLE monitor_worker  PASSWORD :'worker_pw';

-- `SET timezone` numa migration configura só aquela conexão. ALTER ROLE vale
-- para TODA sessão futura do papel, inclusive as do pool.
ALTER ROLE monitor_migrate SET timezone = 'UTC';
ALTER ROLE monitor_api     SET timezone = 'UTC';
ALTER ROLE monitor_worker  SET timezone = 'UTC';

GRANT USAGE ON SCHEMA public TO monitor_api, monitor_worker;
GRANT SELECT ON ALL TABLES    IN SCHEMA public TO monitor_api, monitor_worker;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO monitor_api, monitor_worker;

-- ── urls: a API escreve CONFIGURAÇÃO ────────────────────────────────────────
GRANT INSERT, DELETE ON urls TO monitor_api;
GRANT UPDATE (name, url, check_interval_seconds, timeout_seconds, expected_status_codes,
              follow_redirects, regions, paused, deleted_at, config_version,
              suspended_reason, updated_at) ON urls TO monitor_api;

-- ── urls: o Worker escreve ESTADO OBSERVADO ─────────────────────────────────
GRANT UPDATE (current_status, unknown_reason, current_status_since, last_checked_at,
              suspended_reason) ON urls TO monitor_worker;

-- GRANT por coluna diz QUEM escreve, não QUAL VALOR. `suspended_reason` tem
-- dono por CAUSA: o Worker define config_error e entitlement; a API só limpa
-- config_error ao editar a URL. Isso precisa de trigger.
-- O WHEN evita a chamada da função nos ~325 updates/s que não tocam a coluna.
CREATE OR REPLACE FUNCTION guard_suspended_reason() RETURNS TRIGGER AS $$
BEGIN
    IF current_user = 'monitor_worker'
       AND OLD.suspended_reason = 'config_error' AND NEW.suspended_reason IS NULL THEN
        RAISE EXCEPTION 'worker não limpa config_error: quem limpa é a API, ao editar a URL';
    END IF;
    IF current_user = 'monitor_api'
       AND (NEW.suspended_reason IS NOT NULL OR OLD.suspended_reason = 'entitlement') THEN
        RAISE EXCEPTION 'api só limpa config_error; entitlement pertence ao worker';
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_guard_suspended_reason
    BEFORE UPDATE ON urls
    FOR EACH ROW WHEN (OLD.suspended_reason IS DISTINCT FROM NEW.suspended_reason)
    EXECUTE FUNCTION guard_suspended_reason();

-- ── agenda: next_check_at é compartilhada, protegida pelo update condicional ─
GRANT INSERT, UPDATE, DELETE ON url_schedules TO monitor_api, monitor_worker;

GRANT UPDATE (dashboard_version)              ON teams TO monitor_worker;
GRANT UPDATE (name, dashboard_version, updated_at) ON teams TO monitor_api;
--   `teams.plan` não existe: o plano em vigor é subscriptions.plan

GRANT INSERT ON url_history TO monitor_worker;  -- a API nem insere aqui
GRANT INSERT, UPDATE, DELETE ON url_history_hourly, url_history_daily TO monitor_worker;

-- manutenção de partição: o Worker EXECUTA as funções, mas não é dono de
-- url_history nem tem CREATE no schema
REVOKE ALL ON FUNCTION public.create_history_partition(DATE) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.drop_history_partition(DATE)   FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_history_partition(DATE) TO monitor_worker;
GRANT EXECUTE ON FUNCTION public.drop_history_partition(DATE)   TO monitor_worker;

GRANT INSERT, UPDATE ON incidents TO monitor_worker;
GRANT UPDATE (acknowledged_at, acknowledged_by) ON incidents TO monitor_api;

GRANT INSERT ON notifications TO monitor_worker;
GRANT UPDATE (read_at) ON notifications TO monitor_api;

GRANT INSERT, UPDATE, DELETE ON refresh_tokens, devices, notification_prefs, invites,
      idempotency_keys, rate_events, users, teams TO monitor_api;
GRANT INSERT, UPDATE ON billing_webhook_events TO monitor_api;
GRANT UPDATE          ON billing_webhook_events TO monitor_worker;
GRANT INSERT, UPDATE  ON subscriptions TO monitor_api, monitor_worker;
GRANT INSERT          ON billing_tombstones TO monitor_api;
GRANT INSERT, UPDATE, DELETE ON devices TO monitor_worker;  -- apaga token morto do FCM
GRANT INSERT          ON audit_log TO monitor_api, monitor_worker;
GRANT INSERT, UPDATE  ON system_flags TO monitor_worker;
GRANT INSERT, UPDATE  ON worker_blindness TO monitor_worker;

-- Os serviços conectam DIRETAMENTE como estes papéis — sem login genérico com
-- SET ROLE, sem herança por membership. O trigger acima compara current_user, e
-- cada serviço afirma no boot:
--   SELECT current_user, current_setting('TimeZone');
-- divergiu, falha o boot. É o que impede o trigger de virar decorativo em
-- silêncio e as partições de nascerem com 3 horas de deslocamento.
