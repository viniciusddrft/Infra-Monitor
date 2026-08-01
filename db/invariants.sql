-- Invariantes executáveis do schema. Cada caso negativo precisa falhar pelo
-- banco; todo dado de teste é revertido ao final.
SET timezone = 'UTC';
BEGIN;

DO $test$
DECLARE uid BIGINT; tid BIGINT; urlid BIGINT;
BEGIN
    uid := nextval('users_id_seq');
    tid := nextval('teams_id_seq');
    INSERT INTO users (id, google_sub, email, name, team_id, role)
    VALUES (uid, 'invariant-'||uid, 'invariant@example.com', 'Invariant', tid, 'owner');
    INSERT INTO teams (id, name, owner_user_id) VALUES (tid, 'Invariant', uid);
    INSERT INTO subscriptions (team_id, plan) VALUES (tid, 'free');
    INSERT INTO notification_prefs (user_id) VALUES (uid);
    INSERT INTO urls (team_id, created_by_user_id, name, url, check_interval_seconds)
    VALUES (tid, uid, 'Invariant URL', 'https://example.com', 300)
    RETURNING id INTO urlid;

    IF (SELECT unknown_reason FROM urls WHERE id=urlid) <> 'never_checked' THEN
        RAISE EXCEPTION 'default unknown_reason incorreto';
    END IF;

    BEGIN
        INSERT INTO users (google_sub,email,name,role)
        VALUES ('sem-time','sem-time@example.com','Sem time','owner');
        RAISE EXCEPTION 'NOT NULL users.team_id não recusou';
    EXCEPTION WHEN not_null_violation THEN NULL;
    END;
    BEGIN
        UPDATE urls SET current_status='unknown', unknown_reason=NULL WHERE id=urlid;
        RAISE EXCEPTION 'unknown sem motivo foi aceito';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE urls SET check_interval_seconds=10 WHERE id=urlid;
        RAISE EXCEPTION 'intervalo 10 foi aceito';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO url_schedules(url_id,region_code,next_check_at,shard_key,lease_token)
        VALUES(urlid,'sa-east',now(),0,gen_random_uuid());
        RAISE EXCEPTION 'lease parcial foi aceito';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO incidents(url_id,team_id,started_at) VALUES(urlid,tid,now());
        INSERT INTO incidents(url_id,team_id,started_at) VALUES(urlid,tid,now());
        RAISE EXCEPTION 'dois incidentes abertos foram aceitos';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        UPDATE notification_prefs SET quiet_from='22:00', quiet_to=NULL
        WHERE user_id=uid;
        RAISE EXCEPTION 'quiet hours parcial foi aceito';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
END $test$;

ROLLBACK;
\echo 'ok: constraints e primeiros inserts'
