import Cocoa
import FlutterMacOS
import ServiceManagement
import window_manager

class MainFlutterWindow: NSWindow {
  /// Below this the profile panel would no longer fit beside the friends.
  /// The launch size (1280×840) is the window's contentRect in MainMenu.xib.
  private static let minimumContentSize = NSSize(width: 960, height: 600)

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.minSize = self.frameRect(forContentRect: NSRect(origin: .zero, size: Self.minimumContentSize)).size
    self.center()

    // macOS state restoration would re-apply the frame saved at the last quit
    // (shortly after launch), overriding the 1280×840 launch size.
    self.isRestorable = false

    // Launch at login (package launch_at_startup): SMAppService, macOS 13+.
    FlutterMethodChannel(
      name: "launch_at_startup",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    ).setMethodCallHandler { call, result in
      switch call.method {
      case "launchAtStartupIsEnabled":
        if #available(macOS 13.0, *) {
          result(SMAppService.mainApp.status == .enabled)
        } else {
          result(false)
        }
      case "launchAtStartupSetEnabled":
        let enabled = (call.arguments as? [String: Any])?["setEnabledValue"] as? Bool ?? false
        if #available(macOS 13.0, *) {
          do {
            if enabled {
              try SMAppService.mainApp.register()
            } else {
              try SMAppService.mainApp.unregister()
            }
            result(nil)
          } catch {
            result(FlutterError(code: "launch_at_login", message: error.localizedDescription, details: nil))
          }
        } else {
          result(FlutterError(code: "unsupported", message: "macOS 13 requis", details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  // Hidden until Dart decides (window_manager): "Start minimized".
  override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    super.order(place, relativeTo: otherWin)
    hiddenWindowAtLaunch()
  }
}
