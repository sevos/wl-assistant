# WL-Assistant - Wayland AI Assistant

## Project Overview

WL-Assistant is a lightweight AI assistant designed for Wayland window compositors like Hyprland and Niri. It provides context-aware text generation and injection capabilities for different applications.

## Core Features

- **Context-aware prompts**: Define application-specific prompt sets
- **Text injection**: Generate and inject text into active windows
- **Wayland compatibility**: Native support for modern Wayland compositors
- **Fuzzel integration**: Menu-driven prompt selection when multiple options available
- **Lightweight design**: Minimal resource footprint

## Architecture

The assistant operates by:
1. Detecting the currently active application
2. Loading application-specific prompt configurations
3. Presenting available prompts via Fuzzel (when multiple options exist)
4. Generating AI responses based on selected prompts
5. Injecting generated text into the target application (primarily via clipboard/paste)

## Target Applications

Initial focus on common applications:
- Terminal emulators
- Web browsers (Chrome with Gmail, etc.)
- Text editors
- Chat applications

## Technical Stack

- **Language**: Bash scripting
- **Configuration**: YAML files
- **Documentation**: Markdown
- **Wayland Integration**: Native Wayland tools and protocols
- **Menu System**: Fuzzel for prompt selection
- **AI Integration**: curl-based API calls to OpenAI/Anthropic

## Configuration Format

Application-specific prompts defined in YAML:

```yaml
applications:
  - name: "terminal"
    window_class: "kitty"
    prompts:
      - name: "explain_command"
        description: "Explain the last command output"
        system_prompt: "You are a helpful terminal assistant. Explain the command output in simple terms."
        injection_method: "paste"
      - name: "suggest_fix"
        description: "Suggest how to fix an error"
        system_prompt: "You are a debugging assistant. Analyze the error and suggest solutions."
        injection_method: "paste"

  - name: "gmail"
    window_class: "google-chrome"
    window_title_contains: "Gmail"
    prompts:
      - name: "compose_reply"
        description: "Compose a professional reply"
        system_prompt: "Write a professional email response based on the context."
        injection_method: "paste"
```

## Initial Implementation Plan

1. Wayland window detection script using `hyprctl` or similar
2. YAML configuration parser
3. Basic AI API integration with curl
4. Clipboard management for text injection
5. Fuzzel integration for prompt selection
6. Main orchestration script

## Dependencies

- `yq` for YAML parsing
- `wl-clipboard` for clipboard operations
- `fuzzel` for menu selection
- `curl` for AI API calls
- `jq` for JSON processing
- Wayland compositor tools (`hyprctl`, `niri`, etc.)