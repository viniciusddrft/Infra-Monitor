-- 006: incidentes e notificações

CREATE TABLE incidents (
    id               BIGSERIAL   PRIMARY KEY,
    url_id           BIGINT      NOT NULL REFERENCES urls(id)  ON DELETE CASCADE,
    team_id          BIGINT      NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
    started_at       TIMESTAMPTZ NOT NULL,
    ended_at         TIMESTAMPTZ,
    duration_seconds INT GENERATED ALWAYS AS (
        CASE WHEN ended_at IS NULL THEN NULL
             ELSE EXTRACT(EPOCH FROM (ended_at - started_at))::INT END) STORED,

    -- Flap agrupa incidentes SEPARADOS; nunca reabre o anterior. Apagar o
    -- ended_at de um incidente fechado transformaria o período de recuperação
    -- em downtime, e o uptime consolidado é derivado da duração dos incidentes:
    -- 14:00 down → 14:05 up → 14:06 down → 14:10 up são 9 minutos, não 10.
    flap_group_id     UUID,
    notify_suppressed BOOLEAN    NOT NULL DEFAULT false,

    reason           VARCHAR(64),
    acknowledged_at  TIMESTAMPTZ,
    acknowledged_by  BIGINT      REFERENCES users(id) ON DELETE SET NULL,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (ended_at IS NULL OR ended_at >= started_at)
);

-- A INVARIANTE: no máximo um incidente aberto por URL. Garantida pelo banco,
-- não pelo lock da aplicação — e o INSERT usa ON CONFLICT, porque violação de
-- unicidade aborta a transação inteira do lote de 200 resultados.
CREATE UNIQUE INDEX idx_incidents_open ON incidents (url_id) WHERE ended_at IS NULL;

-- `id` como desempate: o cursor é (started_at, id)
CREATE INDEX idx_incidents_url_time  ON incidents (url_id,  started_at DESC, id DESC);
CREATE INDEX idx_incidents_team_time ON incidents (team_id, started_at DESC, id DESC);
CREATE INDEX idx_incidents_flap      ON incidents (flap_group_id) WHERE flap_group_id IS NOT NULL;

CREATE TABLE notifications (
    id          BIGSERIAL   PRIMARY KEY,
    user_id     BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    team_id     BIGINT      NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
    incident_id BIGINT      REFERENCES incidents(id) ON DELETE CASCADE,
    kind        VARCHAR(32) NOT NULL
                CHECK (kind IN ('incident_opened','incident_closed','incident_summary',
                                'flap_detected','plan_downgraded','welcome_pro',
                                'config_error','removed_from_team')),
    dedup_key   TEXT,  -- para notificações SEM incidente
    title       TEXT        NOT NULL,
    body        TEXT        NOT NULL,
    read_at     TIMESTAMPTZ,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (incident_id IS NOT NULL OR dedup_key IS NOT NULL)
);

-- Idempotência por USUÁRIO. O incidente pertence ao time; a notificação
-- pertence à pessoa: cada membro marca como lida, tem preferência própria e
-- pode apagar a conta sem afetar os outros.
CREATE UNIQUE INDEX idx_notifications_dedup_incident
    ON notifications (user_id, incident_id, kind) WHERE incident_id IS NOT NULL;
CREATE UNIQUE INDEX idx_notifications_dedup_other
    ON notifications (user_id, dedup_key)         WHERE dedup_key IS NOT NULL;
CREATE INDEX idx_notifications_user   ON notifications (user_id, created_at DESC, id DESC);
CREATE INDEX idx_notifications_unread ON notifications (user_id) WHERE read_at IS NULL;

-- Não existe tabela de entrega por dispositivo: o river_job de push_send já
-- guarda estado, tentativas, erro e timestamps por device.
