// Copies the native SDKs' sources (../android, ../ios) into this package, so apps get them with npm and
// need no extra Maven or Swift package setup. Runs before packing; the copies aren't committed.
import { cpSync, mkdirSync, readdirSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(dirname(fileURLToPath(import.meta.url)));
const repo = dirname(here);

const kt = join(here, "android/src/main/java/com/satpane/enhance");
rmSync(kt, { recursive: true, force: true });
mkdirSync(kt, { recursive: true });
const ktSrc = join(repo, "android/enhance/src/main/java/com/satpane/enhance");
for (const f of readdirSync(ktSrc)) cpSync(join(ktSrc, f), join(kt, f));

const sw = join(here, "ios/sdk");
rmSync(sw, { recursive: true, force: true });
mkdirSync(sw, { recursive: true });
for (const d of ["SatpaneEnhancePlan", "SatpaneEnhance"]) {
  const src = join(repo, "ios/Sources", d);
  for (const f of readdirSync(src)) cpSync(join(src, f), join(sw, f));
}
console.log("synced the Android and iOS SDK sources");
