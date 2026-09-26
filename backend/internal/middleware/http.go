package middleware

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/google/uuid"
	"github.com/redis/go-redis/v9"
	"io"
	"net/http"
	"strings"
	"time"
)

type Error struct {
	Code      string `json:"code"`
	Message   string `json:"message"`
	RequestID string `json:"requestID"`
}
type Identity struct{ UserID, DeviceID string }
type key int

const identityKey key = 1

func WithIdentity(ctx context.Context, i Identity) context.Context {
	return context.WithValue(ctx, identityKey, i)
}
func Current(r *http.Request) Identity { i, _ := r.Context().Value(identityKey).(Identity); return i }
func JSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
func Fail(w http.ResponseWriter, r *http.Request, status int, code string) {
	JSON(w, status, Error{Code: code, Message: http.StatusText(status), RequestID: r.Header.Get("X-Request-ID")})
}
func Decode(w http.ResponseWriter, r *http.Request, v any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, 2<<20)
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	if e := d.Decode(v); e != nil {
		Fail(w, r, 400, "invalid_request")
		return false
	}
	var extra any
	if e := d.Decode(&extra); !errors.Is(e, io.EOF) {
		Fail(w, r, 400, "invalid_request")
		return false
	}
	return true
}
func Limit(redis *redis.Client, prefix string, max int, window time.Duration, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ip := r.RemoteAddr
		if i := strings.LastIndex(ip, ":"); i > 0 {
			ip = ip[:i]
		}
		key := "rate:" + prefix + ":" + ip
		n, e := redis.Incr(r.Context(), key).Result()
		if e != nil {
			Fail(w, r, 503, "rate_limit_unavailable")
			return
		}
		if n == 1 {
			redis.Expire(r.Context(), key, window)
		}
		if n > int64(max) {
			Fail(w, r, 429, "rate_limited")
			return
		}
		next.ServeHTTP(w, r)
	})
}
func RequestID(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := uuid.NewString()
		r.Header.Set("X-Request-ID", id)
		w.Header().Set("X-Request-ID", id)
		next.ServeHTTP(w, r)
	})
}
