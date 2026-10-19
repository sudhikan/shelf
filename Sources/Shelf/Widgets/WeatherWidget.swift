import SwiftUI

struct WeatherCompact: View {
    @AppStorage(SettingsKey.tileSize) private var tileSize = SettingsDefault.tileSize
    private var service: WeatherService { .shared }

    var body: some View {
        Group {
            if let report = service.report {
                HStack(spacing: 6) {
                    Image(systemName: WeatherCode.symbol(report.code, isDay: report.isDay))
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: tileSize * 0.42))
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(Int(report.temperature.rounded()))°")
                            .font(.system(size: tileSize * 0.34, weight: .medium))
                            .monospacedDigit()
                        Text(service.placeName)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: tileSize * 1.3, alignment: .leading)
                }
            } else {
                Image(systemName: "cloud.sun.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: tileSize * 0.42))
                    .frame(width: tileSize * 0.8)
            }
        }
        .onAppear { service.start() }
    }
}

struct WeatherExpanded: View {
    @State private var query = ""
    @State private var results: [WeatherPlace] = []
    @State private var choosingPlace = false
    private var service: WeatherService { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WidgetHeader(title: service.placeName, symbol: service.useCurrentLocation ? "location.fill" : "mappin.and.ellipse") {
                Button(choosingPlace ? "Done" : "Change") { choosingPlace.toggle() }
                    .buttonStyle(.link)
            }

            if choosingPlace {
                placePicker
            } else if let report = service.report {
                current(report)
                Divider()
                hourly(report)
                Divider()
                daily(report)
            } else if service.locationDenied || service.lastError != nil {
                Text(service.lastError ?? "Location access is off. Pick a city instead.")
                    .foregroundStyle(.secondary)
                Button("Pick a City") { choosingPlace = true }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            }

            Text("Open-Meteo").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 360)
        .onAppear { service.start() }
    }

    private func current(_ r: WeatherReport) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: WeatherCode.symbol(r.code, isDay: r.isDay))
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 44))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Int(r.temperature.rounded()))°").font(.system(size: 38, weight: .light)).monospacedDigit()
                Text(WeatherCode.description(r.code)).font(.callout)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("Feels \(Int(r.feelsLike.rounded()))°")
                Text("Humidity \(r.humidity)%")
                Text("Wind \(Int(r.wind.rounded())) \(service.usesFahrenheit ? "mph" : "km/h")")
                if let today = r.days.first {
                    Text("H \(Int(today.high.rounded()))°  L \(Int(today.low.rounded()))°")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func hourly(_ r: WeatherReport) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(r.hours.prefix(16)) { hour in
                    VStack(spacing: 4) {
                        Text(hour.id, format: .dateTime.hour()).font(.caption2).foregroundStyle(.secondary)
                        Image(systemName: WeatherCode.symbol(hour.code, isDay: hour.isDay))
                            .symbolRenderingMode(.multicolor)
                            .frame(height: 18)
                        Text("\(Int(hour.temp.rounded()))°").font(.caption).monospacedDigit()
                        Text(hour.rainChance >= 20 ? "\(hour.rainChance)%" : " ")
                            .font(.system(size: 9)).foregroundStyle(.cyan)
                    }
                }
            }
        }
    }

    private func daily(_ r: WeatherReport) -> some View {
        let low = r.days.map(\.low).min() ?? 0, high = r.days.map(\.high).max() ?? 1
        return VStack(spacing: 6) {
            ForEach(r.days) { day in
                HStack(spacing: 10) {
                    Text(Calendar.current.isDateInToday(day.id) ? "Today" : day.id.formatted(.dateTime.weekday(.abbreviated)))
                        .frame(width: 44, alignment: .leading)
                    Image(systemName: WeatherCode.symbol(day.code))
                        .symbolRenderingMode(.multicolor)
                        .frame(width: 22)
                    Text(day.rainChance >= 20 ? "\(day.rainChance)%" : "")
                        .font(.caption2).foregroundStyle(.cyan).frame(width: 30, alignment: .leading)
                    Text("\(Int(day.low.rounded()))°").foregroundStyle(.secondary).monospacedDigit().frame(width: 32, alignment: .trailing)
                    TemperatureBar(low: day.low, high: day.high, rangeLow: low, rangeHigh: high)
                    Text("\(Int(day.high.rounded()))°").monospacedDigit().frame(width: 32, alignment: .trailing)
                }
                .font(.callout)
            }
        }
    }

    private var placePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                service.useCurrent()
                choosingPlace = false
            } label: {
                Label("Use My Current Location", systemImage: "location.fill")
            }
            .buttonStyle(.borderless)
            if service.locationDenied {
                Text("Location access is off for Shelf in System Settings → Privacy & Security → Location Services.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextField("Search for a city", text: $query)
                .textFieldStyle(.roundedBorder)
            ForEach(results) { place in
                Button {
                    service.use(place)
                    choosingPlace = false
                    query = ""
                } label: {
                    Text(place.name).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
            }
        }
        .task(id: query) {
            guard query.count >= 2 else { results = []; return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            results = await WeatherService.searchPlaces(query)
        }
    }
}

private struct TemperatureBar: View {
    let low, high, rangeLow, rangeHigh: Double

    var body: some View {
        GeometryReader { geo in
            let span = max(rangeHigh - rangeLow, 1)
            let x = (low - rangeLow) / span * geo.size.width
            let w = max((high - low) / span * geo.size.width, 4)
            Capsule().fill(.primary.opacity(0.1))
            Capsule()
                .fill(LinearGradient(colors: [.cyan, .yellow, .orange], startPoint: .leading, endPoint: .trailing))
                .frame(width: w)
                .offset(x: x)
        }
        .frame(height: 5)
    }
}
