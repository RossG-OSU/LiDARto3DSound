/*
See LICENSE folder for this sample’s licensing information.

Abstract:
A view that combines color textures into one RGB texture and draws it.
*/

import SwiftUI
import MetalKit
import Metal

struct MetalTextureViewColor: UIViewRepresentable, MetalRepresentable {
    var rotationAngle: Double
    
    var capturedData: CameraCapturedData

    func makeCoordinator() -> MTKColorTextureCoordinator {
        MTKColorTextureCoordinator(parent: self)
    }
}

final class MTKColorTextureCoordinator: MTKCoordinator<MetalTextureViewColor> {
    override func preparePipelineAndDepthState() {
        guard let metalDevice = mtkView.device else { fatalError("Expected a Metal device.") }
        do {
            let library = MetalEnvironment.shared.metalLibrary
            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipelineDescriptor.vertexFunction = library.makeFunction(name: "planeVertexShader")
            pipelineDescriptor.fragmentFunction = library.makeFunction(name: "planeFragmentShaderColor")
            pipelineDescriptor.vertexDescriptor = createPlaneMetalVertexDescriptor()
            pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
            pipelineState = try metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
            
            let depthDescriptor = MTLDepthStencilDescriptor()
            depthDescriptor.isDepthWriteEnabled = true
            depthDescriptor.depthCompareFunction = .less
            depthState = metalDevice.makeDepthStencilState(descriptor: depthDescriptor)
        } catch {
            print("Unexpected error: \(error).")
        }
    }
    
    override func draw(in view: MTKView) {
        guard parent.capturedData.colorY != nil && parent.capturedData.colorCbCr != nil else {
            print("There's no content to display.")
            return
        }
        // added per stackoverflow.com/questions/76451005/capturing-depth-using-the-lidar-camera-sample-code-caused-gpu-timeout-error-00
        guard let colorY = parent.capturedData.colorY?.makeTextureView(pixelFormat: .r8Unorm), let colorCbCr = parent.capturedData.colorCbCr?.makeTextureView(pixelFormat: .rg8Unorm) else {
                        print("One or both textures are deallocated. Unable to render.")
                        return
                    }
        
        
        guard let commandBuffer = metalCommandQueue.makeCommandBuffer() else { return }
        guard let passDescriptor = view.currentRenderPassDescriptor else { return }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else { return }
        // Vertex and Texture coordinates data (x,y,u,v) * 4 ordered for triangle strip.
        let vertexData: [Float] = [-1, -1, 1, 1,
                                    1, -1, 1, 0,
                                   -1,  1, 0, 1,
                                    1,  1, 0, 0]
        encoder.setVertexBytes(vertexData, length: vertexData.count * MemoryLayout<Float>.stride, index: 0)
        encoder.setFragmentTexture(parent.capturedData.colorY!, index: 0)
        encoder.setFragmentTexture(parent.capturedData.colorCbCr!, index: 1)
        encoder.setDepthStencilState(depthState)
        encoder.setRenderPipelineState(pipelineState)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.present(view.currentDrawable!)
        commandBuffer.commit()
    }
}
