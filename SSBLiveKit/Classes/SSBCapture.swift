//
//  SSBCapture.swift
//  SSBLiveKit
//
//  Created by Jiang,Zhenhua on 2018/12/28.
//

import Foundation
import AudioToolbox
import AVFoundation
import GPUImage
import SSBEncoder
import SSBFilter

/// LFAudioCapture callback audioData
@objc public protocol SSBAudioCaptureDelegate: NSObjectProtocol {
    @objc func capture(_ capture: SSBAudioCapture, audioData: Data?)
}

private func handleInputBuffer(inRefCon: UnsafeMutableRawPointer,
                               ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                               inTimeStamp: UnsafePointer<AudioTimeStamp>,
                               inBusNumber: UInt32,
                               inNumberFrames: UInt32,
                               ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    
    return autoreleasepool { () -> OSStatus in
        let source = inRefCon.assumingMemoryBound(to: SSBAudioCapture.self).pointee
        var buffer = AudioBuffer()
        buffer.mData = nil
        buffer.mDataByteSize = 0
        buffer.mNumberChannels = 1
        
        var buffers = AudioBufferList()
        buffers.mNumberBuffers = 1
        UnsafeMutableAudioBufferListPointer(&buffers)[0] = buffer
        
        guard let instance = source.componentsInstance else {
            return -1
        }
        let status = AudioUnitRender(instance,
                                     ioActionFlags,
                                     inTimeStamp,
                                     inBusNumber,
                                     inNumberFrames,
                                     &buffers)
        if source.isMuted {
            UnsafeMutableAudioBufferListPointer(&buffers).forEach {
                memset($0.mData, 0, Int($0.mDataByteSize))
            }
        }
        if status != 0,
            let delegate = source.delegate,
            delegate.responds(to: #selector(SSBAudioCaptureDelegate.capture(_:audioData:))),
            let buffer = UnsafeMutableAudioBufferListPointer(&buffers).first,
            let data = buffer.mData {
            delegate.capture(source,
                             audioData: Data(bytes: data, count: Int(buffer.mDataByteSize)))
        }
        return noErr
    }
}

@objcMembers open class SSBAudioCapture: NSObject {
    /// The delegate of the capture. captureData callback
    public weak var delegate: SSBAudioCaptureDelegate?
    /// The muted control callbackAudioData,muted will memset
    public var isMuted = false
    /// The running control start capture or stop capture
    public var isRunning = false {
        willSet {
            guard isRunning != newValue else {
                return
            }
            if newValue {
                taskQueue.async { [weak self] in
                    print("MicrophoneSource: startRunning")
                    let session = AVAudioSession.sharedInstance()
                    if #available(iOS 9.0, *) {
                        try? session.setCategory(AVAudioSessionCategoryPlayAndRecord, with: [.defaultToSpeaker, .interruptSpokenAudioAndMixWithOthers])
                    } else {
                        try? session.setCategory(AVAudioSessionCategoryPlayAndRecord, with: .defaultToSpeaker)
                    }
                    if let componetInstance = self?.componentsInstance {
                        AudioOutputUnitStart(componetInstance)
                    }
                }
            } else {
                taskQueue.async { [weak self] in
                    print("MicrophoneSource: stopRunning")
                    if let componetInstance = self?.componentsInstance {
                        AudioOutputUnitStop(componetInstance)
                    }
                }
            }
        }
    }
    
    var componentsInstance: AudioComponentInstance?
    private var component: AudioComponent?
    private let taskQueue = DispatchQueue(label: "com.ssb.SSBLiveKit.audioCapture.Queue")
    private let configuration: SSBLiveAudioConfiguration
    
    public init(audioConfiguration: SSBLiveAudioConfiguration) {
        configuration = audioConfiguration
        super.init()
        let session = AVAudioSession.sharedInstance()
        NotificationCenter.default.addObserver(self, selector: #selector(SSBAudioCapture.handleRouteChange(_:)),
                                               name: .AVAudioSessionRouteChange,
                                               object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(SSBAudioCapture.handleInterruption(_:)),
                                               name: .AVAudioSessionInterruption,
                                               object: session)
        var acd = AudioComponentDescription()
        acd.componentType = kAudioUnitType_Output
        acd.componentSubType = kAudioUnitSubType_RemoteIO
        acd.componentManufacturer = kAudioUnitManufacturer_Apple
        acd.componentFlags = 0
        acd.componentFlagsMask = 0
        
        component = AudioComponentFindNext(nil, &acd)
        if let component = component, AudioComponentInstanceNew(component, &componentsInstance) != noErr {
            handleAudioComponentCreationFailure()
        }
        
        guard let componentsInstance = componentsInstance else {
            return
        }
        
        var flagOne = 1
        AudioUnitSetProperty(componentsInstance, kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Input, 1, &flagOne, UInt32(MemoryLayout.size(ofValue: flagOne)))
        
        var desc = AudioStreamBasicDescription()
        desc.mSampleRate = Float64(configuration.sampleRate.rawValue)
        desc.mFormatID = kAudioFormatLinearPCM
        desc.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked
        desc.mChannelsPerFrame = UInt32(configuration.numberOfChannels)
        desc.mFramesPerPacket = 1
        desc.mBitsPerChannel = 16
        desc.mBytesPerFrame = desc.mBitsPerChannel / 8 * desc.mChannelsPerFrame
        desc.mFramesPerPacket = desc.mBytesPerFrame * desc.mFramesPerPacket
        
        var cb = AURenderCallbackStruct()
        var mySelf = self
        cb.inputProcRefCon = withUnsafeMutablePointer(to: &mySelf, { UnsafeMutableRawPointer($0)})
        cb.inputProc = handleInputBuffer
        AudioUnitSetProperty(componentsInstance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &desc, UInt32(MemoryLayout.size(ofValue: desc)))
        AudioUnitSetProperty(componentsInstance, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 1, &cb, UInt32(MemoryLayout.size(ofValue: cb)))
        
        if AudioUnitInitialize(componentsInstance) != noErr {
            handleAudioComponentCreationFailure()
        }
        do {
            try session.setPreferredSampleRate(Double(configuration.sampleRate.rawValue))
            if #available(iOS 9.0, *) {
                try session.setCategory(AVAudioSessionCategoryPlayAndRecord, with: [.defaultToSpeaker, .interruptSpokenAudioAndMixWithOthers])
            } else {
                try session.setCategory(AVAudioSessionCategoryPlayAndRecord, with: .defaultToSpeaker)
            }
            try session.setActive(true, with: .notifyOthersOnDeactivation)
            try session.setActive(true)
        } catch {
            print("AVAudioSession Set Property Error: \(error.localizedDescription)")
        }
    }
    
    @objc private func handleInterruption(_ notification: Notification) {
        guard notification.name == .AVAudioSessionInterruption else {
            return
        }
        var reasonStr = ""
        //Posted when an audio interruption occurs.
        if let reason = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? AVAudioSession.InterruptionType {
            switch reason {
            case .began where isRunning:
                taskQueue.sync { [weak self] in
                    print("MicrophoneSource: stopRunning")
                    if let instance = self?.componentsInstance {
                        AudioOutputUnitStop(instance)
                    }
                }
            case .ended where notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? AVAudioSession.InterruptionOptions == .shouldResume
                && isRunning:
                reasonStr = "AVAudioSessionInterruptionTypeEnded"
                taskQueue.async { [weak self] in
                    print("MicrophoneSource: startRunning")
                    if let instance = self?.componentsInstance {
                        AudioOutputUnitStop(instance)
                    }
                }
                /* Indicates that the audio session is active and immediately ready to be used.
                 Your app can resume the audio operation that was interrupted.*/
            default:
                break
            }
        }
        print("handleInterruption: \(notification.name) reason \(reasonStr)")
    }
    
    @objc private func handleRouteChange(_ notification: Notification) {
        let session = AVAudioSession.sharedInstance()
        if let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as?AVAudioSession.RouteChangeReason {
            var reasonStr = ""
            switch reason {
            case .noSuitableRouteForCategory:
                reasonStr = "The route changed because no suitable route is now available for the specified category."
            case .wakeFromSleep:
                reasonStr = "The route changed when the device woke up from sleep."
            case .override:
                reasonStr = "The output route was overridden by the app."
            case .categoryChange:
                reasonStr = "The category of the session object changed."
            case .oldDeviceUnavailable:
                reasonStr = "The previous audio output path is no longer available."
            case .newDeviceAvailable:
                reasonStr = "A preferred new audio output path is now available."
            default:
                reasonStr = "The reason for the change is unknown."
            }
            print("handle print reason is: \(reasonStr)")
        }
        if session.currentRoute.inputs.first?.portType == AVAudioSessionPortHeadsetMic {
            
        }
    }
    
    private func handleAudioComponentCreationFailure() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .SSBAudioComponentFailedToCreateNotification, object: nil)
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        taskQueue.async { [weak self] in
            self?.isRunning = false
            if let componentsInstance = self?.componentsInstance {
                AudioOutputUnitStop(componentsInstance)
                AudioComponentInstanceDispose(componentsInstance)
                self?.componentsInstance = nil
            }
            self?.component = nil
        }
    }
}

