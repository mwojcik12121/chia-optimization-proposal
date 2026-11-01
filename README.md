# Chia security measure optimization proposal

## Contents
1. Implementation of optimization suggestion (found [here](https://github.com/mwojcik12121/chia-optimization-proposal/tree/main/chia-build-env/src/chia-blockchain-2.7.3-modified))
2. Building environment used to create modified Chia binaries
3. Testing environment used to check optimization's logic and performance
4. Results generated from running tests on both original and modified version of binaries

## Optimization description

timelord_lock execution scope limitation.

## Components' version

* chiabip158: 1.5.4
* chia-blockchain: 2.7.3
* chialisp: 0.5.0
* chiapos: 2.0.12
* chia_puzzles: 0.20.3
* chia_rs: 0.48.0
* chiavdf: 1.1.14
* clvm: 0.9.15
* clvm_rs: 0.19.0
* clvm_tools: 0.4.10


## Notes

* Instructions and specification for each environment are added directly to the environment's directory