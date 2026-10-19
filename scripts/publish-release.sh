#!/usr/bin/env bash
set -euo pipefail

dist_dir="${1:-artifacts}"
kernel_package="${KERNEL_PACKAGE:-linux7.3}"
release_commit="${RELEASE_COMMIT:?RELEASE_COMMIT is required}"
[[ "$kernel_package" =~ ^linux[0-9]+\.[0-9]+$ ]] || { echo "Invalid kernel package family: $kernel_package" >&2; exit 1; }
[[ "$release_commit" =~ ^[0-9a-f]{40}$ ]] || { echo "Invalid release commit SHA." >&2; exit 1; }
[[ -d "$dist_dir" ]] || { echo "Missing artifact directory: $dist_dir" >&2; exit 1; }

shopt -s nullglob
main_packages=( "$dist_dir/$kernel_package"-[0-9]*_*.x86_64-musl.xbps )
if [[ "${#main_packages[@]}" -ne 1 ]]; then
  printf 'Expected exactly one main kernel package, found %s\n' "${#main_packages[@]}" >&2
  exit 1
fi
main_path="${main_packages[0]}"
main_name="$(basename "$main_path")"
version_revision="${main_name#"$kernel_package"-}"
version_revision="${version_revision%.x86_64-musl.xbps}"
version="${version_revision%_*}"
revision="${version_revision##*_}"
[[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "Invalid package version: $version" >&2; exit 1; }
[[ "$revision" =~ ^[0-9]+$ ]] || { echo "Invalid package revision: $revision" >&2; exit 1; }

headers_name="$kernel_package-headers-$version"_"$revision.x86_64-musl.xbps"
headers_path="$dist_dir/$headers_name"
[[ -s "$main_path" ]] || { echo "Kernel package is empty: $main_name" >&2; exit 1; }
[[ -s "$headers_path" ]] || { echo "Matching kernel headers package is missing: $headers_name" >&2; exit 1; }
all_packages=( "$dist_dir"/*.xbps )
if [[ "${#all_packages[@]}" -ne 2 ]]; then
  printf 'Expected only the kernel and its headers packages, found %s XBPS files\n' "${#all_packages[@]}" >&2
  exit 1
fi
for package_path in "${all_packages[@]}"; do
  [[ "$package_path" == "$main_path" || "$package_path" == "$headers_path" ]] || {
    echo "Unexpected package asset: $(basename "$package_path")" >&2
    exit 1
  }
done

release_tag="kernel-${version}_${revision}"
assets=("$main_path" "$headers_path")
asset_names=("$main_name" "$headers_name")
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

if gh release view "$release_tag" --json tagName >/dev/null 2>&1; then
  mapfile -t existing_assets < <(gh release view "$release_tag" --json assets --jq '.assets[].name')
  for i in "${!assets[@]}"; do
    name="${asset_names[$i]}"
    if printf '%s\n' "${existing_assets[@]}" | grep -Fxq -- "$name"; then
      download_dir="$tmp/$i"
      mkdir -p "$download_dir"
      gh release download "$release_tag" --pattern "$name" --dir "$download_dir"
      if [[ ! -s "$download_dir/$name" ]] || ! cmp -s "${assets[$i]}" "$download_dir/$name"; then
        echo "Package bytes changed without a version/revision change: $name; increment the package revision." >&2
        exit 1
      fi
    else
      gh release upload "$release_tag" "${assets[$i]}"
    fi
  done
  for existing_asset in "${existing_assets[@]}"; do
    case "$existing_asset" in
      "$main_name"|"$headers_name") ;;
      *) gh release delete-asset "$release_tag" "$existing_asset" --yes ;;
    esac
  done
  gh release edit "$release_tag" --title "$release_tag" --notes "" --latest
else
  gh release create "$release_tag" "${assets[@]}" \
    --title "$release_tag" --notes "" --target "$release_commit" --latest
fi

body="$(gh release view "$release_tag" --json body --jq '.body // ""')"
if [[ -n "$body" ]]; then
  gh release edit "$release_tag" --title "$release_tag" --notes "" --latest
  body="$(gh release view "$release_tag" --json body --jq '.body // ""')"
fi
[[ -z "$body" ]] || { echo "Release body is not empty: $release_tag" >&2; exit 1; }
mapfile -t published_assets < <(gh release view "$release_tag" --json assets --jq '.assets[].name' | sort)
expected_assets=("$main_name" "$headers_name")
mapfile -t expected_sorted < <(printf '%s\n' "${expected_assets[@]}" | sort)
if [[ "${#published_assets[@]}" -ne 2 ]] ||
   [[ "${published_assets[0]}" != "${expected_sorted[0]}" ]] ||
   [[ "${published_assets[1]}" != "${expected_sorted[1]}" ]]; then
  printf 'Unexpected assets in %s: %s\n' "$release_tag" "${published_assets[*]}" >&2
  exit 1
fi
printf 'Published %s with %s\n' "$release_tag" "${published_assets[*]}"
