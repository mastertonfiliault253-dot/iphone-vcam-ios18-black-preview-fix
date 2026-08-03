#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VCAMInjectionTarget) {
    VCAMInjectionTargetUnknown = 0,
    VCAMInjectionTargetCamera,
    VCAMInjectionTargetSafari,
    VCAMInjectionTargetChrome,
    VCAMInjectionTargetWebKit,
    VCAMInjectionTargetMediaServer,
};

/// One process-policy seam shared by the Logos constructor, configuration loader,
/// and control UI. "Global" means every explicit target, never every process.
@interface VCAMInjectionPolicy : NSObject

+ (VCAMInjectionTarget)currentTarget;
+ (BOOL)isCurrentProcessEnabled;
+ (BOOL)isCurrentProcessEnabledForValues:(NSDictionary<NSString *, id> *)values;
+ (BOOL)shouldShowControlUI;
+ (BOOL)shouldShowControlUIForValues:(NSDictionary<NSString *, id> *)values;
+ (BOOL)isCurrentProcessMediaReplacementEnabled;
+ (BOOL)isCurrentProcessMediaReplacementEnabledForValues:(NSDictionary<NSString *, id> *)values;
+ (BOOL)isRecognizedTarget;
+ (NSString *)displayNameForTarget:(VCAMInjectionTarget)target;
+ (NSArray<NSString *> *)individualPreferenceKeys;

@end

NS_ASSUME_NONNULL_END
