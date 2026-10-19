#import "OSPSpeedViewController.h"
#import "OSPSpeedFeed.h"

// vi / en text of the screen, following the language pref (Settings > OmniSpeed > globe) or the system language.
#define T(vi, en) (self.feed.vietnamese ? (vi) : (en))

#pragma mark - Limit sign

// Vienna-style limit sign: white disc, red ring, black number. "–" in grey while the road has no limit in OSM.
@interface OSPLimitSignView : UIView
@property (nonatomic, strong) UILabel *number;
@property (nonatomic, strong) CAShapeLayer *ring;
- (void)setLimit:(int)limit source:(OSPLimitSource)source;
@end

@implementation OSPLimitSignView

- (instancetype)initWithFrame:(CGRect)frame
{
    if (!(self = [super initWithFrame:frame])) return nil;
    self.backgroundColor = UIColor.whiteColor;
    _ring = [CAShapeLayer layer];
    _ring.fillColor = UIColor.clearColor.CGColor;
    _ring.strokeColor = [UIColor colorWithRed:0.86 green:0.12 blue:0.12 alpha:1].CGColor;
    [self.layer addSublayer:_ring];
    _number = [UILabel new];
    _number.textAlignment = NSTextAlignmentCenter;
    _number.textColor = UIColor.blackColor;
    _number.adjustsFontSizeToFitWidth = YES;
    _number.minimumScaleFactor = 0.4;
    [self addSubview:_number];
    return self;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGFloat d = MIN(self.bounds.size.width, self.bounds.size.height);
    self.layer.cornerRadius = d / 2;
    CGFloat w = d * 0.14;
    _ring.lineWidth = w;
    _ring.path = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(self.bounds, w / 2 + d * 0.02, w / 2 + d * 0.02)].CGPath;
    _number.font = [UIFont monospacedDigitSystemFontOfSize:d * 0.46 weight:UIFontWeightBold];
    _number.frame = CGRectInset(self.bounds, w + d * 0.06, w);
}

// Sign on this way: red ring, black number. Sign read elsewhere on the road: lighter ring, grey number.
// Road-class default: grey ring. Nothing: "–".
- (void)setLimit:(int)limit source:(OSPLimitSource)source
{
    _number.text = limit > 0 ? [NSString stringWithFormat:@"%d", limit] : @"–";
    UIColor *ring = [UIColor colorWithRed:0.86 green:0.12 blue:0.12 alpha:1], *num = UIColor.blackColor;
    if (limit <= 0) num = [UIColor colorWithWhite:0.6 alpha:1];
    else if (source == OSPLimitClassDefault) { ring = [UIColor colorWithRed:0.49 green:0.55 blue:0.64 alpha:1]; num = [UIColor colorWithWhite:0.2 alpha:1]; }
    else if (source != OSPLimitSign) { ring = [UIColor colorWithRed:0.91 green:0.44 blue:0.42 alpha:1]; num = [UIColor colorWithWhite:0.2 alpha:1]; }
    _number.textColor = num;
    _ring.strokeColor = ring.CGColor;
}

@end

#pragma mark - Screen

@interface OSPSpeedViewController ()
@property (nonatomic, strong) OSPSpeedFeed *feed;
@property (nonatomic, strong) UILabel *speedLabel, *unitLabel, *roadLabel, *statusLabel, *mapLabel, *disabledLabel;
@property (nonatomic, strong) OSPLimitSignView *sign;
@property (nonatomic, strong) UIButton *gearButton;
@property (nonatomic, strong) UIView *flash;
@property (nonatomic) BOOL warning;
@end

