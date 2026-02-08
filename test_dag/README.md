# Megabytes DAG – Network & Consensus Stress Tests

This directory contains a full suite of **network, DAG, and consensus stress tests**
used to validate Megabytes Core behavior under real-world failure conditions.

The goal of these tests is to ensure that:
- the DAG converges deterministically,
- consensus remains authoritative under partitions,
- nodes recover correctly after restarts,
- and no invalid or partial state persists.

All tests are designed to run on **regtest**, using **Linux network namespaces (netns)**,
and simulate realistic failure scenarios observed on mainnet-class networks.

---

## Test Environment Overview

- 4 nodes: `mgb1`, `mgb2`, `mgb3`, `mgb4`
- Each node runs in its own **network namespace**
- Custom P2P and RPC ports per node
- Full DAG logic enabled (GhostDAG, blue scoring, DAG DB)
- Tests are deterministic and repeatable

Typical topology:
- Full mesh by default
- Controlled partitions using `iptables` and `tc netem`

---

## Script Index & Purpose

### 01_net_setup.sh  
Initializes Linux network namespaces and virtual interfaces.

- Creates isolated network environments per node
- Assigns static IPs (10.10.0.x)
- Required once per session

---

### 02_run_nodes.sh  
Starts all Megabytes nodes inside their respective namespaces.

- Launches `megabytesd` with correct:
  - datadir
  - bind address
  - P2P port
  - RPC port
- Enables DAG and network debug logs

---

### 03_connect_nodes.sh  
Establishes initial peer connectivity.

- Uses `addnode` to form a full mesh
- Ensures all nodes see each other before testing

---

### 04_badnet.sh  
Applies artificial network degradation.

- Adds latency, jitter, packet loss
- Used to simulate unstable real-world conditions
- Can be cleared later by test scripts

---

### 05_realistic_partition_test.sh  
Simulates a realistic multi-node network partition.

- Full partition between node groups
- Independent mining on each side
- Tests basic reorg and convergence behavior

---

### 05_stop.sh  
Gracefully stops all nodes.

- Cleans up running daemons
- Safe reset point between test runs

---

### 06_dual_miner_race.sh  
Creates a mining race scenario.

- Two sides mine simultaneously
- Produces competing DAG tips
- Stress-tests tip selection and chainwork comparison

---

### 07_check_dual_miner_race.sh  
Verifies correctness after the mining race.

- Ensures:
  - one authoritative tip
  - valid DAG metadata
  - no inconsistent active chains

---

### 08_diag_divergence.sh  
Deep diagnostic script for divergence and convergence.

- Compares:
  - tips
  - last N blocks
  - headers vs blocks
- Confirms that all nodes eventually share the same active history
- Forks in chaintips are allowed, active chain must match

---

### 09_partition_test.sh  
Simple controlled partition test.

- Clean split and reconnect
- Sanity check for reorg logic

---

### 10_partial_partition.sh  
Partial partition test (critical DAG scenario).

- One node (mgb2) is isolated from a subset of peers
- Still connected to at least one honest node
- Mining continues on both sides
- Validates DAG convergence under asymmetric visibility

---

### 11_restart_during_partition.sh  **(“Killer Test”)**

The most aggressive test in the suite.

This test validates that a node can safely restart **while a partition and reorg are in progress**.

Scenario:
- Partial partition is applied
- Both sides mine independently
- `mgb2` is restarted while still partitioned
- Network is reconnected
- Node must:
  - rejoin peers
  - sync the winning chain
  - rebuild DAG state correctly

Validation criteria:
- All nodes converge on the same active tip
- `getdagmeta` on restarted node shows:
  - `has_meta = true`
  - `sp_match = true`
  - `blue_score_match = true`
  - `blue_steps_match = true`
- Flags include:
  - `BLUE_READY`
  - `HAS_SUMMARY`

This test has successfully passed and is considered a **mainnet-grade stress scenario**.

---

## What These Tests Prove

Collectively, these tests demonstrate that:

- DAG selection is deterministic
- Chainwork remains authoritative
- Blue score cannot override work
- Partial visibility does not break consensus
- Restarting a node mid-reorg does not corrupt DAG DB
- No “headers-only” or placeholder state persists
- Nodes recover and converge automatically

---

## What Comes Next

Remaining validation stages (planned / in progress):

1. **ASAN / UBSAN / TSAN**
   - Memory safety
   - Undefined behavior
   - Concurrency correctness

2. **State Sync Torture**
   - Restart during reorg
   - Restart during header download
   - Restart during intense DAG DB writes

3. **Low-Difficulty / Blue Inflation Attack Simulation**
   - Attempted blue-score abuse
   - Verify algo-balance, JSD, finality, and chainwork protections

---

## Notes

- All scripts assume:
  - Linux
  - `ip netns`
  - `iptables`
  - `jq`
- Regtest only (no mainnet data is modified)
- Scripts are intended for **core developers and reviewers**

---

## Summary

This test suite goes far beyond typical blockchain testing.
It validates not only consensus correctness, but **resilience under failure**.

If these tests pass, the system is no longer “theoretically correct” —
it is **battle-tested**.
