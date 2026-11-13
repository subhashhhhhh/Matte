import SwiftUI

/// Which photo of a carousel is showing, by post pk, shared by every view of the post: page it
/// in the feed card and it opens (and the photo flies) on that photo; page it open and the card
/// shows that photo when you come back. Only posts paged past the first are kept.
@Observable
final class CarouselPages {
    static let shared = CarouselPages()
    private var pages: [String: Int] = [:]

    func page(_ pk: String) -> Int { pages[pk] ?? 0 }

    func set(_ page: Int, for pk: String) {
        if page <= 0 { pages[pk] = nil } else if pages[pk] != page { pages[pk] = page }
    }
}

extension Media {
    /// The carousel photo showing now (`CarouselPages`), or the post itself.
    var shownItem: Media {
        guard !children.isEmpty else { return self }
        return children[min(CarouselPages.shared.page(pk), children.count - 1)]
    }
}

/// A carousel you swipe through like on a phone: two fingers on the trackpad (or a Magic
/// Mouse) slide the photos along and settle on one. A paging horizontal scroll view, so
/// vertical scrolling still goes to the page around it.
struct CarouselPager<Content: View>: View {
    let count: Int
    @Binding var page: Int
    @ViewBuilder let content: (Int) -> Content
    @State private var position: Int?

    init(count: Int, page: Binding<Int>, @ViewBuilder content: @escaping (Int) -> Content) {
        self.count = count
        _page = page
        self.content = content
        _position = State(initialValue: page.wrappedValue)
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(0..<count, id: \.self) { i in
                        content(i)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                            .id(i)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.never)
            .scrollPosition(id: $position)
            .onAppear { if position != page { position = page } }
            .onChange(of: position) { if let position, position != page { page = position } }
            .onChange(of: page) {
                guard position != page else { return }
                withAnimation(Motion.reduced ? nil : .smooth(duration: 0.3)) { position = page }
            }
        }
    }
}
