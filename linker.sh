#!/bin/bash

# Linker - Headscale自动化部署管理脚本
# Author: Assistant
# Version: 2.0.0

set -euo pipefail

# 全局变量
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yaml"

CONFIG_DIR="${SCRIPT_DIR}/config"
DATA_DIR="${SCRIPT_DIR}/data"
IMAGES_DIR="${SCRIPT_DIR}/images"
PKG_DIR="${SCRIPT_DIR}/pkg"
LOCK_FILE="${SCRIPT_DIR}/.install.lock"
BACKUP_DIR="${SCRIPT_DIR}/.backup"

# 立即初始化颜色支持
init_colors_now() {
    # 简化的颜色检测逻辑
    local use_colors=false
    
    # 检查环境变量强制设置
    if [[ "${NO_COLOR:-}" == "1" ]] || [[ "${NO_COLOR:-}" == "true" ]]; then
        use_colors=false
    elif [[ "${FORCE_COLOR:-}" == "1" ]] || [[ "${FORCE_COLOR:-}" == "true" ]]; then
        use_colors=true
    else
        # 恢复正常的颜色检测逻辑
        # 因为日志函数（log_info, log_error等）确实能正常显示颜色
        use_colors=true
        
        # 检查明确不支持颜色的情况
        case "${TERM:-}" in
            dumb|unknown|"")
                use_colors=false
                ;;
        esac
        
        # 如果输出被重定向，禁用颜色
        if [[ ! -t 1 ]]; then
            use_colors=false
        fi
    fi
    
    if [[ "$use_colors" == "true" ]]; then
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
        NC='\033[0m'
    else
        RED=''
        GREEN=''
        YELLOW=''
        BLUE=''
        PURPLE=''
        CYAN=''
        WHITE=''
        NC=''
    fi
}

# 立即初始化颜色
init_colors_now

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# 进度显示
show_progress() {
    local current=$1
    local total=$2
    local desc=$3
    local percent=$((current * 100 / total))
    local bar_length=50
    local filled_length=$((percent * bar_length / 100))
    
    printf "\r${CYAN}[%3d%%]${NC} [" "$percent"
    printf "%*s" "$filled_length" | tr ' ' '='
    printf "%*s" $((bar_length - filled_length)) | tr ' ' '-'
    printf "] %s" "$desc"
}

# 清理函数
cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 && -f "$LOCK_FILE" ]]; then
        log_error "安装过程中发生错误，正在执行回滚..."
        rollback_installation
    fi
    # 清理锁文件
    [[ -f "$LOCK_FILE" ]] && rm -f "$LOCK_FILE"
    exit $exit_code
}

# 设置信号处理
trap cleanup EXIT INT TERM

# 并发安全检查
check_concurrent_install() {
    if [[ -f "$LOCK_FILE" ]]; then
        local lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
            log_error "另一个安装进程正在运行 (PID: $lock_pid)"
            exit 1
        else
            log_warn "发现陈旧的锁文件，清理中..."
            rm -f "$LOCK_FILE"
        fi
    fi
    
    # 创建锁文件
    echo $$ > "$LOCK_FILE"
}

