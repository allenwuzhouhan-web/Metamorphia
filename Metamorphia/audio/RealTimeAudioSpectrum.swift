/*
 * Metamorphia
 * Original work Copyright (C) 2026 ZephyrCodesStuff (https://github.com/ZephyrCodesStuff/rtaudio)
 * Modified work Copyright (C) 2026 Metamorphia Contributors
 *
 * Real-time audio spectrum visualization using CoreAudio tap data.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This file is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import AppKit
import Cocoa
import SwiftUI
import simd

/// NSView-based real-time audio spectrum visualizer
class RealTimeAudioSpectrum: NSView {
    private var barLayers: [CAShapeLayer] = []
    private var isPlaying: Bool = true
    private var animationTimer: Timer?

    // Idle-pause: when the audio is silent for a while, drop the timer to a low
    // polling rate so we stop doing a 30fps main-thread wakeup over nothing, then
    // ramp back up to full frame rate as soon as activity returns.
    private let activeInterval: TimeInterval = 1.0 / 30.0
    private let idleInterval: TimeInterval = 1.0 / 2.0
    private let silenceEpsilon: Float = 0.01
    private let idleFrameThreshold = 30
    private var silentFrameCount = 0
    private var isIdle = false
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupBars()
    }

    deinit {
        stopAnimating()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setupBars()
    }

    private func setupBars() {
        let barWidth: CGFloat = 2
        let barCount = 4
        let spacing: CGFloat = barWidth
        let totalWidth = CGFloat(barCount) * (barWidth + spacing)
        let totalHeight: CGFloat = 14
        frame.size = CGSize(width: totalWidth, height: totalHeight)

        for i in 0 ..< barCount {
            let xPosition = CGFloat(i) * (barWidth + spacing)
            let barLayer = CAShapeLayer()
            barLayer.frame = CGRect(x: xPosition, y: 0, width: barWidth, height: totalHeight)
            barLayer.position = CGPoint(x: xPosition + barWidth / 2, y: totalHeight / 2)
            barLayer.fillColor = NSColor.white.cgColor
            
            let path = NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: barWidth, height: totalHeight),
                                    xRadius: barWidth / 2,
                                    yRadius: barWidth / 2)
            barLayer.path = path.cgPath
            
            barLayers.append(barLayer)
            layer?.addSublayer(barLayer)
        }
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopAnimating()
        } else if isPlaying {
            startAnimating()
        }
    }

    private func startAnimating() {
        guard animationTimer == nil else { return }
        silentFrameCount = 0
        isIdle = false
        scheduleTimer(interval: activeInterval)
    }

    private func scheduleTimer(interval: TimeInterval) {
        animationTimer?.invalidate()
        animationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.updateBarsFromAudio()
        }
    }

    private func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
        silentFrameCount = 0
        isIdle = false
        resetBars()
    }
    
    #if DEBUG
    private var debugLogCounter = 0
    #endif

    private func updateBarsFromAudio() {
        guard isPlaying else {
            resetBars()
            return
        }

        // Get real-time magnitudes from AudioTap
        let magnitudes = AudioTap.shared.getSmoothedMagnitudes()

        // Idle-pause: throttle to a low polling rate while every lane is silent,
        // and ramp straight back to full frame rate the moment activity returns.
        let isSilent = magnitudes.max() < silenceEpsilon
        if isSilent {
            if !isIdle {
                silentFrameCount += 1
                if silentFrameCount >= idleFrameThreshold {
                    isIdle = true
                    scheduleTimer(interval: idleInterval)
                }
            }
        } else {
            silentFrameCount = 0
            if isIdle {
                isIdle = false
                scheduleTimer(interval: activeInterval)
            }
        }

        // Debug: log magnitudes periodically
        #if DEBUG
        debugLogCounter += 1
        if debugLogCounter % 60 == 0 { // Every 2 seconds at 30fps
            print("📊 [Spectrum] Magnitudes: [\(magnitudes.x), \(magnitudes.y), \(magnitudes.z), \(magnitudes.w)]")
        }
        #endif

        // Update each bar with its corresponding band magnitude
        for (index, barLayer) in barLayers.enumerated() {
            let magnitude = magnitudes[index]
            // Map magnitude (0-1) to scale (0.2 - 1.0) for visual appeal
            let scale = max(0.2, min(1.0, CGFloat(magnitude) * 1.5 + 0.2))
            
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            barLayer.transform = CATransform3DMakeScale(1, scale, 1)
            CATransaction.commit()
        }
    }
    
    private func resetBars() {
        for barLayer in barLayers {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            barLayer.transform = CATransform3DMakeScale(1, 0.2, 1)
            CATransaction.commit()
        }
    }
    
    func setPlaying(_ playing: Bool) {
        isPlaying = playing
        if isPlaying {
            startAnimating()
        } else {
            stopAnimating()
        }
    }
}

/// SwiftUI wrapper for RealTimeAudioSpectrum
struct RealTimeAudioSpectrumView: NSViewRepresentable {
    @Binding var isPlaying: Bool
    
    func makeNSView(context: Context) -> RealTimeAudioSpectrum {
        let spectrum = RealTimeAudioSpectrum()
        spectrum.setPlaying(isPlaying)
        return spectrum
    }
    
    func updateNSView(_ nsView: RealTimeAudioSpectrum, context: Context) {
        nsView.setPlaying(isPlaying)
    }

    static func dismantleNSView(_ nsView: RealTimeAudioSpectrum, coordinator: ()) {
        nsView.setPlaying(false)
    }
}

#Preview {
    RealTimeAudioSpectrumView(isPlaying: .constant(true))
        .frame(width: 16, height: 20)
        .padding()
}
