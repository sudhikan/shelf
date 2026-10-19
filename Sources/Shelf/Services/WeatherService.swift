import CoreLocation
import MapKit
import Foundation

struct WeatherPlace: Codable, Hashable, Identifiable {
    var id: String { "\(latitude),\(longitude)" }
    var name: String
    var latitude: Double
    var longitude: Double
}

struct WeatherReport {
    struct Hour: Identifiable { let id: Date; let temp: Double; let code: Int; let isDay: Bool; let rainChance: Int }
    struct Day: Identifiable { let id: Date; let high: Double; let low: Double; let code: Int; let rainChance: Int }

    let temperature: Double
    let feelsLike: Double
    let code: Int
    let isDay: Bool
    let humidity: Int
    let wind: Double
    let hours: [Hour]
    let days: [Day]
    let sunrise: Date?
    let sunset: Date?
}

/// Forecasts from Open-Meteo (free, no key). Apple's WeatherKit needs a paid developer
/// account, so this is the one non-Apple source besides Stocks. Location comes from CoreLocation.
@Observable
final class WeatherService: NSObject, CLLocationManagerDelegate {
    static let shared = WeatherService()
    private static let placeKey = "weatherPlace"
    private static let useCurrentKey = "weatherUseCurrentLocation"

    private(set) var report: WeatherReport?
    private(set) var placeName = "—"
    private(set) var lastError: String?
    private(set) var locationDenied = false

    /// True: follow the Mac's location. False: use `savedPlace`.
    private(set) var useCurrentLocation: Bool
    private(set) var savedPlace: WeatherPlace?

    @ObservationIgnored private let locationManager = CLLocationManager()
    @ObservationIgnored private var currentCoordinate: CLLocationCoordinate2D?
    @ObservationIgnored private var started = false

    var usesFahrenheit: Bool { Locale.current.measurementSystem == .us }

    private override init() {
        useCurrentLocation = UserDefaults.standard.object(forKey: Self.useCurrentKey) as? Bool ?? true
        if let data = UserDefaults.standard.data(forKey: Self.placeKey) {
            savedPlace = try? JSONDecoder().decode(WeatherPlace.self, from: data)
        }
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func start() {
        guard !started else { return }
        started = true
        if useCurrentLocation { requestLocation() }
        Task {
            while !Task.isCancelled {
                if DockStore.shared.hasWidget(.weather) { await refresh() }
                try? await Task.sleep(for: .seconds(15 * 60))
            }
        }
    }

    func useCurrent() {
        useCurrentLocation = true
        UserDefaults.standard.set(true, forKey: Self.useCurrentKey)
        requestLocation()
    }

    func use(_ place: WeatherPlace) {
        savedPlace = place
        useCurrentLocation = false
        UserDefaults.standard.set(false, forKey: Self.useCurrentKey)
        UserDefaults.standard.set(try? JSONEncoder().encode(place), forKey: Self.placeKey)
        Task { await refresh() }
    }

    private func requestLocation() {
        switch locationManager.authorizationStatus {
        case .notDetermined: locationManager.requestWhenInUseAuthorization()
        case .denied, .restricted: locationDenied = true
        default: locationManager.requestLocation()
        }
    }

    // MARK: Fetching

    func refresh() async {
        let place: WeatherPlace?
        if useCurrentLocation, let c = currentCoordinate {
            place = WeatherPlace(name: placeName, latitude: c.latitude, longitude: c.longitude)
        } else {
            place = savedPlace
        }
        guard let place else { return }
        if !useCurrentLocation { placeName = place.name }
        do {
            report = try await Self.fetch(place, fahrenheit: usesFahrenheit)
            lastError = nil
        } catch {
            lastError = "Couldn't load weather"
        }
    }

    private nonisolated static func fetch(_ place: WeatherPlace, fahrenheit: Bool) async throws -> WeatherReport {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: "\(place.latitude)"),
            .init(name: "longitude", value: "\(place.longitude)"),
            .init(name: "current", value: "temperature_2m,apparent_temperature,weather_code,is_day,relative_humidity_2m,wind_speed_10m"),
            .init(name: "hourly", value: "temperature_2m,weather_code,is_day,precipitation_probability"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "7"),
            .init(name: "timeformat", value: "unixtime"),
            .init(name: "temperature_unit", value: fahrenheit ? "fahrenheit" : "celsius"),
            .init(name: "wind_speed_unit", value: fahrenheit ? "mph" : "kmh"),
        ]
        let (data, _) = try await URLSession.shared.data(from: c.url!)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = root["current"] as? [String: Any],
              let hourly = root["hourly"] as? [String: Any],
              let daily = root["daily"] as? [String: Any] else { throw URLError(.cannotParseResponse) }

        func doubles(_ d: [String: Any], _ k: String) -> [Double] { (d[k] as? [Any] ?? []).map { ($0 as? NSNumber)?.doubleValue ?? 0 } }
        func ints(_ d: [String: Any], _ k: String) -> [Int] { (d[k] as? [Any] ?? []).map { ($0 as? NSNumber)?.intValue ?? 0 } }
        func num(_ k: String) -> Double { (current[k] as? NSNumber)?.doubleValue ?? 0 }

