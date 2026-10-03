#!/usr/bin/env python3
"""Generate `Sources/JXCodeCore/MXIcons.swift` from the mx-icons repository.

mx-icons (https://github.com/ig-imanish/mx-icons) ships ~12,900 React icon
components, each an `<svg viewBox="0 0 24 24">` wrapping plain SVG children.
SwiftUI cannot render SVG, so this script transcribes the handful of icons
JXCode uses into `MXIconDefinition` values — the same plain-value vocabulary
`AgentIcons` already uses, so both icon sets are drawn by one renderer.

Vendoring the whole library is deliberately avoided: 13k icons would add
megabytes to the app for no benefit. Adding an icon is one line in `MAPPING`.

Usage:
    scripts/generate-mx-icons.py <path-to-mx-icons-checkout>

The checkout is expected to contain `src/icons/components/<category>/`.
"""

import os
import re
import sys

# --- The icons JXCode uses -------------------------------------------------
#
# key -> mx-icons category. The key is the name the Swift code refers to; the
# category is the directory name in the upstream repository. Every key is
# resolved to the Bold variant when one exists and Outline otherwise, because
# the app's visual language is a heavy, filled icon at small sizes.
MAPPING = {
    # --- generic chrome ---------------------------------------------------
    "add":            "add",
    "close":          "close-circle",
    "check":          "check-circle",
    "circle":         "record-circle",
    "warning":        "danger-triangle",
    "info":           "info-circle",
    "refresh":        "arrows-refresh",
    "trash":          "trash-bin-trash",
    "edit":           "edit",
    "search":         "magnifier",
    "settings":       "settings",
    "eye":            "eye",
    "arrowRight":     "arrow-right",
    "arrowUpRight":   "arrow-right-up",
    "chevronDown":    "alt-arrow-down",
    "play":           "play",
    "stop":           "stop",
    "bolt":           "bolt",
    "clock":          "clock",
    "link":           "link",
    "key":            "key",
    "shield":         "shield",
    "code":           "code",
    "layers":         "layers",
    "sparkle":        "sparkle",
    "star":           "stars-minimalistic",
    "user":           "user",
    "people":         "users-group-rounded",
    "build":          "sledgehammer",
    # --- files and workspaces ---------------------------------------------
    "folder":         "folder",
    "folderAdd":      "add-folder",
    "folderCheck":    "folder-check",
    "download":       "download",
    "package":        "box",
    "terminal":       "command",
    # --- JXCode domain ----------------------------------------------------
    "dashboard":      "monitor",
    "cpu":            "cpu",
    "cpuBolt":        "cpu-bolt",
    "routing":        "branching-paths-up",
    "doctor":         "stethoscope",
    "model":          "widget",
    "connector":      "plug-circle",
    "cloud":          "cloud",
    "lock":           "lock-keyhole-minimalistic",
    "unlock":         "lock-keyhole-minimalistic-unlocked",
    "wallet":         "wallet-money",
    "checklist":      "checklist",
}

# The `Icon` wrapper hardcodes this; every vendored icon is authored in it.
VIEW_BOX = 24

# Upstream omits `fillRule` on a few icons that cut a hole by relying on the
# winding direction of their subpaths. Even-odd produces the same ring without
# depending on that, so it is forced here. `circle` (record-circle) is the case
# that needs it: two nested circles that must render as a ring, because the app
# uses it for an unselected radio.
FILL_RULE_OVERRIDES = {
    "circle": "evenodd",
}


def pascal(category):
    return "".join(p[:1].upper() + p[1:] for p in category.split("-"))


def find_component(root, category):
    """Return (variant, path) for the Bold component, else the first fallback."""
    directory = os.path.join(root, category)
    if not os.path.isdir(directory):
        return None
    stem = pascal(category)
    for variant in ("Bold", "Outline", "Linear", "Bulk"):
        candidate = os.path.join(directory, f"{stem}{variant}.jsx")
        if os.path.exists(candidate):
            return variant, candidate
    return None


def wrapper_fill(source):
    """The `fill` prop on the `<Icon>` wrapper, which children inherit.

    This matters: SVG `fill` is an inherited property, so a child `<path>`
    with no `fill` of its own is filled with whatever the wrapper declared.
    `SparkleBold` has exactly such a child, and dropping the wrapper's value
    would render that half of the icon invisible.
    """
    props = source.split("<Icon", 1)[1].split(">", 1)[0]
    match = re.search(r'\bfill="([^"]*)"', props)
    return match.group(1) if match else "none"


