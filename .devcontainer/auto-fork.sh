#!/usr/bin/env bash
set -euo pipefail

log() { printf "\n[auto-fork] %s\n" "$*"; }

# Ensure we're inside a git repo
git rev-parse --show-toplevel >/dev/null 2>&1 || { log "Not a git repo, skipping."; exit 0; }

# Confirm GH CLI is available (it should be via the Feature)
if ! command -v gh >/dev/null 2>&1; then
  log "GitHub CLI (gh) not found; skipping fork."
  exit 0
fi

# Try to auth GH CLI (Codespaces typically provides GITHUB_TOKEN)
if ! gh auth status >/dev/null 2>&1; then
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    log "Authenticating gh with GITHUB_TOKEN…"
    echo "$GITHUB_TOKEN" | gh auth login --with-token >/dev/null 2>&1 || true
  fi
fi

if ! gh auth status >/dev/null 2>&1; then
  log "Warning: gh is not authenticated. Forking may fail. Run 'gh auth login' if needed."
fi

# Detect current origin (supports https and ssh)
origin_url="$(git remote get-url origin)"
case "$origin_url" in
  git@github.com:*) base="${origin_url#git@github.com:}";;
  https://github.com/*) base="${origin_url#https://github.com/}";;
  *) log "Unrecognized origin URL: $origin_url"; exit 0;;
esac
base="${base%.git}"

upstream_owner="${base%%/*}"
repo_name="${base##*/}"

# Who am I (fork owner)?
me="$(gh api user -q .login 2>/dev/null || echo "")"
if [[ -z "$me" ]]; then
  log "Could not determine authenticated user; proceeding best-effort."
fi

# If origin already points to my fork, do nothing.
if [[ -n "$me" ]]; then
  if [[ "$origin_url" == "https://github.com/$me/$repo_name.git" || "$origin_url" == "git@github.com:$me/$repo_name.git" ]]; then
    log "Origin already points to your fork ($me/$repo_name). Nothing to do."
    exit 0
  fi
fi

# If 'upstream' exists and matches base, assume already switched.
if git remote | grep -q "^upstream$"; then
  existing_upstream="$(git remote get-url upstream || true)"
  if [[ "$existing_upstream" == *"github.com/$upstream_owner/$repo_name"* ]]; then
    log "Upstream already set to $upstream_owner/$repo_name. Skipping fork step."
    exit 0
  fi
fi

# Create fork if missing
fork_exists=false
if [[ -n "$me" ]]; then
  if gh repo view "$me/$repo_name" >/dev/null 2>&1; then
    fork_exists=true
    log "Found existing fork: $me/$repo_name"
  fi
fi

if [[ "$fork_exists" == false ]]; then
  log "Creating fork of $upstream_owner/$repo_name …"
  if ! gh repo fork "$upstream_owner/$repo_name" --clone=false --remote=false >/dev/null 2>&1; then
    log "Fork attempt failed (org restrictions or permissions). Leaving remotes unchanged."
    exit 0
  fi
  log "Fork created."
fi

# Repoint remotes: origin => fork (HTTPS), upstream => original
fork_url="https://github.com/${me:-unknown}/$repo_name.git"
upstream_url="https://github.com/$upstream_owner/$repo_name.git"

# Rename current origin to upstream (if not already)
if git remote | grep -q "^upstream$"; then
  :
else
  log "Renaming 'origin' -> 'upstream' ($upstream_url)"
  git remote rename origin upstream
  git remote set-url upstream "$upstream_url"
fi

# Add or update origin pointing to fork
if git remote | grep -q "^origin$"; then
  git remote set-url origin "$fork_url"
else
  git remote add origin "$fork_url"
fi

log "Remotes configured:"
git remote -v | sed 's/^/[auto-fork]   /'

# Sync main branch from upstream to origin (fork)
log "Syncing 'main' branch from upstream to your fork..."
git fetch upstream main >/dev/null 2>&1 || { log "Failed to fetch upstream/main."; exit 0; }
git checkout main >/dev/null 2>&1 || { log "Failed to checkout main branch."; exit 0; }
git reset --hard upstream/main >/dev/null 2>&1 || { log "Failed to reset main to upstream/main."; exit 0; }
git push origin main --force >/dev/null 2>&1 || { log "Failed to push main to origin."; exit 0; }

log "Done. 'origin' -> your fork, 'upstream' -> $upstream_owner/$repo_name. 'main' branch synced."
