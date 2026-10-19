#import "OSPSpeedFeed.h"
#import <notify.h>

#define OSP_GPS_FRESH 3.0   // s: an older fix counts as "no GPS"

@interface OSPSpeedFeed () <CLLocationManagerDelegate>
@property (nonatomic, strong) CLLocationManager *manager;
@property (nonatomic, strong) CLLocation *lastFix;
@property (nonatomic, strong) OSPRoadData *roads;
@property (nonatomic, strong) OSPRoad *road;
@property (nonatomic, strong) NSDictionary *prefs;
@property (nonatomic, strong) NSTimer *ageTimer;
@property (nonatomic) int prefsToken, clearToken;
@property (nonatomic) BOOL running;
@end

@implementation OSPSpeedFeed

- (instancetype)init
{
    if (!(self = [super init])) return nil;
    _gpsSpeed = -1; _gpsAccuracy = -1;
    _roads = [OSPRoadData new];
    __weak typeof(self) weakSelf = self;
    _roads.onChange = ^{ [weakSelf updateRoad]; [weakSelf changed]; };
    [self reloadPrefs];
    return self;
}

#pragma mark - Prefs

// Sandbox-free app: read the prefs file the settings bundle writes. Missing keys use the defaults in OmniSpeed.h.
- (void)reloadPrefs
{
    self.prefs = [NSDictionary dictionaryWithContentsOfFile:@OSP_PREFS_PATH] ?: @{};
    self.roads.server = self.server;
    self.roads.useClassDefaults = self.classDefaults;
}

- (BOOL)prefBool:(NSString *)key default:(BOOL)def { id v = self.prefs[key]; return v ? [v boolValue] : def; }
- (int)prefInt:(NSString *)key default:(int)def     { id v = self.prefs[key]; return v ? [v intValue] : def; }

- (BOOL)enabled     { return [self prefBool:OSP_KEY_ENABLED default:YES]; }
- (BOOL)keepAwake   { return [self prefBool:OSP_KEY_KEEP_AWAKE default:YES]; }
- (BOOL)showLimit   { return [self prefBool:OSP_KEY_SHOW_LIMIT default:YES]; }
- (BOOL)showRoad    { return [self prefBool:OSP_KEY_SHOW_ROAD default:YES]; }
- (BOOL)warnEnabled { return [self prefBool:OSP_KEY_WARN default:YES]; }
- (BOOL)classDefaults { return [self prefBool:OSP_KEY_CLASS_DEFAULTS default:YES]; }
- (int)warnOver     { return MAX(-10, MIN(10, [self prefInt:OSP_KEY_WARN_OVER default:5])); }
- (int)server
{
    int s = [self prefInt:OSP_KEY_SERVER default:0];
    return (s >= 0 && s < OSP_OVERPASS_COUNT) ? s : 0;
}
- (BOOL)vietnamese
{
    NSString *lang = self.prefs[OSP_KEY_LANGUAGE];
    if ([lang isKindOfClass:[NSString class]] && lang.length) return [lang isEqualToString:@"vi"];
    return [[NSLocale preferredLanguages].firstObject hasPrefix:@"vi"];
}

#pragma mark - Road

- (void)updateRoad
{
    self.road = self.lastFix ? [self.roads roadAt:self.lastFix] : nil;
}

- (BOOL)mapLoading     { return self.roads.loading; }
- (BOOL)mapReady       { return self.roads.haveCell; }
- (NSString *)mapError { return self.roads.lastError; }

#pragma mark - GPS

- (int)gpsSpeed
{
    CLLocation *fix = self.lastFix;
    if (!fix || -[fix.timestamp timeIntervalSinceNow] > OSP_GPS_FRESH || fix.horizontalAccuracy < 0 || fix.horizontalAccuracy > 100) return -1;
    double v = fix.speed;   // m/s, < 0 = invalid (usually standing still)
    int kmh = (int)lround(MAX(v, 0) * 3.6);
    return kmh > 300 ? -1 : kmh;
}

- (double)gpsAccuracy
{
    CLLocation *fix = self.lastFix;
    return (fix && -[fix.timestamp timeIntervalSinceNow] <= OSP_GPS_FRESH) ? fix.horizontalAccuracy : -1;
}

- (CLAuthorizationStatus)authStatus
{
    if (@available(iOS 14, *)) return self.manager ? self.manager.authorizationStatus : kCLAuthorizationStatusNotDetermined;
    return [CLLocationManager authorizationStatus];
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations
{
    CLLocation *fix = locations.lastObject;
    if (!fix || fix.horizontalAccuracy < 0 || fix.horizontalAccuracy > 200) return;   // too rough to pick a road
    self.lastFix = fix;
    [self updateRoad];
    [self changed];
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error
{
    [self changed];
}

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager
{
    CLAuthorizationStatus s = self.authStatus;
    if (s == kCLAuthorizationStatusAuthorizedWhenInUse || s == kCLAuthorizationStatusAuthorizedAlways) [manager startUpdatingLocation];
    [self changed];
}

#pragma mark - Lifecycle

- (void)start
{
    if (self.running) return;
    self.running = YES;
    [self reloadPrefs];

    if (!self.manager) {
        CLLocationManager *m = [CLLocationManager new];
        m.delegate = self;
        m.desiredAccuracy = kCLLocationAccuracyBestForNavigation;
        m.distanceFilter = kCLDistanceFilterNone;
        m.activityType = CLActivityTypeAutomotiveNavigation;
        m.pausesLocationUpdatesAutomatically = NO;
        self.manager = m;
    }
    CLAuthorizationStatus s = self.authStatus;
    if (s == kCLAuthorizationStatusNotDetermined) [self.manager requestWhenInUseAuthorization];
    else if (s == kCLAuthorizationStatusAuthorizedWhenInUse || s == kCLAuthorizationStatusAuthorizedAlways) [self.manager startUpdatingLocation];

    __weak typeof(self) weakSelf = self;
    if (!self.prefsToken) {
        notify_register_dispatch(OSP_DARWIN_PREFS, &_prefsToken, dispatch_get_main_queue(), ^(int token) {
            [weakSelf reloadPrefs];
            [weakSelf changed];
        });
    }
    if (!self.clearToken) {
        notify_register_dispatch(OSP_DARWIN_CLEAR_CACHE, &_clearToken, dispatch_get_main_queue(), ^(int token) {
            typeof(self) self = weakSelf;
            [self.roads clearCache];
            [self updateRoad];
            [self changed];
        });
    }
    // GPS stops silently when the signal is gone: age the values on a timer so the screen notices.
    self.ageTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) { [weakSelf changed]; }];
    [self changed];
}

- (void)stop
{
    if (!self.running) return;
    self.running = NO;
    [self.manager stopUpdatingLocation];
    [self.ageTimer invalidate]; self.ageTimer = nil;
}

- (void)changed
{
    if (self.onChange) self.onChange();
}

@end
