import { createHash, type Hash } from "node:crypto";
import * as fs from "node:fs";
import * as path from "node:path";

const HASH_FORMAT = "bar-widget-content-v1";

export function calculateWidgetContentHash(widgetDir: string): string {
  const files = collectFiles(widgetDir);
  const hash = createHash("sha512");
  writeField(hash, Buffer.from(HASH_FORMAT, "utf8"));

  for (const file of files) {
    const relativePath = toCanonicalPath(path.relative(widgetDir, file));
    const contents = fs.readFileSync(file);
    writeField(hash, Buffer.from(relativePath, "utf8"));
    writeField(hash, contents);
  }

  return `sha512:${hash.digest("hex")}`;
}

function collectFiles(rootDir: string): string[] {
  const files: { absolutePath: string; canonicalPath: string }[] = [];
  const canonicalPaths = new Map<string, string>();

  function visit(dir: string): void {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const absolutePath = path.join(dir, entry.name);
      const relativePath = path.relative(rootDir, absolutePath);
      const canonicalPath = toCanonicalPath(relativePath);
      const collisionKey = canonicalPath.toLowerCase();
      const existingPath = canonicalPaths.get(collisionKey);
      if (existingPath) {
        throw new Error(
          `Ambiguous widget paths '${existingPath}' and '${relativePath}'`
        );
      }
      canonicalPaths.set(collisionKey, relativePath);

      if (entry.isSymbolicLink()) {
        throw new Error(`Symbolic links are not supported: ${relativePath}`);
      }
      if (entry.isDirectory()) {
        visit(absolutePath);
        continue;
      }
      if (!entry.isFile()) {
        throw new Error(`Unsupported filesystem entry: ${relativePath}`);
      }

      files.push({ absolutePath, canonicalPath });
    }
  }

  visit(rootDir);
  files.sort((left, right) =>
    Buffer.from(left.canonicalPath).compare(Buffer.from(right.canonicalPath))
  );
  return files.map((file) => file.absolutePath);
}

function toCanonicalPath(relativePath: string): string {
  return relativePath.split(path.sep).join("/").normalize("NFC");
}

function writeField(hash: Hash, value: Buffer): void {
  const length = Buffer.allocUnsafe(4);
  length.writeUInt32LE(value.length);
  hash.update(length);
  hash.update(value);
}