        let now = Date.now
        let hTimes = ints(hourly, "time"), hTemps = doubles(hourly, "temperature_2m")
        let hCodes = ints(hourly, "weather_code"), hDay = ints(hourly, "is_day"), hRain = ints(hourly, "precipitation_probability")
        let hours = hTimes.indices.compactMap { i -> WeatherReport.Hour? in
            let date = Date(timeIntervalSince1970: TimeInterval(hTimes[i]))
            guard date > now.addingTimeInterval(-3600), i < hTemps.count, i < hCodes.count else { return nil }
            return .init(id: date, temp: hTemps[i], code: hCodes[i], isDay: (hDay.indices.contains(i) ? hDay[i] : 1) == 1,
                         rainChance: hRain.indices.contains(i) ? hRain[i] : 0)
        }.prefix(24)

        let dTimes = ints(daily, "time"), highs = doubles(daily, "temperature_2m_max"), lows = doubles(daily, "temperature_2m_min")
        let dCodes = ints(daily, "weather_code"), dRain = ints(daily, "precipitation_probability_max")
        let days = dTimes.indices.compactMap { i -> WeatherReport.Day? in
            guard i < highs.count, i < lows.count, i < dCodes.count else { return nil }
            return .init(id: Date(timeIntervalSince1970: TimeInterval(dTimes[i])), high: highs[i], low: lows[i],
                         code: dCodes[i], rainChance: dRain.indices.contains(i) ? dRain[i] : 0)
        }
        let sunrise = ints(daily, "sunrise").first.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let sunset = ints(daily, "sunset").first.map { Date(timeIntervalSince1970: TimeInterval($0)) }

        return WeatherReport(temperature: num("temperature_2m"), feelsLike: num("apparent_temperature"),
                             code: Int(num("weather_code")), isDay: num("is_day") == 1,
                             humidity: Int(num("relative_humidity_2m")), wind: num("wind_speed_10m"),
                             hours: Array(hours), days: days, sunrise: sunrise, sunset: sunset)
    }

    /// City search for picking a location by name.
    nonisolated static func searchPlaces(_ query: String) async -> [WeatherPlace] {
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [.init(name: "name", value: query), .init(name: "count", value: "6")]
        guard let (data, _) = try? await URLSession.shared.data(from: c.url!),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { r in
            guard let name = r["name"] as? String,
                  let lat = (r["latitude"] as? NSNumber)?.doubleValue,
                  let lon = (r["longitude"] as? NSNumber)?.doubleValue else { return nil }
            let detail = [r["admin1"] as? String, r["country"] as? String].compactMap { $0 }.joined(separator: ", ")
            return WeatherPlace(name: detail.isEmpty ? name : "\(name), \(detail)", latitude: lat, longitude: lon)
        }
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            let service = WeatherService.shared
            service.locationDenied = status == .denied || status == .restricted
            if status == .authorized || status == .authorizedAlways, service.useCurrentLocation {
                service.locationManager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let coordinate = location.coordinate
        Task { @MainActor in
            let service = WeatherService.shared
            service.currentCoordinate = coordinate
            service.placeName = await Self.name(for: location) ?? "Current Location"
            await service.refresh()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            let service = WeatherService.shared
            if service.savedPlace == nil { service.lastError = "Couldn't find your location — pick a city instead" }
            await service.refresh()
        }
    }

    private nonisolated static func name(for location: CLLocation) async -> String? {
        guard let request = MKReverseGeocodingRequest(location: location),
              let item = try? await request.mapItems.first else { return nil }
        return item.addressRepresentations?.cityName ?? item.name
    }
}

/// WMO weather codes → SF Symbols and descriptions.
enum WeatherCode {
    static func symbol(_ code: Int, isDay: Bool = true) -> String {
        switch code {
        case 0: isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51, 53, 55, 56, 57: "cloud.drizzle.fill"
        case 61, 63, 66, 80, 81: "cloud.rain.fill"
        case 65, 67, 82: "cloud.heavyrain.fill"
        case 71, 73, 75, 77, 85, 86: "cloud.snow.fill"
        case 95, 96, 99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }

    static func description(_ code: Int) -> String {
        switch code {
        case 0: "Clear"
        case 1: "Mostly Clear"
        case 2: "Partly Cloudy"
        case 3: "Cloudy"
        case 45, 48: "Fog"
        case 51, 53, 55: "Drizzle"
        case 56, 57: "Freezing Drizzle"
        case 61, 80: "Light Rain"
        case 63, 81: "Rain"
        case 65, 82: "Heavy Rain"
        case 66, 67: "Freezing Rain"
        case 71, 85: "Light Snow"
        case 73, 75, 86: "Snow"
        case 77: "Snow Grains"
        case 95: "Thunderstorms"
        case 96, 99: "Thunderstorms with Hail"
        default: "—"
        }
    }
}
