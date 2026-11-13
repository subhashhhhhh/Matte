import Foundation

/// Saving into your collections, as instagram.com's save button does when you rest on it
/// (recorded 2026-11-13): the list of collections, adding a post to one (the web app saves the
/// post first if it isn't), taking it out of one, and a new collection with the post in it.
extension IGClient {
    nonisolated static let collectionDocIds: [String: String] = [
        "PolarisSavedCollectionPickerQuery": "29115677831365401",
        "PolarisSavedCollectionPickerPaginationQuery": "28466833206340367",
        "usePolarisMediaSaveToCollectionAddMediaMutation": "39663440886576281",
        "PolarisAPIEditCollectionRemoveMediaMutation": "27067931769494869",
        "PolarisAPICreateCollectionMutation": "27305499509043563",
    ]

    private func collectionDoc(_ name: String) -> String? { knownOperations()[name] ?? Self.collectionDocIds[name] }

    /// Your collections, newest first (the picker's own query, 20 at a time).
    func collectionPicker() async throws -> [SavedCollection] {
        await prepare()
        var out: [SavedCollection] = []
        var cursor: String?
        for _ in 0..<10 {
            let name = cursor == nil ? "PolarisSavedCollectionPickerQuery" : "PolarisSavedCollectionPickerPaginationQuery"
            var vars: [String: JSON] = ["first": 20]
            if let cursor { vars["after"] = .string(cursor) }
            let data = try await graphQL(name, variables: .object(vars), docId: collectionDoc(name))
            let conn = data["viewer"]["media_collections"]
            for edge in conn["edges"].array {
                let n = edge["node"]
                guard let id = Parser.idString(n["collection_id"]), let title = n["collection_name"].string else { continue }
                out.append(SavedCollection(id: id, name: title, count: nil,
                                           cover: Parser.media(n["cover_media"])?.image(minWidth: 120)))
            }
            guard conn["page_info"]["has_next_page"].bool == true, let next = conn["page_info"]["end_cursor"].string else { break }
            cursor = next
        }
        return out
    }

    func addToCollection(_ collectionId: String, media m: Media) async throws {
        await prepare()
        let name = "usePolarisMediaSaveToCollectionAddMediaMutation"
        _ = try await graphQL(name, variables: ["input": mutationInput([
            "collection_id": .string(collectionId), "media_id": .string(m.pk),
        ])], docId: collectionDoc(name))
    }

    func removeFromCollection(_ collectionId: String, media m: Media) async throws {
        await prepare()
        let name = "PolarisAPIEditCollectionRemoveMediaMutation"
        _ = try await graphQL(name, variables: ["input": mutationInput([
            "collection_id": .string(collectionId), "media_id": .string(m.pk),
        ])], docId: collectionDoc(name))
    }

    /// A new collection holding `m`; returns its id.
    func createCollection(named title: String, with m: Media) async throws -> String {
        await prepare()
        let name = "PolarisAPICreateCollectionMutation"
        let r = try await graphQL(name, variables: ["input": mutationInput([
            "added_media_ids": [.string(m.pk)], "name": .string(title),
        ])], docId: collectionDoc(name))
        guard let id = Parser.idString(r["xig_media_collection_create"]["collection"]["id"]) else { throw IGError.badResponse }
        return id
    }
}