# 检查必要的模板文件
check_template_files() {
    log_step "检查配置文件模板..."
    
    local required_files=(
        "${CONFIG_DIR}/headscale/config.yaml"
        "${CONFIG_DIR}/headscale/derp.yaml"
        "${COMPOSE_FILE}"
    )
    
    local missing_files=()
    
    for file in "${required_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            missing_files+=("$file")
        fi
    done
    
    if [[ ${#missing_files[@]} -gt 0 ]]; then
        log_error "缺少必要的配置文件:"
        for file in "${missing_files[@]}"; do
            echo "  - $file"
        done
        return 1
    fi
    
    log_success "所有配置文件检查通过"
    return 0
}

# 创建默认模板文件
create_default_templates() {
    log_step "创建默认模板文件..."
    
    # 创建目录
    mkdir -p "${CONFIG_DIR}/headscale" "${BACKUP_DIR}"
    
    log_info "使用现有配置文件作为模板"
    log_success "模板文件已存在，无需创建"
}

# 检测操作系统
detect_os() {
    if [[ -f /etc/centos-release ]]; then
        echo "centos"
    elif [[ -f /etc/lsb-release ]] && grep -q "Ubuntu" /etc/lsb-release; then
        echo "ubuntu"
    elif [[ -f /etc/debian_version ]]; then
        echo "debian"
    else
        echo "unknown"
    fi
}

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 检查是否已部署 - 基础配置检查
check_basic_deployment() {
    local config_file="$COMPOSE_FILE"
    
    # 检查配置文件是否存在
    if [[ ! -f "$config_file" ]]; then
        log_error "配置文件不存在: $config_file"
        log_info "请先运行安装命令: $0 install --ip <YOUR_IP>"
        return 1
    fi
    
    # 检查配置文件是否包含未替换的模板变量
    if grep -q "{{.*}}" "$config_file"; then
        log_error "服务未部署，配置文件未完成初始化"
        log_info "请先运行安装命令: $0 install --ip <YOUR_IP>"
        return 1
    fi
    
    # 检查Docker是否可用
    if ! command_exists docker; then
        log_error "Docker未安装或不可用"
        log_info "请先运行安装命令: $0 install --ip <YOUR_IP>"
        return 1
    fi
    
    return 0
}

# 检查是否已部署 - 完整检查（包括运行状态）
check_deployment_status() {
    local allow_stopped=${1:-false}  # 是否允许服务停止状态
    
    # 先进行基础配置检查
    if ! check_basic_deployment; then
        return 1
    fi
    
    # 如果允许停止状态（如start命令），则不检查运行状态
    if [[ "$allow_stopped" == "true" ]]; then
        return 0
    fi
    
    # 检查服务是否实际运行
    local running_containers=0
    if docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^headscale$"; then
        running_containers=$((running_containers + 1))
    fi
    if docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^headscale_derp$"; then
        running_containers=$((running_containers + 1))
    fi
    
    # 如果配置文件已初始化但服务未运行，给出不同的提示
    if [[ $running_containers -eq 0 ]]; then
        log_error "服务未部署，未检测到运行中的容器"
        log_info "可尝试启动服务: $0 start"
        return 1
    fi
    
    return 0
}

# 检查是否已部署（配置已初始化）
check_already_deployed() {
    if [[ -f "$COMPOSE_FILE" ]] && ! grep -q "{{.*}}" "$COMPOSE_FILE"; then
        return 0  # 已部署
    fi
    return 1  # 未部署
}

# 检查服务是否运行中
check_services_running() {
    local headscale_running=false
    local derp_running=false
    
    if docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^headscale$"; then
        headscale_running=true
    fi
    if docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^headscale_derp$"; then
        derp_running=true
    fi
    
    [[ "$headscale_running" == "true" && "$derp_running" == "true" ]]
}

# 记录部署信息
record_deployment_info() {
    local public_ip=$1
    local headscale_port=$2
    local derp_port=$3
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local readable_time=$(date '+%Y-%m-%d %H:%M:%S')
    
    mkdir -p "${DATA_DIR}"
    cat > "${DATA_DIR}/deployment.info" << EOF
DEPLOYED_TIME="$readable_time"
DEPLOYED_TIMESTAMP=$timestamp
PUBLIC_IP=$public_ip
HEADSCALE_PORT=$headscale_port
DERP_PORT=$derp_port
VERSION=v2.0.0
EOF
}

# 安装全局 headscale 命令
install_global_headscale_command() {
    log_step "安装全局 headscale 命令..."
    
    # 创建全局 headscale 命令包装器
    sudo tee /usr/local/bin/headscale >/dev/null << 'EOF'
#!/bin/bash
# Headscale 全局命令包装器
if ! docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^headscale$"; then
    echo -e "\033[0;31m[ERROR]\033[0m Headscale 容器未运行"
    echo -e "\033[0;32m[INFO]\033[0m 请先启动服务: linker start"
    exit 1
fi

docker exec headscale headscale "$@"
EOF
    
    sudo chmod +x /usr/local/bin/headscale
    
    log_success "全局 headscale 命令安装完成"
}

# 升级备份
backup_for_upgrade() {
    log_step "备份当前环境..."
    
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_path="${BACKUP_DIR}/upgrade_backup_${timestamp}"
    
    mkdir -p "$backup_path"
    
    # 备份数据库和配置
    if [[ -d "${DATA_DIR}" ]]; then
        cp -r "${DATA_DIR}" "${backup_path}/"
    fi
    cp -r "${CONFIG_DIR}" "${backup_path}/"
    cp "$COMPOSE_FILE" "${backup_path}/"
    
    echo "$backup_path" > "${BACKUP_DIR}/.last_upgrade_backup"
    log_success "环境已备份到: $backup_path"
}

# 从备份恢复
restore_from_backup() {
    log_step "从备份恢复环境..."
    
    local backup_path
    if [[ -f "${BACKUP_DIR}/.last_upgrade_backup" ]]; then
        backup_path=$(cat "${BACKUP_DIR}/.last_upgrade_backup")
    else
        log_error "找不到备份路径"
        return 1
    fi
    
    if [[ ! -d "$backup_path" ]]; then
        log_error "备份目录不存在: $backup_path"
        return 1
    fi
    
    # 停止服务
    ${COMPOSE_CMD:-docker-compose} -f "$COMPOSE_FILE" down 2>/dev/null || true
    
    # 恢复文件
    if [[ -d "${backup_path}/data" ]]; then
        rm -rf "${DATA_DIR}"
        cp -r "${backup_path}/data" "${DATA_DIR}"
    fi
    cp -r "${backup_path}/config/"* "${CONFIG_DIR}/"
    cp "${backup_path}/docker-compose.yaml" "$COMPOSE_FILE"
    
    log_success "环境恢复完成"
}

# 清理环境但保留用户数据（默认行为）
cleanup_preserve_data() {
    log_step "清理环境但保留用户数据..."
    
    # 停止并删除服务
    ${COMPOSE_CMD:-docker-compose} -f "$COMPOSE_FILE" down 2>/dev/null || true
    
    # 只清理非关键数据
    rm -rf "${DATA_DIR}/derp" 2>/dev/null || true
    rm -f "${DATA_DIR}/deployment.info" 2>/dev/null || true
    
    # 保留 headscale 数据目录（用户、节点、密钥等）
    log_info "保留用户数据目录: ${DATA_DIR}/headscale"
    
    # 恢复配置文件到模板状态
    restore_template_configs
    
    log_success "环境清理完成，用户数据已保留"
}

# 完全清理环境（仅在用户明确要求时使用）
cleanup_all() {
    log_step "完全清理环境..."
    
    # 停止并删除服务
    ${COMPOSE_CMD:-docker-compose} -f "$COMPOSE_FILE" down -v 2>/dev/null || true
    
    # 清理所有数据
    rm -rf "${DATA_DIR}/headscale" 2>/dev/null || true
    rm -rf "${DATA_DIR}/derp" 2>/dev/null || true
    rm -f "${DATA_DIR}/deployment.info" 2>/dev/null || true
    
    # 清理全局命令
    sudo rm -f /usr/local/bin/headscale 2>/dev/null || true
    
    # 恢复配置文件到模板状态
    restore_template_configs
    
    log_success "环境完全清理完成"
}

# 获取用户和节点统计
get_headscale_stats() {
    local user_count=0
    local node_count=0
    
    if check_services_running; then
        # 安全地获取统计数据
        if user_output=$(docker exec headscale headscale users list 2>/dev/null); then
            user_count=$(echo "$user_output" | grep -c "^id:" 2>/dev/null || echo "0")
        fi
        
        if node_output=$(docker exec headscale headscale nodes list 2>/dev/null); then
            node_count=$(echo "$node_output" | grep -c "^id:" 2>/dev/null || echo "0")
        fi
        
        # 确保是有效数字
        [[ "$user_count" =~ ^[0-9]+$ ]] || user_count=0
        [[ "$node_count" =~ ^[0-9]+$ ]] || node_count=0
    fi
    
    # 返回结果（用空格分隔）
    echo "$user_count $node_count"
}

# 检查并显示现有用户数据
check_existing_data() {
    if [[ -f "${DATA_DIR}/headscale/db.sqlite" ]]; then
        log_info "检测到现有用户数据，将自动保留"
        
        # 显示现有数据统计（如果服务正在运行）
        if check_services_running; then
            read user_count node_count <<< "$(get_headscale_stats)"
            
            if [[ $user_count -gt 0 || $node_count -gt 0 ]]; then
                echo "  现有用户数量: $user_count"
                echo "  现有节点数量: $node_count"
                log_success "用户数据将在重新部署后继续可用"
            fi
        else
            log_info "服务未运行，无法获取数据统计"
        fi
    fi
}

# 恢复配置文件到模板状态
restore_template_configs() {
    local template_backup="${DATA_DIR}/.template_backup"
    local restored=false
    
    if [[ -d "$template_backup" ]]; then
        # 恢复原始模板文件
        log_step "恢复配置文件到模板状态..."
        cp "$template_backup/docker-compose.yaml" "$COMPOSE_FILE" 2>/dev/null || true
        cp "$template_backup/config.yaml" "${CONFIG_DIR}/headscale/config.yaml" 2>/dev/null || true
        cp "$template_backup/derp.yaml" "${CONFIG_DIR}/headscale/derp.yaml" 2>/dev/null || true
        rm -rf "$template_backup"
        restored=true
    elif [[ -d ".git" ]]; then
        # 如果是 git 仓库，使用 git 恢复
        log_step "使用 git 恢复配置文件..."
        git checkout -- "$COMPOSE_FILE" "${CONFIG_DIR}/headscale/config.yaml" "${CONFIG_DIR}/headscale/derp.yaml" 2>/dev/null || true
        restored=true
    else
        # 手动恢复：在关键位置重新插入模板变量
        log_step "手动恢复配置文件到模板状态..."
        manual_restore_templates
        restored=true
    fi
    
    if [[ "$restored" == "true" ]]; then
        log_success "配置文件已恢复到模板状态"
    fi
}

# 手动恢复模板变量
manual_restore_templates() {
    # 恢复 docker-compose.yaml 中的模板变量
    if [[ -f "$COMPOSE_FILE" ]]; then
        sed -i.bak \
            -e 's/[0-9]\{1,5\}:8080/{{HEADSCALE_PORT}}:8080/g' \
            -e 's/[0-9]\{1,5\}:80/{{DERP_PORT}}:80/g' \
            -e 's/hostname [0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}/hostname {{PUBLIC_IP}}/g' \
            "$COMPOSE_FILE" && rm -f "${COMPOSE_FILE}.bak"
    fi
    
    # 恢复 headscale config.yaml 中的模板变量
    if [[ -f "${CONFIG_DIR}/headscale/config.yaml" ]]; then
        sed -i.bak \
            -e 's|server_url: http://[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}:[0-9]\{1,5\}|server_url: http://{{PUBLIC_IP}}:{{HEADSCALE_PORT}}|g' \
            "${CONFIG_DIR}/headscale/config.yaml" && rm -f "${CONFIG_DIR}/headscale/config.yaml.bak"
    fi
    
    # 恢复 derp.yaml 中的模板变量
    if [[ -f "${CONFIG_DIR}/headscale/derp.yaml" ]]; then
        sed -i.bak \
            -e 's/[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}/{{PUBLIC_IP}}/g' \
            "${CONFIG_DIR}/headscale/derp.yaml" && rm -f "${CONFIG_DIR}/headscale/derp.yaml.bak"
    fi
}

# 在首次安装时备份原始模板
backup_template_configs() {
    local template_backup="${DATA_DIR}/.template_backup"
    
    # 只在首次安装时备份（模板文件存在且包含变量）
    if [[ -f "$COMPOSE_FILE" ]] && grep -q "{{.*}}" "$COMPOSE_FILE" && [[ ! -d "$template_backup" ]]; then
        log_step "备份原始模板文件..."
        mkdir -p "$template_backup"
        cp "$COMPOSE_FILE" "$template_backup/docker-compose.yaml"
        cp "${CONFIG_DIR}/headscale/config.yaml" "$template_backup/config.yaml"
        cp "${CONFIG_DIR}/headscale/derp.yaml" "$template_backup/derp.yaml"
    fi
}



# 检查Docker权限
check_docker_permission() {
    if ! docker ps >/dev/null 2>&1; then
        if groups $USER | grep -q docker; then
            log_warn "Docker权限配置完成，但需要重新登录或执行: newgrp docker"
            log_info "尝试使用sudo运行Docker命令..."
            if ! sudo docker ps >/dev/null 2>&1; then
                log_error "无法访问Docker，请检查Docker安装和权限"
                return 1
            fi
            # 设置后续Docker命令使用sudo
            export DOCKER_CMD="sudo docker"
            export COMPOSE_CMD="sudo docker-compose"
        else
            log_error "当前用户不在docker组中，请运行: sudo usermod -aG docker $USER"
            return 1
        fi
    else
        export DOCKER_CMD="docker"
        export COMPOSE_CMD="docker-compose"
    fi
    return 0
}

# 安装Docker
install_docker() {
    local os=$(detect_os)
    log_step "安装Docker..."
    
    case $os in
        centos)
            if ! command_exists docker; then
                log_info "检测到CentOS系统，使用yum安装Docker..."
                sudo yum install -y yum-utils
                sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
                sudo yum install -y docker-ce docker-ce-cli containerd.io
                sudo systemctl start docker
                sudo systemctl enable docker
                sudo usermod -aG docker $USER
                log_success "Docker安装完成"
            else
                log_info "Docker已存在，跳过安装"
            fi
            ;;
        ubuntu|debian)
            if ! command_exists docker; then
                log_info "检测到Ubuntu/Debian系统，使用apt安装Docker..."
                sudo apt-get update
                sudo apt-get install -y ca-certificates curl gnupg lsb-release
                curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
                echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
                sudo apt-get update
                sudo apt-get install -y docker-ce docker-ce-cli containerd.io
                sudo systemctl start docker
                sudo systemctl enable docker
                sudo usermod -aG docker $USER
                log_success "Docker安装完成"
            else
                log_info "Docker已存在，跳过安装"
            fi
            ;;
                *)
            log_error "不支持的操作系统: $(detect_os)，目前仅支持CentOS和Ubuntu/Debian"
            return 1
            ;;
    esac
    
    # 检查Docker权限
    check_docker_permission
}

