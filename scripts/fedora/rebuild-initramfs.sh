#!/usr/bin/env bash

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

BOOT_ROOT=${KAIT2EN_BOOT_ROOT:-/boot}

if [[ ${KAIT2EN_TEST_MODE:-0} != 1 ]]; then
	require_root
	require_fedora
fi
require_repo_root
require_command awk df dracut lsinitrd modinfo stat

KVER="$(kernel_release)"
INITRAMFS="$BOOT_ROOT/initramfs-$KVER.img"
STAGED=
# Assumed image size when none is installed yet, so the first build on a kernel
# is still checked against something rather than waved through.
MIN_INITRAMFS_KB=131072

cleanup() {
	if [[ -n "$STAGED" && -e "$STAGED" ]]; then
		rm -f "$STAGED"
	fi
}
trap cleanup EXIT

# Dracut resolves --force-drivers through modules.dep, so a module that depmod
# never indexed is silently left out of the image. Ask the same index first and
# stop while the installed initramfs is still intact.
missing=()
for module in "${INPUT_MODULES[@]}"; do
	modinfo -k "$KVER" -n "$module" >/dev/null 2>&1 || missing+=("$module")
done
if (( ${#missing[@]} > 0 )); then
	fail "no installed module for $KVER: ${missing[*]}. Install the DKMS modules for this kernel before rebuilding its initramfs. $INITRAMFS was left unchanged."
fi

# The new image is staged beside the installed one, so the filesystem briefly
# holds both. Say so plainly here instead of failing later inside mktemp or
# leaving dracut to run out of room halfway through writing.
needed_kb=$(( $(stat -c %s "$INITRAMFS" 2>/dev/null || printf 0) / 1024 ))
(( needed_kb >= MIN_INITRAMFS_KB )) || needed_kb=$MIN_INITRAMFS_KB
needed_kb=$(( needed_kb + needed_kb / 4 ))
available_kb=$(df -Pk "$BOOT_ROOT" | awk 'NR == 2 { print $4 }')
[[ "$available_kb" =~ ^[0-9]+$ ]] ||
	fail "unable to determine the free space on $BOOT_ROOT"
if (( available_kb < needed_kb )); then
	fail "$BOOT_ROOT has $(( available_kb / 1024 )) MiB free but staging a new initramfs needs about $(( needed_kb / 1024 )) MiB. Remove an unused kernel and run this again. $INITRAMFS was left unchanged."
fi

info "rebuilding initramfs for $KVER"

# Build beside the installed image rather than over it. A rebuild that drops the
# input modules leaves an initramfs nobody can type a LUKS passphrase into, and
# on a kernel whose modules live only in the old image that is unrecoverable.
STAGED="$(mktemp "$BOOT_ROOT/.initramfs-$KVER.img.XXXXXX")"
dracut --force --force-drivers "${INPUT_MODULES[*]}" "$STAGED" "$KVER" ||
	fail "dracut failed for $KVER. $INITRAMFS was left unchanged."

listing="$(lsinitrd "$STAGED")"
missing=()
for module in "${INPUT_MODULES[@]}"; do
	grep -Eq "/${module}\.ko([.][a-z0-9]+)?$" <<<"$listing" ||
		missing+=("$module")
done
if (( ${#missing[@]} > 0 )); then
	fail "the rebuilt initramfs for $KVER is missing: ${missing[*]}. $INITRAMFS was left unchanged."
fi

mv -f "$STAGED" "$INITRAMFS"
STAGED=

info "initramfs rebuilt"
