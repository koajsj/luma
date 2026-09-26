package auth

import (
	"context"
	"encoding/base64"
	"errors"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
	"luma/backend/internal/crypto"
	"luma/backend/internal/middleware"
	"net/http"
	"strconv"
	"strings"
	"time"
)

type Service struct {
	DB    *pgxpool.Pool
	Cache *redis.Client
}

func (s Service) Challenge(w http.ResponseWriter, r *http.Request) {
	var in struct {
		DeviceID string `json:"deviceID"`
		UserID   string `json:"userID"`
	}
	if !middleware.Decode(w, r, &in) {
		return
	}
	purpose := "login"
	if strings.HasSuffix(r.URL.Path, "register/challenge") {
		purpose = "register"
		in.UserID = strings.ToLower(strings.TrimSpace(in.UserID))
		if len(in.UserID) < 3 || len(in.UserID) > 32 {
			middleware.Fail(w, r, 400, "invalid_user_id")
			return
		}
	} else {
		if _, e := uuid.Parse(in.DeviceID); e != nil {
			middleware.Fail(w, r, 400, "invalid_device_id")
			return
		}
	}
	nonce, e := crypto.Random()
	if e != nil {
		middleware.Fail(w, r, 500, "random_unavailable")
		return
	}
	id := uuid.NewString()
	var device any
	if purpose == "login" {
		device = in.DeviceID
	}
	_, e = s.DB.Exec(r.Context(), "INSERT INTO auth_challenges(id,device_id,purpose,user_id,nonce_hash,expires_at) VALUES($1,$2,$3,$4,$5,now()+interval '2 minutes')", id, device, purpose, in.UserID, crypto.Hash(nonce))
	if e != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	middleware.JSON(w, 200, map[string]any{"challengeID": id, "nonce": nonce, "expiresAt": time.Now().Add(2 * time.Minute).UTC()})
}

type register struct {
	ChallengeID, Nonce, UserID, Nickname, IdentityPublicKey, DevicePublicKey, AuthPublicKey, DeviceName, SignedPreKey, SignedPreKeySignature, Signature string
	SignedPreKeyVersion                                                                                                                                 int
}

