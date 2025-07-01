#!/bin/bash

# WL-Assistant - Wayland AI Assistant
# Modular helper script for context-aware text generation

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.yml"

# Required binaries
REQUIRED_BINARIES=("yq" "niri" "curl" "jq" "wl-copy" "wl-paste" "fuzzel" "waystt" "ydotool")

# Global variables for current application context
CURRENT_APP_ID=""
CURRENT_WINDOW_TITLE=""

# Background process management
WAYSTT_PID=""
WAYSTT_OUTPUT=""
WAYSTT_TEMP_FILE=""
SELECTED_PROMPT_FILE=""

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

start_waystt() {
    # Create temporary file for output
    WAYSTT_TEMP_FILE=$(mktemp)
    
    # Start waystt in background and capture only stdout (transcription)
    # stderr goes to /dev/null to avoid capturing debug messages
    # Use a subshell to prevent bash from reporting the USR1 signal as an error
    (waystt 2>/dev/null > "$WAYSTT_TEMP_FILE") &
    WAYSTT_PID=$!
    
    # Verify process started successfully
    if ! kill -0 "$WAYSTT_PID" 2>/dev/null; then
        echo "Error: Failed to start waystt" >&2
        cleanup_waystt
        return 1
    fi
    
    return 0
}

stop_waystt() {
    if [[ -n "$WAYSTT_PID" ]]; then
        # Try graceful termination first
        if kill -0 "$WAYSTT_PID" 2>/dev/null; then
            kill "$WAYSTT_PID" 2>/dev/null
            sleep 0.1
            
            # Force kill if still running
            if kill -0 "$WAYSTT_PID" 2>/dev/null; then
                kill -9 "$WAYSTT_PID" 2>/dev/null
            fi
        fi
        WAYSTT_PID=""
    fi
}

kill_waystt() {
    if [[ -n "$WAYSTT_PID" ]]; then
        # Force kill immediately
        if kill -0 "$WAYSTT_PID" 2>/dev/null; then
            kill -9 "$WAYSTT_PID" 2>/dev/null
        fi
        WAYSTT_PID=""
    fi
    
    # Also kill any remaining waystt processes
    pkill -9 waystt 2>/dev/null || true
}

capture_waystt_output() {
    if [[ -n "$WAYSTT_TEMP_FILE" && -f "$WAYSTT_TEMP_FILE" ]]; then
        WAYSTT_OUTPUT=$(cat "$WAYSTT_TEMP_FILE")
    fi
}

cleanup_waystt() {
    stop_waystt
    if [[ -n "$WAYSTT_TEMP_FILE" && -f "$WAYSTT_TEMP_FILE" ]]; then
        rm -f "$WAYSTT_TEMP_FILE"
        WAYSTT_TEMP_FILE=""
    fi
    # Don't clear WAYSTT_OUTPUT here - we need it after cleanup
}

play_success_beep() {
    # Play C-E-G triad beep (261.63Hz, 329.63Hz, 392.00Hz) - approximately 450ms total
    # Using ffplay to generate sine wave tones
    if command -v ffplay &> /dev/null; then
        # Play each note for ~150ms to total ~450ms
        (ffplay -f lavfi -i "sine=frequency=261.63:duration=0.150" -autoexit -nodisp -loglevel quiet 2>/dev/null &
         sleep 0.150
         ffplay -f lavfi -i "sine=frequency=329.63:duration=0.150" -autoexit -nodisp -loglevel quiet 2>/dev/null &
         sleep 0.150
         ffplay -f lavfi -i "sine=frequency=392.00:duration=0.150" -autoexit -nodisp -loglevel quiet 2>/dev/null &) &
    else
        # Fallback to system bell if ffplay is not available
        printf '\a' 2>/dev/null || true
    fi
}

