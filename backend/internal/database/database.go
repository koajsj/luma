package database

import (
	"context"
	"fmt"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

func Open(ctx context.Context, url string) (*pgxpool.Pool, error) {
	p, e := pgxpool.New(ctx, url)
	if e != nil {
		return nil, e
	}
	if e = p.Ping(ctx); e != nil {
		p.Close()
		return nil, e
	}
	return p, nil
}
func Migrate(ctx context.Context, p *pgxpool.Pool, dir string) error {
	// A dedicated connection holds the migration lock across per-file transactions.
	// Concurrent backend startup must not both observe an unapplied migration.
	conn, err := p.Acquire(ctx)
	if err != nil {
		return err
	}
	const migrationLock int64 = 0x4c554d410001
	if _, err = conn.Exec(ctx, "SELECT pg_advisory_lock($1)", migrationLock); err != nil {
		_ = conn.Hijack().Close(context.Background())
		return err
	}
	defer func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		var unlocked bool
		if err := conn.QueryRow(cleanup, "SELECT pg_advisory_unlock($1)", migrationLock).Scan(&unlocked); err != nil || !unlocked {
			// Never return a connection still holding a session lock to the pool.
			_ = conn.Hijack().Close(cleanup)
		} else {
			conn.Release()
		}
	}()
	if _, e := conn.Exec(ctx, "CREATE TABLE IF NOT EXISTS schema_migrations(version integer PRIMARY KEY)"); e != nil {
		return e
	}
	entries, e := os.ReadDir(dir)
	if e != nil {
		return e
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].Name() < entries[j].Name() })
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".sql") {
			continue
		}
		n, e := strconv.Atoi(strings.SplitN(entry.Name(), "_", 2)[0])
		if e != nil {
			return e
		}
		data, e := os.ReadFile(filepath.Join(dir, entry.Name()))
		if e != nil {
			return e
		}
		tx, e := conn.BeginTx(ctx, pgx.TxOptions{})
		if e != nil {
			return e
		}
		var exists bool
		e = tx.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM schema_migrations WHERE version=$1)", n).Scan(&exists)
		if e == nil && !exists {
			_, e = tx.Exec(ctx, string(data))
			if e == nil {
				_, e = tx.Exec(ctx, "INSERT INTO schema_migrations(version) VALUES($1)", n)
			}
		}
		if e != nil {
			_ = tx.Rollback(ctx)
			return fmt.Errorf("migration %d: %w", n, e)
		}
		if e = tx.Commit(ctx); e != nil {
			return e
		}
	}
	return nil
}
