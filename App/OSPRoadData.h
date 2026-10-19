// Roads from OpenStreetMap: downloads the ways around the car from the Overpass API in 1 km cells, keeps them
// on disk (OSP_CACHE_DIR) and in memory, and answers "which road am I on, what is its maxspeed".
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

// Where the limit shown comes from, in the order it is looked for
typedef NS_ENUM(int, OSPLimitSource) {
    OSPLimitNone,          // nothing known: no tag on this road and no default for its class
    OSPLimitSign,          // this way's own maxspeed
    OSPLimitSignBehind,    // the last sign passed on this road (same name, walked back)
    OSPLimitSignAhead,     // a sign further along this road (OSM often tags one segment of a street only)
    OSPLimitClassDefault,  // the legal default for the road class (Vietnam, built-up area)
};

@interface OSPRoad : NSObject
@property (nonatomic, copy) NSString *name;      // OSM "name" (or ref), may be empty
@property (nonatomic, copy) NSString *highway;   // OSM "highway" class
@property (nonatomic) int limit;                  // km/h in force (see source); -1 = nothing known
@property (nonatomic) OSPLimitSource source;
@property (nonatomic) double distance;            // m from the fix to the way
@property (nonatomic) double inheritedDistance;   // SignBehind / SignAhead: m of road to that sign
@end

@interface OSPRoadData : NSObject

@property (nonatomic) int server;                 // index into OSP_OVERPASS_SERVERS
@property (nonatomic) BOOL useClassDefaults;      // OSPLimitClassDefault when the road carries no sign (pref)
@property (nonatomic, readonly) BOOL loading;     // a cell is being downloaded
@property (nonatomic, readonly) BOOL haveCell;    // the cell under the last fix is cached (so "no road" is an answer)
@property (nonatomic, readonly) NSString *lastError;   // last download failure (localized description), nil when fine
@property (nonatomic, copy) void (^onChange)(void);    // main thread: a cell arrived / failed

// The road under the fix, from the cache; nil when none is within reach or the cell is not here yet.
// Also starts the download of the cell under the fix and the one ahead along the course.
- (OSPRoad *)roadAt:(CLLocation *)fix;

- (void)clearCache;   // memory + disk

@end
