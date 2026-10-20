import AudioToolbox
import Foundation
import os

/// 「轉成其他格式」：轉出的檔案放在同一資料夾、同名換副檔名（重名加 (2)…），⛔ 不覆蓋、不刪原檔。
/// 轉檔中寫到隱藏暫存檔，完成才改成正式檔名（取消或失敗不會留下半個檔案）。
enum ExportFormat: String, CaseIterable, Identifiable {
    case mp3, wav, flac, aiff, m4a
    var id: String { rawValue }
    var ext: String { rawValue }
    var title: String {
        switch self {
        case .mp3: L("format.mp3")
        case .wav: L("format.wav")
        case .flac: L("format.flac")
        case .aiff: L("format.aiff")
        case .m4a: L("format.m4a")
        }
    }
}

@MainActor
final class Exporter: ObservableObject {
    @Published private(set) var progress: Double?      // nil＝沒有在轉
    @Published private(set) var label = ""
    @Published var resultMessage: String?
    /// 轉好一個檔案後遞增，讓列表重新整理。
    @Published private(set) var finishedCount = 0

    private let cancelFlag = OSAllocatedUnfairLock(initialState: false)
    var isBusy: Bool { progress != nil }

    func cancel() { cancelFlag.withLock { $0 = true } }

    func export(_ source: URL, to format: ExportFormat) {
        guard !isBusy else { return }
        let dest = Self.uniqueURL(for: source, ext: format.ext)
        let temp = source.deletingLastPathComponent().appendingPathComponent(".export-\(UUID().uuidString).\(format.ext)")
        cancelFlag.withLock { $0 = false }
        progress = 0
        label = String(format: L("convert.progress"), dest.lastPathComponent)
        let flag = cancelFlag
        DispatchQueue.global(qos: .userInitiated).async {
            let report: (Double) -> Void = { p in DispatchQueue.main.async { if self.progress != nil { self.progress = p } } }
            let cancelled: () -> Bool = { flag.withLock { $0 } }
            var err: String?
            var finalName = ""
            do {
                switch format {
                case .m4a: try FileManager.default.copyItem(at: source, to: temp)   // 原檔就是 AAC 256 kbps：直接另存，不重新編碼（不損失）
                case .mp3: try MP3Encoder.encode(source, to: temp, progress: report, cancelled: cancelled)
                case .wav, .flac, .aiff: try PCMExporter.export(source, to: temp, format: format, progress: report, cancelled: cancelled)
                }
                if cancelled() { throw CancellationError() }
                let final = Self.uniqueURL(for: source, ext: format.ext)
                try FileManager.default.moveItem(at: temp, to: final)
                finalName = final.lastPathComponent
            } catch is CancellationError {
                err = L("convert.cancelled")
            } catch {
                err = String(format: L("convert.failed"), error.localizedDescription)
            }
            if err != nil { try? FileManager.default.removeItem(at: temp) }
            DispatchQueue.main.async {
                DebugLog.write("export \(source.lastPathComponent) -> \(format.ext): \(err ?? "ok")")
                self.progress = nil
                self.resultMessage = err
                AppModel.shared.notices.post(err.map { .message($0) } ?? .exportDone(file: finalName))
                self.finishedCount += 1
            }
        }
    }

    nonisolated static func uniqueURL(for source: URL, ext: String) -> URL {
        let dir = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        var url = dir.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) (\(n))").appendingPathExtension(ext)
            n += 1
        }
        return url
    }
}

struct ExportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ m: String) { message = m }
    init(_ step: String, _ st: OSStatus) { message = "\(step) (OSStatus \(st))" }
}

/// 讀 m4a → Float32 交錯取樣的小工具。
struct SourceReader {
    let file: ExtAudioFileRef
    let sampleRate: Double
    let channels: Int
    let totalFrames: Int64

