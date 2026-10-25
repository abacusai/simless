// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

// Image attachments came with Swift 6.3 (Xcode 26.4).
#if compiler(>=6.3)
import Testing
import UIKit

/// A test that attaches a UIImage, as snapshot testing libraries do, loads
/// Swift Testing's UIKit overlay.
struct AttachmentTests {
    @Test func attachesAUIImage() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        Attachment.record(image, named: "red")
        #expect(image.size.width == 8)
    }
}
#endif
