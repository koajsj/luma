package presence

import (
	"context"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
	"luma/backend/internal/middleware"
	"net/http"
	"time"
)

type Service struct {
	DB     *pgxpool.Pool
	Redis  *redis.Client
	Notify interface{ Presence(userID string) }
}

func (s Service) Heartbeat(w http.ResponseWriter, r *http.Request) {
	i := middleware.Current(r)
	key := "presence:" + i.UserID + ":" + i.DeviceID
	if e := s.Redis.Set(r.Context(), key, "1", 90*time.Second).Err(); e != nil {
		middleware.Fail(w, r, 503, "presence_unavailable")
		return
	}
	_, _ = s.DB.Exec(r.Context(), "UPDATE devices SET last_active_at=now() WHERE id=$1", i.DeviceID)
	if s.Notify != nil {
		s.Notify.Presence(i.UserID)
	}
	w.WriteHeader(204)
}
func (s Service) Get(w http.ResponseWriter, r *http.Request) {
	target := r.PathValue("userID")
	me := middleware.Current(r).UserID
	var id string
	var visible bool
	e := s.DB.QueryRow(r.Context(), "SELECT u.id,u.show_presence FROM users u WHERE u.user_id=$1 AND u.disabled_at IS NULL AND (u.id=$2 OR EXISTS(SELECT 1 FROM friendships f WHERE f.user_a=LEAST(u.id,$2::uuid) AND f.user_b=GREATEST(u.id,$2::uuid)))", target, me).Scan(&id, &visible)
	if e != nil || !visible {
		middleware.Fail(w, r, 404, "not_found")
		return
	}
	iter := s.Redis.Scan(r.Context(), 0, "presence:"+id+":*", 10).Iterator()
	online := iter.Next(r.Context())
	if e := iter.Err(); e != nil {
		middleware.Fail(w, r, 503, "presence_unavailable")
		return
	}
	var last *time.Time
	e = s.DB.QueryRow(r.Context(), "SELECT MAX(last_active_at) FROM devices WHERE user_id=$1", id).Scan(&last)
	if e != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	middleware.JSON(w, 200, map[string]any{"online": online, "lastSeenAt": last})
}
func (s Service) Typing(ctx context.Context, device, conversation string, active bool) error {
	key := "typing:" + conversation + ":" + device
	if active {
		return s.Redis.Set(ctx, key, "1", 8*time.Second).Err()
	}
	return s.Redis.Del(ctx, key).Err()
}
