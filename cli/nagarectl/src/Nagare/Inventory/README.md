# Inventory implementation boundaries

The public modules retain their explicit export lists. Their implementation
submodules are Cabal `other-modules`, so moving an opaque type's definition does
not expose its constructor to downstream packages. Never replace a facade's
explicit exports with a module-wide re-export.

## Application composition

`Application` is the public API. `Application.Compile` composes the complete
selected application and its release hooks. `Service`, `Worker`, `Tasks` and
`Database` own workload compilation. `Bindings` resolves dependencies from
accepted inventory; `Recovery` validates recovery bindings; `Release` owns
immutable release-history inputs; `Ownership` and `Policy` implement scoped
ownership and service actions. `Environment` resolves generated values and
secret references, and `Types` holds their shared inputs and witnesses.

These modules compile pure declarations and private native bytes. They do not
perform provider effects. Constructors such as `DatabaseBinding` remain opaque
at the public API. Workload modules share lower-level helpers rather than
calling back into the complete application composer.