@objc public protocol SSBVideoCaptureDelegate: NSObjectProtocol {
    @objc func captureOutput(_ capture: SSBVideoCapture, pixelBuffer: CVPixelBuffer)
}

@objcMembers open class SSBVideoCapture: NSObject {
    
    /// The delegate of the capture. captureData callback
    public weak var delegate: SSBVideoCaptureDelegate?
    ///  The running control start capture or stop capture
    public var isRunning = false {
        willSet {
            guard isRunning != newValue else {
                return
            }
            UIApplication.shared.isIdleTimerDisabled = newValue
            if newValue {
                reloadFilter()
                videoCamera?.startCapture()
                if saveLocalVideo {
                    movieWriter?.startRecording()
                }
            } else {
                videoCamera?.stopCapture()
                if saveLocalVideo {
                    movieWriter?.finishRecording()
                }
            }
        }
    }
    /// The preView will show OpenGL ES view
    public var preView: UIView! {
        set {
            if gpuImageView?.superview != nil {
                gpuImageView?.removeFromSuperview()
            }
            if let imageView = gpuImageView {
                newValue.insertSubview(imageView, at: 0)
            }
            gpuImageView?.frame = .init(origin: .zero, size: newValue.frame.size)
        }
        get {
            return gpuImageView?.superview
        }
    }
    /// The captureDevicePosition control camraPosition ,default front
    public var captureDevicePosition: AVCaptureDevice.Position {
        set {
            guard newValue != captureDevicePosition else {
                return
            }
            videoCamera?.rotateCamera()
            videoCamera?.frameRate = Int32(configuration.videoFrameRate)
            reloadMirror()
        }
        get {
            return videoCamera?.cameraPosition() ?? .front
        }
    }
    /// The beautyFace control capture shader filter empty or beautiy
    public var beautyFace = true
    ///  The torch control capture flash is on or off
    public var useTorch: Bool {
        set {
            guard let captureSession = videoCamera?.captureSession else {
                return
            }
            captureSession.beginConfiguration()
            if let inputCamera = videoCamera?.inputCamera {
                if inputCamera.isTorchAvailable {
                    do {
                        try inputCamera.lockForConfiguration()
                        try inputCamera.setTorchModeOn(level: Float(newValue
                            ? AVCaptureDevice.TorchMode.on.rawValue
                            : AVCaptureDevice.TorchMode.off.rawValue))
                        inputCamera.unlockForConfiguration()
                    } catch {
                        print("Error while locking device for torch: \(error.localizedDescription)")
                    }
                } else {
                    print("Torch not available in current camera input")
                }
            }
            captureSession.commitConfiguration()
        }
        get {
            return videoCamera?.inputCamera.torchMode != .off
        }
    }
    /// The mirror control mirror of front camera is on or off
    public var isMirror = true
    /// The beautyLevel control beautyFace Level, default 0.5, between 0.0 ~ 1.0
    public var beautyLevel: CGFloat = 0.5 {
        didSet {
            reloadFilter()
        }
    }
    /// The brightLevel control brightness Level, default 0.5, between 0.0 ~ 1.0
    public var brightLevel: CGFloat = 0.5 {
        didSet {
            if let filter = beautyFilter {
                filter.bright = brightLevel
            }
        }
    }
    /// The torch control camera zoom scale default 1.0, between 1.0 ~ 3.0
    public var zoomScale: CGFloat = 1 {
        didSet {
            if let inputCamera = videoCamera?.inputCamera {
                do {
                    try inputCamera.lockForConfiguration()
                    inputCamera.videoZoomFactor = zoomScale
                    inputCamera.unlockForConfiguration()
                } catch {
                    print("Error while locking device for torch: \(error.localizedDescription)")
                }
            }
        }
    }
    /// The videoFrameRate control videoCapture output data count
    public var videoFrameRate: Int {
        set {
            guard newValue > 0,
                Int(videoCamera?.frameRate ?? 0) != newValue else {
                    return
            }
            videoCamera?.frameRate = Int32(newValue)
        }
        get {
            return Int(videoCamera?.frameRate ?? 0)
        }
    }
    private var _warterMarkView: UIView?
    /// The warterMarkView control whether the watermark is displayed or not ,if set nil,will remove watermark,otherwise add
    public var warterMarkView: UIView? {
        set {
            if _warterMarkView != nil, _warterMarkView?.superview != nil {
                _warterMarkView?.removeFromSuperview()
            }
            if let view = newValue {
                _warterMarkView = view
                blendFilter.mix = view.alpha
                watermarkContentView.addSubview(view)
                reloadFilter()
            }
        }
        get {
            return _warterMarkView
        }
    }
    
