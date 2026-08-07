from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"marker not found for {label}")
    return text.replace(old, new, 1)


# Load the new PostgreSQL module into both generator dependency graphs.
base_path = Path("db/src/gwdb/ledger/base.clj")
base = base_path.read_text()
base_marker = "            [gwdb.ledger.workspace-review]\n            [gwdb.ledger.developer]"
base_replacement = (
    "            [gwdb.ledger.workspace-review]\n"
    "            [gwdb.ledger.workspace-acceptance]\n"
    "            [gwdb.ledger.developer]"
)
base = replace_once(base, base_marker, base_replacement, "base require")
base = replace_once(base, base_marker, base_replacement, "base script require")
base_path.write_text(base)


# Exercise policy publication beside the existing signed workspace lifecycle.
verify_path = Path(".github/workflows/verify.yml")
verify = verify_path.read_text()
verify = replace_once(
    verify,
    "      - name: Test signed workspace reviews, proposals, refs, commits and runtime contracts",
    "      - name: Test signed workspace policies, reviews, proposals, refs, commits and runtime contracts",
    "verify step name",
)
verify = replace_once(
    verify,
    "                 gwdb.ledger.workspace-review-test \\\n                 gwdb.ledger.scoped-ref-test \\",
    "                 gwdb.ledger.workspace-review-test \\\n                 gwdb.ledger.workspace-acceptance-test \\\n                 gwdb.ledger.scoped-ref-test \\",
    "verify policy test",
)
verify_path.write_text(verify)


# Add generated TypeScript request and result contracts.
contract_path = Path("db/src/ledger/build_contract.clj")
contract = contract_path.read_text()
types_marker = '''export type WorkspaceReviewSubmission =
  | {
      status: \\"ok\\";
      address: LedgerRoot;
      sequence: number;
      workspace_id_root: LedgerRoot;
      candidate_root: LedgerRoot;
      scope: string;
      name: string;
      expected_review_root?: LedgerRoot;
      review_root: LedgerRoot;
      decision: WorkspaceReviewDecision;
      recorded_at: number;
      policy: \\"review-decision-v1\\";
      ref_version: number;
      intent_root: LedgerRoot;
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
      candidate_root: LedgerRoot;
      scope: string;
      name: string;
      expected_root?: LedgerRoot;
      actual_root?: LedgerRoot;
      desired_root: LedgerRoot;
      version: number;
      review_root: LedgerRoot;
      decision: WorkspaceReviewDecision;
      recorded_at: number;
      policy: \\"review-decision-v1\\";
      intent_root: LedgerRoot;
    };

export interface LedgerDeveloperApi {'''
policy_types = '''export type WorkspaceReviewSubmission =
  | {
      status: \\"ok\\";
      address: LedgerRoot;
      sequence: number;
      workspace_id_root: LedgerRoot;
      candidate_root: LedgerRoot;
      scope: string;
      name: string;
      expected_review_root?: LedgerRoot;
      review_root: LedgerRoot;
      decision: WorkspaceReviewDecision;
      recorded_at: number;
      policy: \\"review-decision-v1\\";
      ref_version: number;
      intent_root: LedgerRoot;
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
      candidate_root: LedgerRoot;
      scope: string;
      name: string;
      expected_root?: LedgerRoot;
      actual_root?: LedgerRoot;
      desired_root: LedgerRoot;
      version: number;
      review_root: LedgerRoot;
      decision: WorkspaceReviewDecision;
      recorded_at: number;
      policy: \\"review-decision-v1\\";
      intent_root: LedgerRoot;
    };

export interface WorkspaceMainPolicySigningRequest {
  address: LedgerRoot;
  sequence: number;
  workspace_id_root: LedgerRoot;
  scope: string;
  name: \\"policy/main\\";
  expected_root?: undefined;
  reviewer_roots_root: LedgerRoot;
  recorded_at: number;
  policy: \\"unanimous-reviewers-v1\\";
  policy_root: LedgerRoot;
  operation_root: LedgerRoot;
  signing_payload: string;
}

export type WorkspaceMainPolicySubmission =
  | {
      status: \\"ok\\";
      address: LedgerRoot;
      sequence: number;
      workspace_id_root: LedgerRoot;
      scope: string;
      name: \\"policy/main\\";
      expected_root?: undefined;
      reviewer_roots_root: LedgerRoot;
      recorded_at: number;
      policy: \\"unanimous-reviewers-v1\\";
      policy_root: LedgerRoot;
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
      scope: string;
      name: \\"policy/main\\";
      expected_root?: undefined;
      actual_root?: LedgerRoot;
      desired_root: LedgerRoot;
      version: number;
      reviewer_roots_root: LedgerRoot;
      recorded_at: number;
      policy: \\"unanimous-reviewers-v1\\";
      policy_root: LedgerRoot;
    };

export interface LedgerDeveloperApi {'''
contract = replace_once(contract, types_marker, policy_types, "main policy types")

