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

class ViewController: UIViewController, ARSessionDelegate {
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    var phaseEngine: PHASEEngine
    var phaseListener: PHASEListener
    
    func didload() {
        setupPhase()
    }
    
    func setupPhase() {
            phaseEngine = PHASEEngine(updateMode: .automatic)
            phaseSpatialMixerDefinition = setupPhaseSpatialMixerDefinition()
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
//        PHASEDistanceModelFadeOutParameters(cullDistance: DEFAULT_CULL_DISTANCE)
//        distanceModelParameters.rolloffFactor = DEFAULT_ROLLOFF_FACTOR
        return distanceModelParameters
    }
    
}
