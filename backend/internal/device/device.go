package device

import (
	"bytes"
	"encoding/base64"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"luma/backend/internal/crypto"
	"luma/backend/internal/middleware"
	"luma/backend/internal/sync"
	"net/http"
	"time"
)

type Notifier interface {
	Notify(deviceID string, seq int64)
	Disconnect(deviceID string)
}
type Service struct {
	DB     *pgxpool.Pool
	Notify Notifier
}

func (s Service) List(w http.ResponseWriter, r *http.Request) {
	rows, e := s.DB.Query(r.Context(), "SELECT id,device_name,created_at,last_active_at,revoked_at FROM devices WHERE user_id=$1 ORDER BY created_at", middleware.Current(r).UserID)
	if e != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	defer rows.Close()
	out := []map[string]any{}
	for rows.Next() {
		var id, name string
		var created any
		var last, revoked any
		if rows.Scan(&id, &name, &created, &last, &revoked) != nil {
			middleware.Fail(w, r, 503, "storage_unavailable")
			return
		}
		out = append(out, map[string]any{"id": id, "deviceName": name, "createdAt": created, "lastActiveAt": last, "revokedAt": revoked})
	}
	middleware.JSON(w, 200, out)
}
func (s Service) Revoke(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	i := middleware.Current(r)
	if id == i.DeviceID {
		middleware.Fail(w, r, 409, "cannot_revoke_current_device")
		return
	}
	tx, e := s.DB.Begin(r.Context())
	if e != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	defer tx.Rollback(r.Context())
	tag, e := tx.Exec(r.Context(), "UPDATE devices SET revoked_at=now() WHERE id=$1 AND user_id=$2 AND revoked_at IS NULL", id, i.UserID)
	if e != nil || tag.RowsAffected() == 0 {
		middleware.Fail(w, r, 404, "not_found")
		return
	}
	_, e = tx.Exec(r.Context(), "UPDATE access_sessions SET revoked_at=now() WHERE device_id=$1", id)
	if e == nil {
		_, e = tx.Exec(r.Context(), "UPDATE refresh_sessions SET revoked_at=now() WHERE device_id=$1", id)
	}
	if e == nil {
		_, e = tx.Exec(r.Context(), "DELETE FROM one_time_prekeys WHERE device_id=$1", id)
	}
	if e == nil {
		_, e = tx.Exec(r.Context(), "DELETE FROM signed_prekeys WHERE device_id=$1", id)
	}
	if e == nil {
		_, e = tx.Exec(r.Context(), "DELETE FROM v4_one_time_prekeys WHERE device_id=$1", id)
	}
	// Keep signed public v4 identity material for validating envelopes sent before
	// revocation. The active-device bundle excludes this device from new sends.
	seqs := map[string]int64{}
	if e == nil {
		rows, err := tx.Query(r.Context(), "SELECT id FROM devices WHERE user_id=$1 AND revoked_at IS NULL AND id<>$2", i.UserID, id)
		if err != nil {
			e = err
		} else {
			ids := []string{}
			for rows.Next() {
				var other string
				if err = rows.Scan(&other); err != nil {
					e = err
					break
				}
				ids = append(ids, other)
			}
			if rows.Err() != nil {
				e = rows.Err()
			}
			rows.Close()
			if e == nil {
				for _, other := range ids {
					var seq int64
					seq, e = sync.Append(r.Context(), tx, other, "device.revoked", nil, map[string]any{"revokedDeviceID": id})
					if e != nil {
						break
					}
					seqs[other] = seq
				}
			}
		}
	}
	if e != nil || tx.Commit(r.Context()) != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	if s.Notify != nil {
		s.Notify.Disconnect(id)
		for other, seq := range seqs {
			s.Notify.Notify(other, seq)
		}
	}
	w.WriteHeader(204)
}
func (s Service) PutPrekeys(w http.ResponseWriter, r *http.Request) {
	i := middleware.Current(r)
	if r.PathValue("id") != i.DeviceID {
		middleware.Fail(w, r, 403, "forbidden")
		return
	}
	var in struct {
		SignedPreKey   string   `json:"signedPreKey"`
		Signature      string   `json:"signature"`
		KeyVersion     int      `json:"keyVersion"`
		OneTimePreKeys []string `json:"oneTimePreKeys"`
	}
	if !middleware.Decode(w, r, &in) {
		return
	}
	pre, e := crypto.DecodeKey(in.SignedPreKey)
	sig, e2 := crypto.DecodeSignature(in.Signature)
	if e != nil || e2 != nil || len(sig) == 0 || in.KeyVersion < 1 || len(in.OneTimePreKeys) > 100 {
		middleware.Fail(w, r, 400, "invalid_prekeys")
		return
	}
	var identity []byte
	e = s.DB.QueryRow(r.Context(), "SELECT identity_public_key FROM users WHERE id=$1", i.UserID).Scan(&identity)
	if e != nil || !crypto.VerifySignedPrekey(identity, pre, sig) {
		middleware.Fail(w, r, 400, "invalid_prekey_signature")
		return
	}
	tx, e := s.DB.Begin(r.Context())
	if e != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	defer tx.Rollback(r.Context())
	_, e = tx.Exec(r.Context(), "INSERT INTO signed_prekeys(device_id,public_key,signature,key_version) VALUES($1,$2,$3,$4) ON CONFLICT(device_id,key_version) DO NOTHING", i.DeviceID, pre, sig, in.KeyVersion)
	for _, v := range in.OneTimePreKeys {
		if e != nil {
			break
		}
		b, err := crypto.DecodeKey(v)
		if err != nil {
			middleware.Fail(w, r, 400, "invalid_prekeys")
			return
		}
		_, e = tx.Exec(r.Context(), "INSERT INTO one_time_prekeys(device_id,public_key) VALUES($1,$2)", i.DeviceID, b)
	}
	if e != nil || tx.Commit(r.Context()) != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	w.WriteHeader(204)
}
func (s Service) Bundle(w http.ResponseWriter, r *http.Request) {
	target := r.PathValue("id")
	me := middleware.Current(r).UserID
	var allowed bool
	e := s.DB.QueryRow(r.Context(), "SELECT ($1::uuid=$2::uuid OR EXISTS(SELECT 1 FROM friendships WHERE user_a=LEAST($1::uuid,$2::uuid) AND user_b=GREATEST($1::uuid,$2::uuid))) AND NOT EXISTS(SELECT 1 FROM blocks WHERE (blocker=$1 AND blocked=$2) OR (blocker=$2 AND blocked=$1))", me, target).Scan(&allowed)
	if e != nil || !allowed {
		middleware.Fail(w, r, 403, "forbidden")
		return
	}
	var identity []byte
	var identityVersion int
	e = s.DB.QueryRow(r.Context(), "SELECT identity_public_key,identity_key_version FROM users WHERE id=$1", target).Scan(&identity, &identityVersion)
	if e != nil {
		middleware.Fail(w, r, 404, "not_found")
		return
	}
	tx, e := s.DB.Begin(r.Context())
	if e != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	defer tx.Rollback(r.Context())
	rows, e := tx.Query(r.Context(), "SELECT d.id,d.device_public_key,s.public_key,s.signature,s.key_version FROM devices d JOIN LATERAL (SELECT public_key,signature,key_version FROM signed_prekeys WHERE device_id=d.id ORDER BY key_version DESC LIMIT 1) s ON true WHERE d.user_id=$1 AND d.revoked_at IS NULL", target)
	if e != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	type info struct {
		id               string
		device, pre, sig []byte
		version          int
	}
	list := []info{}
	for rows.Next() {
		var x info
		if rows.Scan(&x.id, &x.device, &x.pre, &x.sig, &x.version) != nil {
			rows.Close()
			middleware.Fail(w, r, 503, "storage_unavailable")
			return
		}
		list = append(list, x)
	}
	rows.Close()
	out := []map[string]any{}
	for _, x := range list {
		var one []byte
		if r.URL.Query().Get("claim") != "false" && x.id != middleware.Current(r).DeviceID {
			_ = tx.QueryRow(r.Context(), "UPDATE one_time_prekeys SET claimed_at=now() WHERE id=(SELECT id FROM one_time_prekeys WHERE device_id=$1 AND claimed_at IS NULL ORDER BY id FOR UPDATE SKIP LOCKED LIMIT 1) RETURNING public_key", x.id).Scan(&one)
		}
		out = append(out, map[string]any{"identityPublicKey": base64.RawURLEncoding.EncodeToString(identity), "identityKeyVersion": identityVersion, "deviceID": x.id, "devicePublicKey": base64.RawURLEncoding.EncodeToString(x.device), "signedPreKey": base64.RawURLEncoding.EncodeToString(x.pre), "signature": base64.RawURLEncoding.EncodeToString(x.sig), "keyVersion": x.version, "oneTimePreKey": base64.RawURLEncoding.EncodeToString(one)})
	}
	if tx.Commit(r.Context()) != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	middleware.JSON(w, 200, out)
}
func (s Service) AuthorizeChallenge(w http.ResponseWriter, r *http.Request) {
	i := middleware.Current(r)
	nonce, e := crypto.Random()
	if e != nil {
		middleware.Fail(w, r, 500, "random_unavailable")
		return
	}
	id := uuid.NewString()
	_, e = s.DB.Exec(r.Context(), "INSERT INTO auth_challenges(id,device_id,purpose,nonce_hash,expires_at) VALUES($1,$2,'device_authorize',$3,now()+interval '2 minutes')", id, i.DeviceID, crypto.Hash(nonce))
	if e != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	middleware.JSON(w, 200, map[string]any{"challengeID": id, "nonce": nonce, "expiresAt": time.Now().Add(2 * time.Minute).UTC()})
}
func (s Service) Authorize(w http.ResponseWriter, r *http.Request) {
	var in struct {
		ChallengeID, Nonce, DeviceName, DevicePublicKey, AuthPublicKey, SignedPreKey, SignedPreKeySignature, NewDeviceSignature, ApproverSignature string
		SignedPreKeyVersion                                                                                                                        int
	}
	if !middleware.Decode(w, r, &in) {
		return
	}
	if len(in.DeviceName) < 1 || len(in.DeviceName) > 100 || in.SignedPreKeyVersion < 1 {
		middleware.Fail(w, r, 400, "invalid_request")
		return
	}
	device, e1 := crypto.DecodeKey(in.DevicePublicKey)
	authKey, e2 := crypto.DecodeKey(in.AuthPublicKey)
	pre, e3 := crypto.DecodeKey(in.SignedPreKey)
	preSig, e4 := crypto.DecodeSignature(in.SignedPreKeySignature)
	newSig, e5 := crypto.DecodeSignature(in.NewDeviceSignature)
	approverSig, e6 := crypto.DecodeSignature(in.ApproverSignature)
	if e1 != nil || e2 != nil || e3 != nil || e4 != nil || e5 != nil || e6 != nil {
		middleware.Fail(w, r, 400, "invalid_keys")
		return
	}
	i := middleware.Current(r)
	tx, e := s.DB.Begin(r.Context())
	if e != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	defer tx.Rollback(r.Context())
	var identity, approver, nonceHash []byte
	e = tx.QueryRow(r.Context(), "SELECT u.identity_public_key,d.auth_public_key,c.nonce_hash FROM users u JOIN devices d ON d.user_id=u.id JOIN auth_challenges c ON c.device_id=d.id WHERE u.id=$1 AND d.id=$2 AND d.revoked_at IS NULL AND c.id=$3 AND c.purpose='device_authorize' AND c.used_at IS NULL AND c.expires_at>now() FOR UPDATE OF c", i.UserID, i.DeviceID, in.ChallengeID).Scan(&identity, &approver, &nonceHash)
	if e != nil || !bytes.Equal(nonceHash, crypto.Hash(in.Nonce)) || !crypto.VerifySignedPrekey(identity, pre, preSig) {
		middleware.Fail(w, r, 401, "invalid_challenge")
		return
	}
	canonical := "luma.device.authorize.v1\n" + in.Nonce + "\n" + i.UserID + "\n" + in.DevicePublicKey + "\n" + in.AuthPublicKey + "\n" + in.SignedPreKey
	if !crypto.VerifyEd25519(approver, approverSig, canonical) || !crypto.VerifyEd25519(authKey, newSig, canonical) {
		middleware.Fail(w, r, 401, "invalid_signature")
		return
	}
	id := uuid.NewString()
	_, e = tx.Exec(r.Context(), "INSERT INTO devices(id,user_id,device_name,device_public_key,auth_public_key) VALUES($1,$2,$3,$4,$5)", id, i.UserID, in.DeviceName, device, authKey)
	if e == nil {
		_, e = tx.Exec(r.Context(), "INSERT INTO signed_prekeys(device_id,public_key,signature,key_version) VALUES($1,$2,$3,$4)", id, pre, preSig, in.SignedPreKeyVersion)
	}
	if e == nil {
		_, e = tx.Exec(r.Context(), "UPDATE auth_challenges SET used_at=now() WHERE id=$1", in.ChallengeID)
	}
	if e != nil || tx.Commit(r.Context()) != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	middleware.JSON(w, 201, map[string]string{"deviceID": id})
}
