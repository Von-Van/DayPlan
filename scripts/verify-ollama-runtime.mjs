import { createHash } from "node:crypto";
import { readFileSync, existsSync } from "node:fs";

const manifest = JSON.parse(
  readFileSync("src-tauri/resources/ollama/runtime-manifest.json", "utf8"),
);
if (manifest.version !== "0.32.0" || manifest.license !== "MIT") {
  throw new Error("Unexpected bundled Ollama manifest");
}
if (!existsSync("src-tauri/resources/ollama/LICENSE")) {
  throw new Error("Bundled Ollama license is missing");
}
const rust = readFileSync("src-tauri/src/runtime.rs", "utf8");
if (!rust.includes(`BUNDLED_OLLAMA_VERSION: &str = "${manifest.version}"`)) {
  throw new Error("Rust runtime version and artifact manifest differ");
}
for (const artifact of Object.values(manifest.artifacts)) {
  if (!/^[a-f0-9]{64}$/.test(artifact.sha256)) {
    throw new Error(`Invalid SHA-256 for ${artifact.name}`);
  }
}
console.log(
  `Ollama ${manifest.version} manifest verified (${createHash("sha256").update(JSON.stringify(manifest)).digest("hex").slice(0, 12)})`,
);