def inner_markup(source):
    """Everything between the opening `<Icon ...>` and its closing tag."""
    start = source.index("<Icon")
    open_end = source.index(">", start) + 1
    close = source.index("</Icon>")
    return source[open_end:close]


def attributes(body):
    return dict(re.findall(r'([a-zA-Z][\w:-]*)=\"([^\"]*)\"', body))


def number(attrs, key, default=None):
    if key in attrs:
        return float(attrs[key])
    if default is None:
        raise SystemExit(f"missing required attribute {key!r}")
    return default


def trim(value):
    """Format a float without a trailing `.0`, so the generated data stays short."""
    if value == int(value):
        return str(int(value))
    return repr(round(value, 6))


def element_path(tag, attrs):
    """Reduce an SVG element to an equivalent `d` string.

    Only `<path>` appears in the icons JXCode vendors, but the primitives are
    supported so that adding an icon never fails on a technicality. Each is
    expressed with the same two-arc circle trick the SVG spec recommends,
    which keeps the parser's arc handling exercised rather than special-cased.
    """
    if tag == "path":
        return attrs["d"]

    if tag == "circle":
        cx, cy, r = number(attrs, "cx"), number(attrs, "cy"), number(attrs, "r")
        return (
            f"M{trim(cx - r)} {trim(cy)}"
            f"a{trim(r)} {trim(r)} 0 1 0 {trim(2 * r)} 0"
            f"a{trim(r)} {trim(r)} 0 1 0 {trim(-2 * r)} 0Z"
        )

    if tag == "ellipse":
        cx, cy = number(attrs, "cx"), number(attrs, "cy")
        rx, ry = number(attrs, "rx"), number(attrs, "ry")
        return (
            f"M{trim(cx - rx)} {trim(cy)}"
            f"a{trim(rx)} {trim(ry)} 0 1 0 {trim(2 * rx)} 0"
            f"a{trim(rx)} {trim(ry)} 0 1 0 {trim(-2 * rx)} 0Z"
        )

    if tag == "line":
        return (
            f"M{trim(number(attrs, 'x1'))} {trim(number(attrs, 'y1'))}"
            f"L{trim(number(attrs, 'x2'))} {trim(number(attrs, 'y2'))}"
        )

    if tag == "rect":
        x = number(attrs, "x", 0)
        y = number(attrs, "y", 0)
        width, height = number(attrs, "width"), number(attrs, "height")
        if "rx" in attrs or "ry" in attrs:
            raise SystemExit("rounded <rect> is not supported — extend element_path")
        return (
            f"M{trim(x)} {trim(y)}H{trim(x + width)}"
            f"V{trim(y + height)}H{trim(x)}Z"
        )

    raise SystemExit(f"unsupported element <{tag}> — extend element_path")


def layers_for(markup, inherited, rule_override=None):
    """Turn SVG children into `(kind, path, extras)` tuples.

    Returns a list of `(kind, path, extras)` where kind is `"fill"` or
    `"stroke"`. `extras` carries the fill rule, or the stroke's width, cap and
    join. `rule_override` replaces the fill rule read from the file, for the
    icons listed in `FILL_RULE_OVERRIDES`.
    """
    layers = []
    elements = re.findall(r"<([a-zA-Z][\w:-]*)([^>]*)/>", markup)

    for tag, body in elements:
        attrs = attributes(body)
        path = element_path(tag, attrs)

        # SVG inheritance: a child with no `fill` of its own takes the
        # wrapper's. An explicit `fill="none"` overrides it back to nothing.
        fill = attrs.get("fill", inherited)
        stroke = attrs.get("stroke", "none")

        if fill == "currentColor":
            rule = attrs.get("fillRule") or attrs.get("fill-rule") or "nonzero"
            if rule_override:
                rule = rule_override
            layers.append(("fill", path, "evenodd" if rule.lower() == "evenodd" else "nonzero"))

        if stroke == "currentColor":
            width = float(attrs.get("strokeWidth") or attrs.get("stroke-width") or 1.5)
            cap = attrs.get("strokeLinecap", "butt")
            join = attrs.get("strokeLinejoin", "miter")
            layers.append(("stroke", path, (width, cap, join)))

        if fill != "currentColor" and stroke != "currentColor":
            raise SystemExit(
                f"<{tag}> paints nothing (fill={fill!r}, stroke={stroke!r}) — "
                "it would render as a gap"
            )

    return layers


