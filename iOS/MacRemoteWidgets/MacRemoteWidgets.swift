import ActivityKit
import AppIntents
import SwiftUI
import UIKit
import WidgetKit

enum RemoteWidgetAction: String, AppEnum {
    case previous, playPause, next, mute, sleep, fullscreen, volumeUp, volumeDown, brightnessUp, brightnessDown

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Remote action")
    static var caseDisplayRepresentations: [RemoteWidgetAction: DisplayRepresentation] = [
        .previous: "Previous", .playPause: "Play or pause", .next: "Next",
        .mute: "Mute", .sleep: "Sleep Mac", .fullscreen: "Toggle fullscreen", .volumeUp: "Volume up",
        .volumeDown: "Volume down", .brightnessUp: "Brightness up", .brightnessDown: "Brightness down"
    ]

    var symbol: String {
        switch self {
        case .previous: "backward.end.fill"
        case .playPause: "playpause.fill"
        case .next: "forward.end.fill"
        case .mute: "speaker.slash.fill"
        case .sleep: "moon.zzz.fill"
        case .fullscreen: "arrow.up.left.and.arrow.down.right"
        case .volumeUp: "speaker.plus.fill"
        case .volumeDown: "speaker.minus.fill"
        case .brightnessUp: "sun.max.fill"
        case .brightnessDown: "sun.min.fill"
        }
    }
}

struct RemoteWidgetActionIntent: AppIntent {
    static var title: LocalizedStringResource = "Mac Remote action"
    static var description = IntentDescription("Runs a Mac Remote quick action.")

    @Parameter(title: "Action") var action: RemoteWidgetAction

    init() { action = .playPause }
    init(action: RemoteWidgetAction) { self.action = action }

    func perform() async throws -> some IntentResult {
        try await WidgetRemoteCommandSender.send(action)
        return .result()
    }
}

struct RemoteWidgetEntry: TimelineEntry {
    let date: Date
    let isConnected: Bool

    static let preview = RemoteWidgetEntry(date: .now, isConnected: true)
}

struct RemoteWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> RemoteWidgetEntry { .preview }
    func getSnapshot(in context: Context, completion: @escaping (RemoteWidgetEntry) -> Void) {
        completion(.preview)
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<RemoteWidgetEntry>) -> Void) {
        completion(Timeline(entries: [.preview], policy: .never))
    }
}

struct MacRemoteControlWidget: Widget {
    let kind = "local.macremote.control"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RemoteWidgetProvider()) { _ in
            MacRemoteWidgetView()
                .containerBackground(for: .widget) { Color.black }
        }
        .configurationDisplayName("Mac Remote")
        .description("Previous, play or pause, and next.")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}

struct MacRemoteSystemControlsWidget: Widget {
    let kind = "local.macremote.system-controls"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RemoteWidgetProvider()) { _ in
            SystemControlsWidgetView()
                .containerBackground(for: .widget) { Color.black }
        }
        .configurationDisplayName("Mac Controls")
        .description("Adjust your Mac’s volume and screen brightness.")
        .supportedFamilies([.systemSmall])
    }
}

struct MacRemoteCombinedControlsWidget: Widget {
    let kind = "local.macremote.combined-controls"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RemoteWidgetProvider()) { _ in
            CombinedControlsWidgetView()
                .containerBackground(for: .widget) { Color.black }
        }
        .configurationDisplayName("Mac Remote Controls")
        .description("Media, volume, and brightness controls for your Mac.")
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}

struct MacRemoteCircularAccessoryWidget: Widget {
    let kind = "local.macremote.accessory-circular"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RemoteWidgetProvider()) { _ in
            Button(intent: RemoteWidgetActionIntent(action: .playPause)) {
                Image(systemName: "playpause.fill")
                    .font(.title2)
            }
            .widgetLabel("Play / Pause")
            .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Mac Play / Pause")
        .description("Play or pause media on your Mac from the Lock Screen.")
        .supportedFamilies([.accessoryCircular])
    }
}

struct MacRemoteAppIconAccessoryWidget: Widget {
    let kind = "local.macremote.accessory-app-icon"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RemoteWidgetProvider()) { _ in
            AppIconAccessoryView()
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Open Mac Remote")
        .description("Open Mac Remote from the Lock Screen.")
        .supportedFamilies([.accessoryCircular])
    }
}

private struct AppIconAccessoryView: View {
    private let destination = URL(string: "macremote://open")!

