import CryptoKit
import Foundation

struct V4FrozenManifest: Codable {
    let pairID: Data
    let conflictID: V4ConflictID
    let loser: V4ProposalID
    let winner: V4ProposalID
    let cutoff: Int
    let entries: [V4RecoverySealedEntry]
    var segmentIndex: Int = 0
    var segmentCount: Int = 1
    let signature: Data

    var transcript: Data {
        var fields = [pairID, conflictID.bytes, loser.bytes, winner.bytes, V4HandshakeRecovery.integer(cutoff), V4HandshakeRecovery.integer(segmentIndex), V4HandshakeRecovery.integer(segmentCount)]
        fields += entries.map { entry in
            V4Handshake.fields("luma.v4.frozen-entry.v2", [V4HandshakeRecovery.uuidBytes(entry.messageID),
                V4HandshakeRecovery.uuidBytes(entry.conversationID), entry.ratchetPublicKey,
                V4HandshakeRecovery.integer(entry.index), entry.digest, Data([entry.cancelled ? 1 : 0])])
        }
        return V4Handshake.fields("luma.v4.freeze.v2", fields)
    }
    var digest: Data { Data(SHA256.hash(data: V4Handshake.fields("luma.v4.freeze-proof.v2", [transcript, signature]))) }

    init(pair: V4RecoveryPair, proposals: [V4RecoveryProposal], loser: V4ProposalID,
         entries: [V4RecoverySealedEntry], cutoff: Int, identity: V4IdentityKeys) throws {
        guard proposals.count == 2 else { throw V4ProtocolError.invalidHandshake }
        pairID = pair.id; conflictID = try V4ConflictID(pair: pair.id, proposals: proposals.map(\.id))
        winner = try V4HandshakeRecovery.winner(proposals[0], proposals[1]); self.loser = loser
        self.cutoff = cutoff; self.entries = entries.sorted { $0.index < $1.index }
        // A separate unsigned value lets the immutable signature cover the exact canonical transcript.
        let unsigned = Self(pairID: pairID, conflictID: conflictID, loser: loser, winner: winner,
            cutoff: cutoff, entries: self.entries, signature: Data())
        signature = try identity.signing.signature(for: unsigned.transcript)
        try verify(pair: pair, proposals: proposals)
    }

    private init(pairID: Data, conflictID: V4ConflictID, loser: V4ProposalID, winner: V4ProposalID,
                 cutoff: Int, entries: [V4RecoverySealedEntry], signature: Data) {
        self.pairID = pairID; self.conflictID = conflictID; self.loser = loser; self.winner = winner
        self.cutoff = cutoff; self.entries = entries; self.signature = signature
    }

    func verify(pair: V4RecoveryPair, proposals: [V4RecoveryProposal]) throws {
        guard segmentIndex == 0, segmentCount == 1, proposals.count == 2, cutoff >= 0, cutoff <= 2_000, entries.count == cutoff,
              pairID == pair.id, conflictID == (try V4ConflictID(pair: pair.id, proposals: proposals.map(\.id))),
              winner == (try V4HandshakeRecovery.winner(proposals[0], proposals[1])), loser != winner,
              let proposal = proposals.first(where: { $0.id == loser }),
              Set(entries.map(\.messageID)).count == entries.count,
              entries.enumerated().allSatisfy({ $0.offset == $0.element.index && $0.element.digest.count == 32 && $0.element.ratchetPublicKey.count == 32 }),
              entries.allSatisfy({ $0.ratchetPublicKey == proposal.header.senderEphemeralPublicKey }) else {
            throw V4ProtocolError.invalidHandshake
        }
        for p in proposals { try p.verify(in: pair) }
        let signer = try Curve25519.Signing.PublicKey(rawRepresentation: proposal.header.senderIdentitySigningPublicKey)
        guard signer.isValidSignature(signature, for: transcript) else { throw V4ProtocolError.invalidHandshake }
    }

    func permits(_ entry: V4RecoverySealedEntry) -> Bool { entries.contains(entry) && !entry.cancelled }
}

