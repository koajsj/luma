package device_test

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
	"testing"
	"time"

	"github.com/google/uuid"
	"luma/backend/internal/auth"
	"luma/backend/internal/crypto"
	"luma/backend/internal/database"
	"luma/backend/internal/device"
	"luma/backend/internal/middleware"
)

// Uses an explicitly provided isolated PostgreSQL database; no external test framework.
func TestRevocationInvalidatesTokenAndEmitsOneCursorEvent(t *testing.T) {
	dsn := os.Getenv("LUMA_DEVICE_TEST_DSN")
	if dsn == "" {
		t.Skip("isolated PostgreSQL DSN not provided")
	}
	db, err := database.Open(context.Background(), dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	uid, approver, target := uuid.NewString(), uuid.NewString(), uuid.NewString()
	name := "test_" + uuid.NewString()[:8]
	_, err = db.Exec(context.Background(), "INSERT INTO users(id,user_id,identity_public_key) VALUES($1,$2,$3)", uid, name, []byte{1})
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{approver, target} {
		_, err = db.Exec(context.Background(), "INSERT INTO devices(id,user_id,device_name,device_public_key,auth_public_key) VALUES($1,$2,'test',$3,$4)", id, uid, []byte{1}, []byte{2})
		if err != nil {
			t.Fatal(err)
		}
	}
	_, err = db.Exec(context.Background(), "INSERT INTO signed_prekeys(device_id,public_key,signature,key_version) VALUES($1,$2,$3,1)", target, []byte{3}, []byte{4})
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec(context.Background(), "INSERT INTO one_time_prekeys(device_id,public_key) VALUES($1,$2)", target, []byte{5})
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec(context.Background(), `INSERT INTO v4_device_prekeys(device_id,identity_agreement_public,identity_signing_public,
		identity_binding_signature,signed_prekey_public,signed_prekey_signature,key_version)
		VALUES($1,$2,$3,$4,$5,$6,1)`, target, make([]byte, 32), make([]byte, 32), []byte{1}, make([]byte, 32), make([]byte, 64))
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec(context.Background(), "INSERT INTO v4_one_time_prekeys(device_id,public_key) VALUES($1,$2)", target, make([]byte, 32))
	if err != nil {
		t.Fatal(err)
	}
	token := uuid.NewString()
	_, err = db.Exec(context.Background(), "INSERT INTO access_sessions(device_id,token_hash,family_id,expires_at) VALUES($1,$2,$3,now()+interval '1 hour')", target, crypto.Hash(token), uuid.NewString())
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec(context.Background(), "INSERT INTO refresh_sessions(device_id,token_hash,family_id,expires_at) VALUES($1,$2,$3,now()+interval '1 hour')", target, crypto.Hash(uuid.NewString()), uuid.NewString())
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodDelete, "/v1/devices/"+target, nil)
	req.SetPathValue("id", target)
	req = req.WithContext(middleware.WithIdentity(req.Context(), middleware.Identity{UserID: uid, DeviceID: approver}))
	w := httptest.NewRecorder()
	(device.Service{DB: db}).Revoke(w, req)
	if w.Code != 204 {
		t.Fatalf("revoke status = %d: %s", w.Code, w.Body.String())
	}
	var accessRevoked, refreshRevoked, deviceRevoked bool
	err = db.QueryRow(context.Background(), `SELECT d.revoked_at IS NOT NULL, a.revoked_at IS NOT NULL, r.revoked_at IS NOT NULL
        FROM devices d JOIN access_sessions a ON a.device_id=d.id JOIN refresh_sessions r ON r.device_id=d.id WHERE d.id=$1`, target).Scan(&deviceRevoked, &accessRevoked, &refreshRevoked)
	if err != nil || !deviceRevoked || !accessRevoked || !refreshRevoked {
		t.Fatalf("tokens/device not revoked: %v", err)
	}
	var publicCount, oneTimeCount int
	err = db.QueryRow(context.Background(), `SELECT (SELECT count(*) FROM v4_device_prekeys WHERE device_id=$1),
		(SELECT count(*) FROM v4_one_time_prekeys WHERE device_id=$1)`, target).Scan(&publicCount, &oneTimeCount)
	if err != nil || publicCount != 1 || oneTimeCount != 0 {
		t.Fatalf("v4 public history or one-time prekeys inconsistent: %d, %d, %v", publicCount, oneTimeCount, err)
	}
	var eventType string
	var routing []byte
	err = db.QueryRow(context.Background(), "SELECT type,routing FROM sync_events WHERE target_device_id=$1 AND device_seq=1", approver).Scan(&eventType, &routing)
	var value map[string]string
	if err != nil || json.Unmarshal(routing, &value) != nil || eventType != "device.revoked" || value["revokedDeviceID"] != target {
		t.Fatalf("revocation event missing: %v", err)
	}
	rejected := httptest.NewRecorder()
	protected := (auth.Service{DB: db}).Require(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(204) }))
	authRequest := httptest.NewRequest(http.MethodGet, "/v1/sync/events?cursor=0", nil)
	authRequest.Header.Set("Authorization", "Bearer "+token)
	protected.ServeHTTP(rejected, authRequest)
	if rejected.Code != 401 {
		t.Fatalf("revoked device sync status = %d", rejected.Code)
	}
	var code map[string]any
	_ = json.Unmarshal(rejected.Body.Bytes(), &code)
	if code["code"] != "device_revoked" {
		t.Fatalf("unexpected auth error: %v", code)
	}
	second := httptest.NewRecorder()
	(device.Service{DB: db}).Revoke(second, req)
	if second.Code != 404 {
		t.Fatalf("duplicate revoke status = %d", second.Code)
	}
	var eventCount int
	if err := db.QueryRow(context.Background(), "SELECT count(*) FROM sync_events WHERE target_device_id=$1 AND type='device.revoked'", approver).Scan(&eventCount); err != nil || eventCount != 1 {
		t.Fatalf("duplicate revocation event: %d, %v", eventCount, err)
	}
}

