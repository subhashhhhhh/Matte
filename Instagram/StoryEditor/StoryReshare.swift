import SwiftUI

/// A post or reel added to your story, as the phone app does it: the post is drawn as a card
/// (author and picture) into the story, and a tappable sticker of the same size sits over it
/// so viewers can open the post.
///
/// Instagram's web app can't do this (only the phone app can), so the request is written from
/// instagrapi's `photo_configure_to_story` (`medias`): `reshared_media_id` plus a `tap_models`
/// entry of type `feed_media` with the sticker's place as fractions of the story.
nonisolated struct StoryReshare: Equatable, Sendable {
    var mediaPk: String
    var ownerId: String
    var placement = Placement(x: 0.5, y: 0.5, width: 0.8, height: 0.5)

    /// Where the card sits on the finished story, as fractions of its width and height
    /// (centre, size), for the sticker's tap area.
    struct Placement: Equatable, Sendable {
        var x: Double, y: Double, width: Double, height: Double
    }
}

/// Draws a post as a story card: its author on top and its picture, on a rounded white card.
enum PostStoryCard {
    /// The card's width in pixels (the story is 1080 wide; it starts at about three quarters).
    static let width: CGFloat = 900

    /// Renders the card to a PNG (transparent outside its rounded corners), or nil if the
    /// post's picture can't be loaded.
    static func render(_ media: Media) async -> URL? {
        let first = media.children.first ?? media
        guard let url = first.image(minWidth: 1080),
              let photo = await ImagePipeline.shared.image(for: url, maxPixel: 1440) else { return nil }
        let avatar: CGImage? = if let a = media.user?.avatar { await ImagePipeline.shared.image(for: a, maxPixel: 160) } else { nil }
        let aspect = min(1.91, max(0.8, CGFloat(photo.width) / CGFloat(max(photo.height, 1))))
        let view = Card(photo: photo, avatar: avatar, username: media.user?.username ?? "",
                        isReel: media.productType == "clips", aspect: aspect)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let image = renderer.cgImage else { return nil }
        let out = CreateMedia.folder.appending(path: "reshare-\(UUID().uuidString).png")
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out : nil
    }

    private struct Card: View {
        let photo: CGImage
        let avatar: CGImage?
        let username: String
        let isReel: Bool
        let aspect: CGFloat

        var body: some View {
            VStack(spacing: 0) {
                HStack(spacing: 18) {
                    Group {
                        if let avatar {
                            Image(decorative: avatar, scale: 1).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Color.gray.opacity(0.3)
                        }
                    }
                    .frame(width: 76, height: 76)
                    .clipShape(Circle())
                    Text(username)
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(.black)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 28)
                .frame(height: 132)
                Image(decorative: photo, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: PostStoryCard.width, height: PostStoryCard.width / aspect)
                    .clipped()
                    .overlay(alignment: .topTrailing) {
                        if isReel {
                            Image(systemName: "play.fill")
                                .font(.system(size: 34, weight: .bold))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.4), radius: 6)
                                .padding(28)
                        }
                    }
            }
            .frame(width: PostStoryCard.width)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
            .environment(\.colorScheme, .light)
        }
    }
}
