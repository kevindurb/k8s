# Kubernetes Cluster Hardware Inventory

This document provides a comprehensive hardware inventory of all nodes in the Kubernetes cluster.

## Cluster Overview

| Node | Role | IP Address | Internal IP | OS | CPU | Memory | Primary Storage |
|------|------|------------|-------------|----|----|--------|----------------|
| kube-big-01 | Worker | 192.168.0.55 | 100.83.110.81 | Fedora CoreOS 42.20250623.3.1 | AMD Ryzen 7 2700 (8 cores) | 15GB | 111.8GB SSD |
| kube-master-01 | Control Plane | 192.168.0.94 | 100.97.38.47 | Fedora CoreOS 42.20250623.3.1 | Intel i5-3210M (2 cores) | 15GB | 238.5GB SSD |
| kube-master-02 | Control Plane | 192.168.0.153 | 100.122.123.119 | Fedora CoreOS 42.20250623.3.1 | Intel i5-3210M (2 cores) | 15GB | 223.6GB SSD |
| kube-master-03 | Control Plane | 192.168.0.202 | 100.123.21.88 | Fedora CoreOS 42.20250623.3.1 | Intel i5-3210M (2 cores) | 15GB | 238.5GB SSD |
| kube-storage-01 | Worker | 192.168.0.41 | 100.101.83.66 | Fedora CoreOS 42.20250623.3.1 | Intel i5-4590 (4 cores) | 15GB | 223.6GB SSD + 476.9GB NVMe |
| kube-storage-02 | Worker | 192.168.0.38 | 100.93.95.94 | Fedora CoreOS 42.20250623.3.1 | Intel i5-4590 (4 cores) | 7.4GB | 55.9GB SSD + 476.9GB NVMe |
| kube-storage-03 | Worker | 192.168.0.134 | 100.87.45.82 | Fedora CoreOS 42.20250623.3.1 | Intel i5-4590 (4 cores) | 15GB | 953.9GB SSD + 476.9GB NVMe |

---

## Node Details

### kube-big-01 (Worker Node)
**Role**: Worker Node  
**IP**: 192.168.0.55 (Internal: 100.83.110.81)  
**OS**: Fedora CoreOS 42.20250623.3.1 (uCore minimal)  
**Kernel**: 6.14.11-300.fc42.x86_64  
**Container Runtime**: containerd://2.0.5-k3s1.32  

#### Hardware Specifications
- **CPU**: AMD Ryzen 7 2700 Eight-Core Processor
  - Architecture: x86_64
  - Cores: 8 cores, 1 thread per core
  - Base Clock: 3.2 GHz
  - Cache: L1d: 256 KiB, L1i: 512 KiB, L2: 4 MiB, L3: 16 MiB
  - Virtualization: AMD-V
- **Memory**: 15GB RAM + 4GB Swap (zram)
- **Storage**: 
  - Primary: 111.8GB SSD (sda)
  - Optical: 44.1GB (sr0) + 1024MB (sr1)
- **Network**: 
  - Ethernet: enp4s0 (192.168.0.55/16)
  - Tailscale: tailscale0 (100.83.110.81/32)
  - Flannel: flannel.1 (10.42.6.0/32)
  - CNI: cni0 (10.42.6.1/24)

---

### kube-master-01 (Control Plane)
**Role**: Control Plane, etcd, master  
**IP**: 192.168.0.94 (Internal: 100.97.38.47)  
**OS**: Fedora CoreOS 42.20250623.3.1 (uCore minimal)  
**Kernel**: 6.14.11-300.fc42.x86_64  
**Container Runtime**: containerd://2.0.5-k3s1.32  
**Hardware Model**: Mac Mini 6,1 (2012) ⚠️ **11+ Years Old**

#### Hardware Specifications
- **CPU**: Intel Core i5-3210M @ 2.50GHz
  - Architecture: x86_64
  - Cores: 2 cores, 1 thread per core
  - Max Clock: 3.1 GHz
  - Cache: L1d: 64 KiB, L1i: 64 KiB, L2: 512 KiB, L3: 3 MiB
  - Virtualization: VT-x
- **Memory**: 15GB RAM + 4GB Swap (zram)
- **Storage**: 238.5GB SSD (sda)
- **Network**: 
  - Ethernet: enp1s0f0 (192.168.0.94/16)
  - Tailscale: tailscale0 (100.97.38.47/32)
  - Flannel: flannel.1 (10.42.0.0/32)

#### Notable Hardware
- Thunderbolt Controller (Cactus Ridge 4C 2012)
- Broadcom NetXtreme Gigabit Ethernet
- Broadcom BCM4331 802.11n WiFi
- FireWire (IEEE 1394) Controller

#### Reliability Issues
- **Recent Crash**: System crashed on July 18, 2025 around 00:24 UTC
- **Age Concern**: 11+ year old hardware, well beyond typical server lifespan
- **Risk**: Potential for age-related hardware failures (power supply, thermal, capacitors)

---

