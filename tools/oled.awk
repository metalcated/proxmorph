# Applies one OLED substitution table to a base UniFi stylesheet.
# Map file (tab separated): "hex<TAB>#RRGGBB<TAB>#rrggbb" | "rgb<TAB>r,g,b<TAB>r,g,b" | "lit<TAB>from<TAB>to"
# Hex lookups are case insensitive; rgb lookups ignore whitespace.

function hexval(h,   i, c, v) {
    v = 0; h = toupper(h)
    for (i = 1; i <= length(h); i++) {
        c = index("0123456789ABCDEF", substr(h, i, 1)) - 1
        v = v * 16 + c
    }
    return v
}

function spaced(csv) { gsub(/,/, ", ", csv); return csv }

# Replace every color token that the table names.
function recolor(s,   out, pre, tok, key, rep) {
    out = ""
    # Older mawk (Debian 12) does not implement interval expressions like {6}.
    while (match(s, /rgba\([^)]*\)|rgb\([^)]*\)|#[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]/)) {
        pre = substr(s, 1, RSTART - 1)
        tok = substr(s, RSTART, RLENGTH)
        s   = substr(s, RSTART + RLENGTH)
        rep = tok
        if (tok ~ /^#/) {
            key = toupper(tok)
            if (key in HEX) rep = HEX[key]
        } else if (tok ~ /^rgb\(/) {
            key = tok; gsub(/[ \t]/, "", key); sub(/^rgb\(/, "", key); sub(/\)$/, "", key)
            if (key in RGB) rep = "rgb(" spaced(RGB[key]) ")"
        } else if (tok in LIT) {
            rep = LIT[tok]
        }
        out = out pre rep
    }
    return out s
}

# Header comments annotate a hex with its decimal triple: "#131416 (rgb 19,20,22)".
# Re-derive the triple so the annotation cannot drift from the recolored hex.
function resync_annotations(s,   out, pre, tok, hex) {
    out = ""
    while (match(s, /#[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F] \(rgb [0-9]+, ?[0-9]+, ?[0-9]+\)/)) {
        pre = substr(s, 1, RSTART - 1)
        tok = substr(s, RSTART, RLENGTH)
        s   = substr(s, RSTART + RLENGTH)
        hex = substr(tok, 2, 6)
        out = out pre "#" hex " (rgb " hexval(substr(hex, 1, 2)) "," hexval(substr(hex, 3, 2)) "," hexval(substr(hex, 5, 2)) ")"
    }
    return out s
}

BEGIN { FS = "\t" }

NR == FNR {
    sub(/\r$/, "")
    if ($0 ~ /^#/ || $0 == "") next
    if ($1 == "hex") HEX[toupper($2)] = $3
    else if ($1 == "rgb") RGB[$2] = $3
    else if ($1 == "lit") LIT[$2] = $3
    else { print "gen-oled: bad map row: " $0 > "/dev/stderr"; exit 1 }
    next
}

$0 == "/*!" NAME "*/" { print "/*!" NAME " OLED*/"; next }
$0 ~ ("^ [*] ProxMorph .*Theme: " NAME "$") { print $0 " OLED"; print PROVENANCE; next }

{ print resync_annotations(recolor($0)) }
