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
	var visible bool
	if e := s.DB.QueryRow(r.Context(), "SELECT show_presence FROM users WHERE id=$1 AND disabled_at IS NULL", i.UserID).Scan(&visible); e != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	// Device management retains last activity for the account owner even when
	// presence is hidden from friends.
	if _, e := s.DB.Exec(r.Context(), "UPDATE devices SET last_active_at=now() WHERE id=$1", i.DeviceID); e != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	if !visible {
		if e := s.Redis.Del(r.Context(), key).Err(); e != nil {
			middleware.Fail(w, r, 503, "presence_unavailable")
			return
		}
		w.WriteHeader(204)
		return
	}
	if e := s.Redis.Set(r.Context(), key, "1", 90*time.Second).Err(); e != nil {
		middleware.Fail(w, r, 503, "presence_unavailable")
		return
	}
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
	e := s.DB.QueryRow(r.Context(), "SELECT u.id,u.show_presence FROM users u WHERE u.user_id=$1 AND u.disabled_at IS NULL AND (u.id=$2 OR EXISTS(SELECT 1 FROM friendships f WHERE f.user_a=LEAST(u.id,$2::uuid) AND f.user_b=GREATEST(u.id,$2::uuid))) AND NOT EXISTS(SELECT 1 FROM blocks b WHERE (b.blocker=u.id AND b.blocked=$2) OR (b.blocker=$2 AND b.blocked=u.id))", target, me).Scan(&id, &visible)
	if e != nil || !visible {
		middleware.Fail(w, r, 404, "not_found")
		return
	}
	rows, e := s.DB.Query(r.Context(), "SELECT id,last_active_at FROM devices WHERE user_id=$1 AND revoked_at IS NULL", id)
	if e != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	keys := []string{}
	var last *time.Time
	for rows.Next() {
		var deviceID string
		var seen *time.Time
		if e = rows.Scan(&deviceID, &seen); e != nil {
			break
		}
		keys = append(keys, "presence:"+id+":"+deviceID)
		if seen != nil && (last == nil || seen.After(*last)) {
			last = seen
		}
	}
	if e == nil {
		e = rows.Err()
	}
	rows.Close()
	if e != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	online := false
	if len(keys) > 0 {
		count, err := s.Redis.Exists(r.Context(), keys...).Result()
		if err != nil {
			middleware.Fail(w, r, 503, "presence_unavailable")
			return
		}
		online = count > 0
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
