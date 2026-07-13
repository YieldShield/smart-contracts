const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const test = require("node:test");

const root = join(__dirname, "..", "..");
const workflow = readFileSync(
    join(root, ".github", "workflows", "ci.yml"),
    "utf8",
);
const oracleFork = readFileSync(join(root, "test", "OracleFork.t.sol"), "utf8");
const arbitrumFork = readFileSync(
    join(root, "test", "ArbitrumOracleFork.t.sol"),
    "utf8",
);
const robinhoodFork = readFileSync(
    join(root, "test", "RobinhoodMainnetFork.t.sol"),
    "utf8",
);
const forkHelper = readFileSync(
    join(root, "test", "helpers", "ForkTestHelper.sol"),
    "utf8",
);
const packageJson = JSON.parse(
    readFileSync(join(root, "package.json"), "utf8"),
);

const forkJob = workflow.slice(
    workflow.indexOf("  fork-tests:"),
    workflow.indexOf("  contract-size:"),
);
const arbitrumForkJob = workflow.slice(
    workflow.indexOf("  arbitrum-public-fork-smokes:"),
    workflow.indexOf("  fork-tests:"),
);

test("Ethereum fork suites are independently gated", () => {
    assert.match(forkJob, /if: github\.event_name == 'push'/u);
    assert.match(forkJob, /mainnet_available=true/u);
    assert.match(forkJob, /sepolia_available=true/u);
    assert.match(
        forkJob,
        /if: steps\.ethereum-fork-rpcs\.outputs\.mainnet_available == 'true'/u,
    );
    assert.match(
        forkJob,
        /if: steps\.ethereum-fork-rpcs\.outputs\.sepolia_available == 'true'/u,
    );
    assert.doesNotMatch(forkJob, /\[ -n "\$MAINNET_RPC_URL" \] &&/u);
});

test("Arbitrum public fork smokes run before merge against official RPCs", () => {
    assert.doesNotMatch(arbitrumForkJob, /if: github\.event_name == 'push'/u);
    assert.match(arbitrumForkJob, /actions\/setup-node@/u);
    assert.match(arbitrumForkJob, /run: npm ci/u);
    assert.ok(
        arbitrumForkJob.indexOf("run: npm ci") <
            arbitrumForkJob.indexOf(
                "forge test --match-contract ArbitrumOracleForkTest -vv",
            ),
        "Node.js dependencies must be installed before compiling the fork smoke",
    );
    assert.match(arbitrumForkJob, /FORK_TESTS_ENABLED: "true"/u);
    assert.match(arbitrumForkJob, /FORK_TESTS_REQUIRED: "true"/u);
    assert.match(arbitrumForkJob, /https:\/\/arb1\.arbitrum\.io\/rpc/u);
    assert.match(
        arbitrumForkJob,
        /https:\/\/sepolia-rollup\.arbitrum\.io\/rpc/u,
    );
    assert.match(
        arbitrumForkJob,
        /forge test --match-contract ArbitrumOracleForkTest -vv/u,
    );

    assert.match(arbitrumFork, /PythConfig\.ARBITRUM_MAINNET_CHAIN_ID/u);
    assert.match(arbitrumFork, /PythConfig\.ARBITRUM_SEPOLIA_CHAIN_ID/u);
    assert.match(arbitrumFork, /getValidTimePeriod\(\)/u);
    assert.match(arbitrumFork, /getUpdateFee\(noUpdates\)/u);
    assert.match(arbitrumFork, /PythErrors\.PriceFeedNotFound\.selector/u);
    assert.match(arbitrumFork, /sequencer\.latestRoundData\(\)/u);
    assert.match(
        arbitrumFork,
        /PythConfig\.ARBITRUM_MAINNET_SEQUENCER_UPTIME_FEED/u,
    );
    assert.match(
        arbitrumFork,
        /oracle\.setSequencerUptimeFeedRequired\(false\)/u,
    );
    assert.match(
        arbitrumFork,
        /address\(oracle\.sequencerUptimeFeed\(\)\), address\(0\)/u,
    );
});

test("RPC configuration alone cannot enable live fork tests", () => {
    assert.match(forkHelper, /vm\.envOr\("FORK_TESTS_ENABLED", required\)/u);
    assert.match(forkHelper, /if \(!enabled\)/u);
    assert.match(
        packageJson.scripts["test:fork"],
        /^FORK_TESTS_ENABLED=true FORK_TESTS_REQUIRED=true /u,
    );

    const enabledCount =
        forkJob.match(/FORK_TESTS_ENABLED: "true"/gu)?.length ?? 0;
    const requiredCount =
        forkJob.match(/FORK_TESTS_REQUIRED: "true"/gu)?.length ?? 0;
    assert.equal(enabledCount, 3);
    assert.equal(requiredCount, 3);
});

test("Robinhood mainnet fork smoke is mandatory and has the official public fallback", () => {
    assert.match(forkJob, /Run required Robinhood mainnet fork smoke test/u);
    assert.match(forkJob, /FORK_TESTS_REQUIRED: "true"/u);
    assert.match(forkJob, /https:\/\/rpc\.mainnet\.chain\.robinhood\.com/u);
    assert.match(
        forkJob,
        /forge test --match-contract RobinhoodMainnetForkTest/u,
    );
    assert.doesNotMatch(forkJob, /RobinhoodTestnetForkTest/u);

    assert.match(robinhoodFork, /ROBINHOOD_MAINNET_CHAIN_ID = 4_663/u);
    assert.match(
        robinhoodFork,
        /IRobinhoodStockToken\.oraclePaused\.selector/u,
    );
    assert.match(
        robinhoodFork,
        /TSLA_USD_FEED = 0x4A1166a659A55625345e9515b32adECea5547C38/u,
    );
    assert.match(robinhoodFork, /supportsStrictProtectedPrice/u);
    assert.match(robinhoodFork, /AlwaysClosedMarketSessionGate/u);
    assert.match(robinhoodFork, /market closure changed feed staleness/u);
    assert.match(robinhoodFork, /if \(oraclePaused\)/u);
    assert.match(robinhoodFork, /if \(isStale\)/u);
});

test("Sepolia Pyth fork accepts only the protocol stale-price selector", () => {
    assert.match(oracleFork, /catch \(bytes memory reason\)/u);
    assert.match(oracleFork, /PythOracle\.StalePrice\.selector/u);
    assert.doesNotMatch(oracleFork, /catch \{/u);
});
