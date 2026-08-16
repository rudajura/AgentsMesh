# shellcheck shell=bash
# Production-mode Next.js launchers for the local dev environment.

_start_frontend_prod() {
    local web_port="$1" log_file="$2" root_dir="$3" bazel_output_base="$4"
    local saved_dir="$PWD"

    info "Building frontend production bundle..."
    cd "$root_dir" || return 1
    # next.config.ts's rewrites()/env{} read process.env at `next build` time
    # and get baked into .next/routes-manifest.json — next start replays that
    # manifest rather than re-evaluating the config. Bazel build actions are
    # sandboxed, so the env assignments below (visible to the bazel client)
    # never reach the action unless forwarded via --action_env; without it,
    # the API proxy rewrite silently compiles out and every /proto.* request
    # 404s against Next's own router instead of reaching the backend.
    local -a action_env_flags=(
        --action_env=API_PROXY_TARGET
        --action_env=AGENTSMESH_DEV_FRONTEND_MODE
        --action_env=AGENTSMESH_DEV_FRONTEND_PROXY
        --action_env=NEXT_PUBLIC_E2E
        --action_env=PRIMARY_DOMAIN
        --action_env=USE_HTTPS
    )
    if ! PORT="$web_port" \
        API_PROXY_TARGET="http://localhost:$HTTP_PORT" \
        AGENTSMESH_DEV_FRONTEND_MODE="prod" \
        AGENTSMESH_DEV_FRONTEND_PROXY="true" \
        NEXT_PUBLIC_E2E="true" \
        PRIMARY_DOMAIN="localhost:$HTTP_PORT" \
        USE_HTTPS="false" \
        bazel --output_base="$bazel_output_base" build //clients/web:next "${action_env_flags[@]}" > "$log_file" 2>&1; then
        cd "$saved_dir" || return 1
        error "Frontend production build failed; see $log_file"
        return 1
    fi
    PORT="$web_port" \
    API_PROXY_TARGET="http://localhost:$HTTP_PORT" \
    AGENTSMESH_DEV_FRONTEND_MODE="prod" \
    AGENTSMESH_DEV_FRONTEND_PROXY="true" \
    NEXT_PUBLIC_E2E="true" \
    PRIMARY_DOMAIN="localhost:$HTTP_PORT" \
    USE_HTTPS="false" \
        bazel --output_base="$bazel_output_base" run //clients/web:next_start "${action_env_flags[@]}" >> "$log_file" 2>&1 < /dev/null &
    disown $!
    cd "$saved_dir" || return 1
}

_start_admin_frontend_prod() {
    local web_admin_port="$1" log_file="$2" root_dir="$3" bazel_output_base="$4"
    local saved_dir="$PWD"

    info "Building Admin Console production bundle..."
    cd "$root_dir" || return 1
    # Same sandboxing gap as _start_frontend_prod above: next.config.ts's
    # rewrites() bakes PRIMARY_DOMAIN/USE_HTTPS in at `next build` time, and
    # Bazel build actions don't see the invoking shell's env without
    # --action_env.
    local -a action_env_flags=(
        --action_env=PRIMARY_DOMAIN
        --action_env=USE_HTTPS
        --action_env=AGENTSMESH_DEV_FRONTEND_MODE
    )
    if ! PORT="$web_admin_port" \
        PRIMARY_DOMAIN="localhost:$HTTP_PORT" \
        USE_HTTPS="false" \
        AGENTSMESH_DEV_FRONTEND_MODE="prod" \
        bazel --output_base="$bazel_output_base" build //clients/web-admin:next "${action_env_flags[@]}" > "$log_file" 2>&1; then
        cd "$saved_dir" || return 1
        error "Admin Console production build failed; see $log_file"
        return 1
    fi
    PORT="$web_admin_port" \
    PRIMARY_DOMAIN="localhost:$HTTP_PORT" \
    USE_HTTPS="false" \
    AGENTSMESH_DEV_FRONTEND_MODE="prod" \
        bazel --output_base="$bazel_output_base" run //clients/web-admin:next_start "${action_env_flags[@]}" >> "$log_file" 2>&1 < /dev/null &
    disown $!
    cd "$saved_dir" || return 1
}
