#!/usr/bin/env bash

# Intended to be run in the top directory.
# We need to set Authorization and User-Agent headers.
# Env var:
#   GITHUB_OAUTH_TOKEN: OAuth token for GitHub
# Arguments:
#   [tag_name] [release_name] [release_note_path] [asset_path]..
#
# You can generate OAuth tokens from https://github.com/settings/tokens

function get_content_type() {
    local file_name="$1"
    if [[ "${file_name}" =~ (.*)\.zip$ ]]; then
        printf "%s" "application/zip"
    elif [[ "${file_name}" =~ (.*)\.tar\.gz$ ]]; then
        printf "%s" "application/gzip"
    fi
}

function push_release() {
    local repository="dora-gt/interledger-rs"
    local user_agent="curl-on-CircleCI"
    local tag_name="$1"
    local release_name="$2"
    local release_note_path="$3"
    shift 3

    if [ -z "${tag_name}" ]; then
        printf "%s\n" "tag name is required."
        exit 1
    fi
    if [ -z "${release_name}" ]; then
        printf "%s\n" "release name is required."
        exit 1
    fi
    if [ -z "${release_note_path}" ]; then
        printf "%s\n" "release note path is required."
        exit 1
    fi
    if [ ! -e "${release_note_path}" ] || [ ! -f "${release_note_path}" ]; then
        printf "%s\n" "release note file was not found."
        exit 1
    fi
    if [ ! $# -ge 1 ]; then
        printf "%s\n" "asset path(s) is required."
        exit 1
    fi

    printf "%s" "Checking tag: ${tag_name}..."
    tags=$(curl \
        -X GET \
        -H "User-Agent: ${user_agent}" \
        -H "Authorization: token ${GITHUB_OAUTH_TOKEN}" \
        -H "Accept: application/vnd.github.v3+json" \
        https://api.github.com/repos/${repository}/tags 2>/dev/null | jq 'map(select(.name == "'${tag_name}'"))|length')
    if [ ! $tags -ge 1 ]; then
        printf "%s\n" "Tag: ${tag_name} was not found on repository: ${repository}"
        exit 1
    fi
    printf "%s\n" "done"

    release_note=$(cat "${release_note_path}")
    json=$(printf '{
      "tag_name": "%s",
      "name": "%s",
      "body": "%s"
    }' "${tag_name}" "${release_name}" "${release_note}")

    printf "%s" "Creating a release: ${release_name}..."
    curl \
        -X POST \
        -H "User-Agent: ${user_agent}" \
        -H "Authorization: token ${GITHUB_OAUTH_TOKEN}" \
        -H "Accept: application/vnd.github.v3+json" \
        -d "${json}" \
        https://api.github.com/repos/${repository}/releases 2>/dev/null >logs/release.json
    printf "%s\n" "done"

    asset_upload_url=$(cat logs/release.json | jq -r ".upload_url")
    asset_upload_url=${asset_upload_url/\{\?name,label\}/}

    for asset_path in $@
    do
        file_name=$(basename "${asset_path}")
        content_type=$(get_content_type "${file_name}")
        printf "%s" "Uploading an asset: ${file_name}..."
        cat "${asset_path}" | curl \
            -X POST \
            -H "User-Agent: curl-on-CircleCI" \
            -H "Authorization: token ${GITHUB_OAUTH_TOKEN}" \
            -H "Content-Type: ${content_type}" \
            -d @- \
            ${asset_upload_url}?name=${file_name} 2>/dev/null >logs/asset_${file_name}.json || exit 2
        printf "%s\n" "done"
    done
}

if [ ! $# -ge 3 ]; then
    printf "%s\n" "missing parameter(s)."
    exit 1
fi

mkdir -p logs

push_release $@