@implementation OSPSpeedViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    self.feed = [OSPSpeedFeed new];
    __weak typeof(self) weakSelf = self;
    self.feed.onChange = ^{ [weakSelf refresh]; };

    // Red frame that pulses while over the limit
    _flash = [UIView new];
    _flash.backgroundColor = [UIColor colorWithRed:0.9 green:0.1 blue:0.1 alpha:1];
    _flash.alpha = 0;
    _flash.userInteractionEnabled = NO;
    [self.view addSubview:_flash];

    _speedLabel = [self label:[UIFont monospacedDigitSystemFontOfSize:200 weight:UIFontWeightBold] color:UIColor.whiteColor];
    _speedLabel.adjustsFontSizeToFitWidth = YES;
    _speedLabel.minimumScaleFactor = 0.3;
    _speedLabel.text = @"--";
    _unitLabel = [self label:[UIFont systemFontOfSize:28 weight:UIFontWeightSemibold] color:[UIColor colorWithWhite:0.6 alpha:1]];
    _unitLabel.text = @"km/h";
    _roadLabel = [self label:[UIFont systemFontOfSize:22 weight:UIFontWeightMedium] color:[UIColor colorWithWhite:0.8 alpha:1]];
    _roadLabel.adjustsFontSizeToFitWidth = YES;
    _roadLabel.minimumScaleFactor = 0.6;
    _statusLabel = [self label:[UIFont systemFontOfSize:15 weight:UIFontWeightMedium] color:[UIColor colorWithWhite:0.55 alpha:1]];
    _mapLabel = [self label:[UIFont systemFontOfSize:15 weight:UIFontWeightMedium] color:[UIColor colorWithWhite:0.55 alpha:1]];
    _disabledLabel = [self label:[UIFont systemFontOfSize:20 weight:UIFontWeightSemibold] color:[UIColor colorWithWhite:0.7 alpha:1]];
    _disabledLabel.numberOfLines = 0;
    _disabledLabel.hidden = YES;
    for (UILabel *l in @[_statusLabel, _mapLabel]) l.textAlignment = NSTextAlignmentLeft;

    _sign = [[OSPLimitSignView alloc] initWithFrame:CGRectZero];
    [_sign setLimit:-1 source:OSPLimitNone];
    [self.view addSubview:_sign];

    _gearButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_gearButton setImage:[UIImage systemImageNamed:@"gearshape.fill" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightMedium]] forState:UIControlStateNormal];
    _gearButton.tintColor = [UIColor colorWithWhite:0.6 alpha:1];
    [_gearButton addTarget:self action:@selector(openSettings) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_gearButton];

    for (UIView *v in @[_speedLabel, _unitLabel, _roadLabel, _statusLabel, _mapLabel, _disabledLabel, _sign, _gearButton]) v.translatesAutoresizingMaskIntoConstraints = NO;
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_speedLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_speedLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-30],
        [_speedLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:24],
        [_speedLabel.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-24],
        [_unitLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_unitLabel.topAnchor constraintEqualToAnchor:_speedLabel.bottomAnchor constant:-8],
        [_roadLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_roadLabel.topAnchor constraintEqualToAnchor:_unitLabel.bottomAnchor constant:12],
        [_roadLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:24],
        [_roadLabel.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-24],

        [_disabledLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_disabledLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [_disabledLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:32],
        [_disabledLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-32],

        [_sign.topAnchor constraintEqualToAnchor:safe.topAnchor constant:16],
        [_sign.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
        [_sign.widthAnchor constraintEqualToConstant:110],
        [_sign.heightAnchor constraintEqualToConstant:110],

        [_mapLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [_mapLabel.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-16],
        [_statusLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [_statusLabel.bottomAnchor constraintEqualToAnchor:_mapLabel.topAnchor constant:-4],
        [_statusLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_gearButton.leadingAnchor constant:-12],
        [_mapLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_gearButton.leadingAnchor constant:-12],

        [_gearButton.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
        [_gearButton.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12],
        [_gearButton.widthAnchor constraintEqualToConstant:44],
        [_gearButton.heightAnchor constraintEqualToConstant:44],
    ]];
}

- (UILabel *)label:(UIFont *)font color:(UIColor *)color
{
    UILabel *l = [UILabel new];
    l.font = font;
    l.textColor = color;
    l.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:l];
    return l;
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    _flash.frame = self.view.bounds;
    // The frame is a border: punch the middle out
    CAShapeLayer *mask = [CAShapeLayer layer];
    UIBezierPath *p = [UIBezierPath bezierPathWithRect:self.view.bounds];
    [p appendPath:[UIBezierPath bezierPathWithRoundedRect:CGRectInset(self.view.bounds, 18, 18) cornerRadius:28]];
    mask.path = p.CGPath;
    mask.fillRule = kCAFillRuleEvenOdd;
    _flash.layer.mask = mask;
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self.feed start];
    [self refresh];
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    [self.feed stop];
    [UIApplication sharedApplication].idleTimerDisabled = NO;
}

- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAllButUpsideDown; }

#pragma mark - Refresh

