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
	"encoding/binary"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/google/uuid"
	"luma/backend/internal/database"
	"luma/backend/internal/device"
	"luma/backend/internal/middleware"
)

func v4TestFields(domain string, values ...[]byte) []byte {
	out := []byte(domain)
	for _, value := range values {
		var size [4]byte
		binary.BigEndian.PutUint32(size[:], uint32(len(value)))
		out = append(out, size[:]...)
		out = append(out, value...)
	}
	return out
}

// One isolated database check covers signature validation, one-time claiming,
// and read-only verification of a revoked sender's historical public identity.
func TestV4PublicDirectoryAndRevokedHistory(t *testing.T) {
	dsn := os.Getenv("LUMA_DEVICE_TEST_DSN")
	if dsn == "" {
		t.Skip("isolated PostgreSQL DSN not provided")
	}
	db, err := database.Open(context.Background(), dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	account, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	userID, deviceA, deviceB := uuid.NewString(), uuid.NewString(), uuid.NewString()
	accountPublic := elliptic.Marshal(elliptic.P256(), account.PublicKey.X, account.PublicKey.Y)
	_, err = db.Exec(context.Background(), "INSERT INTO users(id,user_id,identity_public_key) VALUES($1,$2,$3)",
		userID, "v4_"+uuid.NewString()[:8], accountPublic)
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{deviceA, deviceB} {
		_, err = db.Exec(context.Background(), "INSERT INTO devices(id,user_id,device_name,device_public_key,auth_public_key) VALUES($1,$2,'test',$3,$4)",
			id, userID, []byte{1}, []byte{2})
		if err != nil {
			t.Fatal(err)
		}
	}
	encode := base64.RawURLEncoding.EncodeToString
	var deviceBUpload []byte
	for _, id := range []string{deviceA, deviceB} {
		signing, private, e := ed25519.GenerateKey(rand.Reader)
		if e != nil {
			t.Fatal(e)
		}
		agreement, prekey, oneTime := make([]byte, 32), make([]byte, 32), make([]byte, 32)
		for _, key := range [][]byte{agreement, prekey, oneTime} {
			if _, e = rand.Read(key); e != nil {
				t.Fatal(e)
			}
		}
		binding := sha256.Sum256(v4TestFields("luma.v4.binding", []byte(id), []byte("1"), agreement, signing))
		bindingSignature, e := ecdsa.SignASN1(rand.Reader, account, binding[:])
		if e != nil {
			t.Fatal(e)
		}
		proof := ed25519.Sign(private, v4TestFields("luma.v4.signed-prekey", []byte(id), []byte("1"), agreement, signing, prekey))
		body, e := json.Marshal(map[string]any{"identityAgreementPublicKey": encode(agreement),
			"identitySigningPublicKey": encode(signing), "identityBindingSignature": encode(bindingSignature),
			"signedPreKeyPublicKey": encode(prekey), "signedPreKeySignature": encode(proof),
			"keyVersion": 1, "oneTimePreKeys": []string{encode(oneTime)}})
		if e != nil {
			t.Fatal(e)
		}
		if id == deviceB {
			deviceBUpload = body
		}
		req := httptest.NewRequest(http.MethodPut, "/v1/devices/"+id+"/v4-prekeys", bytes.NewReader(body))
		req.SetPathValue("id", id)
		req = req.WithContext(middleware.WithIdentity(req.Context(), middleware.Identity{UserID: userID, DeviceID: id}))
		w := httptest.NewRecorder()
		(device.Service{DB: db}).PutV4Prekeys(w, req)
		if w.Code != 204 {
			t.Fatalf("upload: %d %s", w.Code, w.Body.String())
		}
	}
	lookup := func(path string) ([]map[string]any, int) {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		req.SetPathValue("id", userID)
		req = req.WithContext(middleware.WithIdentity(req.Context(), middleware.Identity{UserID: userID, DeviceID: deviceA}))
		w := httptest.NewRecorder()
		(device.Service{DB: db}).V4Bundle(w, req)
		var rows []map[string]any
		_ = json.Unmarshal(w.Body.Bytes(), &rows)
		return rows, w.Code
	}
	rows, code := lookup("/v1/users/" + userID + "/v4-prekey-bundle")
	if code != 200 || len(rows) != 2 {
		t.Fatalf("bundle: %d, %d", code, len(rows))
	}
	var claimed int
	if err = db.QueryRow(context.Background(), "SELECT count(*) FROM v4_one_time_prekeys WHERE device_id=$1 AND claimed_at IS NOT NULL", deviceB).Scan(&claimed); err != nil || claimed != 1 {
		t.Fatalf("one-time claim: %d, %v", claimed, err)
	}
	_, code = lookup("/v1/users/" + userID + "/v4-prekey-bundle")
	if code != 409 {
		t.Fatalf("exhausted one-time key must fail closed: %d", code)
	}
	status := httptest.NewRequest(http.MethodGet, "/v1/devices/"+deviceB+"/v4-prekeys/status", nil)
	status.SetPathValue("id", deviceB)
	status = status.WithContext(middleware.WithIdentity(status.Context(), middleware.Identity{UserID: userID, DeviceID: deviceB}))
	statusWriter := httptest.NewRecorder()
	(device.Service{DB: db}).V4PrekeyStatus(statusWriter, status)
	if statusWriter.Code != 200 || !bytes.Contains(statusWriter.Body.Bytes(), []byte(`"availableOneTimePreKeys":0`)) {
		t.Fatalf("prekey status: %d %s", statusWriter.Code, statusWriter.Body.String())
	}
	var replenished map[string]any
	if err = json.Unmarshal(deviceBUpload, &replenished); err != nil {
		t.Fatal(err)
	}
	newOneTime := make([]byte, 32)
	if _, err = rand.Read(newOneTime); err != nil {
		t.Fatal(err)
	}
	replenished["oneTimePreKeys"] = []string{encode(newOneTime)}
	refillBody, err := json.Marshal(replenished)
	if err != nil {
		t.Fatal(err)
	}
	refill := httptest.NewRequest(http.MethodPut, "/v1/devices/"+deviceB+"/v4-prekeys", bytes.NewReader(refillBody))
	refill.SetPathValue("id", deviceB)
	refill = refill.WithContext(middleware.WithIdentity(refill.Context(), middleware.Identity{UserID: userID, DeviceID: deviceB}))
	refillWriter := httptest.NewRecorder()
	(device.Service{DB: db}).PutV4Prekeys(refillWriter, refill)
	if refillWriter.Code != 204 {
		t.Fatalf("prekey refill: %d %s", refillWriter.Code, refillWriter.Body.String())
	}
	_, code = lookup("/v1/users/" + userID + "/v4-prekey-bundle")
	if code != 200 {
		t.Fatalf("prekey claim after refill: %d", code)
	}
	otherUser := uuid.NewString()
	if _, err = db.Exec(context.Background(), "INSERT INTO users(id,user_id,identity_public_key) VALUES($1,$2,$3)",
		otherUser, "v4_"+uuid.NewString()[:8], accountPublic); err != nil {
		t.Fatal(err)
	}
	if _, err = db.Exec(context.Background(), "INSERT INTO friendships(user_a,user_b) VALUES(LEAST($1::uuid,$2::uuid),GREATEST($1::uuid,$2::uuid))", userID, otherUser); err != nil {
		t.Fatal(err)
	}
	if _, err = db.Exec(context.Background(), "INSERT INTO blocks(blocker,blocked) VALUES($1,$2)", otherUser, userID); err != nil {
		t.Fatal(err)
	}
	blocked := httptest.NewRequest(http.MethodGet, "/v1/users/"+otherUser+"/v4-prekey-bundle?claim=false", nil)
	blocked.SetPathValue("id", otherUser)
	blocked = blocked.WithContext(middleware.WithIdentity(blocked.Context(), middleware.Identity{UserID: userID, DeviceID: deviceA}))
	blockedWriter := httptest.NewRecorder()
	(device.Service{DB: db}).V4Bundle(blockedWriter, blocked)
	if blockedWriter.Code != 403 {
		t.Fatalf("blocked peer may not read v4 directory: %d", blockedWriter.Code)
	}
	revoke := httptest.NewRequest(http.MethodDelete, "/v1/devices/"+deviceB, nil)
	revoke.SetPathValue("id", deviceB)
	revoke = revoke.WithContext(middleware.WithIdentity(revoke.Context(), middleware.Identity{UserID: userID, DeviceID: deviceA}))
	w := httptest.NewRecorder()
	(device.Service{DB: db}).Revoke(w, revoke)
	if w.Code != 204 {
		t.Fatalf("revoke: %d", w.Code)
	}
	rows, code = lookup("/v1/users/" + userID + "/v4-prekey-bundle?claim=false")
	if code != 200 || len(rows) != 1 {
		t.Fatalf("active bundle: %d, %d", code, len(rows))
	}
	rows, code = lookup("/v1/users/" + userID + "/v4-prekey-bundle?claim=false&includeRevoked=true&deviceID=" + deviceB)
	if code != 200 || len(rows) != 1 || rows[0]["deviceID"] != deviceB {
		t.Fatalf("historical bundle: %d, %v", code, rows)
	}
}