# 安装docker-compose
install_docker_compose() {
    local os=$(detect_os)
    log_step "安装docker-compose..."
    
    # 删除系统自带的docker-compose
    if command_exists docker-compose; then
        log_info "删除系统自带的docker-compose..."
        case $os in
            centos)
                sudo yum remove -y docker-compose 2>/dev/null || true
                ;;
            ubuntu|debian)
                sudo apt-get remove -y docker-compose 2>/dev/null || true
                ;;
        esac
        # 删除可能的链接文件
        sudo rm -f /usr/bin/docker-compose /usr/local/bin/docker-compose 2>/dev/null || true
    fi
    
    # 使用本地二进制文件
    local compose_binary=""
    case $os in
        centos)
            compose_binary="${PKG_DIR}/centos/docker-compose"
            ;;
        ubuntu|debian)
            if [[ -f "${PKG_DIR}/ubuntu/docker-compose" ]]; then
                compose_binary="${PKG_DIR}/ubuntu/docker-compose"
            else
                log_warn "Ubuntu版本的docker-compose不存在，使用CentOS版本"
                compose_binary="${PKG_DIR}/centos/docker-compose"
            fi
            ;;
        *)
            log_error "不支持的操作系统: $(detect_os)，目前仅支持CentOS和Ubuntu/Debian"
            return 1
            ;;
    esac
    
    if [[ -f "$compose_binary" ]]; then
        log_info "使用本地docker-compose二进制文件..."
        sudo cp "$compose_binary" /usr/local/bin/docker-compose
        sudo chmod +x /usr/local/bin/docker-compose
        
        # 验证安装
        if /usr/local/bin/docker-compose --version >/dev/null 2>&1; then
            log_success "docker-compose安装完成"
            export COMPOSE_CMD="sudo /usr/local/bin/docker-compose"
        else
            log_error "docker-compose安装失败"
            return 1
        fi
    else
        log_error "找不到适合的docker-compose二进制文件: $compose_binary"
        return 1
    fi
}

