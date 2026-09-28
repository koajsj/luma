package middleware

import (
	"net/http/httptest"
	"net/netip"
	"testing"
)

func TestClientIPTrustBoundary(t *testing.T) {
	proxy := netip.MustParseAddr("172.31.251.2")
	tests := []struct {
		name, remote, forwarded, want string
	}{
		{"trusted first client", "172.31.251.2:1234", "198.51.100.1", "198.51.100.1"},
		{"trusted second client", "172.31.251.2:1234", "198.51.100.2", "198.51.100.2"},
		{"untrusted spoof", "198.51.100.3:1234", "198.51.100.1", "198.51.100.3"},
		{"reject header chain", "172.31.251.2:1234", "198.51.100.1, 198.51.100.2", "172.31.251.2"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := httptest.NewRequest("GET", "/", nil)
			r.RemoteAddr = tt.remote
			r.Header.Set("X-Forwarded-For", tt.forwarded)
			if got := ClientIP(r, proxy); got != tt.want {
				t.Fatalf("ClientIP() = %q, want %q", got, tt.want)
			}
		})
	}
}