### kube-master-02 (Control Plane)
**Role**: Control Plane, etcd, master  
**IP**: 192.168.0.153 (Internal: 100.122.123.119)  
**OS**: Fedora CoreOS 42.20250623.3.1 (uCore minimal)  
**Kernel**: 6.14.11-300.fc42.x86_64  
**Container Runtime**: containerd://2.0.5-k3s1.32  
**Hardware Model**: Mac Mini 6,1 (2012) ⚠️ **11+ Years Old**

#### Hardware Specifications
- **CPU**: Intel Core i5-3210M @ 2.50GHz
  - Architecture: x86_64
  - Cores: 2 cores, 1 thread per core
  - Max Clock: 3.1 GHz
  - Cache: L1d: 64 KiB, L1i: 64 KiB, L2: 512 KiB, L3: 3 MiB
  - Virtualization: VT-x
- **Memory**: 15GB RAM + 4GB Swap (zram)
- **Storage**: 223.6GB SSD (sda)
- **Network**: 
  - Ethernet: enp1s0f0 (192.168.0.153/16)
  - Tailscale: tailscale0 (100.122.123.119/32)
  - Flannel: flannel.1 (10.42.1.0/32)
  - CNI: cni0 (10.42.1.1/24)

#### Notable Hardware
- Thunderbolt Controller (Cactus Ridge 4C 2012)
- Broadcom NetXtreme Gigabit Ethernet
- Broadcom BCM4331 802.11n WiFi
- FireWire (IEEE 1394) Controller

---

### kube-master-03 (Control Plane)
**Role**: Control Plane, etcd, master  
**IP**: 192.168.0.202 (Internal: 100.123.21.88)  
**OS**: Fedora CoreOS 42.20250623.3.1 (uCore minimal)  
**Kernel**: 6.14.11-300.fc42.x86_64  
**Container Runtime**: containerd://2.0.5-k3s1.32  
**Hardware Model**: Mac Mini 6,1 (2012) ⚠️ **11+ Years Old**

#### Hardware Specifications
- **CPU**: Intel Core i5-3210M @ 2.50GHz
  - Architecture: x86_64
  - Cores: 2 cores, 1 thread per core
  - Max Clock: 3.1 GHz
  - Cache: L1d: 64 KiB, L1i: 64 KiB, L2: 512 KiB, L3: 3 MiB
  - Virtualization: VT-x
- **Memory**: 15GB RAM + 4GB Swap (zram)
- **Storage**: 238.5GB SSD (sda)
- **Network**: 
  - Ethernet: enp1s0f0 (192.168.0.202/16)
  - Tailscale: tailscale0 (100.123.21.88/32)
  - Flannel: flannel.1 (10.42.2.0/32)
  - CNI: cni0 (10.42.2.1/24)

#### Notable Hardware
- Thunderbolt Controller (Cactus Ridge 4C 2012)
- Broadcom NetXtreme Gigabit Ethernet
- Broadcom BCM4331 802.11n WiFi
- FireWire (IEEE 1394) Controller

---

### kube-storage-01 (Worker Node)
**Role**: Worker Node  
**IP**: 192.168.0.41 (Internal: 100.101.83.66)  
**OS**: Fedora CoreOS 42.20250623.3.1 (uCore minimal)  
**Kernel**: 6.14.11-300.fc42.x86_64  
**Container Runtime**: containerd://2.0.5-k3s1.32  

#### Hardware Specifications
- **CPU**: Intel Core i5-4590 @ 3.30GHz
  - Architecture: x86_64
  - Cores: 4 cores, 1 thread per core
  - Max Clock: 3.7 GHz
  - Cache: L1d: 128 KiB, L1i: 128 KiB, L2: 1 MiB, L3: 6 MiB
  - Virtualization: VT-x
- **Memory**: 15GB RAM + 4GB Swap (zram)
- **Storage**: 
  - Primary: 223.6GB SSD (sda)
  - NVMe: 476.9GB NVMe SSD (nvme0n1) - MAXIO Technology MAP1202
- **Network**: 
  - Ethernet: enp0s25 (192.168.0.41/16) - Intel I218-V
  - Tailscale: tailscale0 (100.101.83.66/32)
  - Flannel: flannel.1 (10.42.3.0/32)
  - CNI: cni0 (10.42.3.1/24)

#### Notable Hardware
- Intel H97 Chipset
- 9 Series Chipset Family controllers
- ASMedia PCIe to PCI Bridge

---

### kube-storage-02 (Worker Node)
**Role**: Worker Node  
**IP**: 192.168.0.38 (Internal: 100.93.95.94)  
**OS**: Fedora CoreOS 42.20250623.3.1 (uCore minimal)  
**Kernel**: 6.14.11-300.fc42.x86_64  
**Container Runtime**: containerd://2.0.5-k3s1.32  

#### Hardware Specifications
- **CPU**: Intel Core i5-4590 @ 3.30GHz
  - Architecture: x86_64
  - Cores: 4 cores, 1 thread per core
  - Max Clock: 3.7 GHz
  - Cache: L1d: 128 KiB, L1i: 128 KiB, L2: 1 MiB, L3: 6 MiB
  - Virtualization: VT-x
