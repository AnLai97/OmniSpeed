#import "OSPRoadData.h"
#import "OmniSpeed.h"

#define OSP_CELL_DEG     0.01     // cell size in degrees (~1.1 km); the key is the cell's floor(lat/lon / size)
#define OSP_FETCH_RADIUS 1000     // m around the cell centre: covers the cell with margin for roads at its edge
#define OSP_MATCH_MAX    45.0     // m: farther than this from every road = off road, no limit
#define OSP_LOOKAHEAD    700.0    // m: prefetch the cell this far ahead along the course
#define OSP_RETRY        20.0     // s before a failed cell is tried again
#define OSP_CACHE_DAYS   30       // cached cells older than this are downloaded again
#define OSP_GRID         20000.0  // spatial hash bins for road connectivity (1/20000° ≈ 5 m)

// One OSM way: tags we keep + geometry (meters are computed on the fly from lat/lon)
@interface OSPWay : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *highway;
@property (nonatomic) int limit;
@property (nonatomic) BOOL oneway;
@property (nonatomic, strong) NSArray<NSArray<NSNumber *> *> *points;   // @[@[lat, lon], ...]
@end
@implementation OSPWay
@end

@implementation OSPRoad
@end

// One way -> the compact form we cache (defined with the Overpass code below); the XML parser needs it first
static NSDictionary *OSPCompactWay(NSDictionary *tags, NSArray *pts);

// OSM API XML (nodes + ways with nd refs) -> compact, streamed through NSXMLParser
@interface OSPOsmXML : NSObject <NSXMLParserDelegate>
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSArray *> *nodes;   // id -> @[lat, lon]
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *ways;
@property (nonatomic, strong) NSMutableArray *refs;
@property (nonatomic, strong) NSMutableDictionary *tags;
@end

@implementation OSPOsmXML

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)name namespaceURI:(NSString *)ns qualifiedName:(NSString *)q attributes:(NSDictionary<NSString *, NSString *> *)a
{
    if ([name isEqualToString:@"node"]) {
        if (!self.nodes) self.nodes = [NSMutableDictionary dictionary];
        self.nodes[a[@"id"] ?: @""] = @[@(a[@"lat"].doubleValue), @(a[@"lon"].doubleValue)];
    } else if ([name isEqualToString:@"way"]) {
        self.refs = [NSMutableArray array]; self.tags = [NSMutableDictionary dictionary];
    } else if (self.refs && [name isEqualToString:@"nd"]) {
        NSArray *p = self.nodes[a[@"ref"] ?: @""];
        if (p) [self.refs addObject:p];
    } else if (self.refs && [name isEqualToString:@"tag"] && a[@"k"] && a[@"v"]) {
        self.tags[a[@"k"]] = a[@"v"];
    }
}

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)name namespaceURI:(NSString *)ns qualifiedName:(NSString *)q
{
    if (![name isEqualToString:@"way"] || !self.refs) return;
    if (!self.ways) self.ways = [NSMutableArray array];
    NSDictionary *w = OSPCompactWay(self.tags, self.refs);
    if (w) [self.ways addObject:w];
    self.refs = nil; self.tags = nil;
}

@end

@interface OSPRoadData ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSArray<OSPWay *> *> *cells;   // key -> ways
@property (nonatomic, strong) NSMutableSet<NSString *> *pending;                              // keys being downloaded
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDate *> *failedAt;            // key -> last failure
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic) BOOL haveCell;
@property (nonatomic, copy) NSString *lastError;
// Connectivity index: 5 m bin -> ways with a point in it (rebuilt when the set of cells changes)
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableSet<OSPWay *> *> *grid;
@property (nonatomic) NSUInteger gridCellCount;
@property (nonatomic, weak) OSPWay *lastWay;     // the way matched last time: keeps the match from flickering at junctions
@end

@implementation OSPRoadData

