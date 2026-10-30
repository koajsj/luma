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

// VerifySchema is the no-DDL startup path. It refuses both pending migrations
// and a newer database; it never creates the ledger or runs a migration file.
func VerifySchema(ctx context.Context, p *pgxpool.Pool, dir string) error {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	expected := make(map[int]bool)
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".sql") {
			continue
		}
		version, err := strconv.Atoi(strings.SplitN(entry.Name(), "_", 2)[0])
		if err != nil || version < 1 || expected[version] {
			return fmt.Errorf("invalid migration filename: %s", entry.Name())
		}
		expected[version] = true
	}
	if len(expected) == 0 {
		return fmt.Errorf("no migration files found")
	}
	conn, err := p.Acquire(ctx)
	if err != nil {
		return err
	}
	defer conn.Release()
	var schema string
	if err = conn.QueryRow(ctx, "SELECT current_schema()").Scan(&schema); err != nil {
		return err
	}
	// A missing ledger must not resolve to another schema later in search_path.
	rows, err := conn.Query(ctx, "SELECT version FROM "+pgx.Identifier{schema, "schema_migrations"}.Sanitize())
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var version int
		if err = rows.Scan(&version); err != nil {
			return err
		}
		if !expected[version] {
			return fmt.Errorf("database migration version incompatible with this binary")
		}
		delete(expected, version)
	}
	if err = rows.Err(); err != nil {
		return err
	}
	if len(expected) != 0 {
		return fmt.Errorf("database migration required before API startup")
	}
	return nil
}

// VerifyRuntimeRole rejects accidentally supplying migration/admin credentials
// to the opt-in no-DDL API process. This is not a substitute for SQL grants.
func VerifyRuntimeRole(ctx context.Context, p *pgxpool.Pool) error {
	var unsafe bool
	err := p.QueryRow(ctx, `SELECT r.rolsuper OR r.rolcreatedb OR r.rolcreaterole OR r.rolreplication OR r.rolbypassrls
        OR EXISTS(SELECT FROM pg_auth_members WHERE member=r.oid)
        OR EXISTS(SELECT FROM pg_database WHERE oid=(SELECT oid FROM pg_database WHERE datname=current_database()) AND datdba=r.oid)
        OR EXISTS(SELECT FROM pg_namespace WHERE nspowner=r.oid)
        OR EXISTS(SELECT FROM pg_class WHERE relowner=r.oid)
        OR has_database_privilege(current_database(),'CREATE,TEMP')
        OR has_schema_privilege('public','CREATE')
        OR has_table_privilege('schema_migrations','INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
        OR has_any_column_privilege('schema_migrations','INSERT,UPDATE,REFERENCES')
        FROM pg_roles r WHERE r.rolname=current_user`).Scan(&unsafe)
	if err != nil {
		return err
	}
	if unsafe {
		return fmt.Errorf("API runtime requires a separate non-owner, non-DDL database role")
	}
	return nil
}
