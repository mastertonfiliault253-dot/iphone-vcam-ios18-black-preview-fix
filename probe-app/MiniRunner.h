#import <Foundation/Foundation.h>

// 零帧根因排查用：教科书式最小 AVCaptureSession 参考实现。
// 与 ProbeRunner 完全隔离：不自定义队列（delegate 走主队列）、不锁格式、
// 不用 session 管理队列、不经测试台——结果直接写 /var/mobile/Media/VCAM/mini.log。
@interface MiniRunner : NSObject
+ (void)startWithDurationSeconds:(NSInteger)seconds;
@end
