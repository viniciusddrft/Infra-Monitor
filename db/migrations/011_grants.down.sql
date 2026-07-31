DROP TRIGGER IF EXISTS trg_guard_suspended_reason ON urls;
DROP FUNCTION IF EXISTS guard_suspended_reason();

DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'monitor_api') THEN
        EXECUTE 'REVOKE ALL ON ALL TABLES IN SCHEMA public FROM monitor_api';
        EXECUTE 'REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM monitor_api';
        EXECUTE 'REVOKE ALL ON SCHEMA public FROM monitor_api';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'monitor_worker') THEN
        EXECUTE 'REVOKE ALL ON ALL TABLES IN SCHEMA public FROM monitor_worker';
        EXECUTE 'REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM monitor_worker';
        EXECUTE 'REVOKE ALL ON SCHEMA public FROM monitor_worker';
    END IF;
END $$;

DROP ROLE IF EXISTS monitor_worker;
DROP ROLE IF EXISTS monitor_api;
DROP ROLE IF EXISTS monitor_migrate;
