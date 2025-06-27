#!/bin/bash

# WL-Assistant - Wayland AI Assistant
# Modular helper script for context-aware text generation

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.yml"

# Required binaries
REQUIRED_BINARIES=("yq" "niri" "curl" "jq" "wl-copy" "wl-paste" "fuzzel")

# Global variables for current application context
CURRENT_APP_ID=""
CURRENT_WINDOW_TITLE=""

validate_dependencies() {
    local missing_binaries=()
    
    for binary in "${REQUIRED_BINARIES[@]}"; do
        if ! command -v "$binary" &> /dev/null; then
            missing_binaries+=("$binary")
        fi
    done
    
    if [[ ${#missing_binaries[@]} -ne 0 ]]; then
        echo "Error: Missing required binaries: ${missing_binaries[*]}" >&2
        echo "Please install the missing dependencies and try again." >&2
        return 1
    fi
    
    return 0
}

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "Error: config.yml not found in $SCRIPT_DIR" >&2
        return 1
    fi

    # Extract commands from config.yml
    local app_id_cmd=$(yq -r '.current.app_id' "$CONFIG_FILE")
    local title_cmd=$(yq -r '.current.title' "$CONFIG_FILE")

    if [[ "$app_id_cmd" == "null" || "$title_cmd" == "null" ]]; then
        echo "Error: Invalid configuration in config.yml" >&2
        return 1
    fi

    # Execute commands and set global variables
    CURRENT_APP_ID=$(eval "$app_id_cmd" 2>/dev/null)
    CURRENT_WINDOW_TITLE=$(eval "$title_cmd" 2>/dev/null)

    # Handle empty results
    CURRENT_APP_ID="${CURRENT_APP_ID:-unknown}"
    CURRENT_WINDOW_TITLE="${CURRENT_WINDOW_TITLE:-unknown}"
}

available_prompts() {
    local prompts_dir="$SCRIPT_DIR/prompts"
    local matching_files=()

    if [[ ! -d "$prompts_dir" ]]; then
        return 0
    fi

    # Find all YAML files in prompts directory
    for file in "$prompts_dir"/*.yml "$prompts_dir"/*.yaml; do
        if [[ -f "$file" ]]; then
            # Check if the file has an app_id key that matches current app ID
            local file_id=$(yq -r '.app_id // empty' "$file" 2>/dev/null)
            if [[ "$file_id" == "$CURRENT_APP_ID" ]]; then
                matching_files+=("$file")
            fi
        fi
    done

    # Output matching file paths
    printf '%s\n' "${matching_files[@]}"
}

select_prompt() {
    local available_files
    mapfile -t available_files < <(available_prompts)

    # Return empty if no prompts available
    if [[ ${#available_files[@]} -eq 0 ]]; then
        return 1
    fi

    # If only one prompt available, return it directly
    if [[ ${#available_files[@]} -eq 1 ]]; then
        echo "${available_files[0]}"
        return 0
    fi

    # Build fuzzel options using titles
    local fuzzel_options=()
    local file_map=()

    for file in "${available_files[@]}"; do
        local title=$(yq -r '.title // empty' "$file" 2>/dev/null)
        
        # Use filename if no title is defined
        if [[ -z "$title" ]]; then
            title=$(basename "$file" .yml)
            title=$(basename "$title" .yaml)
        fi

        fuzzel_options+=("$title")
        file_map+=("$file")
    done

    # Use fuzzel to select
    local selected_index
    local selected_display
    selected_display=$(printf '%s\n' "${fuzzel_options[@]}" | fuzzel --dmenu)

    # Find the index of selected option
    for i in "${!fuzzel_options[@]}"; do
        if [[ "${fuzzel_options[$i]}" == "$selected_display" ]]; then
            selected_index=$i
            break
        fi
    done

    # Return the corresponding file path
    if [[ -n "$selected_index" ]]; then
        echo "${file_map[$selected_index]}"
        return 0
    else
        return 1
    fi
}

# Main execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    validate_dependencies || exit 1
    load_config
    select_prompt
fi