# shellcheck shell=bash
# doctor.sh — fail-fast prereq check.
#
# Why ibazel is mandatory: dev.sh's contract is "hot-reload dev environment".
# Without ibazel, host services can't pick up `.go` edits without manual
# restart, breaking the contract. CI installs ibazel explicitly (see
# .github/workflows/bazel.yml) — no fallback in this script.

check_ibazel_doctor() {
    local missing=()
    command -v bazel  >/dev/null 2>&1 || missing+=("bazel (bazelisk)")
    command -v ibazel >/dev/null 2>&1 || missing+=("ibazel (bazel-watcher)")
    if (( ${#missing[@]} > 0 )); then
        error "缺少必需工具：${missing[*]}"
        echo "  bazel:   brew install bazelisk (macOS) | bazelisk releases (Linux)"
        echo "  ibazel:  https://github.com/bazelbuild/bazel-watcher/releases"
        echo "           (no homebrew formula — grab the darwin-arm64 / linux-amd64 binary)"
        exit 1
    fi

    # AI CLIs are runner-pod prereqs — warn (don't fail) so backend / relay
    # come up for non-pod work even when CLIs aren't installed.
    local ai_missing=()
    command -v claude >/dev/null 2>&1 || ai_missing+=("claude")
    command -v codex  >/dev/null 2>&1 || ai_missing+=("codex")
    command -v gemini >/dev/null 2>&1 || ai_missing+=("gemini")
    if (( ${#ai_missing[@]} > 0 )); then
        warn "AI CLI 未全装（${ai_missing[*]}）— runner pod 创建会受限"
        echo "  npm i -g @anthropic-ai/claude-code @openai/codex @google/gemini-cli"
    fi
}

check_codex_sandbox_doctor() {
    [[ "$(uname -s)" == "Linux" ]] || return 0

    if [[ -r /proc/sys/kernel/unprivileged_userns_clone ]]; then
        local enabled
        enabled="$(< /proc/sys/kernel/unprivileged_userns_clone)"
        if [[ "$enabled" != "1" ]]; then
            error "Codex sandbox nebude v host runneru fungovat: kernel.unprivileged_userns_clone=$enabled"
            cat << 'EOF'
    sudo sysctl -w kernel.unprivileged_userns_clone=1
    echo 'kernel.unprivileged_userns_clone=1' | sudo tee /etc/sysctl.d/99-agentsmesh-codex.conf
    sudo sysctl --system
EOF
            exit 1
        fi
    fi

    if [[ -r /proc/sys/user/max_user_namespaces ]]; then
        local max_userns
        max_userns="$(< /proc/sys/user/max_user_namespaces)"
        if [[ "$max_userns" == "0" ]]; then
            error "Codex sandbox nebude v host runneru fungovat: user.max_user_namespaces=0"
            cat << 'EOF'
    sudo sysctl -w user.max_user_namespaces=28633
    echo 'user.max_user_namespaces=28633' | sudo tee /etc/sysctl.d/99-agentsmesh-codex.conf
    sudo sysctl --system
EOF
            exit 1
        fi
    fi
}