- (instancetype)init
{
    if (!(self = [super init])) return nil;
    _cells = [NSMutableDictionary dictionary];
    _pending = [NSMutableSet set];
    _failedAt = [NSMutableDictionary dictionary];
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest = 25;
    cfg.waitsForConnectivity = YES;
    _session = [NSURLSession sessionWithConfiguration:cfg];
    [[NSFileManager defaultManager] createDirectoryAtPath:@OSP_CACHE_DIR withIntermediateDirectories:YES attributes:nil error:nil];
    return self;
}

- (BOOL)loading { return self.pending.count > 0; }

#pragma mark - Cells

static NSString *OSPCellKey(double lat, double lon)
{
    return [NSString stringWithFormat:@"%ld_%ld", lround(floor(lat / OSP_CELL_DEG)), lround(floor(lon / OSP_CELL_DEG))];
}

static CLLocationCoordinate2D OSPCellCentre(NSString *key)
{
    NSArray *p = [key componentsSeparatedByString:@"_"];
    return CLLocationCoordinate2DMake(([p[0] doubleValue] + 0.5) * OSP_CELL_DEG, ([p[1] doubleValue] + 0.5) * OSP_CELL_DEG);
}

static NSString *OSPCellPath(NSString *key)
{
    return [NSString stringWithFormat:@"%s/%@.json", OSP_CACHE_DIR, key];
}

// Point OSP_LOOKAHEAD metres from `c` along `course` (degrees from north)
static CLLocationCoordinate2D OSPAhead(CLLocationCoordinate2D c, double course, double metres)
{
    double rad = course * M_PI / 180;
    double dLat = metres * cos(rad) / 111320.0;
    double dLon = metres * sin(rad) / (111320.0 * cos(c.latitude * M_PI / 180));
    return CLLocationCoordinate2DMake(c.latitude + dLat, c.longitude + dLon);
}

#pragma mark - maxspeed

// "60", "60 km/h", "50 mph", "VN:urban", "none", "walk" -> km/h, -1 if there is no usable value
static int OSPParseMaxspeed(NSString *v)
{
    if (![v isKindOfClass:[NSString class]] || !v.length) return -1;
    NSString *s = [[v lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    // "60; 80" / "60|80": first value
    NSRange sep = [s rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@";|"]];
    if (sep.location != NSNotFound) s = [s substringToIndex:sep.location];
    int n = 0;
    NSScanner *sc = [NSScanner scannerWithString:s];
    if ([sc scanInt:&n]) {
        if ([s containsString:@"mph"]) n = (int)lround(n * 1.609344);
        return (n > 0 && n <= 200) ? n : -1;
    }
    if ([s isEqualToString:@"none"] || [s isEqualToString:@"signals"] || [s isEqualToString:@"variable"]) return -1;
    if ([s isEqualToString:@"walk"]) return 5;
    // Implicit country defaults ("VN:urban"). Vietnam: 60 in town, 80 outside, 120 on expressways.
    BOOL vn = [s hasPrefix:@"vn:"];
    if ([s hasSuffix:@":urban"])     return vn ? 60 : 50;
    if ([s hasSuffix:@":rural"])     return vn ? 80 : 90;
    if ([s hasSuffix:@":motorway"])  return vn ? 120 : 130;
    if ([s hasSuffix:@":living_street"]) return 20;
    return -1;
}

static int OSPWayLimit(NSDictionary *tags)
{
    int n = OSPParseMaxspeed(tags[@"maxspeed"]);
    if (n < 0) n = OSPParseMaxspeed(tags[@"maxspeed:forward"]);
    if (n < 0) n = OSPParseMaxspeed(tags[@"maxspeed:backward"]);
    return n;
}

#pragma mark - Download

// Road-like highway values we keep (the Overpass query filters server side, the OSM API answer is filtered here)
#define OSP_HIGHWAYS "motorway|trunk|primary|secondary|tertiary|unclassified|residential|living_street|service|motorway_link|trunk_link|primary_link|secondary_link|tertiary_link"

static NSSet<NSString *> *OSPHighwaySet(void)
{
    static NSSet *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [NSSet setWithArray:[@OSP_HIGHWAYS componentsSeparatedByString:@"|"]]; });
    return s;
}

