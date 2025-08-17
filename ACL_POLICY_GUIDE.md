# Headscale ACL 策略配置指南

## 📋 概述

ACL (Access Control List) 策略是 Headscale 中用于控制网络访问和 IP 地址分配的重要功能。通过配置 ACL 策略，你可以：

- 精确控制每个节点的 IP 地址
- 管理网络访问权限
- 设置标签和分组
- 实现细粒度的网络控制

## 🗂️ 文件结构

```
config/headscale/
├── config.yaml          # 主配置文件
├── derp.yaml           # DERP 服务器配置
└── acl.hujson          # ACL 策略文件 ✨
```

## ⚙️ 配置说明

### 1. ACL 策略文件 (`acl.hujson`)

```json
{
  "tagOwners": {
    "tag:admin": ["default"]
  },
  "hosts": {
    "macmini": "10.24.0.20",
    "macbookpro": "10.24.0.30", 
    "minipcn100": "10.24.0.10",
    "arm-centos7-1": "10.24.0.40"
  },
  "acls": [
    {
      "action": "accept",
      "src": ["*"],
      "dst": ["*:*"]
    }
  ]
}
```

### 2. 主配置文件 (`config.yaml`)

```yaml
# ACL Policy configuration
policy:
  mode: file
  path: /etc/headscale/acl.hujson
```

## 🔧 使用方法

### 启用 ACL 策略

1. **重启 Headscale 服务**
   ```bash
   ./linker.sh restart headscale
   ```

2. **验证配置**
   ```bash
   # 检查服务状态
   ./linker.sh status
   
   # 查看节点列表
   headscale nodes list
   ```

### 修改 IP 地址

1. **编辑 ACL 策略文件**
   ```bash
   vim config/headscale/acl.hujson
   ```

2. **修改 hosts 部分**
   ```json
   "hosts": {
     "节点名称": "期望的IP地址"
   }
   ```

3. **重启服务生效**
   ```bash
   ./linker.sh restart headscale
   ```

## 📝 配置字段说明

### `tagOwners`
- 定义标签的所有者
- `"tag:admin": ["default"]` 表示 `default` 用户拥有 `admin` 标签

### `hosts`
- 静态 IP 地址映射
- 格式：`"主机名": "IP地址"`
- 支持 IPv4 和 IPv6

### `acls`
- 访问控制规则
- `"action": "accept"` 表示允许访问
- `"src": ["*"]` 表示所有源
- `"dst": ["*:*"]` 表示所有目标的所有端口

## 🚀 高级用法

### 1. 标签管理
```json
{
  "tagOwners": {
    "tag:server": ["admin"],
    "tag:client": ["user1", "user2"]
  }
}
```

### 2. 分组管理
```json
{
  "groups": {
    "group:admins": ["tag:admin"],
    "group:users": ["tag:client"]
  }
}
```

### 3. 端口控制
```json
{
  "acls": [
    {
      "action": "accept",
      "src": ["tag:admin"],
      "dst": ["*:22", "*:80", "*:443"]
    }
  ]
}
```

## ⚠️ 注意事项

1. **IP 地址范围**：确保分配的 IP 在 `prefixes` 配置的范围内
2. **主机名一致性**：`hosts` 中的主机名必须与节点名称完全匹配
3. **配置文件格式**：使用 `.hujson` 格式，支持注释和更灵活的语法
4. **重启要求**：修改 ACL 策略后必须重启 Headscale 服务

## 🔍 故障排除

### 常见问题

1. **IP 地址未生效**
   - 检查主机名是否匹配
   - 确认 IP 地址在有效范围内
   - 重启 Headscale 服务

2. **策略文件语法错误**
   - 使用 JSON 验证工具检查语法
   - 查看 Headscale 日志获取详细错误信息

3. **权限问题**
   - 确认文件权限正确
   - 检查 Docker 挂载配置

## 📚 参考资源

- [Headscale ACL 文档](https://github.com/juanfont/headscale/blob/main/docs/acls.md)
- [Tailscale ACL 语法](https://tailscale.com/kb/1018/acls/)
- [HuJSON 格式说明](https://github.com/tailscale/hujson)
