import Cocoa
import FlutterMacOS
import MultipeerConnectivity

class MainFlutterWindow: NSWindow {
  private var macNearbyBridge: MacNearbyBridge?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    macNearbyBridge = MacNearbyBridge(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}

final class MacNearbyBridge: NSObject {
  private static let methodChannelName = "vmessages/macos_nearby/methods"
  private static let peersEventChannelName = "vmessages/macos_nearby/peers"
  private static let messagesEventChannelName = "vmessages/macos_nearby/messages"

  private let methodChannel: FlutterMethodChannel
  private let peersEventChannel: FlutterEventChannel
  private let messagesEventChannel: FlutterEventChannel

  private var peersSink: FlutterEventSink?
  private var messagesSink: FlutterEventSink?

  private var serviceType = "vmsgchat"
  private var localPeerID = MCPeerID(displayName: Host.current().localizedName ?? "Mac")
  private var localDisplayName = Host.current().localizedName ?? "Mac"
  private var session: MCSession?
  private var advertiser: MCNearbyServiceAdvertiser?
  private var browser: MCNearbyServiceBrowser?

  private var discoveredPeers: [String: MCPeerID] = [:]
  private var peerStates: [String: Int] = [:]

  init(messenger: FlutterBinaryMessenger) {
    methodChannel = FlutterMethodChannel(name: Self.methodChannelName, binaryMessenger: messenger)
    peersEventChannel = FlutterEventChannel(name: Self.peersEventChannelName, binaryMessenger: messenger)
    messagesEventChannel = FlutterEventChannel(name: Self.messagesEventChannelName, binaryMessenger: messenger)
    super.init()
    methodChannel.setMethodCallHandler(handleMethodCall)
    peersEventChannel.setStreamHandler(PeersStreamHandler(owner: self))
    messagesEventChannel.setStreamHandler(MessagesStreamHandler(owner: self))
  }

  deinit {
  }

