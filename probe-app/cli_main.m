// vcamprobcli：把 MiniRunner 的教科书原生采集以 CLI 进程跑起来——
// 不经 LaunchServices、无 UI 场景角色，用于隔离"零帧是否由 App 安装/启动身份造成"。
// 用法：vcamprobcli [秒数，默认 12]。结果同时走 stderr 与 /var/mobile/Media/VCAM/mini.log。
#import <Foundation/Foundation.h>
#import <stdlib.h>
#import "MiniRunner.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSInteger seconds = 12;
        if (argc > 1) { seconds = atoll(argv[1]); if (seconds < 1) { seconds = 1; } }
        fprintf(stderr, "[vcam-cli] start seconds=%ld uid=%d\n", (long)seconds, (int)getuid());
        [MiniRunner startWithDurationSeconds:seconds];
        sleep((unsigned)(seconds + 3));
        fprintf(stderr, "[vcam-cli] exit\n");
    }
    return 0;
}
