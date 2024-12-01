/*
See LICENSE folder for this sample’s licensing information.

Abstract:
An object that configures and manages the capture pipeline to stream video and LiDAR depth data.
*/

import Foundation
import AVFoundation
import CoreImage
import SwiftUI

protocol CaptureDataReceiver: AnyObject {
    func onNewData(capturedData: CameraCapturedData)
    func onNewPhotoData(capturedData: CameraCapturedData)
}

class CameraController: NSObject, ObservableObject {
    
    enum ConfigurationError: Error {
        case lidarDeviceUnavailable
        case requiredFormatUnavailable
    }
    private let soundManager = SoundManager()
    private let preferredWidthResolution = 1920
    
    private let videoQueue = DispatchQueue(label: "com.example.apple-samplecode.VideoQueue", qos: .userInteractive)
    
    private(set) var captureSession: AVCaptureSession!
    
    private var photoOutput: AVCapturePhotoOutput!
    private var depthDataOutput: AVCaptureDepthDataOutput!
    private var videoDataOutput: AVCaptureVideoDataOutput!
    private var outputVideoSync: AVCaptureDataOutputSynchronizer!
    
    private var textureCache: CVMetalTextureCache!
    
    weak var delegate: CaptureDataReceiver?
    
    var isFilteringEnabled = true {
        didSet {
            depthDataOutput.isFilteringEnabled = isFilteringEnabled
        }
    }

    
    override init() {
        
        // Create a texture cache to hold sample buffer textures.
        CVMetalTextureCacheCreate(kCFAllocatorDefault,
                                  nil,
                                  MetalEnvironment.shared.metalDevice,
                                  nil,
                                  &textureCache)
        
        super.init()

        do {
            try setupSession()
        } catch {
            fatalError("Unable to configure the capture session.")
        }
        
    }
    
    private func setupSession() throws {
        captureSession = AVCaptureSession()
        captureSession.sessionPreset = .inputPriority

        // Configure the capture session.
        captureSession.beginConfiguration()
        
        try setupCaptureInput()
        setupCaptureOutputs()
        
        // Finalize the capture session configuration.
        captureSession.commitConfiguration()
    }
    
    private func setupCaptureInput() throws {
        // Look up the LiDAR camera.
        guard let device = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) else {
            throw ConfigurationError.lidarDeviceUnavailable
        }
        
        // Find a match that outputs video data in the format the app's custom Metal views require.
        guard let format = (device.formats.last { format in
            format.formatDescription.dimensions.width == preferredWidthResolution &&
            format.formatDescription.mediaSubType.rawValue == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange &&
            !format.isVideoBinned &&
            !format.supportedDepthDataFormats.isEmpty
        }) else {
            throw ConfigurationError.requiredFormatUnavailable
        }
        
        // Find a match that outputs depth data in the format the app's custom Metal views require.
        guard let depthFormat = (format.supportedDepthDataFormats.last { depthFormat in
            depthFormat.formatDescription.mediaSubType.rawValue == kCVPixelFormatType_DepthFloat16
        }) else {
            throw ConfigurationError.requiredFormatUnavailable
        }
        
        // Begin the device configuration.
        try device.lockForConfiguration()

        // Configure the device and depth formats.
        device.activeFormat = format
        device.activeDepthDataFormat = depthFormat

        // Finish the device configuration.
        device.unlockForConfiguration()
        
        print("Selected video format: \(device.activeFormat)")
        print("Selected depth format: \(String(describing: device.activeDepthDataFormat))")
        
        // Add a device input to the capture session.
        let deviceInput = try AVCaptureDeviceInput(device: device)
        captureSession.addInput(deviceInput)
    }
    
    private func setupCaptureOutputs() {
        // Create an object to output video sample buffers.
        videoDataOutput = AVCaptureVideoDataOutput()
        captureSession.addOutput(videoDataOutput)
        
        // Create an object to output depth data.
        depthDataOutput = AVCaptureDepthDataOutput()
        depthDataOutput.isFilteringEnabled = isFilteringEnabled
        captureSession.addOutput(depthDataOutput)

        // Create an object to synchronize the delivery of depth and video data.
        outputVideoSync = AVCaptureDataOutputSynchronizer(dataOutputs: [depthDataOutput, videoDataOutput])
        outputVideoSync.setDelegate(self, queue: videoQueue)

        // Enable camera intrinsics matrix delivery.
        guard let outputConnection = videoDataOutput.connection(with: .video) else { return }
        if outputConnection.isCameraIntrinsicMatrixDeliverySupported {
            outputConnection.isCameraIntrinsicMatrixDeliveryEnabled = true
        }
        
        // Create an object to output photos.
        photoOutput = AVCapturePhotoOutput()
        photoOutput.maxPhotoQualityPrioritization = .quality
        captureSession.addOutput(photoOutput)

        // Enable delivery of depth data after adding the output to the capture session.
        photoOutput.isDepthDataDeliveryEnabled = true
    }
    
    func startStream() {
        captureSession.startRunning()
    }
    
    func stopStream() {
        captureSession.stopRunning()
    }

}

