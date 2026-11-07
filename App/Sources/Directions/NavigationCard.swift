import Routing
import SwiftUI

/// The card along the bottom while navigating: when you'd get there, what's left, and
/// the way out. The rest of the screen is the drag surface, so it stays small.
struct NavigationCard: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 16) {
            if model.isAtEndOfRoute {
                VStack(alignment: .leading, spacing: 2) {
                    Text("You've arrived")
                        .font(.title3.bold())
                        .accessibilityIdentifier("navigationHeadline")
                    if let name = model.directions.destination?.summary(in: model.campus)?.title {
                        Text(name).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    TimelineView(.everyMinute) { context in
                        Text("Arrive \(arrival(from: context.date), format: .dateTime.hour().minute())")
                            .font(.title3.bold().monospacedDigit())
                            .accessibilityIdentifier("navigationHeadline")
                    }
                    Text(remainingText)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("navigationRemaining")
                }
            }
            Spacer()
            Button(model.isAtEndOfRoute ? "Done" : "End") { model.endDirections() }
                .buttonStyle(.glassProminent)
                .tint(model.isAtEndOfRoute ? .accentColor : .red)
                .controlSize(.large)
                .accessibilityIdentifier("endNavigation")
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func arrival(from now: Date) -> Date {
        now.addingTimeInterval(model.navigationStatus?.secondsRemaining ?? 0)
    }

    private var remainingText: String {
        guard let status = model.navigationStatus else { return " " }
        let minutes = max(1, Int((status.secondsRemaining / 60).rounded()))
        return "\(minutes) min · \(Route.distanceText(status.distanceRemaining))"
    }
}
