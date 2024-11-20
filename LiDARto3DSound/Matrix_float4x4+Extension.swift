/*
See LICENSE folder for this sample’s licensing information.

Abstract:
An extension to for a 4x4 transformation with a 3x3 matrix.
*/

import Foundation
import AVFoundation

extension matrix_float4x4 {
    static func translationTransform(_ translation: simd_float3) -> matrix_float4x4 {
        var transform = matrix_identity_float4x4
        transform.columns.3 = simd_float4(translation.x, translation.y, translation.z, 1.0)
        return transform
    }
}

