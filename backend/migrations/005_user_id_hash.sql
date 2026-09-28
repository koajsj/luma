-- Deterministic exact-match index. Keep user_id for account identity and API compatibility.
-- A low-entropy UserID can still be guessed from its hash; rate limits remain necessary.
ALTER TABLE users ADD COLUMN user_id_hash bytea
    GENERATED ALWAYS AS (digest(user_id, 'sha256')) STORED;
CREATE UNIQUE INDEX users_user_id_hash_unique ON users(user_id_hash);
