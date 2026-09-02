# Chia test environment

This environment is used to test optimization proposed for Chia.

## Required resources

The aggregate container limits match the resource budget of the machine used for the optimization proposal.

| Role | Count | CPU each | RAM each | Writable storage each |
|:---|---:|---:|---:|---:|
| Farmer + full node | 4 | 1.0 | 3 GB | 150 GB |
| Timelord | 2 | 1.25 | 3 GB | 37.5 GB |
| External VDF | 2 | 0.75 | 3 GB | 37.5 GB |
| **Declared total** | **8** | **8.0** | **24 GB** | **750 GB** |

GB values are decimal. The storage total covers container writable layers; Docker images, build cache, logs, and host processes require additional physical capacity if every container approaches its limit. The writable-storage limits require a Docker storage driver that supports `storage_opt.size`.

## Run test scenario

Copy product of chia-build-env into `bin/` folder, then run the scenario:

```bash
./run.sh 1
```

The runner checks that Docker exposes at least 8 CPUs and 24 GB RAM and that the host filesystem has at least 750 GB free before it builds or starts the scenario.

## Scenario description

### Scenario 1: exact fork tie-break

1. Four farmer/full-node containers (`node01` through `node04`), two timelords (`node06` and `node07`), and two external VDF-worker containers (`node08` and `node09`) start with empty temporary state. Each timelord runs two local VDF processes and uses one process from its paired external worker, supplying the three concurrent chains Chia requires.
2. Four distinct K25 plots are generated, one per farmer. The private network uses plot-filter bits of zero and a difficulty constant factor of one, making distinct proofs at the same signage point resolve to one required iteration. A production-size VDF discriminant and 32-second sub-slot space the 16 signage points about two seconds apart, giving the capture loop time to freeze exactly one child.
3. The nodes create at least 200 blocks and all four farmer/full nodes synchronize to the same activation-ready peak.
4. The farmers run as a ring of pairs: `01/02`, `02/03`, `03/04`, and `04/01`. Thus every producer participates in two races, while all eight nodes execute every loop iteration and barrier.
5. Each pair is isolated and driven by a separate timelord/VDF group. Both farmers capture exactly one child of the same parent, and the coordinator accepts an attempt only when the blocks have equal weight, equal `total_iters`, distinct hashes, and capture timestamps no more than one second apart.
6. If an attempt does not form an exact near-simultaneous tie, the pair is healed and retried, up to 12 attempts. A missing exact tie fails the scenario.
7. For an exact tie, the coordinator reads both persisted fork-order keys, predicts the lowest lexicographic key (with header hash only as a collision fallback), connects the competing full nodes, and requires the predicted losing node to converge to that block.
8. The full-node mesh is restored and all four full nodes must converge before the next attempt. Logs include both keys, both producer nodes, the selected node, and the capture-time gap.
9. Existing `logs/*.log` files are cleared at run start. Current stdout and stderr are exported to `logs/nodeXX_scenario1_YYYYMMDD_HHMMSS.log` before containers are removed.

## Notes

* It is recommended to build the binaries and run the tests on the same machine.
* Nodes do not have access to the Internet after setup.
* Resource limits vary by role as shown above.
* Runtime chain data is temporary and stored in bounded ephemeral container writable layers; `/tmp` is a size-limited tmpfs.
* Log timestamps use the current Docker host's local time zone. The host's `/etc/localtime` is mounted read-only into each node so Chia and test-harness messages use the same clock.
