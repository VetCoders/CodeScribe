# COMPILE_EMBARGO_CODING

Status: canonical execution protocol
Revision: 2026-09-09
Scope: architecture-sensitive implementation by one agent or a Fleet Worktree
formation

## 1. Definition

`COMPILE_EMBARGO_CODING` is a phase-separated implementation technique in
which source structure and its executable contracts are assembled before the
compiler, linter, test runner or live runtime is allowed to influence the
shape.

The technique does **not** claim that compilation is unimportant. It preserves
compilation as an independent falsifier. A green build is valuable after the
architecture has a declared shape; while the shape is still being discovered,
green can become a local optimization target that rewards adapters, duplicate
truth, compatibility scar tissue and accidental ownership.

The short law is:

> Shape first. Close it structurally. Then let compilation falsify it.

Embargo is therefore a sequencing protocol, not a relaxed quality standard.
No phase may borrow the verdict of a later instrument, and no later green gate
may retroactively disguise an earlier structural failure.

## 2. Why a gate is deferred, and when it returns

An embargo follows from the stage of the work and its dependencies, not from
who approved it. A gate is deferred only when its result is predictably
useless because it checks exactly the fragment being dismantled. Every other
check keeps running.

Each deferral carries three things:

1. the exact command or hook id that is deferred;
2. the reason its verdict would be noise at this stage ("refactor in
   progress" is not a reason; name what is missing for the check to be
   meaningful);
3. the condition under which it returns.

A gate returns the moment its reason disappears, not at a ceremonial phase
close. An embargo is never extended because a returning gate exposed a defect;
the defect is repaired. Before a release there are no deferrals: every required
gate and the real product path run on the generation being released.

## 3. What is embargoed

From W1 opening until an explicit W2 structural-close attestation, workers do
not run any command whose result can steer implementation through
executability:

- compiler, build or package build;
- typechecker;
- project import or dependency-resolution smoke;
- linter or formatter when it parses or rewrites project semantics;
- unit, integration, snapshot, UI or end-to-end tests;
- application, service, model or live-runtime probe;
- dependency installation performed to make one of the above possible.

The plan must name exact forbidden commands for the repository. Examples alone
are not a contract. A worker does not choose its own gate subset: partial
gates pull the worker into repairing local greenness instead of finishing the
cut, which is the tunnel the embargo exists to prevent.

The embargo does not forbid evidence. It permits preregistered structural
checks that do not execute or import the product, such as:

- Loctree structure, slice, impact, references and occurrence evidence;
- literal contract and absence checks with bounded text search;
- definition/reference, owner/consumer and residue censuses;
- review of source, schemas, routes, manifests and generated contracts;
- `git diff --check` and scoped diff inspection;
- secret detection and merge-conflict/line-ending hygiene;
- scoped static security scans that do not build or import the product;
- a neutral syntax parser only when the plan explicitly admits it as a
  structural instrument.

Tests are authored during W1/W2 because they state the intended contract. They
remain unrun until the embargo closes.

## 4. Roles and truth ownership

For a multi-agent execution there is one Agent-Operator acting as integrator.
Workers own isolated structural atoms; they do not own admission into the
destination tree.

- Founder: chooses the mission, accepts product/architecture decisions and owns
  trunk, publication, deploy and other explicitly reserved buttons.
- Agent-Operator/integrator: owns the plan, phase state, recovery channel,
  dispatch ledger, admission, structural-close attestation, the first compile
  and the moment every deferred gate returns.
- Worker: owns one closed file/symbol domain, its unrun contract tests, one
  durable checkpoint commit and one honest report of unknowns.
- Compiler/test/runtime: independent falsifiers used only in their declared
  phases. They are not architecture authors.

Shared truth must have one writer: one plan, one tracker/journal, one embargo
state and one integrator. Per-provider copies must not redefine phase or
completion semantics.

### 4.1 Three levels of truth

The protocol keeps three verdicts apart. Conflating any two of them is the
failure the embargo is designed against.

| Level                  | Who                     | What it proves                                                                                                  |
| ---------------------- | ----------------------- | --------------------------------------------------------------------------------------------------------------- |
| Checkpoint             | worker                  | the work and its exact SHA are preserved; nothing about quality                                                 |
| Structural integration | integrator              | scope, ownership, contracts between cuts, security scan and review are reconciled; deferred gates still pending |
| Verified delivery      | integrator, after close | every required gate and the real product path passed on the named generation                                    |

