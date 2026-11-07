import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import VideoToolbox

/// The project's colour setting (`ProjectSettings.color`): SDR Rec.709 (the default) or HDR Rec.2020 with HLG or PQ.
///
/// SDR projects take none of this: the compositor's unmanaged context, NSNull-tagged sources and Rec.709 tags, exactly
/// as before. In an HDR project:
/// - the composition is drawn in a second Core Image context whose working space is extended sRGB (non-linear, values
///   past 1.0 allowed). SDR sources and stills stay untagged, so their values pass into it unchanged, exactly as in SDR;
///   HDR sources (frames whose transfer function is HLG or PQ) are tagged as such and converted, so an iPhone HLG
///   highlight arrives above 1.0 instead of clipped (HLG 1.0 ≈ 1.99, HLG 0.75 = SDR white = 1.0).
/// - the masters (HEVC 10-bit, ProRes) write Rec.2020 HLG or PQ: SDR white lands at 203 nits (HLG 0.75, PQ 0.58, as
///   BT.2408 has it) and the frames carry the colour tags (and, for PQ, mastering-display and light-level metadata).
/// - everything else that reads the composition (H.264 exports, `capture_frame`, frame stats, thumbnails) gets SDR:
///   HDR sources are tone-mapped into SDR range (`CIToneMapHeadroom`) and SDR sources pass unchanged.
/// - the preview is drawn exactly as an SDR project's (`configure` leaves its composition alone). It was HDR once, but
///   macOS shows a paused HDR frame (a still) differently from the same frames playing, so picking HLG or PQ changed
///   the paused picture and playing put it back; and an HDR-capable compositor is handed SDR sources already converted
///   toward its colour tags (a 709 blue came in as 30,78,203 instead of 28,68,196). Now the setting never changes it.
enum ColorManagement {
    /// How a composition's frames leave the compositor.
    enum Output: Equatable {
        case passthrough            // SDR project: as always
        case hdr(ProjectColor)      // HDR frames in Rec.2020 HLG or PQ
        case toneMapped             // an HDR project read for an SDR use (exports, captures)

        var isPassthrough: Bool { self == .passthrough }
    }

    static let workingSpace = CGColorSpace(name: CGColorSpace.extendedSRGB)!
    static let context = CIContext(options: [.cacheIntermediates: false, .name: "EditMaxHDR", .workingColorSpace: workingSpace, .workingFormat: CIFormat.RGBAh])
    static let sdrSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    static func space(_ c: ProjectColor) -> CGColorSpace {
        CGColorSpace(name: c == .pq ? CGColorSpace.itur_2100_PQ : CGColorSpace.itur_2100_HLG)!
    }

    /// HDR headroom assumed for HDR sources when tone-mapping to SDR: a 1000-nit peak over 203-nit reference white.
    static let sourceHeadroom = 1000.0 / 203.0

    // MARK: Composition

    /// Sets an HDR project's composition up after the builder made it: swaps in the HDR compositor that matches the one
    /// asked for, sets the Rec.2020 colour properties where the output is HDR, and tells every instruction and source
    /// how to treat colour. SDR projects and the preview (drawn as in SDR, see the note at the top): returns at once.
    static func configure(_ vc: AVMutableVideoComposition, compositor: AVVideoCompositing.Type, color: ProjectColor) {
        guard color.isHDR, !(compositor is EditMaxPreviewCompositor.Type) else { return }
        let output: Output
        if compositor is EditMaxCompositor10.Type { vc.customVideoCompositorClass = EditMaxCompositorHDR.self; output = .hdr(color) }
        else { vc.customVideoCompositorClass = EditMaxCompositorToneMapped.self; output = .toneMapped }
        if case .hdr = output {
            vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_2020
            vc.colorTransferFunction = color == .pq ? AVVideoTransferFunction_SMPTE_ST_2084_PQ : AVVideoTransferFunction_ITU_R_2100_HLG
            vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_2020
        } else {
            // Said outright: a compositor that takes HDR sources but leaves the output untagged has its SDR frames
            // read as HDR downstream and tone-mapped a second time (SDR sources came out darker).
            vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
            vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
            vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        }
        for case let inst as EditMaxInstruction in vc.instructions {
            inst.output = output
            for l in inst.layers { l.current.output = output; l.outgoing?.output = output }
        }
    }

    /// A decoded source frame for an HDR project: HLG and PQ frames tagged with their colour space (Core Image converts
    /// them into the working space, keeping values above SDR white), tone-mapped into SDR range for an SDR output;
    /// every other frame untagged, as in SDR projects.
    static func source(_ buf: CVPixelBuffer, _ output: Output) -> CIImage {
        guard let space = hdrSpace(of: buf) else { return CIImage(cvPixelBuffer: buf, options: [.colorSpace: NSNull()]) }
        let img = CIImage(cvPixelBuffer: buf, options: [.colorSpace: space])
        guard output == .toneMapped else { return img }
        return toneMapped(img)
    }

