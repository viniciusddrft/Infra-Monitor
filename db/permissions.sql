-- Teste de permissão da fase 0. `make test-permissions`.
--
-- Quebrou => RAISE EXCEPTION => ON_ERROR_STOP => psql sai 3.
--
-- Conecta como CADA papel real, pelo socket do container (o pg_hba da imagem
-- traz `local all all trust`), num arquivo e num processo só. Isso mantém a
-- sequência explícita e faz a primeira regressão derrubar tudo.
--
-- As SENHAS não são provadas aqui, de propósito: é `make test-login`, por TCP
-- a partir de outro container na rede Compose (regra host/scram). Testar pelo
-- socket ou pelo loopback do próprio Postgres seria autoengano: ambos caem em
-- trust nesta imagem e qualquer senha "funcionaria".
--
-- Exige `make seed` antes: alguns casos precisam de linha real em urls.

SET timezone = 'UTC';

-- Fallback: se o seu pg_hba não estiver em trust, estas linhas fazem o \c
-- funcionar mesmo assim. Sob trust são inofensivas.
\setenv PGPASSWORD :api_pw

-- ═══════════════════════════════════════════════════════════════════════════
--  monitor_api
-- ═══════════════════════════════════════════════════════════════════════════
\c - monitor_api

-- Guarda de identidade. Sem ela, um \c que falhou em silêncio deixaria a
-- sessão como superusuário e TODO caso "tem que funcionar" passaria por engano.
-- É a mesma razão pela qual cada serviço afirma current_user no boot.
DO $t$ BEGIN
    IF current_user <> 'monitor_api' THEN
        RAISE EXCEPTION 'conectado como % — o \c falhou e o teste inteiro seria vazio', current_user
          USING ERRCODE = 'ZZ001';
    END IF;
    -- Critério da fase 0: sessão NOVA já nasce em UTC, sem SET explícito.
    IF current_setting('TimeZone') <> 'UTC' THEN
        RAISE EXCEPTION 'sessão nova de monitor_api não nasceu em UTC (%) — sumiu o ALTER ROLE ... SET timezone da 011',
          current_setting('TimeZone') USING ERRCODE = 'ZZ001';
    END IF;
END $t$;

-- ── o que a API NÃO pode escrever ──────────────────────────────────────────
--
-- Padrão dos casos negativos, e cada detalhe carrega peso:
--   * plpgsql é o único try/catch que o psql tem;
--   * `WHERE false` — a checagem de privilégio acontece na PARTIDA do executor,
--     antes de tocar linha, então o caso não depende do seed e não escreve nada
--     nem se o GRANT estiver errado;
--   * ERRCODE 'ZZ001' no raise de regressão: `RAISE EXCEPTION` puro é P0001
--     (raise_exception), que é justamente o que o handler do teste do trigger
--     mais abaixo captura. Sem o código próprio, a regressão seria engolida
--     pelo seu próprio catch e o teste passaria quebrado.
DO $t$
DECLARE
    caso RECORD;
BEGIN
    FOR caso IN SELECT * FROM (VALUES
        ('urls.current_status',  $q$UPDATE urls SET current_status = 'up' WHERE false$q$),
        ('urls.unknown_reason',  $q$UPDATE urls SET unknown_reason = 'blind' WHERE false$q$),
        ('urls.last_checked_at', $q$UPDATE urls SET last_checked_at = now() WHERE false$q$),
        -- guarda do defeito do UPDATE amplo em teams
        ('teams.created_at',     $q$UPDATE teams SET created_at = now() WHERE false$q$),
        ('teams.owner_user_id',  $q$UPDATE teams SET owner_user_id = 1 WHERE false$q$),
        ('INSERT em url_history',
         $q$INSERT INTO url_history (url_id, region_code, checked_at, status)
            SELECT 1,'sa-east',now(),'up' WHERE false$q$),
        ('UPDATE schema_migrations', $q$UPDATE schema_migrations SET version = 999 WHERE false$q$),
        ('DELETE schema_migrations', $q$DELETE FROM schema_migrations WHERE false$q$)
    ) AS t(alvo, sql)
    LOOP
        BEGIN
            EXECUTE caso.sql;
            RAISE EXCEPTION 'REGRESSÃO: monitor_api escreveu %', caso.alvo
              USING ERRCODE = 'ZZ001';
        EXCEPTION WHEN insufficient_privilege THEN
            NULL;  -- recusado, que é o esperado
        END;
    END LOOP;
END $t$;
\echo 'ok: api recusada em current_status, unknown_reason, last_checked_at, teams.* e url_history'