## 5. Enforcement grades

Every execution declares one of these grades before W1:

### A. Repository-enforced

The repository contains and consumes a tracked phase guard. A local marker may
open W1/W2 and defer only explicitly allowlisted gates. Non-deferred security,
provenance and hygiene checks continue to run. Malformed state fails closed.

The reference mechanism in this repository is `scripts/git-hooks/embargo-guard.sh`
wrapping the deferrable pre-commit hooks, driven by `.vibecrafted/embargo.toml`
(template: `.vibecrafted/embargo.toml.example`):

- required fields: `plan_id` (lowercase slug), `phase` (`W1` or `W2`),
  `deferred_gates`, `attestation` (`open` or `W2_STRUCTURALLY_CLOSED`),
  `recovery_ref` (must equal `embargo/<plan_id>`);
- deferrable set: `cargo-check`, `cargo-fmt`, `cargo-clippy`, `prettier`, and
  nothing else; the guard rejects any other id;
- always running, marker or not: whitespace/EOF/line-ending hygiene,
  merge-conflict check, private-key detection, commit-message provenance and
  the pre-push security scan;
- at `attestation = "W2_STRUCTURALLY_CLOSED"` every deferred gate is active
  again immediately; the attestation is only valid in `phase = "W2"`;
- a missing marker is the ordinary repository path (all gates run);
  `scripts/git-hooks/embargo-selftest.sh` proves the guard on a throwaway
  repository.

### B. Dispatcher-enforced operational embargo

Used when the repository has no consuming guard. Every rendered worker prompt
contains the same explicit forbidden-command list; the Agent-Operator checks
transcripts and reports before admission. Reports must call the absence of a
technical guard out directly.

### C. Informal

A conversational request without a marker, dispatcher contract or auditable
phase receipts is not sufficient for a fleet execution. Upgrade it to A or B
before writing code.

Never create a decorative marker in a repository that has no guard consuming
it. The marker is an enforcement input, not theatre.

### 5.1 Checkpoints and `--no-verify`

A worker can always preserve its work. The preferred path is the guard above:
hooks skip only the deferred gates and run everything else. When the
repository has no guard, or the guard cannot express the declared deferral, a
worker may use `git commit --no-verify` for a local checkpoint inside the
declared phase.

`--no-verify` bypasses the whole hook entry point, including checks nobody
intended to defer. The checkpoint report therefore names the exact SHA, the
scope and every hook that did not run, security hooks included. The commit
preserves work; it certifies nothing. The integrator runs the skipped security
and hygiene checks before structural admission, not after delivery.

Outside a declared phase checkpoint, `--no-verify` remains forbidden. Workers
never push with `--no-verify`; that push belongs to the integration and
publication authority, never to a worker.

## 6. Phase protocol

### W0 — admission and preregistration

No product implementation begins until the Agent-Operator records:

1. repository root, runtime class, baseline branch and full baseline SHA;
2. clean/dirty state and ownership of any pre-existing changes;
3. target architecture, invariants and one source of truth per behavior;
4. closed worker domains and their overlap matrix;
5. acceptance contracts and tests each worker must author;
6. allowed structural instruments and exact forbidden commands;
7. each deferred gate with its reason and return condition (section 2);
8. enforcement grade, phase state and recovery ref;
9. commit/report paths, provenance requirements and integration authority;
10. later compile, test and runtime gates;
11. failure/re-entry budget.

For Fleet Worktrees, the supervisor creates each worktree from the exact pinned
SHA. A branch mismatch, dirty starting tree or wrong merge-base is
`SUBSTRATE_FAILURE`, not a reason to improvise.

If Grade A enforcement does not already exist, its guard is a separate W0 cut
that must be proven before product W1 begins. If Grade B is deliberately chosen,
the journal says so and does not claim hook enforcement.

### W1 — structural atoms

All independent workers may run concurrently. Each worker:

1. verifies branch, merge-base and clean start;
2. maps the domain before editing and reads each affected file immediately
   before changing it;
3. implements the complete atom, not a compile-shaped fragment;
4. authors non-trivial tests for success, failure and ownership boundaries but
   does not execute them;
5. stays inside the closed domain and reports required cross-domain seams as
   `DANGLING` or `BOUNDARY`;
6. runs only W1-admitted structural checks;
7. stages only owned files/hunks and creates one durable checkpoint commit;
8. writes a report with baseline, terminal SHA, changed files, exact checks,
   unrun tests, skipped hooks, unknowns and the next integrator instruction.

