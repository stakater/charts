# Rendered by up.sh (envsubst): ${PFX} = first two octets of the kind /16,
# ${FRR_IP} = the FRR peer container. Two pools so BOTH announcement modes get
# exercised and captured: bgp-pool (BGPAdvertisement -> FRR peer, with BFD) and
# l2-pool (L2Advertisement -> ARP on the docker bridge).
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: bgp-pool
  namespace: metallb-system
spec:
  addresses:
    - ${PFX}.250.1-${PFX}.250.50
  autoAssign: true
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: l2-pool
  namespace: metallb-system
spec:
  addresses:
    - ${PFX}.251.1-${PFX}.251.50
  autoAssign: false
---
apiVersion: metallb.io/v1beta1
kind: BFDProfile
metadata:
  name: fast
  namespace: metallb-system
spec:
  receiveInterval: 300
  transmitInterval: 300
  detectMultiplier: 3
---
apiVersion: metallb.io/v1beta2
kind: BGPPeer
metadata:
  name: frr-peer
  namespace: metallb-system
spec:
  myASN: 64513
  peerASN: 64512
  peerAddress: ${FRR_IP}
  bfdProfile: fast
---
apiVersion: metallb.io/v1beta1
kind: BGPAdvertisement
metadata:
  name: bgp-adv
  namespace: metallb-system
spec:
  ipAddressPools:
    - bgp-pool
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2-adv
  namespace: metallb-system
spec:
  ipAddressPools:
    - l2-pool
