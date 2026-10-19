// Data for the speed screen: the app's own GPS (current speed), the road under the car from OpenStreetMap
// (OSPRoadData) and the prefs (Settings > OmniSpeed). Everything is delivered on the main thread.
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import "OmniSpeed.h"
#import "OSPRoadData.h"

@interface OSPSpeedFeed : NSObject

// GPS
@property (nonatomic, readonly) int gpsSpeed;             // km/h, -1 = no usable fix
@property (nonatomic, readonly) double gpsAccuracy;       // m, -1 = none
@property (nonatomic, readonly) CLAuthorizationStatus authStatus;

// Road (OpenStreetMap)
@property (nonatomic, readonly) OSPRoad *road;            // nil = off road / cell not downloaded yet
@property (nonatomic, readonly) BOOL mapLoading;          // downloading the cell
@property (nonatomic, readonly) BOOL mapReady;            // the cell under the car is here (so nil road = off road)
@property (nonatomic, readonly) NSString *mapError;       // last download failure, nil when fine

// Prefs (Root.plist keys, see OmniSpeed.h)
@property (nonatomic, readonly) BOOL enabled, keepAwake, showLimit, showRoad, warnEnabled, classDefaults;
@property (nonatomic, readonly) int server, warnOver;
@property (nonatomic, readonly) BOOL vietnamese;          // language pref, else system language

// Called on the main thread whenever any value above may have changed.
@property (nonatomic, copy) void (^onChange)(void);

- (void)start;    // GPS + Darwin listeners
- (void)stop;     // app leaving the screen: GPS off

@end
