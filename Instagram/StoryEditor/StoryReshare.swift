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

/// Draws a post as a story card, in the phone app's two looks (clicking the card switches):
/// the full card (author on top, picture, the caption under it on white) or the picture alone
/// with "@author" under it.
enum PostStoryCard {
    enum Style: Equatable, Sendable { case full, photo }

    /// The card's width in pixels (the story is 1080 wide; it starts at about five sixths).
    static let width: CGFloat = 900

    /// Renders the card to a PNG (transparent outside it), or nil if the picture can't be loaded.
    static func render(_ media: Media, style: Style) async -> URL? {
        let first = media.children.first ?? media
        guard let url = first.image(minWidth: 1080),
              let photo = await ImagePipeline.shared.image(for: url, maxPixel: 1440) else { return nil }
        let avatar: CGImage? = if let a = media.user?.avatar { await ImagePipeline.shared.image(for: a, maxPixel: 160) } else { nil }
        let aspect = min(1.91, max(0.8, CGFloat(photo.width) / CGFloat(max(photo.height, 1))))
        let username = media.user?.username ?? ""
        let caption = (media.caption ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let renderer: ImageRenderer<AnyView>
        switch style {
        case .full:
            renderer = ImageRenderer(content: AnyView(FullCard(photo: photo, avatar: avatar, username: username, caption: caption,
                                                               isReel: media.productType == "clips", aspect: aspect)))
        case .photo:
            renderer = ImageRenderer(content: AnyView(PhotoCard(photo: photo, username: username,
                                                                isReel: media.productType == "clips", aspect: aspect)))
        }
        renderer.scale = 1
        guard let image = renderer.cgImage else { return nil }
        let out = CreateMedia.folder.appending(path: "reshare-\(UUID().uuidString).png")
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out : nil
    }

    /// About two lines of caption at the card's size; longer ones end in "… more".
    static func shortCaption(_ caption: String, username: String) -> (text: String, more: Bool) {
        let budget = max(20, 78 - username.count)
        guard caption.count > budget else { return (caption, false) }
        var cut = String(caption.prefix(budget))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > budget / 2 {
            cut = String(cut[..<space])
        }
        return (cut + "…", true)
    }

    private struct ReelMark: View {
        var body: some View {
            Image(systemName: "play.fill")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 6)
                .padding(28)
        }
    }

    private struct FullCard: View {
        let photo: CGImage
        let avatar: CGImage?
        let username: String
        let caption: String
        let isReel: Bool
        let aspect: CGFloat

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
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
                    .overlay(alignment: .topTrailing) { if isReel { ReelMark() } }
                if !caption.isEmpty {
                    let short = PostStoryCard.shortCaption(caption, username: username)
                    (Text(username).fontWeight(.semibold) + Text(" " + short.text)
                        + (short.more ? Text(" more").foregroundColor(.gray) : Text("")))
                        .font(.system(size: 36))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 28)
                        .padding(.top, 26)
                        .padding(.bottom, 32)
                }
            }
            .foregroundStyle(.black)
            .frame(width: PostStoryCard.width, alignment: .leading)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
            .environment(\.colorScheme, .light)
        }
    }

    private struct PhotoCard: View {
        let photo: CGImage
        let username: String
        let isReel: Bool
        let aspect: CGFloat

        var body: some View {
            VStack(alignment: .leading, spacing: 22) {
                Image(decorative: photo, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: PostStoryCard.width, height: PostStoryCard.width / aspect)
                    .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
                    .overlay(alignment: .topTrailing) { if isReel { ReelMark() } }
                Text("@" + username)
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
                    .lineLimit(1)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 8)
            }
            .frame(width: PostStoryCard.width, alignment: .leading)
        }
    }
}
