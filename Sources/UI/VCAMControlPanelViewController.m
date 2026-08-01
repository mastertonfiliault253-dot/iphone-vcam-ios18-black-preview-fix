#import "VCAMControlPanelViewController.h"

@interface VCAMControlPanelViewController ()
@property(nonatomic, copy) NSDictionary<NSString *, NSString *> *status;
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
    self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.52];

    UIControl *scrim = [UIControl new];
    scrim.translatesAutoresizingMaskIntoConstraints = NO;
    scrim.accessibilityLabel = @"关闭 VCAM 控制面板";
    [scrim addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:scrim];

    UIView *card = [UIView new];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor colorWithRed:0.06 green:0.09 blue:0.15 alpha:0.98];
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

    UILabel *notice = [self labelWithText:@"仅用于已授权的软件测试；当前版本采用安全进程白名单。"
                                      size:13
                                    weight:UIFontWeightRegular
                                     color:[UIColor colorWithWhite:0.72 alpha:1.0]];
    notice.numberOfLines = 0;
    [stack addArrangedSubview:notice];

    UIView *statusCard = [self statusCard];
    [stack addArrangedSubview:statusCard];
    [stack addArrangedSubview:[self sectionLabel:@"导入资源"]];
    [stack addArrangedSubview:[self actionButton:@"从相册选择" symbol:@"photo.on.rectangle"
                                                  color:[UIColor colorWithRed:0.05 green:0.46 blue:0.96 alpha:1]
                                                 action:@selector(photoLibraryTapped)]];
    [stack addArrangedSubview:[self actionButton:@"从文件选择" symbol:@"folder"
                                                  color:[UIColor colorWithRed:0.02 green:0.68 blue:0.82 alpha:1]
                                                 action:@selector(documentTapped)]];
    [stack addArrangedSubview:[self actionButton:@"在线源下载" symbol:@"arrow.down.circle"
                                                  color:[UIColor colorWithRed:0.49 green:0.22 blue:0.93 alpha:1]
                                                 action:@selector(onlineTapped)]];
    [stack addArrangedSubview:[self actionButton:@"输入直播流" symbol:@"dot.radiowaves.left.and.right"
                                                  color:[UIColor colorWithRed:0.82 green:0.12 blue:0.42 alpha:1]
                                                 action:@selector(streamTapped)]];

    [stack addArrangedSubview:[self sectionLabel:@"画面调整"]];
    UIStackView *rotationRow = [[UIStackView alloc] init];
    rotationRow.axis = UILayoutConstraintAxisHorizontal;
    rotationRow.distribution = UIStackViewDistributionFillEqually;
    rotationRow.spacing = 8.0;
    [rotationRow addArrangedSubview:[self actionButton:@"逆时针旋转" symbol:@"rotate.left"
                                                        color:[UIColor colorWithRed:0.20 green:0.27 blue:0.38 alpha:1]
                                                       action:@selector(counterClockwiseTapped)]];
    [rotationRow addArrangedSubview:[self actionButton:@"顺时针旋转" symbol:@"rotate.right"
                                                        color:[UIColor colorWithRed:0.20 green:0.27 blue:0.38 alpha:1]
                                                       action:@selector(clockwiseTapped)]];
    [stack addArrangedSubview:rotationRow];
    [stack addArrangedSubview:[self actionButton:[NSString stringWithFormat:@"镜像：%@", self.status[@"mirror"] ?: @"关闭"]
                                                symbol:@"arrow.left.and.right.righttriangle.left.righttriangle.right"
                                                 color:[UIColor colorWithRed:0.20 green:0.27 blue:0.38 alpha:1]
                                                action:@selector(mirrorTapped)]];
    [stack addArrangedSubview:[self actionButton:[NSString stringWithFormat:@"填充方式：%@", self.status[@"contentMode"] ?: @"裁切填满"]
                                                symbol:@"rectangle.inset.filled"
                                                 color:[UIColor colorWithRed:0.20 green:0.27 blue:0.38 alpha:1]
                                                action:@selector(contentModeTapped)]];
    [stack addArrangedSubview:[self actionButton:[NSString stringWithFormat:@"替换声音：%@", self.status[@"audio"] ?: @"关闭"]
                                                symbol:@"waveform"
                                                 color:[UIColor colorWithRed:0.20 green:0.27 blue:0.38 alpha:1]
                                                action:@selector(audioTapped)]];
    [stack addArrangedSubview:[self actionButton:[NSString stringWithFormat:@"视频循环：%@", self.status[@"loop"] ?: @"开启"]
                                                symbol:@"repeat"
                                                 color:[UIColor colorWithRed:0.20 green:0.27 blue:0.38 alpha:1]
                                                action:@selector(loopTapped)]];

    [stack addArrangedSubview:[self sectionLabel:@"目标与恢复"]];
    [stack addArrangedSubview:[self actionButton:@"选择替换软件和进程" symbol:@"app.badge.checkmark"
                                                  color:[UIColor colorWithRed:0.10 green:0.55 blue:0.42 alpha:1]
                                                 action:@selector(targetTapped)]];
    [stack addArrangedSubview:[self actionButton:@"恢复真实相机" symbol:@"camera"
                                                  color:[UIColor colorWithRed:0.88 green:0.20 blue:0.24 alpha:1]
                                                 action:@selector(restoreTapped)]];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    NSLayoutConstraint *preferredCardWidth = [card.widthAnchor constraintEqualToConstant:380];
    preferredCardWidth.priority = UILayoutPriorityDefaultHigh;
    preferredCardWidth.active = YES;
    NSLayoutConstraint *preferredCardHeight = [card.heightAnchor constraintEqualToAnchor:safe.heightAnchor
                                                                                  constant:-20];
    preferredCardHeight.priority = UILayoutPriorityDefaultHigh;
    preferredCardHeight.active = YES;
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
    card.backgroundColor = [UIColor colorWithRed:0.10 green:0.15 blue:0.23 alpha:1];
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
    [stack addArrangedSubview:[self labelWithText:self.status[@"source"] ?: @"真实相机"
                                             size:17 weight:UIFontWeightBold color:UIColor.whiteColor]];
    UILabel *detail = [self labelWithText:self.status[@"detail"] ?: @"未启用替换"
                                      size:13 weight:UIFontWeightRegular
                                     color:[UIColor colorWithWhite:0.72 alpha:1]];
    detail.numberOfLines = 0;
    [stack addArrangedSubview:detail];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
    ]];
    return card;
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
- (void)audioTapped { [self.delegate controlPanelDidRequestAudioToggle:self]; }
- (void)contentModeTapped { [self.delegate controlPanelDidRequestContentModeCycle:self]; }
- (void)loopTapped { [self.delegate controlPanelDidRequestLoopToggle:self]; }
- (void)restoreTapped { [self.delegate controlPanelDidRequestRestoreCamera:self]; }
- (void)targetTapped { [self.delegate controlPanelDidRequestTargetSelector:self]; }

@end
