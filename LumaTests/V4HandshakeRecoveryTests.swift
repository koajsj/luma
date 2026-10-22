import CryptoKit
import XCTest
@testable import Luma

final class V4HandshakeRecoveryTests: XCTestCase {
    private let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    func testLegacyAuthenticatedEncodingVectorIsUnchanged() throws {
        let header = V4InitialHeader(senderDeviceID: a, receiverDeviceID: b, recipientKeyVersion: 1,
            senderIdentityAgreementPublicKey: Data(repeating: 1, count: 32), senderIdentitySigningPublicKey: Data(repeating: 2, count: 32),
            senderEphemeralPublicKey: Data(repeating: 3, count: 32), recipientIdentityAgreementPublicKey: Data(repeating: 4, count: 32),
            recipientIdentitySigningPublicKey: Data(repeating: 5, count: 32), recipientSignedPreKeyPublicKey: Data(repeating: 6, count: 32),
            recipientOneTimePreKeyPublicKey: Data(repeating: 7, count: 32), signature: Data(repeating: 10, count: 64))
        let message = V4RatchetMessage(messageID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            conversationID: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!, senderDeviceID: a, receiverDeviceID: b,
            encryptionVersion: 4, ratchetPublicKey: Data(repeating: 9, count: 32), previousChainLength: 0,
            messageIndex: 7, sessionVersion: 1, initialHeader: header, nonce: Data(), ciphertext: Data(), authenticationTag: Data())
        let hex: (Data) -> String = { Data(SHA256.hash(data: $0)).map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(hex(header.transcript()), "5867373fca96d92b0b2f99f8742d60b09f6f5a3a7da48a369edc297ab08a33f7")
        XCTAssertEqual(hex(message.authenticatedHeader()), "3d8175a31791647b703797e7595cc30ac24c0a2ae6e06e7828d304e3a5a5e5b8")
    }

    func testRecoveryIsDisabledByDefault() {
        XCTAssertFalse(V4RecoveryConfiguration().enabled)
    }

    func testPairAndWinnerDoNotDependOnInputOrderOrConversation() throws {
        let first = try participant(a), second = try participant(b)
        let pair = try V4RecoveryPair(first, second)
        XCTAssertEqual(pair, try V4RecoveryPair(second, first))
        let p = try proposal(pair, sender: a, salt: 1)
        let q = try proposal(pair, sender: b, salt: 2)
        XCTAssertEqual(try V4HandshakeRecovery.winner(p, q), p.id)
        XCTAssertEqual(try V4HandshakeRecovery.winner(q, p), p.id)
        XCTAssertEqual(try V4ConflictID(pair: pair.id, proposals: [p.id, q.id]),
                       try V4ConflictID(pair: pair.id, proposals: [q.id, p.id]))
        XCTAssertThrowsError(try V4HandshakeRecovery.winner(p, proposal(pair, sender: a, salt: 3)))
    }

    func testCoordinatorRejectsRollbackIllegalJumpAndThirdProposal() throws {
        let pair = try V4RecoveryPair(participant(a), participant(b))
        let p = try proposal(pair, sender: a, salt: 1), q = try proposal(pair, sender: b, salt: 2)
        var state = V4RecoveryCoordinator(pair: pair)
        try state.add(p, localDevice: a)
        XCTAssertEqual(state.phase, .initialCreated)
        try state.transition(to: .initialSent, expectedRevision: state.revision)
        let old = state.revision
        try state.add(q, localDevice: a)
        XCTAssertEqual(state.phase, .conflictDetected)
        XCTAssertEqual(state.activeProposal, p.id)
        XCTAssertThrowsError(try state.transition(to: .established, expectedRevision: old))
        XCTAssertThrowsError(try state.transition(to: .none, expectedRevision: state.revision))
        XCTAssertThrowsError(try state.add(p, localDevice: a))
        XCTAssertThrowsError(try state.add(proposal(pair, sender: b, salt: 4), localDevice: a))
    }

    func testProposalRejectsForgedSignatureAndWrongPair() throws {
        let pair = try V4RecoveryPair(participant(a), participant(b))
        var p = try proposal(pair, sender: a, salt: 1)
        p.signature[0] ^= 1
        XCTAssertThrowsError(try p.verify(in: pair))
        let other = try V4RecoveryPair(participant(a), participant(UUID()))
        XCTAssertThrowsError(try proposal(pair, sender: a, salt: 1).verify(in: other))
    }

    func testVaultCASJournalRecoveryAndOTPReservation() throws {
        let service = "app.luma.recovery-test.\(UUID().uuidString)"
        let keychain = KeychainManager(service: service)
        let vault = V4HandshakeRecoveryVault(keychain: keychain, userID: "test", localDevice: a)
        defer { try? vault.purge() }
        let pair = try V4RecoveryPair(participant(a), participant(b))
        let proposal = try proposal(pair, sender: a, salt: 1)
        var state = V4RecoverySnapshot(coordinator: V4RecoveryCoordinator(pair: pair))
        try state.coordinator.add(proposal, localDevice: a)
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        state.candidates = [.init(proposal: proposal, ratchet: .responder(
            sharedSecret: SymmetricKey(size: .bits256), ownSignedPreKey: privateKey), version: 1)]
        let operation = V4RecoveryOperation(id: UUID(), expectedVersion: 0, next: state,
            output: Data("sealed-only".utf8), incomingSequence: nil)
        try vault.stage(operation)
        let reopened = V4HandshakeRecoveryVault(keychain: KeychainManager(service: service), userID: "test", localDevice: a)
        XCTAssertEqual(try reopened.pending(pair.id)?.id, operation.id)
        try reopened.finish(pair.id, operationID: operation.id)
        XCTAssertEqual(try reopened.load(pair.id)?.version, 1)
        try reopened.finish(pair.id, operationID: operation.id)
        XCTAssertThrowsError(try reopened.stage(V4RecoveryOperation(id: UUID(), expectedVersion: 0,
            next: state, output: Data(), incomingSequence: nil)))
        let otp = Data(repeating: 7, count: 32)
        try reopened.reserve(otp, proposal: proposal.id)
        try reopened.reserve(otp, proposal: proposal.id)
        XCTAssertThrowsError(try reopened.reserve(otp, proposal: self.proposal(pair, sender: b, salt: 2).id))
    }

    func testInitialStageInterruptionBeforePairIndexCanResume() throws {
        for checkpoint in 1...2 {
            let service = "app.luma.recovery-stage-test.\(UUID().uuidString)"
            let keychain = KeychainManager(service: service)
            var interrupted = V4HandshakeRecoveryVault(
                keychain: keychain,
                userID: "test",
                localDevice: a
            )
            defer { try? interrupted.purge() }

            let pair = try V4RecoveryPair(participant(a), participant(b))
            let proposal = try proposal(pair, sender: a, salt: 1)
            let privateKey = Curve25519.KeyAgreement.PrivateKey()
            var state = V4RecoverySnapshot(coordinator: V4RecoveryCoordinator(pair: pair))
            try state.coordinator.add(proposal, localDevice: a)
            state.candidates = [.init(
                proposal: proposal,
                ratchet: .responder(
                    sharedSecret: SymmetricKey(size: .bits256),
                    ownSignedPreKey: privateKey
                ),
                version: 1
            )]
            let operation = V4RecoveryOperation(
                id: UUID(),
                expectedVersion: 0,
                next: state,
                output: Data("sealed-only".utf8),
                incomingSequence: nil
            )
            var writes = 0
            interrupted.onPersistence = {
                writes += 1
                if writes == checkpoint {
                    throw NSError(domain: "InjectedInitialStageInterruption", code: checkpoint)
                }
            }

            XCTAssertThrowsError(try interrupted.stage(operation))
            let reopened = V4HandshakeRecoveryVault(
                keychain: keychain,
                userID: "test",
                localDevice: a
            )
            XCTAssertEqual(try reopened.pending(pair.id)?.id, operation.id)
            try reopened.finish(pair.id, operationID: operation.id)
            XCTAssertEqual(try reopened.load(pair.id)?.version, 1)
            XCTAssertTrue(try reopened.pairs().contains(pair.id))
            XCTAssertNil(try reopened.pending(pair.id))
        }
    }

    func testInitialStageInterruptionCannotReuseReservedOneTimePreKey() throws {
        let service = "app.luma.recovery-otp-stage-test.\(UUID().uuidString)"
        let keychain = KeychainManager(service: service)
        var interrupted = V4HandshakeRecoveryVault(
            keychain: keychain,
            userID: "test",
            localDevice: a
        )
        defer { try? interrupted.purge() }

        let pair = try V4RecoveryPair(participant(a), participant(b))
        let original = try proposal(pair, sender: b, salt: 1)
        let competing = try proposal(pair, sender: b, salt: 2)
        let oneTimePrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let oneTimePreKey = oneTimePrivateKey.publicKey.rawRepresentation
        try V4SessionVault(keychain: keychain).saveDevice(.init(
            formatVersion: 1,
            deviceID: a,
            keyVersion: 1,
            identityAgreement: Curve25519.KeyAgreement.PrivateKey().rawRepresentation,
            identitySigning: Curve25519.Signing.PrivateKey().rawRepresentation,
            signedPreKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation,
            oneTimePreKeys: [oneTimePreKey.base64EncodedString(): oneTimePrivateKey.rawRepresentation]
        ), userID: "test")
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        var state = V4RecoverySnapshot(coordinator: V4RecoveryCoordinator(pair: pair))
        try state.coordinator.add(original, localDevice: a)
        state.candidates = [.init(
            proposal: original,
            ratchet: .responder(
                sharedSecret: SymmetricKey(size: .bits256),
                ownSignedPreKey: privateKey
            ),
            version: 1
        )]
        let operation = V4RecoveryOperation(
            id: UUID(),
            expectedVersion: 0,
            next: state,
            output: Data("sealed-only".utf8),
            incomingSequence: 1,
            consumedPreKeys: [.init(publicKey: oneTimePreKey, proposal: original.id)]
        )
        interrupted.onPersistence = {
            throw NSError(domain: "InjectedOTPReservationInterruption", code: 1)
        }

        XCTAssertThrowsError(try interrupted.stage(operation))
        let reopened = V4HandshakeRecoveryVault(
            keychain: keychain,
            userID: "test",
            localDevice: a
        )
        XCTAssertNil(try reopened.pending(pair.id))
        XCTAssertThrowsError(try reopened.reserve(oneTimePreKey, proposal: competing.id))

        try reopened.stage(operation)
        XCTAssertEqual(try reopened.pending(pair.id)?.id, operation.id)
        try reopened.finish(pair.id, operationID: operation.id)
        XCTAssertEqual(try reopened.load(pair.id)?.version, 1)
    }

    func testPeerRemovalPreservesInboundJournalAndCompletesApplyingOutboundJournal() throws {
        let service = "app.luma.recovery-peer-removal-test.\(UUID().uuidString)"
        let keychain = KeychainManager(service: service)
        let vault = V4HandshakeRecoveryVault(
            keychain: keychain,
            userID: "test",
            localDevice: a
        )
        defer { try? vault.purge() }

        func operation(incomingSequence: Int64?) throws -> (V4RecoveryPair, V4RecoveryOperation) {
            let pair = try V4RecoveryPair(participant(a), participant(b))
            let proposal = try self.proposal(pair, sender: a, salt: UInt8(incomingSequence ?? 1))
            let privateKey = Curve25519.KeyAgreement.PrivateKey()
            var state = V4RecoverySnapshot(coordinator: V4RecoveryCoordinator(pair: pair))
            try state.coordinator.add(proposal, localDevice: a)
            state.candidates = [.init(
                proposal: proposal,
                ratchet: .responder(
                    sharedSecret: SymmetricKey(size: .bits256),
                    ownSignedPreKey: privateKey
                ),
                version: 1
            )]
            return (pair, V4RecoveryOperation(
                id: UUID(),
                expectedVersion: 0,
                next: state,
                output: Data("sealed-only".utf8),
                incomingSequence: incomingSequence
            ))
        }

        let (inboundPair, inbound) = try operation(incomingSequence: 9)
        try vault.stage(inbound)
        XCTAssertThrowsError(try vault.removePeer(b)) { error in
            XCTAssertEqual(error as? V4VaultError, .pendingOperation)
        }
        XCTAssertEqual(try vault.pending(inboundPair.id)?.id, inbound.id)

        try vault.purge()
        let (outboundPair, outbound) = try operation(incomingSequence: nil)
        try vault.stage(outbound)
        var interrupted = vault
        interrupted.onPersistence = {
            throw NSError(domain: "InjectedPeerRemovalInterruption", code: 1)
        }
        XCTAssertThrowsError(try interrupted.finish(outboundPair.id, operationID: outbound.id))
        XCTAssertEqual(try vault.pending(outboundPair.id)?.phase, .applying)

        try vault.removePeer(b)
        XCTAssertNil(try vault.pending(outboundPair.id))
        XCTAssertNil(try vault.load(outboundPair.id))
        XCTAssertFalse(try vault.pairs().contains(outboundPair.id))
    }

    func testSignedControlAndFreezeProofRejectTampering() throws {
        let pair = try V4RecoveryPair(participant(a), participant(b))
        let p = try proposal(pair, sender: a, salt: 1), q = try proposal(pair, sender: b, salt: 2)
        let entry = V4RecoverySealedEntry(messageID: UUID(), conversationID: UUID(),
            ratchetPublicKey: q.header.senderEphemeralPublicKey, index: 0, digest: Data(repeating: 4, count: 32))
        let manifest = try V4FrozenManifest(pair: pair, proposals: [p, q], loser: q.id,
            entries: [entry], cutoff: 1, identity: keys(b))
        try manifest.verify(pair: pair, proposals: [p, q])
        let control = try V4SessionControl(kind: .resolveOffer, conversationID: entry.conversationID,
            actor: b, pair: pair, proposals: [p, q], manifest: manifest, identity: keys(b))
        try control.verify(pair: pair, expectedActor: b, conversation: entry.conversationID)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(control)) as? [String: Any])
        json["kind"] = "resolve_commit"
        let forged = try JSONDecoder().decode(V4SessionControl.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertThrowsError(try forged.verify(pair: pair, expectedActor: b, conversation: entry.conversationID))
        XCTAssertThrowsError(try control.verify(pair: pair, expectedActor: a, conversation: entry.conversationID))
        XCTAssertThrowsError(try V4FrozenManifest(pair: pair, proposals: [p, q], loser: q.id,
            entries: [entry, entry], cutoff: 2, identity: keys(b)))
    }

