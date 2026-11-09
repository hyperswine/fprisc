'use strict';
// The compiler owns diagnostics/types and the list of consumed sources. Refuse
// stale/unknown reports; never infer types from editor heuristics.
const path = require('path');
function digest(text) {
  let h = 14695981039346656037n;
  for (const b of Buffer.from(text, 'utf8')) h = BigInt.asUintN(64, (h ^ BigInt(b)) * 1099511628211n);
  return h.toString(16).padStart(16, '0');
}
function readReport(output, { readText, readOpen, failed }) {
  const lines = output.split(/\r?\n/).filter(l => l.startsWith('{') && l.includes('"editorVersion"'));
  if (!lines.length) return null;
  let report;
  try { report = JSON.parse(lines[lines.length - 1]); } catch (_) { throw new Error('Malformed compiler editor report'); }
  if (![1, 2].includes(report.editorVersion) || report.positionEncoding !== 'utf-32' || report.algorithm !== 'fnv1a-64-utf8' ||
      typeof report.ok !== 'boolean' || report.ok === failed || !Array.isArray(report.inputs) ||
      !Array.isArray(report.diagnostics) || !Array.isArray(report.types)) throw new Error('Unsupported or inconsistent compiler editor report');
  // Version 1 compilers still provide ordinary type hovers. Unknown resource
  // schemas are ignored without discarding valid diagnostics/types.
  const resourcesSupported = report.editorVersion === 2 && report.resourceVersion === 1 && report.resourceModel === 'native-source-v1';
  if (resourcesSupported && (!Array.isArray(report.resources) || !['complete', 'budget-limited', 'not-requested', 'check-failed'].includes(report.resourceStatus)))
    throw new Error('Invalid compiler resource report');
  report.resources = resourcesSupported ? report.resources : [];
  const texts = new Map();
  for (const input of report.inputs) {
    if (typeof input.file !== 'string' || !path.isAbsolute(input.file) || !/^[a-f0-9]{16}$/.test(input.digest)) throw new Error('Invalid compiler source metadata');
    const text = readText(input.file), open = readOpen(input.file);
    // Native source decoding strips a UTF-8 BOM before parsing.
    if (typeof text !== 'string' || (digest(text) !== input.digest && digest(text.replace(/^\uFEFF/, '')) !== input.digest) || (open != null && open !== text)) return { stale: true };
    texts.set(input.file, text);
  }
  for (const d of [...report.diagnostics, ...report.types, ...report.resources]) {
    if (typeof d.file !== 'string' || !path.isAbsolute(d.file) || !d.start || !Number.isSafeInteger(d.start.line) || d.start.line < 0 ||
        !Number.isSafeInteger(d.start.character) || d.start.character < 0) throw new Error('Invalid compiler source position');
  }
  if (report.diagnostics.some(d => typeof d.message !== 'string' || ![1, 2, 3].includes(d.severity)) ||
      report.types.some(t => typeof t.name !== 'string' || typeof t.type !== 'string' || !texts.has(t.file)) ||
      (!report.ok && report.types.length)) throw new Error('Invalid compiler diagnostics or types');
  if ((!report.ok || report.resourceStatus !== 'complete') && report.resources.length)
    throw new Error('Unexpected resource evidence');
  for (const r of report.resources) {
    if (!texts.has(r.file) || typeof r.name !== 'string' || typeof r.declaration !== 'string' || !validSummary(r.summary))
      throw new Error('Invalid compiler resource summary');
  }
  return { report, texts };
}
function validSummary(s) {
  const bound = (b, unit) => b && b.unit === unit && ['proved', 'unknown'].includes(b.status) &&
    typeof b.display === 'string' && Array.isArray(b.unknowns) && b.unknowns.every(x => typeof x === 'string') && b.expression && typeof b.expression.op === 'string';
  const equation = e => e && bound(e.work, 'abstract-operations') && bound(e.allocation, 'requested-cell-bytes');
  return s && s.scope === 'native-source' && s.provenance === 'checked-source-cost-equations' &&
    Array.isArray(s.parameters) && s.parameters.every(x => typeof x === 'string') &&
    Array.isArray(s.domains) && s.domains.every(x => typeof x === 'string') &&
    equation(s.inferred) && equation(s.effective) && s.declared &&
    (!s.declared.work || bound(s.declared.work, 'abstract-operations')) &&
    (!s.declared.allocation || bound(s.declared.allocation, 'requested-cell-bytes'));
}
module.exports = { digest, readReport };
