// VCAMDetectProbe：原生 KYC 检测自检探针的一键入口（阶段 6）。
// 启动后经 vcam-probe://run?host=<ip>&port=<port> 或界面按钮触发一次约 50s 采集，
// 结果结构化 JSON + 视频/照片资产 POST 回测试台（默认 http://<host>:8077）。
// WKWebView 页（原阶段 6 的宿主 demo 并入本 App）：WKUIDelegate 的
// requestMediaCapturePermission（iOS 15+）自动放行 getUserMedia，
// 使 App 内 WebView 与 Safari 的指纹/权限路径差异可被同页对照采集。
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import "ProbeRunner.h"

@interface WKProbeViewController : UIViewController <WKUIDelegate, WKNavigationDelegate>
@property(nonatomic, strong) WKWebView *webView;
@end

@implementation WKProbeViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.allowsInlineMediaPlayback = YES;
    self.webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:config];
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.webView.UIDelegate = self;
    self.webView.navigationDelegate = self;
    [self.view addSubview:self.webView];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    NSString *base = [[NSUserDefaults standardUserDefaults] stringForKey:@"probeBaseURL"];
    if (!base.length) { base = @"http://127.0.0.1:8077"; }
    // kyc_upload_server 以 probe/ 为文档根：页面在 /kyc-flow.html。
    NSString *urlString = [base stringByAppendingString:@"/kyc-flow.html?auto=1"];
    [self.webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:urlString]]];
}

- (void)webView:(WKWebView *)webView
    requestMediaCapturePermissionForOrigin:(WKSecurityOrigin *)origin
                          initiatedByFrame:(WKFrameInfo *)frame
                                      type:(WKMediaCaptureType)type
                           decisionHandler:(void (^)(WKPermissionDecision decision))decisionHandler {
    // WebKit 公开头文件常量名为 Grant（非 Allow）：WKPermissionDecision{Prompt,Grant,Deny}。
    decisionHandler(WKPermissionDecisionGrant);
}

@end

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
    self.hostField.text = @"127.0.0.1:8077";
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

    UIButton *webButton = [UIButton buttonWithType:UIButtonTypeSystem];
    webButton.frame = CGRectMake(20, 256, 360, 44);
    [webButton setTitle:@"Open kyc-flow in WKWebView (vs Safari)" forState:UIControlStateNormal];
    webButton.layer.borderWidth = 1;
    webButton.layer.borderColor = UIColor.systemPurpleColor.CGColor;
    [webButton addTarget:self action:@selector(openWebView) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:webButton];

    self.logView = [[UITextView alloc] initWithFrame:CGRectMake(20, 310, 360, 380)];
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

- (void)openWebView {
    WKProbeViewController *web = [[WKProbeViewController alloc] init];
    [self presentViewController:web animated:YES completion:nil];
}

- (void)runTapped {
    NSString *hostPort = self.hostField.text.length ? self.hostField.text : @"127.0.0.1:8077";
    NSString *base = [@"http://" stringByAppendingString:hostPort];
    [[NSUserDefaults standardUserDefaults] setObject:base forKey:@"probeBaseURL"];
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
// minimal=1 诊断模式：只挂 video 输出（不挂 photo/metadata），用于隔离
// "多输出组合是否会阻断 iOS 18 帧流"（真机首轮出现全档零帧，Safari 同机正常）。
// simple=1 叠加开关：不锁 activeFormat、用会话默认 preset——隔离
// "InputPriority+锁 640x480 档"组合本身是否导致 iOS 18 原生管线零帧。
- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary *)opts {
    ProbeViewController *vc = (ProbeViewController *)self.window.rootViewController;
    if (![url.scheme isEqualToString:@"vcam-probe"]) { return YES; }
    NSString *host = nil;
    NSString *port = @"8077";
    BOOL minimal = NO;
    BOOL simple = NO;
    for (NSString *pair in [url.query componentsSeparatedByString:@"&"]) {
        NSArray *kv = [pair componentsSeparatedByString:@"="];
        if (kv.count == 2) {
            if ([kv[0] isEqualToString:@"host"]) { host = kv[1]; }
            if ([kv[0] isEqualToString:@"port"]) { port = kv[1]; }
            if ([kv[0] isEqualToString:@"minimal"]) { minimal = [kv[1] boolValue]; }
            if ([kv[0] isEqualToString:@"simple"]) { simple = [kv[1] boolValue]; }
        }
    }
    [[NSUserDefaults standardUserDefaults] setBool:minimal forKey:@"probeMinimal"];
    [[NSUserDefaults standardUserDefaults] setBool:simple forKey:@"probeSimple"];
    if (host.length) {
        vc.hostField.text = [NSString stringWithFormat:@"%@:%@", host, port];
    }
    [vc runTapped];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, @"AppDelegate");
    }
}
