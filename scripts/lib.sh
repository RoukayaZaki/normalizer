# shellcheck disable=SC2148

function print_message {
    printf "\n\n\n[[[%s]]]\n\n\n" "$1"
}

export -f print_message

function write_pipeline_lock {

    pipeline_lock_file="$1"
    pipeline_lock_file_new="$2"
    pipeline_config_file="$3"

        cat > "$pipeline_lock_file_new" <<EOF
EO_HEAD_HASH="$(git rev-parse HEAD:eo)"
PIPELINE_CONFIG_HASH="$(git hash-object "$pipeline_config_file")"
EOF

    pipeline_lock_changed=false

    if ! cmp "$pipeline_lock_file" "$pipeline_lock_file_new"; then
        pipeline_lock_changed=true
    fi
}

function update_pipeline_lock {
    pipeline_config="pipeline/config.yaml"
    pipeline_lock_file="pipeline/pipeline.lock"
    pipeline_lock_file_new="pipeline/pipeline_new.lock"

    print_message "Update pipeline lock in $pipeline_lock_file"

    write_pipeline_lock "$pipeline_lock_file" "$pipeline_lock_file_new" "$pipeline_config"

    if [[ "$pipeline_lock_changed" = "true" ]]; then
        print_message "Result: pipeline lock updated"
        mv "$pipeline_lock_file_new" "$pipeline_lock_file"
    else
        print_message "Result: pipeline lock didn't change"
    fi
}

export -f write_pipeline_lock

function mkdir_clean {
    rm -rf "$1"
    mkdir -p "$1"
}

export -f mkdir_clean

function get_eo_version {
    printf "%s" "${EO:-$(yq '.project.parent.version' -p xml < eo/eo-runtime/pom.xml)}"
}

export -f get_eo_version