// Overpass QL: every road-like way within the radius, with its geometry
static NSString *OSPQuery(CLLocationCoordinate2D c)
{
    return [NSString stringWithFormat:
            @"[out:json][timeout:20];"
            @"way(around:%d,%.5f,%.5f)[\"highway\"~\"^(" OSP_HIGHWAYS ")$\"];"
            @"out tags geom;", OSP_FETCH_RADIUS, c.latitude, c.longitude];
}

// OSM API "map" call: bbox = the fetch radius around the cell centre (0.018° square, well under the 0.25 deg² cap)
static NSURL *OSPOsmApiURL(CLLocationCoordinate2D c)
{
    double dLat = OSP_FETCH_RADIUS / 111320.0, dLon = dLat / cos(c.latitude * M_PI / 180);
    return [NSURL URLWithString:[NSString stringWithFormat:@"%@?bbox=%.5f,%.5f,%.5f,%.5f", OSP_OVERPASS_SERVERS[OSP_SERVER_OSM_API],
                                 c.longitude - dLon, c.latitude - dLat, c.longitude + dLon, c.latitude + dLat]];
}

// One way -> the compact form we cache: {n, l, o, p:[[lat,lon],...]}; nil when it is not a road we keep
static NSDictionary *OSPCompactWay(NSDictionary *tags, NSArray *pts)
{
    if (pts.count < 2 || ![OSPHighwaySet() containsObject:tags[@"highway"] ?: @""]) return nil;
    NSString *name = tags[@"name"] ?: tags[@"ref"] ?: @"";
    NSString *ow = [tags[@"oneway"] isKindOfClass:[NSString class]] ? tags[@"oneway"] : @"";
    BOOL oneway = [ow isEqualToString:@"yes"] || [ow isEqualToString:@"1"] || [tags[@"junction"] isEqualToString:@"roundabout"]
                  || [tags[@"highway"] isEqualToString:@"motorway"];
    return @{@"n": name, @"h": tags[@"highway"] ?: @"", @"l": @(OSPWayLimit(tags)), @"o": @(oneway), @"p": pts};
}

// Overpass JSON -> compact
static NSArray<NSDictionary *> *OSPCompact(NSDictionary *json)
{
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *el in json[@"elements"]) {
        if (![el[@"type"] isEqualToString:@"way"]) continue;
        NSDictionary *tags = [el[@"tags"] isKindOfClass:[NSDictionary class]] ? el[@"tags"] : @{};
        NSMutableArray *pts = [NSMutableArray array];
        for (NSDictionary *g in el[@"geometry"]) {
            if (g[@"lat"] && g[@"lon"]) [pts addObject:@[g[@"lat"], g[@"lon"]]];
        }
        NSDictionary *w = OSPCompactWay(tags, pts);
        if (w) [out addObject:w];
    }
    return out;
}

static NSArray<NSDictionary *> *OSPCompactFromXML(NSData *xml)
{
    OSPOsmXML *d = [OSPOsmXML new];
    NSXMLParser *p = [[NSXMLParser alloc] initWithData:xml];
    p.delegate = d;
    return [p parse] ? (d.ways ?: @[]) : nil;
}

static NSArray<OSPWay *> *OSPWaysFromCompact(NSArray *arr)
{
    NSMutableArray *ways = [NSMutableArray array];
    for (NSDictionary *d in arr) {
        OSPWay *w = [OSPWay new];
        w.name = d[@"n"] ?: @""; w.highway = d[@"h"] ?: @""; w.limit = [d[@"l"] intValue]; w.oneway = [d[@"o"] boolValue]; w.points = d[@"p"];
        [ways addObject:w];
    }
    return ways;
}

- (NSArray<OSPWay *> *)cellForKey:(NSString *)key
{
    NSArray<OSPWay *> *ways = self.cells[key];
    if (ways) return ways;
    // Disk cache
    NSString *path = OSPCellPath(key);
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if (attrs && -[attrs.fileModificationDate timeIntervalSinceNow] < OSP_CACHE_DAYS * 86400.0) {
        NSData *data = [NSData dataWithContentsOfFile:path];
        NSArray *arr = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if ([arr isKindOfClass:[NSArray class]]) {
            ways = OSPWaysFromCompact(arr);
            self.cells[key] = ways;
            return ways;
        }
    }
    [self fetchCell:key];
    return nil;
}

