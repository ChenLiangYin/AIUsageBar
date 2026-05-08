import AppKit

enum StatusItemVisuals {
    static func configure(_ button: NSStatusBarButton) {
        button.title = "AI"
        button.toolTip = "AIUsageBar"
        button.imagePosition = .imageLeft

        if let image = NSImage(
            systemSymbolName: "chart.bar.fill",
            accessibilityDescription: "AIUsageBar"
        ) {
            image.isTemplate = true
            image.size = NSSize(width: 14, height: 14)
            button.image = image
        }
    }
}
