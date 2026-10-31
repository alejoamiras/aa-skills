# date_in <text> <YYYY-MM-DD>...: exit 0 when the text writes one of the dates in a common form. Python, for its regex
# classes: \d, \w and \s follow this Python's Unicode version, which bun's does not match.
import re, sys
text, M = sys.argv[1].lower(), ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
for d in sys.argv[2:]:
    y, m, dd = d.split("-"); mi, di = int(m), int(dd)
    mon, day = f"(?:{M[mi - 1]}|{M[mi - 1][:3]}\\.?)", f"0?{di}(?:st|nd|rd|th)?"
    # without its year only a slashed form counts: a dotted or dashed one is also a version or a range (1.15, 1-15)
    forms = [f"{y}{m}{dd}", f"(?<!\\d){y}[-/.]0?{mi}[-/.]0?{di}(?!\\d)", f"(?<!\\d)0?{di}[-/.]0?{mi}[-/.]{y}(?!\\d)", f"(?<!\\d)0?{mi}[-/.]0?{di}[-/.]{y}(?!\\d)",
             f"(?<!\\d)0?{mi}/0?{di}(?!\\d)", f"(?<!\\d)0?{di}/0?{mi}(?!\\d)", f"\\b{mon}[\\s,-]*{day}\\b", f"\\b{day}(?:\\s+of)?[\\s,-]*{mon}\\b"]
    if any(re.search(f, text) for f in forms): sys.exit(0)
sys.exit(1)
