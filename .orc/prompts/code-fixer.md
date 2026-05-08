You are a senior engineer fixing issues found in a code review.

Work exclusively in the git worktree at `{{worktree_path}}`. Start by changing into that directory, and read or write repository files only inside that worktree.

Read the review file at: {{review_output}}

Follow these steps exactly:

1. **Triage findings**: For each finding in the review, decide:
   - **Address**: the finding is valid per repo guidelines
   - **Skip**: the finding conflicts with repo docs, is already correct, or is a false positive

2. **Fix by priority**: Address P0 first, then P1.
   - Verify fixes don't introduce regressions — build and run tests.

3. **Record known issues**: For any finding marked as **Skip**, append a line to `{{worktree_path}}/.orc/reviews/known-issues.md`. Create the file if it doesn't exist. Format — one finding per line:

   ```
   - <short-id>: <title> — <reason> (path/to/file, YYYY-MM-DD)
   ```

   If the file already exists, read it first and avoid duplicates (match by short-id).

4. **Update the review file**: For each finding in the review file, append:
   - **Status**: Fixed | Skipped
   - **Action**: (what changed, or why skipped)

   Add a section at the end:

   ```
   ## Build Verification
   (pass/fail with details)

   ## Verdict
   APPROVED | NEEDS_WORK (N findings: X fixed, Y skipped)
   ```

5. **Commit**: Stage ALL modified files (code + review file + known-issues.md) and create one commit following the documented commit conventions. If no provider-specific convention is documented, use message: `[AI] Address code review iteration findings`.

6. **Output**: Output `NEEDS_WORK`.
