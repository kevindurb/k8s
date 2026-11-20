# Spec Delta

## Purpose

The cluster's ability to measure its internet uplink on a recurring basis, publish download,
upload, latency and data-use metrics for Prometheus, and raise an alert when a measurement
fails — so uplink degradation is visible without an operator noticing it by hand.

## ADDED Requirements

### Requirement: Periodic uplink measurement

The cluster SHALL measure the internet uplink on a recurring six-hour interval and SHALL keep
the most recent successful result available between measurements, without requiring operator
action to start a test.

#### Scenario: Interval elapses

- **WHEN** six hours have passed since the previous measurement
- **THEN** a new measurement runs automatically and replaces the previously published result

#### Scenario: Between measurements

- **WHEN** a consumer reads the published metrics before the next interval elapses
- **THEN** it receives the most recent completed result rather than a new measurement or a
  partially collected one

#### Scenario: Exporter has just started

- **WHEN** the exporter has not yet completed its first measurement
- **THEN** it publishes no throughput or latency sample rather than reporting zero speed

#### Scenario: A measurement overlaps a scrape

- **WHEN** a metrics scrape arrives while a measurement is running
- **THEN** the scrape either waits for that measurement or fails, and the completed result is
  still published on the next scrape

### Requirement: Published measurement metrics

The system SHALL publish, for each completed measurement, download throughput, upload
throughput, ping latency, jitter, and the volume of data consumed by the measurement, each
expressed in units that need no conversion to be compared with a connection's rated speed.

#### Scenario: Successful measurement

- **WHEN** a measurement completes successfully
- **THEN** download throughput, upload throughput, ping latency, jitter and data used are all
  present in the published metric set

#### Scenario: Failed measurement

- **WHEN** a measurement cannot complete
- **THEN** the failure is reported through a dedicated success indicator and the throughput
  and latency series are not updated with fabricated values

#### Scenario: Assess bandwidth cost

- **WHEN** an operator wants to know what the measurement interval costs on the WAN link
- **THEN** the reported data-used value reflects the volume transferred by the most recent
  measurement

### Requirement: Collection through existing service discovery

Prometheus SHALL collect the measurement metrics through the cluster's existing
service-endpoint discovery, requiring neither a new scrape job nor edits to the existing
scrape configuration.

#### Scenario: Target discovered

- **WHEN** Prometheus runs its service-endpoint discovery cycle
- **THEN** the exporter appears as a target and its metrics are recorded with the namespace
  and service labels the other discovered exporters carry

#### Scenario: Exporter unreachable

- **WHEN** the exporter stops answering scrapes
- **THEN** the target reports itself as down and the existing target-missing alerting covers
  it, rather than the last known values being served indefinitely

### Requirement: Measurement runs without host access

The measurement workload SHALL run without privileged mode, host namespaces, host path
mounts, persistent storage, or a credential, so it satisfies the namespace's standard
baseline pod security enforcement.

#### Scenario: Pod admitted under baseline enforcement

- **WHEN** the namespace enforces the baseline pod security standard
- **THEN** the measurement pod is admitted and runs without privileged access

#### Scenario: Container restart

- **WHEN** the container restarts for any reason
- **THEN** it resumes measurement without needing a volume, secret, or manual preparation

### Requirement: Health check does not consume measurement bandwidth

The cluster's health-check system SHALL verify that the exporter is serving while avoiding
any request that triggers a speed test, so a failing or frequent health check cannot add
WAN traffic.

#### Scenario: Health check passes

- **WHEN** the exporter is serving requests
- **THEN** the health-check endpoint reports the check as healthy in the infrastructure group

#### Scenario: Health check interval elapses

- **WHEN** the health checker probes the exporter on its normal interval
- **THEN** the probe completes without starting or waiting on a speed test

### Requirement: Alert when a measurement fails

The alerting pipeline SHALL raise a warning notification when the most recent measurement
failed, and SHALL clear it only after a subsequent measurement succeeds.

#### Scenario: Measurement fails

- **WHEN** a measurement attempt fails and reports failure
- **THEN** a warning alert fires after its evaluation window

#### Scenario: Measurement recovers

- **WHEN** a later measurement succeeds
- **THEN** the failure alert resolves without operator intervention
