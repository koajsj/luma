-- Replaces the unkeyed SHA-256 generated column introduced by migration 005.
-- The Go startup backfill computes HMAC without sending the secret to PostgreSQL.
DROP INDEX IF EXISTS users_user_id_hash_unique;
ALTER TABLE users DROP COLUMN IF EXISTS user_id_hash;
ALTER TABLE users ADD COLUMN user_id_hash bytea;
CREATE UNIQUE INDEX users_user_id_hash_unique ON users(user_id_hash) WHERE user_id_hash IS NOT NULL;