    func testSimultaneousRecoveryPreservesBothMessagesAndConvergesAfterReopen() throws {
        let (alice, bob, pair, aBundle, bBundle) = try recoveryDevices()
        defer { try? alice.deviceVault.purgeAccount(userID: alice.userID); try? bob.deviceVault.purgeAccount(userID: bob.userID) }
        let conversation = UUID(), aMessage = UUID(), bMessage = UUID()
        let aWire = try alice.prepare(Data("A first".utf8), messageID: aMessage,
            conversationID: conversation, pair: pair, recipient: bBundle)
        let bWire = try bob.prepare(Data("B first".utf8), messageID: bMessage,
            conversationID: conversation, pair: pair, recipient: aBundle)
        try alice.commit(aMessage); try bob.commit(bMessage)
        let aRoot = try XCTUnwrap(alice.vault.load(pair.id)?.candidates.first).ratchet?.rootKey
        let receivedA = UUID(), receivedB = UUID()
        XCTAssertEqual(try bob.receive(aWire, eventID: receivedA, deviceSeq: 1, pair: pair, control: false), Data("A first".utf8))
        try bob.finish(receivedA)
        XCTAssertEqual(try alice.receive(bWire, eventID: receivedB, deviceSeq: 1, pair: pair, control: false), Data("B first".utf8))
        try alice.finish(receivedB)
        XCTAssertTrue(try alice.vault.load(pair.id)?.candidates.first?.ratchet?.rootKey == aRoot)
        try exchangeControls(alice, bob, pair)
        XCTAssertEqual(try alice.vault.load(pair.id)?.coordinator.phase, .established)
        XCTAssertEqual(try bob.vault.load(pair.id)?.coordinator.phase, .established)
        XCTAssertEqual(try alice.vault.load(pair.id)?.coordinator.activeProposal,
                       try bob.vault.load(pair.id)?.coordinator.activeProposal)
        let nextID = UUID()
        let next = try bob.prepare(Data("B reply".utf8), messageID: nextID,
            conversationID: conversation, pair: pair, recipient: aBundle)
        try bob.commit(nextID)
        XCTAssertEqual(try alice.receive(next, eventID: nextID, deviceSeq: 99, pair: pair, control: false), Data("B reply".utf8))
        try alice.finish(nextID)
        XCTAssertThrowsError(try alice.receive(next, eventID: UUID(), deviceSeq: 100, pair: pair, control: false))
    }

