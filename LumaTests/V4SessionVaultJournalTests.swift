import CryptoKit
import XCTest
@testable import Luma

final class V4SessionVaultJournalTests: XCTestCase {
    func testDeletePeerCompletesApplyingMultiRecipientOutgoingJournal() throws {
        let fixture = try Fixture()
        defer { try? fixture.vault.purgeAccount(userID: fixture.userID) }

        let removed = try fixture.session(remoteDeviceID: UUID(), remoteUserID: UUID())
        let retained = try fixture.session(remoteDeviceID: UUID(), remoteUserID: UUID())
        var pending = V4SessionVault.OutgoingPending(
            messageID: UUID(),
            request: Data("sealed request".utf8),
            sessions: [removed, retained]
        )
        pending.phase = .applying
        try fixture.vault.stageOutgoing(pending, userID: fixture.userID, deviceID: fixture.localDeviceID)

        try fixture.vault.deletePeer(
            userID: fixture.userID,
            localDeviceID: fixture.localDeviceID,
            remoteDeviceID: removed.remoteDeviceID
        )

        XCTAssertNil(try fixture.vault.outgoingPending(
            userID: fixture.userID,
            deviceID: fixture.localDeviceID
        ))
        XCTAssertNil(try fixture.vault.loadSession(
            userID: fixture.userID,
            local: fixture.localDeviceID,
            remote: removed.remoteDeviceID
        ))
        XCTAssertNotNil(try fixture.vault.loadSession(
            userID: fixture.userID,
            local: fixture.localDeviceID,
            remote: retained.remoteDeviceID
        ))
    }

    func testDeletePeerKeepsIncomingJournalUntilSyncRecovery() throws {
        let fixture = try Fixture()
        defer { try? fixture.vault.purgeAccount(userID: fixture.userID) }

        let session = try fixture.session(remoteDeviceID: UUID(), remoteUserID: UUID())
        let pending = V4SessionVault.IncomingPending(
            eventID: UUID(),
            deviceSeq: 42,
            plaintext: Data("decrypted only in keychain".utf8),
            envelopeDigest: Data(repeating: 7, count: 32),
            session: session,
            consumedOneTimePublicKey: nil
        )
        try fixture.vault.stageIncoming(pending, userID: fixture.userID, deviceID: fixture.localDeviceID)

        XCTAssertThrowsError(try fixture.vault.deletePeer(
            userID: fixture.userID,
            localDeviceID: fixture.localDeviceID,
            remoteDeviceID: session.remoteDeviceID
        )) { error in
            XCTAssertEqual(error as? V4VaultError, .pendingOperation)
        }
        XCTAssertEqual(
            try fixture.vault.incomingPending(userID: fixture.userID, deviceID: fixture.localDeviceID)?.eventID,
            pending.eventID
        )
    }

    func testDiscardRemoteUserDoesNotDropApplyingOrIncomingJournals() throws {
        let fixture = try Fixture()
        defer { try? fixture.vault.purgeAccount(userID: fixture.userID) }

        let remoteUserID = UUID()
        let outgoing = try fixture.session(remoteDeviceID: UUID(), remoteUserID: remoteUserID)
        var outgoingPending = V4SessionVault.OutgoingPending(
            messageID: UUID(), request: Data("sealed request".utf8), sessions: [outgoing]
        )
        outgoingPending.phase = .applying
        try fixture.vault.stageOutgoing(
            outgoingPending, userID: fixture.userID, deviceID: fixture.localDeviceID
        )
        let incoming = try fixture.session(remoteDeviceID: UUID(), remoteUserID: remoteUserID)
        let incomingPending = V4SessionVault.IncomingPending(
            eventID: UUID(), deviceSeq: 8, plaintext: Data("plaintext".utf8),
            envelopeDigest: Data(repeating: 9, count: 32), session: incoming,
            consumedOneTimePublicKey: nil
        )
        try fixture.vault.stageIncoming(
            incomingPending, userID: fixture.userID, deviceID: fixture.localDeviceID
        )

        XCTAssertThrowsError(try fixture.vault.discardPendingForRemoteUser(
            userID: fixture.userID,
            localDeviceID: fixture.localDeviceID,
            remoteUserID: remoteUserID
        )) { error in
            XCTAssertEqual(error as? V4VaultError, .pendingOperation)
        }
        XCTAssertNil(try fixture.vault.outgoingPending(
            userID: fixture.userID, deviceID: fixture.localDeviceID
        ))
        XCTAssertNotNil(try fixture.vault.loadSession(
            userID: fixture.userID, local: fixture.localDeviceID, remote: outgoing.remoteDeviceID
        ))
        XCTAssertEqual(
            try fixture.vault.incomingPending(userID: fixture.userID, deviceID: fixture.localDeviceID)?.eventID,
            incomingPending.eventID
        )
    }
}

private extension V4SessionVaultJournalTests {
    struct Fixture {
        let userID = "journal-test"
        let localDeviceID = UUID()
        let vault: V4SessionVault

        init() throws {
            vault = V4SessionVault(keychain: KeychainManager(
                service: "app.luma.v4-journal-test.\(UUID().uuidString)"
            ))
        }

        func session(remoteDeviceID: UUID, remoteUserID: UUID) throws -> V4SessionVault.Session {
            let signedPreKey = Curve25519.KeyAgreement.PrivateKey()
            return V4SessionVault.Session(
                formatVersion: 1,
                localDeviceID: localDeviceID,
                remoteDeviceID: remoteDeviceID,
                remoteUserID: remoteUserID,
                remoteIdentityFingerprint: String(repeating: "a", count: 64),
                sessionVersion: 1,
                recipientKeyVersion: 1,
                ratchet: try V4RatchetState.responder(
                    sharedSecret: SymmetricKey(size: .bits256),
                    ownSignedPreKey: signedPreKey
                ),
                initialHeader: nil,
                stateVersion: 1
            )
        }
    }
}
