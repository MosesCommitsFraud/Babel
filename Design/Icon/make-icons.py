#!/usr/bin/env python3
"""Erzeugt die App-Icons (aufgeschlagenes Buch mit Lesezeichen) in allen Farben.

Aufruf im Projektordner:  python3 Design/Icon/make-icons.py
Schreibt Babel/AppIcon.icon (Standard), Babel/AppIcon-<Name>.icon (Alternativen)
und die Vorschaubilder für die Einstellungen nach Babel/Assets.xcassets.
Neue Farbe: hier eintragen, in `AppIconChoice` (Views/Settings/AppIconSettingsView.swift)
und in project.yml (ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES), dann `xcodegen generate`.
"""
import json, math, os, shutil, subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ICTOOL = "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"

# Erste Farbe = Standard-Icon.
COLORS = {
    "Weinrot": (0.46, 0.20, 0.25),
    "Jade": (0.30, 0.56, 0.50),
    "Waldnacht": (0.18, 0.26, 0.23),
    "Tiefsee": (0.08, 0.28, 0.33),
    "Nachtblau": (0.13, 0.18, 0.32),
    "Pflaume": (0.44, 0.26, 0.39),
    "Rost": (0.62, 0.31, 0.21),
    "Senf": (0.72, 0.60, 0.30),
    "Sand": (0.74, 0.67, 0.56),
    "Tinte": (0.22, 0.22, 0.24),
}
PAGE = "#F8FAF6"
# Senkrechte Verschiebung: Der Buchkörper sitzt optisch mittig, das Lesezeichen hängt unten heraus.
SHIFT = -26


def p3(c):
    return "display-p3:%.5f,%.5f,%.5f,1.00000" % tuple(c)


def rounded(points, r):
    d = ""
    for i, p1 in enumerate(points):
        p0, p2 = points[i - 1], points[(i + 1) % len(points)]

        def toward(a, b):
            l = math.hypot(b[0] - a[0], b[1] - a[1])
            return (a[0] + (b[0] - a[0]) * r / l, a[1] + (b[1] - a[1]) * r / l)

        a, b = toward(p1, p0), toward(p1, p2)
        d += ("M" if i == 0 else "L") + f"{a[0]:.1f} {a[1]:.1f} Q{p1[0]:.1f} {p1[1]:.1f} {b[0]:.1f} {b[1]:.1f} "
    return d + "Z"


LEFT = "M494 352 C430 300 310 286 232 300 Q196 306 196 342 L196 668 Q196 706 234 700 C320 688 430 700 494 748 Z"
RIGHT = "M530 352 C594 300 714 286 792 300 Q828 306 828 342 L828 668 Q828 706 790 700 C704 688 594 700 530 748 Z"
COVER = ("M150 372 Q150 340 182 340 L842 340 Q874 340 874 372 L874 716 Q874 748 842 748 "
         "C730 744 610 752 512 806 C414 752 294 744 182 748 Q150 748 150 716 Z")
MARK = rounded([(484, 300), (540, 300), (540, 822), (512, 796), (484, 822)], 10)


def svg(body):
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">'
            f'<g transform="translate(0 {SHIFT})">{body}</g></svg>')


def write_icon(path, color):
    shutil.rmtree(path, ignore_errors=True)
    os.makedirs(path + "/Assets")
    mark = "#%02X%02X%02X" % tuple(int(v * 0.45 * 255) for v in color)
    layers = {
        "cover": f'<path d="{COVER}" fill="{PAGE}" fill-opacity="0.42"/>',
        "under": f'<g transform="translate(0 20)" fill-opacity="0.75"><path d="{LEFT}" fill="{PAGE}"/><path d="{RIGHT}" fill="{PAGE}"/></g>',
        "left": f'<path d="{LEFT}" fill="{PAGE}"/>',
        "right": f'<path d="{RIGHT}" fill="{PAGE}"/>',
        "mark": f'<path d="{MARK}" fill="{mark}"/>',
    }
    for name, body in layers.items():
        with open(f"{path}/Assets/{name}.svg", "w") as f:
            f.write(svg(body))

    # Dunkel: iOS färbt das Buch in der Hintergrundfarbe auf Schwarz. Sehr dunkle Töne
    # hellen wir dafür auf, das Lesezeichen wird cremefarben (sonst kaum zu sehen).
    lift = 0.58 / max(color)
    book_dark = [{"appearance": "dark", "value": {"solid": p3([min(1, v * lift) for v in color])}}] if lift > 1 else None
    mark_dark = [{"appearance": "dark", "value": {"solid": p3((0.93, 0.90, 0.83))}}]

    def group(names, shadow, translucency=None, dark=None):
        layer_list = []
        for n in names:
            layer = {"image-name": n + ".svg", "name": n, "glass": True}
            if dark:
                layer["fill-specializations"] = dark
            layer_list.append(layer)
        g = {"layers": layer_list, "shadow": {"kind": "layer-color", "opacity": shadow}}
        if translucency is not None:
            g["translucency"] = {"enabled": True, "value": translucency}
        return g

    doc = {
        "fill": {"automatic-gradient": p3(color)},
        "groups": [
            group(["mark"], 0.5, 0.1, mark_dark),
            group(["left", "right"], 0.5, dark=book_dark),
            group(["under"], 0.3, dark=book_dark),
            group(["cover"], 0.4, dark=book_dark),
        ],
        "supported-platforms": {"squares": ["iOS"]},
    }
    with open(path + "/icon.json", "w") as f:
        json.dump(doc, f, indent=2)


def render(icon, out, rendition="Default", size=1024):
    subprocess.run([ICTOOL, icon, "--export-image", "--output-file", out, "--platform", "iOS",
                    "--rendition", rendition, "--width", str(size), "--height", str(size),
                    "--scale", "1", "--design-generation", "27"], check=True, capture_output=True)


for index, (name, color) in enumerate(COLORS.items()):
    icon = f"{ROOT}/Babel/AppIcon.icon" if index == 0 else f"{ROOT}/Babel/AppIcon-{name}.icon"
    write_icon(icon, color)
    # Vorschau für die Einstellungen: alternative Icons lassen sich zur Laufzeit nicht als Bild laden.
    imageset = f"{ROOT}/Babel/Assets.xcassets/IconPreview-{name}.imageset"
    os.makedirs(imageset, exist_ok=True)
    render(icon, f"{imageset}/preview.png", size=192)
    with open(imageset + "/Contents.json", "w") as f:
        json.dump({"images": [{"idiom": "universal", "filename": "preview.png", "scale": "3x"}],
                   "info": {"author": "xcode", "version": 1}}, f, indent=2)
    print(name)
