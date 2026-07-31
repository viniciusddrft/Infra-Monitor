-- 008: convites de time

CREATE TABLE invites (
    id          BIGSERIAL    PRIMARY KEY,
    team_id     BIGINT       NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
    email_lower VARCHAR(320) NOT NULL,
    token_hash  CHAR(64)     NOT NULL UNIQUE,  -- o token cru só existe no e-mail
    invited_by  BIGINT       REFERENCES users(id) ON DELETE SET NULL,
    expires_at  TIMESTAMPTZ  NOT NULL,
    accepted_at TIMESTAMPTZ,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX idx_invites_pending
    ON invites (team_id, email_lower) WHERE accepted_at IS NULL;
CREATE INDEX idx_invites_cleanup ON invites (expires_at) WHERE accepted_at IS NULL;

-- A cota de membros é verificada NO ACEITE, sob lock do time de destino:
-- validar só na emissão não cobre dois convites aceitos ao mesmo tempo.
