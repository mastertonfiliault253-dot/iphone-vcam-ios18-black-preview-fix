#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class VCAMControlPanelViewController;

@protocol VCAMControlPanelDelegate <NSObject>
- (void)controlPanelDidRequestClose:(VCAMControlPanelViewController *)panel;
- (void)controlPanelDidRequestPhotoLibrary:(VCAMControlPanelViewController *)panel;
- (void)controlPanelDidRequestDocument:(VCAMControlPanelViewController *)panel;
- (void)controlPanelDidRequestOnlineVideo:(VCAMControlPanelViewController *)panel;
- (void)controlPanelDidRequestLiveStream:(VCAMControlPanelViewController *)panel;
- (void)controlPanelDidRequestClockwiseRotation:(VCAMControlPanelViewController *)panel;
- (void)controlPanelDidRequestCounterClockwiseRotation:(VCAMControlPanelViewController *)panel;
- (void)controlPanelDidRequestMirrorToggle:(VCAMControlPanelViewController *)panel;
- (void)controlPanelDidRequestAudioToggle:(VCAMControlPanelViewController *)panel;
- (void)controlPanelDidRequestContentModeCycle:(VCAMControlPanelViewController *)panel;
- (void)controlPanelDidRequestLoopToggle:(VCAMControlPanelViewController *)panel;
- (void)controlPanelDidRequestLocalDecoderToggle:(VCAMControlPanelViewController *)panel;
- (void)controlPanelDidRequestRestoreCamera:(VCAMControlPanelViewController *)panel;
- (void)controlPanelDidRequestTargetSelector:(VCAMControlPanelViewController *)panel;
@end

@interface VCAMControlPanelViewController : UIViewController

@property(nonatomic, weak) id<VCAMControlPanelDelegate> delegate;

- (instancetype)initWithStatus:(NSDictionary<NSString *, NSString *> *)status;

@end

NS_ASSUME_NONNULL_END
