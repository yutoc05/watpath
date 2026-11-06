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
            if model.activity == .browsing {
                MapModePicker(mode: $model.mapMode)
                    .padding(.leading, 16)
                    .padding(.top, 74)
            }
        }
        .overlay {
            if model.activity == .searching {
                SearchPanel(model: model)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(isPresented: isShowingCard) {
            PlaceCard(model: model)
                .presentationDetents([.height(AppModel.cardPeekHeight), .medium, .large], selection: $cardDetent)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationDragIndicator(.visible)
        }
        .animation(.snappy, value: model.activity)
        .onGeometryChange(for: Double.self) { proxy in
            proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
        } action: { screenHeight = $0 }
        .onChange(of: cardDetent, initial: true) { updateCardHeight() }
        .onChange(of: screenHeight) { updateCardHeight() }
        .onChange(of: model.selection == nil) { _, isEmpty in
            // A new selection always opens the card at its smallest size.
            if isEmpty { cardDetent = .height(AppModel.cardPeekHeight) }
        }
        .task { model.requestLocationPermission() }
    }

    private func updateCardHeight() {
        model.cardHeight = switch cardDetent {
        case .medium: screenHeight / 2
        case .large: screenHeight
        default: AppModel.cardPeekHeight
        }
    }

    /// The card shows whenever something is selected and the user isn't searching
    /// or picking; swiping it away clears the selection.
    private var isShowingCard: Binding<Bool> {
        Binding(
            get: { model.selection != nil && model.activity == .browsing },
            set: { isPresented in if !isPresented { model.select(nil) } }
        )
    }
}
