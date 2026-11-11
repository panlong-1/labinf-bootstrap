#!/usr/bin/env bash
# =====================================================================
# bootstrap.sh — PoliTO LabInf 无状态 VM：一步恢复 Claude Code + 课程项目
# 全程无需 sudo。用法（每次开机后，在终端粘贴一行）：
#   curl -fsSL https://raw.githubusercontent.com/panlong-1/labinf-bootstrap/main/bootstrap.sh -o /tmp/b.sh && bash /tmp/b.sh
# VM 的 bash 装了 ble.sh，SPICE 粘贴会带 ^[[200~：先运行 bash --norc 再粘贴。
# 可用环境变量临时覆盖下面的配置，例如：
#   REPO=isa-lab AUTH=pat bash /tmp/b.sh
# 本文件不含任何密钥，可放在公开仓库 / gist。
# =====================================================================
set -euo pipefail

# ======== 配置 ========
GH_USER="${GH_USER:-panlong-1}"
REPO="${REPO:-test-and-tolerance}"       # 私有项目仓库名
BRANCH="${BRANCH:-main}"
GIT_NAME="${GIT_NAME:-panlong-1}"
# 本仓库是公开的，默认用 GitHub noreply 邮箱，避免把真实邮箱公开；要用别的邮箱就运行时传 GIT_EMAIL=...
GIT_EMAIL="${GIT_EMAIL:-panlong-1@users.noreply.github.com}"
AUTH="${AUTH:-gh}"                       # gh  = gh 设备码登录（无需搬运任何密钥）
                                         # pat = 粘贴细粒度 PAT，只存在内存缓存里
WORK="${WORK:-$HOME/work}"
AUTOSAVE_MIN="${AUTOSAVE_MIN:-10}"       # >0：每 N 分钟自动 commit+push（防整点强制关机）；0 关闭
# =====================================

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }

if [[ "$GH_USER" == YOUR_* || "$REPO" == YOUR_* ]]; then
  warn "请先在脚本顶部填好 GH_USER / REPO，或用环境变量传入：REPO=yyy bash $0"
  exit 1
fi

mkdir -p "$HOME/.local/bin" "$WORK"
export PATH="$HOME/.local/bin:$PATH"

# ---------- 1. Claude Code（官方原生安装器，装到 ~/.local，无需 sudo / node）----------
say "1/5 安装 Claude Code"
if command -v claude >/dev/null 2>&1; then
  echo "已安装：$(claude --version 2>/dev/null || echo ok)"
else
  curl -fsSL https://claude.ai/install.sh | bash
  command -v claude >/dev/null || { warn "claude 安装失败"; exit 1; }
  echo "完成：$(claude --version 2>/dev/null || echo ok)"
fi

# ---------- 2. Git 身份 ----------
say "2/5 Git 身份"
if [[ -z "$GIT_NAME"  ]]; then read -rp "git user.name: " GIT_NAME; fi
if [[ -z "$GIT_EMAIL" ]]; then read -rp "git user.email（推荐 ID+用户名@users.noreply.github.com）: " GIT_EMAIL; fi
git config --global user.name  "$GIT_NAME"
git config --global user.email "$GIT_EMAIL"
git config --global init.defaultBranch main
git config --global pull.rebase true
git config --global rebase.autoStash true