    func testSingleInitiatorBothDirectionsAndExactPreparedRetry() throws {
        for initiatorIsAlice in [true, false] {
            let (a, b, pair, ab, bb) = try recoveryDevices()
            defer { try? a.deviceVault.purgeAccount(userID: a.userID); try? b.deviceVault.purgeAccount(userID: b.userID) }
            let sender = initiatorIsAlice ? a : b, receiver = initiatorIsAlice ? b : a
            let bundle = initiatorIsAlice ? bb : ab, conversation = UUID(), id = UUID()
            let bytes = try sender.prepare(Data("original".utf8), messageID: id, conversationID: conversation,
                pair: pair, recipient: bundle)
            XCTAssertEqual(bytes, try sender.prepare(Data("ignored retry input".utf8), messageID: id,
                conversationID: conversation, pair: pair, recipient: bundle))
            try sender.commit(id)
            let event = UUID()
            XCTAssertEqual(try receiver.receive(bytes, eventID: event, deviceSeq: 1, pair: pair, control: false), Data("original".utf8))
            XCTAssertEqual(try receiver.receive(bytes, eventID: event, deviceSeq: 1, pair: pair, control: false), Data("original".utf8))
            try receiver.finish(event)
            try exchangeControls(a, b, pair)
            XCTAssertEqual(try a.vault.load(pair.id)?.coordinator.phase, .established)
            XCTAssertEqual(try b.vault.load(pair.id)?.coordinator.phase, .established)
        }
    }

