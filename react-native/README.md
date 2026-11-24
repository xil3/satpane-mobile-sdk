# @satpane/enhance-native

Sharper [Satpane](https://satpane.com) satellite imagery close up in React Native / Expo apps: a small
AI super-resolution model redraws zoom 14-15 tiles at 4x the detail, on the phone (Android: ONNX
Runtime on the CPU; iOS: Core ML). Off until the user turns it on; the model is downloaded with your
Satpane key when the key's plan includes it.

> The extra detail is **AI-generated**: a plausible reconstruction, not new survey data. Say so on your map.

```sh
npx expo install @satpane/enhance-native
```

It has native code, so it needs a development build (`npx expo run:android` / `run:ios`, EAS or
BuildBakery), not Expo Go. In Expo Go `isSupported` is false and the hook stays off.

```tsx
import { useSatpaneEnhance } from "@satpane/enhance-native";

const sharper = useSatpaneEnhance(satelliteShown ? { key: SATPANE_KEY } : null);

// A switch, when sharper.state.available:
<Switch value={sharper.state.enabled} onValueChange={sharper.setEnabled} />

// The map (MapLibre React Native): a raster source above your normal Satpane layer
{sharper.state.tileUrl && (
  <RasterSource id="sharper" tileUrlTemplates={[sharper.state.tileUrl]} tileSize={512} minZoomLevel={14} maxZoomLevel={15}>
    <RasterLayer id="sharper" />
  </RasterSource>
)}

// On camera changes: sharper.onCamera([west, south, east, north], zoom, moving)
```

`state`: `available` (offer the switch), `enabled` (the saved choice), `tileUrl` (a `file://` template;
it changes when new tiles are written so the map redraws), `slow`, `message`, `backend`, and on Android
`failure`: set (with `available` false) when the model crashed the app on this phone even after a retry
without XNNPACK, so it turned itself off rather than crash again at every launch.

Docs: https://satpane.com/docs#enhance-react-native · Source: https://github.com/xil3/satpane-mobile-sdk
(this package bundles the Android and iOS SDKs' sources). MIT.