# 检查端口占用
check_port() {
    local port=$1
    if ss -tlnp 2>/dev/null | grep -q ":${port} " || netstat -tlnp 2>/dev/null | grep -q ":${port} "; then
        return 0  # 端口被占用
    else
        return 1  # 端口可用
    fi
}

# 加载Docker镜像
load_docker_images() {
    log_step "加载Docker镜像..."
    local total_images=2
    local current=0
    
    local required_images=(
        "${IMAGES_DIR}/headscale-v0.26.1.tar"
        "${IMAGES_DIR}/derp-sha-82c26de.tar"
    )
    
    for image_file in "${required_images[@]}"; do
        if [[ -f "$image_file" ]]; then
            current=$((current + 1))
            show_progress $current $total_images "加载 $(basename "$image_file")"
            if ${DOCKER_CMD:-docker} load -i "$image_file" >/dev/null 2>&1; then
                echo # 换行
                log_success "镜像 $(basename "$image_file") 加载成功"
            else
                echo # 换行
                log_error "镜像 $(basename "$image_file") 加载失败"
                return 1
            fi
        else
            log_warn "镜像文件不存在: $image_file，尝试使用在线镜像"
        fi
    done
}

# 生成配置文件
generate_configs() {
    local public_ip=$1
    local headscale_port=${2:-10001}
    local derp_port=${3:-10002}
    
    log_step "生成配置文件..."
    
    # 创建目录
    mkdir -p "${DATA_DIR}/headscale" "${DATA_DIR}/derp"
    
    # 使用变量替换配置文件（直接原地替换）
    sed -i.tmp -e "s/{{PUBLIC_IP}}/${public_ip}/g" \
        -e "s/{{HEADSCALE_PORT}}/${headscale_port}/g" \
               "${CONFIG_DIR}/headscale/config.yaml" && rm -f "${CONFIG_DIR}/headscale/config.yaml.tmp"
    
    sed -i.tmp -e "s/{{PUBLIC_IP}}/${public_ip}/g" \
        -e "s/{{DERP_PORT}}/${derp_port}/g" \
               "${CONFIG_DIR}/headscale/derp.yaml" && rm -f "${CONFIG_DIR}/headscale/derp.yaml.tmp"

    # 更新docker-compose.yaml
    sed -i.tmp -e "s/{{PUBLIC_IP}}/${public_ip}/g" \
        -e "s/{{HEADSCALE_PORT}}/${headscale_port}/g" \
        -e "s/{{DERP_PORT}}/${derp_port}/g" \
               "${COMPOSE_FILE}" && rm -f "${COMPOSE_FILE}.tmp"
    
    log_success "配置文件生成完成"
}

# 等待服务启动
wait_for_service() {
    local service_name=$1
    local check_url=$2
    local max_attempts=${3:-15}
    local attempt=0
    
    log_info "等待 $service_name 服务启动..."
    
    while [[ $attempt -lt $max_attempts ]]; do
        if curl -s --connect-timeout 2 "$check_url" >/dev/null 2>&1; then
            log_success "$service_name 服务启动成功"
            return 0
        fi
        
        attempt=$((attempt + 1))
        show_progress $attempt $max_attempts "等待 $service_name 启动"
        sleep 2
    done
    
    echo # 换行
    log_error "$service_name 服务启动超时"
    return 1
}

# 健康检查
health_check() {
    local public_ip=$1
    local headscale_port=${2:-10001}
    local derp_port=${3:-10002}
    
    log_step "执行健康检查..."
    
    local checks=0
    local total_checks=4
    
    # 等待服务启动
    if ! wait_for_service "Headscale" "http://${public_ip}:${headscale_port}/health"; then
        return 1
    fi
    
    if ! wait_for_service "DERP" "http://${public_ip}:${derp_port}/"; then
        return 1
    fi
    
    # 检查Headscale API
    checks=$((checks + 1))
    show_progress $checks $total_checks "检查Headscale API"
    if curl -s "http://${public_ip}:${headscale_port}/health" | grep -q "pass"; then
        echo # 换行
        log_success "Headscale API检查通过"
    else
        echo # 换行
        log_error "Headscale API检查失败"
        return 1
    fi
    
    # 检查DERP服务
    checks=$((checks + 1))
    show_progress $checks $total_checks "检查DERP服务"
    if curl -s -I "http://${public_ip}:${derp_port}/" | grep -q "200 OK"; then
        echo # 换行
        log_success "DERP服务检查通过"
    else
        echo # 换行
        log_error "DERP服务检查失败"
        return 1
    fi
    
    # 检查DERP探测端点
    checks=$((checks + 1))
    show_progress $checks $total_checks "检查DERP探测端点"
    if curl -s -I "http://${public_ip}:${derp_port}/derp/probe" | grep -q "200 OK"; then
        echo # 换行
        log_success "DERP探测端点检查通过"
    else
        echo # 换行
        log_error "DERP探测端点检查失败"
        return 1
    fi
    
    # 检查容器状态
    checks=$((checks + 1))
    show_progress $checks $total_checks "检查容器状态"
    if ${COMPOSE_CMD:-docker-compose} -f "$COMPOSE_FILE" ps | grep -q "Up"; then
        echo # 换行
        log_success "容器状态检查通过"
    else
        echo # 换行
        log_error "容器状态检查失败"
        return 1
    fi
    
    log_success "所有健康检查通过"
    return 0
}

# 安装失败回滚（简化版）
rollback_installation() {
    log_step "执行回滚操作..."
    
    # 停止服务
    if [[ -f "$COMPOSE_FILE" ]] && command -v docker-compose >/dev/null 2>&1; then
        docker-compose -f "$COMPOSE_FILE" down 2>/dev/null || true
    fi
    
    # 恢复配置文件到模板状态（使用git或初始模板）
    if [[ -d ".git" ]]; then
        git checkout -- "$COMPOSE_FILE" "${CONFIG_DIR}/headscale/config.yaml" "${CONFIG_DIR}/headscale/derp.yaml" 2>/dev/null || true
    fi
    
    log_success "回滚操作完成"
}

