import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // Title bar takes the app's background so window and content read as one
    // dark surface, while it still drags the window natively.
    // ponytail: content stops below the title bar; full-size content needs a
    // drag strip in Flutter (window_manager) if the sidebar should reach the top.
    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true
    self.appearance = NSAppearance(named: .darkAqua)
    self.backgroundColor = NSColor(red: 0x0d / 255, green: 0x11 / 255, blue: 0x1b / 255, alpha: 1)
    self.minSize = NSSize(width: 820, height: 600)
    self.setContentSize(NSSize(width: 1180, height: 780))
    self.center()
    self.setFrameAutosaveName("Main")

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
