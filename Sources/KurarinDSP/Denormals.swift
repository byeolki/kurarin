/// Snaps a value that has decayed into the denormal range down to zero.
///
/// A filter or a reverb tail fed silence does not reach zero, it approaches it
/// exponentially, and once the numbers fall below the smallest normal float the
/// CPU handles them in microcode — on the order of a hundred times slower than
/// normal arithmetic. The effect is a processor that quietly gets slower minutes
/// after the last sound, which on the audio thread means dropouts with no
/// visible cause.
///
/// Applied to the state a unit carries between blocks, not to every sample: the
/// state is what keeps a decaying value alive, and once it is zero everything
/// computed from it is zero too.
@inline(__always)
func withoutDenormals(_ value: Float) -> Float {
    value.isNormal || value == 0 ? value : 0
}
