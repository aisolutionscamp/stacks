// Builds the catalog records for aisolutionscamp.io from this repository.
//   node scripts/export.mjs <out-dir>
// Writes <out-dir>/<slug>.json per stack. Field names match the `stacks`
// table of the site; the site imports them with its sync script.
import fs from "node:fs";
import path from "node:path";

const REPO_URL = "https://github.com/aisolutionscamp/stacks";
const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const outDir = path.resolve(process.argv[2] || "export");
fs.mkdirSync(outDir, { recursive: true });

const read = (dir, file) => {
  const p = path.join(dir, file);
  return fs.existsSync(p) ? fs.readFileSync(p, "utf8").trimEnd() + "\n" : null;
};

for (const slug of fs.readdirSync(path.join(root, "stacks")).sort()) {
  const dir = path.join(root, "stacks", slug);
  if (!fs.existsSync(path.join(dir, "stack.json"))) continue;
  const meta = JSON.parse(fs.readFileSync(path.join(dir, "stack.json"), "utf8"));
  if (meta.slug !== slug) throw new Error(`${slug}: stack.json slug is "${meta.slug}"`);
  const record = {
    ...meta,
    sourceUrl: `${REPO_URL}/tree/main/stacks/${slug}`,
    documentation: read(dir, "README.md"),
    dockerCompose: read(dir, "compose.yaml"),
    helmChart: read(dir, "helm/install.sh"),
    helmValues: read(dir, "helm/values.yaml"),
    terraformConfig: read(dir, "terraform/local/main.tf"),
    terraformAws: read(dir, "terraform/aws/main.tf"),
    quickStart: read(dir, "quickstart/docker.md"),
    quickStartDocker: read(dir, "quickstart/docker.md"),
    quickStartHelm: read(dir, "quickstart/helm.md"),
    quickStartTerraform: read(dir, "quickstart/terraform.md"),
    quickStartTerraformAws: read(dir, "quickstart/terraform-aws.md"),
  };
  for (const key of ["dockerCompose", "helmChart", "terraformConfig", "terraformAws", "documentation"]) {
    if (!record[key]) throw new Error(`${slug}: missing ${key}`);
  }
  fs.writeFileSync(path.join(outDir, `${slug}.json`), JSON.stringify(record, null, 2) + "\n");
  console.log(`exported ${slug}`);
}
