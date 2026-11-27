import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Principal class of the share extension (NSExtensionPrincipalClass). Copies the shared items
/// into the extension's temporary folder, then hosts the SwiftUI picker.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.finish = { [weak self] cancelled in
            guard let context = self?.extensionContext else { return }
            if cancelled {
                context.cancelRequest(withError: NSError(domain: "cx.m42.zlink.share", code: NSUserCancelledError))
            } else {
                context.completeRequest(returningItems: nil)
            }
        }
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        let providers: [NSItemProvider] = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        Task { @MainActor in
            await model.loadItems(from: providers)
            await model.start()
        }
    }
}
