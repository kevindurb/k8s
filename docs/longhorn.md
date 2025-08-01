# Longhorn Notes

## Storage Nodes ZFS Setup
```sh
sudo wipefs -a /dev/nvme0n1
sudo zpool create tank -m /var/tank /dev/nvme0n1
sudo zfs create -o mountpoint=/var/lib/longhorn tank/longhorn
```
