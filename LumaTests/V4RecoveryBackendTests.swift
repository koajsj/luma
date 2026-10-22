import CryptoKit
import Foundation
import XCTest
@testable import Luma

/// Opt-in isolated service check. Run with backend/scripts/validate-recovery.sh;
/// a missing local service is reported as skipped, never as a successful integration.
final class V4RecoveryBackendTests: XCTestCase {
    private struct Device {
        let name: String
        let account: P256.Signing.PrivateKey
        let auth: Curve25519.Signing.PrivateKey
        let userID: UUID
        let deviceID: UUID
        let token: String
        let service: V4HandshakeRecoveryService
        let participant: V4RecoveryParticipant
    }
    private let base = URL(string: "http://127.0.0.1:55441")!

    private func call(_ method: String, _ path: String, _ body: [String: Any]? = nil,
                      device: Device? = nil, statuses: Set<Int> = [200], idem: UUID? = nil) async throws -> Data {
        var request = URLRequest(url: base.appendingPathComponent(path))
        // appendingPathComponent must not escape the query delimiter in the request proof.
        request.url = URL(string: base.absoluteString + path)
        request.httpMethod = method; request.timeoutInterval = 10
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let device {
            let timestamp = String(Int(Date().timeIntervalSince1970))
            let nonce = UUID().uuidString
            let digest = Data(SHA256.hash(data: Data(device.token.utf8))).base64URLEncodedString()
            let proof = ["luma.request.v1", method, path, timestamp, nonce, digest].joined(separator: "\n")
            request.setValue("Bearer " + device.token, forHTTPHeaderField: "Authorization")
            request.setValue(timestamp, forHTTPHeaderField: "X-Device-Timestamp")
            request.setValue(nonce, forHTTPHeaderField: "X-Device-Nonce")
            request.setValue(try device.auth.signature(for: Data(proof.utf8)).base64URLEncodedString(), forHTTPHeaderField: "X-Device-Signature")
        }
        if let idem { request.setValue(idem.uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key") }
        let (bytes, response) = try await URLSession.shared.data(for: request)
        let code = try XCTUnwrap(response as? HTTPURLResponse).statusCode
        guard statuses.contains(code) else { throw NSError(domain: "RecoveryBackendHTTP", code: code) }
        return bytes
    }
    private func object(_ bytes: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }
    private func string(_ object: [String: Any], _ key: String) throws -> String {
        try XCTUnwrap(object[key] as? String)
    }

    private func register() async throws -> Device {
        let name = "rec_" + UUID().uuidString.prefix(8).lowercased()
        let account = P256.Signing.PrivateKey(), pre = P256.Signing.PrivateKey(), auth = Curve25519.Signing.PrivateKey()
        let challenge = try object(await call("POST", "/v1/auth/register/challenge", ["userID": name]))
        let nonce = try string(challenge, "nonce")
        let ap = account.publicKey.x963Representation.base64URLEncodedString()
        let pp = pre.publicKey.x963Representation.base64URLEncodedString()
        let au = auth.publicKey.rawRepresentation.base64URLEncodedString()
        let transcript = ["luma.register.v1", nonce, name, ap, pp, au, pp].joined(separator: "\n")
        let registration = try object(await call("POST", "/v1/auth/register", [
            "userID": name, "nickname": "Recovery Test", "challengeID": string(challenge, "challengeID"),
            "nonce": nonce, "identityPublicKey": ap, "devicePublicKey": pp, "authPublicKey": au,
            "deviceName": "Isolated logical device", "signedPreKey": pp, "signedPreKeyVersion": 1,
            "signedPreKeySignature": account.signature(for: pre.publicKey.x963Representation).derRepresentation.base64URLEncodedString(),
            "signature": auth.signature(for: Data(transcript.utf8)).base64URLEncodedString()
        ], statuses: [201]))
        let did = try string(registration, "deviceID"), uid = try string(registration, "userID")
        let login = try object(await call("POST", "/v1/auth/challenge", ["deviceID": did]))
        let loginNonce = try string(login, "nonce")
        let tokens = try object(await call("POST", "/v1/auth/token", ["deviceID": did,
            "challengeID": string(login, "challengeID"), "nonce": loginNonce,
            "signature": auth.signature(for: Data("luma.login.v1\n\(loginNonce)\n\(did)".utf8)).base64URLEncodedString()]))
        let deviceID = try XCTUnwrap(UUID(uuidString: did)), userID = try XCTUnwrap(UUID(uuidString: uid))
        let identity = V4IdentityKeys(), signed = Curve25519.KeyAgreement.PrivateKey(), otp = Curve25519.KeyAgreement.PrivateKey()
        let vault = V4SessionVault(keychain: KeychainManager(service: "app.luma.backend-recovery-test.\(UUID().uuidString)"))
        try vault.saveDevice(.init(formatVersion: 1, deviceID: deviceID, keyVersion: 1,
            identityAgreement: identity.agreement.rawRepresentation, identitySigning: identity.signing.rawRepresentation,
            signedPreKey: signed.rawRepresentation, oneTimePreKeys: [otp.publicKey.rawRepresentation.base64EncodedString(): otp.rawRepresentation]), userID: name)
        let device = Device(name: name, account: account, auth: auth, userID: userID, deviceID: deviceID,
            token: try string(tokens, "accessToken"), service: .init(deviceVault: vault, userID: name, localDevice: deviceID),
            participant: .init(accountID: userID, deviceID: deviceID,
                accountFingerprint: IdentityFingerprint.make(publicKey: account.publicKey.x963Representation),
                agreementPublicKey: identity.agreement.publicKey.rawRepresentation, signingPublicKey: identity.signing.publicKey.rawRepresentation))
        let bundle = try V4Handshake.enableRecovery(V4Handshake.bundle(deviceID: deviceID, version: 1,
            identity: identity, signedPreKey: signed, oneTimePreKey: otp), identity: identity)
        let binding = V4Handshake.fields("luma.v4.binding", [Data(did.utf8), Data("1".utf8),
            bundle.identityAgreementPublicKey, bundle.identitySigningPublicKey])
        _ = try await call("PUT", "/v1/devices/\(did)/v4-prekeys", [
            "identityAgreementPublicKey": bundle.identityAgreementPublicKey.base64URLEncodedString(),
            "identitySigningPublicKey": bundle.identitySigningPublicKey.base64URLEncodedString(),
            "identityBindingSignature": account.signature(for: binding).derRepresentation.base64URLEncodedString(),
            "signedPreKeyPublicKey": bundle.signedPreKeyPublicKey.base64URLEncodedString(),
            "signedPreKeySignature": bundle.signedPreKeySignature.base64URLEncodedString(), "keyVersion": 1,
            "oneTimePreKeys": [otp.publicKey.rawRepresentation.base64URLEncodedString()], "recoveryProtocolVersion": 2,
            "recoveryCapabilitySignature": try XCTUnwrap(bundle.recoveryCapabilitySignature).base64URLEncodedString()
        ], device: device, statuses: [204])
        let status = try object(await call("GET", "/v1/devices/\(did)/v4-prekeys/status", device: device))
        XCTAssertEqual(status["recoveryProtocolVersion"] as? Int, 2)
        return device
    }

    private func bundle(_ peer: Device, requestedBy device: Device) async throws -> V4PreKeyBundle {
        let bytes = try await call("GET", "/v1/users/\(peer.userID.uuidString.lowercased())/v4-prekey-bundle", device: device)
        let row = try XCTUnwrap(JSONDecoder().decode([V4RemoteBundle].self, from: bytes).first(where: { $0.deviceID == peer.deviceID }))
        var verified = try row.verified(expectedAccountFingerprint: peer.participant.accountFingerprint)
        verified.recoveryParticipant = peer.participant
        return verified
    }

    func testSimultaneousHandshakeThroughBackendAndCursorRetry() async throws {
        do { _ = try await call("GET", "/ready") }
        catch { throw XCTSkip("Isolated backend absent: run backend/scripts/validate-recovery.sh; not a passed backend validation") }
        let a = try await register(), b = try await register()
        defer {
            try? a.service.vault.purge(); try? b.service.vault.purge()
            try? a.service.deviceVault.purgeAccount(userID: a.name)
            try? b.service.deviceVault.purgeAccount(userID: b.name)
        }
        _ = try await call("PATCH", "/v1/users/me", ["searchable": true], device: b)
        _ = try await call("POST", "/v1/friend/request", ["userID": b.name], device: a, statuses: [202])
        let requestBytes = try await call("GET", "/v1/friend/requests", device: b)
        let requests = try XCTUnwrap(JSONSerialization.jsonObject(with: requestBytes) as? [[String: Any]])
        _ = try await call("POST", "/v1/friend/accept", ["requestID": string(XCTUnwrap(requests.first), "requestID")], device: b, statuses: [204])
        let conversation = try object(await call("POST", "/v1/conversations", ["friendID": b.userID.uuidString.lowercased()], device: a, statuses: [201]))
        let cid = try XCTUnwrap(UUID(uuidString: string(conversation, "id")))
        let pair = try V4RecoveryPair(a.participant, b.participant)
        let ab = try await bundle(a, requestedBy: b), bb = try await bundle(b, requestedBy: a)
        for (sender, receiver, target) in [(a,b,bb), (b,a,ab)] {
            let id = UUID()
            let wire = try sender.service.prepare(Data("synthetic first".utf8), messageID: id,
                conversationID: cid, pair: pair, recipient: target)
            try sender.service.commit(id)
            try sender.service.markSubmitted(id)
            let message = try JSONDecoder().decode(V4RatchetMessage.self, from: wire)
            let body: [String: Any] = ["messageID": id.uuidString.lowercased(), "conversationID": cid.uuidString.lowercased(),
                "encryptionVersion": 4, "recipientEnvelopes": [["recipientDeviceID": receiver.deviceID.uuidString.lowercased(),
                    "ciphertext": wire.base64URLEncodedString(), "keyVersion": 1, "messageKeyIndex": message.messageIndex]]]
            _ = try await call("POST", "/v1/messages", body, device: sender, statuses: [201], idem: id)
            // HTTP response loss: a byte-identical retry must not produce a second sync event.
            _ = try await call("POST", "/v1/messages", body, device: sender, statuses: [200], idem: id)
        }
        var cursors: [UUID: Int64] = [a.deviceID: 0, b.deviceID: 0]
        var applicationMessages = 0
        for _ in 0..<12 {
            var progress = false
            for (sender, receiver) in [(a,b),(b,a)] {
                for item in try sender.service.controls() {
                    let body: [String: Any] = ["controlID": item.id.uuidString.lowercased(),
                        "conversationID": cid.uuidString.lowercased(), "receiverDeviceID": receiver.deviceID.uuidString.lowercased(),
                        "encryptionVersion": 4, "envelope": item.wire.base64URLEncodedString()]
                    _ = try await call("POST", "/v1/sessions/controls", body, device: sender, statuses: [201])
                    _ = try await call("POST", "/v1/sessions/controls", body, device: sender, statuses: [200])
                    try sender.service.acknowledgeControl(item.id, pairID: pair.id)
                }
                let cursor = cursors[receiver.deviceID] ?? 0
                let page = try JSONDecoder().decode(RemoteSyncPage.self, from: await call("GET", "/v1/sync/events?cursor=\(cursor)&limit=100", device: receiver))
                for event in page.events {
                    let fresh = V4HandshakeRecoveryService(deviceVault: receiver.service.deviceVault,
                        userID: receiver.name, localDevice: receiver.deviceID)
                    let bytes = try XCTUnwrap(Data(base64URL: event.payloadCiphertext))
                    let plaintext = try fresh.receive(bytes, eventID: event.eventID, deviceSeq: event.deviceSeq,
                        pair: pair, control: event.type == "session.control")
                    if event.type == "message.created" {
                        XCTAssertEqual(plaintext, Data("synthetic first".utf8)); applicationMessages += 1
                    }
                    // Simulate app reopening after local cursor saved, before crypto finalization.
                    try fresh.vault.recoverIncoming(cursor: event.deviceSeq)
                    cursors[receiver.deviceID] = event.deviceSeq
                    _ = try await call("POST", "/v1/sync/ack", ["cursor": event.deviceSeq], device: receiver, statuses: [204])
                    progress = true
                }
            }
            if !progress { break }
        }
        XCTAssertEqual(applicationMessages, 2)
        XCTAssertEqual(try a.service.vault.load(pair.id)?.coordinator.phase, .established)
        XCTAssertEqual(try b.service.vault.load(pair.id)?.coordinator.phase, .established)
        XCTAssertEqual(try a.service.vault.load(pair.id)?.coordinator.activeProposal, try b.service.vault.load(pair.id)?.coordinator.activeProposal)
    }
}
