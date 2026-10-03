import AppKit
import SwiftUI

@MainActor
public enum AppBranding {
    static let lightIcon = loadImage(named: "AppIcon", extension: "icns")
    static let darkIcon = loadImage(named: "AppIconDark", extension: "icns")
    static let lightLogo = loadImage(named: "BrandLight", extension: "png")
    static let darkLogo = loadImage(named: "BrandDark", extension: "png")

    public static let menuBarIcon: NSImage = {
        let image = loadImage(named: "MenuBarTemplate", extension: "png")
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()

    public static func updateApplicationIcon() {
        #if DEBUG
        NSApplication.shared.applicationIconImage = darkIcon
        #else
        NSApplication.shared.applicationIconImage = lightIcon
        #endif
    }

    private static func loadImage(named name: String, extension suffix: String) -> NSImage {
        guard let url = Bundle.module.url(forResource: name, withExtension: suffix),
              let image = NSImage(contentsOf: url) else {
            preconditionFailure("缺少品牌资源：\(name).\(suffix)")
        }
        return image
    }
}

public struct AppLogo: View {
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public var body: some View {
        Image(nsImage: colorScheme == .dark ? AppBranding.darkLogo : AppBranding.lightLogo)
            .resizable()
            .scaledToFit()
    }
}
