import AppKit
import AVFoundation
import PedalCore
import PedalUI
import SwiftUI

/// The standalone app: hosts the same effect the plugin uses, fed by a built-in riff, an audio file or a live input.
@MainActor
final class AudioHost: ObservableObject {
    enum Source: String, CaseIterable, Identifiable {
        case demo = "Demo riff", file = "Audio file", live = "Live input"
        var id: String { rawValue }
    }

    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    var effect: AVAudioUnit?
    var synthNode: AVAudioSourceNode?
    var fileBuffer: AVAudioPCMBuffer?
    let synth = DemoGuitar()
    @Published var unit: LutherieAudioUnit?
    @Published var source: Source = .demo
    @Published var playing = false
    @Published var fileName: String?
    @Published var status: String?

    static let inProcess = AudioComponentDescription(componentType: kAudioUnitType_Effect,
                                                      componentSubType: 0x4C757430 /* Lut0 */,
                                                      componentManufacturer: 0x43686E6C /* Chnl */,
                                                      componentFlags: 0, componentFlagsMask: 0)

    init() {
        AUAudioUnit.registerSubclass(LutherieAudioUnit.self, as: AudioHost.inProcess, name: "Channel Audio: Lutherie (app)", version: 1)
        AVAudioUnit.instantiate(with: AudioHost.inProcess, options: []) { [weak self] av, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let av else { self.status = "Couldn't start the effect: \(error?.localizedDescription ?? "unknown")"; return }
                self.effect = av
                self.unit = av.auAudioUnit as? LutherieAudioUnit
                self.engine.attach(av)
                self.engine.attach(self.player)
                self.start()
            }
        }
    }

    func start() {
        engine.stop()
        guard let effect else { return }
        engine.disconnectNodeOutput(player)
        if let s = synthNode { engine.disconnectNodeOutput(s); engine.detach(s); synthNode = nil }
        engine.disconnectNodeInput(effect)
        engine.disconnectNodeOutput(effect)
        let outFormat = engine.outputNode.inputFormat(forBus: 0)
        let sr = outFormat.sampleRate > 0 ? outFormat.sampleRate : 48_000
        let stereo = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        engine.connect(effect, to: engine.mainMixerNode, format: stereo)
        switch source {
        case .demo:
            synth.prepare(sampleRate: sr)
            let synth = self.synth
            let mono = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
            let node = AVAudioSourceNode(format: mono) { _, _, frames, abl -> OSStatus in
                let buf = UnsafeMutableAudioBufferListPointer(abl)
                synth.render(buf[0].mData!.assumingMemoryBound(to: Float.self), Int(frames))
                return noErr
            }
            synthNode = node
            engine.attach(node)
            engine.connect(node, to: effect, format: mono)
        case .file:
            if let b = fileBuffer {
                engine.connect(player, to: effect, format: b.format)
                player.scheduleBuffer(b, at: nil, options: .loops)
            } else { status = "Choose an audio file first."; return }
        case .live:
            let inFormat = engine.inputNode.inputFormat(forBus: 0)
            guard inFormat.channelCount > 0 else { status = "No audio input found."; return }
            engine.connect(engine.inputNode, to: effect, format: inFormat)
        }
        // Snapshots for testing are taken silently.
        if CommandLine.arguments.contains("--snapshot") { engine.mainMixerNode.outputVolume = 0 }
        do {
            engine.prepare()
            try engine.start()
            if source == .file { player.play() }
            playing = true
            status = nil
        } catch {
            playing = false
            status = "Audio couldn't start: \(error.localizedDescription)"
        }
    }

    func stop() {
        player.stop()
        engine.stop()
        playing = false
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.message = "Choose a dry guitar recording (DI) to play through the rig"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let file = try AVAudioFile(forReading: url)
            let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buf)
            fileBuffer = buf
            fileName = url.lastPathComponent
            source = .file
            start()
        } catch { status = "Couldn't read that file: \(error.localizedDescription)" }
    }
}

struct SourceBar: View {
    @ObservedObject var host: AudioHost
    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: $host.source) {
                ForEach(AudioHost.Source.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().frame(width: 120)
            .onChange(of: host.source) { _, s in if s == .file && host.fileBuffer == nil { host.chooseFile() } else { host.start() } }
            if host.source == .file {
                Button(host.fileName ?? "Choose file…") { host.chooseFile() }.lineLimit(1).frame(maxWidth: 160)
            }
            Button { host.playing ? host.stop() : host.start() } label: {
                Image(systemName: host.playing ? "stop.fill" : "play.fill").foregroundColor(Theme.accent)
            }
            .help(host.playing ? "Stop" : "Play")
            if let s = host.status { Text(s).font(.system(size: 11)).foregroundColor(.orange).lineLimit(1) }
            Button {
                AppDelegate.notify(PluginInstaller.installIfNeeded(force: true) ?? "The plugins are already up to date.")
            } label: { Label("Install plugins", systemImage: "puzzlepiece.extension") }
            .help("Install the Audio Unit and VST3 versions of Lutherie for your music software")
        }
    }
}

