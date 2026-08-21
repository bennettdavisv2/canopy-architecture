#!/usr/bin/env bash
# Wraps site/index.html (authored as a fragment) into a standalone document
# served by GitHub Pages from the repository root. Output: ../index.html
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p ../.pages-tmp
{
  cat <<'HEAD'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="description" content="Canopy — a yield-aggregation protocol on the Movement network. Interactive map of the deployed Move packages, each linking to verified on-chain source.">
<meta property="og:title" content="Canopy Protocol">
<meta property="og:description" content="Interactive map of Canopy's deployed Move packages, each linking to its verified on-chain source.">
<meta property="og:type" content="website">
<link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'><text y='13' font-size='13'>%F0%9F%8C%B2</text></svg>">
HEAD
  cat index.html
  printf '</body>\n</html>\n'
} > ../index.html
# close <head> and open <body> after the inline stylesheet, so <style> stays in <head>
perl -0pi -e 's|</style>|</style>\n</head>\n<body>|' ../index.html
rmdir ../.pages-tmp 2>/dev/null || true
echo "built ../index.html ($(wc -c < ../index.html) bytes)"
