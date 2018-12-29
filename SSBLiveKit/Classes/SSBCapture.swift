//
//  SSBCapture.swift
//  SSBLiveKit
//
//  Created by Jiang,Zhenhua on 2018/12/28.
//

import Foundation
import SSBEncoder
import AudioToolbox
import AVFoundation

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
