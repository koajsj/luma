# Luma Source Audit — 2026-10-22

## Scope and evidence

Repository: `koajsj/luma`  
Base revision: `af6c5293dd2c430283a1ccee106946122062fe38`  
Audit branch: `audit/luma-hardening-2026-10-22`

Reviewed the repository tree and source paths covering the v4 handshake, Double Ratchet, PreKey publication and claiming, Keychain session vault, remote message/sync flow, authentication, device revocation, middleware, file storage, SQL migrations, and deployment scripts.

This was a remote source review. The audit environment could not clone the repository because outbound DNS/network access was unavailable. No local build, XCTest, Go test, race test, shellcheck, live database test, or device-to-device test was run during this pass. This report is not an independent cryptographic audit and does not certify E2EE security.

## Fix applied on this branch

### Ratchet journal loss during peer removal

**Severity: high reliability / potential message-delivery failure**

The original `V4SessionVault.deletePeer` and `discardPendingForRemoteUser` deleted an outgoing journal whenever any recipient in a multi-recipient send matched the peer being removed. If the journal had already entered `applying` or `failed`, some recipient sessions might already have advanced. Deleting the journal could permanently leave other recipient sessions behind the message stream.

The updated code:
- Deletes an outgoing journal only while its phase is still `prepared`, before session writes begin.
- Completes an outgoing journal that has entered a write/recovery phase before removing the peer session, preserving ratchet advancement for other recipients.
- Refuses to remove a peer while an incoming journal for that peer is pending. The vault cannot independently know whether the matching SwiftData message and sync cursor were committed; sync recovery must resolve that cross-store state first.

This deliberately prefers a recoverable, temporarily blocked operation over silently discarding ratchet state. The change is on the audit branch and has not been merged into `main`.

## Findings requiring further verification

### P1 — PreKey claims can be consumed before a handshake completes
The server marks a one-time PreKey as claimed while returning a bundle. If the client crashes or abandons session setup, that key is not automatically returned to the pool. This is primarily availability and inventory-exhaustion risk, not proof of a confidentiality break. A safe improvement should use bounded claims/leases and explicit completion or expiry, with concurrency tests. Do not simply unclaim a key that may already have been used.

### P1 — Ratchet journal changes need fault-injection regression tests
The vault has explicit transaction phases, but peer removal, identity re-verification, device revocation, sync-cursor persistence, and journal recovery need systematic crash-point tests. Cover failure after each Keychain write, after local message persistence, after cursor persistence, and before server acknowledgement. Verify all recipient ratchets remain aligned and never silently reset.

### P1 — End-to-end release evidence remains incomplete
The repository README itself says real-device two-device attachment flow, two physical devices, forced-exit/offline fault injection, independent security audit, and production deployment validation remain incomplete. These must stay listed as release blockers until evidence exists.

### P2 — Deployment network collision
`deploy/docker-compose.yml` hardcodes the private subnet `172.31.251.0/24` and the backend's trusted proxy address `172.31.251.2`. On a VPS with an overlapping Docker/VPN network, deployment may fail or routing/trust assumptions may become invalid. Make the subnet configurable and validate the chosen subnet against existing host networks before creating resources. Do not change a live VPS automatically.

### P2 — Rate-limit expiry error is ignored
`backend/internal/middleware/http.go` ignores the result of Redis `Expire` after incrementing a new rate-limit key. If expiry fails after the increment, the key may persist and keep throttling that route/client indefinitely. Make increment and expiry atomic and handle failure safely; add a test with an isolated Redis or a testable limiter abstraction.

## Required validation before merge

1. Run `go test ./...`, `go vet ./...`, and `go test -race ./...` in `backend`.
2. Run all XCTest cases on an iOS Simulator; record the actual test count and result.
3. Run `bash -n` for every deployment shell script and ShellCheck where available.
4. Add targeted tests for journal recovery across all transaction phases and peer-removal paths.
5. Run PostgreSQL integration tests only against a disposable, explicitly isolated test database.
6. Perform two-physical-device tests for first handshake, simultaneous initiation, offline delivery, duplicate/reordered events, attachment send/receive, revocation, identity change, and forced termination at each persistence boundary.
7. Do not merge or claim release-ready until the above results are recorded. No production migration, deployment, or live VPS operation is authorized by this audit.
