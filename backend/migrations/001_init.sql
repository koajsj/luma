CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE TABLE IF NOT EXISTS schema_migrations (version integer PRIMARY KEY);
CREATE TABLE users (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id text NOT NULL UNIQUE,
 nickname text NOT NULL DEFAULT '', avatar_object_id uuid,
 identity_public_key bytea NOT NULL, identity_key_version integer NOT NULL DEFAULT 1,
 searchable boolean NOT NULL DEFAULT false, show_presence boolean NOT NULL DEFAULT false,
 read_receipts boolean NOT NULL DEFAULT true, created_at timestamptz NOT NULL DEFAULT now(), disabled_at timestamptz,
 CHECK (user_id = lower(user_id) AND user_id ~ '^[a-z0-9_]{3,32}$')
);
CREATE TABLE devices (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid NOT NULL REFERENCES users(id),
 device_name text NOT NULL, device_public_key bytea NOT NULL, auth_public_key bytea NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(), last_active_at timestamptz,
 revoked_at timestamptz, next_seq bigint NOT NULL DEFAULT 0
);
CREATE INDEX devices_user_active ON devices(user_id) WHERE revoked_at IS NULL;
CREATE TABLE signed_prekeys (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), device_id uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
 public_key bytea NOT NULL, signature bytea NOT NULL, key_version integer NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(device_id,key_version)
);
CREATE TABLE one_time_prekeys (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), device_id uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
 public_key bytea NOT NULL, claimed_at timestamptz
);
CREATE INDEX one_time_prekeys_available ON one_time_prekeys(device_id) WHERE claimed_at IS NULL;
CREATE TABLE auth_challenges (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), device_id uuid, purpose text NOT NULL,
 user_id text, nonce_hash bytea NOT NULL, expires_at timestamptz NOT NULL, used_at timestamptz
);
CREATE TABLE refresh_sessions (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), device_id uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
 token_hash bytea NOT NULL UNIQUE, family_id uuid NOT NULL, expires_at timestamptz NOT NULL,
 used_at timestamptz, revoked_at timestamptz
);
CREATE TABLE friend_requests (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), from_user uuid NOT NULL REFERENCES users(id),
 to_user uuid NOT NULL REFERENCES users(id), status text NOT NULL DEFAULT 'pending',
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 CHECK (from_user <> to_user), CHECK (status IN ('pending','accepted','rejected')),
 UNIQUE(from_user,to_user)
);
CREATE TABLE friendships (
 user_a uuid NOT NULL REFERENCES users(id), user_b uuid NOT NULL REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(user_a,user_b), CHECK(user_a < user_b)
);
CREATE TABLE blocks (
 blocker uuid NOT NULL REFERENCES users(id), blocked uuid NOT NULL REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(blocker,blocked), CHECK(blocker <> blocked)
);
CREATE TABLE conversations (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), type text NOT NULL DEFAULT 'direct',
 created_at timestamptz NOT NULL DEFAULT now(), CHECK(type='direct')
);
CREATE TABLE conversation_members (
 conversation_id uuid NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
 user_id uuid NOT NULL REFERENCES users(id), PRIMARY KEY(conversation_id,user_id)
);
CREATE TABLE messages (
 id uuid PRIMARY KEY, conversation_id uuid NOT NULL REFERENCES conversations(id),
 sender_user_id uuid NOT NULL REFERENCES users(id), sender_device_id uuid NOT NULL REFERENCES devices(id),
 encryption_version integer NOT NULL CHECK(encryption_version >= 3), created_at timestamptz NOT NULL DEFAULT now(),
 edited_at timestamptz, deleted_at timestamptz, revision integer NOT NULL DEFAULT 1,
 request_hash bytea NOT NULL, idempotency_key text NOT NULL, UNIQUE(sender_device_id,idempotency_key)
);
CREATE INDEX messages_conversation ON messages(conversation_id,created_at);
CREATE TABLE message_envelopes (
 message_id uuid NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
 recipient_device_id uuid NOT NULL REFERENCES devices(id), ciphertext bytea NOT NULL,
 key_version integer NOT NULL, message_key_index bigint NOT NULL,
 PRIMARY KEY(message_id,recipient_device_id), CHECK(octet_length(ciphertext) BETWEEN 28 AND 1048576)
);
CREATE TABLE message_receipts (
 message_id uuid NOT NULL REFERENCES messages(id), recipient_device_id uuid NOT NULL REFERENCES devices(id),
 delivered_at timestamptz, read_at timestamptz, PRIMARY KEY(message_id,recipient_device_id)
);
CREATE TABLE attachments (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), owner_user_id uuid NOT NULL REFERENCES users(id),
 message_id uuid REFERENCES messages(id), object_key text NOT NULL UNIQUE,
 encrypted_url text, ciphertext_size bigint NOT NULL CHECK(ciphertext_size > 0),
 ciphertext_hash bytea NOT NULL, status text NOT NULL DEFAULT 'pending', created_at timestamptz NOT NULL DEFAULT now(),
 CHECK(status IN ('pending','complete','deleted'))
);
CREATE TABLE sync_events (
 event_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), target_device_id uuid NOT NULL REFERENCES devices(id),
 device_seq bigint NOT NULL, type text NOT NULL, payload_ciphertext bytea NOT NULL, routing jsonb NOT NULL DEFAULT '{}',
 created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(target_device_id,device_seq)
);
CREATE INDEX sync_events_target ON sync_events(target_device_id,device_seq);
CREATE TABLE sync_cursors (
 device_id uuid PRIMARY KEY REFERENCES devices(id), acked_seq bigint NOT NULL DEFAULT 0,
 updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE push_tokens (
 device_id uuid PRIMARY KEY REFERENCES devices(id), token_ciphertext bytea NOT NULL,
 environment text NOT NULL, updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE access_sessions (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), device_id uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
 token_hash bytea NOT NULL UNIQUE, family_id uuid NOT NULL,
 expires_at timestamptz NOT NULL, revoked_at timestamptz
);
