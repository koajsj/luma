package websocket

import (
	"context"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/google/uuid"
	"luma/backend/internal/database"
	"luma/backend/internal/middleware"
)

func TestPresenceBroadcastRespectsBlockAndVisibility(t *testing.T) {
	dsn := os.Getenv("LUMA_DEVICE_TEST_DSN")
	if dsn == "" {
		t.Skip("isolated PostgreSQL DSN not provided")
	}
	ctx := context.Background()
	db, err := database.Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Close)
	sender, recipient, device := uuid.NewString(), uuid.NewString(), uuid.NewString()
	t.Cleanup(func() {
		_, _ = db.Exec(ctx, "DELETE FROM blocks WHERE blocker=$1 AND blocked=$2", recipient, sender)
		_, _ = db.Exec(ctx, "DELETE FROM friendships WHERE user_a=LEAST($1::uuid,$2::uuid) AND user_b=GREATEST($1::uuid,$2::uuid)", sender, recipient)
		_, _ = db.Exec(ctx, "DELETE FROM devices WHERE id=$1", device)
		_, _ = db.Exec(ctx, "DELETE FROM users WHERE id IN ($1,$2)", sender, recipient)
	})
	for _, id := range []string{sender, recipient} {
		if _, err := db.Exec(ctx, "INSERT INTO users(id,user_id,identity_public_key,show_presence) VALUES($1,$2,$3,true)",
			id, "presence_"+id[:8], []byte{1}); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := db.Exec(ctx, "INSERT INTO devices(id,user_id,device_name,device_public_key,auth_public_key) VALUES($1,$2,'test',$3,$3)",
		device, recipient, []byte{1}); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(ctx, "INSERT INTO friendships(user_a,user_b) VALUES(LEAST($1::uuid,$2::uuid),GREATEST($1::uuid,$2::uuid))", sender, recipient); err != nil {
		t.Fatal(err)
	}
	hub := New(db, nil)
	request := httptest.NewRequest("GET", "/v1/ws", nil)
	request = request.WithContext(middleware.WithIdentity(ctx, middleware.Identity{UserID: recipient, DeviceID: device}))
	tokenHash := []byte(uuid.NewString())
	if _, err := db.Exec(ctx, "INSERT INTO access_sessions(device_id,token_hash,family_id,expires_at) VALUES($1,$2,$3,now()+interval '1 minute')", device, tokenHash, uuid.NewString()); err != nil {
		t.Fatal(err)
	}
	if !hub.active(request, tokenHash) {
		t.Fatal("valid socket credentials rejected")
	}
	if _, err := db.Exec(ctx, "UPDATE devices SET revoked_at=now() WHERE id=$1", device); err != nil {
		t.Fatal(err)
	}
	if hub.active(request, tokenHash) {
		t.Fatal("revoked socket credentials accepted")
	}
	if _, err := db.Exec(ctx, "UPDATE devices SET revoked_at=NULL WHERE id=$1", device); err != nil {
		t.Fatal(err)
	}
	frames := make(chan any, 1)
	hub.clients[device] = map[chan any]struct{}{frames: {}}
	hub.Presence(sender)
	select {
	case <-frames:
	default:
		t.Fatal("friend did not receive opted-in presence")
	}
	if _, err := db.Exec(ctx, "INSERT INTO blocks(blocker,blocked) VALUES($1,$2)", recipient, sender); err != nil {
		t.Fatal(err)
	}
	hub.Presence(sender)
	select {
	case <-frames:
		t.Fatal("blocked friend received presence")
	default:
	}
	if _, err := db.Exec(ctx, "DELETE FROM blocks WHERE blocker=$1 AND blocked=$2", recipient, sender); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(ctx, "UPDATE users SET show_presence=false WHERE id=$1", sender); err != nil {
		t.Fatal(err)
	}
	hub.Presence(sender)
	select {
	case <-frames:
		t.Fatal("opted-out user broadcast presence")
	default:
	}
}
