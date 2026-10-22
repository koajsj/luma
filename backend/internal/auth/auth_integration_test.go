package auth

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/google/uuid"
	"luma/backend/internal/crypto"
	"luma/backend/internal/database"
)

func TestDisabledAccountCannotIssueTokens(t *testing.T) {
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
	uid, did, cid := uuid.NewString(), uuid.NewString(), uuid.NewString()
	pub, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = db.Exec(ctx, "INSERT INTO users(id,user_id,identity_public_key,disabled_at) VALUES($1,$2,$3,now())", uid, "disabled_"+uid[:8], []byte{1}); err != nil {
		t.Fatal(err)
	}
	if _, err = db.Exec(ctx, "INSERT INTO devices(id,user_id,device_name,device_public_key,auth_public_key) VALUES($1,$2,'test',$3,$4)", did, uid, []byte{1}, pub); err != nil {
		t.Fatal(err)
	}
	nonce := "test-only-login-challenge"
	if _, err = db.Exec(ctx, "INSERT INTO auth_challenges(id,device_id,purpose,user_id,nonce_hash,expires_at) VALUES($1,$2,'login','',$3,now()+interval '2 minutes')", cid, did, crypto.Hash(nonce)); err != nil {
		t.Fatal(err)
	}
	signature := ed25519.Sign(private, []byte("luma.login.v1\n"+nonce+"\n"+did))
	body, _ := json.Marshal(map[string]string{"challengeID": cid, "deviceID": did, "nonce": nonce, "signature": base64.RawURLEncoding.EncodeToString(signature)})
	w := httptest.NewRecorder()
	(Service{DB: db}).Token(w, httptest.NewRequest("POST", "/v1/auth/token", bytes.NewReader(body)))
	if w.Code != 401 {
		t.Fatalf("disabled account issued tokens: status %d", w.Code)
	}
	var count int
	if err = db.QueryRow(ctx, "SELECT count(*) FROM access_sessions WHERE device_id=$1", did).Scan(&count); err != nil || count != 0 {
		t.Fatalf("sessions persisted for disabled account: %d, %v", count, err)
	}
}
