package websocket

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"luma/backend/internal/middleware"
)

func TestDisconnectClosesRevokedDeviceSocket(t *testing.T) {
	for _, flood := range []bool{false, true} {
		name := "revocation"
		if flood {
			name = "frame_flood"
		}
		t.Run(name, func(t *testing.T) {
			hub := New(nil, nil)
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				hub.Serve(w, r.WithContext(middleware.WithIdentity(r.Context(), middleware.Identity{DeviceID: "revoked"})))
			}))
			defer server.Close()
			socket, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(server.URL, "http"), nil)
			if err != nil {
				t.Fatal(err)
			}
			defer socket.Close()
			deadline := time.Now().Add(time.Second)
			for {
				hub.mu.Lock()
				ready := len(hub.clients["revoked"]) > 0
				hub.mu.Unlock()
				if ready {
					break
				}
				if time.Now().After(deadline) {
					t.Fatal("socket registration timed out")
				}
				time.Sleep(10 * time.Millisecond)
			}
			if flood {
				for range 5 {
					if err := socket.WriteJSON(map[string]string{"type": "unsupported"}); err != nil {
						t.Fatal(err)
					}
				}
			} else {
				hub.Disconnect("revoked")
			}
			_ = socket.SetReadDeadline(time.Now().Add(2 * time.Second))
			if _, _, err := socket.ReadMessage(); err == nil {
				t.Fatal("revoked socket stayed open")
			} else if flood && !websocket.IsCloseError(err, websocket.ClosePolicyViolation) {
				t.Fatalf("flood was not explicitly rejected: %v", err)
			}
		})
	}
}
