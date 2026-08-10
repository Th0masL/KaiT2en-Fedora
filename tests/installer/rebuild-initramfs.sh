#!/usr/bin/env bash

set -Eeuo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
rebuild="$repo_root/scripts/fedora/rebuild-initramfs.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/kait2en-rebuild-initramfs-test.XXXXXX")
trap 'rm -rf "$work"' EXIT

target=7.1.7-200.fc44.x86_64
all_modules='t2bce_dma t2hid hid_t2magicmouse t2bce_core t2bce_vhci'
fake_boot="$work/boot"
fake_bin="$work/bin"
log="$work/commands.log"
initramfs="$fake_boot/initramfs-$target.img"
mkdir -p "$fake_boot" "$fake_bin"

cat >"$fake_bin/modinfo" <<'EOF'
#!/usr/bin/env bash
module=${*: -1}
if [[ " $KAIT2EN_TEST_INSTALLED_MODULES " == *" $module "* ]]; then
	printf '/usr/lib/modules/test/extra/%s.ko.xz\n' "$module"
	exit 0
fi
exit 1
EOF
cat >"$fake_bin/dracut" <<'EOF'
#!/usr/bin/env bash
printf 'dracut %s\n' "$*" >>"$KAIT2EN_TEST_LOG"
if [[ ${KAIT2EN_TEST_DRACUT_FAIL:-0} != 0 ]]; then
	exit 1
fi
arguments=("$@")
printf 'rebuilt\n' >"${arguments[${#arguments[@]} - 2]}"
EOF
cat >"$fake_bin/df" <<'EOF'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf 'fake 100000000 1 %s 1%% %s\n' "${KAIT2EN_TEST_FREE_KB:-10000000}" "${2:-/}"
EOF
cat >"$fake_bin/lsinitrd" <<'EOF'
#!/usr/bin/env bash
for module in t2bce_dma t2hid hid_t2magicmouse t2bce_core t2bce_vhci; do
	if [[ "$module" == "${KAIT2EN_TEST_OMIT_MODULE:-}" ]]; then
		continue
	fi
	printf 'usr/lib/modules/test/updates/kait2en/%s.ko\n' "$module"
done
EOF
chmod 0755 "$fake_bin"/*

reset_image() {
	: >"$log"
	printf 'installed\n' >"$initramfs"
}

run_rebuild() {
	env \
		PATH="$fake_bin:/usr/sbin:/usr/bin:/sbin:/bin" \
		KAIT2EN_TEST_MODE=1 \
		KAIT2EN_BOOT_ROOT="$fake_boot" \
		KERNEL_RELEASE="$target" \
		KAIT2EN_TEST_LOG="$log" \
		KAIT2EN_TEST_INSTALLED_MODULES="${1:-$all_modules}" \
		KAIT2EN_TEST_DRACUT_FAIL="${2:-0}" \
		KAIT2EN_TEST_OMIT_MODULE="${3:-}" \
		KAIT2EN_TEST_FREE_KB="${4:-10000000}" \
		bash "$rebuild"
}

assert_image_untouched() {
	local reason=$1
	if [[ $(cat "$initramfs") != installed ]]; then
		printf 'the installed initramfs was replaced after %s\n' "$reason" >&2
		exit 1
	fi
}

assert_no_leftovers() {
	local reason=$1 leftover
	leftover=$(find "$fake_boot" -maxdepth 1 -name '.initramfs-*' -print -quit)
	if [[ -n "$leftover" ]]; then
		printf 'a staged initramfs was left behind after %s: %s\n' \
			"$reason" "$leftover" >&2
		exit 1
	fi
}

# The modules must be forced in. Relying on host-only autodetection is what
# produced initramfs images with none of them.
reset_image
run_rebuild >/dev/null
grep -Fq "dracut --force --force-drivers $all_modules" "$log"
[[ $(cat "$initramfs") == rebuilt ]]
assert_no_leftovers 'a successful rebuild'

# A kernel without the modules installed must be refused before dracut runs,
# while the image that still boots the machine is intact.
reset_image
if run_rebuild 't2bce_dma t2bce_core t2bce_vhci' >/dev/null 2>&1; then
	printf 'the rebuild unexpectedly succeeded without t2hid installed\n' >&2
	exit 1
fi
[[ ! -s "$log" ]]
assert_image_untouched 'a kernel missing the input modules'
assert_no_leftovers 'a kernel missing the input modules'

# Staging needs room for a second image. Too little must be reported as such,
# before dracut starts writing, rather than surfacing as an mktemp failure.
reset_image
if run_rebuild "$all_modules" 0 '' 4096 >/dev/null 2>&1; then
	printf 'the rebuild unexpectedly succeeded with a full boot filesystem\n' >&2
	exit 1
fi
[[ ! -s "$log" ]]
assert_image_untouched 'a full boot filesystem'
assert_no_leftovers 'a full boot filesystem'

# A failing dracut must not consume the installed image either.
reset_image
if run_rebuild "$all_modules" 1 >/dev/null 2>&1; then
	printf 'the rebuild unexpectedly succeeded after a dracut failure\n' >&2
	exit 1
fi
assert_image_untouched 'a dracut failure'
assert_no_leftovers 'a dracut failure'

# Nor may an image that dracut built without one of the modules be installed.
reset_image
if run_rebuild "$all_modules" 0 t2hid >/dev/null 2>&1; then
	printf 'the rebuild unexpectedly accepted an initramfs without t2hid\n' >&2
	exit 1
fi
assert_image_untouched 'an incomplete rebuild'
assert_no_leftovers 'an incomplete rebuild'

printf 'Initramfs rebuild checks passed.\n'