    static func toneMapped(_ img: CIImage) -> CIImage {
        guard let f = CIFilter(name: "CIToneMapHeadroom") else { return img }
        // The headrooms are linear ratios and the working space is non-linear extended sRGB: map in linear light.
        f.setValue(img.applyingFilter("CISRGBToneCurveToLinear"), forKey: kCIInputImageKey)
        f.setValue(sourceHeadroom, forKey: "inputSourceHeadroom")
        f.setValue(1.0, forKey: "inputTargetHeadroom")
        return f.outputImage?.applyingFilter("CILinearToSRGBToneCurve") ?? img
    }

    /// The colour space of an HLG or PQ frame, from its transfer-function attachment; nil for anything else.
    static func hdrSpace(of buf: CVPixelBuffer) -> CGColorSpace? {
        guard let tf = CVBufferCopyAttachment(buf, kCVImageBufferTransferFunctionKey, nil) as? String else { return nil }
        if tf == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String) { return CGColorSpace(name: CGColorSpace.itur_2100_HLG) }
        if tf == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String) { return CGColorSpace(name: CGColorSpace.itur_2100_PQ) }
        return nil
    }

    /// Draws a composed frame for an HDR project; false for an SDR one (the caller draws it as always).
    static func render(_ image: CIImage, to out: CVPixelBuffer, _ inst: EditMaxInstruction) -> Bool {
        let bounds = CGRect(origin: .zero, size: inst.renderSize)
        switch inst.output {
        case .passthrough: return false
        case .hdr(let c):
            attach(out, c)
            context.render(image, to: out, bounds: bounds, colorSpace: space(c))
        case .toneMapped:
            context.render(image, to: out, bounds: bounds, colorSpace: sdrSpace)
            CVBufferSetAttachment(out, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(out, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(out, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        }
        return true
    }

    /// Rec.2020 HLG / PQ tags on a frame; for PQ also the static metadata: a P3-D65 mastering display of 1000 nits down
    /// to 0.0001, MaxCLL 1000 and MaxFALL 400 (EditMax does not measure the content's own light levels).
    static func attach(_ buf: CVPixelBuffer, _ c: ProjectColor) {
        CVBufferSetAttachment(buf, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(buf, kCVImageBufferTransferFunctionKey, c == .pq ? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ : kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
        CVBufferSetAttachment(buf, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        if c == .pq {
            CVBufferSetAttachment(buf, kCVImageBufferMasteringDisplayColorVolumeKey, masteringDisplay as CFData, .shouldPropagate)
            CVBufferSetAttachment(buf, kCVImageBufferContentLightLevelInfoKey, contentLightLevel as CFData, .shouldPropagate)
        }
    }

    /// SMPTE ST 2086 as HEVC's SEI carries it (big-endian): G, B, R primaries and the white point in 0.00002 steps,
    /// then the max and min luminance in 0.0001 cd/m² steps.
    static let masteringDisplay: Data = {
        var d = Data()
        func u16(_ v: Double) { let x = UInt16((v / 0.00002).rounded()).bigEndian; withUnsafeBytes(of: x) { d.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
        u16(0.265); u16(0.690); u16(0.150); u16(0.060); u16(0.680); u16(0.320)   // P3 G, B, R
        u16(0.3127); u16(0.3290)                                                   // D65
        u32(1000 * 10000); u32(1)                                                  // 1000 nits, 0.0001 nits
        return d
    }()
    static let contentLightLevel: Data = {
        var d = Data()
        for v: UInt16 in [1000, 400] { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
        return d
    }()

    // MARK: Masters

    /// The writer settings of a master for an HDR project: Rec.2020 HLG or PQ tags in place of Rec.709 and, for PQ HEVC,
    /// the mastering-display and light-level metadata (dropped again when this Mac's writer does not take them; the
    /// frames carry them as attachments too). SDR projects: unchanged.
    static func tagMaster(_ video: inout [String: Any], preset: ExportService.Preset, color: ProjectColor, writer: AVAssetWriter) {
        guard color.isHDR else { return }
        video[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                                            AVVideoTransferFunctionKey: color == .pq ? AVVideoTransferFunction_SMPTE_ST_2084_PQ : AVVideoTransferFunction_ITU_R_2100_HLG,
                                            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020]
        guard color == .pq, preset == .hevc10, var props = video[AVVideoCompressionPropertiesKey] as? [String: Any] else { return }
        let plain = video
        props[kVTCompressionPropertyKey_MasteringDisplayColorVolume as String] = masteringDisplay
        props[kVTCompressionPropertyKey_ContentLightLevelInfo as String] = contentLightLevel
        video[AVVideoCompressionPropertiesKey] = props
        if !writer.canApply(outputSettings: video, forMediaType: .video) { video = plain }
    }
}

// MARK: - Compositors for HDR projects

/// Masters of an HDR project: HDR source frames in, Rec.2020 HLG / PQ half-float frames out.
final class EditMaxCompositorHDR: EditMaxCompositor10 {
    @objc var supportsHDRSourceFrames: Bool { true }
    @objc var supportsWideColorSourceFrames: Bool { true }
}

/// Everything else an HDR project feeds (H.264 exports, frame captures): HDR sources tone-mapped, SDR frames out.
final class EditMaxCompositorToneMapped: EditMaxCompositor {
    @objc var supportsHDRSourceFrames: Bool { true }
}
