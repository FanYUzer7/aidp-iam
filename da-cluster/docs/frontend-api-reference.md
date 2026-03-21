# 前端 UI 对接 API 参考

## API 地址说明

前端部署在 K8s 内（nginx 容器），nginx 已配置反向代理到 IAM Gateway 和 Keycloak。
**前端代码中所有 API 请求使用相对路径，不需要加域名或端口。**

```
前端代码中:
  fetch('/api/v1/tenants')          ✅ 相对路径
  fetch('/realms/master/...')       ✅ 相对路径

不要写:
  fetch('http://localhost:8080/api/v1/tenants')   ❌
```

nginx 会自动将请求代理到 K8s 内部的 Gateway Service。

如果用 curl 从集群外测试，需要加服务器地址：

```bash
curl http://<server-ip>:30080/api/v1/tenants       # NodePort
curl http://localhost:8080/api/v1/tenants           # port-forward
```

Gateway 会自动对受保护路由执行 OPA ext-authz 鉴权，前端只需在请求头带 `Authorization: Bearer <token>`。

---

## 1. 认证（Login）

### 1.1 Super-admin 登录（master realm，账号密码直接登录）

| 项目 | 内容 |
|------|------|
| **UI** | Super-admin 登录表单，输入 username + password |
| **方法** | `POST` |
| **URL** | `/realms/master/protocol/openid-connect/token` |
| **Content-Type** | `application/x-www-form-urlencoded` |
| **需要 Token** | 否 |

**请求参数：**

```
grant_type=password
client_id=admin-cli
username=super-admin
password=<密码>
```

> 使用 `admin-cli`（Keycloak 内置 public client），**不需要 client_secret**，安全适用于 SPA 前端。
>
> 如果后端服务间调用（非浏览器），可使用 `idb-proxy-client` + secret（client_credentials grant）：
> ```bash
> # 获取 client_secret（在服务器上执行）
> kubectl -n keycloak get secret keycloak-idb-proxy-client \
>   -o jsonpath='{.data.client-secret}' | base64 -d
> ```

**响应：**

```json
{
  "access_token": "eyJhbG...",
  "refresh_token": "eyJhbG...",
  "expires_in": 300,
  "token_type": "Bearer"
}
```

### 1.2 Tenant 用户登录（tenant realm，OIDC redirect）

| 项目 | 内容 |
|------|------|
| **UI** | Tenant 登录页，点击按钮跳转到 Keycloak 登录界面 |
| **方法** | 浏览器 redirect |
| **URL** | `/realms/{realm}/protocol/openid-connect/auth` |
| **需要 Token** | 否 |

**Redirect URL 构造：**

```javascript
// 前端代码示例
const realm = 'data-agent';
const redirectUri = `${window.location.origin}/login/callback`;  // 回调页面

const loginUrl = `/realms/${realm}/protocol/openid-connect/auth`
  + `?response_type=code`
  + `&client_id=data-agent`
  + `&redirect_uri=${encodeURIComponent(redirectUri)}`
  + `&scope=openid profile email`;

window.location.href = loginUrl;
```

> **redirect_uri 说明：**
> - 必须是前端路由中存在的页面（如 `/login/callback`）
> - 该页面负责接收 URL 中的 `code` 参数并换取 token
> - 必须与 Keycloak client 配置的 `Valid Redirect URIs` 匹配
> - 创建租户时 `data-agent` client 的 redirectUris 已设为 `["*"]`（通配），所以任意 URL 都可以
> - 实际地址示例：`http://10.0.0.1:30080/login/callback`

**回调页面收到 code 后，换取 token：**

| 项目 | 内容 |
|------|------|
| **方法** | `POST` |
| **URL** | `/realms/{realm}/protocol/openid-connect/token` |
| **Content-Type** | `application/x-www-form-urlencoded` |

```
grant_type=authorization_code
client_id=data-agent
code=<URL 中的 code 参数>
redirect_uri=<和上面完全相同的 redirect_uri>
```

> `data-agent` 是 public client，**不需要 client_secret**。

```javascript
// 前端回调页面代码示例
const code = new URLSearchParams(window.location.search).get('code');
const redirectUri = `${window.location.origin}/login/callback`;

const resp = await fetch(`/realms/${realm}/protocol/openid-connect/token`, {
  method: 'POST',
  headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
  body: new URLSearchParams({
    grant_type: 'authorization_code',
    client_id: 'data-agent',
    code: code,
    redirect_uri: redirectUri,
  })
});
const { access_token, refresh_token } = await resp.json();
```

### 1.3 Token 刷新

