/*
See LICENSE folder for this sample’s licensing information.

Abstract:
An object that configures and manages the capture pipeline to stream video and LiDAR depth data.
*/

import Foundation
import AVFoundation
import CoreImage

protocol CaptureDataReceiver: AnyObject {
    func onNewData(capturedData: CameraCapturedData)
    func onNewPhotoData(capturedData: CameraCapturedData)
}

class CameraController: NSObject, ObservableObject {
    
    enum ConfigurationError: Error {
        case lidarDeviceUnavailable
        case requiredFormatUnavailable
    }
    
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
        
        // Package the captured data.
        let data = CameraCapturedData(depth: syncedDepthData.depthData.depthDataMap.texture(withFormat: .r16Float, planeIndex: 0, addToCache: textureCache),
                                      colorY: pixelBuffer.texture(withFormat: .r8Unorm, planeIndex: 0, addToCache: textureCache),
                                      colorCbCr: pixelBuffer.texture(withFormat: .rg8Unorm, planeIndex: 1, addToCache: textureCache),
                                      cameraIntrinsics: cameraCalibrationData.intrinsicMatrix,
                                      cameraReferenceDimensions: cameraCalibrationData.intrinsicMatrixReferenceDimensions)
        
        delegate?.onNewData(capturedData: data)
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
        var convertedDepth = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat16)
        
        convertAndSmoothDepthData(depthMap: convertedDepth.depthDataMap)
        
        // Package the captured data.
        let data = CameraCapturedData(depth: convertedDepth.depthDataMap.texture(withFormat: .r16Float, planeIndex: 0, addToCache: textureCache),
                                      colorY: pixelBuffer.texture(withFormat: .r8Unorm, planeIndex: 0, addToCache: textureCache),
                                      colorCbCr: pixelBuffer.texture(withFormat: .rg8Unorm, planeIndex: 1, addToCache: textureCache),
                                      cameraIntrinsics: cameraCalibrationData.intrinsicMatrix,
                                      cameraReferenceDimensions: cameraCalibrationData.intrinsicMatrixReferenceDimensions)
        
        delegate?.onNewPhotoData(capturedData: data)
    }
    
    // found at forums.developer.apple.com/forums/thread/653539
    func convertAndSmoothDepthData(depthMap: CVPixelBuffer, windowSize: Int = 30) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        
        // Lock the pixel buffer's base address for safe access
        CVPixelBufferLockBaseAddress(depthMap, CVPixelBufferLockFlags.readOnly)
            
        // Ensure the pixel format is DepthFloat16 (kCVPixelFormatType_DepthFloat16)
        guard CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat16 else {
            print("Error: Pixel buffer has incorrect format. Expected kCVPixelFormatType_DepthFloat16.")
            CVPixelBufferUnlockBaseAddress(depthMap, CVPixelBufferLockFlags.readOnly)
            return nil
        }
        
        // Get the base address and safely cast it to an UnsafeMutablePointer<Float16>
        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            print("Error: Failed to retrieve base address of the pixel buffer.")
            CVPixelBufferUnlockBaseAddress(depthMap, CVPixelBufferLockFlags.readOnly)
            return nil
        }
        
        // Cast the buffer to Float16 (half-precision floating point)
        let buffer = baseAddress.assumingMemoryBound(to: Float16.self)
        
        // Create a new pixel buffer to store the smoothed data as DepthFloat16
        var outputBuffer: CVPixelBuffer?
        let pixelFormat = kCVPixelFormatType_DepthFloat16
        let options: [CFString: Any] = [
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: pixelFormat
        ]
        
        let status = CVPixelBufferCreate(nil, width, height, pixelFormat, options as CFDictionary, &outputBuffer)
        if status != kCVReturnSuccess {
            print("Error: Failed to create output pixel buffer.")
            CVPixelBufferUnlockBaseAddress(depthMap, CVPixelBufferLockFlags.readOnly)
            return nil
        }
        
        // Lock the output pixel buffer
        CVPixelBufferLockBaseAddress(outputBuffer!, CVPixelBufferLockFlags.readWrite)
        
        // Get the base address of the output buffer and cast it to a pointer for Float16
        guard let outputBaseAddress = CVPixelBufferGetBaseAddress(outputBuffer!) else {
            print("Error: Failed to retrieve base address of the output pixel buffer.")
            CVPixelBufferUnlockBaseAddress(depthMap, CVPixelBufferLockFlags.readOnly)
            CVPixelBufferUnlockBaseAddress(outputBuffer!, CVPixelBufferLockFlags.readWrite)
            return nil
        }
        
        let outputBufferPointer = outputBaseAddress.assumingMemoryBound(to: Float16.self)

        // Apply smoothing using a moving window average on Float16 values
        let halfWindow = windowSize / 2
        
        for row in 0..<height {
            for col in 0..<width {
                var sum: Float32 = 0.0  // Using Float32 for the sum to avoid overflow
                var count: Int = 0
                
                // Loop through the window around the current pixel (ensuring we stay within bounds)
                for i in -halfWindow...halfWindow {
                    for j in -halfWindow...halfWindow {
                        let neighborRow = row + i
                        let neighborCol = col + j
                        
                        // Skip out-of-bounds indices
                        if neighborRow >= 0 && neighborRow < height && neighborCol >= 0 && neighborCol < width {
                            let neighborIndex = width * neighborRow + neighborCol
                            let neighborValue = buffer[neighborIndex]
                            
                            // Add the neighbor value to the sum (Float16 values, promoted to Float32 for sum)
                            sum += Float32(neighborValue)
                            count += 1
                        }
                    }
                }
                
                // Calculate the average and store it (truncate if necessary)
                if count > 0 {
                    let average = sum / Float32(count)
                    
                    // Truncate to Float16 and store it in the output buffer
                    outputBufferPointer[width * row + col] = Float16(average)
                }
            }
        }
        
        // Unlock the buffers after processing
        CVPixelBufferUnlockBaseAddress(depthMap, CVPixelBufferLockFlags.readOnly)
        CVPixelBufferUnlockBaseAddress(outputBuffer!, CVPixelBufferLockFlags.readWrite)
        
        return outputBuffer
    }


    
    func convertHalfToFloat32(_ half: UInt16) -> Float32 {
        let sign = (half & 0x8000) >> 15
        let exponent = (half & 0x7C00) >> 10
        let fraction = half & 0x03FF
        
        if exponent == 0 {
            // Subnormal or zero
            return Float32(sign == 0 ? 0 : -0)
        } else if exponent == 0x1F {
            // Infinity or NaN
            return Float32(sign == 0 ? Float.infinity : -Float.infinity)
        } else {
            // Normalized value
            let exponentFloat = Float32(exponent - 15)  // Bias of 15
            let fractionFloat = Float32(fraction) / Float32(1 << 10)
            return Float32((sign == 0 ? 1 : -1) * pow(2, exponentFloat) * (1 + fractionFloat))
        }
    }
    
    func smoothDepthMap(depthMap: [[Float32]], windowSize: Int) -> [[Float32]] {
        let height = depthMap.count
        let width = depthMap[0].count
        let halfWindowSize = windowSize / 2
        
        // Create a new array to hold the smoothed depth values
        var smoothedDepthMap = Array(repeating: Array(repeating: Float32(0.0), count: width), count: height)

        
        // Iterate over each pixel in the depth map
        for row in 0..<height {
            for col in 0..<width {
                var sum: Float32 = 0.0
                var count: Int = 0
                
                // Iterate through the window around the current pixel
                for i in -halfWindowSize...halfWindowSize {
                    for j in -halfWindowSize...halfWindowSize {
                        // Calculate the coordinates of the neighboring pixel
                        let neighborRow = row + i
                        let neighborCol = col + j
                        
                        // Ensure the neighbor is within bounds
                        if neighborRow >= 0 && neighborRow < height && neighborCol >= 0 && neighborCol < width {
                            sum += depthMap[neighborRow][neighborCol]
                            count += 1
                        }
                    }
                }
                
                // Calculate the average and assign it to the smoothed depth map
                if count > 0 {
                    smoothedDepthMap[row][col] = sum / Float32(count)
                }
            }
        }
        
        let targetSize = windowSize
            var downsampledDepthMap = Array(repeating: Array(repeating: Float32(0.0), count: windowSize), count: targetSize)
            
            let rowStep = height / targetSize
            let colStep = width / targetSize
            
            for i in 0..<targetSize {
                for j in 0..<targetSize {
                    let rowIndex = i * rowStep
                    let colIndex = j * colStep
                    downsampledDepthMap[i][j] = smoothedDepthMap[rowIndex][colIndex]
                }
            }
                    
        // print for debugging
        for (rowIndex, row) in downsampledDepthMap.enumerated() {
            let rowString = row.map { String(format: "%.2f", $0) }.joined(separator: " ")
            print("Row \(rowIndex): \(rowString)")
        }
        
        return downsampledDepthMap
    }

}
