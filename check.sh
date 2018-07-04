#!/usr/bin/env bash
set -e

# Simple, quick sanity check. Useful as a git pre-commit hook.

find . -name "*.nix" | while read -r F
do
    echo "Checking syntax of '$F'" 1>&2
    nix-instantiate --parse "$F" > /dev/null
done

echo "Evaluating default.nix" 1>&2
nix-instantiate --show-trace default.nix || {
    echo "Couldn't evaluate jobs derivation derivation" 1>&2
    exit 1
}
