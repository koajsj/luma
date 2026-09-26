package sync

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"luma/backend/internal/middleware"
	"net/http"
	"strconv"
)

type Service struct{ DB *pgxpool.Pool }
type Notifier interface {
	Notify(deviceID string, seq int64)
}

// Append serializes sequence allocation on the device row inside the caller's transaction.
func Append(ctx context.Context, tx pgx.Tx, device, eventType string, payload []byte, routing any) (int64, error) {
	if payload == nil {
		payload = []byte{}
	}
	var seq int64
	e := tx.QueryRow(ctx, "UPDATE devices SET next_seq=next_seq+1 WHERE id=$1 AND revoked_at IS NULL RETURNING next_seq", device).Scan(&seq)
	if e != nil {
		return 0, e
	}
	body, e := json.Marshal(routing)
	if e != nil {
		return 0, e
	}
	_, e = tx.Exec(ctx, "INSERT INTO sync_events(event_id,target_device_id,device_seq,type,payload_ciphertext,routing) VALUES($1,$2,$3,$4,$5,$6)", uuid.NewString(), device, seq, eventType, payload, body)
	return seq, e
}
func (s Service) Events(w http.ResponseWriter, r *http.Request) {
	cursor, e := strconv.ParseInt(r.URL.Query().Get("cursor"), 10, 64)
	if r.URL.Query().Get("cursor") == "" {
		cursor = 0
		e = nil
	}
	if e != nil || cursor < 0 {
		middleware.Fail(w, r, 400, "invalid_cursor")
		return
	}
	limit := 100
	if v := r.URL.Query().Get("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 || n > 200 {
			middleware.Fail(w, r, 400, "invalid_limit")
			return
		}
		limit = n
	}
	did := middleware.Current(r).DeviceID
	rows, e := s.DB.Query(r.Context(), "SELECT event_id,device_seq,type,payload_ciphertext,routing,created_at FROM sync_events WHERE target_device_id=$1 AND device_seq>$2 ORDER BY device_seq LIMIT $3", did, cursor, limit)
	if e != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	defer rows.Close()
	out := []map[string]any{}
	last := cursor
	for rows.Next() {
		var id, typ string
		var seq int64
		var payload []byte
		var routing json.RawMessage
		var created any
		if rows.Scan(&id, &seq, &typ, &payload, &routing, &created) != nil {
			middleware.Fail(w, r, 503, "storage_unavailable")
			return
		}
		out = append(out, map[string]any{"eventID": id, "deviceSeq": seq, "type": typ, "payloadCiphertext": base64.RawURLEncoding.EncodeToString(payload), "routing": routing, "createdAt": created})
		last = seq
	}
	middleware.JSON(w, 200, map[string]any{"events": out, "nextCursor": last})
}
func (s Service) Ack(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Cursor int64 `json:"cursor"`
	}
	if !middleware.Decode(w, r, &in) {
		return
	}
	if in.Cursor < 0 {
		middleware.Fail(w, r, 400, "invalid_cursor")
		return
	}
	did := middleware.Current(r).DeviceID
	tag, e := s.DB.Exec(r.Context(), "INSERT INTO sync_cursors(device_id,acked_seq) SELECT id,$2 FROM devices WHERE id=$1 AND next_seq >= $2 ON CONFLICT(device_id) DO UPDATE SET acked_seq=GREATEST(sync_cursors.acked_seq,EXCLUDED.acked_seq),updated_at=now()", did, in.Cursor)
	if e != nil {
		middleware.Fail(w, r, 503, "storage_unavailable")
		return
	}
	if tag.RowsAffected() == 0 {
		middleware.Fail(w, r, 400, "invalid_cursor")
		return
	}
	w.WriteHeader(204)
}
