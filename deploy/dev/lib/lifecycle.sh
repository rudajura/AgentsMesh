# shellcheck shell=bash
# shellcheck disable=SC1090
# lifecycle.sh — start / stop / status / banner.
#
# Frontend launch goes through Bazel so `@agentsmesh/*` packages linked at
# //:node_modules are visible to Next.js in dev and production-start modes.
#
# `clean` tears down everything dev.sh created (host pids, frontend ports,
# docker volumes, .env). `reset_runners` is the targeted "rebuild + restart
# host runner" path used after a runner-only code change.

print_banner() {
    echo ""
    echo "=========================================="
    echo "  AgentsMesh 开发环境初始化"
    echo "=========================================="
    echo ""
}

print_usage() {
    cat << 'EOF'
用法:
  bazel run //deploy/dev:up                 # 一键启动完整开发环境
  bazel run //deploy/dev:up_prod_frontend   # build frontend once + next start
  bazel run //deploy/dev:backend_only       # 仅启动 docker + host backend/relay (CI)
  bazel run //deploy/dev:rebuild_runner     # 重 build host runner + 重启 runner
  bazel run //deploy/dev:reset_runners      # 重启 host runner+relay (backend 不动)
  bazel run //deploy/dev:clean              # 停止并清理所有服务

  或直接调脚本（backward-compat）:
  ./dev.sh [--backend-only|--prod-frontend|--dev-frontend|--rebuild-runner|--reset-runners|--clean|--help]

  改动 backend / relay 源码: ibazel 自动重 build (host)
  改动 runner 源码:        bazel run //deploy/dev:rebuild_runner

前端日志: tail -f deploy/dev/web.log
EOF
}

# `docker compose up -d` with a 3-attempt retry loop. Docker Hub fetches are
# flaky on fresh CI runners, so retries beat hard-fail every time.
docker_compose_up() {
    info "启动 Docker 基础设施 (runner 在 host 上运行，首次可能需要几分钟)..."
    local up_attempt=0
    local up_max=3
    local services=(postgres redis minio gitea adminer traefik jaeger otel-collector)
    while [ $up_attempt -lt $up_max ]; do
        up_attempt=$((up_attempt + 1))
        # set -o pipefail so docker compose's non-zero exit (auth.docker.io
        # token timeouts, build failures) actually fails the pipe — without
        # it grep returns 0 even if compose crashed and the loop exits
        # success'fully' while postgres is missing.
        if (set -o pipefail; docker compose up -d --quiet-pull "${services[@]}" 2>&1 | grep -v "^#" | grep -v "^\[" | grep -v "^$"); then
            break
        fi
        if [ $up_attempt -eq $up_max ]; then
            error "Docker compose up failed after $up_max attempts"
            exit 1
        fi
        warn "compose up failed (attempt $up_attempt/$up_max) — retrying in 10s"
        sleep 10
    done
    docker compose stop runner runner-2 >/dev/null 2>&1 || true
    success "Docker 基础设施已启动"
}

wait_for_postgres() {
    local pg_container="${COMPOSE_PROJECT_NAME}-postgres-1"
    info "等待 PostgreSQL 就绪..."
    if ! wait_for_service "$pg_container" "pg_isready -U agentsmesh"; then
        error "PostgreSQL 启动超时"
        exit 1
    fi
    success "PostgreSQL 已就绪"
}

# Rebuild host runner artifacts, restart relay and runner, keep backend up.
reset_runners() {
    if [[ -f "$ENV_FILE" ]]; then
        source "$ENV_FILE"
    else
        generate_env
        source "$ENV_FILE"
    fi

    echo ""
    echo "=========================================="
    echo "  Reset Runner (rebuild bazel binary + restart host runner)"
    echo "=========================================="
    echo ""

    check_codex_sandbox_doctor
    generate_ssl_certs
    generate_ai_cli_configs
    generate_runner_ssh_key
    setup_gitea_ssh_config
    _stop_host_service runner
    _stop_host_service relay
    start_relay_host || return 1
    start_runner_host || return 1
    success "Host runner 已重启"

    echo ""
}

