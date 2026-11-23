// Sharper Satpane satellite imagery close up for React Native / Expo apps: the Satpane Android and iOS
// SDKs (AI super-resolution on the phone, ONNX Runtime) behind a small JS API and a hook.
//
//   const sharper = useSatpaneEnhance(satelliteShown ? { key: SATPANE_KEY } : null);
//   // a switch: <Switch value={sharper.state.enabled} onValueChange={sharper.setEnabled} /> when sharper.state.available
//   // the map: a raster source { tiles: [sharper.state.tileUrl], minzoom: 14, maxzoom: 15, tileSize: 512 } over the normal imagery
//   // the camera: sharper.onCamera([w, s, e, n], zoom, moving) on camera changes (moving=false when it stops)
import { useCallback, useEffect, useState } from "react";
import { requireOptionalNativeModule, type EventSubscription } from "expo-modules-core";

export interface Config {
  /** Your Satpane API key. Keys in apps can be copied out of them: give this one its own monthly limit in the dashboard. */
  key: string;
  /** Default https://api.satpane.com */
  api?: string;
  /** Default "true-color". */
  layer?: string;
  /** "latest" (default) or a mosaic like "2026-09". */
  period?: string;
  /** Default: "enhance-x4-int8" on Android (best on phone CPUs), "enhance-x4-coreml" on iOS (Core ML). */
  model?: string;
}

export interface State {
  /** Offer the switch: the key's plan includes enhancement and a model is published. */
  available: boolean;
  /** The user's choice (saved on the device). */
  enabled: boolean;
  /** file:// tile template for the enhanced layer (zoom 14-15), or null when off or not ready. It changes
   *  whenever new tiles are written, so the map redraws them. */
  tileUrl: string | null;
  /** Where the model runs ("xnnpack" or "cpu" on Android, "coreml" on iOS), once loaded. */
  backend: string | null;
  /** Slow on this phone: a good moment to suggest turning it off. */
  slow: boolean;
  /** Something to show under the switch, or null. */
  message: string | null;
}

type Native = {
  configure(config: Config): State;
  getState(): State | null;
  setEnabled(on: boolean): void;
  onCamera(west: number, south: number, east: number, north: number, zoom: number, moving: boolean): void;
  refresh(): void;
  clearCache(): void;
  addListener(event: "onState", cb: (s: State) => void): EventSubscription;
  addListener(event: "onSourceTiles", cb: (e: { count: number }) => void): EventSubscription;
};

const native = requireOptionalNativeModule<Native>("SatpaneEnhance");

/** False in builds without the native module (Expo Go, web, an app build from before it was added). */
export const isSupported = !!native;

const OFF: State = { available: false, enabled: false, tileUrl: null, backend: null, slow: false, message: null };

/** Starts (or reconfigures) the enhancer. Returns its current state. */
export function configure(config: Config): State {
  return (native && clean(native.configure(config))) || OFF;
}

export function getState(): State {
  return (native && clean(native.getState())) || OFF;
}

/** The user's choice: on or off (saved). */
export function setEnabled(on: boolean): void {
  native?.setEnabled(on);
}

/** The camera: bounds [west, south, east, north] and zoom. Call while moving and when it stops. */
export function onCamera(bounds: readonly [number, number, number, number], zoom: number, moving = false): void {
  native?.onCamera(bounds[0], bounds[1], bounds[2], bounds[3], zoom, moving);
}

/** Ask Satpane again whether the key may use the model (normally every few days on its own). */
export function refresh(): void {
  native?.refresh();
}

/** Delete enhanced tiles on the device (the model is kept). */
export function clearCache(): void {
  native?.clearCache();
}

export function addStateListener(cb: (s: State) => void): { remove(): void } {
  const sub = native?.addListener("onState", (s) => cb(clean(s)!));
  return { remove: () => sub?.remove() };
}

/** Zoom-13 tiles downloaded to feed the model (they count as Satpane tile requests). */
export function addSourceTilesListener(cb: (count: number) => void): { remove(): void } {
  const sub = native?.addListener("onSourceTiles", (e) => cb(e.count));
  return { remove: () => sub?.remove() };
}

/** The enhancer as React state. Pass null while satellite imagery isn't showing (nothing runs). */
export function useSatpaneEnhance(config: Config | null, opts?: { onSourceTiles?: (count: number) => void }) {
  const [state, setState] = useState<State>(OFF);
  const key = config ? [config.key, config.api, config.layer, config.period, config.model].join("|") : "";
  useEffect(() => {
    if (!native || !config) {
      setState(OFF);
      return;
    }
    const sub = addStateListener(setState);
    setState(configure(config));
    return () => sub.remove();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key]);
  const onTiles = opts?.onSourceTiles;
  useEffect(() => {
    if (!onTiles) return;
    const sub = addSourceTilesListener(onTiles);
    return () => sub.remove();
  }, [onTiles]);
  const onCam = useCallback((b: readonly [number, number, number, number], zoom: number, moving = false) => {
    if (config) onCamera(b, zoom, moving);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key]);
  return { supported: isSupported, state: config ? state : OFF, setEnabled, onCamera: onCam, refresh, clearCache };
}

function clean(s: State | null | undefined): State | null {
  if (!s) return null;
  return { available: !!s.available, enabled: !!s.enabled, tileUrl: s.tileUrl ?? null, backend: s.backend ?? null, slow: !!s.slow, message: s.message ?? null };
}
