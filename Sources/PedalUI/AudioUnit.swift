import AVFoundation
import AudioToolbox
import CoreAudioKit
import PedalCore
import SwiftUI

public enum LutherieComponent {
    public static let description = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: fourCC("Luth"),
        componentManufacturer: fourCC("Chnl"),
        componentFlags: 0, componentFlagsMask: 0)

    static func fourCC(_ s: String) -> FourCharCode { s.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) } }
}

/// The plugin: an Audio Unit v3 effect around the Rig, with the editor as its view.
@objc(LutherieAudioUnit)
public final class LutherieAudioUnit: AUAudioUnit, ParamBridge {
    public let rig: Rig
    private var inBus: AUAudioUnitBus!
    private var outBus: AUAudioUnitBus!
    private var inBusArray: AUAudioUnitBusArray!
    private var outBusArray: AUAudioUnitBusArray!
    private var tree: AUParameterTree!
    private var params: [RigParam: AUParameter] = [:]
    private var pullBuffer: AVAudioPCMBuffer?
    private var monoBuffer: UnsafeMutablePointer<Float>
    /// Frames monoBuffer holds. Hosts may ask for bigger blocks than the 4096 offered: the buffers are sized
    /// to whatever they ask for when render resources are allocated, never on the audio thread.
    private var monoCapacity: Int = 4096
    private let maxFramesCap: AUAudioFrameCount = 4096
    @MainActor public private(set) var editor: EditorModel!

