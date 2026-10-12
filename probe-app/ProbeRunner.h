#import <Foundation/Foundation.h>

// 一次原生检测采集。progress 回调用于界面日志，completion 在结束（含失败）后调用一次。
@interface ProbeRunner : NSObject
- (void)runWithBaseURL:(NSString *)baseURL
              progress:(void (^)(NSString *line))progress
            completion:(void (^)(void))completion;
@end
