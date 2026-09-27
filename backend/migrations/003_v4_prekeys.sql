-- Separate Curve25519 v4 directory; legacy P-256 identity and prekeys remain intact.
CREATE TABLE v4_device_prekeys (
 device_id uuid PRIMARY KEY REFERENCES devices(id) ON DELETE CASCADE,
 identity_agreement_public bytea NOT NULL CHECK (octet_length(identity_agreement_public)=32),
 identity_signing_public bytea NOT NULL CHECK (octet_length(identity_signing_public)=32),
 identity_binding_signature bytea NOT NULL,
 signed_prekey_public bytea NOT NULL CHECK (octet_length(signed_prekey_public)=32),
 signed_prekey_signature bytea NOT NULL CHECK (octet_length(signed_prekey_signature)=64),
 key_version integer NOT NULL CHECK (key_version>0),
 updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE v4_one_time_prekeys (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 device_id uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
 public_key bytea NOT NULL CHECK (octet_length(public_key)=32),
 claimed_at timestamptz,
 UNIQUE(device_id,public_key)
);
CREATE INDEX v4_one_time_available ON v4_one_time_prekeys(device_id) WHERE claimed_at IS NULL;