# Tear down everything dev.sh creates: host service pids, frontend port
# squatters, docker volumes, .env. Safe to re-run.
clean() {
    if [[ -f "$ENV_FILE" ]]; then
        source "$ENV_FILE"
    fi
    local web_port="${WEB_PORT:-3000}"
    local web_admin_port="${WEB_ADMIN_PORT:-3001}"

    info "停止 host-side ibazel 服务..."
    stop_host_services
    success "host-side 服务已停止"

    if lsof -i :"$web_port" &>/dev/null; then
        info "停止前端服务 (端口: $web_port)..."
        lsof -ti :"$web_port" | xargs kill -9 2>/dev/null || true
        success "前端服务已停止"
    fi

    if lsof -i :"$web_admin_port" &>/dev/null; then
        info "停止 Admin Console (端口: $web_admin_port)..."
        lsof -ti :"$web_admin_port" | xargs kill -9 2>/dev/null || true
        success "Admin Console 已停止"
    fi

    # next_dev is a long-running Bazel invocation. Web and Admin use isolated
    # output bases so normal builds/tests cannot evict them; shut those servers
    # down explicitly before removing their caches.
    local frontend frontend_output_base
    for frontend in web web-admin; do
        frontend_output_base=$(_frontend_bazel_output_base "$frontend")
        if [[ -d "$frontend_output_base" ]]; then
            bazel --output_base="$frontend_output_base" shutdown >/dev/null 2>&1 || true
            _remove_frontend_bazel_output_base "$frontend_output_base"
        fi
    done

    rm -f "$SCRIPT_DIR/web.log"
    rm -f "$SCRIPT_DIR/web-admin.log"
    rm -rf "$(_runtime_dir)"

    if [[ -f "$ENV_FILE" ]]; then
        info "清理 Docker 环境: ${COMPOSE_PROJECT_NAME:-agentsmesh}..."
        cd "$SCRIPT_DIR" || return 1
        docker compose down -v --remove-orphans 2>/dev/null || true
        rm -f "$ENV_FILE"
        success "清理完成"
    else
        warn "Docker 环境未初始化"
    fi
}

show_result() {
    source "$ENV_FILE"

    echo ""
    echo "=========================================="
    echo "  AgentsMesh 开发环境已就绪!"
    echo "=========================================="
    echo ""
    echo "  前端:       http://localhost:$WEB_PORT"
    echo "  Admin:      http://localhost:$WEB_ADMIN_PORT"
    echo "  API:        http://localhost:$HTTP_PORT/api  (→ host backend :$BACKEND_HTTP_PORT)"
    echo "  Relay:      ws://localhost:$HTTP_PORT/relay  (→ host relay :$RELAY_HTTP_PORT)"
    echo "  gRPC mTLS:  grpcs://localhost:$GRPC_PORT      (→ host backend :$BACKEND_GRPC_PORT)"
    echo ""
    echo "  Host services (ibazel hot-reload):"
    echo "    backend  日志: tail -f deploy/dev/runtime/backend/backend.log"
    echo "    relay    日志: tail -f deploy/dev/runtime/relay/relay.log"
    echo ""
    echo "  Host runner:"
    echo "    日志: tail -f deploy/dev/runtime/runner/runner.log"
    echo "    workspace: $(host_runner_workspace_root)"
    echo "    重 build: ./dev.sh --rebuild-runner"
    echo ""
    echo "  测试账号:   dev@agentsmesh.local / devpass123"
    echo "  管理员:     admin@agentsmesh.local / adminpass123"
    echo ""
    echo "  其他服务:"
    echo "    Gitea:    http://localhost:$GITEA_HTTP_PORT (gitea-admin / gitea-admin-123)"
    echo "    Traefik:  http://localhost:$TRAEFIK_DASHBOARD_PORT (Dashboard)"
    echo "    Adminer:  http://localhost:$ADMINER_PORT"
    echo "    MinIO:    http://localhost:$MINIO_CONSOLE_PORT"
    echo "    Jaeger:   http://localhost:$JAEGER_UI_PORT (Tracing UI)"
    echo ""
    echo "  停止: ./dev.sh --clean"
    echo "  仅重 build runner: ./dev.sh --rebuild-runner"
    echo ""
}
