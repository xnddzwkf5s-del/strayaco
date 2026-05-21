#!/bin/bash
# Pre-commit hook — block sensitive files from being committed.
# Install: ln -sf ../../scripts/pre-commit-hook.sh .git/hooks/pre-commit

set -euo pipefail

RED='\033[0;31m'
NC='\033[0m'

BLOCKED_EXTENSIONS=(
    "*.sqlite"
    "*.sqlite3"
    "*.db"
    "*.tar.gz"
    "*.tar.bz2"
    "*.tar.xz"
    "*.7z"
    "*.zip"
    "*.pem"
    "*.key"
    "*.p12"
    "*.pfx"
    "*.jks"
    "*.keystore"
)

BLOCKED_PATTERNS=(
    ".env"
    "id_rsa"
    "id_ed25519"
    "id_ecdsa"
    "known_hosts"
    "credentials.json"
    "service-account.json"
)

MAX_FILE_SIZE=$((5 * 1024 * 1024))  # 5MB

violations=()

# Get list of staged files
staged=$(git diff --cached --name-only --diff-filter=ACM)

for file in $staged; do
    basename=$(basename "$file")

    # Check blocked extensions
    for ext in "${BLOCKED_EXTENSIONS[@]}"; do
        if [[ "$basename" == $ext ]]; then
            violations+=("$file — blocked file type ($ext)")
            continue 2
        fi
    done

    # Check blocked patterns (partial match on filename)
    for pat in "${BLOCKED_PATTERNS[@]}"; do
        if [[ "$basename" == *"$pat"* ]]; then
            # Exception: .env.example is OK
            if [[ "$basename" == ".env.example" ]]; then
                continue
            fi
            violations+=("$file — matches blocked pattern ($pat)")
            continue 2
        fi
    done

    # Check file size (skip if deleted or not a regular file)
    if [[ -f "$file" ]]; then
        size=$(wc -c < "$file" 2>/dev/null || echo 0)
        if [[ "$size" -gt "$MAX_FILE_SIZE" ]]; then
            size_mb=$(echo "scale=1; $size / 1048576" | bc)
            violations+=("$file — too large (${size_mb}MB, limit 5MB)")
        fi
    fi
done

if [[ ${#violations[@]} -gt 0 ]]; then
    echo -e "${RED}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  COMMIT BLOCKED — sensitive/large files detected       ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    for v in "${violations[@]}"; do
        echo -e "  ${RED}✗${NC} $v"
    done
    echo ""
    echo "Unstage these files with: git reset HEAD <file>"
    echo "Or add them to .gitignore and retry."
    echo ""
    echo "Blocked: .sqlite .db archives .env .pem .key >5MB"
    exit 1
fi

exit 0
