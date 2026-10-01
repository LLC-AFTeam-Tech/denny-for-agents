import AppKit
import SwiftUI
import WebKit

/// The scenes drawn by activity.js (frames of the website video).
enum DennyActivity: String, Equatable {
    case notes, tasks, calendar
}

/// Local-only canvas scenes shared with the approved website artwork.
struct DennyActivityView: NSViewRepresentable {
    let activity: DennyActivity
    let reduceMotion: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        context.coordinator.activity = activity
        context.coordinator.reduceMotion = reduceMotion
        if let folder = DennyMotionAssetCatalog.shared.activityDirectory {
            context.coordinator.folder = folder
            view.loadFileURL(folder.appendingPathComponent("index.html"), allowingReadAccessTo: folder)
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.activity = activity
        context.coordinator.reduceMotion = reduceMotion
        context.coordinator.apply(to: view)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.evaluateJavaScript("window.setDennyPaused?.(true)", completionHandler: nil)
        view.stopLoading()
        view.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var activity: DennyActivity = .notes
        var reduceMotion = false
        var folder: URL?
        var ready = false

        func apply(to view: WKWebView) {
            guard ready else { return }
            let reduced = reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            // Only a closed enum and a Bool cross this boundary; never user text.
            view.evaluateJavaScript("window.setDennyActivity('\(activity.rawValue)', \(reduced))", completionHandler: nil)
        }

        func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            apply(to: view)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url, let folder,
                  url.isFileURL, url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
