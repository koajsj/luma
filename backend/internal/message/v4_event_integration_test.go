package message_test

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/google/uuid"
	"luma/backend/internal/database"
	"luma/backend/internal/message"
	"luma/backend/internal/middleware"
)

// Exercises the real PostgreSQL transaction and two independently addressed
// devices. Cryptographic opening is covered by the iOS ratchet test.
func TestV4ControlEventsAreOpaqueIdempotentAndAuthorized(t *testing.T) {
	dsn := os.Getenv("LUMA_DEVICE_TEST_DSN")
	if dsn == "" {
		t.Skip("isolated PostgreSQL DSN not provided")
	}
	ctx := context.Background()
	db, err := database.Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	a, b := uuid.NewString(), uuid.NewString()
	ad, bd := uuid.NewString(), uuid.NewString()
	cid, mid := uuid.NewString(), uuid.NewString()
	for _, row := range []struct{ id, name string }{{a, "test_" + uuid.NewString()[:8]}, {b, "test_" + uuid.NewString()[:8]}} {
		if _, err = db.Exec(ctx, "INSERT INTO users(id,user_id,identity_public_key) VALUES($1,$2,$3)", row.id, row.name, []byte{1}); err != nil {
			t.Fatal(err)
		}
	}
	for _, row := range []struct{ id, user string }{{ad, a}, {bd, b}} {
		if _, err = db.Exec(ctx, "INSERT INTO devices(id,user_id,device_name,device_public_key,auth_public_key) VALUES($1,$2,'test',$3,$4)", row.id, row.user, []byte{1}, []byte{2}); err != nil {
			t.Fatal(err)
		}
	}
	if _, err = db.Exec(ctx, "INSERT INTO friendships(user_a,user_b) VALUES(LEAST($1::uuid,$2::uuid),GREATEST($1::uuid,$2::uuid))", a, b); err != nil {
		t.Fatal(err)
	}
	if _, err = db.Exec(ctx, "INSERT INTO conversations(id) VALUES($1)", cid); err != nil {
		t.Fatal(err)
	}
	for _, uid := range []string{a, b} {
		if _, err = db.Exec(ctx, "INSERT INTO conversation_members(conversation_id,user_id) VALUES($1,$2)", cid, uid); err != nil {
			t.Fatal(err)
		}
	}
	if _, err = db.Exec(ctx, "INSERT INTO messages(id,conversation_id,sender_user_id,sender_device_id,encryption_version,request_hash,idempotency_key) VALUES($1,$2,$3,$4,4,$5,$6)", mid, cid, a, ad, []byte{1}, uuid.NewString()); err != nil {
		t.Fatal(err)
	}
	opaque := []byte(`{"ciphertext":"opaque-no-plaintext","nonce":"opaque"}`)
	if _, err = db.Exec(ctx, "INSERT INTO message_envelopes(message_id,recipient_device_id,ciphertext,key_version,message_key_index) VALUES($1,$2,$3,1,0)", mid, bd, opaque); err != nil {
		t.Fatal(err)
	}
	attachmentID := uuid.NewString()
	if _, err = db.Exec(ctx, "INSERT INTO attachments(id,owner_user_id,message_id,object_key,ciphertext_size,ciphertext_hash,status) VALUES($1,$2,$3,$4,1,$5,'verified')",
		attachmentID, a, mid, "ciphertext/"+attachmentID, []byte{1}); err != nil {
		t.Fatal(err)
	}
	call := func(actorUser, actorDevice, eventID, typ string, revision int) *httptest.ResponseRecorder {
		body, _ := json.Marshal(map[string]any{"eventID": strings.ToUpper(eventID), "messageID": strings.ToUpper(mid), "conversationID": strings.ToUpper(cid),
			"type": typ, "revision": revision, "recipientEnvelopes": []map[string]any{{
				"recipientDeviceID": bd, "ciphertext": base64.RawURLEncoding.EncodeToString(opaque),
				"keyVersion": 1, "messageKeyIndex": 1,
			}}})
		if actorDevice == bd {
			body, _ = json.Marshal(map[string]any{"eventID": strings.ToUpper(eventID), "messageID": strings.ToUpper(mid), "conversationID": strings.ToUpper(cid),
				"type": typ, "revision": revision, "recipientEnvelopes": []map[string]any{{
					"recipientDeviceID": ad, "ciphertext": base64.RawURLEncoding.EncodeToString(opaque),
					"keyVersion": 1, "messageKeyIndex": 1,
				}}})
		}
		req := httptest.NewRequest(http.MethodPost, "/v1/messages/v4/events", bytes.NewReader(body))
		req = req.WithContext(middleware.WithIdentity(req.Context(), middleware.Identity{UserID: actorUser, DeviceID: actorDevice}))
		w := httptest.NewRecorder()
		(message.Service{DB: db, Notify: noOpNotifier{}}).V4Event(w, req)
		return w
	}
	editID := uuid.NewString()
	if w := call(a, ad, editID, "message.edited", 2); w.Code != 201 {
		t.Fatalf("edit: %d %s", w.Code, w.Body.String())
	}
	if w := call(a, ad, editID, "message.edited", 2); w.Code != 200 {
		t.Fatalf("idempotent retry: %d", w.Code)
	}
	if w := call(b, bd, uuid.NewString(), "message.deleted", 3); w.Code != 409 {
		t.Fatalf("unauthorized delete: %d", w.Code)
	}
	// A receipt or reaction queued before an edit still targets the same message.
	if w := call(b, bd, uuid.NewString(), "message.read", 1); w.Code != 201 {
		t.Fatalf("read: %d %s", w.Code, w.Body.String())
	}
	if _, err = db.Exec(ctx, "UPDATE users SET read_receipts=false WHERE id=$1", b); err != nil {
		t.Fatal(err)
	}
	if w := call(b, bd, uuid.NewString(), "message.read", 1); w.Code != 403 {
		t.Fatalf("disabled read receipt: %d", w.Code)
	}
	if _, err = db.Exec(ctx, "UPDATE users SET read_receipts=true WHERE id=$1", b); err != nil {
		t.Fatal(err)
	}
	if w := call(b, bd, uuid.NewString(), "reaction.added", 1); w.Code != 201 {
		t.Fatalf("reaction: %d %s", w.Code, w.Body.String())
	}
	// Concurrent network retries must resolve to one stored event and one replay.
	concurrentID := uuid.NewString()
	results := make(chan int, 2)
	for range 2 {
		go func() { results <- call(b, bd, concurrentID, "reaction.added", 2).Code }()
	}
	first, second := <-results, <-results
	if !((first == 201 && second == 200) || (first == 200 && second == 201)) {
		t.Fatalf("concurrent idempotency: %d, %d", first, second)
	}
	if w := call(a, ad, uuid.NewString(), "message.deleted", 3); w.Code != 201 {
		t.Fatalf("delete: %d %s", w.Code, w.Body.String())
	}
	var attachmentStatus string
	if err = db.QueryRow(ctx, "SELECT status FROM attachments WHERE id=$1", attachmentID).Scan(&attachmentStatus); err != nil || attachmentStatus != "deleted" {
		t.Fatalf("attachment access not revoked: %s %v", attachmentStatus, err)
	}
	var count int
	if err = db.QueryRow(ctx, "SELECT count(*) FROM sync_events WHERE target_device_id=$1 AND type IN ('message.edited','message.read','reaction.added','message.deleted')", bd).Scan(&count); err != nil || count != 2 {
		t.Fatalf("target B events: %d %v", count, err)
	}
	var payload []byte
	if err = db.QueryRow(ctx, "SELECT payload_ciphertext FROM sync_events WHERE target_device_id=$1 AND type='message.edited'", bd).Scan(&payload); err != nil || !bytes.Equal(payload, opaque) {
		t.Fatalf("opaque payload not preserved: %v", err)
	}
	// Swift's UUID JSON encoding uses uppercase. The same request must be accepted
	// once and deduplicated after its response is lost.
	newID := uuid.NewString()
	newAttachmentID := uuid.NewString()
	if _, err = db.Exec(ctx, "INSERT INTO attachments(id,owner_user_id,object_key,ciphertext_size,ciphertext_hash,status) VALUES($1,$2,$3,1,$4,'verified')",
		newAttachmentID, a, "ciphertext/"+newAttachmentID, []byte{2}); err != nil {
		t.Fatal(err)
	}
	sendBody, _ := json.Marshal(map[string]any{"messageID": strings.ToUpper(newID),
		"conversationID": strings.ToUpper(cid), "encryptionVersion": 4,
		"attachmentIDs": []string{newAttachmentID},
		"recipientEnvelopes": []map[string]any{{"recipientDeviceID": bd,
			"ciphertext": base64.RawURLEncoding.EncodeToString(opaque),
			"keyVersion": 1, "messageKeyIndex": 2}}})
	for attempt, expected := range []int{201, 200} {
		req := httptest.NewRequest(http.MethodPost, "/v1/messages", bytes.NewReader(sendBody))
		req.Header.Set("Idempotency-Key", newID)
		req = req.WithContext(middleware.WithIdentity(req.Context(),
			middleware.Identity{UserID: a, DeviceID: ad}))
		w := httptest.NewRecorder()
		(message.Service{DB: db, Notify: noOpNotifier{}}).Send(w, req)
		if w.Code != expected {
			t.Fatalf("uppercase send retry %d: %d %s", attempt, w.Code, w.Body.String())
		}
	}
	var linked string
	if err = db.QueryRow(ctx, "SELECT message_id FROM attachments WHERE id=$1", newAttachmentID).Scan(&linked); err != nil || linked != newID {
		t.Fatalf("v4 attachment not linked to message: %s %v", linked, err)
	}
}

type noOpNotifier struct{}

func (noOpNotifier) Notify(string, int64) {}
