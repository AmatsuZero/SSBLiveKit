//
//  UmbrellaHeader.h
//  SSBLiveKit
//
//  Created by Jiang,Zhenhua on 2019/1/2.
//

#ifndef UmbrellaHeader_h
#define UmbrellaHeader_h

#ifdef __OBJC__
#import <UIKit/UIKit.h>
#else
#ifndef FOUNDATION_EXPORT
#if defined(__cplusplus)
#define FOUNDATION_EXPORT extern "C"
#else
#define FOUNDATION_EXPORT extern
#endif
#endif
#endif


FOUNDATION_EXPORT double SSBLiveKitVersionNumber;
FOUNDATION_EXPORT const unsigned char SSBLiveKitVersionString[];

#endif /* UmbrellaHeader_h */