- (void)fetchCell:(NSString *)key
{
    if ([self.pending containsObject:key]) return;
    NSDate *failed = self.failedAt[key];
    if (failed && -[failed timeIntervalSinceNow] < OSP_RETRY) return;
    [self.pending addObject:key];

    int idx = (self.server >= 0 && self.server < OSP_OVERPASS_COUNT) ? self.server : 0;
    [self requestCell:key server:idx];
}

// Overpass (POST query) or the OSM API (GET bbox). An Overpass failure retries once through the OSM API.
- (void)requestCell:(NSString *)key server:(int)idx
{
    CLLocationCoordinate2D c = OSPCellCentre(key);
    BOOL osmApi = (idx == OSP_SERVER_OSM_API);
    NSMutableURLRequest *req;
    if (osmApi) {
        req = [NSMutableURLRequest requestWithURL:OSPOsmApiURL(c)];
    } else {
        req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:OSP_OVERPASS_SERVERS[idx]]];
        req.HTTPMethod = @"POST";
        [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
        NSString *q = OSPQuery(c);
        NSCharacterSet *allowed = [NSCharacterSet alphanumericCharacterSet];
        req.HTTPBody = [[@"data=" stringByAppendingString:[q stringByAddingPercentEncodingWithAllowedCharacters:allowed]] dataUsingEncoding:NSUTF8StringEncoding];
    }
    [req setValue:@"OmniSpeed/" TWEAK_VERSION forHTTPHeaderField:@"User-Agent"];

    __weak typeof(self) weakSelf = self;
    [[self.session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        NSArray *compact = nil;
        if (!error && status == 200 && data) {
            if (osmApi) compact = OSPCompactFromXML(data);
            else {
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if ([json isKindOfClass:[NSDictionary class]]) compact = OSPCompact(json);
            }
        }
        NSData *store = compact ? [NSJSONSerialization dataWithJSONObject:compact options:0 error:nil] : nil;
        if (store) [store writeToFile:OSPCellPath(key) atomically:YES];
        NSString *failure = compact ? nil : (error ? error.localizedDescription : [NSString stringWithFormat:@"HTTP %ld", (long)status]);
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self) return;
            if (!compact && !osmApi) {
                // Overpass mirror down / blocked: the OSM API itself usually still answers
                NSLog(@"[OmniSpeed] cell %@: %@ (%@) -> OSM API", key, failure, OSP_OVERPASS_NAMES[idx]);
                [self requestCell:key server:OSP_SERVER_OSM_API];
                return;
            }
            [self.pending removeObject:key];
            if (compact) {
                self.cells[key] = OSPWaysFromCompact(compact);
                [self.failedAt removeObjectForKey:key];
                self.lastError = nil;
            } else {
                self.failedAt[key] = [NSDate date];
                self.lastError = failure;
                NSLog(@"[OmniSpeed] cell %@: %@", key, failure);
            }
            if (self.onChange) self.onChange();
        });
    }] resume];
}

#pragma mark - Matching

// Distance (m) from p to segment a-b, the segment's bearing and where on it p projects (t 0..1), flat projection
static double OSPSegmentDistance(CLLocationCoordinate2D p, CLLocationCoordinate2D a, CLLocationCoordinate2D b, double *bearing, double *outT)
{
    double kx = 111320.0 * cos(p.latitude * M_PI / 180), ky = 111320.0;
    double ax = (a.longitude - p.longitude) * kx, ay = (a.latitude - p.latitude) * ky;
    double bx = (b.longitude - p.longitude) * kx, by = (b.latitude - p.latitude) * ky;
    double dx = bx - ax, dy = by - ay;
    double len2 = dx * dx + dy * dy;
    double t = len2 > 0 ? MAX(0, MIN(1, -(ax * dx + ay * dy) / len2)) : 0;
    double cx = ax + t * dx, cy = ay + t * dy;
    if (bearing) *bearing = fmod(atan2(dx, dy) * 180 / M_PI + 360, 360);   // 0 = north, clockwise
    if (outT) *outT = t;
    return sqrt(cx * cx + cy * cy);
}

