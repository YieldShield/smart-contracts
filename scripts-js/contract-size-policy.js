export const DEFAULT_RUNTIME_LIMIT = 24_576;
export const DEFAULT_INITCODE_LIMIT = 49_152;

// These are repository-owned regression ceilings, not claims of EIP-170
// portability. Keep them at the reviewed artifact size so every byte of growth
// requires an explicit budget change.
export const TRACKED_SIZE_BUDGETS = Object.freeze({
    SplitRiskPool: Object.freeze({
        runtimeLimit: 45_988,
        initcodeLimit: 46_255,
        reason: "Robinhood-targeted monolith pending module split",
    }),
    SplitRiskPoolFactory: Object.freeze({
        runtimeLimit: 41_258,
        initcodeLimit: 41_525,
        reason: "Robinhood-targeted monolith pending module split",
    }),
});

export function exceedsLimits(row, limits) {
    return (
        row.runtimeSize > limits.runtimeLimit ||
        row.initcodeSize > limits.initcodeLimit
    );
}

export function classifySizeRows(
    rows,
    {
        runtimeLimit = DEFAULT_RUNTIME_LIMIT,
        initcodeLimit = DEFAULT_INITCODE_LIMIT,
        trackedBudgets = TRACKED_SIZE_BUDGETS,
    } = {},
) {
    const standardLimits = { runtimeLimit, initcodeLimit };
    const standardViolations = rows.filter((row) =>
        exceedsLimits(row, standardLimits),
    );
    const trackedBudgetRows = rows.filter(
        (row) => trackedBudgets[row.contract] !== undefined,
    );
    const trackedBudgetViolations = trackedBudgetRows.filter((row) =>
        exceedsLimits(row, trackedBudgets[row.contract]),
    );

    return {
        standardViolations,
        trackedBudgetRows,
        trackedBudgetViolations,
    };
}

export function shouldFailSizeCheck(
    classification,
    { reportOnly = false } = {},
) {
    return (
        classification.trackedBudgetViolations.length > 0 ||
        (!reportOnly && classification.standardViolations.length > 0)
    );
}
