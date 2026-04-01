# CLAUDE.md

- Do not create functions that are only called once. Inline the logic instead.
- When diagnosing an issue, do not use words like "likely", "probably", or "may" to describe a root cause. Either verify the hypothesis with data (dry run, log, trace) or state explicitly that it is unverified. Never proceed with a fix based on an unverified hypothesis.
- use forge install/remove for managing submodule dependencies
- In tests, use interface types (e.g. `IStabilityPool_v3(address)`) not concrete contract types (e.g. `StabilityPool_v3(address)`) when calling functions. This verifies the interface matches the implementation. Concrete types are only for initialisation (constructor, deploy).
- in code never use an if or loop statement without curly brackets - I want the code coverage to be visible and that hides some branches from the display