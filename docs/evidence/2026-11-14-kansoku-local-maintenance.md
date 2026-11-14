# Kansoku local shared-server maintenance

Source candidate `8cc5a7792710083092c60c2dc71777186b61a360` passes the actual
reviewed local-mode Kansoku ceremony. The delivered reader metadata API from
`ddaee801c8799a625a5320a0f41a9324da385e4d`, accepted scratch relations from
`6b3a7dd390b29372608bb19603a33c71c5b62ac0` and exact reader-database observation
fix are included. Package/platform version remains 0.20.0; published v0.20.0
alone does not contain these source extensions.

The fresh Apple Container Kubernetes deployment uses actual reviewed namespace,
ClickHouse/PostgreSQL server and app-database scopes. Runtime-only quiesce,
paused/drained schedules, on-demand backups, verified signed receipt ingestion,
three-store scratch restores and reviewed resume all execute through the
packaged CLI. A separately declared bounded SELECT-only reader verifies the
restored schema/history and rejects schema drift, authentication-column reads,
temporary tables and mutations. Final declaration re-plan has no operations.

The other app's long query remains active at every phase; 274 fresh query
samples succeed with unchanged data/grants and no shared-server restart. The
backend is the exact official Linux arm64 ClickHouse 26.8.28.14 image, independently
qualified by the SDK. Clients are packaged Darwin arm64 Kansoku binaries. Stock
k3d/Knative bootstrap and a Linux application image are separate qualification.

The final Nagare full suite passes all four explicit shards; app-database focused
tests and Haskell style checks also pass. An earlier 36-shard invocation exhausted
host process resources while other native qualification was active and is retained
as a failed run. Whole user-documentation validation remains blocked by the
pre-existing missing frontmatter in project-relative
`docs/user/delegating-deployments.md`; that unrelated page is unchanged and no
whole-documentation pass is claimed.

Exact application evidence and signed artifact identifiers are recorded in
`mori://shinzui/kansoku/plans/53-prove-shared-server-maintenance-across-deployment-platforms`
and `mori://shinzui/kansoku`, project-relative
`docs/evidence/shared-clickhouse-maintenance.md` (artifact URI pending).
The same project retains private test logs at project-relative
`.dev/ep53-nagare-final-full.log`, `.dev/ep53-nagare-final-style.log`,
`.dev/ep53-nagare-qualified-prepare.log` and
`.dev/ep53-nagare-qualified-ceremony.log` (artifact URIs pending).
Owned cluster processes were stopped after proof; private inventories, data and
receipts remain available. This is implementation-authored conformance evidence,
not independent review or a production rollout.
