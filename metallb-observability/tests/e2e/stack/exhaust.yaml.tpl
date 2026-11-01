# Scenario S3: a 2-IP pool filled by two Services -> MetalLBAddressPoolExhausted (and
# near-exhaustion at 100%). Rendered by scenarios.sh (envsubst: ${PFX}).
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: tiny-pool
  namespace: metallb-system
spec:
  addresses:
    - ${PFX}.252.1-${PFX}.252.2
  autoAssign: false
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: tiny-adv
  namespace: metallb-system
spec:
  ipAddressPools:
    - tiny-pool
---
apiVersion: v1
kind: Service
metadata:
  name: exhaust-1
  namespace: default
  annotations:
    metallb.io/address-pool: tiny-pool
    metallb.universe.tf/address-pool: tiny-pool
spec:
  type: LoadBalancer
  selector: {app: echo}
  ports: [{port: 80, targetPort: 80}]
---
apiVersion: v1
kind: Service
metadata:
  name: exhaust-2
  namespace: default
  annotations:
    metallb.io/address-pool: tiny-pool
    metallb.universe.tf/address-pool: tiny-pool
spec:
  type: LoadBalancer
  selector: {app: echo}
  ports: [{port: 80, targetPort: 80}]
