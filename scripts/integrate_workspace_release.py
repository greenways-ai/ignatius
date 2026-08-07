from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"marker not found for {label}")
    return text.replace(old, new, 1)


# Keep the portable and PostgreSQL version boundaries aligned.
portable_path = Path("hal/src/ignatius/workspace_release.hal")
portable = portable_path.read_text()
portable = replace_once(
    portable,
    '''      (= nil version)
      :workspace/missing-release-version

      (= nil candidate-root)''',
    '''      (= nil version)
      :workspace/missing-release-version

      (= 0 (count version))
      :workspace/missing-release-version

      (= nil candidate-root)''',
    "portable non-empty release version",
)
portable_path.write_text(portable)


# Load the signed release module into both PostgreSQL generator graphs.
base_path = Path("db/src/gwdb/ledger/base.clj")
base = base_path.read_text()
base = replace_once(
    base,
    "            [gwdb.ledger.workspace-main]\n            [gwdb.ledger.developer]",
    "            [gwdb.ledger.workspace-main]\n            [gwdb.ledger.workspace-release]\n            [gwdb.ledger.developer]",
    "base release require",
)
base = replace_once(
    base,
    "             [gwdb.ledger.workspace-main]\n             [gwdb.ledger.developer]",
    "             [gwdb.ledger.workspace-main]\n             [gwdb.ledger.workspace-release]\n             [gwdb.ledger.developer]",
    "base release script require",
)
base_path.write_text(base)


# Add generated TypeScript release request and result contracts.
contract_path = Path("db/src/ledger/build_contract.clj")
contract = contract_path.read_text()
types_marker = "export interface LedgerDeveloperApi {"
release_types = '''export interface WorkspaceReleaseSigningRequest {
  address: LedgerRoot;
  sequence: number;
  workspace_id_root: LedgerRoot;
  scope: string;
  name: string;
  expected_root?: undefined;
  version: string;
  candidate_root: LedgerRoot;
  policy_root: LedgerRoot;
  acceptance_root: LedgerRoot;
  recorded_at: number;
  policy: \\"release-publication-v1\\";
  release_root: LedgerRoot;
  operation_root: LedgerRoot;
  signing_payload: string;
}

export type WorkspaceReleaseSubmission =
  | {
      status: \\"ok\\";
      address: LedgerRoot;
      sequence: number;
      workspace_id_root: LedgerRoot;
      scope: string;
      name: string;
      expected_root?: undefined;
      version: string;
      candidate_root: LedgerRoot;
      policy_root: LedgerRoot;
      acceptance_root: LedgerRoot;
      recorded_at: number;
      policy: \\"release-publication-v1\\";
      release_root: LedgerRoot;
      ref_version: number;
      transaction_root: LedgerRoot;
      receipt_root: LedgerRoot;
      result_root: LedgerRoot;
      state_root: LedgerRoot;
      block_root: LedgerRoot;
    }
  | {
      status: \\"conflict\\";
      error: \\"storage/ref-conflict\\";
      address: LedgerRoot;
      sequence: number;
      workspace_id_root: LedgerRoot;
      scope: string;
      name: string;
      expected_root?: undefined;
      actual_root?: LedgerRoot;
      desired_root: LedgerRoot;
      version: string;
      candidate_root: LedgerRoot;
      policy_root: LedgerRoot;
      acceptance_root: LedgerRoot;
      recorded_at: number;
      policy: \\"release-publication-v1\\";
      release_root: LedgerRoot;
    };

export interface LedgerDeveloperApi {'''
contract = replace_once(contract, types_marker, release_types, "release types")