    var body: some View {
        Group {
            if let icon = UIImage(named: "Icon-60@3x") {
                Image(uiImage: icon)
                    .resizable()
                    .scaledToFit()
                    .clipShape(Circle())
                    .padding(2)
            } else {
                Image(systemName: "app.fill")
                    .font(.title2)
            }
        }
        .widgetURL(destination)
        .widgetLabel("Open Mac Remote")
    }
}

struct MacRemoteRectangularAccessoryWidget: Widget {
    let kind = "local.macremote.accessory-rectangular"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RemoteWidgetProvider()) { _ in
            HStack(spacing: 12) {
                accessoryButton(.previous)
                accessoryButton(.playPause)
                accessoryButton(.next)
            }
            .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Mac Media Controls")
        .description("Previous, play or pause, and next from the Lock Screen.")
        .supportedFamilies([.accessoryRectangular])
    }

    private func accessoryButton(_ action: RemoteWidgetAction) -> some View {
        Button(intent: RemoteWidgetActionIntent(action: action)) {
            Image(systemName: action.symbol)
                .font(.body)
        }
        .accessibilityLabel(action.rawValue)
    }
}

private struct MacRemoteWidgetView: View {
    var body: some View {
        HStack(spacing: 2) {
            mediaButton(.previous, position: .left)
            mediaButton(.playPause, prominent: true, position: .middle)
            mediaButton(.next, position: .right)
        }
        .frame(minWidth: 142, maxWidth: 142, maxHeight: .infinity)
        .padding(.horizontal, 4)
        .padding(.vertical, 16)
    }

    private enum HorizontalPosition { case left, middle, right }

    private func mediaButton(_ action: RemoteWidgetAction, prominent: Bool = false, position: HorizontalPosition) -> some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: position == .left ? 14 : 4,
            bottomLeadingRadius: position == .left ? 14 : 4,
            bottomTrailingRadius: position == .right ? 14 : 4,
            topTrailingRadius: position == .right ? 14 : 4,
            style: .continuous
        )
        return Button(intent: RemoteWidgetActionIntent(action: action)) {
            Image(systemName: action.symbol)
                .font(prominent ? .title2 : .title3)
                .foregroundStyle(.white)
                .frame(width: 46, height: 104)
                .background(shape.fill(.white.opacity(0.16)))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
    }
}

private struct SystemControlsWidgetView: View {
    var body: some View {
        HStack(spacing: 8) {
            VStack(spacing: 2) {
                systemButton(.volumeUp, label: "Volume up", position: .top)
                systemButton(.volumeDown, label: "Volume down", position: .bottom)
            }
            VStack(spacing: 2) {
                systemButton(.brightnessUp, label: "Brightness up", position: .top)
                systemButton(.brightnessDown, label: "Brightness down", position: .bottom)
            }
        }
        .padding(8)
    }

    private enum Position { case top, bottom }

    private func systemButton(_ action: RemoteWidgetAction, label: String, position: Position) -> some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: position == .top ? 14 : 4,
            bottomLeadingRadius: position == .bottom ? 14 : 4,
            bottomTrailingRadius: position == .bottom ? 14 : 4,
            topTrailingRadius: position == .top ? 14 : 4,
            style: .continuous
        )
        return Button(intent: RemoteWidgetActionIntent(action: action)) {
            Image(systemName: action.symbol)
                .font(.title2)
                .frame(maxWidth: .infinity, minHeight: 64, maxHeight: .infinity)
                .background(shape.fill(.gray.opacity(0.22)))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct CombinedControlsWidgetView: View {
    private enum HorizontalPosition { case left, middle, right }
    private enum VerticalPosition { case top, bottom }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                mediaButton(.previous, position: .left)
                mediaButton(.playPause, position: .middle)
                mediaButton(.next, position: .right)
            }

            HStack(spacing: 8) {
                VStack(spacing: 2) {
                    systemButton(.volumeUp, position: .top)
                    systemButton(.volumeDown, position: .bottom)
                }
                VStack(spacing: 2) {
                    systemButton(.brightnessUp, position: .top)
                    systemButton(.brightnessDown, position: .bottom)
                }
            }
        }
        .padding(12)
    }

    private func mediaButton(_ action: RemoteWidgetAction, position: HorizontalPosition) -> some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: position == .left ? 14 : 4,
            bottomLeadingRadius: position == .left ? 14 : 4,
            bottomTrailingRadius: position == .right ? 14 : 4,
            topTrailingRadius: position == .right ? 14 : 4,
            style: .continuous
        )
        return Button(intent: RemoteWidgetActionIntent(action: action)) {
            Image(systemName: action.symbol)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 36, height: 104)
                .background(shape.fill(.white.opacity(0.16)))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
    }

    private func systemButton(_ action: RemoteWidgetAction, position: VerticalPosition) -> some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: position == .top ? 14 : 4,
            bottomLeadingRadius: position == .bottom ? 14 : 4,
            bottomTrailingRadius: position == .bottom ? 14 : 4,
            topTrailingRadius: position == .top ? 14 : 4,
            style: .continuous
        )
        return Button(intent: RemoteWidgetActionIntent(action: action)) {
            Image(systemName: action.symbol)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 70, height: 51)
                .background(shape.fill(.white.opacity(0.16)))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
    }
}

