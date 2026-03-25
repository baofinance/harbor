# CLAUDE.md

- Do not create functions that are only called once. Inline the logic instead.
- When diagnosing an issue, do not use words like "likely", "probably", or "may" to describe a root cause. Either verify the hypothesis with data (dry run, log, trace) or state explicitly that it is unverified. Never proceed with a fix based on an unverified hypothesis.