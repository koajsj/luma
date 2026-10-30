#!/bin/sh
# Short-lived administrator job. No credentials are passed in command arguments.
set -eu
runtime=${LUMA_DATABASE_RUNTIME_ROLE:-luma_api}
migrator=${LUMA_DATABASE_MIGRATION_ROLE:-luma}
grants=${LUMA_DATABASE_GRANTS_FILE:-/app/runtime-grants.sql}
case ${LUMA_DATABASE_RUNTIME_PASSWORD:-} in
    ''|*[!0-9a-fA-F]*) echo 'Invalid runtime database password configuration.' >&2; exit 1 ;;
esac
[ "${#LUMA_DATABASE_RUNTIME_PASSWORD}" -eq 64 ] || exit 1
if ! psql -X -q -v ON_ERROR_STOP=1 -v runtime_role="$runtime" \
    -v migration_role="$migrator" -v database="${PGDATABASE:?}" <<'SQL' >/dev/null 2>&1
-- Disable statement/error-body logging before the password enters SQL.
SET log_statement = 'none';
SET log_min_error_statement = 'panic';
SET log_min_duration_statement = -1;
SET log_min_duration_sample = -1;
SET log_transaction_sample_rate = 0;
SET log_parameter_max_length_on_error = 0;
SET password_encryption = 'scram-sha-256';
\getenv runtime_password LUMA_DATABASE_RUNTIME_PASSWORD
SELECT set_config('luma.runtime_password', :'runtime_password', false),
       set_config('luma.runtime_role', :'runtime_role', false)
\gset
DO $$
DECLARE r text := current_setting('luma.runtime_role');
BEGIN
    IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname=r) THEN
        EXECUTE format('CREATE ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS', r);
    END IF;
    IF EXISTS(SELECT FROM pg_roles WHERE rolname=r AND
        (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls OR NOT rolcanlogin)) OR
       EXISTS(SELECT FROM pg_auth_members WHERE member=to_regrole(r)) OR
       EXISTS(SELECT FROM pg_database WHERE datdba=to_regrole(r)) OR
       EXISTS(SELECT FROM pg_namespace WHERE nspowner=to_regrole(r)) OR
       EXISTS(SELECT FROM pg_class WHERE relowner=to_regrole(r)) THEN
        RAISE EXCEPTION 'Unsafe existing runtime role';
    END IF;
    EXECUTE format('ALTER ROLE %I PASSWORD %L', r, current_setting('luma.runtime_password'));
END $$;
SQL
then
    echo 'Database runtime role preparation failed; inspect roles privately.' >&2
    exit 1
fi
# The reviewed template rejects unexpected object ownership and hidden column ACLs.
if ! psql -X -q -v ON_ERROR_STOP=1 -v runtime_role="$runtime" \
    -v migration_role="$migrator" -v database="$PGDATABASE" -f "$grants" >/dev/null 2>&1; then
    echo 'Database runtime grants failed; API startup remains blocked.' >&2
    exit 1
fi
