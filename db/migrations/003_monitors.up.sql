-- 003: regiões, monitores e a agenda de checks
--
-- É aqui que mora o protocolo de escrita concorrente entre API e Worker.
-- Calendário, coordenação e configuração são colunas DISTINTAS: colapsar as
-- três numa só produzia drift de calendário e resultado de check em voo
-- ressuscitando URL que a API acabou de pausar.

CREATE TABLE regions (
    code    VARCHAR(8)  PRIMARY KEY,
    name    VARCHAR(64) NOT NULL,
    enabled BOOLEAN     NOT NULL DEFAULT true
);
INSERT INTO regions (code, name) VALUES ('sa-east', 'South America East');

CREATE TABLE urls (
    id                     BIGSERIAL    PRIMARY KEY,
    team_id                BIGINT       NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
    created_by_user_id     BIGINT       REFERENCES users(id) ON DELETE SET NULL,

    -- ── CONFIGURAÇÃO: escreve a API ──────────────────────────────────────────
    name                   VARCHAR(120) NOT NULL CHECK (length(btrim(name)) > 0),
    url                    TEXT         NOT NULL CHECK (length(url) BETWEEN 8 AND 2048),
    check_interval_seconds INT          NOT NULL CHECK (check_interval_seconds BETWEEN 30 AND 86400),
    timeout_seconds        INT          NOT NULL DEFAULT 10 CHECK (timeout_seconds BETWEEN 1 AND 30),
    expected_status_codes  INT[]        NOT NULL DEFAULT '{200,201,202,204}'
                                        CHECK (array_length(expected_status_codes,1) BETWEEN 1 AND 20),
    follow_redirects       BOOLEAN      NOT NULL DEFAULT true,
    regions                VARCHAR(8)[] NOT NULL DEFAULT '{sa-east}'
                                        CHECK (array_length(regions,1) BETWEEN 1 AND 8),
    paused                 BOOLEAN      NOT NULL DEFAULT false,  -- intenção do USUÁRIO
    deleted_at             TIMESTAMPTZ,

    -- a API incrementa em TODA alteração acima; o Worker só aplica efeito
    -- autoritativo se a versão não mudou desde o claim
    config_version         INT          NOT NULL DEFAULT 1,

    -- ── ESTADO OBSERVADO: escreve o Worker ───────────────────────────────────
    current_status         VARCHAR(10)  NOT NULL DEFAULT 'unknown'
                                        CHECK (current_status IN ('up','down','unknown')),
    -- DEFAULT coerente com o de current_status: sem ele, todo INSERT que não
    -- informasse a razão violaria o CHECK do fim da tabela
    unknown_reason         VARCHAR(24)  DEFAULT 'never_checked'
                                        CHECK (unknown_reason IS NULL OR unknown_reason IN
                                        ('never_checked','stale_evidence','blind',
                                         'ssrf_blocked','config_error','host_saturated')),
    current_status_since   TIMESTAMPTZ,
    last_checked_at        TIMESTAMPTZ,

    -- suspensão pelo SISTEMA, distinta da pausa do usuário.
    -- Reassinar reativa só 'entitlement'. Editar a URL limpa 'config_error'.
    suspended_reason       VARCHAR(24)  CHECK (suspended_reason IS NULL OR suspended_reason IN
                                        ('entitlement','config_error')),

    created_at             TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at             TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CHECK ((current_status = 'unknown') = (unknown_reason IS NOT NULL))
);
-- `id` no fim: é o desempate do cursor de paginação
CREATE INDEX idx_urls_team ON urls (team_id, created_at DESC, id DESC)
    WHERE deleted_at IS NULL;

CREATE TRIGGER trg_urls_updated BEFORE UPDATE ON urls
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE url_schedules (
    url_id                 BIGINT      NOT NULL REFERENCES urls(id) ON DELETE CASCADE,
    region_code            VARCHAR(8)  NOT NULL REFERENCES regions(code),

    -- ── CALENDÁRIO ──────────────────────────────────────────────────────────
    -- 'infinity' = não monitorar (pausa do usuário OU suspensão do sistema).
    -- Worker avança o ciclo SEMPRE condicionado a lease_token + config_version.
    next_check_at          TIMESTAMPTZ NOT NULL,

    -- ── COORDENAÇÃO: só o Worker escreve ────────────────────────────────────
    lease_token            UUID,
    lease_owner            TEXT,
    lease_expires_at       TIMESTAMPTZ,
    claimed_scheduled_at   TIMESTAMPTZ,  -- horário LÓGICO reclamado, evita drift
    claimed_config_version INT,          -- versão vista no claim

    -- ── ESTADO DO CICLO: só o Worker escreve ────────────────────────────────
    attempt_kind           VARCHAR(16) NOT NULL DEFAULT 'scheduled'
                                       CHECK (attempt_kind IN ('scheduled','confirm')),
    consecutive_failures   SMALLINT    NOT NULL DEFAULT 0,

    -- ── ÚLTIMA AMOSTRA DESTA REGIÃO: é a FONTE do quórum ────────────────────
    -- Sem isto, Decide() recebe []Sample e não há de onde montá-lo com mais de
    -- uma região: o caminho crítico não pode consultar url_history.
    last_status            VARCHAR(10) CHECK (last_status IN ('up','down','unknown')),
    last_sample_at         TIMESTAMPTZ,

    shard_key              SMALLINT    NOT NULL CHECK (shard_key BETWEEN 0 AND 63),

    PRIMARY KEY (url_id, region_code),

    -- coerência COMPLETA do lease: os cinco campos vivem e morrem juntos
    CHECK ( (lease_token IS NULL AND lease_owner IS NULL AND lease_expires_at IS NULL
             AND claimed_scheduled_at IS NULL AND claimed_config_version IS NULL)
         OR (lease_token IS NOT NULL AND lease_owner IS NOT NULL AND lease_expires_at IS NOT NULL
             AND claimed_scheduled_at IS NOT NULL AND claimed_config_version IS NOT NULL) ),
    CHECK ((last_status IS NULL) = (last_sample_at IS NULL))
);

-- Índice do claim. PARCIAL: linha com lease sai do índice e não é reescaneada.
-- `shard_key` fica FORA por enquanto — no meio da chave e sem estar no WHERE,
-- ele impediria o range scan ordenado por next_check_at.
CREATE INDEX idx_schedules_due ON url_schedules (region_code, next_check_at)
    WHERE lease_expires_at IS NULL;

-- Para o reaper de lease vencido
CREATE INDEX idx_schedules_lease ON url_schedules (lease_expires_at)
    WHERE lease_expires_at IS NOT NULL;

-- OBRIGATÓRIO: ~325 updates/s numa tabela de 50 mil linhas a reescreve ~560x/dia.
-- Sem isto ela incha, o índice degrada e o claim fica lento — o modo de falha
-- clássico de fila em Postgres.
ALTER TABLE url_schedules SET (
    fillfactor                     = 70,
    autovacuum_vacuum_scale_factor = 0.01,
    autovacuum_vacuum_cost_delay   = 0
);
