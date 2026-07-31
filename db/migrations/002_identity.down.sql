-- CASCADE resolve as FKs circulares entre users e teams
DROP TABLE IF EXISTS refresh_tokens;
DROP TABLE IF EXISTS users  CASCADE;
DROP TABLE IF EXISTS teams  CASCADE;
DROP TABLE IF EXISTS plan_products;
DROP TABLE IF EXISTS plans;
DROP FUNCTION IF EXISTS set_updated_at();
