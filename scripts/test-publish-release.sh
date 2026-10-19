#!/usr/bin/env bash
set -euo pipefail
repo_root="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
fake_bin="$tmp/bin"
state="$tmp/state"
dist="$tmp/dist"
mkdir -p "$fake_bin" "$state" "$dist"
log="$tmp/gh.log"
: > "$log"
export MOCK_GH_STATE="$state" MOCK_GH_LOG="$log"
export GH_REPO=test/kernel GH_TOKEN=test-token
export KERNEL_PACKAGE=linux7.3 RELEASE_COMMIT=1111111111111111111111111111111111111111

cat > "$fake_bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_GH_LOG"
[[ "${1:-}" == release ]] || exit 64
command="${2:-}"
tag="${3:-}"
release_dir="$MOCK_GH_STATE/$tag"
assets_dir="$release_dir/assets"
case "$command" in
  view)
    [[ -d "$release_dir" ]] || exit 1
    case " $* " in
      *" --json assets "*) [[ ! -d "$assets_dir" ]] || find "$assets_dir" -maxdepth 1 -type f -printf '%f\n' | sort ;;
      *" --json body "*) cat "$release_dir/body" ;;
      *" --json tagName "*) printf '%s\n' "$tag" ;;
      *) echo "Unexpected mocked gh release view: $*" >&2; exit 64 ;;
    esac
    ;;
  create)
    shift 3
    title="$tag"; body=""
    mkdir -p "$assets_dir"
    while (($#)); do
      case "$1" in
        --title) title="$2"; shift 2 ;;
        --notes) body="$2"; shift 2 ;;
        --target) target="$2"; shift 2 ;;
        --latest) shift ;;
        *)
          [[ -f "$1" ]] || { echo "Missing test asset: $1" >&2; exit 66; }
          cp "$1" "$assets_dir/$(basename "$1")"; shift
          ;;
      esac
    done
    printf '%s' "$title" > "$release_dir/title"
    printf '%s' "$body" > "$release_dir/body"
    printf '%s' "$target" > "$release_dir/target"
    ;;
  download)
    shift 3
    pattern=""; dest=""
    while (($#)); do
      case "$1" in
        --pattern) pattern="$2"; shift 2 ;;
        --dir) dest="$2"; shift 2 ;;
        *) echo "Unexpected download argument: $1" >&2; exit 64 ;;
      esac
    done
    [[ -f "$assets_dir/$pattern" && -n "$dest" ]] || exit 1
    mkdir -p "$dest"; cp "$assets_dir/$pattern" "$dest/"
    ;;
  upload)
    shift 3
    while (($#)); do
      case "$1" in
        --clobber) shift ;;
        *) [[ -f "$1" ]] || exit 66; mkdir -p "$assets_dir"; cp "$1" "$assets_dir/$(basename "$1")"; shift ;;
      esac
    done
    ;;
  delete-asset)
    [[ -f "$assets_dir/${4:-}" ]] || exit 1
    rm "$assets_dir/$4"
    ;;
  edit)
    shift 3
    title="$tag"; body=""
    while (($#)); do
      case "$1" in
        --title) title="$2"; shift 2 ;;
        --notes) body="$2"; shift 2 ;;
        --latest) shift ;;
        *) echo "Unexpected edit argument: $1" >&2; exit 64 ;;
      esac
    done
    printf '%s' "$title" > "$release_dir/title"
    printf '%s' "$body" > "$release_dir/body"
    ;;
  *) echo "Unexpected gh command: $*" >&2; exit 64 ;;
esac
GH
chmod +x "$fake_bin/gh"
export PATH="$fake_bin:$PATH"

make_assets() {
  printf '%s\n' "$2" > "$dist/linux7.3-7.3_$1.x86_64-musl.xbps"
  printf '%s\n' "$3" > "$dist/linux7.3-headers-7.3_$1.x86_64-musl.xbps"
}
assert_release() {
  tag="$1"
  count="$(find "$state/$tag/assets" -maxdepth 1 -type f | wc -l | tr -d ' ')"
  [[ "$count" == 2 ]]
  [[ "$(cat "$state/$tag/title")" == "$tag" ]]
  [[ ! -s "$state/$tag/body" ]]
}

make_assets 1 "kernel bytes" "headers bytes"
bash "$repo_root/scripts/publish-release.sh" "$dist"
assert_release "kernel-7.3_1"
bash "$repo_root/scripts/publish-release.sh" "$dist"
assert_release "kernel-7.3_1"
[[ "$(grep -c '^release create kernel-7.3_1 ' "$log")" == 1 ]]

make_assets 1 "changed kernel bytes" "headers bytes"
if bash "$repo_root/scripts/publish-release.sh" "$dist" >"$tmp/failure.log" 2>&1; then
  echo "Publisher accepted changed bytes at the same revision." >&2
  exit 1
fi
grep -Fq "increment the package revision" "$tmp/failure.log"
[[ "$(cat "$state/kernel-7.3_1/assets/linux7.3-7.3_1.x86_64-musl.xbps")" == "kernel bytes" ]]

rm -f "$dist"/*.xbps
make_assets 2 "kernel bytes revision 2" "headers bytes revision 2"
bash "$repo_root/scripts/publish-release.sh" "$dist"
assert_release "kernel-7.3_2"
echo "kernel release publisher tests passed"