# ---------- 3. GitHub 认证（凭据只活到关机）----------
say "3/5 GitHub 认证（AUTH=$AUTH）"
if [[ "$AUTH" == "gh" ]]; then
  if ! command -v gh >/dev/null 2>&1; then
    tmp=$(mktemp -d)
    # 用 releases/latest 的重定向取版本号：不经过管道，避免 grep -m1 提前关管道
    # 导致 curl 收到 SIGPIPE，在 set -o pipefail 下让整个脚本退出
    latest=$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/cli/cli/releases/latest)
    ver=${latest##*/v}
    curl -fsSL -o "$tmp/gh.tar.gz" \
      "https://github.com/cli/cli/releases/download/v${ver}/gh_${ver}_linux_amd64.tar.gz"
    tar -xzf "$tmp/gh.tar.gz" -C "$tmp"
    cp "$tmp/gh_${ver}_linux_amd64/bin/gh" "$HOME/.local/bin/"
    rm -rf "$tmp"
  fi
  if ! gh auth status -h github.com >/dev/null 2>&1; then
    echo "将显示一个 8 位设备码：在 VM 浏览器或手机打开 https://github.com/login/device 输入即可。"
    # VM 自动登录 labinf，GNOME 登录钥匙环没解锁，gh 默认往钥匙环存 token 会弹
    # “Authentication required”。改存 ~/.config/gh/hosts.yml：关机随模板还原，bye 也会 logout。
    gh auth login --hostname github.com --git-protocol https --web --insecure-storage --skip-ssh-key
  fi
  gh auth setup-git
else
  # PAT 只进 git 的内存缓存（8 小时），不落盘
  git config --global credential.helper 'cache --timeout=28800'
  read -rsp "粘贴 GitHub 细粒度 PAT（仅授权 $REPO，Contents: Read and write）: " PAT; echo
  printf 'protocol=https\nhost=github.com\nusername=%s\npassword=%s\n\n' "$GH_USER" "$PAT" \
    | git credential approve
  unset PAT
fi

# ---------- 4. 克隆 / 更新项目 ----------
PROJ="$WORK/$REPO"
say "4/5 项目 → $PROJ"
if [[ -d "$PROJ/.git" ]]; then
  git -C "$PROJ" pull --rebase
else
  git clone --branch "$BRANCH" "https://github.com/$GH_USER/$REPO.git" "$PROJ"
fi

# ---------- 5. Shell 快捷命令（写进 ~/.bashrc，关机即随模板还原）----------
say "5/5 安装快捷命令 save / bye"
MARK="# >>> labinf-bootstrap >>>"
if ! grep -qF "$MARK" "$HOME/.bashrc" 2>/dev/null; then
  cat >> "$HOME/.bashrc" <<EOF
$MARK
export PATH="\$HOME/.local/bin:\$PATH"
export PROJ="$PROJ"
# save [说明]：提交全部改动并推送
save() {
  ( cd "\$PROJ" || return 1
    git add -A
    git diff --cached --quiet || git commit -m "\${1:-wip: VM \$(date '+%F %H:%M')}"
    git pull --rebase && git push ) && echo "✔ 已推送到 GitHub"
}
# bye：保存 → 停自动保存 → 清掉本机凭据 → 关机
bye() {
  save "\${1:-}" || { echo "✘ 推送失败，未关机，请先处理"; return 1; }
  [[ -f "\$HOME/.labinf-autosave.pid" ]] && kill "\$(cat "\$HOME/.labinf-autosave.pid")" 2>/dev/null
  rm -f "\$HOME/.claude/.credentials.json"
  command -v gh >/dev/null && gh auth logout -h github.com 2>/dev/null <<<"y" || true
  git credential-cache exit 2>/dev/null || true
  systemctl poweroff || echo "关机被拒绝：请用桌面右上角菜单关机"
}
# <<< labinf-bootstrap <<<
EOF
fi

# 可选：后台自动保存（整点可能被管理员强制关机）
if (( AUTOSAVE_MIN > 0 )); then
  PIDF="$HOME/.labinf-autosave.pid"
  if [[ -f "$PIDF" ]]; then kill "$(cat "$PIDF")" 2>/dev/null || true; fi
  nohup bash -c "
    while sleep $((AUTOSAVE_MIN*60)); do
      cd '$PROJ' || exit
      git add -A
      git diff --cached --quiet || git commit -qm \"autosave: VM \$(date '+%F %H:%M')\"
      git pull -q --rebase && git push -q
    done" >"$HOME/.labinf-autosave.log" 2>&1 &
  echo $! > "$PIDF"
  echo "自动保存：每 ${AUTOSAVE_MIN} 分钟（日志 ~/.labinf-autosave.log）"
fi

m=$((10#$(date +%M)))
say "完成！距下一个整点还有 $((60 - m)) 分钟（可能被自动关机，记得 save）"
cat <<EOF
  claude          启动 Claude Code（首次输入 /login，在 VM 浏览器里授权）
  save "说明"     提交并推送
  bye             保存 + 清除凭据 + 关机
EOF
cd "$PROJ"
exec bash -i
