#import "VCAMControlPanelViewController.h"
#import "VCAMSharedFramePreviewView.h"

@interface VCAMControlPanelViewController ()
@property(nonatomic, copy) NSDictionary<NSString *, NSString *> *status;
@property(nonatomic, strong, nullable) UILabel *sourceLabel;
@property(nonatomic, strong, nullable) UILabel *detailLabel;
@property(nonatomic, strong, nullable) UILabel *streamLabel;
@property(nonatomic, strong, nullable) UIButton *mirrorButton;
@property(nonatomic, strong, nullable) UIButton *contentModeButton;
@property(nonatomic, strong, nullable) UIButton *loopButton;
@end

@implementation VCAMControlPanelViewController

- (instancetype)initWithStatus:(NSDictionary<NSString *,NSString *> *)status {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _status = [status copy];
        self.modalPresentationStyle = UIModalPresentationOverFullScreen;
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    [self startStatusRefresh];

    UIControl *scrim = [UIControl new];
    scrim.translatesAutoresizingMaskIntoConstraints = NO;
    scrim.accessibilityLabel = @"关闭 VCAM 控制面板";
    [scrim addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:scrim];

    UIView *card = [UIView new];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor colorWithRed:0.06 green:0.09 blue:0.15 alpha:0.5];
    card.layer.cornerRadius = 24.0;
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = [UIColor colorWithRed:0.28 green:0.35 blue:0.45 alpha:0.85].CGColor;
    card.clipsToBounds = YES;
    [self.view addSubview:card];

    UIScrollView *scrollView = [UIScrollView new];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.alwaysBounceVertical = YES;
    scrollView.showsVerticalScrollIndicator = YES;
    [card addSubview:scrollView];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12.0;
    stack.layoutMargins = UIEdgeInsetsMake(20, 18, 24, 18);
    stack.layoutMarginsRelativeArrangement = YES;
    [scrollView addSubview:stack];

    UIStackView *header = [[UIStackView alloc] init];
    header.axis = UILayoutConstraintAxisHorizontal;
    header.alignment = UIStackViewAlignmentCenter;
    header.spacing = 8.0;
    UILabel *title = [self labelWithText:@"虚拟视频控制面板" size:22 weight:UIFontWeightBold color:UIColor.whiteColor];
    [header addArrangedSubview:title];
    UIButton *close = [self compactIconButton:@"xmark" accessibilityLabel:@"关闭控制面板" action:@selector(closeTapped)];
    [header addArrangedSubview:close];
    [stack addArrangedSubview:header];

    UIView *statusCard = [self statusCard];
    [stack addArrangedSubview:statusCard];
    VCAMSharedFramePreviewView *preview = [[VCAMSharedFramePreviewView alloc] initWithFrame:CGRectZero];
    preview.translatesAutoresizingMaskIntoConstraints = NO;
    preview.accessibilityLabel = @"当前虚拟摄像头画面预览";
    [stack addArrangedSubview:preview];
    [preview.heightAnchor constraintEqualToConstant:210].active = YES;
    [stack addArrangedSubview:[self sectionLabel:@"导入资源"]];
    {
        UIStackView *r1 = [UIStackView new]; r1.axis=UILayoutConstraintAxisHorizontal; r1.distribution=UIStackViewDistributionFillEqually; r1.spacing=8.0;
        [r1 addArrangedSubview:[self actionButton:@"从相册选择" symbol:@"photo.on.rectangle" color:[UIColor colorWithRed:0.05 green:0.46 blue:0.96 alpha:1] action:@selector(photoLibraryTapped)]];
        [r1 addArrangedSubview:[self actionButton:@"从文件选择" symbol:@"folder" color:[UIColor colorWithRed:0.02 green:0.68 blue:0.82 alpha:1] action:@selector(documentTapped)]];
        [stack addArrangedSubview:r1];
    }
    {
        UIStackView *r2 = [UIStackView new]; r2.axis=UILayoutConstraintAxisHorizontal; r2.distribution=UIStackViewDistributionFillEqually; r2.spacing=8.0;
        [r2 addArrangedSubview:[self actionButton:@"在线源下载" symbol:@"arrow.down.circle" color:[UIColor colorWithRed:0.49 green:0.22 blue:0.93 alpha:1] action:@selector(onlineTapped)]];
        [r2 addArrangedSubview:[self actionButton:@"输入直播流" symbol:@"dot.radiowaves.left.and.right" color:[UIColor colorWithRed:0.82 green:0.12 blue:0.42 alpha:1] action:@selector(streamTapped)]];
        [stack addArrangedSubview:r2];
    }

    [stack addArrangedSubview:[self sectionLabel:@"画面调整"]];
    {
        UIStackView *rr = [UIStackView new]; rr.axis=UILayoutConstraintAxisHorizontal; rr.distribution=UIStackViewDistributionFillEqually; rr.spacing=8.0;
        [rr addArrangedSubview:[self actionButton:@"逆时针旋转" symbol:@"rotate.left" color:[UIColor colorWithRed:0.20 green:0.27 blue:0.38 alpha:1] action:@selector(counterClockwiseTapped)]];
        [rr addArrangedSubview:[self actionButton:@"顺时针旋转" symbol:@"rotate.right" color:[UIColor colorWithRed:0.20 green:0.27 blue:0.38 alpha:1] action:@selector(clockwiseTapped)]];
        [stack addArrangedSubview:rr];
    }
    {
        UIStackView *ar = [UIStackView new]; ar.axis=UILayoutConstraintAxisHorizontal; ar.distribution=UIStackViewDistributionFillEqually; ar.spacing=8.0;
        UIButton *mirrorButton = [self actionButton:[NSString stringWithFormat:@"镜像：%@", self.status[@"mirror"] ?: @"关闭"] symbol:@"arrow.left.and.right.righttriangle.left.righttriangle.right" color:[UIColor colorWithRed:0.20 green:0.27 blue:0.38 alpha:1] action:@selector(mirrorTapped)];
        [ar addArrangedSubview:mirrorButton]; self.mirrorButton = mirrorButton;
        UIButton *contentModeButton = [self actionButton:[NSString stringWithFormat:@"填充方式：%@", self.status[@"contentMode"] ?: @"裁切填满"] symbol:@"rectangle.inset.filled" color:[UIColor colorWithRed:0.20 green:0.27 blue:0.38 alpha:1] action:@selector(contentModeTapped)];
        [ar addArrangedSubview:contentModeButton]; self.contentModeButton = contentModeButton;
        [stack addArrangedSubview:ar];
    }
    {
        UIStackView *br = [UIStackView new]; br.axis=UILayoutConstraintAxisHorizontal; br.distribution=UIStackViewDistributionFillEqually; br.spacing=8.0;
        UIButton *loopButton = [self actionButton:[NSString stringWithFormat:@"视频循环：%@", self.status[@"loop"] ?: @"开启"] symbol:@"repeat" color:[UIColor colorWithRed:0.20 green:0.27 blue:0.38 alpha:1] action:@selector(loopTapped)];
        [br addArrangedSubview:loopButton]; self.loopButton = loopButton;
        [stack addArrangedSubview:br];
    }
    [stack addArrangedSubview:[self sectionLabel:@"相机切换"]];
    {
        UIStackView *cr = [UIStackView new]; cr.axis=UILayoutConstraintAxisHorizontal; cr.distribution=UIStackViewDistributionFillEqually; cr.spacing=8.0;
        [cr addArrangedSubview:[self actionButton:@"启用虚拟相机" symbol:@"video.fill" color:[UIColor colorWithRed:0.12 green:0.68 blue:0.34 alpha:1] action:@selector(enableTapped)]];
        [cr addArrangedSubview:[self actionButton:@"恢复真实相机" symbol:@"camera" color:[UIColor colorWithRed:0.88 green:0.20 blue:0.24 alpha:1] action:@selector(restoreTapped)]];
        [stack addArrangedSubview:cr];
    }

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    NSLayoutConstraint *preferredCardWidth = [card.widthAnchor constraintEqualToConstant:380];
    preferredCardWidth.priority = UILayoutPriorityDefaultHigh;
    preferredCardWidth.active = YES;
    [NSLayoutConstraint activateConstraints:@[
        [scrim.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scrim.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scrim.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [scrim.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [card.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
        [card.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:12],
        [card.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-12],
        [card.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor constant:-24],
        [card.heightAnchor constraintLessThanOrEqualToAnchor:safe.heightAnchor constant:-20],
        [scrollView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [scrollView.topAnchor constraintEqualToAnchor:card.topAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor],
        [stack.widthAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.widthAnchor],
        [close.widthAnchor constraintEqualToConstant:44],
        [close.heightAnchor constraintEqualToConstant:44],
        [statusCard.heightAnchor constraintGreaterThanOrEqualToConstant:112],
    ]];
}

- (UIView *)statusCard {
    UIView *card = [UIView new];
    card.backgroundColor = [UIColor colorWithRed:0.10 green:0.15 blue:0.23 alpha:0.5];
    card.layer.cornerRadius = 16.0;
    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 5.0;
    stack.layoutMargins = UIEdgeInsetsMake(14, 14, 14, 14);
    stack.layoutMarginsRelativeArrangement = YES;
    [card addSubview:stack];
    [stack addArrangedSubview:[self labelWithText:@"当前源信息" size:14 weight:UIFontWeightSemibold
                                            color:[UIColor colorWithRed:0.35 green:0.68 blue:1 alpha:1]]];
    UILabel *source = [self labelWithText:self.status[@"source"] ?: @"真实相机"
                                    size:17 weight:UIFontWeightBold color:UIColor.whiteColor];
    [stack addArrangedSubview:source];
    self.sourceLabel = source;
    UILabel *detail = [self labelWithText:self.status[@"detail"] ?: @"未启用替换"
                                      size:13 weight:UIFontWeightRegular
                                     color:[UIColor colorWithWhite:0.72 alpha:1]];
    detail.numberOfLines = 0;
    [stack addArrangedSubview:detail];
    self.detailLabel = detail;
    UILabel *stream = [self labelWithText:@"推流状态：查询中"
                                     size:13 weight:UIFontWeightSemibold
                                    color:UIColor.systemGrayColor];
    [stack addArrangedSubview:stream];
    self.streamLabel = stream;
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
    ]];
    return card;
}

- (void)updateStatus:(NSDictionary<NSString *, NSString *> *)status {
    _status = [status copy];
    self.sourceLabel.text = status[@"source"] ?: @"真实相机";
    self.detailLabel.text = status[@"detail"] ?: @"未启用替换";
    NSString *stream = status[@"stream"];
    if (stream.length > 0) {
        self.streamLabel.text = [NSString stringWithFormat:@"推流状态：%@", stream];
        self.streamLabel.textColor = [stream hasPrefix:@"已收到"] || [stream hasPrefix:@"已加载"]
            ? [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1]
            : [UIColor colorWithRed:0.95 green:0.32 blue:0.30 alpha:1];
    }
    [self updateButton:self.mirrorButton label:@"镜像" value:status[@"mirror"] ?: @"关闭"];
    [self updateButton:self.contentModeButton label:@"填充方式" value:status[@"contentMode"] ?: @"裁切填满"];
    [self updateButton:self.loopButton label:@"视频循环" value:status[@"loop"] ?: @"开启"];
}

- (void)startStatusRefresh {
    static const NSTimeInterval refreshInterval = 1.0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(refreshInterval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!self.isViewLoaded || self.view.window == nil) return;
        [self.delegate controlPanelDidRequestStatusRefresh:self];
        [self startStatusRefresh];
    });
}

