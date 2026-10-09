import AVFoundation
import UIKit
import Network
import ImageIO

enum StreamResolution: String, CaseIterable, Identifiable {
    case hd720 = "720p"
    case hd1080 = "1080p"
    case uhd4k = "4K"

    var id: String { rawValue }
    var preset: AVCaptureSession.Preset {
        switch self {
        case .hd720:  return .hd1280x720
        case .hd1080: return .hd1920x1080
        case .uhd4k:  return .hd4K3840x2160
        }
    }
}

enum StreamQuality: String, CaseIterable, Identifiable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"

    var id: String { rawValue }
    var jpeg: Double {
        switch self {
        case .low:    return 0.5
        case .medium: return 0.7
        case .high:   return 0.85
        }
    }
}

/// Captures video from the iPhone camera and serves JPEG frames over TCP port 9999.
/// The PC host reaches this port through the USB cable (usbmuxd), no Wi-Fi needed.
/// Wire format: [4 bytes big-endian length][JPEG bytes] repeated.
final class CameraManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum Phase { case starting, denied, noCamera, running }

    @Published private(set) var phase: Phase = .starting
    @Published private(set) var pcConnected = false
    @Published private(set) var resolution = "-"
    @Published private(set) var fps = 0
    @Published private(set) var usingFrontCamera = false
    @Published private(set) var selectedResolution: StreamResolution = .hd1080
    @Published private(set) var selectedQuality: StreamQuality = .medium
    @Published private(set) var availableResolutions: [StreamResolution] = StreamResolution.allCases

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "usc.session")
    private let frameQueue = DispatchQueue(label: "usc.frames", qos: .userInteractive)
    private let netQueue = DispatchQueue(label: "usc.net")
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let output = AVCaptureVideoDataOutput()

    private var listener: NWListener?
    private var connection: NWConnection?
    private var configured = false

    private let lock = NSLock()
    private var inFlight = 0
    private var frameCounter = 0
    private var lastFpsTick = CACurrentMediaTime()
    private var qualityValue: Double = StreamQuality.medium.jpeg   // guarded by `lock`
    private var desiredResolution: StreamResolution = .hd1080      // sessionQueue only
    private var isFront = false                                    // sessionQueue only

    override init() {
        let d = UserDefaults.standard
        let r = StreamResolution(rawValue: d.string(forKey: "usc.resolution") ?? "") ?? .hd1080
        let q = StreamQuality(rawValue: d.string(forKey: "usc.quality") ?? "") ?? .medium
        selectedResolution = r
        selectedQuality = q
        desiredResolution = r
        qualityValue = q.jpeg
        super.init()
    }

    // MARK: Lifecycle

    func start() {
        UIApplication.shared.isIdleTimerDisabled = true
        startListener()
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
                ok ? self?.configureAndRun() : self?.setPhase(.denied)
            }
        default:
            setPhase(.denied)
        }
    }

    // MARK: User settings (phone UI)

    func setResolution(_ r: StreamResolution) {
        UserDefaults.standard.set(r.rawValue, forKey: "usc.resolution")
        DispatchQueue.main.async { self.selectedResolution = r }
        sessionQueue.async { [weak self] in
            guard let self = self, self.configured else { self?.desiredResolution = r; return }
            self.desiredResolution = r
            self.session.beginConfiguration()
            self.applyPreset()
            self.session.commitConfiguration()
            self.applyFrameRate()
            self.updateResolutionLabel()
        }
    }

    func setQuality(_ q: StreamQuality) {
        UserDefaults.standard.set(q.rawValue, forKey: "usc.quality")
        lock.lock(); qualityValue = q.jpeg; lock.unlock()
        DispatchQueue.main.async { self.selectedQuality = q }
        sessionQueue.async { [weak self] in
            guard let self = self, self.configured else { return }
            self.session.beginConfiguration()
            self.applyVideoSettings()
            self.session.commitConfiguration()
        }
    }

    func flipCamera() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            let front = !self.isFront
            self.session.beginConfiguration()
            self.session.inputs.forEach { self.session.removeInput($0) }
            if self.addInput(front: front) {
                self.isFront = front
                DispatchQueue.main.async { self.usingFrontCamera = front }
            } else {
                _ = self.addInput(front: !front)
            }
            self.applyPreset()
            self.session.commitConfiguration()
            self.applyFrameRate()
            self.publishAvailableResolutions()
            self.updateResolutionLabel()
        }
    }

    // MARK: Camera

    private func configureAndRun() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if !self.configured {
                self.session.beginConfiguration()
                guard self.addInput(front: false) else {
                    self.session.commitConfiguration()
                    self.setPhase(.noCamera)
                    return
                }
                self.applyPreset()

                self.output.alwaysDiscardsLateVideoFrames = true
                self.output.setSampleBufferDelegate(self, queue: self.frameQueue)
                if self.session.canAddOutput(self.output) { self.session.addOutput(self.output) }
                // Hardware JPEG encoder: far faster than converting every frame on the CPU.
                // (Must be set after the output joined the session so the codec list is valid.)
                self.applyVideoSettings()
                self.session.commitConfiguration()
                self.configured = true
                self.applyFrameRate()
                self.publishAvailableResolutions()
            }
            if !self.session.isRunning { self.session.startRunning() }
            self.updateResolutionLabel()
            self.setPhase(.running)
        }
    }

    @discardableResult
    private func addInput(front: Bool) -> Bool {
        let position: AVCaptureDevice.Position = front ? .front : .back
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return false }
        session.addInput(input)
        return true
    }

    /// Picks the chosen resolution, or the next lower one the camera supports.
    private func applyPreset() {
        let order: [StreamResolution] = [.uhd4k, .hd1080, .hd720]
        let start = order.firstIndex(of: desiredResolution) ?? 1
        for r in order[start...] where session.canSetSessionPreset(r.preset) {
            session.sessionPreset = r.preset
            return
        }
        session.sessionPreset = .high
    }

    private func applyVideoSettings() {
        lock.lock(); let q = qualityValue; lock.unlock()
        if output.availableVideoCodecTypes.contains(.jpeg) {
            output.videoSettings = [
                AVVideoCodecKey: AVVideoCodecType.jpeg,
                AVVideoCompressionPropertiesKey: [AVVideoQualityKey: q]
            ]
        }
    }

    /// Fixed 30 fps: steady frame pacing, half the data of 60 fps.
    private func applyFrameRate() {
        guard let device = (session.inputs.first as? AVCaptureDeviceInput)?.device else { return }
        let ok = device.activeFormat.videoSupportedFrameRateRanges.contains {
            $0.minFrameRate <= 30 && $0.maxFrameRate >= 30
        }
        guard ok, (try? device.lockForConfiguration()) != nil else { return }
        let d = CMTime(value: 1, timescale: 30)
        device.activeVideoMinFrameDuration = d
        device.activeVideoMaxFrameDuration = d
        device.unlockForConfiguration()
    }

    private func publishAvailableResolutions() {
        let list = StreamResolution.allCases.filter { session.canSetSessionPreset($0.preset) }
        DispatchQueue.main.async { self.availableResolutions = list.isEmpty ? [.hd720] : list }
    }

    private func updateResolutionLabel() {
        guard let device = (session.inputs.first as? AVCaptureDeviceInput)?.device else { return }
        let d = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        DispatchQueue.main.async { self.resolution = "\(d.width)x\(d.height)" }
    }

    private func setPhase(_ p: Phase) {
        DispatchQueue.main.async { self.phase = p }
    }

    // MARK: Network (USB tunnel endpoint)

    private func startListener() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                tcp.noDelay = true
            }
            let l = try NWListener(using: params, on: 9999)
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    self?.listener?.cancel()
                    self?.listener = nil
                    self?.netQueue.asyncAfter(deadline: .now() + 1) { self?.startListener() }
                }
            }
            l.start(queue: netQueue)
            listener = l
        } catch {
            netQueue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.startListener() }
        }
    }

    private func accept(_ conn: NWConnection) {
        connection?.cancel()
        connection = conn
        lock.lock(); inFlight = 0; lock.unlock()
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self = self, let conn = conn, conn === self.connection else { return }
            switch state {
            case .ready: DispatchQueue.main.async { self.pcConnected = true }
            case .failed, .cancelled: DispatchQueue.main.async { self.pcConnected = false }
            default: break
            }
        }
        conn.start(queue: netQueue)
    }

    // MARK: Frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let conn = self.connection, conn.state == .ready else { return }

        lock.lock()
        let busy = inFlight >= 2          // PC/USB can't keep up -> drop frame, keep latency low
        lock.unlock()
        if busy { return }

        guard let jpeg = jpegData(from: sampleBuffer) else { return }

        var length = UInt32(jpeg.count).bigEndian
        var packet = Data(bytes: &length, count: 4)
        packet.append(jpeg)

        lock.lock(); inFlight += 1; lock.unlock()
        conn.send(content: packet, completion: .contentProcessed { [weak self] _ in
            self?.lock.lock(); self?.inFlight -= 1; self?.lock.unlock()
        })
        tickFps()
    }

    private func jpegData(from sampleBuffer: CMSampleBuffer) -> Data? {
        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            // Fallback path (raw pixels): encode with Core Image.
            lock.lock(); let q = qualityValue; lock.unlock()
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            return ciContext.jpegRepresentation(of: image, colorSpace: space,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: q])
        }
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
              let p = pointer, length > 0 else { return nil }
        return Data(bytes: p, count: length)
    }

    private func tickFps() {
        frameCounter += 1
        let now = CACurrentMediaTime()
        if now - lastFpsTick >= 1 {
            let value = Int((Double(frameCounter) / (now - lastFpsTick)).rounded())
            frameCounter = 0
            lastFpsTick = now
            DispatchQueue.main.async { self.fps = value }
        }
    }
}
