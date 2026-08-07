from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"marker not found for {label}")
    return text.replace(old, new, 1)


contract_path = Path("db/src/ledger/build_contract.clj")
contract = contract_path.read_text()

types_marker = '''export type WorkspaceProposalSubmission = WorkspaceRefSubmission & {
  policy: \\"proposal-publication-v1\\";
};

export interface LedgerDeveloperApi {'''
review_types = '''export type WorkspaceProposalSubmission = WorkspaceRefSubmission & {
  policy: \\"proposal-publication-v1\\";
};

export type WorkspaceReviewDecision = \\"approve\\" | \\"reject\\" | \\"withdraw\\";

export interface WorkspaceReviewSigningRequest {
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
  intent_root: LedgerRoot;
  operation_root: LedgerRoot;
  signing_payload: string;
}

export type WorkspaceReviewSubmission =
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
contract = replace_once(contract, types_marker, review_types, "review types")

methods_marker = '''  workspaceProposalSigningRequest(network: string, publicKey: string, workspaceIdRoot: LedgerRoot, desiredRoot: LedgerRoot, costLimit?: number): Promise<WorkspaceProposalSigningRequest>;
  submitWorkspaceProposal(network: string, publicKey: string, sequence: number, workspaceIdRoot: LedgerRoot, desiredRoot: LedgerRoot, signature: string, costLimit?: number): Promise<WorkspaceProposalSubmission>;
}'''
review_methods = '''  workspaceProposalSigningRequest(network: string, publicKey: string, workspaceIdRoot: LedgerRoot, desiredRoot: LedgerRoot, costLimit?: number): Promise<WorkspaceProposalSigningRequest>;
  submitWorkspaceProposal(network: string, publicKey: string, sequence: number, workspaceIdRoot: LedgerRoot, desiredRoot: LedgerRoot, signature: string, costLimit?: number): Promise<WorkspaceProposalSubmission>;
  workspaceReviewSigningRequest(network: string, publicKey: string, workspaceIdRoot: LedgerRoot, candidateRoot: LedgerRoot, expectedReviewRoot: LedgerRoot | undefined, decision: WorkspaceReviewDecision, recordedAt: number, costLimit?: number): Promise<WorkspaceReviewSigningRequest>;
  submitWorkspaceReview(network: string, publicKey: string, sequence: number, workspaceIdRoot: LedgerRoot, candidateRoot: LedgerRoot, expectedReviewRoot: LedgerRoot | undefined, decision: WorkspaceReviewDecision, recordedAt: number, signature: string, costLimit?: number): Promise<WorkspaceReviewSubmission>;
}'''
contract = replace_once(contract, methods_marker, review_methods, "review methods")
contract_path.write_text(contract)

readme_path = Path("README.md")
readme = readme_path.read_text()
old = '''Shared `main`, proposal and release refs remain policy-gated follow-up work. See
[`docs/workspace-ref-admission.md`](docs/workspace-ref-admission.md).

## Convex-style accounts and actors'''
new = '''Proposal publication and reviewer decisions are separate signed policies; shared
`main` and release refs remain policy-gated follow-up work. See
[`docs/workspace-ref-admission.md`](docs/workspace-ref-admission.md).

## Signed workspace proposals and reviews

A verified account may publish an immutable candidate as
`proposal/<candidate-root>`. The proposal is create-only and cannot be redirected
to a different commit. Reviewers then sign canonical `:review/decision` records
for that exact candidate. Each reviewer has an independent
`review/<candidate-root>/<reviewer-root>` ref updated through exact compare-and-set,
so stale decisions do not consume account sequence or global block height.

Proposal visibility and reviewer statements do not by themselves authorize
`main`. A later explicit workspace policy evaluates exact proposal and review
roots before accepting a shared head. See
[`docs/workspace-proposals.md`](docs/workspace-proposals.md) and
[`docs/workspace-reviews.md`](docs/workspace-reviews.md).

## Convex-style accounts and actors'''
readme_path.write_text(replace_once(readme, old, new, "README review section"))
