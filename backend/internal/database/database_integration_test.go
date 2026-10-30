package database

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"luma/backend/internal/useridindex"
)

func TestConcurrentStartupMigrations(t *testing.T) {
	dsn := os.Getenv("LUMA_DEVICE_TEST_DSN")
	if dsn == "" {
		t.Skip("isolated PostgreSQL DSN not provided")
	}
	ctx := context.Background()
	admin, err := Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer admin.Close()
	name := "audit_" + uuid.NewString()[:8]
	schema := pgx.Identifier{name}.Sanitize()
	if _, err = admin.Exec(ctx, "CREATE SCHEMA "+schema); err != nil {
		t.Fatal(err)
	}
	defer admin.Exec(ctx, "DROP SCHEMA "+schema+" CASCADE")
	fallbackName := name + "_fallback"
	fallbackSchema := pgx.Identifier{fallbackName}.Sanitize()
	if _, err = admin.Exec(ctx, "CREATE SCHEMA "+fallbackSchema); err != nil {
		t.Fatal(err)
	}
	defer admin.Exec(ctx, "DROP SCHEMA "+fallbackSchema+" CASCADE")
	config, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	config.ConnConfig.RuntimeParams["search_path"] = name + "," + fallbackName + ",public"
	config.MaxConns = 4
	pool, err := pgxpool.NewWithConfig(ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	if _, err = pool.Exec(ctx, "CREATE TABLE schema_migrations(version integer PRIMARY KEY)"); err != nil {
		t.Fatal(err)
	}
	start := make(chan struct{})
	errors := make(chan error, 2)
	var workers sync.WaitGroup
	for range 2 {
		workers.Add(1)
		go func() { defer workers.Done(); <-start; errors <- Migrate(ctx, pool, "../../migrations") }()
	}
	close(start)
	workers.Wait()
	close(errors)
	for err := range errors {
		if err != nil {
			t.Errorf("concurrent startup failed: %v", err)
		}
	}
	if err := Migrate(ctx, pool, "../../migrations"); err != nil {
		t.Fatalf("repeat migration: %v", err)
	}
	if err := VerifySchema(ctx, pool, "../../migrations"); err != nil {
		t.Fatalf("current schema rejected: %v", err)
	}
	// Another schema has an equally current ledger. It must not conceal a
	// missing ledger in the API's own schema through search_path fallback.
	if _, err := pool.Exec(ctx, "CREATE TABLE "+fallbackSchema+".schema_migrations AS SELECT version FROM schema_migrations"); err != nil {
		t.Fatal(err)
	}
	// Runtime verification must not bootstrap a missing table or apply new SQL.
	if _, err := pool.Exec(ctx, "ALTER TABLE schema_migrations RENAME TO saved_migrations"); err != nil {
		t.Fatal(err)
	}
	if err := VerifySchema(ctx, pool, "../../migrations"); err == nil {
		t.Fatal("missing migration ledger accepted")
	}
	if _, err := pool.Exec(ctx, "ALTER TABLE saved_migrations RENAME TO schema_migrations"); err != nil {
		t.Fatal(err)
	}
	pending := t.TempDir()
	entries, err := os.ReadDir("../../migrations")
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if !entry.IsDir() && strings.HasSuffix(entry.Name(), ".sql") {
			if err := os.WriteFile(filepath.Join(pending, entry.Name()), nil, 0600); err != nil {
				t.Fatal(err)
			}
		}
	}
	if err := os.WriteFile(filepath.Join(pending, "008_pending.sql"), []byte("CREATE TABLE must_not_exist(id integer)"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := VerifySchema(ctx, pool, pending); err == nil {
		t.Fatal("incompatible schema accepted")
	}
	var exists bool
	if err := pool.QueryRow(ctx, "SELECT to_regclass($1) IS NOT NULL", name+".must_not_exist").Scan(&exists); err != nil || exists {
		t.Fatalf("verification applied SQL: exists=%v err=%v", exists, err)
	}
	if _, err := pool.Exec(ctx, "INSERT INTO schema_migrations(version) VALUES(999)"); err != nil {
		t.Fatal(err)
	}
	if err := VerifySchema(ctx, pool, "../../migrations"); err == nil {
		t.Fatal("newer database silently accepted by older binary")
	}
}

// This test creates only uniquely named databases and roles on an explicitly
// isolated cluster. It exercises the actual administrator SQL, not copied grants.
func TestRuntimeRoleBoundary(t *testing.T) {
	dsn := os.Getenv("LUMA_DATABASE_ROLE_TEST_DSN")
	if dsn == "" {
		t.Skip("isolated role-management PostgreSQL DSN not provided")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	admin, err := Open(ctx, dsn)
	if err != nil {
		t.Fatal("isolated database unavailable")
	}
	defer admin.Close()
	suffix := strings.ReplaceAll(uuid.NewString(), "-", "")[:12]
	name, migrator, runtime := "roles_"+suffix, "migration_"+suffix, "api_"+suffix
	ident := func(s string) string { return pgx.Identifier{s}.Sanitize() }
	for _, role := range []string{migrator, runtime} {
		if _, err := admin.Exec(ctx, "CREATE ROLE "+ident(role)+" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS"); err != nil {
			t.Fatal(err)
		}
		defer admin.Exec(context.Background(), "DROP ROLE "+ident(role))
	}
	if _, err = admin.Exec(ctx, "CREATE DATABASE "+ident(name)+" OWNER "+ident(migrator)); err != nil {
		t.Fatal(err)
	}
	defer admin.Exec(context.Background(), "DROP DATABASE "+ident(name)+" WITH (FORCE)")
	openAs := func(dbName, role string) *pgxpool.Pool {
		t.Helper()
		cfg, err := pgxpool.ParseConfig(dsn)
		if err != nil {
			t.Fatal(err)
		}
		cfg.ConnConfig.Database, cfg.ConnConfig.User = dbName, role
		pool, err := pgxpool.NewWithConfig(ctx, cfg)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(pool.Close)
		return pool
	}
	owner, api := openAs(name, migrator), openAs(name, runtime)
	if err := Migrate(ctx, owner, "../../migrations"); err != nil {
		t.Fatal(err)
	}
	key, _ := useridindex.ParseKey(strings.Repeat("a1", 32))
	if err := key.Backfill(ctx, owner); err != nil {
		t.Fatal(err)
	}
	if err := VerifyRuntimeRole(ctx, owner); err == nil {
		t.Fatal("migration owner accepted as API role")
	}
	run := func(dbName, role, binary string, args ...string) {
		t.Helper()
		cfg, err := pgxpool.ParseConfig(dsn)
		if err != nil {
			t.Fatal(err)
		}
		cmd := exec.CommandContext(ctx, binary, args...)
		cmd.Env = append(os.Environ(), "PGHOST="+cfg.ConnConfig.Host,
			"PGPORT="+strconv.Itoa(int(cfg.ConnConfig.Port)), "PGUSER="+role,
			"PGDATABASE="+dbName, "PGPASSWORD="+cfg.ConnConfig.Password,
			"LUMA_DATABASE_RUNTIME_ROLE="+runtime, "LUMA_DATABASE_MIGRATION_ROLE="+migrator,
			"LUMA_DATABASE_RUNTIME_PASSWORD="+strings.Repeat("f3", 32),
			"LUMA_DATABASE_GRANTS_FILE=../../ops/runtime-grants.sql")
		if _, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("%s isolated operation failed: %v", binary, err)
		}
	}
	applyGrants := func(dbName string) {
		t.Helper()
		run(dbName, admin.Config().ConnConfig.User, "sh", "../../../deploy/database-role.sh")
	}
	// Per-schema revocation alone cannot remove global default grants.
	if _, err := owner.Exec(ctx, "ALTER DEFAULT PRIVILEGES GRANT SELECT ON TABLES TO "+ident(runtime)+"; ALTER DEFAULT PRIVILEGES GRANT USAGE ON SEQUENCES TO "+ident(runtime)); err != nil {
		t.Fatal(err)
	}
	applyGrants(name)
	applyGrants(name) // Explicit rerun is safe; no role or ownership replacement.
	if err := VerifySchema(ctx, api, "../../migrations"); err != nil {
		t.Fatal(err)
	}
	if err := VerifyRuntimeRole(ctx, api); err != nil {
		t.Fatal(err)
	}
	if _, err := api.Exec(ctx, "INSERT INTO users(user_id,identity_public_key,user_id_hash) VALUES('privacy_test',$1,$2)", []byte{1}, key.Sum("privacy_test")); err != nil {
		t.Fatal(err)
	}
	if err := key.Verify(ctx, api); err != nil {
		t.Fatal(err)
	}
	for _, sql := range []string{
		"CREATE TABLE public.forbidden(id integer)", "CREATE TEMP TABLE forbidden(id integer)",
		"ALTER TABLE users ADD COLUMN forbidden text", "TRUNCATE users", "DELETE FROM users",
		"UPDATE schema_migrations SET version=999", "DELETE FROM schema_migrations",
		"SET ROLE " + ident(migrator), "SELECT * FROM push_tokens",
	} {
		if _, err := api.Exec(ctx, sql); err == nil {
			t.Fatalf("runtime permitted forbidden statement: %s", sql)
		}
	}
	// A future migration gets no implicit API access. Reviewed grants are required.
	if _, err := owner.Exec(ctx, "CREATE TABLE future_private(id integer); CREATE SEQUENCE future_private_seq"); err != nil {
		t.Fatal(err)
	}
	for _, sql := range []string{"SELECT * FROM future_private", "SELECT nextval('future_private_seq')"} {
		if _, err := api.Exec(ctx, sql); err == nil {
			t.Fatalf("future object unexpectedly accessible: %s", sql)
		}
	}
	if _, err := owner.Exec(ctx, "DROP TABLE future_private; DROP SEQUENCE future_private_seq"); err != nil {
		t.Fatal(err)
	}
	// Exercise the deployment's --no-owner --no-acl restore contract in a
	// second disposable database, without modifying the source database.
	archive := filepath.Join(t.TempDir(), "synthetic.dump")
	run(name, migrator, "pg_dump", "-Fc", "--no-owner", "--no-acl", "-f", archive)
	restoredName := name + "_restored"
	if _, err := admin.Exec(ctx, "CREATE DATABASE "+ident(restoredName)+" OWNER "+ident(migrator)); err != nil {
		t.Fatal(err)
	}
	defer admin.Exec(context.Background(), "DROP DATABASE "+ident(restoredName)+" WITH (FORCE)")
	run(restoredName, migrator, "pg_restore", "--dbname="+restoredName, "--no-owner", "--no-acl", archive)
	restored := openAs(restoredName, runtime)
	if err := VerifySchema(ctx, restored, "../../migrations"); err == nil {
		t.Fatal("ungranted restored schema accepted")
	}
	applyGrants(restoredName)
	if err := VerifySchema(ctx, restored, "../../migrations"); err != nil {
		t.Fatal(err)
	}
	if err := VerifyRuntimeRole(ctx, restored); err != nil {
		t.Fatal(err)
	}
	if err := key.Verify(ctx, restored); err != nil {
		t.Fatal(err)
	}
	restored.Close()
	api.Close()
	owner.Close()
}