# 显示部署信息
show_deployment_info() {
    local public_ip=$1
    local headscale_port=${2:-10001}
    local derp_port=${3:-10002}
    
    echo
    echo -e "${WHITE}==================== 部署信息 ====================${NC}"
    echo -e "${GREEN}✓ Headscale服务:${NC} http://${public_ip}:${headscale_port}"
    echo -e "${GREEN}✓ DERP中继服务:${NC} http://${public_ip}:${derp_port}"
    echo -e "${GREEN}✓ STUN服务:${NC} ${public_ip}:3478 (UDP)"
    echo -e "${GREEN}✓ IP地址段:${NC} 10.24.0.0/24"
    echo
    echo -e "${WHITE}==================== 客户端连接 ====================${NC}"
    echo -e "${YELLOW}生成预授权密钥:${NC}"
    echo -e "  ${SCRIPT_DIR}/linker.sh headscale preauthkeys create --user 1 --expiration 87600h --reusable"
    echo
    echo -e "${YELLOW}客户端连接命令:${NC}"
    echo -e "  sudo tailscale up --login-server=http://${public_ip}:${headscale_port} --authkey=<YOUR_KEY>"
    echo
    echo -e "${WHITE}==================== 管理命令 ====================${NC}"
    echo -e "${CYAN}查看状态:${NC} ${SCRIPT_DIR}/linker.sh status"
    echo -e "${CYAN}查看日志:${NC} ${SCRIPT_DIR}/linker.sh logs <headscale|derp>"
    echo -e "${CYAN}服务管理:${NC} ${SCRIPT_DIR}/linker.sh <start|stop|restart> [service]"
    echo
    echo -e "${WHITE}==================== 全局命令 ====================${NC}"
    echo -e "${CYAN}Headscale管理:${NC} headscale users list"
    echo -e "${CYAN}创建密钥:${NC} headscale preauthkeys create --user default --reusable"
    echo -e "${CYAN}节点管理:${NC} headscale nodes list"
    echo -e "${WHITE}=================================================${NC}"
}

# 安装命令
cmd_install() {
    local public_ip=""
    local headscale_port=10001
    local derp_port=10002
    
    # 解析参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            --ip)
                if [[ -z "${2:-}" ]]; then
                    log_error "--ip参数需要指定IP地址"
                    exit 1
                fi
                public_ip="$2"
                shift 2
                ;;
            --port-headscale)
                if [[ -z "${2:-}" ]]; then
                    log_error "--port-headscale参数需要指定端口号"
                    exit 1
                fi
                headscale_port="$2"
                shift 2
                ;;
            --port-derp)
                if [[ -z "${2:-}" ]]; then
                    log_error "--port-derp参数需要指定端口号"
                    exit 1
                fi
                derp_port="$2"
                shift 2
                ;;
            --help|-h)
                show_install_help
                exit 0
                ;;
            *)
                log_error "未知参数: $1"
                show_install_help
                exit 1
                ;;
        esac
    done
    
    # 验证必要参数
    if [[ -z "$public_ip" ]]; then
        log_error "必须提供本机公网IP地址，使用 --ip 参数"
        exit 1
    fi
    
    # 验证IP格式
    if ! [[ $public_ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        log_error "IP地址格式无效: $public_ip"
        exit 1
    fi
    
    # 检查是否已部署（除非是reinstall调用）
    if [[ "${SKIP_DEPLOYMENT_CHECK:-}" != "true" ]] && check_already_deployed; then
        log_warn "检测到系统已部署"
        log_info "当前部署信息:"
        if [[ -f "${DATA_DIR}/deployment.info" ]]; then
            source "${DATA_DIR}/deployment.info"
            echo "  部署时间: ${DEPLOYED_TIME:-未知}"
            echo "  公网IP: ${PUBLIC_IP:-未知}"
            echo "  Headscale端口: ${HEADSCALE_PORT:-未知}"
            echo "  DERP端口: ${DERP_PORT:-未知}"
            echo "  版本: ${VERSION:-未知}"
        fi
        echo
        
        # 智能处理：如果参数相同，跳过安装；如果不同，询问用户
        if [[ -f "${DATA_DIR}/deployment.info" ]]; then
            source "${DATA_DIR}/deployment.info"
            if [[ "$PUBLIC_IP" == "$public_ip" && "$HEADSCALE_PORT" == "$headscale_port" && "$DERP_PORT" == "$derp_port" ]]; then
                if check_services_running; then
                    log_success "服务已部署且正在运行，无需重复安装"
                    log_info "您可以执行:"
                    echo "  查看状态: $0 status"
                    echo "  重启服务: $0 restart"
                    exit 0
                else
                    log_info "配置已存在但服务未运行，正在启动服务..."
                    ${COMPOSE_CMD:-docker-compose} -f "$COMPOSE_FILE" up -d
                    if health_check "$public_ip" "$headscale_port" "$derp_port"; then
                        log_success "服务启动成功！"
                    fi
                    exit 0
                fi
            fi
        fi
        
        # 参数不同，询问用户意图
        echo
        log_warn "新的参数与已部署配置不同"
        echo "新参数: IP=$public_ip, Headscale端口=$headscale_port, DERP端口=$derp_port"
        echo
        
        # 检查现有数据
        check_existing_data
        echo
        
        echo "请选择操作:"
        echo "  1) 取消安装 (默认)"
        echo "  2) 更新配置 (保留用户数据，更新IP/端口配置)"
        echo "  3) 重新开始 (⚠️  删除所有数据，完全重新安装)"
        echo
        read -p "请选择 [1/2/3]: " choice
        
        case "${choice:-1}" in
            2)
                log_info "更新配置，保留用户数据..."
                # 备份当前环境
                backup_for_upgrade
                # 保留数据的清理
                cleanup_preserve_data
                # 继续安装流程
                export SKIP_DEPLOYMENT_CHECK=true
                ;;
            3)
                log_warn "⚠️  将删除所有数据，所有客户端需要重新获取密钥连接"
                read -p "确认删除所有数据? (yes/no): " confirm
                if [[ "$confirm" != "yes" ]]; then
                    log_info "操作已取消"
                    exit 0
                fi
                log_info "完全重新安装..."
                # 备份当前环境
                backup_for_upgrade
                # 完全清理
                cleanup_all
                # 继续安装流程
                export SKIP_DEPLOYMENT_CHECK=true
                ;;
            *)
                log_info "操作已取消"
                exit 0
                ;;
        esac
    fi
    
    # 并发安全检查
    check_concurrent_install
    
    # 备份原始模板文件
    backup_template_configs
    
    log_info "开始首次安装部署 Headscale..."
    log_info "公网IP: $public_ip"
    log_info "Headscale端口: $headscale_port"
    log_info "DERP端口: $derp_port"
    
    # 检查端口占用
    if check_port "$headscale_port"; then
        log_error "端口 $headscale_port 已被占用"
        exit 1
    fi
    
    if check_port "$derp_port"; then
        log_error "端口 $derp_port 已被占用"
        exit 1
    fi
    
    # 创建模板文件（如果不存在）
    create_default_templates
    
    # 检查模板文件
    if ! check_template_files; then
        log_error "模板文件检查失败"
        exit 1
    fi
    
    # 创建锁文件
    echo $$ > "$LOCK_FILE"
    
    # 安装依赖
    install_docker
    install_docker_compose
    
    # 加载镜像
    load_docker_images
    
    # 生成配置
    generate_configs "$public_ip" "$headscale_port" "$derp_port"
    
    # 启动服务
    log_step "启动服务..."
    ${COMPOSE_CMD:-docker-compose} -f "$COMPOSE_FILE" up -d
    
    # 健康检查
    if health_check "$public_ip" "$headscale_port" "$derp_port"; then
        show_deployment_info "$public_ip" "$headscale_port" "$derp_port"
        
        # 创建默认用户
        log_step "创建默认用户..."
        ${COMPOSE_CMD:-docker-compose} -f "$COMPOSE_FILE" exec -T headscale headscale users create default 2>/dev/null || log_info "用户已存在"
        
        # 安装全局 headscale 命令
        install_global_headscale_command
        
        # 记录部署信息
        record_deployment_info "$public_ip" "$headscale_port" "$derp_port"
        
        # 清理锁文件
        rm -f "$LOCK_FILE"
        
        log_success "Headscale首次部署完成!"
    else
        log_error "健康检查失败，正在回滚..."
        rollback_installation
        exit 1
    fi
}

