const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const { test } = require("node:test");

function artifactWithSizes(runtimeSize, initcodeSize) {
    return {
        bytecode: { object: `0x${"00".repeat(initcodeSize)}` },
        deployedBytecode: { object: `0x${"00".repeat(runtimeSize)}` },
    };
}

test("production deployment source and size inventory stay in sync", async () => {
    const { PRODUCTION_DEPLOYMENT_TARGETS, validateTargetInventory } =
        await import("../checkDeploymentTargetSizes.js");
    const source = readFileSync(
        join(
            __dirname,
            "..",
            "..",
            "script",
            "DeployYieldShieldProduction.s.sol",
        ),
        "utf8",
    );

    assert.deepEqual(
        validateTargetInventory(source),
        Object.keys(PRODUCTION_DEPLOYMENT_TARGETS).sort(),
    );
});

test("CI enforces the exact Robinhood deployment target inventory", () => {
    const workflow = readFileSync(
        join(__dirname, "..", "..", ".github", "workflows", "ci.yml"),
        "utf8",
    );
    const contractSizeJob = workflow.slice(
        workflow.indexOf("  contract-size:"),
        workflow.indexOf("  coverage:"),
    );

    assert.match(
        contractSizeJob,
        /run: npm run size-check:robinhood-deployment/u,
    );
});

test("target inventory extraction ignores arrays, comments, and strings", async () => {
    const { extractConstructedContractNames } =
        await import("../checkDeploymentTargetSizes.js");
    const source = `
        // new IgnoredComment()
        string memory text = "new IgnoredString()";
        address[] memory accounts = new address[](0);
        uint256[] memory values = new uint256[](1);
        Foo foo = new Foo();
        Bar bar = new Bar(1);
    `;

    assert.deepEqual(extractConstructedContractNames(source), ["Bar", "Foo"]);
});

test("target inventory fails closed for missing and unused entries", async () => {
    const { validateTargetInventory } =
        await import("../checkDeploymentTargetSizes.js");
    const source = "Foo foo = new Foo(); Bar bar = new Bar();";

    assert.throws(
        () => validateTargetInventory(source, { Foo: "Foo.json" }),
        /missing: Bar/u,
    );
    assert.throws(
        () =>
            validateTargetInventory(source, {
                Bar: "Bar.json",
                Baz: "Baz.json",
                Foo: "Foo.json",
            }),
        /unused: Baz/u,
    );
});

test("Robinhood target size limits accept exact boundaries", async () => {
    const {
        ROBINHOOD_INITCODE_SIZE_LIMIT,
        ROBINHOOD_RUNTIME_SIZE_LIMIT,
        checkDeploymentTargetSizes,
    } = await import("../checkDeploymentTargetSizes.js");
    const inventory = { Foo: "Foo.json" };

    const rows = checkDeploymentTargetSizes({
        source: "Foo foo = new Foo();",
        inventory,
        readArtifact: () =>
            artifactWithSizes(
                ROBINHOOD_RUNTIME_SIZE_LIMIT,
                ROBINHOOD_INITCODE_SIZE_LIMIT,
            ),
        runtimeLimit: ROBINHOOD_RUNTIME_SIZE_LIMIT,
        initcodeLimit: ROBINHOOD_INITCODE_SIZE_LIMIT,
    });

    assert.deepEqual(rows, [
        {
            target: "Foo",
            runtimeSize: ROBINHOOD_RUNTIME_SIZE_LIMIT,
            initcodeSize: ROBINHOOD_INITCODE_SIZE_LIMIT,
        },
    ]);
});

test("Robinhood target size validation rejects runtime and initcode overflow", async () => {
    const {
        ROBINHOOD_INITCODE_SIZE_LIMIT,
        ROBINHOOD_RUNTIME_SIZE_LIMIT,
        checkDeploymentTargetSizes,
    } = await import("../checkDeploymentTargetSizes.js");
    const inventory = { Foo: "Foo.json" };
    const run = (runtimeSize, initcodeSize) =>
        checkDeploymentTargetSizes({
            source: "Foo foo = new Foo();",
            inventory,
            readArtifact: () => artifactWithSizes(runtimeSize, initcodeSize),
            runtimeLimit: ROBINHOOD_RUNTIME_SIZE_LIMIT,
            initcodeLimit: ROBINHOOD_INITCODE_SIZE_LIMIT,
        });

    assert.throws(
        () =>
            run(
                ROBINHOOD_RUNTIME_SIZE_LIMIT + 1,
                ROBINHOOD_INITCODE_SIZE_LIMIT,
            ),
        /runtime 98305 B \/ 98304 B/u,
    );
    assert.throws(
        () =>
            run(
                ROBINHOOD_RUNTIME_SIZE_LIMIT,
                ROBINHOOD_INITCODE_SIZE_LIMIT + 1,
            ),
        /initcode 196609 B \/ 196608 B/u,
    );
});

test("target size validation counts library placeholders and rejects malformed bytecode", async () => {
    const { bytecodeSize, checkDeploymentTargetSizes } =
        await import("../checkDeploymentTargetSizes.js");

    assert.equal(
        bytecodeSize(
            "0x60ff__$4a0d5521c2dede9d7cce0b2de08f0a89ff$__00",
            "LinkedTarget",
            "bytecode",
        ),
        23,
    );

    assert.throws(
        () =>
            checkDeploymentTargetSizes({
                source: "Foo foo = new Foo();",
                inventory: { Foo: "Foo.json" },
                readArtifact: () => ({
                    bytecode: { object: "0x__$unlinked$__" },
                    deployedBytecode: { object: "0x00" },
                }),
            }),
        /invalid bytecode\.object/u,
    );
});
