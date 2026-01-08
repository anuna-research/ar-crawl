#!/bin/bash
set -e

# Get the latest tag (sorted by version number)
latest_tag=$(git tag --sort=-v:refname | head -1)
latest_tag=${latest_tag:-v0.0.0}

# Parse version components
version=${latest_tag#v}
IFS='.' read -r major minor patch <<< "$version"

# Increment based on argument (default: patch)
case "${1:-patch}" in
  major)
    major=$((major + 1))
    minor=0
    patch=0
    ;;
  minor)
    minor=$((minor + 1))
    patch=0
    ;;
  patch)
    patch=$((patch + 1))
    ;;
  *)
    echo "Usage: $0 [major|minor|patch]"
    exit 1
    ;;
esac

new_tag="v${major}.${minor}.${patch}"

echo "Current tag: $latest_tag"
echo "New tag: $new_tag"

git tag -a "$new_tag" -m "Release $new_tag"
git push origin "$new_tag"

echo "Released $new_tag"