# 服务管理函数 (start/stop/restart 保持不变，但使用 $COMPOSE_CMD)
cmd_start() {
    # 检查帮助参数
    if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
        show_service_help "start"
        exit 0
    fi
    
    local service=${1:-all}
    log_info "启动服务: $service"
    
    # 检查是否已部署
    if ! check_already_deployed; then
        log_error "系统未部署，请先执行安装"
        log_info "执行: $0 install --ip <YOUR_IP>"
        exit 1
    fi
    
    # 检查权限
    check_docker_permission || exit 1
    
    case $service in
        all)
            ${COMPOSE_CMD:-docker-compose} -f "$COMPOSE_FILE" up -d
            ;;
        headscale|derp)
            ${COMPOSE_CMD:-docker-compose} -f "$COMPOSE_FILE" up -d "$service"
            ;;
        *)
            log_error "无效的服务名: $service，支持: headscale, derp, all"
            exit 1
            ;;
    esac
    
    log_success "服务启动完成"
}

cmd_stop() {
    # 检查帮助参数
    if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
        show_service_help "stop"
        exit 0
    fi
    
    local service=${1:-all}
    log_info "停止服务: $service"
    
    # 检查部署状态（允许服务停止状态）
    if ! check_deployment_status false; then
        exit 1
    fi
    
    # 检查权限
    check_docker_permission || exit 1
    
    case $service in
        all)
            ${COMPOSE_CMD:-docker-compose} -f "$COMPOSE_FILE" down
            ;;
        headscale|derp)
            ${COMPOSE_CMD:-docker-compose} -f "$COMPOSE_FILE" stop "$service"
            ;;
        *)
            log_error "无效的服务名: $service，支持: headscale, derp, all"
            exit 1
            ;;
    esac
    
    log_success "服务停止完成"
}

cmd_restart() {
    # 检查帮助参数
    if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
        show_service_help "restart"
        exit 0
    fi
    
    local service=${1:-all}
    log_info "重启服务: $service"
    
    # 检查部署状态（允许服务停止状态，因为重启可以在停止状态下执行）
    if ! check_deployment_status false; then
        exit 1
    fi
    
    # 检查权限
    check_docker_permission || exit 1
    
    case $service in
        all)
            ${COMPOSE_CMD:-docker-compose} -f "$COMPOSE_FILE" restart
            ;;
        headscale|derp)
            ${COMPOSE_CMD:-docker-compose} -f "$COMPOSE_FILE" restart "$service"
            ;;
        *)
            log_error "无效的服务名: $service，支持: headscale, derp, all"
            exit 1
            ;;
    esac
    
    log_success "服务重启完成"
}

# 日志查看
cmd_logs() {
    # 检查帮助参数
    if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
        show_logs_help
        exit 0
    fi
    
    local service=$1
    local follow_flag=""
    
    # 检查部署状态（需要服务运行）
    if ! check_deployment_status true; then
        exit 1
    fi
    
    # 检查权限
    check_docker_permission || exit 1
    
    # 检查是否有-f参数
    if [[ "${2:-}" == "-f" ]]; then
        follow_flag="-f"
    fi
    
    case $service in
        headscale)
            ${COMPOSE_CMD:-docker-compose} -f "$COMPOSE_FILE" logs $follow_flag headscale
            ;;
        derp)
            ${COMPOSE_CMD:-docker-compose} -f "$COMPOSE_FILE" logs $follow_flag derp
            ;;
        *)
            log_error "无效的服务名: $service，支持: headscale, derp"
            exit 1
            ;;
    esac
}

# 状态查看
cmd_status() {
    # 检查部署状态（允许服务停止状态，status命令应该能显示停止的服务）
    if ! check_deployment_status false; then
        exit 1
    fi
    
    # 检查权限
    check_docker_permission || exit 1
    
    log_info "服务状态:"
    ${COMPOSE_CMD:-docker-compose} -f "$COMPOSE_FILE" ps
    
    echo
    log_info "容器详细信息:"
    ${DOCKER_CMD:-docker} ps --filter "name=headscale" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

# Headscale命令代理
cmd_headscale() {
    # 检查帮助参数
    if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
        show_headscale_help
        exit 0
    fi
    
    # 检查部署状态（需要服务运行）
    if ! check_deployment_status true; then
        exit 1
    fi
    
    # 检查权限
    check_docker_permission || exit 1
    
    ${COMPOSE_CMD:-docker-compose} -f "$COMPOSE_FILE" exec headscale headscale "$@"
}





# 卸载命令
cmd_uninstall() {
    # 检查帮助参数
    if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
        show_uninstall_help
        exit 0
    fi
    
    # 检查是否有多余参数
    if [[ $# -gt 0 ]]; then
        log_warn "uninstall 命令不需要额外参数，忽略: $*"
    fi
    
    log_info "开始卸载 Headscale..."
    
    # 检查是否已部署
    if ! check_already_deployed; then
        log_warn "系统未部署或已卸载"
        exit 0
    fi
    
    # 检查现有数据
    check_existing_data
    
    echo
    echo "卸载选项:"
    echo "  1) 保留用户数据卸载 (推荐) - 保留数据，将来可快速恢复"
    echo "  2) 完全卸载 - ⚠️  删除所有数据和配置"
    echo "  3) 取消操作"
    echo
    read -p "请选择 [1/2/3]: " uninstall_option
    
    case "${uninstall_option:-1}" in
        1)
            PRESERVE_DATA=true
            log_info "将保留用户数据卸载"
            ;;
        2)
            PRESERVE_DATA=false
            log_warn "⚠️  将完全删除所有数据，包括用户、节点、路由等信息"
            read -p "确认完全卸载? (yes/no): " confirm
            if [[ "$confirm" != "yes" ]]; then
                log_info "操作已取消"
                exit 0
            fi
            ;;
        *)
            log_info "操作已取消"
            exit 0
            ;;
    esac
    
    # 显示当前部署信息
    if [[ -f "${DATA_DIR}/deployment.info" ]]; then
        source "${DATA_DIR}/deployment.info"
        log_info "卸载部署信息:"
        echo "  部署时间: $DEPLOYED_TIME"
        echo "  公网IP: $PUBLIC_IP"
        echo "  Headscale端口: $HEADSCALE_PORT"
        echo "  DERP端口: $DERP_PORT"
    fi
    
    # 最终备份
    backup_for_upgrade
    
    # 根据用户选择清理
    if [[ "$PRESERVE_DATA" == "true" ]]; then
        cleanup_preserve_data
    else
        cleanup_all
    fi
    
    # 移除Docker镜像（可选）
    read -p "是否同时删除Docker镜像? (yes/no): " remove_images
    if [[ "$remove_images" == "yes" ]]; then
        log_step "删除Docker镜像..."
        docker rmi headscale/headscale:v0.26.1 2>/dev/null || true
        docker rmi sparanoid/derp:sha-82c26de 2>/dev/null || true
        log_success "Docker镜像已删除"
    fi
    
    log_success "Headscale已完全卸载"
    log_info "备份文件保留在: ${BACKUP_DIR}/"
}

