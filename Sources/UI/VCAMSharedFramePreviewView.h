#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface VCAMSharedFramePreviewView : UIView

/// Live stream health observed by the panel preview: whether a fresh shared
/// frame arrived recently, how old the newest frame is, and the measured
/// preview copy rate. Used by the floating panel to show stream status.
+ (NSDictionary<NSString *, id> *)streamingStatus;

@end

NS_ASSUME_NONNULL_END
