// Build script — uses Bun's JS API with Solid JSX transform via babel-preset-solid

import { transformSync } from "@babel/core";
import solidPreset from "babel-preset-solid";
import { readFileSync } from "fs";
import { resolve, extname } from "path";

const solidPlugin: import("bun").BunPlugin = {
  name: "solid-jsx",
  setup(build) {
    build.onLoad({ filter: /\.tsx$/ }, (args) => {
      const source = readFileSync(args.path, "utf-8");
      const result = transformSync(source, {
        filename: args.path,
        presets: [[solidPreset, { generate: "dom" }]],
        plugins: [["@babel/plugin-transform-typescript", { isTSX: true, allowDeclareFields: true }]],
      });
      return { contents: result!.code!, loader: "js" };
    });
  },
};

const result = await Bun.build({
  entrypoints: ["src/main.tsx"],
  outdir: "../public",
  minify: true,
  sourcemap: "external",
  naming: "[name].js",
  plugins: [solidPlugin],
});

if (!result.success) {
  for (const log of result.logs) console.error(log);
  process.exit(1);
}
console.log(`Built ${result.outputs.length} files`);
