# Recorded snapshots

The goldens the diff gate compares against, one PNG per case in
`SnapshotCatalogue`, plus `environment.json` saying what they were recorded
against.

**These files are evidence, not output.** Re-recording them is a decision: it
replaces the thing the gate compares against, so a re-record that nobody looked
at turns the gate off for every case it touched. Read
[`docs/snapshot-testing.md`](../../../docs/snapshot-testing.md) before changing
one — it covers how to re-record, what to look at in the diff image, and why
the directory is checked in both directions by
`Tools/assert-snapshot-gate.py`.

The file names are `<subject>.<scheme>[.<type size>].png`, derived from the
catalogue rather than written down, so a subject that is renamed leaves a golden
behind that nothing compares against — which the audit fails on.