    init(_ url: URL) throws {
        var f: ExtAudioFileRef?
        var st = ExtAudioFileOpenURL(url as CFURL, &f)
        guard st == noErr, let f else { throw ExportError("ExtAudioFileOpenURL", st) }
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ExtAudioFileGetProperty(f, kExtAudioFileProperty_FileDataFormat, &size, &asbd)
        var frames: Int64 = 0
        size = UInt32(MemoryLayout<Int64>.size)
        ExtAudioFileGetProperty(f, kExtAudioFileProperty_FileLengthFrames, &size, &frames)
        sampleRate = asbd.mSampleRate
        channels = Int(asbd.mChannelsPerFrame)
        totalFrames = frames
        var client = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        st = ExtAudioFileSetProperty(f, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
        guard st == noErr else { ExtAudioFileDispose(f); throw ExportError("ClientDataFormat", st) }
        file = f
    }

    var clientFormat: AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
    }

    /// 讀最多 maxFrames 影格到 buffer，回傳實際影格數（0＝讀完）。
    func read(into buffer: UnsafeMutablePointer<Float>, maxFrames: Int) throws -> Int {
        var frames = UInt32(maxFrames)
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: UInt32(channels), mDataByteSize: UInt32(maxFrames * channels * 4), mData: UnsafeMutableRawPointer(buffer)))
        let st = ExtAudioFileRead(file, &frames, &list)
        guard st == noErr else { throw ExportError("ExtAudioFileRead", st) }
        return Int(frames)
    }

    func close() { ExtAudioFileDispose(file) }
}

/// WAV／AIFF（16-bit PCM）、FLAC（無損）：用 AudioToolbox 的 ExtAudioFile 轉。
enum PCMExporter {
    static func export(_ src: URL, to dst: URL, format: ExportFormat,
                       progress: (Double) -> Void, cancelled: () -> Bool) throws {
        let reader = try SourceReader(src)
        defer { reader.close() }
        let ch = UInt32(reader.channels)
        var out = AudioStreamBasicDescription()
        out.mSampleRate = reader.sampleRate
        out.mChannelsPerFrame = ch
        let fileType: AudioFileTypeID
        switch format {
        case .wav, .aiff:
            out.mFormatID = kAudioFormatLinearPCM
            out.mBitsPerChannel = 16
            out.mBytesPerFrame = 2 * ch
            out.mBytesPerPacket = 2 * ch
            out.mFramesPerPacket = 1
            out.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
                | (format == .aiff ? kAudioFormatFlagIsBigEndian : 0)
            fileType = format == .wav ? kAudioFileWAVEType : kAudioFileAIFFType
        default:
            out.mFormatID = kAudioFormatFLAC
            out.mFormatFlags = kAppleLosslessFormatFlag_16BitSourceData
            fileType = kAudioFileFLACType
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &size, &out)
        }
        var f: ExtAudioFileRef?
        var st = ExtAudioFileCreateWithURL(dst as CFURL, fileType, &out, nil, AudioFileFlags.eraseFile.rawValue, &f)
        guard st == noErr, let f else { throw ExportError("ExtAudioFileCreateWithURL(\(format.ext))", st) }
        defer { ExtAudioFileDispose(f) }
        var client = reader.clientFormat
        st = ExtAudioFileSetProperty(f, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
        guard st == noErr else { throw ExportError("ClientDataFormat(out)", st) }

        let chunk = 8192
        let buf = UnsafeMutablePointer<Float>.allocate(capacity: chunk * reader.channels)
        defer { buf.deallocate() }
        var done: Int64 = 0
        while true {
            if cancelled() { throw CancellationError() }
            let n = try reader.read(into: buf, maxFrames: chunk)
            if n == 0 { break }
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: ch, mDataByteSize: UInt32(n * reader.channels * 4), mData: UnsafeMutableRawPointer(buf)))
            st = ExtAudioFileWrite(f, UInt32(n), &list)
            guard st == noErr else { throw ExportError("ExtAudioFileWrite", st) }
            done += Int64(n)
            if reader.totalFrames > 0 { progress(min(1, Double(done) / Double(reader.totalFrames))) }
        }
    }
}