static inline double OSPTurn(double a, double b) { return fabs(fmod(a - b + 540, 360) - 180); }   // 0..180

// Matching: a side street crossing the main road scores worse (metres added), and the way we are already on
// keeps a head start, so the match does not jump to every alley at a junction.
#define OSP_STICKY 12.0
static double OSPClassPenalty(NSString *hw)
{
    if ([hw isEqualToString:@"service"]) return 20;
    if ([hw isEqualToString:@"living_street"]) return 14;
    if ([hw isEqualToString:@"residential"]) return 10;
    if ([hw isEqualToString:@"unclassified"]) return 6;
    if ([hw hasSuffix:@"_link"]) return 4;
    return 0;
}

// Legal default when the road carries no sign - Vietnam, built-up area (Thông tư 31/2019): dual carriageway or
// one-way with 2+ lanes 60, other roads 50; expressway 120; living street 20. Dual carriageways are mapped in OSM
// as two one-way ways, so "oneway" is the practical test. Service roads (car parks, alleys) get nothing.
static int OSPClassDefault(OSPWay *w)
{
    NSString *hw = w.highway;
    if ([hw hasPrefix:@"motorway"]) return 120;
    if ([hw isEqualToString:@"living_street"]) return 20;
    if ([hw isEqualToString:@"service"]) return -1;
    for (NSString *k in @[@"trunk", @"primary", @"secondary", @"tertiary"]) if ([hw hasPrefix:k]) return w.oneway ? 60 : 50;
    return 50;   // unclassified, residential
}

- (OSPRoad *)roadAt:(CLLocation *)fix
{
    if (!fix) return nil;
    CLLocationCoordinate2D c = fix.coordinate;
    NSString *key = OSPCellKey(c.latitude, c.longitude);
    NSArray<OSPWay *> *ways = [self cellForKey:key];
    self.haveCell = ways != nil;

    // Prefetch the cell ahead while moving (course is only valid above walking pace)
    if (fix.course >= 0 && fix.speed > 3) {
        CLLocationCoordinate2D ahead = OSPAhead(c, fix.course, OSP_LOOKAHEAD);
        NSString *aheadKey = OSPCellKey(ahead.latitude, ahead.longitude);
        if (![aheadKey isEqualToString:key]) [self cellForKey:aheadKey];
    }
    if (!ways) return nil;

    // Closest way; when we know our heading, a way running the other way is penalised so parallel roads and
    // junctions resolve to the one we are driving along.
    BOOL haveCourse = fix.course >= 0 && fix.speed > 3;
    OSPWay *best = nil; double bestScore = 1e9, bestDist = 0, bestT = 0, bestBearing = 0; NSUInteger bestSeg = 0;
    for (OSPWay *w in ways) {
        NSArray *pts = w.points;
        for (NSUInteger i = 0; i + 1 < pts.count; i++) {
            CLLocationCoordinate2D a = CLLocationCoordinate2DMake([pts[i][0] doubleValue], [pts[i][1] doubleValue]);
            CLLocationCoordinate2D b = CLLocationCoordinate2DMake([pts[i + 1][0] doubleValue], [pts[i + 1][1] doubleValue]);
            double bearing = 0, t = 0;
            double d = OSPSegmentDistance(c, a, b, &bearing, &t);
            if (d > OSP_MATCH_MAX) continue;
            double score = d + OSPClassPenalty(w.highway);
            if (haveCourse) {
                double diff = OSPTurn(fix.course, bearing);                         // 0..180
                if (!w.oneway && diff > 90) diff = 180 - diff;                      // two-way: either direction
                score += diff * 0.5;                                                // 90° off ~ 45 m farther
            }
            if (w == self.lastWay) score -= OSP_STICKY;
            if (score < bestScore) { bestScore = score; best = w; bestDist = d; bestSeg = i; bestT = t; bestBearing = bearing; }
        }
    }
    self.lastWay = best;
    if (!best) return nil;
    OSPRoad *r = [OSPRoad new];
    r.name = best.name; r.highway = best.highway; r.limit = best.limit; r.distance = bestDist;
    r.source = best.limit > 0 ? OSPLimitSign : OSPLimitNone;
    // Travelling along the way's point order? Unknown course: assume so (a one-way can only be driven that way).
    BOOL forward = haveCourse ? OSPTurn(fix.course, bestBearing) <= 90 : YES;
    if (best.limit <= 0) [self fillNearestLimit:r from:best seg:bestSeg t:bestT forward:forward];
    return r;
}

