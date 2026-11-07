import CampusModel
import SwiftUI

/// Loads the campus bundle once at launch.
struct RootView: View {
    @State private var model: Result<AppModel, any Error> = Result {
        guard let url = Bundle.main.url(forResource: "CampusBundle", withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return AppModel(campus: try CampusBundle.load(from: url), bundleURL: url)
    }

    var body: some View {
        switch model {
        case .success(let model):
            HomeView(model: model)
        case .failure(let error):
            ContentUnavailableView("Campus map unavailable", systemImage: "map", description: Text(error.localizedDescription))
        }
    }
}

struct HomeView: View {
    /// Right below the search field.
    private static let modePickerTop = 74.0
    /// On the search field's line, which is free throughout directions.
    private static let modePickerTopInDirections = 13.0

    @Bindable var model: AppModel
    @State private var cardDetent = PresentationDetent.height(AppModel.cardPeekHeight)
    @State private var screenHeight = 844.0

    var body: some View {
        ZStack {
            CampusMapView(model: model)
                .ignoresSafeArea()
            if model.activity == .pickingLocation {
                LocationPickerOverlay(model: model)
            }
        }
        .overlay(alignment: .top) {
            if model.activity == .browsing {
                SearchField { model.beginSearch() }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topLeading) {
            if model.activity == .browsing || model.activity == .directions {
                MapModePicker(mode: $model.mapMode)
                    .padding(.leading, 16)
                    .padding(.top, model.activity == .directions ? Self.modePickerTopInDirections : Self.modePickerTop)
            }
        }
        .overlay(alignment: .bottom) {
            if model.activity == .navigating {
                NavigationCard(model: model)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay {
            if model.activity == .searching {
                SearchPanel(model: model)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(isPresented: isShowingSheet) {
            Group {
                if model.activity == .directions {
                    DirectionsSheet(model: model)
                } else {
                    PlaceCard(model: model)
                }
            }
            .presentationDetents(detents, selection: detent)
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            .presentationDragIndicator(.visible)
            .presentationContentInteraction(model.routePreview == nil ? .automatic : .scrolls)
            .interactiveDismissDisabled()
        }
        .animation(.snappy, value: model.activity)
        .onChange(of: model.activity) { _, activity in
            // Left alone, the keyboard stays up until the search has slid away, nearly a
            // second later.
            if activity != .searching { UIApplication.shared.dismissKeyboard() }
        }
        .onGeometryChange(for: Double.self) { proxy in
            proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
        } action: { screenHeight = $0 }
        .onChange(of: detent.wrappedValue, initial: true) { updateCardHeight() }
        .onChange(of: screenHeight) { updateCardHeight() }
        .onChange(of: model.selection == nil) { _, isEmpty in
            // A new selection always opens the card at its smallest size.
            if isEmpty { cardDetent = .height(AppModel.cardPeekHeight) }
        }
        .task { model.requestLocationPermission() }
    }

    private func updateCardHeight() {
        model.cardHeight = switch detent.wrappedValue {
        case .medium: screenHeight / 2
        case .large: screenHeight
        case DirectionsSheet.routesPeek: DirectionsSheet.routesPeekHeight
        case DirectionsSheet.promptDetent: DirectionsSheet.promptHeight
        default: AppModel.cardPeekHeight
        }
    }

    private var detents: Set<PresentationDetent> {
        switch model.directions.step {
        case .idle: [.height(AppModel.cardPeekHeight), .medium, .large]
        case .routes: [DirectionsSheet.routesPeek, .medium, .large]
        default: [DirectionsSheet.promptDetent]
        }
    }

    /// The sheet's size. It stays what the user last made it for as long as that's an
    /// option, and otherwise opens at a size that suits what's in it.
    private var detent: Binding<PresentationDetent> {
        Binding(
            get: {
                if detents.contains(cardDetent) { return cardDetent }
                if case .routes = model.directions.step { return .medium }
                return model.directions.isActive ? DirectionsSheet.promptDetent : .height(AppModel.cardPeekHeight)
            },
            set: { cardDetent = $0 }
        )
    }

    /// The sheet shows while browsing with something selected, and through directions,
    /// other than while the map or the search takes over. Dragging can only resize it:
    /// its X closes it. SwiftUI still reports the sheet closing when something else takes
    /// over, which needs no answer here.
    private var isShowingSheet: Binding<Bool> {
        Binding(
            get: { model.activity == .directions || (model.selection != nil && model.activity == .browsing) },
            set: { _ in }
        )
    }
}
