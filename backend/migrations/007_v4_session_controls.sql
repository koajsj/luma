-- Opaque, single-device recovery controls; no server-side session/key state.
CREATE TABLE v4_session_controls (
 control_id uuid PRIMARY KEY,
 conversation_id uuid NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
 sender_device_id uuid NOT NULL REFERENCES devices(id),
 receiver_device_id uuid NOT NULL REFERENCES devices(id),
 request_hash bytea NOT NULL CHECK (octet_length(request_hash)=32),
 created_at timestamptz NOT NULL DEFAULT now()
);
-- Capability is authenticated by the existing, account-bound device signing key.
ALTER TABLE v4_device_prekeys ADD COLUMN recovery_protocol_version integer NOT NULL DEFAULT 0 CHECK (recovery_protocol_version IN (0,2));
ALTER TABLE v4_device_prekeys ADD COLUMN recovery_capability_signature bytea;
ALTER TABLE v4_device_prekeys ADD CONSTRAINT v4_recovery_capability_valid CHECK (
 (recovery_protocol_version=0 AND recovery_capability_signature IS NULL) OR
 (recovery_protocol_version=2 AND octet_length(recovery_capability_signature)=64)
);
