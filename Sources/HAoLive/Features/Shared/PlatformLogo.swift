// PlatformLogo.swift
// HAo Live — a platform's own brand logo, bundled from Pure Live's
// platform assets (the platforms' genuine brand marks, not HAo's
// design). Falls back to the colored dot when no logo is bundled.
// Used by the Hot chips and the Categories rail.

import SwiftUI

/// The platform's logo image, or the colored dot when no logo is
/// bundled for it.
struct PlatformLogo: View {
    let platform: LivePlatform
    var size: CGFloat = 18

    var body: some View {
        if let image = UIImage(named: platform.logoAssetName) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else {
            Circle()
                .fill(Color(hex: platform.colorHex))
                .frame(width: size * 0.45, height: size * 0.45)
        }
    }
}
