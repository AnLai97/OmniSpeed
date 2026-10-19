// OmniSpeed contract - shared by the app (App/) and the settings page (omnispeedprefs/): pref keys and
// defaults, Darwin notification names, the Overpass servers and the cache folder. Only macros here.
//
// How it works:
//   OSPSpeedFeed       the app's own GPS (CoreLocation) -> current speed, course
//   OSPRoadData        OpenStreetMap through the Overpass API: the roads around the car (1 km cells, cached on
//                      disk), the one you are on (closest + same direction) and its "maxspeed" tag
//   OSPSpeedViewController   speed in big digits, the limit as a road sign, the road name; red + flashing frame
//                      over the limit
//   omnispeedprefs/    Settings > OmniSpeed (PreferenceLoader bundle)

#pragma once

#define OSP_PREFS_DOMAIN     "com.anlai.omnispeed"
// The app is sandbox-free (entitlements.plist) and reads the prefs file directly.
#define OSP_PREFS_PATH       "/var/mobile/Library/Preferences/com.anlai.omnispeed.plist"
// Downloaded road cells (<lat>_<lon>.json); Settings' "Clear map data" deletes it.
#define OSP_CACHE_DIR        "/var/mobile/Library/Caches/com.anlai.omnispeed"

// Pref keys (Root.plist) and defaults
#define OSP_KEY_ENABLED      @"enabled"       // BOOL, YES
#define OSP_KEY_LANGUAGE     @"language"      // "vi" / "en", unset = system language
#define OSP_KEY_SERVER       @"server"        // index into OSP_OVERPASS_SERVERS, 0
#define OSP_KEY_KEEP_AWAKE   @"keepAwake"     // BOOL, YES: screen never dims while the app is open
#define OSP_KEY_SHOW_LIMIT   @"showLimit"     // BOOL, YES: draw the limit sign
#define OSP_KEY_SHOW_ROAD    @"showRoad"      // BOOL, YES: road name under the speed
#define OSP_KEY_WARN         @"warnEnabled"   // BOOL, YES: red speed + flashing frame over the limit
#define OSP_KEY_WARN_OVER    @"warnOver"      // -10..10 km/h over the limit before warning, 5
#define OSP_KEY_CLASS_DEFAULTS @"classDefaults" // BOOL, YES: no sign on the road -> legal default for its class (VN urban)

// Map data servers. Order = index stored in OSP_KEY_SERVER: add new ones at the END.
// 0..2 are public Overpass mirrors (one small JSON query per cell). 3 is OpenStreetMap's own API "map" call
// (XML of everything in a bbox, ~1-3 MB per cell): heavier, but it is the authoritative server and it still
// answers when the Overpass mirrors are down or blocked - the app also falls back to it when an Overpass
// download fails.
#define OSP_OVERPASS_SERVERS (@[@"https://overpass-api.de/api/interpreter", \
                                @"https://overpass.kumi.systems/api/interpreter", \
                                @"https://maps.mail.ru/osm/tools/overpass/api/interpreter", \
                                @"https://api.openstreetmap.org/api/0.6/map"])
#define OSP_OVERPASS_NAMES   (@[@"overpass-api.de", @"overpass.kumi.systems", @"maps.mail.ru", @"api.openstreetmap.org"])
#define OSP_OVERPASS_COUNT   4
#define OSP_SERVER_OSM_API   3

// Settings -> app: a pref changed (posted by every stored cell of the settings bundle).
#define OSP_DARWIN_PREFS       "com.anlai.omnispeed/prefschanged"
// Settings -> app: the cache folder was deleted, drop what is in memory too.
#define OSP_DARWIN_CLEAR_CACHE "com.anlai.omnispeed/clearcache"