#pragma mark - Nearest sign along the road

#define OSP_WALK_MAX   3000.0   // m of road to follow from the car
#define OSP_MAX_TURN   70.0     // degrees: a bigger turn at a junction is a side street, not "the road"

static NSString *OSPGridKey(long la, long lo) { return [NSString stringWithFormat:@"%ld:%ld", la, lo]; }

// a, b: @[lat, lon]
static inline double OSPMetres(NSArray *a, NSArray *b)
{
    double lat0 = [a[0] doubleValue];
    return hypot(([b[0] doubleValue] - lat0) * 111320.0, ([b[1] doubleValue] - [a[1] doubleValue]) * 111320.0 * cos(lat0 * M_PI / 180));
}

static inline double OSPBearing(NSArray *a, NSArray *b)
{
    double dx = ([b[1] doubleValue] - [a[1] doubleValue]) * cos([a[0] doubleValue] * M_PI / 180), dy = [b[0] doubleValue] - [a[0] doubleValue];
    return fmod(atan2(dx, dy) * 180 / M_PI + 360, 360);
}

- (void)ensureIndex
{
    if (self.grid && self.gridCellCount == self.cells.count) return;
    self.gridCellCount = self.cells.count;
    NSMutableDictionary *g = [NSMutableDictionary dictionary];
    for (NSArray<OSPWay *> *ways in self.cells.allValues) for (OSPWay *w in ways) for (NSArray *p in w.points) {
        NSString *k = OSPGridKey(lround([p[0] doubleValue] * OSP_GRID), lround([p[1] doubleValue] * OSP_GRID));
        NSMutableSet *s = g[k];
        if (!s) g[k] = s = [NSMutableSet set];
        [s addObject:w];
    }
    self.grid = g;
}

// Ways with a point within one bin of p (@[lat, lon])
- (NSSet<OSPWay *> *)waysAt:(NSArray *)p
{
    NSMutableSet *out = [NSMutableSet set];
    long la = lround([p[0] doubleValue] * OSP_GRID), lo = lround([p[1] doubleValue] * OSP_GRID);
    for (int i = -1; i <= 1; i++) for (int j = -1; j <= 1; j++) {
        NSSet *s = self.grid[OSPGridKey(la + i, lo + j)];
        if (s) [out unionSet:s];
    }
    return out;
}

