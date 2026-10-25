import CleanupModel
import Foundation
import IruddVoiceKit

// The cleanup helper: an XPC service inside the app
// (Contents/XPCServices/IruddVoiceCleanup.xpc). It loads the cleanup model
// with MLX and keeps it warm, so the app itself never holds the model. If
// it crashes, launchd starts it again on the next call and it starts empty.

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    let handler: CleanupServiceHandler

    init(handler: CleanupServiceHandler) {
        self.handler = handler
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = CleanupInterface.make()
        connection.exportedObject = handler
        connection.resume()
        return true
    }
}

// shared/cleanup-prompt.json is copied into the service's Resources.
guard let promptURL = Bundle.main.url(forResource: "cleanup-prompt", withExtension: "json"),
      let prompt = try? CleanupPrompt.load(from: promptURL) else {
    fatalError("cleanup-prompt.json is missing from the helper's Resources")
}
let delegate = ServiceDelegate(handler: CleanupServiceHandler(prompt: prompt, backend: CleanupEngine(prompt: prompt)))
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
