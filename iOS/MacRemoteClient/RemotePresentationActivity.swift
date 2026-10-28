import ActivityKit
import Foundation

struct RemotePresentationAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var slide: Int
        var totalSlides: Int
    }

    var macName: String
}

@MainActor
enum RemotePresentationPreview {
    static func start() async {
        await startIfNeeded()
    }

    static func sync(connected: Bool, enabled: Bool) async {
        if connected && enabled { await startIfNeeded() }
        else { await end() }
    }

    private static func startIfNeeded() async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled,
              Activity<RemotePresentationAttributes>.activities.isEmpty else { return }
        let attributes = RemotePresentationAttributes(macName: "My Mac")
        let content = ActivityContent(
            state: RemotePresentationAttributes.ContentState(slide: 4, totalSlides: 12),
            staleDate: nil
        )
        _ = try? Activity.request(attributes: attributes, content: content)
    }

    static func end() async {
        for activity in Activity<RemotePresentationAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
