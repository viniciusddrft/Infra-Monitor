-- 010: idempotência, rate limit, auditoria, flags e cegueira

CREATE TABLE idempotency_keys (
    team_id       BIGINT      NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
    key           TEXT        NOT NULL,
    endpoint      TEXT        NOT NULL,
    request_hash  CHAR(64)    NOT NULL,
    status_code   INT,
    response_body JSONB,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (team_id, key)
);
CREATE INDEX idx_idem_cleanup ON idempotency_keys (created_at);
-- A PK é (team_id, key) de propósito: a MESMA chave em endpoints diferentes é
-- bug do cliente e tem que aparecer como 422, não virar duas operações
-- silenciosas. Por isso o conflito compara `endpoint` E `request_hash`.

-- Rate limit contado no banco para as rotas em que o limite É a proteção.
-- Em memória, com 2 réplicas, o limite efetivo vira 2x o configurado — e é
-- justamente o de login que protege contra força bruta.
CREATE TABLE rate_events (
    bucket_key TEXT        PRIMARY KEY,  -- "auth_google:203.0.113.7:29218440"
    count      INT         NOT NULL DEFAULT 0,
    expires_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX idx_rate_cleanup ON rate_events (expires_at);

CREATE TABLE audit_log (
    id         BIGSERIAL   PRIMARY KEY,
    user_id    BIGINT      REFERENCES users(id) ON DELETE SET NULL,
    team_id    BIGINT,     -- sem FK: sobrevive ao time apagado
    actor      VARCHAR(16) NOT NULL CHECK (actor IN ('user','system','admin')),
    action     VARCHAR(64) NOT NULL,
    metadata   JSONB,
    ip         INET,
    user_agent VARCHAR(255),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_audit_user   ON audit_log (user_id, created_at DESC);
CREATE INDEX idx_audit_action ON audit_log (action,  created_at DESC);

CREATE TABLE system_flags (
    key        VARCHAR(64) PRIMARY KEY,
    value      JSONB       NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by TEXT
);

INSERT INTO system_flags (key, value) VALUES
    ('checks_enabled',       'true'::jsonb),  -- KILL SWITCH: TTL de cache de 10s
    ('blocked_target_hosts', '[]'::jsonb),
    ('min_app_version',      '1'::jsonb);
-- min_app_version mora AQUI, não em variável de ambiente: matar uma versão de
-- app com bug não pode depender de deploy. Middleware e /v1/app-config leem do
-- mesmo cache de 10s.

-- Cegueira é estado POR INSTÂNCIA, não global. Com uma flag única, uma
-- instância saudável sobrescreveria o estado de outra que está cega, e o app
-- receberia um retrato falso da frota.
CREATE TABLE worker_blindness (
    instance_id      TEXT        PRIMARY KEY,
    region_code      VARCHAR(8)  NOT NULL REFERENCES regions(code),
    engaged          BOOLEAN     NOT NULL DEFAULT false,
    engaged_since    TIMESTAMPTZ,
    controls_failing SMALLINT    NOT NULL DEFAULT 0,
    controls_total   SMALLINT    NOT NULL DEFAULT 0,
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_blindness_region ON worker_blindness (region_code, engaged);
-- A API deriva o brake_engaged do dashboard com um predicado de FRESCOR:
--   EXISTS (SELECT 1 FROM worker_blindness
--            WHERE engaged AND updated_at > now() - interval '60 seconds')
-- sem ele, uma instância morta deixaria o aviso ligado para sempre.
