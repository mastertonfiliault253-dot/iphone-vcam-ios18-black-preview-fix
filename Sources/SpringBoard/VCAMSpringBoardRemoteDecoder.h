#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// RTSP hardware-decode service hosted in SpringBoard. vcamd keeps the RTSP
/// demuxer and pushes compressed H.264/HEVC access units over the surface
/// broker (the daemon context cannot run VideoToolbox; docs VIDEOTOOLBOX
/// case E9); this module feeds them to VCAMHardwareVideoDecoder and returns
/// the decoded IOSurfaces to vcamd for normal frame publication.
@interface VCAMSpringBoardRemoteDecoder : NSObject

+ (instancetype)sharedDecoder;
- (void)start;

@end

NS_ASSUME_NONNULL_END
