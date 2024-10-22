# 同步镜像到个人仓库

## 操作流程
- Fork 仓库
- 新增 Repository secrets
<br>进入仓库 Settings --> Secrets and variables --> Actions --> 点击 New repository secrets, 新增4个 secrets 分别为 REGISTRY 仓库地址,REGISTRY_NAMESPACE 命名空间,REGISTRY_USER 用户名, REGISTRY_PASSWORD 密码。
- 修改`images.yaml`文件,在文件中填入需要同步的镜像,例如：
```yaml
grafana/grafana:11.2.0
redis
```
- 提交
<br>提交后点击 Actions 查看同步过程。