methods_marker = '''  workspaceMainSigningRequest(network: string, publicKey: string, workspaceIdRoot: LedgerRoot, expectedRoot: LedgerRoot | undefined, candidateRoot: LedgerRoot, policyRoot: LedgerRoot, reviewRootsRoot: LedgerRoot, recordedAt: number, costLimit?: number): Promise<WorkspaceMainAcceptanceSigningRequest>;
  submitWorkspaceMain(network: string, publicKey: string, sequence: number, workspaceIdRoot: LedgerRoot, expectedRoot: LedgerRoot | undefined, candidateRoot: LedgerRoot, policyRoot: LedgerRoot, reviewRootsRoot: LedgerRoot, recordedAt: number, signature: string, costLimit?: number): Promise<WorkspaceMainAcceptanceSubmission>;
}'''
release_methods = '''  workspaceMainSigningRequest(network: string, publicKey: string, workspaceIdRoot: LedgerRoot, expectedRoot: LedgerRoot | undefined, candidateRoot: LedgerRoot, policyRoot: LedgerRoot, reviewRootsRoot: LedgerRoot, recordedAt: number, costLimit?: number): Promise<WorkspaceMainAcceptanceSigningRequest>;
  submitWorkspaceMain(network: string, publicKey: string, sequence: number, workspaceIdRoot: LedgerRoot, expectedRoot: LedgerRoot | undefined, candidateRoot: LedgerRoot, policyRoot: LedgerRoot, reviewRootsRoot: LedgerRoot, recordedAt: number, signature: string, costLimit?: number): Promise<WorkspaceMainAcceptanceSubmission>;
  workspaceReleaseSigningRequest(network: string, publicKey: string, workspaceIdRoot: LedgerRoot, version: string, candidateRoot: LedgerRoot, policyRoot: LedgerRoot, acceptanceRoot: LedgerRoot, recordedAt: number, costLimit?: number): Promise<WorkspaceReleaseSigningRequest>;
  submitWorkspaceRelease(network: string, publicKey: string, sequence: number, workspaceIdRoot: LedgerRoot, version: string, candidateRoot: LedgerRoot, policyRoot: LedgerRoot, acceptanceRoot: LedgerRoot, recordedAt: number, signature: string, costLimit?: number): Promise<WorkspaceReleaseSubmission>;
}'''
contract = replace_once(contract, methods_marker, release_methods, "release methods")
contract_path.write_text(contract)


# Bring the repository overview up to the completed lifecycle boundary.
readme_path = Path("README.md")
readme = readme_path.read_text()
readme = replace_once(
    readme,
    '''Proposal publication and reviewer decisions are separate signed policies; shared
`main` and release refs remain policy-gated follow-up work. See
[`docs/workspace-ref-admission.md`](docs/workspace-ref-admission.md).''',
    '''Proposal publication and reviewer decisions are separate signed policies.
Shared `main` and release refs are admitted only through explicit selected policy
and evidence roots. See
[`docs/workspace-ref-admission.md`](docs/workspace-ref-admission.md).''',
    "README lifecycle boundary",
)
main_marker = '''[`docs/workspace-main-policy-admission.md`](docs/workspace-main-policy-admission.md),
and [`docs/workspace-main-admission.md`](docs/workspace-main-admission.md).

## Convex-style accounts and actors'''
release_section = '''[`docs/workspace-main-policy-admission.md`](docs/workspace-main-policy-admission.md),
and [`docs/workspace-main-admission.md`](docs/workspace-main-admission.md).

## Immutable workspace releases

[`ignatius.workspace-release`](hal/src/ignatius/workspace_release.hal) publishes
create-only `release/<version>` selections for the candidate currently accepted
at `main`. The canonical release attestation pins workspace, version, candidate,
selected policy and the exact accepted-main evidence root.

PostgreSQL proves that the acceptance has an `ok` receipt bound to a valid block
on the current linear network chain. A structurally valid acceptance created by
a stale main attempt is therefore insufficient. Successful release publication
returns the immutable release claim root while the release ref selects the
candidate; duplicate versions consume neither sequence nor block height. See
[`docs/workspace-release-admission.md`](docs/workspace-release-admission.md).

## Convex-style accounts and actors'''
readme = replace_once(readme, main_marker, release_section, "README release section")
readme_path.write_text(readme)
