package message

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"net/http"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"luma/backend/internal/middleware"
	events "luma/backend/internal/sync"
)

type sessionControlRequest struct {
	ControlID         string `json:"controlID"`
	ConversationID    string `json:"conversationID"`
	ReceiverDeviceID  string `json:"receiverDeviceID"`
	EncryptionVersion int    `json:"encryptionVersion"`
	Envelope          string `json:"envelope"`
}

// SessionControl routes opaque authenticated controls. It cannot choose a proposal,
// inspect key state, or generate a valid cryptographic confirmation.
func (s Service) SessionControl(w http.ResponseWriter, r *http.Request) {
	var in sessionControlRequest
	if !middleware.Decode(w, r, &in) {
		return
	}
	id, e1 := uuid.Parse(in.ControlID)
	cid, e2 := uuid.Parse(in.ConversationID)
	receiver, e3 := uuid.Parse(in.ReceiverDeviceID)
	opaque, e4 := base64.RawURLEncoding.DecodeString(in.Envelope)
	if e1 != nil || e2 != nil || e3 != nil || e4 != nil || in.EncryptionVersion != 4 || len(opaque) < 28 || len(opaque) > 1_048_576 {
		middleware.Fail(w, r, 400, "invalid_session_control")
		return
	}
	actor := middleware.Current(r)
	if receiver.String() == actor.DeviceID {
		middleware.Fail(w, r, 400, "invalid_receiver")
		return
	}
	in.ControlID = id.String()
	in.ConversationID = cid.String()
	in.ReceiverDeviceID = receiver.String()
	in.Envelope = base64.RawURLEncoding.EncodeToString(opaque)
	encoded, err := json.Marshal(in)
	if err != nil {
		middleware.Fail(w, r, 400, "invalid_session_control")
		return
	}
	digest := sha256.Sum256(encoded)
	tx, err := s.DB.Begin(r.Context())
	if err != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	defer tx.Rollback(r.Context())
	// Lock both device rows in stable order so revocation and delivery cannot race.
	rows, err := tx.Query(r.Context(), `SELECT d.id::text,d.user_id::text FROM devices d JOIN users u ON u.id=d.user_id
  WHERE d.id=ANY($1::uuid[]) AND d.revoked_at IS NULL AND u.disabled_at IS NULL ORDER BY d.id FOR UPDATE OF d`, []string{actor.DeviceID, receiver.String()})
	if err != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	users := map[string]string{}
	for rows.Next() {
		var device, user string
		if err = rows.Scan(&device, &user); err != nil {
			break
		}
		users[device] = user
	}
	if err == nil {
		err = rows.Err()
	}
	rows.Close()
	if err != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	peer, ok := users[receiver.String()]
	if !ok || users[actor.DeviceID] != actor.UserID {
		middleware.Fail(w, r, 403, "forbidden")
		return
	}
	var allowed bool
	err = tx.QueryRow(r.Context(), `SELECT EXISTS(SELECT 1 FROM conversation_members WHERE conversation_id=$1 AND user_id=$2)
  AND EXISTS(SELECT 1 FROM conversation_members WHERE conversation_id=$1 AND user_id=$3)
  AND ($2::uuid=$3::uuid OR EXISTS(SELECT 1 FROM friendships WHERE user_a=LEAST($2::uuid,$3::uuid) AND user_b=GREATEST($2::uuid,$3::uuid)))
  AND NOT EXISTS(SELECT 1 FROM blocks WHERE (blocker=$2 AND blocked=$3) OR (blocker=$3 AND blocked=$2))`, cid, actor.UserID, peer).Scan(&allowed)
	if err != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	if !allowed {
		middleware.Fail(w, r, 403, "forbidden")
		return
	}
	lock := sha256.Sum256([]byte(id.String()))
	if _, err = tx.Exec(r.Context(), "SELECT pg_advisory_xact_lock($1)", int64(binary.BigEndian.Uint64(lock[:8]))); err != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	var oldHash []byte
	var oldSender string
	err = tx.QueryRow(r.Context(), "SELECT request_hash,sender_device_id::text FROM v4_session_controls WHERE control_id=$1", id).Scan(&oldHash, &oldSender)
	if err == nil {
		if oldSender != actor.DeviceID || !bytes.Equal(oldHash, digest[:]) {
			middleware.Fail(w, r, 409, "idempotency_conflict")
			return
		}
		middleware.JSON(w, 200, map[string]string{"controlID": id.String(), "status": "already_stored"})
		return
	}
	if err != pgx.ErrNoRows {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	if _, err = tx.Exec(r.Context(), "INSERT INTO v4_session_controls(control_id,conversation_id,sender_device_id,receiver_device_id,request_hash) VALUES($1,$2,$3,$4,$5)", id, cid, actor.DeviceID, receiver, digest[:]); err != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	routing := map[string]any{"controlID": id.String(), "conversationID": cid.String(), "senderDeviceID": actor.DeviceID, "senderUserID": actor.UserID, "recipientDeviceID": receiver.String(), "encryptionVersion": 4}
	seq, err := events.AppendWithEventID(r.Context(), tx, id.String(), receiver.String(), "session.control", opaque, routing)
	if err != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	if err = tx.Commit(r.Context()); err != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	if s.Notify != nil {
		s.Notify.Notify(receiver.String(), seq)
	}
	middleware.JSON(w, 201, map[string]string{"controlID": id.String(), "status": "stored"})
}