struct MacRemotePresentationLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RemotePresentationAttributes.self) { context in
            lockScreenContent(context)
            .padding(.horizontal)
        } dynamicIsland: { context in
            DynamicIsland {
                islandExpandedContent(context)
            } compactLeading: {
                Image(systemName: "dot.radiowaves.left.and.right")
            } compactTrailing: {
                Text("Mac")
            } minimal: {
                Image(systemName: "dot.radiowaves.left.and.right")
            }
            .contentMargins(.leading, 24, for: .expanded)
            .contentMargins(.trailing, 24, for: .expanded)
            .contentMargins(.leading, 12, for: .compactLeading)
            .contentMargins(.trailing, 12, for: .compactTrailing)
        }
    }

    @ViewBuilder
    private func lockScreenContent(_ context: ActivityViewContext<RemotePresentationAttributes>) -> some View {
        HStack {
            Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.red)
            Text("Mac Remote").font(.headline)
            Spacer()
            liveActivityControls
        }
    }

    private var liveActivityControls: some View {
        HStack(spacing: 14) {
            Button(intent: RemoteWidgetActionIntent(action: .previous)) { Image(systemName: "backward.fill") }
            Button(intent: RemoteWidgetActionIntent(action: .playPause)) { Image(systemName: "playpause.fill") }
            Button(intent: RemoteWidgetActionIntent(action: .next)) { Image(systemName: "forward.fill") }
        }
        .font(.body)
    }

    @DynamicIslandExpandedContentBuilder
    private func islandExpandedContent(_ context: ActivityViewContext<RemotePresentationAttributes>) -> DynamicIslandExpandedContent<some View> {
        DynamicIslandExpandedRegion(.leading) { Image(systemName: "dot.radiowaves.left.and.right") }
        DynamicIslandExpandedRegion(.trailing) { Text("Mac") }
        DynamicIslandExpandedRegion(.bottom) {
            HStack(spacing: 14) {
                HStack(spacing: 8) {
                    VStack(spacing: 3) {
                        expandedControlButton(.volumeUp, position: .top)
                        expandedControlButton(.volumeDown, position: .bottom)
                    }
                    VStack(spacing: 3) {
                        expandedControlButton(.brightnessUp, position: .top)
                        expandedControlButton(.brightnessDown, position: .bottom)
                    }
                }
                Spacer(minLength: 10)
                HStack(spacing: 3) {
                    expandedControlButton(.previous, position: .left)
                    expandedControlButton(.playPause, position: .middle)
                    expandedControlButton(.next, position: .right)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private enum ExpandedButtonPosition { case top, bottom, left, middle, right }

    private func expandedControlButton(_ action: RemoteWidgetAction, position: ExpandedButtonPosition) -> some View {
        let outerRadius: CGFloat = 9
        let innerRadius: CGFloat = 4
        let height: CGFloat = position == .top || position == .bottom ? 44 : 36
        let shape: UnevenRoundedRectangle
        switch position {
        case .top:
            shape = .init(topLeadingRadius: outerRadius, bottomLeadingRadius: innerRadius,
                          bottomTrailingRadius: innerRadius, topTrailingRadius: outerRadius, style: .continuous)
        case .bottom:
            shape = .init(topLeadingRadius: innerRadius, bottomLeadingRadius: outerRadius,
                          bottomTrailingRadius: outerRadius, topTrailingRadius: innerRadius, style: .continuous)
        case .left:
            shape = .init(topLeadingRadius: outerRadius, bottomLeadingRadius: outerRadius,
                          bottomTrailingRadius: innerRadius, topTrailingRadius: innerRadius, style: .continuous)
        case .middle:
            shape = .init(topLeadingRadius: innerRadius, bottomLeadingRadius: innerRadius,
                          bottomTrailingRadius: innerRadius, topTrailingRadius: innerRadius, style: .continuous)
        case .right:
            shape = .init(topLeadingRadius: innerRadius, bottomLeadingRadius: innerRadius,
                          bottomTrailingRadius: outerRadius, topTrailingRadius: outerRadius, style: .continuous)
        }
        return Button(intent: RemoteWidgetActionIntent(action: action)) {
            Image(systemName: action.symbol)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 44, height: height)
                .background(shape.fill(.white.opacity(0.16)))
                .contentShape(shape)
        }
        .accessibilityLabel(action.rawValue)
    }
}

@available(iOS 18.0, *)
private struct MacRemotePreviousControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "local.macremote.control-center.previous") {
            ControlWidgetButton(action: RemoteWidgetActionIntent(action: .previous)) { Label("Previous", systemImage: "backward.end.fill") }
        }
        .displayName("Previous")
        .description("Plays the previous item on your Mac.")
    }
}