The canonical W1 receipt is:

```text
GATE=green PHASE=W1 BUILD/LINT/TEST=NOT_ASSESSED (embargo W1)
```

Here `green` describes only the declared W1 structural gate. It must never be
read as compiler, test or runtime success.

Workers do not merge, push, deploy, restart services, repair sibling cuts,
lift the embargo or decide which gates return. They commit coherent local
batons; partial uncommitted work is not a baton.

### W2 — integration and structural closure

The Agent-Operator integrates on the declared recovery/integration ref, not
silently on trunk. For every cut, independently verify:

- exact baseline and ancestry;
- worker branch and terminal commit;
- report identity and finalized claim;
- changed-file fence and absence of unrelated work;
- actual diff, not just the commit subject;
- W1 structural checks, explicit embargo receipt and the list of skipped
  hooks;
- security and hygiene checks the checkpoint skipped, re-run now;
- all declared dangling seams.

Admission alone is not structural closure. The integrator then wires the atoms
and proves the complete source graph without compiling:

- every intended definition has the intended consumers;
- every production consumer resolves to one declared owner;
- no bypass path or duplicate truth remains;
- schemas, types, routes, storage and lifecycle edges agree;
- tests cover cross-cut seams and negative paths;
- all executable residue has an explicit disposition;
- absence claims come from a complete enough instrument, with truncation and
  coverage recorded;
- no `DANGLING`, `BOUNDARY` or unresolved conflict is hidden.

`STRUCTURALLY_WIRED` is not enough. The embargo closes only on an explicit:

```text
W2_STRUCTURALLY_CLOSED
```

The attestation means "the system is assembled and fit to be checked". It does
not mean "the system works". It records the integrated SHA, structural
instruments, unresolved unknowns (normally none), who signed it and the
timestamp. In Grade A, changing the marker to this attestation restores all
deferred commands before any first compile. In Grade B, the Agent-Operator
journals the phase transition and unlocks only the preregistered commands.

Structurally unfinished fragments may be integrated when later cuts depend on
them, provided their unverified state stays visible in the tracker until the
gates that cover them return.

### W3 — first compile and bounded recovery

The first compilation is a measurement. Preserve its exact command, output,
exit code and integrated SHA before changing source.

Classify every failure before repair:

- `MECHANICAL_RECOVERY`: spelling, import/export, signature or generated glue
  that preserves the closed ownership model;
- `CONTRACT_MISMATCH`: authored contracts disagree across cuts and require an
  explicit integration decision;
- `INSTRUMENT_FALSE_NEGATIVE`: the W2 structural instrument claimed closure
  while a discoverable dangling edge remained;
- `ARCHITECTURE_COMPILER_CONFLICT`: satisfying the compiler would require a new
  owner, fallback, duplicate truth, compatibility bypass or changed invariant;
- `SUBSTRATE_FAILURE`: toolchain, dependency, environment or hook state is not
  the declared substrate.

Only `MECHANICAL_RECOVERY` may enter a bounded compiler-guided repair loop
without reopening architecture. `CONTRACT_MISMATCH` and
`ARCHITECTURE_COMPILER_CONFLICT` return to an explicit structural re-entry; the
original W2 result remains recorded and is not rewritten. An
`INSTRUMENT_FALSE_NEGATIVE` also produces an instrument defect receipt and a
new regression assertion.

After compilation passes, the integrator runs the repository's full
lint/type/build/test and security gates and distributes concrete repairs from
their results. Requirements are not lowered to make a gate pass. Green now
means only that those named gates passed on the named SHA.

### W4 — runtime falsification

Exercise the real product path on the artifact produced from the verified SHA.
Check behavior, failure paths, persistence, cleanup, security boundaries and
user-visible truth. Source tests, HTTP 200, process liveness or an install
receipt alone are not runtime proof.

Record runtime identity and provenance. Any runtime-driven repair becomes a
new bounded cut with its own structural and verification receipts; do not
quietly fold it into the old W2 attestation.

## 7. Fleet topology

A valid maximum-concurrency W1 has this shape:

```text
                          pinned baseline SHA
                         /        |        \
                    cut A      cut B      cut C ...
                  checkpoint checkpoint checkpoint
                         \        |        /
                      integrator recovery ref
                               |
                    W2 structural closure
                               |
                      first compile (W3)
                               |
                    full gates and runtime (W4)
```

