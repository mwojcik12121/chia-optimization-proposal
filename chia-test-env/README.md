# Chia test environment

This environment is used to test optimization proposed for Chia.

## Required resources

The setup presented below was based on physical capabilities of the machine used by the author of the optimization proposal.

| CPU | RAM | Free disk |
|:---:|:---:|:---:|
| 8 threads | 24 GB | 750 GB |

## Run test scenario

Copy product of chia-build-env into `bin/` folder, then run the scenario:

```bash
./run.sh 1
```

## Scenario description

### Scenario 1 behavior (example):

1. All eight selected nodes start with empty temporary data directories.
2. They cooperatively create and synchronize the first 200 blocks.
3. The runner confirms a common height-200 tip.
4. Every node logs its current Chia peer connections before partitioning, while partitioned, and after healing.
5. Scenario 1 partitions the network, creates competing branches, heals the partition, verifies the stale branch and reorganization, and converges on the selected chain.
6. `node03` and `node04` mine approximately every six to seven seconds and retain 750 ms egress delay for the complete scenario. `node07` and `node08` retain 1250 ms egress delay for the complete scenario.
7. Node stdout and stderr are exported to `logs/nodeXX_scenario1_YYYYMMDD_HHMMSS.log` before containers are removed.

## Notes

* It is recommended to build the binaries and run the tests on the same machine.
* Nodes do not have access to the Internet after setup.
* Each node uses one CPU and ~3 GB of memory.
* Runtime chain data is temporary and stored on bounded tmpfs mounts.
* Log timestamps use the current Docker host's local time zone. The host's `/etc/localtime` is mounted read-only into each node so Chia and test-harness messages use the same clock.
