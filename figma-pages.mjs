import fs from "node:fs/promises";

const FIGMA_TOKEN = process.env.FIGMA_TOKEN;
const PROJECT_ID = process.argv[2];

if (!FIGMA_TOKEN) {
  console.error("Missing FIGMA_TOKEN in environment.");
  process.exit(1);
}

if (!PROJECT_ID) {
  console.error("Usage: node figma-pages.mjs <projectId>");
  process.exit(1);
}

const API_BASE = "https://api.figma.com/v1";

async function figmaGet(path) {
  const res = await fetch(`${API_BASE}${path}`, {
    headers: {
      "X-Figma-Token": FIGMA_TOKEN,
    },
  });

  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Figma API ${res.status} on ${path}\n${body}`);
  }

  return res.json();
}

function slugify(name) {
  return String(name || "untitled")
    .trim()
    .replace(/\s+/g, "-")
    .replace(/[^\w\-]+/g, "");
}

function nodeIdForUrl(id) {
  // Figma API uses colon IDs like 1:3, browser URLs use 1-3
  return String(id).replace(/:/g, "-");
}

function fileRouteFromEditorType(editorType) {
  // This mapping follows current Figma URL patterns.
  // If your workspace uses a different route, change this function.
  switch (editorType) {
    case "figjam":
      return "board";
    case "slides":
      return "slides";
    case "buzz":
      return "buzz";
    case "figma":
    case "dev":
    default:
      return "design";
  }
}

function buildPageUrl({ fileKey, fileName, pageId, editorType }) {
  const route = fileRouteFromEditorType(editorType);
  return `https://www.figma.com/${route}/${fileKey}/${slugify(fileName)}?node-id=${encodeURIComponent(nodeIdForUrl(pageId))}`;
}

async function main() {
  const projectFiles = await figmaGet(`/projects/${PROJECT_ID}/files`);
  const files = Array.isArray(projectFiles.files) ? projectFiles.files : [];

  const results = [];

  for (const file of files) {
    const fileKey = file.key;
    if (!fileKey) continue;

    // depth=1 returns only pages
    const fileData = await figmaGet(`/files/${fileKey}?depth=1`);
    const fileName = fileData.name || file.name || "Untitled";
    const editorType = fileData.editorType || "figma";

    const pages = Array.isArray(fileData?.document?.children)
      ? fileData.document.children.filter((node) => node?.type === "PAGE")
      : [];

    for (const page of pages) {
      results.push({
        fileName,
        fileKey,
        editorType,
        pageName: page.name,
        pageId: page.id,
        pageUrl: buildPageUrl({
          fileKey,
          fileName,
          pageId: page.id,
          editorType,
        }),
      });
    }
  }

  await fs.writeFile("figma-pages.json", JSON.stringify(results, null, 2), "utf8");

  console.log(`Wrote ${results.length} page URLs to figma-pages.json`);
  for (const row of results) {
    console.log(`${row.fileName} -> ${row.pageName}`);
    console.log(`  ${row.pageUrl}`);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});