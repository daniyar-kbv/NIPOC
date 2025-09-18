//
//  ContentView.swift
//  NIPOC
//
//  Created by Daniyar Kurmanbayev on 2025-09-15.
//

import SwiftUI
import NearbyInteraction
import MultipeerConnectivity
import simd
import OSLog

private let osLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NIPOC", category: "general")
@inline(__always)
func log(_ message: String, level: OSLogType = .info) {
    osLogger.log(level: level, "\(message, privacy: .public)")
}

final class PeerService: NSObject, ObservableObject {
    private let service = "ni-poc"
    private let myPeer = PeerService.makePeerID()
    private lazy var session = MCSession(peer: myPeer, securityIdentity: nil, encryptionPreference: .required)
    private lazy var advertiser = MCNearbyServiceAdvertiser(peer: myPeer, discoveryInfo: nil, serviceType: service)
    private lazy var browser = MCNearbyServiceBrowser(peer: myPeer, serviceType: service)

    var onTokenReceived: ((NIDiscoveryToken) -> Void)?
    var onConnected: (() -> Void)?

    override init() {
        super.init()
        
        log("PeerService init — peer=\(myPeer.displayName), service=\(service)")
        
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
        
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        
        log("Started advertising and browsing")
    }

    func send(token: NIDiscoveryToken) {
        guard !session.connectedPeers.isEmpty else {
            log("Attempted to send token but no connected peers", level: .default)
            return
        }
        
        log("Sending my discovery token - tokenHash=\(token.hashValue)", level: .info)
        
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
            try session.send(data, toPeers: session.connectedPeers, with: .reliable)
            log("Sent discovery token - tokenHash=\(token.hashValue) to \(session.connectedPeers.count) peer(s)", level: .info)
        } catch {
            log("Failed to send discovery token — error=\(error.localizedDescription)", level: .error)
        }
    }

    private static func makePeerID() -> MCPeerID {
        let device = UIDevice.current.model
        let suffix = String(format: "%04X", UInt16.random(in: UInt16.min...UInt16.max))
        let name = "UWB-\(device)-\(suffix)"
        return MCPeerID(displayName: name)
    }
}

extension PeerService: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        log("Received invitation from peer=\(peerID.displayName) — accepting")
        invitationHandler(true, session)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        log("Advertiser failed to start — error=\(error.localizedDescription)", level: .error)
    }
}

extension PeerService: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo: [String : String]?) {
        if peerID != myPeer {
            log("Found peer=\(peerID.displayName). Inviting…")
            browser.invitePeer(peerID, to: session, withContext: nil, timeout: 20)
        }
    }
    
    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        log("Browser failed to start — error=\(error.localizedDescription)", level: .error)
    }
    
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        log("Lost peer=\(peerID.displayName)")
    }
}

extension PeerService: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        log("MCSession state changed — peer=\(peerID.displayName) state=\(stateName(state))")
        
        if state == .connected {
            DispatchQueue.main.async { self.onConnected?() }
        }
        
        func stateName(_ s: MCSessionState) -> String {
            switch s {
            case .notConnected: return "notConnected"
            case .connecting: return "connecting"
            case .connected: return "connected"
            @unknown default: return "unknown"
            }
        }
    }
    
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        if let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: data) {
            log("Received discovery token - tokenHash=\(token.hashValue) from peer=\(peerID.displayName)")
            DispatchQueue.main.async { self.onTokenReceived?(token) }
        }
    }
    
    func session(_ session: MCSession, didReceive stream: InputStream, withName: String, fromPeer: MCPeerID) { }
    func session(_ session: MCSession, didStartReceivingResourceWithName: String, fromPeer: MCPeerID, with: Progress) { }
    func session(_ session: MCSession, didFinishReceivingResourceWithName: String, fromPeer: MCPeerID, at: URL?, withError: Error?) { }
}

final class NIManager: NSObject, ObservableObject {
    private let session = NISession()
    private let peerService = PeerService()

    override init() {
        super.init()
        
        session.delegate = self
        
        let caps = NISession.deviceCapabilities
        log("NISession device capabilities - supportsPreciseDistanceMeasurement=\(caps.supportsPreciseDistanceMeasurement), supportsCameraAssistance=\(caps.supportsCameraAssistance), supportsDirectionMeasurement=\(caps.supportsDirectionMeasurement), supportsExtendedDistanceMeasurement=\(caps.supportsExtendedDistanceMeasurement)", level: .info)
        
        if session.discoveryToken != nil {
            log("My discoveryToken is available on init")
        }
        
        peerService.onTokenReceived = { [weak self] peerToken in
            log("onTokenReceived — running NI session with peer token")
            self?.run(with: peerToken)
        }
        
        peerService.onConnected = { [weak self] in
            guard let self, let token = self.session.discoveryToken else { return }
            log("onPeerConnected — attempting to send my discovery token")
            self.peerService.send(token: token)
        }
    }

    private func run(with peerToken: NIDiscoveryToken) {
        let config = NINearbyPeerConfiguration(peerToken: peerToken)
        log("Running NISession with NINearbyPeerConfiguration")
        session.run(config)
    }
}

extension NIManager: NISessionDelegate {
    func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard let obj = nearbyObjects.first else { return }
        if let distance = obj.distance,
           let direction = obj.direction {
            log(String(format: "Nearby object updated — distance=%.2f m, direction=(x: %.2f, y: %.2f, z: %.2f)",
                       distance, direction.x, direction.y, direction.z), level: .info)
        } else if let distance = obj.distance {
            log(String(format: "Nearby object updated — distance=%.2f m", distance), level: .info)
        } else if let direction = obj.direction {
            log(String(format: "Nearby object updated — direction=(x: %.2f, y: %.2f, z: %.2f)",
                          direction.x, direction.y, direction.z), level: .info)
        } else {
            log("Nearby object updated — no distance or direction info", level: .info)
        }
    }

    func sessionWasSuspended(_ session: NISession) {
        log("NISession was suspended", level: .default)
    }
    
    func sessionSuspensionEnded(_ session: NISession) {
        if let config = session.configuration { session.run(config) }
    }

    func session(_ session: NISession, didInvalidateWith error: Error) {
        log("NISession invalidated — error=\(error.localizedDescription)", level: .error)
        
        if let token = session.discoveryToken {
            log("NISession invalidated — re-sending discovery token if possible", level: .default)
            peerService.send(token: token)
        }
    }
}

struct ContentView: View {
    @StateObject private var ni = NIManager()

    var body: some View {
        VStack {
            Text("NI POC")
        }
    }
}
