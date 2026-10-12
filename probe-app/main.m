// VCAMDetectProbe：原生 KYC 检测自检探针的一键入口（阶段 6）。
// 启动后经 vcam-probe://run?host=<ip>&port=<port> 或界面按钮触发一次约 50s 采集，
// 结果结构化 JSON + 视频/照片资产 POST 回测试台（默认 http://<host>:8077）。
#import <UIKit/UIKit.h>
#import "ProbeRunner.h"

@interface ProbeViewController : UIViewController <UITextFieldDelegate>
@property(nonatomic, strong) UITextView *logView;
@property(nonatomic, strong) UITextField *hostField;
@property(nonatomic, strong) UIButton *runButton;
@property(nonatomic, strong) ProbeRunner *runner;
@end

@implementation ProbeViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20, 70, 360, 40)];
    title.text = @"VCAM Detect Probe";
    title.font = [UIFont boldSystemFontOfSize:22];
    [self.view addSubview:title];

    self.hostField = [[UITextField alloc] initWithFrame:CGRectMake(20, 130, 360, 40)];
    self.hostField.placeholder = @"test server host (leave default ok)";
    self.hostField.text = @"192.168.2.181:8077";
    self.hostField.borderStyle = UITextBorderStyleRoundedRect;
    self.hostField.delegate = self;
    self.hostField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.hostField.autocorrectionType = UITextAutocorrectionTypeNo;
    [self.view addSubview:self.hostField];

    self.runButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.runButton.frame = CGRectMake(20, 190, 360, 56);
    [self.runButton setTitle:@"Run native probe (~50s)" forState:UIControlStateNormal];
    self.runButton.titleLabel.font = [UIFont boldSystemFontOfSize:20];
    self.runButton.layer.borderWidth = 1;
    self.runButton.layer.borderColor = UIColor.systemBlueColor.CGColor;
    [self.runButton addTarget:self action:@selector(runTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.runButton];

    self.logView = [[UITextView alloc] initWithFrame:CGRectMake(20, 266, 360, 420)];
    self.logView.editable = NO;
    self.logView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.logView.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.logView.text = @"ready\n";
    [self.view addSubview:self.logView];

    self.runner = [[ProbeRunner alloc] init];
}

- (void)appendLog:(NSString *)line {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.logView.text = [self.logView.text stringByAppendingString:line];
        NSRange end = NSMakeRange(self.logView.text.length, 0);
        [self.logView scrollRangeToVisible:end];
    });
}

- (void)runTapped {
    NSString *hostPort = self.hostField.text.length ? self.hostField.text : @"192.168.2.181:8077";
    NSString *base = [@"http://" stringByAppendingString:hostPort];
    self.runButton.enabled = NO;
    [self appendLog:@"\n[start] target "];
    [self appendLog:base];
    [self appendLog:@"\n"];
    __weak ProbeViewController *me = self;
    [self.runner runWithBaseURL:base
                       progress:^(NSString *s) { [me appendLog:s]; }
                      completion:^{
        dispatch_async(dispatch_get_main_queue(), ^{ me.runButton.enabled = YES; });
    }];
}

@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)opts {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[ProbeViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

// vcam-probe://run?host=192.168.2.181&port=8077 —— 无人值守经 uiopen 直接触发采集。
- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary *)opts {
    ProbeViewController *vc = (ProbeViewController *)self.window.rootViewController;
    if (![url.scheme isEqualToString:@"vcam-probe"]) { return YES; }
    NSString *host = nil;
    NSString *port = @"8077";
    for (NSString *pair in [url.query componentsSeparatedByString:@"&"]) {
        NSArray *kv = [pair componentsSeparatedByString:@"="];
        if (kv.count == 2) {
            if ([kv[0] isEqualToString:@"host"]) { host = kv[1]; }
            if ([kv[0] isEqualToString:@"port"]) { port = kv[1]; }
        }
    }
    if (host.length) {
        vc.hostField.text = [NSString stringWithFormat:@"%@:%@", host, port];
    }
    [vc runTapped];
    return YES;
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, @"AppDelegate");
    }
}
