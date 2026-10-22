package user

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/google/uuid"
	"luma/backend/internal/database"
	"luma/backend/internal/middleware"
	"luma/backend/internal/useridindex"
)

func TestSearchDoesNotDiscloseBlockedUser(t *testing.T) {
	dsn := os.Getenv("LUMA_DEVICE_TEST_DSN")
	if dsn == "" {
		t.Skip("isolated PostgreSQL DSN not provided")
	}
	db, err := database.Open(context.Background(), dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	key, err := useridindex.ParseKey(strings.Repeat("a1", 32))
	if err != nil {
		t.Fatal(err)
	}
	a, b := uuid.NewString(), uuid.NewString()
	name := "search_" + b[:8]
	for _, id := range []string{a, b} {
		userID := "search_" + id[:8]
		if _, err = db.Exec(context.Background(), "INSERT INTO users(id,user_id,user_id_hash,identity_public_key,searchable) VALUES($1,$2,$3,$4,true)", id, userID, key.Sum(userID), []byte{1}); err != nil {
			t.Fatal(err)
		}
	}
	search := func() int {
		r := httptest.NewRequest(http.MethodGet, "/v1/users/search?userID="+name, nil)
		r = r.WithContext(middleware.WithIdentity(r.Context(), middleware.Identity{UserID: a}))
		w := httptest.NewRecorder()
		(Service{DB: db, UserIDIndexKey: key}).Search(w, r)
		return w.Code
	}
	if code := search(); code != 200 {
		t.Fatalf("visible user: %d", code)
	}
	for _, pair := range [][2]string{{a, b}, {b, a}} {
		if _, err = db.Exec(context.Background(), "INSERT INTO blocks(blocker,blocked) VALUES($1,$2)", pair[0], pair[1]); err != nil {
			t.Fatal(err)
		}
		if code := search(); code != 404 {
			t.Errorf("blocked user disclosed: %d", code)
		}
		if _, err = db.Exec(context.Background(), "DELETE FROM blocks WHERE blocker=$1 AND blocked=$2", pair[0], pair[1]); err != nil {
			t.Fatal(err)
		}
	}
	if _, err = db.Exec(context.Background(), "UPDATE users SET searchable=false WHERE id=$1", b); err != nil {
		t.Fatal(err)
	}
	if code := search(); code != 404 {
		t.Errorf("hidden user disclosed: %d", code)
	}
}