methods_marker = '''  workspaceReviewSigningRequest(network: string, publicKey: string, workspaceIdRoot: LedgerRoot, candidateRoot: LedgerRoot, expectedReviewRoot: LedgerRoot | undefined, decision: WorkspaceReviewDecision, recordedAt: number, costLimit?: number): Promise<WorkspaceReviewSigningRequest>;
  submitWorkspaceReview(network: string, publicKey: string, sequence: number, workspaceIdRoot: LedgerRoot, candidateRoot: LedgerRoot, expectedReviewRoot: LedgerRoot | undefined, decision: WorkspaceReviewDecision, recordedAt: number, signature: string, costLimit?: number): Promise<WorkspaceReviewSubmission>;
}'''
policy_methods = '''  workspaceReviewSigningRequest(network: string, publicKey: string, workspaceIdRoot: LedgerRoot, candidateRoot: LedgerRoot, expectedReviewRoot: LedgerRoot | undefined, decision: WorkspaceReviewDecision, recordedAt: number, costLimit?: number): Promise<WorkspaceReviewSigningRequest>;
  submitWorkspaceReview(network: string, publicKey: string, sequence: number, workspaceIdRoot: LedgerRoot, candidateRoot: LedgerRoot, expectedReviewRoot: LedgerRoot | undefined, decision: WorkspaceReviewDecision, recordedAt: number, signature: string, costLimit?: number): Promise<WorkspaceReviewSubmission>;
  workspaceMainPolicySigningRequest(network: string, publicKey: string, workspaceIdRoot: LedgerRoot, reviewerRootsRoot: LedgerRoot, recordedAt: number, costLimit?: number): Promise<WorkspaceMainPolicySigningRequest>;
  submitWorkspaceMainPolicy(network: string, publicKey: string, sequence: number, workspaceIdRoot: LedgerRoot, reviewerRootsRoot: LedgerRoot, recordedAt: number, signature: string, costLimit?: number): Promise<WorkspaceMainPolicySubmission>;
}'''
contract = replace_once(contract, methods_marker, policy_methods, "main policy methods")
contract_path.write_text(contract)


# Describe the new signed boundary without implying that main admission is done.
readme_path = Path("README.md")
readme = readme_path.read_text()
readme_old = '''V1 requires every listed reviewer to have a current `:approve` decision.
Superseded approvals, rejects, withdrawals, unpublished candidates, non-genesis
bootstrap attempts and non-fast-forward updates are rejected before ref CAS. The
portable adapter proves the policy algebra; signed PostgreSQL admission is the
next delivery slice. See
[`docs/workspace-main-acceptance.md`](docs/workspace-main-acceptance.md).'''
readme_new = '''V1 requires every listed reviewer to have a current `:approve` decision.
Superseded approvals, rejects, withdrawals, unpublished candidates, non-genesis
bootstrap attempts and non-fast-forward updates are rejected before ref CAS.

The first signed PostgreSQL slice publishes the immutable policy at `policy/main`
through account sequencing, Ed25519 verification, exact create-only CAS, a
receipt whose result is the policy root, and one linear block. It does not yet
advance `main`. See
[`docs/workspace-main-acceptance.md`](docs/workspace-main-acceptance.md) and
[`docs/workspace-main-policy-admission.md`](docs/workspace-main-policy-admission.md).'''
readme = replace_once(readme, readme_old, readme_new, "README policy admission")
readme_path.write_text(readme)
