package middleware

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/redis/go-redis/v9"
)

func TestLimitRepairsInterruptedExpiryAndStillEnforcesQuota(t *testing.T) {
	raw := os.Getenv("LUMA_REDIS_TEST_URL")
	if raw == "" {
		t.Skip("isolated Redis URL not provided")
	}
	options, err := redis.ParseURL(raw)
	if err != nil {
		t.Fatal(err)
	}
	cache := redis.NewClient(options)
	defer cache.Close()
	ctx := context.Background()
	prefix := "audit-" + uuid.NewString()
	key := "rate:" + prefix + ":192.0.2.1"
	defer cache.Del(ctx, key)
	if err = cache.Set(ctx, key, "1", 0).Err(); err != nil {
		t.Fatal(err)
	}
	handler := Limit(cache, prefix, 2, time.Second, netip.Addr{}, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) }))
	request := func() int {
		r := httptest.NewRequest("GET", "/", nil)
		r.RemoteAddr = "192.0.2.1:1234"
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		return w.Code
	}
	if code := request(); code != 204 {
		t.Fatalf("first request: %d", code)
	}
	if ttl := cache.PTTL(ctx, key).Val(); ttl <= 0 || ttl > time.Second {
		t.Errorf("counter has no bounded expiry: %v", ttl)
	}
	if code := request(); code != 429 {
		t.Fatalf("quota not enforced: %d", code)
	}
}
