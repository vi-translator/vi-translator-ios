import SwiftUI
import UIKit

struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.path }
}

/** The system's share sheet (AirDrop, Files, Mail...). */
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