| 项目 | 内容 |
|------|------|
| **方法** | `POST` |
| **URL** | `/realms/{realm}/protocol/openid-connect/token` |

```
grant_type=refresh_token
client_id=admin-cli                    (super-admin)
  或 client_id=data-agent              (tenant user)
refresh_token=<refresh_token>
```

> Public client 刷新 token 也不需要 client_secret。

### 1.4 Token 结构（解码后）

```json
{
  "iss": "http://localhost:8080/realms/data-agent",
  "sub": "user-uuid",
  "preferred_username": "tenant-admin",
  "email": "tenant-admin@data-agent.local",
  "realm_id": "realm-uuid",
  "roles": [
    {"id": "role-uuid-1", "name": "tenant-admin"}
  ]
}
```

> 前端使用 `roles` 字段（`[{id, name}]` 结构），其中 `id` 是角色 UUID，`name` 是角色名。
> `iss` 中的 realm 名就是 tenant-id。

---

## 2. Tenant 管理（Super-admin）

### 2.1 获取 Tenant 列表

| 项目 | 内容 |
|------|------|
| **UI** | Tenant 列表页 |
| **方法** | `GET` |
| **URL** | `/api/v1/tenants` |
| **权限** | super-admin |

**响应：**

```json
[
  {
    "id": "data-agent",
    "realm": "data-agent",
    "displayName": "Data Agent (Default Tenant)",
    "enabled": true
  }
]
```

### 2.2 创建 Tenant

| 项目 | 内容 |
|------|------|
| **UI** | 创建 Tenant 表单（填写 realm name + display name） |
| **方法** | `POST` |
| **URL** | `/api/v1/tenants` |
| **权限** | super-admin |

**请求体：**

```json
{
  "realm": "new-tenant",
  "displayName": "New Tenant"
}
```

**响应（201）：**

```json
{
  "realm": "new-tenant",
  "id": "new-tenant",
  "admin_role": "tenant-admin"
}
```

> 创建 Tenant 后自动创建 `tenant-admin` 角色和 `data-agent` client。

### 2.3 删除 Tenant

| 项目 | 内容 |
|------|------|
| **UI** | Tenant 列表中的删除按钮 |
| **方法** | `DELETE` |
| **URL** | `/api/v1/tenants/{realm_name}` |
| **权限** | super-admin |

**响应（200）：**

```json
{"msg": "Tenant new-tenant deleted successfully"}
```

### 2.4 配置 Tenant SAML 接入（创建 Tenant 后的 next 步骤）

#### 方式一：手动填写参数

| 项目 | 内容 |
|------|------|
| **UI** | SAML 接入参数表单（SSO URL、Entity ID 等） |
| **方法** | `POST` |
| **URL** | `/api/v1/{realm}/idp/saml/instances` |
| **权限** | tenant-admin / super-admin |

**请求体：**

```json
{
  "displayName": "Corporate SAML IDP",
  "enabled": true,
  "trustEmail": false,
  "config": {
    "singleSignOnServiceUrl": "https://idp.example.com/sso",
    "entityId": "https://idp.example.com/entity"
  }
}
```

#### 方式二：上传 XML Metadata

| 项目 | 内容 |
|------|------|
| **UI** | 上传 SAML Metadata XML 文件 |
| **方法** | `POST` |
| **URL** | `/api/v1/{realm}/idp/saml/import` |
| **Content-Type** | `multipart/form-data` |

```
file=@metadata.xml
```

#### 查看 SAML 配置

| 方法 | URL | 说明 |
|------|-----|------|
| `GET` | `/api/v1/{realm}/idp/saml/instances` | 获取 IDP 实例列表 |
| `PUT` | `/api/v1/{realm}/idp/saml/instances` | 更新 IDP 配置 |
| `DELETE` | `/api/v1/{realm}/idp/saml/instances/{alias}` | 删除 IDP 实例 |

#### IDP Protocol Mappers 管理

| 方法 | URL | 说明 |
|------|-----|------|
| `GET` | `/api/v1/{realm}/idp/saml/instances/{alias}/mappers` | 列出 Mappers |
| `POST` | `/api/v1/{realm}/idp/saml/instances/{alias}/mappers` | 创建 Mapper |
| `PUT` | `/api/v1/{realm}/idp/saml/instances/{alias}/mappers/{mapper_id}` | 更新 Mapper |
| `DELETE` | `/api/v1/{realm}/idp/saml/instances/{alias}/mappers/{mapper_id}` | 删除 Mapper |

**创建 Mapper 请求体：**

