# Linker - Headscale 自动化部署管理工具

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Shell](https://img.shields.io/badge/shell-bash-green.svg)](https://www.gnu.org/software/bash/)
[![Docker](https://img.shields.io/badge/docker-required-blue.svg)](https://www.docker.com/)

Linker 是一个功能完整的 Headscale 自动化部署管理工具，提供一站式的 Tailscale 自建服务器解决方案。通过简单的命令行界面，您可以快速部署、管理和监控 Headscale 服务。

## 🌟 核心特性

### 🚀 一键部署
- **自动化安装**: 自动检测操作系统并安装所需依赖
- **配置模板化**: 支持参数替换的配置文件模板
- **多阶段健康检查**: 确保服务正确启动和运行
- **智能回滚**: 安装失败时自动回滚到之前状态

### 🛡️ 安全可靠
- **并发安全**: 防止多个安装进程同时运行
- **权限检查**: 自动检查和配置 Docker 权限
- **配置备份**: 自动备份原始配置文件
- **状态验证**: 双重验证确保服务正确部署

### 🎨 用户友好
- **彩色输出**: 智能颜色检测和适配
- **进度显示**: 实时显示安装和操作进度
- **友好错误**: 清晰的错误信息和操作指导
- **完整帮助**: 详细的命令帮助和使用示例

### 🔧 功能完整
- **智能部署管理**: install/upgrade/reinstall/uninstall 语义明确
- **服务管理**: 启动、停止、重启服务
- **日志查看**: 实时查看和跟踪日志
- **用户管理**: 完整的用户生命周期管理
- **密钥管理**: 预授权密钥创建和管理
- **节点管理**: 设备注册和管理
- **路由管理**: 网络路由配置
- **全局命令**: 任意目录执行 headscale 命令
- **模板修复**: 自动恢复配置文件模板状态

## 📋 系统要求

### 支持的操作系统
- ✅ **CentOS 7+**
- ✅ **Ubuntu 18.04+**
- ✅ **Debian 10+**

### 硬件要求
- **CPU**: 1 核心以上
- **内存**: 1GB 以上
- **磁盘**: 2GB 可用空间
- **网络**: 可访问互联网

### 软件依赖
- **Docker**: 20.10+
- **Docker Compose**: 1.29+
- **Bash**: 4.0+

## 🚀 快速开始

### 1. 克隆项目
```bash
git clone <repository-url>
cd Linker
chmod +x linker.sh
```

### 2. 基础安装
```bash
# 使用您的公网IP地址
./linker.sh install --ip YOUR_PUBLIC_IP

# 示例
./linker.sh install --ip 192.168.1.100
```

### 3. 自定义端口安装
```bash
./linker.sh install --ip 192.168.1.100 \
  --port-headscale 18080 \
  --port-derp 18001
```

### 4. 创建用户和密钥
```bash
# 创建用户（安装时已自动创建 default 用户）
./linker.sh headscale users create myuser

# 创建预授权密钥
./linker.sh headscale preauthkeys create --user myuser --reusable
```

### 5. 客户端连接
```bash
# 在客户端设备上运行
sudo tailscale up --login-server=http://YOUR_PUBLIC_IP:10001 --authkey=<YOUR_KEY>
```

### 6. 全局 Headscale 命令（安装后自动可用）
```bash
# 用户管理
headscale users list
headscale users create myuser

# 创建预授权密钥
headscale preauthkeys create --user default --reusable

# 节点管理
headscale nodes list

# 路由管理
headscale routes list
```

## 📖 详细使用说明

### 🔧 命令概览

```bash
./linker.sh <command> [options] [arguments]
```

### 部署管理
```bash
# 首次安装
./linker.sh install --ip <IP> \
  [--port-headscale <PORT>] \
  [--port-derp <PORT>]

# 升级部署（保留数据）
./linker.sh upgrade

# 重新安装（删除所有数据）
./linker.sh reinstall --ip <IP> \
  [--port-headscale <PORT>] \
  [--port-derp <PORT>]

# 完全卸载
./linker.sh uninstall

# 查看部署信息
./linker.sh deployment-info

# 修复配置文件模板
./linker.sh fix-templates

# 查看安装帮助
./linker.sh install --help
```

### 服务管理
```bash
# 启动所有服务
./linker.sh start

# 启动特定服务
./linker.sh start headscale
./linker.sh start derp

# 停止服务
./linker.sh stop [service]

# 重启服务
./linker.sh restart [service]

# 查看服务状态
./linker.sh status
```

### 日志管理
```bash
# 查看日志
./linker.sh logs headscale
./linker.sh logs derp

# 实时跟踪日志
./linker.sh logs headscale -f
./linker.sh logs derp -f
```

### Headscale 管理

#### 方式一：全局命令（推荐，安装后自动可用）
```bash
# 用户管理
headscale users list
headscale users create <username>
headscale users destroy <username>

# 密钥管理
headscale preauthkeys list
headscale preauthkeys create --user <username>
headscale preauthkeys create --user <username> --reusable
headscale preauthkeys create --user <username> --expiration 87600h

# 节点管理
headscale nodes list
headscale nodes delete --node-id <node-id>
headscale nodes move --node-id <node-id> --user <username>

# 路由管理
headscale routes list
headscale routes enable --route-id <route-id>
headscale routes disable --route-id <route-id>
```

#### 方式二：通过 linker.sh（传统方式）
```bash
# 用户管理
./linker.sh headscale users list
./linker.sh headscale users create <username>
./linker.sh headscale users destroy <username>

# 别名支持（h = headscale）
./linker.sh h users list
```

## ⚙️ 配置说明

### 默认配置
- **Headscale 端口**: 10001
- **DERP 端口**: 10002
- **STUN 端口**: 3478 (UDP)
- **IP 地址段**: 10.24.0.0/24
- **IPv6 地址段**: fd7a:115c:a1e0::/48

### 目录结构
```
Linker/
├── linker.sh              # 主管理脚本 (1158行)
├── docker-compose.yaml    # Docker Compose 配置
├── config/                # 配置文件模板
│   ├── headscale/
│   │   ├── config.yaml    # Headscale 主配置
│   │   └── derp.yaml      # DERP 服务器配置
│   └── derp/              # DERP 配置目录
├── data/                  # 持久化数据目录
├── images/                # Docker 镜像文件 (212MB)
│   ├── headscale-v0.26.1.tar
│   └── derp-sha-82c26de.tar
└── pkg/                   # 依赖包
    └── centos/
        └── docker-compose # Docker Compose 二进制文件
```

### 环境变量
```bash
# 颜色控制
NO_COLOR=1              # 禁用颜色输出
FORCE_COLOR=1           # 强制启用颜色输出
```

## 🔍 故障排除

### 常见问题

#### 1. 端口已被占用
```bash
[ERROR] 端口 10001 已被占用
```
**解决方案**: 使用自定义端口安装
```bash
./linker.sh install --ip YOUR_IP --port-headscale 18080 --port-derp 18001
```

#### 2. Docker 权限问题
```bash
[ERROR] 无法访问Docker，请检查Docker安装和权限
```
**解决方案**: 
```bash
# 添加用户到 docker 组
sudo usermod -aG docker $USER
# 重新登录或执行
newgrp docker
```

#### 3. 服务未部署
```bash
[ERROR] 服务未部署，配置文件未完成初始化
```
**解决方案**: 先运行安装命令
```bash
./linker.sh install --ip YOUR_IP
```

#### 4. 客户端连接问题
- 检查防火墙设置，确保端口开放
- 验证 IP 地址和端口配置
- 检查 Headscale 服务状态

### 日志分析
```bash
# 查看详细日志
./linker.sh logs headscale -f
./linker.sh logs derp -f

# 检查服务状态
./linker.sh status
docker ps
```

### 手动诊断
```bash
# 检查端口监听
ss -tlnp | grep -E "(10001|10002|3478)"

# 检查服务健康
curl http://YOUR_IP:10001/health
curl http://YOUR_IP:10002/

# 检查容器状态
docker logs headscale
docker logs headscale_derp
```

## 🔐 安全注意事项

### 生产环境建议
1. **启用 HTTPS**: 使用 SSL/TLS 证书
2. **客户端验证**: 启用 `verify-clients`
3. **防火墙配置**: 限制不必要的端口访问
4. **定期备份**: 备份用户数据和配置
5. **监控日志**: 定期检查访问日志

### 网络安全
- 确保 DERP 服务器的安全配置
- 定期更新 Headscale 和相关组件
- 监控异常网络活动

## 🤝 贡献指南

欢迎提交 Issue 和 Pull Request！

### 开发环境
1. Fork 本项目
2. 创建特性分支: `git checkout -b feature/amazing-feature`
3. 提交更改: `git commit -m 'Add amazing feature'`
4. 推送分支: `git push origin feature/amazing-feature`
5. 创建 Pull Request

### 代码规范
- 使用 4 空格缩进
- 添加适当的注释
- 遵循现有的命名约定
- 确保兼容多个操作系统

## 📝 更新日志

### v1.0.1 (最新)
- ✅ 完善的错误处理和用户提示
- ✅ 智能颜色输出适配
- ✅ 双重部署状态验证
- ✅ 全面的命令行帮助系统
- ✅ 并发安全和回滚机制

### 主要改进
- 🎨 修复颜色输出兼容性问题
- 🛡️ 增强部署状态检查机制
- 📋 改进错误信息和操作指导
- 🔧 优化用户体验和交互

## 📄 许可证

本项目采用 MIT 许可证 - 查看 [LICENSE](LICENSE) 文件了解详情。

## 🙏 致谢

- [Headscale](https://github.com/juanfont/headscale) - 开源 Tailscale 控制服务器
- [Tailscale](https://tailscale.com/) - 现代 VPN 解决方案
- [DERP](https://pkg.go.dev/tailscale.com/derp) - Tailscale 中继服务器

## 📞 支持

如果您遇到问题或有任何建议，请：
1. 查看 [故障排除](#-故障排除) 部分
2. 搜索已有的 [Issues](../../issues)
3. 创建新的 [Issue](../../issues/new)

---

**快速链接**: [安装](#-快速开始) | [使用说明](#-详细使用说明) | [故障排除](#-故障排除) | [贡献](#-贡献指南)
