# Disposal of the MP-23 cloud contexts

nagare-verify disposed of each cloud context by exact-name deletes taken from that context's own
`pulumi stack export`. Staged retirement could not be used, because it is blocked by F84 (next
release). `dispose-gen.py` turns a stack export into a delete script. Each script runs only with
`DISPOSE_EXECUTE=1`, in the context's project `tan-ng-labs`, and stops at the first failed delete.
The `.log.gz` files are the console logs.

| Context | Candidate | Script | Result |
| --- | --- | --- | --- |
| `mp23-c3i` | `3ae20f8c` (teardown) | `dispose-c3i.sh` | `DISPOSE-DONE` (see also [`../c3i-teardown/`](../c3i-teardown/)) |
| `mp23-c3j` | `3ae20f8c` | `dispose-c3j.sh`, then the remaining names in `dispose-c3j-rest.txt` | `DISPOSE-C3J-DONE` (see also [`../c3j-disposal/`](../c3j-disposal/)) |
| `mp23-c3k` | `3b78d905` | `dispose-c3k.sh`, which stopped at an instance-group delete still in use; then `dispose-c3k-rest.sh` | `DISPOSE-DONE` |
| `mp23-c3l` | `3b59bcb7` | `dispose-c3l.sh` | `DISPOSE-DONE` |
| `mp23-c3m` | `83124396` | `dispose-c3m.sh` | `DISPOSE-DONE`; afterwards no instance or bucket named `c3-1012` remained |