# 部署信息命令
cmd_deployment_info() {
    if ! check_already_deployed; then
        log_error "系统未部署"
        exit 1
    fi
    
    log_info "当前部署信息:"
    if [[ -f "${DATA_DIR}/deployment.info" ]]; then
        source "${DATA_DIR}/deployment.info"
        echo "  部署时间: $DEPLOYED_TIME"
        echo "  公网IP: $PUBLIC_IP"
        echo "  Headscale端口: $HEADSCALE_PORT"
        echo "  DERP端口: $DERP_PORT"
        echo "  版本: $VERSION"
        echo
        
        # 显示服务状态
        log_info "服务状态:"
        ${COMPOSE_CMD:-docker-compose} -f "$COMPOSE_FILE" ps
        
        # 显示数据统计
        log_info "数据统计:"
        read user_count node_count <<< "$(get_headscale_stats)"
        echo "  用户数量: $user_count"
        echo "  节点数量: $node_count"
    else
        log_warn "部署信息文件不存在"
    fi
}

# 修复模板文件命令
cmd_fix_templates() {
    log_info "修复配置文件模板变量..."
    
    # 检查当前状态
    if grep -q "{{.*}}" "$COMPOSE_FILE"; then
        log_success "配置文件已包含模板变量，无需修复"
        return 0
    fi
    
    log_warn "检测到配置文件已被替换，正在恢复模板变量..."
    manual_restore_templates
    
    # 验证修复结果
    if grep -q "{{.*}}" "$COMPOSE_FILE"; then
        log_success "模板变量修复完成"
        log_info "现在可以重新执行: $0 install --ip <YOUR_IP>"
    else
        log_error "模板变量修复失败，请手动检查配置文件"
        exit 1
    fi
}

# 安装命令帮助
show_install_help() {
    echo -e "${WHITE}linker.sh install - 智能安装/更新Headscale${NC}"
    echo
    echo -e "${YELLOW}用法:${NC}"
    echo "  $0 install --ip <IP> [options]"
    echo
    echo -e "${YELLOW}功能:${NC}"
    echo "  • 首次安装：自动安装依赖、配置服务、启动Headscale"
    echo "  • 智能检测：已部署时提供更新配置或重新安装选项"
    echo "  • 数据保护：默认保留用户数据，避免客户端重新连接"
    echo
    echo -e "${YELLOW}必需参数:${NC}"
    echo -e "  ${GREEN}--ip <IP>${NC}               指定公网IP地址"
    echo
    echo -e "${YELLOW}可选参数:${NC}"
    echo -e "  ${GREEN}--port-headscale <PORT>${NC} 指定Headscale端口 (默认: 10001)"
    echo -e "  ${GREEN}--port-derp <PORT>${NC}      指定DERP端口 (默认: 10002)"
    echo -e "  ${GREEN}--help, -h${NC}              显示此帮助信息"
    echo
    echo -e "${YELLOW}示例:${NC}"
    echo "  $0 install --ip 192.168.1.100"
    echo "  $0 install --ip 192.168.1.100 --port-headscale 18080 --port-derp 18001"
    echo
    echo -e "${YELLOW}智能行为:${NC}"
    echo "  • 未部署 → 直接安装"
    echo "  • 已部署且参数相同 → 检查服务状态，必要时启动"
    echo "  • 已部署但参数不同 → 提供配置更新或重新安装选项"
}

# 卸载命令帮助
show_uninstall_help() {
    echo -e "${WHITE}linker.sh uninstall - 卸载Headscale${NC}"
    echo
    echo -e "${YELLOW}用法:${NC}"
    echo "  $0 uninstall"
    echo
    echo -e "${YELLOW}功能:${NC}"
    echo "  • 智能卸载：默认保留用户数据，便于将来快速恢复"
    echo "  • 灵活选择：可选择完全删除所有数据和配置"
    echo "  • 安全备份：卸载前自动备份当前环境"
    echo
    echo -e "${YELLOW}选项:${NC}"
    echo "  1) 保留数据卸载 (推荐) - 保留用户、节点数据"
    echo "  2) 完全卸载 - 删除所有数据和配置"
    echo "  3) 取消操作"
}

# 服务管理帮助
show_service_help() {
    local cmd=$1
    
    echo -e "${WHITE}linker.sh $cmd - ${cmd}服务${NC}"
    echo
    echo -e "${YELLOW}用法:${NC}"
    echo "  $0 $cmd [service] [options]"
    echo
    echo -e "${YELLOW}可选参数:${NC}"
    echo -e "  ${GREEN}service${NC}                 服务名 (all|headscale|derp，默认: all)"
    echo -e "  ${GREEN}--help, -h${NC}              显示此帮助信息"
    echo
    echo -e "${YELLOW}示例:${NC}"
    echo "  $0 $cmd"
    echo "  $0 $cmd headscale"
    echo "  $0 $cmd derp"
}

# 日志命令帮助
show_logs_help() {
    echo -e "${WHITE}linker.sh logs - 查看服务日志${NC}"
    echo
    echo -e "${YELLOW}用法:${NC}"
    echo "  $0 logs <service> [options]"
    echo
    echo -e "${YELLOW}必需参数:${NC}"
    echo -e "  ${GREEN}service${NC}                 服务名 (headscale|derp)"
    echo
    echo -e "${YELLOW}可选参数:${NC}"
    echo -e "  ${GREEN}-f${NC}                      实时跟踪日志"
    echo -e "  ${GREEN}--help, -h${NC}              显示此帮助信息"
    echo
    echo -e "${YELLOW}示例:${NC}"
    echo "  $0 logs headscale"
    echo "  $0 logs derp -f"
}

