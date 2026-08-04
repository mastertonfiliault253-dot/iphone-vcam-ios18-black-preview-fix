#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "../Core/VCAMConfiguration.h"
#import "../Core/VCAMInjectionPolicy.h"

static void VCAMWriteClassDumpFile(NSString *content) {
    NSError *error = nil;
    [content writeToFile:@"/tmp/vcam-msd-classes.txt" atomically:YES encoding:NSUTF8StringEncoding error:&error];
    [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:@"mediaserverd class dump written=%d error=%@", error == nil, error.localizedDescription ?: @"(none)"]];
}

static void VCAMEnumerateCaptureClasses(void) {
    @autoreleasepool {
        int classCount = objc_getClassList(NULL, 0);
        if (classCount <= 0) return;
        Class *classes = (Class *)calloc((size_t)classCount, sizeof(Class));
        if (classes == NULL) return;
        objc_getClassList(classes, classCount);
        NSMutableArray<NSString *> *interesting = [NSMutableArray array];
        for (int i = 0; i < classCount; i++) {
            const char *name = class_getName(classes[i]);
            if (name == NULL) continue;
            NSString *className = [NSString stringWithUTF8String:name];
            if (![className containsString:@"FigCapture"] &&
                ![className containsString:@"FigCamera"] &&
                ![className containsString:@"Capture"] &&
                ![className containsString:@"Camera"]) {
                continue;
            }
            NSMutableArray<NSString *> *methods = [NSMutableArray array];
            unsigned int methodCount = 0;
            Method *methodList = class_copyMethodList(classes[i], &methodCount);
            for (unsigned int m = 0; m < methodCount && m < 24; m++) {
                SEL selector = method_getName(methodList[m]);
                if (selector != NULL) {
                    [methods addObject:NSStringFromSelector(selector)];
                }
            }
            free(methodList);
            NSString *line = [NSString stringWithFormat:@"CLASS %@ methods=%lu [%@]",
                              className, (unsigned long)methodCount,
                              [methods componentsJoinedByString:@","]];
            [interesting addObject:line];
        }
        free(classes);
        NSString *content = [interesting componentsJoinedByString:@"\n"];
        VCAMWriteClassDumpFile(content);
    }
}

%ctor {
    @autoreleasepool {
        if ([VCAMInjectionPolicy currentTarget] != VCAMInjectionTargetMediaServer) return;
        BOOL enabled = [VCAMInjectionPolicy isCurrentProcessEnabled];
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:@"mediaserverd ctor enabled=%d", enabled]];
        if (!enabled) return;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            for (int attempt = 0; attempt < 30; attempt++) {
                [NSThread sleepForTimeInterval:2.0];
                VCAMEnumerateCaptureClasses();
            }
        });
    }
}