func (s Service) Register(w http.ResponseWriter, r *http.Request) {
	var in register
	if !middleware.Decode(w, r, &in) {
		return
	}
	in.UserID = strings.ToLower(strings.TrimSpace(in.UserID))
	if !validUserID(in.UserID) || len(in.Nickname) > 80 || len(in.DeviceName) < 1 || len(in.DeviceName) > 100 || in.SignedPreKeyVersion < 1 {
		middleware.Fail(w, r, 400, "invalid_request")
		return
	}
	identity, e1 := crypto.DecodeKey(in.IdentityPublicKey)
	device, e2 := crypto.DecodeKey(in.DevicePublicKey)
	auth, e3 := crypto.DecodeKey(in.AuthPublicKey)
	pre, e4 := crypto.DecodeKey(in.SignedPreKey)
	preSig, e5 := crypto.DecodeSignature(in.SignedPreKeySignature)
	sig, e6 := crypto.DecodeSignature(in.Signature)
	if e1 != nil || e2 != nil || e3 != nil || e4 != nil || e5 != nil || e6 != nil || !crypto.VerifySignedPrekey(identity, pre, preSig) {
		middleware.Fail(w, r, 400, "invalid_keys")
		return
	}
	canonical := "luma.register.v1\n" + in.Nonce + "\n" + in.UserID + "\n" + in.IdentityPublicKey + "\n" + in.DevicePublicKey + "\n" + in.AuthPublicKey + "\n" + in.SignedPreKey
	if !crypto.VerifyEd25519(auth, sig, canonical) {
		middleware.Fail(w, r, 401, "invalid_signature")
		return
	}
	tx, e := s.DB.Begin(r.Context())
	if e != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	defer tx.Rollback(r.Context())
	var got []byte
	e = tx.QueryRow(r.Context(), "SELECT nonce_hash FROM auth_challenges WHERE id=$1 AND purpose='register' AND user_id=$2 AND expires_at>now() AND used_at IS NULL FOR UPDATE", in.ChallengeID, in.UserID).Scan(&got)
	if e != nil || !equalHash(got, crypto.Hash(in.Nonce)) {
		middleware.Fail(w, r, 401, "invalid_challenge")
		return
	}
	uid, did := uuid.NewString(), uuid.NewString()
	_, e = tx.Exec(r.Context(), "INSERT INTO users(id,user_id,nickname,identity_public_key) VALUES($1,$2,$3,$4)", uid, in.UserID, in.Nickname, identity)
	if e != nil {
		middleware.Fail(w, r, 409, "registration_conflict")
		return
	}
	_, e = tx.Exec(r.Context(), "INSERT INTO devices(id,user_id,device_name,device_public_key,auth_public_key) VALUES($1,$2,$3,$4,$5)", did, uid, in.DeviceName, device, auth)
	if e == nil {
		_, e = tx.Exec(r.Context(), "INSERT INTO signed_prekeys(device_id,public_key,signature,key_version) VALUES($1,$2,$3,$4)", did, pre, preSig, in.SignedPreKeyVersion)
	}
	if e == nil {
		_, e = tx.Exec(r.Context(), "UPDATE auth_challenges SET used_at=now() WHERE id=$1", in.ChallengeID)
	}
	if e != nil || tx.Commit(r.Context()) != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	middleware.JSON(w, 201, map[string]string{"userID": uid, "deviceID": did})
}
func validUserID(v string) bool {
	if len(v) < 3 || len(v) > 32 {
		return false
	}
	for _, c := range v {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_') {
			return false
		}
	}
	return true
}
func equalHash(a, b []byte) bool { return len(a) == len(b) && string(a) == string(b) }
func (s Service) Token(w http.ResponseWriter, r *http.Request) {
	var in struct{ ChallengeID, Nonce, DeviceID, Signature string }
	if !middleware.Decode(w, r, &in) {
		return
	}
	sig, e := crypto.DecodeSignature(in.Signature)
	if e != nil {
		middleware.Fail(w, r, 400, "invalid_signature")
		return
	}
	tx, e := s.DB.Begin(r.Context())
	if e != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	defer tx.Rollback(r.Context())
	var key, nonceHash []byte
	var uid string
	e = tx.QueryRow(r.Context(), "SELECT d.auth_public_key,d.user_id,c.nonce_hash FROM devices d JOIN auth_challenges c ON c.device_id=d.id WHERE d.id=$1 AND d.revoked_at IS NULL AND c.id=$2 AND c.purpose='login' AND c.expires_at>now() AND c.used_at IS NULL FOR UPDATE OF c", in.DeviceID, in.ChallengeID).Scan(&key, &uid, &nonceHash)
	if e != nil || !equalHash(nonceHash, crypto.Hash(in.Nonce)) || !crypto.VerifyEd25519(key, sig, "luma.login.v1\n"+in.Nonce+"\n"+in.DeviceID) {
		middleware.Fail(w, r, 401, "invalid_credentials")
		return
	}
	_, e = tx.Exec(r.Context(), "UPDATE auth_challenges SET used_at=now() WHERE id=$1", in.ChallengeID)
	if e != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	s.issue(w, r, tx, in.DeviceID, uuid.NewString())
}
func (s Service) issue(w http.ResponseWriter, r *http.Request, tx pgx.Tx, did, family string) {
	access, e := crypto.Random()
	if e != nil {
		middleware.Fail(w, r, 500, "random_unavailable")
		return
	}
	refresh, e := crypto.Random()
	if e != nil {
		middleware.Fail(w, r, 500, "random_unavailable")
		return
	}
	_, e = tx.Exec(r.Context(), "INSERT INTO access_sessions(device_id,token_hash,family_id,expires_at) VALUES($1,$2,$3,now()+interval '15 minutes')", did, crypto.Hash(access), family)
	if e == nil {
		_, e = tx.Exec(r.Context(), "INSERT INTO refresh_sessions(device_id,token_hash,family_id,expires_at) VALUES($1,$2,$3,now()+interval '30 days')", did, crypto.Hash(refresh), family)
	}
	if e != nil || tx.Commit(r.Context()) != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	middleware.JSON(w, 200, map[string]any{"accessToken": access, "refreshToken": refresh, "tokenType": "Bearer", "expiresIn": 900})
}
func (s Service) Refresh(w http.ResponseWriter, r *http.Request) {
	var in struct{ RefreshToken string }
	if !middleware.Decode(w, r, &in) {
		return
	}
	tx, e := s.DB.Begin(r.Context())
	if e != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	defer tx.Rollback(r.Context())
	var did, family string
	var publicKey []byte
	var used bool
	e = tx.QueryRow(r.Context(), "SELECT rs.device_id,rs.family_id,rs.used_at IS NOT NULL,d.auth_public_key FROM refresh_sessions rs JOIN devices d ON d.id=rs.device_id WHERE rs.token_hash=$1 AND rs.expires_at>now() AND rs.revoked_at IS NULL AND d.revoked_at IS NULL FOR UPDATE OF rs", crypto.Hash(in.RefreshToken)).Scan(&did, &family, &used, &publicKey)
	if e != nil {
		var revoked bool
		_ = tx.QueryRow(r.Context(), "SELECT EXISTS(SELECT 1 FROM refresh_sessions rs JOIN devices d ON d.id=rs.device_id WHERE rs.token_hash=$1 AND d.revoked_at IS NOT NULL)", crypto.Hash(in.RefreshToken)).Scan(&revoked)
		if revoked {
			middleware.Fail(w, r, 401, "device_revoked")
			return
		}
		middleware.Fail(w, r, 401, "invalid_refresh_token")
		return
	}
	if !s.proof(w, r, did, publicKey, in.RefreshToken) {
		return
	}
	if used {
		_, _ = tx.Exec(r.Context(), "UPDATE refresh_sessions SET revoked_at=now() WHERE family_id=$1 AND revoked_at IS NULL", family)
		_, _ = tx.Exec(r.Context(), "UPDATE access_sessions SET revoked_at=now() WHERE family_id=$1 AND revoked_at IS NULL", family)
		_ = tx.Commit(r.Context())
		middleware.Fail(w, r, 401, "refresh_reuse_detected")
		return
	}
	_, e = tx.Exec(r.Context(), "UPDATE refresh_sessions SET used_at=now() WHERE token_hash=$1", crypto.Hash(in.RefreshToken))
	if e == nil {
		_, e = tx.Exec(r.Context(), "UPDATE access_sessions SET revoked_at=now() WHERE family_id=$1 AND revoked_at IS NULL", family)
	}
	if e != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	s.issue(w, r, tx, did, family)
}
func (s Service) Revoke(w http.ResponseWriter, r *http.Request) {
	i := middleware.Current(r)
	tx, e := s.DB.Begin(r.Context())
	if e != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	defer tx.Rollback(r.Context())
	_, e = tx.Exec(r.Context(), "UPDATE access_sessions SET revoked_at=now() WHERE device_id=$1 AND revoked_at IS NULL", i.DeviceID)
	if e == nil {
		_, e = tx.Exec(r.Context(), "UPDATE refresh_sessions SET revoked_at=now() WHERE device_id=$1 AND revoked_at IS NULL", i.DeviceID)
	}
	if e != nil || tx.Commit(r.Context()) != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	w.WriteHeader(204)
}
func (s Service) Require(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := r.Header.Get("Authorization")
		if !strings.HasPrefix(h, "Bearer ") {
			middleware.Fail(w, r, 401, "unauthenticated")
			return
		}
		token := strings.TrimPrefix(h, "Bearer ")
		if len(token) > 256 {
			middleware.Fail(w, r, 401, "unauthenticated")
			return
		}
		var uid, did string
		var publicKey []byte
		e := s.DB.QueryRow(r.Context(), "SELECT d.user_id,d.id,d.auth_public_key FROM access_sessions a JOIN devices d ON d.id=a.device_id JOIN users u ON u.id=d.user_id WHERE a.token_hash=$1 AND a.expires_at>now() AND a.revoked_at IS NULL AND d.revoked_at IS NULL AND u.disabled_at IS NULL", crypto.Hash(token)).Scan(&uid, &did, &publicKey)
		if e != nil {
			var revoked bool
			_ = s.DB.QueryRow(r.Context(), "SELECT EXISTS(SELECT 1 FROM access_sessions a JOIN devices d ON d.id=a.device_id WHERE a.token_hash=$1 AND d.revoked_at IS NOT NULL)", crypto.Hash(token)).Scan(&revoked)
			if revoked {
				middleware.Fail(w, r, 401, "device_revoked")
				return
			}
			middleware.Fail(w, r, 401, "unauthenticated")
			return
		}
		if !s.proof(w, r, did, publicKey, token) {
			return
		}
		next.ServeHTTP(w, r.WithContext(middleware.WithIdentity(r.Context(), middleware.Identity{UserID: uid, DeviceID: did})))
	})
}
func (s Service) proof(w http.ResponseWriter, r *http.Request, did string, publicKey []byte, token string) bool {
	ts := r.Header.Get("X-Device-Timestamp")
	nonce := r.Header.Get("X-Device-Nonce")
	signature, e := crypto.DecodeSignature(r.Header.Get("X-Device-Signature"))
	seconds, parseErr := strconv.ParseInt(ts, 10, 64)
	if parseErr != nil || len(nonce) < 16 || len(nonce) > 128 || e != nil || time.Since(time.Unix(seconds, 0)) > 90*time.Second || time.Until(time.Unix(seconds, 0)) > 90*time.Second {
		middleware.Fail(w, r, 401, "invalid_device_proof")
		return false
	}
	canonical := "luma.request.v1\n" + r.Method + "\n" + r.URL.RequestURI() + "\n" + ts + "\n" + nonce + "\n" + base64.RawURLEncoding.EncodeToString(crypto.Hash(token))
	if !crypto.VerifyEd25519(publicKey, signature, canonical) {
		middleware.Fail(w, r, 401, "invalid_device_proof")
		return false
	}
	used, e := s.Cache.SetNX(r.Context(), "proof:"+did+":"+nonce, "1", 3*time.Minute).Result()
	if e != nil {
		middleware.Fail(w, r, 503, "proof_store_unavailable")
		return false
	}
	if !used {
		middleware.Fail(w, r, 401, "replayed_device_proof")
		return false
	}
	return true
}
func DeviceOwner(ctx context.Context, p *pgxpool.Pool, user, device string) error {
	var ok bool
	e := p.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM devices WHERE id=$1 AND user_id=$2 AND revoked_at IS NULL)", device, user).Scan(&ok)
	if e != nil {
		return e
	}
	if !ok {
		return errors.New("device not owned")
	}
	return nil
}
