#!/usr/bin/env bash
set -euo pipefail
kind delete cluster --name "${CLUSTER:-mto-obs-e2e}"