```json
{
  "name": "group-mapping",
  "identityProviderMapper": "saml-user-attribute-idp-mapper",
  "config": {
    "user.attribute": "department",
    "attribute.name": "urn:oid:2.5.4.11"
  }
}
```

---

## 3. User 管理（Tenant Admin）

### 3.1 获取 User 列表

| 项目 | 内容 |
|------|------|
| **UI** | User 管理页 - 用户列表 |
| **方法** | `GET` |
| **URL** | `/api/v1/{realm}/users` |
| **权限** | tenant-admin / super-admin |

**响应：**

```json
[
  {
    "id": "user-uuid",
    "username": "normal-user",
    "email": "normal-user@data-agent.local",
    "firstName": "Normal",
    "lastName": "User",
    "enabled": true
  }
]
```

### 3.2 获取 User 详情（name, groups, roles）

| 项目 | 内容 |
|------|------|
| **UI** | User 列表中点击 View → 显示 name、groups、roles |
| **方法** | `GET` |
| **URL** | `/api/v1/{realm}/users/{user_id}/details` |
| **权限** | tenant-admin / super-admin |

**响应：**

```json
{
  "groups": [
    {"id": "group-uuid", "name": "dev-team"}
  ],
  "roles": [
    {"id": "role-uuid", "name": "normal-user"}
  ]
}
```

---

## 4. Group 管理（Tenant Admin）

### 4.1 获取 Group 列表

| 项目 | 内容 |
|------|------|
| **UI** | Group 管理页 - 组列表 |
| **方法** | `GET` |
| **URL** | `/api/v1/{realm}/groups` |
| **权限** | tenant-admin / super-admin |

**响应：**

```json
[
  {"id": "group-uuid", "name": "dev-team", "subGroups": []}
]
```

### 4.2 获取 Group 详情（members + roles）

| 项目 | 内容 |
|------|------|
| **UI** | Group 列表中点击 View |
| **方法** | `GET` |
| **URL** | `/api/v1/{realm}/groups/{group_id}` |
| **权限** | tenant-admin / super-admin |

**响应：**

```json
{
  "id": "group-uuid",
  "name": "dev-team",
  "members": [
    {"id": "user-uuid", "username": "normal-user"}
  ],
  "roles": [
    {"id": "role-uuid", "name": "normal-user"}
  ]
}
```

### 4.3 创建 Group

| 项目 | 内容 |
|------|------|
| **UI** | Add Group 表单 — name、roles（下拉多选）、members（下拉多选） |
| **方法** | `POST` |
| **URL** | `/api/v1/{realm}/groups` |
| **权限** | tenant-admin / super-admin |

**请求体：**

```json
{
  "name": "new-group",
  "roles": ["role-name-1", "role-name-2"],
  "users": ["username-1", "username-2"]
}
```

> `roles` 传角色名数组，`users` 传用户名数组。

**响应（201）：**

```json
{"msg": "Group new-group created with users/roles", "id": "group-uuid"}
```

### 4.4 编辑 Group

| 项目 | 内容 |
|------|------|
| **UI** | Edit Group — 修改 name、roles、members |
| **方法** | `PUT` |
| **URL** | `/api/v1/{realm}/groups/{group_id}` |
| **权限** | tenant-admin / super-admin |

**请求体（只传需要修改的字段）：**

```json
{
  "name": "updated-group-name",
  "roles": ["role-name-1"],
  "users": ["username-1", "username-3"]
}
```

### 4.5 删除 Group

| 项目 | 内容 |
|------|------|
| **方法** | `DELETE` |
| **URL** | `/api/v1/{realm}/groups/{group_id}` |

---

## 5. Role 管理（Tenant Admin）

### 5.1 获取 Role 列表

| 项目 | 内容 |
|------|------|
| **UI** | Role 管理页 - 角色列表（显示角色名 + 绑定的 Policy） |
| **方法** | `GET` |
| **URL** | `/api/v1/{realm}/roles` |
| **权限** | tenant-admin / super-admin |

**响应：**

```json
[
  {"id": "role-uuid-1", "name": "tenant-admin", "description": "Tenant administrator"},
  {"id": "role-uuid-2", "name": "normal-user", "description": "Normal user"}
]
```

### 5.2 查询 Role 绑定的 Policy

| 项目 | 内容 |
|------|------|
| **UI** | Role 列表中每行显示绑定的 Policy 名称 |
| **方法** | `GET` |
| **URL** | `/api/v1/roles/{role_id}/policy` |
| **权限** | 任意有效 token |

> 前端拿到 Role 列表后，对每个 role 的 `id` 调用此接口获取绑定的 policy。

**响应（200，有绑定）：**

