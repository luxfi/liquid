#!/usr/bin/env node
// Builds a chat-ready content index over docs/**/*.md(x).
// Output: build/search-index.json — chunked, tokenized, served as a static asset.
// Runtime chat widget queries Hanzo Zen with the matching chunks as context.

import { readFile, writeFile, mkdir, readdir } from "node:fs/promises";
import { existsSync } from "node:fs";
import path from "node:path";

const ROOT = path.resolve(process.cwd(), "docs");
const OUT_DIR = path.resolve(process.cwd(), "build");
const OUT_FILE = path.join(OUT_DIR, "search-index.json");
const MAX_CHUNK_CHARS = 1200;

function chunk(text) {
  const out = [];
  const paras = text.split(/\n{2,}/).map((p) => p.trim()).filter(Boolean);
  let buf = "";
  for (const p of paras) {
    if ((buf + "\n\n" + p).length > MAX_CHUNK_CHARS && buf) {
      out.push(buf);
      buf = p;
    } else {
      buf = buf ? buf + "\n\n" + p : p;
    }
  }
  if (buf) out.push(buf);
  return out;
}

function stripFrontmatter(src) {
  if (!src.startsWith("---")) return { meta: {}, body: src };
  const end = src.indexOf("\n---", 3);
  if (end < 0) return { meta: {}, body: src };
  const fm = src.slice(3, end).trim();
  const meta = Object.fromEntries(
    fm.split("\n").map((l) => {
      const i = l.indexOf(":");
      return i < 0 ? [l, ""] : [l.slice(0, i).trim(), l.slice(i + 1).trim().replace(/^["']|["']$/g, "")];
    }),
  );
  return { meta, body: src.slice(end + 4) };
}

async function* walk(dir) {
  const ents = await readdir(dir, { withFileTypes: true });
  for (const e of ents) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) yield* walk(p);
    else if (/\.mdx?$/.test(e.name)) yield p;
  }
}

async function main() {
  if (!existsSync(ROOT)) {
    console.warn(`[index] no docs/ dir at ${ROOT}; skipping`);
    return;
  }
  const docs = [];
  for await (const file of walk(ROOT)) {
    const src = await readFile(file, "utf8");
    const { meta, body } = stripFrontmatter(src);
    const rel = path.relative(ROOT, file).replace(/\\/g, "/");
    const url = "/" + rel.replace(/\.mdx?$/, "").replace(/\/index$/, "");
    const title = meta.title || meta.sidebar_label || path.basename(file, path.extname(file));
    for (const [i, c] of chunk(body).entries()) {
      docs.push({ id: `${rel}#${i}`, url, title, text: c });
    }
  }
  await mkdir(OUT_DIR, { recursive: true });
  await writeFile(OUT_FILE, JSON.stringify({ v: 1, count: docs.length, docs }));
  console.log(`[index] wrote ${docs.length} chunks → ${OUT_FILE}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
