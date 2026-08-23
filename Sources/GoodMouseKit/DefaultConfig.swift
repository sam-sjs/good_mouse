import Foundation

public enum DefaultConfig {
    /// JSON5, so the comments survive in the file the user actually edits. `ConfigLoader` decodes
    /// with JSON5 enabled for exactly this reason.
    public static let json = """
    {
      // Rules are tried in order; the first match wins.
      //
      // Matching is on HID usage and identity, never on transport. The Karabiner virtual pointing
      // device publishes no Transport property at all, which is why transport-keyed tools cannot
      // see it and why this one does not try.
      "devices": [
        {
          "match": { "product": "Karabiner DriverKit VirtualHIDPointing*" },
          "profile": "trackball"
        }
      ],

      "profiles": {
        "trackball": {
          "pointer": {
            // "curve"  — the full parametric shape below
            // "linear" — flat multiplier, no acceleration (ignores resolution)
            // "raw"    — no accelerator at all, 1:1 motion
            "mode": "curve",

            // HIDPointerResolution. HIGHER IS SLOWER. Allowed 10…1995.
            "resolution": 400,

            // The index the curve set is evaluated at. 0.6875 is what a stock device carries.
            "acceleration": 0.6875,

            // Direct aliases for the kernel's own curve parameters. Run `goodmouse plot` after
            // changing any of them — four polynomial coefficients cannot be tuned by feel.
            "curve": {
              // Low-speed multiplier. This is what "sensitivity" means here.
              "gainLinear": 1.0,
              // How hard acceleration ramps. Enters the math as (gainParabolic * speed)^2.
              "gainParabolic": 0.4,
              // Enters as (gainCubic * speed)^3.
              "gainCubic": 0.08,
              // Enters as (gainQuartic * speed)^4.
              "gainQuartic": 0.0,
              // Where the polynomial ramp stops and a straight line takes over.
              "kneeSpeed": 8.0,
              // Where the straight line gives way to a square-root taper.
              "taperSpeed": 18.0
            }
          },

          "scroll": {
            "mode": "linear",
            "resolution": 9,
            "acceleration": 0.3125
          }
        }
      }
    }

    """

    public static func write(to path: String, force: Bool) throws {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path), !force {
            throw ConfigError.invalid(detail: "\(path) already exists. Pass --force to overwrite it.")
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(json.utf8).write(to: url)
    }
}
