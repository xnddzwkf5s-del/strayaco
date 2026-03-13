#!/bin/bash

# Step 1: Generate new content with OpenClaw
echo "Generating content with OpenClaw..."
openclaw "Create a blog post about the impact of renewable energy on global economies."

# Step 2: Move the generated content to Jekyll's _posts folder
echo "Moving the generated content to _posts folder..."
mv generated_content.md _posts/$(date +'%Y-%m-%d')-renewable-energy-impact.md

# Step 3: Add, commit, and push to GitHub
echo "Adding, committing, and pushing to GitHub..."
git add _posts/*
git commit -m "Add new blog post about renewable energy"
git push origin master

# Step 4: Confirmation
echo "Deployment complete! The content has been published to GitHub."
