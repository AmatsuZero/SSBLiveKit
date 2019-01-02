//
//  SSBPublish.swift
//  SSBLiveKit
//
//  Created by Jiang,Zhenhua on 2019/1/1.
//

import Foundation
import SSBEncoder

@objcMembers public class SSBLiveDebug: NSObject {
    /// 流id
    public var streamId = ""
    /// 流地址
    public var uploadUrl = ""
    /// 上传的分辨率
    public var videoSize: CGSize = .zero
    /// 上传方式（TCP or RTMP）
    public var isRTMP = false
    /// 距离上次统计的时间 单位ms
    public var elapsedMilli: CGFloat = 0
    /// 当前的时间戳，从而计算1s内数据
    public var timeStamp: CGFloat = 0
    /// 总流量
    public var dataFlow: CGFloat = 0
    /// 1s内总带宽
    public var bandWidth: CGFloat = 0
    /// 上次的带宽
    public var currentBandwidth: CGFloat = 0
    /// 丢掉的帧数
    public var dropFrame = 0
    /// 总帧数
    public var totalFrame = 0
    /// 1s内音频捕获个数
    public var capturedAudioCount = 0
    /// 1s内视频捕获个数
    public var capturedVideoCount = 0
    /// 上次的音频捕获个数
    public var currentCapturedAudioCount = 0
    /// 上次的视频捕获个数
    public var currentCapturedVideoCount = 0
    /// 未发送个数（代表当前缓冲区等待发送的）
    public var unSendCount = 0
    
    public override var description: String {
        return """
        丢掉的帧数: \(dropFrame)
        总帧数: \(totalFrame)
        上次的音频捕获个数: \(currentCapturedAudioCount)
        上次的视频捕获个数: \(currentCapturedVideoCount)
        未发送个数: \(unSendCount)
        总流量: \(dataFlow)
        """
    }
}

@objcMembers public class SSBLiveStreamInfo: NSObject {
    /// 流状态
    @objc public enum LiveState: Int {
        /// 准备
        case ready = 0
        /// 连接中
        case pending
        /// 已连接
        case start
        /// 已断开
        case stop
        /// 连接出错
        case error
        ///  正在刷新
        case refresh
    }
    
    enum SocketError: CustomNSError {
        /// 预览失败
        case preview(SSBLiveDebug)
        /// 获取流媒体信息失败
        case getStreamInfo(SSBLiveDebug)
        /// 连接socket失败
        case connectSocket(SSBLiveDebug)
        /// 验证服务器失败
        case verification(SSBLiveDebug)
        /// 重新连接服务器超时
        case reconnectTimeout(SSBLiveDebug)
        
        var errorCode: Int {
            switch self {
            case .preview: return 201
            case .getStreamInfo: return 202
            case .connectSocket: return 203
            case .verification: return 204
            case .reconnectTimeout: return 205
            }
        }
        
        static var errorDomain: String {
            return "com.ssb.LiveKit.LiveStreamInfo"
        }
        
        var localizedDescription: String {
            switch self {
            case .preview(let debug),
                 .getStreamInfo(let debug),
                 .connectSocket(let debug),
                 .verification(let debug),
                 .reconnectTimeout(let debug):
                return debug.description
            }
        }
        
        var errorUserInfo: [String : Any] {
            return [NSLocalizedDescriptionKey: localizedDescription]
        }
    }
    
    var streamId: String?
    // MARK: FLV
    var host: String?
    var port: Int?
    // MARK: RTMP
    /// 上传地址
    var url: String?
    /// 音频设置
    var audioConfiguration: SSBLiveAudioConfiguration?
    /// 视频设置
    var videoConfiguration: SSBVideoConfiguration?
}

protocol SSBStreamBufferDelegate: class {
    /// 当前buffer变动（增加or减少） 根据buffer中的updateInterval时间回调*
    func streamingBuffer(_ buffer: SSBStreamingBuffer, state: SSBStreamingBuffer.BufferState)
}

class SSBStreamingBuffer {
    /// current buffer status
    enum BufferState: Int {
        /// 未知
        case unknown = 0
        /// 缓冲区状态差应该降低码率
        case increase
        /// 缓冲区状态好应该提升码率
        case decline
    }
    /// The delegate of the buffer. buffer callback
    weak var delegate: SSBStreamBufferDelegate?
    /// current frame buffer
    private(set) var list = [SSBFrame]()
    /// buffer count max size default 1000
    var maxCount: Int
    /// count of drop frames in last time
    var lastDropFrames = 0
    /// 排序10个内
    private let defaultSortBufferMaxCount = 5
    /// 更新频率为1s
    private let defaultUpdateInterval = 1
    /// 5s计时一次
    private let defaultCallBackInterval = 5
    /// 最大缓冲区为600
    private let defaultSendBufferMaxCount = 600
    
    private var sortList = [SSBFrame]()
    private var thresholdList = [Int]()
    private var currentInterval = 0
    private var callBackInterval: Int
    private var updateInderInerval: Int
    private var startTimer = false
    private let lock = DispatchSemaphore(value: 1)
    
