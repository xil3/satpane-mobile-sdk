# Satpane mobile SDKs

Sharper [Satpane](https://satpane.com) satellite imagery close up, made on the phone. Past zoom 13, where
10 m Sentinel-2 pixels start to blur, a small AI super-resolution model redraws each tile at 4x the
detail. Each area is enhanced once and kept on the device.

| | Package | Runs the model with |
|---|---|---|
| Android (Kotlin) | `com.satpane:enhance` from `https://satpane.com/maven` | ONNX Runtime (CPU, XNNPACK) |
| iOS (Swift) | Swift package `https://github.com/xil3/satpane-mobile-sdk` | Core ML (part of iOS; no other dependencies) |
| React Native / Expo | `@satpane/enhance-native` on npm | both of the above |
| Web | [`@satpane/enhance`](https://www.npmjs.com/package/@satpane/enhance) on npm | ONNX Runtime Web (WebGPU / WASM) |

> The extra detail is **AI-generated**: a plausible reconstruction, not new survey data. Don't use it
> for measurements, and say so on your map.

It's **off until the user turns it on** (the choice is saved): on older phones it can be slow and use
battery. The model (about 1.3 MB on Android, 2.4 MB on iOS) is downloaded with your Satpane key, once per
version, and only when the key's plan includes enhancement.

Full docs with examples: https://satpane.com/docs#enhance

## How it works

You give the SDK your key and the camera (bounds and zoom). When it's on, it:

1. checks with Satpane that the key may use the model (every few days; a recent "yes" holds offline),
   and downloads the model for that version;
2. works out what to enhance: the zoom-14 areas on screen first, then a ring around them for panning,
   and, while the user is zooming in past 12.5, the middle of the view ahead of time;
3. fetches the zoom-13 tile and its 8 neighbours (the border pixels stop seams), runs the model on a
   quarter of the tile (288 px in, 1152 px out), and writes the zoom-14 tile and its four zoom-15 tiles;
4. gives you a `file://…/{z}/{x}/{y}.tile` template to show as a raster source (512 px tiles, zoom
   14-15) above your normal Satpane layer. Tiles not made yet are simply missing, so the normal imagery
   shows through. The template changes whenever new tiles land, so the map redraws them.

Enhanced tiles are kept up to 300 MB (oldest removed first). If the key's plan stops including
enhancement, the model and tiles are deleted.

## Android

```kotlin
// settings.gradle.kts: maven("https://satpane.com/maven")
// app/build.gradle.kts: implementation("com.satpane:enhance:0.1.1")

val sharper = SatpaneEnhancer(context, SatpaneEnhancer.Config(key = "YOUR_KEY"))
sharper.addListener { state -> /* state.available, state.enabled, state.tileUrl, state.slow, state.message, state.failure */ }
sharper.setEnabled(true)                                  // from your switch
sharper.onCamera(west, south, east, north, zoom, moving)  // on camera changes
```

## iOS

```swift
import SatpaneEnhance

let sharper = SatpaneEnhancer(config: .init(key: "YOUR_KEY"))
sharper.addListener { state in /* state.available, state.enabled, state.tileURL, ... */ }
sharper.setEnabled(true)
sharper.onCamera(west: w, south: s, east: e, north: n, zoom: zoom, moving: moving)
```

## React Native / Expo

```tsx
import { useSatpaneEnhance } from "@satpane/enhance-native";

const sharper = useSatpaneEnhance(satelliteShown ? { key: "YOUR_KEY" } : null);
// sharper.state, sharper.setEnabled(on), sharper.onCamera([w, s, e, n], zoom, moving)
```

Needs a development build (it has native code), not Expo Go.

## Layout

- `android/`: the Android library (`android/enhance`), Gradle
- `Package.swift`, `ios/`: the iOS Swift package
- `react-native/`: the React Native / Expo module (copies the two SDKs' sources in when packed)
- `bakery.yaml`: builds and tests on [BuildBakery](https://buildbakery.com)

## Licence

MIT (this code). The model is downloaded from Satpane and is for use with Satpane tiles under the
[Satpane Terms](https://satpane.com/terms).