struct V4SessionControl: Codable {
    enum Kind: String, Codable {
        case confirm, confirmAck = "confirm_ack", resolveRequest = "resolve_request"
        case resolveOffer = "resolve_offer", resolveCommit = "resolve_commit", resolveAck = "resolve_ack", drainAck = "drain_ack"
    }
    let protocolVersion: Int
    let controlID: UUID
    let conversationID: UUID
    let actorDeviceID: UUID
    let pairID: Data
    let kind: Kind
    let proposals: [V4RecoveryProposal]
    let winner: V4ProposalID
    let manifest: V4FrozenManifest?
    let signature: Data

    var transcript: Data {
        V4Handshake.fields("luma.v4.control.v2", [V4HandshakeRecovery.integer(protocolVersion),
            V4HandshakeRecovery.uuidBytes(controlID), V4HandshakeRecovery.uuidBytes(conversationID),
            V4HandshakeRecovery.uuidBytes(actorDeviceID), pairID, Data(kind.rawValue.utf8), winner.bytes,
            V4Handshake.fields("luma.v4.control-proposals.v2", proposals.map { V4Handshake.fields("proposal", [$0.transcript, $0.signature]) }),
            manifest?.transcript ?? Data(), manifest?.signature ?? Data()])
    }

    init(kind: Kind, conversationID: UUID, actor: UUID, pair: V4RecoveryPair,
         proposals: [V4RecoveryProposal], manifest: V4FrozenManifest? = nil,
         identity: V4IdentityKeys, controlID: UUID = UUID()) throws {
        guard !proposals.isEmpty, proposals.count <= 2 else { throw V4ProtocolError.invalidHandshake }
        self.protocolVersion = 2; self.controlID = controlID; self.conversationID = conversationID
        actorDeviceID = actor; pairID = pair.id; self.kind = kind
        self.proposals = proposals.sorted { $0.id.bytes.lexicographicallyPrecedes($1.id.bytes) }
        winner = proposals.count == 2 ? try V4HandshakeRecovery.winner(proposals[0], proposals[1]) : proposals[0].id
        self.manifest = manifest
        let unsigned = Self(protocolVersion: 2, controlID: controlID, conversationID: conversationID,
            actorDeviceID: actor, pairID: pairID, kind: kind, proposals: self.proposals,
            winner: winner, manifest: manifest, signature: Data())
        signature = try identity.signing.signature(for: unsigned.transcript)
        try verify(pair: pair, expectedActor: actor, conversation: conversationID)
    }

    private init(protocolVersion: Int, controlID: UUID, conversationID: UUID, actorDeviceID: UUID,
                 pairID: Data, kind: Kind, proposals: [V4RecoveryProposal], winner: V4ProposalID,
                 manifest: V4FrozenManifest?, signature: Data) {
        self.protocolVersion = protocolVersion; self.controlID = controlID; self.conversationID = conversationID
        self.actorDeviceID = actorDeviceID; self.pairID = pairID; self.kind = kind
        self.proposals = proposals; self.winner = winner; self.manifest = manifest; self.signature = signature
    }

    func verify(pair: V4RecoveryPair, expectedActor: UUID, conversation: UUID) throws {
        guard protocolVersion == 2, pairID == pair.id, actorDeviceID == expectedActor,
              conversationID == conversation, proposals.count >= 1, proposals.count <= 2,
              let participant = pair.participants.first(where: { $0.deviceID == actorDeviceID }) else {
            throw V4ProtocolError.invalidHandshake
        }
        for p in proposals { try p.verify(in: pair) }
        let selected = proposals.count == 2 ? try V4HandshakeRecovery.winner(proposals[0], proposals[1]) : proposals[0].id
        guard selected == winner else { throw V4ProtocolError.invalidHandshake }
        switch kind {
        case .confirm, .confirmAck:
            guard proposals.count == 1, manifest == nil else { throw V4ProtocolError.invalidHandshake }
        case .resolveRequest:
            guard proposals.count == 2, manifest == nil else { throw V4ProtocolError.invalidHandshake }
        case .resolveOffer, .resolveAck, .resolveCommit, .drainAck:
            guard proposals.count == 2, let manifest else { throw V4ProtocolError.invalidHandshake }
            try manifest.verify(pair: pair, proposals: proposals)
        }
        let signer = try Curve25519.Signing.PublicKey(rawRepresentation: participant.signingPublicKey)
        guard signer.isValidSignature(signature, for: transcript) else { throw V4ProtocolError.invalidHandshake }
    }
}
