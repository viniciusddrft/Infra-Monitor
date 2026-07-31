-- 004: histórico particionado por dia
--
-- Toda sessão roda em UTC (ALTER ROLE na 011). Sem isso, CURRENT_DATE e a
-- coerção DATE → TIMESTAMPTZ usariam o fuso da sessão e os limites da partição
-- ficariam 3 horas deslocados em relação ao bucket do rollup.
SET timezone = 'UTC';

CREATE TABLE url_history (
    url_id           BIGINT      NOT NULL,
    region_code      VARCHAR(8)  NOT NULL,
    checked_at       TIMESTAMPTZ NOT NULL,
    status           VARCHAR(10) NOT NULL CHECK (status IN ('up','down','unknown')),
    response_time_ms INT,
    http_status      SMALLINT,
    error_code       VARCHAR(32),  -- categoria, nunca mensagem crua
    applied          BOOLEAN     NOT NULL DEFAULT true
    -- applied=false: resultado zumbi (lease ou config_version divergente).
    -- A medição aconteceu e é um fato, então fica para diagnóstico — mas sai de
    -- todo rollup, uptime e decisão.
) PARTITION BY RANGE (checked_at);

CREATE INDEX idx_history_url_time ON url_history (url_id, checked_at DESC);

-- Quatro ausências deliberadas:
--   sem PK e sem UNIQUE: índice único em tabela particionada precisa conter a
--     chave de particionamento, e custaria ~1,1 GB/dia. A idempotência lógica
--     vem do lease_token e dos índices únicos de incidente e notificação.
--   sem FK para urls: custaria verificação por linha no COPY e varredura de
--     todas as partições ao apagar URL. Órfãos: job purge_url_history.
--   sem índice por região: existe uma região. Adicionar quando existirem três.

-- ── manutenção de partição ──────────────────────────────────────────────────
-- Estas duas funções são a ÚNICA exceção ao princípio "nenhum serviço altera o
-- schema em runtime". Criar a partição de amanhã e dropar a vencida é ciclo de
-- vida de dado, não evolução de schema.
--
-- SECURITY DEFINER porque monitor_worker não é dono de url_history e não tem
-- CREATE no schema — e não deve ter. A superfície é fechada por construção: o
-- único parâmetro é um DATE, então o nome da tabela não aceita texto arbitrário.

CREATE OR REPLACE FUNCTION public.create_history_partition(p_day DATE) RETURNS void AS $$
DECLARE
    part TEXT        := format('url_history_%s', to_char(p_day, 'YYYYMMDD'));
    ini  TIMESTAMPTZ := (p_day::text       || ' 00:00:00+00')::timestamptz;
    fim  TIMESTAMPTZ := ((p_day + 1)::text || ' 00:00:00+00')::timestamptz;
BEGIN
    EXECUTE format('CREATE TABLE IF NOT EXISTS public.%I PARTITION OF public.url_history
                    FOR VALUES FROM (%L) TO (%L)', part, ini, fim);
EXCEPTION
    WHEN duplicate_table THEN NULL;  -- outra instância criou na virada da meia-noite
END $$ LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION public.drop_history_partition(p_day DATE) RETURNS boolean AS $$
DECLARE
    part        TEXT        := format('url_history_%s', to_char(p_day, 'YYYYMMDD'));
    ini         TIMESTAMPTZ := (p_day::text || ' 00:00:00+00')::timestamptz;
    raw_applied BIGINT;
    rolled      BIGINT;
BEGIN
    -- Horizonte de escrita: o writer descarta resultado com mais de 1h de idade
    -- e nada com menos de 2 dias é dropado. As duas janelas são disjuntas por
    -- construção, então não existe corrida entre gravar e dropar.
    IF p_day > (now() AT TIME ZONE 'UTC')::date - 2 THEN
        RAISE WARNING 'dia % está dentro do horizonte de escrita, drop recusado', p_day;
        RETURN false;
    END IF;

    IF to_regclass('public.' || quote_ident(part)) IS NULL THEN RETURN false; END IF;

    EXECUTE format('SELECT count(*) FROM public.%I WHERE applied', part) INTO raw_applied;

    SELECT COALESCE(SUM(checks), 0) INTO rolled
      FROM url_history_hourly
     WHERE bucket >= ini AND bucket < ini + interval '1 day';

    -- Comparação de CONTAGEM, não "existe alguma linha de rollup": um rollup
    -- que morreu na primeira URL passaria por uma guarda de existência.
    IF rolled < raw_applied THEN
        RAISE WARNING 'rollup incompleto para % (cru aplicado=%, agregado=%): partição preservada',
                      p_day, raw_applied, rolled;
        RETURN false;
    END IF;

    EXECUTE format('DROP TABLE public.%I', part);
    RETURN true;
END $$ LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = public, pg_temp;

-- 3 dias de antecedência: se o job de manutenção parar num fim de semana, a
-- ingestão continua
SELECT create_history_partition((now() AT TIME ZONE 'UTC')::date + g)
  FROM generate_series(0, 3) g;
