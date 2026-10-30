package auth

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"net/http/httptest"
	"testing"

	"luma/backend/internal/crypto"
)

func TestSignedRequestUsesOnlyCurrentDomain(t *testing.T) {
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	token := "test-only-token"
	req := httptest.NewRequest("GET", "/v1/sync/events?cursor=0", nil)
	ts, nonce := "1700000000", "test-nonce-1234567890"
	digest := base64.RawURLEncoding.EncodeToString(crypto.Hash(token))
	current := ed25519.Sign(private, []byte("luma.request.v2\nGET\n/v1/sync/events?cursor=0\n"+ts+"\n"+nonce+"\n"+digest))
	if !validRequestProof(public, current, req, ts, nonce, token) {
		t.Fatal("current signed proof rejected")
	}
	legacy := ed25519.Sign(private, []byte("luma.request.v1\nGET\n/v1/sync/events?cursor=0\n"+ts+"\n"+nonce+"\n"+digest))
	if validRequestProof(public, legacy, req, ts, nonce, token) {
		t.Fatal("obsolete proof domain accepted")
	}
	bad := ed25519.Sign(private, []byte("luma.request.v2\nGET\n/v1/sync/events?cursor=1\n"+ts+"\n"+nonce+"\n"+digest))
	if validRequestProof(public, bad, req, ts, nonce, token) {
		t.Fatal("proof for another cursor accepted")
	}
}
