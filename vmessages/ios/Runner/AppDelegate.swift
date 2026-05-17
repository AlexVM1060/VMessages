import Flutter
import UIKit
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let iosBackgroundTaskChannelName = "vmessages/ios_background_task"
  private let iosSilentAudioChannelName = "vmessages/ios_silent_audio"
  private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
  private var appIsInBackground = false
  private var silentAudioEngine: AVAudioEngine?
  private var silentAudioSourceNode: AVAudioSourceNode?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: iosBackgroundTaskChannelName,
        binaryMessenger: controller.binaryMessenger
      )
      channel.setMethodCallHandler { [weak self] call, result in
        guard let self else {
          result(FlutterError(code: "no_app_delegate", message: "AppDelegate no disponible", details: nil))
          return
        }
        switch call.method {
        case "start":
          self.startBackgroundTask()
          result(true)
        case "stop":
          self.stopBackgroundTask()
          result(true)
        default:
          result(FlutterMethodNotImplemented)
        }
      }

      let silentAudioChannel = FlutterMethodChannel(
        name: iosSilentAudioChannelName,
        binaryMessenger: controller.binaryMessenger
      )
      silentAudioChannel.setMethodCallHandler { [weak self] call, result in
        guard let self else {
          result(FlutterError(code: "no_app_delegate", message: "AppDelegate no disponible", details: nil))
          return
        }
        switch call.method {
        case "start":
          self.startSilentBackgroundAudio()
          result(true)
        case "stop":
          self.stopSilentBackgroundAudio()
          result(true)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }

    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func startBackgroundTask() {
    guard appIsInBackground else { return }
    if backgroundTaskId != .invalid {
      UIApplication.shared.endBackgroundTask(backgroundTaskId)
      backgroundTaskId = .invalid
    }
    backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "vmessages-nearby") { [weak self] in
      self?.stopBackgroundTask()
    }
  }

  private func stopBackgroundTask() {
    guard backgroundTaskId != .invalid else { return }
    UIApplication.shared.endBackgroundTask(backgroundTaskId)
    backgroundTaskId = .invalid
  }

  private func startSilentBackgroundAudio() {
    if !appIsInBackground { return }
    if silentAudioEngine?.isRunning == true { return }

    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, options: [.mixWithOthers])
      try session.setActive(true, options: [])

      let engine = AVAudioEngine()
      let outputFormat = engine.outputNode.outputFormat(forBus: 0)
      let source = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
        let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
        for buffer in ablPointer {
          guard let mData = buffer.mData else { continue }
          memset(mData, 0, Int(buffer.mDataByteSize))
        }
        return noErr
      }
      engine.attach(source)
      engine.connect(source, to: engine.mainMixerNode, format: outputFormat)
      engine.mainMixerNode.outputVolume = 0.0
      try engine.start()

      silentAudioSourceNode = source
      silentAudioEngine = engine
    } catch {
      stopSilentBackgroundAudio()
    }
  }

  private func stopSilentBackgroundAudio() {
    silentAudioEngine?.stop()
    if let source = silentAudioSourceNode, let engine = silentAudioEngine {
      engine.detach(source)
    }
    silentAudioSourceNode = nil
    silentAudioEngine = nil
    do {
      try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    } catch {
    }
  }

  override func applicationDidEnterBackground(_ application: UIApplication) {
    appIsInBackground = true
    startBackgroundTask()
    startSilentBackgroundAudio()
    super.applicationDidEnterBackground(application)
  }

  override func applicationWillEnterForeground(_ application: UIApplication) {
    appIsInBackground = false
    stopBackgroundTask()
    stopSilentBackgroundAudio()
    super.applicationWillEnterForeground(application)
  }
}
