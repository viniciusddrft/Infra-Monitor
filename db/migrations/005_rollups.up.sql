-- 005: agregados horário e diário
--
-- O bucket é SEMPRE UTC. O gráfico de 24h lê o cru; 7d lê o horário; 30d e 90d
-- leem o diário — e toda consulta une o bucket parcial da janela corrente,
-- senão o gráfico teria um buraco justamente no ponto que mais interessa.

CREATE TABLE url_history_hourly (
    url_id        BIGINT      NOT NULL,
    region_code   VARCHAR(8)  NOT NULL,
    bucket        TIMESTAMPTZ NOT NULL,
    checks        INT         NOT NULL,
    up_count      INT         NOT NULL,
    down_count    INT         NOT NULL,
    unknown_count INT         NOT NULL,
    avg_ms        INT,
    min_ms        INT,
    max_ms        INT,
    p95_ms        INT,
    PRIMARY KEY (url_id, region_code, bucket)
);
CREATE INDEX idx_hourly_bucket ON url_history_hourly (bucket);

CREATE TABLE url_history_daily (
    url_id        BIGINT      NOT NULL,
    region_code   VARCHAR(8)  NOT NULL,
    bucket        DATE        NOT NULL,
    checks        INT         NOT NULL,
    up_count      INT         NOT NULL,
    down_count    INT         NOT NULL,
    unknown_count INT         NOT NULL,
    avg_ms        INT,
    min_ms        INT,
    max_ms        INT,
    PRIMARY KEY (url_id, region_code, bucket)
);
CREATE INDEX idx_daily_bucket ON url_history_daily (bucket);
