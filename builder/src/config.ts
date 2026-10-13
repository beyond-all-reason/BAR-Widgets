import * as path from "node:path";
import { fileURLToPath } from "node:url";

export const BUILDER_DIR = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  ".."
);
export const ROOT_DIR = path.dirname(BUILDER_DIR);
export const BUILD_DIR = path.join(ROOT_DIR, "build");
export const WIDGETS_DIR = path.join(ROOT_DIR, "Widgets");
export const DIST_DIR = path.join(BUILD_DIR, "distributions");
export const SITES_DIR = path.join(BUILD_DIR, "sites");
export const MANIFEST_SCHEMA_PATH = path.join(
  BUILDER_DIR,
  "schemas",
  "manifests.schema.json"
);
const DEFAULT_MAX_WIDGET_SIZE_BYTES = 5 * 1024 * 1024; // 5 MiB
export const MAX_WIDGET_SIZE_BYTES = process.env["MAX_WIDGET_SIZE_BYTES"] !== undefined
  ? parseInt(process.env["MAX_WIDGET_SIZE_BYTES"], 10)
  : DEFAULT_MAX_WIDGET_SIZE_BYTES;
