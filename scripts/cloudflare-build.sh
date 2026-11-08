#!/usr/bin/env bash
# Build step for the geog215.org Worker (Cloudflare Workers Builds).
# Run by `npx wrangler deploy` through build.command in wrangler.jsonc.
#
# Cloudflare's build image has no Quarto, so install a pinned version, then
# render the gated book (geog215 profile adds the Supabase sign-in gate) into
# _book/, which wrangler uploads. No R needed: code results come from _freeze/.
set -euo pipefail

QUARTO_VERSION="1.11.9"   # keep in step with the GitHub Action's Quarto

if ! command -v quarto >/dev/null 2>&1; then
  dir="${TMPDIR:-/tmp}/quarto-${QUARTO_VERSION}"
  if [ ! -x "${dir}/bin/quarto" ]; then
    echo "Installing Quarto ${QUARTO_VERSION}..."
    mkdir -p "${dir}"
    curl -fsSL "https://github.com/quarto-dev/quarto-cli/releases/download/v${QUARTO_VERSION}/quarto-${QUARTO_VERSION}-linux-amd64.tar.gz" \
      | tar -xz -C "${dir}" --strip-components=1
  fi
  export PATH="${dir}/bin:${PATH}"
fi

quarto --version
quarto render --to html --profile geog215

# Instructor admin page (geog215.org/admin/). Copied in only here, so it is
# never part of the public daveparr.com copy rendered by the GitHub Action.
rm -rf _book/admin
cp -R admin _book/admin
