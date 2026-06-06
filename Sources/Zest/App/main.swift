import CZestCore

// Prove the C module imports and the Zig static lib links: reference a symbol.
// (zest_open(nil-ish) is not called with real data here; we only need the symbol
// to resolve at link time. Print a banner.)
print("Zest bootstrap — CZestCore module imported, libzest-core.a linked")