/// MP3（320 kbps CBR）：AVFoundation／AudioToolbox 沒有 MP3 編碼器，用 LAME（LGPL）。
/// 以 dlopen 動態載入 App 內附的 libmp3lame（Contents/Frameworks），使用者可自行替換該 dylib（符合 LGPL）。
enum MP3Encoder {
    private typealias LameInit = @convention(c) () -> OpaquePointer?
    private typealias LameSetInt = @convention(c) (OpaquePointer?, Int32) -> Int32
    private typealias LameInitParams = @convention(c) (OpaquePointer?) -> Int32
    private typealias LameEncodeFloat = @convention(c) (OpaquePointer?, UnsafePointer<Float>?, Int32, UnsafeMutablePointer<UInt8>?, Int32) -> Int32
    private typealias LameFlush = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UInt8>?, Int32) -> Int32
    private typealias LameClose = @convention(c) (OpaquePointer?) -> Int32

    private static func loadLibrary() -> UnsafeMutableRawPointer? {
        let candidates = [
            Bundle.main.privateFrameworksURL?.appendingPathComponent("libmp3lame.0.dylib").path,
            "/opt/homebrew/opt/lame/lib/libmp3lame.0.dylib",
            "/usr/local/opt/lame/lib/libmp3lame.0.dylib",
        ].compactMap { $0 }
        for p in candidates { if let h = dlopen(p, RTLD_NOW) { return h } }
        return nil
    }

    private static func sym<T>(_ h: UnsafeMutableRawPointer, _ name: String, _ type: T.Type) throws -> T {
        guard let p = dlsym(h, name) else { throw ExportError("LAME: \(name) not found") }
        return unsafeBitCast(p, to: type)
    }

    static func encode(_ src: URL, to dst: URL, progress: (Double) -> Void, cancelled: () -> Bool) throws {
        guard let h = loadLibrary() else { throw ExportError(L("convert.noLame")) }
        let lameInit = try sym(h, "lame_init", LameInit.self)
        let setChannels = try sym(h, "lame_set_num_channels", LameSetInt.self)
        let setInRate = try sym(h, "lame_set_in_samplerate", LameSetInt.self)
        let setOutRate = try sym(h, "lame_set_out_samplerate", LameSetInt.self)
        let setBrate = try sym(h, "lame_set_brate", LameSetInt.self)
        let setVBR = try sym(h, "lame_set_VBR", LameSetInt.self)
        let setQuality = try sym(h, "lame_set_quality", LameSetInt.self)
        let initParams = try sym(h, "lame_init_params", LameInitParams.self)
        let encodeFloat = try sym(h, "lame_encode_buffer_interleaved_ieee_float", LameEncodeFloat.self)
        let flush = try sym(h, "lame_encode_flush", LameFlush.self)
        let close = try sym(h, "lame_close", LameClose.self)

        let reader = try SourceReader(src)
        defer { reader.close() }
        guard reader.channels == 2 else { throw ExportError("MP3: expects stereo") }
        guard let gf = lameInit() else { throw ExportError("lame_init failed") }
        defer { _ = close(gf) }
        _ = setChannels(gf, 2)
        _ = setInRate(gf, Int32(reader.sampleRate))
        _ = setOutRate(gf, Int32(reader.sampleRate))
        _ = setVBR(gf, 0)          // vbr_off＝CBR
        _ = setBrate(gf, 320)
        _ = setQuality(gf, 2)      // 高品質
        guard initParams(gf) >= 0 else { throw ExportError("lame_init_params failed") }

        FileManager.default.createFile(atPath: dst.path, contents: nil)
        let out = try FileHandle(forWritingTo: dst)
        defer { try? out.close() }
        let chunk = 8192
        let pcm = UnsafeMutablePointer<Float>.allocate(capacity: chunk * 2)
        defer { pcm.deallocate() }
        let mp3Size = Int(1.25 * Double(chunk) + 7200)
        let mp3 = UnsafeMutablePointer<UInt8>.allocate(capacity: mp3Size)
        defer { mp3.deallocate() }
        var done: Int64 = 0
        while true {
            if cancelled() { throw CancellationError() }
            let n = try reader.read(into: pcm, maxFrames: chunk)
            if n == 0 { break }
            let bytes = encodeFloat(gf, pcm, Int32(n), mp3, Int32(mp3Size))
            guard bytes >= 0 else { throw ExportError("lame_encode \(bytes)") }
            if bytes > 0 { out.write(Data(bytes: mp3, count: Int(bytes))) }
            done += Int64(n)
            if reader.totalFrames > 0 { progress(min(1, Double(done) / Double(reader.totalFrames))) }
        }
        let tail = flush(gf, mp3, Int32(mp3Size))
        if tail > 0 { out.write(Data(bytes: mp3, count: Int(tail))) }
    }
}
