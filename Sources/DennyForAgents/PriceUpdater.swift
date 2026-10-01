import AgentCore
import Foundation

/// Keeps model prices fresh without an app update: downloads prices.json from
/// the repository once a day and caches it in ~/.denny-for-agents. Only a
/// public file is fetched; nothing about your usage is sent.
final class PriceUpdater {
    static let source = URL(string: "https://raw.githubusercontent.com/OWNER/denny-for-agents/main/prices.json")!
    static let interval: TimeInterval = 24 * 3600

    private var cache: URL { BridgePaths.directory().appendingPathComponent("prices.json") }

    func start() {
        apply(try? Data(contentsOf: cache))
        refresh()
        Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in self?.refresh() }
    }

    private func refresh() {
        // Not published yet: the built-in table is used.
        guard !Self.source.absoluteString.contains("/OWNER/") else { return }
        var request = URLRequest(url: Self.source, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("Denny-for-Agents", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let self, let data, (response as? HTTPURLResponse)?.statusCode == 200,
                  Pricing.overrides(fromJSON: data) != nil else { return }
            try? data.write(to: self.cache, options: .atomic)
            DispatchQueue.main.async { self.apply(data) }
        }.resume()
    }

    private func apply(_ data: Data?) {
        guard let data, let overrides = Pricing.overrides(fromJSON: data), !overrides.isEmpty else { return }
        Pricing.overrides = overrides
    }
}