// MARK: Output Synchronizer Delegate
extension CameraController: AVCaptureDataOutputSynchronizerDelegate {
    
    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection) {
        // Retrieve the synchronized depth and sample buffer container objects.
        guard let syncedDepthData = synchronizedDataCollection.synchronizedData(for: depthDataOutput) as? AVCaptureSynchronizedDepthData,
              let syncedVideoData = synchronizedDataCollection.synchronizedData(for: videoDataOutput) as? AVCaptureSynchronizedSampleBufferData else { return }
        
        guard let pixelBuffer = syncedVideoData.sampleBuffer.imageBuffer,
              let cameraCalibrationData = syncedDepthData.depthData.cameraCalibrationData else { return }
        
        
        let avgDepthSubwindows = depthAvgSubwindows(depthMap: syncedDepthData.depthData.depthDataMap)
        print("Avg array \(String(describing: avgDepthSubwindows))")
        // Play sounds based on the depth subwindows
        if let avgDepths = avgDepthSubwindows {
            soundManager.sounds = avgDepths
        }
        
        
        // Package the captured data.
        let data = CameraCapturedData(depth: syncedDepthData.depthData.depthDataMap.texture(withFormat: .r16Float, planeIndex: 0, addToCache: textureCache),
                                      colorY: pixelBuffer.texture(withFormat: .r8Unorm, planeIndex: 0, addToCache: textureCache),
                                      colorCbCr: pixelBuffer.texture(withFormat: .rg8Unorm, planeIndex: 1, addToCache: textureCache),
                                      cameraIntrinsics: cameraCalibrationData.intrinsicMatrix,
                                      cameraReferenceDimensions: cameraCalibrationData.intrinsicMatrixReferenceDimensions)
        
        delegate?.onNewData(capturedData: data)
    }
    
    func depthAvgSubwindows(depthMap: CVPixelBuffer) -> [Float16]? {
        guard let convertedDepthMap = convertDepthData(depthMap: depthMap) else {
            return nil
        }
        // calculate average of 5 sections of the view, but only in the middle 25% of the height.
        let height = convertedDepthMap.count
        let width = convertedDepthMap[0].count
        let num_sections = 5
        let section_width = width / num_sections
        let top_mid25pc = height * 5 / 8
        let bottom_mid25pc = height * 3 / 8
        let num_pts: Float = Float((top_mid25pc - bottom_mid25pc) * section_width)

        var results: [Float16] = []

        for section in 0..<num_sections {
            var section_sum: Float = 0

            let start_x = section * section_width
            let end_x = (section == num_sections - 1) ? width : start_x + section_width

            for x in start_x..<end_x {
                for y in bottom_mid25pc..<top_mid25pc {
                    var depthValue = Float(convertedDepthMap[y][x]) // Access depth value directly
                    if depthValue >= 4.0 {
                        depthValue = 2.999
                    }
                    if depthValue == 0 {
                        depthValue = 0.001
                    }
                    // Normalize and invert the depth value
                    let invertedDepth = 1.0 - (depthValue / 4.0)

                    // Accumulate inverted depths
                    section_sum += invertedDepth
                }
            }

            // Calculate the average inverted value for the section
            let normalizedValue = section_sum / num_pts
            results.append(Float16(normalizedValue))
        }

        //TODO: problem with image being a mirrored...bandaid below
        return results.reversed()
    }
    
    func weightedDepthAvgSubwindows(depthMap: CVPixelBuffer) -> [Float16]? {
        guard let convertedDepthMap = convertDepthData(depthMap: depthMap) else {
            return nil
        }
        // calculate average of 5 sections of the view, but only in the middle 25% of the height.
        let height = convertedDepthMap.count
        let width = convertedDepthMap[0].count
        let halfx = Float(height) / 2.0 // Vertical center of the image
        let num_sections = 5
        let section_width = width / num_sections
        let top_3rd = height * 5 / 8
        let bottom_3rd = height * 3 / 8

        var results: [Float16] = []

        for section in 0..<num_sections {
            var weightedSum: Float = 0
            var totalWeight: Float = 0

            let start_x = section * section_width
            let end_x = (section == num_sections - 1) ? width : start_x + section_width
            let halfy = Float(start_x + end_x) / 2.0 // Horizontal center of the section

            for x in start_x..<end_x {
                for y in bottom_3rd..<top_3rd {
                    var depthValue = Float(convertedDepthMap[y][x]) // Access depth value directly
                    if depthValue > 5.0 {
                            depthValue = 5.0
                    }
                    let weight = 1.0 / (fabsf(Float(x) - halfy) + fabsf(Float(y) - halfx) + 0.001)
                    
                    weightedSum += (5.001 - depthValue) * weight // Invert depth for 0 (near) -> 3.0 (far)
                    totalWeight += weight
                }
            }

            // Normalize the weighted average to be between 0 and 1
            let normalizedValue = weightedSum / (totalWeight * 5.0)
            results.append(Float16(normalizedValue))
        }

        return results
    }
    
    // found at forums.developer.apple.com/forums/thread/653539
    // needs to be transposed to portrait mode
    func convertDepthData(depthMap: CVPixelBuffer) -> [[Float16]]? {
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        print("Height is \(height) and width is \(width)")
        
        // Assume the device is in portrait mode, so we will transpose the dimensions
        var convertedDepthMap: [[Float16]] = Array(repeating: Array(repeating: Float16(0), count: height), count: width)
        
        // Lock the pixel buffer's base address for safe access
        CVPixelBufferLockBaseAddress(depthMap, CVPixelBufferLockFlags.readOnly)
            
        // Ensure the pixel format is DepthFloat16 (kCVPixelFormatType_DepthFloat16)
        guard CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat16 else {
            print("Error: Pixel buffer has incorrect format. Expected kCVPixelFormatType_DepthFloat16.")
            CVPixelBufferUnlockBaseAddress(depthMap, CVPixelBufferLockFlags.readOnly)
            return nil
        }
            
        // Get the base address and safely cast it to an UnsafeMutablePointer<UInt16>
        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            print("Error: Failed to retrieve base address of the pixel buffer.")
            CVPixelBufferUnlockBaseAddress(depthMap, CVPixelBufferLockFlags.readOnly)
            return nil
        }
            
        let buffer = baseAddress.assumingMemoryBound(to: UInt16.self)
            
        // Iterate over the pixel buffer and convert it into a 2D array of Float32 values
        for row in 0..<height {
                for col in 0..<width {
                    let index = width * row + col
                    convertedDepthMap[col][row] = Float16(bitPattern: buffer[index])
                }
            }
        CVPixelBufferUnlockBaseAddress(depthMap, CVPixelBufferLockFlags.readOnly)
                
        return convertedDepthMap
                
    }
    
}

