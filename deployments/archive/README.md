# Inactive deployment generations

The former `deployments/46630.json` address map was removed from the active manifest
directory on 2026-07-13. It represented Robinhood testnet bytecode deployed before
the schema-v2 promotion, market-session guard, sequencer validation, and runtime
codehash evidence requirements. Its last checked-in contents remain available in Git
at commit `c258095` for forensic reference only.

There is no active Robinhood testnet deployment manifest until an authorized,
funded redeployment of current `main` passes finalization and promotes a new
`deployments/46630.json`. Tools must not bind current ABIs to the archived addresses.