paste_text() {
    local text="$1"
    local paste_combination="$2"
    
    if [[ -z "$text" ]]; then
        echo "Error: No text to paste" >&2
        return 1
    fi
    
    # Default to Ctrl+V if no combination specified
    if [[ -z "$paste_combination" ]]; then
        paste_combination="Ctrl+V"
    fi
    
    # Copy to clipboard using wl-copy
    echo -n "$text" | wl-copy &
    wl_copy_pid=$!
    
    # Give wl-copy a moment to set the clipboard
    local clipboard_delay=$(yq -r '.timeouts.clipboard // 0.05' "$CONFIG_FILE")
    sleep "$clipboard_delay"
    
    # Convert to uppercase for case-insensitive comparison
    local paste_upper="${paste_combination^^}"
    
    # Emulate key combination using ydotool
    case "$paste_upper" in
        "CTRL+V")
            # Ctrl+V: Ctrl(29) + V(47)
            \ydotool key 29:1 47:1 47:0 29:0
            ;;
        "CTRL+SHIFT+V")
            # Ctrl+Shift+V: Ctrl(29) + Shift(42) + V(47)
            \ydotool key 29:1 42:1 47:1 47:0 42:0 29:0
            ;;
        *)
            echo "Warning: Unknown paste combination '$paste_combination', using Ctrl+V" >&2
            \ydotool key 29:1 47:1 47:0 29:0
            ;;
    esac
    
    # Kill wl-copy process
    if kill -0 "$wl_copy_pid" 2>/dev/null; then
        kill -9 "$wl_copy_pid" 2>/dev/null
    fi
    
    return 0
}

