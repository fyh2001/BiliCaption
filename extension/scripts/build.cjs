"use strict";

const fs = require("node:fs");
const path = require("node:path");

function argument(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

const sourceDirectory = path.resolve(__dirname, "..");
const outputDirectory = path.resolve(argument("--out") || path.join(sourceDirectory, "dist"));
const token = argument("--token") || process.env.BILI_CAPTION_BRIDGE_TOKEN || "";

if (!/^[a-f0-9]{64}$/.test(token)) {
  throw new Error("A 64-character lowercase hexadecimal --token is required");
}

fs.mkdirSync(outputDirectory, {recursive: true});

const bundles = [
  ["page-bundle.js", ["core.js", "page-hook.js"]],
  ["content-bundle.js", ["core.js", "content.js"]]
];

for (const [output, inputs] of bundles) {
  const contents = inputs
    .map(file => fs.readFileSync(path.join(sourceDirectory, file), "utf8"))
    .join("\n");
  fs.writeFileSync(path.join(outputDirectory, output), contents, "utf8");
}

for (const file of ["manifest.json", "popup.css", "popup.html", "popup.js", "core.js", "content.js", "page-actions.js", "page-hook.js"]) {
  fs.copyFileSync(path.join(sourceDirectory, file), path.join(outputDirectory, file));
}

const backgroundSource = fs.readFileSync(path.join(sourceDirectory, "background.js"), "utf8");
if (!backgroundSource.includes("__BILI_CAPTION_BRIDGE_TOKEN__")) {
  throw new Error("background.js is missing its bridge token placeholder");
}
fs.writeFileSync(
  path.join(outputDirectory, "background.js"),
  backgroundSource.replace("__BILI_CAPTION_BRIDGE_TOKEN__", token),
  "utf8"
);

console.log(outputDirectory);
