package friend_test

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/google/uuid"
	"luma/backend/internal/database"
	"luma/backend/internal/device"
	"luma/backend/internal/friend"
	"luma/backend/internal/middleware"
	"luma/backend/internal/presence"
)

func TestBlockOverridesPendingRequestAndDirectoryAccess(t *testing.T) {
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
	a, b, requestID := uuid.NewString(), uuid.NewString(), uuid.NewString()
	for _, id := range []string{a, b} {
		if _, err = db.Exec(ctx, "INSERT INTO users(id,user_id,identity_public_key,show_presence) VALUES($1,$2,$3,true)", id, "block_"+id[:8], []byte{1}); err != nil {
			t.Fatal(err)
		}
	}
	if _, err = db.Exec(ctx, "INSERT INTO friend_requests(id,from_user,to_user) VALUES($1,$2,$3)", requestID, a, b); err != nil {
		t.Fatal(err)
	}
	blockBody, _ := json.Marshal(map[string]string{"userID": a})
	block := httptest.NewRequest(http.MethodPost, "/v1/friend/block", bytes.NewReader(blockBody))
	block = block.WithContext(middleware.WithIdentity(block.Context(), middleware.Identity{UserID: b}))
	w := httptest.NewRecorder()
	(friend.Service{DB: db}).Block(w, block)
	if w.Code != 204 {
		t.Fatalf("block: %d %s", w.Code, w.Body.String())
	}
	acceptBody, _ := json.Marshal(map[string]string{"requestID": requestID})
	accept := httptest.NewRequest(http.MethodPost, "/v1/friend/accept", bytes.NewReader(acceptBody))
	accept = accept.WithContext(middleware.WithIdentity(accept.Context(), middleware.Identity{UserID: b}))
	w = httptest.NewRecorder()
	(friend.Service{DB: db}).Decide(w, accept)
	if w.Code != 403 {
		t.Fatalf("blocked pending request accepted: %d", w.Code)
	}
	var count int
	if err = db.QueryRow(ctx, "SELECT count(*) FROM friendships WHERE user_a=LEAST($1::uuid,$2::uuid) AND user_b=GREATEST($1::uuid,$2::uuid)", a, b).Scan(&count); err != nil || count != 0 {
		t.Fatalf("friendship after block: %d %v", count, err)
	}
	if _, err = db.Exec(ctx, "INSERT INTO friendships(user_a,user_b) VALUES(LEAST($1::uuid,$2::uuid),GREATEST($1::uuid,$2::uuid))", a, b); err != nil {
		t.Fatal(err)
	}
	for _, check := range []struct {
		name        string
		run         func(http.ResponseWriter, *http.Request)
		path, param string
		want        int
	}{
		{"legacy bundle", (device.Service{DB: db}).Bundle, "/v1/users/" + b + "/prekey-bundle", "id", 403},
		{"v4 bundle", (device.Service{DB: db}).V4Bundle, "/v1/users/" + b + "/v4-prekey-bundle", "id", 403},
		{"presence", (presence.Service{DB: db}).Get, "/v1/presence/" + "block_" + b[:8], "userID", 404},
	} {
		req := httptest.NewRequest(http.MethodGet, check.path, nil)
		if check.param == "id" {
			req.SetPathValue(check.param, b)
		} else {
			req.SetPathValue(check.param, "block_"+b[:8])
		}
		req = req.WithContext(middleware.WithIdentity(req.Context(), middleware.Identity{UserID: a}))
		w = httptest.NewRecorder()
		check.run(w, req)
		if w.Code != check.want {
			t.Fatalf("%s after block: %d", check.name, w.Code)
		}
	}
}
