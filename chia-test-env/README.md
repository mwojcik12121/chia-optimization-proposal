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

## Run test scenario

Copy product of chia-build-env into `bin/` folder, then run the scenario:

```bash
./run.sh 1
```

The runner checks that Docker exposes at least 8 CPUs and 24 GB RAM and that the host filesystem has at least 750 GB free before it builds or starts the scenario.


## Notes

- It is recommended to build the binaries and run the tests on the same machine.
- Nodes do not have access to the Internet after setup.
- Resource limits vary by role as shown above.
- Logs are exported to `logs/nodeXX_scenarioN_YYYYMMDD_HHMMSS.log`.