    /// The currentImage is videoCapture shot
    public var currentImage: UIImage? {
        if let filter = filter {
            filter.useNextFrameForImageCapture()
            return filter.imageFromCurrentFramebuffer()
        }
        return nil
    }
    /// The saveLocalVideo is save the local video
    public var saveLocalVideo = false
    /// The saveLocalVideoPath is save the local video  path
    public var saveLocalVideoPath: URL?
    private let configuration: SSBVideoConfiguration
    
    private lazy var videoCamera: GPUImageVideoCamera? = {
        let camera = GPUImageVideoCamera(sessionPreset: configuration.avSessionPresset.rawValue,
                                         cameraPosition: captureDevicePosition)
        camera?.outputImageOrientation = configuration.outputImageOrientation
        camera?.horizontallyMirrorFrontFacingCamera = false
        camera?.horizontallyMirrorRearFacingCamera = false
        camera?.frameRate = Int32(configuration.videoFrameRate)
        return camera
    }()
    
    private var beautyFilter: SSBBeautyFilter?
    private var filter: (GPUImageOutput & GPUImageInput)? // Swift4 声明方法
    private var cropFilter: GPUImageCropFilter?
    private var output: (GPUImageOutput & GPUImageInput)?
    private lazy var gpuImageView: GPUImageView? = {
        let view = GPUImageView(frame: UIScreen.main.bounds)
        view.fillMode = kGPUImageFillModePreserveAspectRatioAndFill
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        return view
    }()
    private lazy var blendFilter: GPUImageAlphaBlendFilter = {
        let filter = GPUImageAlphaBlendFilter()
        filter.mix = 1
        filter.disableSecondFrameCheck()
        return filter
    }()
    private lazy var uiElementInput: GPUImageUIElement? = {
        let input = GPUImageUIElement(view: watermarkContentView)
        return input
    }()
    private lazy var watermarkContentView: UIView = {
        let view = UIView(frame: CGRect(origin: .zero, size: configuration.videoSize))
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        return view
    }()
    private lazy var movieWriter: GPUImageMovieWriter? = {
        guard let url = saveLocalVideoPath else {
            return nil
        }
        let writer = GPUImageMovieWriter(movieURL: url, size: configuration.videoSize)
        writer?.encodingLiveVideo = true
        writer?.shouldPassthroughAudio = true
        videoCamera?.audioEncodingTarget = writer
        return writer
    }()
    
