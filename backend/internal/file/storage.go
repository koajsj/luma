package file

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/google/uuid"
	"github.com/minio/minio-go/v7"
)

// Storage contains opaque ciphertext bytes only. Authorization stays in Service.
type Storage interface {
	Put(context.Context, string, []byte) error
	Open(context.Context, string) (io.ReadCloser, error)
	Delete(context.Context, string) error
}

type S3Storage struct {
	Client *minio.Client
	Bucket string
}

func (s S3Storage) Put(ctx context.Context, key string, data []byte) error {
	_, err := s.Client.PutObject(ctx, s.Bucket, key, bytes.NewReader(data), int64(len(data)),
		minio.PutObjectOptions{ContentType: "application/octet-stream"})
	return err
}
func (s S3Storage) Open(ctx context.Context, key string) (io.ReadCloser, error) {
	return s.Client.GetObject(ctx, s.Bucket, key, minio.GetObjectOptions{})
}
func (s S3Storage) Delete(ctx context.Context, key string) error {
	return s.Client.RemoveObject(ctx, s.Bucket, key, minio.RemoveObjectOptions{})
}

type LocalStorage struct{ Root string }

func NewLocalStorage(root string) (LocalStorage, error) {
	if !filepath.IsAbs(root) {
		return LocalStorage{}, errors.New("LOCAL_STORAGE_DIR must be absolute")
	}
	root = filepath.Clean(root)
	if err := os.MkdirAll(filepath.Join(root, "ciphertext"), 0700); err != nil {
		return LocalStorage{}, err
	}
	if err := os.Chmod(filepath.Join(root, "ciphertext"), 0700); err != nil {
		return LocalStorage{}, err
	}
	return LocalStorage{Root: root}, nil
}

func (s LocalStorage) path(key string) (string, error) {
	parts := strings.Split(key, "/")
	if len(parts) != 2 || parts[0] != "ciphertext" {
		return "", errors.New("invalid object key")
	}
	id, err := uuid.Parse(parts[1])
	if err != nil || id.String() != parts[1] {
		return "", errors.New("invalid object key")
	}
	return filepath.Join(s.Root, "ciphertext", id.String()), nil
}

func (s LocalStorage) Put(_ context.Context, key string, data []byte) error {
	path, err := s.path(key)
	if err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".upload-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if err = f.Chmod(0600); err == nil {
		_, err = f.Write(data)
	}
	if err == nil {
		err = f.Sync()
	}
	if closeErr := f.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	return os.Rename(f.Name(), path)
}
func (s LocalStorage) Open(_ context.Context, key string) (io.ReadCloser, error) {
	path, err := s.path(key)
	if err != nil {
		return nil, err
	}
	return os.Open(path)
}
func (s LocalStorage) Delete(_ context.Context, key string) error {
	path, err := s.path(key)
	if err != nil {
		return err
	}
	err = os.Remove(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}