# headscale命令帮助
show_headscale_help() {
    echo -e "${WHITE}linker.sh headscale (别名: h) - 执行headscale命令${NC}"
    echo
    echo -e "${YELLOW}用法:${NC}"
    echo "  $0 headscale <args>"
    echo "  $0 h <args>"
    echo
    echo -e "${YELLOW}说明:${NC}"
    echo "  直接代理headscale容器中的原生命令"
    echo
    echo -e "${YELLOW}示例:${NC}"
    echo "  $0 h users list"
    echo "  $0 h users create myuser"
    echo "  $0 h preauthkeys create --user 1 --expiration 87600h --reusable"
    echo "  $0 h nodes list"
    echo "  $0 h routes list"
}



# 主帮助信息
show_help() {
    echo -e "${WHITE}Linker - Headscale自动化部署管理脚本${NC}"
    echo
    echo -e "${YELLOW}用法:${NC}"
    echo "  $0 <command> [options] [arguments]"
    echo
    echo -e "${YELLOW}环境变量:${NC}"
    echo -e "  ${GREEN}NO_COLOR=1${NC}              禁用颜色输出"
    echo -e "  ${GREEN}FORCE_COLOR=1${NC}           强制启用颜色输出"
    echo
    
    echo -e "${YELLOW}部署命令:${NC}"
    echo -e "  ${GREEN}install${NC}                  智能安装/更新Headscale (处理所有安装场景)"
    echo "    --ip <IP>               指定公网IP地址 (必需)"
    echo "    --port-headscale <PORT> 指定Headscale端口 (默认: 10001)"
    echo "    --port-derp <PORT>      指定DERP端口 (默认: 10002)"
    echo
    echo -e "  ${GREEN}uninstall${NC}               卸载系统 (可选择保留数据)"
    echo -e "  ${GREEN}deployment-info${NC}         显示部署信息"
    echo -e "  ${GREEN}fix-templates${NC}           修复配置文件模板变量"
    echo
    echo -e "${YELLOW}服务管理:${NC}"
    echo -e "  ${GREEN}start [service]${NC}          启动服务 (all|headscale|derp，默认: all)"
    echo -e "  ${GREEN}stop [service]${NC}           停止服务 (all|headscale|derp，默认: all)"
    echo -e "  ${GREEN}restart [service]${NC}        重启服务 (all|headscale|derp，默认: all)"
    echo -e "  ${GREEN}status${NC}                   查看服务状态"
    echo
    echo -e "${YELLOW}日志管理:${NC}"
    echo -e "  ${GREEN}logs <service> [-f]${NC}      查看服务日志"
    echo "    service                 服务名 (headscale|derp)"
    echo "    -f                      实时跟踪日志"
    echo
    echo -e "${YELLOW}Headscale管理:${NC}"
    echo -e "  ${GREEN}headscale, h <args>${NC}      执行headscale命令"
    echo "    示例: $0 h users list"
    echo "          $0 h preauthkeys create --user 1 --expiration 87600h --reusable"
    echo
    echo -e "${YELLOW}示例:${NC}"
    echo "  # 安装部署"
    echo "  $0 install --ip 192.168.1.100"
    echo
    echo "  # 指定自定义端口"
    echo "  $0 install --ip 192.168.1.100 --port-headscale 18080 --port-derp 18001"
    echo
    echo "  # 服务管理"
    echo "  $0 start"
    echo "  $0 restart headscale"
    echo "  $0 stop derp"
    echo
    echo "  # 查看日志"
    echo "  $0 logs headscale"
    echo "  $0 logs derp -f"
    echo
    echo "  # Headscale管理"
    echo "  $0 headscale users create myuser"
    echo "  $0 headscale preauthkeys create --user 1 --reusable"
    echo
    echo -e "${YELLOW}特性:${NC}"
    echo "  ✓ 自动检测操作系统并安装依赖"
    echo "  ✓ 配置文件模板化，支持参数替换"
    echo "  ✓ 多阶段健康检查"
    echo "  ✓ 并发安全和自动回滚"
    echo "  ✓ 固定IP段: 10.24.0.0/24"
}

# 主函数
main() {
    if [[ $# -eq 0 ]]; then
        show_help
        exit 0
    fi
    
    local command=$1
    shift
    
    case $command in
        install)
            cmd_install "$@"
            ;;
        uninstall)
            cmd_uninstall
            ;;
        deployment-info)
            cmd_deployment_info
            ;;
        fix-templates)
            cmd_fix_templates
            ;;
        start)
            cmd_start "$@"
            ;;
        stop)
            cmd_stop "$@"
            ;;
        restart)
            cmd_restart "$@"
            ;;
        logs)
            if [[ $# -eq 0 ]]; then
                log_error "logs命令需要指定服务名"
                exit 1
            fi
            cmd_logs "$@"
            ;;
        status)
            cmd_status
            ;;
        headscale|h)
            cmd_headscale "$@"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            log_error "未知命令: $command"
            
            # 智能命令建议
            local suggestion_found=false
            case "$command" in
                renstall|reinstal|reinsall|reinstall)
                    echo -e "❓ 您是否想要执行: ${GREEN}./linker.sh install --ip <IP>${NC} (智能安装，会处理已部署情况)"
                    suggestion_found=true
                    ;;
                instal|isntall|intall|ininstall)
                    echo -e "❓ 您是否想要执行: ${GREEN}./linker.sh install --ip <IP>${NC}"
                    suggestion_found=true
                    ;;
                uninstal|unintsall|unintall|unnstall)
                    echo -e "❓ 您是否想要执行: ${GREEN}./linker.sh uninstall${NC}"
                    suggestion_found=true
                    ;;
                upgrad|upgarde|upgrade)
                    echo -e "❓ 您是否想要执行: ${GREEN}./linker.sh install --ip <IP>${NC} (会智能处理配置更新)"
                    suggestion_found=true
                    ;;
                stat|stats|st)
                    echo -e "❓ 您是否想要执行: ${GREEN}./linker.sh status${NC}"
                    suggestion_found=true
                    ;;
                log|lg)
                    echo -e "❓ 您是否想要执行: ${GREEN}./linker.sh logs <service>${NC}"
                    suggestion_found=true
                    ;;
            esac
            
            if [[ "$suggestion_found" == "true" ]]; then
                echo
                echo -e "💡 如需查看所有命令，执行: ${GREEN}./linker.sh --help${NC}"
            else
                echo -e "💡 请检查命令拼写，或执行 ${GREEN}./linker.sh --help${NC} 查看可用命令"
                echo
            show_help
            fi
            exit 1
            ;;
    esac
}

# 执行主函数
main "$@"