/*
LiDARto3DSound

Created on 10/19/24.

See LICENSE folder for licensing information.

Abstract:
The app's main user interface.
 
Based on:
developer.apple.com/documentation/avfoundation/capturing-depth-using-the-lidar-camera
*/

import SwiftUI
import MetalKit
import Metal

struct ContentView: View {
    
    @StateObject private var manager = CameraManager()
    
    @State private var maxDepth = Float(5.0)
    @State private var minDepth = Float(0.0)
    @State private var scaleMovement = Float(1.0)
    
    let maxRangeDepth = Float(15)
    let minRangeDepth = Float(0)
    
    var body: some View {
        VStack {
            HStack {
                Button {
                    manager.processingCapturedResult ? manager.resumeStream() : manager.startPhotoCapture()
                } label: {
                    Image(systemName: manager.processingCapturedResult ? "play.circle" : "camera.circle")
                        .font(.largeTitle)
                }
                
                Text("Depth Filtering")
                Toggle("Depth Filtering", isOn: $manager.isFilteringDepth).labelsHidden()
                Spacer()
            }
            SliderDepthBoundaryView(val: $maxDepth, label: "Max Depth", minVal: minRangeDepth, maxVal: maxRangeDepth)
            SliderDepthBoundaryView(val: $minDepth, label: "Min Depth", minVal: minRangeDepth, maxVal: maxRangeDepth)
            ScrollView {
                if manager.dataAvailable {
                    DepthOverlay(manager: manager,
                                 maxDepth: $maxDepth,
                                 minDepth: $minDepth
                    )
                    .aspectRatio(calcAspect(orientation: viewOrientation, texture: manager.capturedData.depth), contentMode: .fit)
                }
            }
        }
    }
}

struct SliderDepthBoundaryView: View {
    @Binding var val: Float
    var label: String
    var minVal: Float
    var maxVal: Float
    let stepsCount = Float(200.0)
    var body: some View {
        HStack {
            Text(String(format: " %@: %.2f", label, val))
            Slider(
                value: $val,
                in: minVal...maxVal,
                step: (maxVal - minVal) / stepsCount
            ) {
            } minimumValueLabel: {
                Text(String(minVal))
            } maximumValueLabel: {
                Text(String(maxVal))
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .previewDevice("iPhone 15 Pro Max")
    }
}