paste_sentences() {
    local text="$1"
    local paste_combination="$2"
    
    if [[ -z "$text" ]]; then
        echo "Error: No text to paste" >&2
        return 1
    fi
    
    # Split text into sentences using period as delimiter, preserving whitespace
    local sentences=()
    
    # Use a more robust approach to split sentences while preserving periods and whitespace
    # This regex captures: (sentence ending with period)(whitespace)
    # and creates an array where each element is a complete sentence with its period
    local remaining_text="$text"
    while [[ -n "$remaining_text" ]]; do
        # Match sentence ending with period followed by whitespace, or remaining text at end
        if [[ "$remaining_text" =~ ^([^.]*\.[[:space:]]+)(.*)$ ]]; then
            # Found a sentence with period and trailing space(s)
            sentences+=("${BASH_REMATCH[1]}")
            remaining_text="${BASH_REMATCH[2]}"
        elif [[ "$remaining_text" =~ ^([^.]*\.)$ ]]; then
            # Found final sentence ending with period but no trailing space
            sentences+=("${BASH_REMATCH[1]}")
            remaining_text=""
        else
            # No more periods found - add remaining text as final sentence
            sentences+=("$remaining_text")
            remaining_text=""
        fi
    done
    
    # Get sentence delay from config (default 0.5 seconds between sentences)
    local sentence_delay=$(yq -r '.timeouts.sentence_delay // 0.5' "$CONFIG_FILE")
    
    # Paste each sentence individually
    local sentence_count=0
    for sentence in "${sentences[@]}"; do
        # Skip empty sentences
        if [[ -n "$sentence" && "$sentence" != " " ]]; then
            # Don't trim whitespace - preserve original formatting
            if [[ -n "$sentence" ]]; then
                echo "Pasting sentence $((sentence_count + 1)): ${sentence:0:50}..."
                
                # Paste the sentence using paste_text function
                if ! paste_text "$sentence" "$paste_combination"; then
                    echo "Error: Failed to paste sentence $((sentence_count + 1))" >&2
                    return 1
                fi
                
                sentence_count=$((sentence_count + 1))
                
                # Wait between sentences (except for the last one)
                if [[ $sentence_count -lt ${#sentences[@]} ]]; then
                    sleep "$sentence_delay"
                fi
            fi
        fi
    done
    
    echo "Successfully pasted $sentence_count sentences"
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
    # Set nullglob to handle case when no files match the pattern
    shopt -s nullglob
    for file in "$prompts_dir"/*.yml "$prompts_dir"/*.yaml; do
        if [[ -f "$file" ]]; then
            # Check if the file has an app_id key that matches current app ID
            local file_id=$(yq -r '.app_id // empty' "$file" 2>/dev/null)
            if [[ "$file_id" == "$CURRENT_APP_ID" ]]; then
                matching_files+=("$file")
            fi
        fi
    done
    shopt -u nullglob

    # Output matching file paths only if there are any
    if [[ ${#matching_files[@]} -gt 0 ]]; then
        printf '%s\n' "${matching_files[@]}"
    fi
}

select_prompt() {
    local available_files
    mapfile -t available_files < <(available_prompts)

    local selected_prompt_file=""

    # Handle case when no prompts are available
    if [[ ${#available_files[@]} -eq 0 ]]; then
        # Show paste option and cancel when no prompts available
        local fuzzel_options=("Paste (Ctrl+V)" "Cancel")
        
        local selected_display
        selected_display=$(printf '%s\n' "${fuzzel_options[@]}" | fuzzel --dmenu)
        
        # Handle Cancel selection or no selection
        if [[ -z "$selected_display" || "$selected_display" == "Cancel" ]]; then
            return 1  # Cancel
        fi
        
        # Handle paste selection
        if [[ "$selected_display" == "Paste (Ctrl+V)" ]]; then
            return 2  # Paste action
        fi
        
        return 1  # Default to cancel
    fi

    # Build fuzzel options using titles for all available prompts
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

    # Always add Cancel as the last option
    fuzzel_options+=("Cancel")

    # Use fuzzel to select
    local selected_display
    selected_display=$(printf '%s\n' "${fuzzel_options[@]}" | fuzzel --dmenu)

    # Handle Cancel selection or no selection
    if [[ -z "$selected_display" || "$selected_display" == "Cancel" ]]; then
        return 1  # Cancel
    fi

    # Find the selected prompt file
    for i in "${!file_map[@]}"; do
        if [[ "${fuzzel_options[$i]}" == "$selected_display" ]]; then
            selected_prompt_file="${file_map[$i]}"
            break
        fi
    done

    if [[ -z "$selected_prompt_file" ]]; then
        return 1  # Error
    fi

    # Set the global variable
    SELECTED_PROMPT_FILE="$selected_prompt_file"
    return 0  # Prompt selected
}

call_llm() {
    local system_prompt="$1"
    local prompt="$2"
    local custom_model="$3"
    local api_key="${OPENAI_API_KEY}"
    
    if [[ -z "$api_key" ]]; then
        echo "Error: OPENAI_API_KEY environment variable is not set" >&2
        return 1
    fi
    
    if [[ -z "$system_prompt" ]]; then
        echo "Error: No system prompt provided" >&2
        return 1
    fi
    
    if [[ -z "$prompt" ]]; then
        echo "Error: No prompt provided" >&2
        return 1
    fi
    
    # Get API URL from config
    local api_url=$(yq -r '.llm.api_url' "$CONFIG_FILE")
    
    if [[ "$api_url" == "null" ]]; then
        echo "Error: LLM API URL not found in config.yml" >&2
        return 1
    fi
    
    # Use custom model if provided, otherwise get default from config
    local model
    if [[ -n "$custom_model" ]]; then
        model="$custom_model"
    else
        model=$(yq -r '.llm.default_model' "$CONFIG_FILE")
        if [[ "$model" == "null" ]]; then
            echo "Error: Default model not found in config.yml and no custom model provided" >&2
            return 1
        fi
    fi
    
    # Create JSON payload with proper escaping
    local json_payload
    json_payload=$(jq -n \
        --arg model "$model" \
        --arg system_content "$system_prompt" \
        --arg user_content "$prompt" \
        '{
            model: $model,
            messages: [
                {
                    role: "system",
                    content: $system_content
                },
                {
                    role: "user", 
                    content: $user_content
                }
            ],
            max_tokens: 1000,
            temperature: 0.7
        }')
    
    local response
    # Get timeout from config
    local timeout=$(yq -r '.llm.timeout // 20' "$CONFIG_FILE")
    
    response=$(curl -s --max-time "$timeout" -X POST "$api_url" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $api_key" \
        -d "$json_payload")
    
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to call LLM API" >&2
        return 1
    fi
    
    # Extract content from response
    local content
    content=$(echo "$response" | jq -r '.choices[0].message.content // empty')
    
    if [[ -z "$content" ]]; then
        echo "Error: Empty response from LLM API" >&2
        echo "API Response: $response" >&2
        return 1
    fi
    
    echo "$content"
    return 0
}

call_claude_code() {
    local system_prompt="$1"
    local prompt="$2"
    local custom_model="$3"
    
    if [[ -z "$system_prompt" ]]; then
        echo "Error: No system prompt provided" >&2
        return 1
    fi
    
    if [[ -z "$prompt" ]]; then
        echo "Error: No prompt provided" >&2
        return 1
    fi
    
    if [[ -z "$custom_model" ]]; then
        echo "Error: No custom model provided" >&2
        return 1
    fi
    
    # Extract Claude model (remove claude_code: prefix)
    local claude_model="${custom_model#claude_code:}"
    
    if [[ -z "$claude_model" ]]; then
        echo "Error: Invalid claude_code model format" >&2
        return 1
    fi
    
    # Combine prompts with double newline separator
    local combined_prompt="SYSTEM:\n$system_prompt\n\nUSER:\n$prompt"
    
    # Call Claude CLI with -p flag for non-interactive output
    local response
    response=$(claude -p --model "$claude_model" "$combined_prompt" 2>&1)
    
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to call Claude Code CLI" >&2
        echo "Claude response: $response" >&2
        return 1
    fi
    
    if [[ -z "$response" ]]; then
        echo "Error: Empty response from Claude Code CLI" >&2
        return 1
    fi
    
    echo "$response"
    return 0
}

evaluate_commands_in_prompt() {
    local prompt="$1"
    
    if [[ -z "$prompt" ]]; then
        echo "$prompt"
        return 0
    fi
    
    # Use a while loop to find and replace all command patterns
    local result="$prompt"
    local temp_result
    
    while [[ "$result" =~ \`([^\`]+)\` ]]; do
        local full_match="${BASH_REMATCH[0]}"
        local command="${BASH_REMATCH[1]}"
        
        # Execute the command and capture output
        local command_output
        if command_output=$(eval "$command" 2>/dev/null); then
            # Remove trailing newlines from command output
            command_output="${command_output%$'\n'}"
            # Replace the backtick expression with the command output
            result="${result/$full_match/$command_output}"
        else
            # If command fails, leave the original backtick expression
            echo "Warning: Failed to evaluate command: $command" >&2
            break
        fi
    done
    
    echo "$result"
    return 0
}

# Main execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    validate_dependencies || exit 1
    load_config
    
    # Start waystt to begin recording
    if ! start_waystt; then
        echo "Error: Could not start waystt" >&2
        exit 1
    fi
    
    # Show selection menu
    select_prompt
    exit_code=$?
    
    if [[ $exit_code -eq 1 ]]; then
        # Cancel - kill waystt with SIGKILL
        kill_waystt
        cleanup_waystt
        echo "Cancelled"
    elif [[ $exit_code -eq 0 || $exit_code -eq 2 ]]; then
        # Prompt selected (0) or Paste selected (2) - capture transcription
        if [[ -n "$WAYSTT_PID" ]] && kill -0 "$WAYSTT_PID" 2>/dev/null; then
            kill -USR1 "$WAYSTT_PID"
            
            # Get transcription timeout from config
            max_wait=$(yq -r '.timeouts.transcription // 30' "$CONFIG_FILE")
            elapsed=0
            while [[ $elapsed -lt $max_wait ]]; do
                if ! kill -0 "$WAYSTT_PID" 2>/dev/null; then
                    # Process has exited, give it a moment to flush output
                    sleep 0.2
                    
                    # Capture output
                    capture_waystt_output
                    break
                fi
                sleep 0.5
                elapsed=$((elapsed + 1))
            done
            
            # If process still running after max_wait, assume error and kill it
            if kill -0 "$WAYSTT_PID" 2>/dev/null; then
                echo "Error: waystt transcription timed out" >&2
                kill_waystt
                cleanup_waystt
                exit 1
            fi
        else
            echo "Error: waystt process not running" >&2
            cleanup_waystt
            exit 1
        fi
        
        # Clean up (process should already be stopped)
        cleanup_waystt
        
        if [[ $exit_code -eq 0 ]]; then
            echo "Selected prompt: $SELECTED_PROMPT_FILE"
            echo "Transcription output:"
            echo "$WAYSTT_OUTPUT"
            
            # Process the prompt with LLM
            if [[ -n "$SELECTED_PROMPT_FILE" && -n "$WAYSTT_OUTPUT" ]]; then
                # Extract system prompt from the YAML file
                system_prompt=$(yq -r '.prompt // empty' "$SELECTED_PROMPT_FILE")
                
                if [[ -n "$system_prompt" ]]; then
                    # Evaluate commands in backticks within the system prompt
                    system_prompt=$(evaluate_commands_in_prompt "$system_prompt")
                    
                    echo "Processing with LLM..."
                    
                    # Extract custom model from YAML file if specified
                    custom_model=$(yq -r '.model // empty' "$SELECTED_PROMPT_FILE")
                    
                    # Call LLM with system prompt, transcription, and optional custom model
                    if [[ -n "$custom_model" ]]; then
                        # Check if model uses Claude Code integration
                        if [[ "$custom_model" == claude_code:* ]]; then
                            llm_response=$(call_claude_code "$system_prompt" "$WAYSTT_OUTPUT" "$custom_model")
                        else
                            llm_response=$(call_llm "$system_prompt" "$WAYSTT_OUTPUT" "$custom_model")
                        fi
                    else
                        llm_response=$(call_llm "$system_prompt" "$WAYSTT_OUTPUT")
                    fi
                    
                    if [[ $? -eq 0 && -n "$llm_response" ]]; then
                        echo "LLM processing completed successfully"
                        
                        # Get paste combination from YAML file
                        paste_combination=$(yq -r '.paste_with // "Ctrl+V"' "$SELECTED_PROMPT_FILE")
                        
                        # Get paste_sentences setting from YAML file
                        paste_sentences_enabled=$(yq -r '.paste_sentences // false' "$SELECTED_PROMPT_FILE")
                        
                        if [[ "$paste_sentences_enabled" == "true" ]]; then
                            echo "Pasting LLM response sentence by sentence using $paste_combination..."
                            if paste_sentences "$llm_response" "$paste_combination"; then
                                echo "LLM response pasted successfully"
                                play_success_beep
                            else
                                echo "Error: Failed to paste LLM response" >&2
                            fi
                        else
                            echo "Pasting LLM response using $paste_combination..."
                            if paste_text "$llm_response" "$paste_combination"; then
                                echo "LLM response pasted successfully"
                                play_success_beep
                            else
                                echo "Error: Failed to paste LLM response" >&2
                            fi
                        fi
                    else
                        echo "Error: Failed to get response from LLM" >&2
                    fi
                else
                    echo "Warning: No prompt found in $SELECTED_PROMPT_FILE" >&2
                fi
            fi
        elif [[ $exit_code -eq 2 ]]; then
            echo "Paste action triggered"
            echo "Transcription output:"
            echo "$WAYSTT_OUTPUT"
            
            # Paste transcription using generic paste configuration
            if [[ -n "$WAYSTT_OUTPUT" ]]; then
                # Get paste combination from config
                paste_combination=$(yq -r '.generic_paste.paste_with // "Ctrl+V"' "$CONFIG_FILE")
                
                # Get paste_sentences setting from config
                paste_sentences_enabled=$(yq -r '.generic_paste.paste_sentences // false' "$CONFIG_FILE")
                
                if [[ "$paste_sentences_enabled" == "true" ]]; then
                    echo "Pasting transcription sentence by sentence using $paste_combination..."
                    if paste_sentences "$WAYSTT_OUTPUT" "$paste_combination"; then
                        echo "Text pasted successfully"
                        play_success_beep
                    else
                        echo "Error: Failed to paste text" >&2
                    fi
                else
                    echo "Pasting transcription using $paste_combination..."
                    if paste_text "$WAYSTT_OUTPUT" "$paste_combination"; then
                        echo "Text pasted successfully"
                        play_success_beep
                    else
                        echo "Error: Failed to paste text" >&2
                    fi
                fi
            else
                echo "No transcription to paste"
            fi
        fi
    else
        # Error occurred
        kill_waystt
        cleanup_waystt
        echo "Error occurred"
    fi
fi