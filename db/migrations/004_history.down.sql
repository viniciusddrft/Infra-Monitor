DROP FUNCTION IF EXISTS public.drop_history_partition(DATE);
DROP FUNCTION IF EXISTS public.create_history_partition(DATE);
DROP TABLE IF EXISTS url_history;  -- leva as partições junto
