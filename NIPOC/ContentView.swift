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

struct Logger {
    private static let osLogger = os.Logger(subsystem: Bundle.main.bundleIdentifier ?? "NIPOC", category: "general")
    
    static func log(_ message: String, level: OSLogType = .info) {
        osLogger.log(level: level, "\(message, privacy: .public)")
    }
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
        
        Logger.log("PeerService init — peer=\(myPeer.displayName), service=\(service)")
        
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
        
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        
        Logger.log("Started advertising and browsing")
    }

    func send(token: NIDiscoveryToken) {
        guard !session.connectedPeers.isEmpty else {
            Logger.log("Attempted to send token but no connected peers", level: .default)
            return
        }
        
        Logger.log("Sending my discovery token - tokenHash=\(token.hashValue)", level: .info)
        
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
            try session.send(data, toPeers: session.connectedPeers, with: .reliable)
            Logger.log("Sent discovery token - tokenHash=\(token.hashValue) to \(session.connectedPeers.count) peer(s)", level: .info)
        } catch {
            Logger.log("Failed to send discovery token — error=\(error.localizedDescription)", level: .error)
        }
    }
}

extension PeerService: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Logger.log("Received invitation from peer=\(peerID.displayName) — accepting")
        invitationHandler(true, session)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Logger.log("Advertiser failed to start — error=\(error.localizedDescription)", level: .error)
    }
}

extension PeerService: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo: [String : String]?) {
        if peerID != myPeer {
            Logger.log("Found peer=\(peerID.displayName). Inviting…")
            browser.invitePeer(peerID, to: session, withContext: nil, timeout: 20)
        }
    }
    
    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Logger.log("Browser failed to start — error=\(error.localizedDescription)", level: .error)
    }
    
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Logger.log("Lost peer=\(peerID.displayName)")
    }
}

extension PeerService {
    private static func makePeerID() -> MCPeerID {
        let device = UIDevice.current.model
        let suffix = String(format: "%04X", UInt16.random(in: UInt16.min...UInt16.max))
        let name = "UWB-\(device)-\(suffix)"
        return MCPeerID(displayName: name)
    }
}

extension PeerService: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Logger.log("MCSession state changed — peer=\(peerID.displayName) state=\(stateName(state))")
        
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
            Logger.log("Received discovery token - tokenHash=\(token.hashValue) from peer=\(peerID.displayName)")
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
    
    @Published var distance: Float? = nil
    @Published var direction: Double? = nil
    @Published var state: State = .searching
    

    override init() {
        super.init()
        
        session.delegate = self
        
        let capabilities = NISession.deviceCapabilities
        Logger.log("NISession device capabilities - supportsPreciseDistanceMeasurement=\(capabilities.supportsPreciseDistanceMeasurement), supportsCameraAssistance=\(capabilities.supportsCameraAssistance), supportsDirectionMeasurement=\(capabilities.supportsDirectionMeasurement), supportsExtendedDistanceMeasurement=\(capabilities.supportsExtendedDistanceMeasurement)", level: .info)
        
        if session.discoveryToken != nil {
            Logger.log("My discoveryToken is available on init")
        }
        
        peerService.onTokenReceived = { [weak self] peerToken in
            Logger.log("onTokenReceived — running NI session with peer token")
            self?.run(with: peerToken)
        }
        
        peerService.onConnected = { [weak self] in
            guard let self, let token = self.session.discoveryToken else { return }
            Logger.log("onPeerConnected — attempting to send my discovery token")
            state = .connected
            self.peerService.send(token: token)
        }
    }

    private func run(with peerToken: NIDiscoveryToken) {
        let config = NINearbyPeerConfiguration(peerToken: peerToken)
        Logger.log("Running NISession with NINearbyPeerConfiguration")
        session.run(config)
    }
}

extension NIManager: NISessionDelegate {
    func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard let object = nearbyObjects.first else { return }
        distance = object.distance
        
        if let direction = object.direction {
            self.direction = Double(asin(direction.x))
        } else {
            self.direction = nil
        }
    }

    func sessionWasSuspended(_ session: NISession) {
        Logger.log("NISession was suspended", level: .default)
        state = .suspended
    }
    
    func sessionSuspensionEnded(_ session: NISession) {
        Logger.log("NISession suspension ended", level: .default)
        if let config = session.configuration {
            Logger.log("Resuming NISession with previous configuration", level: .default)
            state = .connected
            session.run(config)
        } else {
            Logger.log("No previous configuration found.", level: .default)
            state = .searching
        }
    }

    func session(_ session: NISession, didInvalidateWith error: Error) {
        Logger.log("NISession invalidated — error=\(error.localizedDescription)", level: .error)
        state = .searching
        
        if let token = session.discoveryToken {
            Logger.log("NISession invalidated — re-sending discovery token if possible", level: .default)
            peerService.send(token: token)
        }
    }
}

extension NIManager {
    enum State {
        case searching
        case connected
        case suspended
    }
    
    var stateDescription: String {
        switch state {
        case .searching: return "Searching"
        case .connected: return "Connected"
        case .suspended: return "Suspended"
        }
    }
}

struct ContentView: View {
    @StateObject private var ni = NIManager()

    var body: some View {
        VStack {
            Text("NI POC")
                .font(.largeTitle)
            Spacer(minLength: 32)
            Text(ni.stateDescription)
                .font(.title2)
            Text(ni.distance != nil ? String(format: "Distance: %.2f m", ni.distance!) : "Distance: N/A")
                .font(.title3)
            Spacer()
            Text("⬆️")
                .font(.system(size: 140))
                .rotationEffect(.radians(ni.direction ?? 0))
                .animation(.easeInOut(duration: 0.15), value: ni.direction ?? 0)
                .opacity(ni.direction != nil ? 1 : 0.3)
            Spacer()
        }
    }
}
