package friend

import (
	"github.com/jackc/pgx/v5/pgxpool"
	"luma/backend/internal/middleware"
	"luma/backend/internal/useridindex"
	"net/http"
	"strings"
)

type Service struct {
	DB             *pgxpool.Pool
	UserIDIndexKey useridindex.Key
}

func (s Service) List(w http.ResponseWriter, r *http.Request) {
	me := middleware.Current(r).UserID
	rows, e := s.DB.Query(r.Context(), `SELECT u.id,u.user_id,u.nickname FROM friendships f
		JOIN users u ON u.id=CASE WHEN f.user_a=$1 THEN f.user_b ELSE f.user_a END
		WHERE (f.user_a=$1 OR f.user_b=$1) AND u.disabled_at IS NULL
		AND NOT EXISTS(SELECT 1 FROM blocks b WHERE (b.blocker=$1 AND b.blocked=u.id) OR (b.blocker=u.id AND b.blocked=$1))
		ORDER BY u.user_id LIMIT 500`, me)
	if e != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	defer rows.Close()
	out := []map[string]string{}
	for rows.Next() {
		var id, userID, nickname string
		if rows.Scan(&id, &userID, &nickname) != nil {
			middleware.Fail(w, r, 503, "storage_unavailable")
			return
		}
		out = append(out, map[string]string{"id": id, "userID": userID, "nickname": nickname})
	}
	if rows.Err() != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	middleware.JSON(w, 200, out)
}

func (s Service) Request(w http.ResponseWriter, r *http.Request) {
	var in struct {
		UserID string `json:"userID"`
	}
	if !middleware.Decode(w, r, &in) {
		return
	}
	me := middleware.Current(r).UserID
	query := strings.ToLower(strings.TrimSpace(in.UserID))
	if len(query) < 3 || len(query) > 32 {
		middleware.Fail(w, r, 404, "not_found")
		return
	}
	var target string
	e := s.DB.QueryRow(r.Context(), "SELECT id FROM users WHERE user_id_hash=$1 AND searchable=true AND disabled_at IS NULL AND id<>$2", s.UserIDIndexKey.Sum(query), me).Scan(&target)
	if e != nil {
		middleware.Fail(w, r, 404, "not_found")
		return
	}
	var blocked bool
	_ = s.DB.QueryRow(r.Context(), "SELECT EXISTS(SELECT 1 FROM blocks WHERE (blocker=$1 AND blocked=$2) OR (blocker=$2 AND blocked=$1))", me, target).Scan(&blocked)
	if blocked {
		middleware.Fail(w, r, 404, "not_found")
		return
	}
	_, e = s.DB.Exec(r.Context(), "INSERT INTO friend_requests(from_user,to_user) VALUES($1,$2) ON CONFLICT(from_user,to_user) DO UPDATE SET status='pending',updated_at=now() WHERE friend_requests.status='rejected'", me, target)
	if e != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	w.WriteHeader(202)
}
func (s Service) Decide(w http.ResponseWriter, r *http.Request) {
	var in struct {
		RequestID string `json:"requestID"`
	}
	if !middleware.Decode(w, r, &in) {
		return
	}
	accept := r.URL.Path == "/v1/friend/accept"
	tx, e := s.DB.Begin(r.Context())
	if e != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	defer tx.Rollback(r.Context())
	var a, b string
	e = tx.QueryRow(r.Context(), "SELECT from_user,to_user FROM friend_requests WHERE id=$1 AND to_user=$2 AND status='pending' FOR UPDATE", in.RequestID, middleware.Current(r).UserID).Scan(&a, &b)
	if e != nil {
		middleware.Fail(w, r, 404, "not_found")
		return
	}
	status := "rejected"
	if accept {
		status = "accepted"
	}
	_, e = tx.Exec(r.Context(), "UPDATE friend_requests SET status=$1,updated_at=now() WHERE id=$2", status, in.RequestID)
	if e == nil && accept {
		_, e = tx.Exec(r.Context(), "INSERT INTO friendships(user_a,user_b) VALUES(LEAST($1::uuid,$2::uuid),GREATEST($1::uuid,$2::uuid)) ON CONFLICT DO NOTHING", a, b)
	}
	if e != nil || tx.Commit(r.Context()) != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	w.WriteHeader(204)
}
func (s Service) Remove(w http.ResponseWriter, r *http.Request) {
	me := middleware.Current(r).UserID
	other := r.PathValue("id")
	tag, e := s.DB.Exec(r.Context(), "DELETE FROM friendships WHERE user_a=LEAST($1::uuid,$2::uuid) AND user_b=GREATEST($1::uuid,$2::uuid)", me, other)
	if e != nil || tag.RowsAffected() == 0 {
		middleware.Fail(w, r, 404, "not_found")
		return
	}
	w.WriteHeader(204)
}
func (s Service) Block(w http.ResponseWriter, r *http.Request) {
	var in struct {
		UserID string `json:"userID"`
	}
	if !middleware.Decode(w, r, &in) {
		return
	}
	me := middleware.Current(r).UserID
	tx, e := s.DB.Begin(r.Context())
	if e != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	defer tx.Rollback(r.Context())
	_, e = tx.Exec(r.Context(), "INSERT INTO blocks(blocker,blocked) VALUES($1,$2) ON CONFLICT DO NOTHING", me, in.UserID)
	if e == nil {
		_, e = tx.Exec(r.Context(), "DELETE FROM friendships WHERE user_a=LEAST($1::uuid,$2::uuid) AND user_b=GREATEST($1::uuid,$2::uuid)", me, in.UserID)
	}
	if e != nil || tx.Commit(r.Context()) != nil {
		middleware.Fail(w, r, 400, "invalid_target")
		return
	}
	w.WriteHeader(204)
}
func (s Service) Requests(w http.ResponseWriter, r *http.Request) {
	rows, e := s.DB.Query(r.Context(), "SELECT fr.id,u.user_id,fr.created_at FROM friend_requests fr JOIN users u ON u.id=fr.from_user WHERE fr.to_user=$1 AND fr.status='pending' ORDER BY fr.created_at DESC LIMIT 100", middleware.Current(r).UserID)
	if e != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	defer rows.Close()
	out := []map[string]any{}
	for rows.Next() {
		var id, user string
		var created any
		if rows.Scan(&id, &user, &created) != nil {
			middleware.Fail(w, r, 503, "storage_unavailable")
			return
		}
		out = append(out, map[string]any{"requestID": id, "fromUserID": user, "createdAt": created})
	}
	middleware.JSON(w, 200, out)
}
