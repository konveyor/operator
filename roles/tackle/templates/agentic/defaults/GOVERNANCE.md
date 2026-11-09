# Agentic Defaults Governance

These templates curate what ships on every MTA instance: the default agents,
the java-ee-to-quarkus AgentWorkflow, and the skillcards that select skills
from the skills image. They are orchestration - which capabilities ship and
how the workflow stages are wired - while the prompt content itself (the
`SKILL.md` files the skillcards select) is governed in
[konveyor/agentic-controller](https://github.com/konveyor/agentic-controller/blob/main/PROMPT_GOVERNANCE.md).

Changes here are treated as governed configuration, per ISO/IEC 42001
Control A.5.2:

- **Review** - this path is assigned to owners in
  [`.github/CODEOWNERS`](../../../../../.github/CODEOWNERS); changes need an
  approving review.
- **Validation** - the in-memory tests in `test/agentic/test_default_images.py`
  exercise the real Ansible defaults tasks against these templates; keep them
  green.

Considerations for any change:

- A new skillcard widens what the shipped agents can do - confirm the skill
  it selects is covered by the controller's governance.
- Turn limits and execution controls are CRD-level concerns that belong in
  these templates (see the comments in the agent templates); do not move them
  into skill content.
- The `konveyor.io/related-image` annotations drive the image pinning the
  midstream build rewrites - keep them accurate.
