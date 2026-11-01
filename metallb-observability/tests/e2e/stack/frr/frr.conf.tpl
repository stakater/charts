! Rendered by up.sh (envsubst): ${KIND_SUBNET} = kind docker network, ${FRR_IP} = this peer.
! The peer accepts BGP from any kind node (dynamic neighbors) and runs BFD on every session.
frr defaults traditional
hostname frr-peer
log stdout informational
!
router bgp 64512
 bgp router-id ${FRR_IP}
 no bgp ebgp-requires-policy
 no bgp network import-check
 neighbor KIND peer-group
 neighbor KIND remote-as 64513
 neighbor KIND bfd
 bgp listen range ${KIND_SUBNET} peer-group KIND
 !
 address-family ipv4 unicast
  neighbor KIND activate
 exit-address-family
!