@available(iOS 18.0, *)
private struct MacRemotePlayPauseControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "local.macremote.control-center.play-pause") {
            ControlWidgetButton(action: RemoteWidgetActionIntent(action: .playPause)) { Label("Play or Pause", systemImage: "playpause.fill") }
        }
        .displayName("Play or Pause")
        .description("Plays or pauses media on your Mac.")
    }
}

@available(iOS 18.0, *)
private struct MacRemoteNextControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "local.macremote.control-center.next") {
            ControlWidgetButton(action: RemoteWidgetActionIntent(action: .next)) { Label("Next", systemImage: "forward.end.fill") }
        }
        .displayName("Next")
        .description("Plays the next item on your Mac.")
    }
}

@available(iOS 18.0, *)
private struct MacRemoteBrightnessUpControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "local.macremote.control-center.brightness-up") {
            ControlWidgetButton(action: RemoteWidgetActionIntent(action: .brightnessUp)) { Label("Brightness Up", systemImage: "sun.max.fill") }
        }
        .displayName("Brightness Up")
        .description("Raises your Mac display brightness.")
    }
}

@available(iOS 18.0, *)
private struct MacRemoteBrightnessDownControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "local.macremote.control-center.brightness-down") {
            ControlWidgetButton(action: RemoteWidgetActionIntent(action: .brightnessDown)) { Label("Brightness Down", systemImage: "sun.min.fill") }
        }
        .displayName("Brightness Down")
        .description("Lowers your Mac display brightness.")
    }
}

@available(iOS 18.0, *)
private struct MacRemoteVolumeUpControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "local.macremote.control-center.volume-up") {
            ControlWidgetButton(action: RemoteWidgetActionIntent(action: .volumeUp)) { Label("Volume Up", systemImage: "speaker.plus.fill") }
        }
        .displayName("Volume Up")
        .description("Raises your Mac volume.")
    }
}

@available(iOS 18.0, *)
private struct MacRemoteVolumeDownControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "local.macremote.control-center.volume-down") {
            ControlWidgetButton(action: RemoteWidgetActionIntent(action: .volumeDown)) { Label("Volume Down", systemImage: "speaker.minus.fill") }
        }
        .displayName("Volume Down")
        .description("Lowers your Mac volume.")
    }
}

@available(iOS 18.0, *)
private struct MacRemoteSleepControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "local.macremote.control-center.sleep") {
            ControlWidgetButton(action: RemoteWidgetActionIntent(action: .sleep)) { Label("Sleep Mac", systemImage: "moon.zzz.fill") }
        }
        .displayName("Sleep Mac")
        .description("Puts your Mac to sleep.")
    }
}

@available(iOS 18.0, *)
private struct MacRemoteFullscreenControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "local.macremote.control-center.fullscreen") {
            ControlWidgetButton(action: RemoteWidgetActionIntent(action: .fullscreen)) { Label("Toggle Fullscreen", systemImage: "arrow.up.left.and.arrow.down.right") }
        }
        .displayName("Toggle Fullscreen")
        .description("Toggles fullscreen on your Mac.")
    }
}

@main
struct MacRemoteWidgetsBundle: WidgetBundle {
    var body: some Widget {
        MacRemoteControlWidget()
        MacRemoteSystemControlsWidget()
        MacRemoteCombinedControlsWidget()
        MacRemoteCircularAccessoryWidget()
        MacRemoteAppIconAccessoryWidget()
        MacRemoteRectangularAccessoryWidget()
        MacRemotePresentationLiveActivity()
        if #available(iOS 18.0, *) {
            MacRemotePreviousControl()
            MacRemotePlayPauseControl()
            MacRemoteNextControl()
            MacRemoteBrightnessUpControl()
            MacRemoteBrightnessDownControl()
            MacRemoteVolumeUpControl()
            MacRemoteVolumeDownControl()
            MacRemoteSleepControl()
            MacRemoteFullscreenControl()
        }
    }
}
