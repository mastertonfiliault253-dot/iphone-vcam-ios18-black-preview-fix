// vcamprobcli：把 MiniRunner 的教科书原生采集以 CLI 进程跑起来——
// 不经 LaunchServices、无 UI 场景角色，用于隔离"零帧是否由 App 安装/启动身份造成"。
// 用法：vcamprobcli [秒数，默认 12]。结果同时走 stderr 与 /var/mobile/Media/VCAM/mini.log。
// 用法：vcamprobcli bw —— 只枚举本进程（AVF 客户端侧）加载的 BW* 前缀类中
// Torch/Exposure/Gain/Flash/Illum 相关方法名，写 bw_symbols_client.log；
// 与 cameracaptured 侧的 bw_symbols.log（Entry.xm marker dump）配合，
// 决定 torch/AE 状态观测 hook 的落点。
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <string.h>
#import "MiniRunner.h"

static void dumpClientBWSymbols(void) {
    FILE *file = fopen("/var/mobile/Media/VCAM/bw_symbols_client.log", "w");
    if (file == NULL) { fprintf(stderr, "[vcam-cli] cannot open bw_symbols_client.log\n"); return; }
    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    unsigned int hits = 0;
    fprintf(file, "# client bw symbol dump classes=%u\n", classCount);
    for (unsigned int i = 0; i < classCount; i++) {
        const char *className = class_getName(classes[i]);
        if (className == NULL || strncmp(className, "BW", 2) != 0) continue;
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(classes[i], &methodCount);
        for (unsigned int m = 0; m < methodCount; m++) {
            const char *selector = sel_getName(method_getName(methods[m]));
            if (selector == NULL) continue;
            if (strstr(selector, "Torch") != NULL || strstr(selector, "torch") != NULL ||
                strstr(selector, "Exposure") != NULL || strstr(selector, "exposure") != NULL ||
                strstr(selector, "Gain") != NULL || strstr(selector, "Flash") != NULL ||
                strstr(selector, "Illum") != NULL) {
                fprintf(file, "%s %s\n", className, selector);
                hits++;
            }
        }
        free(methods);
    }
    free(classes);
    fclose(file);
    fprintf(stderr, "[vcam-cli] client bw scan classes=%u hits=%u\n", classCount, hits);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "bw") == 0) {
            dumpClientBWSymbols();
            return 0;
        }
        NSInteger seconds = 12;
        if (argc > 1) { seconds = atoll(argv[1]); if (seconds < 1) { seconds = 1; } }
        fprintf(stderr, "[vcam-cli] start seconds=%ld uid=%d\n", (long)seconds, (int)getuid());
        [MiniRunner startWithDurationSeconds:seconds];
        sleep((unsigned)(seconds + 3));
        fprintf(stderr, "[vcam-cli] exit\n");
    }
    return 0;
}