    func testOfferBeforeLoserInitialAndOutOfOrderDrain() throws {
        let (a, b, pair, ab, bb) = try recoveryDevices()
        defer { try? a.deviceVault.purgeAccount(userID: a.userID); try? b.deviceVault.purgeAccount(userID: b.userID) }
        let conversation = UUID()
        var loserWires: [Data] = []
        for _ in 0..<3 {
            let id = UUID()
            loserWires.append(try b.prepare(Data("in flight".utf8), messageID: id,
                conversationID: conversation, pair: pair, recipient: ab))
            try b.commit(id)
        }
        let id = UUID(), event = UUID()
        let winnerWire = try a.prepare(Data("winner".utf8), messageID: id,
            conversationID: conversation, pair: pair, recipient: bb)
        try a.commit(id)
        _ = try b.receive(winnerWire, eventID: event, deviceSeq: 1, pair: pair, control: false)
        try b.finish(event)
        // The offer carries the authenticated losing proposal before any of its messages.
        try exchangeControls(a, b, pair)
        XCTAssertFalse(try XCTUnwrap(a.vault.load(pair.id)).drainAcknowledged)
        for (offset, bytes) in loserWires.reversed().enumerated() {
            let event = UUID()
            XCTAssertEqual(try a.receive(bytes, eventID: event, deviceSeq: Int64(100 + offset), pair: pair, control: false), Data("in flight".utf8))
            try a.finish(event)
        }
        try exchangeControls(a, b, pair)
        XCTAssertTrue(try XCTUnwrap(a.vault.load(pair.id)).drainAcknowledged)
        XCTAssertTrue(try XCTUnwrap(b.vault.load(pair.id)).drainAcknowledged)
        let winner = try XCTUnwrap(a.vault.load(pair.id)?.coordinator.activeProposal)
        XCTAssertTrue(try a.vault.load(pair.id)?.candidates.first(where: { $0.proposal.id != winner })?.ratchet == nil)
        XCTAssertTrue(try b.vault.load(pair.id)?.candidates.first(where: { $0.proposal.id != winner })?.ratchet == nil)
        XCTAssertThrowsError(try a.receive(loserWires[0], eventID: UUID(), deviceSeq: 200, pair: pair, control: false))
    }

    func testTamperedProposalCiphertextAndDowngradeDoNotCreateState() throws {
        let (a, b, pair, _, bb) = try recoveryDevices()
        defer { try? a.deviceVault.purgeAccount(userID: a.userID); try? b.deviceVault.purgeAccount(userID: b.userID) }
        let id = UUID()
        let bytes = try a.prepare(Data("synthetic".utf8), messageID: id, conversationID: UUID(), pair: pair, recipient: bb)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        json["authenticationTag"] = Data(repeating: 0, count: 16).base64EncodedString()
        XCTAssertThrowsError(try b.receive(JSONSerialization.data(withJSONObject: json), eventID: UUID(), deviceSeq: 1, pair: pair, control: false))
        XCTAssertNil(try b.vault.load(pair.id))
        XCTAssertTrue(try b.vault.pending(pair.id) == nil)
        json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var proposal = try XCTUnwrap(json["recoveryProposal"] as? [String: Any])
        proposal["protocolVersion"] = 1
        json["recoveryProposal"] = proposal
        XCTAssertThrowsError(try b.receive(JSONSerialization.data(withJSONObject: json), eventID: UUID(), deviceSeq: 1, pair: pair, control: false))
        XCTAssertNil(try b.vault.load(pair.id))
        try a.commit(id)
    }