    public override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        rig = Rig(sampleRate: 48_000, maxFrames: 4096)
        monoBuffer = .allocate(capacity: 4096)
        try super.init(componentDescription: componentDescription, options: options)

        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        inBus = try AUAudioUnitBus(format: format)
        outBus = try AUAudioUnitBus(format: format)
        inBus.maximumChannelCount = 2
        outBus.maximumChannelCount = 2
        inBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inBus])
        outBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outBus])

        var list: [AUParameter] = []
        for p in RigParam.allCases {
            var flags: AudioUnitParameterOptions = [.flag_IsReadable, .flag_IsWritable, .flag_CanRamp]
            if p.isIndexed { flags = [.flag_IsReadable, .flag_IsWritable] }
            let unit: AudioUnitParameterUnit = p.isIndexed ? .indexed : (p.unit == "dB" ? .decibels : .generic)
            let param = AUParameterTree.createParameter(withIdentifier: "p\(p.rawValue)", name: p.name, address: AUParameterAddress(p.rawValue),
                                                        min: p.range.lowerBound, max: p.range.upperBound, unit: unit, unitName: nil,
                                                        flags: flags, valueStrings: p.valueNames, dependentParameters: nil)
            param.value = p.defaultValue
            params[p] = param
            list.append(param)
        }
        tree = AUParameterTree.createTree(withChildren: list)
        let rigRef = rig
        tree.implementorValueObserver = { param, value in
            if let p = RigParam(rawValue: Int(param.address)) { rigRef[p] = value }
        }
        tree.implementorValueProvider = { param in
            guard let p = RigParam(rawValue: Int(param.address)) else { return 0 }
            return rigRef[p]
        }
        tree.implementorStringFromValueCallback = { param, value in
            guard let p = RigParam(rawValue: Int(param.address)) else { return "" }
            let v = value?.pointee ?? param.value
            if let names = p.valueNames { return names[min(max(Int(v.rounded()), 0), names.count - 1)] }
            if p.unit == "dB" { return String(format: "%.1f", v) }
            return String(format: "%.0f%%", v * 100)
        }
        maximumFramesToRender = maxFramesCap

        if Thread.isMainThread {
            MainActor.assumeIsolated { self.makeEditor() }
        } else {
            DispatchQueue.main.sync { MainActor.assumeIsolated { self.makeEditor() } }
        }
    }

    deinit { monoBuffer.deallocate() }

    @MainActor private func makeEditor() {
        let m = EditorModel()
        editor = m
        m.attach(self)
    }

    // MARK: ParamBridge

    public func value(_ p: RigParam) -> Float { rig[p] }
    public func set(_ p: RigParam, _ v: Float) {
        if let param = params[p] { param.setValue(v, originator: nil) } else { rig[p] = v }
    }

    // MARK: AUAudioUnit

    public override var parameterTree: AUParameterTree? {
        get { tree }
        set { }
    }
    public override var inputBusses: AUAudioUnitBusArray { inBusArray }
    public override var outputBusses: AUAudioUnitBusArray { outBusArray }
    public override var channelCapabilities: [NSNumber]? { [1, 1, 1, 2, 2, 2] }
    public override var latency: TimeInterval { Double(rig.expectedLatency) / max(rig.sampleRate, 1) }
    public func latencyChanged() {
        willChangeValue(forKey: "latency")
        didChangeValue(forKey: "latency")
    }
    public override var tailTime: TimeInterval { 0.2 }
    public override var supportsUserPresets: Bool { true }
    public override var canProcessInPlace: Bool { false }

    public override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        let sr = outBus.format.sampleRate
        let frames = Int(max(maximumFramesToRender, maxFramesCap))
        pullBuffer = AVAudioPCMBuffer(pcmFormat: inBus.format, frameCapacity: AUAudioFrameCount(frames))
        if frames > monoCapacity {
            monoBuffer.deallocate()
            monoBuffer = .allocate(capacity: frames)
            monoBuffer.initialize(repeating: 0, count: frames)
            monoCapacity = frames
        }
        if abs(sr - rig.sampleRate) > 0.5 {
            rig.setSampleRate(sr)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.editor?.sampleRateChanged() } }
        }
    }

    public override func deallocateRenderResources() {
        pullBuffer = nil
        super.deallocateRenderResources()
    }

    public override var internalRenderBlock: AUInternalRenderBlock {
        let rig = self.rig
        return { [unowned self] _, timestamp, frameCount, _, outputData, _, pullInputBlock in
            guard let pull = pullInputBlock, let pb = self.pullBuffer else { return kAudioUnitErr_NoConnection }
            let frames = Int(frameCount)
            // never write past the buffers, whatever block size arrives
            guard frames <= self.monoCapacity, frameCount <= pb.frameCapacity else { return kAudioUnitErr_TooManyFramesToProcess }
            let mono = self.monoBuffer
            pb.frameLength = frameCount
            var flags = AudioUnitRenderActionFlags()
            let inList = pb.mutableAudioBufferList
            // ask for input into our buffer
            let abl = UnsafeMutableAudioBufferListPointer(inList)
            for i in 0..<abl.count { abl[i].mDataByteSize = frameCount * 4 }
            let status = pull(&flags, timestamp, frameCount, 0, inList)
            if status != noErr { return status }
            let outs = UnsafeMutableAudioBufferListPointer(outputData)
            // mono sum of the input
            let nIn = abl.count
            for f in 0..<frames {
                var s: Float = 0
                for c in 0..<nIn { s += abl[c].mData!.assumingMemoryBound(to: Float.self)[f] }
                mono[f] = s / Float(max(nIn, 1))
            }
            if self.shouldBypassEffect {
                // pass through untouched
                for c in 0..<outs.count {
                    let src = abl[min(c, nIn - 1)].mData!.assumingMemoryBound(to: Float.self)
                    if outs[c].mData == nil { outs[c].mData = UnsafeMutableRawPointer(mutating: src); continue }
                    outs[c].mData!.assumingMemoryBound(to: Float.self).update(from: src, count: frames)
                }
                return noErr
            }
            rig.process(mono, mono, frames)
            for c in 0..<outs.count {
                if outs[c].mData == nil { outs[c].mData = abl[min(c, nIn - 1)].mData }
                outs[c].mData!.assumingMemoryBound(to: Float.self).update(from: mono, count: frames)
                outs[c].mDataByteSize = frameCount * 4
            }
            return noErr
        }
    }

    // MARK: State (sessions and presets)

    public override var fullState: [String: Any]? {
        get {
            var s = super.fullState ?? [:]
            let data: Data? = Thread.isMainThread
                ? MainActor.assumeIsolated { editor?.encodedDocument() }
                : DispatchQueue.main.sync { MainActor.assumeIsolated { editor?.encodedDocument() } }
            if let data { s["lutherie.document"] = data }
            return s
        }
        set {
            guard let s = newValue else { return }
            super.fullState = s
            if let data = (s["lutherie.document"] ?? s["pedallab.document"]) as? Data {
                let apply = { MainActor.assumeIsolated { _ = self.editor?.decodeDocument(data) } }
                if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
            }
        }
    }
}

/// The plugin window: hosts the SwiftUI editor. Also the factory the host calls to create the effect.
@objc(LutherieViewController)
public final class LutherieViewController: AUViewController, AUAudioUnitFactory {
    var unit: LutherieAudioUnit?

    public func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        let u = try LutherieAudioUnit(componentDescription: componentDescription, options: [])
        unit = u
        DispatchQueue.main.async { self.showEditor() }
        return u
    }

    public override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 820))
        preferredContentSize = NSSize(width: 1280, height: 820)
        showEditor()
    }

    @MainActor func showEditor() {
        // build the editor once: replacing a live hosting view while SwiftUI is laying it out is asking for trouble
        guard isViewLoaded, let unit, let editor = unit.editor, !view.subviews.contains(where: { $0 is NSHostingView<EditorView<EmptyView>> }) else { return }
        let host = NSHostingView(rootView: EditorView(model: editor) { EmptyView() })
        host.frame = view.bounds
        host.autoresizingMask = [.width, .height]
        view.addSubview(host)
    }
}
