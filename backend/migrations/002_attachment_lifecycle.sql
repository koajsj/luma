ALTER TABLE attachments DROP CONSTRAINT attachments_status_check;
ALTER TABLE attachments ADD CONSTRAINT attachments_status_check
 CHECK (status IN ('pending','stored','verified','complete','deleted'));
CREATE INDEX attachments_cleanup ON attachments(status, created_at)
 WHERE status IN ('pending','stored','deleted');
