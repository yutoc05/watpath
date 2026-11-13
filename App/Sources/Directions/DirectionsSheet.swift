import CampusModel
import Routing
import SwiftUI

/// The sheet through the directions flow: where are you, then which route.
struct DirectionsSheet: View {
    static let promptHeight = 270.0
    static let promptDetent = PresentationDetent.height(promptHeight)
    static let routesPeekHeight = 210.0
    static let routesPeek = PresentationDetent.height(routesPeekHeight)

    let model: AppModel
    /// The list last shown, which stays while the sheet slides away for navigation.
    @State private var shownRoutes: (routes: [Route], selected: Route.ID)?

    var body: some View {
        switch model.directions.step {
        case .routes(let routes, let selected):
            RouteList(model: model, routes: routes, selected: selected)
                .onAppear { shownRoutes = (routes, selected) }
                .onChange(of: selected) { shownRoutes = (routes, selected) }
        case .navigating, .arrived:
            if let shownRoutes {
                RouteList(model: model, routes: shownRoutes.routes, selected: shownRoutes.selected)
            }
        case .noRoutes:
            NoRoutes(model: model)
        case .findingRoutes:
            ProgressView("Finding routes")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            OriginPrompt(model: model)
        }
    }
}

/// The header each step shares: where you're going, and the way out.
private struct DirectionsHeader: View {
    let model: AppModel
    var subtitle: String?

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(destinationTitle)
                    .font(.title3.bold())
                    .lineLimit(2)
                    .accessibilityIdentifier("directionsTitle")
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityIdentifier("directionsSubtitle")
                }
            }
            Spacer()
            Button("Close Directions", systemImage: "xmark") { model.endDirections() }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
        }
    }

    private var destinationTitle: String {
        let name = model.directions.destination?.summary(in: model.campus)?.title
        return name.map { "To \($0)" } ?? "Directions"
    }
}

/// "I'm in the PATH" or "I'm Outside".
private struct OriginPrompt: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DirectionsHeader(model: model, subtitle: "Where are you starting from?")
            choice("I'm in the PATH", detail: "Drop a pin on where you are", systemImage: "building.2.fill", id: "inThePathButton") {
                model.chooseInThePath()
            }
            choice("I'm Outside", detail: "Use your location, or search for a place", systemImage: "figure.walk", id: "outsideButton") {
                model.chooseOutside()
            }
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func choice(_ title: String, detail: String, systemImage: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            PlaceRow(title: title, subtitle: detail, systemImage: systemImage)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.fill.tertiary, in: .rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

private struct NoRoutes: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DirectionsHeader(model: model)
            Text(message)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("noRoutesMessage")
            Button("Choose Another Start") { model.backInDirections() }
                .buttonStyle(.glass)
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var message: String {
        if model.directions.origin == model.directions.destination {
            return "You're already there."
        }
        return "That's too far from main campus for WatPath to find a way."
    }
}

/// The routes on offer, scrolling under a fixed header so the card can stay small and
/// leave the map in view. Picking one shows it on the map.
private struct RouteList: View {
    let model: AppModel
    let routes: [Route]
    let selected: Route.ID

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                DirectionsHeader(model: model, subtitle: originTitle)
                Button("Change Start", systemImage: "chevron.left") { model.backInDirections() }
                    .font(.subheadline)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(routes) { route in
                        RouteRow(route: route, isSelected: route.id == selected) {
                            model.selectRoute(route.id)
                        } start: {
                            model.startRoute(route.id)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .scrollIndicators(.visible)
            .scrollIndicatorsFlash(onAppear: true)
        }
    }

    private var originTitle: String? {
        model.directions.origin?.summary(in: model.campus).map { "From \($0.title)" }
    }
}

private struct RouteRow: View {
    /// Room on the row's last lines for the Start button.
    private static let startButtonWidth = 84.0

    let route: Route
    let isSelected: Bool
    let select: () -> Void
    let start: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(route.label.rawValue).font(.headline)
                    Spacer()
                    Text(route.durationText).font(.title3.bold().monospacedDigit())
                }
                InsideBar(fraction: route.insideFraction)
                HStack {
                    Text("\(route.percentInside)% inside")
                    Spacer()
                    Text(Route.distanceText(route.distance)).monospacedDigit()
                }
                .font(.subheadline)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Inside \(Route.distanceText(route.insideLength)) · Outside \(Route.distanceText(route.outsideLength))")
                    if !route.detailText.isEmpty {
                        Text(route.detailText).lineLimit(1)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.trailing, Self.startButtonWidth)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.tertiary, in: .rect(cornerRadius: 16))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 16).strokeBorder(.tint, lineWidth: 2)
                }
            }
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(route.accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("route-\(route.id)")
        .overlay(alignment: .bottomTrailing) {
            Button("Start", action: start)
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("start-\(route.id)")
                .accessibilityLabel("Start \(route.label.rawValue)")
                .padding(12)
        }
    }
}

/// How much of a route is indoors, as a small bar.
private struct InsideBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.fill.secondary)
                Capsule().fill(.tint).frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

extension Route {
    var durationText: String {
        "\(max(1, Int((seconds / 60).rounded()))) min"
    }

    /// Never rounds up to 100, which would claim there's no time outside at all.
    var percentInside: Int {
        outsideLength == 0 ? 100 : min(99, Int((insideFraction * 100).rounded()))
    }

    /// The buildings it passes through and any floors to change.
    var detailText: String {
        var parts: [String] = []
        if !buildings.isEmpty { parts.append("Via \(buildings.joined(separator: ", "))") }
        let floors = Int(storeys.rounded(.up))
        if floors > 0 { parts.append(floors == 1 ? "1 floor" : "\(floors) floors") }
        return parts.joined(separator: " · ")
    }

    var accessibilityText: String {
        "\(label.rawValue), \(durationText), \(Route.distanceText(distance)), \(percentInside)% inside"
    }

    static func distanceText(_ meters: Double) -> String {
        if meters < 1_000 { return "\(Int((meters / 10).rounded()) * 10) m" }
        return String(format: "%.1f km", meters / 1_000)
    }
}
