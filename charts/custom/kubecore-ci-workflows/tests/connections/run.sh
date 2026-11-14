#!/bin/bash
# CON-02 golden + envFrom tests for the pipeline enhancer (kaos PRD 1034).
# Usage (from the repo root):
#
#   helm template t charts/custom/kubecore-ci-workflows > /tmp/rendered.yaml
#   bash charts/custom/kubecore-ci-workflows/tests/connections/run.sh /tmp/rendered.yaml
#
# Needs python3 with pyyaml and pytest. The pinned pipeline engine (harness.ENGINE_REF of
# kaos-io/kaos-hpc-operator) is fetched from GitHub (GITHUB_TOKEN used when set); set ENGINE_DIR to a local
# `engine/` directory instead. To regenerate after an engine change (read the diff):
#   ENGINE_DIR=<kaos-hpc-operator>/engine ENGINE_PYTHON=<python with engine/requirements.txt> python3 harness.py write-raw
#   ENGINE_DIR=<kaos-hpc-operator>/engine python3 harness.py write-goldens
#   ENGINE_DIR=<kaos-hpc-operator>/engine UPDATE_GOLDEN=1 RENDERED=/tmp/rendered.yaml python3 -m pytest test_step_token.py
# Exit status is pytest's.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
RENDERED="$1" python3 -m pytest -v "${HERE}/test_hera_enhancer.py" "${HERE}/test_harness_cli.py" "${HERE}/test_step_token.py" "${HERE}/test_step_table.py" "${HERE}/test_context_unread.py"
