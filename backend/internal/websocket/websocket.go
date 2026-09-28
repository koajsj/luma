package websocket

import (
	"context"
	"encoding/json"
	"github.com/gorilla/websocket"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
	"luma/backend/internal/crypto"
	"luma/backend/internal/middleware"
	"net/http"
	"strings"
	"sync"
	"time"
)

type Hub struct {
	mu      sync.Mutex
	clients map[string]map[chan any]struct{}
	DB      *pgxpool.Pool
	Cache   *redis.Client
}

func New(db *pgxpool.Pool, cache *redis.Client) *Hub {
	return &Hub{clients: map[string]map[chan any]struct{}{}, DB: db, Cache: cache}
}
func (h *Hub) send(device string, frame any) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for c := range h.clients[device] {
		select {
		case c <- frame:
		default:
		}
	}
}
func (h *Hub) Disconnect(device string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for c := range h.clients[device] {
		select {
		case c <- map[string]any{"type": "device.revoked"}:
		default:
			select {
			case <-c:
			default:
			}
			c <- map[string]any{"type": "device.revoked"}
		}
	}
}
func (h *Hub) Notify(device string, seq int64) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	var id, typ string
	var routing json.RawMessage
	var created time.Time
	e := h.DB.QueryRow(ctx, "SELECT event_id,type,routing,created_at FROM sync_events WHERE target_device_id=$1 AND device_seq=$2", device, seq).Scan(&id, &typ, &routing, &created)
	if e != nil {
		h.send(device, map[string]any{"protocolVersion": 1, "type": "sync.available", "deviceSeq": seq})
		return
	}
	h.send(device, map[string]any{"protocolVersion": 1, "eventID": id, "deviceSeq": seq, "type": typ, "createdAt": created, "routing": routing})
}
func (h *Hub) Presence(userID string) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	rows, e := h.DB.Query(ctx, "SELECT d.id FROM users u JOIN friendships f ON (f.user_a=u.id OR f.user_b=u.id) JOIN devices d ON d.user_id=CASE WHEN f.user_a=u.id THEN f.user_b ELSE f.user_a END AND d.revoked_at IS NULL WHERE u.id=$1 AND u.show_presence=true", userID)
	if e != nil {
		return
	}
	ids := []string{}
	for rows.Next() {
		var id string
		if rows.Scan(&id) == nil {
			ids = append(ids, id)
		}
	}
	rows.Close()
	frame := map[string]any{"protocolVersion": 1, "type": "presence.updated", "userID": userID, "online": true, "lastSeenAt": time.Now().UTC()}
	for _, id := range ids {
		h.send(id, frame)
	}
}
func (h *Hub) typing(r *http.Request, typ, cid string) {
	if typ != "typing.started" && typ != "typing.stopped" {
		return
	}
	i := middleware.Current(r)
	var other string
	e := h.DB.QueryRow(r.Context(), `SELECT m2.user_id FROM conversation_members m1
		JOIN conversation_members m2 ON m1.conversation_id=m2.conversation_id AND m2.user_id<>m1.user_id
		JOIN friendships f ON f.user_a=LEAST(m1.user_id,m2.user_id) AND f.user_b=GREATEST(m1.user_id,m2.user_id)
		WHERE m1.conversation_id=$1 AND m1.user_id=$2
		AND NOT EXISTS (SELECT 1 FROM blocks b WHERE (b.blocker=m1.user_id AND b.blocked=m2.user_id)
		OR (b.blocker=m2.user_id AND b.blocked=m1.user_id))`, cid, i.UserID).Scan(&other)
	if e != nil {
		return
	}
	key := "typing:" + cid + ":" + i.DeviceID
	if typ == "typing.started" {
		_ = h.Cache.Set(r.Context(), key, "1", 8*time.Second).Err()
	} else {
		_ = h.Cache.Del(r.Context(), key).Err()
	}
	rows, e := h.DB.Query(r.Context(), "SELECT id FROM devices WHERE user_id=$1 AND revoked_at IS NULL", other)
	if e != nil {
		return
	}
	ids := []string{}
	for rows.Next() {
		var id string
		if rows.Scan(&id) == nil {
			ids = append(ids, id)
		}
	}
	rows.Close()
	frame := map[string]any{"protocolVersion": 1, "type": typ, "conversationID": cid, "actorID": i.UserID}
	for _, did := range ids {
		h.send(did, frame)
	}
}
func (h *Hub) Serve(w http.ResponseWriter, r *http.Request) {
	device := middleware.Current(r).DeviceID
	tokenHash := crypto.Hash(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "))
	up := websocket.Upgrader{CheckOrigin: func(req *http.Request) bool { return req.Header.Get("Origin") == "" }}
	conn, e := up.Upgrade(w, r, nil)
	if e != nil {
		return
	}
	defer conn.Close()
	c := make(chan any, 16)
	h.mu.Lock()
	if h.clients[device] == nil {
		h.clients[device] = map[chan any]struct{}{}
	}
	h.clients[device][c] = struct{}{}
	h.mu.Unlock()
	defer func() { h.mu.Lock(); delete(h.clients[device], c); h.mu.Unlock() }()
	conn.SetReadLimit(1024)
	_ = conn.SetReadDeadline(time.Now().Add(60 * time.Second))
	conn.SetPongHandler(func(string) error { return conn.SetReadDeadline(time.Now().Add(60 * time.Second)) })
	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			var in struct {
				Type           string `json:"type"`
				ConversationID string `json:"conversationID"`
			}
			if e := conn.ReadJSON(&in); e != nil {
				return
			}
			h.typing(r, in.Type, in.ConversationID)
		}
	}()
	tick := time.NewTicker(25 * time.Second)
	defer tick.Stop()
	for {
		select {
		case frame := <-c:
			if value, ok := frame.(map[string]any); ok && value["type"] == "device.revoked" {
				return
			}
			if conn.SetWriteDeadline(time.Now().Add(5*time.Second)) != nil || conn.WriteJSON(frame) != nil {
				return
			}
		case <-tick.C:
			var active bool
			if h.DB.QueryRow(r.Context(), "SELECT EXISTS(SELECT 1 FROM access_sessions a JOIN devices d ON d.id=a.device_id JOIN users u ON u.id=d.user_id WHERE a.device_id=$1 AND a.token_hash=$2 AND a.expires_at>now() AND a.revoked_at IS NULL AND d.revoked_at IS NULL AND u.disabled_at IS NULL)", device, tokenHash).Scan(&active) != nil || !active {
				return
			}
			if conn.WriteControl(websocket.PingMessage, nil, time.Now().Add(5*time.Second)) != nil {
				return
			}
		case <-done:
			return
		case <-r.Context().Done():
			return
		}
	}
}
