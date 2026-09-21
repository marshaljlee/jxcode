import Foundation

/// Command-line flags, separated from the positional arguments.
///
/// The separation is the whole job, and it is easy to get quietly wrong: see
/// `parseFlags` for the case that motivated this.
public struct Flags {
    public var positional: [String] = []
    public var options: [String: String] = [:]

    /// Options that take a value. Everything else is a switch.
    ///
    /// Decided by name, not by "a value happens to follow". That reading is
    /// what made `jxcode scan --names-only /Volumes/Models` store the path as
    /// the value of a switch, lose the positional, and scan `~/Models` instead
    /// — silently, because nothing checks for a leftover value on an option
    /// that never wanted one.
    ///
    /// Anything not listed here is treated as a switch, which is the safe
    /// direction to be wrong in: a switch that swallows the next token loses
    /// user input without saying so, whereas a value read as a positional is at
    /// least visible in what the command does next.
    ///
    /// Kept in step with the commands themselves by `FlagsTests` rather than by
    /// whoever adds a flag next.
    public static let valuedOptions: Set<String> = [
        "--agent",
        "--args",
        "--body",
        "--cache",
        "--cadence",
        "--command",
        "--context",
        "--description",
        "--env",
        "--file",
        "--hour",
        "--id",
        "--install",
        "--interval",
        "--key",
        "--kind",
        "--memory",
        "--minute",
        "--model",
        "--models",
        "--name",
        "--port",
        "--prompt",
        "--provider",
        "--router",
        "--url",
        "--weekday",
        "--workspace",
    ]

    public init() {}

    public func has(_ name: String) -> Bool { options[name] != nil }
    public func value(_ name: String) -> String? { options[name] }
}

/// Split `arguments` into options and positionals.
///
/// A `--flag` consumes the token after it only when it is one of
/// `Flags.valuedOptions`; otherwise the token is a positional. `--key=value`
/// is accepted for any option, which is how an unlisted option can still be
/// given a value.
public func parseFlags(_ arguments: [String]) -> Flags {
    var flags = Flags()
    var index = 0

    while index < arguments.count {
        let argument = arguments[index]

        guard argument.hasPrefix("--") else {
            flags.positional.append(argument)
            index += 1
            continue
        }

        // Unambiguous, and available to any option whether it is listed or not.
        if let equals = argument.firstIndex(of: "=") {
            flags.options[String(argument[argument.startIndex..<equals])] =
                String(argument[argument.index(after: equals)...])
            index += 1
            continue
        }

        if Flags.valuedOptions.contains(argument),
           index + 1 < arguments.count,
           !arguments[index + 1].hasPrefix("--") {
            flags.options[argument] = arguments[index + 1]
            index += 2
            continue
        }

        flags.options[argument] = ""
        index += 1
    }

    return flags
}
