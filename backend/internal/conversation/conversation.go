package conversation

import (
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"luma/backend/internal/middleware"
	"net/http"
)

type Service struct{ DB *pgxpool.Pool }

func (s Service) Create(w http.ResponseWriter, r *http.Request) {
	var in struct {
		FriendID string `json:"friendID"`
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
	var ok bool
	e = tx.QueryRow(r.Context(), "SELECT EXISTS(SELECT 1 FROM friendships WHERE user_a=LEAST($1::uuid,$2::uuid) AND user_b=GREATEST($1::uuid,$2::uuid)) AND NOT EXISTS(SELECT 1 FROM blocks WHERE (blocker=$1 AND blocked=$2) OR (blocker=$2 AND blocked=$1))", me, in.FriendID).Scan(&ok)
	if e != nil || !ok {
		middleware.Fail(w, r, 403, "not_friends")
		return
	}
	id := uuid.NewString()
	_, e = tx.Exec(r.Context(), "INSERT INTO conversations(id) VALUES($1)", id)
	if e == nil {
		_, e = tx.Exec(r.Context(), "INSERT INTO conversation_members(conversation_id,user_id) VALUES($1,$2),($1,$3)", id, me, in.FriendID)
	}
	if e != nil || tx.Commit(r.Context()) != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	middleware.JSON(w, 201, map[string]string{"id": id})
}
func (s Service) List(w http.ResponseWriter, r *http.Request) {
	rows, e := s.DB.Query(r.Context(), "SELECT c.id,c.created_at FROM conversations c JOIN conversation_members m ON m.conversation_id=c.id WHERE m.user_id=$1 ORDER BY c.created_at DESC", middleware.Current(r).UserID)
	if e != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	defer rows.Close()
	out := []map[string]any{}
	for rows.Next() {
		var id string
		var t any
		if rows.Scan(&id, &t) != nil {
			middleware.Fail(w, r, 503, "storage_unavailable")
			return
		}
		out = append(out, map[string]any{"id": id, "createdAt": t})
	}
	middleware.JSON(w, 200, out)
}
