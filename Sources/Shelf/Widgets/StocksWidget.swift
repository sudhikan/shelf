import Charts
import SwiftUI

struct StocksCompact: View {
    @AppStorage(SettingsKey.tileSize) private var tileSize = SettingsDefault.tileSize
    @State private var index = 0
    private var service: StocksService { .shared }

    var body: some View {
        // Only rotate through symbols that have loaded, so an unknown one never shows a spinner.
        let loaded = service.symbols.compactMap { service.quotes[$0] }
        let stillLoading = loaded.isEmpty && service.lastUpdated == nil && !service.symbols.isEmpty
        Group {
            if stillLoading {
                ProgressView().controlSize(.small).frame(width: tileSize * 2.1)
            } else if loaded.isEmpty {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: tileSize * 0.42, weight: .light))
                    .frame(width: tileSize * 0.8)
            } else {
                let quote = loaded[index % loaded.count]
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(quote.symbol)
                            .font(.system(size: 12, weight: .bold))
                        // Drop cents on big numbers (indexes) so the price fits.
                        Text(quote.price, format: .number.precision(.fractionLength(quote.price >= 10_000 ? 0 : 2)))
                            .font(.system(size: 12))
                            .monospacedDigit()
                        Text(String(format: "%+.2f%%", quote.changePercent))
                            .font(.system(size: 10, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(quote.isUp ? .green : .red)
                    }
                    .frame(width: tileSize * 1.15, alignment: .leading)
                    Sparkline(quote: quote)
                        .frame(width: tileSize * 0.9, height: tileSize * 0.5)
                }
            }
        }
        .onAppear { service.start() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(6))
                index += 1
            }
        }
    }
}

struct Sparkline: View {
    let quote: StockQuote

    var body: some View {
        let closes = quote.closes
        let low = min(closes.min() ?? quote.previousClose, quote.previousClose)
        let high = max(closes.max() ?? quote.previousClose, quote.previousClose)
        Chart {
            RuleMark(y: .value("Prev", quote.previousClose))
                .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                .foregroundStyle(.secondary)
            ForEach(closes.indices, id: \.self) { i in
                LineMark(x: .value("t", i), y: .value("p", closes[i]))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .foregroundStyle(quote.isUp ? Color.green : .red)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartXScale(domain: 0...max(78, closes.count - 1))
        .chartYScale(domain: low...max(high, low + 0.01))
    }
}

struct StocksExpanded: View {
    @State private var newSymbol = ""
    @State private var suggestions: [SymbolMatch] = []
    @State private var addError: String?
    @State private var adding = false
    private var service: StocksService { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WidgetHeader(title: "Stocks", symbol: "chart.line.uptrend.xyaxis") {
                Button { Task { await service.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
            }

            VStack(spacing: 0) {
                ForEach(service.symbols, id: \.self) { symbol in
                    StockRow(symbol: symbol, quote: service.quotes[symbol],
                             notFound: service.notFound.contains(symbol))
                    if symbol != service.symbols.last { Divider() }
                }
            }

            HStack {
                TextField("Add a ticker or name (e.g. MSFT, Dow Jones, Bitcoin)", text: $newSymbol)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                if adding {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Add", action: add).disabled(newSymbol.isEmpty)
                }
            }
            .task(id: newSymbol) {
                addError = nil
                let query = newSymbol.trimmingCharacters(in: .whitespaces)
                guard query.count >= 2 else { suggestions = []; return }
                try? await Task.sleep(for: .milliseconds(300)) // debounce typing
                guard !Task.isCancelled else { return }
                suggestions = await StocksService.search(query)
            }

            if !suggestions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(suggestions) { match in
                        SuggestionRow(match: match, alreadyAdded: service.symbols.contains(match.symbol)) {
                            add(match.symbol)
                        }
                    }
                }
                .background(.primary.opacity(0.05), in: .rect(cornerRadius: 6))
            }

            if let addError {
                Text(addError).font(.caption).foregroundStyle(.red)
            }

            HStack {
                if let error = service.lastError {
                    Text(error).foregroundStyle(.red)
                } else if let updated = service.lastUpdated {
                    Text("Updated \(updated.formatted(date: .omitted, time: .shortened)) · Yahoo Finance")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { service.start() }
    }

    private func add() { add(newSymbol) }

    private func add(_ text: String) {
        adding = true
        Task {
            let error = await service.add(text)
            adding = false
            addError = error
            if error == nil {
                newSymbol = ""
                suggestions = []
            }
        }
    }
}

private struct SuggestionRow: View {
    let match: SymbolMatch
    let alreadyAdded: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack {
            Text(match.symbol).font(.callout.weight(.semibold)).frame(width: 80, alignment: .leading)
            Text(match.name).font(.callout).lineLimit(1)
            Spacer()
            if alreadyAdded {
                Image(systemName: "checkmark").foregroundStyle(.secondary)
            } else {
                Text(match.type).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(hovering && !alreadyAdded ? Color.accentColor.opacity(0.15) : .clear, in: .rect(cornerRadius: 5))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if !alreadyAdded { action() } }
    }
}

private struct StockRow: View {
    let symbol: String
    let quote: StockQuote?
    let notFound: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(symbol).font(.body.weight(.semibold))
                Text(quote?.name ?? "—").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 110, alignment: .leading)

            if let quote {
                Sparkline(quote: quote).frame(height: 28)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(quote.price, format: .number.precision(.fractionLength(2)))
                        .font(.body)
                        .monospacedDigit()
                    Text(String(format: "%+.2f%%", quote.changePercent))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(quote.isUp ? Color.green : .red, in: .rect(cornerRadius: 4))
                }
                .frame(width: 72, alignment: .trailing)
            } else if notFound {
                Spacer()
                Text("Not found").font(.caption).foregroundStyle(.red)
            } else {
                Spacer()
                ProgressView().controlSize(.small)
            }

            if hovering || notFound {
                Button { StocksService.shared.remove(symbol) } label: { Image(systemName: "minus.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
            NSWorkspace.shared.open(URL(string: "https://finance.yahoo.com/quote/\(encoded)")!)
        }
    }
}
