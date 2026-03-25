# rubik-frontend 镜像说明

## 概述

本目录包含 rubik 前端镜像的 Dockerfiles 和 Helm 配置，支持 npm 包管理方式部署。

## 镜像架构

### 1. Dockerfile.base (基础镜像)

- **基础镜像**: `node:20-alpine` + nginx
- **包含内容**:
  - Node.js 20 环境
  - nginx Web 服务器
  - 完整的 `node_modules`（通过 `npm ci` 安装）
  - 已构建的前端静态文件（`dist/`）
- **用途**:
  - 作为 slim 镜像的基础
  - 可用于开发调试
- **默认行为**: 不启动 nginx（`CMD ["sleep", "infinity"]`）

### 2. Dockerfile.slim (胖更新镜像)

- **基础镜像**: `rubik-frontend:base`
- **包含内容**: 基于 base 镜像，用最新源码重新构建
- **用途**:
  - 用于离线环境下的增量更新
  - 构建新版本镜像供 k8s 部署
- **默认行为**: 启动 nginx 服务（`CMD ["nginx", "-g", "daemon off;"]`）

### 3. nginx.conf

nginx 配置文件，提供以下功能：
- **SPA 路由**: 所有路径返回 `index.html`（支持 React Router）
- **API 代理**: `/kbApi/*` 转发到 `http://rubik-backend:43211/api/`
- **WebSocket 支持**: 用于 LLM 流式响应
- **静态资源缓存**: JS/CSS/图片等 30 天缓存

## 构建命令

### 构建基础镜像

```bash
cd da-cluster/images/rubik-frontend

# 构建基础镜像（包含 node + nginx + node_modules + 初始前端）
docker build -f Dockerfile.base -t rubik-frontend:base .

# 打标签推送到仓库
docker tag rubik-frontend:base <registry>/rubik-frontend:base
docker push <registry>/rubik-frontend:base
```

### 构建胖更新镜像

```bash
# 构建胖更新镜像（使用最新源码）
docker build -f Dockerfile.slim -t rubik-frontend:v1.x.x .

# 打标签推送到仓库
docker tag rubik-frontend:v1.x.x <registry>/rubik-frontend:v1.x.x
docker push <registry>/rubik-frontend:v1.x.x
```

## 部署

### 使用 Helm 部署

```bash
# 部署 base 镜像（不启动 nginx）
helm upgrade --install rubik-frontend ./helm/rubik-frontend \
  -n rubik --create-namespace \
  --set image.repository=<registry> \
  --set image.tag=base

# 部署 slim 镜像（启动 nginx 服务）
helm upgrade --install rubik-frontend ./helm/rubik-frontend \
  -n rubik --create-namespace \
  --set image.repository=<registry> \
  --set image.tag=v1.x.x
```

### 更新前端代码

1. 准备好新版本的前端源码（`data-agent-rubik-dev_temp/`）
2. 使用 Dockerfile.slim 构建新镜像
3. 推送镜像到仓库
4. 更新 k8s deployment：

```bash
helm upgrade --install rubik-frontend ./helm/rubik-frontend \
  -n rubik \
  --set image.tag=v1.x.x
```

## 端口配置

| 端口类型 | 值 | 说明 |
|---------|-----|------|
| `service.port` | 80 | nginx 监听端口 |
| `service.nodePort` | 32777 | NodePort 外部访问端口 |
| `config.port` | 80 | 容器内监听端口 |

**访问方式**: `http://<node-ip>:32777`

## 路由说明

| 路径 | 目标 | 说明 |
|------|------|------|
| `/` | 前端静态文件 | React SPA |
| `/kbApi/*` | `http://rubik-backend:43211/api/*` | 后端 API 代理 |

## 前端 API 调用说明

前端代码中使用相对路径 `/kbApi` 作为 API 前缀：

```typescript
// src/lib/api.ts
const API_BASE = import.meta.env.VITE_API_BASE || "/kbApi";
```

构建后的应用通过 nginx 代理将 `/kbApi/*` 请求转发到后端服务，无需修改代码即可适应不同环境。

## 文件结构

```
rubik-frontend/
├── Dockerfile.base      # 基础镜像
├── Dockerfile.slim     # 胖更新镜像
├── nginx.conf          # 本地开发用 nginx 配置（仅供参考）
├── README.md           # 本文档
└── helm/
    └── rubik-frontend/
        ├── Chart.yaml
        ├── values.yaml
        └── templates/
            ├── _helpers.tpl
            ├── configmap.yaml    # nginx ConfigMap 配置
            ├── deployment.yaml
            └── service.yaml
```

## nginx 配置热更新

nginx.conf 通过 Kubernetes ConfigMap 管理，修改配置后无需重建镜像即可生效。

### 更新 nginx 配置

```bash
# 方式 1: 直接编辑 Helm values 并升级
helm upgrade --install rubik-frontend ./helm/rubik-frontend -n rubik \
  --set nginx.config="<new config>"

# 方式 2: 编辑 ConfigMap（需手动重载）
kubectl edit configmap rubik-frontend-nginx -n rubik
# 修改后，手动重载 nginx：
kubectl exec -n rubik deployment/rubik-frontend -- nginx -s reload
```

### 配置生效机制

1. ConfigMap 更新后，kubelet 会在短时间内同步到挂载的文件
2. 容器启动时通过 `lifecycle.postStart` 钩子自动执行 `nginx -s reload`
3. 对于已运行的容器，手动执行 `nginx -s reload` 使配置生效

## 注意事项

1. **node_modules**: base 镜像包含完整的 node_modules，slim 构建时会复用，无需重新下载
2. **离线构建**: slim 镜像构建时不需要网络下载依赖（因为复用 base 的 node_modules）
3. **镜像大小**: base 镜像会比较大（包含 node_modules），但 slim 可以复用其层
4. **nginx 启动**: base 镜像默认不启动 nginx，slim 镜像默认启动
5. **ConfigMap**: nginx 配置通过 Helm values 的 `nginx.config` 字段管理，存储在 ConfigMap 中