def swift_raw_string(text):
    """A Swift raw string literal, widened until the content cannot close it."""
    hashes = "#"
    while f'"{hashes}' in text or f'{hashes}"' in text:
        hashes += "#"
    return f'{hashes}"{text}"{hashes}'


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    root = os.path.join(sys.argv[1], "src/icons/components")
    if not os.path.isdir(root):
        raise SystemExit(f"not an mx-icons checkout: {sys.argv[1]}")

    entries = []
    missing = []
    for key, category in sorted(MAPPING.items()):
        found = find_component(root, category)
        if not found:
            missing.append((key, category))
            continue
        variant, path = found
        source = open(path, encoding="utf-8").read()
        layers = layers_for(
            inner_markup(source),
            wrapper_fill(source),
            FILL_RULE_OVERRIDES.get(key),
        )
        entries.append((key, category, variant, layers))

    if missing:
        for key, category in missing:
            print(f"  MISSING  {key} -> {category}", file=sys.stderr)
        raise SystemExit(f"{len(missing)} icon(s) could not be resolved")

    out = [
        "// Generated by scripts/generate-mx-icons.py — do not edit by hand.",
        "//",
        "// Geometry vendored from mx-icons (https://github.com/ig-imanish/mx-icons),",
        "// MIT licensed. See that repository for the original artwork.",
        "//",
        "// Regenerate with:",
        "//     scripts/generate-mx-icons.py <path-to-mx-icons-checkout>",
        "",
        "import Foundation",
        "",
        "/// Every icon JXCode vendors, named for what it means rather than for",
        "/// what it depicts, so the artwork behind a name can change without",
        "/// touching call sites.",
        "public enum MXIconName: String, CaseIterable, Sendable {",
    ]
    for key, _category, _variant, _layers in entries:
        out.append(f'    case {key} = "{key}"')
    out.append("}")
    out.append("")
    out.append("/// The drawing instructions for each icon.")
    out.append("public enum MXIconCatalog {")
    out.append("")
    out.append("    /// Which upstream variant each icon was taken from. Bold wherever")
    out.append("    /// one exists, because that is the app's visual language.")
    out.append("    public static let variants: [MXIconName: String] = [")
    for key, _category, variant, _layers in entries:
        out.append(f'        .{key}: "{variant}",')
    out.append("    ]")
    out.append("")
    out.append("    /// The upstream category, so an icon can be traced back to the")
    out.append("    /// library it came from.")
    out.append("    public static let sources: [MXIconName: String] = [")
    for key, category, _variant, _layers in entries:
        out.append(f'        .{key}: "{category}",')
    out.append("    ]")
    out.append("")
    out.append("    public static let definitions: [MXIconName: MXIconDefinition] = [")
    for key, _category, _variant, layers in entries:
        out.append(f"        .{key}: MXIconDefinition(layers: [")
        for kind, path, extras in layers:
            literal = swift_raw_string(path)
            if kind == "fill":
                rule = "" if extras == "nonzero" else f", rule: .{extras}"
                out.append(f"            .fill(path: {literal}{rule}),")
            else:
                width, cap, join = extras
                out.append(
                    f"            .stroke(path: {literal}, width: {trim(width)}, "
                    f"cap: .{cap}, join: .{join}),"
                )
        out.append("        ]),")
    out.append("    ]")
    out.append("}")
    out.append("")

    target = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "Sources/JXCodeCore/MXIcons.swift",
    )
    with open(target, "w", encoding="utf-8") as handle:
        handle.write("\n".join(out))

    bold = sum(1 for e in entries if e[2] == "Bold")
    layer_count = sum(len(e[3]) for e in entries)
    print(f"wrote {target}")
    print(f"  {len(entries)} icons, {layer_count} layers — {bold} Bold, {len(entries) - bold} fallback")


if __name__ == "__main__":
    main()
