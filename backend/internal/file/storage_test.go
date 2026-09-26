package file

import (
	"context"
	"io"
	"testing"

	"github.com/google/uuid"
)

func TestLocalCiphertextStorage(t *testing.T) {
	store, err := NewLocalStorage(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	key := "ciphertext/" + uuid.NewString()
	data := []byte{0, 255, 1, 2, 3}
	if err := store.Put(context.Background(), key, data); err != nil {
		t.Fatal(err)
	}
	file, err := store.Open(context.Background(), key)
	if err != nil {
		t.Fatal(err)
	}
	got, err := io.ReadAll(file)
	_ = file.Close()
	if err != nil || string(got) != string(data) {
		t.Fatalf("roundtrip: %v", err)
	}
	if err := store.Delete(context.Background(), key); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Open(context.Background(), key); err == nil {
		t.Fatal("deleted object still available")
	}
	if err := store.Put(context.Background(), "../outside", data); err == nil {
		t.Fatal("invalid key accepted")
	}
}