// MARK: Photo Capture Delegate
extension CameraController: AVCapturePhotoCaptureDelegate {
    
    func capturePhoto() {
        var photoSettings: AVCapturePhotoSettings
        if  photoOutput.availablePhotoPixelFormatTypes.contains(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
            photoSettings = AVCapturePhotoSettings(format: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ])
        } else {
            photoSettings = AVCapturePhotoSettings()
        }
        
        // Capture depth data with this photo capture.
        photoSettings.isDepthDataDeliveryEnabled = true
        photoOutput.capturePhoto(with: photoSettings, delegate: self)
    }
    
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        
        // Retrieve the image and depth data.
        guard let pixelBuffer = photo.pixelBuffer,
              let depthData = photo.depthData,
              let cameraCalibrationData = depthData.cameraCalibrationData else { return }
        
        // Stop the stream until the user returns to streaming mode.
        stopStream()
        
        // Convert the depth data to the expected format.
        let convertedDepth = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat16)

        // Package the captured data.
        let data = CameraCapturedData(depth: convertedDepth.depthDataMap.texture(withFormat: .r16Float, planeIndex: 0, addToCache: textureCache),
                                      colorY: pixelBuffer.texture(withFormat: .r8Unorm, planeIndex: 0, addToCache: textureCache),
                                      colorCbCr: pixelBuffer.texture(withFormat: .rg8Unorm, planeIndex: 1, addToCache: textureCache),
                                      cameraIntrinsics: cameraCalibrationData.intrinsicMatrix,
                                      cameraReferenceDimensions: cameraCalibrationData.intrinsicMatrixReferenceDimensions)
        
        delegate?.onNewPhotoData(capturedData: data)
    }

}