    func testInterruptedPreparedSendCanReceiveAndKeepsExactEnvelope() throws {
        let (a, b, pair, ab, bb) = try recoveryDevices()
        defer { try? a.deviceVault.purgeAccount(userID: a.userID); try? b.deviceVault.purgeAccount(userID: b.userID) }
        let cid = UUID(), aid = UUID(), bid = UUID()
        let original = try a.prepare(Data("retained".utf8), messageID: aid, conversationID: cid, pair: pair, recipient: bb)
        let peer = try b.prepare(Data("peer".utf8), messageID: bid, conversationID: cid, pair: pair, recipient: ab)
        try b.commit(bid)
        let event = UUID()
        XCTAssertEqual(try a.receive(peer, eventID: event, deviceSeq: 1, pair: pair, control: false), Data("peer".utf8))
        try a.finish(event)
        let reopened = V4HandshakeRecoveryService(deviceVault: a.deviceVault, userID: a.userID, localDevice: a.localDevice)
        XCTAssertEqual(try reopened.prepare(Data("same encrypted intent".utf8), messageID: aid,
            conversationID: cid, pair: pair, recipient: bb), original)
    }

    func testMissingCommittedFloorIsNotAnEmptySession() throws {
        let (a, b, pair, _, bb) = try recoveryDevices()
        defer { try? a.deviceVault.purgeAccount(userID: a.userID); try? b.deviceVault.purgeAccount(userID: b.userID) }
        let id = UUID()
        _ = try a.prepare(Data("synthetic".utf8), messageID: id, conversationID: UUID(), pair: pair, recipient: bb)
        try a.commit(id)
        let hex = pair.id.map { String(format: "%02x", $0) }.joined()
        try a.deviceVault.keychain.delete("v4.recovery.\(a.userID).\(a.localDevice.uuidString).\(hex).floor")
        XCTAssertThrowsError(try a.vault.load(pair.id))
    }

    func testUnsupportedSecondTargetDoesNotStageFirstPair() throws {
        let (a, b, pair, _, bb) = try recoveryDevices()
        defer { try? a.deviceVault.purgeAccount(userID: a.userID); try? b.deviceVault.purgeAccount(userID: b.userID) }
        let third = UUID(), identity = V4IdentityKeys(), signed = Curve25519.KeyAgreement.PrivateKey(), otp = Curve25519.KeyAgreement.PrivateKey()
        var valid = bb; valid.recoveryParticipant = pair.participants.first(where: { $0.deviceID == b.localDevice })
        let unsupported = try V4Handshake.bundle(deviceID: third, version: 1, identity: identity,
            signedPreKey: signed, oneTimePreKey: otp)
        let service = V4MessageSessionService(vault: a.deviceVault, userID: a.userID, localDeviceID: a.localDevice,
            recoveryConfiguration: .init(enabled: true), recoveryParticipant: pair.participants.first(where: { $0.deviceID == a.localDevice }))
        XCTAssertThrowsError(try service.prepare(Data("synthetic".utf8), messageID: UUID(), conversationID: UUID(),
            targets: [.init(remoteUserID: b.localDevice, bundle: valid), .init(remoteUserID: third, bundle: unsupported)]))
        XCTAssertTrue(try a.vault.pending(pair.id) == nil)
        XCTAssertNil(try a.vault.load(pair.id))
    }

    func testControlStillWorksAtUnconfirmedApplicationLimit() throws {
        for conflict in [false, true] {
            let (a, b, pair, ab, bb) = try recoveryDevices()
            defer { try? a.deviceVault.purgeAccount(userID: a.userID); try? b.deviceVault.purgeAccount(userID: b.userID) }
            let cid = UUID(), id = UUID()
            let first = try a.prepare(Data("first".utf8), messageID: id, conversationID: cid, pair: pair, recipient: bb)
            try a.commit(id)
            var state = try XCTUnwrap(a.vault.load(pair.id)), ratchet = try XCTUnwrap(state.candidates[0].ratchet)
            for _ in 1..<2_000 {
                let message = try ratchet.encrypt(Data("bounded".utf8), messageID: UUID(), conversationID: cid,
                    senderDeviceID: a.localDevice, receiverDeviceID: b.localDevice,
                    initialHeader: state.candidates[0].proposal.header, recoveryProposal: state.candidates[0].proposal)
                let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                let wire = try encoder.encode(message)
                state.candidates[0].sent.append(.init(messageID: message.messageID, conversationID: cid,
                    ratchetPublicKey: message.ratchetPublicKey, index: message.messageIndex, digest: Data(SHA256.hash(data: wire))))
            }
            state.candidates[0].ratchet = ratchet; state.candidates[0].version += 1
            let operation = UUID()
            try a.vault.stage(.init(id: operation, expectedVersion: state.version, next: state, output: Data(), incomingSequence: nil))
            try a.vault.finish(pair.id, operationID: operation)
            if conflict {
                let bid = UUID(), event = UUID()
                let wire = try b.prepare(Data("simultaneous".utf8), messageID: bid, conversationID: cid, pair: pair, recipient: ab)
                try b.commit(bid)
                _ = try a.receive(wire, eventID: event, deviceSeq: 1, pair: pair, control: false)
                try a.finish(event)
            }
            let event = UUID()
            _ = try b.receive(first, eventID: event, deviceSeq: 1, pair: pair, control: false)
            try b.finish(event)
            try exchangeControls(a, b, pair)
            XCTAssertEqual(try a.vault.load(pair.id)?.coordinator.phase, .established)
            XCTAssertEqual(try b.vault.load(pair.id)?.coordinator.phase, .established)
        }
    }

