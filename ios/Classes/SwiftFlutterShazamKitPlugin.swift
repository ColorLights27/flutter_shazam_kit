import Flutter
import UIKit
import ShazamKit

public class SwiftFlutterShazamKitPlugin: NSObject, FlutterPlugin {
    private var session: SHSession?
    private let audioEngine = AVAudioEngine()
    private let mixerNode = AVAudioMixerNode()
    private var callbackChannel: FlutterMethodChannel?
    private var isStarting = false
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "flutter_shazam_kit", binaryMessenger: registrar.messenger())
        let instance = SwiftFlutterShazamKitPlugin(callbackChannel: FlutterMethodChannel(name: "flutter_shazam_kit_callback", binaryMessenger: registrar.messenger()))
        registrar.addMethodCallDelegate(instance, channel: channel)
    }
    
    init(callbackChannel: FlutterMethodChannel? = nil) {
        self.callbackChannel = callbackChannel
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "configureShazamKitSession":
            configureShazamKitSession()
            result(nil)
        case "startDetectionWithMicrophone":
            startDetection(result: result)
        case "endDetectionWithMicrophone":
            stopListening()
            result(nil)
        case "endSession":
            stopListening()
            session = nil
            result(nil)
        default:
            result(nil)
        }
    }
}

//MARK: ShazamKit session delegation here
//MARK: Methods for AVAudio
extension SwiftFlutterShazamKitPlugin{
    func configureShazamKitSession(){
        if session == nil{
            session = SHSession()
            session?.delegate = self
        }
    }
    
    func addAudio(buffer: AVAudioPCMBuffer, audioTime: AVAudioTime) {
        // Add the audio to the current match request
        session?.matchStreamingBuffer(buffer, at: audioTime)
    }
    
    func startDetection(result: @escaping FlutterResult) {
        guard session != nil else {
            callbackChannel?.invokeMethod("didHasError", arguments: "ShazamSession not found, please call configureShazamKitSession() first to initialize it.")
            result(nil)
            return
        }
        guard !isStarting else {
            result(nil)
            return
        }
        isStarting = true

        // Always clean up previous state to prevent installTap crash
        if audioEngine.isRunning {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }

        let audioSession = AVAudioSession.sharedInstance()

        // 1. playAndRecord allows other app audio to keep playing.
        //    .mixWithOthers prevents interrupting other audio sources.
        //    Feedback is prevented by muting mainMixerNode.outputVolume = 0 below.
        do {
            try audioSession.setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
            try audioSession.setActive(true, options: [])
        } catch {
            isStarting = false
            callbackChannel?.invokeMethod("didHasError", arguments: error.localizedDescription)
            result(nil)
            return
        }

        // 2. Request mic permission, THEN configure audio + start engine
        audioSession.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self else { return }
                defer { self.isStarting = false }
                guard granted else {
                    self.callbackChannel?.invokeMethod("didHasError", arguments: "Recording permission not found, please allow permission first and then try again")
                    return
                }
                do {
                    // Now that permission is granted and session is active,
                    // inputNode will report the real format with channels > 0
                    let inputNode = self.audioEngine.inputNode
                    let recordingFormat = inputNode.outputFormat(forBus: 0)
                    guard recordingFormat.channelCount > 0 else {
                        self.callbackChannel?.invokeMethod("didHasError", arguments: "Audio input has 0 channels.")
                        return
                    }

                    // Remove any existing tap to prevent crash on double-start
                    inputNode.removeTap(onBus: 0)

                    inputNode.installTap(onBus: 0, bufferSize: 8192, format: recordingFormat) { buffer, audioTime in
                        self.addAudio(buffer: buffer, audioTime: audioTime)
                    }

                    // Mute the implicit graph (inputNode→mainMixer→outputNode)
                    // that AVAudioEngine creates when accessing inputNode.
                    // mainMixerNode.outputVolume = 0 prevents any mic audio from
                    // reaching the speakers. Combined with .record category, this
                    // ensures zero audio output.
                    self.audioEngine.mainMixerNode.outputVolume = 0

                    self.audioEngine.prepare()
                    try self.audioEngine.start()

                    // Double-check mute after start (some iOS versions reset volume)
                    self.audioEngine.mainMixerNode.outputVolume = 0
                    self.callbackChannel?.invokeMethod("detectStateChanged", arguments: 1)
                } catch {
                    self.callbackChannel?.invokeMethod("didHasError", arguments: error.localizedDescription)
                }
            }
        }
        result(nil)
    }
    
    func stopListening() {
        isStarting = false
        callbackChannel?.invokeMethod("detectStateChanged", arguments: 0)
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()

        // Restore audio session so other app audio works normally
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true, options: [])
        } catch {}
    }
}

//MARK: Delegate methods for SHSession
extension SwiftFlutterShazamKitPlugin: SHSessionDelegate{
    public func session(_ session: SHSession, didFind match: SHMatch) {
        var mediaItems: [[String: Any]] = []
        match.mediaItems.forEach{rawItem in
            var item: [String: Any] = [:]
            item["title"] = rawItem.title
            item["subtitle"] = rawItem.subtitle
            item["shazamId"] = rawItem.shazamID
            item["appleMusicId"] = rawItem.appleMusicID
            if let appleUrl = rawItem.appleMusicURL{
                item["appleMusicUrl"] = appleUrl.absoluteString
            }
            if let artworkUrl = rawItem.artworkURL{
                item["artworkUrl"] = artworkUrl.absoluteString
            }
            item["artist"] = rawItem.artist
            item["matchOffset"] = rawItem.matchOffset
            if let videoUrl = rawItem.videoURL{
                item["videoUrl"] = videoUrl.absoluteString
            }
            if let webUrl = rawItem.webURL{
                item["webUrl"] = webUrl.absoluteString
            }
            item["genres"] = rawItem.genres
            item["isrc"] = rawItem.isrc
            mediaItems.append(item)
        }
        DispatchQueue.main.async {
            do{
                let jsonData = try JSONSerialization.data(withJSONObject: mediaItems)
                let jsonString = String(data: jsonData, encoding: .utf8)
                self.callbackChannel?.invokeMethod("matchFound", arguments: jsonString)
            }catch{
                self.callbackChannel?.invokeMethod("didHasError", arguments: "Error when trying to format data, please try again")
            }
        }
    }
    
    public func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
        DispatchQueue.main.async {
            self.callbackChannel?.invokeMethod("notFound", arguments: nil)
            self.callbackChannel?.invokeMethod("didHasError", arguments: error?.localizedDescription)
        }
    }
}

