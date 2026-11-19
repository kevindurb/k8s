# Spec Delta

## Purpose

The cluster's ability to observe the rack UPS — power draw, battery charge and runtime, and
line status — and to expose that observation to both Home Assistant and Prometheus, without
granting either consumer direct access to the USB device.

## ADDED Requirements

### Requirement: Node advertises an attached UPS

The cluster SHALL publish a node feature label on whichever node the UPS is attached to over
USB, identifying the device well enough for workloads to select that node by hardware
presence rather than by hostname.

#### Scenario: UPS attached to a node

- **WHEN** the UPS is connected to a node's USB port
- **THEN** within one feature-detection interval that node carries a label identifying the
  attached UPS model, sufficient for a workload to select the node by hardware presence

#### Scenario: UPS detached from a node

- **WHEN** the USB cable is removed from a node
- **THEN** that node stops advertising the UPS device label

#### Scenario: UPS moved between nodes

- **WHEN** the cable is moved from one node to another
- **THEN** the label disappears from the original node and appears on the new one, without
  any configuration change

#### Scenario: Device provides no serial number

- **WHEN** the attached device reports an empty USB serial descriptor
- **THEN** the published label is still unique to that device model and does not depend on a
  serial value

### Requirement: Existing hardware-based scheduling is preserved

The cluster SHALL NOT remove a node label that an existing workload's scheduling constraint
depends on when node feature discovery is configured to recognise new hardware.

#### Scenario: A new hardware rule is added

- **WHEN** a rule is added so that NFD recognises an additional device
- **THEN** labels produced for previously recognised hardware remain published

#### Scenario: An existing hardware-pinned workload is rescheduled

- **WHEN** a workload pinned by a hardware label restarts after that rule was added
- **THEN** it is rescheduled onto the node holding its device

### Requirement: UPS variables are served from a stable in-cluster endpoint

The cluster SHALL serve UPS variables over the network from a stable in-cluster Service
endpoint, so that consumers observe the UPS without requiring USB access or node-local
privilege.

#### Scenario: Consumer reads UPS variables over the network

- **WHEN** an in-cluster consumer queries the endpoint on the NUT protocol port
- **THEN** it receives the UPS's current variable set

#### Scenario: Serving pod is rescheduled

- **WHEN** the pod serving UPS variables is replaced or moves to another node
- **THEN** consumers continue to reach it at the same endpoint name without reconfiguration

### Requirement: Home Assistant presents the UPS as a device

Home Assistant SHALL present the UPS as a device whose sensors report at minimum power load,
battery charge, battery runtime, input voltage, output voltage, and line status.

#### Scenario: Sensors populated under normal operation

- **WHEN** the UPS is online and the Home Assistant integration is configured
- **THEN** load, battery charge, battery runtime, input voltage, output voltage and status
  sensors report current values

#### Scenario: Mains power is lost

- **WHEN** the UPS transfers to battery
- **THEN** the status sensor reflects the on-battery state

### Requirement: Prometheus collects UPS metrics via existing discovery

Prometheus SHALL collect UPS metrics through the cluster's existing service-endpoint
discovery, requiring no modification to its scrape configuration.

#### Scenario: UPS metrics are scraped

- **WHEN** Prometheus runs its service-endpoint discovery cycle
- **THEN** UPS metrics including load, battery charge, battery runtime and line status are
  present in the time series store

#### Scenario: Scraped series identify the attached node

- **WHEN** UPS metrics are recorded
- **THEN** their instance label identifies the node the UPS is attached to

#### Scenario: Metrics become unavailable

- **WHEN** the UPS server stops being reachable
- **THEN** the scrape target reports itself as down rather than continuing to return the last
  known values

### Requirement: Alerting covers UPS conditions

The alerting pipeline SHALL raise notifications for transition to battery, low battery,
battery replacement required, overload, load above the configured capacity threshold, and
unavailability of UPS metrics.

#### Scenario: UPS goes on battery

- **WHEN** the UPS transfers from line power to battery
- **THEN** an on-battery alert fires

#### Scenario: UPS metrics disappear

- **WHEN** UPS metrics have been absent for longer than the alerting window
- **THEN** a metrics-unavailable alert fires, distinguishing it from a healthy UPS

#### Scenario: Load exceeds capacity threshold

- **WHEN** reported load exceeds the configured capacity threshold
- **THEN** a capacity alert fires

### Requirement: Power draw is derived and labelled as an estimate

Where the UPS does not report real power, the system SHALL derive watts from the reported
load percentage and the device nameplate rating, SHALL express the derivation in exactly one
place, and SHALL present the result as an estimate rather than a measurement.

#### Scenario: Watts are derived from load

- **WHEN** the UPS reports a non-zero load percentage
- **THEN** a power estimate is produced from that percentage and the nameplate rating

#### Scenario: Energy is accumulated

- **WHEN** the power estimate has been recorded over a period
- **THEN** an accumulated energy figure in kilowatt-hours is available for consumption history

#### Scenario: Load reporting is absent

- **WHEN** the UPS reports zero load indefinitely while carrying a load
- **THEN** that condition is distinguishable from a genuinely idle UPS

### Requirement: NUT driver is configured for known device behaviour

The NUT driver configuration SHALL avoid the known CyberPower USB interrupt-read instability,
and loss of communication with the device SHALL be observable.

#### Scenario: Driver started for a CyberPower device

- **WHEN** the driver is configured for this UPS
- **THEN** it runs in a polling mode with an explicit poll interval rather than relying on USB
  interrupt reads

#### Scenario: Driver loses the device

- **WHEN** the driver stops communicating with the UPS
- **THEN** the loss is visible to both monitoring consumers

### Requirement: NUT credentials are stored as sealed secrets

Credentials required to read UPS variables SHALL be supplied as SealedSecrets. No plaintext
credential SHALL be committed to the repository.

#### Scenario: Secret is provisioned

- **WHEN** the UPS server requires a monitor user credential
- **THEN** a SealedSecret provides it and the decrypted Secret is referenced by the workload
