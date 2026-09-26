package crypto

import (
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"strings"
)

func Random() (string, error) {
	b := make([]byte, 32)
	_, e := rand.Read(b)
	return base64.RawURLEncoding.EncodeToString(b), e
}
func Hash(s string) []byte { h := sha256.Sum256([]byte(s)); return h[:] }
func DecodeKey(s string) ([]byte, error) {
	b, e := base64.RawURLEncoding.DecodeString(s)
	if e != nil || len(b) == 0 || len(b) > 4096 {
		return nil, errors.New("invalid public key")
	}
	return b, nil
}
func VerifyEd25519(public, signature []byte, message string) bool {
	return len(public) == ed25519.PublicKeySize && len(signature) == ed25519.SignatureSize && ed25519.Verify(public, []byte(message), signature)
}
func DecodeSignature(s string) ([]byte, error) {
	return base64.RawURLEncoding.DecodeString(strings.TrimSpace(s))
}

func VerifySignedPrekey(identity, pre, sig []byte) bool {
	x, y := elliptic.Unmarshal(elliptic.P256(), identity)
	if x == nil {
		return false
	}
	h := sha256.Sum256(pre)
	return ecdsa.VerifyASN1(&ecdsa.PublicKey{Curve: elliptic.P256(), X: x, Y: y}, h[:], sig)
}
