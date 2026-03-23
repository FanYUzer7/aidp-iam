FROM dataagent:20260318

WORKDIR /DataAgent/data-agent-rubik-dev

# 修改 vite.config.ts 中的 proxy target 为后端服务地址
# 后端服务地址通过 build args 传入，默认指向 k8s cluster 内部的服务
ARG RUBIK_BACKEND_URL=http://rubik-backend:43211/api

RUN sed -i "s|target: \"http://[^\"]*\"|target: \"${RUBIK_BACKEND_URL}\"|" vite.config.ts || true

EXPOSE 5173

ENTRYPOINT ["npm", "run", "dev", "--", "--host", "0.0.0.0"]