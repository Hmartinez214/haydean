# Pre-deployment survey

State of the cluster before any BeeGFS changes. Recorded so the previous
configuration can be reconstructed if the migration is rolled back.

Addresses are placeholders; real values are in the gitignored
`docs/survey-raw.txt`.

## Operating system

All nodes:

```
PRETTY_NAME="Ubuntu 26.04 LTS"
VERSION_CODENAME=resolute
kernel 7.0.0-28-generic   (7.0.0-29-generic staged)
```

BeeGFS is not in the Ubuntu archive. The upstream repo publishes a `resolute`
suite, so no distribution backport was needed.

## Storage before

```
login    /dev/sda2  ext4  1.8T   57G used   4%   /
node1    /dev/sda2  ext4  218G   36G used  18%   /
node1    /dev/sdb   111.8G, no filesystem signature, unused
node2    /dev/sdb   111.8G, no filesystem signature, unused
node3    /dev/sdb   111.8G, no filesystem signature, unused
node4    /dev/sdb   111.8G, no filesystem signature, unused
gpu      /dev/sda   465.8G
gpu      /dev/sdb   931.5G
```

The four unused second disks are what the BeeGFS storage pool was built from.

## NFS before

Two exports, both served over the cluster segment:

```
login:/home      -> mounted by node1, node2, node3, node4, gpu
node1:/shared    -> mounted by node2, node3, node4
```

`/home` is backed by the login node's root filesystem, and the shared export
is backed by node1's root filesystem. Neither had a dedicated volume.

Export options were permissive and worth reviewing independently of this
migration; see the local raw survey for specifics.

## Network before

```
login   eno1     1000Mb/s   up
login   eno2                no carrier
node1-4 enp1s0   1000Mb/s   up
node1-4 eno1     eno2       no carrier
gpu     enp5s0   1000Mb/s   up, different subnet, routed to cluster
gpu     eno1     1000Mb/s   carrier but no IPv4 configured
```

Every node also runs Tailscale with a `tailscale0` interface up. The GPU node
was reaching the cluster over Tailscale despite having a routed path at
0.31 ms, which is why interface pinning is part of this deployment.

The GPU node's second NIC is physically connected to the cluster segment and
DHCP offers a lease there, but netplan had the interface set to `accept-ra`
only with no `dhcp4`, so it never requested an address.

## Scheduler

```
slurmctld, slurmdbd, munge running on login
partitions: 4 compute nodes at 12 CPUs each, 1 GPU node at 4 CPUs
all nodes idle at time of survey
```

Nodes being idle is why the migration window was taken when it was.
