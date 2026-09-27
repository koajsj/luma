package device

import (
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"luma/backend/internal/middleware"
	"net/http"
	"strconv"
)

func v4Fields(domain string, values ...[]byte) []byte {
	result := []byte(domain)
	for _, value := range values {
		var n [4]byte
		binary.BigEndian.PutUint32(n[:], uint32(len(value)))
		result = append(result, n[:]...)
		result = append(result, value...)
	}
	return result
}

func v4Decode(s string, size int) ([]byte, error) {
	b, err := base64.RawURLEncoding.DecodeString(s)
	if err != nil || len(b) != size {
		return nil, errors.New("invalid_v4_key")
	}
	return b, nil
}

func v4Binding(deviceID string, version int, agreement, signing []byte) []byte {
	return v4Fields("luma.v4.binding", []byte(deviceID), []byte(strconv.Itoa(version)), agreement, signing)
}

func v4PrekeyProof(deviceID string, version int, agreement, signing, prekey []byte) []byte {
	return v4Fields("luma.v4.signed-prekey", []byte(deviceID), []byte(strconv.Itoa(version)), agreement, signing, prekey)
}

// The legacy account identity signs the new Curve25519 device identity. The server
// validates the binding but never receives private material.
func (s Service) PutV4Prekeys(w http.ResponseWriter, r *http.Request) {
	i := middleware.Current(r)
	deviceID := r.PathValue("id")
	if deviceID != i.DeviceID {
		middleware.Fail(w, r, 403, "forbidden")
		return
	}
	var in struct {
		IdentityAgreementPublic string   `json:"identityAgreementPublicKey"`
		IdentitySigningPublic   string   `json:"identitySigningPublicKey"`
		IdentityBinding         string   `json:"identityBindingSignature"`
		SignedPrekey            string   `json:"signedPreKeyPublicKey"`
		SignedPrekeySignature   string   `json:"signedPreKeySignature"`
		KeyVersion              int      `json:"keyVersion"`
		OneTimePrekeys          []string `json:"oneTimePreKeys"`
	}
	if !middleware.Decode(w, r, &in) {
		return
	}
	agreement, e1 := v4Decode(in.IdentityAgreementPublic, 32)
	signing, e2 := v4Decode(in.IdentitySigningPublic, 32)
	binding, e3 := base64.RawURLEncoding.DecodeString(in.IdentityBinding)
	prekey, e4 := v4Decode(in.SignedPrekey, 32)
	proof, e5 := v4Decode(in.SignedPrekeySignature, 64)
	if e1 != nil || e2 != nil || e3 != nil || e4 != nil || e5 != nil || in.KeyVersion < 1 ||
		len(in.OneTimePrekeys) > 100 {
		middleware.Fail(w, r, 400, "invalid_v4_keys")
		return
	}
	var accountIdentity []byte
	if s.DB.QueryRow(r.Context(), "SELECT identity_public_key FROM users WHERE id=$1 AND disabled_at IS NULL", i.UserID).Scan(&accountIdentity) != nil {
		middleware.Fail(w, r, 403, "forbidden")
		return
	}
	x, y := elliptic.Unmarshal(elliptic.P256(), accountIdentity)
	bindHash := sha256.Sum256(v4Binding(deviceID, in.KeyVersion, agreement, signing))
	if x == nil || !ecdsa.VerifyASN1(&ecdsa.PublicKey{Curve: elliptic.P256(), X: x, Y: y}, bindHash[:], binding) ||
		!ed25519.Verify(ed25519.PublicKey(signing),
			v4PrekeyProof(deviceID, in.KeyVersion, agreement, signing, prekey), proof) {
		middleware.Fail(w, r, 400, "invalid_v4_signature")
		return
	}
	keys := make([][]byte, 0, len(in.OneTimePrekeys))
	for _, raw := range in.OneTimePrekeys {
		key, err := v4Decode(raw, 32)
		if err != nil {
			middleware.Fail(w, r, 400, "invalid_v4_keys")
			return
		}
		keys = append(keys, key)
	}
	tx, err := s.DB.Begin(r.Context())
	if err != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	defer tx.Rollback(r.Context())
	var oldAgreement, oldSigning, oldPrekey []byte
	var oldVersion int
	err = tx.QueryRow(r.Context(), "SELECT identity_agreement_public,identity_signing_public,signed_prekey_public,key_version FROM v4_device_prekeys WHERE device_id=$1 FOR UPDATE", deviceID).
		Scan(&oldAgreement, &oldSigning, &oldPrekey, &oldVersion)
	if err == nil {
		if string(oldAgreement) != string(agreement) || string(oldSigning) != string(signing) ||
			in.KeyVersion < oldVersion || (in.KeyVersion == oldVersion && string(oldPrekey) != string(prekey)) {
			middleware.Fail(w, r, 409, "v4_identity_or_version_changed")
			return
		}
	} else if !errors.Is(err, pgx.ErrNoRows) {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	_, err = tx.Exec(r.Context(), `INSERT INTO v4_device_prekeys(device_id,identity_agreement_public,identity_signing_public,identity_binding_signature,signed_prekey_public,signed_prekey_signature,key_version)
		VALUES($1,$2,$3,$4,$5,$6,$7) ON CONFLICT(device_id) DO UPDATE SET identity_binding_signature=EXCLUDED.identity_binding_signature,
		signed_prekey_public=EXCLUDED.signed_prekey_public,signed_prekey_signature=EXCLUDED.signed_prekey_signature,key_version=EXCLUDED.key_version,updated_at=now()`,
		deviceID, agreement, signing, binding, prekey, proof, in.KeyVersion)
	for _, key := range keys {
		if err != nil {
			break
		}
		_, err = tx.Exec(r.Context(), "INSERT INTO v4_one_time_prekeys(device_id,public_key) VALUES($1,$2) ON CONFLICT(device_id,public_key) DO NOTHING", deviceID, key)
	}
	if err != nil || tx.Commit(r.Context()) != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	w.WriteHeader(204)
}

// V4PrekeyStatus exposes only this authenticated device's remaining public one-time keys.
func (s Service) V4PrekeyStatus(w http.ResponseWriter, r *http.Request) {
	i := middleware.Current(r)
	if r.PathValue("id") != i.DeviceID {
		middleware.Fail(w, r, 403, "forbidden")
		return
	}
	var available int
	err := s.DB.QueryRow(r.Context(), `SELECT count(*) FROM v4_one_time_prekeys k
		JOIN devices d ON d.id=k.device_id WHERE k.device_id=$1 AND d.user_id=$2
		AND d.revoked_at IS NULL AND k.claimed_at IS NULL`, i.DeviceID, i.UserID).Scan(&available)
	if err != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	middleware.JSON(w, 200, map[string]int{"availableOneTimePreKeys": available})
}

func (s Service) V4Bundle(w http.ResponseWriter, r *http.Request) {
	target := r.PathValue("id")
	me := middleware.Current(r).UserID
	includeRevoked := r.URL.Query().Get("includeRevoked") == "true"
	if includeRevoked && r.URL.Query().Get("claim") != "false" {
		middleware.Fail(w, r, 400, "invalid_request")
		return
	}
	selectedDevice := r.URL.Query().Get("deviceID")
	if includeRevoked {
		parsed, err := uuid.Parse(selectedDevice)
		if err != nil {
			middleware.Fail(w, r, 400, "invalid_device_id")
			return
		}
		selectedDevice = parsed.String()
	}
	var allowed bool
	if s.DB.QueryRow(r.Context(), `SELECT $1::uuid=$2::uuid OR (
		EXISTS(SELECT 1 FROM friendships WHERE user_a=LEAST($1::uuid,$2::uuid) AND user_b=GREATEST($1::uuid,$2::uuid))
		AND NOT EXISTS(SELECT 1 FROM blocks WHERE (blocker=$1 AND blocked=$2) OR (blocker=$2 AND blocked=$1)))`, me, target).Scan(&allowed) != nil || !allowed {
		middleware.Fail(w, r, 403, "forbidden")
		return
	}
	var identity []byte
	if s.DB.QueryRow(r.Context(), "SELECT identity_public_key FROM users WHERE id=$1 AND disabled_at IS NULL", target).Scan(&identity) != nil {
		middleware.Fail(w, r, 404, "not_found")
		return
	}
	tx, err := s.DB.Begin(r.Context())
	if err != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	defer tx.Rollback(r.Context())
	var active int
	if tx.QueryRow(r.Context(), "SELECT count(*) FROM devices WHERE user_id=$1 AND revoked_at IS NULL", target).Scan(&active) != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	rows, err := tx.Query(r.Context(), `SELECT d.id,p.identity_agreement_public,p.identity_signing_public,p.identity_binding_signature,
		p.signed_prekey_public,p.signed_prekey_signature,p.key_version FROM devices d
		JOIN v4_device_prekeys p ON p.device_id=d.id WHERE d.user_id=$1 AND
		(($2 AND d.id::text=$3) OR (NOT $2 AND d.revoked_at IS NULL)) ORDER BY d.id`, target, includeRevoked, selectedDevice)
	if err != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	type entry struct {
		id                                         string
		agreement, signing, binding, prekey, proof []byte
		version                                    int
	}
	entries := []entry{}
	for rows.Next() {
		var x entry
		if rows.Scan(&x.id, &x.agreement, &x.signing, &x.binding, &x.prekey, &x.proof, &x.version) != nil {
			rows.Close()
			middleware.Fail(w, r, 503, "storage_unavailable")
			return
		}
		entries = append(entries, x)
	}
	if rows.Err() != nil {
		rows.Close()
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	rows.Close()
	if (!includeRevoked && len(entries) != active) || (includeRevoked && len(entries) != 1) {
		middleware.Fail(w, r, 409, "v4_not_ready_on_all_devices")
		return
	}
	out := []map[string]any{}
	encode := base64.RawURLEncoding.EncodeToString
	for _, x := range entries {
		var one []byte
		if r.URL.Query().Get("claim") != "false" && x.id != middleware.Current(r).DeviceID {
			err = tx.QueryRow(r.Context(), "UPDATE v4_one_time_prekeys SET claimed_at=now() WHERE id=(SELECT id FROM v4_one_time_prekeys WHERE device_id=$1 AND claimed_at IS NULL ORDER BY id FOR UPDATE SKIP LOCKED LIMIT 1) RETURNING public_key", x.id).Scan(&one)
			if err != nil && !errors.Is(err, pgx.ErrNoRows) {
				middleware.Fail(w, r, 503, "storage_unavailable")
				return
			}
			if errors.Is(err, pgx.ErrNoRows) {
				middleware.Fail(w, r, 409, "v4_prekeys_exhausted")
				return
			}
		}
		out = append(out, map[string]any{"accountIdentityPublicKey": encode(identity), "deviceID": x.id,
			"keyVersion": x.version, "identityAgreementPublicKey": encode(x.agreement),
			"identitySigningPublicKey": encode(x.signing), "identityBindingSignature": encode(x.binding),
			"signedPreKeyPublicKey": encode(x.prekey), "signedPreKeySignature": encode(x.proof),
			"oneTimePreKeyPublicKey": encode(one)})
	}
	if tx.Commit(r.Context()) != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	middleware.JSON(w, 200, out)
}
