package message

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"net/http"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"luma/backend/internal/middleware"
	"luma/backend/internal/sync"
)

type v4EventRequest struct {
	EventID            string     `json:"eventID"`
	MessageID          string     `json:"messageID"`
	ConversationID     string     `json:"conversationID"`
	Type               string     `json:"type"`
	Revision           int        `json:"revision"`
	RecipientEnvelopes []Envelope `json:"recipientEnvelopes"`
}

// V4Event accepts opaque device-specific ciphertext. It authenticates the sending
// device and routing rights; clients authenticate the encrypted actor and payload.
func (s Service) V4Event(w http.ResponseWriter, r *http.Request) {
	var in v4EventRequest
	if !middleware.Decode(w, r, &in) {
		return
	}
	eventID, err := uuid.Parse(in.EventID)
	if err != nil {
		middleware.Fail(w, r, 400, "invalid_event_id")
		return
	}
	messageID, err := uuid.Parse(in.MessageID)
	if err != nil {
		middleware.Fail(w, r, 400, "invalid_message_id")
		return
	}
	parsedConversationID, err := uuid.Parse(in.ConversationID)
	if err != nil {
		middleware.Fail(w, r, 400, "invalid_conversation_id")
		return
	}
	in.EventID, in.MessageID, in.ConversationID = eventID.String(), messageID.String(), parsedConversationID.String()
	switch in.Type {
	case "message.edited", "message.deleted", "message.read", "reaction.added":
	default:
		middleware.Fail(w, r, 400, "invalid_event_type")
		return
	}
	if len(in.RecipientEnvelopes) > 32 {
		middleware.Fail(w, r, 400, "invalid_envelopes")
		return
	}
	actual, ok := decodeEnvelopes(in.RecipientEnvelopes)
	if !ok {
		middleware.Fail(w, r, 400, "invalid_envelopes")
		return
	}
	encoded, _ := json.Marshal(in)
	digest := sha256.Sum256(encoded)
	actor := middleware.Current(r)
	tx, err := s.DB.Begin(r.Context())
	if err != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	defer tx.Rollback(r.Context())
	// Serialize retries of the same event ID before checking the idempotency row.
	// Otherwise two concurrent retries can both observe a missing row.
	eventKey := sha256.Sum256([]byte(in.EventID))
	if _, err = tx.Exec(r.Context(), "SELECT pg_advisory_xact_lock($1)", int64(binary.BigEndian.Uint64(eventKey[:8]))); err != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	var oldHash []byte
	var oldDevice string
	err = tx.QueryRow(r.Context(), "SELECT request_hash,sender_device_id FROM v4_message_events WHERE event_id=$1", in.EventID).Scan(&oldHash, &oldDevice)
	if err == nil {
		if oldDevice == actor.DeviceID && bytes.Equal(oldHash, digest[:]) {
			middleware.JSON(w, 200, map[string]string{"eventID": in.EventID, "status": "already_stored"})
			return
		}
		middleware.Fail(w, r, 409, "idempotency_conflict")
		return
	}
	if err != pgx.ErrNoRows {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	var conversationID, senderUserID string
	var revision, version int
	var deleted bool
	err = tx.QueryRow(r.Context(), "SELECT conversation_id,sender_user_id,revision,encryption_version,deleted_at IS NOT NULL FROM messages WHERE id=$1 FOR UPDATE", in.MessageID).Scan(&conversationID, &senderUserID, &revision, &version, &deleted)
	if err != nil || conversationID != in.ConversationID || version != 4 || deleted {
		middleware.Fail(w, r, 404, "not_found")
		return
	}
	expected, ok := s.allowed(tx, r, conversationID)
	if !ok || !equalDevices(expected, actual) {
		middleware.Fail(w, r, 403, "forbidden")
		return
	}
	if in.Type == "message.edited" || in.Type == "message.deleted" {
		if senderUserID != actor.UserID || in.Revision != revision+1 {
			middleware.Fail(w, r, 409, "revision_conflict")
			return
		}
	} else if in.Revision < 1 || in.Revision > revision {
		middleware.Fail(w, r, 409, "revision_conflict")
		return
	}
	if in.Type == "message.read" {
		if senderUserID == actor.UserID {
			middleware.Fail(w, r, 403, "forbidden")
			return
		}
		var enabled bool
		err = tx.QueryRow(r.Context(), "SELECT read_receipts FROM users WHERE id=$1", actor.UserID).Scan(&enabled)
		if err != nil || !enabled {
			middleware.Fail(w, r, 403, "read_receipts_disabled")
			return
		}
		var exists bool
		err = tx.QueryRow(r.Context(), "SELECT EXISTS(SELECT 1 FROM message_envelopes WHERE message_id=$1 AND recipient_device_id=$2)", in.MessageID, actor.DeviceID).Scan(&exists)
		if err != nil || !exists {
			middleware.Fail(w, r, 403, "forbidden")
			return
		}
	}
	if _, err = tx.Exec(r.Context(), "INSERT INTO v4_message_events(event_id,message_id,sender_device_id,request_hash) VALUES($1,$2,$3,$4)", in.EventID, in.MessageID, actor.DeviceID, digest[:]); err != nil {
		middleware.Fail(w, r, 409, "event_conflict")
		return
	}
	if in.Type == "message.edited" {
		_, err = tx.Exec(r.Context(), "UPDATE messages SET revision=$2,edited_at=now() WHERE id=$1", in.MessageID, in.Revision)
	} else if in.Type == "message.deleted" {
		_, err = tx.Exec(r.Context(), "UPDATE messages SET revision=$2,deleted_at=now() WHERE id=$1", in.MessageID, in.Revision)
		if err == nil {
			// Revoke download access in the same transaction as the deletion event.
			// File reconciliation removes the opaque object after commit.
			_, err = tx.Exec(r.Context(), "UPDATE attachments SET status='deleted' WHERE message_id=$1 AND status IN ('verified','complete')", in.MessageID)
		}
	} else if in.Type == "message.read" {
		_, err = tx.Exec(r.Context(), "INSERT INTO message_receipts(message_id,recipient_device_id,read_at) VALUES($1,$2,now()) ON CONFLICT(message_id,recipient_device_id) DO UPDATE SET read_at=COALESCE(message_receipts.read_at,EXCLUDED.read_at)", in.MessageID, actor.DeviceID)
	}
	if err != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	seqs := map[string]int64{}
	for _, env := range in.RecipientEnvelopes {
		seqs[env.RecipientDeviceID], err = sync.Append(r.Context(), tx, env.RecipientDeviceID, in.Type, actual[env.RecipientDeviceID], map[string]any{
			"messageID": in.MessageID, "conversationID": in.ConversationID, "mutationEventID": in.EventID,
			"senderUserID": actor.UserID, "senderDeviceID": actor.DeviceID, "encryptionVersion": 4,
			"revision": in.Revision, "keyVersion": env.KeyVersion, "messageKeyIndex": env.MessageKeyIndex,
		})
		if err != nil {
			break
		}
	}
	if err != nil || tx.Commit(r.Context()) != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	for did, seq := range seqs {
		s.Notify.Notify(did, seq)
	}
	middleware.JSON(w, 201, map[string]string{"eventID": in.EventID, "status": "stored"})
}