    func testNeverSubmittedCancellationIsAuthenticatedAndAmbiguousSendIsRetained() throws {
        let (a, b, pair, ab, bb) = try recoveryDevices()
        defer { try? a.deviceVault.purgeAccount(userID: a.userID); try? b.deviceVault.purgeAccount(userID: b.userID) }
        let cid = UUID(), cancelled = UUID(), pending = UUID(), aid = UUID()
        _ = try b.prepare(Data("never submitted".utf8), messageID: cancelled, conversationID: cid, pair: pair, recipient: ab)
        XCTAssertTrue(try b.cancelUnsubmitted(cancelled))
        let wire = try b.prepare(Data("retained".utf8), messageID: pending, conversationID: cid, pair: pair, recipient: ab)
        try b.commit(pending)
        try b.markSubmitted(pending)
        XCTAssertFalse(try b.cancelUnsubmitted(pending))
        XCTAssertEqual(try b.prepare(Data(), messageID: pending, conversationID: cid, pair: pair, recipient: ab), wire)
        let aWire = try a.prepare(Data("winner".utf8), messageID: aid, conversationID: cid, pair: pair, recipient: bb)
        try a.commit(aid)
        let be = UUID(), ae = UUID()
        _ = try b.receive(aWire, eventID: be, deviceSeq: 1, pair: pair, control: false); try b.finish(be)
        _ = try a.receive(wire, eventID: ae, deviceSeq: 1, pair: pair, control: false); try a.finish(ae)
        try exchangeControls(a, b, pair)
        XCTAssertTrue(try XCTUnwrap(b.vault.load(pair.id)).drainAcknowledged)
        let manifest = try JSONDecoder().decode(V4FrozenManifest.self, from: XCTUnwrap(b.vault.load(pair.id)?.frozenManifest))
        XCTAssertTrue(manifest.entries.contains(where: { $0.messageID == cancelled && $0.cancelled }))
        XCTAssertFalse(manifest.entries.contains(where: { $0.messageID == pending && $0.cancelled }))
    }

    func testEstablishedPairIsSharedAcrossConversationsAndRejectsNewProposal() throws {
        let (a, b, pair, ab, bb) = try recoveryDevices()
        defer { try? a.deviceVault.purgeAccount(userID: a.userID); try? b.deviceVault.purgeAccount(userID: b.userID) }
        let id = UUID(), event = UUID()
        let first = try a.prepare(Data("first".utf8), messageID: id, conversationID: UUID(), pair: pair, recipient: bb)
        try a.commit(id)
        _ = try b.receive(first, eventID: event, deviceSeq: 1, pair: pair, control: false); try b.finish(event)
        try exchangeControls(a, b, pair)
        let originalProposal = try a.vault.load(pair.id)?.coordinator.activeProposal
        for sequence in 100..<104 {
            let id = UUID(), event = UUID()
            let wire = try b.prepare(Data("cross conversation".utf8), messageID: id,
                conversationID: UUID(), pair: pair, recipient: ab)
            try b.commit(id)
            XCTAssertEqual(try a.receive(wire, eventID: event, deviceSeq: Int64(sequence), pair: pair, control: false), Data("cross conversation".utf8))
            try a.finish(event)
        }
        XCTAssertEqual(try a.vault.load(pair.id)?.coordinator.activeProposal, originalProposal)
        XCTAssertEqual(try a.vault.load(pair.id)?.candidates.count, 1)
        let fresh = try proposal(pair, sender: b.localDevice, salt: 12)
        var state = try XCTUnwrap(a.vault.load(pair.id)).coordinator
        XCTAssertThrowsError(try state.add(fresh, localDevice: a.localDevice))
    }

    func testEveryCommitWriteCanResumeWithoutRatchetReDerivation() throws {
        for checkpoint in 1...7 {
            let (a, b, pair, _, bb) = try recoveryDevices()
            defer { try? a.deviceVault.purgeAccount(userID: a.userID); try? b.deviceVault.purgeAccount(userID: b.userID) }
            let id = UUID()
            let bytes = try a.prepare(Data("exact sealed output".utf8), messageID: id,
                conversationID: UUID(), pair: pair, recipient: bb)
            var interrupted = a.vault
            var writes = 0
            interrupted.onPersistence = {
                writes += 1
                if writes == checkpoint { throw NSError(domain: "InjectedKeychainInterruption", code: checkpoint) }
            }
            do { try interrupted.finish(pair.id, operationID: id) }
            catch { XCTAssertEqual((error as NSError).domain, "InjectedKeychainInterruption") }
            let reopened = V4HandshakeRecoveryVault(keychain: a.deviceVault.keychain, userID: a.userID, localDevice: a.localDevice)
            try reopened.finish(pair.id, operationID: id)
            let state = try XCTUnwrap(reopened.load(pair.id))
            XCTAssertEqual(state.version, 1)
            XCTAssertEqual(state.applicationOutbox.first?.wire, bytes)
            XCTAssertTrue(try reopened.pending(pair.id) == nil)
        }
    }

