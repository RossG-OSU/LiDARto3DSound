//
//  ARViewControllerRepresentable.swift
//  LiDARto3DSound
//
//  Created by Andrew on 11/6/24.
//

import SwiftUI
import UIKit

// This struct wraps your UIKit ViewController in a SwiftUI-compatible format
struct ARViewControllerRepresentable: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> ViewController {
        // Create and return your ViewController here
        return ViewController()
    }
    
    func updateUIViewController(_ uiViewController: ViewController, context: Context) {
        // Handle updates to your ViewController (if necessary)
    }
}
