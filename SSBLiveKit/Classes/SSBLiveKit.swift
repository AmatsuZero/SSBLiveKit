import Foundation
import AVFoundation

@objc public protocol SSBLiveSessionDelegate: NSObjectProtocol {
    /// live status changed will callback
    @objc optional func liveSession(_ session: SSBLiveSession, stateChanged state: SSBLiveStreamInfo.LiveState)
    /// live debug info callback
    @objc optional func liveSession(_ session: SSBLiveSession, debugInfo: SSBLiveDebug?)
    /// callback socket error
    @objc optional func liveSession(_ session: SSBLiveSession, error: Error?)
    
}

@objcMembers open class SSBLiveSession: NSObject {
    /// The delegate of the capture. captureData callback
    public weak var delegate: SSBLiveSessionDelegate?
    /// The running control start capture or stop capture
    public var isRunning = false
    /// The preView will show OpenGL ES view
    public var preView: UIView!
    /// The captureDevicePosition control camraPosition ,default front
    public var captureDevicePosition = AVCaptureDevice.Position.front
    /// The beautyFace control capture shader filter empty or beautiy
    public var enableBeautyFace = false
    /// The beautyLevel control beautyFace Level. Default is 0.5, between 0.0 ~ 1.0
    public var beautyLevel: CGFloat = 0.5
    /// The brightLevel control brightness Level, Default is 0.5, between 0.0 ~ 1.0
    public var brightLevel: CGFloat = 0.5
    /// The torch control camera zoom scale default 1.0, between 1.0 ~ 3.0
    public var zoomScale: CGFloat = 1
    ///  The torch control capture flash is on or off
    public var useTorch = false
    ///  The mirror control mirror of front camera is on or off
    public var isMirror = false
    /// The muted control callbackAudioData,muted will memset 0
    public var isMuted = false
    /// The adaptiveBitrate control auto adjust bitrate. Default is NO
    public var isAdaptiveBitrate = false
    /// The stream control upload and package
    public private(set) var streamInfo: SSBLiveStreamInfo?
    /// The status of the stream
    public private(set) var state: SSBLiveStreamInfo.LiveState = .ready
    /// The captureType control inner or outer audio and video
    public private(set) var captureType = SSBLiveCaptureTypeMask.captureDefaultMask
}
