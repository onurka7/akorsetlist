import AVFoundation
import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    AudioDecoder.register(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}

/// Decodes compressed audio (MP3, M4A, AAC, ...) to mono float32 PCM for the
/// on-device chord analyzer. Output goes to a temporary file whose path is
/// returned. Keep in sync with the iOS copy in ios/Runner/AppDelegate.swift.
enum AudioDecoder {
  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "akor_setlist/audio_decoder", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "decodeToPcm",
            let args = call.arguments as? [String: Any],
            let path = args["path"] as? String,
            let rate = args["sampleRate"] as? Int
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let out = try decode(path: path, sampleRate: Double(rate))
          DispatchQueue.main.async { result(out) }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "decode_failed", message: error.localizedDescription, details: nil))
          }
        }
      }
    }
  }

  static func decode(path: String, sampleRate: Double) throws -> String {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let track = asset.tracks(withMediaType: .audio).first else {
      throw NSError(domain: "AudioDecoder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Dosyada ses kanalı yok."])
    }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
      AVNumberOfChannelsKey: 1,
      AVSampleRateKey: sampleRate,
    ])
    reader.add(output)
    guard reader.startReading() else {
      throw reader.error ?? NSError(domain: "AudioDecoder", code: 2, userInfo: nil)
    }
    let outURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".f32")
    FileManager.default.createFile(atPath: outURL.path, contents: nil)
    let handle = try FileHandle(forWritingTo: outURL)
    defer { try? handle.close() }
    while let sample = output.copyNextSampleBuffer() {
      if let block = CMSampleBufferGetDataBuffer(sample) {
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        data.withUnsafeMutableBytes { raw in
          _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        handle.write(data)
      }
      CMSampleBufferInvalidate(sample)
    }
    if reader.status == .failed {
      throw reader.error ?? NSError(domain: "AudioDecoder", code: 3, userInfo: nil)
    }
    return outURL.path
  }
}
