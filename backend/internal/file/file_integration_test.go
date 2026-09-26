package file

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/google/uuid"
	"luma/backend/internal/database"
	"luma/backend/internal/middleware"
)

// Runs only against an explicitly provided isolated, migrated PostgreSQL database.
func TestLocalFileFlowAndAccessControl(t *testing.T) {
	dsn := os.Getenv("LUMA_FILE_TEST_DSN")
	if dsn == "" {
		t.Skip("isolated PostgreSQL DSN not provided")
	}
	db, err := database.Open(context.Background(), dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	owner, stranger := uuid.NewString(), uuid.NewString()
	for _, id := range []string{owner, stranger} {
		_, err = db.Exec(context.Background(),
			"INSERT INTO users(id,user_id,identity_public_key) VALUES($1,$2,$3)",
			id, "file_"+id[:8], []byte{1})
		if err != nil {
			t.Fatal(err)
		}
	}
	storage, err := NewLocalStorage(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	svc := Service{DB: db, Storage: storage}
	call := func(method, path, user string, body []byte, handler http.HandlerFunc) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, path, bytes.NewReader(body))
		req = req.WithContext(middleware.WithIdentity(req.Context(), middleware.Identity{UserID: user}))
		w := httptest.NewRecorder()
		handler(w, req)
		return w
	}
	// Opaque bytes stand in for client ciphertext; the server checks size/hash, not plaintext.
	data := []byte{0, 255, 17, 38, 0, 4}
	hash := sha256.Sum256(data)
	input, _ := json.Marshal(map[string]any{
		"ciphertextSize": len(data), "ciphertextHash": base64.RawURLEncoding.EncodeToString(hash[:]),
	})
	w := call(http.MethodPost, "/v1/files/upload/init", owner, input, svc.Init)
	if w.Code != 201 {
		t.Fatalf("init = %d: %s", w.Code, w.Body.String())
	}
	var created struct {
		AttachmentID string `json:"attachmentID"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &created); err != nil || created.AttachmentID == "" {
		t.Fatalf("invalid init response: %v", err)
	}
	withID := func(method, user string, body []byte, handler http.HandlerFunc) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, fmt.Sprintf("/v1/files/%s/content", created.AttachmentID), bytes.NewReader(body))
		req.SetPathValue("id", created.AttachmentID)
		req = req.WithContext(middleware.WithIdentity(req.Context(), middleware.Identity{UserID: user}))
		w := httptest.NewRecorder()
		handler(w, req)
		return w
	}
	if w := withID(http.MethodPut, owner, data, svc.Upload); w.Code != 204 {
		t.Fatalf("upload = %d: %s", w.Code, w.Body.String())
	}
	complete, _ := json.Marshal(map[string]string{"attachmentID": created.AttachmentID})
	if w := call(http.MethodPost, "/v1/files/upload/complete", owner, complete, svc.Complete); w.Code != 204 {
		t.Fatalf("complete = %d: %s", w.Code, w.Body.String())
	}
	if w := withID(http.MethodGet, stranger, nil, svc.Content); w.Code != 404 {
		t.Fatalf("stranger content = %d", w.Code)
	}
	w = withID(http.MethodGet, owner, nil, svc.Content)
	got, _ := io.ReadAll(w.Body)
	if w.Code != 200 || !bytes.Equal(got, data) {
		t.Fatalf("owner download = %d", w.Code)
	}
	if w := withID(http.MethodDelete, owner, nil, svc.Delete); w.Code != 204 {
		t.Fatalf("delete = %d: %s", w.Code, w.Body.String())
	}
	if w := withID(http.MethodGet, owner, nil, svc.Content); w.Code != 404 {
		t.Fatalf("deleted content = %d", w.Code)
	}
}
