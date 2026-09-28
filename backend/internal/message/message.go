package message

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"luma/backend/internal/middleware"
	"luma/backend/internal/sync"
	"net/http"
	"sort"
	"strings"
)

type Service struct {
	DB     *pgxpool.Pool
	Notify sync.Notifier
}
type Envelope struct {
	RecipientDeviceID string `json:"recipientDeviceID"`
	Ciphertext        string `json:"ciphertext"`
	KeyVersion        int    `json:"keyVersion"`
	MessageKeyIndex   int64  `json:"messageKeyIndex"`
}
type SendRequest struct {
	MessageID          string     `json:"messageID"`
	ConversationID     string     `json:"conversationID"`
	EncryptionVersion  int        `json:"encryptionVersion"`
	RecipientEnvelopes []Envelope `json:"recipientEnvelopes"`
	AttachmentIDs      []string   `json:"attachmentIDs"`
}

func decodeEnvelopes(v []Envelope) (map[string][]byte, bool) {
	out := map[string][]byte{}
	for _, x := range v {
		if _, e := uuid.Parse(x.RecipientDeviceID); e != nil || x.KeyVersion < 1 || x.MessageKeyIndex < 0 {
			return nil, false
		}
		b, e := base64.RawURLEncoding.DecodeString(x.Ciphertext)
		if e != nil || len(b) < 28 || len(b) > 1<<20 {
			return nil, false
		}
		if _, found := out[x.RecipientDeviceID]; found {
			return nil, false
		}
		out[x.RecipientDeviceID] = b
	}
	return out, len(out) > 0
}
func (s Service) allowed(tx pgx.Tx, r *http.Request, cid string) (map[string]bool, bool) {
	i := middleware.Current(r)
	var other string
	e := tx.QueryRow(r.Context(), "SELECT m2.user_id FROM conversation_members m1 JOIN conversation_members m2 ON m1.conversation_id=m2.conversation_id AND m2.user_id<>m1.user_id WHERE m1.conversation_id=$1 AND m1.user_id=$2", cid, i.UserID).Scan(&other)
	if e != nil {
		return nil, false
	}
	var friends bool
	e = tx.QueryRow(r.Context(), "SELECT EXISTS(SELECT 1 FROM friendships WHERE user_a=LEAST($1::uuid,$2::uuid) AND user_b=GREATEST($1::uuid,$2::uuid)) AND NOT EXISTS(SELECT 1 FROM blocks WHERE (blocker=$1 AND blocked=$2) OR (blocker=$2 AND blocked=$1))", i.UserID, other).Scan(&friends)
	if e != nil || !friends {
		return nil, false
	}
	rows, e := tx.Query(r.Context(), "SELECT d.id FROM devices d JOIN conversation_members m ON m.user_id=d.user_id WHERE m.conversation_id=$1 AND d.revoked_at IS NULL AND d.id<>$2", cid, i.DeviceID)
	if e != nil {
		return nil, false
	}
	defer rows.Close()
	out := map[string]bool{}
	for rows.Next() {
		var id string
		if rows.Scan(&id) != nil {
			return nil, false
		}
		out[id] = true
	}
	return out, rows.Err() == nil
}
func equalDevices(expected map[string]bool, actual map[string][]byte) bool {
	if len(expected) != len(actual) {
		return false
	}
	for id := range expected {
		if _, ok := actual[id]; !ok {
			return false
		}
	}
	return true
}
func hashRequest(in SendRequest) []byte {
	sort.Slice(in.RecipientEnvelopes, func(i, j int) bool {
		return in.RecipientEnvelopes[i].RecipientDeviceID < in.RecipientEnvelopes[j].RecipientDeviceID
	})
	sort.Strings(in.AttachmentIDs)
	b, _ := json.Marshal(in)
	h := sha256.Sum256(b)
	return h[:]
}
func (s Service) Send(w http.ResponseWriter, r *http.Request) {
	var in SendRequest
	if !middleware.Decode(w, r, &in) {
		return
	}
	messageID, e := uuid.Parse(in.MessageID)
	if e != nil {
		middleware.Fail(w, r, 400, "invalid_message_id")
		return
	}
	conversationID, e := uuid.Parse(in.ConversationID)
	if e != nil || in.EncryptionVersion < 3 || in.EncryptionVersion > 255 || len(in.RecipientEnvelopes) > 32 || len(in.AttachmentIDs) > 32 {
		middleware.Fail(w, r, 400, "invalid_request")
		return
	}
	in.MessageID, in.ConversationID = messageID.String(), conversationID.String()
	actual, ok := decodeEnvelopes(in.RecipientEnvelopes)
	if !ok {
		middleware.Fail(w, r, 400, "invalid_envelopes")
		return
	}
	idem := r.Header.Get("Idempotency-Key")
	if len(idem) < 8 || len(idem) > 128 {
		middleware.Fail(w, r, 400, "idempotency_required")
		return
	}
	hash := hashRequest(in)
	i := middleware.Current(r)
	tx, e := s.DB.Begin(r.Context())
	if e != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	defer tx.Rollback(r.Context())
	expected, ok := s.allowed(tx, r, in.ConversationID)
	if !ok {
		middleware.Fail(w, r, 403, "forbidden")
		return
	}
	if !equalDevices(expected, actual) {
		middleware.Fail(w, r, 400, "recipient_device_mismatch")
		return
	}
	for _, id := range in.AttachmentIDs {
		var n int
		e = tx.QueryRow(r.Context(), "SELECT 1 FROM attachments WHERE id=$1 AND owner_user_id=$2 AND status IN ('complete','verified')", id, i.UserID).Scan(&n)
		if e != nil {
			middleware.Fail(w, r, 400, "invalid_attachment")
			return
		}
	}
	var oldHash []byte
	var oldID string
	e = tx.QueryRow(r.Context(), "SELECT id,request_hash FROM messages WHERE (id=$1 OR (sender_device_id=$2 AND idempotency_key=$3))", in.MessageID, i.DeviceID, idem).Scan(&oldID, &oldHash)
	if e == nil {
		if oldID == in.MessageID && bytes.Equal(oldHash, hash) {
			middleware.JSON(w, 200, map[string]string{"messageID": oldID, "status": "already_stored"})
			return
		}
		middleware.Fail(w, r, 409, "idempotency_conflict")
		return
	}
	if e != pgx.ErrNoRows {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	_, e = tx.Exec(r.Context(), "INSERT INTO messages(id,conversation_id,sender_user_id,sender_device_id,encryption_version,request_hash,idempotency_key) VALUES($1,$2,$3,$4,$5,$6,$7)", in.MessageID, in.ConversationID, i.UserID, i.DeviceID, in.EncryptionVersion, hash, idem)
	if e != nil {
		middleware.Fail(w, r, 409, "message_conflict")
		return
	}
	seqs := map[string]int64{}
	for _, env := range in.RecipientEnvelopes {
		b := actual[env.RecipientDeviceID]
		_, e = tx.Exec(r.Context(), "INSERT INTO message_envelopes(message_id,recipient_device_id,ciphertext,key_version,message_key_index) VALUES($1,$2,$3,$4,$5)", in.MessageID, env.RecipientDeviceID, b, env.KeyVersion, env.MessageKeyIndex)
		if e != nil {
			break
		}
		seqs[env.RecipientDeviceID], e = sync.Append(r.Context(), tx, env.RecipientDeviceID, "message.created", b, map[string]any{"messageID": in.MessageID, "conversationID": in.ConversationID, "senderUserID": i.UserID, "senderDeviceID": i.DeviceID, "encryptionVersion": in.EncryptionVersion, "keyVersion": env.KeyVersion, "messageKeyIndex": env.MessageKeyIndex})
		if e != nil {
			break
		}
	}
	if e == nil {
		for _, id := range in.AttachmentIDs {
			tag, updateErr := tx.Exec(r.Context(), "UPDATE attachments SET message_id=$1 WHERE id=$2 AND owner_user_id=$3 AND status IN ('complete','verified') AND message_id IS NULL", in.MessageID, id, i.UserID)
			e = updateErr
			if e != nil {
				break
			}
			if tag.RowsAffected() != 1 {
				middleware.Fail(w, r, 400, "invalid_attachment")
				return
			}
		}
	}
	if e != nil || tx.Commit(r.Context()) != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	for did, seq := range seqs {
		s.Notify.Notify(did, seq)
	}
	middleware.JSON(w, 201, map[string]string{"messageID": in.MessageID, "status": "stored"})
}
func (s Service) Delete(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	i := middleware.Current(r)
	tx, e := s.DB.Begin(r.Context())
	if e != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	defer tx.Rollback(r.Context())
	var cid string
	var rev, version int
	e = tx.QueryRow(r.Context(), "SELECT conversation_id,revision,encryption_version FROM messages WHERE id=$1 AND sender_user_id=$2 AND deleted_at IS NULL FOR UPDATE", id, i.UserID).Scan(&cid, &rev, &version)
	if e != nil {
		middleware.Fail(w, r, 404, "not_found")
		return
	}
	if version == 4 {
		middleware.Fail(w, r, 409, "v4_encrypted_event_required")
		return
	}
	devices, ok := s.allowed(tx, r, cid)
	if !ok {
		middleware.Fail(w, r, 403, "forbidden")
		return
	}
	_, e = tx.Exec(r.Context(), "UPDATE messages SET deleted_at=now(),revision=revision+1 WHERE id=$1", id)
	seqs := map[string]int64{}
	for did := range devices {
		if e != nil {
			break
		}
		seqs[did], e = sync.Append(r.Context(), tx, did, "message.deleted", nil, map[string]any{"messageID": id, "revision": rev + 1, "senderUserID": i.UserID, "senderDeviceID": i.DeviceID})
	}
	if e != nil || tx.Commit(r.Context()) != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	for did, seq := range seqs {
		s.Notify.Notify(did, seq)
	}
	w.WriteHeader(204)
}
func (s Service) Edit(w http.ResponseWriter, r *http.Request) {
	var in struct {
		MessageID          string     `json:"messageID"`
		Revision           int        `json:"revision"`
		RecipientEnvelopes []Envelope `json:"recipientEnvelopes"`
	}
	if !middleware.Decode(w, r, &in) {
		return
	}
	actual, valid := decodeEnvelopes(in.RecipientEnvelopes)
	if !valid {
		middleware.Fail(w, r, 400, "invalid_envelopes")
		return
	}
	i := middleware.Current(r)
	tx, e := s.DB.Begin(r.Context())
	if e != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	defer tx.Rollback(r.Context())
	var cid string
	var rev, version int
	e = tx.QueryRow(r.Context(), "SELECT conversation_id,revision,encryption_version FROM messages WHERE id=$1 AND sender_user_id=$2 AND deleted_at IS NULL FOR UPDATE", in.MessageID, i.UserID).Scan(&cid, &rev, &version)
	if e != nil {
		middleware.Fail(w, r, 404, "not_found")
		return
	}
	if version == 4 {
		middleware.Fail(w, r, 409, "v4_encrypted_event_required")
		return
	}
	devices, ok := s.allowed(tx, r, cid)
	if !ok || !equalDevices(devices, actual) {
		middleware.Fail(w, r, 403, "forbidden")
		return
	}
	if rev != in.Revision {
		middleware.Fail(w, r, 409, "revision_conflict")
		return
	}
	_, e = tx.Exec(r.Context(), "UPDATE messages SET revision=revision+1,edited_at=now() WHERE id=$1", in.MessageID)
	seqs := map[string]int64{}
	for _, env := range in.RecipientEnvelopes {
		if e != nil {
			break
		}
		b := actual[env.RecipientDeviceID]
		_, e = tx.Exec(r.Context(), "UPDATE message_envelopes SET ciphertext=$1,key_version=$2,message_key_index=$3 WHERE message_id=$4 AND recipient_device_id=$5", b, env.KeyVersion, env.MessageKeyIndex, in.MessageID, env.RecipientDeviceID)
		if e == nil {
			seqs[env.RecipientDeviceID], e = sync.Append(r.Context(), tx, env.RecipientDeviceID, "message.edited", b, map[string]any{"messageID": in.MessageID, "senderUserID": i.UserID, "senderDeviceID": i.DeviceID, "encryptionVersion": version, "revision": rev + 1, "keyVersion": env.KeyVersion, "messageKeyIndex": env.MessageKeyIndex})
		}
	}
	if e != nil || tx.Commit(r.Context()) != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	for did, seq := range seqs {
		s.Notify.Notify(did, seq)
	}
	middleware.JSON(w, 200, map[string]int{"revision": rev + 1})
}
func (s Service) Receipt(w http.ResponseWriter, r *http.Request) {
	read := strings.HasSuffix(r.URL.Path, "/read")
	var in struct {
		MessageID string `json:"messageID"`
	}
	if !middleware.Decode(w, r, &in) {
		return
	}
	i := middleware.Current(r)
	tx, e := s.DB.Begin(r.Context())
	if e != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	defer tx.Rollback(r.Context())
	var sender string
	var version int
	var allowed bool
	e = tx.QueryRow(r.Context(), "SELECT m.sender_user_id,m.encryption_version,COALESCE(u.read_receipts,true) FROM message_envelopes env JOIN messages m ON m.id=env.message_id JOIN users u ON u.id=$2 WHERE env.message_id=$1 AND env.recipient_device_id=$3", in.MessageID, i.UserID, i.DeviceID).Scan(&sender, &version, &allowed)
	if e != nil {
		middleware.Fail(w, r, 403, "forbidden")
		return
	}
	if read && version == 4 {
		middleware.Fail(w, r, 409, "v4_encrypted_event_required")
		return
	}
	if read && !allowed {
		middleware.Fail(w, r, 403, "read_receipts_disabled")
		return
	}
	field := "delivered_at"
	typ := "message.delivered"
	if read {
		field = "read_at"
		typ = "message.read"
	}
	tag, err := tx.Exec(r.Context(), "INSERT INTO message_receipts(message_id,recipient_device_id,"+field+") VALUES($1,$2,now()) ON CONFLICT(message_id,recipient_device_id) DO UPDATE SET "+field+"=now() WHERE message_receipts."+field+" IS NULL", in.MessageID, i.DeviceID)
	e = err
	if e != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	if tag.RowsAffected() == 0 {
		w.WriteHeader(204)
		return
	}
	rows, e := tx.Query(r.Context(), "SELECT id FROM devices WHERE user_id=$1 AND revoked_at IS NULL", sender)
	if e != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	ids := []string{}
	for rows.Next() {
		var id string
		if rows.Scan(&id) == nil {
			ids = append(ids, id)
		}
	}
	rows.Close()
	seqs := map[string]int64{}
	for _, did := range ids {
		seqs[did], e = sync.Append(r.Context(), tx, did, typ, nil, map[string]any{"messageID": in.MessageID, "recipientDeviceID": i.DeviceID, "senderUserID": i.UserID, "senderDeviceID": i.DeviceID})
		if e != nil {
			break
		}
	}
	if e != nil || tx.Commit(r.Context()) != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	for did, seq := range seqs {
		s.Notify.Notify(did, seq)
	}
	w.WriteHeader(204)
}
func (s Service) Reaction(w http.ResponseWriter, r *http.Request) {
	var in struct {
		MessageID          string     `json:"messageID"`
		RecipientEnvelopes []Envelope `json:"recipientEnvelopes"`
	}
	if !middleware.Decode(w, r, &in) {
		return
	}
	actual, ok := decodeEnvelopes(in.RecipientEnvelopes)
	if !ok {
		middleware.Fail(w, r, 400, "invalid_envelopes")
		return
	}
	sort.Slice(in.RecipientEnvelopes, func(i, j int) bool {
		return in.RecipientEnvelopes[i].RecipientDeviceID < in.RecipientEnvelopes[j].RecipientDeviceID
	})
	requestBody, _ := json.Marshal(in)
	requestHash := sha256.Sum256(append([]byte(middleware.Current(r).DeviceID+":"), requestBody...))
	eventID := func(deviceID string) string {
		h := sha256.Sum256(append(requestHash[:], []byte(deviceID)...))
		id, _ := uuid.FromBytes(h[:16])
		return id.String()
	}
	tx, e := s.DB.Begin(r.Context())
	if e != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	defer tx.Rollback(r.Context())
	if _, e = tx.Exec(r.Context(), "SELECT pg_advisory_xact_lock($1)", int64(binary.BigEndian.Uint64(requestHash[:8]))); e != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	var cid string
	var version int
	e = tx.QueryRow(r.Context(), "SELECT conversation_id,encryption_version FROM messages WHERE id=$1 AND deleted_at IS NULL", in.MessageID).Scan(&cid, &version)
	if e != nil {
		middleware.Fail(w, r, 404, "not_found")
		return
	}
	if version == 4 {
		middleware.Fail(w, r, 409, "v4_encrypted_event_required")
		return
	}
	devices, ok := s.allowed(tx, r, cid)
	if !ok || !equalDevices(devices, actual) {
		middleware.Fail(w, r, 403, "forbidden")
		return
	}
	var seen bool
	e = tx.QueryRow(r.Context(), "SELECT EXISTS(SELECT 1 FROM sync_events WHERE event_id=$1 AND target_device_id=$2 AND type='reaction.added')", eventID(in.RecipientEnvelopes[0].RecipientDeviceID), in.RecipientEnvelopes[0].RecipientDeviceID).Scan(&seen)
	if e != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	if seen {
		w.WriteHeader(202)
		return
	}
	seqs := map[string]int64{}
	for _, env := range in.RecipientEnvelopes {
		seqs[env.RecipientDeviceID], e = sync.AppendWithEventID(r.Context(), tx, eventID(env.RecipientDeviceID), env.RecipientDeviceID, "reaction.added", actual[env.RecipientDeviceID], map[string]any{"messageID": in.MessageID, "senderUserID": middleware.Current(r).UserID, "senderDeviceID": middleware.Current(r).DeviceID, "encryptionVersion": version})
		if e != nil {
			break
		}
	}
	if e != nil || tx.Commit(r.Context()) != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	for did, seq := range seqs {
		s.Notify.Notify(did, seq)
	}
	w.WriteHeader(202)
}