-- ── o que a API TEM que conseguir ──────────────────────────────────────────
-- Os dois caminhos que a revisão 2 do schema não permitia executar.
BEGIN;
DO $t$
DECLARE uid BIGINT; tid BIGINT; nova BIGINT; razao TEXT;
BEGIN
    -- Receita de IDs reservados: users.team_id e teams.owner_user_id são os
    -- dois NOT NULL e apontam um para o outro. DEFERRABLE adia a checagem
    -- REFERENCIAL até o COMMIT, mas NOT NULL não é adiável — então os dois IDs
    -- precisam existir antes do primeiro INSERT.
    uid := nextval('users_id_seq');
    tid := nextval('teams_id_seq');

    INSERT INTO users (id, google_sub, email, name, team_id, role)
    VALUES (uid, 'perm-test-'||uid, 'perm'||uid||'@exemplo.com', 'Perm Test', tid, 'owner');

    INSERT INTO teams (id, name, owner_user_id) VALUES (tid, 'Time do teste', uid);
    INSERT INTO subscriptions (team_id, plan) VALUES (tid, 'free');
    INSERT INTO notification_prefs (user_id) VALUES (uid);

    -- INSERT INTO urls SEM informar unknown_reason: o DEFAULT tem que cobrir o
    -- CHECK ((current_status='unknown') = (unknown_reason IS NOT NULL)).
    INSERT INTO urls (team_id, created_by_user_id, name, url, check_interval_seconds)
    VALUES (tid, uid, 'Alvo do teste', 'http://localhost:8081/ok', 300)
    RETURNING unknown_reason, id INTO razao, nova;

    IF razao IS DISTINCT FROM 'never_checked' THEN
        RAISE EXCEPTION 'urls.unknown_reason não caiu no DEFAULT: %', COALESCE(razao,'NULL')
          USING ERRCODE = 'ZZ001';
    END IF;

    INSERT INTO url_schedules (url_id, region_code, next_check_at, shard_key)
    VALUES (nova, 'sa-east', now(), 0);
END $t$;

-- Sem isto o ROLLBACK faria o teste passar SEM NUNCA verificar as FKs
-- circulares — elas são INITIALLY DEFERRED e só seriam checadas no COMMIT, que
-- nunca acontece. É a diferença entre testar a receita e testar nada.
SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;
\echo 'ok: receita de IDs reservados e INSERT em urls sem unknown_reason'

-- ── a API enfileira job com o papel real ───────────────────────────────────
-- Prova os GRANT qualificados do schema river, que só falham em runtime.
BEGIN;
DO $t$
DECLARE k TEXT;
BEGIN
    FOREACH k IN ARRAY ARRAY['notify','push_send','email_send','purge_url_history'] LOOP
        INSERT INTO river.river_job (kind, queue, args, max_attempts)
        VALUES (k, 'default', '{}'::jsonb, 25);
    END LOOP;
    -- SELECT junto porque o insert com UniqueOpts consulta antes de inserir:
    -- sem SELECT o producer quebra em runtime, com o INSERT funcionando.
    IF (SELECT count(*) FROM river.river_job WHERE kind = 'notify') = 0 THEN
        RAISE EXCEPTION 'INSERT em river_job não voltou no SELECT' USING ERRCODE = 'ZZ001';
    END IF;
END $t$;
ROLLBACK;
\echo 'ok: api enfileira em river.river_job com o papel real'

-- ═══════════════════════════════════════════════════════════════════════════
--  monitor_worker
-- ═══════════════════════════════════════════════════════════════════════════
\setenv PGPASSWORD :worker_pw
\c - monitor_worker

DO $t$ BEGIN
    IF current_user <> 'monitor_worker' THEN
        RAISE EXCEPTION 'conectado como % — o \c falhou', current_user USING ERRCODE = 'ZZ001';
    END IF;
    IF current_setting('TimeZone') <> 'UTC' THEN
        RAISE EXCEPTION 'sessão nova de monitor_worker não nasceu em UTC (%)',
          current_setting('TimeZone') USING ERRCODE = 'ZZ001';
    END IF;
END $t$;

DO $t$
DECLARE
    caso RECORD;
