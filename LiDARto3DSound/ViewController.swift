//
//  ViewController.swift
//  LiDARto3DSound
//
//  Created by Andrew on 11/6/24.
//

import UIKit
import SceneKit
import ARKit
import PHASE
import CoreMotion

class ViewController: UIViewController, ARSessionDelegate, CaptureAnchors {
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    var phaseEngine: PHASEEngine
    var phaseListener: PHASEListener
    var spatialMixerDefinition: PHASESpatialMixerDefinition!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupPhase()
    }
    
//    required init?(coder: NSCoder) {
//        fatalError("init(coder:) has not been implemented")
//    }
    
    func onNewAnchors(soundAnchors: [simd_float3]) {
        phaseEngine.rootObject.removeChildren()
        for point in soundAnchors {
            createAudioSource(for: createARAnchor(from: point))
        }
    }
    
    func createARAnchor(from point: simd_float3) -> ARAnchor {
        return ARAnchor(name: "SoundPoint", transform: simd_float4x4.translationTransform(point))
    }
    
    func createAudioSource(for anchor: ARAnchor) {
        let source = PHASESource(engine: phaseEngine)
        source.transform = anchor.transform
        try! phaseEngine.rootObject.addChild(source)
    }
    
    func setupPhase() {
            phaseEngine = PHASEEngine(updateMode: .automatic)
            spatialMixerDefinition = setupPhaseSpatialMixerDefinition()
            phaseListener = setupPhaseListener()
            
//            for (anchorName, fileName) in anchorFileMapping {
//                registerSoundWithPhase(anchorName: anchorName, fileName: fileName)
//            }
            
            try! phaseEngine.start()
    }
    
    func setupPhaseListener() -> PHASEListener {
        let listener = PHASEListener(engine: phaseEngine)
        listener.transform = matrix_identity_float4x4
        try! phaseEngine.rootObject.addChild(listener)
        return listener
    }
    
    func setupPhaseSpatialMixerDefinition() -> PHASESpatialMixerDefinition {
        let spatialPipeline = setupPhaseSpatialPipeline()
        let distanceModelParameters = setupPhaseDistanceModelParameters()
        
        let spatialMixerDefinition = PHASESpatialMixerDefinition(spatialPipeline: spatialPipeline)
        spatialMixerDefinition.distanceModelParameters = distanceModelParameters
        
        return spatialMixerDefinition
    }
    
    func setupPhaseSpatialPipeline() -> PHASESpatialPipeline {
        let spatialPipelineFlags : PHASESpatialPipeline.Flags = [.directPathTransmission, .lateReverb]
        let spatialPipeline = PHASESpatialPipeline(flags: spatialPipelineFlags)!
        spatialPipeline.entries[PHASESpatialCategory.lateReverb]!.sendLevel = 0.1;
        phaseEngine.defaultReverbPreset = .mediumRoom
        return spatialPipeline
    }
    
    func setupPhaseDistanceModelParameters() -> PHASEDistanceModelParameters {
        let distanceModelParameters = PHASEGeometricSpreadingDistanceModelParameters()
        distanceModelParameters.fadeOutParameters =
        PHASEDistanceModelFadeOutParameters(cullDistance: 16.5)
        distanceModelParameters.rolloffFactor = 2.0
        return distanceModelParameters
    }
    
}

