#!/bin/bash

# Website update script for Straya Co
# Usage: ./update.sh "Commit message"

if [ -z "$1" ]; then
    echo "Usage: $0 \"Commit message\""
    exit 1
fi

echo "Updating Straya Co website..."

# Add all changes
git add .

# Commit with provided message
git commit -m "$1"

# Push to GitHub
git push origin main

echo "✅ Website update published!"
echo "Live at: https://www.strayaco.com.au/"
