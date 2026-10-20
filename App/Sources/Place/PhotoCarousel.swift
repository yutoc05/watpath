import SwiftUI
import UIKit

/// Swipeable door photos from the campus bundle, or a placeholder until someone
/// photographs the door.
struct PhotoCarousel: View {
    let paths: [String]
    let bundleURL: URL

    var body: some View {
        Group {
            if paths.isEmpty {
                ContentUnavailableView {
                    Label("No photos yet", systemImage: "camera")
                } description: {
                    Text("Photos are added as doors are surveyed.")
                }
            } else {
                TabView {
                    ForEach(paths, id: \.self) { path in
                        BundlePhoto(url: bundleURL.appendingPathComponent(path))
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: paths.count > 1 ? .always : .never))
            }
        }
        .frame(height: 200)
        .frame(maxWidth: .infinity)
        .background(.fill.tertiary)
        .clipShape(.rect(cornerRadius: 14))
    }
}

private struct BundlePhoto: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: url) {
            // Decode off the main thread; full-size photos take a while.
            image = await Task.detached(priority: .userInitiated) { [url] in
                UIImage(contentsOfFile: url.path)?.preparingForDisplay()
            }.value
        }
    }
}