// Walk from the car along `from` (dir +1 = point order, -1 = reverse) to the end of the way, then continue along
// THE SAME ROAD only: a way with the same name, or an unnamed link in between - never a differently named road,
// so a side street's tag can never leak in. Among those the straightest (< OSP_MAX_TURN), never against a one-way.
// Stops at the first same-name way with a maxspeed (fills r, returns YES), after OSP_WALK_MAX metres, or when the
// road ends / changes name (NO). Walking back along a one-way is fine: we only read the map.
- (BOOL)walkRoad:(OSPWay *)from seg:(NSUInteger)seg t:(double)t dir:(int)dir into:(OSPRoad *)r
{
    [self ensureIndex];
    NSMutableSet *visited = [NSMutableSet setWithObject:from];
    NSString *roadName = from.name ?: @"";   // "" = we are on an unnamed link: follow unnamed ways only
    OSPWay *way = from; NSArray *pts = from.points; double total = 0;
    if (seg + 1 >= pts.count) return NO;
    NSInteger i = dir > 0 ? (NSInteger)seg + 1 : (NSInteger)seg;
    NSArray *carPt = @[@([pts[seg][0] doubleValue] + ([pts[seg + 1][0] doubleValue] - [pts[seg][0] doubleValue]) * t),
                       @([pts[seg][1] doubleValue] + ([pts[seg + 1][1] doubleValue] - [pts[seg][1] doubleValue]) * t)];
    total += OSPMetres(carPt, pts[i]);
    while (i + dir >= 0 && i + dir < (NSInteger)pts.count) { total += OSPMetres(pts[i], pts[i + dir]); i += dir; }
    NSArray *endPt = pts[i]; double inBearing = OSPBearing(pts[i - dir], pts[i]);
    for (int hops = 0; hops < 40 && total <= OSP_WALK_MAX; hops++) {
        OSPWay *bestW = nil; NSInteger bestK = 0; int bestD = 1; double bestScore = 1e9;
        for (OSPWay *cand in [self waysAt:endPt]) {
            if ([visited containsObject:cand]) continue;
            if (![cand.name isEqualToString:roadName] && cand.name.length) continue;   // another road: not ours
            NSInteger k = -1;
            for (NSUInteger q = 0; q < cand.points.count; q++) if (OSPMetres(cand.points[q], endPt) < 3) { k = (NSInteger)q; break; }
            if (k < 0) continue;
            for (int d = 1; d >= -1; d -= 2) {
                if (d < 0 && cand.oneway) continue;
                if (k + d < 0 || k + d >= (NSInteger)cand.points.count) continue;
                double turn = OSPTurn(inBearing, OSPBearing(cand.points[k], cand.points[k + d]));
                if (turn > OSP_MAX_TURN) continue;
                double score = [cand.name isEqualToString:roadName] ? turn - 1000 : turn;   // same name wins over an unnamed link, then straightest
                if (score < bestScore) { bestScore = score; bestW = cand; bestK = k; bestD = d; }
            }
        }
        if (!bestW) return NO;
        [visited addObject:bestW]; way = bestW; pts = bestW.points;
        if (bestW.limit > 0 && [bestW.name isEqualToString:roadName]) { r.limit = bestW.limit; r.inheritedDistance = total; return YES; }   // a link's own tag is not the road's
        NSInteger j = bestK;
        while (j + bestD >= 0 && j + bestD < (NSInteger)pts.count) { total += OSPMetres(pts[j], pts[j + bestD]); j += bestD; }
        endPt = pts[j]; inBearing = OSPBearing(pts[j - bestD], pts[j]);
    }
    return NO;
}

// The way has no maxspeed - the limit in force on this road:
//   1. the last sign passed on this road (walk back along the same road - what the law says applies)
//   2. a sign further ahead on the same road (OSM often tags only one segment of a street)
//   3. the legal default for the road class, if enabled in Settings
- (void)fillNearestLimit:(OSPRoad *)r from:(OSPWay *)from seg:(NSUInteger)seg t:(double)t forward:(BOOL)forward
{
    int dir = forward ? 1 : -1;
    if ([self walkRoad:from seg:seg t:t dir:-dir into:r]) { r.source = OSPLimitSignBehind; return; }
    if ([self walkRoad:from seg:seg t:t dir:dir into:r])  { r.source = OSPLimitSignAhead;  return; }
    if (!self.useClassDefaults) return;
    int d = OSPClassDefault(from);
    if (d > 0) { r.limit = d; r.source = OSPLimitClassDefault; }
}

- (void)clearCache
{
    [self.cells removeAllObjects];
    [self.failedAt removeAllObjects];
    self.grid = nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *f in [fm contentsOfDirectoryAtPath:@OSP_CACHE_DIR error:nil]) {
        [fm removeItemAtPath:[@OSP_CACHE_DIR stringByAppendingPathComponent:f] error:nil];
    }
}

@end