    public init(videoConfiguration: SSBVideoConfiguration) {
        configuration = videoConfiguration
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(SSBVideoCapture.willEnterBackground(_:)),
                           name: .UIApplicationWillResignActive,
                           object: nil)
        center.addObserver(self, selector: #selector(SSBVideoCapture.willEnterForeground(_:)),
                           name: .UIApplicationDidBecomeActive,
                           object: nil)
        center.addObserver(self, selector: #selector(SSBVideoCapture.statusBarChanged(_:)),
                           name: .UIApplicationWillChangeStatusBarOrientation,
                           object: nil)
    }
    
    deinit {
        UIApplication.shared.isIdleTimerDisabled = false
        NotificationCenter.default.removeObserver(self)
        videoCamera?.stopCapture()
        if let image = gpuImageView {
            image.removeFromSuperview()
            gpuImageView = nil
        }
    }
    
    // MARK: - Notification Handler
    @objc private func willEnterBackground(_ notification: Notification)  {
        UIApplication.shared.isIdleTimerDisabled = false
        videoCamera?.pauseCapture()
        runSynchronouslyOnContextQueue(nil) {
            glFinish()
        }
        
    }
    
    @objc private func willEnterForeground(_ notifation: Notification) {
        videoCamera?.resumeCameraCapture()
        UIApplication.shared.isIdleTimerDisabled = true
    }
    
    @objc private func statusBarChanged(_ notification: Notification) {
        print("UIApplicationWillChangeStatusBarOrientationNotification. UserInfo: \(notification.userInfo ?? [:])")
        guard configuration.isAutorotate else {
            return
        }
        switch UIApplication.shared.statusBarOrientation {
        case .landscapeLeft where configuration.isLandscape:
            videoCamera?.outputImageOrientation = .landscapeRight
        case .landscapeRight where configuration.isLandscape:
            videoCamera?.outputImageOrientation = .landscapeLeft
        case .portrait where !configuration.isLandscape:
            videoCamera?.outputImageOrientation = .portraitUpsideDown
        case .portraitUpsideDown where !configuration.isLandscape:
            videoCamera?.outputImageOrientation = .portrait
        default:
            break
        }
    }
    
    // MARK: - Custom Method
    private func reloadFilter() {
        filter?.removeAllTargets()
        blendFilter.removeAllTargets()
        uiElementInput?.removeAllTargets()
        videoCamera?.removeAllTargets()
        output?.removeAllTargets()
        cropFilter?.removeAllTargets()
        
        if beautyFace {
            output = SSBEmptyFilter()
            filter = SSBBeautyFilter()
            beautyFilter = filter as? SSBBeautyFilter
        } else {
            output = SSBEmptyFilter()
            filter = SSBEmptyFilter()
            beautyFilter = nil
        }
        
        // 调节镜像
        reloadMirror()
        
        // 480*640 比例为4:3  强制转换为16:9
        if configuration.avSessionPresset == .vga640x480 {
            let cropRect = configuration.isLandscape
                ? CGRect(x: 0, y: 0.125, width: 1, height: 0.75)
                : CGRect(x: 0.125, y: 0, width: 0.75, height: 1)
            cropFilter = GPUImageCropFilter(cropRegion: cropRect)
            videoCamera?.addTarget(cropFilter)
            cropFilter?.addTarget(filter!)
        } else {
            videoCamera?.addTarget(filter!)
        }
        
        // 添加水印
        if warterMarkView != nil {
            filter?.addTarget(blendFilter)
            uiElementInput?.addTarget(blendFilter)
            blendFilter.addTarget(gpuImageView)
            if saveLocalVideo {
                blendFilter.addTarget(movieWriter)
            }
            filter?.addTarget(output)
            uiElementInput?.update()
        } else {
            filter?.addTarget(output)
            output?.addTarget(gpuImageView)
            if saveLocalVideo {
                output?.addTarget(movieWriter)
            }
        }
        
        filter?.forceProcessing(at: configuration.videoSize)
        output?.forceProcessing(at: configuration.videoSize)
        blendFilter.forceProcessing(at: configuration.videoSize)
        uiElementInput?.forceProcessing(at: configuration.videoSize)
        
        // 输出数据
        output?.frameProcessingCompletionBlock = { [weak self] (output, _) in
            self?.process(video: output)
        }
    }
    
    private func process(video: GPUImageOutput?)  {
        autoreleasepool { [weak self] in
            if let self = self,
                let buffer = video?.framebufferForOutput()?.pixelBuffer?.takeUnretainedValue(),
                let delegate = delegate,
                delegate.responds(to: #selector(SSBVideoCaptureDelegate.captureOutput(_:pixelBuffer:))) {
               delegate.captureOutput(self, pixelBuffer: buffer)
            }
        }
    }
    
    private func reloadMirror() {
        videoCamera?.horizontallyMirrorFrontFacingCamera = isMirror && captureDevicePosition == .front
    }
}

extension NSString {
    @objc public static var SSBAudioComponentFailedToCreateNotification: String {
        return "AudioComponentFailedToCreateNotification"
    }
}

extension Notification.Name {
    /// ompoentFialed will post the notification
    public static var SSBAudioComponentFailedToCreateNotification: Notification.Name {
        return .init(NSString.SSBAudioComponentFailedToCreateNotification)
    }
}

extension GPUImageFramebuffer {
    var pixelBuffer: Unmanaged<CVPixelBuffer>? {// Core Foundation对象要用Unmanged来管理
        // 仅适用于iOS或者iPhone模拟器
        #if ((arch(i386) || arch(x86_64)) && os(iOS)) || os(iOS)
        guard let ivar = class_getInstanceVariable(GPUImageFramebuffer.self, "renderTarget") else {
            return nil
        }
        return object_getIvar(self, ivar) as? Unmanaged<CVPixelBuffer>
        #else
        return nil
        #endif
    }
}
