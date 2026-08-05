# Repository Delivery Policy

## Default Workflow

- Use a pull request for repository delivery by default.
- Do not commit or push directly to the default branch unless the repository owner explicitly requests direct default-branch commit and push for the current task.
- Requests such as "finish", "ship", or "publish" do not imply permission for a direct push.
- Direct delivery does not waive security review, required tests, repository hooks, CI requirements, or any other project policy.

## Repository Delivery Worker

- Before any staging, commit, or push, designate exactly one **Repository Delivery Worker** for the task.
- Only that worker may stage files, create the delivery commit, or push it.
- Other workers may inspect and validate, but must not mutate Git state.
- If authorization or worker designation is absent or ambiguous, stop before Git mutation and use the pull-request workflow.

## Direct Default-Branch Delivery

When the repository owner explicitly authorizes direct delivery, the Repository Delivery Worker must:

1. Confirm the checked-out branch and the repository's default branch before staging. Direct delivery is permitted only to the default branch.
2. Inspect the working tree and preserve all unrelated changes. Never stash, discard, restore, overwrite, or include another person's work.
3. Stage only approved exact paths with `git add -- <exact-path>...`. Do not use `git add .`, `git add -A`, broad directories, or globs.
4. Review the complete staged change with `git diff --cached --check`, `git diff --cached --name-only`, and `git diff --cached -- <exact-path>...`. Abort if any staged path is unrelated or unexpected.
5. Run all relevant validation for the staged scope, including required security and test gates. Record the exact commands and results; do not claim validation that was not run.
6. Create a signed, DCO-compliant commit using both signature and sign-off, for example `git commit -S -s` with a Conventional Commit message.
7. Verify the resulting commit, staged-path scope, and clean separation from unrelated dirty-tree changes before pushing.
8. Push normally to the default branch. Force push, including `--force-with-lease`, is prohibited.

If signing, validation, hooks, branch state, remote state, or push safety cannot be confirmed, do not bypass the gate. Report the blocker and fall back to a pull request when appropriate.

## Delivery Report

Report:

- the commit SHA, subject, signature status, and DCO sign-off;
- the exact validation commands and their outcomes;
- the remote, branch, and push result;
- any unrelated working-tree changes that were deliberately excluded;
- any failed or skipped step, without implying completion.