struct ContentView: View {
    @ObservedObject var host: AudioHost
    var body: some View {
        Group {
            if let unit = host.unit, let editor = unit.editor {
                EditorView(model: editor) { SourceBar(host: host) }
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(host.status ?? "Starting the audio engine…").foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 1180, minHeight: 760)
        .task(id: host.unit != nil) {
            guard let editor = host.unit?.editor else { return }
            // Testing aid: `--preset "Name"` opens that starter circuit (pedal or amp) at launch.
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--preset"), i + 1 < args.count {
                if let p = Presets.pedals.first(where: { $0.name == args[i + 1] }) { if let f = editor.pedals.first { editor.open(.pedal(f.id)) }; editor.load(preset: p) }
                else if let p = Presets.amps.first(where: { $0.name == args[i + 1] }) { editor.open(.amp); editor.load(preset: p) }
                if let z = args.firstIndex(of: "--zoom"), z + 1 < args.count, let v = Double(args[z + 1]) { editor.zoom = v }
            }
            // Testing aid: `--learn-demo` turns learn mode on and moves the first pedal knob.
            guard args.contains("--learn-demo") else { return }
            editor.learnMode = true
            try? await Task.sleep(for: .seconds(2))
            editor.setParam(.pedalKnob1, 0.15)
            try? await Task.sleep(for: .seconds(0.2))
            editor.setParam(.pedalKnob1, 0.95)
        }
    }
}

struct LutherieApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var host = AudioHost()

    var body: some Scene {
        WindowGroup("Lutherie") {
            ContentView(host: host)
        }
        .defaultSize(width: 1440, height: 920)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Session…") { host.unit?.editor.openDocumentPanel() }.keyboardShortcut("o")
                Button("Save Session…") { host.unit?.editor.saveDocumentPanel() }.keyboardShortcut("s")
                Divider()
                Button("Export SPICE Netlist…") { host.unit?.editor.exportSpicePanel() }.keyboardShortcut("e")
                Button("Load Amp Profile…") { host.unit?.editor.loadProfilePanel() }
                Button("Load Cabinet Impulse…") { host.unit?.editor.loadImpulsePanel() }
                Button("Play Audio File…") { host.chooseFile() }
                Divider()
                Button("Install Plugins Again") {
                    AppDelegate.notify(PluginInstaller.installIfNeeded(force: true) ?? "The plugins are already up to date.")
                }
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { host.unit?.editor.undo() }.keyboardShortcut("z")
                Button("Redo") { host.unit?.editor.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandMenu("Audio") {
                Button(host.playing ? "Stop" : "Play") { host.playing ? host.stop() : host.start() }.keyboardShortcut(.space, modifiers: [])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Testing aid: `Lutherie --snapshot out.png [seconds]` saves a picture of the window and quits.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let path = args[i + 1]
            let delay = i + 2 < args.count ? Double(args[i + 2]) ?? 6 : 6
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if let view = (NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.windows.first(where: { $0.contentView != nil }))?.contentView,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                NSApp.terminate(nil)
            }
        } else {
            // Install (or update) the plugins that ship inside the app.
            DispatchQueue.global(qos: .utility).async {
                let message = PluginInstaller.installIfNeeded()
                guard let message else { return }
                DispatchQueue.main.async { AppDelegate.notify(message) }
            }
        }
    }

    static func notify(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Lutherie"
        var text = message
        if !PluginInstaller.isInApplications {
            text += "\n\nTip: move Lutherie into your Applications folder so it stays put (then open it once more)."
        }
        alert.informativeText = text
        alert.runModal()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// Testing aid: `Lutherie --render "Preset name" out.png` draws that starter circuit to a picture and quits.
if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 2 < CommandLine.arguments.count {
    let name = CommandLine.arguments[i + 1]
    guard let circuit = (Presets.pedals + Presets.amps).first(where: { $0.name == name }),
          let data = MainActor.assumeIsolated({ SchematicSnapshot.png(circuit) }) else { print("No such preset: \(name)"); exit(1) }
    try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 2]))
    exit(0)
}

// Testing aid: `Lutherie --render-board out.png` draws the editor with a board of several pedals and quits.
if let i = CommandLine.arguments.firstIndex(of: "--render-board"), i + 1 < CommandLine.arguments.count {
    let out = CommandLine.arguments[i + 1]
    let data = MainActor.assumeIsolated {
        SchematicSnapshot.editorPNG(preset: nil, board: ["JFET Clean Boost", "Two-Transistor Fuzz", "Germanium Treble Booster", "Selectable-Clip Overdrive"].compactMap { n in Presets.pedals.first { $0.name == n } }, width: 2100)
    }
    if let data { try? data.write(to: URL(fileURLWithPath: out)) }
    exit(data == nil ? 1 : 0)
}
// Testing aid: `Lutherie --render-ui "Preset name" out.png` draws the whole editor off screen and quits.
if let i = CommandLine.arguments.firstIndex(of: "--render-ui"), i + 2 < CommandLine.arguments.count {
    let name = CommandLine.arguments[i + 1]
    let data = MainActor.assumeIsolated { SchematicSnapshot.editorPNG(preset: (Presets.pedals + Presets.amps).first { $0.name == name }) }
    try? data?.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 2]))
    exit(data == nil ? 1 : 0)
}

LutherieApp.main()
