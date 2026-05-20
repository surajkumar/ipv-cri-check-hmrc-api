// Read npm audit JSON, split vulnerabilities into four buckets, and emit:
//   - audit-summary.json (consumed by the PR + issue scripts)
//   - GITHUB_OUTPUT counters (consumed by step `if:` guards)
//
// Buckets:
//   safe              fixAvailable === true                       → `npm audit fix` handles it
//   forceNonBreaking  fixAvailable object, NOT semver-major       → targeted `npm install`
//   breaking          fixAvailable object, IS  semver-major       → targeted `npm install`, flagged
//   unfixable         fixAvailable === false                      → opens / updates a tracking issue
import fs from 'node:fs';

const audit = JSON.parse(fs.readFileSync('audit.json', 'utf8'));
const vulns = audit.vulnerabilities || {};

const advisoriesFor = (v) => (v.via || [])
  .filter(x => typeof x === 'object' && x !== null)
  .map(a => ({
    title: a.title,
    url: a.url,
    severity: a.severity,
    range: a.range,
    cvss: a.cvss?.score,
  }));

const summary = { safe: [], forceNonBreaking: [], breaking: [], unfixable: [] };

for (const [name, v] of Object.entries(vulns)) {
  const fa = v.fixAvailable;
  const base = { name, severity: v.severity, range: v.range };

  if (fa === false) {
    summary.unfixable.push({ ...base, advisories: advisoriesFor(v) });
  } else if (fa === true) {
    summary.safe.push(base);
  } else if (fa && typeof fa === 'object') {
    const entry = { ...base, target: `${fa.name}@${fa.version}`, isSemVerMajor: !!fa.isSemVerMajor };
    (fa.isSemVerMajor ? summary.breaking : summary.forceNonBreaking).push(entry);
  }
}

fs.writeFileSync('audit-summary.json', JSON.stringify(summary, null, 2));
console.log(JSON.stringify(summary, null, 2));

const out = process.env.GITHUB_OUTPUT;
if (out) {
  fs.appendFileSync(out, [
    `safe_count=${summary.safe.length}`,
    `force_count=${summary.forceNonBreaking.length}`,
    `breaking_count=${summary.breaking.length}`,
    `unfixable_count=${summary.unfixable.length}`,
    '',
  ].join('\n'));
}