```json
{
  "role_id": "role-uuid",
  "policy": {
    "id": "documents-allow",
    "tenant_id": "data-agent",
    "rules": [{"resource": "documents", "effect": "allow"}],
    "created_at": "2026-03-19T12:00:00",
    "updated_at": "2026-03-19T12:00:00"
  }
}
```

**响应（404，无绑定）：**

```json
{"detail": "No policy binding found for role"}
```

### 5.3 创建 Role（两步）

**Step 1：创建角色**

| 项目 | 内容 |
|------|------|
| **UI** | Create Role 表单 — name、description、resource policy 下拉 |
| **方法** | `POST` |
| **URL** | `/api/v1/{realm}/roles` |

```json
{"name": "viewer", "description": "Read-only viewer"}
```

**Step 2：绑定 Policy（可选，如果用户选了 resource policy）**

| 项目 | 内容 |
|------|------|
| **方法** | `POST` |
| **URL** | `/api/v1/roles/{role_id}/policy` |

```json
{"policy_id": "documents-allow", "tenant_id": "data-agent"}
```

> `role_id` 从 Step 1 创建后查 Role 列表获取 UUID，或者直接用 Keycloak 返回的信息。
> 前端流程：创建角色 → 查询 role 获取 UUID → 绑定 policy。

### 5.4 编辑 Role

**更新角色基本信息：**

| 方法 | URL |
|------|-----|
| `PUT` | `/api/v1/{realm}/roles/{role_name}` |

```json
{"description": "Updated description"}
```

**更新/替换绑定的 Policy：**

| 方法 | URL |
|------|-----|
| `PUT` | `/api/v1/roles/{role_id}/policy` |

```json
{"policy_id": "new-policy-id", "tenant_id": "data-agent"}
```

### 5.5 删除 Role

| 方法 | URL |
|------|-----|
| `DELETE` | `/api/v1/{realm}/roles/{role_name}` |

### 5.6 通过 UUID 管理 Role（by-id 接口）

> 适用于需要通过角色 UUID 而非角色名操作的场景（如角色改名后 UUID 不变）。

| 操作 | 方法 | URL |
|------|------|-----|
| 查看 | `GET` | `/api/v1/{realm}/roles/by-id/{role_uuid}` |
| 编辑（支持改名） | `PUT` | `/api/v1/{realm}/roles/by-id/{role_uuid}` |
| 删除 | `DELETE` | `/api/v1/{realm}/roles/by-id/{role_uuid}` |

**PUT 请求体：**

```json
{"name": "new-role-name", "description": "Updated description"}
```

**PUT 响应（200）：**

```json
{"msg": "Role updated", "id": "role-uuid"}
```

---

## 6. Resource Policy 管理（Tenant Admin）

### 6.1 获取 Policy 列表

| 项目 | 内容 |
|------|------|
| **UI** | Resource Policy 页 — policy 列表 |
| **方法** | `GET` |
| **URL** | `/api/v1/policies` |
| **权限** | 任意有效 token |

**响应：**

```json
{
  "policies": [
    {
      "id": "documents-allow",
      "tenant_id": "data-agent",
      "rules": [
        {"resource": "documents", "effect": "allow"},
        {"resource": "reports", "effect": "deny"}
      ],
      "created_at": "2026-03-19T12:00:00",
      "updated_at": "2026-03-19T12:00:00"
    }
  ],
  "count": 1,
  "tenant_id": "data-agent"
}
```

### 6.2 获取单个 Policy 详情

| 项目 | 内容 |
|------|------|
| **UI** | Policy 列表中点击 View |
| **方法** | `GET` |
| **URL** | `/api/v1/policies/{policy_id}` |

### 6.3 创建 Policy

| 项目 | 内容 |
|------|------|
| **UI** | Add Policy 表单 — name + resource 列表（每个 resource 选 allow/deny） |
| **方法** | `POST` |
| **URL** | `/api/v1/policies` |
| **权限** | tenant-admin / super-admin |

**请求体：**

```json
{
  "name": "documents-allow",
  "tenant_id": "data-agent",
  "rules": [
    {"resource": "documents", "effect": "allow"},
    {"resource": "reports", "effect": "deny"},
    {"resource": "settings", "effect": "allow"}
  ]
}
```

> `name` 即 policy ID，全局唯一（tenant 内）。
> `rules` 数组中每个 resource 对应一个 allow/deny 开关。

### 6.4 编辑 Policy

| 项目 | 内容 |
|------|------|
| **UI** | Edit Policy — 修改 resource 的 allow/deny |
| **方法** | `PUT` |
| **URL** | `/api/v1/policies/{policy_id}` |
| **权限** | tenant-admin / super-admin |