- (void)refresh
{
    OSPSpeedFeed *f = self.feed;
    [UIApplication sharedApplication].idleTimerDisabled = f.keepAwake;

    BOOL enabled = f.enabled;
    _disabledLabel.hidden = enabled;
    _disabledLabel.text = T(@"OmniSpeed đang tắt.\nBật trong Cài đặt > OmniSpeed.", @"OmniSpeed is off.\nTurn it on in Settings > OmniSpeed.");
    _speedLabel.hidden = _unitLabel.hidden = _roadLabel.hidden = _sign.hidden = _statusLabel.hidden = _mapLabel.hidden = !enabled;
    if (!enabled) { [self setWarning:NO]; return; }

    // Speed
    int speed = f.gpsSpeed;
    _speedLabel.text = speed >= 0 ? [NSString stringWithFormat:@"%d", speed] : @"--";

    // GPS line
    CLAuthorizationStatus auth = f.authStatus;
    if (auth == kCLAuthorizationStatusDenied || auth == kCLAuthorizationStatusRestricted)
        _statusLabel.text = T(@"Chưa cho phép vị trí: Cài đặt > Quyền riêng tư > Dịch vụ định vị > OmniSpeed", @"Location not allowed: Settings > Privacy > Location Services > OmniSpeed");
    else if (speed >= 0)
        _statusLabel.text = [NSString stringWithFormat:@"GPS ±%.0f m", f.gpsAccuracy];
    else
        _statusLabel.text = T(@"Đang tìm GPS…", @"Looking for GPS…");

    // Road + map line
    OSPRoad *road = f.road;
    _roadLabel.hidden = !f.showRoad;
    _roadLabel.text = road ? (road.name.length ? road.name : T(@"Đường không tên", @"Unnamed road")) : @"";
    if (f.mapError && !road)
        _mapLabel.text = [NSString stringWithFormat:T(@"OpenStreetMap: lỗi tải (%@)", @"OpenStreetMap: download failed (%@)"), f.mapError];
    else if (f.mapLoading && !f.mapReady)
        _mapLabel.text = T(@"OpenStreetMap: đang tải đường quanh đây…", @"OpenStreetMap: downloading nearby roads…");
    else if (!f.mapReady)
        _mapLabel.text = @"OpenStreetMap";
    else if (!road)
        _mapLabel.text = T(@"OpenStreetMap: không ở trên đường", @"OpenStreetMap: not on a road");
    else switch (road.source) {
        case OSPLimitSign:
            _mapLabel.text = [NSString stringWithFormat:T(@"OpenStreetMap: giới hạn %d km/h", @"OpenStreetMap: limit %d km/h"), road.limit]; break;
        case OSPLimitSignBehind:
            _mapLabel.text = [NSString stringWithFormat:T(@"Biển đã qua trên đường này: %d (%.0f m)", @"Sign passed on this road: %d (%.0f m)"), road.limit, road.inheritedDistance]; break;
        case OSPLimitSignAhead:
            _mapLabel.text = [NSString stringWithFormat:T(@"Biển phía trước trên đường này: %d (%.0f m)", @"Sign ahead on this road: %d (%.0f m)"), road.limit, road.inheritedDistance]; break;
        case OSPLimitClassDefault:
            _mapLabel.text = [NSString stringWithFormat:T(@"Chưa có biển trên OSM · mặc định %d (%@)", @"No sign in OSM · default %d (%@)"), road.limit, road.highway]; break;
        default:
            _mapLabel.text = T(@"OpenStreetMap: đường này chưa có giới hạn", @"OpenStreetMap: no limit tagged on this road"); break;
    }

    // Limit sign: shown while we are on a road; "–" when nothing is known for it
    _sign.hidden = !f.showLimit || !road;
    [_sign setLimit:road ? road.limit : -1 source:road ? road.source : OSPLimitNone];

    // Over the limit?
    BOOL over = f.warnEnabled && road && road.limit > 0 && speed >= 0 && speed > road.limit + f.warnOver;
    [self setWarning:over];
}

- (void)setWarning:(BOOL)on
{
    if (on == _warning) return;
    _warning = on;
    _speedLabel.textColor = on ? [UIColor colorWithRed:1 green:0.25 blue:0.25 alpha:1] : UIColor.whiteColor;
    [_flash.layer removeAllAnimations];
    if (on) {
        CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"opacity"];
        a.fromValue = @0.15; a.toValue = @0.9;
        a.duration = 0.45; a.autoreverses = YES; a.repeatCount = HUGE_VALF;
        [_flash.layer addAnimation:a forKey:@"pulse"];
        _flash.alpha = 0.9;
    } else {
        _flash.alpha = 0;
    }
}

#pragma mark - Actions

- (void)openSettings
{
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"prefs:root=OmniSpeed"] options:@{} completionHandler:nil];
}

@end
