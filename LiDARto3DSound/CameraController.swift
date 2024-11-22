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
        let convertedDepth = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat16)
        
        let avgDepthSubwindows = weightedDepthAvgSubwindows(depthMap: convertedDepth.depthDataMap)
        
        // Play sounds based on the depth subwindows
        if let avgDepths = avgDepthSubwindows {
            soundManager.playSounds(for: avgDepths, interval: 0.5) // Adjust interval as needed
        }
        
        // Package the captured data.
        let data = CameraCapturedData(depth: convertedDepth.depthDataMap.texture(withFormat: .r16Float, planeIndex: 0, addToCache: textureCache),
                                      colorY: pixelBuffer.texture(withFormat: .r8Unorm, planeIndex: 0, addToCache: textureCache),
                                      colorCbCr: pixelBuffer.texture(withFormat: .rg8Unorm, planeIndex: 1, addToCache: textureCache),
                                      cameraIntrinsics: cameraCalibrationData.intrinsicMatrix,
                                      cameraReferenceDimensions: cameraCalibrationData.intrinsicMatrixReferenceDimensions)
        
        delegate?.onNewPhotoData(capturedData: data)
    }
    
    func weightedDepthAvgSubwindows(depthMap: CVPixelBuffer) -> [Float32]? {
        
        let convertedDepthMap = convertDepthData(depthMap: depthMap)
        // Calculate weighted averages for 5 vertical subwindows
        let height = convertedDepthMap!.count
        let width = convertedDepthMap![0].count
        let halfx = height / 2 // Halving for abs value later, slight preference for bottom of frame
        let num_sections = 5
        let section_width = width / num_sections
        
        var results: [Float32] = []
        let multiplier = Float32(16.5 / 0.1) // Set to make array of 0 values near 1 (max volume)
           
        for section in 0..<num_sections {
            var rolling_avg = Float32(0)
            let start_x = section * section_width
            let end_x = (section == num_sections - 1) ? width : start_x + section_width
               
            for x in start_x..<end_x {
                for y in 0..<height {
                    let halfy = (start_x + end_x) / 2 // Middle of the current section
                    if let depthValue = convertedDepthMap?[y][x] {
                        rolling_avg += ((16.5 / (depthValue + 0.01)) /
                                        (fabsf(Float(x - halfy)) + fabsf(Float(y - halfx)) + 0.1))
                    }
                }
            }
               
            let section_area = Float32((end_x - start_x) * height)
            rolling_avg /= section_area * multiplier
            results.append(rolling_avg)
        }
           
        return results
    
    }
    
    // found at forums.developer.apple.com/forums/thread/653539
    func convertDepthData(depthMap: CVPixelBuffer) -> [[Float32]]? {
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        
        var convertedDepthMap: [[Float32]] = Array(repeating: Array(repeating: 0.0, count: width), count: height)
        
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
            
        // Cast the buffer to UInt16.
        // no native Float16 type in Swift, so convert it to Float32
        let buffer = baseAddress.assumingMemoryBound(to: UInt16.self)
            
        // Iterate over the pixel buffer and convert it into a 2D array of Float32 values
        for row in 0..<height {
            for col in 0..<width {
                // Calculate the index in the buffer
                let index = width * row + col
                let halfPrecisionValue = buffer[index]
                    
                // Convert the 16-bit half precision value to Float32 for easier usage
                // Here we need a helper function to decode half-precision floats
                let float32Value = convertHalfToFloat32(halfPrecisionValue)
                convertedDepthMap[row][col] = float32Value
            }
        }
        CVPixelBufferUnlockBaseAddress(depthMap, CVPixelBufferLockFlags(rawValue: 2))
                
        return convertedDepthMap
                
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

}
