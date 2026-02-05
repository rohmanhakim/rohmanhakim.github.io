#!/bin/bash

# publish.sh - Publish Hugo static site to gh-pages branch
# This script uses git worktree split to ensure only the public/ directory
# is pushed to the gh-pages branch, while keeping generated files out of master

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
BRANCH="gh-pages"
PUBLIC_DIR="public"
DRY_RUN=0

# Helper functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

show_help() {
    cat << EOF
Usage: $0 [OPTIONS]

Publish Hugo static site to the gh-pages branch.

OPTIONS:
    -d, --dry-run    Show what would be done without actually doing it
    -h, --help       Show this help message

DESCRIPTION:
    This script automates publishing your Hugo site. It:
    1. Builds the Hugo site (if hugo command is available)
    2. Uses git worktree split to extract only the public/ directory
    3. Commits and pushes the public/ contents to the gh-pages branch

    The script ensures that generated files in public/ are NEVER committed
    to the master branch - they are isolated to the gh-pages branch only.

REQUIREMENTS:
    - Hugo must be installed (optional, if not present, assumes public/ exists)
    - Git must be configured with a gh-pages branch
    - The repository must be clean (no uncommitted changes)

EXAMPLES:
    $0                    # Build and publish
    $0 --dry-run         # Show what would be done without doing it

EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Check if we're in a git repository
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_error "Not in a git repository. Run this script from the root of your Hugo project."
    exit 1
fi

# Check for uncommitted changes (tracked files only, ignore untracked files)
if git diff-index --quiet HEAD -- && git diff --cached --quiet; then
    # No tracked changes, good to proceed
    :
else
    log_error "You have uncommitted changes. Please commit or stash them before publishing."
    git status
    exit 1
fi

# Check if public/ directory exists
if [[ ! -d "$PUBLIC_DIR" ]]; then
    log_error "The $PUBLIC_DIR directory does not exist. Build your Hugo site first."
    exit 1
fi

# Check if Hugo is available and build the site
if command -v hugo &> /dev/null; then
    log_info "Building Hugo site..."
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "  [DRY RUN] Would execute: hugo"
    else
        hugo
    fi
else
    log_warn "Hugo command not found. Assuming public/ directory already exists."
fi

# Verify public/ directory has content after build
if [[ -z $(ls -A "$PUBLIC_DIR" 2>/dev/null) ]]; then
    log_error "The $PUBLIC_DIR directory is empty. Build may have failed."
    exit 1
fi

log_info "Preparing to publish to '$BRANCH' branch..."

# Check if the branch already exists
if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    BRANCH_EXISTS=1
    log_info "Branch '$BRANCH' exists. Will update it with new content."
else
    BRANCH_EXISTS=0
    log_info "Branch '$BRANCH' does not exist. Will create it."
fi

# Check if there's already a worktree for the branch
if [[ -d "$BRANCH" ]]; then
    log_warn "A directory named '$BRANCH' already exists. This may conflict with the worktree."
    if [[ $DRY_RUN -eq 0 ]]; then
        read -p "Remove existing '$BRANCH' directory? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf "$BRANCH"
        else
            log_error "Cannot proceed with existing '$BRANCH' directory."
            exit 1
        fi
    fi
fi

# Use git worktree to split the public/ directory
# This creates a new worktree containing only the public/ directory contents
# in a separate branch, allowing us to commit only those files

if [[ $DRY_RUN -eq 1 ]]; then
    echo
    log_info "DRY RUN - No changes will be made"
    echo "The following commands would be executed:"
    echo ""
    if [[ $BRANCH_EXISTS -eq 1 ]]; then
        echo "  git worktree remove -f $BRANCH 2>/dev/null || true"
        echo "  git worktree add -B $BRANCH $BRANCH"
    else
        echo "  git worktree add -b $BRANCH $BRANCH"
    fi
    echo "  (in worktree $BRANCH) git rm -rf ."
    echo "  (in worktree $BRANCH) git checkout orphan -- ."
    echo "  (in worktree $BRANCH) cp -r ../$PUBLIC_DIR/. ."
    echo "  (in worktree $BRANCH) git add -A"
    echo "  (in worktree $BRANCH) git commit -m \"Publish site\""
    echo "  git worktree remove -f $BRANCH"
    echo "  git push origin $BRANCH --force"
    echo ""
    exit 0
fi

# Create temporary worktree
TEMP_WORKTREE_DIR="$BRANCH"
if [[ $BRANCH_EXISTS -eq 1 ]]; then
    # Remove existing worktree if it exists
    git worktree remove -f "$TEMP_WORKTREE_DIR" 2>/dev/null || true
    # Checkout the branch and update it
    git worktree add -B "$BRANCH" "$TEMP_WORKTREE_DIR"
else
    # Create new branch with orphan origin (no history)
    git worktree add -b "$BRANCH" "$TEMP_WORKTREE_DIR"
fi

cd "$TEMP_WORKTREE_DIR"

# Remove all existing files in the worktree
log_info "Cleaning worktree directory..."
git rm -rf . 2>/dev/null || true
git clean -fdx 2>/dev/null || true

# Copy all contents from public/ to worktree root
log_info "Copying files from $PUBLIC_DIR/..."
cp -r "../$PUBLIC_DIR"/. .

# Stage all files
git add -A

# Check if there are changes to commit
if git diff --cached --quiet; then
    log_info "No changes detected. Nothing to commit."
else
    # Commit changes
    log_info "Committing changes..."
    git commit -m "Publish site $(date '+%Y-%m-%d %H:%M:%S')" || true
fi

# Return to original directory
cd ..

# Remove worktree (this returns us to the main branch)
log_info "Cleaning up worktree..."
git worktree remove -f "$TEMP_WORKTREE_DIR"

# Push to remote
log_info "Pushing to origin/$BRANCH..."
git push origin "$BRANCH" --force

log_info "Successfully published to $BRANCH branch!"
log_info "Your site should be live at: https://$(git config --get remote.origin.url | sed 's/.*@//;s/:/\//;s/\.git//').github.io/"