CREATE TABLE v4_message_events (
 event_id uuid PRIMARY KEY,
 message_id uuid NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
 sender_device_id uuid NOT NULL REFERENCES devices(id),
 request_hash bytea NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now()
);
