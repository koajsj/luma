package useridindex

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Key is process-only configuration. It must never be persisted or logged.
type Key struct{ bytes [32]byte }

func ParseKey(encoded string) (Key, error) {
	var key Key
	if len(encoded) != 64 {
		return key, errors.New("LUMA_USERID_HMAC_SECRET must be 32 random bytes encoded as 64 hex characters")
	}
	decoded, err := hex.DecodeString(encoded)
	if err != nil {
		return key, errors.New("LUMA_USERID_HMAC_SECRET must be hexadecimal")
	}
	copy(key.bytes[:], decoded)
	if key.bytes == [32]byte{} {
		return Key{}, errors.New("LUMA_USERID_HMAC_SECRET must not be all zeros")
	}
	return key, nil
}

func (k Key) Sum(normalizedUserID string) []byte {
	mac := hmac.New(sha256.New, k.bytes[:])
	_, _ = mac.Write([]byte(normalizedUserID))
	return mac.Sum(nil)
}

// Backfill runs before HTTP starts. A changed secret fails closed instead of
// silently making existing users undiscoverable or accepting mixed indexes.
func (k Key) Backfill(ctx context.Context, db *pgxpool.Pool) error {
	tx, err := db.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	rows, err := tx.Query(ctx, "SELECT id,user_id,user_id_hash FROM users ORDER BY id FOR UPDATE")
	if err != nil {
		return err
	}
	type record struct {
		id, userID string
		stored     []byte
	}
	var records []record
	for rows.Next() {
		var row record
		if err = rows.Scan(&row.id, &row.userID, &row.stored); err != nil {
			break
		}
		records = append(records, row)
	}
	if err == nil {
		err = rows.Err()
	}
	rows.Close()
	if err != nil {
		return err
	}
	for _, row := range records {
		computed := k.Sum(row.userID)
		if row.stored != nil {
			if !hmac.Equal(row.stored, computed) {
				return errors.New("UserID index key mismatch; restore the original LUMA_USERID_HMAC_SECRET")
			}
			continue
		}
		if _, err = tx.Exec(ctx, "UPDATE users SET user_id_hash=$1 WHERE id=$2", computed, row.id); err != nil {
			return fmt.Errorf("UserID index backfill failed: %w", err)
		}
	}
	return tx.Commit(ctx)
}
