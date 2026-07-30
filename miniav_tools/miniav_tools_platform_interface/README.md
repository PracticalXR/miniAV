# miniav_tools_platform_interface

Pure-Dart platform interface and shared types for [miniav_tools](../miniav_tools).

Backends (`miniav_tools_ffmpeg`, `miniav_tools_minigpu`, `miniav_tools_web`) implement the abstract classes defined here. Application code depends on `miniav_tools` (the facade), not on this package directly.

See the [design doc](../miniav_tools_design.MD) for the full architecture.