Concurrency is earned by disjoint ownership, not by optimistic scheduling.
Two workers touching the same owner, schema, route, generated file or shared
test oracle are either one cut or explicitly serialized. Because no cut is
compiled before W2, the cost of overlapping domains lands entirely on the
integrator's first compile; shape the cuts so that it does not.

If a provider fails before writing, verify PID, worktree, diff, commit and
report. Re-dispatch only that atom with a recovery baton stating exactly what
exists. Never restart healthy siblings. If work exists, the baton identifies
the exact commit/diff and inherited unknowns; if nothing exists, it says so.

## 8. Honest-state vocabulary

Use these states literally:

- `NOT_ASSESSED`: the phase intentionally did not run the instrument;
- `UNKNOWN`: evidence is absent or insufficient;
- `STRUCTURALLY_WIRED`: components are connected, closure not yet proven;
- `W2_STRUCTURALLY_CLOSED`: the preregistered structural closure gate passed;
  the system is fit to be checked;
- `MECHANICALLY_GREEN`: named compile/lint/test gates passed on an exact SHA;
- `RUNTIME_VERIFIED`: named real paths passed against an identified artifact;
- `BLOCKED`, `BOUNDARY`, `DANGLING`: unfinished truth, stated before delivered
  work in reports.

Do not use `ready`, `done`, `green` or `integrated` without the instrument,
scope and exact SHA that make the word true.

## 9. Stop conditions

Stop the current phase when:

- the baseline or worktree identity is wrong;
- a worker must cross its closed domain;
- the enforcing guard behaves differently from the declared phase;
- the structural instrument is truncated, stale or unable to prove a required
  absence;
- a compile/test/runtime command was accidentally run during W1/W2;
- compiler recovery would change ownership or architecture;
- integration evidence cannot distinguish authored work from unrelated dirt.

An accidental embargo break is disclosed immediately. The affected scientific
claim may be invalid even when the product work remains salvageable.

## 10. Anti-patterns

- Compiling every worker cut and calling the final integration an embargo.
- Treating unrun tests as passing tests.
- Adding adapters or fallbacks until the build turns green.
- Using formatting or autofix as an undeclared source rewrite.
- Declaring closure from definitions while ignoring references and consumers.
- Letting a marker skip secrets, provenance, merge-conflict or other unrelated
  safety gates.
- Creating a marker no tool consumes.
- Reconstructing missing evidence after seeing later test/runtime results.
- A worker choosing its own subset of gates to run "just to be safe".
- Using `--no-verify` outside a declared phase checkpoint, omitting the
  skipped-hook receipt, or using it to claim security-clean or verified
  delivery.
- A worker pushing with `--no-verify`.
- Extending an embargo because a returning gate found a defect.
- Merging worker branches because their reports say `completed`.

## 11. Minimal execution checklist

Before W1:

- [ ] pinned clean baseline and recovery ref
- [ ] single integrator and explicit reserved buttons
- [ ] disjoint closed domains and overlap matrix
- [ ] architecture invariants and one owner per truth
- [ ] authored-test requirements
- [ ] enforcement grade and exact forbidden commands
- [ ] each deferred gate with reason and return condition
- [ ] structural gates and phase receipts

Before closing W2:

- [ ] every worker baton independently verified
- [ ] skipped security and hygiene checks re-run by the integrator
- [ ] all atoms admitted on the recovery/integration ref
- [ ] consumers, definitions, owners and residue reconciled
- [ ] cross-cut tests authored but still unrun
- [ ] zero hidden dangling/boundary items
- [ ] `W2_STRUCTURALLY_CLOSED` tied to exact SHA

After closing W2:

- [ ] first compile captured as immutable evidence
- [ ] failures classified before repair
- [ ] architecture conflicts cause re-entry, not green-driven patching
- [ ] full named quality and security gates pass on exact SHA
- [ ] real artifact/runtime path is falsified separately
- [ ] final report distinguishes structural, mechanical and runtime verdicts

## 12. Provenance

This protocol distills several Fleet Worktree executions run under a compile
embargo across Vetcoders repositories, including the phase guard and selftest
that live in this repository. The repository-owned guard, its selftest and the
dispatch reports of those executions are the evidence; this document does not
replace them.

This revision derives the embargo from the stage of the work rather than from
an approval, moves the return of every deferred gate to the integrator, and
permits `--no-verify` only for a declared phase checkpoint with a full
skipped-hook receipt. It does not authorize worker pushes or convert skipped
verification into delivery.
