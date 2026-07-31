-- 007: dispositivos e preferências de notificação

CREATE TABLE devices (
    id           BIGSERIAL   PRIMARY KEY,  -- é ISTO que vai na URL, nunca o token
    user_id      BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    fcm_token    TEXT        NOT NULL UNIQUE,
    platform     VARCHAR(16) NOT NULL DEFAULT 'android' CHECK (platform IN ('android')),
    app_version  INT,
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_devices_user  ON devices (user_id);
CREATE INDEX idx_devices_stale ON devices (last_seen_at);

-- fcm_token UNIQUE sem user_id: o mesmo aparelho trocando de conta TRANSFERE o
-- token via UPSERT, não duplica. Registro de device nunca devolve 409 — token
-- já registrado é o caso normal (reinstalação, troca de conta), não conflito.

CREATE TABLE notification_prefs (
    user_id       BIGINT      PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    push_enabled  BOOLEAN     NOT NULL DEFAULT true,
    email_enabled BOOLEAN     NOT NULL DEFAULT true,
    quiet_from    TIME,
    quiet_to      TIME,
    timezone      VARCHAR(64) NOT NULL DEFAULT 'America/Sao_Paulo',
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK ((quiet_from IS NULL) = (quiet_to IS NULL))
);

CREATE TRIGGER trg_prefs_updated BEFORE UPDATE ON notification_prefs
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
