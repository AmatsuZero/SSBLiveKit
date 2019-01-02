//
//  SSBLiveCaptureMask.h
//  SSBEncoder
//
//  Created by Jiang,Zhenhua on 2019/1/2.
//

#ifndef SSBLiveCaptureMask_h
#define SSBLiveCaptureMask_h

typedef NS_ENUM(NSInteger,SSBLiveCaptureType) {
    /// capture only audio
    SSBLiveCaptureAudio,
    /// capture onlt video
    SSBLiveCaptureVideo,
    ///  only audio (External input audio)
    SSBLiveInputAudio,
    /// only video (External input video)
    SSBLiveInputVideo
};

/// 用来控制采集类型（可以内部采集也可以外部传入等各种组合，支持单音频与单视频,外部输入适用于录屏，无人机等外设介入）
typedef NS_OPTIONS(NSUInteger, SSBLiveCaptureTypeMask) {
    /// only inner capture audio (no video)
    SSBLiveCaptureMaskAudio = (1 << SSBLiveCaptureAudio),
    /// only inner capture video (no audio)
    SSBLiveCaptureMaskVideo = (1 << SSBLiveCaptureVideo),
    /// only outer input audio (no video)
    SSBLiveInputMaskAudio = (1 << SSBLiveInputAudio),
    /// only outer input video (no audio)
    SSBLiveInputMaskVideo = (1 << SSBLiveInputVideo),
    /// inner capture audio and video
    SSBLiveCaptureMaskAll = (SSBLiveCaptureMaskAudio | SSBLiveCaptureMaskVideo),
    /// outer input audio and video(method see pushVideo and pushAudio)
    SSBLiveInputMaskAll = (SSBLiveInputMaskAudio | SSBLiveInputMaskVideo),
    /// inner capture audio and outer input video(method pushVideo and setRunning)
    SSBLiveCaptureMaskAudioInputVideo = (SSBLiveCaptureMaskAudio | SSBLiveInputMaskVideo),
    /// inner capture video and outer input audio(method pushAudio and setRunning)
    SSBLiveCaptureMaskVideoInputAudio = (SSBLiveCaptureMaskVideo | SSBLiveInputMaskAudio),
    ///< default is inner capture audio and video
    SSBLiveCaptureDefaultMask = SSBLiveCaptureMaskAll
};

#endif /* SSBLiveCaptureMask_h */
