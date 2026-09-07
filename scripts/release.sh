#!/bin/sh

set -eu

release_usage() {
    echo "Usage: scripts/release.sh X.Y.Z [--push]" >&2
    exit 2
}

release_version=${1:-}
release_action=${2:-}

if ! printf '%s\n' "$release_version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    release_usage
fi

case "$release_action" in
    ""|--push) ;;
    *) release_usage ;;
esac

if [ "$#" -gt 2 ]; then
    release_usage
fi

release_script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
release_repo_dir=$(dirname -- "$release_script_dir")

cd "$release_repo_dir"

if [ "$(git branch --show-current)" != "main" ]; then
    echo "Release must be made from main." >&2
    exit 1
fi

if [ -n "$(git status --short)" ]; then
    echo "Release requires a clean working tree." >&2
    exit 1
fi

if ! git rev-parse --verify '@{upstream}' >/dev/null 2>&1; then
    echo "main must have an upstream before release." >&2
    exit 1
fi

if [ "$(git rev-parse HEAD)" != "$(git rev-parse '@{upstream}')" ]; then
    echo "Push main and make sure it matches its upstream before release." >&2
    exit 1
fi

if git rev-parse --verify --quiet "refs/tags/$release_version" >/dev/null; then
    if [ "$release_action" = "--push" ]; then
        if [ "$(git rev-list -n 1 "$release_version")" != "$(git rev-parse HEAD)" ]; then
            echo "Existing tag $release_version does not point at HEAD; refusing to publish it." >&2
            exit 1
        fi
        git push origin "refs/tags/$release_version"
        exit 0
    fi

    echo "Tag $release_version already exists locally." >&2
    exit 1
fi

if ! grep -Fq "exact: \"$release_version\"" README.md; then
    echo "Update the README installation example to exact: \"$release_version\" and commit it first." >&2
    exit 1
fi

"$release_script_dir/verify.sh"

git tag -a "$release_version" -m "Quagmire $release_version"
echo "Created annotated tag $release_version at $(git rev-parse --short HEAD)."

if [ "$release_action" = "--push" ]; then
    git push origin "refs/tags/$release_version"
else
    echo "Inspect it with: git show $release_version"
    echo "Publish it with: scripts/release.sh $release_version --push"
fi