    func testBoundedFrozenManifestFitsOneAuthenticatedSegment() throws {
        let pair = try V4RecoveryPair(participant(a), participant(b))
        let p = try proposal(pair, sender: a, salt: 1), q = try proposal(pair, sender: b, salt: 2)
        let entries = (0..<2_000).map { index in
            V4RecoverySealedEntry(messageID: UUID(), conversationID: UUID(),
                ratchetPublicKey: q.header.senderEphemeralPublicKey, index: index, digest: Data(repeating: 1, count: 32))
        }
        let manifest = try V4FrozenManifest(pair: pair, proposals: [p,q], loser: q.id,
            entries: entries, cutoff: 2_000, identity: keys(b))
        let control = try V4SessionControl(kind: .resolveOffer, conversationID: UUID(), actor: b,
            pair: pair, proposals: [p,q], manifest: manifest, identity: keys(b))
        let payload = try JSONEncoder().encode(control)
        // Account for two base64 layers, routing/header overhead, nonce and tag.
        let conservativeWireSize = ((payload.count + 16 + 2) / 3 * 4 + 10_000 + 2) / 3 * 4 + 1_000
        XCTAssertLessThan(conservativeWireSize, 1_048_576)
        XCTAssertEqual(manifest.segmentIndex, 0); XCTAssertEqual(manifest.segmentCount, 1)
    }

    func testIncomingCommitInterruptionConsumesOTPOnceAndKeepsControlBytes() throws {
        for checkpoint in 1...8 {
            let (a, b, pair, _, bb) = try recoveryDevices()
            defer { try? a.deviceVault.purgeAccount(userID: a.userID); try? b.deviceVault.purgeAccount(userID: b.userID) }
            let id = UUID(), event = UUID()
            let bytes = try a.prepare(Data("synthetic inbound".utf8), messageID: id,
                conversationID: UUID(), pair: pair, recipient: bb)
            try a.commit(id)
            _ = try b.receive(bytes, eventID: event, deviceSeq: 1, pair: pair, control: false)
            let staged = try XCTUnwrap(b.vault.pending(pair.id))
            let controlBytes = staged.next.outbox.first?.wire
            var interrupted = b.vault, writes = 0
            interrupted.onPersistence = {
                writes += 1
                if writes == checkpoint { throw NSError(domain: "InjectedKeychainInterruption", code: checkpoint) }
            }
            do { try interrupted.finish(pair.id, operationID: event) }
            catch { XCTAssertEqual((error as NSError).domain, "InjectedKeychainInterruption") }
            XCTAssertGreaterThanOrEqual(writes, checkpoint)
            let reopened = b.vault
            try reopened.finish(pair.id, operationID: event)
            let state = try XCTUnwrap(reopened.load(pair.id))
            XCTAssertEqual(state.version, 1)
            XCTAssertEqual(state.outbox.first?.wire, controlBytes)
            let secrets = try XCTUnwrap(b.deviceVault.loadDevice(userID: b.userID, deviceID: b.localDevice))
            XCTAssertTrue(secrets.oneTimePreKeys.isEmpty)
            XCTAssertTrue(try reopened.pending(pair.id) == nil)
            let otp = try XCTUnwrap(staged.consumedPreKeys.first)
            XCTAssertThrowsError(try reopened.reserve(otp.publicKey, proposal: proposal(pair, sender: a.localDevice, salt: 21).id))
        }
    }

    func testDelayedAuthenticatedResolveRequestDoesNotBlockEstablishedSession() throws {
        let (a, b, pair, ab, bb) = try recoveryDevices()
        defer { try? a.deviceVault.purgeAccount(userID: a.userID); try? b.deviceVault.purgeAccount(userID: b.userID) }
        let cid = UUID(), aid = UUID(), bid = UUID()
        let aWire = try a.prepare(Data("a".utf8), messageID: aid, conversationID: cid, pair: pair, recipient: bb)
        let bWire = try b.prepare(Data("b".utf8), messageID: bid, conversationID: cid, pair: pair, recipient: ab)
        try a.commit(aid); try b.commit(bid)
        let ae = UUID(), be = UUID()
        _ = try a.receive(bWire, eventID: ae, deviceSeq: 1, pair: pair, control: false); try a.finish(ae)
        let delayed = try XCTUnwrap(a.controls().first)
        // Server accepted this request, but delivery is delayed past offer/ack/commit.
        try a.acknowledgeControl(delayed.id, pairID: pair.id)
        _ = try b.receive(aWire, eventID: be, deviceSeq: 1, pair: pair, control: false); try b.finish(be)
        try exchangeControls(a, b, pair)
        XCTAssertEqual(try b.vault.load(pair.id)?.coordinator.phase, .established)
        let before = try XCTUnwrap(b.vault.load(pair.id))
        let root = before.candidates.first(where: { $0.proposal.id == before.coordinator.activeProposal })?.ratchet?.rootKey
        _ = try b.receive(delayed.wire, eventID: delayed.id, deviceSeq: 200, pair: pair, control: true)
        try b.finish(delayed.id)
        XCTAssertEqual(try b.vault.load(pair.id)?.coordinator.phase, .established)
        let state = try XCTUnwrap(b.vault.load(pair.id))
        XCTAssertTrue(state.candidates.first(where: { $0.proposal.id == state.coordinator.activeProposal })?.ratchet?.rootKey == root)
        XCTAssertThrowsError(try b.receive(delayed.wire, eventID: delayed.id, deviceSeq: 201, pair: pair, control: true))
    }

