package useridindex_test

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/google/uuid"
	"luma/backend/internal/auth"
	"luma/backend/internal/database"
	"luma/backend/internal/friend"
	"luma/backend/internal/middleware"
	"luma/backend/internal/user"
	"luma/backend/internal/useridindex"
)

func TestLegacyBackfillSearchPrivacyAndFriendRequest(t *testing.T) {
	dsn := os.Getenv("LUMA_USERID_INDEX_TEST_DSN")
	if dsn == "" {
		t.Skip("isolated PostgreSQL DSN not provided")
	}
	ctx := context.Background()
	db, err := database.Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if err = database.Migrate(ctx, db, "../../migrations"); err != nil {
		t.Fatal(err)
	}
	key, err := useridindex.ParseKey(strings.Repeat("a1", 32))
	if err != nil {
		t.Fatal(err)
	}
	alice, bob := uuid.NewString(), uuid.NewString()
	_, err = db.Exec(ctx, "INSERT INTO users(id,user_id,identity_public_key) VALUES($1,'alice',$2),($3,'bob',$2)", alice, []byte{1}, bob)
	if err != nil {
		t.Fatal(err)
	}
	if err = key.Backfill(ctx, db); err != nil {
		t.Fatal(err)
	}
	var stored []byte
	if err = db.QueryRow(ctx, "SELECT user_id_hash FROM users WHERE id=$1", bob).Scan(&stored); err != nil || !bytes.Equal(stored, key.Sum("bob")) {
		t.Fatalf("legacy backfill mismatch: %v", err)
	}
	search := func() int {
		req := httptest.NewRequest(http.MethodGet, "/v1/users/search?userID=%20BOB%20", nil)
		req = req.WithContext(middleware.WithIdentity(req.Context(), middleware.Identity{UserID: alice}))
		w := httptest.NewRecorder()
		(user.Service{DB: db, UserIDIndexKey: key}).Search(w, req)
		return w.Code
	}
	if got := search(); got != 404 {
		t.Fatalf("private user discovered: %d", got)
	}
	if _, err = db.Exec(ctx, "UPDATE users SET searchable=true WHERE id=$1", bob); err != nil {
		t.Fatal(err)
	}
	if got := search(); got != 200 {
		t.Fatalf("search failed: %d", got)
	}
	request, _ := json.Marshal(map[string]string{"userID": " BOB "})
	req := httptest.NewRequest(http.MethodPost, "/v1/friend/request", bytes.NewReader(request))
	req = req.WithContext(middleware.WithIdentity(req.Context(), middleware.Identity{UserID: alice}))
	w := httptest.NewRecorder()
	(friend.Service{DB: db, UserIDIndexKey: key}).Request(w, req)
	if w.Code != 202 {
		t.Fatalf("friend request failed: %d", w.Code)
	}
	var count int
	if err = db.QueryRow(ctx, "SELECT count(*) FROM friend_requests WHERE from_user=$1 AND to_user=$2", alice, bob).Scan(&count); err != nil || count != 1 {
		t.Fatalf("friend request not stored: %v", err)
	}
	otherKey, _ := useridindex.ParseKey(strings.Repeat("b2", 32))
	if err = otherKey.Backfill(ctx, db); err == nil {
		t.Fatal("changed index secret accepted")
	}
	challengeBody, _ := json.Marshal(map[string]string{"userID": "charlie"})
	challengeResponse := httptest.NewRecorder()
	(auth.Service{DB: db}).Challenge(challengeResponse,
		httptest.NewRequest(http.MethodPost, "/v1/auth/register/challenge", bytes.NewReader(challengeBody)))
	if challengeResponse.Code != 200 {
		t.Fatalf("registration challenge: %d", challengeResponse.Code)
	}
	var challenge struct{ ChallengeID, Nonce string }
	if err = json.Unmarshal(challengeResponse.Body.Bytes(), &challenge); err != nil {
		t.Fatal(err)
	}
	identity, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	authPublic, authPrivate, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	encode := base64.RawURLEncoding.EncodeToString
	identityPublic := encode(elliptic.Marshal(elliptic.P256(), identity.PublicKey.X, identity.PublicKey.Y))
	devicePublic, prekeyPublic := encode([]byte{1, 2, 3}), encode([]byte{4, 5, 6})
	authPublicEncoded := encode(authPublic)
	prekeyHash := sha256.Sum256([]byte{4, 5, 6})
	prekeySignature, err := ecdsa.SignASN1(rand.Reader, identity, prekeyHash[:])
	if err != nil {
		t.Fatal(err)
	}
	canonical := "luma.register.v1\n" + challenge.Nonce + "\ncharlie\n" + identityPublic + "\n" + devicePublic + "\n" + authPublicEncoded + "\n" + prekeyPublic
	registration, _ := json.Marshal(map[string]any{
		"challengeID": challenge.ChallengeID, "nonce": challenge.Nonce, "userID": "charlie", "nickname": "Charlie",
		"identityPublicKey": identityPublic, "devicePublicKey": devicePublic, "authPublicKey": authPublicEncoded,
		"deviceName": "test", "signedPreKey": prekeyPublic, "signedPreKeySignature": encode(prekeySignature),
		"signedPreKeyVersion": 1, "signature": encode(ed25519.Sign(authPrivate, []byte(canonical))),
	})
	registerResponse := httptest.NewRecorder()
	(auth.Service{DB: db, UserIDIndexKey: key}).Register(registerResponse,
		httptest.NewRequest(http.MethodPost, "/v1/auth/register", bytes.NewReader(registration)))
	if registerResponse.Code != 201 {
		t.Fatalf("registration failed: %d", registerResponse.Code)
	}
	if err = db.QueryRow(ctx, "SELECT user_id_hash FROM users WHERE user_id='charlie'").Scan(&stored); err != nil || !bytes.Equal(stored, key.Sum("charlie")) {
		t.Fatalf("new account index mismatch: %v", err)
	}
}
