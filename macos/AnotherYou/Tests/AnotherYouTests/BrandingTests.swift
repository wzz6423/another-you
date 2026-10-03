import AppKit
import XCTest
@testable import AnotherYouCore

@MainActor
final class BrandingTests: XCTestCase {
    func testBundledIconsContainDayAndNightArtwork() throws {
        for (icon, isDark) in [(AppBranding.lightIcon, false), (AppBranding.darkIcon, true),
                               (AppBranding.lightLogo, false), (AppBranding.darkLogo, true)] {
            XCTAssertTrue(icon.isValid)
            let data = try XCTUnwrap(icon.tiffRepresentation)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
            let center = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
            if isDark {
                XCTAssertLessThan(center.redComponent, 0.2)
            } else {
                XCTAssertGreaterThan(center.redComponent, 0.9)
            }
        }
    }

    func testMenuBarIconHasTemplateRenderingAndTransparentCorners() throws {
        let icon = AppBranding.menuBarIcon
        XCTAssertTrue(icon.isTemplate)
        XCTAssertEqual(icon.size, NSSize(width: 18, height: 18))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(icon.tiffRepresentation)))
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent, 0, accuracy: 0.01)
    }

    func testApplicationIconUsesBuildConfigurationRegardlessOfAppearance() throws {
        let application = NSApplication.shared
        let originalAppearance = application.appearance
        let originalIcon = application.applicationIconImage
        defer {
            application.appearance = originalAppearance
            application.applicationIconImage = originalIcon
        }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            application.appearance = NSAppearance(named: name)
            AppBranding.updateApplicationIcon()
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(application.applicationIconImage.tiffRepresentation)))
            let center = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
            #if DEBUG
            XCTAssertLessThan(center.redComponent, 0.2)
            #else
            XCTAssertGreaterThan(center.redComponent, 0.9)
            #endif
        }
    }
}
