import CampusGeo
import CampusModel
import MapKit
import SwiftUI

/// Bottom-sheet card for the selected place, like tapping a point of interest in Apple Maps.
struct PlaceCard: View {
    let model: AppModel

    var body: some View {
        if let place = model.selection, let summary = place.summary(in: model.campus) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(summary)
                    Button {
                        model.beginDirections()
                    } label: {
                        Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("directionsButton")
                    details(for: place)
                }
                .padding(20)
            }
            .id(place)  // a new place starts scrolled to the top
        }
    }

    private func header(_ summary: PlaceSummary) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.title).font(.title2.bold())
                    .accessibilityIdentifier("placeTitle")
                if !summary.subtitle.isEmpty {
                    Text(summary.subtitle).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Close", systemImage: "xmark") { model.select(nil) }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
        }
    }

    @ViewBuilder
    private func details(for place: Place) -> some View {
        switch place {
        case .campus(.door(let id)):
            if let door = model.campus.door(id: id), let building = model.campus.building(code: door.building) {
                DoorDetails(door: door, building: building, model: model)
            }
        case .campus(.building(let code)):
            if let building = model.campus.building(code: code) {
                BuildingDetails(building: building, model: model)
            }
        case .mapItem(let item):
            MapItemDetails(item: item)
        case .droppedPin(let coordinate), .currentLocation(let coordinate):
            DroppedPinDetails(coordinate: coordinate)
        }
    }
}

private struct DoorDetails: View {
    let door: Door
    let building: Building
    let model: AppModel

    var body: some View {
        PhotoCarousel(paths: door.photos, bundleURL: model.bundleURL)
        FactList {
            Fact(label: "Type", value: door.kind.label)
            Fact(label: "Floor", value: door.level ?? "Not known yet")
            Fact(label: "Step-free access", value: door.accessible.map { $0 ? "Yes" : "No" } ?? "Not known yet")
        }
        Button {
            model.select(.campus(.building(code: building.code)), focus: true)
        } label: {
            PlaceRow(title: building.name, subtitle: "Building · \(building.code)", systemImage: "building.2.fill")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        SourceNote(verified: door.verified)
    }
}

private struct BuildingDetails: View {
    let building: Building
    let model: AppModel

    var body: some View {
        FactList {
            Fact(label: "Code", value: building.code)
            if !building.displayAliases.isEmpty {
                Fact(label: "Also called", value: building.displayAliases.joined(separator: ", "))
            }
            Fact(label: "Floors", value: building.levelsEstimated ? "Not known yet" : building.floorSummary)
        }
        let doors = model.campus.doors(of: building)
        VStack(alignment: .leading, spacing: 10) {
            Text(doors.isEmpty ? "No entrances mapped yet" : "Entrances (\(doors.count))").font(.headline)
            ForEach(doors) { door in
                Button {
                    model.select(.campus(.door(id: door.id)), focus: true)
                } label: {
                    PlaceRow(title: door.name, subtitle: door.kind.label, systemImage: "door.left.hand.open")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
        SourceNote(verified: !doors.isEmpty && doors.allSatisfy(\.verified))
    }
}

private struct MapItemDetails: View {
    let item: MapItemPlace

    var body: some View {
        if let address = item.address {
            FactList { Fact(label: "Address", value: address) }
        }
        Button("Open in Apple Maps", systemImage: "map") {
            let location = CLLocation(latitude: item.coordinate.latitude, longitude: item.coordinate.longitude)
            let mapItem = MKMapItem(location: location, address: nil)
            mapItem.name = item.name
            mapItem.openInMaps()
        }
        .buttonStyle(.glass)
    }
}

private struct DroppedPinDetails: View {
    let coordinate: GeoCoordinate

    var body: some View {
        FactList {
            Fact(label: "Coordinates", value: coordinate.formatted)
        }
        Button("Copy Coordinates", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = coordinate.formatted
        }
        .buttonStyle(.glass)
    }
}

// MARK: Building blocks

private struct FactList<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.tertiary, in: .rect(cornerRadius: 14))
    }
}

private struct Fact: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Where the data came from, and whether anyone has checked it on site yet.
private struct SourceNote: View {
    let verified: Bool

    var body: some View {
        Label(
            verified ? "Checked on site · Map data © OpenStreetMap contributors"
                : "Not yet checked on site · Map data © OpenStreetMap contributors",
            systemImage: verified ? "checkmark.seal" : "info.circle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

extension Building {
    /// Aliases worth showing: search keeps spelling variants ("Math & Computer",
    /// "Math and Computer") that would read as repetition on a card.
    var displayAliases: [String] {
        var seen: Set<String> = [Self.normalized(name)]
        return aliases.filter { seen.insert(Self.normalized($0)).inserted }
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "&", with: "and").filter { $0.isLetter || $0.isNumber }
    }
}

extension Door.Kind {
    var label: String {
        switch self {
        case .main: "Main entrance"
        case .entrance: "Entrance"
        case .exit: "Exit only"
        case .stairwell: "Stairwell door"
        }
    }
}
