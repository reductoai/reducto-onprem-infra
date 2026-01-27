---
name: require-explicit-commit
enabled: true
event: bash
pattern: git\s+commit
action: block
conditions:
  - field: user_context
    operator: not_contains
    pattern: commit
---

🚫 **Git commit blocked - explicit request required**

You configured Claude Code to ONLY run `git commit` when you explicitly use the word "commit" in your request.

**To allow this commit:**
Your message must contain the word "commit" (e.g., "commit these changes", "create a commit", "make a git commit")

**Current issue:**
Your recent message did not contain the word "commit", so this operation is blocked.

**User's last message likely was something like:**
"update the code" or "fix this" without mentioning commits.
