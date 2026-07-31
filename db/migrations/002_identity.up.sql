-- 002: planos, usuários, times e sessões

CREATE TABLE plans (
    code                 VARCHAR(16)  PRIMARY KEY,
    name                 VARCHAR(64)  NOT NULL,
    max_urls             INT          NOT NULL,
    max_members          INT          NOT NULL,
    min_interval_seconds INT          NOT NULL,
    retention_days       INT          NOT NULL,
    updated_at           TIMESTAMPTZ  NOT NULL DEFAULT now()
);

INSERT INTO plans (code, name, max_urls, max_members, min_interval_seconds, retention_days)
VALUES ('free', 'Grátis', 5,  5, 300, 30),
       ('pro',  'Pro',    50, 5,  60, 90);

-- N produtos por plano: mensal e anual desde o primeiro dia
CREATE TABLE plan_products (
    plan_code       VARCHAR(16)  NOT NULL REFERENCES plans(code),
    period          VARCHAR(16)  NOT NULL CHECK (period IN ('monthly','annual')),
    play_product_id VARCHAR(128) NOT NULL UNIQUE,
    active          BOOLEAN      NOT NULL DEFAULT true,
    PRIMARY KEY (plan_code, period)
);

INSERT INTO plan_products (plan_code, period, play_product_id) VALUES
    ('pro', 'monthly', 'monitor.pro.monthly'),
    ('pro', 'annual',  'monitor.pro.annual');

CREATE TABLE users (
    id            BIGSERIAL    PRIMARY KEY,
    google_sub    VARCHAR(255) NOT NULL UNIQUE,  -- chave estável; o e-mail muda, o sub não
    email         VARCHAR(320) NOT NULL,
    email_lower   VARCHAR(320) GENERATED ALWAYS AS (lower(email)) STORED,
    name          VARCHAR(255),
    picture_url   TEXT,
    team_id       BIGINT       NOT NULL,
    role          VARCHAR(16)  NOT NULL CHECK (role IN ('owner','member')),
    last_login_at TIMESTAMPTZ,
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX idx_users_email_lower ON users (email_lower);
CREATE INDEX        idx_users_team        ON users (team_id);

-- `plan` NÃO existe aqui: o plano em vigor é subscriptions.plan, e duas
-- colunas com o mesmo fato divergem na primeira falha entre as escritas
CREATE TABLE teams (
    id                BIGSERIAL    PRIMARY KEY,
    name              VARCHAR(120) NOT NULL,
    owner_user_id     BIGINT       NOT NULL,
    dashboard_version BIGINT       NOT NULL DEFAULT 1,
    created_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- 1 usuário → 1 time, garantido pelo banco
CREATE UNIQUE INDEX idx_teams_owner ON teams (owner_user_id);

-- FKs circulares. DEFERRABLE adia a verificação REFERENCIAL até o COMMIT — não
-- adia o NOT NULL, que é constraint de coluna. Por isso a criação do primeiro
-- usuário reserva os dois IDs com nextval ANTES de qualquer INSERT (ver README).
ALTER TABLE users ADD CONSTRAINT fk_users_team
    FOREIGN KEY (team_id) REFERENCES teams(id) ON DELETE CASCADE
    DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE teams ADD CONSTRAINT fk_teams_owner
    FOREIGN KEY (owner_user_id) REFERENCES users(id) ON DELETE CASCADE
    DEFERRABLE INITIALLY DEFERRED;

CREATE TABLE refresh_tokens (
    id           BIGSERIAL   PRIMARY KEY,
    user_id      BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash   CHAR(64)    NOT NULL UNIQUE,  -- SHA-256 hex; o valor cru nunca persiste
    family_id    UUID        NOT NULL,
    replaced_by  BIGINT      REFERENCES refresh_tokens(id) ON DELETE SET NULL,
    grace_used   BOOLEAN     NOT NULL DEFAULT false,
    expires_at   TIMESTAMPTZ NOT NULL,
    revoked_at   TIMESTAMPTZ,
    revoke_cause VARCHAR(32),  -- rotated | reuse | logout | membership_change
    user_agent   VARCHAR(255),
    ip           INET,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_rt_family  ON refresh_tokens (family_id);
CREATE INDEX idx_rt_cleanup ON refresh_tokens (expires_at) WHERE revoked_at IS NULL;

-- updated_at automático
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS TRIGGER AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_users_updated BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_teams_updated BEFORE UPDATE ON teams
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_plans_updated BEFORE UPDATE ON plans
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
