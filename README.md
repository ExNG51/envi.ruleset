envi.ruleset

## VPS 安全加固脚本

脚本位置：`vps/secure_sever.sh`

推荐执行顺序：

1. 在当前 SSH 会话之外，先打开一个备用 SSH 会话。
2. 运行 `sudo bash vps/secure_sever.sh`。
3. 配置 UFW 前先阅读端口检测摘要和即将执行的规则变更。
4. 执行 SSH 加固后，不要关闭当前会话，先用新 SSH 会话验证登录。

交互约定：

- 主菜单：`0` 退出脚本。
- 子菜单：`0` 返回上一级。
- 普通输入：`q` 取消当前操作并返回上一级。
- 默认值输入：提示会明确显示“回车使用默认值，q 取消”。

安全行为：

- UFW 重置前会显示摘要并要求输入 `yes` 确认。
- SSH 来源限制会明确区分“全部来源开放”和“仅允许当前 IP/CIDR”。
- Fail2ban 使用 `/etc/fail2ban/jail.d/99-sshd-hardening.local`，不会覆盖已有 `jail.local`。
- SSH 加固使用 `/etc/ssh/sshd_config.d/99-hardening.conf`，并在重启前执行 `sshd -t` 验证。
- 可通过 `SECURE_SERVER_DRY_RUN=1 sudo bash vps/secure_sever.sh` 查看将执行的高危命令。