    func testPeerCleanupFindsJournalEvenWithoutDiscoveryIndex() throws {
        let (a, b, pair, _, bb) = try recoveryDevices()
        defer { try? a.deviceVault.purgeAccount(userID: a.userID); try? b.deviceVault.purgeAccount(userID: b.userID) }
        _ = try a.prepare(Data("pending".utf8), messageID: UUID(), conversationID: UUID(), pair: pair, recipient: bb)
        try a.deviceVault.keychain.delete("v4.recovery.\(a.userID).\(a.localDevice.uuidString).peer.\(b.localDevice.uuidString)")
        try a.vault.removePeer(b.localDevice)
        XCTAssertTrue(try a.vault.pending(pair.id) == nil)
        XCTAssertTrue(try a.vault.load(pair.id) == nil)
    }

    private func recoveryDevices() throws -> (V4HandshakeRecoveryService, V4HandshakeRecoveryService, V4RecoveryPair, V4PreKeyBundle, V4PreKeyBundle) {
        let namespace = "app.luma.recovery-devices.\(UUID().uuidString)"
        let av = V4SessionVault(keychain: KeychainManager(service: namespace + ".a"))
        let bv = V4SessionVault(keychain: KeychainManager(service: namespace + ".b"))
        func device(_ id: UUID, _ vault: V4SessionVault, _ name: String) throws -> V4PreKeyBundle {
            let identity = try keys(id), signed = Curve25519.KeyAgreement.PrivateKey(), otp = Curve25519.KeyAgreement.PrivateKey()
            try vault.saveDevice(.init(formatVersion: 1, deviceID: id, keyVersion: 1,
                identityAgreement: identity.agreement.rawRepresentation, identitySigning: identity.signing.rawRepresentation,
                signedPreKey: signed.rawRepresentation, oneTimePreKeys: [otp.publicKey.rawRepresentation.base64EncodedString(): otp.rawRepresentation]), userID: name)
            return try V4Handshake.enableRecovery(V4Handshake.bundle(deviceID: id, version: 1, identity: identity,
                signedPreKey: signed, oneTimePreKey: otp), identity: identity)
        }
        let ab = try device(a, av, "a"), bb = try device(b, bv, "b")
        return (V4HandshakeRecoveryService(deviceVault: av, userID: "a", localDevice: a),
            V4HandshakeRecoveryService(deviceVault: bv, userID: "b", localDevice: b),
            try V4RecoveryPair(participant(a), participant(b)), ab, bb)
    }

    private func exchangeControls(_ a: V4HandshakeRecoveryService, _ b: V4HandshakeRecoveryService, _ pair: V4RecoveryPair) throws {
        var sequence: Int64 = 10
        for _ in 0..<20 {
            var progressed = false
            for (sender, receiver) in [(a,b),(b,a)] {
                let reopened = V4HandshakeRecoveryService(deviceVault: receiver.deviceVault,
                    userID: receiver.userID, localDevice: receiver.localDevice)
                for item in try sender.controls() {
                    _ = try reopened.receive(item.wire, eventID: item.id, deviceSeq: sequence, pair: pair, control: true)
                    try reopened.finish(item.id)
                    try sender.acknowledgeControl(item.id, pairID: pair.id)
                    sequence += 1; progressed = true
                }
            }
            if !progressed { return }
        }
        XCTFail("Negotiation must converge without infinite controls")
    }

    private func participant(_ id: UUID) throws -> V4RecoveryParticipant {
        let identity = try keys(id)
        return V4RecoveryParticipant(accountID: id, deviceID: id,
            accountFingerprint: String(repeating: "A", count: 64),
            agreementPublicKey: identity.agreement.publicKey.rawRepresentation,
            signingPublicKey: identity.signing.publicKey.rawRepresentation)
    }

    private func keys(_ id: UUID) throws -> V4IdentityKeys {
        let seed = Data(repeating: id == a ? 1 : 2, count: 32)
        return try V4IdentityKeys(agreement: .init(rawRepresentation: seed), signing: .init(rawRepresentation: seed))
    }

    private func proposal(_ pair: V4RecoveryPair, sender: UUID, salt: UInt8) throws -> V4RecoveryProposal {
        let peer = try XCTUnwrap(pair.participants.first { $0.deviceID != sender })
        let identity = try keys(sender)
        let signed = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: salt + 10, count: 32))
        let recipientIdentity = try keys(peer.deviceID)
        let bundle = try V4Handshake.bundle(deviceID: peer.deviceID, version: 1, identity: recipientIdentity,
            signedPreKey: signed, oneTimePreKey: signed)
        let initiated = try V4Handshake.initiate(senderDeviceID: sender, identity: identity,
            recipient: V4Handshake.enableRecovery(bundle, identity: recipientIdentity), expectedFingerprint: bundle.identityFingerprint, recoveryPair: pair)
        return try V4RecoveryProposal(pair: pair, header: initiated.header, identity: identity)
    }
}
