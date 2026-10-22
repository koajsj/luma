package message_test

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"sync"
	"testing"

	"github.com/google/uuid"
	"luma/backend/internal/database"
	"luma/backend/internal/message"
	"luma/backend/internal/middleware"
)

func TestSessionControlDirectedIdempotentAndAuthorized(t *testing.T) {
	dsn := os.Getenv("LUMA_DEVICE_TEST_DSN")
	if dsn == "" {
		t.Skip("isolated PostgreSQL required")
	}
	ctx := context.Background()
	db, err := database.Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	a, b, ad, bd, cid := seedDirectConversation(t, db)
	call := func(id string, payload []byte) *httptest.ResponseRecorder {
		body, _ := json.Marshal(map[string]any{"controlID": id, "conversationID": cid, "receiverDeviceID": bd, "encryptionVersion": 4, "envelope": base64.RawURLEncoding.EncodeToString(payload)})
		req := httptest.NewRequest(http.MethodPost, "/v1/sessions/controls", bytes.NewReader(body))
		req = req.WithContext(middleware.WithIdentity(req.Context(), middleware.Identity{UserID: a, DeviceID: ad}))
		w := httptest.NewRecorder()
		(message.Service{DB: db, Notify: noOpNotifier{}}).SessionControl(w, req)
		return w
	}
	id := uuid.NewString()
	opaque := bytes.Repeat([]byte{9}, 128)
	var wg sync.WaitGroup
	codes := make(chan int, 4)
	for range 4 {
		wg.Add(1)
		go func() { defer wg.Done(); codes <- call(id, opaque).Code }()
	}
	wg.Wait()
	close(codes)
	for code := range codes {
		if code != 200 && code != 201 {
			t.Fatalf("retry status %d", code)
		}
	}
	var n int
	if err = db.QueryRow(ctx, "SELECT count(*) FROM sync_events WHERE target_device_id=$1 AND type='session.control'", bd).Scan(&n); err != nil || n != 1 {
		t.Fatalf("events: %d %v", n, err)
	}
	if w := call(id, bytes.Repeat([]byte{8}, 128)); w.Code != 409 {
		t.Fatalf("changed retry: %d", w.Code)
	}
	if _, err = db.Exec(ctx, "INSERT INTO blocks(blocker,blocked) VALUES($1,$2)", b, a); err != nil {
		t.Fatal(err)
	}
	if w := call(uuid.NewString(), opaque); w.Code != 403 {
		t.Fatalf("blocked: %d", w.Code)
	}
	if w := call(id, opaque); w.Code != 403 {
		t.Fatalf("retry must recheck block: %d", w.Code)
	}
	if _, err = db.Exec(ctx, "DELETE FROM blocks WHERE blocker=$1 AND blocked=$2", b, a); err != nil {
		t.Fatal(err)
	}
	if _, err = db.Exec(ctx, "UPDATE devices SET revoked_at=now() WHERE id=$1", bd); err != nil {
		t.Fatal(err)
	}
	if w := call(uuid.NewString(), opaque); w.Code != 403 {
		t.Fatalf("revoked: %d", w.Code)
	}
}
