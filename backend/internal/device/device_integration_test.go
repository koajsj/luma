package device_test

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

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
