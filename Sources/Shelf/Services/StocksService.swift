import Foundation

struct SymbolMatch: Identifiable, Hashable, Sendable {
    var id: String { symbol }
    let symbol: String
    let name: String
    let type: String
}

struct StockQuote: Identifiable, Hashable {
    var id: String { symbol }
    let symbol: String
    let name: String
    let price: Double
    let previousClose: Double
    let currency: String
    let closes: [Double]

    var change: Double { price - previousClose }
    var changePercent: Double { previousClose == 0 ? 0 : change / previousClose * 100 }
    var isUp: Bool { change >= 0 }
}

/// Quotes from Yahoo Finance's public chart endpoint (no API key). Apple's Stocks app
/// has no public API, so this is the one non-Apple data source in Shelf.
@Observable
final class StocksService {
    static let shared = StocksService()
    static let symbolsKey = "stockSymbols"

    private(set) var quotes: [String: StockQuote] = [:]
    /// Symbols Yahoo doesn't recognise.
    private(set) var notFound: Set<String> = []
    private(set) var lastError: String?
    private(set) var lastUpdated: Date?

    var symbols: [String] {
        didSet {
            UserDefaults.standard.set(symbols, forKey: Self.symbolsKey)
            Task { await refresh() }
        }
    }

    @ObservationIgnored private var started = false

    private init() {
        symbols = UserDefaults.standard.stringArray(forKey: Self.symbolsKey) ?? ["AAPL", "NVDA", "SPY"]
    }

    func start() {
        guard !started else { return }
        started = true
        Task {
            while !Task.isCancelled {
                if DockStore.shared.hasWidget(.stocks) { await refresh() }
                try? await Task.sleep(for: .seconds(90))
            }
        }
    }

    /// Adds a ticker, or the best match when given a name ("dow jones" → ^DJI).
    /// Returns an error message when nothing matches.
    func add(_ raw: String) async -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        guard let symbol = await resolve(text) else { return "No stock or index matches “\(text)”." }
        guard !symbols.contains(symbol) else { return "\(symbol) is already in the list." }
        symbols.append(symbol)
        return nil
    }

    func remove(_ symbol: String) {
        symbols.removeAll { $0 == symbol }
        quotes[symbol] = nil
        notFound.remove(symbol)
    }

    /// The text itself if it's a valid ticker, else the top search result.
    private func resolve(_ text: String) async -> String? {
        let upper = text.uppercased()
        if !upper.contains(" "), let quote = try? await Self.fetch(upper) {
            quotes[upper] = quote
            return upper
        }
        return await Self.search(text).first?.symbol
    }

    /// Yahoo symbol search, for suggestions while typing.
    nonisolated static func search(_ query: String) async -> [SymbolMatch] {
        var components = URLComponents(string: "https://query1.finance.yahoo.com/v1/finance/search")!
        components.queryItems = [.init(name: "q", value: query), .init(name: "quotesCount", value: "6"),
                                 .init(name: "newsCount", value: "0")]
        var request = URLRequest(url: components.url!)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let quotes = root["quotes"] as? [[String: Any]] else { return [] }
        return quotes.compactMap { q in
            guard let symbol = q["symbol"] as? String else { return nil }
            return SymbolMatch(symbol: symbol,
                               name: q["shortname"] as? String ?? q["longname"] as? String ?? symbol,
                               type: (q["quoteType"] as? String ?? "").capitalized)
        }
    }

    func refresh() async {
        await withTaskGroup(of: (String, StockQuote?).self) { group in
            for symbol in symbols {
                group.addTask { (symbol, try? await Self.fetch(symbol)) }
            }
            var failed: [String] = []
            for await (symbol, quote) in group {
                if let quote { quotes[symbol] = quote } else { failed.append(symbol) }
            }
            // A symbol that never loaded is unknown; one that loaded before is just a network blip.
            notFound = Set(failed.filter { quotes[$0] == nil })
            let blips = failed.count - notFound.count
            lastError = blips > 0 ? "Couldn't refresh \(blips) symbol\(blips == 1 ? "" : "s")" : nil
        }
        lastUpdated = .now
        await fixUnknownSymbols()
    }

    /// Replaces names saved as symbols (e.g. "DOW JONES") with their real ticker, once.
    private func fixUnknownSymbols() async {
        for bad in notFound {
            guard let match = await Self.search(bad).first?.symbol, match != bad else { continue }
            if let i = symbols.firstIndex(of: bad) {
                notFound.remove(bad)
                if symbols.contains(match) { symbols.remove(at: i) } else { symbols[i] = match }
            }
        }
    }

    private nonisolated static func fetch(_ symbol: String) async throws -> StockQuote {
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        var request = URLRequest(url: URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?range=1d&interval=5m")!)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: request)

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chart = root["chart"] as? [String: Any],
              let result = (chart["result"] as? [[String: Any]])?.first,
              let meta = result["meta"] as? [String: Any],
              let price = meta["regularMarketPrice"] as? Double else {
            throw URLError(.cannotParseResponse)
        }
        let quote = ((result["indicators"] as? [String: Any])?["quote"] as? [[String: Any]])?.first
        let closes = (quote?["close"] as? [Any])?.compactMap { $0 as? Double } ?? []
        return StockQuote(
            symbol: symbol,
            name: meta["shortName"] as? String ?? meta["longName"] as? String ?? symbol,
            price: price,
            previousClose: meta["chartPreviousClose"] as? Double ?? meta["previousClose"] as? Double ?? price,
            currency: meta["currency"] as? String ?? "USD",
            closes: closes
        )
    }
}
