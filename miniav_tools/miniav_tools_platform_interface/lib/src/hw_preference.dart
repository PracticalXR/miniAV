/// Richer hardware/software preference than the plain [HwAccelPreference] enum.
///
/// The enum ([forbidden]/[allowed]/[preferred]/[required]) sets the *mode*;
/// this adds the knobs the negotiator needs to turn today's hard-coded
/// workarounds into data:
///   - [order]:  explicit path ranking, e.g. `[nvdec, d3d11va]`.
///   - [exclude]: paths to skip entirely, e.g. `{amf}` on AMD (the black-frame
///                workaround that is currently branchy code becomes data).
///   - [requireZeroCopy]: drop any path that would force a CPU readback.
library;

import 'capability.dart';
import 'codec_types.dart';

class HwPreference {
  const HwPreference({
    this.mode = HwAccelPreference.preferred,
    this.order,
    this.exclude = const {},
    this.requireZeroCopy = false,
  });

  /// Software-only — never pick a hardware path.
  const HwPreference.softwareOnly()
      : mode = HwAccelPreference.forbidden,
        order = null,
        exclude = const {},
        requireZeroCopy = false;

  /// Hardware required — throw if no HW path survives filtering.
  const HwPreference.requireHardware({this.order, this.exclude = const {}})
      : mode = HwAccelPreference.required,
        requireZeroCopy = false;

  /// Adapt a plain [HwAccelPreference] (back-compat with existing configs).
  const HwPreference.fromMode(this.mode)
      : order = null,
        exclude = const {},
        requireZeroCopy = false;

  final HwAccelPreference mode;

  /// Explicit path preference order; paths not listed rank after listed ones
  /// by the negotiator's default ordering. `null` = no explicit order.
  final List<HwPath>? order;

  /// Paths to drop entirely before ranking.
  final Set<HwPath> exclude;

  /// When true, non-zero-copy capabilities are filtered out.
  final bool requireZeroCopy;

  bool get forbidsHardware => mode == HwAccelPreference.forbidden;
  bool get requiresHardware => mode == HwAccelPreference.required;
  bool get prefersHardware =>
      mode == HwAccelPreference.preferred || requiresHardware;
}