- (void)updateButton:(UIButton *)button label:(NSString *)label value:(NSString *)value {
    if (button == nil) return;
    UIButtonConfiguration *configuration = button.configuration;
    configuration.title = [NSString stringWithFormat:@"%@：%@", label, value];
    button.configuration = configuration;
}

- (UILabel *)sectionLabel:(NSString *)text {
    return [self labelWithText:text size:16 weight:UIFontWeightSemibold color:UIColor.whiteColor];
}

- (UILabel *)labelWithText:(NSString *)text size:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color {
    UILabel *label = [UILabel new];
    label.text = text;
    UIFont *baseFont = [UIFont systemFontOfSize:size weight:weight];
    label.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody] scaledFontForFont:baseFont];
    label.textColor = color;
    label.adjustsFontForContentSizeCategory = YES;
    label.minimumScaleFactor = 0.75;
    label.adjustsFontSizeToFitWidth = YES;
    return label;
}

- (UIButton *)compactIconButton:(NSString *)symbol accessibilityLabel:(NSString *)label action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    button.tintColor = UIColor.whiteColor;
    button.accessibilityLabel = label;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UIButton *)actionButton:(NSString *)title symbol:(NSString *)symbol color:(UIColor *)color action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *configuration = [UIButtonConfiguration filledButtonConfiguration];
    configuration.title = title;
    configuration.image = [UIImage systemImageNamed:symbol];
    configuration.imagePadding = 8.0;
    configuration.baseBackgroundColor = color;
    configuration.baseForegroundColor = UIColor.whiteColor;
    configuration.cornerStyle = UIButtonConfigurationCornerStyleMedium;
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(12, 14, 12, 14);
    button.configuration = configuration;
    button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    button.titleLabel.minimumScaleFactor = 0.72;
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.accessibilityLabel = title;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:48].active = YES;
    return button;
}

- (void)closeTapped { [self.delegate controlPanelDidRequestClose:self]; }
- (void)photoLibraryTapped { [self.delegate controlPanelDidRequestPhotoLibrary:self]; }
- (void)documentTapped { [self.delegate controlPanelDidRequestDocument:self]; }
- (void)onlineTapped { [self.delegate controlPanelDidRequestOnlineVideo:self]; }
- (void)streamTapped { [self.delegate controlPanelDidRequestLiveStream:self]; }
- (void)clockwiseTapped { [self.delegate controlPanelDidRequestClockwiseRotation:self]; }
- (void)counterClockwiseTapped { [self.delegate controlPanelDidRequestCounterClockwiseRotation:self]; }
- (void)mirrorTapped { [self.delegate controlPanelDidRequestMirrorToggle:self]; }
- (void)contentModeTapped { [self.delegate controlPanelDidRequestContentModeCycle:self]; }
- (void)loopTapped { [self.delegate controlPanelDidRequestLoopToggle:self]; }
- (void)enableTapped { [self.delegate controlPanelDidRequestEnableVirtualCamera:self]; }
- (void)restoreTapped { [self.delegate controlPanelDidRequestRestoreCamera:self]; }

@end
