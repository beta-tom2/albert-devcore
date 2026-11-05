# Reviewed cross-project knowledge

This directory is the **public, human-reviewed** library for generic DevCore knowledge. It intentionally starts with no claimed verified fixes. Entries are JSON files validated by the script 'scripts/ados-shared-knowledge.ps1'.

Entry categories: solution, anti-pattern, component, design, decision. Categories do not grant permission to import external source files or licenses.

A verified entry must have:

- schemaVersion: 1; a unique DC-KB-0001-style ID; status: verified; and a category.
- Clear title, problem, resolution, applicability, and doNotUseWhen.
- stacks and tags arrays, bounded to 20 strings each.
- lastVerified as YYYY-MM-DD and optional expiresOn for perishable recipes.
- At least one evidence reference with status passed and reviewable provenance. A text claim alone is not sufficient evidence.

**Privacy gate**: the public catalog must contain no secrets, private source code, private project names, identifying log data, personal information, company-confidential content, private CI links, or unlicensed assets. Automated regex checks are only a first filter; the reviewer owns the final decision.

No agent may promote or publish local candidates automatically. Begin with project-local .ai/local-output/knowledge-candidates/, review locally, and open a normal PR with sanitized, independently verified entries. A successful run in project A does not imply compatibility with project B: tests must run in B.

For the schema, workflow, and examples, read [CROSS_PROJECT_KNOWLEDGE.md](../../docs/CROSS_PROJECT_KNOWLEDGE.md).
