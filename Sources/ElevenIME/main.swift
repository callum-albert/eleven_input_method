import AppKit
import Carbon
import InputMethodKit
import ElevenCore

// Input method server bootstrap.
//
// The connection name must match `InputMethodConnectionName` in Info.plist.
// `InputMethodServerControllerClass` names the controller class below.

let connectionName = "ElevenInput_Connection"
let mainBundle = Bundle.main

NSApplication.shared.setActivationPolicy(.accessory)

// Tell the system about this bundle. LaunchServices-validated apps are allowed
// to call this; it makes a freshly copied bundle immediately visible to TIS.
let registerStatus = TISRegisterInputSource(mainBundle.bundleURL as CFURL)
Log.write("TISRegisterInputSource status=\(registerStatus)")

let server: IMKServer? = IMKServer(
    name: connectionName,
    bundleIdentifier: mainBundle.bundleIdentifier
)

if server == nil {
    Log.write("failed to create IMKServer for \(connectionName)")
}

NotificationCenter.default.addObserver(
    forName: NSApplication.willTerminateNotification,
    object: nil,
    queue: .main
) { _ in
    IMEShared.shared.flushLearning()
}

Log.write("ElevenInput started, bundle=\(mainBundle.bundleIdentifier ?? "?")")
NSApplication.shared.run()
