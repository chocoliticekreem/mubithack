#!/bin/sh
# Stop hook: pull the current branch from origin (rebase, autostash) and push any local commits.
# Never commits anything itself, never force-pushes, never fails the session.
cd "${CLAUDE_PROJECT_DIR:-$(dirname "$0")/..}" || exit 0
branch=$(git symbolic-ref --short -q HEAD) || exit 0
# another git command is running (agents, editors): try again next turn instead of failing
[ -f "$(git rev-parse --git-dir)/index.lock" ] && exit 0
git fetch -q origin "$branch" 2>/dev/null || exit 0
if ! git pull -q --rebase --autostash origin "$branch" 2>/dev/null; then
  if [ -d "$(git rev-parse --git-dir)/rebase-merge" ] || [ -d "$(git rev-parse --git-dir)/rebase-apply" ]; then
    git rebase --abort 2>/dev/null
    echo '{"systemMessage":"git-sync: rebase conflict — resolve manually"}'
  fi
  exit 0
fi
ahead=$(git rev-list --count "origin/$branch..HEAD" 2>/dev/null || echo 0)
if [ "$ahead" -gt 0 ]; then
  if git push -q origin "$branch" 2>/dev/null; then
    echo "{\"systemMessage\":\"git-sync: pushed $ahead commit(s) to $branch\"}"
  else
    echo '{"systemMessage":"git-sync: push failed"}'
  fi
fi
exit 0