  private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "init":
      guard
        let args = call.arguments as? [String: Any],
        let serviceTypeArg = args["serviceType"] as? String,
        let deviceNameArg = args["deviceName"] as? String
      else {
        result(FlutterError(code: "invalid_args", message: "Missing init args", details: nil))
        return
      }
      initialize(serviceTypeArg: serviceTypeArg, deviceName: deviceNameArg)
      result(nil)
    case "startAdvertisingPeer":
      startAdvertising()
      result(nil)
    case "stopAdvertisingPeer":
      stopAdvertising()
      result(nil)
    case "startBrowsingForPeers":
      startBrowsing()
      result(nil)
    case "stopBrowsingForPeers":
      stopBrowsing()
      result(nil)
    case "invitePeer":
      guard
        let args = call.arguments as? [String: Any],
        let deviceID = args["deviceID"] as? String
      else {
        result(FlutterError(code: "invalid_args", message: "Missing invite args", details: nil))
        return
      }
      invitePeer(deviceID: deviceID)
      result(nil)
    case "sendMessage":
      guard
        let args = call.arguments as? [String: Any],
        let deviceID = args["deviceID"] as? String,
        let message = args["message"] as? String
      else {
        result(FlutterError(code: "invalid_args", message: "Missing send args", details: nil))
        return
      }
      sendMessage(deviceID: deviceID, message: message, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func initialize(serviceTypeArg: String, deviceName: String) {
    serviceType = String(serviceTypeArg.prefix(15))
    localDisplayName = sanitizePeerName(deviceName)
    localPeerID = MCPeerID(displayName: localDisplayName)
    let newSession = MCSession(peer: localPeerID, securityIdentity: nil, encryptionPreference: .required)
    newSession.delegate = self
    session = newSession
    discoveredPeers.removeAll()
    peerStates.removeAll()
    pushPeers()
  }

  private func startAdvertising() {
    if session == nil {
      initialize(serviceTypeArg: serviceType, deviceName: localDisplayName)
    }
    advertiser?.stopAdvertisingPeer()
    let newAdvertiser = MCNearbyServiceAdvertiser(peer: localPeerID, discoveryInfo: nil, serviceType: serviceType)
    newAdvertiser.delegate = self
    advertiser = newAdvertiser
    advertiser?.startAdvertisingPeer()
  }

  private func stopAdvertising() {
    advertiser?.stopAdvertisingPeer()
    advertiser = nil
  }

  private func startBrowsing() {
    if session == nil {
      initialize(serviceTypeArg: serviceType, deviceName: localDisplayName)
    }
    browser?.stopBrowsingForPeers()
    let newBrowser = MCNearbyServiceBrowser(peer: localPeerID, serviceType: serviceType)
    newBrowser.delegate = self
    browser = newBrowser
    browser?.startBrowsingForPeers()
  }

  private func stopBrowsing() {
    browser?.stopBrowsingForPeers()
    browser = nil
  }

  private func sanitizePeerName(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let base = trimmed.isEmpty ? "Mac" : trimmed
    let compact = base.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    return String(compact.prefix(63))
  }

  private func invitePeer(deviceID: String) {
    guard let session, let browser, let peer = discoveredPeers[deviceID] else { return }
    browser.invitePeer(peer, to: session, withContext: nil, timeout: 10)
  }

  private func sendMessage(deviceID: String, message: String, result: @escaping FlutterResult) {
    guard let session, let peer = discoveredPeers[deviceID] else {
      result(FlutterError(code: "peer_not_found", message: "Peer not found", details: nil))
      return
    }
    let payload: [String: Any] = [
      "senderDeviceId": localPeerID.displayName,
      "deviceId": peer.displayName,
      "message": message
    ]
    guard
      let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
      !data.isEmpty
    else {
      result(FlutterError(code: "invalid_message", message: "Invalid message JSON payload", details: nil))
      return
    }
    do {
      try session.send(data, toPeers: [peer], with: .reliable)
      result(nil)
    } catch {
      result(FlutterError(code: "send_failed", message: "Failed to send message", details: error.localizedDescription))
    }
  }

  private func pushPeers() {
    let peers = discoveredPeers.values.map { peer -> [String: Any] in
      let state = peerStates[peer.displayName] ?? 0
      return [
        "deviceId": peer.displayName,
        "deviceName": peer.displayName,
        "state": state
      ]
    }
    DispatchQueue.main.async { [weak self] in
      self?.peersSink?(peers)
    }
  }

  fileprivate func onPeersListen(_ sink: @escaping FlutterEventSink) {
    peersSink = sink
    pushPeers()
  }

  fileprivate func onPeersCancel() {
    peersSink = nil
  }

  fileprivate func onMessagesListen(_ sink: @escaping FlutterEventSink) {
    messagesSink = sink
  }

  fileprivate func onMessagesCancel() {
    messagesSink = nil
  }
}

extension MacNearbyBridge: MCNearbyServiceBrowserDelegate {
  func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
    discoveredPeers[peerID.displayName] = peerID
    if peerStates[peerID.displayName] == nil {
      peerStates[peerID.displayName] = 0
    }
    pushPeers()
  }

  func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
    discoveredPeers.removeValue(forKey: peerID.displayName)
    peerStates.removeValue(forKey: peerID.displayName)
    pushPeers()
  }
}

extension MacNearbyBridge: MCNearbyServiceAdvertiserDelegate {
  func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
    if discoveredPeers[peerID.displayName] == nil {
      discoveredPeers[peerID.displayName] = peerID
      peerStates[peerID.displayName] = 1
      pushPeers()
    }
    invitationHandler(true, session)
  }
}

extension MacNearbyBridge: MCSessionDelegate {
  func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
    switch state {
    case .connected:
      peerStates[peerID.displayName] = 2
    case .connecting:
      peerStates[peerID.displayName] = 1
    case .notConnected:
      peerStates[peerID.displayName] = 0
    @unknown default:
      peerStates[peerID.displayName] = 0
    }
    if discoveredPeers[peerID.displayName] == nil {
      discoveredPeers[peerID.displayName] = peerID
    }
    pushPeers()
  }

  func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
    guard let message = String(data: data, encoding: .utf8) else { return }
    DispatchQueue.main.async { [weak self] in
      self?.messagesSink?([
        "deviceId": peerID.displayName,
        "message": message
      ])
    }
  }

  func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}

  func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}

  func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

private final class PeersStreamHandler: NSObject, FlutterStreamHandler {
  private weak var owner: MacNearbyBridge?

  init(owner: MacNearbyBridge) {
    self.owner = owner
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    owner?.onPeersListen(events)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    owner?.onPeersCancel()
    return nil
  }
}

private final class MessagesStreamHandler: NSObject, FlutterStreamHandler {
  private weak var owner: MacNearbyBridge?

  init(owner: MacNearbyBridge) {
    self.owner = owner
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    owner?.onMessagesListen(events)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    owner?.onMessagesCancel()
    return nil
  }
}
