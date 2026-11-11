import AppKit
import PedalCore
import PedalUI
import SwiftUI

/// C entry points so the VST3 plugin (C++) can drive the same rig and editor as the Audio Unit.
public typealias PedalParamCallback = @convention(c) (UnsafeMutableRawPointer?, Int32, Float) -> Void

final class VSTInstance: ParamBridge {
    let rig: Rig
    var editor: EditorModel?
    var callback: PedalParamCallback?
    var context: UnsafeMutableRawPointer?
    var hosting: NSView?
    let mono: UnsafeMutablePointer<Float>
    let monoCap = 8192

    init(sampleRate: Double) {
        rig = Rig(sampleRate: sampleRate, maxFrames: 4096)
        mono = .allocate(capacity: monoCap)
        onMain { MainActor.assumeIsolated {
            let m = EditorModel()
            self.editor = m
            m.attach(self)
        } }
    }
    deinit { mono.deallocate() }

    func value(_ p: RigParam) -> Float { rig[p] }

    /// A change made in the editor: apply it and tell the host.
    func set(_ p: RigParam, _ v: Float) {
        rig[p] = v
        callback?(context, Int32(p.rawValue), rig[p])
    }

    /// Parameter id −1 on the callback means "latency changed".
    func latencyChanged() { callback?(context, -1, Float(rig.expectedLatency)) }
}

func onMain(_ body: @escaping () -> Void) {
    if Thread.isMainThread { body() } else { DispatchQueue.main.sync(execute: body) }
}

@inline(__always) func inst(_ p: UnsafeMutableRawPointer) -> VSTInstance { Unmanaged<VSTInstance>.fromOpaque(p).takeUnretainedValue() }

@_cdecl("pedal_create")
public func pedal_create(_ sampleRate: Double) -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(VSTInstance(sampleRate: sampleRate)).toOpaque()
}

@_cdecl("pedal_destroy")
public func pedal_destroy(_ p: UnsafeMutableRawPointer) {
    let i = inst(p)
    onMain { i.hosting?.removeFromSuperview(); i.hosting = nil }
    Unmanaged<VSTInstance>.fromOpaque(p).release()
}

@_cdecl("pedal_set_callback")
public func pedal_set_callback(_ p: UnsafeMutableRawPointer, _ cb: PedalParamCallback?, _ ctx: UnsafeMutableRawPointer?) {
    inst(p).callback = cb
    inst(p).context = ctx
}

@_cdecl("pedal_set_sample_rate")
public func pedal_set_sample_rate(_ p: UnsafeMutableRawPointer, _ sr: Double) {
    let i = inst(p)
    guard abs(i.rig.sampleRate - sr) > 0.5 else { return }
    i.rig.setSampleRate(sr)
    onMain { MainActor.assumeIsolated { i.editor?.sampleRateChanged() } }
}

/// Mono in, mono out (the plugin sums and spreads channels).
@_cdecl("pedal_process")
public func pedal_process(_ p: UnsafeMutableRawPointer, _ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>, _ frames: Int32) {
    inst(p).rig.process(input, output, Int(frames))
}

@_cdecl("pedal_set_param")
public func pedal_set_param(_ p: UnsafeMutableRawPointer, _ id: Int32, _ v: Float) {
    if let rp = RigParam(rawValue: Int(id)) { inst(p).rig[rp] = v }
}

@_cdecl("pedal_get_param")
public func pedal_get_param(_ p: UnsafeMutableRawPointer, _ id: Int32) -> Float {
    RigParam(rawValue: Int(id)).map { inst(p).rig[$0] } ?? 0
}

/// Delay through the plugin in samples (oversampling filters and profile resampling).
@_cdecl("pedal_get_latency")
public func pedal_get_latency(_ p: UnsafeMutableRawPointer) -> Int32 { Int32(inst(p).rig.expectedLatency) }

@_cdecl("pedal_param_count")
public func pedal_param_count() -> Int32 { Int32(RigParam.allCases.count) }

/// Describes parameter `index`: id, name (UTF-8 into buf), range, default and step count (0 = continuous).
@_cdecl("pedal_param_info")
public func pedal_param_info(_ index: Int32, _ id: UnsafeMutablePointer<Int32>, _ name: UnsafeMutablePointer<CChar>, _ nameCap: Int32,
                             _ minV: UnsafeMutablePointer<Float>, _ maxV: UnsafeMutablePointer<Float>,
                             _ def: UnsafeMutablePointer<Float>, _ steps: UnsafeMutablePointer<Int32>, _ unit: UnsafeMutablePointer<CChar>) {
    let p = RigParam.allCases[Int(index)]
    id.pointee = Int32(p.rawValue)
    minV.pointee = p.range.lowerBound
    maxV.pointee = p.range.upperBound
    def.pointee = p.defaultValue
    steps.pointee = p.isIndexed ? Int32(p.range.upperBound - p.range.lowerBound) : 0
    func copy(_ s: String, _ dst: UnsafeMutablePointer<CChar>, _ cap: Int) {
        let bytes = Array(s.utf8.prefix(cap - 1))
        for (k, b) in bytes.enumerated() { dst[k] = CChar(bitPattern: b) }
        dst[bytes.count] = 0
    }
    copy(p.name, name, Int(nameCap))
    copy(p.unit, unit, 16)
}

/// Writes the session (circuits, settings, loaded profile and cabinet) into buf; returns the full size.
@_cdecl("pedal_get_state")
public func pedal_get_state(_ p: UnsafeMutableRawPointer, _ buf: UnsafeMutablePointer<UInt8>?, _ cap: Int32) -> Int32 {
    var data = Data()
    onMain { MainActor.assumeIsolated { data = inst(p).editor?.encodedDocument() ?? Data() } }
    if let buf, cap >= Int32(data.count) { data.copyBytes(to: buf, count: data.count) }
    return Int32(data.count)
}

@_cdecl("pedal_set_state")
public func pedal_set_state(_ p: UnsafeMutableRawPointer, _ buf: UnsafePointer<UInt8>, _ len: Int32) {
    let data = Data(bytes: buf, count: Int(len))
    let i = inst(p)
    let apply = { MainActor.assumeIsolated { _ = i.editor?.decodeDocument(data) } }
    if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
}

@_cdecl("pedal_attach_view")
public func pedal_attach_view(_ p: UnsafeMutableRawPointer, _ parent: UnsafeMutableRawPointer) {
    let i = inst(p)
    onMain { MainActor.assumeIsolated {
        guard let editor = i.editor else { return }
        let parentView = Unmanaged<NSView>.fromOpaque(parent).takeUnretainedValue()
        let host = NSHostingView(rootView: EditorView(model: editor) { EmptyView() })
        host.frame = parentView.bounds
        host.autoresizingMask = [.width, .height]
        parentView.addSubview(host)
        i.hosting = host
    } }
}

@_cdecl("pedal_detach_view")
public func pedal_detach_view(_ p: UnsafeMutableRawPointer) {
    let i = inst(p)
    onMain { i.hosting?.removeFromSuperview(); i.hosting = nil }
}