BEGIN
    FOR caso IN SELECT * FROM (VALUES
        ('urls.name',    $q$UPDATE urls SET name = 'nao devia' WHERE false$q$),
        ('urls.paused',  $q$UPDATE urls SET paused = true WHERE false$q$),
        ('urls.url',     $q$UPDATE urls SET url = 'http://nao.devia/' WHERE false$q$),
        ('DELETE users', $q$DELETE FROM users WHERE false$q$),
        ('UPDATE schema_migrations', $q$UPDATE schema_migrations SET version = 999 WHERE false$q$),
        ('DELETE schema_migrations', $q$DELETE FROM schema_migrations WHERE false$q$),
        -- o worker executa as funções de partição, mas não tem DDL próprio
        ('CREATE TABLE', $q$CREATE TABLE nao_devia_existir (i INT)$q$)
    ) AS t(alvo, sql)
    LOOP
        BEGIN
            EXECUTE caso.sql;
            RAISE EXCEPTION 'REGRESSÃO: monitor_worker conseguiu %', caso.alvo
              USING ERRCODE = 'ZZ001';
        EXCEPTION WHEN insufficient_privilege THEN
            NULL;
        END;
    END LOOP;
END $t$;
\echo 'ok: worker recusado em urls.name, urls.paused, urls.url, DELETE users e CREATE TABLE'

-- ── manutenção de partição: a exceção de DDL é a FUNÇÃO, não o papel ───────
BEGIN;
SELECT create_history_partition((now() AT TIME ZONE 'UTC')::date + 7);
ROLLBACK;
\echo 'ok: worker executa create_history_partition() sem ter DDL'

-- ── escrita e purga do histórico, pelo pai particionado ────────────────────
-- Resolve empiricamente se GRANT no pai cobre as partições — a alternativa
-- seria discutir a documentação.
BEGIN;
INSERT INTO url_history (url_id, region_code, checked_at, status, response_time_ms, http_status, applied)
SELECT min(id), 'sa-east', now(), 'up', 120, 200, true FROM urls;
DO $t$ BEGIN
    IF (SELECT count(*) FROM url_history WHERE response_time_ms = 120) = 0 THEN
        RAISE EXCEPTION 'INSERT em url_history não chegou na partição' USING ERRCODE = 'ZZ001';
    END IF;
END $t$;
DELETE FROM url_history WHERE response_time_ms = 120;  -- purge_url_history
ROLLBACK;
\echo 'ok: worker insere e apaga url_history pelo pai particionado'

-- ── o trigger, com o papel real ────────────────────────────────────────────
-- É o que impede guard_suspended_reason() de virar decorativo: ele compara
-- current_user, e sob o superusuário do seed nenhum dos dois ramos dispara.
BEGIN;
UPDATE urls SET suspended_reason = 'config_error' WHERE id = (SELECT min(id) FROM urls);
DO $t$ BEGIN
    BEGIN
        UPDATE urls SET suspended_reason = NULL WHERE id = (SELECT min(id) FROM urls);
        RAISE EXCEPTION 'REGRESSÃO: o worker limpou config_error' USING ERRCODE = 'ZZ001';
    EXCEPTION WHEN raise_exception THEN
        -- P0001 é o RAISE do trigger. O nosso raise usa ZZ001 justamente para
        -- não cair aqui.
        NULL;
    END;
END $t$;
ROLLBACK;
\echo 'ok: trigger recusa o worker limpar config_error (comparação por current_user viva)'

-- ── partição sob fuso hostil ───────────────────────────────────────────────
-- SECURITY DEFINER fixa search_path, NÃO timezone: o fuso da sessão que cria a
-- partição é de verdade diferente aqui.
BEGIN;
SET LOCAL timezone = 'America/Sao_Paulo';
SELECT create_history_partition(DATE '2031-03-05');
SET LOCAL timezone = 'UTC';
SELECT create_history_partition(DATE '2031-03-06');
DO $t$
DECLARE a TEXT; b TEXT;
BEGIN
    -- lido em UTC de propósito: pg_get_expr renderiza no fuso de QUEM LÊ
    SELECT pg_get_expr(relpartbound, oid) INTO a FROM pg_class WHERE relname = 'url_history_20310305';
    SELECT pg_get_expr(relpartbound, oid) INTO b FROM pg_class WHERE relname = 'url_history_20310306';
    IF a IS NULL OR b IS NULL THEN
        RAISE EXCEPTION 'partição de teste não foi criada' USING ERRCODE = 'ZZ001';
    END IF;
    IF a NOT LIKE '%2031-03-05 00:00:00+00%' OR a NOT LIKE '%2031-03-06 00:00:00+00%'
       OR b NOT LIKE '%2031-03-06 00:00:00+00%' OR b NOT LIKE '%2031-03-07 00:00:00+00%' THEN
        RAISE EXCEPTION E'partição criada sob outro fuso não nasceu à meia-noite UTC:\n  %\n  %', a, b
          USING ERRCODE = 'ZZ001';
    END IF;
END $t$;
ROLLBACK;
\echo 'ok: partições criadas sob fusos diferentes têm os mesmos limites'

\echo ''
\echo 'teste de permissão: tudo passou'