**请求体（完整覆盖）：**

```json
{
  "name": "documents-allow",
  "tenant_id": "data-agent",
  "rules": [
    {"resource": "documents", "effect": "allow"},
    {"resource": "reports", "effect": "allow"}
  ]
}
```

### 6.5 删除 Policy

| 项目 | 内容 |
|------|------|
| **方法** | `DELETE` |
| **URL** | `/api/v1/policies/{policy_id}` |
| **权限** | tenant-admin / super-admin |

> 删除 policy 会同时删除所有关联的 role-policy 绑定。

---

## 7. 权限检查 API

### 7.1 主动权限查询

| 项目 | 内容 |
|------|------|
| **UI** | 前端需要判断用户是否有某资源访问权限时调用 |
| **方法** | `POST` |
| **URL** | `/api/v1/auth/check` |
| **权限** | 任意有效 token |

**请求体：**

```json
{
  "resource": "documents",
  "tenant_id": "data-agent"
}
```

**响应：**

```json
{
  "allowed": true,
  "user": "user-uuid",
  "tenant_id": "data-agent",
  "resource": "documents",
  "reason": "Allowed by policy"
}
```

---

## 8. Gateway ext-authz Headers

经过 OPA 鉴权后，gateway 会在转发到后端的请求中注入以下 headers：

| Header | 值 | 说明 |
|--------|---|------|
| `X-Auth-User-Id` | `sub` (UUID) | 用户 ID |
| `X-Auth-Username` | `preferred_username` | 用户名 |
| `X-Auth-Roles` | `role1,role2` | 角色名（逗号分隔） |
| `X-Auth-Role-Ids` | `uuid1,uuid2` | 角色 UUID（逗号分隔） |
| `X-Auth-Issuer` | `http://localhost/realms/data-agent` | Token 签发者 |
| `X-Auth-Tenant` | `data-agent` | 租户（realm 名称） |

---

## 9. 前端调用流程总结

### Super-admin 完整流程

```
1. POST /realms/master/.../token (password grant) → 获取 access_token
2. GET  /api/v1/tenants                           → 展示 Tenant 列表
3. POST /api/v1/tenants                           → 创建新 Tenant
4. POST /api/v1/{realm}/idp/saml/instances         → 配置 SAML 接入
```

### Tenant Admin 完整流程

```
1. Redirect → /realms/{realm}/.../auth             → Keycloak 登录
2. POST /realms/{realm}/.../token (code exchange)   → 获取 access_token

-- User 管理 --
3. GET  /api/v1/{realm}/users                       → User 列表
4. GET  /api/v1/{realm}/users/{id}/details          → User 详情

-- Group 管理 --
5. GET  /api/v1/{realm}/groups                      → Group 列表
6. GET  /api/v1/{realm}/groups/{id}                 → Group 详情
7. POST /api/v1/{realm}/groups                      → 创建 Group
8. PUT  /api/v1/{realm}/groups/{id}                 → 编辑 Group
9. DELETE /api/v1/{realm}/groups/{id}               → 删除 Group

-- Role 管理 --
10. GET  /api/v1/{realm}/roles                      → Role 列表
11. GET  /api/v1/roles/{role_id}/policy             → 查询 Role 绑定的 Policy
12. POST /api/v1/{realm}/roles                      → 创建 Role
13. POST /api/v1/roles/{role_id}/policy             → 绑定 Policy 到 Role
14. PUT  /api/v1/{realm}/roles/{name}               → 编辑 Role 基本信息
15. PUT  /api/v1/roles/{role_id}/policy             → 更新 Role 的 Policy 绑定
16. DELETE /api/v1/{realm}/roles/{name}             → 删除 Role

-- Resource Policy 管理 --
17. GET  /api/v1/policies                           → Policy 列表
18. GET  /api/v1/policies/{id}                      → Policy 详情
19. POST /api/v1/policies                           → 创建 Policy
20. PUT  /api/v1/policies/{id}                      → 编辑 Policy
21. DELETE /api/v1/policies/{id}                    → 删除 Policy
```

---

## 10. 三级权限模型

| 角色 | 权限范围 | OPA 判断 |
|------|---------|---------|
| **super-admin** | 跨所有 tenant，所有操作 | `iss` 来自 master realm 或 roles 含 `super-admin` |
| **tenant-admin** | 本 tenant 内所有操作 | roles 含 `tenant-admin` 且 `tenant_id` 匹配 |
| **normal-user** | 仅可访问 role-policy 绑定的 resource | role UUID → role_bindings → policy.rules 匹配 |
