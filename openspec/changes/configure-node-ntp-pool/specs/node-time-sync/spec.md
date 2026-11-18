# Spec Delta

## Purpose

Defines how the cluster nodes obtain and maintain accurate system time from the public NTP Pool, so the Kubernetes control plane and workloads share a common, reliable clock.

## ADDED Requirements

### Requirement: Nodes synchronize from the NTP Pool

Every cluster node SHALL run a time synchronization service configured to use the NTP Pool as its time source. The configuration MUST use no more than four upstream servers and MUST keep the clock disciplined continuously, including after a node reboot.

#### Scenario: Node reports synchronized time

- **WHEN** a node has been up with network access for at least five minutes
- **THEN** its clock is synchronized to an NTP Pool server with no manual intervention
- **AND** the system reports the clock as synchronized

#### Scenario: Upstream server limit is respected

- **WHEN** the time configuration baked into the node image is inspected
- **THEN** it names no more than four upstream NTP servers or a single pool that resolves to at most four

#### Scenario: Clock recovers after network loss

- **WHEN** a node boots while the network or upstream NTP service is unavailable
- **THEN** the node starts its time service without failing boot
- **AND** it resumes synchronization once the network returns

### Requirement: Time configuration ships with the node image

The provisioned node image SHALL contain the NTP Pool time configuration and SHALL enable the time synchronization service at boot, so a newly provisioned node requires no manual time configuration.

#### Scenario: Freshly provisioned node is synchronized

- **WHEN** a node is installed from the current image and boots
- **THEN** the time synchronization service is enabled and active
- **AND** no post-boot configuration is needed to reach synchronization

#### Scenario: Image update carries the configuration

- **WHEN** an existing node updates to an image containing this change and reboots
- **THEN** the node's effective time configuration uses the NTP Pool
- **AND** the time service is active after the reboot

### Requirement: No LAN time service is introduced

The change SHALL NOT make nodes serve time to other machines. NTP client configuration alone SHALL be provided, and no node SHALL accept inbound NTP requests from the LAN as part of this capability.

#### Scenario: Node does not serve time to the LAN

- **WHEN** another LAN host queries a cluster node for time
- **THEN** the node does not provide a time service response attributable to this change
