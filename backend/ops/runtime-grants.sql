-- Explicit administrator operation, NOT an automatic migration.
-- Dedicated Luma database only; create the two LOGIN roles separately.
-- psql -X -v ON_ERROR_STOP=1 -v database=luma \
--   -v migration_role=luma_migrator -v runtime_role=luma_api -f runtime-grants.sql
\set ON_ERROR_STOP on
BEGIN;
SELECT set_config('luma.grant_database', :'database', true),
       set_config('luma.grant_migrator', :'migration_role', true),
       set_config('luma.grant_runtime', :'runtime_role', true);
DO $$
DECLARE
    runtime oid := to_regrole(current_setting('luma.grant_runtime'));
    migrator oid := to_regrole(current_setting('luma.grant_migrator'));
BEGIN
    IF current_database() <> current_setting('luma.grant_database') OR
       runtime IS NULL OR migrator IS NULL OR runtime = migrator THEN
        RAISE EXCEPTION 'Explicit Luma database and separate existing roles required';
    END IF;
    IF EXISTS (SELECT FROM pg_roles WHERE oid = runtime AND
        (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls OR NOT rolcanlogin)) OR
       EXISTS (SELECT FROM pg_auth_members WHERE member = runtime) OR
       EXISTS (SELECT FROM pg_database WHERE datdba = runtime) OR
       EXISTS (SELECT FROM pg_namespace WHERE nspowner = runtime) OR
       EXISTS (SELECT FROM pg_class WHERE relowner = runtime) THEN
        RAISE EXCEPTION 'Runtime role must have no elevated attributes, memberships or ownership';
    END IF;
    -- Existing volumes may still be owned by the old initialization role. Do not
    -- reassign ownership or alter that role implicitly: stop for reviewed migration.
    IF EXISTS (SELECT FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
        WHERE n.nspname='public' AND c.relkind IN ('r','p','S','v','m') AND
        (c.relowner <> migrator OR c.relname NOT IN (
            'schema_migrations','users','devices','signed_prekeys','one_time_prekeys',
            'auth_challenges','refresh_sessions','friend_requests','friendships','blocks',
            'conversations','conversation_members','messages','message_envelopes','message_receipts',
            'attachments','sync_events','sync_cursors','push_tokens','access_sessions',
            'v4_device_prekeys','v4_one_time_prekeys','v4_message_events','v4_session_controls'))) THEN
        RAISE EXCEPTION 'Unexpected schema objects or ownership; review before applying grants';
    END IF;
    -- Table-level REVOKE does not remove pre-existing column grants. Refuse
    -- these until an administrator reviews them instead of leaving hidden ACLs.
    IF EXISTS (SELECT FROM pg_attribute a
        JOIN pg_class c ON c.oid=a.attrelid
        JOIN pg_namespace n ON n.oid=c.relnamespace
        CROSS JOIN LATERAL aclexplode(a.attacl) acl
        WHERE n.nspname='public' AND acl.grantee IN (0, runtime)) THEN
        RAISE EXCEPTION 'Review and remove existing runtime/PUBLIC column grants first';
    END IF;
END $$;
REVOKE ALL ON DATABASE :"database" FROM PUBLIC;
REVOKE ALL ON DATABASE :"database" FROM :"runtime_role";
GRANT CONNECT ON DATABASE :"database" TO :"runtime_role";
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON SCHEMA public FROM :"runtime_role";
GRANT USAGE ON SCHEMA public TO :"runtime_role";
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM :"runtime_role", PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM :"runtime_role", PUBLIC;
-- No automatic privileges for future tables/sequences. Review grants with each
-- schema change. Current IDs are UUIDs and the API requires no sequence access.
ALTER DEFAULT PRIVILEGES FOR ROLE :"migration_role"
    REVOKE ALL ON TABLES FROM :"runtime_role", PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE :"migration_role"
    REVOKE ALL ON SEQUENCES FROM :"runtime_role", PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE :"migration_role" IN SCHEMA public
    REVOKE ALL ON TABLES FROM :"runtime_role", PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE :"migration_role" IN SCHEMA public
    REVOKE ALL ON SEQUENCES FROM :"runtime_role", PUBLIC;
GRANT SELECT ON schema_migrations TO :"runtime_role";
GRANT SELECT, INSERT, UPDATE ON users, devices, auth_challenges, refresh_sessions,
    access_sessions, friend_requests, messages, message_envelopes, message_receipts,
    sync_cursors, v4_device_prekeys TO :"runtime_role";
GRANT SELECT, INSERT, DELETE ON signed_prekeys, friendships TO :"runtime_role";
GRANT SELECT, INSERT, UPDATE, DELETE ON one_time_prekeys, v4_one_time_prekeys,
    attachments TO :"runtime_role";
GRANT SELECT, INSERT ON blocks, conversations, conversation_members, sync_events,
    v4_message_events, v4_session_controls TO :"runtime_role";
-- push_tokens is a reserved table, currently unused by the API: no grant.
COMMIT;
