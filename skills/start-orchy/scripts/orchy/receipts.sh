# shellcheck shell=bash
# The cost receipt: per lane dollars, tokens, wall-clock, PRs, issues, failed arcs and asks, from the lead logs.
orchy_receipt() {
  js=0; off=0; want=""; for o in "$@"; do case "$o" in --json) js=1;; --offline) off=1;; *) want=$o;; esac; done
  [ $off = 1 ] || need gh
  asks='{}'; if ledger_ro 2>/dev/null; then asks=$(fold | jq -c 'map_values({state, lane})'); fi
  python3 -I "$SCRIPTS/orchy/receipt.py" "$H" "$REPO" "$want" "$asks" "$js" "$off"
}
