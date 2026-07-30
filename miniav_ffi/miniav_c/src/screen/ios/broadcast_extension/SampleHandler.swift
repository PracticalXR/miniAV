//
//  SampleHandler.swift — REFERENCE Broadcast Upload Extension sample handler
//  for miniAV's system-wide iOS screen capture (MOBILE_PLATFORM_SPEC.md §B.3b).
//
//  This is a TEMPLATE. Copy it into your Broadcast Upload Extension target and
//  edit APP_GROUP_ID below to your team's App Group. Apple requires the
//  extension to be part of your app bundle — miniAV cannot inject it. See
//  SETUP.md for the full Xcode walkthrough.
//
//  It drives the producer library (miniav_broadcast_sender.m):
//    - opens the ring LAZILY on the first video buffer (dimensions come from it)
//    - copies each NV12 CVPixelBuffer into the ring via mbs_send_video
//    - forwards app audio (interleaved PCM) via mbs_send_audio
//    - closes on broadcastFinished
//
//  ---------------------------------------------------------------------------
//  BRIDGING HEADER (required — the extension is a mixed Swift/ObjC target):
//
//  Create a file, e.g. "BroadcastExtension-Bridging-Header.h", containing:
//
//      #import "miniav_broadcast_sender.h"
//
//  Then set the extension target's Build Setting
//  "Objective-C Bridging Header" to its path
//  (e.g. $(SRCROOT)/BroadcastExtension/BroadcastExtension-Bridging-Header.h).
//  Add miniav_broadcast_sender.h/.m and miniav_broadcast_protocol.h to the
//  extension target's "Compile Sources" / header search path. See SETUP.md.
//  ---------------------------------------------------------------------------

import ReplayKit
import CoreMedia
import CoreVideo

// EDIT THIS to your App Group id (must match the host app's
// MiniAV_Screen_SetIOSAppGroup call and the App Group capability on BOTH
// targets). Example: "group.com.example.miniav".
private let APP_GROUP_ID = "group.com.example.miniav"

class SampleHandler: RPBroadcastSampleHandler {

    // The producer handle. nil until the first video buffer sizes the ring.
    private var sender: OpaquePointer? = nil
    private var openFailed = false

    override func broadcastStarted(withSetupInfo setupInfo: [String : NSObject]?) {
        // Nothing to size the ring with yet — mbs_open happens lazily on the
        // first video frame (that's where width/height come from). Do NOT open
        // here.
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                      with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .video:
            handleVideo(sampleBuffer)
        case .audioApp:
            handleAudio(sampleBuffer)
        case .audioMic:
            // Mic is optional; forward it the same way if you want it. v1
            // host consumes app audio. Uncomment to also send mic:
            // handleAudio(sampleBuffer)
            break
        @unknown default:
            break
        }
    }

    override func broadcastFinished() {
        if let s = sender {
            mbs_close(s)
            sender = nil
        }
    }

    // MARK: - Video

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Lazy open: the ring is sized to the first frame's dimensions.
        if sender == nil && !openFailed {
            let w = UInt32(CVPixelBufferGetWidth(pb))
            let h = UInt32(CVPixelBufferGetHeight(pb))
            sender = APP_GROUP_ID.withCString { gid in
                mbs_open(gid, w, h)
            }
            if sender == nil {
                // Setup failed (bad App Group, cannot map ring). Latch so we
                // don't retry every frame.
                openFailed = true
                return
            }
        }
        guard let s = sender else { return }

        // PTS -> microseconds (producer clock). The host rebases this onto its
        // own timeline; we just need a monotonic-ish us value.
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let tsUs: UInt64 = pts.isNumeric
            ? UInt64(max(0, CMTimeGetSeconds(pts) * 1_000_000.0))
            : 0

        // The single pixel copy happens inside mbs_send_video. Non-NV12 or
        // mismatched-size frames are dropped (logged once) inside the lib.
        _ = mbs_send_video(s, pb, tsUs)
    }

    // MARK: - Audio

    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let s = sender else { return } // no ring yet -> nothing to sync to
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        guard let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        guard let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc) else { return }
        let asbd = asbdPtr.pointee

        // We forward INTERLEAVED PCM. ReplayKit app audio is typically 44.1 kHz
        // stereo. If the source is non-interleaved (kAudioFormatFlagIsNonInterleaved),
        // CMBlockBuffer still gives us the first buffer's bytes; for robustness we
        // only forward the interleaved case (the common one) and skip otherwise.
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let channels = UInt16(asbd.mChannelsPerFrame)
        let sampleRate = UInt32(asbd.mSampleRate)
        // sample_format: 1 = S16 interleaved, 2 = F32 interleaved.
        let sampleFmt: UInt16 = isFloat ? 2 : 1

        if isNonInterleaved && channels > 1 {
            // Deinterleaved multi-channel — the protocol expects interleaved.
            // Skip rather than send a misinterpreted layout. (Rare for
            // ReplayKit app audio.)
            return
        }

        var lengthAtOffset: Int = 0
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>? = nil
        let status = CMBlockBufferGetDataPointer(blockBuffer,
                                                 atOffset: 0,
                                                 lengthAtOffsetOut: &lengthAtOffset,
                                                 totalLengthOut: &totalLength,
                                                 dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let data = dataPointer, totalLength > 0 else { return }

        // frame_count = samples PER CHANNEL = totalLength / (channels * bytesPerSample)
        let bytesPerSample = isFloat ? 4 : 2
        let denom = Int(channels) * bytesPerSample
        guard denom > 0 else { return }
        let frameCount = UInt32(totalLength / denom)
        guard frameCount > 0 else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let tsUs: UInt64 = pts.isNumeric
            ? UInt64(max(0, CMTimeGetSeconds(pts) * 1_000_000.0))
            : 0

        data.withMemoryRebound(to: UInt8.self, capacity: totalLength) { ptr in
            _ = mbs_send_audio(s, ptr, frameCount, sampleRate, channels, sampleFmt, tsUs)
        }
    }
}
