import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let iosBackgroundTaskChannelName = "vmessages/ios_background_task"
  private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid

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
    }

    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func startBackgroundTask() {
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
}