// Device approvals and revocations must serialize with the account authority,
// including requests whose middleware authentication finished before revocation.
func TestDeviceManagementAuthority(t *testing.T) {
	dsn := os.Getenv("LUMA_DEVICE_TEST_DSN")
	if dsn == "" {
		t.Skip("isolated PostgreSQL DSN not provided")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	db, err := database.Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	account, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	approverPublic, approverPrivate, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	newPublic, newPrivate, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	uid, approver, peer := uuid.NewString(), uuid.NewString(), uuid.NewString()
	public := elliptic.Marshal(elliptic.P256(), account.X, account.Y)
	if _, err = db.Exec(ctx, "INSERT INTO users(id,user_id,identity_public_key) VALUES($1,$2,$3)", uid, "auth_"+uid[:8], public); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{approver, peer} {
		if _, err = db.Exec(ctx, "INSERT INTO devices(id,user_id,device_name,device_public_key,auth_public_key) VALUES($1,$2,'test',$3,$4)", id, uid, public, approverPublic); err != nil {
			t.Fatal(err)
		}
	}
	encode := base64.RawURLEncoding.EncodeToString
	preHash := sha256.Sum256(public)
	preSignature, err := ecdsa.SignASN1(rand.Reader, account, preHash[:])
	if err != nil {
		t.Fatal(err)
	}
	challenge, nonce := uuid.NewString(), uuid.NewString()
	if _, err = db.Exec(ctx, "INSERT INTO auth_challenges(id,device_id,purpose,nonce_hash,expires_at) VALUES($1,$2,'device_authorize',$3,now()+interval '2 minutes')", challenge, approver, crypto.Hash(nonce)); err != nil {
		t.Fatal(err)
	}
	canonical := "luma.device.authorize.v1\n" + nonce + "\n" + uid + "\n" + encode(public) + "\n" + encode(newPublic) + "\n" + encode(public)
	body, err := json.Marshal(map[string]any{"challengeID": challenge, "nonce": nonce, "deviceName": "new", "devicePublicKey": encode(public), "authPublicKey": encode(newPublic), "signedPreKey": encode(public), "signedPreKeySignature": encode(preSignature), "signedPreKeyVersion": 1, "newDeviceSignature": encode(ed25519.Sign(newPrivate, []byte(canonical))), "approverSignature": encode(ed25519.Sign(approverPrivate, []byte(canonical)))})
	if err != nil {
		t.Fatal(err)
	}
	request := func() *http.Request {
		r := httptest.NewRequest(http.MethodPost, "/v1/devices/authorize", bytes.NewReader(body))
		return r.WithContext(middleware.WithIdentity(ctx, middleware.Identity{UserID: uid, DeviceID: approver}))
	}
	svc := device.Service{DB: db}
	accepted := httptest.NewRecorder()
	svc.Authorize(accepted, request())
	if accepted.Code != 201 {
		t.Fatalf("valid authorization: %d", accepted.Code)
	}
	replay := httptest.NewRecorder()
	svc.Authorize(replay, request())
	if replay.Code != 401 {
		t.Fatalf("challenge replay: %d", replay.Code)
	}
	// Refresh the synthetic challenge for a request that has already authenticated.
	if _, err = db.Exec(ctx, "UPDATE auth_challenges SET used_at=NULL WHERE id=$1", challenge); err != nil {
		t.Fatal(err)
	}
	blocker, err := db.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer blocker.Rollback(context.Background())
	var blockerPID int
	if err = blocker.QueryRow(ctx, "SELECT pg_backend_pid() FROM users WHERE id=$1 FOR UPDATE", uid).Scan(&blockerPID); err != nil {
		t.Fatal(err)
	}
	done := make(chan *httptest.ResponseRecorder, 1)
	go func() { w := httptest.NewRecorder(); svc.Authorize(w, request()); done <- w }()
	for {
		select {
		case w := <-done:
			t.Fatalf("authorization bypassed account lock: %d", w.Code)
		default:
		}
		var waiting bool
		if err = db.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE $1=ANY(pg_blocking_pids(pid)))", blockerPID).Scan(&waiting); err != nil {
			t.Fatal(err)
		}
		if waiting {
			break
		}
		select {
		case <-ctx.Done():
			t.Fatal("authorization did not reach account lock")
		case <-time.After(5 * time.Millisecond):
		}
	}
	if _, err = blocker.Exec(ctx, "UPDATE devices SET revoked_at=now() WHERE id=$1", approver); err != nil {
		t.Fatal(err)
	}
	if err = blocker.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	w := <-done
	if w.Code != 403 {
		t.Fatalf("revoked approver resumed authorization: %d", w.Code)
	}
	var count int
	var used bool
	if err = db.QueryRow(ctx, "SELECT (SELECT count(*) FROM devices WHERE user_id=$1),(SELECT used_at IS NOT NULL FROM auth_challenges WHERE id=$2)", uid, challenge).Scan(&count, &used); err != nil || count != 3 || used {
		t.Fatalf("rejected approval changed state: %d %t %v", count, used, err)
	}
	revoke := httptest.NewRequest(http.MethodDelete, "/v1/devices/"+peer, nil)
	revoke.SetPathValue("id", peer)
	revoke = revoke.WithContext(request().Context())
	rejected := httptest.NewRecorder()
	svc.Revoke(rejected, revoke)
	if rejected.Code != 403 {
		t.Fatalf("revoked approver changed roster: %d", rejected.Code)
	}
	if _, err = db.Exec(ctx, "UPDATE users SET disabled_at=now() WHERE id=$1", uid); err != nil {
		t.Fatal(err)
	}
	if _, err = db.Exec(ctx, "UPDATE auth_challenges SET device_id=$1 WHERE id=$2", peer, challenge); err != nil {
		t.Fatal(err)
	}
	// Even an otherwise active device cannot approve for a disabled account.
	disabled := request().WithContext(middleware.WithIdentity(ctx, middleware.Identity{UserID: uid, DeviceID: peer}))
	w = httptest.NewRecorder()
	svc.Authorize(w, disabled)
	if w.Code != 403 {
		t.Fatalf("disabled account authorization: %d", w.Code)
	}
}
