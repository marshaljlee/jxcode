import Foundation
import JXCodeCore

// `jxcode prove route` — the router's half of dynamic verification.
//
// `jxcode prove` (in main.swift) spawns processes and checks where they land,
// because a sandbox that is *described* in a config file proves nothing. The
// router has the same failure mode: `/health` is answered from the router's own
// configuration, and a 200 from `/v1/messages` says only that something
// answered. A router that translated when it should have proxied returns a
// perfectly good answer too — that is why 2.1's route table exists, and why the
// only evidence that counts is what the backend received.
//
// So this command does not talk to the user's backend at all. It stands a
// recording server where the backend would be, points a real router at it, and
// drives the shared corpus through every route. Nothing is registered, nothing
// is bound, and no key is spent: the whole thing runs on loopback and exits.

func cmdProveRoute(sandbox: Sandbox, flags: Flags) throws {
    let kinds: [ProviderKind]
    if let raw = flags.value("--kind") {
        guard let kind = ProviderKind(rawValue: raw) else {
            throw CLIError.usage(
                "unknown kind '\(raw)'. one of: \(ProviderKind.allCases.map(\.rawValue).joined(separator: ", "))"
            )
        }
        kinds = [kind]
    } else {
        kinds = RouteProof.routes
    }

    let report = try awaitBlocking { await RouteProof.run(kinds: kinds) }
    // Failures by default. The corpus produces 122 checks and all but a handful
    // of them are expected to pass, so the full list is what `--all` is for —
    // it is the evidence, not the answer.
    Console.line(report.rendered(verbose: flags.has("--all")))
    Console.line("")
    Console.line("  Each route was given a router, a recording backend, and the same")
    Console.line("  \(RouteCorpus.fixtures.count) requests. Nothing was registered and no key was spent: the backend")
    Console.line("  is a listener on loopback and is gone when this exits. Pass --all to")
    Console.line("  list every check rather than only the failures.")
    Console.line("")

    // Inconclusive is not a pass, and neither is a route that was never tried.
    // A script that gates on this needs the difference between "every route did
    // what it promised" and "we could not find out".
    exit(report.isPassing ? 0 : 1)
}
