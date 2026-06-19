#!/usr/bin/env bash
# =============================================================================
# serve-blink-fonts.sh
#
# Serve the generated Blink Shell font CSS over HTTP so Blink can import it.
#
# Blink Shell adds a custom font from a URL, not a local file. This starts a
# throwaway Python HTTP server rooted at the directory where
# build-updated-font.sh emits the CSS, prints the import URLs, and serves
# until you Ctrl-C.
#
# Usage:
#   ./serve-blink-fonts.sh [port]      # default port 8000
#
# Override the served directory with BLINK_OUT_DIR (must match the value used
# by build-updated-font.sh). In Blink: Settings -> Appearance -> Add font ->
# paste the printed URL. Save the font under the EXACT name Blink ties to the
# font-family inside the CSS:
#   jetbrains-mono-nerd-font.css  -> "JetBrainsMono NF"
# =============================================================================

set -euo pipefail

BLINK_OUT_DIR="${BLINK_OUT_DIR:-${HOME}/.local/share/fonts/blink}"
PORT="${1:-8000}"

if [[ ! -d "${BLINK_OUT_DIR}" ]]; then
  printf 'error: %s does not exist. Run build-updated-font.sh first.\n' \
    "${BLINK_OUT_DIR}" >&2
  exit 1
fi

PYTHON="$(command -v python3 || command -v python || true)"
[[ -n "${PYTHON}" ]] || { printf 'error: python3 not found on PATH.\n' >&2; exit 1; }

# Blink runs on a separate device (iOS), so "localhost" would point at the
# device itself, not this machine — the import fails. Advertise a
# LAN-reachable address instead. The Python server already binds 0.0.0.0.

# The Bonjour/mDNS hostname (<name>.local), resolvable from other devices on
# the same network. Empty if it can't be determined.
bonjour_host() {
  if command -v scutil >/dev/null 2>&1; then
    local lh; lh="$(scutil --get LocalHostName 2>/dev/null || true)"
    [[ -n "${lh}" ]] && { printf '%s.local' "${lh}"; return; }
  fi
  # Linux / other: use the FQDN-ish hostname only if it already looks resolvable.
  if command -v hostname >/dev/null 2>&1; then
    local hn; hn="$(hostname 2>/dev/null || true)"
    [[ "${hn}" == *.* ]] && printf '%s' "${hn}"
  fi
}

# The current LAN IPv4. Empty if it can't be determined.
lan_ip() {
  local ip iface
  if command -v ipconfig >/dev/null 2>&1; then            # macOS
    for iface in en0 en1 en2 en3 en4; do
      ip="$(ipconfig getifaddr "${iface}" 2>/dev/null || true)"
      [[ -n "${ip}" ]] && { printf '%s' "${ip}"; return; }
    done
  fi
  if command -v hostname >/dev/null 2>&1; then             # Linux
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [[ -n "${ip}" ]] && { printf '%s' "${ip}"; return; }
  fi
}

# `|| true`: the detectors return non-zero when nothing is found, which would
# trip `set -e` on these assignments. The || also suspends `set -e` inside the
# function, so internal probe failures can't abort the script either.
HOST_NAME="$(bonjour_host || true)"
HOST_IP="$(lan_ip || true)"
# Prefer the hostname; fall back to the IP. Last resort: localhost (and warn).
HOST="${HOST_NAME:-${HOST_IP:-localhost}}"
if [[ "${HOST}" == "localhost" ]]; then
  printf 'warning: could not detect a LAN hostname/IP; Blink on another device\n'
  printf '         will NOT be able to reach http://localhost:%s/.\n\n' "${PORT}"
fi

print_urls() {  # print_urls <host>
  local css
  for css in "${BLINK_OUT_DIR}"/jetbrains*nerd-font*.css; do
    [[ -f "${css}" ]] && printf '  http://%s:%s/%s\n' "$1" "${PORT}" "$(basename "${css}")"
  done
}

printf 'Serving %s on http://%s:%s/\n\n' "${BLINK_OUT_DIR}" "${HOST}" "${PORT}"
printf 'Import one of these URLs into Blink (Settings -> Appearance -> Add font):\n'
print_urls "${HOST}"
# If we advertised the .local hostname but also have an IP, offer it as a
# fallback — Bonjour resolution is flaky on some iOS networks.
if [[ -n "${HOST_NAME}" && -n "${HOST_IP}" && "${HOST}" == "${HOST_NAME}" ]]; then
  printf '\nIf the .local name does not resolve, use the IP instead:\n'
  print_urls "${HOST_IP}"
fi
printf '\nPress Ctrl-C to stop.\n\n'

exec "${PYTHON}" -m http.server "${PORT}" --directory "${BLINK_OUT_DIR}"
