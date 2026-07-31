-- Seed de desenvolvimento. Idempotente: pode rodar de novo sem duplicar.
--
-- Além de dar dados para olhar, este arquivo é o exemplo executável de duas
-- coisas fáceis de errar: a criação do primeiro usuário (FKs circulares) e a
-- criação de URL junto da agenda, na mesma transação.

SET timezone = 'UTC';

BEGIN;

-- ── usuário e time ──────────────────────────────────────────────────────────
-- users.team_id e teams.owner_user_id são ambos NOT NULL e apontam um para o
-- outro. DEFERRABLE adia a verificação REFERENCIAL até o COMMIT — NÃO adia o
-- NOT NULL, que é constraint de coluna. Por isso os dois IDs são reservados
-- ANTES de qualquer INSERT.
DO $$
DECLARE
    uid BIGINT;
    tid BIGINT;
BEGIN
    IF EXISTS (SELECT 1 FROM users WHERE google_sub = 'dev-google-sub-0001') THEN
        RAISE NOTICE 'seed já aplicado, pulando identidade';
        RETURN;
    END IF;

    uid := nextval('users_id_seq');
    tid := nextval('teams_id_seq');

    INSERT INTO users (id, google_sub, email, name, team_id, role)
    VALUES (uid, 'dev-google-sub-0001', 'dev@exemplo.com', 'Dev Local', tid, 'owner');

    INSERT INTO teams (id, name, owner_user_id)
    VALUES (tid, 'Time de Desenvolvimento', uid);

    INSERT INTO subscriptions (team_id, plan) VALUES (tid, 'free');
    INSERT INTO notification_prefs (user_id) VALUES (uid);
END $$;

-- ── monitores ───────────────────────────────────────────────────────────────
-- Cada alvo exercita um caminho diferente do worker. Os `exemplo.com` vêm do
-- draft: como não resolvem, são alvo de FALHA GARANTIDA por DNS — o que os
-- torna úteis para o caminho de queda, que é o mais difícil de reproduzir.
--
-- O host `localhost:8081` é o nginx do compose. O worker rodando na máquina
-- alcança ali; rodando dentro do compose, seria http://alvo-local/.
-- Lembre que o guard de SSRF bloqueia loopback por padrão: em dev é preciso
-- SSRF_ALLOWED_CIDRS=127.0.0.0/8 (ver .env.example).
WITH time_dev AS (
    SELECT t.id AS team_id, u.id AS user_id
      FROM teams t JOIN users u ON u.id = t.owner_user_id
     WHERE u.google_sub = 'dev-google-sub-0001'
),
novas AS (
    INSERT INTO urls (team_id, created_by_user_id, name, url,
                      check_interval_seconds, timeout_seconds, expected_status_codes,
                      follow_redirects, paused)
    SELECT d.team_id, d.user_id, v.nome, v.url, v.intervalo, v.timeout,
           v.esperados, v.segue_redirect, v.pausada
      FROM time_dev d, (VALUES
        -- caminho feliz: sobe e continua no ar
        ('Alvo local OK',          'http://localhost:8081/ok',                  60, 10, '{200}'::INT[],           true,  false),
        -- cai por status: 500 persistente. É o bug B2 do rascunho, que
        -- derrubava o worker inteiro por dereferência de resposta nula
        ('Alvo local 500',         'http://localhost:8081/erro',                60, 10, '{200}'::INT[],           true,  false),
        -- cai por status fora do conjunto esperado
        ('Alvo local 404',         'http://localhost:8081/nao-encontrado',      60, 10, '{200}'::INT[],           true,  false),
        -- redirect que termina bem: up com 1 salto
        ('Alvo local redirect',    'http://localhost:8081/redireciona',        120, 10, '{200}'::INT[],           true,  false),
        -- redirect de alvo público para metadata de nuvem:
        -- unknown / ssrf_blocked, bloqueado no salto pelo Dialer.Control
        ('Alvo redirect privado',  'http://localhost:8081/redireciona-privado', 300, 10, '{200}'::INT[],          true,  false),
        -- cadeia de 6 saltos, acima do máximo de 5: too_many_redirects
        ('Alvo cadeia longa',      'http://localhost:8081/cadeia',              300, 10, '{200}'::INT[],          true,  false),
        -- FALHA GARANTIDA por DNS (domínios do draft, não resolvem)
        ('API Principal',          'https://api.exemplo.com/health',            300, 10, '{200}'::INT[],          true,  false),
        ('Serviço de Login',       'https://auth.exemplo.com/health',           300, 10, '{200,204}'::INT[],      true,  false),
        -- pausada pelo usuário: next_check_at = 'infinity', some do claim
        ('Dashboard Interno',      'https://dash.infra.exemplo.com/health',     300, 10, '{200}'::INT[],          true,  true)
      ) AS v(nome, url, intervalo, timeout, esperados, segue_redirect, pausada)
     WHERE NOT EXISTS (SELECT 1 FROM urls x WHERE x.url = v.url)
    RETURNING id, regions, paused
)
-- A URL e a agenda nascem na MESMA transação — é a razão de a fila morar no
-- Postgres. Uma linha de agenda por região da URL.
INSERT INTO url_schedules (url_id, region_code, next_check_at, shard_key)
SELECT n.id, r, CASE WHEN n.paused THEN 'infinity'::timestamptz ELSE now() END,
       (hashtext(n.id::text) & 63)
  FROM novas n, unnest(n.regions) AS r;

COMMIT;

-- ── conferência ─────────────────────────────────────────────────────────────
SELECT u.id, u.name, u.url, u.paused, u.current_status, u.unknown_reason,
       s.next_check_at, s.shard_key
  FROM urls u JOIN url_schedules s ON s.url_id = u.id
 ORDER BY u.id;