    private var currentBufferState: BufferState {
        var currentCount = 0
        var increaseCount = 0
        var decreaseCount = 0
        
        thresholdList.forEach {
            if $0 > currentCount {
                increaseCount += 1
            } else {
                decreaseCount += 1
            }
            currentCount = $0
        }
        
        if increaseCount >= callBackInterval {
            return .increase
        }
        
        if decreaseCount >= callBackInterval {
            return .decline
        }
        
        return .unknown
    }
    
    private var expirePFrames: [SSBFrame] {
        var pFrames = [SSBFrame]()
        for case let frame as SSBVideoFrame in list {
            if frame.isKeyFrame, pFrames.count > 0 {
                break
            } else if !frame.isKeyFrame {
                pFrames.append(frame)
            }
        }
        return pFrames
    }
    
    private var expireIFrames: [SSBFrame] {
        var iFrames = [SSBFrame]()
        var timeStamp: Int64 = 0
        for case let frame as SSBVideoFrame in list where frame.isKeyFrame {
            guard timeStamp == 0 || timeStamp == frame.timestamp else {
                break
            }
            iFrames.append(frame)
            timeStamp = frame.timestamp
        }
        return iFrames
    }
    
    init() {
        updateInderInerval = defaultUpdateInterval
        callBackInterval = defaultCallBackInterval
        maxCount = defaultSendBufferMaxCount
    }
    
    /// add frame to buffer
    func append(object: SSBFrame) {
        if !startTimer {
            startTimer = true
            tick()
        }
        _ = lock.wait(wallTimeout: .distantFuture)
        if sortList.count < defaultSortBufferMaxCount {
            sortList.append(object)
        } else {
            sortList.append(object)
            // 排序
            sortList.sort { $0.timestamp > $1.timestamp }
            // 丢帧
            removeExpireFrame()
            // 添加至缓冲区
            if let firstFrame = popFirst() {
                list.append(firstFrame)
            }
        }
    }
    
    /// pop the first frome buffer
    func popFirst() -> SSBFrame? {
        _ = lock.wait(timeout: .distantFuture)
        let firstFrame = list.ssb_popFirst()
        lock.signal()
        return firstFrame
    }
    
    /// remove all objects from Buffer
    func removeAll() {
        _ = lock.wait(wallTimeout: .distantFuture)
        list.removeAll()
        lock.signal()
    }
    
    private func isValidIndex(_ index: Int) -> Bool {
        let i = index >= 0 ? index : list.count + index
        return i >= 0 && i < list.count
    }
    
    private func removeExpireFrame() {
        guard list.count >= maxCount else { return }
        let pFrames = expirePFrames //第一个P到第一个I之间的p帧
        lastDropFrames += pFrames.count
        guard pFrames.isEmpty else {
            list.removeAll { pFrames.contains($0) }
            return
        }
        
        let iFrames = expireIFrames // 删除一个I帧（但一个I帧可能对应多个nal）
        lastDropFrames += iFrames.count
        guard iFrames.isEmpty else {
            list.removeAll { iFrames.contains($0) }
            return
        }
        
        list.removeAll()
    }
    
    subscript(index: Int) -> SSBFrame? {
        get {
            guard isValidIndex(index) else {
                return nil
            }
            return list[index]
        }
        
        set {
            guard isValidIndex(index) else {
                return
            }
            if let value = newValue {
                list[index] = value
            } else {
                list.remove(at: index)
            }
        }
    }
    
    // MARK: 采样
    func tick()  {
        /// 采样 3个阶段   如果网络都是好或者都是差给回调
        currentInterval += updateInderInerval
        
        _ = lock.wait(timeout: .distantFuture)
        thresholdList.append(list.count)
        lock.signal()
        
        if currentInterval >= callBackInterval {
            let state = currentBufferState
            if state != .unknown, let delegate = self.delegate {
                delegate.streamingBuffer(self, state: state)
            }
            currentInterval = 0
            thresholdList.removeAll()
        }
        DispatchQueue.main.asyncAfter(deadline: 5) { [weak self] in
            self?.tick()
        }
    }
}

protocol SSBStreamSocketDelegate: NSObjectProtocol {
    /// callback buffer current status (回调当前缓冲区情况，可实现相关切换帧率 码率等策略)
    func socket(_ socket: SSBStreamSocket, bufferState: SSBStreamingBuffer.BufferState)
    /// callback socket current status (回调当前网络情况)
    func socket(_ socket: SSBStreamSocket, liveState: SSBLiveStreamInfo.LiveState)
    /// callback socket errorcode
    func socket(_ socket: SSBStreamSocket, didError: Error)
}

protocol SSBStreamSocket {
    func start()
    func stop()
    func send(frame: SSBFrame)
    func setDelegate(_ delegate: SSBStreamSocketDelegate)
    init(stream: SSBLiveStreamInfo, reconnectInterval: Int, reconnectCount: Int)
}

extension DispatchTime: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = DispatchTime.now() + .seconds(value)
    }
}

extension DispatchTime: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = DispatchTime.now() + .milliseconds(Int(value * 1000))
    }
}

extension SSBStreamBufferDelegate {
    func streamingBuffer(_ buffer: SSBStreamingBuffer, state: SSBStreamingBuffer.BufferState) {
        
    }
}

extension Array {
    mutating func ssb_popFirst() -> Element? {
        let f = first
        self = Array(dropFirst())
        return f
    }
}
