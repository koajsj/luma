package file

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"
	"io"
	"luma/backend/internal/config"
	"luma/backend/internal/middleware"
	"net/http"
	"time"
)

type Service struct {
	DB      *pgxpool.Pool
	Storage Storage
}

func (s Service) CheckStorage(ctx context.Context) error {
	checker, ok := s.Storage.(interface{ Check(context.Context) error })
	if !ok {
		return errors.New("object storage unavailable")
	}
	return checker.Check(ctx)
}

func New(c config.Config, db *pgxpool.Pool) (Service, error) {
	s := Service{DB: db}
	if c.LocalStorageDir != "" {
		local, err := NewLocalStorage(c.LocalStorageDir)
		s.Storage = local
		return s, err
	}
	if c.S3Endpoint == "" {
		return s, nil
	}
	client, e := minio.New(c.S3Endpoint, &minio.Options{Creds: credentials.NewStaticV4(c.S3AccessKey, c.S3SecretKey, ""), Secure: c.S3Secure})
	if e == nil {
		s.Storage = S3Storage{Client: client, Bucket: c.S3Bucket}
	}
	return s, e
}
func (s Service) ready(w http.ResponseWriter, r *http.Request) bool {
	if s.Storage == nil {
		middleware.Fail(w, r, 503, "object_storage_unconfigured")
		return false
	}
	return true
}
func (s Service) Init(w http.ResponseWriter, r *http.Request) {
	if !s.ready(w, r) {
		return
	}
	var in struct {
		CiphertextSize int64  `json:"ciphertextSize"`
		CiphertextHash string `json:"ciphertextHash"`
	}
	if !middleware.Decode(w, r, &in) {
		return
	}
	hash, e := base64.RawURLEncoding.DecodeString(in.CiphertextHash)
	if e != nil || len(hash) != 32 || in.CiphertextSize < 1 || in.CiphertextSize > 100<<20 {
		middleware.Fail(w, r, 400, "invalid_ciphertext_metadata")
		return
	}
	id := uuid.NewString()
	key := "ciphertext/" + id
	_, e = s.DB.Exec(r.Context(), "INSERT INTO attachments(id,owner_user_id,object_key,ciphertext_size,ciphertext_hash) VALUES($1,$2,$3,$4,$5)", id, middleware.Current(r).UserID, key, in.CiphertextSize, hash)
	if e != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	middleware.JSON(w, 201, map[string]any{"attachmentID": id, "uploadPath": "/v1/files/" + id + "/upload", "expiresIn": 300})
}
func (s Service) Upload(w http.ResponseWriter, r *http.Request) {
	if !s.ready(w, r) {
		return
	}
	id := r.PathValue("id")
	var key string
	var size int64
	var expected []byte
	var status string
	var createdAt time.Time
	e := s.DB.QueryRow(r.Context(), "SELECT object_key,ciphertext_size,ciphertext_hash,status,created_at FROM attachments WHERE id=$1 AND owner_user_id=$2 AND status IN ('pending','stored','verified')", id, middleware.Current(r).UserID).Scan(&key, &size, &expected, &status, &createdAt)
	if e != nil {
		middleware.Fail(w, r, 404, "not_found")
		return
	}
	if status == "pending" && time.Since(createdAt) > 5*time.Minute {
		middleware.Fail(w, r, 404, "upload_expired")
		return
	}
	if r.ContentLength != size {
		middleware.Fail(w, r, 400, "size_mismatch")
		return
	}
	data, e := io.ReadAll(http.MaxBytesReader(w, r.Body, size))
	if e != nil || int64(len(data)) != size {
		middleware.Fail(w, r, 400, "size_mismatch")
		return
	}
	h := sha256.Sum256(data)
	if !bytes.Equal(h[:], expected) {
		middleware.Fail(w, r, 400, "ciphertext_mismatch")
		return
	}
	// A lost response must not force the client to create another ciphertext object.
	// Complete still rechecks the stored object before marking it verified.
	if status == "stored" || status == "verified" {
		w.WriteHeader(204)
		return
	}
	e = s.Storage.Put(r.Context(), key, data)
	if e != nil {
		middleware.Fail(w, r, 503, "object_storage_unavailable")
		return
	}
	tag, e := s.DB.Exec(r.Context(), "UPDATE attachments SET status='stored' WHERE id=$1 AND owner_user_id=$2 AND status='pending'", id, middleware.Current(r).UserID)
	if e != nil {
		// The object remains addressable only by its owner; reconciliation removes expired uploads.
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	if tag.RowsAffected() == 0 {
		var current string
		if s.DB.QueryRow(r.Context(), "SELECT status FROM attachments WHERE id=$1 AND owner_user_id=$2",
			id, middleware.Current(r).UserID).Scan(&current) == nil &&
			(current == "stored" || current == "verified") {
			w.WriteHeader(204)
			return
		}
		_ = s.Storage.Delete(r.Context(), key)
		middleware.Fail(w, r, 409, "upload_expired")
		return
	}
	w.WriteHeader(204)
}
func (s Service) Complete(w http.ResponseWriter, r *http.Request) {
	if !s.ready(w, r) {
		return
	}
	var in struct {
		AttachmentID string `json:"attachmentID"`
	}
	if !middleware.Decode(w, r, &in) {
		return
	}
	var key string
	var size int64
	var expected []byte
	e := s.DB.QueryRow(r.Context(), "SELECT object_key,ciphertext_size,ciphertext_hash FROM attachments WHERE id=$1 AND owner_user_id=$2 AND status IN ('pending','stored','verified')", in.AttachmentID, middleware.Current(r).UserID).Scan(&key, &size, &expected)
	if e != nil {
		middleware.Fail(w, r, 404, "not_found")
		return
	}
	obj, e := s.Storage.Open(r.Context(), key)
	if e != nil {
		middleware.Fail(w, r, 503, "object_storage_unavailable")
		return
	}
	defer obj.Close()
	h := sha256.New()
	n, e := io.Copy(h, io.LimitReader(obj, size+1))
	if e != nil || n != size || !bytes.Equal(h.Sum(nil), expected) {
		middleware.Fail(w, r, 400, "ciphertext_mismatch")
		return
	}
	tag, e := s.DB.Exec(r.Context(), "UPDATE attachments SET status='verified' WHERE id=$1 AND owner_user_id=$2 AND status IN ('pending','stored','verified')", in.AttachmentID, middleware.Current(r).UserID)
	if e != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	if tag.RowsAffected() == 0 {
		middleware.Fail(w, r, 409, "upload_state_changed")
		return
	}
	w.WriteHeader(204)
}
func (s Service) Download(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.authorized(w, r); !ok {
		return
	}
	middleware.JSON(w, 200, map[string]any{"downloadPath": "/v1/files/" + r.PathValue("id") + "/content"})
}
func (s Service) authorized(w http.ResponseWriter, r *http.Request) (string, bool) {
	if !s.ready(w, r) {
		return "", false
	}
	id := r.PathValue("id")
	me := middleware.Current(r).UserID
	var key string
	e := s.DB.QueryRow(r.Context(), `SELECT a.object_key FROM attachments a
		LEFT JOIN messages m ON m.id=a.message_id AND m.deleted_at IS NULL
		LEFT JOIN conversation_members cm ON cm.conversation_id=m.conversation_id AND cm.user_id=$2
		WHERE a.id=$1 AND a.status IN ('complete','verified') AND
		(a.owner_user_id=$2 OR (cm.user_id IS NOT NULL AND EXISTS (
			SELECT 1 FROM friendships f WHERE f.user_a=LEAST($2::uuid,a.owner_user_id)
			AND f.user_b=GREATEST($2::uuid,a.owner_user_id)
		) AND NOT EXISTS (
			SELECT 1 FROM blocks b WHERE (b.blocker=$2 AND b.blocked=a.owner_user_id)
			OR (b.blocker=a.owner_user_id AND b.blocked=$2)
		)))`, id, me).Scan(&key)
	if e != nil {
		middleware.Fail(w, r, 404, "not_found")
		return "", false
	}
	return key, true
}
func (s Service) Content(w http.ResponseWriter, r *http.Request) {
	key, ok := s.authorized(w, r)
	if !ok {
		return
	}
	obj, e := s.Storage.Open(r.Context(), key)
	if e != nil {
		middleware.Fail(w, r, 503, "object_storage_unavailable")
		return
	}
	defer obj.Close()
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Disposition", "attachment; filename=encrypted.bin")
	_, _ = io.Copy(w, obj)
}
func (s Service) Delete(w http.ResponseWriter, r *http.Request) {
	if !s.ready(w, r) {
		return
	}
	id := r.PathValue("id")
	me := middleware.Current(r).UserID
	var key string
	e := s.DB.QueryRow(r.Context(), "UPDATE attachments SET status='deleted' WHERE id=$1 AND owner_user_id=$2 RETURNING object_key", id, me).Scan(&key)
	if e != nil {
		middleware.Fail(w, r, 404, "not_found")
		return
	}
	if e = s.Storage.Delete(r.Context(), key); e != nil {
		middleware.Fail(w, r, 503, "object_storage_unavailable")
		return
	}
	_, e = s.DB.Exec(r.Context(), "DELETE FROM attachments WHERE id=$1 AND owner_user_id=$2 AND status='deleted'", id, me)
	if e != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	w.WriteHeader(204)
}

// Reconcile is safe to repeat after interruption: access is revoked by the DB
// tombstone first, then orphaned ciphertext objects are removed.
func (s Service) Reconcile(ctx context.Context) error {
	if s.Storage == nil {
		return nil
	}
	rows, err := s.DB.Query(ctx, `SELECT id FROM attachments
		WHERE status='deleted' OR (status IN ('pending','stored') AND created_at < $1)
		OR (status='verified' AND message_id IS NULL AND created_at < $2)`,
		time.Now().Add(-10*time.Minute), time.Now().Add(-24*time.Hour))
	if err != nil {
		return err
	}
	var items []string
	for rows.Next() {
		var id string
		if err = rows.Scan(&id); err != nil {
			break
		}
		items = append(items, id)
	}
	if err == nil {
		err = rows.Err()
	}
	rows.Close()
	if err != nil {
		return err
	}
	for _, id := range items {
		var key string
		// Claim the stale row before removing its object. A concurrent message link
		// can make a verified upload live between the listing and this update.
		err = s.DB.QueryRow(ctx, `UPDATE attachments SET status='deleted' WHERE id=$1 AND
			(status='deleted' OR (status IN ('pending','stored') AND created_at < $2)
			OR (status='verified' AND message_id IS NULL AND created_at < $3)) RETURNING object_key`,
			id, time.Now().Add(-10*time.Minute), time.Now().Add(-24*time.Hour)).Scan(&key)
		if err == pgx.ErrNoRows {
			continue
		}
		if err != nil {
			return err
		}
		if err = s.Storage.Delete(ctx, key); err != nil {
			return err
		}
		if _, err = s.DB.Exec(ctx, "DELETE FROM attachments WHERE id=$1 AND status='deleted'", id); err != nil {
			return err
		}
	}
	return nil
}
