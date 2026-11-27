/// What the committed root reference points at, recorded in the commit slot so readers never guess.
pub const RootKind = enum(u8) {
    /// No root: the root reference is 0.
    none = 0,
    /// Raw bytes with no typed structure to audit.
    blob = 1,
    /// A single catalog node, as the C ABI commits it.
    catalog = 2,
    /// A type directory of up to 256 catalogs, as the typed API commits it.
    typeDirectory = 3,
};
