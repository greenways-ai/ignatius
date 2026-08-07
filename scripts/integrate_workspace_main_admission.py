from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"marker not found for {label}")
    return text.replace(old, new, 1)


# Load the signed main module into both PostgreSQL generator dependency graphs.
base_path = Path("db/src/gwdb/ledger/base.clj")
base = base_path.read_text()
base = replace_once(
    base,
    "            [gwdb.ledger.workspace-acceptance]\n            [gwdb.ledger.developer]",
    "            [gwdb.ledger.workspace-acceptance]\n            [gwdb.ledger.workspace-main]\n            [gwdb.ledger.developer]",
    "base require",
)
base = replace_once(
    base,
    "             [gwdb.ledger.workspace-acceptance]\n             [gwdb.ledger.developer]",
    "             [gwdb.ledger.workspace-acceptance]\n             [gwdb.ledger.workspace-main]\n             [gwdb.ledger.developer]",
    "base script require",
)
base_path.write_text(base)


# Add the generated TypeScript accepted-main surface.
contract_path = Path("db/src/ledger/build_contract.clj")
contract = contract_path.read_text()
types_marker = "export interface LedgerDeveloperApi {"
main_types = '''export interface WorkspaceMainAcceptanceSigningRequest {
  address: LedgerRoot;
  sequence: number;
  workspace_id_root: LedgerRoot;
  scope: string;
  name: \\"main\\";
  expected_root?: LedgerRoot;
  candidate_root: LedgerRoot;
  policy_root: LedgerRoot;
  review_roots_root: LedgerRoot;
  recorded_at: number;
  policy: \\"main-acceptance-v1\\";
  acceptance_root: LedgerRoot;
  operation_root: LedgerRoot;
  signing_payload: string;
}

export type WorkspaceMainAcceptanceSubmission =
  | {
      status: \\"ok\\";
      address: LedgerRoot;
      sequence: number;
      workspace_id_root: LedgerRoot;
      scope: string;
      name: \\"main\\";
      expected_root?: LedgerRoot;
      candidate_root: LedgerRoot;
      policy_root: LedgerRoot;
      review_roots_root: LedgerRoot;
      recorded_at: number;
      policy: \\"main-acceptance-v1\\";
      acceptance_root: LedgerRoot;
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
      name: \\"main\\";
      expected_root?: LedgerRoot;
      actual_root?: LedgerRoot;
      desired_root: LedgerRoot;
      version: number;
      candidate_root: LedgerRoot;
      policy_root: LedgerRoot;
      review_roots_root: LedgerRoot;
      recorded_at: number;
      policy: \\"main-acceptance-v1\\";
      acceptance_root: LedgerRoot;
    };

export interface LedgerDeveloperApi {'''
contract = replace_once(contract, types_marker, main_types, "main acceptance types")

methods_marker = '''  workspaceMainPolicySigningRequest(network: string, publicKey: string, workspaceIdRoot: LedgerRoot, reviewerRootsRoot: LedgerRoot, recordedAt: number, costLimit?: number): Promise<WorkspaceMainPolicySigningRequest>;
  submitWorkspaceMainPolicy(network: string, publicKey: string, sequence: number, workspaceIdRoot: LedgerRoot, reviewerRootsRoot: LedgerRoot, recordedAt: number, signature: string, costLimit?: number): Promise<WorkspaceMainPolicySubmission>;
}'''
main_methods = '''  workspaceMainPolicySigningRequest(network: string, publicKey: string, workspaceIdRoot: LedgerRoot, reviewerRootsRoot: LedgerRoot, recordedAt: number, costLimit?: number): Promise<WorkspaceMainPolicySigningRequest>;
  submitWorkspaceMainPolicy(network: string, publicKey: string, sequence: number, workspaceIdRoot: LedgerRoot, reviewerRootsRoot: LedgerRoot, recordedAt: number, signature: string, costLimit?: number): Promise<WorkspaceMainPolicySubmission>;
  workspaceMainSigningRequest(network: string, publicKey: string, workspaceIdRoot: LedgerRoot, expectedRoot: LedgerRoot | undefined, candidateRoot: LedgerRoot, policyRoot: LedgerRoot, reviewRootsRoot: LedgerRoot, recordedAt: number, costLimit?: number): Promise<WorkspaceMainAcceptanceSigningRequest>;
  submitWorkspaceMain(network: string, publicKey: string, sequence: number, workspaceIdRoot: LedgerRoot, expectedRoot: LedgerRoot | undefined, candidateRoot: LedgerRoot, policyRoot: LedgerRoot, reviewRootsRoot: LedgerRoot, recordedAt: number, signature: string, costLimit?: number): Promise<WorkspaceMainAcceptanceSubmission>;
}'''
contract = replace_once(contract, methods_marker, main_methods, "main acceptance methods")
contract_path.write_text(contract)


# Make the reviewer-position assertion independent of the no-op rule.
test_path = Path("db/test/gwdb/ledger/workspace_main_test.clj")
test = test_path.read_text()
test = replace_once(
    test,
    "           network alice-public-key workspace-id-root c1 c1\n           policy-root reversed-review-roots-root 13 20)",
    "           network alice-public-key workspace-id-root c0 c1\n           policy-root reversed-review-roots-root 13 20)",
    "reviewer position test",
)
test_path.write_text(test)


# State that signed main selection now exists, without claiming releases exist.
readme_path = Path("README.md")
readme = readme_path.read_text()
old = '''The first signed PostgreSQL slice publishes the immutable policy at `policy/main`
through account sequencing, Ed25519 verification, exact create-only CAS, a
receipt whose result is the policy root, and one linear block. It does not yet
advance `main`. See
[`docs/workspace-main-acceptance.md`](docs/workspace-main-acceptance.md) and
[`docs/workspace-main-policy-admission.md`](docs/workspace-main-policy-admission.md).'''
new = '''PostgreSQL first publishes the immutable policy at `policy/main` through account
sequencing, Ed25519 verification and create-only CAS. A separate signed
acceptance then verifies the selected policy, proposed candidate, exact current
approval roots and commit ancestry before advancing `main`. The transaction
receipt returns the immutable acceptance root while the ref selects the candidate
root; stale main updates consume neither sequence nor block height. See
[`docs/workspace-main-acceptance.md`](docs/workspace-main-acceptance.md),
[`docs/workspace-main-policy-admission.md`](docs/workspace-main-policy-admission.md),
and [`docs/workspace-main-admission.md`](docs/workspace-main-admission.md).'''
readme = replace_once(readme, old, new, "README signed main")
readme_path.write_text(readme)
