package useridindex

import (
	"bytes"
	"strings"
	"testing"
)

func TestDigestUsesSecret(t *testing.T) {
	a, err := ParseKey(strings.Repeat("a1", 32))
	if err != nil {
		t.Fatal(err)
	}
	b, err := ParseKey(strings.Repeat("b2", 32))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Equal(a.Sum("alice"), a.Sum("bob")) || bytes.Equal(a.Sum("alice"), b.Sum("alice")) {
		t.Fatal("UserID indexes must depend on both ID and secret")
	}
	if _, err := ParseKey(strings.Repeat("00", 32)); err == nil {
		t.Fatal("zero key accepted")
	}
	if _, err := ParseKey("short"); err == nil {
		t.Fatal("short key accepted")
	}
}
