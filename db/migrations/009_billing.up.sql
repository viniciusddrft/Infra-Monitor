-- 009: assinaturas e ingestão de RTDN

CREATE TABLE subscriptions (
    team_id             BIGINT      PRIMARY KEY REFERENCES teams(id) ON DELETE CASCADE,
    plan                VARCHAR(16) NOT NULL DEFAULT 'free' REFERENCES plans(code),
    status              VARCHAR(16) NOT NULL DEFAULT 'active'
                        CHECK (status IN ('active','in_grace','on_hold','paused','cancelled','expired')),
    play_purchase_token TEXT UNIQUE,  -- UNIQUE: é o caminho do RTDN até o time
    play_product_id     VARCHAR(128),
    play_order_id       VARCHAR(128),
    period              VARCHAR(16) CHECK (period IN ('monthly','annual')),
    auto_renewing       BOOLEAN     NOT NULL DEFAULT false,

    -- Identificador opaco enviado à Play como obfuscatedExternalAccountId.
    -- PERSISTIDO e indexado, não derivado: derivar por HMAC obrigaria a
    -- recalcular para cada time ao resolver um RTDN antigo depois de rotacionar
    -- a chave — varredura em vez de lookup. Aleatório, sem segredo a rotacionar,
    -- e menos adivinhável que qualquer derivação de ID sequencial.
    obfuscated_account_id TEXT UNIQUE NOT NULL
                          DEFAULT encode(gen_random_bytes(24), 'base64'),

    -- acknowledge é AUTORITATIVO no servidor. Nunca dentro de transação aberta:
    -- tx1 persiste o entitlement → rede → tx2 marca. Compra pendente de
    -- acknowledge é revertida pelo Google em 3 dias.
    ack_state           VARCHAR(16) NOT NULL DEFAULT 'not_required'
                        CHECK (ack_state IN ('not_required','pending','done','failed')),
    ack_attempts        SMALLINT    NOT NULL DEFAULT 0,

    expires_at          TIMESTAMPTZ,
    last_verified_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    raw_play_data       JSONB,
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Todo time nasce com uma linha free/active. Por isso TODO job e TODA consulta
-- de billing filtra play_purchase_token IS NOT NULL — senão um time grátis vira
-- "assinatura ativa que nunca é reverificada" e entra em regra de expiração.
CREATE INDEX idx_subs_reverify ON subscriptions (last_verified_at)
    WHERE play_purchase_token IS NOT NULL;
CREATE INDEX idx_subs_expiring ON subscriptions (expires_at)
    WHERE status IN ('active','in_grace');
CREATE INDEX idx_subs_ack_pending ON subscriptions (updated_at)
    WHERE ack_state IN ('pending','failed');

CREATE TRIGGER trg_subs_updated BEFORE UPDATE ON subscriptions
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- A API só INGERE o RTDN: valida o JWT, persiste e responde 2xx. Responder 200
-- antes de persistir faz o Pub/Sub dar o evento por entregue — com o banco
-- fora, um evento de cobrança evapora. Todo efeito é job do Worker.
CREATE TABLE billing_webhook_events (
    id             BIGSERIAL    PRIMARY KEY,
    message_id     VARCHAR(128) NOT NULL UNIQUE,  -- idempotência do Pub/Sub
    purchase_token TEXT,
    payload        JSONB        NOT NULL,
    received_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
    processed_at   TIMESTAMPTZ,
    attempts       SMALLINT     NOT NULL DEFAULT 0,
    error          TEXT
);
CREATE INDEX idx_webhook_unprocessed ON billing_webhook_events (received_at)
    WHERE processed_at IS NULL;

-- Conta apagada com compra que pode continuar ativa. A exclusão NÃO é bloqueada
-- por assinatura (a Play exige que o usuário consiga apagar a conta); o
-- tombstone dá ao RTDN futuro um lugar para aterrissar.
CREATE TABLE billing_tombstones (
    play_purchase_token TEXT        PRIMARY KEY,
    former_team_id      BIGINT,     -- sem FK: o time não existe mais
    former_email_hash   CHAR(64),   -- para suporte, sem PII
    reason              VARCHAR(32) NOT NULL CHECK (reason IN ('account_deleted','team_deleted')),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