- **Memory**: 7.4GB RAM + 3.7GB Swap (zram) ⚠️ **Lower Memory**
- **Storage**: 
  - Primary: 55.9GB SSD (sda) ⚠️ **Smaller Primary Storage**
  - NVMe: 476.9GB NVMe SSD (nvme0n1) - MAXIO Technology MAP1202
- **Network**: 
  - Ethernet: enp0s25 (192.168.0.38/16) - Intel I218-V
  - Tailscale: tailscale0 (100.93.95.94/32)
  - Flannel: flannel.1 (10.42.5.0/32)
  - CNI: cni0 (10.42.5.1/24)

#### Notable Hardware
- Intel H97 Chipset
- 9 Series Chipset Family controllers
- ASMedia PCIe to PCI Bridge

---

### kube-storage-03 (Worker Node)
**Role**: Worker Node  
**IP**: 192.168.0.134 (Internal: 100.87.45.82)  
**OS**: Fedora CoreOS 42.20250623.3.1 (uCore minimal)  
**Kernel**: 6.14.11-300.fc42.x86_64  
**Container Runtime**: containerd://2.0.5-k3s1.32  

#### Hardware Specifications
- **CPU**: Intel Core i5-4590 @ 3.30GHz
  - Architecture: x86_64
  - Cores: 4 cores, 1 thread per core
  - Max Clock: 3.7 GHz
  - Cache: L1d: 128 KiB, L1i: 128 KiB, L2: 1 MiB, L3: 6 MiB
  - Virtualization: VT-x
- **Memory**: 15GB RAM + 4GB Swap (zram)
- **Storage**: 
  - Primary: 953.9GB SSD (sda) ⭐ **Largest Primary Storage**
  - NVMe: 476.9GB NVMe SSD (nvme0n1) - MAXIO Technology MAP1202
- **Network**: 
  - Ethernet: enp0s25 (192.168.0.134/16) - Intel I218-V
  - Tailscale: tailscale0 (100.87.45.82/32)
  - Flannel: flannel.1 (10.42.4.0/32)
  - CNI: cni0 (10.42.4.1/24)

#### Notable Hardware
- Intel H97 Chipset
- 9 Series Chipset Family controllers
- ASMedia PCIe to PCI Bridge

---

## Cluster Summary

### Total Resources
- **Total CPU Cores**: 30 cores (8 AMD + 22 Intel)
- **Total Memory**: 102.4GB RAM
- **Total Storage**: 2.5TB+ across all nodes
- **Node Count**: 7 nodes (3 control plane, 4 worker)

### CPU Distribution
- **AMD**: 1 node (kube-big-01) with Ryzen 7 2700 (8 cores)
- **Intel 3rd Gen**: 3 nodes (masters) with i5-3210M (2 cores each)
- **Intel 4th Gen**: 3 nodes (storage) with i5-4590 (4 cores each)

### Memory Distribution
- **15GB**: 6 nodes
- **7.4GB**: 1 node (kube-storage-02) ⚠️

### Storage Distribution
- **Primary Storage**: Ranges from 55.9GB to 953.9GB
- **NVMe Storage**: 476.9GB on all storage nodes
- **Additional Storage**: Available NVMe drives for distributed storage

### Network Configuration
- **LAN Network**: 192.168.0.0/16 subnet
- **Tailscale VPN**: 100.x.x.x/32 addresses for secure access
- **Flannel CNI**: 10.42.x.0/24 pod networks
- **Container Runtime**: containerd 2.0.5-k3s1.32 across all nodes

### Operating System
- **OS**: Fedora CoreOS 42.20250623.3.1 (uCore minimal)
- **Kernel**: 6.14.11-300.fc42.x86_64
- **K8s Version**: v1.32.6+k3s1

---

## Notes and Recommendations

### Performance Considerations
1. **kube-big-01** has the most powerful CPU (AMD Ryzen 7 2700) - ideal for compute-intensive workloads
2. **kube-storage-02** has limited memory (7.4GB) - consider memory-conscious scheduling
3. **Storage nodes** have additional NVMe drives perfect for Longhorn distributed storage

### Hardware Observations
1. All master nodes are identical **Mac Mini 6,1 (2012)** hardware (Intel i5-3210M)
2. All storage nodes are identical desktop hardware (Intel i5-4590)
3. kube-big-01 stands out as a more powerful desktop system
4. Consistent network setup with Tailscale VPN across all nodes
5. **Age Concern**: Mac Mini nodes are 11+ years old, well beyond typical server lifespan

### Potential Issues
- **kube-storage-02** has significantly less memory and primary storage
- Some nodes show offline CPU cores (likely power management)
- All nodes are running the same uCore minimal OS image
- **Mac Mini Age**: 11+ year old hardware poses reliability risks
  - **kube-master-01** recently crashed (July 18, 2025)
  - Risk of age-related failures: power supplies, thermal management, capacitors
  - Consider replacement or treating as potentially unreliable

### Reliability Recommendations
1. **Monitor Mac Mini nodes closely** for stability patterns
2. **Plan hardware replacement** for the aging Mac Mini control plane
3. **Consider hardware refresh** to newer, more reliable equipment
4. **Implement proper monitoring** for temperature and hardware health
5. **Ensure proper maintenance** - clean dust, check ventilation