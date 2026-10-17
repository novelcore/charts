#!/bin/bash
# CON-02 golden + envFrom tests for both pipeline renderers (kaos PRD 1034).
# Usage (from the repo root):
#
#   helm template t charts/custom/kubecore-ci-workflows > /tmp/rendered.yaml
#   bash charts/custom/kubecore-ci-workflows/tests/connections/run.sh /tmp/rendered.yaml
#
# Needs python3 with pyyaml and pytest. The pinned Hera enhancer is fetched from
# GitHub (GITHUB_TOKEN used when set); set ENHANCER_DIR to use a local checkout.
# Exit status is pytest's.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
RENDERED="$1" python3 -m pytest -v "${HERE}/test_render_wft.py" "${HERE}/test_hera_enhancer.py" "${HERE}/test_harness_cli.py"
