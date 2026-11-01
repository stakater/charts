# Shared helpers for the kind e2e scripts. Source it; don't run it.
# Isolated kubeconfig: never touches the caller's ~/.kube/config or current context.
CLUSTER="metallb-obs-e2e"
export KUBECONFIG="${TMPDIR:-/tmp}/${CLUSTER}.kubeconfig"
CTX="kind-${CLUSTER}"
E2E="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="$(cd "${E2E}/../.." && pwd)"
NS="metallb-system"
FRR="${CLUSTER}-frr"            # the BGP/BFD peer container on the kind docker network
METALLB_CHART_VERSION="0.15.3"  # pinned; bump deliberately and re-capture
# (0.15.2's CRDs fail admission on k8s >=1.34: "Maximum boundary value must be of
#  type integer with format int32" on BGPPeer ASN fields)

red()   { printf "\033[31m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
step()  { printf "\n\033[1m== %s ==\033[0m\n" "$*"; }
k() { kubectl --context "$CTX" "$@"; }
ts() { date -u +%H:%M:%SZ; }

# IPv4 subnet of the kind docker network (the nodes' and the FRR peer's L2 segment).
kind_subnet() {
  docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' | grep -E '^[0-9.]+/[0-9]+$' | head -1
}
frr_ip() { docker inspect "$FRR" -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'; }
vtysh() { docker exec "$FRR" vtysh -c "$*"; }
