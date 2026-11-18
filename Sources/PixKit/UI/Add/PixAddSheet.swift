import SwiftUI

/// Adding to a space: photos and videos from the library (several at once),
/// the in-app camera (photos, and video with sound), or an audio clip. Each
/// thing chosen is queued with the engine and the sheet closes; a refusal
/// (an unsupported type, a space that's gone) shows as the engine's notice.
public struct PixAddSheet: View {
    let engine: PixEngine
    let spaceID: UUID
    @Environment(\.dismiss) private var dismiss

    public init(engine: PixEngine, spaceID: UUID) {
        self.engine = engine
        self.spaceID = spaceID
    }

    public var body: some View {
        PixAddPanel(config: engine.config,
                    add: { url, mime in await engine.add(file: url, mimeType: mime, to: spaceID, ownsFile: true) },
                    close: { dismiss() })
            .onChange(of: engine.isGone(spaceID)) { _, gone in if gone { dismiss() } }
    }
}
