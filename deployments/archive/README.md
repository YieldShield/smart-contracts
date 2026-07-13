# Inactive deployment generations

The former `deployments/46630.json` address map was removed from the active manifest
directory on 2026-07-13. It represented Robinhood testnet bytecode deployed before
the schema-v2 promotion, market-session guard, sequencer validation, and runtime
codehash evidence requirements. Its last checked-in contents remain available in Git
at commit `c258095` for forensic reference only.

There is no active Robinhood testnet deployment manifest until an authorized,
funded redeployment of current `main` passes finalization and promotes a new
`deployments/46630.json`. Tools must not bind current ABIs to the archived addresses.

## Arbitrum Sepolia legacy address map

The former `deployments/421614.json` address map was removed from the active manifest
directory on 2026-07-13. It predated schema-v2 promotion and had no checked-in
finality, transaction, runtime-codehash, or finalized-state wiring evidence. Its last
checked-in contents remain available in Git at commit
`51a063f433465dd18636a05bf58319c3c010c818` for forensic reference only; no evidence
has been synthesized for those historical addresses.

There is no active Arbitrum Sepolia deployment manifest until a fresh authorized
deployment passes finalization and promotes a new `deployments/421614.json`. Public
ABI, Ponder, and Pyth address resolution must not bind to the historical address map.
