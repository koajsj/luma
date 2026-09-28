package user

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

func (s Service) Me(w http.ResponseWriter, r *http.Request) {
	i := middleware.Current(r)
	if r.Method == "PATCH" {
		var in struct {
			Nickname     *string `json:"nickname"`
			Searchable   *bool   `json:"searchable"`
			ShowPresence *bool   `json:"showPresence"`
			ReadReceipts *bool   `json:"readReceipts"`
		}
		if !middleware.Decode(w, r, &in) {
			return
		}
		if in.Nickname != nil && len(*in.Nickname) > 80 {
			middleware.Fail(w, r, 400, "invalid_nickname")
			return
		}
		_, e := s.DB.Exec(r.Context(), "UPDATE users SET nickname=COALESCE($1,nickname), searchable=COALESCE($2,searchable), show_presence=COALESCE($3,show_presence), read_receipts=COALESCE($4,read_receipts) WHERE id=$5", in.Nickname, in.Searchable, in.ShowPresence, in.ReadReceipts, i.UserID)
		if e != nil {
			middleware.Fail(w, r, 503, "storage_unavailable")
			return
		}
	}
	var id, name, nick string
	var searchable, presence, receipts bool
	e := s.DB.QueryRow(r.Context(), "SELECT id,user_id,nickname,searchable,show_presence,read_receipts FROM users WHERE id=$1", i.UserID).Scan(&id, &name, &nick, &searchable, &presence, &receipts)
	if e != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	middleware.JSON(w, 200, map[string]any{"id": id, "userID": name, "nickname": nick, "searchable": searchable, "showPresence": presence, "readReceipts": receipts})
}
func (s Service) Search(w http.ResponseWriter, r *http.Request) {
	q := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("userID")))
	if len(q) < 3 || len(q) > 32 {
		middleware.Fail(w, r, 400, "invalid_query")
		return
	}
	var id, name, nick string
	e := s.DB.QueryRow(r.Context(), "SELECT id,user_id,nickname FROM users WHERE user_id_hash=$1 AND searchable=true AND disabled_at IS NULL AND id<>$2", s.UserIDIndexKey.Sum(q), middleware.Current(r).UserID).Scan(&id, &name, &nick)
	if e != nil {
		middleware.Fail(w, r, 404, "not_found")
		return
	}
	middleware.JSON(w, 200, map[string]string{"id": id, "userID": name, "nickname": nick})
}
