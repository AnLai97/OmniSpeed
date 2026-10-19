# OmniSpeed

iPhone speed display for the dashboard: your GPS speed in big digits, the speed limit of the road you
are on as a road sign, and the road's name. Limits come from OpenStreetMap (the road's `maxspeed`
tag), so no navigation app is involved. Rootless jailbreak (Dopamine, palera1n), iOS 15+.

## How it works

```
            OmniSpeed.app                                          Settings > OmniSpeed
 ┌────────────────────────────────────────────────────┐    ┌──────────────────────────┐
 │ OSPSpeedFeed      CoreLocation -> speed, course     │    │ omnispeedprefs/          │
 │ OSPRoadData       Overpass API -> roads in 1 km     │ ◀──│  enable, display,        │
 │                   cells, cached 30 days on disk;    │    │  warning, Overpass       │
 │                   closest way in our direction      │    │  server, clear cache     │
 │                   -> name + maxspeed                │    │  (prefs file + Darwin)   │
 │ OSPSpeedViewController   digits, sign, road, warn   │    └──────────────────────────┘
 └────────────────────────────────────────────────────┘
```

`App/OmniSpeed.h` is the contract the app and the settings page share: pref keys and defaults,
Darwin notification names, the Overpass servers and the cache folder.

### Road matching (OSPRoadData)

- The world is split into 0.01° cells (~1.1 km). For the cell under the car (and the one ~700 m ahead
  along the course) one Overpass query fetches every road-like way within 1 km of the cell centre,
  with geometry; the result is reduced to `{name, limit, oneway, points}` and written to
  `/var/mobile/Library/Caches/com.anlai.omnispeed/<cell>.json`.
- The road you are on = the way with the smallest `distance + 0.5 × heading difference` (two-way
  roads accept either direction); farther than 45 m from every way = off road.
- `maxspeed` parsing: numbers (km/h, `mph` converted), `VN:urban` 60 / `VN:rural` 80 /
  `VN:motorway` 120 (other countries 50 / 90 / 130), `none` = no limit, `maxspeed:forward/backward`
  as fallbacks.

## Layout

| Path | What |
|------|------|
| `App/` | the OmniSpeed app (`/Applications/OmniSpeed.app`, `omnispeed://` URL scheme) |
| `omnispeedprefs/` | HarmonyOS-style settings page (PreferenceLoader bundle, vi/en) |
| `control` | Sileo listing; `Version:` is read by the Makefiles |
| `.github/workflows/build.yml` | the only compiler: builds `out/OmniSpeed_<version>_rootless.deb` |

## Build

No local Theos on Windows: push and let GitHub Actions build. A `v<version>` tag publishes a release
with the .deb attached. Install, grant OmniSpeed location access on first launch; the first drive on a
road needs internet to download it.

## Settings and icons

Settings rows live in `omnispeedprefs/Resources/Root.plist` (labels are keys into the `.lproj` files).
The icons (`icon*.png`, `logo*.png`, `PackageIcon.png`, `App/Resources/AppIcon60x60@*.png`,
`assets/icon-1024.png`) come from the `ios-tweak-format` skill's `harmony_icon.py`; the glyph file is
not kept in the repo.
